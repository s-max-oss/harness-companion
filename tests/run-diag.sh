#!/bin/bash
# run-diag.sh — diagnostic full-suite runner that PRESERVES per-suite logs
#
# Same ordering/logic as run-all.sh (P0-7) but writes each suite's FULL output
# to $OUTDIR/<nn>-<name>.log so a flaky failure can be root-caused instead of
# reduced to `tail -3`. Also runs with stdin from /dev/null (an installed
# SessionStart hook that reads stdin would otherwise block forever).
#
# Usage: bash tests/run-diag.sh [outdir]
#   outdir defaults to /tmp/fullrun-DIAG (created if missing).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${1:-/tmp/fullrun-$(date +%H%M%S)}"

resolve_gnu_timeout() {
  local name candidate version
  for name in timeout gtimeout; do
    candidate="$(builtin type -P "$name" 2>/dev/null || true)"
    [ -n "$candidate" ] || continue
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    version="$("$candidate" --version 2>/dev/null)"
    version="${version%%$'\n'*}"
    case "$version" in
      'timeout (GNU coreutils) '*) printf '%s\n' "$candidate"; return 0 ;;
    esac
  done
  return 1
}

TIMEOUT_BIN="$(resolve_gnu_timeout)"
if [ -z "$TIMEOUT_BIN" ]; then
  echo "ERROR: GNU timeout is required; refusing to run diagnostic suites without bounded execution." >&2
  exit 2
fi

mkdir -p "$OUTDIR"

run_test() {
  local rel="$1" idx="$2"
  local log="$OUTDIR/$(printf '%02d' "$idx")-$(basename "$rel").log"
  local rc
  echo "========== RUNNING $rel ==========" | tee -a "$OUTDIR/summary.txt"
  if [ "$rel" = "tests/release/test-version-sync.sh" ]; then
    "$TIMEOUT_BIN" --kill-after=60s 1500s bash "$ROOT/scripts/version-sync-gate.sh" "$ROOT" < /dev/null > "$log" 2>&1
    rc=$?
  else
    "$TIMEOUT_BIN" --kill-after=60s 1500s bash "$ROOT/$rel" < /dev/null > "$log" 2>&1
    rc=$?
  fi
  local res
  res="$(grep -E 'Results:|passed,|Failed:|FAILED:' "$log" | tail -1)"
  echo "  [RC=$rc]  [$res]  full log: $log" | tee -a "$OUTDIR/summary.txt"
  if [ "$rc" -ne 0 ]; then
    echo "  --- FAILING LINES ---" | tee -a "$OUTDIR/summary.txt"
    grep -nE "FAIL|FATAL|Error|error:" "$log" | head -25 | sed 's/^/    /' | tee -a "$OUTDIR/summary.txt"
  fi
  echo >> "$OUTDIR/summary.txt"
  return "$rc"
}

mapfile -t TESTS < <(find "$ROOT/tests" -name 'test-*.sh' | LC_ALL=C sort)
TOTAL=0
PASS_ALL=0
FAILS=""
for i in "${!TESTS[@]}"; do
  TOTAL=$((TOTAL+1))
  rel="${TESTS[$i]#"$ROOT"/}"
  run_test "$rel" "$((i+1))"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS_ALL=$((PASS_ALL+1))
  else
    FAILS="$FAILS $rel(rc=$rc)"
  fi
done
echo "========== FULL SUITE DONE =========="
echo "SUITES: $PASS_ALL/$TOTAL passed"
echo "FAILS:$FAILS"
echo "OUTDIR: $OUTDIR"
if [ -n "$FAILS" ]; then
  exit 1
fi
exit 0
