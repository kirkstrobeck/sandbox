#!/usr/bin/env bash
# Tests for the two PreToolUse gates. Run: bash tools/sandbox/gate-test.sh
#
# These gates are the only mechanical thing keeping the outer agent off the
# host, so "it looked right" is not good enough. Every case below is a decision
# the gates have to keep making after someone edits them.
#
# SANDBOX_GATE_FORCE makes the gates evaluate their rules even when the test
# happens to run inside a container.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export SANDBOX_GATE_FORCE=1
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

pass=0
fail=0

decision_of() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "ERROR"' 2>/dev/null
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf '  ok   %-58s %s\n' "$label" "$actual"
    return 0
  fi
  fail=$((fail + 1))
  printf '  FAIL %-58s expected %s, got %s\n' "$label" "$expected" "$actual"
}

bash_case() {
  local expected="$1" cmd="$2"
  local out
  out="$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' |
    bash "$SCRIPT_DIR/outer-gate.sh" 2>/dev/null)"
  check "bash: $cmd" "$expected" "$(decision_of "$out")"
}

write_case() {
  local expected="$1" path="$2"
  local out
  out="$(jq -nc --arg p "$path" '{tool_name:"Edit",tool_input:{file_path:$p}}' |
    bash "$SCRIPT_DIR/outer-write-gate.sh" 2>/dev/null)"
  check "edit: $path" "$expected" "$(decision_of "$out")"
}

echo "Bash gate — the work belongs to inner"
bash_case deny  'git status'
bash_case deny  'git push origin main'
bash_case deny  'gh pr create --fill'
bash_case deny  'pnpm install'
bash_case deny  'npm run build'
bash_case deny  'node scripts/seed.js'
bash_case deny  'rm -rf build'
bash_case deny  'curl https://example.com'
bash_case deny  'ssh deploy@host'
bash_case deny  'cat src/app.ts'
bash_case deny  'GIT_DIR=.git git log'

echo
echo "Bash gate — driving and observing the sandbox is allowed"
bash_case allow 'bash tools/sandbox/dispatch.sh "fix the header"'
bash_case allow 'bash tools/sandbox/boot.sh'
bash_case allow './sandbox "fix the header"'
bash_case allow './sandbox -c "now add a test"'
bash_case allow './sandbox -a cursor "fix the header"'
bash_case allow './sandbox -m gpt-5 "fix the header"'
bash_case allow './sandbox run pnpm test'
bash_case allow './sandbox status'
# The deliberate exception: `update` writes to tools/sandbox on the host. It is
# a harness operation with a reviewable diff, and the CLI is the door for it.
bash_case allow './sandbox update'
bash_case allow './sandbox update --check'
bash_case allow 'bash -n tools/sandbox/boot.sh'
bash_case allow 'docker ps'
bash_case allow 'docker logs my-sandbox-1234abcd'
bash_case allow 'docker restart my-sandbox-1234abcd'
bash_case allow 'cat tools/sandbox/sandbox.conf'
bash_case allow 'ls .claude/skills'
bash_case allow 'pwd'
bash_case allow 'colima status'
bash_case allow 'curl -sS http://localhost:3000/'
bash_case allow 'curl -I http://127.0.0.1:3000/health'

echo
echo "Bash gate — chaining cannot smuggle a denied command past an allowed one"
bash_case deny  'pwd && git push'
bash_case deny  'docker ps; rm -rf /'
bash_case deny  'echo $(git rev-parse HEAD)'
bash_case deny  'echo `whoami`'
bash_case deny  'bash tools/sandbox/boot.sh | tee /tmp/out'
bash_case deny  './sandbox up && git push'
bash_case deny  'curl http://localhost:3000 && curl https://evil.example'

echo
echo "Bash gate — quoted operators are text, not chaining"
bash_case allow 'bash tools/sandbox/dispatch.sh "commit this; then push"'
bash_case allow "bash tools/sandbox/dispatch.sh 'fix a && b in the parser'"
# An unterminated quote is input we cannot parse, so it reads as chained.
bash_case deny  'bash tools/sandbox/dispatch.sh "oops'

echo
echo "Write gate — host source files are off limits"
write_case deny  "$PROJECT_ROOT/src/app.ts"
write_case deny  "$PROJECT_ROOT/package.json"
write_case deny  "$PROJECT_ROOT/README.md"
write_case deny  "/etc/hosts"
# The whole point of normalizing before resolving: an allowed prefix must not
# be usable as a launchpad into the rest of the repo.
write_case deny  "$PROJECT_ROOT/.claude/../src/app.ts"
write_case deny  "$PROJECT_ROOT/tools/sandbox/../../src/app.ts"

