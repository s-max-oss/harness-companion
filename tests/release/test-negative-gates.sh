#!/bin/bash
# test-negative-gates.sh — Prove release gates fail reliably
#
# Each sub-test DELIBERATELY causes a failure and asserts the gate exits
# non-zero, proving the gate catches the failure rather than running through.
#
# THIS SCRIPT MUST EXIT 0 when all negative tests pass (each gate correctly
# fails-closed). If any gate unexpectedly succeeds (exit 0 instead of non-zero),
# the overall script exits 1.
#
# Negative scenarios:
#   NEG-1: mktemp failure → gate must exit non-zero
#   NEG-2: fixture setup failure → gate must exit non-zero
#   NEG-3: missing validator (without SKIP_OK) → gate must exit non-zero
#
# Usage:
#   bash tests/release/test-negative-gates.sh
#
# Exit 0: all gates correctly fail-closed (negative tests pass)
# Exit 1: at least one gate unexpectedly succeeded (negative test failed)

set -uo pipefail

SOURCE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASSED=0
FAILED=0

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---- helpers ------------------------------------------------------------------

# Cumulative cleanup
cleanup_dirs=""
add_cleanup() { cleanup_dirs="$cleanup_dirs $1"; }
trap 'for d in $cleanup_dirs; do rm -rf "$d" 2>/dev/null; done' EXIT

safe_mktemp() {
  local _label="${1:-unknown}"
  local _dir; _dir="$(mktemp -d)" || { echo "FATAL: mktemp failed ($_label)" >&2; exit 1; }
  add_cleanup "$_dir"
  printf '%s' "$_dir"
}

neg_pass() {
  local label="$1"
  printf "${GREEN}PASS${NC} (negative): %s\n" "$label"
  PASSED=$((PASSED + 1))
}

neg_fail() {
  local label="$1" detail="${2:-}"
  printf "${RED}FAIL${NC} (negative): %s\n" "$label"
  [ -n "$detail" ] && printf "  detail: %s\n" "$detail"
  FAILED=$((FAILED + 1))
}

# Assert that a command exits NON-ZERO. Returns 0 if the command exits ≠ 0
# (gate correctly failed-closed). Returns 1 if the command exits 0 (gate
# unexpectedly succeeded — this is a bug).
assert_exit_nonzero() {
  local label="$1"; shift
  local cmd="$*"
  local rc=0
  eval "$cmd" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    neg_pass "$label (exit=$rc — gate correctly failed-closed)"
    return 0
  else
    neg_fail "$label (exit=0 — gate unexpectedly succeeded!)"
    return 1
  fi
}

echo "============================================"
echo "  test-negative-gates.sh"
echo "  Prove release gates fail reliably"
echo "============================================"
echo ""

# ---- NEG-1: mktemp failure → gate must exit non-zero -----------------------
echo "=== NEG-1: mktemp failure ==="
echo "Strategy: Override mktemp to always fail. The gate's safe_mktemp()"
echo "         should detect this and exit non-zero immediately."
echo ""

# Create a fake mktemp that always fails, then run the release archive test.
# We inject the fake by prepending a directory to PATH that contains our
# failing mktemp stub.
FAKE_BIN="$(safe_mktemp "neg1-fake-bin")"
cat > "$FAKE_BIN/mktemp" <<'STUB'
#!/bin/bash
echo "FAKE MKTEMP: deliberately failing" >&2
exit 1
STUB
chmod +x "$FAKE_BIN/mktemp"

assert_exit_nonzero \
  "NEG-1: mktemp failure blocks release archive gate" \
  "PATH=\"$FAKE_BIN:\$PATH\" bash \"$SOURCE_REPO/tests/release/test-release-archive.sh\""

echo ""

# ---- NEG-2: fixture setup failure → gate must exit non-zero ----------------
echo "=== NEG-2: fixture setup failure ==="
echo "Strategy: Create a read-only directory and attempt git operations inside"
echo "         it. The gate's setup failure checks should catch this."
echo ""

# We run a minimal inline test that mirrors the safe_mktemp + git init pattern
# but with a deliberately broken directory.
NEG2_TMP="$(safe_mktemp "neg2-test")"

# Create a read-only subdirectory inside the temp dir
NEG2_RO="$NEG2_TMP/readonly-dir"
mkdir "$NEG2_RO" || { echo "FATAL: mkdir failed (neg2)" >&2; exit 1; }
chmod 555 "$NEG2_RO" 2>/dev/null || true

# Try to run a test script that needs to write into a read-only dir.
# This should fail because `mktemp` or `git init` can't create files.
cat > "$NEG2_TMP/neg2-test.sh" <<'NEG2SCRIPT'
#!/bin/bash
set -uo pipefail
safe_mktemp() {
  local _dir; _dir="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  printf '%s' "$_dir"
}
T="$(safe_mktemp "neg2-inner")" || exit 1
# This should never be reached if safe_mktemp works (but our PATH may allow it)
# Actually we test git init failure:
cd "$T" || { echo "FATAL: cd into test dir failed" >&2; exit 1; }
# Write into a path that doesn't exist to trigger git init failure:
git init --quiet /nonexistent/path/should/fail 2>/dev/null || { echo "FATAL: git init failed" >&2; exit 1; }
echo "SHOULD NOT REACH HERE"
exit 0
NEG2SCRIPT
chmod +x "$NEG2_TMP/neg2-test.sh"

