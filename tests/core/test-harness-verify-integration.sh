#!/bin/bash
# test-harness-verify-integration.sh — End-to-end integration tests for harness-verify.sh
#
# Covers:
#   1. Happy path — real command execution, complete NDJSON
#   2. Each event is exactly one NDJSON line
#   3. Validate entire log with validate_run_log (canonical pass)
#   4. capability_level computed by core
#   5. Required command failure → run_failed
#   6. Required executable missing → fail-closed (not skipped)
#   7. Optional/non-applicable commands
#   8. Evidence write failure → run_aborted
#   9. 0-step → no_checks
#  10. Windows Git Bash (cygpath normalization)
#  11. Path with spaces
#  12. --write successful evidence association
#  13. Association record is written correctly

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
CORE_LIB="$CORE_DIR/lib"
VERIFY_SCRIPT="$CORE_DIR/harness-verify.sh"

# shellcheck source=../../core/lib/validate-run-log.sh
source "$CORE_LIB/validate-run-log.sh"
# shellcheck source=../../core/lib/passing.sh
source "$CORE_LIB/passing.sh"

PASSED=0
FAILED=0

# Master temp dir
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ---- helpers ----

# Run harness-verify.sh, capturing both stdout and actual exit code.
# Stores output in VERIFY_OUT and exit code in VERIFY_RC.
run_verify() {
  set +e
  VERIFY_OUT="$("$VERIFY_SCRIPT" "$@" 2>&1)"
  VERIFY_RC=$?
}

assert_exit_code() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $name (exit=$actual)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $actual"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — expected to contain '$needle', got:"
    echo "$haystack"
    FAILED=$((FAILED + 1))
  fi
}

assert_file_nonempty() {
  local name="$1" path="$2"
  if [ -f "$path" ] && [ -s "$path" ]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — file '$path' missing or empty"
    FAILED=$((FAILED + 1))
  fi
}

assert_line_count() {
  local name="$1" path="$2" expected="$3"
  local actual
  actual="$(grep -cv '^[[:space:]]*$' "$path" 2>/dev/null || echo 0)"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $name ($expected lines)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — expected $expected non-blank lines, got $actual"
    FAILED=$((FAILED + 1))
  fi
}

assert_each_line_is_compact_json() {
  local name="$1" path="$2"
  local bad_lines=0
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    [ -z "$line" ] && continue
    if ! printf '%s' "$line" | jq . >/dev/null 2>&1; then
      echo "  FAIL: $name — line $line_num is not valid JSON: $line"
      bad_lines=$((bad_lines + 1))
      break
    fi
    local json_lines
    json_lines="$(printf '%s' "$line" | jq -c . 2>/dev/null | wc -l)"
    if [ "$json_lines" != "1" ]; then
      echo "  FAIL: $name — line $line_num spans multiple lines"
      bad_lines=$((bad_lines + 1))
      break
    fi
  done < "$path"
  if [ "$bad_lines" -eq 0 ]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
}

assert_validate_run_log_passes() {
  local name="$1" run_id="$2" project_dir="$3"
  local result
  if result="$(validate_run_log "$run_id" "$project_dir" 2>&1)"; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — validate_run_log returned: $result"
    FAILED=$((FAILED + 1))
  fi
}

# Create a minimal feature_list.json with one feature
create_feature_list() {
  local dir="$1" fid="$2"
  cat > "$dir/feature_list.json" <<FLEND
{
  "revision": 1,
  "features": [
    {
      "id": "$fid",
      "status": "in_progress",
      "evidence_associations": [],
      "legacy_audit_evidence": []
    }
  ],
  "last_updated": "2026-07-31"
}
FLEND
}

# Create a CLAUDE.md for L0 capability
create_knowledge_entry() {
  local dir="$1"
  echo "# Test Project" > "$dir/CLAUDE.md"
}

# Create config.json with given commands (JSON array)
create_config() {
  local dir="$1" commands_json="$2"
  mkdir -p "$dir/.harness"
  cat > "$dir/.harness/config.json" <<CONFEND
{
  "project_type": "generic",
  "verification": {
    "commands": $commands_json
  }
}
CONFEND
}

