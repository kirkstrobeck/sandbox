#!/usr/bin/env bash
# Install the sandbox into the repo you are standing in.
#
#   curl -fsSL https://raw.githubusercontent.com/kirkstrobeck/sandbox/main/install.sh | bash
#
# Re-running is safe. Files you have edited — sandbox.conf, AGENTS.md, CLAUDE.md
# — are left alone; the harness under tools/sandbox is replaced, because that is
# the part that gets upgraded.

set -euo pipefail

REPO="${SANDBOX_REPO:-kirkstrobeck/sandbox}"
REF="${SANDBOX_REF:-main}"
TARGET="${SANDBOX_TARGET:-$PWD}"

say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
kept() { printf '  kept     %s\n' "$1" >&2; }
put()  { printf '  wrote    %s\n' "$1" >&2; }

for tool in git jq curl tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required. brew install $tool"
done

git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 ||
  die "$TARGET is not a git repo. Run 'git init' first — the sandbox mounts a repo."

# Source: a local checkout if this script sits next to the harness, otherwise a
# tarball. The local case is what you get when you clone the starter and want to
# push a change out to another project without a round trip through GitHub.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
if [ -n "$SELF_DIR" ] && [ -d "$SELF_DIR/tools/sandbox" ]; then
  SRC="$SELF_DIR"
  CLEANUP=""
else
  SRC="$(mktemp -d)"
  CLEANUP="$SRC"
  say "Fetching $REPO@$REF ..."
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" |
    tar -xz -C "$SRC" --strip-components=1 ||
    die "could not download $REPO@$REF"
fi
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT

[ "$SRC" = "$TARGET" ] && die "source and target are the same directory"

say "Installing the sandbox into $TARGET"

# --- the harness: always replaced ------------------------------------------
# sandbox.conf is the one file in here a project owns, so it is preserved and
# the new default is left beside it for comparison.
conf_backup=""
if [ -f "$TARGET/tools/sandbox/sandbox.conf" ]; then
  conf_backup="$(mktemp)"
  cp "$TARGET/tools/sandbox/sandbox.conf" "$conf_backup"
fi

mkdir -p "$TARGET/tools"
rm -rf "$TARGET/tools/sandbox"
cp -R "$SRC/tools/sandbox" "$TARGET/tools/sandbox"
rm -rf "$TARGET/tools/sandbox/.cache"
chmod +x "$TARGET"/tools/sandbox/*.sh
put "tools/sandbox/"

if [ -n "$conf_backup" ]; then
  cp "$TARGET/tools/sandbox/sandbox.conf" "$TARGET/tools/sandbox/sandbox.conf.new"
  cp "$conf_backup" "$TARGET/tools/sandbox/sandbox.conf"
  rm -f "$conf_backup"
  kept "tools/sandbox/sandbox.conf (new defaults in sandbox.conf.new)"
fi

cp "$SRC/sandbox" "$TARGET/sandbox"
chmod +x "$TARGET/sandbox"
put "sandbox"

# --- agent instructions: yours once they exist ------------------------------
copy_once() {
  local rel="$1"
  if [ -e "$TARGET/$rel" ]; then
    kept "$rel"
    return 0
  fi
  mkdir -p "$(dirname "$TARGET/$rel")"
  cp "$SRC/$rel" "$TARGET/$rel"
  put "$rel"
}

copy_once AGENTS.md
copy_once CLAUDE.md
copy_once .cursor/rules/sandbox.mdc

# The skill is reference documentation for the harness, not project prose, so it
# tracks the harness version rather than being preserved.
mkdir -p "$TARGET/.claude/skills/sandbox"
cp "$SRC/.claude/skills/sandbox/SKILL.md" "$TARGET/.claude/skills/sandbox/SKILL.md"
put ".claude/skills/sandbox/SKILL.md"

# --- hooks: merged, never clobbered -----------------------------------------
# Any PreToolUse entry pointing at our gates is dropped and re-added, so a
# reinstall upgrades cleanly. Every other hook the project has is untouched.
settings="$TARGET/.claude/settings.json"
mkdir -p "$TARGET/.claude"
[ -f "$settings" ] || printf '{}\n' >"$settings"
jq --slurpfile new "$SRC/tools/sandbox/hooks.json" '
  .hooks = (.hooks // {}) |
  .hooks.PreToolUse = (
    ((.hooks.PreToolUse // []) | map(select(
       ((.hooks // []) | map(.command // "") | join(" "))
       | test("outer-(write-)?gate\\.sh") | not)))
    + $new[0].hooks.PreToolUse)
' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
put ".claude/settings.json (PreToolUse gates wired)"

# --- gitignore: the cache holds live credentials ----------------------------
ignore="$TARGET/.gitignore"
touch "$ignore"
add_ignore() {
  grep -qxF "$1" "$ignore" && return 0
  printf '%s\n' "$1" >>"$ignore"
  put ".gitignore += $1"
}
grep -q 'sandbox credentials' "$ignore" 2>/dev/null ||
  printf '\n# sandbox credentials and run state — never commit\n' >>"$ignore"
add_ignore 'tools/sandbox/.cache/'
add_ignore 'tools/sandbox/sandbox.local.conf'
add_ignore '.claude/settings.local.json'

say ""
say "Done. Next:"
say "  1. edit tools/sandbox/sandbox.conf   (ports, watch dirs, volumes)"
say "  2. ./sandbox doctor                  (checks the host, names every fix)"
say "  3. ./sandbox \"say hello and list the files you can see\""
say ""
say "Restart your agent client so it picks up the new PreToolUse hooks."
