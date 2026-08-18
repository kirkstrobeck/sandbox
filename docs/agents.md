# Agents

Two agents, and a container between them. The outer agent runs on your Mac,
talks to you, and does no work. The inner agent runs inside Docker with
permissions turned off and does all of it.

All three clients — Claude Code, Codex, Cursor — work on both sides of that
boundary. What differs between them is enforcement, and the difference is real:
one of the three has none.

## The boundary, and what actually holds it

The outer agent is told not to touch the host: no `git`, no `gh`, no
`pnpm`/`npm`/`node`/`make`/`python`, no `rm`/`mv`, no editing project files, no
`curl` off loopback. That instruction lives in `AGENTS.md`.

An instruction is not a control. It holds for a while, and then a plausible
little command shows up — just checking the branch, just a quick install — and
the boundary is gone with nothing to stop it. So in Claude Code the same rule is
also a pair of hooks, and hooks are the only version that survives a persuasive
moment.

## Claude Code: enforced

`install.sh` merges `tools/sandbox/hooks.json` into `.claude/settings.json`,
wiring two `PreToolUse` hooks:

| Matcher | Hook |
| --- | --- |
| `Bash` | `tools/sandbox/outer-gate.sh` |
| `Edit\|Write\|MultiEdit\|NotebookEdit` | `tools/sandbox/outer-write-gate.sh` |

**`outer-gate.sh` denies by default.** Named denials come first, so the reason
explains the actual rule rather than refusing generically — version control
belongs to the inner agent because that is where the bridged GitHub token is;
toolchain commands run against the container's dependency tree, not the Mac's.
The allowlist is deliberately small: the `./sandbox` CLI and the harness scripts,
read-only `docker`/`colima` introspection, lifecycle verbs scoped to a container
whose name contains `sandbox`, reading files under `.claude/`, `tools/sandbox/`,
`AGENTS.md` and `README.md`, a short list of harmless first tokens (`pwd`,
`echo`, `jq`, `lsof`, `uname`…), and `curl` when every URL in the command is
loopback — that last one exists so the outer agent can check whether the dev
server the container published is answering.

Anything chained is denied even if the first command is allowed. The chaining
check runs against a skeleton produced by `skeleton.awk`, never the raw string,
and falls back to the raw text when the skeleton cannot be produced — erring
toward "chained", and therefore toward denying. Leading `VAR=value` assignments
are stripped first, so `FOO=1 git push` is judged as `git push`.

**`outer-write-gate.sh` exists because blocking Bash is only half the
boundary.** An outer agent denied every shell path into the repo will reach for
the Edit tool instead — no hook, no prompt, a source file on the Mac quietly
hand-edited. It denies every path except the two the outer agent legitimately
owns: its own Claude Code state, and this harness (`.claude/`, `.cursor/`,
`tools/sandbox/`, and exactly `sandbox`, `AGENTS.md`, `CLAUDE.md`). Paths are
normalized lexically *before* touching the filesystem, so
`.claude/../src/app.ts` cannot resolve through an allowed prefix; symlinked
leaves are followed, bounded at 8 hops; and a tool call whose file path cannot
be read at all is denied, because that is the safe way for this gate to be
wrong.

Both gates no-op inside the container (`gate_bypass_if_inner`, keyed on the
`SANDBOX_INNER=1` that `entrypoint.sh` exports) — the inner agent is already
inside the boundary.

Run `./sandbox test` to execute the gate test suite. These gates are the only
mechanical thing keeping the outer agent off the host, so "it looked right" is
not good enough after an edit.

If you get a denial, you have not found an obstacle. You have found the design.
Dispatch instead.

## Codex: instructed, not enforced

Codex reads `AGENTS.md` at the repo root, which is why the outer-agent rules
live in that file rather than somewhere Claude-specific. It has no `PreToolUse`
hook mechanism, so **nothing stops a Codex outer agent from running a command on
the host.** The boundary there is the instruction plus your attention.

Codex also has no `--continue`. It resumes an explicit thread id, so
`dispatch-codex.sh` persists one: after each run it reads the `thread.started`
event out of the JSONL log and writes the id to
`tools/sandbox/.cache/codex-thread`. The next `./sandbox -c` reads it back and
runs `codex exec resume <thread-id>` instead of a bare `codex exec` — which is
what makes `-c` mean the same thing for both agents even though only one of them
has the flag.

The inner Codex invocation is:

```bash
codex exec [resume <thread-id>] --dangerously-bypass-approvals-and-sandbox \
  --json --output-last-message "$OUT_FILE" "$msg"
```

