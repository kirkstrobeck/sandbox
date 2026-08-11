#!/usr/bin/env bash
# Claude Code backend for dispatch.sh. Source, don't run.
#
# `--dangerously-skip-permissions` is the entire point of the container: inside
# a throwaway box with one repo bind-mounted, there is no human to ask and
# nothing outside to damage, so asking is pure friction. Running that flag on
# the Mac would be a different thing entirely, which is what the gates prevent.

dispatch_claude() {
  local continue_flag="$1" run_dir_host="$2" run_dir_ctr="$3"

  # Only one inner run at a time. A previous run orphaned by a disconnected
  # client is still holding the repo, and two agents editing the same worktree
  # produce corruption that is very hard to attribute later.
  docker exec "$SANDBOX_NAME" pkill -f 'claude -p' >/dev/null 2>&1 || true

  # The result is written INSIDE the container, to a path on the bind mount. If
  # the client dies mid-run the work still finishes and the answer is still
  # there — `dispatch.sh --result` reads it back.
  docker exec -u agent -w /workspace \
    -e "MSG_FILE=$run_dir_ctr/msg" \
    -e "OUT_FILE=$run_dir_ctr/last.json" \
    -e "CONT_FLAG=$continue_flag" \
    -e "SANDBOX_INNER_MODEL=${SANDBOX_INNER_MODEL:-}" \
    "$SANDBOX_NAME" bash -lc '
      msg="$(cat "$MSG_FILE")"
      set -- -p $CONT_FLAG --dangerously-skip-permissions --output-format json
      [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
      claude "$@" "$msg" >"$OUT_FILE" 2>&1
    ' </dev/null || true

  # Push before reading: the run may have refreshed the OAuth token, and the
  # rotated refresh token has to get back to the Mac or the human is logged out.
  bash "$SCRIPT_DIR/token-sync.sh" push >&2 || true

  local raw
  raw="$(cat "$run_dir_host/last.json" 2>/dev/null || true)"
  if [ -z "$raw" ]; then
    echo "Inner Claude produced no output. Check: docker logs $SANDBOX_NAME" >&2
    return 1
  fi

  local result is_error
  result="$(printf '%s' "$raw" | jq -r '.result // ""' 2>/dev/null || true)"
  is_error="$(printf '%s' "$raw" | jq -r '.is_error // false' 2>/dev/null || printf 'false')"

  # Not valid JSON means claude failed before it could produce a result envelope
  # — usually a login or rate-limit message. Surface it verbatim; summarizing it
  # is how a fixable "run /login" turns into a mysterious failure.
  if [ -z "$result" ]; then
    printf '%s\n' "$raw"
    return 1
  fi

  printf '%s\n' "$result"
  [ "$is_error" = "true" ] && return 1
  return 0
}
