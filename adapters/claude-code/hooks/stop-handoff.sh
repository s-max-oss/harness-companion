#!/bin/bash
# adapters/claude-code/hooks/stop-handoff.sh — Claude Code Stop protocol mapping
#
# Phase 4: Adapter is host protocol mapping ONLY. All business semantics live
# in core/lib/status-renderer.sh. This script:
#   1. Reads stdin (Claude Stop event JSON)
#   2. Parses cwd via core/lib/json-helpers.sh
#   3. Reads SessionStart baseline via core/lib/baseline.sh
#   4. Calls sr_handoff_warnings from core/lib/status-renderer.sh
#   5. JSON-encodes the plain-text result
#   6. Wraps in the Claude Code Stop envelope:
#        {"continue":true,"systemMessage":"<json-string>"}
#      OR, if no warnings, emits:
#        {"continue":true,"suppressOutput":true}
#   7. Fail-open: any error → {"continue":true,"suppressOutput":true}
#
# The handoff warning content (uncommitted files, dangling in_progress, passing-
# without-evidence, stale evidence vs SessionStart baseline, checklist reminder)
# is computed by core/lib/status-renderer.sh. This script only maps it onto
# the Claude protocol.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../../core" && pwd)"

# ---- Per-hook diagnostic logging (best effort, never block) ---------------------
HC_LOG_DIR="${HOME}/.claude/harness-companion/logs"
mkdir -p "$HC_LOG_DIR" 2>/dev/null || HC_LOG_DIR="/tmp"
LOG_FILE="$HC_LOG_DIR/stop-handoff.log"

_log() {
  printf '[%s] %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" \
    "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# ---- Fail-open envelopes -------------------------------------------------------
emit_continue_only() {
  printf '{"continue":true,"suppressOutput":true}\n'
  exit 0
}

emit_message() {
  local msg="$1"
  local encoded=""
  if command -v jq >/dev/null 2>&1; then
    encoded="$(printf '%s' "$msg" | jq -Rs . 2>/dev/null || true)"
  elif command -v python >/dev/null 2>&1; then
    encoded="$(printf '%s' "$msg" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || true)"
  elif command -v python3 >/dev/null 2>&1; then
    encoded="$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || true)"
  fi
  if [ -z "$encoded" ]; then
    _log "no JSON encoder; emitting continue only"
    emit_continue_only
  fi
  printf '{"continue":true,"systemMessage":%s}\n' "$encoded"
  exit 0
}

# Trap any uncaught error → fail-open.
trap 'emit_continue_only' ERR

# ---- Source core libs (reusable across adapters) -------------------------------
# shellcheck source=../../../core/lib/json-helpers.sh
source "$CORE_DIR/lib/json-helpers.sh"
# shellcheck source=../../../core/lib/baseline.sh
source "$CORE_DIR/lib/baseline.sh"
# shellcheck source=../../../core/lib/status-renderer.sh
source "$CORE_DIR/lib/status-renderer.sh"

# ---- Parse stdin + cwd ---------------------------------------------------------
ji_init
CWD="$(ji_cwd)"

if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  _log "no valid cwd (got '$CWD')"
  emit_continue_only
fi

cd "$CWD" 2>/dev/null || { _log "cd failed for $CWD"; emit_continue_only; }

# Only activate if harness files are present.
if [ ! -f "feature_list.json" ]; then
  emit_continue_only
fi

# ---- Export baseline SHA so core's sr_handoff_warnings can use it ------------
export HC_SESSION_BASELINE_SHA
HC_SESSION_BASELINE_SHA="$(hc_baseline_read_commit "$(pwd)" 2>/dev/null || true)"

# ---- Render handoff warnings via core (plain text, no protocol) --------------
MESSAGE="$(sr_handoff_warnings "$(pwd)")"

if [ -z "$MESSAGE" ]; then
  emit_continue_only
fi

# ---- Emit Claude Code Stop envelope -------------------------------------------
emit_message "$MESSAGE"