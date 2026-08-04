#!/bin/bash
# test-r4-contracts.sh — Phase 2 R4 schema→core contract tests
#
# Verifies the schema→core contract for:
#   1. has_files matches → command executes
#   2. has_files does not match → command skipped (not_applicable)
#   3. generic optional-only → terminal no_checks (overall_result=no_checks)
#   4. optional-only run MUST NOT produce passed
#   5. detected+pending → not executed
#   6. detected+rejected → not executed
#   7. configured+not_required → executes normally
#   8. Illegal origin/confirmation combinations rejected by schema or runtime
#
# Plus has_files schema validation (must use has_files, NOT files_any / package_json_has_script)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
CORE_LIB="$CORE_DIR/lib"
VERIFY_SCRIPT="$CORE_DIR/harness-verify.sh"

# shellcheck source=../../core/lib/validate-run-log.sh
source "$CORE_LIB/validate-run-log.sh"
# shellcheck source=../../core/lib/config-validate.sh
source "$CORE_LIB/config-validate.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

assert_pass() {
  local name="$1"
  echo "PASS: $name"
  PASSED=$((PASSED + 1))
}

assert_fail() {
  local name="$1" reason="$2"
  echo "FAIL: $name — $reason"
  FAILED=$((FAILED + 1))
}

run_verify() {
  set +e
  VERIFY_OUT="$("$VERIFY_SCRIPT" "$@" 2>&1)"
  VERIFY_RC=$?
}

# Find latest log file in a project dir
find_log() {
  local dir="$1"
  ls "$dir/.harness/logs/runs/"*.ndjson 2>/dev/null | head -1
}

# Read a JSON field from terminal event
terminal_field() {
  local log="$1" field="$2"
  jq -r "select(.event==\"run_completed\" or .event==\"run_failed\" or .event==\"run_aborted\") | .${field}" "$log" 2>/dev/null
}

# Count command_completed events with a given command_id
count_cmd_events() {
  local log="$1" cmd_id="$2"
  jq -r "select(.event==\"command_completed\" and .command_id==\"$cmd_id\") | .event" "$log" 2>/dev/null | wc -l
}

# Get a command_completed event for a given id
get_cmd_exit() {
  local log="$1" cmd_id="$2"
  jq -r "select(.event==\"command_completed\" and .command_id==\"$cmd_id\") | .exit_code" "$log" 2>/dev/null
}

# ============================================================================
# Test 1: has_files MATCH → command EXECUTES
# ============================================================================
echo ""
echo "=== Test 1: has_files match → command executes ==="
T1="$TMPROOT/t1"
mkdir -p "$T1"
git -C "$T1" init --quiet 2>/dev/null
git -C "$T1" config user.email "t@t"
git -C "$T1" config user.name "t"
git -C "$T1" config commit.gpgsign false
mkdir -p "$T1/.harness"
cat > "$T1/feature_list.json" <<'FL'
{"revision":1,"features":[{"id":"feat-1","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}],"last_updated":"2026-08-01"}
FL
# has_files=["package.json"] matches the package.json we create below
cat > "$T1/.harness/config.json" <<'CFG'
{
  "project_type": "node",
  "verification": {
    "commands": [
      {
        "id": "smoke-conditional",
        "command": ["bash", "-c", "echo conditional-ran && exit 0"],
        "required_for_passing": true,
        "command_origin": "configured",
        "confirmation": "not_required",
        "applies_when": { "has_files": ["package.json"] }
      }
    ]
  }
}
CFG
echo '{"name":"test"}' > "$T1/package.json"

run_verify "feat-1" "$T1"
LOG="$(find_log "$T1")"
if [ -z "$LOG" ]; then
  assert_fail "Test 1: log produced" "no log file"
else
  n_events="$(count_cmd_events "$LOG" "smoke-conditional")"
  if [ "$n_events" = "1" ]; then
    assert_pass "Test 1: has_files match → command executed (1 command_completed event)"
  else
    assert_fail "Test 1: has_files match → executed" "got $n_events command_completed events"
  fi
fi

# ============================================================================
# Test 2: has_files NO MATCH → command SKIPPED
# ============================================================================
echo ""
echo "=== Test 2: has_files no-match → command skipped ==="
T2="$TMPROOT/t2"
mkdir -p "$T2"
git -C "$T2" init --quiet 2>/dev/null
git -C "$T2" config user.email "t@t"
git -C "$T2" config user.name "t"
mkdir -p "$T2/.harness"
cp "$T1/feature_list.json" "$T2/feature_list.json"
# has_files=["package.json"] but NO package.json in T2 → skipped
cat > "$T2/.harness/config.json" <<'CFG'
{
  "project_type": "node",
  "verification": {
    "commands": [
      {
        "id": "smoke-conditional",
        "command": ["bash", "-c", "echo conditional-ran && exit 0"],
        "required_for_passing": true,
        "command_origin": "configured",
        "confirmation": "not_required",
        "applies_when": { "has_files": ["package.json"] }
      }
    ]
  }
}
CFG
# No package.json in T2!
run_verify "feat-1" "$T2"
LOG="$(find_log "$T2")"
if [ -z "$LOG" ]; then
  assert_fail "Test 2: log produced" "no log file"
else
  n_events="$(count_cmd_events "$LOG" "smoke-conditional")"
  # Skipped commands don't write command_completed events; they increment
  # SKIPPED counter in the terminal event. Check the output for [skip].
  if [ "$n_events" = "0" ] && printf '%s' "$VERIFY_OUT" | grep -q "\[skip\] smoke-conditional"; then
    assert_pass "Test 2: has_files no-match → command skipped (no command_completed, [skip] printed)"
  else
    assert_fail "Test 2: has_files no-match → skipped" "events=$n_events, output snippet: $(printf '%s' "$VERIFY_OUT" | grep -E 'skip|conditional' | head -3)"
  fi
fi

# ============================================================================
# Test 3: generic optional-only → terminal no_checks
# (also covers Test 4: optional-only MUST NOT produce passed)
# ============================================================================
echo ""
echo "=== Test 3: generic optional-only → no_checks (not passed) ==="
T3="$TMPROOT/t3"
mkdir -p "$T3"
git -C "$T3" init --quiet 2>/dev/null
git -C "$T3" config user.email "t@t"
git -C "$T3" config user.name "t"
mkdir -p "$T3/.harness"
cp "$T1/feature_list.json" "$T3/feature_list.json"
# generic config: only optional smoke command (mirrors templates/.harness/config.json.generic.example)
cat > "$T3/.harness/config.json" <<'CFG'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {
        "id": "smoke",
        "command": ["bash", "-c", "echo smoke && exit 0"],
        "required_for_passing": false,
        "command_origin": "configured",
        "confirmation": "not_required"
      }
    ]
  }
}
CFG

