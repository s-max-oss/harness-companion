#!/bin/bash
# test-negative-gates.sh — Prove release gates fail reliably using REAL gates
#
# This script DELIBERATELY causes failures and asserts each gate exits
# non-zero. Every test invokes the REAL production gate script (not a
# reimplemented example). NEG-4/NEG-5 source the REAL helper functions
# extracted from the release archive gate to verify safe_mktemp / add_cleanup
# behavior at the function level.
#
# After each gate abort, the harness asserts:
#   1. Source repo HEAD unchanged (git rev-parse HEAD)
#   2. Source repo working tree clean
#   3. /tmp baseline unchanged (zero new dirs)
#   4. Sentinel NOT created (gate aborted before fixture steps)
#
# Exit 0: all gates correctly fail-closed
# Exit 1: at least one gate unexpectedly succeeded

set -uo pipefail

SOURCE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
PASSED=0
FAILED=0

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- helpers for THIS harness (NOT the gates under test) -------------------

cleanup_dirs=()
add_cleanup() { cleanup_dirs+=("$1"); }
cleanup_all() {
  local d
  for d in "${cleanup_dirs[@]}"; do
    [ -n "$d" ] && rm -rf -- "$d" 2>/dev/null
  done
}
trap cleanup_all EXIT

# Harness own temp-dir factory. Separate from gate's safe_mktemp under test.
h_mktemp() {
  local _varname="$1" _label="${2:-unknown}"
  local _dir; _dir="$(mktemp -d 2>/dev/null)" || _dir=""
  if [ -z "$_dir" ] || [ ! -d "$_dir" ]; then
    echo "FATAL: harness mktemp failed ($_label)" >&2
    return 1
  fi
  add_cleanup "$_dir"
  printf -v "$_varname" '%s' "$_dir" || return 1
}

neg_pass() {
  printf "${GREEN}PASS${NC} (negative): %s\n" "$1"
  PASSED=$((PASSED + 1))
}

neg_fail() {
  printf "${RED}FAIL${NC} (negative): %s — %s\n" "$1" "${2:-}"
  FAILED=$((FAILED + 1))
}

SKIPPED=0
neg_skip() {
  printf "${CYAN}SKIP${NC} (negative): %s\n" "$1"
  SKIPPED=$((SKIPPED + 1))
}

