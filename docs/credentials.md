# Credentials

The inner agent runs with permissions disabled, so what it can reach is decided
entirely by what gets mounted into the container. This is the list, how each one
arrives, and what is deliberately left out.

Credentials cross the boundary into `tools/sandbox/.cache/`, which is mounted
into the container's home. Only the credential(s) for the dispatched agent are
synced — `prepare_cache` runs only the sync script for the active agent, plus
GitHub unconditionally:

| What | Host source | Cache path | Mounted at | Direction |
| --- | --- | --- | --- | --- |
| Claude Code OAuth | macOS Keychain, or `~/.claude/.credentials.json` | `.cache/claude-home/.credentials.json` | `/home/agent/.claude` | two-way |
| Codex auth | `~/.codex/auth.json` | `.cache/codex-home/auth.json` | `/home/agent/.codex` | two-way |
| Cursor auth | `CURSOR_API_KEY`, macOS Keychain, or `~/.cursor/auth.json` | `.cache/cursor-home/auth.json` | `/home/agent/.config/cursor` | pull-only |
| GitHub token | `gh auth token`, `GH_TOKEN`, or `GITHUB_TOKEN` | `.cache/gh/hosts.yml` | `/home/agent/.config/gh` | pull-only |
| Copilot | reuses the GitHub token (`gh auth token` inside the container) | — | `/home/agent/.config/gh` (shared) | pull-only |
| agy / Gemini | `GEMINI_API_KEY`, or `~/.gemini/credentials.json` | `.cache/agy-home/` | `/home/agent/.gemini` | pull-only |
| Amp | `AMP_API_KEY`, or `~/.config/amp/config.json` | `.cache/amp-home/` | `/home/agent/.config/amp` | pull-only |
| OpenCode | `~/.config/opencode/` (BYOK provider keys) | `.cache/opencode-home/` | `/home/agent/.config/opencode` | pull-only |

`boot.sh` refreshes the relevant credential in `prepare_cache` before the
container starts, so every dispatch runs against current credentials.

## `.cache/` holds live credentials

Say it plainly: `tools/sandbox/.cache/` contains a live Anthropic OAuth token, a
live OpenAI token, a live Cursor token or API key, and a GitHub token that can
push to your repos.

- The installer adds `tools/sandbox/.cache/` to `.gitignore`, and
  `./sandbox doctor` fails — not warns — if that line is missing.
- Never commit it, never print it, never paste it into a bug report, and never
  ask an agent to read it out. An agent that is asked to "check the token" will
  cheerfully put it in a transcript.
- `install.sh` deletes `.cache/` from the source tree when installing into
  another repo, so a credential cannot ride along with the harness.

Stopping the container keeps the cache on purpose — stopping is a pause, not a
reset. The real reset is `docker rm -f` plus removing `tools/sandbox/.cache`.

## Why the sync is two-way

The obvious design is a one-way copy at boot: read the host credential, drop it
in the mounted home, done. That is a time bomb, and both agent providers arm it
the same way.

OAuth refresh tokens rotate. The old refresh token stops working the moment a
new one is issued. So when the agent inside the container refreshes — which it
will, on any long run — the Mac's copy becomes dead the instant the container's
copy becomes valid. The next time you open Claude Code or Codex on the Mac you
are logged out, with nothing to connect it to what happened.

So both sync scripts run in both directions, and the rule is the same: whichever
side refreshed last is the authority. The only difference is how each provider
lets you tell.

## Claude: `token-sync.sh` and `expiresAt`

`tools/sandbox/token-sync.sh pull|push|status`.

On macOS the host credential lives in the login Keychain, not in a file, so the
script reads both stores:

- Keychain, under the service name **`Claude Code-credentials`**, via
  `security find-generic-password -s "Claude Code-credentials" -w`
- the file at `~/.claude/.credentials.json`, if it exists

The comparison key is `.claudeAiOauth.expiresAt` from the credential JSON. A
`newest()` helper picks whichever blob carries the later expiry, and ties keep
the first argument — so "already in sync" is a no-op rather than a pointless
rewrite.

- **`pull`** (before the run, from `boot.sh` and `require_agent_credential`)
  takes the newest of Keychain and host file, compares it to the cache, and
  writes the cache only if the host is newer. With no credential on either side
  it fails with: *Run `claude` on the Mac and sign in, then re-run boot.*
- **`push`** (after every dispatch, from `dispatch-claude.sh`) copies the cache
  back to the Mac **only when the cache is strictly newer** — writing both the
  host file and the Keychain entry. An unconditional push would happily
  overwrite a newer host token with an older container one and log you out,
  which is the exact failure the file exists to prevent. When it does fire it
  says so:

  ```
  Claude credential refreshed inside the sandbox; pushed back to the host.
  ```

- **`status`** prints both `expiresAt` values, which is the fastest way to see
  which side is authoritative.

Writes go through `mktemp` + `chmod 600` + `mv`, so the credential never exists
at its final name in a world-readable state.

## Codex: `codex-token-sync.sh` and `last_refresh`