run_verify "feat-1" "$T3"
LOG="$(find_log "$T3")"
if [ -z "$LOG" ]; then
  assert_fail "Test 3: log produced" "no log file"
else
  overall="$(terminal_field "$LOG" "overall_result")"
  # Test 3 assertion: overall_result == "no_checks"
  if [ "$overall" = "no_checks" ]; then
    assert_pass "Test 3: generic optional-only → terminal overall_result=no_checks"
  else
    assert_fail "Test 3: generic optional-only → no_checks" "overall=$overall (rc=$VERIFY_RC)"
  fi
  # Test 4 assertion: optional-only run MUST NOT produce passed
  if [ "$overall" != "passed" ]; then
    assert_pass "Test 4: optional-only run does NOT produce passed (overall=$overall)"
  else
    assert_fail "Test 4: optional-only run produces passed" "FAIL: overall=passed"
  fi
fi

# ============================================================================
# Test 5: detected+pending → NOT executed
# ============================================================================
echo ""
echo "=== Test 5: detected+pending → skipped ==="
T5="$TMPROOT/t5"
mkdir -p "$T5"
git -C "$T5" init --quiet 2>/dev/null
git -C "$T5" config user.email "t@t"
git -C "$T5" config user.name "t"
mkdir -p "$T5/.harness"
cp "$T1/feature_list.json" "$T5/feature_list.json"
# required + detected+pending → would be FAILURE if executed (failed_commands>0)
# but pending → skipped (not failed). Pass condition: skipped, overall=passed
# (no required failed commands because nothing was required AND executed)
cat > "$T5/.harness/config.json" <<'CFG'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {
        "id": "user-must-review",
        "command": ["bash", "-c", "echo ran-detected-pending && exit 1"],
        "required_for_passing": true,
        "command_origin": "detected",
        "confirmation": "pending"
      }
    ]
  }
}
CFG

run_verify "feat-1" "$T5"
LOG="$(find_log "$T5")"
if [ -z "$LOG" ]; then
  assert_fail "Test 5: log produced" "no log file"
else
  n_exec="$(count_cmd_events "$LOG" "user-must-review")"
  # n_exec must be 0 — pending MUST NOT execute
  if [ "$n_exec" = "0" ] && printf '%s' "$VERIFY_OUT" | grep -q "detected+pending"; then
    assert_pass "Test 5: detected+pending → NOT executed (0 command_completed, [skip] printed)"
  else
    assert_fail "Test 5: detected+pending → skipped" "events=$n_exec, output: $(printf '%s' "$VERIFY_OUT" | grep -E 'skip|pending|user-must' | head -3)"
  fi
fi