# Assert gate exits non-zero, and post-state matches pre-state.
#
# Usage: assert_gate_fail_closed [--skip-residue]
#          [--expect-diagnostic REGEX] LABEL SENTINEL CMD...
#
#   --skip-residue  Omit /tmp residue check. Use when the gate runs inner
#                   test suites that create temp dirs via raw mktemp
#                   (pre-existing condition, not the gate's fault).
#   --expect-diagnostic REGEX
#                   Require gate output to match a scenario-specific regex,
#                   preventing an unrelated early failure from counting as
#                   proof that the intended guard fired.
#
#   LABEL           Display label for this assertion.
#   SENTINEL        Touch-file path (deleted before pre-state capture).
#   CMD...          Gate command. The CALLER must append
#                   `&& touch "$SENTINEL"` so the sentinel is ONLY created
#                   when the gate unexpectedly exits 0.  Do NOT use `;`.
assert_gate_fail_closed() {
  local skip_residue=0 expected_diagnostic="" require_gate=""
  while [ "${1:-}" = "--skip-residue" ] || [ "${1:-}" = "--expect-diagnostic" ] \
        || [ "${1:-}" = "--require-gate" ]; do
    case "$1" in
      --skip-residue)
        skip_residue=1
        shift
        ;;
      --expect-diagnostic)
        expected_diagnostic="${2:-}"
        shift 2
        ;;
      --require-gate)
        require_gate="${2:-}"
        shift 2
        ;;
    esac
  done

  local label="$1" sentinel="$2"
  shift 2

  # A retired gate cannot be exercised: report it explicitly instead of
  # silently passing or failing the negative suite.
  if [ -n "$require_gate" ] && [ ! -f "$require_gate" ]; then
    neg_skip "$label (gate retired: ${require_gate#"$SOURCE_REPO"/})"
    return 0
  fi

  # Clean up any sentinel from a prior run, THEN capture baseline.
  # This way git status --porcelain won't count the sentinel file.
  rm -f "$sentinel"

  local head_before worktree_before
  head_before="$(git -C "$SOURCE_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
  worktree_before="$(git -C "$SOURCE_REPO" status --porcelain 2>/dev/null | wc -l)"

  # Snapshot the active temp root for residue detection (unless skipped).
  # Store snapshots outside that root so the snapshot files themselves
  # don't appear in the diff.
  local assertion_dir=""
  local tmp_snap_before=""
  local tmp_snap_after=""
  local gate_output=""
  h_mktemp assertion_dir "neg-assertion" || return 1
  gate_output="$assertion_dir/gate-output.log"
  if [ "$skip_residue" -eq 0 ]; then
    tmp_snap_before="$assertion_dir/before.txt"
    tmp_snap_after="$assertion_dir/after.txt"
    ls -1 "$TEST_TMP_ROOT" 2>/dev/null | sort > "$tmp_snap_before"
  fi

  # Run gate. eval propagates the exit code of the last command in the
  # pipeline. Because the caller uses "&& touch sentinel", if the gate
  # exits non-zero (correct behavior) the compound exits non-zero, eval
  # sees that, and gate_rc captures it.
  local gate_rc=0
  eval "$*" >"$gate_output" 2>&1 || gate_rc=$?

  # Post-state
  local head_after; head_after="$(git -C "$SOURCE_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
  local worktree_after; worktree_after="$(git -C "$SOURCE_REPO" status --porcelain 2>/dev/null | wc -l)"

  local leaked_gate=0 leak_names=""
  if [ "$skip_residue" -eq 0 ]; then
    ls -1 "$TEST_TMP_ROOT" 2>/dev/null | sort > "$tmp_snap_after"
    # Filter to only entries matching mktemp's default prefix (tmp.)
    # to exclude system noise from unrelated processes.
    local new_entries; new_entries="$(comm -13 "$tmp_snap_before" "$tmp_snap_after" 2>/dev/null)"
    leaked_gate="$(echo "$new_entries" | grep -cE '^tmp\.' 2>/dev/null || true)"
    [ "$leaked_gate" = "" ] && leaked_gate=0
    [ "$leaked_gate" -gt 0 ] && leak_names="$(echo "$new_entries" | grep -E '^tmp\.' | head -5 | tr '\n' ' ')"
  fi

  local sentinel_exists=0
  [ -e "$sentinel" ] && sentinel_exists=1

  local issues=""
  if [ "$gate_rc" -eq 0 ]; then
    issues="${issues}gate exited 0 (should be non-zero); "
  fi
  if [ -n "$expected_diagnostic" ] && ! grep -Eq "$expected_diagnostic" "$gate_output"; then
    issues="${issues}expected diagnostic not found ('$expected_diagnostic'); "
  fi
  if [ "$head_before" != "$head_after" ]; then
    issues="${issues}HEAD changed; "
  fi
  if [ "$worktree_before" != "$worktree_after" ]; then
    issues="${issues}worktree changed ($worktree_before → $worktree_after lines); "
  fi
  if [ "$leaked_gate" -gt 0 ]; then
    issues="${issues}$leaked_gate mktemp-dirs leaked [$(echo "$leak_names" | xargs)]; "
  fi
  if [ "$sentinel_exists" -eq 1 ]; then
    issues="${issues}sentinel exists (gate ran fixture steps before abort); "
  fi

  local residue_note=""
  [ "$skip_residue" -eq 1 ] && residue_note=", residue skipped"

  if [ -z "$issues" ]; then
    neg_pass "$label (rc=$gate_rc, HEAD/worktree clean$residue_note, no fixture steps)"
    return 0
  fi
  neg_fail "$label" "$issues"
  return 1
}

