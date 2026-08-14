#!/usr/bin/env bash
# One shared, once-a-day snapshot of model/plan/promo news. Source, don't run.
#
# This runs on the MAC, before the container exists. It is here because the
# inner agent is a manager that has to pick a cheaper worker model per task
# (see AGENT.md), and making it web-search for plan changes and promos on every
# dispatch spends the expensive tokens on a lookup whose answer does not move
# hour to hour. So the harness looks it up at most once a day, once for every
# sandbox on this machine, and hands the text in as one environment variable.
#
# Three rules keep it cheap and boring:
#
#   READ FIRST — a fresh file is used as-is. No network, no retry, no history.
#   FAIL OPEN  — every failure still writes a stub carrying a timestamp, so a
#                dead network costs one attempt a day, not one per dispatch.
#   HOST ONLY  — the file lives in the user's TMPDIR and is deliberately NOT
#                mounted into the container; dispatch.sh passes the text in as
#                SANDBOX_MODEL_DAILY. Mounting it would hand the inner agent a
#                host path outside the repo and buy nothing. See docs/security.md.
#
# Knobs, all read at call time so a caller can change them after sourcing:
#
#   SANDBOX_MODEL_DAILY_FILE       where it lives. Default $TMPDIR/sandbox-model-daily
#   SANDBOX_MODEL_DAILY_MAX_AGE    seconds before it is refetched. Default 86400
#   SANDBOX_MODEL_DAILY_TIMEOUT    per-URL curl timeout. Default 8, like update.sh
#   SANDBOX_MODEL_DAILY_FETCH_CMD  replaces curl. Given one URL, prints the page.
#                                  This is what makes the tests run with no network.

# macOS TMPDIR ends in a slash and /tmp does not, so the trailing one is trimmed
# rather than producing a path with a doubled separator in half the messages.
_sandbox_model_daily_path() {
  if [ -n "${SANDBOX_MODEL_DAILY_FILE:-}" ]; then
    printf '%s\n' "$SANDBOX_MODEL_DAILY_FILE"
    return 0
  fi
  local tmp="${TMPDIR:-/tmp}"
  printf '%s/sandbox-model-daily\n' "${tmp%/}"
}

# BSD and GNU stat spell mtime differently and neither fails cleanly when handed
# the other's flags — GNU `stat -f` reads a filesystem and still exits nonzero,
# which would smuggle its output into a fallback. So each form is tried and the
# answer is only accepted when it is all digits.
_sandbox_model_daily_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

# Seconds since the snapshot was written. A missing or unreadable file is
# reported as very old rather than as an error: every caller wants "refetch".
sandbox_model_daily_age() {
  local file mtime
  file="$(_sandbox_model_daily_path)"
  mtime="$(_sandbox_model_daily_mtime "$file")" || { printf '999999999\n'; return 0; }
  printf '%s\n' "$(( $(date +%s) - mtime ))"
}

sandbox_model_daily_fresh() {
  local file
  file="$(_sandbox_model_daily_path)"
  [ -r "$file" ] || return 1
  [ "$(sandbox_model_daily_age)" -le "${SANDBOX_MODEL_DAILY_MAX_AGE:-86400}" ]
}

# One page, best effort. Word splitting on the FETCH_CMD is deliberate so a stub
# can carry its own arguments ("bash /path/stub.sh").
_sandbox_model_daily_fetch() {
  local url="$1"
  if [ -n "${SANDBOX_MODEL_DAILY_FETCH_CMD:-}" ]; then
    # shellcheck disable=SC2086
    $SANDBOX_MODEL_DAILY_FETCH_CMD "$url" 2>/dev/null
    return $?
  fi
  command -v curl >/dev/null 2>&1 || return 1
  curl -sL -m "${SANDBOX_MODEL_DAILY_TIMEOUT:-8}" "$url" 2>/dev/null
}

