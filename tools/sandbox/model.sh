#!/usr/bin/env bash
# Decide which model the inner agent runs. Source, don't run. Expects
# SANDBOX_DIR (common.sh sets it) when reading host config files.
#
# The inner agent is the same product as the outer one (agent.sh). This file is
# the other half of that: where the outer model can be read, the inner run gets
# the same model id, so the two halves are not quietly a tier apart. An outer
# agent on a big model writing a dispatch for an inner agent on a small one is a
# bad surprise in exactly one direction, and it is invisible in the transcript.
#
# WHERE THE ANSWER COMES FROM, in order:
#
#   1. SANDBOX_MODEL          — explicit, wins over everything.
#   2. the outer client's own environment or config, per agent (below).
#   3. SANDBOX_DEFAULT_MODEL  — a project-wide pin in sandbox.conf.
#   4. nothing. No flag is passed and the inner CLI picks its own default.
#
# Step 4 is deliberate. None of the three clients exports "the model I am
# currently running" — the closest thing each has is a setting the human chose,
# and if they did not choose one there is nothing to read. Guessing an id here
# would mean pinning a model nobody asked for, which is worse than the CLI's own
# default being used and said out loud.

# The `model = "..."` at the top level of ~/.codex/config.toml — the same value
# the outer Codex reads. Stop at the first [section] header: `model` inside
# [profiles.foo] belongs to that profile, not to the default run.
_codex_config_model() {
  local file="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [ -r "$file" ] || return 0
  awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*model[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^["\x27]|["\x27][[:space:]]*$/, "")
      sub(/[[:space:]]*#.*$/, "")
      print; exit
    }' "$file" 2>/dev/null
}

# Best effort. The Cursor CLI keeps its settings in cli-config.json, and the
# model there may be a plain id or a details object depending on how it was
# chosen; both shapes are read and anything else yields nothing.
_cursor_config_model() {
  local dir="${CURSOR_CONFIG_DIR:-${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/cursor}}"
  [ -n "$dir" ] || dir="$HOME/.cursor"
  local file="$dir/cli-config.json"
  [ -r "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    (.model? // .defaultModel? // empty) as $m
    | if ($m | type) == "string" then $m
      elif ($m | type) == "object" then ($m.name? // $m.id? // empty)
      else empty end' "$file" 2>/dev/null | head -1
}

resolve_sandbox_model() {
  local agent="$1" model=""

  if [ -n "${SANDBOX_MODEL:-}" ]; then
    printf '%s\n' "$SANDBOX_MODEL"
    return 0
  fi

  case "$agent" in
    claude)
      # ANTHROPIC_MODEL is the documented way to pin Claude Code's model, so a
      # shell that has it set is a shell whose outer agent is running it.
      model="${ANTHROPIC_MODEL:-${CLAUDE_MODEL:-}}"
      ;;
    codex)
      model="${CODEX_MODEL:-}"
      [ -n "$model" ] || model="$(_codex_config_model)"
      ;;
    cursor)
      model="${CURSOR_MODEL:-}"
      [ -n "$model" ] || model="$(_cursor_config_model)"
      ;;
  esac

  [ -n "$model" ] || model="${SANDBOX_DEFAULT_MODEL:-}"
  printf '%s\n' "$model"
}
