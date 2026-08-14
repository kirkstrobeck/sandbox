# Security

> ## ⚠️ CAUTION — USE AT YOUR OWN RISK
>
> This project runs a coding agent with permission checks turned off. It is a
> way to keep that work off your Mac by default. It is **not** a hardened
> isolation product, and it does not claim you cannot break things if you try.
>
> The software and these docs are provided **AS IS**, with no warranty of
> safety, security, fitness, or completeness. See [LICENSE](../LICENSE) for the
> warranty disclaimer and limitation of liability.

These are operator notes: what the harness mounts, what it enforces, what it
does not, and how to keep the guardrails growing along with the risk. They are
threat-model documentation for this project — not legal advice, and not a
professional security assessment.

## What this is for

The workflow this is built around is: **you already trust the agent, and you
want the high-privilege parts of its work to happen somewhere that is not your
laptop.** Permission prompts get turned off because answering them one at a
time does not scale; the container is what makes that trade tolerable, by
keeping the Mac out of the default blast radius.

| Fits | Does not fit |
| --- | --- |
| An agent you trust, doing work you asked for, on one repo | Running hostile or unreviewed third-party code |
| Reducing what a careless or confused agent can reach on the host | Containing an agent that is actively trying to escape |
| Making the boundary mechanical instead of a promise in a prompt | A substitute for gVisor, Firecracker, or a disposable VM |
| Keeping build junk, installs, and dependency trees off the Mac | A substitute for CI review or properly scoped secrets |

Docker containers share the host kernel. Colima puts a VM between the container
and macOS, which helps, but the design goal here is *reduced blast radius*, not
*containment of an adversary*. If your threat model includes untrusted code, use
something built for that instead.

## The trust boundary

There are two agents. The **outer agent** runs on your Mac in your terminal, in
your shell, with your files. The **inner agent** runs inside the container, on
the repo bind-mounted at `/workspace`, with permission checks disabled. The
whole design is that the outer agent relays and the inner agent works — see
[docs/agents.md](agents.md).

Everything the inner agent can reach is decided by what crosses that boundary.
The mount layout is deliberately kept in one readable file,
[`tools/sandbox/run-args.sh`](../tools/sandbox/run-args.sh).

| What crosses | Where it comes from | Mode | Why it matters |
| --- | --- | --- | --- |
| The repo | `$REPO_ROOT` → `/workspace` **and** → its literal host path | read-write | The inner agent can change or delete anything in your working tree, including `.git/`. The second mount exists so paths handed to the Docker daemon resolve; it is the same worktree. |
| Claude credential | `.cache/claude-home` → `/home/agent/.claude` | read-write | A live Anthropic OAuth token. |
| Codex credential | `.cache/codex-home` → `/home/agent/.codex` | read-write | A live OpenAI token. |
| Cursor credential | `.cache/cursor-home` → `/home/agent/.config/cursor` | read-write | A live Cursor token or API key. |
| GitHub token | `.cache/gh` → `/home/agent/.config/gh` | read-write | Whatever your `gh` login can do, including push. |
| Claude config | `.cache/claude.json` → `/home/agent/.claude.json` | read-write | Client state, not a credential. |
| Docker socket | `SANDBOX_DOCKER_SOCK` (default `/var/run/docker.sock`) → `/var/run/docker.sock` | read-write | **Mounted whenever the daemon answers `docker info`.** See below. |
| Published ports | `SANDBOX_PORTS`, default `127.0.0.1:3000:3000` | — | The address half decides who on your network can reach the container. |
| Build/dep dirs | Named volumes over `SANDBOX_VOLUME_DIRS` | read-write | Container-private; they shadow the bind mount, so writes there do not reach the Mac. |
| Daily model snapshot | `$TMPDIR/sandbox-model-daily` on the host → `SANDBOX_MODEL_DAILY` environment variable | **not a mount** — text only, one way in | A few KB of public product-page text so the inner manager can pick a worker model without a web search. **The inner agent does not see that path**, or any of `$TMPDIR`. It holds no credentials and nothing project-specific. |
| Linked worktree git common dir | When `.git` is a pointer file, the common dir (`parent/.git`) is mounted at its literal host path | read-write | Same trust level as the worktree itself; required for git to work inside a linked worktree. The mount is detected from the pointer file — never from a `git` command. |
| `SANDBOX_EXTRA_MOUNTS` | Whatever the project lists in `sandbox.conf` | as declared (`rw` or `ro`) | Explicit project capability. Listed in `sandbox.conf`, so the fingerprint recreates the container on change and `./sandbox doctor` can report them. |
| `SANDBOX_EXTRA_ENV` | Key=value pairs listed in `sandbox.conf` | env variable only — not a mount | Passes project-specific configuration into the container without creating a filesystem path. Same clobber rule as extra mounts: append, do not reassign. |

