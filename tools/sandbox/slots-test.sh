#!/usr/bin/env bash
# Tests for tools/sandbox/slots.sh. Run: bash tools/sandbox/slots-test.sh
#
# gate-test.sh sources this so check/pass/fail accumulate into the harness total.
# Uses a temp CACHE_DIR — never the real tools/sandbox/.cache.

ST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if ! declare -F check >/dev/null 2>&1; then
  set -uo pipefail
  ST_STANDALONE=1
  pass=0
  fail=0
  check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
      pass=$((pass + 1))
      printf '  ok   %-58s %s\n' "$label" "$actual"
      return 0
    fi
    fail=$((fail + 1))
    printf '  FAIL %-58s expected %s, got %s\n' "$label" "$expected" "$actual"
  }
fi

slots_tests() {
  echo
  echo "slots.sh — acquire, lease, release, helpers"

  export CACHE_DIR="$(mktemp -d)"
  export SANDBOX_MAX_SLOTS=2
  export SLOTS_ROOT="$CACHE_DIR/slots"
  # shellcheck source=slots.sh
  . "$ST_DIR/slots.sh"

  local id0 id1 id2 rc err

  id0="$(slots_acquire auto)"
  id1="$(slots_acquire auto)"
  check "acquire auto: first id" 0 "$id0"
  check "acquire auto: second id" 1 "$id1"
  check "acquire auto: ids differ" different \
    "$([ "$id0" != "$id1" ] && echo different || echo same)"

  rc=0
  err="$(slots_acquire auto 2>&1 >/dev/null)" || rc=$?
  check "acquire auto: third fails when MAX=2" 1 "$rc"
  check "acquire auto: third stderr nonempty" nonempty \
    "$([ -n "$err" ] && echo nonempty || echo empty)"

  printf '999999\n' >"$SLOTS_ROOT/0/pid"
  rc=0
  slots_is_free 0 || rc=$?
  check "is_free: dead pid but state=running still busy" 1 "$rc"

  rc=0
  err="$(SANDBOX_SLOT_CALLER_PID=$$ slots_lease_paths 0 src/foo 2>&1 >/dev/null)" || rc=$?
  check "lease_paths: slot0 src/foo ok" 0 "$rc"

  rc=0
  err="$(SANDBOX_SLOT_CALLER_PID=$$ slots_lease_paths 1 src/foo/bar 2>&1 >/dev/null)" || rc=$?
  check "lease_paths: child conflict fails" 1 "$rc"
  check "lease_paths: names other slot" slot0 \
    "$(printf '%s' "$err" | grep -q 'slot 0' && echo slot0 || echo missing)"

  rc=0
  slots_lease_paths 1 src/foobar >/dev/null 2>&1 || rc=$?
  check "lease_paths: src/foobar no conflict with src/foo" 0 "$rc"

  slots_release "$id0"
  id2="$(slots_acquire auto)"
  check "release frees slot: re-acquire gets released id" 0 "$id2"

  check "slot_kill_pattern 2 matches sandbox-slot-2 claude" match \
    "$(printf '%s\n' 'sandbox-slot-2 claude' | grep -E "$(slot_kill_pattern 2)" >/dev/null && echo match || echo miss)"
  check "slot_kill_pattern 2 matches sandbox-slot-2 alone" match \
    "$(printf '%s\n' 'sandbox-slot-2' | grep -E "$(slot_kill_pattern 2)" >/dev/null && echo match || echo miss)"
  check "slot_kill_pattern 2 not sandbox-slot-20" nomatch \
    "$(printf '%s\n' 'sandbox-slot-20 claude' | grep -E "$(slot_kill_pattern 2)" >/dev/null && echo match || echo nomatch)"
  check "slot_kill_pattern 2 not sandbox-slot-12" nomatch \
    "$(printf '%s\n' 'sandbox-slot-12 foo' | grep -E "$(slot_kill_pattern 2)" >/dev/null && echo match || echo nomatch)"

  check "slot_argv0 0" sandbox-slot-0 "$(slot_argv0 0)"

  rc=0
  bash "$ST_DIR/slots.sh" git_lock -- true >/dev/null 2>&1 || rc=$?
  check "git_lock -- true exits 0" 0 "$rc"

  echo
  echo "Syntax — slots scripts"
  for _sf in slots.sh slot-run.sh slot-spawn.sh slots-test.sh; do
    check "bash -n $_sf" ok \
      "$(bash -n "$ST_DIR/$_sf" 2>&1 && echo ok || echo "syntax error")"
  done

  rm -rf "$CACHE_DIR"
}

slots_tests

if [ -n "${ST_STANDALONE:-}" ]; then
  echo
  printf '%s passed, %s failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
fi
