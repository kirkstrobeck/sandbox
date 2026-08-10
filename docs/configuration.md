# Configuration

Everything project-specific lives in `tools/sandbox/sandbox.conf`. It is plain
shell, sourced by `config.sh`, and it is the one file under `tools/sandbox/`
that an upgrade preserves — the rest of the directory is meant to stay generic
and gets replaced.

## Layering

`config.sh` applies three layers, last one wins:

1. **Defaults**, set in `config.sh` itself. Defaults come first so a config file
   only has to state what it changes, and so an older config never leaves a new
   variable unset after an upgrade.
2. **`tools/sandbox/sandbox.conf`**, if readable. Committed. This is the
   project's answer.
3. **`tools/sandbox/sandbox.local.conf`**, if readable. Gitignored. This is your
   machine's answer.

`common.sh` is the only intended caller; it sources `config.sh` after computing
`REPO_ROOT`, then derives `SANDBOX_NAME` as
`<project>-sandbox-<8 chars of a hash of the repo path>`. The hash means two
worktrees of the same repo get two containers instead of fighting over one, and
the same path always yields the same name. `SANDBOX_IMAGE`
(`<project>-sandbox:local`) is derived too, unless you set it explicitly.

## `sandbox.local.conf`

For anything true of your machine rather than the project — a port already taken
by something else, an unusual daemon socket. It is sourced last, so it overrides
`sandbox.conf`, and `install.sh` adds it to `.gitignore`:

```bash
# Machine-local overrides. Gitignored. Sourced last.
# Port 3000 is taken on this machine by another container.
SANDBOX_PORTS="127.0.0.1:3917:3000"
```

Never put a credential in it. Credentials belong in `tools/sandbox/.cache/`,
which the harness manages — see [credentials.md](credentials.md).

## The gotcha: some settings are fixed at container creation

Docker has no way to add a mount, a port, or a volume to a container that
already exists. A container started under an older config keeps that config
forever.

So `boot.sh` does not blindly reuse what is running. `container_is_current()`
checks that the running container matches what the config now asks for:

- the image id matches the current `SANDBOX_IMAGE`
- `/workspace`, the host repo path, and `/home/agent/.config/gh` are all mounted
- every directory in `SANDBOX_VOLUME_DIRS` has a mount at `/workspace/<dir>`
- every container port in `SANDBOX_PORTS` appears in the port bindings

Any mismatch and it recreates:

```
Sandbox config changed; recreating <project>-sandbox-1a2b3c4d.
```

Silent drift here is the kind of bug that costs an afternoon, which is why the
check is explicit rather than optimistic. In practice: change ports, volumes, or
mounts, then run `./sandbox up`. If it somehow does not take, `./sandbox
rebuild`.

Image-level settings (the toolchain versions below) are a different lever:
`boot.sh` compares `SANDBOX_STACK` against the label baked into the image and
rebuilds on drift. Changing a version *without* bumping `SANDBOX_STACK` does
nothing until someone forces `./sandbox rebuild`.

Watch settings are the cheap ones — the bridge is restarted on every
`./sandbox up`, no recreation and no rebuild.

## Identity

### `SANDBOX_PROJECT`

Default: the repo directory name, lowercased and made DNS-safe.

Becomes part of the container name, the image tag, and the volume names. Keep it
lowercase and DNS-safe. Changing it points the harness at a *different*
container and set of volumes — the old ones stay on disk until you remove them.

### `SANDBOX_STACK`

Default `v1`. The image contract version, baked in as the
`dev.sandbox.agent-stack` label.

Bump it when the Dockerfile changes in a way every worktree must pick up.
`boot.sh` compares the label to this value and rebuilds on drift, which is how a
harness upgrade reaches machines that would otherwise keep using a stale image.

## Runtime

### `SANDBOX_PORTS`

Default empty. Ports published from the container to the Mac, one entry per line
or word, in Docker's `HOST:CONTAINER` form.

```bash
SANDBOX_PORTS="127.0.0.1:3000:3000 127.0.0.1:5432:5432"
```

Bind to `127.0.0.1` unless you actually want the dev server reachable from your
network. Note the other half of this: the server *inside* the container must
bind `0.0.0.0`, or the published port reaches nothing.

Change it when you add a service or when a host port is taken — the
`port is already allocated` failure is the common one, and `boot.sh` prints the
fix. **Fixed at container creation.**

