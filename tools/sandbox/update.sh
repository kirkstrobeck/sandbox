#!/usr/bin/env bash
# Pull a newer harness into this project from the repo it was installed from.
#
#   bash tools/sandbox/update.sh           fetch upstream and reinstall over this project
#   bash tools/sandbox/update.sh --check   ask upstream whether there is anything newer
#   bash tools/sandbox/update.sh --nudge   one quiet line, only if the last check said yes
#
# Flags: --ref REF, --repo OWNER/NAME, --from PATH (a local checkout instead of
# a download), --force.
#
# The upgrade itself is install.sh, fetched with the rest of the tarball and run
# against this directory. Nothing about which files are preserved is decided
# here — sandbox.conf, AGENTS.md and CLAUDE.md survive because install.sh says
# so, and a second copy of that rule is how the two quietly stop agreeing.
#
# Everything is wrapped in functions and called from the last line, because this
# script is one of the files the upgrade replaces underneath itself.

set -uo pipefail
# Read before config.sh gets a chance to set its default over the top. This is
# the one setting where the environment must beat the config file: it is a
# kill switch, and `SANDBOX_UPDATE_CHECK=0 ./sandbox up` has to actually be
# quiet in a project whose sandbox.conf says 1.
UPDATE_CHECK_ENV="${SANDBOX_UPDATE_CHECK:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

ORIGIN_FILE="$SCRIPT_DIR/ORIGIN.md"
STAMP="$CACHE_DIR/update-check"
# Global, not a local in cmd_update: the EXIT trap runs after that function has
# returned, and a local would be out of scope by then.
CLEANUP_DIR=""
# One check a day. This is a courtesy line in someone's terminal, not a service.
STAMP_MAX_AGE="${SANDBOX_UPDATE_CHECK_MAX_AGE:-86400}"
DEFAULT_REPO="kirkstrobeck/sandbox"
DEFAULT_REF="main"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ORIGIN.md is markdown for a human first; the KEY=value lines in it are the
# machine-readable half. Missing file, missing key and empty value all mean the
# same thing to every caller: fall back to the default.
origin_value() {
  [ -r "$ORIGIN_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$ORIGIN_FILE" | head -1 | tr -d '\r'
}

# The one place that decides which repo/ref this project tracks: the flags, then
# the environment, then ORIGIN.md, then the upstream defaults.
resolve_origin() {
  REPO="${REPO_FLAG:-${SANDBOX_REPO:-$(origin_value SANDBOX_ORIGIN_REPO)}}"
  REF="${REF_FLAG:-${SANDBOX_REF:-$(origin_value SANDBOX_ORIGIN_REF)}}"
  [ -n "$REPO" ] || REPO="$DEFAULT_REPO"
  [ -n "$REF" ] || REF="$DEFAULT_REF"
  LOCAL_COMMIT="$(origin_value SANDBOX_ORIGIN_COMMIT)"
}

# The commit behind REF, from the API. Unauthenticated on purpose: a background
# check is not a place to be handling someone's token, and 60 requests an hour
# is generous for something that runs once a day.
#
# Every way this fails is a thing a person can act on — a typo'd ref reads
# nothing like a flaky network — so the reason is kept rather than flattened
# into an empty string. The answer comes back in a global rather than on stdout
# because a command substitution is a subshell, and the reason would not survive
# the trip back.
UPSTREAM_SHA=""
UPSTREAM_ERR=""
upstream_head() {
  UPSTREAM_SHA=""; UPSTREAM_ERR=""
  command -v curl >/dev/null 2>&1 || { UPSTREAM_ERR="curl is not on PATH"; return 1; }
  local body code
  body="$(mktemp)"
  code="$(curl -sL -m "${SANDBOX_UPDATE_TIMEOUT:-8}" -o "$body" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$REPO/commits/$REF" 2>/dev/null)"
  case "$code" in
    200) UPSTREAM_SHA="$(jq -r '.sha // empty' <"$body" 2>/dev/null)" ;;
    404) UPSTREAM_ERR="github.com has no $REPO@$REF" ;;
    409) UPSTREAM_ERR="$REPO exists on github.com but has no commits yet" ;;
    403|429) UPSTREAM_ERR="github.com rate-limited the check; it will retry tomorrow" ;;
    000|'') UPSTREAM_ERR="could not reach github.com" ;;
    *) UPSTREAM_ERR="github.com answered HTTP $code" ;;
  esac
  rm -f "$body"
  [ -z "$UPSTREAM_ERR" ]
}

stamp_write() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  printf '%s %s %s\n' "$(date +%s)" "$1" "${2:-}" >"$STAMP" 2>/dev/null || true
}

stamp_field() {
  [ -r "$STAMP" ] || return 0
  awk -v n="$1" 'NR==1{print $n}' "$STAMP"
}

stamp_age() {
  local when
  when="$(stamp_field 1)"
  case "$when" in ''|*[!0-9]*) echo 999999999; return 0 ;; esac
  echo $(( $(date +%s) - when ))
}

# current | outdated | unknown. "unknown" covers both halves of the comparison
# being unavailable — no network, or an install that predates ORIGIN.md — and
# every caller treats it as "say nothing".
STATUS="unknown"
check() {
  upstream_head
  if [ -z "$UPSTREAM_SHA" ] || [ -z "$LOCAL_COMMIT" ]; then
    STATUS="unknown"
  elif [ "$UPSTREAM_SHA" = "$LOCAL_COMMIT" ]; then
    STATUS="current"
  else
    STATUS="outdated"
  fi
  stamp_write "$STATUS" "$UPSTREAM_SHA"
}

short() { printf '%s' "${1:0:7}"; }

