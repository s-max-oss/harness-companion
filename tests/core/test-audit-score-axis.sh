#!/bin/bash
# test-audit-score-axis.sh — Boundary tests for the audit score_axis formula.
#
# score_axis() in core/harness-audit.sh must implement the continuous scale:
#   floor(passed * 3 / total)
# so that:
#   0/5 → 0
#   1/5 → 0
#   2/5 → 1
#   3/5 → 1
#   4/5 → 2
#   5/5 → 3 (max)
#
# The OLD bracket formula (>=3 → 3) overestimated low-pass cases and is no
# longer used. These tests pin the new formula.
#
# Also tests that audit correctly classifies the 5 G10 fixture run-log states
# (valid / missing / corrupt / stale / no-association).

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
AUDIT="$ROOT_DIR/core/harness-audit.sh"

if [ ! -f "$AUDIT" ]; then
  echo "SKIP: $AUDIT not present"
  exit 0
fi

# Fixtures are built at runtime. The retired adapter fixtures embedded absolute
# artifact paths, so they rotted as soon as the repository moved (the audit then
# classified every run log as corrupt instead of the intended state).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc-audit-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIXTURES="$WORK"
CONFIG='{"project_type":"generic","verification":{"commands":[{"id":"echo","command":["bash","-c","echo ok"],"command_origin":"configured","confirmation":"not_required","required_for_passing":true,"timeout_seconds":60}]}}'

mk_project() {
  local dir="$1" features="$2"
  mkdir -p "$dir/.harness"
  printf '# %s\n' "$(basename "$dir")" > "$dir/AGENTS.md"
  printf '%s' "$CONFIG" > "$dir/.harness/config.json"
  printf '{"version":"2","schema_version":"2.0.0","revision":1,"features":[%s]}' "$features" \
    > "$dir/feature_list.json"
}

verified_project() {
  local dir="$1" fid="$2"
  mk_project "$dir" "{\"id\":\"$fid\",\"title\":\"audit case\",\"status\":\"not_started\",\"evidence_associations\":[],\"legacy_audit_evidence\":[]}"
  bash "$ROOT_DIR/core/harness-feature.sh" status "$dir" "$fid" in_progress >/dev/null 2>&1
  bash "$ROOT_DIR/core/harness-verify.sh" "$fid" "$dir" --write >/dev/null 2>&1
  bash "$ROOT_DIR/core/harness-feature.sh" status "$dir" "$fid" passing >/dev/null 2>&1
}

verified_project "$WORK/clean-project" "F-AUDIT-CLEAN"
mk_project "$WORK/invalid-runid" '{"id":"F-AUDIT-MISS","title":"missing","status":"passing","evidence_associations":[{"run_id":"19990101T000000Z-1-1"}],"legacy_audit_evidence":[]}'
mk_project "$WORK/corrupted-runlog" '{"id":"F-AUDIT-CORRUPT","title":"corrupt","status":"passing","evidence_associations":[{"run_id":"19990101T000000Z-2-2"}],"legacy_audit_evidence":[]}'
mkdir -p "$WORK/corrupted-runlog/.harness/logs/runs"
printf 'not-json\n' > "$WORK/corrupted-runlog/.harness/logs/runs/19990101T000000Z-2-2.ndjson"
verified_project "$WORK/stale-run" "F-AUDIT-STALE"
printf 'changed after verification\n' >> "$WORK/stale-run/AGENTS.md"
mk_project "$WORK/no-association" '{"id":"F-AUDIT-NOASSC","title":"no assoc","status":"passing","evidence_associations":[],"legacy_audit_evidence":[]}'

PASSED=0
FAILED=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASSED=$((PASSED + 1))
    printf '  [PASS] %s\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf '  [FAIL] %s  expected=%s actual=%s\n' "$name" "$expected" "$actual"
  fi
}

# ============================================================
echo "=== Boundary tests for score_axis ==="
# ============================================================

# Extract score_axis function from the audit script and source it.
SCORE_AXIS_BODY="$(awk '/^score_axis\(\)/,/^}/' "$AUDIT")"
if [ -z "$SCORE_AXIS_BODY" ]; then
  echo "FAIL: could not extract score_axis from $AUDIT"
  exit 1
fi
# shellcheck disable=SC2046
eval "$(printf '%s\n' "$SCORE_AXIS_BODY" | sed 's/score_axis/score_axis_test/g')"
score_axis() { score_axis_test "$@"; }

# 0/5
SC="$(score_axis 0 5)"
assert_eq "0/5 → 0" "0" "$SC"

# 1/5 → floor(0.6) = 0
SC="$(score_axis 1 5)"
assert_eq "1/5 → 0" "0" "$SC"

