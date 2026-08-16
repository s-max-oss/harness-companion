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
# Codex r5 defect 1: step 5b/5c/5d require (a) the per-command log files
# referenced by log_artifact to exist on disk with matching SHA, and (b) a
# config.json declaring the matching argv for each command_origin=configured
# command. The golden valid log references typecheck/unit-test with real SHAs
# recorded in the file — create the per-command logs with deterministic content
# whose SHA equals the recorded value, and create a config.json so the
# command-array-match check has an anchor.
mkdir -p "$TMPDIR/.harness/logs/runs/20260731T151257Z-12345-32767"
printf 'synthetic typecheck log\n' > "$TMPDIR/.harness/logs/runs/20260731T151257Z-12345-32767/typecheck.log"
printf 'synthetic unit-test log\n' > "$TMPDIR/.harness/logs/runs/20260731T151257Z-12345-32767/unit-test.log"
cat > "$TMPDIR/.harness/config.json" <<'CFG'
{
  "version": 1,
  "verification": {
    "commands": [
      {"id": "typecheck", "command": ["npx","tsc","--noEmit"], "required_for_passing": true, "command_origin": "configured", "confirmation": "not_required"},
      {"id": "unit-test", "command": ["npm","run","test"], "required_for_passing": true, "command_origin": "configured", "confirmation": "not_required"},
      {"id": "c1", "command": ["echo"], "required_for_passing": false, "command_origin": "configured", "confirmation": "not_required"},
      {"id": "c2", "command": ["echo"], "required_for_passing": false, "command_origin": "configured", "confirmation": "not_required"},
      {"id": "c3", "command": ["echo"], "required_for_passing": false, "command_origin": "configured", "confirmation": "not_required"},
      {"id": "dupcmd", "command": ["echo"], "required_for_passing": false, "command_origin": "configured", "confirmation": "not_required"},
      {"id": "other", "command": ["echo"], "required_for_passing": false, "command_origin": "configured", "confirmation": "not_required"}
    ]
  }
}
CFG

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

# Codex r6: structural tests (Steps 12-15) build hand-crafted fixtures whose
# command_completed events previously used the empty log_artifact + null
# log_sha256 sentinel. Under the new fail-closed validator (an exit_code != 127
# must carry a real artifact), those fixtures must declare a real artifact
# on disk so they can exercise their OWN invariant (terminal counts,
# command_id uniqueness, etc.) instead of being rejected at the artifact
# check first. The helpers below materialize the per-command log file and
# emit a single command_completed JSON line with the matching sha256.
#
# _mk_cmd_log <run_id> <cmd_id> [<content>]
#   Writes "$TMPDIR/.harness/logs/runs/<run_id>/<cmd_id>.log" with the given
#   content (default: "log for <run_id>/<cmd_id>\n") and echoes the
#   project-relative path (POSIX-style — validator prefixes with project_dir).
_mk_cmd_log() {
  local run_id="$1" cmd_id="$2" content="${3:-log for ${run_id}/${cmd_id}\n}"
  mkdir -p "$TMPDIR/.harness/logs/runs/${run_id}"
  printf '%s' "$content" > "$TMPDIR/.harness/logs/runs/${run_id}/${cmd_id}.log"
  printf '.harness/logs/runs/%s/%s.log' "$run_id" "$cmd_id"
}

