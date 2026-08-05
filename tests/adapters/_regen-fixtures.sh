#!/bin/bash
# tests/adapters/_regen-fixtures.sh — RUNTIME-PORTABLE fixture regenerator
# (G0-rev3 §Harness-gate-1: regeneration runs entirely in a temp copy)
#
# Regenerates canonical NDJSON run logs + evidence associations for each
# adapter test fixture, using the production `harness-verify --write`.
#
# Why a temp copy: per the rc.2 G0-rev3 directive, all fixture-regeneration
# side effects (NDJSON creation, .harness mutation, fingerprint writes) must
# happen inside a temporary copy of the fixture. Only the resulting NDJSONs
# and feature_list.json are then atomically published back into the source
# fixture directory. The source fixture tree is NEVER written-to by
# `harness-verify` directly; the temp copy is the only place regeneration
# actually executes. This prevents accidental pollution of the source tree
# if regeneration fails partway.
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
#   - Source fixture's feature_list.json restored from feature_list.template.json
#   - Source fixture's NDJSONs deleted before publish
#   - Temp copy under ${TMPDIR:-/tmp}/regen-<pid>-<rand>/ is created, mutated,
#     and discarded at end (NEVER pollutes source tree)
#   - Only the final NDJSON + feature_list.json files are atomically
#     moved from temp copy → source fixture
#   - Mutates NDJSONs for variants (stale-run, corrupted-runlog, stale-evidence)
#   - Replaces evidence_associations for invalid-runid and no-association
#     with the test-specific shape

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# FIXTURES_DIR env var overrides the fixture root so contract tests can
# copy fixtures to a temp directory and regenerate there without mutating
# the source fixture tree (G0-rev4 contract test isolation).
FIX_DIR="${FIXTURES_DIR:-$ROOT_DIR/tests/adapters/fixtures}"
VERIFY="$ROOT_DIR/core/harness-verify.sh"

# Must run from ROOT_DIR so harness-verify picks up core/ via relative path.
cd "$ROOT_DIR"