# ---- cleanup from prior runs ----
rm -rf "$TMPROOT"/*

# ============================================================================
# Test 1: Happy path — real commands, complete NDJSON, validate_run_log passes
# ============================================================================
echo "========== Test 1: Happy Path =========="

T1="$TMPROOT/test1"
mkdir -p "$T1"
git -C "$T1" init --quiet .
git -C "$T1" config user.email "test@example.com"
git -C "$T1" config user.name "Tester"
create_knowledge_entry "$T1"
create_feature_list "$T1" "feat-happy"
create_config "$T1" '[
  {"id":"required-ok","command":["bash","-c","echo hello && exit 0"],"required_for_passing":true},
  {"id":"also-required","command":["bash","-c","echo world && exit 0"],"required_for_passing":true}
]'

run_verify "feat-happy" "$T1"
OUT1="$VERIFY_OUT"
RC1="$VERIFY_RC"
RUN_ID1="$(echo "$OUT1" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID1"
echo "  exit_code: $RC1"

assert_exit_code "happy path exits 0" "0" "$RC1"
assert_contains "happy path says PASSED" "$OUT1" "PASSED"

LOG1="$T1/.harness/logs/runs/${RUN_ID1}.ndjson"
assert_file_nonempty "happy path creates NDJSON log" "$LOG1"
assert_line_count "happy path has 4 events" "$LOG1" 4
assert_each_line_is_compact_json "happy path each line is compact JSON" "$LOG1"
assert_validate_run_log_passes "happy path validates canonical" "$RUN_ID1" "$T1"

# ============================================================================
# Test 2: Required command failure -> run_failed
# ============================================================================
echo ""
echo "========== Test 2: Required Command Failure =========="

T2="$TMPROOT/test2"
mkdir -p "$T2"
git -C "$T2" init --quiet .
git -C "$T2" config user.email "test@example.com"
git -C "$T2" config user.name "Tester"
create_knowledge_entry "$T2"
create_feature_list "$T2" "feat-fail"
create_config "$T2" '[
  {"id":"will-fail","command":["bash","-c","echo failing && exit 1"],"required_for_passing":true}
]'

run_verify "feat-fail" "$T2"
OUT2="$VERIFY_OUT"
RC2="$VERIFY_RC"
RUN_ID2="$(echo "$OUT2" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID2"
echo "  exit_code: $RC2"

assert_exit_code "required failure exits 1" "1" "$RC2"
assert_contains "required failure says FAILED" "$OUT2" "FAILED"

LOG2="$T2/.harness/logs/runs/${RUN_ID2}.ndjson"
assert_file_nonempty "required failure creates NDJSON log" "$LOG2"
assert_line_count "required failure has 3 events" "$LOG2" 3
assert_each_line_is_compact_json "required failure each line is compact JSON" "$LOG2"
assert_validate_run_log_passes "required failure validates canonical" "$RUN_ID2" "$T2"

# Verify the terminal event is run_failed
TERM2="$(tail -1 "$LOG2")"
assert_contains "required failure terminal is run_failed" "$TERM2" '"event":"run_failed"'
assert_contains "required failure overall_result=failed" "$TERM2" '"overall_result":"failed"'

# ============================================================================
# Test 3: Required executable missing -> fail-closed (not skipped)
# ============================================================================
echo ""
echo "========== Test 3: Required Tool Missing (fail-closed) =========="

T3="$TMPROOT/test3"
mkdir -p "$T3"
git -C "$T3" init --quiet .
git -C "$T3" config user.email "test@example.com"
git -C "$T3" config user.name "Tester"
create_knowledge_entry "$T3"
create_feature_list "$T3" "feat-missing"
create_config "$T3" '[
  {"id":"missing-tool","command":["nonexistent-tool-xyz-12345","--flag"],"required_for_passing":true}
]'

run_verify "feat-missing" "$T3"
OUT3="$VERIFY_OUT"
RC3="$VERIFY_RC"
RUN_ID3="$(echo "$OUT3" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID3"
echo "  output: $(echo "$OUT3" | grep -E '\[fail\]|\[skip\]')"
echo "  exit_code: $RC3"

assert_exit_code "required missing tool exits 1" "1" "$RC3"
assert_contains "required missing tool says [fail]" "$OUT3" "[fail]"
if echo "$OUT3" | grep -qE '\[skip\].*missing-tool'; then
  echo "FAIL: required-missing-tool was SKIPPED instead of FAILED"
  FAILED=$((FAILED + 1))
else
  echo "PASS: required missing tool is NOT skipped"
  PASSED=$((PASSED + 1))
fi

LOG3="$T3/.harness/logs/runs/${RUN_ID3}.ndjson"
assert_file_nonempty "required missing tool creates NDJSON log" "$LOG3"
assert_contains "required missing tool has exit_code 127" "$(cat "$LOG3")" '"exit_code":127'

TERM3="$(tail -1 "$LOG3")"
assert_contains "required missing tool terminal is run_failed" "$TERM3" '"event":"run_failed"'
assert_validate_run_log_passes "required missing tool validates canonical" "$RUN_ID3" "$T3"

# ============================================================================
# Test 4: Optional command missing tool -> skipped (not failed)
# ============================================================================
echo ""
echo "========== Test 4: Optional Missing Tool (skipped) =========="

T4="$TMPROOT/test4"
mkdir -p "$T4"
git -C "$T4" init --quiet .
git -C "$T4" config user.email "test@example.com"
git -C "$T4" config user.name "Tester"
create_knowledge_entry "$T4"
create_feature_list "$T4" "feat-optional"
create_config "$T4" '[
  {"id":"req-ok","command":["bash","-c","echo required && exit 0"],"required_for_passing":true},
  {"id":"opt-missing","command":["nonexistent-opt-tool-xyz","--flag"],"required_for_passing":false}
]'

run_verify "feat-optional" "$T4"
OUT4="$VERIFY_OUT"
RC4="$VERIFY_RC"
RUN_ID4="$(echo "$OUT4" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID4"
echo "  output: $(echo "$OUT4" | grep -E '\[pass\]|\[skip\]|\[fail\]')"
echo "  exit_code: $RC4"

assert_exit_code "optional missing tool exits 0" "0" "$RC4"
assert_contains "optional missing tool says [skip]" "$OUT4" "[skip]"
assert_contains "optional says PASSED" "$OUT4" "PASSED"

LOG4="$T4/.harness/logs/runs/${RUN_ID4}.ndjson"
# opt-missing should NOT appear as a command_completed event
if grep -q '"command_id":"opt-missing"' "$LOG4" 2>/dev/null; then
  echo "FAIL: opt-missing has command_completed event (should be skipped)"
  FAILED=$((FAILED + 1))
else
  echo "PASS: opt-missing NOT in command_completed (correctly skipped)"
  PASSED=$((PASSED + 1))
fi

# Verify required_command_ids in run_started only contains req-ok
RUN_STARTED4="$(head -1 "$LOG4")"
assert_contains "run_started only has req-ok" "$RUN_STARTED4" '"required_command_ids":["req-ok"]'

# ============================================================================
# Test 5: 0-step (no commands) -> no_checks
# ============================================================================
echo ""
echo "========== Test 5: Zero-step (no_checks) =========="

T5="$TMPROOT/test5"
mkdir -p "$T5"
git -C "$T5" init --quiet .
git -C "$T5" config user.email "test@example.com"
git -C "$T5" config user.name "Tester"
create_knowledge_entry "$T5"
create_feature_list "$T5" "feat-empty"
create_config "$T5" '[]'

run_verify "feat-empty" "$T5"
OUT5="$VERIFY_OUT"
RC5="$VERIFY_RC"
RUN_ID5="$(echo "$OUT5" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID5"
echo "  exit_code: $RC5"

assert_exit_code "0-step exits 1" "1" "$RC5"
assert_contains "0-step says no_checks" "$OUT5" "no_checks"

LOG5="$T5/.harness/logs/runs/${RUN_ID5}.ndjson"
assert_line_count "0-step has 2 events" "$LOG5" 2
assert_contains "0-step terminal is run_completed/no_checks" "$(tail -1 "$LOG5")" '"overall_result":"no_checks"'
assert_validate_run_log_passes "0-step validates canonical" "$RUN_ID5" "$T5"

# ============================================================================
# Test 6: capability_level computed by core
# ============================================================================
echo ""
echo "========== Test 6: capability_level from core =========="

T6="$TMPROOT/test6"
mkdir -p "$T6"
git -C "$T6" init --quiet .
git -C "$T6" config user.email "test@example.com"
git -C "$T6" config user.name "Tester"
create_knowledge_entry "$T6"
create_feature_list "$T6" "feat-cap"
create_config "$T6" '[
  {"id":"ok","command":["bash","-c","echo cap && exit 0"],"required_for_passing":true}
]'

run_verify "feat-cap" "$T6"
OUT6="$VERIFY_OUT"
RC6="$VERIFY_RC"
RUN_ID6="$(echo "$OUT6" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID6"

LOG6="$T6/.harness/logs/runs/${RUN_ID6}.ndjson"
RUN_STARTED6="$(head -1 "$LOG6")"
assert_contains "capability_level is 2 (L2)" "$RUN_STARTED6" '"capability_level":2'

# Test L1: no revision field in feature_list.json
T6b="$TMPROOT/test6b"
mkdir -p "$T6b"
git -C "$T6b" init --quiet .
git -C "$T6b" config user.email "test@example.com"
git -C "$T6b" config user.name "Tester"
create_knowledge_entry "$T6b"
cat > "$T6b/feature_list.json" <<'FL'
{"features":[{"id":"any","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}
FL
create_config "$T6b" '[
  {"id":"ok","command":["bash","-c","echo l1 && exit 0"],"required_for_passing":true}
]'

run_verify "any" "$T6b"
OUT6b="$VERIFY_OUT"
RUN_ID6b="$(echo "$OUT6b" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"
LOG6b="$T6b/.harness/logs/runs/${RUN_ID6b}.ndjson"
RUN_STARTED6b="$(head -1 "$LOG6b")"
assert_contains "capability_level is 1 (L1)" "$RUN_STARTED6b" '"capability_level":1'

# ============================================================================
# Test 7: Path with spaces
# ============================================================================
echo ""
echo "========== Test 7: Path With Spaces =========="

T7="$TMPROOT/test 7 with spaces"
mkdir -p "$T7"
git -C "$T7" init --quiet .
git -C "$T7" config user.email "test@example.com"
git -C "$T7" config user.name "Tester"
create_knowledge_entry "$T7"
create_feature_list "$T7" "feat-spaces"
create_config "$T7" '[
  {"id":"ok","command":["bash","-c","echo spaces && exit 0"],"required_for_passing":true}
]'

run_verify "feat-spaces" "$T7"
OUT7="$VERIFY_OUT"
RC7="$VERIFY_RC"
RUN_ID7="$(echo "$OUT7" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID7"
echo "  exit_code: $RC7"

assert_exit_code "spaces in path exits 0" "0" "$RC7"
assert_contains "spaces in path says PASSED" "$OUT7" "PASSED"

LOG7="$T7/.harness/logs/runs/${RUN_ID7}.ndjson"
assert_file_nonempty "spaces in path creates NDJSON log" "$LOG7"
assert_each_line_is_compact_json "spaces in path each line is compact JSON" "$LOG7"
assert_validate_run_log_passes "spaces in path validates canonical" "$RUN_ID7" "$T7"

# ============================================================================
# Test 8: Non-applicable command (applies_when predicate false)
# ============================================================================
echo ""
echo "========== Test 8: Non-Applicable Command =========="

T8="$TMPROOT/test8"
mkdir -p "$T8"
git -C "$T8" init --quiet .
git -C "$T8" config user.email "test@example.com"
git -C "$T8" config user.name "Tester"
create_knowledge_entry "$T8"
create_feature_list "$T8" "feat-skip"
create_config "$T8" '[
  {"id":"required","command":["bash","-c","echo ok && exit 0"],"required_for_passing":true},
  {"id":"not-applicable","command":["bash","-c","echo never && exit 0"],"required_for_passing":false,"applies_when":{"has_files":["nonexistent-file.xyz"]}}
]'

run_verify "feat-skip" "$T8"
OUT8="$VERIFY_OUT"
RC8="$VERIFY_RC"
RUN_ID8="$(echo "$OUT8" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID8"
echo "  output: $(echo "$OUT8" | grep -E '\[skip\]|\[pass\]|\[fail\]')"

assert_exit_code "non-applicable exits 0" "0" "$RC8"
# R4.1 fix: skip message is now "not_applicable (predicate false)"
assert_contains "non-applicable says not_applicable" "$OUT8" "not_applicable"

LOG8="$T8/.harness/logs/runs/${RUN_ID8}.ndjson"
if grep -q '"command_id":"not-applicable"' "$LOG8" 2>/dev/null; then
  echo "FAIL: not-applicable has command_completed event (should be skipped)"
  FAILED=$((FAILED + 1))
else
  echo "PASS: not-applicable NOT in command_completed"
  PASSED=$((PASSED + 1))
fi
assert_validate_run_log_passes "non-applicable validates canonical" "$RUN_ID8" "$T8"

# ============================================================================
# Test 9: --write association
# ============================================================================
echo ""
echo "========== Test 9: --write Association =========="

T9="$TMPROOT/test9"
mkdir -p "$T9"
git -C "$T9" init --quiet .
git -C "$T9" config user.email "test@example.com"
git -C "$T9" config user.name "Tester"
create_knowledge_entry "$T9"
create_feature_list "$T9" "feat-write"
create_config "$T9" '[
  {"id":"write-cmd","command":["bash","-c","echo written && exit 0"],"required_for_passing":true}
]'

# Run with --write
run_verify "feat-write" "$T9" --write
OUT9="$VERIFY_OUT"
RC9="$VERIFY_RC"
RUN_ID9="$(echo "$OUT9" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

echo "  run_id: $RUN_ID9"
echo "  exit_code: $RC9"

assert_exit_code "--write exits 0" "0" "$RC9"
assert_contains "--write says Association added" "$OUT9" "Association added"
assert_contains "--write says PASSED" "$OUT9" "PASSED"

# Verify feature_list.json was updated
FL9="$T9/feature_list.json"
ASSOC_RUN_ID="$(jq -r '.features[0].evidence_associations[0].run_id // empty' "$FL9")"
if [ "$ASSOC_RUN_ID" = "$RUN_ID9" ]; then
  echo "PASS: feature_list has correct run_id"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: expected run_id '$RUN_ID9' in association, got '$ASSOC_RUN_ID'"
  FAILED=$((FAILED + 1))
fi

# Verify the association has required fields
ASSOC_AT="$(jq -r '.features[0].evidence_associations[0].associated_at // empty' "$FL9")"
ASSOC_BY="$(jq -r '.features[0].evidence_associations[0].associated_by // empty' "$FL9")"
if [ -n "$ASSOC_AT" ] && [ "$ASSOC_BY" = "user" ]; then
  echo "PASS: association has associated_at and associated_by"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: association missing fields (at='$ASSOC_AT', by='$ASSOC_BY')"
  FAILED=$((FAILED + 1))
fi

# Second --write should add a second association
run_verify "feat-write" "$T9" --write
ASSOC_COUNT9b="$(jq '.features[0].evidence_associations | length' "$FL9")"
if [ "$ASSOC_COUNT9b" = "2" ]; then
  echo "PASS: second --write adds second association"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: expected 2 associations, got $ASSOC_COUNT9b"
  FAILED=$((FAILED + 1))
fi

# ============================================================================
# Test 10: Evidence write failure -> fail-closed
# ============================================================================
echo ""
echo "========== Test 10: Evidence Write Failure =========="

T10="$TMPROOT/test10"
mkdir -p "$T10"
git -C "$T10" init --quiet .
git -C "$T10" config user.email "test@example.com"
git -C "$T10" config user.name "Tester"
create_knowledge_entry "$T10"
create_feature_list "$T10" "feat-evidence-fail"
create_config "$T10" '[
  {"id":"will-work","command":["bash","-c","echo ok && exit 0"],"required_for_passing":true}
]'

# Sabotage: make .harness/logs/runs a FILE so writes fail
mkdir -p "$T10/.harness/logs"
touch "$T10/.harness/logs/runs"

run_verify "feat-evidence-fail" "$T10"
OUT10="$VERIFY_OUT"
RC10="$VERIFY_RC"

echo "  exit_code: $RC10"
echo "  output: $(echo "$OUT10" | grep -i 'FATAL\|error\|fail' | head -3)"

assert_exit_code "evidence write failure exits 2" "2" "$RC10"
assert_contains "evidence write failure says FATAL" "$OUT10" "FATAL"

# ============================================================================
# Test 11: NDJSON Line Discipline
# ============================================================================
echo ""
echo "========== Test 11: NDJSON Line Discipline =========="

T11="$TMPROOT/test11"
mkdir -p "$T11"
git -C "$T11" init --quiet .
git -C "$T11" config user.email "test@example.com"
git -C "$T11" config user.name "Tester"
create_knowledge_entry "$T11"
create_feature_list "$T11" "feat-lines"
create_config "$T11" '[
  {"id":"a","command":["bash","-c","echo a && exit 0"],"required_for_passing":true},
  {"id":"b","command":["bash","-c","echo b && exit 0"],"required_for_passing":true}
]'

run_verify "feat-lines" "$T11"
OUT11="$VERIFY_OUT"
RUN_ID11="$(echo "$OUT11" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"
LOG11="$T11/.harness/logs/runs/${RUN_ID11}.ndjson"

# Every non-blank line must be exactly one JSON value
line_count="$(grep -cv '^[[:space:]]*$' "$LOG11" 2>/dev/null || echo 0)"
jq_count="$(jq -s 'length' "$LOG11" 2>/dev/null || echo 0)"
if [ "$line_count" = "$jq_count" ]; then
  echo "PASS: line count ($line_count) == jq -s length ($jq_count)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: line count ($line_count) != jq -s length ($jq_count)"
  FAILED=$((FAILED + 1))
fi

# Verify each line round-trips through jq -c without changing
# Strip CR (Carriage Return) for Windows compatibility
bad_multiline=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  line_no_cr="${line%$'\r'}"
  compressed="$(printf '%s' "$line_no_cr" | jq -c . 2>/dev/null)"
  [ "${compressed}" = "${line_no_cr}" ] || {
    bad_multiline=1
    echo "  mismatch: compressed=${compressed:0:60}..."
    echo "  mismatch: original=${line_no_cr:0:60}..."
  }
done < "$LOG11"
if [ "$bad_multiline" -eq 0 ]; then
  echo "PASS: all lines are compact single-line JSON"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: found non-compact JSON events"
  FAILED=$((FAILED + 1))
fi

# ============================================================================
# Test 12: Windows Git Bash path normalization
# ============================================================================
echo ""
echo "========== Test 12: Windows Path Normalization =========="

if command -v cygpath >/dev/null 2>&1; then
  T12="$TMPROOT/test12"
  mkdir -p "$T12"
  git -C "$T12" init --quiet .
  git -C "$T12" config user.email "test@example.com"
  git -C "$T12" config user.name "Tester"
  create_knowledge_entry "$T12"
  create_feature_list "$T12" "feat-win"
  create_config "$T12" '[
    {"id":"ok","command":["bash","-c","echo winpath && exit 0"],"required_for_passing":true}
  ]'

  WIN_PATH="$(cygpath -m "$T12" 2>/dev/null || echo "$T12")"
  echo "  testing with Windows-style path: $WIN_PATH"

  run_verify "feat-win" "$WIN_PATH"
  OUT12="$VERIFY_OUT"
  RC12="$VERIFY_RC"
  RUN_ID12="$(echo "$OUT12" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"

  echo "  run_id: $RUN_ID12"
  echo "  exit_code: $RC12"

  assert_exit_code "Windows path exits 0" "0" "$RC12"
  assert_contains "Windows path says PASSED" "$OUT12" "PASSED"

  LOG12="$T12/.harness/logs/runs/${RUN_ID12}.ndjson"
  assert_file_nonempty "Windows path creates NDJSON log" "$LOG12"
  assert_validate_run_log_passes "Windows path validates canonical" "$RUN_ID12" "$T12"
else
  echo "SKIP: cygpath not available (not Windows)"
  echo "PASS: cygpath normalization skipped (non-Windows)"
  PASSED=$((PASSED + 1))
fi

# ============================================================================
# Test 13: Event sequence verification
# ============================================================================
echo ""
echo "========== Test 13: Event Sequence =========="

T13="$TMPROOT/test13"
mkdir -p "$T13"
git -C "$T13" init --quiet .
git -C "$T13" config user.email "test@example.com"
git -C "$T13" config user.name "Tester"
create_knowledge_entry "$T13"
create_feature_list "$T13" "feat-seq"
create_config "$T13" '[
  {"id":"first","command":["bash","-c","echo first && exit 0"],"required_for_passing":true},
  {"id":"second","command":["bash","-c","echo second && exit 0"],"required_for_passing":true}
]'

run_verify "feat-seq" "$T13"
OUT13="$VERIFY_OUT"
RUN_ID13="$(echo "$OUT13" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"
LOG13="$T13/.harness/logs/runs/${RUN_ID13}.ndjson"

FIRST_EV="$(head -1 "$LOG13" | jq -r '.event')"
LAST_EV="$(tail -1 "$LOG13" | jq -r '.event')"

if [ "$FIRST_EV" = "run_started" ]; then
  echo "PASS: first event is run_started"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: first event is $FIRST_EV"
  FAILED=$((FAILED + 1))
fi

if [ "$LAST_EV" = "run_completed" ]; then
  echo "PASS: last event is run_completed"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: last event is $LAST_EV"
  FAILED=$((FAILED + 1))
fi

# Verify required_command_ids contains only required commands
REQ_IDS="$(head -1 "$LOG13" | jq -r '.required_command_ids[]' | sort | tr '\n' ' ')"
echo "  required_command_ids: $REQ_IDS"

if echo "$REQ_IDS" | grep -q "first" && echo "$REQ_IDS" | grep -q "second"; then
  echo "PASS: required_command_ids contains first and second"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: required_command_ids missing entries: $REQ_IDS"
  FAILED=$((FAILED + 1))
fi

# ============================================================================
# Test 14: --write → eligible → 3-axis stale (integration)
# ============================================================================
# User-requested Round 3 acceptance criterion: after --write establishes
# evidence association, is_eligible_for_passing must return eligible; then
# modifying each axis (workspace, config, git HEAD) in turn must make it
# not eligible. This proves the 3-axis fail-closed semantics work end-to-end.
#
# We use 3 sub-trees (T14A/B/C) so each axis is tested independently from a
# known-good post --write state, without needing to mutate+rollback (which is
# fragile because git reset doesn't unstage untracked, etc.).
echo ""
echo "========== Test 14: 3-Axis Stale After --write =========="

# Helper: set up a fresh project, run --write, and return the temp dir
_axes_setup() {
  local label="$1"
  local d="$TMPROOT/test14-$label"
  rm -rf "$d"
  mkdir -p "$d"
  git -C "$d" init --quiet .
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name  "Tester"
  git -C "$d" config commit.gpgsign false
  create_knowledge_entry "$d"
  create_feature_list "$d" "feat-axes"
  create_config "$d" '[
    {"id":"write-cmd","command":["bash","-c","echo written && exit 0"],"required_for_passing":true}
  ]'
  # Seed an initial commit so vcs_revision is non-null in run_started.
  # Without this, design §9.1 step 8 silently skips VCS comparison
  # (stored_rev is null) and any later HEAD advance wouldn't be detected.
  # We must NOT commit feature_list.json, because --write mutates it after
  # the run, and a tracked+modified file shows up in git diff as a stale
  # workspace fingerprint (axis 6 fail-closed) — which is correct behavior
  # but would prevent the post-write eligible assertion.
  git -C "$d" add CLAUDE.md .harness/config.json 2>/dev/null
  git -C "$d" commit -q -m "initial seed for axes test" 2>/dev/null
  run_verify "feat-axes" "$d" --write
  if [ "$VERIFY_RC" != "0" ]; then
    echo "FAIL: Test 14 setup ($label): --write failed rc=$VERIFY_RC"
    FAILED=$((FAILED + 1))
    return 1
  fi
  printf '%s' "$d"
}

# ---- 14.1: eligible right after --write (all 3 axes fresh) ----
T14A="$(_axes_setup a)"
if [ -n "$T14A" ]; then
  ELIG="$(is_eligible_for_passing "feat-axes" "$T14A/feature_list.json" "$T14A" 2>&1)"
  ELIG_RC=$?
  if [ "$ELIG_RC" = "0" ]; then
    echo "PASS: Test 14.1 — eligible right after --write (all 3 axes fresh)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: Test 14.1 — expected eligible, got rc=$ELIG_RC: $ELIG"
    FAILED=$((FAILED + 1))
  fi
fi

# ---- 14.2: workspace modification → not eligible (axis 1) ----
T14B="$(_axes_setup b)"
if [ -n "$T14B" ]; then
  # Add a tracked file (git add -A picks it up; commit so it shows in fingerprint)
  echo "extra" > "$T14B/extra-tracked.txt"
  git -C "$T14B" add -A 2>/dev/null
  git -C "$T14B" commit -q -m "test extra" 2>/dev/null
  # Now the workspace fingerprint has changed (added tracked file) but HEAD
  # also advanced. To isolate axis 1 we need to reset HEAD back to original
  # commit while keeping the working-tree dirty. Use git reset --mixed to move
  # HEAD back without changing working tree.
  git -C "$T14B" reset --mixed HEAD~1 2>/dev/null
  ELIG1="$(is_eligible_for_passing "feat-axes" "$T14B/feature_list.json" "$T14B" 2>&1)"
  ELIG1_RC=$?
  if [ "$ELIG1_RC" != "0" ] && printf '%s' "$ELIG1" | grep -qi "workspace_changed_since_verification"; then
    echo "PASS: Test 14.2 — workspace modification → not eligible (axis 1)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: Test 14.2 — expected workspace_changed_since_verification, got rc=$ELIG1_RC: $ELIG1"
    FAILED=$((FAILED + 1))
  fi
fi

# ---- 14.3: config modification → not eligible (axis 2) ----
T14C="$(_axes_setup c)"
if [ -n "$T14C" ]; then
  # Modify .harness/config.json — change content while leaving structure intact.
  # IMPORTANT: must commit the new config so the working tree is clean
  # (else axis 6 fires first with workspace_changed_since_verification).
  # Step 7 hashes raw file content regardless of git status.
  cat > "$T14C/.harness/config.json" <<'CFGNEW'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"write-cmd","command":["bash","-c","echo written && exit 0"],"required_for_passing":true}
    ],
    "extra_field": "added-by-axis2-test"
  }
}
CFGNEW
  git -C "$T14C" add -A 2>/dev/null
  git -C "$T14C" commit -q -m "axis-2 config change" 2>/dev/null
  ELIG2="$(is_eligible_for_passing "feat-axes" "$T14C/feature_list.json" "$T14C" 2>&1)"
  ELIG2_RC=$?
  if [ "$ELIG2_RC" != "0" ] && printf '%s' "$ELIG2" | grep -qi "config_changed_since_run"; then
    echo "PASS: Test 14.3 — config modification → not eligible (axis 2)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: Test 14.3 — expected config_changed_since_run, got rc=$ELIG2_RC: $ELIG2"
    FAILED=$((FAILED + 1))
  fi
fi

# ---- 14.4: git HEAD advance → not eligible (axis 3) ----
T14D="$(_axes_setup d)"
if [ -n "$T14D" ]; then
  # Advance HEAD with an empty commit so only vcs_revision changes
  git -C "$T14D" commit --allow-empty -q -m "advance HEAD for axis-3 test" 2>/dev/null
  ELIG3="$(is_eligible_for_passing "feat-axes" "$T14D/feature_list.json" "$T14D" 2>&1)"
  ELIG3_RC=$?
  if [ "$ELIG3_RC" != "0" ] && printf '%s' "$ELIG3" | grep -qi "vcs_moved_since_run"; then
    echo "PASS: Test 14.4 — git HEAD advance → not eligible (axis 3)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: Test 14.4 — expected vcs_moved_since_run, got rc=$ELIG3_RC: $ELIG3"
    FAILED=$((FAILED + 1))
  fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "Integration Test Results: $PASSED passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
