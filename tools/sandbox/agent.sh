#!/usr/bin/env bash
# Decide which agent runs inside the sandbox. Source, don't run.
#
# The rule is: the inner agent is the SAME PRODUCT as the outer one. A Claude
# Code outer gets a Claude inner, Codex gets Codex, Cursor gets Cursor. Not
# because the products are interchangeable, but because they are not — the two
# halves share a repo and a task, and a Codex outer handing work to a Claude
# inner means the agent that wrote the dispatch and the agent that reads it
# disagree about their own conventions.
#
# Same product, NOT the same model. What runs inside is a manager that spawns
# cheaper workers, and model.sh picks its model on those terms rather than
# copying whatever the outer client happens to be running.
#
# Nobody is asked. The outer client leaves its fingerprints in the environment
# of every command it runs, and that is what gets read.

resolve_sandbox_agent() {
  local allow_prompt="${1:-noprompt}"

  if [ -n "${SANDBOX_AGENT:-}" ]; then
    case "$SANDBOX_AGENT" in
      codex|claude|cursor) printf '%s\n' "$SANDBOX_AGENT"; return 0 ;;
      *) echo "SANDBOX_AGENT must be 'codex', 'claude' or 'cursor', got '$SANDBOX_AGENT'." >&2; return 2 ;;
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
  # Cursor is checked LAST of the three, because Claude Code and Codex are both
  # things people run *inside* a Cursor terminal. When both sets of markers are
  # present the more specific one — the CLI actually executing this command — is
  # the right answer, and it got its turn above.
  #
  # CURSOR_AGENT=1 is the reliable one: the Cursor CLI sets it in the
  # environment of every shell command its agent runs. CURSOR_TRACE_ID comes
  # from the Cursor IDE's integrated terminal and is the fallback for the
  # in-editor agent. TERM_PROGRAM is no help here — Cursor is a VS Code fork and
  # reports itself as `vscode`, which is also what real VS Code reports.
  if [ -n "${CURSOR_AGENT:-}" ] || [ -n "${CURSOR_TRACE_ID:-}" ]; then
    printf 'cursor\n'
    return 0
  fi

  # A human at a terminal can just be asked. A script cannot, and blocking on a
  # prompt that nobody will ever answer is worse than picking the default.
  if [ "$allow_prompt" = "prompt" ] && [ -t 0 ] && [ -t 1 ]; then
    local reply
    printf 'Which agent should run inside the sandbox? [claude/codex/cursor] ' >&2
    read -r reply
    case "$reply" in
      codex) printf 'codex\n'; return 0 ;;
      claude|cl) printf 'claude\n'; return 0 ;;
      cursor|cu) printf 'cursor\n'; return 0 ;;
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
    cursor)
      bash "$SANDBOX_DIR/cursor-token-sync.sh" pull >&2 || {
        echo "Sign in on the Mac first: run 'agent login', or export CURSOR_API_KEY." >&2
        return 1
      } ;;
  esac
}
