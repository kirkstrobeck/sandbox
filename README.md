# sandbox

Run your coding agent with permissions turned off, inside a container, without
handing it your Mac.

> ## ⚠️ CAUTION — USE AT YOUR OWN RISK
>
> Permission checks are off on purpose. The container keeps that work off your
> Mac by default; it is **not** a hardened isolation product and it will not
> contain an agent that is trying to get out.
>
> Provided **AS IS**, with no warranty of safety or fitness — see
> [LICENSE](LICENSE). Full threat model, what crosses the boundary, and the
> residual risks: [docs/security.md](docs/security.md).

## Quick install

Open your project and give this instruction to your agent

```
Install and use https://github.com/kirkstrobeck/sandbox in this project
```

Then just use prompts as you normally would and sandbox will take over

## Two agents

The **outer agent** runs in your terminal, talks to you, and does no work. The
**inner agent** runs inside Docker with permission checks off, on the repo
bind-mounted at `/workspace`. Nothing else on the host is mounted, and git auth
is a scoped, revocable GitHub token — never an SSH key.

In Claude Code that split is enforced: two `PreToolUse` hooks deny `git`, `gh`,
package managers, `rm`, repo edits and non-loopback `curl` on the host. Codex
and Cursor have no equivalent hook mechanism, so there the boundary is the rule
in `AGENTS.md` plus your attention — details in [docs/agents.md](docs/agents.md).

### The inner agent matches the outer one

| You are typing into | What runs inside |
| --- | --- |
| Claude Code | Claude Code |
| Codex | Codex |
| Cursor | Cursor |

Same product. A Codex outer writing a dispatch for a Claude inner means the
agent that wrote it and the agent that reads it disagree about their own
conventions.

Detection reads what the outer client leaves in the environment, in this order:
`SANDBOX_AGENT` → Codex (`CODEX_*`, `TERM_PROGRAM=codex`) → Claude
(`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`) → Cursor (`CURSOR_AGENT`,
`CURSOR_TRACE_ID`) → `SANDBOX_DEFAULT_AGENT`. Override one run with
`./sandbox -a cursor "task"`.

### Manager inside, workers under it

**Not the same model.** What a dispatch starts is a *manager*: it writes a short
spec, spawns cheaper *workers* to make the edits and run the tests, reviews what
comes back, and answers. The expensive tokens go on judgement, not on typing.
Tokens build scripts; only scripts do the work; those scripts stay in the repo.

The manager model is `SANDBOX_MODEL` (`./sandbox -m <id>`, one run), else the
daily snapshot's `<agent>_manager=` line, else `SANDBOX_DEFAULT_MODEL`, else a
high-value default per agent. The snapshot is model/plan/promo text the host
fetches at most once a day into `$TMPDIR/sandbox-model-daily` and passes in as
an environment variable — read first, shared by every sandbox on the machine,
and never mounted into the container. Details in
[docs/agents.md](docs/agents.md).

## Install

Per-project. Run it from the project's root; each project gets its own copy of
the harness, its own container, and its own `sandbox.conf`. An empty folder is a
fine target — a git repo is not required, and the directory is created if it
doesn't exist.

```
curl -fsSL https://raw.githubusercontent.com/kirkstrobeck/sandbox/main/install.sh | bash
```

Then:

```bash
./sandbox doctor                       # checks the host, names every fix
./sandbox "run the tests and tell me what fails"
```

Restart your agent client afterward so it picks up the new PreToolUse hooks.

**`tools/sandbox/` is harness-owned.** Put project scripts in `tools/`, not
`tools/sandbox/`. An install or update may delete anything else in that
directory. `tools/sandbox/MANIFEST` is the full ownership list.

To upgrade that project later:

```bash
./sandbox update
```

`tools/sandbox/MANIFEST` lists every path an install owns. `update` applies the
new one and removes what the harness stopped shipping; your `sandbox.conf`,
`sandbox.local.conf` and `.cache/` are never touched.

## Commands

| Command | Does |
| --- | --- |
| `./sandbox "task"` | Dispatch. Starts the container if needed, prints the answer. |
| `./sandbox -c "task"` | Continue the previous thread. |
| `./sandbox -a claude\|codex\|cursor "task"` | Pick the inner agent for one run. |
| `./sandbox -m <model-id> "task"` | Pin the inner manager's model for one run. |
| `./sandbox --file <path>` | Long message from a file (pipes are denied by the gate). |
| `./sandbox result` | Re-read the last answer without spending a run. |
| `./sandbox tail [-f]` | Watch the run. |
| `./sandbox up` \| `status` \| `stop` \| `rebuild` | Container lifecycle. |
| `./sandbox run <cmd>` \| `shell` | Run one command, or get a shell, inside it. |
| `./sandbox doctor` | Check the host. Changes nothing. |
| `./sandbox test` | Gate and manifest test suite. |
| `./sandbox bench` | Time a canonical dispatch (writes `foo.md`) and print ms. |
| `./sandbox update` | Pull a newer harness into this project. |

A single bare token that is not a known verb is an error, not a task — `./sandbox
down` exits 2 with `unknown verb: down` (the verb is `stop`). To send something
as a dispatch, quote it: `./sandbox "down the service"`.

For long prompts, write to a file and use `--file`. Piping directly to
`./sandbox` is denied by the outer gate: `printf '%s' "$LONG" | ./sandbox` will
be blocked.

## Requirements

macOS, `jq`, and a Docker daemon — Colima is what this is tuned for
(`brew install colima docker jq`), Docker Desktop works too. `curl` and `tar`
are needed only by the one-line install.

You also need a login for whichever agent runs inside: `claude`, `codex login`,
or `agent login` / `CURSOR_API_KEY`. Add `gh auth login` if the inner agent
should push. `./sandbox doctor` reports each one and prints the exact fix.

## Secrets

Do not let the outer agent read secrets on the host — anything it reads ends up
in a transcript. If the inner agent needs a credential (an API key, a service
token), use `SANDBOX_EXTRA_MOUNTS` in `sandbox.conf` to mount a secrets
directory read-only into the container:

```bash
SANDBOX_EXTRA_MOUNTS="
/path/to/my-secrets:/secrets:ro
"
```

A grant that lives in the container dies with it. The host path never appears in
any transcript. See [docs/configuration.md](docs/configuration.md) for details.

## Docs

- [docs/agents.md](docs/agents.md) — the two-agent split, the gates, which agent
  and model run inside, and how to write a dispatch that comes back done.
- [docs/credentials.md](docs/credentials.md) — how each login and the GitHub
  token get into the container, and what is deliberately never mounted.
- [docs/configuration.md](docs/configuration.md) — every `sandbox.conf` setting,
  the install manifest, and when a change needs a rebuild.
- [docs/colima.md](docs/colima.md) — the VM, why `vz` + `virtiofs`, and what to
  do when the daemon isn't reachable.
- [docs/hot-reload.md](docs/hot-reload.md) — why saving a file on the Mac
  reloads inside the container.
- [docs/security.md](docs/security.md) — threat model, what crosses the trust
  boundary, residual risks, and keeping guardrails aligned with capability.

## License

MIT. See [LICENSE](LICENSE).
