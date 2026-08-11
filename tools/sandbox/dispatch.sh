#!/usr/bin/env bash
# Send one message to the inner agent and print its answer.
#
# This is the only door between the outer agent and the sandbox. Everything the
# outer agent is forbidden to do on the host — install, build, test, commit,
# push, edit source — it asks for here.
#
#   bash tools/sandbox/dispatch.sh "run the test suite"
#   bash tools/sandbox/dispatch.sh --continue "now fix the failure"
#   bash tools/sandbox/dispatch.sh --agent cursor "run the test suite"
#   bash tools/sandbox/dispatch.sh --model gpt-5 "run the test suite"
#   bash tools/sandbox/dispatch.sh --result        # re-read the last answer
#   echo "$LONG_PROMPT" | bash tools/sandbox/dispatch.sh
#
# The message travels through a file, never through a shell argument, so quotes,
# newlines, backticks and $() in a prompt stay literal text.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=agent.sh
. "$SCRIPT_DIR/agent.sh"
# shellcheck source=model.sh
. "$SCRIPT_DIR/model.sh"
# shellcheck source=dispatch-claude.sh
. "$SCRIPT_DIR/dispatch-claude.sh"
# shellcheck source=dispatch-codex.sh
. "$SCRIPT_DIR/dispatch-codex.sh"
# shellcheck source=dispatch-cursor.sh
. "$SCRIPT_DIR/dispatch-cursor.sh"

RUN_DIR="$CACHE_DIR/run"
RUN_DIR_CTR="/workspace/${SANDBOX_DIR#"$REPO_ROOT"/}/.cache/run"

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-0}"
}

continue_flag=""
want_result=0
message=""

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--continue) continue_flag="--continue"; shift ;;
    -a|--agent) SANDBOX_AGENT="${2:-}"; shift 2 ;;
    -m|--model) SANDBOX_MODEL="${2:-}"; shift 2 ;;
    --result) want_result=1; shift ;;
    -h|--help) usage 0 ;;
    --) shift; message="$*"; break ;;
    -*) echo "Unknown option: $1" >&2; usage 2 ;;
    *) message="$*"; break ;;
  esac
done

agent="$(resolve_sandbox_agent noprompt)" || exit 2

# Recovery path. A dispatch that outlived its client still finished inside the
# container and still wrote its answer to disk; this reads that back without
# spending another run.
if [ "$want_result" = 1 ]; then
  case "$agent" in
    claude)
      [ -f "$RUN_DIR/last.json" ] || { echo "No previous Claude result." >&2; exit 1; }
      jq -r '.result // empty' "$RUN_DIR/last.json" 2>/dev/null || cat "$RUN_DIR/last.json"
      exit 0 ;;
    codex)
      [ -f "$RUN_DIR/last.txt" ] || { echo "No previous Codex result." >&2; exit 1; }
      cat "$RUN_DIR/last.txt"
      exit 0 ;;
    cursor)
      [ -f "$RUN_DIR/last.jsonl" ] || { echo "No previous Cursor result." >&2; exit 1; }
      cursor_result_from_log "$RUN_DIR/last.jsonl"
      printf '\n'
      exit 0 ;;
  esac
fi

# Reading stdin only when it isn't a terminal keeps an argument-less invocation
# from silently hanging on a keyboard nobody is at.
if [ -z "$message" ] && [ ! -t 0 ]; then
  message="$(cat)"
fi
if [ -z "${message//[[:space:]]/}" ]; then
  echo "Nothing to dispatch: give a message as an argument or on stdin." >&2
  usage 2
fi

require_agent_credential "$agent" || exit 1

# Same product, same model. Empty means nothing could be read, and no --model
# flag is passed — the inner CLI uses its own default rather than one we made up.
SANDBOX_INNER_MODEL="$(resolve_sandbox_model "$agent")"
export SANDBOX_INNER_MODEL

container="$(bash "$SCRIPT_DIR/boot.sh")" || {
  echo "Sandbox failed to start. See the errors above." >&2
  exit 1
}
SANDBOX_NAME="$container"

mkdir -p "$RUN_DIR"
printf '%s' "$message" >"$RUN_DIR/msg"
rm -f "$RUN_DIR/last.json" "$RUN_DIR/last.txt" "$RUN_DIR/last.jsonl"

echo "→ $agent (inner)${SANDBOX_INNER_MODEL:+ · $SANDBOX_INNER_MODEL} ..." >&2

case "$agent" in
  claude) dispatch_claude "$continue_flag" "$RUN_DIR" "$RUN_DIR_CTR" ;;
  codex)  dispatch_codex  "$continue_flag" "$RUN_DIR" "$RUN_DIR_CTR" ;;
  cursor) dispatch_cursor "$continue_flag" "$RUN_DIR" "$RUN_DIR_CTR" ;;
esac
