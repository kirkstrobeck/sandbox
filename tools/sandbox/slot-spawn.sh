#!/usr/bin/env bash
# Spawn a peer agent inside the container (super-manager use only).
#
#   bash tools/sandbox/slot-spawn.sh [--slot id|auto] [--paths p1 p2 ...] [--wait] -- <message...>
#
# Must NOT call ./sandbox or dispatch.sh.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=slots.sh
. "$SCRIPT_DIR/slots.sh"
# shellcheck source=agent.sh
. "$SCRIPT_DIR/agent.sh"
# shellcheck source=model.sh
. "$SCRIPT_DIR/model.sh"

slot_arg=auto
wait_flag=0
paths=()
message=""
spawn_pid=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slot)
      slot_arg="${2:-}"
      shift 2
      ;;
    --paths)
      shift
      while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
        paths+=("$1")
        shift
      done
      ;;
    --wait) wait_flag=1; shift ;;
    --)
      shift
      message="$*"
      break
      ;;
    -h|--help)
      sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
      exit 0
      ;;
    *)
      message="$*"
      break
      ;;
  esac
done

if [ -z "${message//[[:space:]]/}" ]; then
  echo "slot-spawn: nothing to dispatch" >&2
  exit 2
fi

agent="$(resolve_sandbox_agent noprompt)" || exit 2
export SANDBOX_AGENT="$agent"
export SANDBOX_SLOT_TASK="${message%%$'\n'*}"

SANDBOX_INNER_MODEL="${SANDBOX_INNER_MODEL:-$(resolve_sandbox_model "$agent")}"
export SANDBOX_INNER_MODEL

slot_id="$(slots_acquire "$slot_arg")" || exit 1
export SANDBOX_SLOT="$slot_id"
export SANDBOX_ROLE="${SANDBOX_ROLE:-agent}"

