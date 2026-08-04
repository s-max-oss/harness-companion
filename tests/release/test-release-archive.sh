#!/bin/bash
# test-release-archive.sh — Verify git archive HEAD is release-ready
#
# Two phases:
#   Phase A (outer — runs inside the source git repo):
#     1. Verify templates/.harness/* are tracked (git ls-files)
#     2. Verify git archive HEAD extracts all 7 templates/.harness/ files
#     3. Verify plugin.json is in the archive
#     4. Extract the full archive into a temp dir
#   Phase B (inner — runs inside the extracted archive, no .git):
#     1. Representative core smoke tests (init, passing, fingerprint)
#     2. Adapter contracts (tests/adapters/test-*.sh)
#     3. Migration compat (tests/migration/test-v1-compat.sh)
#        — G13 git-ls-files/git-archive assertions SKIP when .git is absent
#     4. Codex validate_plugin.py
#
# Validator resolution (priority order):
#   1. $HARNESS_VALIDATOR env var (explicit override)
#   2. $CODEX_VALIDATOR_PATH env var (legacy)
#   3. Common install locations (cross-platform)
#   4. find-based search under $HOME
#
# Missing validator is a HARD FAIL unless HARNESS_VALIDATOR_SKIP_OK=1 is set.
#
# Usage:
#   bash tests/release/test-release-archive.sh
#   HARNESS_VALIDATOR=/path/to/validate_plugin.py bash tests/release/test-release-archive.sh
#   HARNESS_VALIDATOR_SKIP_OK=1 bash tests/release/test-release-archive.sh  # CI mode
#
# Exit 0 if everything passes, 1 if any test or validator fails.

set -uo pipefail

SOURCE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASSED=0
FAILED=0
SKIPPED=0

# ---- helpers ------------------------------------------------------------------

# Cumulative cleanup: single EXIT trap cleans all registered dirs.
cleanup_dirs=()
add_cleanup() { cleanup_dirs+=("$1"); }
cleanup_all() {
  local d
  for d in "${cleanup_dirs[@]}"; do
    [ -n "$d" ] && rm -rf -- "$d" 2>/dev/null
  done
}
trap cleanup_all EXIT