# Crude on purpose. This is not an HTML parser and must never grow into one: it
# splits on tags, keeps the lines that mention a model, a price or a promo, and
# throws away everything else. The manager reading the result is perfectly able
# to cope with a ragged line; a parser that breaks on a marketing-site redesign
# would instead fail a dispatch.
_sandbox_model_daily_digest() {
  # One tag per line, then drop the tag itself and keep the text after it. A
  # line with no '>' on it is text that already contained a newline, and the
  # substitution leaves it alone.
  tr '<' '\n' |
    sed -e 's/[^>]*>//' \
        -e 's/&[A-Za-z#0-9]\{1,8\};/ /g' \
        -e 's/[[:space:]]\{1,\}/ /g' |
    grep -Ei 'promo|free|discount|opus|sonnet|haiku|gpt|grok|composer|plan|codex|openai' |
    # Inlined scripts and styles are text between tags too, and a page's own JSON
    # payload mentions every model name on it. Dropping the obvious shapes keeps
    # the digest readable without pretending to know what a script is.
    grep -vE '\{"|\}\)|self\.__|function\(|@media|;--|[[:alnum:]_]+\(\)' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    grep -v '^$' |
    cut -c1-140 |
    awk '!seen[$0]++' |
    head -10
}

_sandbox_model_daily_sources() {
  case "$1" in
    claude) printf '%s\n' 'https://www.anthropic.com/news' 'https://www.anthropic.com/pricing' ;;
    cursor) printf '%s\n' 'https://cursor.com/changelog' ;;
    # openai.com serves a JS challenge page to non-browser requests (403).
    # The releases atom and the npm manifest answer curl without gating.
    codex)  printf '%s\n' 'https://github.com/openai/codex/releases.atom' \
                          'https://registry.npmjs.org/@openai/codex/latest' ;;
  esac
}

# Every source for one product, digested and capped. The 2KB cap is per product:
# three of them plus the header keeps the whole file inside the ~8KB budget an
# environment variable can carry without becoming a burden to read.
_sandbox_model_daily_product() {
  local agent="$1" url page out=""
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    page="$(_sandbox_model_daily_fetch "$url")" || continue
    [ -n "$page" ] || continue
    out="$out$(printf '%s' "$page" | _sandbox_model_daily_digest)
"
  done <<EOF
$(_sandbox_model_daily_sources "$agent")
EOF
  printf '%s' "$out" | grep -v '^$' | head -c 2000
}

# mktemp + chmod + mv, in the snapshot's own directory. Two sandboxes booting at
# once must never see a half-written file, and the rename is the only step that
# is atomic.
_sandbox_model_daily_write() {
  local file="$1" dir tmp now iso status="unavailable"
  local claude_notes cursor_notes codex_notes

  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$(mktemp "$dir/.sandbox-model-daily.XXXXXX" 2>/dev/null)" || return 1
  chmod 600 "$tmp" 2>/dev/null || true

  claude_notes="$(_sandbox_model_daily_product claude)"
  cursor_notes="$(_sandbox_model_daily_product cursor)"
  codex_notes="$(_sandbox_model_daily_product codex)"
  [ -n "$claude_notes$cursor_notes$codex_notes" ] && status="ok"

  now="$(date +%s)"
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"

  # The *_manager keys are left empty by the fetcher and that is the intended
  # steady state. Guessing a model id out of marketing prose produces an id the
  # CLI rejects INSIDE the container, minutes later, which is worse than the
  # fallback in model.sh — so the keys exist for a human (or a future source
  # that publishes real ids) to fill in, and resolve_sandbox_model skips them
  # when they are blank.
  {
    printf '# sandbox model daily snapshot. Regenerated at most once per 24h, no history.\n'
    printf '# Public product pages, crudely stripped. Advisory only, and possibly stale.\n'
    printf 'fetched_at=%s\n' "$now"
    printf 'fetched_at_iso=%s\n' "$iso"
    printf 'status=%s\n' "$status"
    printf 'claude_manager=%s\n' "${SANDBOX_MODEL_DAILY_CLAUDE_MANAGER:-}"
    printf 'cursor_manager=%s\n' "${SANDBOX_MODEL_DAILY_CURSOR_MANAGER:-}"
    printf 'codex_manager=%s\n' "${SANDBOX_MODEL_DAILY_CODEX_MANAGER:-}"
    printf '\n[claude]\n%s\n' "$claude_notes"
    printf '\n[cursor]\n%s\n' "$cursor_notes"
    printf '\n[codex]\n%s\n' "$codex_notes"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  return 0
}

# The only function callers need. Prints today's snapshot on stdout and always
# succeeds: a dispatch must not fail because a marketing page was down.
sandbox_model_daily_ensure() {
  local file
  file="$(_sandbox_model_daily_path)"

  if sandbox_model_daily_fresh; then
    cat "$file" 2>/dev/null
    return 0
  fi

  _sandbox_model_daily_write "$file" || true
  cat "$file" 2>/dev/null || true
  return 0
}
