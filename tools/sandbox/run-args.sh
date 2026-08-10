#!/usr/bin/env bash
# Builds the `docker run` argument list for the sandbox container. Source after
# common.sh. Kept apart from boot.sh so the mount layout can be read — and
# argued with — without wading through lifecycle logic.

# Mount the repo at BOTH /workspace and its real host path.
#
# The container shares the host's Docker socket, so when the inner agent starts
# a sibling container (a database, a test service) with a bind mount, the daemon
# resolving that mount is the one on the Mac. It has never heard of /workspace.
# Mounting the repo a second time at its literal host path means a path that
# works inside also works when handed to the daemon.
sandbox_mount_args() {
  printf '%s\n' \
    -v "$REPO_ROOT:/workspace" \
    -v "$REPO_ROOT:$REPO_ROOT" \
    -v "$CACHE_DIR/claude-home:/home/agent/.claude" \
    -v "$CACHE_DIR/codex-home:/home/agent/.codex" \
    -v "$CACHE_DIR/gh:/home/agent/.config/gh" \
    -v "$CACHE_DIR/claude.json:/home/agent/.claude.json"

  # The socket, so the inner agent can start sibling containers.
  #
  # The mount SOURCE is resolved by the daemon, not by the Mac. Under Colima the
  # daemon lives in a VM, where the Mac's ~/.colima/<profile>/docker.sock does
  # not exist — and a unix socket cannot cross virtiofs anyway, so handing over
  # the host path fails with "error while creating mount source path ...
  # operation not supported". The socket every supported daemon can see is its
  # own, at /var/run/docker.sock. Gate on the daemon answering rather than on a
  # file existing on the Mac, for the same reason: the Mac is not where the path
  # gets looked up.
  if docker info >/dev/null 2>&1; then
    printf '%s\n' -v "${SANDBOX_DOCKER_SOCK:-/var/run/docker.sock}:/var/run/docker.sock"
  fi

  # Named volumes shadow the bind mount at these paths. node_modules must be
  # container-private because the Mac's tree is built for darwin and the
  # container needs linux; build caches are here because thousands of small
  # writes per rebuild are painfully slow over virtiofs.
  local dir vol
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    vol="$(sandbox_volume_name "${SANDBOX_NAME}_${dir}")"
    printf '%s\n' -v "$vol:/workspace/$dir"
  done < <(sandbox_list "$SANDBOX_VOLUME_DIRS")
}

sandbox_port_args() {
  local port
  while IFS= read -r port; do
    [ -z "$port" ] && continue
    printf '%s\n' -p "$port"
  done < <(sandbox_list "$SANDBOX_PORTS")
}

sandbox_env_args() {
  printf '%s\n' \
    -e "SANDBOX_INNER=1" \
    -e "SANDBOX_PROJECT=$SANDBOX_PROJECT" \
    -e "HOST_REPO_ROOT=$REPO_ROOT"

  # Mirrored so commits made inside carry the human's identity, not root's.
  local name email
  name="$(git -C "$REPO_ROOT" config user.name 2>/dev/null || true)"
  email="$(git -C "$REPO_ROOT" config user.email 2>/dev/null || true)"
  [ -n "$name" ] && printf '%s\n' -e "HOST_GIT_NAME=$name"
  [ -n "$email" ] && printf '%s\n' -e "HOST_GIT_EMAIL=$email"
}

sandbox_run_args() {
  printf '%s\n' \
    --name "$SANDBOX_NAME" \
    --label "sandbox.project=$SANDBOX_PROJECT" \
    -w /workspace \
    --add-host "host.docker.internal:host-gateway"
  sandbox_mount_args
  sandbox_port_args
  sandbox_env_args
}