# Safe mktemp — runs in PARENT shell (no subshell). Validates the dir,
# refuses to assign an empty/non-existent path, registers cleanup in the
# parent's trap state, and returns non-zero on failure.
#
# Usage: safe_mktemp VAR [label]
#
# MUST NOT be called as VAR="$(safe_mktemp ...)" — the subshell would lose
# the trap state and exit 1 would terminate only the subshell.
safe_mktemp() {
  local _varname="$1" _label="${2:-unknown}"

  if ! [[ "$_varname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "FATAL: safe_mktemp received illegal varname '$_varname'" >&2
    return 1
  fi

  local _dir=""
  _dir="$(mktemp -d 2>/dev/null)" || _dir=""
  if [ -z "$_dir" ] || [ ! -d "$_dir" ] || [ ! -w "$_dir" ]; then
    echo "FATAL: mktemp failed (label=$_label)" >&2
    return 1
  fi

  add_cleanup "$_dir"
  printf -v "$_varname" '%s' "$_dir" || {
    echo "FATAL: could not assign temp dir to '$_varname'" >&2
    return 1
  }
}

# Resolve validator path. Returns path on stdout (exit 0), or nothing (exit 1).
# Exit 2: validator not found but SKIP_OK is set.
find_validator() {
  # 1. Explicit env var overrides
  if [ -n "${HARNESS_VALIDATOR:-}" ]; then
    if [ -f "$HARNESS_VALIDATOR" ]; then
      echo "$HARNESS_VALIDATOR"
      return 0
    fi
    echo "FATAL: HARNESS_VALIDATOR='$HARNESS_VALIDATOR' does not exist" >&2
    return 1
  fi
  if [ -n "${CODEX_VALIDATOR_PATH:-}" ] && [ -f "$CODEX_VALIDATOR_PATH" ]; then
    echo "$CODEX_VALIDATOR_PATH"
    return 0
  fi

  # 2. Common install locations (cross-platform)
  local cand
  for cand in \
    "$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py" \
    "$HOME/.codex/scripts/validate_plugin.py" \
    "/usr/local/share/codex/scripts/validate_plugin.py"; do
    [ -f "$cand" ] && { echo "$cand"; return 0; }
  done

  # 3. Last resort: find under $HOME (best-effort, may be slow)
  local found
  found="$(find "$HOME" -maxdepth 6 -name "validate_plugin.py" -path "*plugin-creator*" 2>/dev/null | head -1)"
  if [ -n "$found" ] && [ -f "$found" ]; then
    echo "$found"
    return 0
  fi

  # 4. Not found
  if [ "${HARNESS_VALIDATOR_SKIP_OK:-0}" = "1" ]; then
    return 2
  fi
  return 1
}

run_test() {
  local label="$1" script="$2"
  echo "---- $label ----"
  if [ ! -f "$script" ]; then
    echo "FAIL: required test $script not found in archive"
    FAILED=$((FAILED + 1))
    return 1
  fi
  if run_isolated_test "$script"; then
    echo "PASS: $label"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $label"
    FAILED=$((FAILED + 1))
  fi
  echo ""
}

# Execute an inner test with isolated HOME/TMPDIR so adapter baselines,
# Python tempfile directories, and legacy raw-mktemp fixtures cannot pollute
# the invoking user's profile or survive outside the release gate. The outer
# EXIT trap remains a backstop if the inner test is interrupted.
run_isolated_test() {
  local script="$1" sandbox="" rc=0 expected_tmp_root=""
  local native_home="" native_tmp=""
  safe_mktemp sandbox "inner-$(basename "$script")" || return 1
  mkdir -p "$sandbox/home" "$sandbox/tmp" "$sandbox/home/.config" || return 1

  native_home="$sandbox/home"
  native_tmp="$sandbox/tmp"
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*)
      # Native Windows children and nested Git Bash instances expect
      # USERPROFILE/TMP/TEMP in Windows form. TMPDIR/HOME stay POSIX so the
      # current Bash process and mktemp remain inside the same sandbox.
      if command -v cygpath >/dev/null 2>&1; then
        native_home="$(cygpath -w "$sandbox/home")"
        native_tmp="$(cygpath -w "$sandbox/tmp")"
      fi
      ;;
  esac

  # The fingerprint smoke has an explicit regression assertion that its own
  # workspace mktemp remains beneath this sandbox. Do not export that
  # assertion to adapter suites: they intentionally create nested isolated
  # environments with their own TMPDIR values.
  if [ "$(basename "$script")" = "test-workspace-fingerprint.sh" ]; then
    expected_tmp_root="$sandbox/tmp"
  fi

  HOME="$sandbox/home" \
  USERPROFILE="$native_home" \
  XDG_CONFIG_HOME="$sandbox/home/.config" \
  TMPDIR="$sandbox/tmp" \
  TMP="$native_tmp" \
  TEMP="$native_tmp" \
  HARNESS_EXPECTED_TMP_ROOT="$expected_tmp_root" \
    bash "$script" 2>&1 || rc=$?

  rm -rf -- "$sandbox" 2>/dev/null || true
  return "$rc"
}

# Run representative core smoke tests from the extracted archive. The full
# core regression already runs in CI Phase 1; repeating all 11 suites here
# pushed the release job beyond its 30-minute timeout without adding archive-
# specific coverage. These smokes prove executable behavior survives archive.
run_core_smokes() {
  local failed=0
  local smoke_tests=(
    tests/core/test-init.sh
    tests/core/test-passing.sh
    tests/core/test-workspace-fingerprint.sh
  )
  local t
  for t in "${smoke_tests[@]}"; do
    if [ ! -f "$t" ]; then
      echo "FAIL: required core smoke $t not found in archive"
      FAILED=$((FAILED + 1))
      failed=$((failed + 1))
      continue
    fi
    printf '  %-50s ' "$t"
    if run_isolated_test "$t" >/dev/null 2>&1; then
      echo "PASS"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL"
      FAILED=$((FAILED + 1))
      failed=$((failed + 1))
    fi
  done
  return $failed
}

echo "============================================"
echo "  test-release-archive.sh"
echo "  Source repo: $SOURCE_REPO"
echo "============================================"

# Resolve the validator before doing any expensive archive/test work. An
# explicitly invalid override must fail immediately rather than spending a
# full archive run before reporting a configuration error.
VALIDATOR=""
VALIDATOR_STATUS=""
if VALIDATOR="$(find_validator)"; then
  VALIDATOR_STATUS="found"
else
  VALIDATOR_RC=$?
  if [ "$VALIDATOR_RC" = "2" ]; then
    VALIDATOR_STATUS="skip-approved"
  else
    echo "FATAL: validate_plugin.py not found — release gate BLOCKED" >&2
    echo "  Set HARNESS_VALIDATOR=/path/to/validate_plugin.py" >&2
    echo "  Or set HARNESS_VALIDATOR_SKIP_OK=1 for explicit exemption" >&2
    exit 1
  fi
fi

# ---- Phase A: outer — verify in source repo --------------------------------
echo ""
echo "=== Phase A: Outer — git-ls-files + git archive ==="

# A1: templates/.harness/ tracked file count
TRACKED_COUNT="$(git -C "$SOURCE_REPO" ls-files templates/.harness/ | wc -l)"
if [ "$TRACKED_COUNT" -eq 7 ]; then
  echo "PASS: A1 — git ls-files templates/.harness/ = 7"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: A1 — expected 7 tracked files, got $TRACKED_COUNT"
  FAILED=$((FAILED + 1))
fi

# A2: git archive extraction file count
ARCHIVE_DIR=""
safe_mktemp ARCHIVE_DIR "phase-a-archive" || exit 1
git -C "$SOURCE_REPO" archive HEAD -- 'templates/.harness/' | tar -x -C "$ARCHIVE_DIR" || { echo "FATAL: git archive extraction failed" >&2; exit 1; }
ARCHIVE_COUNT="$(find "$ARCHIVE_DIR" -type f | wc -l)"
if [ "$ARCHIVE_COUNT" -eq 7 ]; then
  echo "PASS: A2 — git archive HEAD templates/.harness/ → 7 files extracted"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: A2 — expected 7 files in archive extraction, got $ARCHIVE_COUNT"
  FAILED=$((FAILED + 1))
fi
# Clean A2 extract (not needed after this check), but keep ARCHIVE_DIR for A3
rm -rf "$ARCHIVE_DIR"/* 2>/dev/null || true

# A3: verify plugin.json is in the archive
git -C "$SOURCE_REPO" archive HEAD -- '.codex-plugin/plugin.json' | tar -x -C "$ARCHIVE_DIR" || { echo "FATAL: plugin.json extraction failed" >&2; exit 1; }
if [ -f "$ARCHIVE_DIR/.codex-plugin/plugin.json" ]; then
  echo "PASS: A3 — .codex-plugin/plugin.json in archive"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: A3 — .codex-plugin/plugin.json missing from archive"
  FAILED=$((FAILED + 1))
fi

# A4: extract full archive for Phase B
FULL_ARCHIVE_DIR=""
safe_mktemp FULL_ARCHIVE_DIR "phase-b-full-archive" || exit 1
rm -rf "$ARCHIVE_DIR" 2>/dev/null || true
git -C "$SOURCE_REPO" archive HEAD | tar -x -C "$FULL_ARCHIVE_DIR" || { echo "FATAL: full archive extraction failed" >&2; exit 1; }
if [ -d "$FULL_ARCHIVE_DIR/tests" ] && [ -f "$FULL_ARCHIVE_DIR/SKILL.md" ]; then
  echo "PASS: A4 — full archive extracted to $FULL_ARCHIVE_DIR"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: A4 — archive extraction incomplete"
  FAILED=$((FAILED + 1))
  exit 1
fi
echo ""

# ---- Phase B: inner — run tests inside archive dir -------------------------
echo "=== Phase B: Inner — run tests inside archive (no .git) ==="
cd "$FULL_ARCHIVE_DIR" || { echo "FATAL: cd into archive dir failed" >&2; exit 1; }

IS_GIT=0
git rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1
echo "Archive has .git: $IS_GIT (0 = archive mode, tests that require .git should SKIP)"
echo ""

echo "=== Phase B1: Representative core smoke tests ==="
run_core_smokes

echo "=== Phase B2: Adapter contracts ==="
for t in tests/adapters/test-claude-code-contract.sh tests/adapters/test-codex-contract.sh tests/adapters/test-codex-install-modes.sh; do
  run_test "$(basename "$t")" "$t"
done

# ---- Phase B3: Migration compat (run ONCE, not 3 times) -------------------
echo "=== Phase B3: Migration compat (archive mode) ==="
echo ""
MIG_OUTPUT_DIR=""
safe_mktemp MIG_OUTPUT_DIR "migration-output" || exit 1
MIG_OUTPUT_FILE="$MIG_OUTPUT_DIR/migration.log"
MIG_RC=0
run_isolated_test tests/migration/test-v1-compat.sh >"$MIG_OUTPUT_FILE" || MIG_RC=$?
cat "$MIG_OUTPUT_FILE"
rm -rf -- "$MIG_OUTPUT_DIR" 2>/dev/null || true
if [ "$MIG_RC" -eq 0 ]; then
  echo "PASS: migration compat"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: migration compat"
  FAILED=$((FAILED + 1))
fi
echo ""

# ---- Phase B4: Official validate_plugin.py --------------------------------
echo "=== Phase B4: Official validate_plugin.py ==="
if [ "$VALIDATOR_STATUS" = "skip-approved" ]; then
  echo "SKIP: validate_plugin.py not found — HARNESS_VALIDATOR_SKIP_OK=1 (explicit exemption)"
  SKIPPED=$((SKIPPED + 1))
else
  echo "Validator: $VALIDATOR"
  if PYTHONIOENCODING=utf-8 python3 "$VALIDATOR" "$FULL_ARCHIVE_DIR" 2>&1; then
    echo "PASS: validate_plugin.py"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: validate_plugin.py"
    FAILED=$((FAILED + 1))
  fi
fi

echo ""
echo "============================================"
echo "  Release Archive Test Summary"
echo "  Passed:  $PASSED"
echo "  Failed:  $FAILED"
echo "  Skipped: $SKIPPED"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