if [ ${#paths[@]} -gt 0 ]; then
  slots_lease_paths "$slot_id" "${paths[@]}" || {
    slots_release "$slot_id" || true
    exit 1
  }
fi

run_dir="${CACHE_DIR}/run"
slots_prepare_run_dir "$slot_id" "$run_dir"
printf '%s' "$message" >"$run_dir/slot-$slot_id/msg"

slot_run="$SCRIPT_DIR/slot-run.sh"
slot_dir="$run_dir/slot-$slot_id"
slot_reg="$(_slots_slot_dir "$slot_id")"
spawn_pid=""

_record_spawn_pid() {
  local pid="$1"
  spawn_pid="$pid"
  _slots_write_field "$slot_reg" pid "$pid"
  _slots_write_field "$slot_reg" spawn.pid "$pid"
}

_link_session() {
  local base="$1"
  ln -sfn "${base}-slot-$slot_id" "$CACHE_DIR/$base" 2>/dev/null || true
}

case "$agent" in
  cursor)
    session_file="$CACHE_DIR/cursor-session-slot-$slot_id"
    session_id=""
    [ -f "$session_file" ] && session_id="$(cat "$session_file" 2>/dev/null || true)"
    set -- -p --force --trust --sandbox disabled --output-format stream-json
    [ -n "$session_id" ] && set -- "$@" --resume "$session_id"
    [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
    bash "$slot_run" "$slot_id" agent "$@" -- "$message" \
      >"$slot_dir/last.jsonl" 2>"$slot_dir/last.err" &
    _record_spawn_pid $!
    _link_session cursor-session
    ;;
  claude)
    set -- -p --verbose --dangerously-skip-permissions --output-format stream-json
    [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
    bash "$slot_run" "$slot_id" claude "$@" "$message" \
      >"$slot_dir/last.jsonl" 2>"$slot_dir/last.err" &
    _record_spawn_pid $!
    ;;
  codex)
    thread_file="$CACHE_DIR/codex-thread-slot-$slot_id"
    thread_id=""
    [ -f "$thread_file" ] && thread_id="$(cat "$thread_file" 2>/dev/null || true)"
    set -- exec
    [ -n "$thread_id" ] && set -- "$@" resume "$thread_id"
    set -- "$@" --dangerously-bypass-approvals-and-sandbox --json \
      --output-last-message "$slot_dir/last.txt"
    [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
    bash "$slot_run" "$slot_id" codex "$@" "$message" \
      >"$slot_dir/last.jsonl" 2>&1 &
    _record_spawn_pid $!
    _link_session codex-thread
    ;;
  copilot)
    COPILOT_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)" \
      bash "$slot_run" "$slot_id" copilot -p --autopilot --no-ask-user --allow-all \
      ${SANDBOX_INNER_MODEL:+--model "$SANDBOX_INNER_MODEL"} \
      "$message" >"$slot_dir/last.txt" 2>"$slot_dir/last.err" &
    _record_spawn_pid $!
    ;;
  agy)
    conv_file="$CACHE_DIR/agy-conversation-slot-$slot_id"
    conv_id=""
    [ -f "$conv_file" ] && conv_id="$(cat "$conv_file" 2>/dev/null || true)"
    set -- -p --dangerously-skip-permissions --output-format stream-json --print-timeout 1200
    [ -n "$conv_id" ] && set -- "$@" --conversation "$conv_id"
    [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
    bash "$slot_run" "$slot_id" agy "$@" "$message" \
      >"$slot_dir/last.jsonl" 2>"$slot_dir/last.err" &
    _record_spawn_pid $!
    _link_session agy-conversation
    ;;
  amp)
    thread_file="$CACHE_DIR/amp-thread-slot-$slot_id"
    thread_id=""
    [ -f "$thread_file" ] && thread_id="$(cat "$thread_file" 2>/dev/null || true)"
    if [ -n "$thread_id" ]; then
      bash "$slot_run" "$slot_id" amp threads continue "$thread_id" \
        >"$slot_dir/last.jsonl" 2>"$slot_dir/last.err" &
    else
      set -- -x --dangerously-allow-all --stream-json
      [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
      bash "$slot_run" "$slot_id" amp "$@" "$message" \
        >"$slot_dir/last.jsonl" 2>"$slot_dir/last.err" &
    fi
    _record_spawn_pid $!
    _link_session amp-thread
    ;;
  opencode)
    set -- run -p
    [ -n "$SANDBOX_INNER_MODEL" ] && set -- "$@" --model "$SANDBOX_INNER_MODEL"
    bash "$slot_run" "$slot_id" opencode "$@" -- "$message" \
      >"$slot_dir/last.txt" 2>"$slot_dir/last.err" &
    _record_spawn_pid $!
    ;;
  *)
    echo "slot-spawn: unsupported agent: $agent" >&2
    slots_release "$slot_id" || true
    exit 1
    ;;
esac

printf '%s\n' "$slot_id"
if [ "$wait_flag" = 1 ]; then
  wait "$spawn_pid"
  case "$agent" in
    cursor)
      new_session="$(jq -Rr 'fromjson? | select(.session_id != null) | .session_id' \
        "$slot_dir/last.jsonl" 2>/dev/null | tail -1 || true)"
      [ -n "$new_session" ] && printf '%s' "$new_session" >"$CACHE_DIR/cursor-session-slot-$slot_id"
      ;;
    codex)
      new_thread="$(jq -r 'select(.type == "thread.started") | .thread_id' \
        "$slot_dir/last.jsonl" 2>/dev/null | tail -1 || true)"
      [ -n "$new_thread" ] && printf '%s' "$new_thread" >"$CACHE_DIR/codex-thread-slot-$slot_id"
      ;;
    agy)
      new_conv="$(jq -r 'select(.conversation_id != null) | .conversation_id' \
        "$slot_dir/last.jsonl" 2>/dev/null | tail -1 || true)"
      [ -n "$new_conv" ] && printf '%s' "$new_conv" >"$CACHE_DIR/agy-conversation-slot-$slot_id"
      ;;
    amp)
      new_thread="$(jq -r 'select(.type == "thread.started") | .thread_id' \
        "$slot_dir/last.jsonl" 2>/dev/null | tail -1 || true)"
      [ -n "$new_thread" ] && printf '%s' "$new_thread" >"$CACHE_DIR/amp-thread-slot-$slot_id"
      ;;
  esac
fi
