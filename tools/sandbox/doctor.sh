#!/usr/bin/env bash
# Check the host before anything expensive happens.
#
# Every failure here has one specific fix, so the check prints the fix rather
# than the symptom. Nothing in this file changes the project — the only write is
# the update-check stamp under .cache/, which is run state.
#
# FAIL is reserved for things that actually stop a run: no Docker, no jq, or
# credentials that could leak into a commit. Everything the sandbox can start
# without — git on the host, a git repo at all, colima, an agent login — is a
# warn, because an empty project directory is a supported place to work.

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
for tool in jq docker; do
  command -v "$tool" >/dev/null 2>&1 && ok "$tool" || bad "$tool missing — brew install $tool"
done
# git on the host is only used to copy your commit identity into the container
# and to bridge a gh token. Without it the sandbox still runs.
command -v git >/dev/null 2>&1 && ok "git" \
  || warn "git missing — brew install git (only needed to push from inside the sandbox)"
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

echo "project"
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  ok "git repo at $REPO_ROOT"
else
  warn "not a git repo at $REPO_ROOT — fine; the sandbox mounts the directory either way"
fi
# Stays a FAIL even with no git repo. The line costs nothing now, and the day
# someone runs 'git init' here it is the difference between a gitignored token
# and a committed one.
grep -qs 'tools/sandbox/.cache' "$REPO_ROOT/.gitignore" \
  && ok ".cache is gitignored" \
  || bad ".cache is NOT gitignored — it holds credentials. Add tools/sandbox/.cache/ to $REPO_ROOT/.gitignore"

echo "harness"
# Where tools/sandbox came from, and whether it has moved since. Doctor is the
# one place a synchronous network call is appropriate — you asked for a report —
# so this checks now rather than reading the cached answer boot.sh uses. Never a
# FAIL: an old harness runs fine, and so does one that cannot reach github.com.
if [ -f "$SCRIPT_DIR/ORIGIN.md" ]; then
  ok "installed from $(sed -n 's/^[[:space:]]*SANDBOX_ORIGIN_URL=//p' "$SCRIPT_DIR/ORIGIN.md" | head -1)"
  update_status="$(bash "$SCRIPT_DIR/update.sh" --check 2>&1)"
  case "$update_status" in
    "up to date"*) ok "$update_status" ;;
    *)             warn "$update_status" ;;
  esac
elif [ -f "$REPO_ROOT/install.sh" ]; then
  # install.sh at the root: this is the sandbox repo itself, where tools/sandbox
  # is the working copy rather than something installed. Nothing to check.
  ok "this is the sandbox source repo — tools/sandbox is the working copy"
else
  warn "no tools/sandbox/ORIGIN.md — installed before it existed. './sandbox update' writes one"
fi

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
