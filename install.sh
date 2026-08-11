#!/usr/bin/env bash
# Install the sandbox into the project directory you are standing in.
#
#   curl -fsSL https://raw.githubusercontent.com/kirkstrobeck/sandbox/main/install.sh | bash
#
# An empty folder is a fine target. There is no requirement that the directory
# be a git repo — if you run 'git init' later, the .gitignore written here is
# already in place to keep credentials out.
#
# Re-running is safe. Files you have edited — sandbox.conf, AGENTS.md, CLAUDE.md
# — are left alone; the harness under tools/sandbox is replaced, because that is
# the part that gets upgraded.
#
# This is also the upgrade path: `./sandbox update` in an installed project
# fetches the current tarball and runs this script against the project again.
# There is one set of rules about which files are preserved, and it lives here.

set -euo pipefail

REPO="${SANDBOX_REPO:-kirkstrobeck/sandbox}"
REF="${SANDBOX_REF:-main}"
TARGET="${SANDBOX_TARGET:-$PWD}"

say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
kept() { printf '  kept     %s\n' "$1" >&2; }
put()  { printf '  wrote    %s\n' "$1" >&2; }

# jq is the only unconditional requirement — it merges the PreToolUse hooks into
# .claude/settings.json. curl and tar are checked below, and only when this
# install actually has to fetch the tarball.
command -v jq >/dev/null 2>&1 || die "jq is required. brew install jq"

[ -d "$TARGET" ] || { mkdir -p "$TARGET" || die "could not create $TARGET"; }
TARGET="$(cd "$TARGET" && pwd -P)"

# Source: a local checkout if this script sits next to the harness, otherwise a
# tarball. The local case is what you get when you clone the starter and want to
# push a change out to another project without a round trip through GitHub.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
if [ -n "$SELF_DIR" ] && [ -d "$SELF_DIR/tools/sandbox" ]; then
  SRC="$SELF_DIR"
  CLEANUP=""
else
  for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 ||
      die "$tool is required to fetch $REPO@$REF. brew install $tool"
  done
  SRC="$(mktemp -d)"
  CLEANUP="$SRC"
  say "Fetching $REPO@$REF ..."
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" |
    tar -xz -C "$SRC" --strip-components=1 ||
    die "could not download $REPO@$REF"
fi
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT

[ "$SRC" = "$TARGET" ] && die "source and target are the same directory"

# An existing tools/sandbox means this is an upgrade rather than a first
# install, which changes nothing about what gets written and everything about
# what is worth saying at the end.
had_harness=""
[ -d "$TARGET/tools/sandbox" ] && had_harness=1

say "Installing the sandbox into $TARGET"

# --- the harness: always replaced ------------------------------------------
# sandbox.conf is the one file in here a project owns, so it is preserved and
# the new default is left beside it for comparison.
conf_backup=""
if [ -f "$TARGET/tools/sandbox/sandbox.conf" ]; then
  conf_backup="$(mktemp)"
  cp "$TARGET/tools/sandbox/sandbox.conf" "$conf_backup"
fi
# sandbox.local.conf is gitignored, so a tarball never carries one — but it is
# still under the directory about to be deleted, and losing a pinned port on
# every upgrade is not acceptable.
local_backup=""
if [ -f "$TARGET/tools/sandbox/sandbox.local.conf" ]; then
  local_backup="$(mktemp)"
  cp "$TARGET/tools/sandbox/sandbox.local.conf" "$local_backup"
fi

# The cache is inside the directory about to be deleted, and it is not
# disposable: it holds the bridged credentials and the inner agent's run state,
# so wiping it on an upgrade costs a re-login and every `-c` thread. Moved
# aside within the same filesystem rather than copied — these are live tokens
# and they should not be duplicated through /tmp.
cache_backup=""
if [ -d "$TARGET/tools/sandbox/.cache" ]; then
  cache_backup="$TARGET/tools/.sandbox-cache-$$"
  rm -rf "$cache_backup"
  mv "$TARGET/tools/sandbox/.cache" "$cache_backup"
fi

mkdir -p "$TARGET/tools"
rm -rf "$TARGET/tools/sandbox"
cp -R "$SRC/tools/sandbox" "$TARGET/tools/sandbox"
# Any .cache that came in with the source belongs to whoever ran the install,
# not to this project.
rm -rf "$TARGET/tools/sandbox/.cache"
if [ -n "$cache_backup" ]; then
  mv "$cache_backup" "$TARGET/tools/sandbox/.cache"
  kept "tools/sandbox/.cache/ (credentials and run state)"
