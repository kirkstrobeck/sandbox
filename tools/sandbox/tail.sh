#!/usr/bin/env bash
# Show what the inner agent is doing right now.
#
#   bash tools/sandbox/tail.sh          # last 40 steps of the current run
#   bash tools/sandbox/tail.sh -f       # follow until the run ends
#
# A dispatch prints one answer at the end and nothing in between, which for a
# ten-minute task looks identical to a hang. This renders the inner transcript
# as a progress readout so the human can see it working.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

RUN_DIR="$CACHE_DIR/run"
follow=0
[ "${1:-}" = "-f" ] || [ "${1:-}" = "--follow" ] && follow=1

# Codex streams JSONL as it goes; Claude's `-p --output-format json` writes one
# object at the end. So for Claude the honest live signal is the process itself.
render_codex() {
  jq -r '
    if .type == "item.completed" then
      (.item.type) as $t
      | if $t == "agent_message" then "· " + (.item.text // "" | .[0:400])
        elif $t == "command_execution" then "$ " + (.item.command // "")
        elif $t == "file_change" then "~ " + ((.item.changes // []) | map(.path) | join(", "))
        elif $t == "reasoning" then "  " + (.item.text // "" | .[0:200])
        else "· " + $t end
    else empty end' 2>/dev/null
}

if [ -f "$RUN_DIR/last.jsonl" ]; then
  if [ "$follow" = 1 ]; then
    tail -f -n 40 "$RUN_DIR/last.jsonl" | render_codex
    exit 0
  fi
  tail -n 40 "$RUN_DIR/last.jsonl" | render_codex
  exit 0
fi

sandbox_docker_host
if docker exec "$SANDBOX_NAME" pgrep -f 'claude -p' >/dev/null 2>&1; then
  echo "Inner Claude is running. Its transcript arrives all at once when it finishes."
  echo "Recover it any time with: bash tools/sandbox/dispatch.sh --result"
  exit 0
fi

if [ -f "$RUN_DIR/last.json" ]; then
  jq -r '"finished in \((.duration_ms // 0) / 1000 | floor)s, \(.num_turns // 0) turns"' \
    "$RUN_DIR/last.json" 2>/dev/null || true
  exit 0
fi

echo "No inner run has happened yet."