cmd_check() {
  check
  case "$STATUS" in
    current)  log "up to date with $REPO@$REF ($(short "$LOCAL_COMMIT"))" ;;
    outdated) log "an update is available for $REPO@$REF — run: ./sandbox update" ;;
    unknown)
      if [ -n "$UPSTREAM_ERR" ]; then
        log "cannot tell: $UPSTREAM_ERR"
      else
        log "cannot tell: no commit recorded in tools/sandbox/ORIGIN.md — ./sandbox update stamps one"
      fi
      ;;
  esac
  # Exit 1 means "there is an update", not "the check broke" — doctor reads the
  # text, but a script can read the status.
  [ "$STATUS" = outdated ] && return 1
  return 0
}

# Called from boot.sh on every `./sandbox up`, so it has two hard rules: never
# block, and never speak unless there is something to say.
cmd_nudge() {
  [ "${UPDATE_CHECK_ENV:-${SANDBOX_UPDATE_CHECK:-1}}" = "0" ] && return 0
  if [ "$(stamp_age)" -gt "$STAMP_MAX_AGE" ]; then
    # Refresh for next time, detached. Today's boot reports yesterday's answer,
    # which is the right trade for a line of terminal courtesy.
    ( check >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
  [ "$(stamp_field 2)" = "outdated" ] &&
    log "A newer sandbox harness is available ($REPO@$REF) — run: ./sandbox update"
  return 0
}

# tools/sandbox plus the two files install.sh writes outside it. ORIGIN.md is
# skipped because its timestamp changes on every run and would report itself as
# the only change; .cache is skipped because it is credentials and run state.
manifest() {
  ( cd "$REPO_ROOT" 2>/dev/null || exit 0
    find tools/sandbox sandbox .claude/skills/sandbox -type f \
      ! -path 'tools/sandbox/.cache/*' \
      ! -name 'ORIGIN.md' -print 2>/dev/null |
      sort | tr '\n' '\0' | xargs -0 shasum 2>/dev/null )
}

report_changes() {
  local out
  out="$(awk 'NR==FNR{a[$2]=$1;next}
              {if(!($2 in a)) print "  added    " $2
               else if(a[$2]!=$1) print "  updated  " $2
               delete a[$2]}
              END{for(p in a) print "  removed  " p}' "$1" "$2" | sort -k2)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
  else
    log "  (nothing — this project was already on that revision)"
  fi
}

fetch_source() {
  local dest="$1"
  for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 ||
      die "$tool is required to fetch $REPO@$REF. brew install $tool"
  done
  log "Fetching $REPO@$REF ..."
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" |
    tar -xz -C "$dest" --strip-components=1 ||
    die "could not download $REPO@$REF"
}

cmd_update() {
  # install.sh at the project root means this IS the starter repo, not a project
  # that installed it — the harness here is the working copy, and overwriting it
  # with upstream would discard exactly the work someone is in the middle of.
  if [ -f "$REPO_ROOT/install.sh" ] && [ -z "$FORCE" ]; then
    die "$REPO_ROOT looks like the sandbox source repo itself (install.sh is at the root).
       Updating would overwrite your working copy with upstream. Use git pull, or --force."
  fi

  local src commit=""
  trap '[ -n "${CLEANUP_DIR:-}" ] && rm -rf "$CLEANUP_DIR"' EXIT
  if [ -n "$FROM" ]; then
    src="$(cd "$FROM" 2>/dev/null && pwd -P)" || die "no such directory: $FROM"
    [ -d "$src/tools/sandbox" ] && [ -f "$src/install.sh" ] ||
      die "$FROM is not a sandbox checkout (no install.sh + tools/sandbox)"
    command -v git >/dev/null 2>&1 && commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
  else
    src="$(mktemp -d)"
    CLEANUP_DIR="$src"
    fetch_source "$src"
    # A tarball has no sha in it, and this is the moment the network is already
    # in hand, so record what the ref pointed at while we can. Empty is fine:
    # ORIGIN.md then says so and the daily check stays quiet.
    upstream_head || true
    commit="$UPSTREAM_SHA"
  fi

  [ -f "$src/install.sh" ] || die "the fetched tree has no install.sh"

  log "Updating the sandbox harness in $REPO_ROOT"
  log "  from $REPO@$REF${FROM:+ (local checkout $src)}"
  log ""

  local before after
  before="$(mktemp)"; after="$(mktemp)"
  manifest >"$before"

  SANDBOX_REPO="$REPO" SANDBOX_REF="$REF" SANDBOX_TARGET="$REPO_ROOT" \
    SANDBOX_ORIGIN_COMMIT="$commit" \
    bash "$src/install.sh" || die "install.sh failed; nothing further was changed"

  manifest >"$after"
  log ""
  log "Changed:"
  report_changes "$before" "$after"
  rm -f "$before" "$after"

  # The new harness is on disk and the recorded commit moved with it, so the
  # cached answer is stale by definition.
  rm -f "$STAMP"

  log ""
  log "Ports, mounts and volumes are fixed at container creation — run ./sandbox up"
  log "to pick up a harness change, and ./sandbox doctor if anything looks off."
}

main() {
  local mode="update"
  REPO_FLAG=""; REF_FLAG=""; FROM=""; FORCE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) mode="check" ;;
      --nudge) mode="nudge" ;;
      --force) FORCE=1 ;;
      --repo)  REPO_FLAG="${2:-}"; shift ;;
      --ref)   REF_FLAG="${2:-}"; shift ;;
      --from)  FROM="${2:-}"; shift ;;
      -h|--help)
        awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}" >&2
        return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  command -v jq >/dev/null 2>&1 || die "jq is required. brew install jq"
  resolve_origin

  case "$mode" in
    check)  cmd_check ;;
    nudge)  cmd_nudge ;;
    update) cmd_update ;;
  esac
}

main "$@"