# 2/5 → floor(1.2) = 1
SC="$(score_axis 2 5)"
assert_eq "2/5 → 1" "1" "$SC"

# 3/5 → floor(1.8) = 1
SC="$(score_axis 3 5)"
assert_eq "3/5 → 1" "1" "$SC"

# 4/5 → floor(2.4) = 2
SC="$(score_axis 4 5)"
assert_eq "4/5 → 2" "2" "$SC"

# 5/5 → floor(3) = 3 (max)
SC="$(score_axis 5 5)"
assert_eq "5/5 → 3 (max)" "3" "$SC"

# 1/1 → floor(3) = 3
SC="$(score_axis 1 1)"
assert_eq "1/1 → 3 (single check passes)" "3" "$SC"

# 0/total → 0 (no possible checks)
SC="$(score_axis 0 0)"
assert_eq "0/0 → 0 (no checks possible)" "0" "$SC"

# 2/3 → floor(2) = 2
SC="$(score_axis 2 3)"
assert_eq "2/3 → 2" "2" "$SC"

# 1/3 → floor(1) = 1
SC="$(score_axis 1 3)"
assert_eq "1/3 → 1" "1" "$SC"

# ============================================================
echo ""
echo "=== Real audit assertions across 5 G10 run-log states ==="
# ============================================================

# Helper: extract Verification effectiveness line for a fixture.
# Filters to lines matching "effectiveness: passing=" (the canonical green line)
# — this is the run-log state summary, not other effectiveness rows.
audit_effectiveness() {
  local fix="$1"
  HARNESS_VERBOSE=1 bash "$AUDIT" "$fix" 2>/dev/null \
    | grep -E 'effectiveness: passing=' \
    | head -1 \
    | sed 's/^[[:space:]]*-[[:space:]]*effectiveness:[[:space:]]*//'
}

# G-A1: clean-project — run log is valid + overall_result=passed → green=1
EFF="$(audit_effectiveness "$FIXTURES/clean-project")"
echo "clean-project effectiveness: $EFF"
if printf '%s' "$EFF" | grep -qE 'green=1.*missing=0.*corrupt=0.*stale=0'; then
  PASSED=$((PASSED+1))
  printf '  [PASS] audit classifies clean-project as green=1 (valid + passed)\n'
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] audit mis-classified clean-project: %s\n' "$EFF"
fi

# G-A2: invalid-runid — run log file missing → missing=1
EFF="$(audit_effectiveness "$FIXTURES/invalid-runid")"
echo "invalid-runid effectiveness: $EFF"
if printf '%s' "$EFF" | grep -qE 'green=0.*missing=1.*corrupt=0.*stale=0'; then
  PASSED=$((PASSED+1))
  printf '  [PASS] audit classifies invalid-runid as missing=1\n'
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] audit mis-classified invalid-runid: %s\n' "$EFF"
fi

# G-A3: corrupted-runlog — NDJSON present but unparseable → corrupt=1
EFF="$(audit_effectiveness "$FIXTURES/corrupted-runlog")"
echo "corrupted-runlog effectiveness: $EFF"
if printf '%s' "$EFF" | grep -qE 'green=0.*missing=0.*corrupt=1.*stale=0'; then
  PASSED=$((PASSED+1))
  printf '  [PASS] audit classifies corrupted-runlog as corrupt=1\n'
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] audit mis-classified corrupted-runlog: %s\n' "$EFF"
fi

# G-A4: stale-run — NDJSON valid but workspace_fingerprint_verified mismatch → stale=1
EFF="$(audit_effectiveness "$FIXTURES/stale-run")"
echo "stale-run effectiveness: $EFF"
if printf '%s' "$EFF" | grep -qE 'green=0.*missing=0.*corrupt=0.*stale=1'; then
  PASSED=$((PASSED+1))
  printf '  [PASS] audit classifies stale-run as stale=1\n'
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] audit mis-classified stale-run: %s\n' "$EFF"
fi

# G-A5: no-association — passing feature with empty evidence_associations
# → audit reports no_assoc=1 (no canonical run log to evaluate)
EFF="$(audit_effectiveness "$FIXTURES/no-association")"
echo "no-association effectiveness: $EFF"
if printf '%s' "$EFF" | grep -qE 'green=0.*no_assoc=1'; then
  PASSED=$((PASSED+1))
  printf '  [PASS] audit classifies no-association as no_assoc=1\n'
elif printf '%s' "$EFF" | grep -q 'no passing features'; then
  PASSED=$((PASSED+1))
  printf '  [PASS] audit handles no-association (no passing-with-association)\n'
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] audit mis-classified no-association: %s\n' "$EFF"
fi

# ============================================================
echo ""
echo "=== Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then exit 1; fi
exit 0
