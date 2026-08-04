#!/bin/bash
# tests/adapters/_regen-fixtures.sh — RUNTIME-PORTABLE fixture regenerator
#
# Regenerates canonical NDJSON run logs + evidence associations for each
# adapter test fixture, using the production `harness-verify --write`. This
# ensures every fixture's NDJSON workspace_fingerprint matches the actual
# fingerprint of the fixture directory in its current location.
#
# Why this exists: previously, NDJSONs were checked into the repo with
# workspace_fingerprints computed at the source-tree location. When the
# tree was copied to a different path (or even when sibling files at the
# repo root changed, altering git-untracked-file state), the production
# fingerprint computation diverged from the baked-in value, and the
# staleness probe correctly flagged the evidence as stale.
#
# This script regenerates at test setup time, so tests pass in any copy
# location. It is idempotent — re-running produces equivalent state.
#
# Usage:
#   bash tests/adapters/_regen-fixtures.sh                # regen all fixtures
#   bash tests/adapters/_regen-fixtures.sh <fixture_id>   # regen one
#
# Called by the contract tests at their start. Does NOT need to be invoked
# manually in normal use.
#
# Side effects:
#   - Restores each fixture's feature_list.json from feature_list.template.json
#   - Deletes any existing NDJSON under .harness/logs/runs/
#   - Runs `harness-verify --write` against the fixture (may add new files
#     under .harness/logs/runs/<run_id>/)
#   - Mutates NDJSONs for variants (stale-run, corrupted-runlog, stale-evidence)
#   - Replaces evidence_associations for invalid-runid and no-association
#     with the test-specific shape

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIX_DIR="$ROOT_DIR/tests/adapters/fixtures"
VERIFY="$ROOT_DIR/core/harness-verify.sh"

# Must run from ROOT_DIR so harness-verify picks up core/ via relative path.
cd "$ROOT_DIR"

# ---- helper: restore fixture's feature_list.json from template ----------------
restore_template() {
  local fix="$1"
  if [ -f "$fix/feature_list.template.json" ]; then
    cp "$fix/feature_list.template.json" "$fix/feature_list.json"
  fi
}

