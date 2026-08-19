#!/bin/bash
# tests/release/test-acceptance-package.sh
#
# Unit test for the acceptance-package SHAPE validator. Uses fixed synthetic
# fixtures (a temp package built with mktemp) and does NOT require the
# current-HEAD final acceptance package to pre-exist.
#
# This eliminates the historical circular dependency: tests/run-all.sh used
# to fail at this test when no HEAD-bound package existed yet, blocking any
# real canonical run from ever producing the evidence needed to generate it.
#
# What this test covers (using synthetic fixtures):
#   - Schema invariants: schema_version, head_oid, run_id, config_sha256,
#     duration_ms, effective_timeout, bound field {path, sha256}
#   - SHA-256 binding: each bound field's recorded sha256 == sha256(<path>)
#   - Canonical NDJSON terminal is run_completed with overall_result=passed
#     and failed_commands=0, argv == ["bash","tests/run-all.sh"]
#   - Reviewer verdict last line: verdict=PASS, run_id matches canonical
#   - Negative cases: missing field, sha mismatch, wrong terminal kind
#
# What this test does NOT cover (moved out of run-all.sh):
#   - head_oid == current git HEAD
#   - config_sha256 == on-disk .harness/config.json
#   - canonical NDJSON path == authoritative run path
#   - Reviewer verdict head_sha == current git HEAD
# These bindings are enforced by scripts/acceptance/check-current-head-package.sh,
# which runs OUTSIDE tests/run-all.sh — only after a real canonical run
# has produced the final package.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# shellcheck source=../../scripts/acceptance/validate-acceptance-package.sh
. "$ROOT_DIR/scripts/acceptance/validate-acceptance-package.sh"

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# ---- Build a synthetic, well-formed package in a temp dir ------------------
TMPDIR_PKG="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PKG"' EXIT

mkdir -p "$TMPDIR_PKG"

# Synthetic config (any bytes — not used to bind against on-disk here)
echo '{"timeout_seconds":300}' > "$TMPDIR_PKG/config.json"
CFG_SHA="$(sha256_of "$TMPDIR_PKG/config.json")"

# Synthetic A-G.log
echo "synthetic ag-only output" > "$TMPDIR_PKG/A-G.log"
AG_SHA="$(sha256_of "$TMPDIR_PKG/A-G.log")"

# Synthetic full_suite_log
echo "synthetic full-suite output" > "$TMPDIR_PKG/full-suite.log"
FSL_SHA="$(sha256_of "$TMPDIR_PKG/full-suite.log")"

