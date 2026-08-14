#!/usr/bin/env bash
# Bring the sandbox up. Idempotent: safe to run before every dispatch, cheap
# when nothing has changed. Prints the container name on stdout; everything
# meant for a human goes to stderr, so callers can capture the name cleanly.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=colima.sh
. "$SCRIPT_DIR/colima.sh"
# shellcheck source=run-args.sh
. "$SCRIPT_DIR/run-args.sh"
# shellcheck source=dev-fs.sh
. "$SCRIPT_DIR/dev-fs.sh"

log() { printf '%s\n' "$*" >&2; }

image_stack() {
  docker image inspect "$SANDBOX_IMAGE" \
    --format "{{index .Config.Labels \"$SANDBOX_STACK_LABEL\"}}" 2>/dev/null || true
}

ensure_image() {
  if [ "$(image_stack)" = "$SANDBOX_STACK" ] && [ -z "${SANDBOX_REBUILD:-}" ]; then
    return 0
  fi
  log "Building $SANDBOX_IMAGE (stack $SANDBOX_STACK). First build takes a few minutes."
  docker build \
    --build-arg "NODE_IMAGE=$SANDBOX_NODE_IMAGE" \
    --build-arg "DOCKER_CLI_VERSION=$SANDBOX_DOCKER_CLI_VERSION" \
    --build-arg "PNPM_VERSION=$SANDBOX_PNPM_VERSION" \
    --build-arg "CODEX_VERSION=$SANDBOX_CODEX_VERSION" \
    --build-arg "CURSOR_VERSION=$SANDBOX_CURSOR_VERSION" \
    --build-arg "WITH_PLAYWRIGHT=$SANDBOX_WITH_PLAYWRIGHT" \
    --build-arg "PLAYWRIGHT_VERSION=$SANDBOX_PLAYWRIGHT_VERSION" \
    --build-arg "SANDBOX_STACK=$SANDBOX_STACK" \
    --build-arg "HOST_UID=$(id -u)" \
    --build-arg "HOST_GID=$(id -g)" \
    -t "$SANDBOX_IMAGE" "$SCRIPT_DIR" >&2
}

prepare_cache() {
  mkdir -p "$CACHE_DIR/claude-home" "$CACHE_DIR/codex-home" \
           "$CACHE_DIR/cursor-home" "$CACHE_DIR/gh"

  # This file is bind-mounted as a FILE, so it has to exist before the container
  # starts or Docker creates a directory in its place.
  [ -f "$CACHE_DIR/claude.json" ] || printf '{}\n' >"$CACHE_DIR/claude.json"

  # Seed trust so the inner Claude doesn't stop on a trust dialog.
  # The container is the trust boundary; inner permission prompts are redundant.
  local cj="$CACHE_DIR/claude.json"
  local tmp
  tmp="$(mktemp "$cj.XXXXXX")"
  if jq --arg r "$REPO_ROOT" \
       '.projects |= (. // {}) |
        .projects["/workspace"] |= (. // {}) |
        .projects["/workspace"].hasTrustDialogAccepted = true |
        .projects[$r] |= (. // {}) |
        .projects[$r].hasTrustDialogAccepted = true' \
       "$cj" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$cj"
  else
    rm -f "$tmp"
  fi

  bash "$SCRIPT_DIR/token-sync.sh" pull >&2 || log "WARN: no Claude credential bridged."
  bash "$SCRIPT_DIR/codex-token-sync.sh" pull >&2 || log "WARN: no Codex credential bridged."
  bash "$SCRIPT_DIR/cursor-token-sync.sh" pull >&2 || log "WARN: no Cursor credential bridged."
  bash "$SCRIPT_DIR/github-token-sync.sh" >&2 || log "WARN: git push from inside the sandbox will not work."
}

container_exists() { docker inspect "$SANDBOX_NAME" >/dev/null 2>&1; }
container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$SANDBOX_NAME" 2>/dev/null)" = "true" ]; }

has_mount() {
  docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$SANDBOX_NAME" 2>/dev/null |
    grep -qx "$1"
}

