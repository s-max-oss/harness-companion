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
# Requires: bash, find, GNU timeout. Missing timeout fails closed before tests.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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
  echo "ERROR: GNU timeout is required; refusing to run suites without bounded execution." >&2
  exit 2
fi

# AC-12 / ISO-4: the entire suite runs under a disposable HOME containing a
# simulated installed-skill sentinel. This prevents a test from reaching a
# developer's real ~/.claude or ~/.agents tree and proves the simulated install
# remains untouched across the complete suite.
# Preserve only the caller's read-only validator discovery root before HOME is
# isolated. Release tests may inspect an installed validator there, but all
# installer and test writes remain bound to the disposable HOME below.
export HARNESS_VALIDATOR_SEARCH_HOME="${HARNESS_VALIDATOR_SEARCH_HOME:-${HOME:-}}"
SUITE_ISOLATION_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$SUITE_ISOLATION_ROOT"' EXIT
export HOME="$SUITE_ISOLATION_ROOT/home"
SUITE_SENTINEL="$HOME/.claude/skills/harness-companion/.sentinel"
mkdir -p "$(dirname "$SUITE_SENTINEL")" || exit 1
printf 'full-suite-isolation-sentinel\n' > "$SUITE_SENTINEL"
SUITE_SENTINEL_SHA="$(sha256sum "$SUITE_SENTINEL" | awk '{print $1}')"

run_test() {
  local rel="$1"
  local log rc res
  log="$(mktemp)"
  if [ "$rel" = "tests/release/test-version-sync.sh" ]; then
    # P0-7: shared install + test method — byte-for-byte the same sequence CI
    # Phase 5d runs via scripts/version-sync-gate.sh.
    "$TIMEOUT_BIN" --kill-after=60s 3000s bash "$ROOT/scripts/version-sync-gate.sh" "$ROOT" 2>&1 | tee "$log" | tail -3
    rc=${PIPESTATUS[0]}
  else
    # stdin from /dev/null so a SessionStart hook reading stdin can never block.
    "$TIMEOUT_BIN" --kill-after=60s 3000s bash "$ROOT/$rel" < /dev/null 2>&1 | tee "$log" | tail -3
    rc=${PIPESTATUS[0]}
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

record_result() {
  local rel="$1" rc="$2" output="$3"
  echo "========== RUNNING $rel =========="
  cat "$output"
  if [ "$rc" -eq 0 ]; then
    PASS_ALL=$((PASS_ALL+1))
  else
    FAILS="$FAILS $rel(rc=$rc)"
  fi
  echo
}

# The core contracts are fixture-isolated, but on Windows/MSYS their process
# startup cost makes a fully sequential run consume too much of the auditable
# command budget before the release archive can finish. Run only those core
# contracts two at a time. The lock-registry contract is intentionally serial:
# its T11 already launches two nested harness-verify writers, and an additional
# peer suite can exhaust the Windows/MSYS fork budget before either writer gets
# to exercise the lock. Adapter/install/release tests remain serialized because
# they exercise host-level installation and archive resources.
i=0
while [ "$i" -lt "${#TESTS[@]}" ]; do
  t1="${TESTS[$i]}"
  rel1="${t1#"$ROOT"/}"
  if [[ "$rel1" == tests/core/* ]] && [ $((i + 1)) -lt "${#TESTS[@]}" ]; then
    t2="${TESTS[$((i + 1))]}"
    rel2="${t2#"$ROOT"/}"
  else
    rel2=""
  fi

  if [[ "$rel2" == tests/core/* ]] \
      && [ "$rel1" != "tests/core/test-lock-registry.sh" ] \
      && [ "$rel2" != "tests/core/test-lock-registry.sh" ]; then
    out1="$(mktemp)"
    out2="$(mktemp)"
    run_test "$rel1" >"$out1" 2>&1 &
    pid1=$!
    run_test "$rel2" >"$out2" 2>&1 &
    pid2=$!
    wait "$pid1"; rc1=$?
    wait "$pid2"; rc2=$?
    TOTAL=$((TOTAL + 2))
    record_result "$rel1" "$rc1" "$out1"
    record_result "$rel2" "$rc2" "$out2"
    rm -f "$out1" "$out2"
    i=$((i + 2))
  else
    out1="$(mktemp)"
    run_test "$rel1" >"$out1" 2>&1
    rc1=$?
    TOTAL=$((TOTAL + 1))
    record_result "$rel1" "$rc1" "$out1"
    rm -f "$out1"
    i=$((i + 1))
  fi
done

if [ -f "$SUITE_SENTINEL" ] && [ "$(sha256sum "$SUITE_SENTINEL" | awk '{print $1}')" = "$SUITE_SENTINEL_SHA" ]; then
  echo "PASS: ISO-4 full-suite simulated installed-skill sentinel unchanged"
else
  echo "FAIL: ISO-4 full-suite simulated installed-skill sentinel changed"
  FAILS="$FAILS ISO-4-sentinel(rc=1)"
fi
echo "========== FULL SUITE DONE =========="
echo "SUITES: $PASS_ALL/$TOTAL passed"
if [ -n "$FAILS" ]; then
  echo "FAILS:$FAILS"
  exit 1
fi
exit 0
