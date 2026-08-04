#!/bin/bash
# adapters/codex/hooks/pre-tool-use.sh — Codex PreToolUse hook (Phase 5b)
#
# Phase 5b: Safe exit 0 with "policy not enabled" notice. Codex hook
# protocol IS supported (see SessionStart/Stop hooks), but PreToolUse
# has no defined business rules yet. This hook:
#
#   1. Reads stdin (best effort)
#   2. Logs diagnostic to ~/.claude/harness-companion/logs/codex-pre-tool-use.log
#   3. Emits "policy not enabled" notice to STDERR (informational)
#   4. Exits 0 with {"continue":true} (permissive — allows all tools)
#
# Until specific PreToolUse policies are defined (e.g., blocking writes
# outside the harness directory), this hook allows everything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../../core" && pwd)"

# ---- Per-hook diagnostic logging ----------------------------------------------
HC_LOG_DIR="${HOME}/.claude/harness-companion/logs"
mkdir -p "$HC_LOG_DIR" 2>/dev/null || HC_LOG_DIR="/tmp"
LOG_FILE="$HC_LOG_DIR/codex-pre-tool-use.log"

_log() {
  printf '[%s] %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" \
    "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# Fail-open: on any error, emit continue and exit 0.
emit_continue() {
  _log "${1:-fail-open}"
  printf '{"continue":true}\n'
  exit 0
}
trap 'emit_continue "ERR trap: unexpected error"' ERR

# shellcheck source=../../../core/lib/json-helpers.sh
source "$CORE_DIR/lib/json-helpers.sh"

ji_init
CWD="$(ji_cwd)"

if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  emit_continue "no valid cwd (got '$CWD')"
fi

# ---- Phase 5b: Policy not enabled (safe permissive) ----------------------------
# PreToolUse policy is not configured. All tools are allowed.
# This is NOT a protocol-absent claim — the Codex hook protocol IS supported
# for SessionStart (status injection) and Stop (handoff warnings).
# PreToolUse is a future feature; until then, exit 0 permissively.

POLICY_NOTICE="[codex-hook] PreToolUse: policy not enabled — all tools allowed. Define PreToolUse rules to activate tool-gating."
_log "pre-tool-use: policy not enabled, allowing tool"
printf '%s\n' "$POLICY_NOTICE" >&2
printf '{"continue":true}\n'
exit 0
