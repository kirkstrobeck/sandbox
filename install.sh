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
#
# WHAT GETS WRITTEN is not decided in this file. tools/sandbox/MANIFEST lists
# every path an install owns and what mode it is in, and this script applies it.
# The manifest already in the project is read first, so a path that used to be
# `replace` and is gone from the incoming manifest gets deleted rather than
# lingering in every project that ever installed it.
#
# Flags:
#   --dry-run   Print every path that would be written, kept, or removed.
#               Change nothing. Exit 0.
#   --force     When upgrading from a pre-manifest install, delete foreign files
#               in tools/sandbox/ even if they are not in the incoming harness.
#               (Without --force the install refuses and lists them.)

set -euo pipefail

REPO="${SANDBOX_REPO:-kirkstrobeck/sandbox}"
REF="${SANDBOX_REF:-main}"

# say/die must be defined before arg parsing so they can be used in it.
say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
kept() { printf '  kept     %s\n' "$1" >&2; }
put()  { printf '  wrote    %s\n' "$1" >&2; }
gone() { printf '  removed  %s\n' "$1" >&2; }

DRY_RUN="${SANDBOX_INSTALL_DRY_RUN:-}"
FORCE="${SANDBOX_INSTALL_FORCE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}" >&2
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [ -n "$DRY_RUN" ]; then
  kept() { printf '  would keep   %s\n' "$1" >&2; }
  put()  { printf '  would write  %s\n' "$1" >&2; }
  gone() { printf '  would remove %s\n' "$1" >&2; }
fi

TARGET="${SANDBOX_TARGET:-$PWD}"

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

# --- the manifest -----------------------------------------------------------
NEW_MANIFEST="$SRC/tools/sandbox/MANIFEST"
[ -r "$NEW_MANIFEST" ] || die "the source tree has no tools/sandbox/MANIFEST"
# shellcheck source=tools/sandbox/manifest.sh
. "$SRC/tools/sandbox/manifest.sh"

# Fail before touching the project, not halfway through it. A manifest that
# promises a file the tarball does not carry would install a project into a
# state where the next update deletes files that were never written.
if ! missing="$(manifest_missing_sources "$SRC" "$NEW_MANIFEST")"; then
  die "MANIFEST lists paths that are not in $SRC:
$(printf '       %s\n' $missing)"
fi

# Read the project's current manifest before anything overwrites it: it is the
# only record of what the last install put here.
OLD_MANIFEST=""
if [ -f "$TARGET/tools/sandbox/MANIFEST" ]; then
  OLD_MANIFEST="$(mktemp)"
  cp "$TARGET/tools/sandbox/MANIFEST" "$OLD_MANIFEST"
fi

say "Installing the sandbox into $TARGET (manifest v$(manifest_version "$NEW_MANIFEST"))"

# --- installs that predate the manifest -------------------------------------
# Those projects have a tools/sandbox full of files nothing can enumerate, so
# there is no way to tell a file this harness still ships from one it dropped
# three versions ago. Sweep the directory once — everything except the three
# things that are the project's, not ours — and let the manifest own it after.
#
# tools/sandbox/ is harness-owned. Project scripts belong in tools/, not here.
# Before sweeping, check for foreign files: entries that are not in the incoming
# harness and are not the protected names. If found without --force, refuse.
if [ -n "$had_harness" ] && [ -z "$OLD_MANIFEST" ]; then
  foreign=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="$(basename "$entry")"
    case "$name" in .cache|sandbox.conf|sandbox.local.conf) continue ;; esac
    [ -e "$SRC/tools/sandbox/$name" ] && continue
    foreign="${foreign}  $entry"$'\n'
  done < <(find "$TARGET/tools/sandbox" -mindepth 1 -maxdepth 1 2>/dev/null | sort)

  if [ -n "$foreign" ] && [ -z "$FORCE" ]; then
    if [ -n "$DRY_RUN" ]; then
      say "  warning: foreign files in tools/sandbox/ would cause a refusal without --force:"
      printf '%s' "$foreign" >&2
    else
      die "tools/sandbox/ is harness-owned but contains paths not in the incoming harness:
