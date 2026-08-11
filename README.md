# sandbox

Run your coding agent with permissions turned off, inside a container, without
handing it your Mac.

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

Same product, and the same model where it can be read. Two halves of one task
should not be a tier apart, and a Codex outer writing a dispatch for a Claude
inner means the agent that wrote it and the agent that reads it disagree about
their own conventions.

Detection reads what the outer client leaves in the environment, in this order:
`SANDBOX_AGENT` → Codex (`CODEX_*`, `TERM_PROGRAM=codex`) → Claude
(`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`) → Cursor (`CURSOR_AGENT`,
`CURSOR_TRACE_ID`) → `SANDBOX_DEFAULT_AGENT`. Override one run with
`./sandbox -a cursor "task"`.

The model comes from `SANDBOX_MODEL`, else the outer client's own setting
(`ANTHROPIC_MODEL`, `CODEX_MODEL` or `~/.codex/config.toml`, `CURSOR_MODEL` or
Cursor's `cli-config.json`), else `SANDBOX_DEFAULT_MODEL`. **If none of those
says anything, no model flag is passed and the inner CLI uses its own default** —
guessing an id would pin a model nobody asked for. `./sandbox -m <id>` overrides
one run.

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
| `./sandbox -m <model-id> "task"` | Pick the inner model for one run. |
| `./sandbox result` | Re-read the last answer without spending a run. |
| `./sandbox tail [-f]` | Watch the run. |
| `./sandbox up` \| `status` \| `stop` \| `rebuild` | Container lifecycle. |
| `./sandbox run <cmd>` \| `shell` | Run one command, or get a shell, inside it. |
| `./sandbox doctor` | Check the host. Changes nothing. |
| `./sandbox test` | Gate and manifest test suite. |
| `./sandbox update` | Pull a newer harness into this project. |

Anything that isn't a verb is treated as a message for the inner agent. For a
long prompt, stdin beats an argument: `printf '%s' "$LONG" | ./sandbox`.

## Requirements

macOS, `jq`, and a Docker daemon — Colima is what this is tuned for
(`brew install colima docker jq`), Docker Desktop works too. `curl` and `tar`
are needed only by the one-line install.

You also need a login for whichever agent runs inside: `claude`, `codex login`,
or `agent login` / `CURSOR_API_KEY`. Add `gh auth login` if the inner agent
should push. `./sandbox doctor` reports each one and prints the exact fix.

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

## License

MIT. See [LICENSE](LICENSE).