What is **not** mounted: your home directory, your SSH keys, your other repos,
your shell history, your cloud credentials, and your `$TMPDIR`. Nothing under
`~/.ssh` is ever touched — see [docs/credentials.md](credentials.md) for why a
revocable token is the deliberate choice over a key.

**The daily snapshot is a host-side write, not an inner capability.** The host
harness fetches it (`tools/sandbox/model-daily.sh`), the host harness owns the
file, and only the resulting text crosses into the run as an environment
variable — the same shape as the update-check stamp in `.cache/`. Mounting that
path to save the copy would hand the inner agent a writable host location
outside the repo in exchange for nothing. If a future change adds such a mount,
the design has been lost, not optimized.

**The Docker socket is not optional in the current code.** `sandbox_mount_args`
mounts it if `docker info` succeeds; `SANDBOX_DOCKER_SOCK` changes *which*
socket, not *whether*. Treat that as the highest-capability thing on the list:
an agent with the daemon socket can start a container that mounts `/` from the
VM, so socket access is effectively daemon-level control of everything that
daemon can reach.

The container itself runs as an unprivileged `agent` user matching your host
UID/GID, with no `--privileged`, no added capabilities, and no host networking.
Outbound network access is unrestricted.

## Aligned risk and guardrails

The rule this project is organized around:

> **Do not increase capability without adding a matching control.**

Each row below adds reach. Adding one is fine — adding one without its control
is how a setup drifts from "reasonably safer" to "permissions are off and
nothing is watching."

| Capability you add | What it buys | Control that has to come with it |
| --- | --- | --- |
| Claude Code as the outer agent | Mechanical enforcement of the relay boundary | Keep the `PreToolUse` hooks wired; run `./sandbox test` after any gate edit |
| Codex or Cursor as the outer agent | Same inner agent, matching client | **No hook mechanism exists** — the boundary is `AGENTS.md` plus your attention. Read the diffs; assume the outer agent can act on the host |
| A bridged GitHub token | `git push` from inside | Short-lived and scoped; review the diff before you approve a push; revoke when done |
| No GitHub token at all | Lowest footprint; everything but push still works | None needed — this is the safe default if the agent should not publish |
| Docker socket (current default when a daemon answers) | Sibling containers: databases, test services | Understand it as daemon control. Only run this pointed at a daemon you would hand over anyway; prefer a project-scoped Colima VM over a daemon shared with production tooling |
| Ports on `127.0.0.1` | Browser on your Mac reaches the dev server | None needed — this is the default |
| Ports on `0.0.0.0` or a LAN address | Phone or coworker reaches the dev server | Trust the network you are on. Anything the agent starts is now reachable by everyone on it |
| Extra mounts (`SANDBOX_EXTRA_MOUNTS`) | Inner agent reaches additional host paths (secrets dirs, shared caches) | Listed in `sandbox.conf`; fingerprint recreates container on change; `./sandbox doctor` reports them; prefer `ro` for secrets |
| Dispatching text you did not write (issue bodies, PR comments, scraped pages) | Automation | Treat it as untrusted input, because it is. Do not do this with a push token bridged. See prompt injection below |
| Unattended or scheduled runs | Throughput | Everything above compounds: no human is reading the diff, so the token scope *is* the control |
| A daily snapshot file in your `$TMPDIR` | The inner manager picks a cheap worker model without spending a web search on it | Host-side only. It stays out of the mount list, it holds public text and no credentials, and it is `chmod 600`. Passing it in as an environment variable is the control — mounting it would trade a real boundary for a copy |

Reading the table one way: the lowest-footprint setup is Claude Code outside
with both gates wired, no GitHub token bridged, ports on loopback, a daemon you
do not care about, and a human reading every diff before it goes anywhere. The
highest-footprint setup is a Cursor or Codex outer agent with policy-only
enforcement, a long-lived push token, LAN-bound ports, and dispatches built from
text somebody else wrote. Both are things you can do with this repo. Only one of
them is defensible without adding controls that are not in the box.

## What the harness already does

