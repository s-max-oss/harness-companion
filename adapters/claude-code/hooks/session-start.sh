#!/bin/bash
# adapters/claude-code/hooks/session-start.sh — Claude Code SessionStart protocol mapping
#
# Phase 4: Adapter is host protocol mapping ONLY. All business semantics live
# in core/lib/status-renderer.sh. This script:
#   1. Reads stdin (Claude SessionStart event JSON)
#   2. Parses cwd via core/lib/json-helpers.sh
#   3. Persists SessionStart baseline via core/lib/baseline.sh
#   4. Calls sr_status_text from core/lib/status-renderer.sh
#   5. JSON-encodes the plain-text result
#   6. Wraps in the Claude Code SessionStart envelope:
#        {"continue":true,
#         "hookSpecificOutput":{"hookEventName":"SessionStart",
#                               "additionalContext":"<json-string>"}}
#   7. Fail-open: any error → {"continue":true,"suppressOutput":true}
#
# Failure modes (all fail-open, exit 0):
#   - stdin empty / not JSON: still emit {"continue":true}
#   - cwd not an existing directory: still emit {"continue":true}
#   - jq AND python missing: fall back to guarded substring parser (via ji_cwd)
#   - feature_list.json missing: emit {"continue":true,"suppressOutput":true}
#   - jq missing for envelope: emit {"continue":true,"suppressOutput":true}
#
# Diagnostics: any error is written to ~/.claude/harness-companion/logs/session-start.log.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../../core" && pwd)"

# ---- Per-hook diagnostic logging (best effort, never block) ---------------------
HC_LOG_DIR="${HOME}/.claude/harness-companion/logs"
mkdir -p "$HC_LOG_DIR" 2>/dev/null || HC_LOG_DIR="/tmp"
LOG_FILE="$HC_LOG_DIR/session-start.log"

_log() {
  printf '[%s] %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" \
    "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# ---- Fail-open envelope --------------------------------------------------------
emit_continue_only() {
  printf '{"continue":true,"suppressOutput":true}\n'
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

# ---- Persist SessionStart baseline (used by Stop hook for stale evidence) -----
if git rev-parse --git-dir >/dev/null 2>&1; then
  BASELINE_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
  if [ -n "$BASELINE_SHA" ]; then
    hc_baseline_write "$(pwd)" "$BASELINE_SHA" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
  fi
fi

# ---- Render status block via core (plain text, no protocol) -------------------
STATUS_TEXT="$(sr_status_text "$(pwd)")"
if [ -z "$STATUS_TEXT" ]; then
  emit_continue_only
fi

# ---- JSON-encode the status string --------------------------------------------
# jq produces a proper JSON string with escapes. Fall back to python/python3.
STATUS_JSON=""
if command -v jq >/dev/null 2>&1; then
  STATUS_JSON="$(printf '%s' "$STATUS_TEXT" | jq -Rs . 2>/dev/null || true)"
elif command -v python >/dev/null 2>&1; then
  STATUS_JSON="$(printf '%s' "$STATUS_TEXT" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || true)"
elif command -v python3 >/dev/null 2>&1; then
  STATUS_JSON="$(printf '%s' "$STATUS_TEXT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || true)"
fi

if [ -z "$STATUS_JSON" ]; then
  _log "no JSON encoder available (jq, python, python3 all missing)"
  emit_continue_only
fi

# ---- Validate the encoded string is real JSON --------------------------------
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$STATUS_JSON" | jq -e . >/dev/null 2>&1; then
    _log "STATUS_JSON failed to validate as JSON; falling back to plain"
    emit_continue_only
  fi
fi

# ---- Emit Claude Code SessionStart envelope ----------------------------------
# additionalContext is a JSON string. The hook protocol passes this to the model.
printf '{"continue":true,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$STATUS_JSON"
exit 0