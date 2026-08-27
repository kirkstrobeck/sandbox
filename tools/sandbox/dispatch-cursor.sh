#!/usr/bin/env bash
# Cursor CLI backend for dispatch.sh. Source, don't run.

cursor_result_from_log() {
  local log="$1" out
  out="$(jq -Rr 'fromjson? | select(.type == "result") | .result // empty' "$log" 2>/dev/null | tail -1 || true)"
  [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  jq -Rr 'fromjson? | select(.type == "assistant")
         | [.message.content[]? | select(.type == "text") | .text] | add // empty' \
    "$log" 2>/dev/null | tail -1 || true
}

dispatch_cursor() {
  local continue_flag="$1" run_dir_host="$2" run_dir_ctr="$3"
  local session_file="$CACHE_DIR/cursor-session-slot-${SANDBOX_SLOT:-0}"
  local session_id=""
  local slot_run="/workspace/${SANDBOX_DIR#"$REPO_ROOT"/}/slot-run.sh"

  if [ -n "$continue_flag" ] && [ -f "$session_file" ]; then
    session_id="$(cat "$session_file" 2>/dev/null || true)"
  fi

  docker exec "$SANDBOX_NAME" pkill -f "$(slot_kill_pattern "$SANDBOX_SLOT")" >/dev/null 2>&1 || true

  docker exec -u agent -w /workspace \
    -e "MSG_FILE=$run_dir_ctr/msg" \
    -e "LOG_FILE=$run_dir_ctr/last.jsonl" \
    -e "ERR_FILE=$run_dir_ctr/last.err" \
    -e "SESSION_ID=$session_id" \
    -e "SLOT_RUN=$slot_run" \
    -e "SANDBOX_SLOT=${SANDBOX_SLOT:-0}" \
    -e "SANDBOX_ROLE=${SANDBOX_ROLE:-agent}" \
    -e "SANDBOX_INNER_MODEL=${SANDBOX_INNER_MODEL:-}" \
    -e "SANDBOX_MODEL_DAILY=${SANDBOX_MODEL_DAILY:-}" \
    "$SANDBOX_NAME" bash -lc '
      msg="$(cat "$MSG_FILE")"
      set -- -p --force --trust --sandbox disabled --output-format stream-json
      [ -n "$SESSION_ID" ] && set -- "$@" --resume "$SESSION_ID"
      [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
      bash "$SLOT_RUN" "$SANDBOX_SLOT" agent "$@" -- "$msg" >"$LOG_FILE" 2>"$ERR_FILE"
    ' </dev/null || true

  bash "$SCRIPT_DIR/cursor-token-sync.sh" push >&2 || true

  local new_session
  new_session="$(jq -Rr 'fromjson? | select(.session_id != null) | .session_id' \
    "$run_dir_host/last.jsonl" 2>/dev/null | tail -1 || true)"
  [ -n "$new_session" ] && printf '%s' "$new_session" >"$session_file"
  ln -sfn "cursor-session-slot-${SANDBOX_SLOT:-0}" "$CACHE_DIR/cursor-session" 2>/dev/null || true

  local result
  result="$(cursor_result_from_log "$run_dir_host/last.jsonl")"

  if [ -z "$result" ]; then
    [ -s "$run_dir_host/last.err" ] && cat "$run_dir_host/last.err" >&2
    tail -20 "$run_dir_host/last.jsonl" 2>/dev/null >&2 || true
    echo "Inner Cursor produced no final message. Raw log tail is above." >&2
    return 1
  fi

  printf '%s\n' "$result"

  local is_error
  is_error="$(jq -Rr 'fromjson? | select(.type == "result") | .is_error' \
    "$run_dir_host/last.jsonl" 2>/dev/null | tail -1 || true)"
  [ "$is_error" = "true" ] && return 1
  return 0
}