# ============================================================================
# Test 6: detected+rejected → NOT executed
# ============================================================================
echo ""
echo "=== Test 6: detected+rejected → skipped ==="
T6="$TMPROOT/t6"
mkdir -p "$T6"
git -C "$T6" init --quiet 2>/dev/null
git -C "$T6" config user.email "t@t"
git -C "$T6" config user.name "t"
mkdir -p "$T6/.harness"
cp "$T1/feature_list.json" "$T6/feature_list.json"
cat > "$T6/.harness/config.json" <<'CFG'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {
        "id": "user-rejected",
        "command": ["bash", "-c", "echo ran-detected-rejected && exit 1"],
        "required_for_passing": true,
        "command_origin": "detected",
        "confirmation": "rejected"
      }
    ]
  }
}
CFG

run_verify "feat-1" "$T6"
LOG="$(find_log "$T6")"
if [ -z "$LOG" ]; then
  assert_fail "Test 6: log produced" "no log file"
else
  n_exec="$(count_cmd_events "$LOG" "user-rejected")"
  if [ "$n_exec" = "0" ] && printf '%s' "$VERIFY_OUT" | grep -q "detected+rejected"; then
    assert_pass "Test 6: detected+rejected → NOT executed (0 command_completed, [skip] printed)"
  else
    assert_fail "Test 6: detected+rejected → skipped" "events=$n_exec"
  fi
fi

# ============================================================================
# Test 7: configured+not_required → executes normally
# ============================================================================
echo ""
echo "=== Test 7: configured+not_required → executes normally ==="
T7="$TMPROOT/t7"
mkdir -p "$T7"
git -C "$T7" init --quiet 2>/dev/null
git -C "$T7" config user.email "t@t"
git -C "$T7" config user.name "t"
mkdir -p "$T7/.harness"
cp "$T1/feature_list.json" "$T7/feature_list.json"
cat > "$T7/.harness/config.json" <<'CFG'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {
        "id": "user-configured",
        "command": ["bash", "-c", "echo ran-configured && exit 0"],
        "required_for_passing": true,
        "command_origin": "configured",
        "confirmation": "not_required"
      }
    ]
  }
}
CFG

run_verify "feat-1" "$T7"
LOG="$(find_log "$T7")"
if [ -z "$LOG" ]; then
  assert_fail "Test 7: log produced" "no log file"
else
  n_exec="$(count_cmd_events "$LOG" "user-configured")"
  exit_code="$(get_cmd_exit "$LOG" "user-configured")"
  if [ "$n_exec" = "1" ] && [ "$exit_code" = "0" ]; then
    assert_pass "Test 7: configured+not_required → executed normally (1 event, exit_code=0)"
  else
    assert_fail "Test 7: configured+not_required → executed" "events=$n_exec, exit_code=$exit_code"
  fi
fi

# ============================================================================
# Test 8: Illegal origin/confirmation combinations REJECTED by schema
# ============================================================================
echo ""
echo "=== Test 8: illegal origin/confirmation combos rejected ==="
NEG="$TMPROOT/neg"
mkdir -p "$NEG"

# 8a: configured+pending → should be rejected by schema validator
cat > "$NEG/cfg-pending.json" <<'BAD'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"x","command":["bash","-c","true"],"required_for_passing":true,"command_origin":"configured","confirmation":"pending"}
    ]
  }
}
BAD
if validate_config_schema "$NEG/cfg-pending.json" 2>/dev/null; then
  assert_fail "8a: configured+pending rejected" "validator accepted it"
else
  err="$(validate_config_schema "$NEG/cfg-pending.json" 2>&1 >/dev/null)"
  if printf '%s' "$err" | grep -qi "configured+pending"; then
    assert_pass "8a: configured+pending rejected by schema (err mentions configured+pending)"
  else
    assert_fail "8a: configured+pending rejection message" "got: $err"
  fi
fi

# 8b: configured+rejected → should be rejected by schema validator
cat > "$NEG/cfg-rejected.json" <<'BAD'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"x","command":["bash","-c","true"],"required_for_passing":true,"command_origin":"configured","confirmation":"rejected"}
    ]
  }
}
BAD
if validate_config_schema "$NEG/cfg-rejected.json" 2>/dev/null; then
  assert_fail "8b: configured+rejected rejected" "validator accepted it"
else
  err="$(validate_config_schema "$NEG/cfg-rejected.json" 2>&1 >/dev/null)"
  if printf '%s' "$err" | grep -qi "configured+rejected"; then
    assert_pass "8b: configured+rejected rejected by schema (err mentions configured+rejected)"
  else
    assert_fail "8b: configured+rejected rejection message" "got: $err"
  fi
fi