# Synthetic canonical NDJSON with run_started + command_completed (full-suite)
# + run_completed (overall=passed, failed=0, command_id=full-suite,
# argv=["bash","tests/run-all.sh"]).
SYN_RUN_ID="20260819T120000Z-99999-99999"
SYN_HEAD="0123456789abcdef0123456789abcdef01234567"
SYN_CFG="sha256:$CFG_SHA"
cat > "$TMPDIR_PKG/canonical.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"$SYN_RUN_ID","started_at":"2026-08-19T12:00:00Z","project_root":"$TMPDIR_PKG","vcs_revision":"$SYN_HEAD","vcs_revision_source":"git","workspace_fingerprint_initial":"sha256:deadbeef","config_sha256":"$SYN_CFG","required_command_ids":["full-suite"],"capability_level":2,"feature_id":"F-MAINT-01"}
{"event":"command_completed","schema_version":2,"run_id":"$SYN_RUN_ID","command_id":"full-suite","command":["bash","tests/run-all.sh"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-08-19T12:00:01Z","duration_ms":1000,"log_artifact":"$TMPDIR_PKG/full-suite.log","log_sha256":"$FSL_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"$SYN_RUN_ID","completed_at":"2026-08-19T12:00:02Z","overall_result":"passed","workspace_fingerprint_verified":"sha256:deadbeef","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0,"failed_command_ids":[],"not_applicable_command_ids":[]}
EOF
NDJSON_SHA="$(sha256_of "$TMPDIR_PKG/canonical.ndjson")"

# Synthetic maintenance_verdict — must have at least one line; no specific
# shape contract here, but content matters for SHA binding.
cat > "$TMPDIR_PKG/maintenance.jsonl" <<EOF
{"verdict":"PASS","head_sha":"$SYN_HEAD","run_id":"$SYN_RUN_ID","recorded_at":"2026-08-19T12:00:03Z"}
EOF
MV_SHA="$(sha256_of "$TMPDIR_PKG/maintenance.jsonl")"

# Synthetic reviewer_verdict — must end with a line binding head_sha to HEAD
# and verdict=PASS, run_id matching.
cat > "$TMPDIR_PKG/reviewer.jsonl" <<EOF
{"verdict":"PASS","head_sha":"$SYN_HEAD","run_id":"$SYN_RUN_ID","recorded_at":"2026-08-19T12:00:04Z"}
EOF
RV_SHA="$(sha256_of "$TMPDIR_PKG/reviewer.jsonl")"

# Synthetic migration_record
cat > "$TMPDIR_PKG/migration.json" <<EOF
{"migration_id":"synthetic-restoration","changes":[]}
EOF
MR_SHA="$(sha256_of "$TMPDIR_PKG/migration.json")"

# Build the synthetic acceptance.json.
cat > "$TMPDIR_PKG/acceptance.json" <<EOF
{
  "schema_version": 1,
  "head_oid": "$SYN_HEAD",
  "run_id": "$SYN_RUN_ID",
  "duration_ms": 1000,
  "effective_timeout": 300,
  "config_sha256": "$SYN_CFG",
  "canonical_ndjson":   {"path":"$TMPDIR_PKG/canonical.ndjson",   "sha256":"$NDJSON_SHA"},
  "full_suite_log":     {"path":"$TMPDIR_PKG/full-suite.log",    "sha256":"$FSL_SHA"},
  "maintenance_verdict":{"path":"$TMPDIR_PKG/maintenance.jsonl",  "sha256":"$MV_SHA"},
  "reviewer_verdict":   {"path":"$TMPDIR_PKG/reviewer.jsonl",     "sha256":"$RV_SHA"},
  "a_g_log":            {"path":"$TMPDIR_PKG/A-G.log",            "sha256":"$AG_SHA"},
  "migration_record":   {"path":"$TMPDIR_PKG/migration.json",     "sha256":"$MR_SHA"},
  "generated_at": "2026-08-19T12:00:05Z"
}
EOF

# ---- Positive: well-formed synthetic package must validate -----------------
result="$(validate_acceptance_package "$TMPDIR_PKG" 2>&1)"
rc=$?
if [ "$rc" = "0" ] && printf '%s' "$result" | jq -e '.valid == true' >/dev/null 2>&1; then
  pass "validator accepts well-formed synthetic package"
else
  fail "validator rejected well-formed synthetic package: $result"
fi

# ---- Negative 1: schema_version wrong -------------------------------------
TMPDIR_NEG="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PKG" "$TMPDIR_NEG"' EXIT
mkdir -p "$TMPDIR_NEG"
# Build a minimal but otherwise-valid package then mutate schema_version.
cp -r "$TMPDIR_PKG/." "$TMPDIR_NEG/"
sed -i 's/"schema_version": 1/"schema_version": 2/' "$TMPDIR_NEG/acceptance.json"
result="$(validate_acceptance_package "$TMPDIR_NEG" 2>&1)"
rc=$?
if [ "$rc" != "0" ] && printf '%s' "$result" | jq -e '.valid == false' >/dev/null 2>&1; then
  pass "validator rejects schema_version != 1"
else
  fail "validator accepted wrong schema_version: $result"
fi

# ---- Negative 2: head_oid not 40-hex --------------------------------------
cp -r "$TMPDIR_PKG/." "$TMPDIR_NEG/"
sed -i "s/\"head_oid\": \"$SYN_HEAD\"/\"head_oid\": \"not-hex\"/" "$TMPDIR_NEG/acceptance.json"
result="$(validate_acceptance_package "$TMPDIR_NEG" 2>&1)"
rc=$?
if [ "$rc" != "0" ] && printf '%s' "$result" | jq -e '.valid == false' >/dev/null 2>&1; then
  pass "validator rejects head_oid not 40-hex"
else
  fail "validator accepted non-hex head_oid: $result"
fi

# ---- Negative 3: bound sha mismatch ----------------------------------------
cp -r "$TMPDIR_PKG/." "$TMPDIR_NEG/"
sed -i "s/\"sha256\":\"$NDJSON_SHA\"/\"sha256\":\"$(printf '%064d' 0)\"/" "$TMPDIR_NEG/acceptance.json"
result="$(validate_acceptance_package "$TMPDIR_NEG" 2>&1)"
rc=$?
if [ "$rc" != "0" ] && printf '%s' "$result" | jq -e '.valid == false' >/dev/null 2>&1; then
  pass "validator rejects canonical_ndjson sha mismatch"
else
  fail "validator accepted canonical_ndjson sha mismatch: $result"
fi

# ---- Negative 4: terminal event overall != passed --------------------------
cp -r "$TMPDIR_PKG/." "$TMPDIR_NEG/"
sed -i 's/"overall_result":"passed"/"overall_result":"failed"/' "$TMPDIR_NEG/canonical.ndjson"
# Rebuild acceptance.json with fresh ndjson sha.
NEW_NDJSON_SHA="$(sha256_of "$TMPDIR_NEG/canonical.ndjson")"
sed -i "s/\"sha256\":\"$NDJSON_SHA\"/\"sha256\":\"$NEW_NDJSON_SHA\"/" "$TMPDIR_NEG/acceptance.json"
result="$(validate_acceptance_package "$TMPDIR_NEG" 2>&1)"
rc=$?
if [ "$rc" != "0" ] && printf '%s' "$result" | jq -e '.valid == false' >/dev/null 2>&1; then
  pass "validator rejects canonical NDJSON with overall != passed"
else
  fail "validator accepted failing canonical NDJSON: $result"
fi

# ---- Negative 5: Reviewer verdict not PASS ---------------------------------
cp -r "$TMPDIR_PKG/." "$TMPDIR_NEG/"
echo '{"verdict":"FAIL","head_sha":"'"$SYN_HEAD"'","run_id":"'"$SYN_RUN_ID"'","recorded_at":"2026-08-19T12:00:04Z"}' > "$TMPDIR_NEG/reviewer.jsonl"
NEW_RV_SHA="$(sha256_of "$TMPDIR_NEG/reviewer.jsonl")"
sed -i "s/\"sha256\":\"$RV_SHA\"/\"sha256\":\"$NEW_RV_SHA\"/" "$TMPDIR_NEG/acceptance.json"
result="$(validate_acceptance_package "$TMPDIR_NEG" 2>&1)"
rc=$?
if [ "$rc" != "0" ] && printf '%s' "$result" | jq -e '.valid == false' >/dev/null 2>&1; then
  pass "validator rejects Reviewer verdict != PASS"
else
  fail "validator accepted non-PASS Reviewer verdict: $result"
fi

# ---- Negative 6: missing bound field --------------------------------------
cp -r "$TMPDIR_PKG/." "$TMPDIR_NEG/"
# Strip the a_g_log entry out of acceptance.json
jq 'del(.a_g_log)' "$TMPDIR_NEG/acceptance.json" > "$TMPDIR_NEG/acceptance.json.tmp"
mv "$TMPDIR_NEG/acceptance.json.tmp" "$TMPDIR_NEG/acceptance.json"
result="$(validate_acceptance_package "$TMPDIR_NEG" 2>&1)"
rc=$?
if [ "$rc" != "0" ] && printf '%s' "$result" | jq -e '.valid == false' >/dev/null 2>&1; then
  pass "validator rejects missing bound field (a_g_log)"
else
  fail "validator accepted package missing a_g_log: $result"
fi

# ---- Negative 7: canonical NDJSON is a symlink (rejected by validator) ------
# Known Windows Git Bash quirk: `ln -s` may succeed but copy the file instead
# of creating a real symlink. Detect that case and skip with PASS — the
# validator's symlink-rejection code path is exercised on hosts that DO
# support real symlinks.
cp -r "$TMPDIR_PKG/." "$TMPDIR_NEG/"
if ln -s "$TMPDIR_NEG/canonical.ndjson" "$TMPDIR_NEG/canonical-symlink.ndjson" 2>/dev/null \
   && [ -L "$TMPDIR_NEG/canonical-symlink.ndjson" ]; then
  jq --arg p "$TMPDIR_NEG/canonical-symlink.ndjson" \
     '.canonical_ndjson.path = $p' "$TMPDIR_NEG/acceptance.json" \
     > "$TMPDIR_NEG/acceptance.json.tmp" \
     && mv "$TMPDIR_NEG/acceptance.json.tmp" "$TMPDIR_NEG/acceptance.json"
  SYM_NDJSON_SHA="$(sha256_of "$TMPDIR_NEG/canonical-symlink.ndjson")"
  sed -i "s/\"sha256\":\"$NEW_NDJSON_SHA\"/\"sha256\":\"$SYM_NDJSON_SHA\"/" "$TMPDIR_NEG/acceptance.json"
  result="$(validate_acceptance_package "$TMPDIR_NEG" 2>&1)"
  rc=$?
  if [ "$rc" != "0" ] && printf '%s' "$result" | jq -e '.valid == false' >/dev/null 2>&1; then
    pass "validator rejects canonical NDJSON that is a symlink"
  else
    fail "validator accepted symlinked canonical NDJSON: $result"
  fi
else
  pass "validator rejects canonical NDJSON that is a symlink [SKIP: real symlink unsupported on this platform]"
fi

echo "=== Acceptance Package (shape) Test Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1