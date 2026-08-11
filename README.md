# sandbox

Run your coding agent with permissions turned off, inside a container, without
handing it your Mac.

```
curl -fsSL https://raw.githubusercontent.com/kirkstrobeck/sandbox/main/install.sh | bash
```

Run that from any project root — including an empty folder. A git repo is not
required, and the directory is created if it doesn't exist. It installs the
harness, wires the hooks, and prints:

```
1. edit tools/sandbox/sandbox.conf   (ports, watch dirs, volumes)
2. ./sandbox doctor                  (checks the host, names every fix)
3. ./sandbox "say hello and list the files you can see"
```

Restart your agent client afterward so it picks up the new PreToolUse hooks.

## Why this exists

`--dangerously-skip-permissions` is what makes an agent actually useful and it
is also the thing you should not point at your laptop. The usual compromise is
to approve every command by hand, which is slow enough that people stop reading
the prompts.

This repo takes the other option: two agents, and a container as the trust
boundary.

- **The outer agent** runs in your terminal, talks to you, and does no work. It
  reads the repo, writes the task, and relays it.
- **The inner agent** runs `claude -p --dangerously-skip-permissions` or
  `codex exec --dangerously-bypass-approvals-and-sandbox` inside Docker, on the
  repo bind-mounted at `/workspace`. Nothing else on the host is mounted. Git
  auth is a scoped, revocable GitHub token — never an SSH key.

The part that matters is that the outer agent's restraint is not a promise.
`tools/sandbox/outer-gate.sh` (Bash) and `tools/sandbox/outer-write-gate.sh`
(Edit/Write) run as PreToolUse hooks and deny by default. No `git`, no `gh`, no
`pnpm`/`npm`/`node`/`make`/`python`, no `rm`/`mv`, no editing repo files, no
`curl` off loopback. A prompt asking an agent to always dispatch holds until a
plausible little command shows up — just checking the branch, just a quick
install — and then it doesn't. A hook keeps holding. Run `./sandbox test` to
see the gate cases for yourself.

## Quick start

```bash
./sandbox doctor                       # check the host first
./sandbox "run the test suite and tell me what fails"
./sandbox -c "fix the first failure, then re-run the tests"
./sandbox tail -f                      # watch it work in another pane
./sandbox result                       # re-read the last answer
```

The inner agent gets exactly one message and cannot ask a follow-up question,
so send the whole task: what to change and where, what "done" means, the literal
command that proves it, and whether to commit. A dispatch built on a guess costs
a full run to discover it was wrong.

A long message is safer on stdin than as an argument, where quoting will bite
you:

```bash
printf '%s' "$LONG_PROMPT" | ./sandbox
```

## Commands

| Command | Does |
| --- | --- |
| `./sandbox "task"` | Dispatch. Starts the container if needed, prints the inner agent's answer. |
| `./sandbox -c "task"` | Dispatch continuing the previous thread. |
| `./sandbox -a claude\|codex "task"` | Dispatch to a specific inner agent for this run. |
| `./sandbox result` | Re-read the last answer without spending a run. |
| `./sandbox tail` | Last 40 steps of the current run. |
| `./sandbox tail -f` | Follow the run until it ends. |
| `./sandbox up` | Start the container, sync credentials, start the hot-reload bridge. |
| `./sandbox status` | Container state, published ports, bridge, whether a run is live. |
| `./sandbox doctor` | Check the host and name the fix for each problem. Changes nothing. |
| `./sandbox run <cmd>` | Run one command inside the container. |
| `./sandbox shell` | Interactive shell inside the container. |
| `./sandbox rebuild` | Force an image rebuild. |
| `./sandbox stop` | Stop the container. Cache, credentials, and volumes survive. |
| `./sandbox test` | Run the PreToolUse gate test suite. |
| `./sandbox update` | Pull a newer harness from this repo into the project. |
| `./sandbox help` | The same list, from the script itself. |

Anything that isn't one of those verbs is treated as a message for the inner
agent, so `./sandbox "add a health check endpoint"` just works.

Which inner agent runs is auto-detected from the client you're typing into: a
Codex outer gets a Codex inner, a Claude outer gets a Claude inner. `-a`
overrides one run; `SANDBOX_DEFAULT_AGENT` in `sandbox.conf` overrides the
default.

## Requirements

macOS, `jq`, and a Docker daemon. `curl` and `tar` are needed only for the
one-line install above, which fetches a tarball; installing from a local
checkout skips both.