# 8c: detected+not_required → NOT rejected (valid combination — treats user as
# having confirmed the detected command at config time)
cat > "$NEG/cfg-detected-not-required.json" <<'CFG'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"x","command":["bash","-c","true"],"required_for_passing":true,"command_origin":"detected","confirmation":"not_required"}
    ]
  }
}
CFG
if validate_config_schema "$NEG/cfg-detected-not-required.json" 2>/dev/null; then
  assert_pass "8c: detected+not_required is VALID (allowed at schema level)"
else
  assert_fail "8c: detected+not_required should be VALID" "validator rejected it"
fi

# 8d: detected+pending → schema VALID (runtime gate enforces skip)
cat > "$NEG/cfg-detected-pending.json" <<'CFG'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"x","command":["bash","-c","true"],"required_for_passing":true,"command_origin":"detected","confirmation":"pending"}
    ]
  }
}
CFG
if validate_config_schema "$NEG/cfg-detected-pending.json" 2>/dev/null; then
  assert_pass "8d: detected+pending is schema-VALID (runtime skip gate enforces)"
else
  assert_fail "8d: detected+pending should be schema-VALID" "validator rejected it"
fi

# 8e: confirmed/origin combo that should be rejected — invalid command_origin value
cat > "$NEG/cfg-bad-origin.json" <<'BAD'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"x","command":["bash","-c","true"],"required_for_passing":true,"command_origin":"auto_magic","confirmation":"not_required"}
    ]
  }
}
BAD
if validate_config_schema "$NEG/cfg-bad-origin.json" 2>/dev/null; then
  assert_fail "8e: invalid command_origin rejected" "validator accepted auto_magic"
else
  err="$(validate_config_schema "$NEG/cfg-bad-origin.json" 2>&1 >/dev/null)"
  if printf '%s' "$err" | grep -qi "invalid command_origin"; then
    assert_pass "8e: invalid command_origin rejected"
  else
    assert_fail "8e: invalid command_origin rejection" "got: $err"
  fi
fi

# 8f: invalid confirmation value
cat > "$NEG/cfg-bad-conf.json" <<'BAD'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"x","command":["bash","-c","true"],"required_for_passing":true,"command_origin":"configured","confirmation":"maybe"}
    ]
  }
}
BAD
if validate_config_schema "$NEG/cfg-bad-conf.json" 2>/dev/null; then
  assert_fail "8f: invalid confirmation rejected" "validator accepted maybe"
else
  err="$(validate_config_schema "$NEG/cfg-bad-conf.json" 2>&1 >/dev/null)"
  if printf '%s' "$err" | grep -qi "invalid confirmation"; then
    assert_pass "8f: invalid confirmation rejected"
  else
    assert_fail "8f: invalid confirmation rejection" "got: $err"
  fi
fi

# ============================================================================
# Schema contract: applies_when MUST be has_files (NOT files_any / package_json_has_script)
# ============================================================================
echo ""
echo "=== Schema contract: applies_when uses has_files canonical name ==="
for t in node python rust go docs generic; do
  cfg="templates/.harness/config.json.${t}.example"
  # Check: if any command in this config uses applies_when, it must use has_files
  bad="$(jq -r '.verification.commands[] | select(.applies_when != null) | .applies_when | keys[]' "$cfg" 2>/dev/null | grep -E "^(files_any|package_json_has_script)$" || true)"
  if [ -z "$bad" ]; then
    echo "PASS: $t example: no legacy applies_when keys (files_any/package_json_has_script)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $t example uses legacy keys: $bad"
    FAILED=$((FAILED + 1))
  fi
done

# Also check the schema file itself — applies_when.properties must contain ONLY has_files
echo ""
echo "=== Schema file uses canonical has_files only ==="
schema_keys="$(jq -r '.properties.verification.properties.commands.items.properties.applies_when.properties | keys[]' templates/.harness/config.schema.json 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/ $//')"
if [ "$schema_keys" = "has_files" ]; then
  echo "PASS: schema.applies_when.properties keys = [$schema_keys] (canonical has_files)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: schema.applies_when.properties keys = [$schema_keys] (expected: has_files)"
  FAILED=$((FAILED + 1))
fi

# Also verify schema uses additionalProperties:false on applies_when (no legacy keys allowed)
ap_addl="$(jq -r 'getpath(["properties","verification","properties","commands","items","properties","applies_when","additionalProperties"]) | if . == null then "MISSING" else tostring end' templates/.harness/config.schema.json 2>/dev/null | tr -d '\r')"
if [ "$ap_addl" = "false" ]; then
  echo "PASS: schema.applies_when.additionalProperties = false (no legacy keys permitted)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: schema.applies_when.additionalProperties = $ap_addl (expected: false)"
  FAILED=$((FAILED + 1))
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "R4 Contract Results: $PASSED passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0