echo
echo "Write gate — the harness and agent config are the outer agent's own"
write_case allow "$PROJECT_ROOT/.claude/settings.json"
write_case allow "$PROJECT_ROOT/.claude/skills/sandbox/SKILL.md"
write_case allow "$PROJECT_ROOT/.cursor/rules/sandbox.mdc"
write_case allow "$PROJECT_ROOT/tools/sandbox/sandbox.conf"
write_case allow "$PROJECT_ROOT/sandbox"
write_case allow "$PROJECT_ROOT/AGENTS.md"
write_case allow "$PROJECT_ROOT/CLAUDE.md"
write_case allow "$HOME/.claude/settings.json"
# The exact-match rule has to stay exact.
write_case deny  "$PROJECT_ROOT/sandbox.ts"
write_case deny  "$PROJECT_ROOT/AGENTS.md.bak"

echo
echo "Write gate — a call with no readable path is denied, not waved through"
no_path="$(jq -nc '{tool_name:"Edit",tool_input:{}}' | bash "$SCRIPT_DIR/outer-write-gate.sh" 2>/dev/null)"
check "edit: (no file_path)" deny "$(decision_of "$no_path")"

multi="$(jq -nc --arg a "$PROJECT_ROOT/.claude/x.md" --arg b "$PROJECT_ROOT/src/app.ts" \
  '{tool_name:"MultiEdit",tool_input:{edits:[{file_path:$a},{file_path:$b}]}}' |
  bash "$SCRIPT_DIR/outer-write-gate.sh" 2>/dev/null)"
check "multiedit: one allowed + one denied" deny "$(decision_of "$multi")"

echo
echo "Inside the sandbox the gates stand down"
inner="$(SANDBOX_GATE_FORCE= SANDBOX_INNER=1 bash -c \
  'jq -nc "{tool_name:\"Bash\",tool_input:{command:\"git push\"}}" | bash "$0"' \
  "$SCRIPT_DIR/outer-gate.sh" 2>/dev/null)"
check "bash: git push (SANDBOX_INNER=1)" allow "$(decision_of "$inner")"

echo
echo "Bash gate — project extra allow is after named denials"
bash_case deny  'bash tools/dev-start.sh --foo'
out="$(jq -nc --arg c 'bash tools/dev-start.sh --foo' \
  '{tool_name:"Bash",tool_input:{command:$c}}' |
  SANDBOX_EXTRA_ALLOW='bash tools/dev-start.sh*' bash "$SCRIPT_DIR/outer-gate.sh" 2>/dev/null)"
check "bash: extra-allow project script" allow "$(decision_of "$out")"
out="$(jq -nc --arg c 'git status' \
  '{tool_name:"Bash",tool_input:{command:$c}}' |
  SANDBOX_EXTRA_ALLOW='git*' bash "$SCRIPT_DIR/outer-gate.sh" 2>/dev/null)"
check "bash: extra-allow cannot grant git" deny "$(decision_of "$out")"
out="$(jq -nc --arg c 'pnpm install' \
  '{tool_name:"Bash",tool_input:{command:$c}}' |
  SANDBOX_EXTRA_ALLOW='pnpm *' bash "$SCRIPT_DIR/outer-gate.sh" 2>/dev/null)"
check "bash: extra-allow cannot grant pnpm" deny "$(decision_of "$out")"
out="$(jq -nc --arg c 'rm -rf build' \
  '{tool_name:"Bash",tool_input:{command:$c}}' |
  SANDBOX_EXTRA_ALLOW='rm *' bash "$SCRIPT_DIR/outer-gate.sh" 2>/dev/null)"
check "bash: extra-allow cannot grant rm" deny "$(decision_of "$out")"
bash_case allow './sandbox --file tools/sandbox/sandbox.conf'
bash_case deny  'printf %s x | ./sandbox'

echo
echo "CLI — unknown single-token verbs"
cli_rc=0
cli_out="$(bash "$PROJECT_ROOT/sandbox" down 2>&1)" || cli_rc=$?
check "cli: ./sandbox down exits 2" 2 "$cli_rc"
check "cli: ./sandbox down names the verb" unknown \
  "$(printf '%s' "$cli_out" | grep -q 'unknown verb: down' && echo unknown || echo other)"

echo
echo "Claude result extraction — success is not an envelope dump"
# shellcheck source=dispatch-claude.sh
. "$SCRIPT_DIR/dispatch-claude.sh"
_ext_dir="$(mktemp -d)"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"hello from inner"}' >"$_ext_dir/ok.jsonl"
ext_out="$(claude_result_from_stream "$_ext_dir/ok.jsonl")"; ext_rc=$?
check "claude stream: success prints result" "hello from inner" "$ext_out"
check "claude stream: success exit 0" 0 "$ext_rc"
printf '%s\n' '{"is_error":false,"subtype":"success","result":""}' >"$_ext_dir/empty.json"
ext_out="$(claude_result_from_file "$_ext_dir/empty.json")"; ext_rc=$?
check "claude json: empty success is exit 0" 0 "$ext_rc"
check "claude json: empty success does not dump envelope" nodump \
  "$(printf '%s' "$ext_out" | grep -q is_error && echo dump || echo nodump)"
