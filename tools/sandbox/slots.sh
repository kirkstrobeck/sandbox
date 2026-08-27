#!/usr/bin/env bash
# Slot registry for concurrent inner agents. Source or run as CLI.
#
#   . tools/sandbox/slots.sh
#   bash tools/sandbox/slots.sh acquire auto
#   bash tools/sandbox/slots.sh git_lock -- git commit -m "..."

set -uo pipefail

_SLOTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if [ -z "${CACHE_DIR:-}" ]; then
  # shellcheck source=common.sh
  . "$_SLOTS_SCRIPT_DIR/common.sh"
fi

SLOTS_ROOT="${SLOTS_ROOT:-$CACHE_DIR/slots}"
SANDBOX_MAX_SLOTS="${SANDBOX_MAX_SLOTS:-4}"

_slots_registry_lock_file() {
  printf '%s/registry.lock\n' "$SLOTS_ROOT"
}

_slots_mkdir_lock_dir() {
  printf '%s/.lock\n' "$SLOTS_ROOT"
}

_slots_have_flock() {
  command -v flock >/dev/null 2>&1
}

_slots_with_registry_lock() {
  local rc=0
  mkdir -p "$SLOTS_ROOT"
  if _slots_have_flock; then
    (
      flock -x 200
      "$@"
    ) 200>"$(_slots_registry_lock_file)"
    rc=$?
    return "$rc"
  fi
  local lock_dir tries=0
  lock_dir="$(_slots_mkdir_lock_dir)"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 120 ]; then
      echo "slots: registry lock timeout" >&2
      return 1
    fi
    sleep 0.05
  done
  "$@"
  rc=$?
  rmdir "$lock_dir" 2>/dev/null || true
  return "$rc"
}

_slots_with_git_lock() {
  local rc=0
  mkdir -p "$SLOTS_ROOT"
  if _slots_have_flock; then
    (
      flock -x 9
      "$@"
    ) 9>"$SLOTS_ROOT/git.lock"
    rc=$?
    return "$rc"
  fi
  local lock_dir tries=0
  lock_dir="$SLOTS_ROOT/git.lock.dir"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 120 ]; then
      echo "slots: git lock timeout" >&2
      return 1
    fi
    sleep 0.05
  done
  "$@"
  rc=$?
  rmdir "$lock_dir" 2>/dev/null || true
  return "$rc"
}

_slots_norm_path() {
  local p="${1%/}"
  [ -n "$p" ] || p="/"
  printf '%s' "$p"
}

