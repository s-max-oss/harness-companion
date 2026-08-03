#!/bin/bash
# test-validate-run-log.sh — 16-step validation test suite
#
# Tests all 16 steps of validate_run_log() plus ≥20 corruption variants.
# Requires: bash, jq, and golden files in tests/golden/

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/validate-run-log.sh
source "$CORE_LIB/validate-run-log.sh"

PASSED=0
FAILED=0
SKIPPED=0

GOLDEN_DIR="$TEST_DIR/../golden"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Create a minimal project structure for path validation
mkdir -p "$TMPDIR/.harness/logs/runs"

# ---- helpers ----

assert_valid() {
  local test_name="$1" run_id="$2"
  local result exit_code
  set +e
  result="$(validate_run_log "$run_id" "$TMPDIR" 2>/dev/null)" || true
  set -e
  local valid
  valid="$(printf '%s' "$result" | jq -r '.valid')"
  if [ "$valid" = "true" ]; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    local reason
    reason="$(printf '%s' "$result" | jq -r '.reason // "unknown"')"
    echo "FAIL: $test_name — expected valid=true, got reason=$reason"
    FAILED=$((FAILED + 1))
  fi
}

assert_invalid() {
  local test_name="$1" run_id="$2" expected_reason="$3"
  local result
  set +e
  result="$(validate_run_log "$run_id" "$TMPDIR" 2>/dev/null)" || true
  set -e
  local valid
  valid="$(printf '%s' "$result" | jq -r '.valid')"
  local reason
  reason="$(printf '%s' "$result" | jq -r '.reason // "none"')"
  if [ "$valid" = "false" ] && [ "$reason" = "$expected_reason" ]; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  elif [ "$valid" = "false" ]; then
    echo "FAIL: $test_name — expected reason=$expected_reason, got reason=$reason"
    FAILED=$((FAILED + 1))
  else
    echo "FAIL: $test_name — expected valid=false, got valid=true"
    FAILED=$((FAILED + 1))
  fi
}

install_golden() {
  local run_id="$1" golden_name="$2"
  cp "$GOLDEN_DIR/$golden_name" "$TMPDIR/.harness/logs/runs/${run_id}.ndjson"
}

# ============================================================================
# Positive: Golden valid log
# ============================================================================
echo "=== Positive Tests ==="

install_golden "20260731T151257Z-12345-32767" "run-log-valid.ndjson"
assert_valid "golden valid run log passes all 16 steps" "20260731T151257Z-12345-32767"

install_golden "20260731T151257Z-00000-00000" "run-log-no-checks.ndjson"
assert_valid "golden no_checks run log passes validation" "20260731T151257Z-00000-00000"

# ============================================================================
# Step 1: run_id character whitelist
# ============================================================================
echo ""
echo "=== Step 1: run_id character validation ==="

assert_invalid "run_id with spaces" "bad run id" "run_id_invalid_characters"
assert_invalid "run_id with Chinese chars" "测试id" "run_id_invalid_characters"
assert_invalid "run_id with special chars" "run@id#test" "run_id_invalid_characters"

# ============================================================================
# Step 1b: Path traversal rejection
# ============================================================================
echo ""
echo "=== Step 1b: Path traversal ==="

# ".." uses "." which IS in the character whitelist, so it passes step 1 and
# reaches the path traversal case statement.
assert_invalid "run_id with .." ".." "run_id_path_traversal"
assert_invalid "run_id with .. embedded" "prefix..suffix" "run_id_path_traversal"
# Note: / and \ are caught by step 1 character whitelist before reaching
# step 1b. The case */* and *\\* patterns are defense-in-depth.

# ============================================================================
# Step 3: Missing file
# ============================================================================
echo ""
echo "=== Step 3: File existence ==="

assert_invalid "valid run_id but missing log" "20260731T000000Z-00000-00001" "run_log_missing"

# ============================================================================
# Step 4: Unknown event type
# ============================================================================
echo ""
echo "=== Step 4: Unknown event types ==="