Because Codex streams JSONL as it goes, `./sandbox tail -f` shows real
step-by-step progress for a Codex run. Claude's `-p --output-format json` writes
one object at the end, so for Claude the honest live signal is the process
itself. If `--output-last-message` comes back empty — the run died early — the
dispatcher falls back to the last `agent_message` in the JSONL stream rather
than reporting nothing.

## Cursor: a full inner agent, an outer one with no enforcement

Two separate things, and it is worth not blurring them.

**Inside**, Cursor is first-class. The CLI is in the image, its credential is
bridged like the other two, and `dispatch-cursor.sh` drives it exactly the way
the Codex backend drives Codex. `./sandbox -a cursor "task"` works, and a Cursor
outer agent gets one by default.

**Outside**, Cursor reads `.cursor/rules/sandbox.mdc` (installed with
`alwaysApply: true`) and enforces the same boundary via `.cursor/hooks.json`.
Three hooks run on every agent action:

| Hook | Script | What it checks |
| --- | --- | --- |
| `beforeShellExecution` | `.cursor/hooks/sandbox-shell.sh` | Shell commands — same allow/deny policy as `outer-gate.sh` |
| `preToolUse(Write\|Delete)` | `.cursor/hooks/sandbox-write.sh` | File write/delete paths |
| `beforeReadFile` | `.cursor/hooks/sandbox-read.sh` | Read paths — denies `tools/sandbox/.cache/` (credentials) |

`failClosed: true` in the hooks file means a hook crash denies the action
rather than passing it through. `install.sh` merges the hook entries into any
existing `.cursor/hooks.json` so other project hooks are preserved. Run
`./sandbox doctor` to verify the hooks are wired; it warns if they are missing.

The inner Cursor invocation is:

```bash
agent -p --force --trust --sandbox disabled --output-format stream-json \
  [--resume <session-id>] [--model <id>] -- "$msg"
```

`--force` is the yolo flag. `--trust` is not optional in practice: in print mode
an untrusted workspace stops the run rather than prompting, and a bind mount the
container has never seen is untrusted by definition. `--sandbox disabled` turns
off Cursor's own process sandbox, which is redundant inside a throwaway
container and is the layer most likely to fail for reasons unrelated to the
task — the container is the boundary.

Like Codex, Cursor has no `--continue` that survives a fresh process, so
`dispatch-cursor.sh` persists the `session_id` every stream-json line carries to
`tools/sandbox/.cache/cursor-session` and resumes it explicitly. That is what
makes `./sandbox -c` mean one thing across all three agents. And because the
stream is JSONL, `./sandbox tail -f` shows real step-by-step progress for a
Cursor run, the same as for Codex.

## Which agent runs inside

**The inner agent is the same product as the outer one.** Not because the three
are interchangeable, but because they are not: the two halves share a repo and a
task, and a Codex outer handing work to a Claude inner means the agent that
wrote the dispatch and the agent that reads it disagree about their own
conventions. They do *not* share a model — see below.

Nobody is asked. The outer client leaves fingerprints in the environment of
every command it runs, and `tools/sandbox/agent.sh` reads them:

1. `SANDBOX_AGENT` if set — `codex`, `claude`, `cursor`, `copilot`, `agy`,
   `amp`, or `opencode`; anything else is an error.