# Track a registry of source paths we've touched so cleanup is reliable
declare -a TOUCHED_FILES=()
TMP_WORK=""
cleanup() {
  if [ -n "$TMP_WORK" ] && [ -d "$TMP_WORK" ]; then
    rm -rf -- "$TMP_WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---- helper: make a temp copy of a fixture ----------------------------------
make_temp_copy() {
  local src="$1"
  TMP_WORK="$(mktemp -d -t regen-XXXXXX 2>/dev/null || mktemp -d)"
  if [ -z "$TMP_WORK" ] || [ ! -d "$TMP_WORK" ]; then
    echo "FATAL: could not create temp work directory" >&2
    exit 1
  fi
  # Copy the entire fixture tree (preserving tracked + untracked) to TMP_WORK
  if command -v cp >/dev/null 2>&1; then
    cp -R "$src/." "$TMP_WORK/" 2>/dev/null || {
      echo "FATAL: cp -R failed from $src to $TMP_WORK" >&2
      exit 1
    }
  fi
  echo "$TMP_WORK"
}

# ---- helper: publish regenerated files from temp copy → source fixture -------
# This is the ONLY path that writes back to the source fixture tree.
# G0-rev4: also publishes run directories (for typecheck.log etc.) and
# feature_list.json so run_ids always match the NDJSONs that were written.
publish_from_temp() {
  local src_fix="$1"
  local tmp_work="$2"
  if [ -d "$tmp_work/.harness/logs/runs" ]; then
    mkdir -p "$src_fix/.harness/logs/runs"
    # Replace NDJSONs in source fixture
    rm -f "$src_fix/.harness/logs/runs/"*.ndjson 2>/dev/null || true
    for nd in "$tmp_work/.harness/logs/runs/"*.ndjson; do
      [ -f "$nd" ] || continue
      cp -f "$nd" "$src_fix/.harness/logs/runs/" 2>/dev/null || true
      TOUCHED_FILES+=("$src_fix/.harness/logs/runs/$(basename "$nd")")
    done
    # Also copy run directories (hold typecheck.log and other artifacts)
    for d in "$tmp_work/.harness/logs/runs/"/*/; do
      [ -d "$d" ] || continue
      rm -rf "$src_fix/.harness/logs/runs/$(basename "$d")" 2>/dev/null || true
      cp -R "$d" "$src_fix/.harness/logs/runs/" 2>/dev/null || true
    done
  fi
  # Publish feature_list.json so run_ids stay in sync with the NDJSONs written
  if [ -f "$tmp_work/feature_list.json" ]; then
    cp -f "$tmp_work/feature_list.json" "$src_fix/feature_list.json" 2>/dev/null || true
    TOUCHED_FILES+=("$src_fix/feature_list.json")
  fi
}

publish_feature_list() {
  local src_fix="$1"
  local tmp_work="$2"
  if [ -f "$tmp_work/feature_list.json" ]; then
    cp -f "$tmp_work/feature_list.json" "$src_fix/feature_list.json" 2>/dev/null || true
    TOUCHED_FILES+=("$src_fix/feature_list.json")
  fi
}

# ---- helper: restore fixture's feature_list.json from template ----------------
restore_template() {
  local fix="$1"
  if [ -f "$fix/feature_list.template.json" ]; then
    cp "$fix/feature_list.template.json" "$fix/feature_list.json"
  fi
}

# ---- helper: clear NDJSON state from SOURCE fixture ---------------------------
# We always clear the SOURCE before publishing from temp, so partial regen
# cannot leave stale NDJSONs behind.
clear_source_runs() {
  local fix="$1"
  rm -f "$fix/.harness/logs/runs/"*.ndjson 2>/dev/null || true
  rm -rf "$fix/.harness/logs/runs"/*/ 2>/dev/null || true
  mkdir -p "$fix/.harness/logs/runs"
}

# ---- helper: get latest run_id for a feature (reads from temp copy) ----------
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
#
# Every regen_* function now follows this pattern:
#   1. Copy the source fixture to a temp directory
#   2. Run all harness-verify / mutations INSIDE the temp copy
#   3. Atomically publish NDJSONs (and feature_list.json if regenerated)
#      from the temp copy back into the source fixture
#   4. Discard the temp copy via the EXIT trap
# The source fixture tree is NEVER directly mutated by `harness-verify`.

regen_clean_project() {
  local fix="$FIX_DIR/clean-project"
  clear_source_runs "$fix"
  local tmp
  tmp="$(make_temp_copy "$fix")"
  # Run harness-verify inside the temp copy
  bash "$VERIFY" feat-clean-001 "$tmp" --write >/dev/null 2>&1
  local rid
  rid="$(latest_run_id "$tmp" feat-clean-001)"
  publish_from_temp "$fix" "$tmp"
  echo "  clean-project: regenerated NDJSON $rid (in temp copy)"
}

regen_stale_run() {
  local fix="$FIX_DIR/stale-run"
  clear_source_runs "$fix"
  local tmp
  tmp="$(make_temp_copy "$fix")"
  bash "$VERIFY" feat-stalerun-001 "$tmp" --write >/dev/null 2>&1
  local rid
  rid="$(latest_run_id "$tmp" feat-stalerun-001)"
  local ndjson="$tmp/.harness/logs/runs/${rid}.ndjson"
  mutate_fingerprint_verified "$ndjson" "sha256:deadbeef0000000000000000000000000000000000000000000000000000beef"
  publish_from_temp "$fix" "$tmp"
  echo "  stale-run: regenerated + mutated fingerprint_verified to deadbeef (in temp copy)"
}

regen_corrupted_runlog() {
  local fix="$FIX_DIR/corrupted-runlog"
  clear_source_runs "$fix"
  local tmp
  tmp="$(make_temp_copy "$fix")"
  bash "$VERIFY" feat-corrupt-001 "$tmp" --write >/dev/null 2>&1
  local rid
  rid="$(latest_run_id "$tmp" feat-corrupt-001)"
  local ndjson="$tmp/.harness/logs/runs/${rid}.ndjson"
  inject_corruption "$ndjson"
  publish_from_temp "$fix" "$tmp"
  echo "  corrupted-runlog: regenerated + injected NOT_A_JSON_LINE (in temp copy)"
}

regen_invalid_runid() {
  local fix="$FIX_DIR/invalid-runid"
  clear_source_runs "$fix"
  local tmp
  tmp="$(make_temp_copy "$fix")"
  # Generate a fresh NDJSON for the verification to pass (proves the chain works)
  bash "$VERIFY" feat-invrid-001 "$tmp" --write >/dev/null 2>&1
  # Then REPLACE evidence_associations with a bogus run_id (the test target)
  jq '.features[0].evidence_associations = [{
    run_id: "20991231T000000Z-99999-99999",
    associated_at: "2026-08-01T11:00:00Z",
    associated_by: "user"
  }]' "$tmp/feature_list.json" > "$tmp/feature_list.json.tmp"
  mv "$tmp/feature_list.json.tmp" "$tmp/feature_list.json"
  # Delete the NDJSON we generated (the bogus run_id has no NDJSON by design)
  rm -f "$tmp/.harness/logs/runs/"*.ndjson 2>/dev/null || true
  # Publish only feature_list.json (no NDJSONs to publish)
  publish_from_temp "$fix" "$tmp"
  publish_feature_list "$fix" "$tmp"
  echo "  invalid-runid: regenerated + rewrote assoc to bogus run_id (in temp copy, NDJSONs discarded)"
}