${foreign}Move them to tools/ (outside tools/sandbox/) or pass --force to delete them."
    fi
  fi

  if [ -n "$DRY_RUN" ]; then
    say "  would sweep tools/sandbox/ (pre-manifest install; .cache and your conf kept)"
  else
    find "$TARGET/tools/sandbox" -mindepth 1 -maxdepth 1 \
      ! -name '.cache' ! -name 'sandbox.conf' ! -name 'sandbox.local.conf' \
      -exec rm -rf {} + 2>/dev/null || true
    say "  swept    tools/sandbox/ (pre-manifest install; .cache and your conf kept)"
  fi
fi

# --- apply the manifest -----------------------------------------------------
install_path() {
  local mode="$1" rel="$2"
  case "$mode" in
    replace)
      put "$rel"
      [ -n "$DRY_RUN" ] && return 0
      mkdir -p "$(dirname "$TARGET/$rel")"
      cp "$SRC/$rel" "$TARGET/$rel"
      case "$rel" in *.sh|sandbox) chmod +x "$TARGET/$rel" ;; esac
      ;;
    preserve)
      if [ -e "$TARGET/$rel" ]; then
        kept "$rel"
        return 0
      fi
      put "$rel"
      [ -n "$DRY_RUN" ] && return 0
      mkdir -p "$(dirname "$TARGET/$rel")"
      cp "$SRC/$rel" "$TARGET/$rel"
      ;;
    # manage: merged, generated, or the project's own. Handled elsewhere in this
    # script, or not at all. Listed in the manifest so the footprint is honest.
    manage) : ;;
  esac
}

# sandbox.conf is preserved like the rest, but it is also the file people are
# most likely to want to diff after an upgrade, so the incoming defaults land
# beside it.
if [ -f "$TARGET/tools/sandbox/sandbox.conf" ]; then
  if [ -n "$DRY_RUN" ]; then
    say "  would write  tools/sandbox/sandbox.conf.new (incoming defaults)"
  else
    mkdir -p "$TARGET/tools/sandbox"
    cp "$SRC/tools/sandbox/sandbox.conf" "$TARGET/tools/sandbox/sandbox.conf.new"
    say "  wrote    tools/sandbox/sandbox.conf.new (incoming defaults)"
  fi
fi

while read -r mode rel; do
  [ -n "$rel" ] || continue
  install_path "$mode" "$rel"
done <<EOF
$(manifest_entries "$NEW_MANIFEST")
EOF

# --- remove what this harness stopped shipping ------------------------------
# The rule, and the only rule: a path the last install owned outright and this
# one does not mention is deleted. A `preserve` or `manage` path that leaves the
# manifest is left exactly where it is — those are the project's files, and
# dropping a line from a list is not consent to delete somebody's config.
if [ -n "$OLD_MANIFEST" ]; then
  new_paths="$(manifest_paths "$NEW_MANIFEST")"
  for rel in $(manifest_paths "$OLD_MANIFEST" replace); do
    printf '%s\n' "$new_paths" | grep -qxF "$rel" && continue
    [ -e "$TARGET/$rel" ] || continue
    gone "$rel"
    [ -n "$DRY_RUN" ] && continue
    rm -rf "$TARGET/$rel"
  done
fi
[ -n "$OLD_MANIFEST" ] && rm -f "$OLD_MANIFEST"

# Neither of these is ever copied, swept or removed — they are `manage` paths.
# Saying so out loud is the point: an upgrade that silently keeps your
# credentials is indistinguishable from one that silently lost them.
[ -d "$TARGET/tools/sandbox/.cache" ] &&
  kept "tools/sandbox/.cache/ (credentials and run state)"
[ -f "$TARGET/tools/sandbox/sandbox.local.conf" ] &&
  kept "tools/sandbox/sandbox.local.conf"
mkdir -p "$TARGET/tools/sandbox/outer-gate-deny.d" \
         "$TARGET/tools/sandbox/outer-write-gate-deny.d" 2>/dev/null || true
for _deny_d_rel in tools/sandbox/outer-gate-deny.d tools/sandbox/outer-write-gate-deny.d; do
  if [ -n "$(find "$TARGET/$_deny_d_rel" -name '*.sh' 2>/dev/null)" ]; then
    kept "$_deny_d_rel/ (project deny hooks; contents survive updates)"
  fi