### `SANDBOX_VOLUME_DIRS`

Default `node_modules`. Repo-relative directories that become container-private
named volumes, shadowing the bind mount at those paths.

Two reasons a directory belongs here:

- **`node_modules`** — the Mac's tree is darwin-arm64 and the container needs
  linux-arm64. Sharing one tree breaks both installs.
- **build caches** (`.next`, `dist`, `.turbo`, `coverage`) — thousands of small
  writes per rebuild over virtiofs is slow and floods the mount layer.

```bash
SANDBOX_VOLUME_DIRS="node_modules .next"
```

Anything listed here is invisible from the Mac: it exists only inside the
container. Volume names are derived from the container name and path, encoded
rather than truncated so two repos cannot collide. `boot.sh` chowns each one to
your uid/gid right after creation, because Docker creates named volumes owned by
root and the first install would otherwise fail with a permission error that
looks like a package-manager bug. **Fixed at container creation.**

### `SANDBOX_DOCKER_SOCK`

Default `/var/run/docker.sock`. The Docker socket shared with the container, so
the inner agent can start sibling containers.

This is the path **as the daemon sees it**, not as the Mac sees it. That default
is correct for Colima and Docker Desktop alike, and pointing it at the Mac's
`~/.colima/<profile>/docker.sock` fails — that path does not exist in the VM,
and a unix socket cannot cross virtiofs anyway. Only change it for an unusual
daemon layout. See [colima.md](colima.md). **Fixed at container creation.**

## Hot reload

`SANDBOX_WATCH_DIRS` (default `src`), `SANDBOX_WATCH_INTERVAL_MS` (default
`250`), and `SANDBOX_WATCH_EXT` (a JS regex, no delimiters) configure the bridge
that makes a save on the Mac look like a real file change inside the container.

Keep the watch dirs tight and pointed at your actual source roots — the bridge
polls, and polling the whole repo is what makes it slow. Setting
`SANDBOX_WATCH_DIRS` empty disables the bridge. All three take effect on the
next `./sandbox up`, which restarts the bridge rather than reusing it. Full
detail and the measured numbers behind the design are in
[hot-reload.md](hot-reload.md).

## `SANDBOX_DEFAULT_AGENT`

Default `claude`. Used only when nothing can be auto-detected from the
environment your outer client leaves behind. Override for a single run with
`./sandbox -a codex "task"`, or for a shell with `SANDBOX_AGENT`. Detection
order and why Codex is checked first: [agents.md](agents.md).

## Toolchain, baked into the image

| Variable | Default | Notes |
| --- | --- | --- |
| `SANDBOX_NODE_IMAGE` | `node:24-bookworm-slim` | Base image. |
| `SANDBOX_DOCKER_CLI_VERSION` | `27.5.1` | CLI only; the daemon is the host's. |
| `SANDBOX_PNPM_VERSION` | `10.15.0` | |
| `SANDBOX_CODEX_VERSION` | `latest` | `@openai/codex`. |
| `SANDBOX_WITH_PLAYWRIGHT` | `0` | `1` installs Chromium with deps — a large image. |
| `SANDBOX_PLAYWRIGHT_VERSION` | `1.55.0` | Only used when the above is `1`. |

Pin them — a floating toolchain is how the container and CI quietly stop
agreeing. All six are `docker build` args, so a change needs either a
`SANDBOX_STACK` bump or an explicit `./sandbox rebuild`.

## Environment variables, not in the file

| Variable | Effect |
| --- | --- |
| `SANDBOX_AGENT` | Inner agent for this invocation. Beats detection and the default. |
| `SANDBOX_REBUILD=1` | Forces an image rebuild. What `./sandbox rebuild` sets. |
| `COLIMA_PROFILE` | Non-default Colima profile, for socket resolution and the inotify daemon stop. |
| `GH_TOKEN` / `GITHUB_TOKEN` | Taken ahead of `gh auth token` when bridging GitHub auth. |
| `SANDBOX_INNER` | Set to `1` inside the container. If you see it, you are the inner agent. |

## After a change

```bash
./sandbox doctor    # host, daemon, credentials, gitignore, hooks — with the fix for each
./sandbox status    # what is actually running: image, ports, bridge, live run
./sandbox up        # apply config: recreates the container on drift, restarts the bridge
./sandbox rebuild   # force the image too
```