echo "============================================"
echo "  test-negative-gates.sh"
echo "  Source repo: $SOURCE_REPO"
echo "  All negative tests invoke REAL gates"
echo "============================================"
echo ""

# ---- Fake mktemp factory ---------------------------------------------------

setup_fake_mktemp() {
  local _varname="$1" label="$2"
  local exit_code="${3:-1}"
  local emit_output="${4:-0}"  # 1 = emit a valid dir path before exiting
  local dir=""
  h_mktemp dir "fake-mktemp-$label" || return 1

  if [ "$emit_output" -eq 1 ]; then
    cat > "$dir/mktemp" <<STUB
#!/bin/bash
echo "$dir/fake-tmp-dir-\$\$"
exit $exit_code
STUB
  else
    cat > "$dir/mktemp" <<STUB
#!/bin/bash
echo "FAKE MKTEMP: deliberately failing" >&2
exit $exit_code
STUB
  fi
  chmod +x "$dir/mktemp"
  printf -v "$_varname" '%s' "$dir" || return 1
}

# ---- NEG-1: mktemp failure (exit 1, no output) aborts real core gate ------
echo "=== NEG-1: mktemp failure (real core gate) ==="

FAKE_BIN=""
setup_fake_mktemp FAKE_BIN "1" || exit 1

SENTINEL="$SOURCE_REPO/.neg1-sentinel"
assert_gate_fail_closed \
  --expect-diagnostic "FATAL: mktemp failed" \
  "NEG-1: mktemp exit 1 aborts test-workspace-fingerprint.sh" \
  "$SENTINEL" \
  "PATH=\"$FAKE_BIN:\$PATH\" bash \"$SOURCE_REPO/tests/core/test-workspace-fingerprint.sh\" && touch \"$SENTINEL\""

echo ""

# ---- NEG-1b: mktemp failure blocks migration gate -------------------------
echo "=== NEG-1b: mktemp failure (real migration gate) ==="

FAKE_BIN_B=""
setup_fake_mktemp FAKE_BIN_B "1b" || exit 1

SENTINEL="$SOURCE_REPO/.neg1b-sentinel"
assert_gate_fail_closed \
  --expect-diagnostic "FATAL: mktemp failed" \
  --require-gate "$SOURCE_REPO/tests/migration/test-v1-compat.sh" \
  "NEG-1b: mktemp exit 1 aborts test-v1-compat.sh" \
  "$SENTINEL" \
  "PATH=\"$FAKE_BIN_B:\$PATH\" bash \"$SOURCE_REPO/tests/migration/test-v1-compat.sh\" && touch \"$SENTINEL\""

echo ""

# ---- NEG-1c: mktemp failure blocks release archive gate -------------------
echo "=== NEG-1c: mktemp failure (real release archive gate) ==="

FAKE_BIN_C=""
setup_fake_mktemp FAKE_BIN_C "1c" || exit 1

SENTINEL="$SOURCE_REPO/.neg1c-sentinel"
assert_gate_fail_closed \
  --expect-diagnostic "FATAL: mktemp failed" \
  --require-gate "$SOURCE_REPO/tests/release/test-release-archive.sh" \
  "NEG-1c: mktemp exit 1 aborts test-release-archive.sh" \
  "$SENTINEL" \
  "PATH=\"$FAKE_BIN_C:\$PATH\" HARNESS_VALIDATOR_SKIP_OK=1 bash \"$SOURCE_REPO/tests/release/test-release-archive.sh\" && touch \"$SENTINEL\""

echo ""

# ---- NEG-1d: real fixture setup failure aborts immediately ----------------
echo "=== NEG-1d: git init fixture failure (real core gate) ==="

FAKE_GIT_DIR=""
h_mktemp FAKE_GIT_DIR "neg1d-fake-git" || exit 1
REAL_GIT="$(command -v git)"
GIT_CALL_LOG="$FAKE_GIT_DIR/git-calls.log"
cat > "$FAKE_GIT_DIR/git" <<STUB
#!/bin/bash
echo "\${1:-missing}" >> "$GIT_CALL_LOG"
if [ "\${1:-}" = "init" ]; then
  echo "FAKE GIT: deliberately failing git init" >&2
  exit 42
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$FAKE_GIT_DIR/git"

