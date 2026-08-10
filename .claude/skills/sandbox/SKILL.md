---
name: sandbox
description: Use when work in this repo needs to run — builds, tests, installs, git, edits to project files. Explains how to dispatch to the containerized inner agent, watch it, recover a lost result, and fix a broken sandbox.
---

# Sandbox

You relay. The inner agent works. See `AGENTS.md` for the rule; this is the
reference for carrying it out.

## Commands

| Command | Does |
| --- | --- |
| `./sandbox "task"` | Dispatch. Prints the inner agent's answer. |
| `./sandbox -c "task"` | Dispatch continuing the previous thread. |
| `./sandbox result` | Re-read the last answer without spending a run. |
| `./sandbox tail -f` | Live progress of the current run. |
| `./sandbox up` | Start the container (dispatch does this for you). |
| `./sandbox status` | Container state, ports, hot-reload, whether a run is live. |
| `./sandbox doctor` | Check the host setup and name the fix for each problem. |
| `./sandbox run <cmd>` | Run one command inside the container. |
| `./sandbox shell` | Interactive shell inside the container. |
| `./sandbox rebuild` | Force an image rebuild. |
| `./sandbox stop` | Stop the container; cache and credentials survive. |
| `./sandbox test` | Run the gate test suite. |

A long message is safer on stdin than as an argument:
`printf '%s' "$LONG" | ./sandbox`

## Writing the dispatch

One message, no follow-up questions possible. Include the paths you found, the
acceptance check (the literal command), and whether to commit. Read the repo
first — you are allowed to read, and a dispatch built on a guess costs a full
run to discover it was wrong.

## When something goes wrong

**Denied by a hook.** Working as designed. Dispatch it.

**"Sandbox failed to start."** Run `./sandbox doctor`. Almost always Colima is
down: `colima start --vm-type vz --mount-type virtiofs`.

**Dispatch returns a login or auth error.** The credential expired on the Mac.
The human runs `claude` (or `codex login`) on the host and signs in; the next
dispatch re-bridges it. You cannot sign in for them.

**`git push` fails inside the container.** The GitHub token didn't bridge. The
human runs `gh auth login` on the Mac, then `./sandbox up` re-syncs it. No SSH
key is ever mounted — this is a scoped, revocable token by design.

**Edits on the Mac don't reload in the container.** Check
`./sandbox status` for the hot-reload line. `./sandbox up` restarts the bridge.
Do not add a polling watcher to the dev server; polling from the repo root over
virtiofs is two orders of magnitude slower than the native path.

**Config changed but the container ignores it.** Ports, mounts, and volumes are
fixed at creation. `./sandbox up` detects the drift and recreates. If it
doesn't, `./sandbox rebuild`.

## Choosing the inner agent

Auto-detected from your own environment: a Codex outer runs Codex inner, a
Claude outer runs Claude inner. Override per dispatch with
`./sandbox -a codex "task"`, or permanently with `SANDBOX_DEFAULT_AGENT` in
`tools/sandbox/sandbox.conf`.

## Never

Read, print, or commit anything under `tools/sandbox/.cache/` — it holds live
OAuth tokens and a GitHub token.