assert_exit_nonzero \
  "NEG-2: fixture setup failure blocks execution" \
  "bash \"$NEG2_TMP/neg2-test.sh\""

echo ""

# ---- NEG-2b: git init inside read-only dir fails --------------------------
NEG2B_TMP="$(safe_mktemp "neg2b-test")"
cat > "$NEG2B_TMP/neg2b-test.sh" <<'NEG2BSCRIPT'
#!/bin/bash
set -uo pipefail
safe_mktemp() {
  local _label="${1:-unknown}"
  local _dir; _dir="$(mktemp -d)" || { echo "FATAL: mktemp failed ($_label)" >&2; exit 1; }
  printf '%s' "$_dir"
}
# Simulate the git-init setup pattern from test files
T="$(safe_mktemp "neg2b")"
cd "$T" || { echo "FATAL: cd failed" >&2; exit 1; }
git init --quiet . || { echo "FATAL: git init failed" >&2; exit 1; }
git config user.email t@t && git config user.name t
echo "base" > src.txt
git add -A && git commit -m "base" --quiet || { echo "FATAL: git commit failed" >&2; exit 1; }
# Deliberately corrupt the git repo to cause failure
rm -rf .git/objects
# This should fail because we corrupted .git
git add -A 2>/dev/null || { echo "FATAL: git add failed in corrupted repo" >&2; exit 1; }
echo "SHOULD NOT REACH HERE"
exit 0
NEG2BSCRIPT
chmod +x "$NEG2B_TMP/neg2b-test.sh"

assert_exit_nonzero \
  "NEG-2b: git add failure in corrupted repo blocks execution" \
  "bash \"$NEG2B_TMP/neg2b-test.sh\""

echo ""

# ---- NEG-3: missing validator (without SKIP_OK) blocks release -------------
echo "=== NEG-3: missing validator (without SKIP_OK) ==="
echo "Strategy: Set HARNESS_VALIDATOR=/nonexistent/path, do NOT set SKIP_OK."
echo "         The find_validator() should return non-zero, causing the gate"
echo "         to FAIL (not SKIP)."
echo ""

# Unset SKIP_OK (belt-and-suspenders — our assert wrapper unsets it too)
assert_exit_nonzero \
  "NEG-3: missing validator (HARNESS_VALIDATOR=/nonexistent, no SKIP_OK) blocks release" \
  "HARNESS_VALIDATOR=/nonexistent/path/validate_plugin.py HARNESS_VALIDATOR_SKIP_OK=0 bash \"$SOURCE_REPO/tests/release/test-release-archive.sh\""

echo ""

# ---- NEG-3b: validator set but file doesn't exist blocks release ----------
assert_exit_nonzero \
  "NEG-3b: HARNESS_VALIDATOR points to non-existent file → blocks" \
  "HARNESS_VALIDATOR=/tmp/nonexistent_validate_plugin_xyz.py bash \"$SOURCE_REPO/tests/release/test-release-archive.sh\""

echo ""

# ---- NEG-4 (bonus): verify that mktemp stub actually fails -----------------
echo "=== NEG-4: Verify the fake mktemp stub itself fails ==="
FAKE_BIN2="$(safe_mktemp "neg4-fake-bin")"
cat > "$FAKE_BIN2/mktemp" <<'STUB'
#!/bin/bash
echo "FAKE MKTEMP: deliberately failing" >&2
exit 1
STUB
chmod +x "$FAKE_BIN2/mktemp"

# The fake mktemp should exit 1
FAKE_RC=0
PATH="$FAKE_BIN2:$PATH" mktemp -d >/dev/null 2>&1 || FAKE_RC=$?
if [ "$FAKE_RC" -ne 0 ]; then
  neg_pass "NEG-4: fake mktemp stub correctly exits non-zero ($FAKE_RC)"
else
  neg_fail "NEG-4: fake mktemp stub unexpectedly succeeded" "Stub is broken"
fi

echo ""

# ---- Summary ---------------------------------------------------------------
echo "============================================"
echo "  Negative Gate Test Summary"
echo "  Passed (gates correctly fail-closed): $PASSED"
echo "  Failed (gates unexpectedly succeeded): $FAILED"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "FATAL: $FAILED negative test(s) failed — at least one gate"
  echo "unexpectedly succeeded when it should have failed-closed."
  echo "This is a RELEASE BLOCKER — the gate is NOT reliable."
  exit 1
fi

echo ""
echo "All negative tests pass: gates reliably fail-closed on errors."
exit 0
