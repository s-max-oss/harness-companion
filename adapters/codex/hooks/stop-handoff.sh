#!/bin/bash
# adapters/codex/hooks/stop-handoff.sh — Codex Stop hook (Phase 5b)
#
# Phase 5b: Implements real Stop handoff warnings using the Codex hook
# protocol (systemMessage). All business semantics live in
# core/lib/status-renderer.sh — this adapter only does protocol envelope
# wrapping.
#
# Input (stdin): Codex Stop JSON with at minimum:
#   { "cwd": "<path>", "session_id": "<id>" }
#
# Output (stdout): Codex hook envelope (one of):
#   {"systemMessage":"<handoff warnings>"}   — when warnings exist
#   {"continue":true}                         — when no warnings (clean stop)
#
# Fail-open: any error → {"continue":true} exit 0. Never block the agent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../../core" && pwd)"

# ---- Per-hook diagnostic logging ----------------------------------------------
HC_LOG_DIR="${HOME}/.claude/harness-companion/logs"
mkdir -p "$HC_LOG_DIR" 2>/dev/null || HC_LOG_DIR="/tmp"
LOG_FILE="$HC_LOG_DIR/codex-stop-handoff.log"

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

# ---- Source core libs (reusable across adapters) -------------------------------
# shellcheck source=../../../core/lib/json-helpers.sh
source "$CORE_DIR/lib/json-helpers.sh"
# shellcheck source=../../../core/lib/json-encode.sh
source "$CORE_DIR/lib/json-encode.sh"
# shellcheck source=../../../core/lib/status-renderer.sh
source "$CORE_DIR/lib/status-renderer.sh"

# ---- Parse stdin + cwd ---------------------------------------------------------
ji_init
CWD="$(ji_cwd)"

if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  emit_continue "no valid cwd (got '$CWD')"
fi

cd "$CWD" 2>/dev/null || emit_continue "cd failed for $CWD"

# Only activate if harness files are present.
if [ ! -f "feature_list.json" ]; then
  _log "feature_list.json missing in $CWD — not a harness project"
  emit_continue "not a harness project"
fi

# ---- Render handoff warnings via core (plain text, no protocol) ----------------
WARNINGS_TEXT="$(sr_handoff_warnings "$(pwd)" || true)"
if [ -z "$WARNINGS_TEXT" ]; then
  _log "stop-handoff: clean — no warnings to surface"
  emit_continue "no handoff warnings"
fi

# ---- Map plain text → Codex Stop JSON envelope ---------------------------------
# Cross-platform JSON encoder (tries python3, python, py -3, jq -Rs).
# Adapter does NOT depend on a specific runtime being installed.
WARNINGS_JSON="$(hc_json_encode_string "$WARNINGS_TEXT" 2>/dev/null || true)"
if [ -z "$WARNINGS_JSON" ]; then
  emit_continue "json encoding failed (no python3/python/py/jq available)"
fi

printf '{"systemMessage":%s}\n' "$WARNINGS_JSON"
_log "stop-handoff: warnings emitted (${#WARNINGS_TEXT} chars)"
exit 0