fi
# Installing from a local checkout copies that checkout's working tree, which
# may include the installer's own machine-local overrides. Whoever is installing
# does not want their ports in someone else's project.
rm -f "$TARGET/tools/sandbox/sandbox.local.conf"
chmod +x "$TARGET"/tools/sandbox/*.sh
put "tools/sandbox/"

if [ -n "$conf_backup" ]; then
  cp "$TARGET/tools/sandbox/sandbox.conf" "$TARGET/tools/sandbox/sandbox.conf.new"
  cp "$conf_backup" "$TARGET/tools/sandbox/sandbox.conf"
  rm -f "$conf_backup"
  kept "tools/sandbox/sandbox.conf (new defaults in sandbox.conf.new)"
fi

if [ -n "$local_backup" ]; then
  cp "$local_backup" "$TARGET/tools/sandbox/sandbox.local.conf"
  rm -f "$local_backup"
  kept "tools/sandbox/sandbox.local.conf"
fi

cp "$SRC/sandbox" "$TARGET/sandbox"
chmod +x "$TARGET/sandbox"
put "sandbox"

# --- where this came from ---------------------------------------------------
# Six months from now, tools/sandbox is a directory of shell scripts nobody in
# the project wrote and nobody remembers the origin of. This file is the answer,
# sitting where you would look for it, and it is also what `./sandbox update`
# reads to know which repo and ref to fetch. Rewritten on every install.

# update.sh already knows the sha it fetched — it asked while it had the network
# out — so take its word over asking again.
origin_commit="${SANDBOX_ORIGIN_COMMIT:-}"
if [ -n "$origin_commit" ]; then
  :
elif [ -n "$CLEANUP" ]; then
  # A tarball carries no sha, so ask the API for the one behind this ref. Best
  # effort: it only feeds the "an update is available" check, and an install
  # must not fail because github.com was slow.
  origin_commit="$(curl -fsSL -m 10 "https://api.github.com/repos/$REPO/commits/$REF" 2>/dev/null |
    jq -r '.sha // empty' 2>/dev/null || true)"
elif command -v git >/dev/null 2>&1; then
  origin_commit="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
fi

cat >"$TARGET/tools/sandbox/ORIGIN.md" <<EOF
# Where this harness came from

    https://github.com/$REPO
    git@github.com:$REPO.git

Everything in tools/sandbox/ and the ./sandbox script at the repo root are
installed from that repo. They are not project code. Editing them here works
until the next upgrade replaces the directory, so a fix worth keeping belongs
upstream.

The exception is tools/sandbox/sandbox.conf — that file is the project's, and
every install and update preserves it, leaving the incoming defaults beside it
as sandbox.conf.new. AGENTS.md and CLAUDE.md are kept the same way.

To pull a newer harness into this project:

    ./sandbox update

## Installed from

    SANDBOX_ORIGIN_REPO=$REPO
    SANDBOX_ORIGIN_REF=$REF
    SANDBOX_ORIGIN_COMMIT=$origin_commit
    SANDBOX_ORIGIN_URL=https://github.com/$REPO
    SANDBOX_ORIGIN_GIT=git@github.com:$REPO.git
    SANDBOX_ORIGIN_INSTALLED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

tools/sandbox/update.sh reads those KEY=value lines back out to find upstream.
Keep them if you edit this file; delete the file and update falls back to
kirkstrobeck/sandbox@main.
EOF
put "tools/sandbox/ORIGIN.md"

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
# Written whether or not this directory is a git repo. If it becomes one later,
# the ignore lines are already there and the tokens under .cache never get a
# chance to be committed.
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
if [ -n "$had_harness" ]; then
  say "Done. Harness upgraded from $REPO@$REF; sandbox.conf kept."
  say "Restart your agent client if the PreToolUse hooks changed."
else
  say "Done. Next:"
  say "  1. edit tools/sandbox/sandbox.conf   (ports, watch dirs, volumes)"
  say "  2. ./sandbox doctor                  (checks the host, names every fix)"
  say "  3. ./sandbox \"say hello and list the files you can see\""
  say ""
  say "Restart your agent client so it picks up the new PreToolUse hooks."
fi
say ""
say "From https://github.com/$REPO — git@github.com:$REPO.git"
say "Upgrade later with: ./sandbox update   (details in tools/sandbox/ORIGIN.md)"