done
:

# --- where this came from ---------------------------------------------------
# Six months from now, tools/sandbox is a directory of shell scripts nobody in
# the project wrote and nobody remembers the origin of. This file is the answer,
# sitting where you would look for it, and it is also what `./sandbox update`
# reads to know which repo and ref to fetch. Rewritten on every install.

# update.sh already knows the sha it fetched — it asked while it had the network
# out — so take its word over asking again.
origin_commit="${SANDBOX_ORIGIN_COMMIT:-}"
if [ -n "$DRY_RUN" ]; then
  put "tools/sandbox/ORIGIN.md"
else
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

tools/sandbox/MANIFEST is the full list: every path an install owns, and whether
it is replaced, preserved, or only managed. It is also what an upgrade reads to
find files this harness used to ship and no longer does.

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
fi

# --- hooks: merged, never clobbered -----------------------------------------
# Any PreToolUse entry pointing at our gates is dropped and re-added, so a
# reinstall upgrades cleanly. Every other hook the project has is untouched.
if [ -n "$DRY_RUN" ]; then
  put ".claude/settings.json (PreToolUse gates wired)"
else
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
fi

# --- cursor hooks: merged, never clobbered ----------------------------------
# Same pattern as the Claude settings merge above: drop any hook entries that
# point at our scripts and re-add the current versions, leaving every other
# hook the project has untouched.
if [ -n "$DRY_RUN" ]; then
  put ".cursor/hooks.json (sandbox hooks wired)"
else
  cursor_hooks="$TARGET/.cursor/hooks.json"
  mkdir -p "$TARGET/.cursor"
  [ -f "$cursor_hooks" ] || printf '{"version":1,"failClosed":true,"hooks":{}}\n' >"$cursor_hooks"
  jq --slurpfile new "$SRC/.cursor/hooks.json" '
    .version = 1 |
    .failClosed = true |
    .hooks = (.hooks // {}) |
    .hooks.beforeShellExecution = (
      ((.hooks.beforeShellExecution // []) | map(select(
         (.command // "") | test("sandbox-shell\\.sh") | not)))
      + $new[0].hooks.beforeShellExecution) |
    .hooks.preToolUse = (
      ((.hooks.preToolUse // []) | map(select(
         (.command // "") | test("sandbox-write\\.sh") | not)))
      + $new[0].hooks.preToolUse) |
    .hooks.beforeReadFile = (
      ((.hooks.beforeReadFile // []) | map(select(
         (.command // "") | test("sandbox-read\\.sh") | not)))
      + $new[0].hooks.beforeReadFile)
  ' "$cursor_hooks" >"$cursor_hooks.tmp" && mv "$cursor_hooks.tmp" "$cursor_hooks"
  put ".cursor/hooks.json (sandbox hooks wired)"
fi

# --- gitignore: the cache holds live credentials ----------------------------
# Written whether or not this directory is a git repo. If it becomes one later,
# the ignore lines are already there and the tokens under .cache never get a
# chance to be committed.
ignore="$TARGET/.gitignore"
add_ignore() {
  local entry="$1"
  if [ -n "$DRY_RUN" ]; then
    grep -qxF "$entry" "$ignore" 2>/dev/null && kept ".gitignore (already has $entry)" ||
      put ".gitignore += $entry"
    return 0
  fi
  touch "$ignore"
  grep -qxF "$entry" "$ignore" && return 0
  printf '%s\n' "$entry" >>"$ignore"
  put ".gitignore += $entry"
}
if [ -n "$DRY_RUN" ]; then
  : # header line skipped in dry-run
else
  touch "$ignore"
  grep -q 'sandbox credentials' "$ignore" 2>/dev/null ||
    printf '\n# sandbox credentials and run state — never commit\n' >>"$ignore"
fi
add_ignore 'tools/sandbox/.cache/'
add_ignore 'tools/sandbox/sandbox.local.conf'
add_ignore '.claude/settings.local.json'
add_ignore 'tools/sandbox/.install-hashes'

say ""
if [ -n "$DRY_RUN" ]; then
  say "Dry run complete. Nothing was written."
elif [ -n "$had_harness" ]; then
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