`tools/sandbox/codex-token-sync.sh pull|push|status`.

Same hazard, different tell. Codex stores `auth.json` with a `last_refresh`
timestamp, so that string decides which copy wins. It is ISO-8601, so a plain
lexical comparison orders it correctly without parsing dates:

```bash
if [ -n "$cache_t" ] && [[ "$cache_t" > "$host_t" ]]; then ...
```

`push` requires strictly newer, for the same reason as the Claude side: equal
timestamps mean nothing refreshed, and copying anyway just churns the host file.
With no credential anywhere it fails with: *Run `codex login` on the Mac, then
re-run boot.*

The agents' credentials live in **separate cache homes** — `claude-home`,
`codex-home`, `cursor-home` — on purpose. One shared home would put an OpenAI
token, an Anthropic token and a Cursor token in the same directory, and every
mount that needed one would carry all three.

## Cursor: `cursor-token-sync.sh`, and why it is pull-only

`tools/sandbox/cursor-token-sync.sh pull|status`.

This is the one agent bridge that does not travel back, and the reason is a
property of the CLI rather than an omission. The Cursor CLI's refresh path
re-runs `loginWithApiKey(apiKey)`: the durable secret is the **API key**, and an
API key does not rotate. Nothing the container does can invalidate what the Mac
holds, so there is nothing to push back — and not writing three rotated secrets
into somebody's login Keychain after every dispatch is the better trade. `push`
exists as an explicit no-op so a caller that treats all three bridges alike does
not fail on this one.

The consequence is worth stating plainly: **a login-only credential (no API key)
bridges an access token the container cannot refresh on its own.** It works
until that token expires, then a dispatch comes back with an auth error and
`agent login` on the Mac fixes it. For a sandbox that runs unattended, set
`CURSOR_API_KEY` — that is also why the API key is read first.

Host side, in order:

1. `CURSOR_API_KEY` in the environment.
2. The macOS login Keychain: account `cursor-user`, services
   `cursor-api-key`, `cursor-access-token`, `cursor-refresh-token`.
3. The host file, if the CLI was told to use the file store there
   (`AGENT_CLI_CREDENTIAL_STORE=file`): `~/.cursor/auth.json` on macOS,
   `$XDG_CONFIG_HOME/cursor/auth.json` on Linux. The whole blob is passed
   through rather than rebuilt, so a field this script has never heard of — a
   Bedrock credential, say — survives the trip.

Container side is always a file. The CLI picks its store by platform: macOS uses
the Keychain, Linux uses `$XDG_CONFIG_HOME/cursor/auth.json`, which is why the
cache is mounted at `/home/agent/.config/cursor` and not at `~/.cursor`.

Writes go through `mktemp` + `chmod 600` + `mv` into a `chmod 700` directory,
like the other two. `status` prints which *fields* each side has and never a
value:

```
host  credential: apiKey
cache credential: apiKey
cache path:       tools/sandbox/.cache/cursor-home/auth.json
```

## GitHub: `github-token-sync.sh`

`tools/sandbox/github-token-sync.sh [--quiet]`. Host-side only; there is no push
direction, because nothing inside the container rotates this token.

It reads a token from `GH_TOKEN`, then `GITHUB_TOKEN`, then `gh auth token`, and
writes a minimal `hosts.yml` into `.cache/gh/`, which is mounted at
`/home/agent/.config/gh`. Inside the container, `entrypoint.sh` points git at it:

```bash
git config --global 'credential.https://github.com.helper' '!gh auth git-credential'
```

so `git push` works with no key, no ssh-agent, and no prompt. It also sets an
`insteadOf` rewrite from `git@github.com:` to `https://github.com/` — in the
container's `~/.gitconfig`, never in `.git/config`, because `.git/config` is
inside the bind-mounted worktree and is the same file the Mac uses.

**The token is never printed.** Not to stdout, not to stderr, not into an error
message, not into a log. It travels host env → variable → file descriptor and
stops there. Do not add `set -x` to that file. The success line names the login,
not the token:

```
GitHub auth bridged for <login> (token stays in .cache/gh, which is gitignored).
```

Resolving that login with `gh api user --jq .login` doubles as a liveness check:
a revoked or expired token fails on the host with a clear message instead of
surfacing later as a mysterious push failure inside the container. The file is
written with `mktemp` + `chmod 600` + `mv` into a `chmod 700` directory. The
rename is safe only because the container mounts the *directory* — Docker binds
the inode, so renaming a bind-mounted *file* would hand the host a new inode
while the container read the old one forever.

## No SSH key is ever mounted

Nothing under `~/.ssh` is touched and no key is mounted into the container. This
is not an oversight to fix later.

A GitHub token is revocable from the GitHub UI, scoped to what you granted, and
expires on its own. An SSH private key is none of those things. Handing one to a
container running an agent with permissions disabled is handing over the whole
account, with no way to narrow it and no way to take it back short of rotating
the key everywhere it is used. The token is the smaller, reversible version of
the same capability — which is the entire argument for the container in the
first place.

