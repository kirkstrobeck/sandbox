#!/usr/bin/env bash
# Codex PreToolUse hook for Bash. Delegates to the shared outer shell gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/../../tools/sandbox/outer-gate.sh"