# _cmd_completed <run_id> <cmd_id> <command_json> <command_origin> <confirmation> <exit_code> [<duration_ms>]
#   Emits a single command_completed JSON line with a real log_artifact and
#   matching log_sha256 derived from _mk_cmd_log above.
_cmd_completed() {
  local run_id="$1" cmd_id="$2" command_json="$3" origin="$4" confirmation="$5" exit_code="$6" duration="${7:-100}"
  local rel; rel="$(_mk_cmd_log "$run_id" "$cmd_id")"
  local sha; sha="$(sha256sum "$TMPDIR/$rel" | awk '{print $1}')"
  printf '{"event":"command_completed","schema_version":2,"run_id":"%s","command_id":"%s","command":%s,"command_origin":"%s","confirmation":"%s","exit_code":%s,"started_at":"2026-01-01T00:00:00Z","duration_ms":%s,"log_artifact":"%s","log_sha256":"%s"}\n' \
    "$run_id" "$cmd_id" "$command_json" "$origin" "$confirmation" "$exit_code" "$duration" "$rel" "$sha"
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
{"event":"command_completed","schema_version":2,"run_id":"t03","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":"","log_sha256":null}
{"event":"run_completed","schema_version":2,"run_id":"t03","completed_at":"2026-01-01T00:00:00Z","overall_result":"no_checks","workspace_fingerprint_verified":"fp","planned_commands":0,"executed_commands":0,"passed_commands":0,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "command_completed missing command_id" "t03" "invalid_event_fields"

# Invalid command_origin
cat > "$TMPDIR/.harness/logs/runs/t04.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"t04","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"t04","command_id":"c1","command":["echo"],"command_origin":"magic","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":"","log_sha256":null}
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

cat > "$TMPDIR/.harness/logs/runs/t09.ndjson" <<EOF
$(_cmd_completed t09 c1 '["echo"]' configured not_required 0)
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

cat > "$TMPDIR/.harness/logs/runs/t12.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t12","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
$(_cmd_completed t12 c1 '["echo"]' configured not_required 0)
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

cat > "$TMPDIR/.harness/logs/runs/t14.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t14","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["dupcmd","dupcmd","other"],"capability_level":1,"feature_id":null}
$(_cmd_completed t14 dupcmd '["echo"]' configured not_required 0)
$(_cmd_completed t14 dupcmd '["echo"]' configured not_required 0)
$(_cmd_completed t14 other  '["echo"]' configured not_required 0)
{"event":"run_completed","schema_version":2,"run_id":"t14","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":3,"executed_commands":3,"passed_commands":3,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "duplicate command_id in command_completed events" "t14" "duplicate_required_command_id"

# ============================================================================
# Step 13: Missing required command
# ============================================================================
echo ""
echo "=== Step 13: Required command coverage ==="

cat > "$TMPDIR/.harness/logs/runs/t15.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t15","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1","c2"],"capability_level":1,"feature_id":null}
$(_cmd_completed t15 c1 '["echo"]' configured not_required 0)
{"event":"run_completed","schema_version":2,"run_id":"t15","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":2,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":1}
EOF
assert_invalid "missing required command coverage" "t15" "missing_required_command"

# ============================================================================
# Step 14: Terminal count invariants
# ============================================================================
echo ""
echo "=== Step 14: Terminal count invariants ==="

# 14a: executed != passed + failed
cat > "$TMPDIR/.harness/logs/runs/t16.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t16","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
$(_cmd_completed t16 c1 '["echo"]' configured not_required 0)
{"event":"run_completed","schema_version":2,"run_id":"t16","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":5,"passed_commands":1,"failed_commands":1,"skipped_commands":0}
EOF
assert_invalid "executed != passed + failed" "t16" "executed_count_invariant"

# 14b: planned != executed + skipped
cat > "$TMPDIR/.harness/logs/runs/t17.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t17","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
$(_cmd_completed t17 c1 '["echo"]' configured not_required 0)
{"event":"run_completed","schema_version":2,"run_id":"t17","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":99,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "planned != executed + skipped" "t17" "planned_count_invariant"

# 14c: planned > required_command_ids.length is VALID (optional commands allowed)
# required=["c1","c2"] (length=2), all required completed + 1 optional (c3),
# terminal says planned=3 (because optional command exists), executed=2, passed=1, failed=1, skipped=1
# v2 fix: required_command_ids is a subset of planned — planned >= required is OK.
cat > "$TMPDIR/.harness/logs/runs/t18.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t18","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1","c2"],"capability_level":1,"feature_id":null}
$(_cmd_completed t18 c1 '["echo"]' configured not_required 1)
$(_cmd_completed t18 c2 '["echo"]' configured not_required 0)
{"event":"run_completed","schema_version":2,"run_id":"t18","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":3,"executed_commands":2,"passed_commands":1,"failed_commands":1,"skipped_commands":1}
EOF
assert_valid "planned > required (optional commands) is valid" "t18"