2. **Codex**, if any `CODEX_*` variable exists or `TERM_PROGRAM=codex`.
3. **Claude**, if `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, or
   `CLAUDE_AGENT_SDK_VERSION` is set.
4. **Cursor**, if `CURSOR_AGENT` or `CURSOR_TRACE_ID` is set.
5. A prompt, but only when stdin and stdout are both terminals — a script cannot
   answer, and blocking on a prompt nobody will ever answer is worse than
   picking a default.
6. `SANDBOX_DEFAULT_AGENT` from `sandbox.conf`, default `claude`.

**Codex is checked before Claude on purpose.** Some Codex installs inherit
unrelated `CLAUDE_*` tuning variables from a shell profile, so looking for those
first would misidentify a Codex session as a Claude one. The order is the fix.

**Cursor is checked last of the three on purpose too.** Claude Code and Codex
are both things people run *inside* a Cursor terminal, so when both sets of
markers are present the CLI actually executing the command is the right answer,
and it got its turn first. `CURSOR_AGENT=1` is the reliable marker — the Cursor
CLI sets it in the environment of every shell command its agent runs.
`CURSOR_TRACE_ID` comes from the Cursor IDE's integrated terminal and covers the
in-editor agent. `TERM_PROGRAM` is no help: Cursor is a VS Code fork and reports
itself as `vscode`, which is what real VS Code reports too.

Override for one run with `./sandbox -a cursor "task"`, or permanently with
`SANDBOX_DEFAULT_AGENT`. Whichever is chosen, `require_agent_credential` pulls
that agent's credential before the container starts, so a missing login fails on
the Mac with the command that fixes it instead of failing later inside the
container. See [credentials.md](credentials.md).

## A manager inside, workers under it

The inner run is not one agent doing the task. It is a **manager**, and the
manager spawns **workers**.

The manager reads enough of the repo to write a short spec, spawns a worker on a
cheaper model to make the edits and run the tests, reviews what came back, and
retries or accepts. It does not sit in the repo with editor tools open. The
point is narrow and it is about money: routing and reviewing need judgement,
typing does not, and paying the judgement rate for the typing is the default
that this design exists to break.

Two rules come with it, both in `tools/sandbox/AGENT.md`, which is the manager's
prompt:

- **Tokens build scripts; only scripts do work.** Tokens are not allowed to do
  the work directly. They build scripts; those scripts do the work and stay in
  the project tree.
- **Work products live in the worktree.** Committable, visible on the Mac. Not
  in `tools/sandbox/.cache`, not in `/tmp`, not in the container's home.

The outer agent does not steer any of this. It does not pick models, name
workers, or split the job.

## Which model the manager runs

`tools/sandbox/model.sh` resolves it, in order:

1. `SANDBOX_MODEL`, or `./sandbox -m <id>` for one run. Wins over everything.
2. A non-empty `<agent>_manager=` line in the daily snapshot — see below.
3. `SANDBOX_DEFAULT_MODEL` from `sandbox.conf` — a project-wide manager pin.
4. A high-value default per agent:

   | Agent | Manager default | Passed as |
   | --- | --- | --- |
   | Claude | `claude-sonnet-4-6` | `claude -p --model <id>` |
   | Codex | `gpt-5.3-codex` | `codex exec --model <id>` |
   | Cursor | `cursor-grok-4.6-high` | `agent --model <id>` |

**The outer client's model is deliberately not copied.** This file used to do
exactly that, and it is the wrong answer for a manager in both directions: an
outer agent on a small fast model would hand the container a manager that cannot
review, and an outer agent on the flagship would bill every routing decision at
flagship rates. The two halves have different jobs now, so they get different
models.

The defaults in step 4 are chosen to be high enough to route and review, and
deliberately not a fast/mini/haiku/composer tier — that is what the workers are
for. They are handed to the CLI verbatim, so they have to be ids that agent
understands; when one goes stale, `_sandbox_manager_fallback` in `model.sh` is
the single place to change it. `./sandbox -m gpt-5` against a Claude inner fails
inside the container, not on the Mac.

The dispatch line names the role, so a run that was pinned is visible:

```
→ cursor (manager) · cursor-grok-4.6-high ...
→ claude (manager) · claude-sonnet-4-6 ...
```

## The daily snapshot

The manager has to pick a worker model, and plans, tiers and promos move. Making
it web-search that on every dispatch would spend the expensive tokens on a
lookup whose answer does not change hour to hour.

So `tools/sandbox/model-daily.sh` does it **on the host**, at most once every 24
hours, once for every sandbox on the machine:

| | |
| --- | --- |
| Where | `$TMPDIR/sandbox-model-daily`, override with `SANDBOX_MODEL_DAILY_FILE` |
| When | Only if missing or older than `SANDBOX_MODEL_DAILY_MAX_AGE` (86400s). Read first, always |
| What | Public sources — Anthropic news and pricing, the Cursor changelog, the GitHub Codex releases atom and the npm `@openai/codex` latest document — crudely tag-stripped, filtered to lines mentioning a model, a price or a promo. Also the upstream harness sha (`harness_sha`) via a separate GitHub commits API call |
| Shape | `fetched_at`, `fetched_at_iso`, `status=ok\|unavailable`, `<agent>_manager=` lines, `harness_repo`, `harness_ref`, `harness_sha`, `harness_autoupdate`, then per-product notes. No history, `chmod 600`, written `mktemp` + `mv` |
| How it gets in | `dispatch.sh` exports the text as `SANDBOX_MODEL_DAILY` and each backend passes it to `docker exec -e`. **Not a mount** |

It fails open at every step. No `curl`, a dead page, a redesign that makes the
digest empty: the file is still written, with `status=unavailable` and a
timestamp, so a broken network costs one attempt a day instead of one attempt
per dispatch. `SANDBOX_MODEL_DAILY_FETCH_CMD` replaces `curl` with any command
that prints a page for a URL, which is how `model-daily-test.sh` runs the whole
thing with no network at all.

**The `<agent>_manager=` lines are normally empty, and that is intended.** The
fetcher does not try to infer a model id out of marketing prose: a guessed id
fails inside the container minutes later, which is worse than the default in
`model.sh`. The keys are there for a human, or a future source that publishes
real ids, to fill in. What the snapshot is actually for is the manager reading
it — one env var instead of a web search.

The `harness_sha` key drives autoupdate: `./sandbox up` (via `boot.sh`) reads
the sha from the daily file and compares it to `SANDBOX_ORIGIN_COMMIT`. If they
differ and `SANDBOX_AUTOUPDATE=1`, `update.sh` fetches and installs the new
harness before the container starts. The default is `0` (off) — autoupdate
rewrites host gate scripts without a separate approval step, so it requires an
explicit opt-in. Set `SANDBOX_UPDATE_CHECK=0` to disable both the nudge and
autoupdate.

Nothing about it is mounted, and it must stay that way. The container does not
see `$TMPDIR`; it sees an environment variable holding today's text. That is the
whole reason this is a host-side write analogous to the update-check stamp
rather than a new hole in the boundary — see
[docs/security.md](security.md).

## Inside the container

The inner agent gets its own instructions: `tools/sandbox/AGENT.md` is baked into
the image and copied by `entrypoint.sh` to each agent's user-global location —
`/home/agent/.claude/CLAUDE.md`, `/home/agent/.codex/AGENTS.md`, and
`/home/agent/.cursor/rules/sandbox-inner.mdc` with `alwaysApply: true` — so
whichever one runs finds them. `dispatch.sh` then recopies all three from the
bind-mounted `tools/sandbox/AGENT.md` before every run, best effort, so an edit
to the manager's prompt takes effect on the next dispatch instead of waiting for
an image rebuild. They say that the run is a manager and the work goes to
workers, that tokens build scripts and only scripts do work, that
`tools/sandbox/*.sh` are host-side scripts it must not run — dispatching from
inside is an agent calling itself — and to always pass `git commit -m`, since
the container's editor is `/bin/false` and a bare commit fails fast rather than
hanging a non-interactive run forever.

That user-global copy is load-bearing. The project's own `AGENTS.md` says "you
are the OUTER agent, dispatch everything"; an inner agent reading only that file
would dutifully try to dispatch to itself. The user-global file is what outranks
it.

Only one inner run happens at a time. Each dispatch kills any previous
`claude -p`, `codex exec` or `cursor-agent` first: a run orphaned by a
disconnected client is still holding the repo, and two agents editing one
worktree produce corruption that is very hard to attribute later.

The answer is written to a file **inside** the container, on the bind mount. If
your client dies mid-run the work still finishes and the answer is still on
disk — `./sandbox result` reads it back without spending another run.

## Writing a dispatch

The inner agent gets exactly one message and cannot ask a follow-up question. A
clarifying question comes back to you as a failed task minutes later, so send
the whole thing:

- what to change, and where, with paths you found by reading
- what "done" means, and the literal command that verifies it
- whether to commit and push

Bad: `fix the tests`

Good: `src/parse.ts drops a trailing comma in list literals — see the failing
case in test/parse.test.ts:44. Fix the parser, run 'pnpm test', and commit with a
message describing the fix.`

You are allowed to read the repo on the host, and you should. A dispatch built
on a guess costs a full run to discover it was wrong. For a long message, write
to a file and pass `--file`:

```bash
./sandbox --file /path/to/task.md
```

Piping is denied by the outer gate — `printf '%s' "$LONG" | ./sandbox` will be
blocked with "pipe denied". `DISPATCH_MSG` is set to the message text by the
gate, but write it to a file in the worktree rather than relying on that.

## Unknown single-token verbs

A single bare token that is not a known verb is rejected immediately — `./sandbox
down` exits 2 with `unknown verb: down`, rather than sending "down" to the inner
agent as a task. The common mistakes are called out:

| You typed | The verb is |
| --- | --- |
| `down` | `stop` |
| `start`, `restart` | `up` (or stop then up) |
| `ps`, `logs` | `status` or `tail` |
| `exec` | `run` or `shell` |
| `kill`, `destroy`, `reset`, `clean` | `stop` |

To dispatch a single word as a task, quote it: `./sandbox "down the service"`.

## Secrets

Do not ask the outer agent to read secrets from the host — anything it reads
ends up in a transcript. Instead, declare a read-only secrets mount in
`sandbox.conf` with `SANDBOX_EXTRA_MOUNTS`:

```bash
SANDBOX_EXTRA_MOUNTS="
/path/to/my-secrets:/secrets:ro
"
```

The grant lives only in the container and disappears when the container is
removed. See [configuration.md](configuration.md) for the full `SANDBOX_EXTRA_MOUNTS`
documentation and security notes.