regen_no_association() {
  local fix="$FIX_DIR/no-association"
  clear_source_runs "$fix"
  local tmp
  tmp="$(make_temp_copy "$fix")"
  # Restore template inside temp copy too — this fixture needs NO harness-verify
  if [ -f "$tmp/feature_list.template.json" ]; then
    cp "$tmp/feature_list.template.json" "$tmp/feature_list.json"
  fi
  publish_from_temp "$fix" "$tmp"
  publish_feature_list "$fix" "$tmp"
  echo "  no-association: restored from template inside temp copy (no harness-verify, no NDJSONs)"
}

regen_stale_evidence() {
  local fix="$FIX_DIR/stale-evidence"
  clear_source_runs "$fix"
  local tmp
  tmp="$(make_temp_copy "$fix")"
  bash "$VERIFY" feat-stale-001 "$tmp" --write >/dev/null 2>&1
  bash "$VERIFY" feat-stale-002 "$tmp" --write >/dev/null 2>&1
  local rid1 rid2
  rid1="$(latest_run_id "$tmp" feat-stale-001)"
  rid2="$(latest_run_id "$tmp" feat-stale-002)"
  mutate_fingerprint_verified \
    "$tmp/.harness/logs/runs/${rid1}.ndjson" \
    "sha256:deadbeef0000000000000000000000000000000000000000000000000000beef"
  publish_from_temp "$fix" "$tmp"
  echo "  stale-evidence: feat-stale-001 mutated to stale, feat-stale-002 fresh (in temp copy)"
}

regen_wip_violation() {
  local fix="$FIX_DIR/wip-violation"
  clear_source_runs "$fix"
  local tmp
  tmp="$(make_temp_copy "$fix")"
  if [ -f "$tmp/feature_list.template.json" ]; then
    cp "$tmp/feature_list.template.json" "$tmp/feature_list.json"
  fi
  publish_from_temp "$fix" "$tmp"
  publish_feature_list "$fix" "$tmp"
  echo "  wip-violation: restored from template inside temp copy (WIP=2, no NDJSONs)"
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
echo "=== regen complete for target=$TARGET (all side effects ran in temp copy; source fixture published atomically) ==="
exit 0