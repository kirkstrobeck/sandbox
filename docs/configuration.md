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
mounts, then run `./sandbox up` — it recreates the container when the
`sandbox.config-fp` label no longer matches the current config fingerprint. If
that somehow does not take, `./sandbox rebuild`.

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

## Project extension points

These three variables let `sandbox.conf` extend the container without forking
any harness files. All three are multi-line: assign once (overwriting clobbers),
or append with `SANDBOX_EXTRA_MOUNTS+="..."`. **Fixed at container creation**
for mounts; env takes effect immediately.

### `SANDBOX_EXTRA_MOUNTS`

Extra bind mounts, one per line: `host:container` or `host:container:rw|ro`.
Comments and blank lines are ignored.

```bash
SANDBOX_EXTRA_MOUNTS="
/path/to/my-secrets:/secrets:ro
/path/to/shared-cache:/cache:rw
"
```

The worktree's linked git common dir is already mounted automatically — do not
list it here. Never put `$(git ...)` in this variable; the automatic worktree
detection never forks git. A change to this variable changes the config
fingerprint, so `./sandbox up` recreates the container automatically.

### `SANDBOX_EXTRA_ENV`

Extra environment variables passed into the container, one `NAME=value` per
line. Useful for feature flags and non-secret config. For actual secrets, prefer
`SANDBOX_EXTRA_MOUNTS` with a `ro` secrets directory — env vars end up in
`docker inspect` output and process lists.

```bash
SANDBOX_EXTRA_ENV="
EXAMPLE_FLAG=1
MY_SERVICE_URL=http://my-service:8080
"
```

### `SANDBOX_EXTRA_ALLOW`

Extra glob patterns for the outer-gate Bash allowlist, one per line. Evaluated
**after** the named denials, so `git`, `pnpm`, `rm`, and `ssh` cannot be
re-enabled here regardless of what pattern you write.

```bash
SANDBOX_EXTRA_ALLOW="
bash tools/dev-start.sh*
bash tools/ci-check.sh
"
```

This is how a project adds its own harness scripts to the outer allowlist without
forking `outer-gate.sh`.

## Path variables inside vs outside the container

Two variables name the same directory but mean different things:

| Variable | Set by | Value | Visible in |
| --- | --- | --- | --- |
| `REPO_ROOT` | `common.sh` | Physical host path of the project (e.g. `/Users/alice/my-project`) | Host harness scripts only |
| `HOST_REPO_ROOT` | `run-args.sh` via `-e HOST_REPO_ROOT=$REPO_ROOT` | Same physical host path | Inside the container only |

Inside the container, `/workspace` and `$HOST_REPO_ROOT` are both bind-mounted
to the same tree; `/workspace` is the agent's working directory, and
`HOST_REPO_ROOT` is what to hand the Docker daemon when starting a sibling
container with a bind mount — the daemon resolves paths in the VM, not in the
container, so `/workspace` would not be found. They are deliberately different
strings (two separate Docker mounts of the same directory).

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

Default `claude`. `claude`, `codex` or `cursor`. Used only when nothing can be
auto-detected from the environment your outer client leaves behind — normally
the inner agent matches the outer one and nothing has to be set here. Override
for a single run with `./sandbox -a cursor "task"`, or for a shell with
`SANDBOX_AGENT`. Detection order, and why Codex is checked first and Cursor
last: [agents.md](agents.md).

## `SANDBOX_DEFAULT_MODEL`

Default empty. A project-wide pin for the **manager** model — the model of the
agent a dispatch starts inside the container, which routes and reviews and
spawns cheaper workers to do the work. It is not the model the workers run on;
the manager picks those per task.

`SANDBOX_MODEL` in the environment, or `./sandbox -m <id>` for one run, beats
it. A non-empty `<agent>_manager=` line in the daily snapshot beats it too.
Empty — the default — means the high-value per-agent default in
`tools/sandbox/model.sh` is used: `claude-sonnet-4-6`, `gpt-5.3-codex`,
`cursor-grok-4.6-high`. The outer client's own model is deliberately not copied.

Set this when your account has a model that suits the manager job better than
the shipped default, or when a default has gone stale. The id is handed through
verbatim, so it has to be one the chosen agent understands. Full resolution
order: [agents.md](agents.md).

## The daily model snapshot

The harness fetches a small model/plan/promo digest **on the host**, at most once
every 24 hours, and passes today's text into the run as `SANDBOX_MODEL_DAILY` so
the manager can pick a worker model without spending a web search on it.
`tools/sandbox/model-daily.sh` owns it.

| Variable | Default | Notes |
| --- | --- | --- |
| `SANDBOX_MODEL_DAILY_FILE` | `$TMPDIR/sandbox-model-daily` | Host path. Read first; refetched only when missing or stale. `chmod 600`, written `mktemp` + `mv`, no history |
| `SANDBOX_MODEL_DAILY_MAX_AGE` | `86400` | Seconds before the file is considered stale |
| `SANDBOX_MODEL_DAILY_TIMEOUT` | `8` | Per-URL fetch timeout, the same budget as the update check |
| `SANDBOX_MODEL_DAILY_FETCH_CMD` | unset | Replaces `curl`. Given one URL, prints the page. This is how the tests run offline |
| `SANDBOX_MODEL_DAILY` | — | Not read from the file: **set by `dispatch.sh`** and passed to `docker exec -e`. Set it yourself to override the snapshot for one run |