The target does **not** have to be a git repo, and `git` does not have to be on
the host. Install still writes a `.gitignore` covering
`tools/sandbox/.cache/` and `tools/sandbox/sandbox.local.conf`, so if you run
`git init` later the credentials are already excluded. Host `git` only comes up
when you want commits from inside the container to carry your name and a `gh`
token to push with.

About the Docker daemon: Colima is what this is tuned for — `boot.sh` starts it
with `--vm-type vz --mount-type virtiofs`, which is what makes the bind mount
fast enough to work in:

```bash
brew install colima docker jq
```

Docker Desktop works too; the socket path in `sandbox.conf` is already correct
for both. If you use Docker Desktop, Colima is not required and `doctor` will
warn rather than fail.

You also need a working agent login on the host — `claude` or `codex login` —
and `gh auth login` if the inner agent should push. `./sandbox doctor` reports
each of these and tells you the exact command to fix it; it only FAILs on what
actually blocks a run, and warns about the rest.

## Configuration

Everything project-specific lives in `tools/sandbox/sandbox.conf`. It is plain
shell, it is commented, and it is the one file in `tools/sandbox/` that an
install will preserve rather than replace:

- `SANDBOX_PROJECT` — names the container, image, and volumes.
- `SANDBOX_PORTS` — published ports, in `HOST:CONTAINER` or `IP:HOST:CONTAINER`
  form. The host number is a preference: if it is already taken, boot publishes
  the next free one up and says so. The container port never moves.
- `SANDBOX_VOLUME_DIRS` — directories that must be container-private named
  volumes instead of the bind mount. `node_modules` belongs here because the
  Mac's tree is darwin-arm64 and the container needs linux-arm64; build caches
  belong here because thousands of small writes over virtiofs are slow.
- `SANDBOX_WATCH_DIRS` — source roots the hot-reload bridge watches. Keep them
  tight; the bridge polls.
- `SANDBOX_DEFAULT_AGENT`, and pinned toolchain versions for the image.

For anything machine-specific that must not be committed — a pinned port, a
different daemon socket — create
`tools/sandbox/sandbox.local.conf`. It is sourced last and the installer adds it
to `.gitignore`, along with `tools/sandbox/.cache/`, which holds live OAuth and
GitHub tokens and must never be read out, printed, or committed.

Ports, mounts, and volumes are fixed when the container is created. `./sandbox
up` notices the drift after a config change and recreates the container; if it
somehow doesn't, `./sandbox rebuild`.

## Upgrading an installed project

```bash
./sandbox update
```

That fetches this repo at the ref the project was installed from and runs
`install.sh` against the project again — same script, same rules, so there is
only one definition of which files are preserved. `tools/sandbox/` and
`./sandbox` are replaced; `sandbox.conf`, `sandbox.local.conf`, `AGENTS.md` and
`CLAUDE.md` are kept, with the incoming defaults left beside your config as
`sandbox.conf.new`. The hooks are re-merged into `.claude/settings.json` without
disturbing any other hook you have, and the changed files are listed at the end.

Every install writes `tools/sandbox/ORIGIN.md` — the repo, the ref, and the
commit it came from. That is what `update` reads, so a fork is upgraded from the
fork: `./sandbox update --repo you/sandbox --ref main` once, and the file
remembers. `--from ../sandbox` updates from a local checkout instead of the
network.

Once a day `./sandbox up` asks GitHub whether the harness has moved, in the
background, and prints one line if it has. Nothing is ever changed for you —
the line just names the command. `SANDBOX_UPDATE_CHECK="0"` in `sandbox.conf`
turns it off, and so does `SANDBOX_UPDATE_CHECK=0` in the environment.
`./sandbox doctor` reports the same thing on demand.

## Docs

- [docs/colima.md](docs/colima.md) — the VM, why `vz` + `virtiofs`, and what to
  do when the daemon isn't reachable.
- [docs/credentials.md](docs/credentials.md) — how agent logins and the GitHub
  token get into the container, and what is deliberately never mounted.
- [docs/hot-reload.md](docs/hot-reload.md) — why saving a file on the Mac
  reloads inside the container, and why you should not add a polling watcher.
- [docs/agents.md](docs/agents.md) — the two-agent split, the gates, and how to
  write a dispatch that comes back done.
- [docs/configuration.md](docs/configuration.md) — every `sandbox.conf` setting,
  what it affects, and when a change needs a rebuild.

## License

MIT. See [LICENSE](LICENSE).
