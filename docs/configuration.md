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
- every container port in `SANDBOX_PORTS` appears in the port bindings — the
  *container* half only, so a host port that got auto-picked (below) does not
  make a healthy container look stale on the next boot

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
or word, in Docker's `IP:HOST:CONTAINER` or `HOST:CONTAINER` form.

```bash
SANDBOX_PORTS="127.0.0.1:3000:3000 127.0.0.1:5432:5432"
```

Bind to `127.0.0.1` unless you actually want the dev server reachable from your
network. Note the other half of this: the server *inside* the container must
bind `0.0.0.0`, or the published port reaches nothing.

**Fixed at container creation.**

#### The host port is a preference, not a requirement

A busy host port used to be a hard failure. It is now a remap: before
`docker run`, `boot.sh` calls `sandbox_resolve_ports` in `run-args.sh`, which
checks each host port with an `lsof` listen check and — if something already
holds it — walks upward on the *same bind address* until it finds one free.

```
Host port 127.0.0.1:3000 is in use; publishing 127.0.0.1:3001 -> container 3000 instead.
```

What that does and does not change:

- **The container port never moves.** Your dev server keeps binding 3000; only
  the number you type into a browser changes. `./sandbox status` prints the
  bindings the container actually got.
- **Nothing is written to `sandbox.local.conf`.** A remap is a fact about this
  boot, not a decision about the project. If you want the new number to stick,
  put it in the file yourself.
- **The configured port is always preferred.** It is taken as-is whenever it is
  free, so the remap does not creep upward on every boot.
- **Only the two documented forms are rewritten.** A bare container port, an
  IPv6 literal, a port range, a `/udp` suffix — all passed through untouched
  and left to Docker.
- **The address matters.** A process on `0.0.0.0:3000` blocks a bind to
  `127.0.0.1:3000` and counts as busy; a process on `127.0.0.1:3000` does not
  block `192.168.1.5:3000` and does not.
- **A recreate does not fight itself.** `boot.sh` records the outgoing
  container's bindings and hands them to the resolver as already-released, so a
  config change does not bump the port just because Docker's proxy has not torn
  down yet.
- **Without `lsof` there is no remap.** The resolver has no opinion it cannot
  support, so it publishes what you configured and lets Docker produce the
  error — the behaviour that predates this.

`SANDBOX_PORT_SCAN_LIMIT` (default `20`) bounds the walk. If every port in the
window is taken, boot warns, keeps the configured port, and lets `docker run`
fail with `port is already allocated` — which `boot.sh` still explains.

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

## Upgrading the harness itself

`tools/sandbox/` and the `./sandbox` script are installed from
https://github.com/kirkstrobeck/sandbox — they are not project code.
`tools/sandbox/ORIGIN.md` says so in the directory, and carries the repo, ref
and commit the current copy came from as `KEY=value` lines:

```
SANDBOX_ORIGIN_REPO=kirkstrobeck/sandbox
SANDBOX_ORIGIN_REF=main
SANDBOX_ORIGIN_COMMIT=<sha>
```

```bash
./sandbox update                              # fetch that repo at that ref, reinstall here
./sandbox update --ref v2                     # and pin the project to a different ref
./sandbox update --repo you/sandbox           # or to your fork; ORIGIN.md remembers
./sandbox update --from ../sandbox            # from a local checkout, no network
./sandbox update --check                      # is there anything newer? exit 1 if yes
```

The update *is* `install.sh`, fetched with the tarball and run against this
directory, so the rules are the install rules and there is no second copy of
them to drift: `tools/sandbox` and `./sandbox` are replaced, `sandbox.conf`,
`sandbox.local.conf`, `AGENTS.md` and `CLAUDE.md` are preserved, the incoming
defaults land beside your config as `sandbox.conf.new`, and the PreToolUse hooks
are re-merged into `.claude/settings.json` without touching your other hooks.
The changed files are listed when it finishes. Run `./sandbox up` afterwards —
a new `SANDBOX_STACK` or run-args change only takes effect on the next boot.

Running it in a clone of the sandbox repo itself is refused: there, upstream
would overwrite the working copy. `git pull`, or `--force` if you meant it.

### `SANDBOX_UPDATE_CHECK`

Default `1`. Once a day, `./sandbox up` asks the GitHub API which commit the
recorded ref points at and prints one line if it differs from
`SANDBOX_ORIGIN_COMMIT`:

```
A newer sandbox harness is available (kirkstrobeck/sandbox@main) — run: ./sandbox update
```

The request is unauthenticated, detached, and capped at 8 seconds
(`SANDBOX_UPDATE_TIMEOUT`), and the line you see is the *previous* check's
answer — a boot never waits on the network for it. Nothing is fetched or changed
without `./sandbox update`. An install with no commit recorded, an unreachable
github.com, a rate limit: all report "cannot tell" to `--check` and stay silent
on boot.

Set to `0` in `sandbox.conf` to switch it off for the project, or export
`SANDBOX_UPDATE_CHECK=0` to switch it off for a shell — this is the one setting
where the environment beats the file, because a kill switch that a config file
can override is not one.

## Environment variables, not in the file

| Variable | Effect |
| --- | --- |
| `SANDBOX_AGENT` | Inner agent for this invocation. Beats detection and the default. |
| `SANDBOX_REBUILD=1` | Forces an image rebuild. What `./sandbox rebuild` sets. |
| `SANDBOX_PORT_SCAN_LIMIT` | How far above a busy host port to look for a free one. Default `20`. |
| `SANDBOX_UPDATE_CHECK=0` | Silences the daily "a newer harness exists" check for this shell. |
| `SANDBOX_UPDATE_TIMEOUT` | Seconds the update check waits on the GitHub API. Default `8`. |
| `SANDBOX_REPO` / `SANDBOX_REF` | Override the repo and ref `install.sh` and `./sandbox update` fetch. |
| `COLIMA_PROFILE` | Non-default Colima profile, for socket resolution and the inotify daemon stop. |
| `GH_TOKEN` / `GITHUB_TOKEN` | Taken ahead of `gh auth token` when bridging GitHub auth. |
| `SANDBOX_INNER` | Set to `1` inside the container. If you see it, you are the inner agent. |

## After a change

```bash
./sandbox doctor    # host, daemon, credentials, gitignore, hooks, upstream — with the fix for each
./sandbox status    # what is actually running: image, ports, bridge, live run
./sandbox up        # apply config: recreates the container on drift, restarts the bridge
./sandbox rebuild   # force the image too
./sandbox update    # replace the harness itself with a newer one from upstream
```