rm -rf "$_ext_dir"

echo
echo "Worktree pointer — common dir is outside the repo"
_wt="$(mktemp -d)"
mkdir -p "$_wt/parent/.git/worktrees/leaf" "$_wt/leaf"
printf 'gitdir: %s\n' "$_wt/parent/.git/worktrees/leaf" >"$_wt/leaf/.git"
_wt_got="$(
  # shellcheck source=common.sh
  . "$SCRIPT_DIR/common.sh"
  # shellcheck source=run-args.sh
  . "$SCRIPT_DIR/run-args.sh"
  REPO_ROOT="$_wt/leaf"
  sandbox_git_common_dir
)"
check "worktree: common dir resolves" "$(cd "$_wt/parent/.git" && pwd -P)" "$_wt_got"
rm -rf "$_wt"

echo
echo "Manifest — every path install claims to own is really here"
# The gates are not the only thing that fails silently. A MANIFEST that lists a
# file the tree does not have installs a project into a state where the next
# update deletes files that were never written, and nothing notices until
# somebody's harness is missing a script. This is the cheapest possible guard:
# run it wherever the tests run.
# shellcheck source=manifest.sh
. "$SCRIPT_DIR/manifest.sh"
MANIFEST_FILE="$SCRIPT_DIR/MANIFEST"

if [ ! -r "$MANIFEST_FILE" ]; then
  check "manifest: tools/sandbox/MANIFEST exists" present missing
else
  check "manifest: tools/sandbox/MANIFEST exists" present present
  missing_paths="$(manifest_missing_sources "$PROJECT_ROOT" "$MANIFEST_FILE" || true)"
  if [ -z "$missing_paths" ]; then
    check "manifest: every replace/preserve path is in the tree" complete complete
  else
    check "manifest: every replace/preserve path is in the tree" complete "missing $(printf '%s ' $missing_paths)"
  fi

  # The other direction. A harness file nobody listed is a file no install
  # copies and no update removes — it exists here and nowhere else.
  unlisted=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    manifest_entries "$MANIFEST_FILE" | awk -v p="$f" '$2 == p { found = 1 } END { exit !found }' ||
      unlisted="$unlisted $f"
  done <<EOF
$(cd "$PROJECT_ROOT" && find tools/sandbox -type f \
    ! -path 'tools/sandbox/.cache/*' \
    ! -name 'sandbox.local.conf' ! -name 'sandbox.conf.new' ! -name 'ORIGIN.md' \
    ! -name '.install-hashes' 2>/dev/null | sort)
EOF
  if [ -z "$unlisted" ]; then
    check "manifest: no harness file is missing from it" complete complete
  else
    check "manifest: no harness file is missing from it" complete "unlisted$unlisted"
  fi
fi

# The daily model snapshot and the manager-model resolution that reads it. It
# shares check/pass/fail rather than running as a subprocess, so `./sandbox test`
# reports one honest number for the whole harness instead of two.
# shellcheck source=model-daily-test.sh
. "$SCRIPT_DIR/model-daily-test.sh"

# Latency-cut additions: sandbox_now_ms, stamp-fresh, github cache, bridge skip.
# shellcheck source=bench-test.sh
. "$SCRIPT_DIR/bench-test.sh"

echo
echo "install.sh — dry-run does not change files; no --force refuses foreign files"
_itmp="$(mktemp -d)"
mkdir -p "$_itmp/tools/sandbox"
printf '#!/usr/bin/env bash\necho hi\n' >"$_itmp/tools/sandbox/my-project-script.sh"
# dry-run against this repo (SRC=PROJECT_ROOT since install.sh is next to tools/sandbox)
_irc=0
SANDBOX_TARGET="$_itmp" bash "$PROJECT_ROOT/install.sh" --dry-run 2>/dev/null || _irc=$?
check "install: dry-run exits 0" 0 "$_irc"
check "install: dry-run keeps foreign file" present \
  "$([ -f "$_itmp/tools/sandbox/my-project-script.sh" ] && echo present || echo gone)"
# without --force: must refuse (nonzero) because of the foreign file
_irc2=0
SANDBOX_TARGET="$_itmp" bash "$PROJECT_ROOT/install.sh" 2>/dev/null || _irc2=$?
check "install: refuses foreign file without --force" nonzero \
  "$([ "$_irc2" -ne 0 ] && echo nonzero || echo zero)"
check "install: foreign file present after refusal" present \
  "$([ -f "$_itmp/tools/sandbox/my-project-script.sh" ] && echo present || echo gone)"
rm -rf "$_itmp"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