SENTINEL="$SOURCE_REPO/.neg1d-sentinel"
assert_gate_fail_closed \
  --expect-diagnostic "FATAL: git init failed" \
  "NEG-1d: git init failure aborts real core gate" \
  "$SENTINEL" \
  "PATH=\"$FAKE_GIT_DIR:\$PATH\" bash \"$SOURCE_REPO/tests/core/test-workspace-fingerprint.sh\" && touch \"$SENTINEL\""

GIT_CALL_COUNT="$(wc -l < "$GIT_CALL_LOG" | tr -d ' ')"
if [ "$GIT_CALL_COUNT" -eq 1 ] && grep -qx "init" "$GIT_CALL_LOG"; then
  neg_pass "NEG-1d: gate stopped immediately after failing git init"
else
  neg_fail "NEG-1d" "gate executed later git commands after fixture failure: $(tr '\n' ' ' < "$GIT_CALL_LOG")"
fi

echo ""

# ---- NEG-2: missing validator without SKIP_OK blocks release gate ---------
echo "=== NEG-2: missing validator blocks release archive gate ==="

SENTINEL="$SOURCE_REPO/.neg2-sentinel"
assert_gate_fail_closed \
  --expect-diagnostic "HARNESS_VALIDATOR=.*does not exist" \
  --require-gate "$SOURCE_REPO/tests/release/test-release-archive.sh" \
  "NEG-2: HARNESS_VALIDATOR=/nonexistent + no SKIP_OK → FAILS" \
  "$SENTINEL" \
  "HARNESS_VALIDATOR=/nonexistent/path/validate_plugin.py HARNESS_VALIDATOR_SKIP_OK=0 bash \"$SOURCE_REPO/tests/release/test-release-archive.sh\" && touch \"$SENTINEL\""

echo ""

# NEG-4 through NEG-6 exercise helper functions extracted from the release
# archive gate. With that gate retired there is nothing to extract, so the
# three cases are reported as skipped rather than failed.
ARCHIVE_GATE="$SOURCE_REPO/tests/release/test-release-archive.sh"
if [ ! -f "$ARCHIVE_GATE" ]; then
  neg_skip "NEG-4: safe_mktemp failure case retired with the release archive gate"
  neg_skip "NEG-5: safe_mktemp empty-output case retired with the release archive gate"
  neg_skip "NEG-6: cumulative trap case retired with the release archive gate"
else

# ---- NEG-4: real safe_mktemp fails on mktemp failure (function level) -----
echo "=== NEG-4: real safe_mktemp() rejects mktemp failure ==="

# Extract only the helper definitions from the real release archive gate.
# Must NOT source the whole script because it does set -uo pipefail and runs.
HELPERS_DIR=""
h_mktemp HELPERS_DIR "neg4-helpers" || exit 1
sed -n '/^cleanup_dirs=()/,/^# Resolve validator path/p' \
  "$SOURCE_REPO/tests/release/test-release-archive.sh" | sed '$d' > "$HELPERS_DIR/helpers.sh"

FAKE_BIN4=""
h_mktemp FAKE_BIN4 "neg4-fake-bin" || exit 1
cat > "$FAKE_BIN4/mktemp" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$FAKE_BIN4/mktemp"

NEG4_OUT="$HELPERS_DIR/neg4-out.txt"
bash -c "
  set +e
  source \"$HELPERS_DIR/helpers.sh\"
  RESULT_VAR=\"\"
  PATH=\"$FAKE_BIN4:\$PATH\" safe_mktemp RESULT_VAR \"neg4\" || exit 1
  echo \"REACHED_AFTER_SAFE_MKTEMP RESULT_VAR='\$RESULT_VAR'\"
" > "$NEG4_OUT" 2>&1
NEG4_RC=$?