| Control | Where | What it actually does |
| --- | --- | --- |
| Bash gate | [`tools/sandbox/outer-gate.sh`](../tools/sandbox/outer-gate.sh) | `PreToolUse` hook, **default deny**. Blocks `git`/`gh`, package managers and runtimes, `rm`/`mv`/`chmod`, `ssh`/`wget`/`nc`, and any `curl` to a non-loopback URL. Command chaining is detected on a skeleton, not the raw string |
| Write gate | [`tools/sandbox/outer-write-gate.sh`](../tools/sandbox/outer-write-gate.sh) | `PreToolUse` hook on `Edit`/`Write`/`MultiEdit`/`NotebookEdit`, **default deny**. Only `.claude/`, `.cursor/`, `tools/sandbox/`, `sandbox`, `AGENTS.md`, `CLAUDE.md` are writable on the host. Paths are normalized lexically and symlinked leaves are followed, so `.claude/../src/app.ts` does not sneak through |
| Gate tests | `./sandbox test` → [`gate-test.sh`](../tools/sandbox/gate-test.sh) | Asserts each allow/deny decision, so an edit to a gate fails loudly instead of quietly widening it |
| No SSH key | [`github-token-sync.sh`](../tools/sandbox/github-token-sync.sh) | Nothing under `~/.ssh` is read or mounted. Git auth is a GitHub token — revocable from the GitHub UI, scoped, and expiring |
| Token never printed | same | The token travels host env → variable → file descriptor. The success line names the login, not the token |
| Credential cache gitignored | `.gitignore`, [`doctor.sh`](../tools/sandbox/doctor.sh) | `tools/sandbox/.cache/` is ignored, and `./sandbox doctor` **fails** — not warns — if that line is missing |
| Cache stripped on install | [`install.sh`](../install.sh) | `.cache/` is deleted from the source tree when installing elsewhere, so a credential cannot ride along |
| Two-way OAuth sync | [`token-sync.sh`](../tools/sandbox/token-sync.sh), [`codex-token-sync.sh`](../tools/sandbox/codex-token-sync.sh) | Push back to the Mac only when the container's copy is strictly newer, so a rotated refresh token does not log you out. Writes are `mktemp` + `chmod 600` + `mv` |
| Separate credential homes | mount layout | Anthropic, OpenAI and Cursor tokens live in different directories, so a mount that needs one does not carry all three |
| `.git/config` left alone | `entrypoint.sh` | Container git settings go in `~/.gitconfig`. `.git/config` is inside the bind mount and is the Mac's file |
| Loopback ports by default | `sandbox.conf` | `SANDBOX_PORTS="127.0.0.1:3000:3000"` |
| Daily snapshot stays host-side | [`model-daily.sh`](../tools/sandbox/model-daily.sh) | Written on the host, `chmod 600`, `mktemp` + `mv`, no history, no credentials in it. It is **not** in `run-args.sh` — the text crosses as one environment variable and the path does not cross at all |
| Hook wiring check | `./sandbox doctor` | Warns when `.claude/settings.json` does not reference `outer-gate.sh` — i.e. when the outer agent can still act on the host |

Details: [docs/agents.md](agents.md) for the gates and the client-by-client
enforcement story, [docs/credentials.md](credentials.md) for every credential
and how it travels, [docs/configuration.md](configuration.md) for every setting
that changes the shape of any of this.

## Known residual risks

Honest list. None of these are bugs to be fixed by reading the doc harder; they
are the cost of the design. Keep it current as the harness changes.

| Risk | Why it exists | What reduces it |
| --- | --- | --- |
| **Docker socket = daemon control** | Mounted whenever the daemon answers, so sibling containers work | Use a Colima VM dedicated to this work. Do not point it at a daemon that also runs anything you care about |
| **The worktree is read-write** | The inner agent has to be able to do the work | Commit often; review diffs; the Mac's copy and the container's copy are the same files, including `.git/` |
| **Live tokens inside a container with open egress** | The agent needs its own credentials to run at all | Short-lived scoped tokens; no push token when push is not needed; rotate after anything odd |
| **Two-way OAuth sync writes to the host** | Refresh tokens rotate; one-way copy would log you out | It is a real host-write path from container state. It is narrow (credential files and one Keychain entry) but it is not nothing |
| **Outer enforcement is uneven** | Only Claude Code has `PreToolUse` hooks. Codex and Cursor have policy files and nothing that stops a call | Prefer Claude Code outside when the boundary needs to be mechanical |
| **Outer gates cover writes and Bash, not reads** | The `Read` tool is not gated, and the Bash allowlist permits `cat tools/sandbox/*` | That path reaches `tools/sandbox/.cache/`. Never ask an agent to read or "check" a credential — it will put it in a transcript |
| **Allowlist bypass class** | Any allowlist over a shell is approximate. Argument-level tricks under a permitted first token are the standing weakness | Keep the allowlist small; re-run `./sandbox test` after every gate change; treat a new allowed verb as a security change |
| **Prompt injection / confused deputy** | The agent reads repo files, web pages, issues, and CI output, and it holds a push token | Do not dispatch untrusted text with a token bridged. Review before push. The container is the blast radius, not the filter |
| **Supply chain** | Install is `curl … \| bash`; `./sandbox update` refetches the harness from GitHub, and `SANDBOX_REF` defaults to `main` | Read `install.sh` before running it. Pin `SANDBOX_REF` to a tag or commit. `tools/sandbox/ORIGIN.md` records repo, ref and commit; `update` produces a reviewable diff |
| **`.cache/` is a file on disk** | Credentials have to be somewhere the daemon can mount | It is inside your project directory, so Time Machine, Dropbox, and any folder sync will happily copy it. Check what backs up your repos |
| **Container is not a security boundary against a determined agent** | Shared kernel, mounted socket, mounted worktree | Nothing in this repo. This is the premise: you trust the agent |