# 14d: command_completed events != executed
# required=["c1","c2"], both completed (2 events), but terminal says executed=1
cat > "$TMPDIR/.harness/logs/runs/t19.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t19","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1","c2"],"capability_level":1,"feature_id":null}
$(_cmd_completed t19 c1 '["echo"]' configured not_required 0)
$(_cmd_completed t19 c2 '["echo"]' configured not_required 0)
{"event":"run_completed","schema_version":2,"run_id":"t19","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":2,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":1}
EOF
assert_invalid "command_completed count != executed" "t19" "command_event_count_mismatch"

# ============================================================================
# Step 15: Origin–confirmation invariants
# ============================================================================
echo ""
echo "=== Step 15: Origin–confirmation invariants ==="

# configured with non-not_required confirmation
cat > "$TMPDIR/.harness/logs/runs/t20.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t20","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
$(_cmd_completed t20 c1 '["echo"]' configured confirmed 0)
{"event":"run_completed","schema_version":2,"run_id":"t20","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "configured command with confirmed (not not_required)" "t20" "origin_confirmation_invariant"

# detected with non-confirmed confirmation
cat > "$TMPDIR/.harness/logs/runs/t21.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"t21","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
$(_cmd_completed t21 c1 '["echo"]' detected pending 0)
{"event":"run_completed","schema_version":2,"run_id":"t21","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "detected command with pending (not confirmed)" "t21" "origin_confirmation_invariant"

# ============================================================================
# Step 5b/5c/5d (Codex r5 defect 1): command execution evidence forgery
# ============================================================================
echo ""
echo "=== Step 5b/5c/5d: command execution evidence forgery ==="

# 5b: log_artifact file must exist on disk. Forge a NDJSON with a non-empty
# log_artifact pointing to a file that is NOT on disk → must be rejected.
mkdir -p "$TMPDIR/.harness/logs/runs/forgery1"
cat > "$TMPDIR/.harness/logs/runs/forgery1.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"forgery1","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"forgery1","command_id":"c1","command":["x"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":".harness/logs/runs/forgery1/nonexistent.log","log_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"event":"run_completed","schema_version":2,"run_id":"forgery1","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "5b: non-empty log_artifact pointing to nonexistent file rejected" "forgery1" "log_artifact_missing"

# 5b: log_artifact is a SYMLINK → rejected before [ -f ] follows the link.
# The recorded log_sha256 must equal the symlink target's SHA so step 5c
# (recompute + match) would PASS — only step 5b's symlink rejection should
# fire. Otherwise step 5c fires first and the test would reject with the
# wrong reason. On MSYS bash, `ln -s` may silently COPY instead of linking
# (a regular file would not exercise the reject-symlink path); in that
# environment this test is SKIPPED rather than false-failed.
mkdir -p "$TMPDIR/.harness/logs/runs/forgery2"
printf 'symlink target\n' > "$TMPDIR/.harness/logs/runs/forgery2/real.log"
REAL2_SHA="$(sha256sum "$TMPDIR/.harness/logs/runs/forgery2/real.log" | awk '{print $1}')"
if ln -s "$TMPDIR/.harness/logs/runs/forgery2/real.log" "$TMPDIR/.harness/logs/runs/forgery2/symlink.log" 2>/dev/null \
   && [ -L "$TMPDIR/.harness/logs/runs/forgery2/symlink.log" ]; then
  cat > "$TMPDIR/.harness/logs/runs/forgery2.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"forgery2","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"forgery2","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":".harness/logs/runs/forgery2/symlink.log","log_sha256":"$REAL2_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"forgery2","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
  assert_invalid "5b: log_artifact as symlink rejected" "forgery2" "log_artifact_symlink"
else
  echo "  [SKIP] 5b log_artifact symlink — real symlink creation unsupported on this platform"
  SKIPPED=$((SKIPPED + 1))
fi

# 5c: log_sha256 does NOT match the actual sha256 of log_artifact → rejected.
mkdir -p "$TMPDIR/.harness/logs/runs/forgery3"
printf 'actual content\n' > "$TMPDIR/.harness/logs/runs/forgery3/c.log"
ACTUAL_FORGERY3="$(sha256sum "$TMPDIR/.harness/logs/runs/forgery3/c.log" | awk '{print $1}')"
cat > "$TMPDIR/.harness/logs/runs/forgery3.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"forgery3","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"forgery3","command_id":"c1","command":["x"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":".harness/logs/runs/forgery3/c.log","log_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"event":"run_completed","schema_version":2,"run_id":"forgery3","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "5c: log_sha256 mismatch rejected (recorded != recomputed)" "forgery3" "log_sha256_mismatch"

# 5b/5c regression (Windows/MSYS): harness-verify.sh records project_root and
# log_artifact as mixed-style "D:/..." paths on Windows. The old /*-only case
# treated drive-letter paths as relative and prefixed them with $project_dir,
# producing a broken path and a false log_artifact_missing. Verify the resolver
# treats drive-letter paths as absolute while still prefixing true relatives.
WL_A="$(_vl_resolve_abs_path "D:/foo/bar.log" "/proj")"
WL_B="$(_vl_resolve_abs_path 'D:\foo\bar.log' "/proj")"
WL_C="$(_vl_resolve_abs_path "rel/foo.log" "/proj")"
WL_D="$(_vl_resolve_abs_path "/abs/foo.log" "/proj")"
if [ "$WL_A" = "D:/foo/bar.log" ] \
   && [ "$WL_B" = 'D:\foo\bar.log' ] \
   && [ "$WL_C" = "/proj/rel/foo.log" ] \
   && [ "$WL_D" = "/abs/foo.log" ]; then
  echo "PASS: 5b/5c: drive-letter + POSIX absolute + relative path resolution"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: 5b/5c: _vl_resolve_abs_path (A=$WL_A B=$WL_B C=$WL_C D=$WL_D)"
  FAILED=$((FAILED + 1))
fi

# End-to-end positive: on Windows/MSYS, a real file referenced by a drive-letter
# absolute log_artifact must pass 5b/5c (not be prefixed into a broken path).
if command -v cygpath >/dev/null 2>&1; then
  mkdir -p "$TMPDIR/.harness/logs/runs/winpath"
  printf 'winpath log content\n' > "$TMPDIR/.harness/logs/runs/winpath/win.log"
  WIN_ABS="$(cygpath -m "$TMPDIR/.harness/logs/runs/winpath/win.log")"
  WIN_SHA="$(sha256sum "$TMPDIR/.harness/logs/runs/winpath/win.log" | awk '{print $1}')"
  cat > "$TMPDIR/.harness/logs/runs/winpath.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"winpath","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"winpath","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":"$WIN_ABS","log_sha256":"$WIN_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"winpath","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
  assert_valid "5b/5c: drive-letter absolute log_artifact accepted end-to-end" "winpath"
else
  echo "  [SKIP] 5b/5c drive-letter end-to-end positive — non-Windows platform"
  SKIPPED=$((SKIPPED + 1))
fi

# 5b: log_artifact containment (real-path, Codex r7 item 2) — a recorded
# log_artifact MUST resolve inside project_dir after '.'/'..' and symlinks are
# collapsed. These fixtures all record a CORRECT log_sha256 so only the
# containment step can reject — proving containment (not a sha mismatch) fires.
OUTSIDE_ESC="$(mktemp -d)"
printf 'outside log\n' > "$OUTSIDE_ESC/outside.log"
OUTSIDE_ESC_SHA="$(sha256sum "$OUTSIDE_ESC/outside.log" | awk '{print $1}')"

# (a) absolute path pointing outside the project dir → rejected
mkdir -p "$TMPDIR/.harness/logs/runs/esc1"
cat > "$TMPDIR/.harness/logs/runs/esc1.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"esc1","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"esc1","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":"$OUTSIDE_ESC/outside.log","log_sha256":"$OUTSIDE_ESC_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"esc1","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "5b: absolute log_artifact outside project rejected" "esc1" "log_artifact_outside_project"

# (b) relative '../' escape — walk up out of the project root into a sibling dir
REL_ESCAPE="../$(basename "$OUTSIDE_ESC")/outside.log"
mkdir -p "$TMPDIR/.harness/logs/runs/esc2"
cat > "$TMPDIR/.harness/logs/runs/esc2.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"esc2","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"esc2","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":"$REL_ESCAPE","log_sha256":"$OUTSIDE_ESC_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"esc2","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "5b: '../' escape log_artifact rejected" "esc2" "log_artifact_outside_project"

# (c) parent-directory symlink escape — the artifact's PARENT dir is a symlink
# pointing outside the project; a string-prefix check would pass but real-path
# containment must reject. Skipped where ln -s silently copies.
if ln -s "$OUTSIDE_ESC" "$TMPDIR/.harness/logs/runs/esc3" 2>/dev/null \
   && [ -L "$TMPDIR/.harness/logs/runs/esc3" ]; then
  cat > "$TMPDIR/.harness/logs/runs/esc3.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"esc3","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"esc3","command_id":"c1","command":["echo"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":".harness/logs/runs/esc3/outside.log","log_sha256":"$OUTSIDE_ESC_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"esc3","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
  assert_invalid "5b: parent-directory symlink escape rejected" "esc3" "log_artifact_outside_project"
else
  echo "  [SKIP] 5b parent-directory symlink escape — real symlink creation unsupported on this platform"
  SKIPPED=$((SKIPPED + 1))
fi

# 5d: forged command array (doesn't match config) → rejected. The command
# "c1" is not declared in TMPDIR/.harness/config.json so command_not_in_config
# fires first; use a declared command_id with a forged argv to test the
# command_array_mismatch path specifically.
mkdir -p "$TMPDIR/.harness/logs/runs/forgery4"
printf 'log content\n' > "$TMPDIR/.harness/logs/runs/forgery4/typecheck.log"
FORGERY4_SHA="$(sha256sum "$TMPDIR/.harness/logs/runs/forgery4/typecheck.log" | awk '{print $1}')"
cat > "$TMPDIR/.harness/logs/runs/forgery4.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"forgery4","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["typecheck"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"forgery4","command_id":"typecheck","command":["true"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":".harness/logs/runs/forgery4/typecheck.log","log_sha256":"$FORGERY4_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"forgery4","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "5d: forged command array rejected (command:[\"true\"] vs config argv)" "forgery4" "command_array_mismatch"

# 5d: command_id declared in log but NOT in config → rejected.
# Use an id that is absent from TMPDIR/.harness/config.json so step 5d
# finds it in the config map but the lookup misses → command_not_in_config
# (rather than command_array_mismatch, which fires first when the id IS
# present with mismatching argv).
mkdir -p "$TMPDIR/.harness/logs/runs/forgery5"
printf 'log content\n' > "$TMPDIR/.harness/logs/runs/forgery5/not-in-config-id.log"
FORGERY5_SHA="$(sha256sum "$TMPDIR/.harness/logs/runs/forgery5/not-in-config-id.log" | awk '{print $1}')"
cat > "$TMPDIR/.harness/logs/runs/forgery5.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"forgery5","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["not-in-config-id"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"forgery5","command_id":"not-in-config-id","command":["true"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":".harness/logs/runs/forgery5/not-in-config-id.log","log_sha256":"$FORGERY5_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"forgery5","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "5d: command_id in log but not in config rejected" "forgery5" "command_not_in_config"

# 5d: configured origin with no config.json present → fail-closed.
# Remove the config so any configured-origin event fails closed.
mv "$TMPDIR/.harness/config.json" "$TMPDIR/.harness/config.json.bak"
mkdir -p "$TMPDIR/.harness/logs/runs/forgery6"
printf 'log content\n' > "$TMPDIR/.harness/logs/runs/forgery6/c1.log"
FORGERY6_SHA="$(sha256sum "$TMPDIR/.harness/logs/runs/forgery6/c1.log" | awk '{print $1}')"
cat > "$TMPDIR/.harness/logs/runs/forgery6.ndjson" <<EOF
{"event":"run_started","schema_version":2,"run_id":"forgery6","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["c1"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"forgery6","command_id":"c1","command":["true"],"command_origin":"configured","confirmation":"not_required","exit_code":0,"started_at":"2026-01-01T00:00:00Z","duration_ms":100,"log_artifact":".harness/logs/runs/forgery6/c1.log","log_sha256":"$FORGERY6_SHA"}
{"event":"run_completed","schema_version":2,"run_id":"forgery6","completed_at":"2026-01-01T00:00:00Z","overall_result":"passed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":1,"failed_commands":0,"skipped_commands":0}
EOF
assert_invalid "5d: configured origin without config.json fail-closed" "forgery6" "configured_command_without_config"
# Restore the config for any subsequent tests
mv "$TMPDIR/.harness/config.json.bak" "$TMPDIR/.harness/config.json"

# Positive: legitimate missing-tool sentinel — empty log_artifact + null
# log_sha256 + exit_code=127 (harness-verify emits this when argv[0] not on PATH).
# The command_id IS in config (it's a configured command that just happens to
# be missing on PATH); the recorded argv must still match config to satisfy
# step 5d. The terminal event is `run_failed` (not `run_completed`) because
# harness-verify.sh lines 607-639 emit run_failed when failed_commands > 0.
mkdir -p "$TMPDIR/.harness/logs/runs"
cat > "$TMPDIR/.harness/logs/runs/forgery7.ndjson" <<'EOF'
{"event":"run_started","schema_version":2,"run_id":"forgery7","started_at":"2026-01-01T00:00:00Z","project_root":"/x","workspace_fingerprint_initial":"fp","config_sha256":"cs","required_command_ids":["typecheck"],"capability_level":1,"feature_id":null}
{"event":"command_completed","schema_version":2,"run_id":"forgery7","command_id":"typecheck","command":["npx","tsc","--noEmit"],"command_origin":"configured","confirmation":"not_required","exit_code":127,"started_at":"2026-01-01T00:00:00Z","duration_ms":0,"log_artifact":"","log_sha256":null}
{"event":"run_failed","schema_version":2,"run_id":"forgery7","completed_at":"2026-01-01T00:00:00Z","overall_result":"failed","workspace_fingerprint_verified":"fp","planned_commands":1,"executed_commands":1,"passed_commands":0,"failed_commands":1,"skipped_commands":0,"failed_command_ids":["typecheck"]}
EOF
assert_valid "5b/5c/5d: legitimate missing-tool sentinel (empty log_artifact, null log_sha256) accepted" "forgery7"

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
