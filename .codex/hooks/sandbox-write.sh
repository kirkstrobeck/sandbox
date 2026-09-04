#!/usr/bin/env bash
# Codex PreToolUse hook for apply_patch/Edit/Write. Delegates to the shared write gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/../../tools/sandbox/outer-write-gate.sh"