If the inner agent should not be able to push at all, do not bridge a token:
`boot.sh` warns and carries on, and everything except pushing still works.

## Copilot: `copilot-token-sync.sh`

Copilot reuses the GitHub OAuth token that is already bridged for `git push`.
Inside the container, `dispatch-copilot.sh` calls `gh auth token` and exports
the result as `COPILOT_GITHUB_TOKEN` immediately before invoking the CLI. No
separate credential file is written; there is nothing to push back.

## agy / Gemini: `agy-token-sync.sh`

`tools/sandbox/agy-token-sync.sh pull|push|status`.

agy authenticates through Google OAuth. The OAuth dance re-runs server-side and
the container cannot refresh a Google credential on the Mac's behalf, so this
bridge is **pull-only**. `GEMINI_API_KEY` takes precedence over the OAuth
credential for the same reason CURSOR_API_KEY is preferred over a login token:
an API key does not expire mid-run. With neither present, `pull` fails with the
command to fix it.

## Amp: `amp-token-sync.sh`

`tools/sandbox/amp-token-sync.sh pull|push|status`.

Amp authenticates with an API key (`AMP_API_KEY`). The key does not rotate, so
this bridge is **pull-only**. The sync reads the key from the env var or from
`~/.config/amp/config.json`, writes it to `.cache/amp-home/.amp_api_key`, and
mirrors the config file if one exists. `dispatch-amp.sh` forwards the key as an
env var and also falls back to the cache file. With no key found, `pull` fails.

## OpenCode: `opencode-token-sync.sh`

`tools/sandbox/opencode-token-sync.sh pull|push|status`.

OpenCode is BYOK (bring-your-own-key): the user stores provider API keys in
`~/.config/opencode/` and the directory is bind-mounted into the container. The
sync copies `config.json`, `settings.json`, `opencode.json`, and
`providers.json` into the cache. Provider API keys do not rotate, so this bridge
is **pull-only**. If the host config directory does not exist, an empty cache dir
is created — a project that configures via environment variables still works.

## Checking and fixing

```bash
./sandbox doctor                                   # all agents, plus the fix for each
bash tools/sandbox/token-sync.sh status            # Claude: host vs cache expiresAt
bash tools/sandbox/codex-token-sync.sh status      # Codex: host vs cache last_refresh
bash tools/sandbox/cursor-token-sync.sh status     # Cursor: which fields each side has
bash tools/sandbox/agy-token-sync.sh status        # agy: API key or OAuth credential
bash tools/sandbox/amp-token-sync.sh status        # Amp: API key present/missing
bash tools/sandbox/opencode-token-sync.sh status   # OpenCode: config dir populated
```

| Symptom | Fix |
| --- | --- |
| Dispatch returns a login or auth error | Run `claude`, `codex login`, or `agent login`, on the Mac and sign in. The next dispatch re-bridges it. |
| Cursor auth expires mid-run, repeatedly | The bridged credential is login-only and cannot refresh in the container. Export `CURSOR_API_KEY` instead. |
| agy auth fails mid-run | Export `GEMINI_API_KEY` instead of relying on OAuth — API keys don't expire. |
| `git push` fails inside the container | `gh auth login` on the Mac, then `./sandbox up` re-syncs the token. |
| Logged out on the Mac after a long run | The push-back did not land. `token-sync.sh status` shows which side is newer; signing in on the Mac is always safe. |
| `doctor` fails on `.cache is NOT gitignored` | Add `tools/sandbox/.cache/` to `.gitignore` before anything else. |

## Expiry warnings

The sandbox warns when a bridged credential will expire within the next 12 hours (configurable with `SANDBOX_AUTH_WARN_HOURS` — see [configuration](configuration.md)). Warnings appear on stderr during `./sandbox up` and before each dispatch.

**Claude** — the OAuth token's `expiresAt` field is read and compared. Tokens rotate on every refresh, so the newest copy (Keychain or file, whichever refreshed last) is used.

**Cursor login-only** — the access token is a short-lived JWT. The sandbox decodes it to find the expiry. If expiry cannot be determined (no JWT, unknown format), doctor warns that expiry is unknown and recommends `CURSOR_API_KEY` for unattended runs.

**Codex** — auth.json only carries `last_refresh`, not an explicit expiry. The sandbox cannot determine when the token expires without knowing the server-side lifetime, so no expiry warning is issued for Codex.

**GitHub / Copilot** — expiry is reported when `gh auth status` exposes it. Tokens set via `GH_TOKEN` or `GITHUB_TOKEN` environment variables carry no expiry metadata and are not checked.

**API-key agents** (agy, Amp, OpenCode) — API keys are non-expiring; no warning is issued.

To suppress repeated warnings during a tight dispatch loop, each service's warning is deduplicated to at most once per hour via a stamp in `.cache/stamps/`. `./sandbox doctor` always shows the current expiry state regardless of the dedup stamp.

You cannot sign in on the human's behalf from inside the container — the
credential has to be created on the Mac and bridged in.