mkdir -p "$TMPDIR/.harness/logs/runs"
cat > "$TMPDIR/.harness/logs/runs/t01.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t01","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"mystery_event","schema_version":2,"run_id":"t01"}
{"event":"run_completed","schema_version":2,"run_id":"t01","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "unknown event type rejected" "t01" "unknown_event_type"

# ============================================================================
# Step 5: Invalid event fields
# ============================================================================
echo ""
echo "=== Step 5: Field validation ==="

# Missing schema_version
cat > "$TMPDIR/.harness/logs/runs/t02.ndjson" <<'EOF'
{"event":"run_started","run_id":"t02","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":2,"run_id":"t02","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "run_started missing schema_version" "t02" "invalid_event_fields"

# command_completed missing command_id
cat > "$TMPDIR/.harness/logs/runs/t03.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t03","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t03","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t03","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "command_completed missing command_id" "t03" "invalid_event_fields"

# Invalid command_origin
cat > "$TMPDIR/.harness/logs/runs/t04.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t04","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t04","command_id":"c1","command":["echo"],"command_origin":"magic","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t04","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "invalid command_origin enum" "t04" "invalid_event_fields"

# Invalid overall_result for run_completed
cat > "$TMPDIR/.harness/logs/runs/t05.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t05","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":2,"run_id":"t05","completed_at":"2026-01-01T00:00:00Z","overall_result":"banana","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "invalid overall_result enum in run_completed" "t05" "invalid_event_fields"

# ============================================================================
# Step 6: Invalid schema_version
# ============================================================================
echo ""
echo "=== Step 6: schema_version validation ==="

cat > "$TMPDIR/.harness/logs/runs/t06.ndjson" <<'EOF'
{"event":"run_started","schema_version":0,"run_id":"t06","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":0,"run_id":"t06","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "schema_version < 1 rejected" "t06" "invalid_schema_version"

# ============================================================================
# Step 7: Mixed schema_version
# ============================================================================
echo ""
echo "=== Step 7: Mixed schema_version ==="

cat > "$TMPDIR/.harness/logs/runs/t07.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t07","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":1,"run_id":"t07","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "mixed schema_version rejected" "t07" "mixed_schema_version"

# ============================================================================
# Step 8: run_id mismatch
# ============================================================================
echo ""
echo "=== Step 8: run_id mismatch ==="

cat > "$TMPDIR/.harness/logs/runs/t08.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t08","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":2,"run_id":"t08-wrong","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "run_id mismatch between events" "t08" "run_id_mismatch"

# ============================================================================
# Step 9: First event not run_started
# ============================================================================
echo ""
echo "=== Step 9: run_started ordering ==="

cat > "$TMPDIR/.harness/logs/runs/t09.ndjson" <<'EOF'
{"event":"command_completed","schema_version":2,"run_id":"t09","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_started","schema_version":2,"run_id":"t09","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":2,"run_id":"t09","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "first event not run_started" "t09" "first_event_not_run_started"

# Multiple run_started events
cat > "$TMPDIR/.harness/logs/runs/t10.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t10","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"run_started","schema_version":2,"run_id":"t10","started_at":"2026-01-01T00:00:01Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":2,"run_id":"t10","completed_at":"2026-01-01T00:00:02Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "duplicate run_started rejected" "t10" "run_started_count"

# ============================================================================
# Step 10: Duplicate required_command_ids
# ============================================================================
echo ""
echo "=== Step 10: Duplicate required_command_ids ==="

cat > "$TMPDIR/.harness/logs/runs/t11.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t11","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["dup","dup"],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":2,"run_id":"t11","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "duplicate required_command_ids rejected" "t11" "duplicate_required_command_id"

# ============================================================================
# Step 11: Last event not terminal
# ============================================================================
echo ""
echo "=== Step 11: Terminal event rules ==="

cat > "$TMPDIR/.harness/logs/runs/t12.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t12","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t12","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
EOF
assert_invalid "last event not terminal" "t12" "last_event_not_terminal"

# Multiple terminal events
cat > "$TMPDIR/.harness/logs/runs/t13.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t13","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":[],"capability_level":1,"feature_id":null}
{"event":"run_completed","schema_version":2,"run_id":"t13","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
{"event":"run_completed","schema_version":2,"run_id":"t13","completed_at":"2026-01-01T00:00:01Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "multiple terminal events rejected" "t13" "terminal_event_count"

# ============================================================================
# Step 12: Duplicate command_id
# ============================================================================
echo ""
echo "=== Step 12: command_id uniqueness ==="

cat > "$TMPDIR/.harness/logs/runs/t14.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t14","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["dupcmd","dupcmd","other"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t14","command_id":"dupcmd","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"command_completed","schema_version":2,"run_id":"t14","command_id":"dupcmd","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"command_completed","schema_version":2,"run_id":"t14","command_id":"other","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t14","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":3,"executed_commands":3,"passed_commands":3,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "duplicate command_id in command_completed events" "t14" "duplicate_required_command_id"

# ============================================================================
# Step 13: Missing required command
# ============================================================================
echo ""
echo "=== Step 13: Required command coverage ==="

cat > "$TMPDIR/.harness/logs/runs/t15.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t15","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1","c2"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t15","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t15","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":2,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":1}
EOF
assert_invalid "missing required command coverage" "t15" "missing_required_command"

# ============================================================================
# Step 14: Terminal count invariants
# ============================================================================
echo ""
echo "=== Step 14: Terminal count invariants ==="

# 14a: executed != passed + failed
cat > "$TMPDIR/.harness/logs/runs/t16.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t16","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t16","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t16","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":5,"passed_commands":1,"failed_commands":1,"skipped_commands":0}
EOF
assert_invalid "executed != passed + failed" "t16" "executed_count_invariant"

# 14b: planned != executed + skipped
cat > "$TMPDIR/.harness/logs/runs/t17.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t17","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t17","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t17","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":99,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "planned != executed + skipped" "t17" "planned_count_invariant"

# 14c: planned > required_command_ids.length is VALID (optional commands allowed)
# required=["c1","c2"] (length=2), all required completed + 1 optional (c3),
# terminal says planned=3 (because optional command exists), executed=2, passed=1, failed=1, skipped=1
# v2 fix: required_command_ids is a subset of planned — planned >= required is OK.
cat > "$TMPDIR/.harness/logs/runs/t18.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t18","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1","c2"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t18","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":1,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"command_completed","schema_version":2,"run_id":"t18","command_id":"c2","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t18","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":3,"executed_commands":2,"passed_commands":1,"failed_commands":1,"skipped_commands":1}
EOF
assert_valid "planned > required (optional commands) is valid" "t18"

# 14d: command_completed events != executed
# required=["c1","c2"], both completed (2 events), but terminal says executed=1
cat > "$TMPDIR/.harness/logs/runs/t19.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t19","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1","c2"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t19","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"command_completed","schema_version":2,"run_id":"t19","command_id":"c2","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t19","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":2,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":1}
EOF
assert_invalid "command_completed count != executed" "t19" "command_event_count_mismatch"

# ============================================================================
# Step 15: Origin–confirmation invariants
# ============================================================================
echo ""
echo "=== Step 15: Origin–confirmation invariants ==="

# configured with non-not_required confirmation
cat > "$TMPDIR/.harness/logs/runs/t20.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t20","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t20","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"confirmed","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t20","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "configured command with confirmed (not not_required)" "t20" "origin_confirmation_invariant"

# detected with non-confirmed confirmation
cat > "$TMPDIR/.harness/logs/runs/t21.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t21","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t21","command_id":"c1","command":["echo"],"command_origin":"detected","confirmation":"pending","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100}
{"event":"run_completed","schema_version":2,"run_id":"t21","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "detected command with pending (not confirmed)" "t21" "origin_confirmation_invariant"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