_slots_paths_conflict() {
  local a b
  a="$(_slots_norm_path "$1")"
  b="$(_slots_norm_path "$2")"
  [ "$a" = "$b" ] && return 0
  case "$b" in
    "$a"/*) return 0 ;;
  esac
  case "$a" in
    "$b"/*) return 0 ;;
  esac
  return 1
}

_slots_slot_dir() {
  printf '%s/%s\n' "$SLOTS_ROOT" "$1"
}

_slots_read_field() {
  local slot_dir="$1" field="$2" file
  file="$slot_dir/$field"
  [ -f "$file" ] || return 1
  cat "$file"
}

_slots_write_field() {
  local slot_dir="$1" field="$2" value="$3"
  mkdir -p "$slot_dir"
  printf '%s' "$value" >"$slot_dir/$field"
}

slots_is_free() {
  local id="$1" slot_dir state
  slot_dir="$(_slots_slot_dir "$id")"
  [ -d "$slot_dir" ] || return 0
  state="$(_slots_read_field "$slot_dir" state 2>/dev/null || printf 'idle')"
  [ "$state" = "idle" ] && return 0
  [ "$state" = "running" ] && return 1
  return 0
}

_slots_validate_id() {
  local id="$1"
  case "$id" in
    ''|*[!0-9]*) echo "slots: invalid slot id: $id" >&2; return 1 ;;
  esac
  if [ "$id" -ge "${SANDBOX_MAX_SLOTS:-4}" ] 2>/dev/null; then
    echo "slots: slot id out of range (0..$((SANDBOX_MAX_SLOTS - 1))): $id" >&2
    return 1
  fi
  return 0
}

_slots_acquire_one() {
  local id="$1" slot_dir caller_pid started task agent role
  slot_dir="$(_slots_slot_dir "$id")"
  if ! slots_is_free "$id"; then
    echo "slots: slot $id is busy" >&2
    return 1
  fi
  caller_pid="${SANDBOX_SLOT_CALLER_PID:-$$}"
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  task="${SANDBOX_SLOT_TASK:-}"
  task="${task%%$'\n'*}"
  agent="${SANDBOX_AGENT:-}"
  role="${SANDBOX_ROLE:-agent}"
  mkdir -p "$slot_dir"
  _slots_write_field "$slot_dir" state running
  _slots_write_field "$slot_dir" pid "$caller_pid"
  _slots_write_field "$slot_dir" started_epoch "$(date +%s 2>/dev/null || printf '0')"
  _slots_write_field "$slot_dir" started_at "$started"
  _slots_write_field "$slot_dir" task "$task"
  _slots_write_field "$slot_dir" agent "$agent"
  _slots_write_field "$slot_dir" role "$role"
  : >"$slot_dir/leases"
  printf '%s' "$id"
  return 0
}

slots_acquire() {
  local arg="${1:-auto}" id i
  _slots_with_registry_lock _slots_acquire_locked "$arg"
}

_slots_reap_stale() {
  local id slot_dir state pid pattern now started age
  now="$(date +%s 2>/dev/null || true)"
  for ((id = 0; id < SANDBOX_MAX_SLOTS; id++)); do
    slot_dir="$(_slots_slot_dir "$id")"
    [ -d "$slot_dir" ] || continue
    state="$(_slots_read_field "$slot_dir" state 2>/dev/null || printf 'idle')"
    [ "$state" = "running" ] || continue
    pattern="$(slot_kill_pattern "$id")"
    if command -v pgrep >/dev/null 2>&1; then
      pgrep -f "$pattern" >/dev/null 2>&1 && continue
    fi
    pid="$(_slots_read_field "$slot_dir" pid 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    started="$(_slots_read_field "$slot_dir" started_epoch 2>/dev/null || true)"
    if [ -z "$started" ] || [ -z "$now" ]; then
      continue
    fi
    age=$((now - started))
    if [ "$age" -lt 15 ]; then
      continue
    fi
    _slots_release_locked "$id"
  done
}

_slots_acquire_locked() {
  local arg="$1" id i
  _slots_reap_stale
  case "$arg" in
    auto)
      for ((i = 0; i < SANDBOX_MAX_SLOTS; i++)); do
        if slots_is_free "$i"; then
          _slots_acquire_one "$i"
          return $?
        fi
      done
      echo "slots: no free slot (max $SANDBOX_MAX_SLOTS)" >&2
      return 1
      ;;
    *)
      _slots_validate_id "$arg" || return 1
      _slots_acquire_one "$arg"
      ;;
  esac
}

slots_release() {
  local id="$1" slot_dir
  _slots_validate_id "$id" || return 1
  slot_dir="$(_slots_slot_dir "$id")"
  [ -d "$slot_dir" ] || { echo "slots: slot $id not found" >&2; return 1; }
  _slots_with_registry_lock _slots_release_locked "$id"
}

_slots_release_locked() {
  local id="$1" slot_dir
  slot_dir="$(_slots_slot_dir "$id")"
  _slots_write_field "$slot_dir" state idle
  rm -f "$slot_dir/pid" "$slot_dir/spawn.pid"
  : >"$slot_dir/leases"
  return 0
}

slots_list() {
  local id slot_dir state pid agent role task
  mkdir -p "$SLOTS_ROOT"
  for ((id = 0; id < SANDBOX_MAX_SLOTS; id++)); do
    slot_dir="$(_slots_slot_dir "$id")"
    [ -d "$slot_dir" ] || continue
    state="$(_slots_read_field "$slot_dir" state 2>/dev/null || printf 'idle')"
    [ "$state" = "running" ] || continue
    pid="$(_slots_read_field "$slot_dir" pid 2>/dev/null || true)"
    agent="$(_slots_read_field "$slot_dir" agent 2>/dev/null || true)"
    role="$(_slots_read_field "$slot_dir" role 2>/dev/null || true)"
    task="$(_slots_read_field "$slot_dir" task 2>/dev/null || true)"
    printf 'slot %s  running  pid=%s  agent=%s  role=%s  task=%s\n' \
      "$id" "${pid:-?}" "${agent:-?}" "${role:-agent}" "${task:-}"
  done
}

slots_list_status() {
  local id slot_dir state agent parts=""
  mkdir -p "$SLOTS_ROOT"
  for ((id = 0; id < SANDBOX_MAX_SLOTS; id++)); do
    slot_dir="$(_slots_slot_dir "$id")"
    [ -d "$slot_dir" ] || continue
    state="$(_slots_read_field "$slot_dir" state 2>/dev/null || printf 'idle')"
    [ "$state" = "running" ] || continue
    agent="$(_slots_read_field "$slot_dir" agent 2>/dev/null || true)"
    [ -n "$agent" ] || agent="?"
    if [ -n "$parts" ]; then
      parts="$parts slot${id}=${agent}"
    else
      parts="slot${id}=${agent}"
    fi
  done
  printf '%s' "$parts"
}

slots_git_lock() {
  mkdir -p "$SLOTS_ROOT"
  if _slots_have_flock; then
    exec 9>"$SLOTS_ROOT/git.lock"
    flock -x 9
    return $?
  fi
  local lock_dir tries=0
  lock_dir="$SLOTS_ROOT/git.lock.dir"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 120 ]; then
      echo "slots: git lock timeout" >&2
      return 1
    fi
    sleep 0.05
  done
  export _SLOTS_GIT_MKDIR_LOCK=1
  return 0
}

slots_git_unlock() {
  if [ -n "${_SLOTS_GIT_MKDIR_LOCK:-}" ]; then
    rmdir "$SLOTS_ROOT/git.lock.dir" 2>/dev/null || true
    unset _SLOTS_GIT_MKDIR_LOCK
    return 0
  fi
  if _slots_have_flock; then
    flock -u 9 2>/dev/null || true
  fi
  return 0
}

slots_lease_paths() {
  local id="$1"
  shift
  _slots_validate_id "$id" || return 1
  [ $# -gt 0 ] || { echo "slots: lease_paths requires at least one path" >&2; return 1; }
  _slots_with_registry_lock _slots_lease_paths_locked "$id" "$@"
}

_slots_lease_paths_locked() {
  local id="$1" slot_dir other_id other_dir other_state state path other_path leases_file
  shift
  slot_dir="$(_slots_slot_dir "$id")"
  [ -d "$slot_dir" ] || { echo "slots: slot $id not found" >&2; return 1; }
  state="$(_slots_read_field "$slot_dir" state 2>/dev/null || printf 'idle')"
  [ "$state" = "running" ] || { echo "slots: slot $id is not running" >&2; return 1; }

  for ((other_id = 0; other_id < SANDBOX_MAX_SLOTS; other_id++)); do
    [ "$other_id" = "$id" ] && continue
    other_dir="$(_slots_slot_dir "$other_id")"
    [ -d "$other_dir" ] || continue
    other_state="$(_slots_read_field "$other_dir" state 2>/dev/null || printf 'idle')"
    [ "$other_state" = "running" ] || continue
    leases_file="$other_dir/leases"
    [ -f "$leases_file" ] || continue
    while IFS= read -r other_path || [ -n "$other_path" ]; do
      [ -n "$other_path" ] || continue
      for path in "$@"; do
        if _slots_paths_conflict "$path" "$other_path"; then
          echo "slots: path lease conflict with slot $other_id ($other_path vs $path)" >&2
          return 1
        fi
      done
    done <"$leases_file"
  done

  leases_file="$slot_dir/leases"
  mkdir -p "$slot_dir"
  for path in "$@"; do
    path="$(_slots_norm_path "$path")"
    if grep -Fxq "$path" "$leases_file" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$path" >>"$leases_file"
  done
  return 0
}

slots_release_paths() {
  local id="$1" slot_dir
  _slots_validate_id "$id" || return 1
  slot_dir="$(_slots_slot_dir "$id")"
  [ -d "$slot_dir" ] || { echo "slots: slot $id not found" >&2; return 1; }
  : >"$slot_dir/leases"
  return 0
}

slot_argv0() {
  printf 'sandbox-slot-%s' "$1"
}

slot_kill_pattern() {
  local id="$1"
  printf 'sandbox-slot-%s( |$)' "$id"
}

slots_pkill_pattern() {
  slot_kill_pattern "$@"
}

slots_prepare_run_dir() {
  local id="$1" run_dir="${2:-$CACHE_DIR/run}" slot_sub f
  slot_sub="slot-$id"
  mkdir -p "$run_dir/$slot_sub"
  printf '%s' "$id" >"$run_dir/foreground-slot"
  for f in last.jsonl last.json last.txt last.err msg; do
    ln -sfn "$slot_sub/$f" "$run_dir/$f"
  done
}

_slots_running_count() {
  local id count=0
  for ((id = 0; id < SANDBOX_MAX_SLOTS; id++)); do
    slots_is_free "$id" || count=$((count + 1))
  done
  printf '%s' "$count"
}

_slots_cli() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    acquire)
      slots_acquire "${1:-auto}"
      ;;
    release)
      [ -n "${1:-}" ] || { echo "usage: slots.sh release <id>" >&2; return 2; }
      slots_release "$1"
      ;;
    list)
      slots_list
      ;;
    list-status)
      slots_list_status
      ;;
    git_lock)
      if [ "${1:-}" = "--" ]; then
        shift
        _slots_with_git_lock "$@"
        return $?
      fi
      echo "usage: slots.sh git_lock -- <command...>" >&2
      return 2
      ;;
    git_unlock)
      slots_git_unlock
      ;;
    lease_paths)
      [ -n "${1:-}" ] || { echo "usage: slots.sh lease_paths <id> <path>..." >&2; return 2; }
      local lid="$1"
      shift
      slots_lease_paths "$lid" "$@"
      ;;
    release_paths)
      [ -n "${1:-}" ] || { echo "usage: slots.sh release_paths <id>" >&2; return 2; }
      slots_release_paths "$1"
      ;;
    prepare_run_dir)
      [ -n "${1:-}" ] || { echo "usage: slots.sh prepare_run_dir <id> [run_dir]" >&2; return 2; }
      local rid="$1"
      shift
      slots_prepare_run_dir "$rid" "${1:-}"
      ;;
    is_free)
      [ -n "${1:-}" ] || { echo "usage: slots.sh is_free <id>" >&2; return 2; }
      slots_is_free "$1"
      ;;
    '')
      echo "usage: slots.sh acquire|release|list|list-status|git_lock|lease_paths|release_paths|..." >&2
      return 2
      ;;
    *)
      echo "slots: unknown command: $cmd" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _slots_cli "$@"
fi
