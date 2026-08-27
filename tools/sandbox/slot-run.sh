#!/usr/bin/env bash
# Run a command with argv0 sandbox-slot-<id> so slot-scoped pkill works.
#
#   bash tools/sandbox/slot-run.sh 2 claude -p "task"

set -uo pipefail

if [ $# -lt 2 ]; then
  echo "usage: slot-run.sh <slot-id> <command...>" >&2
  exit 2
fi

id="$1"
shift
exec -a "sandbox-slot-${id}" "$@"