## Operator practices

Ordered roughly by how much they buy you.

- **Review the diff before anything is pushed.** The single highest-value habit.
  The inner agent commits; you decide what leaves the machine.
- **Do not bridge a GitHub token unless the agent needs to push.** `boot.sh`
  warns and carries on; everything else still works.
- **When you do bridge one, make it short-lived and scoped** to the repos it
  needs. Fine-grained tokens over classic ones, always.
- **Prefer Claude Code as the outer agent when enforcement matters.** Codex and
  Cursor are honored rules, not hooks.
- **Keep `SANDBOX_PORTS` on `127.0.0.1`** unless you have a reason and know the
  network you are on.
- **Point Docker at a VM you would not mind losing.** Socket access is the
  largest capability in the setup.
- **Pin the update ref.** Set `SANDBOX_REF` to a tag or commit, and read the
  `./sandbox update` diff before committing it.
- **Never ask an agent to print, check, or debug a credential.** Use
  `token-sync.sh status`, which prints timestamps and field names, never values.
- **Rotate after anything suspicious** — an odd run, a leaked transcript, a repo
  you did not mean to give it. Revoke the GitHub token first, then re-login the
  agent clients.
- **Run `./sandbox test` after touching a gate**, and `./sandbox doctor` when
  anything about the host changes. `doctor` fails on an ungitignored `.cache`.
- **Reset means more than stopping.** `docker rm -f` plus removing
  `tools/sandbox/.cache/`; stopping the container is a pause and keeps the
  cache.

## Keeping this document current

This doc is only useful if it describes the harness that exists. It goes stale
the moment capability grows without the tables growing.

**If your change does any of these, update this file in the same change:**

- [ ] Adds, removes, or changes a **mount** (`run-args.sh`) → update the trust
      boundary table, and the residual-risk list if it widens reach
- [ ] Adds or changes a **credential** that crosses the boundary → update the
      boundary table here and the table in [docs/credentials.md](credentials.md)
- [ ] Mounts a **socket** or device, or changes `SANDBOX_DOCKER_SOCK` semantics
      → update the boundary table and the risk-alignment table
- [ ] Changes **port defaults** or the bind address → update the boundary and
      alignment tables
- [ ] Adds support for another **outer agent client** → say plainly whether the
      boundary is enforced or advisory, and add the row to the alignment table
- [ ] Changes a **gate** (`outer-gate.sh`, `outer-write-gate.sh`, `hooks.json`)
      → update the controls table, add cases to `gate-test.sh`, and re-run
      `./sandbox test`
- [ ] Changes **install or update** fetching → revisit the supply-chain row
- [ ] Adds a **host-side file the harness writes or fetches** outside the
      project (the update-check stamp, the daily model snapshot) → say where it
      lives, what is in it, and that it is not mounted. If you find yourself
      mounting one to make it easier to read, stop: the text can be passed in
      as an environment variable, and that is why these are not capabilities
- [ ] Removes a control → delete the row here rather than leaving a control
      documented that no longer runs

A capability added without its row in the alignment table, or a control removed
without its row deleted here, is the failure mode this checklist exists to
prevent.

## Related docs

- [docs/agents.md](agents.md) — the two-agent split, the gates, and what
  enforcement each client actually has
- [docs/credentials.md](credentials.md) — every credential, how it crosses, and
  what is deliberately never mounted
- [docs/configuration.md](configuration.md) — every setting, including ports,
  volumes, and the Docker socket
- [docs/colima.md](colima.md) — the VM the daemon runs in
- [docs/hot-reload.md](hot-reload.md) — the save bridge, and why no polling
  watcher is needed
- [AGENTS.md](../AGENTS.md) — the rules the outer agent runs under
- [LICENSE](../LICENSE) — MIT. AS IS, no warranty. Use at your own risk