It is shared by every sandbox on the machine, because a promo is not
project-specific. It is **not mounted** — the container never sees `$TMPDIR` and
must not; the text crosses as an environment variable, which is why this is a
host-side write like the update-check stamp rather than a new capability. See
[security.md](security.md).

Every failure path still writes the file, with `status=unavailable` and a
timestamp. That is the point of the timestamp: a dead network costs one attempt
a day, not one attempt per dispatch. Delete the file to force a refetch.

## Toolchain, baked into the image

| Variable | Default | Notes |
| --- | --- | --- |
| `SANDBOX_NODE_IMAGE` | `node:24-bookworm-slim` | Base image. |
| `SANDBOX_DOCKER_CLI_VERSION` | `27.5.1` | CLI only; the daemon is the host's. |
| `SANDBOX_PNPM_VERSION` | `10.15.0` | |
| `SANDBOX_CODEX_VERSION` | `latest` | `@openai/codex`. |
| `SANDBOX_CURSOR_VERSION` | `latest` | Cursor CLI. Not on npm — a dated lab build like `2026.08.04-aaa8809`. `latest` reads the current one out of `cursor.com/install` at build time. |
| `SANDBOX_WITH_PLAYWRIGHT` | `0` | `1` installs Chromium with deps — a large image. |
| `SANDBOX_PLAYWRIGHT_VERSION` | `1.55.0` | Only used when the above is `1`. |

Pin them — a floating toolchain is how the container and CI quietly stop
agreeing. All seven are `docker build` args, so a change needs either a
`SANDBOX_STACK` bump or an explicit `./sandbox rebuild`.

## What an install owns: `tools/sandbox/MANIFEST`

Every path an install writes is listed in `tools/sandbox/MANIFEST`, with a
`version` header and a mode per path. It is checked in, and it is read by
`install.sh` (what to write), `update.sh` (what to remove, and what to report as
changed), `doctor.sh` and `./sandbox test`.

| Mode | Meaning |
| --- | --- |
| `replace` | Copied from the source tree on every install. **Deleting the line deletes the file from the project on the next `./sandbox update`.** |
| `preserve` | Copied only when the project does not have it. Never overwritten, never deleted. |
| `manage` | Install touches it but does not own its contents — merged into, generated, or purely yours. Never wholesale copied, never deleted. |

```
version 2

replace  tools/sandbox/dispatch-cursor.sh
preserve tools/sandbox/sandbox.conf
manage   tools/sandbox/.cache               # live credentials and run state
```

The point is that ownership stops being implicit. Before this, an upgrade
deleted `tools/sandbox` and copied a new one — which worked for files inside
that directory and quietly failed for everything outside it. A file the harness
stopped shipping stayed in every project that had ever installed it, forever,
and nothing reported it.

The removal rule is deliberately one-directional: a path the **old** manifest
owned as `replace` and the **new** one does not mention is deleted. A `preserve`
or `manage` path that leaves the manifest is left exactly where it is. Dropping
a line from a list is not consent to delete somebody's config.

Two guards keep the file honest, because a manifest that lies is worse than no
manifest — it would install a project into a state where the next update deletes
files that were never written:

- **At install time**, `install.sh` fails *before touching the project* if a
  `replace` or `preserve` path is missing from the source tree.
- **In the test suite**, `./sandbox test` checks both directions: every listed
  path exists, and every file under `tools/sandbox/` is listed.

`./sandbox doctor` reports the manifest version and warns if the project is
missing a path the manifest claims.

Upgrading from an install that predates the manifest is handled once: there is
no way to tell a file still shipped from one dropped three versions ago, so
`install.sh` sweeps `tools/sandbox/` — keeping `.cache/`, `sandbox.conf` and
`sandbox.local.conf` — says `swept`, and lets the manifest own the directory
from then on.

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
them to drift: the manifest above decides what is replaced, preserved and
removed, the incoming defaults land beside your config as `sandbox.conf.new`,
and the PreToolUse hooks are re-merged into `.claude/settings.json` without
touching your other hooks.

The change report at the end is computed over the union of the old and new
manifests, so a file the harness stopped shipping shows up as `removed` rather
than just quietly vanishing:

```
Changed:
  added    tools/sandbox/dispatch-cursor.sh
  updated  tools/sandbox/dispatch.sh
  removed  tools/sandbox/dropped.sh
```

Run `./sandbox up` afterwards — a new `SANDBOX_STACK` or run-args change only
takes effect on the next boot.

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
| `SANDBOX_MODEL` | Manager model for this invocation. Beats the snapshot and `SANDBOX_DEFAULT_MODEL`. What `./sandbox -m` sets. |
| `SANDBOX_MODEL_DAILY` | Today's model/plan/promo snapshot. Set by `dispatch.sh` and passed into the container; set it yourself to override for one run. |
| `SANDBOX_MODEL_DAILY_FILE` / `_MAX_AGE` / `_TIMEOUT` / `_FETCH_CMD` | Where that snapshot lives, when it goes stale, how long a fetch may take, and what to fetch with. |
| `CURSOR_API_KEY` | Bridged to the inner Cursor CLI ahead of any stored login. |
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
