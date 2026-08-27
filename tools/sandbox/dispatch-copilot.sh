#!/usr/bin/env bash
# GitHub Copilot backend for dispatch.sh. Source, don't run.

copilot_result_from_file() {
  local txt_file="$1" err_file="${2:-}"
  if [ ! -s "$txt_file" ]; then
    [ -s "$err_file" ] && cat "$err_file" >&2
    echo "Inner Copilot produced no output. Check: docker logs $SANDBOX_NAME" >&2
    return 1
  fi
  cat "$txt_file"
}

dispatch_copilot() {
  local continue_flag="$1" run_dir_host="$2" run_dir_ctr="$3"
  local slot_run="/workspace/${SANDBOX_DIR#"$REPO_ROOT"/}/slot-run.sh"

  if [ -n "$continue_flag" ]; then
    echo "WARN: Copilot has no --continue mechanism; starting a fresh session." >&2
  fi

  docker exec "$SANDBOX_NAME" pkill -f "$(slot_kill_pattern "$SANDBOX_SLOT")" >/dev/null 2>&1 || true

  docker exec -u agent -w /workspace \
    -e "MSG_FILE=$run_dir_ctr/msg" \
    -e "OUT_FILE=$run_dir_ctr/last.txt" \
    -e "ERR_FILE=$run_dir_ctr/last.err" \
    -e "SLOT_RUN=$slot_run" \
    -e "SANDBOX_SLOT=${SANDBOX_SLOT:-0}" \
    -e "SANDBOX_ROLE=${SANDBOX_ROLE:-agent}" \
    -e "SANDBOX_INNER_MODEL=${SANDBOX_INNER_MODEL:-}" \
    -e "SANDBOX_MODEL_DAILY=${SANDBOX_MODEL_DAILY:-}" \
    "$SANDBOX_NAME" bash -lc '
      msg="$(cat "$MSG_FILE")"
      export COPILOT_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
      set -- -p --autopilot --no-ask-user --allow-all
      [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
      bash "$SLOT_RUN" "$SANDBOX_SLOT" copilot "$@" "$msg" >"$OUT_FILE" 2>"$ERR_FILE"
    ' </dev/null || true

  copilot_result_from_file "$run_dir_host/last.txt" "$run_dir_host/last.err"
}
