#!/bin/bash
# run-all.sh — reproducible full-suite runner (P0-7)
#
# Solidified in-repo form of the historical /tmp/full-suite.sh. Runs EVERY
# tests/**/test-*.sh script and aggregates results. Reproducible because:
#   - ROOT is derived from this script's own location (location-independent).
#   - Each test runs with stdin from /dev/null: an installed SessionStart hook
#     reads stdin (ji_init), and a background shell leaves an open pipe that
#     never EOFs → the hook's `cat` blocks forever and the test (and timeout)
#     can never finish.
#   - test-version-sync.sh is FAIL-CLOSED on items #6/#7 unless given a REAL
#     installed target, per CI Phase 5d. The install + test sequence is the
#     SAME one CI uses — scripts/version-sync-gate.sh — so local and CI can
#     never diverge on the version-sync install method (P0-7).
#
# Usage (from anywhere):
#   bash tests/run-all.sh
#
# Exit 0 only if every test script exits 0.
#
# Requires: bash, find, timeout (falls back to plain invocation when absent).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# timeout available? (coreutils; absent on some minimal shells)
HAS_TIMEOUT=1
command -v timeout >/dev/null 2>&1 || HAS_TIMEOUT=0

run_test() {
  local rel="$1"
  local log rc res
  log="$(mktemp)"
  if [ "$rel" = "tests/release/test-version-sync.sh" ]; then
    # P0-7: shared install + test method — byte-for-byte the same sequence CI
    # Phase 5d runs via scripts/version-sync-gate.sh.
    if [ "$HAS_TIMEOUT" = "1" ]; then
      timeout -k 60 1500 bash "$ROOT/scripts/version-sync-gate.sh" "$ROOT" 2>&1 | tee "$log" | tail -3
      rc=${PIPESTATUS[0]}
    else
      bash "$ROOT/scripts/version-sync-gate.sh" "$ROOT" 2>&1 | tee "$log" | tail -3
      rc=${PIPESTATUS[0]}
    fi
  else
    # stdin from /dev/null so a SessionStart hook reading stdin can never block.
    if [ "$HAS_TIMEOUT" = "1" ]; then
      timeout -k 60 1500 bash "$ROOT/$rel" < /dev/null 2>&1 | tee "$log" | tail -3
      rc=${PIPESTATUS[0]}
    else
      bash "$ROOT/$rel" < /dev/null 2>&1 | tee "$log" | tail -3
      rc=${PIPESTATUS[0]}
    fi
  fi
  res="$(grep -E 'Results:|passed,' "$log" | tail -1)"
  echo "  [RC=$rc]"
  echo "  [RESULT: $res]"
  rm -f "$log"
  return "$rc"
}

mapfile -t TESTS < <(find "$ROOT/tests" -name 'test-*.sh' | LC_ALL=C sort)
TOTAL=0
PASS_ALL=0
FAILS=""
for t in "${TESTS[@]}"; do
  TOTAL=$((TOTAL+1))
  rel="${t#"$ROOT"/}"
  echo "========== RUNNING $rel =========="
  run_test "$rel"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS_ALL=$((PASS_ALL+1))
  else
    FAILS="$FAILS $rel(rc=$rc)"
  fi
  echo
done
echo "========== FULL SUITE DONE =========="
echo "SUITES: $PASS_ALL/$TOTAL passed"
if [ -n "$FAILS" ]; then
  echo "FAILS:$FAILS"
  exit 1
fi
exit 0
