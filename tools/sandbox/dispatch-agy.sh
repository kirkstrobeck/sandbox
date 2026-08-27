#!/usr/bin/env bash
# Antigravity (agy) backend for dispatch.sh. Source, don't run.

agy_result_from_stream() {
  local jsonl_file="$1" err_file="${2:-}"

  if [ ! -s "$jsonl_file" ]; then
    [ -s "$err_file" ] && cat "$err_file" >&2
    echo "Inner agy produced no output. Check: docker logs $SANDBOX_NAME" >&2
    return 1
  fi

  local result is_error
  result="$(grep -v '^$' "$jsonl_file" | jq -r 'select(.type == "result") | .result // ""' 2>/dev/null | tail -1 || true)"
  is_error="$(grep -v '^$' "$jsonl_file" | jq -r 'select(.type == "result") | .is_error // false' 2>/dev/null | tail -1 || printf 'false')"

  if [ -z "$result" ]; then
    result="$(grep -v '^$' "$jsonl_file" | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null | tail -1 || true)"
  fi

  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    [ "$is_error" = "true" ] && return 1
    return 0
  fi

  [ -s "$err_file" ] && cat "$err_file" >&2
  echo "Inner agy produced no final message. See: $jsonl_file" >&2
  return 1
}

dispatch_agy() {
  local continue_flag="$1" run_dir_host="$2" run_dir_ctr="$3"
  local conv_file="$CACHE_DIR/agy-conversation-slot-${SANDBOX_SLOT:-0}"
  local conv_id=""
  local slot_run="/workspace/${SANDBOX_DIR#"$REPO_ROOT"/}/slot-run.sh"

  if [ -n "$continue_flag" ] && [ -f "$conv_file" ]; then
    conv_id="$(cat "$conv_file" 2>/dev/null || true)"
  fi

  docker exec "$SANDBOX_NAME" pkill -f "$(slot_kill_pattern "$SANDBOX_SLOT")" >/dev/null 2>&1 || true

  docker exec -u agent -w /workspace \
    -e "MSG_FILE=$run_dir_ctr/msg" \
    -e "LOG_FILE=$run_dir_ctr/last.jsonl" \
    -e "ERR_FILE=$run_dir_ctr/last.err" \
    -e "CONV_ID=$conv_id" \
    -e "SLOT_RUN=$slot_run" \
    -e "SANDBOX_SLOT=${SANDBOX_SLOT:-0}" \
    -e "SANDBOX_ROLE=${SANDBOX_ROLE:-agent}" \
    -e "GEMINI_API_KEY=${GEMINI_API_KEY:-}" \
    -e "SANDBOX_INNER_MODEL=${SANDBOX_INNER_MODEL:-}" \
    -e "SANDBOX_MODEL_DAILY=${SANDBOX_MODEL_DAILY:-}" \
    "$SANDBOX_NAME" bash -lc '
      msg="$(cat "$MSG_FILE")"
      set -- -p --dangerously-skip-permissions --output-format stream-json \
             --print-timeout 1200
      [ -n "$CONV_ID" ] && set -- "$@" --conversation "$CONV_ID"
      [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
      bash "$SLOT_RUN" "$SANDBOX_SLOT" agy "$@" "$msg" >"$LOG_FILE" 2>"$ERR_FILE"
    ' </dev/null || true

  local new_conv
  new_conv="$(jq -r 'select(.conversation_id != null) | .conversation_id' \
    "$run_dir_host/last.jsonl" 2>/dev/null | tail -1 || true)"
  [ -n "$new_conv" ] && printf '%s' "$new_conv" >"$conv_file"
  ln -sfn "agy-conversation-slot-${SANDBOX_SLOT:-0}" "$CACHE_DIR/agy-conversation" 2>/dev/null || true

  agy_result_from_stream "$run_dir_host/last.jsonl" "$run_dir_host/last.err"
}
