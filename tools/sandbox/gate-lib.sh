#!/usr/bin/env bash
# Shared plumbing for the PreToolUse gates. Source, don't run.
#
# Both gates emit the same decision envelope and share the same bypass rules.
# One copy means a fix to the decision shape cannot land in one gate and quietly
# miss the other — which is exactly how a hole stays open in practice: the Bash
# path gets hardened, the Edit path is forgotten, and the agent walks through it.

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$GATE_DIR/../.." && pwd -P)"

DISPATCH_MSG='Do not run this on the host. Dispatch the work to the inner agent: bash tools/sandbox/dispatch.sh "<message>" (or --continue for follow-ups). See .claude/skills/sandbox/SKILL.md.'

# Claude Code reads this exact JSON shape from a PreToolUse hook. Exit 0 always:
# a nonzero exit is a hook *error*, which is not the same thing as a deny and is
# handled differently by the client.
decide() {
  local decision="$1" reason="$2"
  jq -nc --arg d "$decision" --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

allow() { decide allow "$1"; }
deny()  { decide deny  "$1"; }

# The gates exist to keep the OUTER agent out of the host. Inside the container
# there is nothing left to protect, and leaving them armed would block the inner
# agent from doing the work it was dispatched to do.
#
# GATE_FORCE exists for the test harness: it makes a host shell evaluate the
# rules as if it were outer, even when run from inside.
gate_bypass_if_inner() {
  if [ -n "${SANDBOX_GATE_FORCE:-}" ]; then
    return 0
  fi
  if [ -n "${SANDBOX_INNER:-}" ]; then
    allow "inside sandbox"
  fi
  if [ -f /.dockerenv ] || [ -d /workspace ]; then
    allow "inside sandbox"
  fi
}

# Fail open, deliberately. A gate that crashes on an unexpected payload and
# denies everything makes the agent unusable and gets disabled by the human
# within the hour — at which point the protection is zero instead of partial.
gate_read_payload() {
  local payload
  payload="$(cat)"
  if [ -z "$payload" ]; then
    allow "no hook payload"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    allow "jq unavailable; gate cannot evaluate"
  fi
  printf '%s' "$payload"
}
