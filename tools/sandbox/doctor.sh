#!/usr/bin/env bash
# Check the host before anything expensive happens.
#
# Every failure here has one specific fix, so the check prints the fix rather
# than the symptom. Nothing in this file changes state.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=colima.sh
. "$SCRIPT_DIR/colima.sh"

fails=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

echo "host"
for tool in git jq docker; do
  command -v "$tool" >/dev/null 2>&1 && ok "$tool" || bad "$tool missing — brew install $tool"
done
command -v colima >/dev/null 2>&1 && ok "colima" \
  || warn "colima missing — brew install colima (or use another Docker daemon)"

echo "docker daemon"
sandbox_docker_host
if docker info >/dev/null 2>&1; then
  ok "reachable at ${DOCKER_HOST:-default socket}"
  colima_inotify_daemon_running \
    && warn "colima --inotify daemon is running; boot.sh will stop it (it storms the guest)" \
    || ok "no colima inotify daemon"
else
  bad "not reachable — colima start $(colima_start_flags)"
fi

echo "credentials"
if security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  ok "Claude Code (macOS Keychain)"
else
  warn "no Claude credential — run 'claude' on the Mac and sign in"
fi
[ -f "$HOME/.codex/auth.json" ] && ok "Codex (~/.codex/auth.json)" \
  || warn "no Codex credential — run 'codex login' on the Mac"
if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] || gh auth token >/dev/null 2>&1; then
  ok "GitHub token available (git push will work inside the sandbox)"
else
  warn "no GitHub token — run 'gh auth login' if the inner agent needs to push"
fi

echo "repo"
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 && ok "git repo at $REPO_ROOT" \
  || bad "not a git repo — run 'git init' first"
grep -qs 'tools/sandbox/.cache' "$REPO_ROOT/.gitignore" \
  && ok ".cache is gitignored" \
  || bad ".cache is NOT gitignored — it holds credentials. Add tools/sandbox/.cache/ to .gitignore"

echo "gates"
if [ -f "$REPO_ROOT/.claude/settings.json" ] &&
   grep -q 'outer-gate.sh' "$REPO_ROOT/.claude/settings.json" 2>/dev/null; then
  ok "PreToolUse hooks wired in .claude/settings.json"
else
  warn "hooks not wired — the outer agent can still act on the host"
fi

echo
[ "$fails" -eq 0 ] && { echo "Ready. Run: ./sandbox \"hello\""; exit 0; }
echo "$fails blocking problem(s) above."
exit 1