# ---- helper: clear NDJSON state ------------------------------------------------
clear_runs() {
  local fix="$1"
  rm -f "$fix/.harness/logs/runs/"*.ndjson
  rm -rf "$fix/.harness/logs/runs"/*/ 2>/dev/null || true
  mkdir -p "$fix/.harness/logs/runs"
}

# ---- helper: get latest run_id for a feature ---------------------------------
latest_run_id() {
  local fix="$1" feature_id="$2"
  jq -r --arg fid "$feature_id" \
    '.features[] | select(.id == $fid) | .evidence_associations | last | .run_id // empty' \
    "$fix/feature_list.json"
}

# ---- helper: mutate workspace_fingerprint_verified to a known bad value -------
mutate_fingerprint_verified() {
  local ndjson="$1" new_value="$2"
  local tmp="${ndjson}.tmp"
  head -1 "$ndjson" > "$tmp"
  # Skip the first event (run_started) and update workspace_fingerprint_verified on the run_completed
  tail -n +2 "$ndjson" \
    | jq -c --arg fp "$new_value" \
        'if .event == "run_completed" then .workspace_fingerprint_verified = $fp else . end' \
    >> "$tmp"
  mv "$tmp" "$ndjson"
}

# ---- helper: inject NOT_A_JSON_LINE between run_started and run_completed ----
inject_corruption() {
  local ndjson="$1"
  local tmp="${ndjson}.tmp"
  head -1 "$ndjson" > "$tmp"
  echo "NOT_A_JSON_LINE" >> "$tmp"
  tail -n +2 "$ndjson" >> "$tmp"
  mv "$tmp" "$ndjson"
}

# ---- per-fixture regeneration ------------------------------------------------

regen_clean_project() {
  local fix="$FIX_DIR/clean-project"
  restore_template "$fix"
  clear_runs "$fix"
  bash "$VERIFY" feat-clean-001 "$fix" --write >/dev/null 2>&1
  local rid
  rid="$(latest_run_id "$fix" feat-clean-001)"
  echo "  clean-project: regenerated NDJSON $rid"
}

regen_stale_run() {
  local fix="$FIX_DIR/stale-run"
  restore_template "$fix"
  clear_runs "$fix"
  bash "$VERIFY" feat-stalerun-001 "$fix" --write >/dev/null 2>&1
  local rid
  rid="$(latest_run_id "$fix" feat-stalerun-001)"
  local ndjson="$fix/.harness/logs/runs/${rid}.ndjson"
  mutate_fingerprint_verified "$ndjson" "sha256:deadbeef0000000000000000000000000000000000000000000000000000beef"
  echo "  stale-run: regenerated + mutated fingerprint_verified to deadbeef"
}

regen_corrupted_runlog() {
  local fix="$FIX_DIR/corrupted-runlog"
  restore_template "$fix"
  clear_runs "$fix"
  bash "$VERIFY" feat-corrupt-001 "$fix" --write >/dev/null 2>&1
  local rid
  rid="$(latest_run_id "$fix" feat-corrupt-001)"
  local ndjson="$fix/.harness/logs/runs/${rid}.ndjson"
  inject_corruption "$ndjson"
  echo "  corrupted-runlog: regenerated + injected NOT_A_JSON_LINE"
}

regen_invalid_runid() {
  local fix="$FIX_DIR/invalid-runid"
  restore_template "$fix"
  clear_runs "$fix"
  # Generate a fresh NDJSON for the verification to pass (proves the chain works)
  bash "$VERIFY" feat-invrid-001 "$fix" --write >/dev/null 2>&1
  # Then REPLACE evidence_associations with a bogus run_id (the test target)
  jq '.features[0].evidence_associations = [{
    run_id: "20991231T000000Z-99999-99999",
    associated_at: "2026-08-01T11:00:00Z",
    associated_by: "user"
  }]' "$fix/feature_list.json" > "$fix/feature_list.json.tmp"
  mv "$fix/feature_list.json.tmp" "$fix/feature_list.json"
  # Delete the NDJSON we generated (the bogus run_id has no NDJSON by design)
  clear_runs "$fix"
  echo "  invalid-runid: regenerated + rewrote assoc to bogus run_id (no NDJSON)"
}

regen_no_association() {
  local fix="$FIX_DIR/no-association"
  restore_template "$fix"
  clear_runs "$fix"
  # Don't run harness-verify — the test target is feature with EMPTY associations.
  # legacy_audit_evidence stays as-is from template (proves legacy data is
  # NOT treated as canonical passing evidence).
  echo "  no-association: restored from template (empty evidence_associations, legacy preserved)"
}

regen_stale_evidence() {
  local fix="$FIX_DIR/stale-evidence"
  restore_template "$fix"
  clear_runs "$fix"
  bash "$VERIFY" feat-stale-001 "$fix" --write >/dev/null 2>&1
  bash "$VERIFY" feat-stale-002 "$fix" --write >/dev/null 2>&1
  local rid1 rid2
  rid1="$(latest_run_id "$fix" feat-stale-001)"
  rid2="$(latest_run_id "$fix" feat-stale-002)"
  # Mutate feat-stale-001's fingerprint_verified to make it stale-by-fingerprint.
  mutate_fingerprint_verified \
    "$fix/.harness/logs/runs/${rid1}.ndjson" \
    "sha256:deadbeef0000000000000000000000000000000000000000000000000000beef"
  # feat-stale-002 stays fresh (truthful FP).
  echo "  stale-evidence: feat-stale-001 mutated to stale, feat-stale-002 fresh"
}

regen_wip_violation() {
  local fix="$FIX_DIR/wip-violation"
  restore_template "$fix"
  clear_runs "$fix"
  # No harness-verify — this fixture tests WIP>1 with no run logs.
  echo "  wip-violation: restored from template (WIP=2, no NDJSONs)"
}

# ---- main --------------------------------------------------------------------
TARGET="${1:-all}"

case "$TARGET" in
  clean-project)       regen_clean_project ;;
  stale-run)           regen_stale_run ;;
  corrupted-runlog)    regen_corrupted_runlog ;;
  invalid-runid)       regen_invalid_runid ;;
  no-association)      regen_no_association ;;
  stale-evidence)      regen_stale_evidence ;;
  wip-violation)       regen_wip_violation ;;
  all)
    regen_clean_project
    regen_stale_run
    regen_corrupted_runlog
    regen_invalid_runid
    regen_no_association
    regen_stale_evidence
    regen_wip_violation
    ;;
  *)
    echo "Unknown fixture: $TARGET" >&2
    exit 1
    ;;
esac

echo ""
echo "=== regen complete for target=$TARGET ==="
exit 0
