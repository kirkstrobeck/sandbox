# Colima

The sandbox needs a Docker daemon, a fast bind mount, and control over how the
VM is started. Colima gives all three from the command line, so `boot.sh` can
bring the whole thing up without a human clicking anything.

## Why Colima, and what Docker Desktop still gets you

Docker Desktop works. `common.sh` only overrides `DOCKER_HOST` when a Colima
socket actually exists, and a Docker Desktop install that creates the default
`/var/run/docker.sock` is used as-is. `./sandbox doctor` warns when `colima` is
missing rather than failing.

Colima is the default because of what the harness has to do automatically:

- **The VM flags are the whole ballgame.** The bind mount has to be `virtiofs`
  on a `vz` VM or working in the container is miserable. Colima takes those as
  arguments to a start command, so `ensure_colima` in `colima.sh` can start a
  correctly configured VM for someone who has never heard of either flag.
- **`boot.sh` can repair the VM.** Stopping the mount-inotify daemon (below) is
  a command, not a settings pane.
- **No licence question.** Colima is open source and free for any use, which
  matters for a starter meant to be dropped into someone else's repo.

The exact invocation, from `colima_start_flags` and `ensure_colima` in
`tools/sandbox/colima.sh`:

```bash
colima start --vm-type vz --mount-type virtiofs
```

`ensure_colima` runs that only when `colima status` reports the VM is down, and
does nothing at all when `colima` is not installed. It never reconfigures a VM
you already have running — if you started Colima with different flags, that is
the VM the sandbox uses.

## Never `--mount-inotify`

Colima has a `--mount-inotify` option that sounds like exactly what this repo
needs, and it is the one flag you must not use.

That daemon delivers a host save to the guest by `chmod`-ing the matching guest
file. A `chmod` is a metadata write, and it propagates straight back out to
macOS, where it looks like another host change. Pair it with any host-side
bridge doing the same trick with contents and the two sustain an event storm
with nobody typing — measured, in the setup this starter is generalized from, at
34 inotify events in a 15-second window on a file no one had touched.

`boot.sh` does not just avoid the flag, it stops the daemon. A machine that
booted Colima with `--mount-inotify` still has the daemon running, and it keeps
injecting until something stops it, so `stop_colima_inotify` runs on every boot:

```
Stopping Colima mount-inotify daemon (mac-save-bridge replaces it)...
```

It detects the daemon with `ps -axo args=` and stops it via
`colima daemon stop "${COLIMA_PROFILE:-default}"`. `./sandbox doctor` reports
the same condition as a warning. The replacement is
`tools/sandbox/mac-save-bridge.mjs`, which manufactures the event from inside
the guest where the rewrite cannot propagate back out — see
[hot-reload.md](hot-reload.md).

## How `DOCKER_HOST` gets resolved

Colima's socket lives under `~/.colima/<profile>/docker.sock`, and nothing
creates `/var/run/docker.sock` on the Mac. Every `docker` call in the harness
would otherwise fail. `common.sh` resolves it once, at source time:

```bash
sandbox_docker_host() {
  local sock="$HOME/.colima/${COLIMA_PROFILE:-default}/docker.sock"
  if [ -S "$sock" ]; then
    export DOCKER_HOST="unix://$sock"
  fi
}
```

Two details worth knowing:

- **It only overrides when a Colima socket is really there.** No socket, no
  `DOCKER_HOST`, and Docker Desktop's default socket is used untouched.
- **It runs at source time, not per caller.** Every script here shells out to
  `docker`, and one that forgot the call would talk to a socket that does not
  exist — surfacing as `dial unix /var/run/docker.sock: no such file or
  directory` from a command that has nothing to do with sockets.

Set `COLIMA_PROFILE` if you run a non-default Colima profile; both `common.sh`
and `stop_colima_inotify` read it.

## Mount paths are resolved by the daemon, not by the Mac

This is the lesson that explains two otherwise baffling parts of the harness.

Under Colima the Docker daemon runs inside a VM. When you hand it `-v
/some/path:/dest`, the *source* is looked up by the daemon, in the VM — not on
macOS. A path that plainly exists on your Mac can still fail, and a path that
means something inside the VM is what actually matters.

Two consequences, both in `tools/sandbox/run-args.sh`:

**The repo is mounted twice.** Once at `/workspace`, and once at its literal
host path:

```bash
-v "$REPO_ROOT:/workspace"
-v "$REPO_ROOT:$REPO_ROOT"
```

The container shares the host's Docker socket, so when the inner agent starts a
sibling container — a database, a test service — with a bind mount, the daemon
resolving that mount is the host's. It has never heard of `/workspace`. Mounting
the repo a second time at its real path means a path that works inside also
works when handed to the daemon. `REPO_ROOT` is computed with `pwd -P` in
`common.sh` for the same reason: the daemon only knows physical paths, not
symlinks.

**The Docker socket is shared as `/var/run/docker.sock`, not as the Mac sees
it.** Handing over `~/.colima/<profile>/docker.sock` fails twice over: that path
does not exist inside the VM where the daemon resolves it, and a unix socket
cannot cross virtiofs anyway. The error is `error while creating mount source
path ... operation not supported`. The socket every supported daemon can see is
its own, at `/var/run/docker.sock` — which is why `SANDBOX_DOCKER_SOCK` defaults
to that and is correct for Colima and Docker Desktop alike. `run-args.sh` gates
the mount on `docker info` answering rather than on a file existing on the Mac,
for the same reason: the Mac is not where the path gets looked up.

## Troubleshooting

Run `./sandbox doctor` first. It changes nothing and prints the fix for each
problem it finds.

**`Docker daemon not reachable` / `dial unix ... no such file or directory`**

The VM is down. `colima start --vm-type vz --mount-type virtiofs`, or let
`./sandbox up` do it.

**`port is already allocated`**

Something else on the Mac already holds a host port from `SANDBOX_PORTS`.
`boot.sh` catches this and prints the fix rather than leaving you with Docker's
message: free the port, or pick a different host port in the gitignored
`tools/sandbox/sandbox.local.conf`, which is sourced last and never committed:

```bash
SANDBOX_PORTS="127.0.0.1:3100:3000"
```

The container port stays the same; only the Mac-side number changes.

**`error while creating mount source path ... operation not supported`**

The daemon could not resolve a mount source. This is the daemon-side-vs-Mac-side
problem above: under Colima the path has to exist in the VM, not only on the
Mac, and a unix socket cannot be bind-mounted across virtiofs at all. `boot.sh`
prints a pointer to `sandbox_mount_args` in `tools/sandbox/run-args.sh`, which
is where every mount the container gets is decided. The usual cause is a
hand-edited `SANDBOX_DOCKER_SOCK` pointing at the Mac's Colima socket path;
`/var/run/docker.sock` is the right answer.

**Hot reload stopped working after a Colima restart**

Check `./sandbox status` for the bridge line, then `./sandbox up` to restart it.
If the `--inotify` daemon came back, boot stops it again. See
[hot-reload.md](hot-reload.md).

**A config change appears to do nothing**

Ports, mounts, and volumes are fixed when the container is created. `./sandbox
up` detects the drift and recreates; `./sandbox rebuild` forces the image too.
See [configuration.md](configuration.md).