if [ "$NEG4_RC" -ne 0 ] && grep -q "FATAL:" "$NEG4_OUT" && ! grep -q "REACHED_AFTER_SAFE_MKTEMP" "$NEG4_OUT"; then
  neg_pass "NEG-4: real safe_mktemp returned non-zero and caller aborted"
else
  neg_fail "NEG-4" "safe_mktemp path did not fail-closed (rc=$NEG4_RC): $(head -3 "$NEG4_OUT")"
fi

echo ""

# ---- NEG-5: real safe_mktemp detects silent-empty mktemp output -----------
echo "=== NEG-5: real safe_mktemp detects empty mktemp output ==="

FAKE_BIN5=""
h_mktemp FAKE_BIN5 "neg5-fake-bin" || exit 1
cat > "$FAKE_BIN5/mktemp" <<'STUB'
#!/bin/bash
# Simulate mktemp that succeeds (exit 0) but produces EMPTY stdout.
# This was the original bug vector — command substitution returns "".
exit 0
STUB
chmod +x "$FAKE_BIN5/mktemp"

NEG5_OUT="$HELPERS_DIR/neg5-out.txt"
bash -c "
  set +e
  source \"$HELPERS_DIR/helpers.sh\"
  RESULT_VAR=\"\"
  PATH=\"$FAKE_BIN5:\$PATH\" safe_mktemp RESULT_VAR \"neg5\" || exit 1
  echo \"REACHED_AFTER_SAFE_MKTEMP RESULT_VAR='\$RESULT_VAR'\"
" > "$NEG5_OUT" 2>&1
NEG5_RC=$?

if [ "$NEG5_RC" -ne 0 ] && grep -q "FATAL:" "$NEG5_OUT" && ! grep -q "REACHED_AFTER_SAFE_MKTEMP" "$NEG5_OUT"; then
  neg_pass "NEG-5: real safe_mktemp detects silent-empty mktemp and aborts"
else
  neg_fail "NEG-5" "real safe_mktemp accepted empty output — output: $(head -3 "$NEG5_OUT")"
fi

echo ""

# ---- NEG-6: cumulative trap cleans up registered dirs ---------------------
echo "=== NEG-6: real cumulative trap cleans up registered dirs ==="

PROBE_PREFIX="neg6-probe-$$"
TMP_BEFORE="$(find "$TEST_TMP_ROOT" -maxdepth 1 -type d -name "${PROBE_PREFIX}*" 2>/dev/null | wc -l)"

(
  set +e
  source "$HELPERS_DIR/helpers.sh"
  for i in 1 2 3; do
    D="$(mktemp -d -t "${PROBE_PREFIX}-XXXXXX" 2>/dev/null)"
    [ -n "$D" ] && add_cleanup "$D"
  done
  exit 0
)

TMP_AFTER="$(find "$TEST_TMP_ROOT" -maxdepth 1 -type d -name "${PROBE_PREFIX}*" 2>/dev/null | wc -l)"
if [ "$TMP_AFTER" -eq 0 ] && [ "$TMP_BEFORE" -eq 0 ]; then
  neg_pass "NEG-6: cumulative trap cleaned all 3 registered dirs (0 orphans)"
else
  neg_fail "NEG-6" "cumulative trap left orphan(s): before=$TMP_BEFORE after=$TMP_AFTER"
fi

fi  # end archive-gate availability guard

echo ""

# ---- Summary ---------------------------------------------------------------
echo "============================================"
echo "  Negative Gate Test Summary"
echo "  Passed (gates correctly fail-closed):  $PASSED"
echo "  Failed (gates unexpectedly succeeded): $FAILED"
echo "  Skipped (gate retired):                $SKIPPED"
echo "============================================"

# Cleanup sentinels
rm -f "$SOURCE_REPO"/.neg*-sentinel 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "FATAL: $FAILED negative test(s) failed — at least one gate"
  echo "unexpectedly succeeded when it should have failed-closed."
  echo "This is a RELEASE BLOCKER."
  exit 1
fi

echo ""
echo "All negative tests pass: gates reliably fail-closed on errors."
exit 0
