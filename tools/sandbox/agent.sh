#!/usr/bin/env bash
# Decide which agent runs inside the sandbox. Source, don't run.
#
# The outer agent is whatever the human is typing into. The inner agent does not
# have to match, but defaulting to "the same one" is what people expect, so we
# read the environment the outer client leaves behind rather than asking.

resolve_sandbox_agent() {
  local allow_prompt="${1:-noprompt}"

  if [ -n "${SANDBOX_AGENT:-}" ]; then
    case "$SANDBOX_AGENT" in
      codex|claude) printf '%s\n' "$SANDBOX_AGENT"; return 0 ;;
      *) echo "SANDBOX_AGENT must be 'codex' or 'claude', got '$SANDBOX_AGENT'." >&2; return 2 ;;
    esac
  fi

  # Codex is checked FIRST on purpose. Some Codex installs inherit unrelated
  # CLAUDE_* tuning variables from a shell profile, so looking for those first
  # would misidentify a Codex session as a Claude one.
  if compgen -A variable CODEX_ >/dev/null 2>&1 || [ "${TERM_PROGRAM:-}" = "codex" ]; then
    printf 'codex\n'
    return 0
  fi
  if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ -n "${CLAUDE_AGENT_SDK_VERSION:-}" ]; then
    printf 'claude\n'
    return 0
  fi

  # A human at a terminal can just be asked. A script cannot, and blocking on a
  # prompt that nobody will ever answer is worse than picking the default.
  if [ "$allow_prompt" = "prompt" ] && [ -t 0 ] && [ -t 1 ]; then
    local reply
    printf 'Which agent should run inside the sandbox? [claude/codex] ' >&2
    read -r reply
    case "$reply" in
      codex|c) printf 'codex\n'; return 0 ;;
      claude|cl) printf 'claude\n'; return 0 ;;
    esac
  fi

  printf '%s\n' "${SANDBOX_DEFAULT_AGENT:-claude}"
}

# Ensure the credential for the chosen agent is actually present, with an error
# that says what to do instead of failing later inside the container.
require_agent_credential() {
  case "$1" in
    claude)
      bash "$SANDBOX_DIR/token-sync.sh" pull >&2 || {
        echo "Sign in on the Mac first: run 'claude' and complete login." >&2
        return 1
      } ;;
    codex)
      bash "$SANDBOX_DIR/codex-token-sync.sh" pull >&2 || {
        echo "Sign in on the Mac first: run 'codex login'." >&2
        return 1
      } ;;
  esac
}