# A container started under an older config keeps that config forever — Docker
# has no way to add a mount or a port to a running container. So rather than
# reuse whatever is there, check that what is running matches what the config
# now asks for, and recreate when it doesn't. Silent drift here is the kind of
# bug that costs an afternoon.
container_is_current() {
  local want_image running_image
  want_image="$(docker image inspect -f '{{.Id}}' "$SANDBOX_IMAGE" 2>/dev/null || true)"
  running_image="$(docker inspect -f '{{.Image}}' "$SANDBOX_NAME" 2>/dev/null || true)"
  [ -n "$want_image" ] && [ "$want_image" = "$running_image" ] || return 1

  has_mount /workspace || return 1
  has_mount "$REPO_ROOT" || return 1
  has_mount /home/agent/.config/gh || return 1
  has_mount /home/agent/.config/cursor || return 1

  local dir
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    has_mount "/workspace/$dir" || return 1
  done < <(sandbox_list "$SANDBOX_VOLUME_DIRS")

  local port container_port
  while IFS= read -r port; do
    [ -z "$port" ] && continue
    container_port="${port##*:}"
    docker inspect -f '{{json .HostConfig.PortBindings}}' "$SANDBOX_NAME" 2>/dev/null |
      grep -q "\"$container_port/tcp\"" || return 1
  done < <(sandbox_list "$SANDBOX_PORTS")

  # Config fingerprint: mount args + env args + stack + ports + volume dirs.
  # Stored as a label at run time; mismatch means the config changed.
  local want_fp running_fp
  want_fp="$(sandbox_config_fingerprint 2>/dev/null || true)"
  running_fp="$(docker inspect -f '{{index .Config.Labels "sandbox.config-fp"}}' "$SANDBOX_NAME" 2>/dev/null || true)"
  [ -z "$want_fp" ] || [ "$want_fp" = "$running_fp" ] || return 1

  return 0
}

# Host ports the container we are about to remove currently holds, as
# "HostIp:HostPort" lines. They belong to us, so the resolver must not count
# them as taken — see SANDBOX_PORTS_RELEASED in run-args.sh.
old_host_ports() {
  docker inspect -f \
    '{{range $p, $bs := .HostConfig.PortBindings}}{{range $bs}}{{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}{{end}}' \
    "$SANDBOX_NAME" 2>/dev/null || true
}

# Docker names the symptom and stops. The two failures people actually hit here
# have specific fixes, and printing them is the difference between a five-second
# correction and a debugging session.
explain_run_failure() {
  case "$1" in
    *"port is already allocated"*)
      log ""
      log "A host port from SANDBOX_PORTS is held by something else, and the"
      log "auto-pick did not get out of the way: either every port in the scan"
      log "window above it is taken too, or lsof is not on PATH, so the conflict"
      log "only surfaced at docker run."
      log "Free the port, widen the search with SANDBOX_PORT_SCAN_LIMIT, or pin a"
      log "different host port in tools/sandbox/sandbox.local.conf:"
      log "  SANDBOX_PORTS=\"127.0.0.1:3100:3000\""
      ;;
    *"mount source path"*)
      log ""
      log "The Docker daemon could not resolve a mount source. Under Colima the"
      log "daemon runs inside a VM, so the path has to exist there — not only on"
      log "the Mac. See sandbox_mount_args in tools/sandbox/run-args.sh."
      ;;
  esac
}

ensure_container() {
  if container_exists && container_running && container_is_current; then
    return 0
  fi
  if container_exists; then
    log "Sandbox config changed; recreating $SANDBOX_NAME."
    SANDBOX_PORTS_RELEASED="$(old_host_ports)"
    docker rm -f "$SANDBOX_NAME" >/dev/null 2>&1 || true
  fi

  # Once, here, before the args are built: a host port that is taken gets
  # remapped upward and everything downstream — including the -p flags — sees
  # the resolved list rather than the configured one.
  SANDBOX_PORTS_RESOLVED="$(sandbox_resolve_ports)"

  local args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(sandbox_run_args)

  local err
  if err="$(docker run -d "${args[@]}" "$SANDBOX_IMAGE" sleep infinity 2>&1 >/dev/null)"; then
    log "Started $SANDBOX_NAME."
    return 0
  fi
  log "$err"
  explain_run_failure "$err"
  return 1
}

ensure_colima
sandbox_require_docker
stop_colima_inotify
ensure_image
prepare_cache
ensure_container
fix_volume_ownership
ensure_mac_save_bridge

# Last, and never fatal: at most one line saying a newer harness exists. It
# reports the previous check's answer and refreshes in the background, so a slow
# or absent network costs a boot nothing. Nothing is updated without being asked.
bash "$SCRIPT_DIR/update.sh" --nudge >/dev/null || true

printf '%s\n' "$SANDBOX_NAME"
