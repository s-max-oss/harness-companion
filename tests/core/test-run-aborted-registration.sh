#!/bin/bash
# test-run-aborted-registration.sh — R2 remediation regression
#
# harness-verify.sh has TWO run_aborted terminal paths (the missing-tool path
# and the executed-command path). Each builds a run_aborted event, writes it as
# the terminal event, and — per R2 — must call register_run_or_die after a
# SUCCESSFUL terminal write, and propagate any registration failure as a FATAL
# exit 2.
#
# The write of command_completed is the deterministic trigger for run_aborted,
# and it shares its file with the terminal write, so a pure filesystem sabotage
# cannot make command_completed fail while terminal succeeds. Instead we run the
# REAL harness-verify.sh against a mock evidence.sh that sources the real one
# and forces ONLY ev_write_command_completed to fail — leaving the real
# ev_write_terminal to actually write the terminal event (success), after which
# register_run_or_die fires. A directory obstacle at .harness/runtime-manifest.jsonl
# then makes runtime registration fail deterministically, so the test observes
# BOTH "terminal write succeeded" (a run_aborted line is on disk) AND
# "registration failure propagated" (exit 2 + FATAL message).
#
# Local-only (never CI): builds its own git-free fixtures.
# Requires: bash, jq.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
CORE_LIB="$CORE_DIR/lib"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

check() {
  local name="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — expected $expected, got $got"
    FAILED=$((FAILED + 1))
  fi
}

# build_mock_verify <hvdir> — copy the real harness-verify.sh + lib tree, then
# overwrite evidence.sh with a mock that sources the REAL evidence.sh and forces
# ev_write_command_completed to fail. The script's SKILL_DIR resolves to <hvdir>,
# so the mocked lib is what gets sourced.
build_mock_verify() {
  local hvdir="$1"
  mkdir -p "$hvdir/lib"
  cp "$CORE_DIR/harness-verify.sh" "$hvdir/harness-verify.sh"
  cp "$CORE_LIB"/*.sh "$hvdir/lib/"
  cat > "$hvdir/lib/evidence.sh" <<EOF
# mock evidence.sh — real evidence functions + forced command_completed failure
. "$CORE_LIB/evidence.sh"
ev_write_command_completed() { return 1; }
EOF
}

# setup_project <dir> <fid> <commands_json> — a minimal non-git project with a
# directory obstacle at .harness/runtime-manifest.jsonl (deterministic
# registration failure).
setup_project() {
  local d="$1" fid="$2" commands_json="$3"
  mkdir -p "$d/.harness"
  cat > "$d/.harness/config.json" <<CONFEND
{
  "project_type": "generic",
  "verification": {
    "commands": $commands_json
  }
}
CONFEND
  cat > "$d/feature_list.json" <<FLEND
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
  mkdir -p "$d/.harness/runtime-manifest.jsonl"
}

# run_mock <hvdir> <fid> <project> — invoke the mocked harness-verify and capture
# output + exit code into VERIFY_OUT / VERIFY_RC.
run_mock() {
  local hvdir="$1" fid="$2" project="$3"
  set +e
  VERIFY_OUT="$(bash "$hvdir/harness-verify.sh" "$fid" "$project" 2>&1)"
  VERIFY_RC=$?
}

HV="$TMPDIR/mock-hv"
build_mock_verify "$HV"

# ============================================================================
# Test 1: run_aborted via MISSING-TOOL path — registration failure propagates
# ============================================================================
echo ""
echo "========== Run-Aborted Registration: missing-tool path =========="
D="$TMPDIR/missing-tool"
setup_project "$D" "feat-abort-missing" '[
  {"id":"missing-tool","command":["no-such-tool-xyz-$$"],"required_for_passing":true}
]'
run_mock "$HV" "feat-abort-missing" "$D"
check "missing-tool path exits 2" 2 "$VERIFY_RC"
check "missing-tool path reports registration FATAL" "yes" \
  "$(printf '%s' "$VERIFY_OUT" | grep -qF 'FATAL: failed to register runtime artifacts' && echo yes || echo no)"
RUN_ID="$(printf '%s' "$VERIFY_OUT" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"
LOG="$D/.harness/logs/runs/${RUN_ID}.ndjson"
if [ -f "$LOG" ]; then
  check "missing-tool path wrote run_aborted terminal (write succeeded first)" "run_aborted" \
    "$(tail -1 "$LOG" | jq -r '.event // empty' 2>/dev/null)"
else
  check "missing-tool path wrote run_aborted terminal (write succeeded first)" "run_aborted" "no-log"
fi

# ============================================================================
# Test 2: run_aborted via EXECUTED-COMMAND path — registration failure propagates
# ============================================================================
echo ""
echo "========== Run-Aborted Registration: executed-command path =========="
D="$TMPDIR/exec-ok"
setup_project "$D" "feat-abort-exec" '[
  {"id":"ok","command":["bash","-c","exit 0"],"required_for_passing":true}
]'
run_mock "$HV" "feat-abort-exec" "$D"
check "executed-command path exits 2" 2 "$VERIFY_RC"
check "executed-command path reports registration FATAL" "yes" \
  "$(printf '%s' "$VERIFY_OUT" | grep -qF 'FATAL: failed to register runtime artifacts' && echo yes || echo no)"
RUN_ID="$(printf '%s' "$VERIFY_OUT" | grep -oE '[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+' | head -1)"
LOG="$D/.harness/logs/runs/${RUN_ID}.ndjson"
if [ -f "$LOG" ]; then
  check "executed-command path wrote run_aborted terminal (write succeeded first)" "run_aborted" \
    "$(tail -1 "$LOG" | jq -r '.event // empty' 2>/dev/null)"
else
  check "executed-command path wrote run_aborted terminal (write succeeded first)" "run_aborted" "no-log"
fi

echo ""
echo "Run-Aborted Registration Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
