#!/usr/bin/env bash
# Filesystem-side care and feeding of a running sandbox: named-volume ownership
# and the hot-reload bridge. Source after common.sh + run-args.sh.

# Docker creates a fresh named volume owned by root. The agent user then can't
# write into node_modules or the build cache, and the first install fails with
# a permission error that looks like a bug in the package manager. Chown once,
# as root, right after the container exists.
fix_volume_ownership() {
  local dir targets=()
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    targets+=("/workspace/$dir")
  done < <(sandbox_list "$SANDBOX_VOLUME_DIRS")
  [ "${#targets[@]}" -eq 0 ] && return 0

  docker exec -u 0 "$SANDBOX_NAME" \
    sh -c 'for d in "$@"; do mkdir -p "$d"; chown '"$(id -u):$(id -g)"' "$d"; done' \
    _ "${targets[@]}" >/dev/null 2>&1 || true
}

# Absolute watch roots, as the container sees them.
watch_roots() {
  local dir out=""
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    out="${out:+$out:}/workspace/$dir"
  done < <(sandbox_list "$SANDBOX_WATCH_DIRS")
  printf '%s' "$out"
}

# Restart rather than reuse. A bridge left over from a previous boot is watching
# whatever roots that boot configured, so leaving it running is how a config
# change appears to have no effect.
ensure_mac_save_bridge() {
  local roots
  roots="$(watch_roots)"
  if [ -z "$roots" ]; then
    return 0
  fi

  docker exec "$SANDBOX_NAME" pkill -f 'mac-save-bridge\.mjs' >/dev/null 2>&1 || true
  docker exec -d \
    -e "SANDBOX_WATCH_ROOTS=$roots" \
    -e "SANDBOX_WATCH_INTERVAL_MS=$SANDBOX_WATCH_INTERVAL_MS" \
    -e "SANDBOX_WATCH_EXT=$SANDBOX_WATCH_EXT" \
    "$SANDBOX_NAME" node /usr/local/lib/mac-save-bridge.mjs >/dev/null 2>&1 || true
  echo "Hot-reload bridge watching: ${roots//:/, }" >&2
}

bridge_running() {
  docker exec "$SANDBOX_NAME" pgrep -f 'mac-save-bridge\.mjs' >/dev/null 2>&1
}
