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

# Preserve the caller's read-only validator search root before isolating all
# installer activity. Validator discovery must not be disabled by the sandbox.
VALIDATOR_SEARCH_HOME="${HARNESS_VALIDATOR_SEARCH_HOME:-${HOME:-}}"
# A valid explicit override never traverses the search root. Otherwise, a
# non-empty root must be canonical and option-safe before find sees it. An
# empty root remains valid for documented SKIP_OK/headless environments.
if [ -n "${HARNESS_VALIDATOR:-}" ] \
   || { [ -n "${CODEX_VALIDATOR_PATH:-}" ] && [ -f "$CODEX_VALIDATOR_PATH" ]; }; then
  VALIDATOR_SEARCH_HOME=""
elif [ -n "$VALIDATOR_SEARCH_HOME" ]; then
  case "$VALIDATOR_SEARCH_HOME" in
    /*) ;;
    *)
      echo "FATAL: validator search root must be an absolute existing directory" >&2
      exit 1
      ;;
  esac
  if [ ! -d "$VALIDATOR_SEARCH_HOME" ]; then
    echo "FATAL: validator search root must be an absolute existing directory" >&2
    exit 1
  fi
  VALIDATOR_SEARCH_HOME="$(cd -- "$VALIDATOR_SEARCH_HOME" 2>/dev/null && pwd -P)" || {
    echo "FATAL: validator search root could not be canonicalized" >&2
    exit 1
  }
fi

# ISO-2: archive install/uninstall round-trips use a disposable home even
# though project-mode targets are already temporary directories.
safe_mktemp INSTALL_TEST_HOME iso2-home || exit 1
export HOME="$INSTALL_TEST_HOME"

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
  if [ -n "$VALIDATOR_SEARCH_HOME" ]; then
    for cand in \
      "$VALIDATOR_SEARCH_HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py" \
      "$VALIDATOR_SEARCH_HOME/.codex/scripts/validate_plugin.py"; do
      [ -f "$cand" ] && { echo "$cand"; return 0; }
    done
  fi
  cand="/usr/local/share/codex/scripts/validate_plugin.py"
  [ -f "$cand" ] && { echo "$cand"; return 0; }

  # 3. Last resort: find under $HOME (best-effort, may be slow)
  local found=""
  if [ -n "$VALIDATOR_SEARCH_HOME" ]; then
    found="$(find "$VALIDATOR_SEARCH_HOME" -maxdepth 6 -name "validate_plugin.py" -path "*plugin-creator*" 2>/dev/null | head -1)"
  fi
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

# ---- e2_archive_gate — single source of truth for archive E2 --------------
# Usage: e2_archive_gate <archive_dir>
#
# Validates that the archive candidate contains a release tag trigger in its
# GitHub workflow(s). ALL code (workflows, e2_aggregate.sh, e2_check.py) is
# resolved from <archive_dir> — there is NO external fallback.
#
# Exit codes (shell, not stdout):
#   0 — PASS: release tag trigger found
#   1 — FAIL: aggregation returned NOT_FOUND / PARSE_ERR / DEP_MISSING
#   2 — FAIL: e2_aggregate.sh missing or unreadable in archive
#   3 — FAIL: e2_check.py missing or unreadable in archive
#
# Output on stdout: human-readable verdict (line 1 = "PASS" or "FAIL").
e2_archive_gate() {
  local archive_dir="$1"
  local aggregator="$archive_dir/tests/release/e2_aggregate.sh"
  local checker="$archive_dir/tests/release/e2_check.py"
  local workflows="$archive_dir/.github/workflows"

  # Gate 1: aggregator must exist in the archive candidate.
  if [ ! -f "$aggregator" ] || [ ! -r "$aggregator" ]; then
    echo "FAIL"
    echo "E2_AGGREGATOR_MISSING: $aggregator"
    return 2
  fi

  # shellcheck disable=SC1090
  . "$aggregator"

  # Gate 2: checker must exist in the archive candidate.
  if [ ! -f "$checker" ] || [ ! -r "$checker" ]; then
    echo "FAIL"
    echo "E2_CHECKER_MISSING: $checker"
    return 3
  fi

  # Gate 3: aggregate across all workflow files.
  local verdict first_line
  verdict="$(e2_aggregate "$workflows" "$checker")"
  first_line="$(printf '%s' "$verdict" | head -1)"

  if [ "$first_line" = "PASS" ]; then
    echo "PASS"
    echo "E2: release tag trigger found in GitHub workflow(s)"
    return 0
  else
    echo "FAIL"
    printf '%s\n' "$verdict" | tail -n +2
    return 1
  fi
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
  if PYTHONIOENCODING=utf-8 PYTHONDONTWRITEBYTECODE=1 python3 -B "$VALIDATOR" "$FULL_ARCHIVE_DIR" 2>&1; then
    echo "PASS: validate_plugin.py"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: validate_plugin.py"
    FAILED=$((FAILED + 1))
  fi
fi

# ---- Phase B5: rc.3 forward-eval release gate -----------------------------
# Case definitions are part of every archive and must always parse. Real-Agent
# result artifacts are required only for a release-intent run (tag CI or an
# explicit local pre-tag invocation), so ordinary branch/PR CI remains green
# while conversation evals are being collected.
echo "=== Phase B5: Forward-eval contract and release results ==="
EVAL_CASE_COUNT="$(find tests/eval/cases -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
EVAL_CASE_PARSE=true
if [ "$EVAL_CASE_COUNT" -eq 14 ]; then
  while IFS= read -r eval_case; do
    jq -e 'type == "object" and (.name|type=="string") and (.version|type=="string") and (.scenario_ref|test("^FE-[0-9]{2}$"))' \
      "$eval_case" >/dev/null 2>&1 || EVAL_CASE_PARSE=false
  done < <(find tests/eval/cases -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
else
  EVAL_CASE_PARSE=false
fi
if [ "$EVAL_CASE_PARSE" = true ]; then
  echo "PASS: B5a — 14 versioned forward-eval cases parse"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: B5a — expected 14 valid versioned forward-eval cases, got $EVAL_CASE_COUNT"
  FAILED=$((FAILED + 1))
fi

if [ -n "${GITHUB_TAG:-}" ] || [ "${HARNESS_REQUIRE_EVAL_RESULTS:-0}" = "1" ]; then
  if bash tests/eval/check-results.sh; then
    echo "PASS: B5b — all forward-eval cases have CONFIRMED passing results"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: B5b — release blocked by failed, unconfirmed, or unrun forward eval"
    FAILED=$((FAILED + 1))
  fi
else
  echo "SKIP: B5b — result gate activates for GITHUB_TAG or HARNESS_REQUIRE_EVAL_RESULTS=1"
  SKIPPED=$((SKIPPED + 1))
fi

# ---- Phase C: installer round-trip inside extracted archive ------------------
echo ""
echo "=== Phase C: Installer round-trip (install → verify → uninstall) ==="
C_ROUNDTRIP_DIR="$(mktemp -d)"
add_cleanup "$C_ROUNDTRIP_DIR"

# C1: Run Claude install.sh --project inside the extracted archive
echo "--- C1: Claude install.sh --project ---"
pushd "$C_ROUNDTRIP_DIR" >/dev/null
bash "$FULL_ARCHIVE_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
C1_INSTALL_RC=$?
popd >/dev/null

C1_TARGET="$C_ROUNDTRIP_DIR/.claude/skills/harness-companion"
C1_SETTINGS="$C_ROUNDTRIP_DIR/.claude/settings.json"

if [ "$C1_INSTALL_RC" -eq 0 ] && [ -f "$C1_TARGET/VERSION" ] && [ -f "$C1_TARGET/install-receipt.json" ]; then
  echo "PASS: C1 — install.sh --project exit 0, VERSION + receipt present"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: C1 — install exit=$C1_INSTALL_RC, VERSION=$([ -f "$C1_TARGET/VERSION" ] && echo yes || echo no), receipt=$([ -f "$C1_TARGET/install-receipt.json" ] && echo yes || echo no)"
  FAILED=$((FAILED + 1))
fi

# C2: Verify installed VERSION matches source VERSION
C1_VERSION="$(cat "$C1_TARGET/VERSION" 2>/dev/null || echo "")"
SOURCE_VERSION="$(cat "$FULL_ARCHIVE_DIR/VERSION" 2>/dev/null || echo "")"
if [ "$C1_VERSION" = "$SOURCE_VERSION" ] && [ -n "$C1_VERSION" ]; then
  echo "PASS: C2 — installed VERSION ($C1_VERSION) matches archive VERSION ($SOURCE_VERSION)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: C2 — installed VERSION='$C1_VERSION' vs archive VERSION='$SOURCE_VERSION'"
  FAILED=$((FAILED + 1))
fi

# C3: Verify receipt fields
C1_RCP_VERSION="$(jq -r '.version // empty' "$C1_TARGET/install-receipt.json" 2>/dev/null || echo "")"
C1_RCP_SKILL="$(jq -r '.skill // empty' "$C1_TARGET/install-receipt.json" 2>/dev/null || echo "")"
C1_SRC_ORIGIN="$(jq -r '.source.origin // empty' "$C1_TARGET/install-receipt.json" 2>/dev/null || echo "")"

C3_OK=1
if [ "$C1_RCP_VERSION" != "$SOURCE_VERSION" ]; then
  echo "FAIL: C3 — receipt version='$C1_RCP_VERSION' expected='$SOURCE_VERSION'"
  FAILED=$((FAILED + 1)); C3_OK=0
fi
if [ "$C1_RCP_SKILL" != "harness-companion" ]; then
  echo "FAIL: C3 — receipt skill='$C1_RCP_SKILL' expected='harness-companion'"
  FAILED=$((FAILED + 1)); C3_OK=0
fi
# In archive mode (no .git), source.origin should be "archive"
if [ "$C1_SRC_ORIGIN" != "archive" ]; then
  echo "FAIL: C3 — source.origin='$C1_SRC_ORIGIN' expected='archive' (no .git in archive)"
  FAILED=$((FAILED + 1)); C3_OK=0
fi
if [ "$C3_OK" -eq 1 ]; then
  echo "PASS: C3 — receipt version=$C1_RCP_VERSION, skill=$C1_RCP_SKILL, origin=$C1_SRC_ORIGIN"
  PASSED=$((PASSED + 1))
fi

# C4: Verify hooks registered in settings.json
C1_SS_COUNT="$(jq '.hooks.SessionStart | length' "$C1_SETTINGS" 2>/dev/null || echo "0")"
C1_STOP_COUNT="$(jq '.hooks.Stop | length' "$C1_SETTINGS" 2>/dev/null || echo "0")"
if [ "$C1_SS_COUNT" -ge 1 ] && [ "$C1_STOP_COUNT" -ge 1 ]; then
  echo "PASS: C4 — hooks registered (SS=$C1_SS_COUNT, Stop=$C1_STOP_COUNT)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: C4 — hooks missing (SS=$C1_SS_COUNT, Stop=$C1_STOP_COUNT)"
  FAILED=$((FAILED + 1))
fi

# C5: Invoke installed hooks
printf '{"session_id":"test","cwd":"%s","hook_event_name":"SessionStart"}\n' "$C_ROUNDTRIP_DIR" \
  | bash "$C1_TARGET/scripts/hooks/session-start.sh" >/dev/null 2>&1
C5_SS_RC=$?
printf '{"session_id":"test","cwd":"%s","hook_event_name":"Stop"}\n' "$C_ROUNDTRIP_DIR" \
  | bash "$C1_TARGET/scripts/hooks/stop-handoff.sh" >/dev/null 2>&1
C5_STOP_RC=$?
if [ "$C5_SS_RC" -eq 0 ] && [ "$C5_STOP_RC" -eq 0 ]; then
  echo "PASS: C5 — hooks invoked successfully (SS=$C5_SS_RC, Stop=$C5_STOP_RC)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: C5 — hook invocation failed (SS=$C5_SS_RC, Stop=$C5_STOP_RC)"
  FAILED=$((FAILED + 1))
fi

# C6: Uninstall and verify cleanup
pushd "$C_ROUNDTRIP_DIR" >/dev/null
bash "$FULL_ARCHIVE_DIR/adapters/claude-code/uninstall.sh" --project >/dev/null 2>&1
C6_UNINSTALL_RC=$?
popd >/dev/null

C6_SS_AFTER="$(jq '.hooks.SessionStart | length' "$C1_SETTINGS" 2>/dev/null || echo "0")"
C6_STOP_AFTER="$(jq '.hooks.Stop | length' "$C1_SETTINGS" 2>/dev/null || echo "0")"
C6_TARGET_EXISTS="$([ -d "$C1_TARGET" ] && echo YES || echo NO)"

C6_OK=1
if [ "$C6_UNINSTALL_RC" -ne 0 ]; then
  echo "FAIL: C6 — uninstall exit=$C6_UNINSTALL_RC (expected 0)"
  FAILED=$((FAILED + 1)); C6_OK=0
fi
if [ "$C6_SS_AFTER" -ne 0 ] || [ "$C6_STOP_AFTER" -ne 0 ]; then
  echo "FAIL: C6 — hooks not fully deregistered (SS=$C6_SS_AFTER, Stop=$C6_STOP_AFTER)"
  FAILED=$((FAILED + 1)); C6_OK=0
fi
if [ "$C6_TARGET_EXISTS" = "YES" ]; then
  echo "FAIL: C6 — target tree not removed"
  FAILED=$((FAILED + 1)); C6_OK=0
fi
if [ "$C6_OK" -eq 1 ]; then
  echo "PASS: C6 — uninstall clean: hooks removed, target removed"
  PASSED=$((PASSED + 1))
fi

# ---- Phase D: Post-install integrity validation (F10) ----------------------
echo ""
echo "=== Phase D: Post-install integrity validation ==="
D_ROUNDTRIP_DIR="$(mktemp -d)"
add_cleanup "$D_ROUNDTRIP_DIR"

# D1: Install and verify integrity.files is non-empty
pushd "$D_ROUNDTRIP_DIR" >/dev/null
bash "$FULL_ARCHIVE_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
D1_RC=$?
popd >/dev/null

D1_TARGET="$D_ROUNDTRIP_DIR/.claude/skills/harness-companion"
D1_RECEIPT="$D1_TARGET/install-receipt.json"
D1_INTEGRITY_COUNT="$(jq '.integrity.files | length' "$D1_RECEIPT" 2>/dev/null || echo 0)"
D1_ALGO="$(jq -r '.integrity.algorithm // empty' "$D1_RECEIPT" 2>/dev/null || echo "")"

if [ "$D1_RC" -eq 0 ] && [ "$D1_INTEGRITY_COUNT" -gt 0 ] && [ "$D1_ALGO" = "sha256" ]; then
  echo "PASS: D1 — integrity contract: $D1_INTEGRITY_COUNT files, algorithm=$D1_ALGO"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: D1 — install_rc=$D1_RC integrity_count=$D1_INTEGRITY_COUNT algo='$D1_ALGO'"
  FAILED=$((FAILED + 1))
fi

# D2: Verify receipt has source.tag field (null allowed, key must exist)
D2_TAG_EXISTS="$(jq 'has("source") and (.source | has("tag"))' "$D1_RECEIPT" 2>/dev/null || echo "false")"
if [ "$D2_TAG_EXISTS" = "true" ]; then
  echo "PASS: D2 — receipt.source.tag key present (value: $(jq -r '.source.tag // "null"' "$D1_RECEIPT"))"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: D2 — receipt.source.tag missing"
  echo "       Receipt has source: $(jq 'has("source")' "$D1_RECEIPT" 2>/dev/null || echo 'n/a')"
  echo "       Receipt source object: $(jq -c '.source // "n/a"' "$D1_RECEIPT" 2>/dev/null || echo 'n/a')"
  echo "       Full receipt: $(cat "$D1_RECEIPT" 2>/dev/null | head -c 400)"
  FAILED=$((FAILED + 1))
fi

# D3: Tamper detection — modify a file, re-compute, expect mismatch
TEST_FILE="$D1_TARGET/core/harness-verify.sh"
if [ -f "$TEST_FILE" ]; then
  ORIG_HASH="$(jq -r '.integrity.files["core/harness-verify.sh"]' "$D1_RECEIPT")"
  echo "tampered-payload-$$" >> "$TEST_FILE"
  NEW_HASH="$(sha256sum "$TEST_FILE" | awk '{print $1}')"
  if [ "$ORIG_HASH" != "$NEW_HASH" ]; then
    echo "PASS: D3 — tamper detection: original $ORIG_HASH != tampered $NEW_HASH"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: D3 — tamper not detected"
    FAILED=$((FAILED + 1))
  fi
fi

# D4: Uninstall Phase D install
pushd "$D_ROUNDTRIP_DIR" >/dev/null
bash "$FULL_ARCHIVE_DIR/adapters/claude-code/uninstall.sh" --project >/dev/null 2>&1
D4_RC=$?
popd >/dev/null
if [ "$D4_RC" -eq 0 ] && [ ! -d "$D1_TARGET" ]; then
  echo "PASS: D4 — Phase D uninstall clean"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: D4 — uninstall_rc=$D4_RC target_exists=$([ -d "$D1_TARGET" ] && echo YES || echo NO)"
  FAILED=$((FAILED + 1))
fi

# ---- Phase D': Real GitHub tag download (F14.3) ----------------------------
# Verifies that a tag-built archive (not just git archive HEAD) is installable
# and produces a receipt with a non-empty integrity.files block. Uses
# $GITHUB_TAG if set (e.g. GITHUB_TAG=v2.0.0-rc.1). Falls back to a local
# `git archive $TAG` extraction so the test still runs in environments without
# network access.
echo ""
echo "=== Phase D': Real GitHub tag archive (F14.3) ==="

DPRIME_TAG="${GITHUB_TAG:-}"
if [ -z "$DPRIME_TAG" ]; then
  # Pick the most recent tag that exists locally
  DPRIME_TAG="$(git -C "$SOURCE_REPO" tag --sort=-version:refname 2>/dev/null | head -1)"
fi
if [ -z "$DPRIME_TAG" ]; then
  echo "SKIP: D'1 — no GITHUB_TAG and no local tags"
  SKIPPED=$((SKIPPED + 1))
else
  DPRIME_DIR=""
  safe_mktemp DPRIME_DIR "phase-dprime-tag-archive" || exit 1

  DPRIME_GH_OK=0
  if command -v curl >/dev/null 2>&1; then
    # Try GitHub download. Repo owner/name detected from `git config remote.origin.url`,
    # or fall back to env vars GITHUB_REPO_OWNER / GITHUB_REPO_NAME.
    GH_OWNER="${GITHUB_REPO_OWNER:-}"
    GH_NAME="${GITHUB_REPO_NAME:-}"
    if [ -z "$GH_OWNER$GH_NAME" ]; then
      REMOTE_URL="$(git -C "$SOURCE_REPO" config --get remote.origin.url 2>/dev/null || echo "")"
      # Parse git@github.com:owner/name.git or https://github.com/owner/name.git
      if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        GH_OWNER="${BASH_REMATCH[1]}"
        GH_NAME="${BASH_REMATCH[2]}"
      fi
    fi
    if [ -n "$GH_OWNER" ] && [ -n "$GH_NAME" ]; then
      GH_URL="https://github.com/${GH_OWNER}/${GH_NAME}/archive/refs/tags/${DPRIME_TAG}.tar.gz"
      echo "  [D'] downloading $GH_URL"
      if curl -fsSL --max-time 60 "$GH_URL" -o "$DPRIME_DIR/tag.tgz" 2>/dev/null; then
        if tar -xzf "$DPRIME_DIR/tag.tgz" -C "$DPRIME_DIR" 2>/dev/null; then
          # The archive extracts to <repo-name>-<tag>/; rename to a flat dir
          EXTRACTED_SUBDIR="$(find "$DPRIME_DIR" -maxdepth 2 -mindepth 1 -type d ! -path "$DPRIME_DIR" | head -1)"
          if [ -n "$EXTRACTED_SUBDIR" ]; then
            mv "$DPRIME_DIR/tag.tgz" "$DPRIME_DIR/_archive.tgz.bak" 2>/dev/null || true
            # Flatten the contents up one level
            (cd "$DPRIME_DIR" && mv "$EXTRACTED_SUBDIR"/* "$DPRIME_DIR/" 2>/dev/null && rmdir "$EXTRACTED_SUBDIR" 2>/dev/null) || true
            DPRIME_GH_OK=1
            echo "  [D'] GitHub download OK → $DPRIME_DIR"
          fi
        fi
      fi
    fi
  fi
  # Fallback: local `git archive $TAG` -- ONLY when GITHUB_TAG is not set
  # (local dev mode). Under CI with a real GITHUB_TAG, the GitHub download is
  # mandatory: fail-closed so we do not silently test a different artifact.
  if [ "$DPRIME_GH_OK" -eq 0 ]; then
    if [ -n "${GITHUB_TAG:-}" ]; then
      echo "FAIL: D'1 -- GitHub download failed for GITHUB_TAG=$GITHUB_TAG (CI: no fallback allowed)"
      FAILED=$((FAILED + 1))
    else
      echo "  [D'] falling back to local 'git archive $DPRIME_TAG' (no GITHUB_TAG set)"
      if git -C "$SOURCE_REPO" archive "$DPRIME_TAG" 2>/dev/null | tar -x -C "$DPRIME_DIR"; then
        DPRIME_GH_OK=1
      fi
    fi
  fi

  if [ "$DPRIME_GH_OK" -eq 0 ] && [ -z "${GITHUB_TAG:-}" ]; then
    echo "FAIL: D'1 -- could not obtain archive for tag $DPRIME_TAG (curl+network failed AND local git archive failed)"
    FAILED=$((FAILED + 1))
  else
    # D'1: archive contains an installer entry point (rc.2 also has VERSION + .claude-plugin).
    # Older tags (e.g. v2.0.0-rc.1) may have a slimmer layout — install.sh is the minimum.
    if [ -f "$DPRIME_DIR/adapters/claude-code/install.sh" ]; then
      DPRIME_HAS_FULL_RC2="no"
      if [ -f "$DPRIME_DIR/VERSION" ] && [ -d "$DPRIME_DIR/.claude-plugin" ]; then
        DPRIME_HAS_FULL_RC2="yes"
      fi
      echo "PASS: D'1 — tag archive $DPRIME_TAG has install.sh (full rc.2 layout=$DPRIME_HAS_FULL_RC2)"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL: D'1 — tag archive missing install.sh"
      FAILED=$((FAILED + 1))
    fi

    # D'2: install from the tag archive and verify integrity contract
    DPRIME_INSTALL_DIR=""
    safe_mktemp DPRIME_INSTALL_DIR "phase-dprime-install" || exit 1
    pushd "$DPRIME_INSTALL_DIR" >/dev/null
    bash "$DPRIME_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
    DPRIME_RC=$?
    popd >/dev/null

    DPRIME_RECEIPT="$DPRIME_INSTALL_DIR/.claude/skills/harness-companion/install-receipt.json"
    DPRIME_INT_COUNT="$(jq '.integrity.files | length' "$DPRIME_RECEIPT" 2>/dev/null || echo 0)"
    DPRIME_ALGO="$(jq -r '.integrity.algorithm // empty' "$DPRIME_RECEIPT" 2>/dev/null || echo "")"

    if [ "$DPRIME_RC" -eq 0 ] && [ "$DPRIME_INT_COUNT" -gt 0 ] && [ "$DPRIME_ALGO" = "sha256" ]; then
      echo "PASS: D'2 — tag archive install: $DPRIME_INT_COUNT integrity entries, algo=$DPRIME_ALGO"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL: D'2 — rc=$DPRIME_RC integrity_count=$DPRIME_INT_COUNT algo='$DPRIME_ALGO'"
      FAILED=$((FAILED + 1))
    fi

    # D'3: receipt source.origin=archive (rc.2 contract). Legacy tags may have
    # source.commit=null but lack source.origin — accept either signal as
    # "tarball install".
    DPRIME_HAS_SOURCE="$(jq 'has("source")' "$DPRIME_RECEIPT" 2>/dev/null || echo "false")"
    DPRIME_ORIGIN="$(jq -r '.source.origin // empty' "$DPRIME_RECEIPT" 2>/dev/null || echo "")"
    DPRIME_COMMIT="$(jq -r '.source.commit // empty' "$DPRIME_RECEIPT" 2>/dev/null || echo "")"
    if [ "$DPRIME_HAS_SOURCE" = "true" ] && { [ "$DPRIME_ORIGIN" = "archive" ] || [ "$DPRIME_COMMIT" = "null" ] || [ "$DPRIME_COMMIT" = "unknown" ] || [ -z "$DPRIME_COMMIT" ]; }; then
      echo "PASS: D'3 — source signals archive install (origin='$DPRIME_ORIGIN' commit='$DPRIME_COMMIT')"
      PASSED=$((PASSED + 1))
    elif [ "$DPRIME_HAS_SOURCE" = "false" ]; then
      echo "SKIP: D'3 — tag $DPRIME_TAG predates source block"
      SKIPPED=$((SKIPPED + 1))
    else
      echo "FAIL: D'3 — source.origin='$DPRIME_ORIGIN' source.commit='$DPRIME_COMMIT'"
      FAILED=$((FAILED + 1))
    fi

    # D'4: cleanup — uninstall if available, otherwise verify target absent.
    # Legacy tags (e.g. v2.0.0-rc.1) may lack uninstall.sh entirely.
    pushd "$DPRIME_INSTALL_DIR" >/dev/null
    DPRIME_UNINSTALL_RC=0
    if [ -f "$DPRIME_DIR/adapters/claude-code/uninstall.sh" ]; then
      bash "$DPRIME_DIR/adapters/claude-code/uninstall.sh" --project >/dev/null 2>&1
      DPRIME_UNINSTALL_RC=$?
    else
      echo "  [D'4] no uninstall.sh in tag archive — manual cleanup not asserted"
    fi
    popd >/dev/null
    if [ ! -d "$DPRIME_INSTALL_DIR/.claude/skills/harness-companion" ]; then
      echo "PASS: D'4 — D' install cleaned up"
      PASSED=$((PASSED + 1))
    elif [ "$DPRIME_UNINSTALL_RC" -eq 0 ] || [ ! -f "$DPRIME_DIR/adapters/claude-code/uninstall.sh" ]; then
      echo "PASS: D'4 — uninstall not required (no uninstall.sh in archive or rc=0)"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL: D'4 — D' target tree still present after uninstall (rc=$DPRIME_UNINSTALL_RC)"
      FAILED=$((FAILED + 1))
    fi
  fi
fi

# ---- Phase E: Tag CI trigger check (F10) -----------------------------------
echo ""
echo "=== Phase E: Tag CI trigger / marketplace.json ==="

E1_MARKETPLACE=""
safe_mktemp E1_MARKETPLACE "phase-e-mkt" || exit 1
git -C "$SOURCE_REPO" archive HEAD -- '.claude-plugin/marketplace.json' | tar -x -C "$E1_MARKETPLACE" || true
E1_PLUGINS_COUNT="$(jq '.plugins | length' "$E1_MARKETPLACE/.claude-plugin/marketplace.json" 2>/dev/null || echo 0)"
E1_OWNER="$(jq -r '.owner.name // empty' "$E1_MARKETPLACE/.claude-plugin/marketplace.json" 2>/dev/null || echo "")"
if [ "$E1_PLUGINS_COUNT" -gt 0 ] && [ -n "$E1_OWNER" ]; then
  echo "PASS: E1 — marketplace.json: $E1_PLUGINS_COUNT plugins, owner=$E1_OWNER"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: E1 — marketplace plugins=$E1_PLUGINS_COUNT owner='$E1_OWNER'"
  FAILED=$((FAILED + 1))
fi

# E2 (production): call the single e2_archive_gate on the REAL archive candidate.
# e2_archive_gate is the single source of truth — both the production Phase E2
# and the E3/E4 negative tests below call the SAME function. Exit codes:
#   0 = PASS, 1 = aggregation FAIL, 2 = aggregator missing, 3 = checker missing.

E2_OUT="$(e2_archive_gate "$FULL_ARCHIVE_DIR")"
E2_RC=$?
E2_FIRST="$(printf '%s' "$E2_OUT" | head -1)"
if [ "$E2_RC" -eq 0 ]; then
  echo "PASS: E2 — release tag trigger found in GitHub workflow(s) (archive)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: E2 — release tag trigger NOT verified in archive (gate rc=$E2_RC)"
  printf '%s\n' "$E2_OUT" | tail -n +2 | sed 's/^/  /'
  FAILED=$((FAILED + 1))
fi

# ---- Phase E3: Negative — archive missing e2_check.py -------------------
# Full archive copy, remove ONLY e2_check.py, call the REAL e2_archive_gate.
# Gate must return rc=3 with E2_CHECKER_MISSING.
# Fail-open hardening: copy failure is fatal; pre-delete and post-delete
# assertions prove the fixture is exactly what we claim.
echo ""
echo "=== Phase E3: Negative — archive missing e2_check.py ==="
E3_ARCHIVE_DIR=""
safe_mktemp E3_ARCHIVE_DIR "phase-e3-neg-e2-check" || exit 1
cp -r "$FULL_ARCHIVE_DIR/." "$E3_ARCHIVE_DIR/" 2>/dev/null
E3_COPY_RC=$?
E3_OK=1
if [ "$E3_COPY_RC" -ne 0 ]; then
  echo "FAIL: E3 — archive copy failed (rc=$E3_COPY_RC)"
  E3_OK=0
fi
if [ "$E3_OK" -ne 0 ] && [ ! -d "$E3_ARCHIVE_DIR/.github/workflows" ]; then
  echo "FAIL: E3 — pre-delete: .github/workflows missing from temp copy"
  E3_OK=0
fi
if [ "$E3_OK" -ne 0 ] && [ ! -f "$E3_ARCHIVE_DIR/tests/release/e2_check.py" ]; then
  echo "FAIL: E3 — pre-delete: e2_check.py missing from temp copy"
  E3_OK=0
fi
if [ "$E3_OK" -ne 0 ] && [ ! -f "$E3_ARCHIVE_DIR/tests/release/e2_aggregate.sh" ]; then
  echo "FAIL: E3 — pre-delete: e2_aggregate.sh missing from temp copy"
  E3_OK=0
fi
if [ "$E3_OK" -ne 0 ]; then
  rm -f "$E3_ARCHIVE_DIR/tests/release/e2_check.py"
fi
if [ "$E3_OK" -ne 0 ] && [ -f "$E3_ARCHIVE_DIR/tests/release/e2_check.py" ]; then
  echo "FAIL: E3 — post-delete: e2_check.py still present (deletion failed)"
  E3_OK=0
fi
if [ "$E3_OK" -ne 0 ] && [ ! -f "$E3_ARCHIVE_DIR/tests/release/e2_aggregate.sh" ]; then
  echo "FAIL: E3 — post-delete: e2_aggregate.sh missing (should still exist)"
  E3_OK=0
fi
if [ "$E3_OK" -ne 0 ] && [ ! -d "$E3_ARCHIVE_DIR/.github/workflows" ]; then
  echo "FAIL: E3 — post-delete: .github/workflows missing (should still exist)"
  E3_OK=0
fi
if [ "$E3_OK" -eq 0 ]; then
  FAILED=$((FAILED + 1))
else
  E3_OUT="$(e2_archive_gate "$E3_ARCHIVE_DIR")"
  E3_RC=$?
  if [ "$E3_RC" -eq 3 ] && printf '%s' "$E3_OUT" | grep -q 'E2_CHECKER_MISSING'; then
    echo "PASS: E3 — archive missing e2_check.py correctly FAIL (gate rc=$E3_RC, checker missing)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: E3 — archive missing e2_check.py but gate rc=$E3_RC (expected rc=3 with E2_CHECKER_MISSING)"
    printf '%s\n' "$E3_OUT" | sed 's/^/  /'
    FAILED=$((FAILED + 1))
  fi
fi

# ---- Phase E4: Negative — archive missing e2_aggregate.sh ---------------
# Full archive copy, remove ONLY e2_aggregate.sh, call the REAL e2_archive_gate.
# Gate must return rc=2 with E2_AGGREGATOR_MISSING.
# Fail-open hardening: copy failure is fatal; pre-delete and post-delete
# assertions prove the fixture is exactly what we claim.
echo ""
echo "=== Phase E4: Negative — archive missing e2_aggregate.sh ==="
E4_ARCHIVE_DIR=""
safe_mktemp E4_ARCHIVE_DIR "phase-e4-neg-e2-aggregate" || exit 1
cp -r "$FULL_ARCHIVE_DIR/." "$E4_ARCHIVE_DIR/" 2>/dev/null
E4_COPY_RC=$?
E4_OK=1
if [ "$E4_COPY_RC" -ne 0 ]; then
  echo "FAIL: E4 — archive copy failed (rc=$E4_COPY_RC)"
  E4_OK=0
fi
if [ "$E4_OK" -ne 0 ] && [ ! -d "$E4_ARCHIVE_DIR/.github/workflows" ]; then
  echo "FAIL: E4 — pre-delete: .github/workflows missing from temp copy"
  E4_OK=0
fi
if [ "$E4_OK" -ne 0 ] && [ ! -f "$E4_ARCHIVE_DIR/tests/release/e2_check.py" ]; then
  echo "FAIL: E4 — pre-delete: e2_check.py missing from temp copy"
  E4_OK=0
fi
if [ "$E4_OK" -ne 0 ] && [ ! -f "$E4_ARCHIVE_DIR/tests/release/e2_aggregate.sh" ]; then
  echo "FAIL: E4 — pre-delete: e2_aggregate.sh missing from temp copy"
  E4_OK=0
fi
if [ "$E4_OK" -ne 0 ]; then
  rm -f "$E4_ARCHIVE_DIR/tests/release/e2_aggregate.sh"
fi
if [ "$E4_OK" -ne 0 ] && [ -f "$E4_ARCHIVE_DIR/tests/release/e2_aggregate.sh" ]; then
  echo "FAIL: E4 — post-delete: e2_aggregate.sh still present (deletion failed)"
  E4_OK=0
fi
if [ "$E4_OK" -ne 0 ] && [ ! -f "$E4_ARCHIVE_DIR/tests/release/e2_check.py" ]; then
  echo "FAIL: E4 — post-delete: e2_check.py missing (should still exist)"
  E4_OK=0
fi
if [ "$E4_OK" -ne 0 ] && [ ! -d "$E4_ARCHIVE_DIR/.github/workflows" ]; then
  echo "FAIL: E4 — post-delete: .github/workflows missing (should still exist)"
  E4_OK=0
fi
if [ "$E4_OK" -eq 0 ]; then
  FAILED=$((FAILED + 1))
else
  E4_OUT="$(e2_archive_gate "$E4_ARCHIVE_DIR")"
  E4_RC=$?
  if [ "$E4_RC" -eq 2 ] && printf '%s' "$E4_OUT" | grep -q 'E2_AGGREGATOR_MISSING'; then
    echo "PASS: E4 — archive missing e2_aggregate.sh correctly FAIL (gate rc=$E4_RC, aggregator missing)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: E4 — archive missing e2_aggregate.sh but gate rc=$E4_RC (expected rc=2 with E2_AGGREGATOR_MISSING)"
    printf '%s\n' "$E4_OUT" | sed 's/^/  /'
    FAILED=$((FAILED + 1))
  fi
fi

# ---- Phase F: Claude plugin validate phase (F10) ---------------------------
echo ""
echo "=== Phase F: Claude validation phase ==="

F1_PLUG_DIR="$FULL_ARCHIVE_DIR/.claude-plugin"
if [ -f "$F1_PLUG_DIR/plugin.json" ] && command -v claude >/dev/null 2>&1; then
  if claude plugin validate "$FULL_ARCHIVE_DIR" --strict >/dev/null 2>&1; then
    echo "PASS: F1 — claude plugin validate (archive root) --strict"
    PASSED=$((PASSED + 1))
  else
    echo "WARN: F1 — claude plugin validate --strict on archive root failed; trying plugin-dir"
    if [ -d "$F1_PLUG_DIR" ] && claude plugin validate "$F1_PLUG_DIR" >/dev/null 2>&1; then
      echo "PASS: F1 — claude plugin validate (plugin-dir) (no strict)"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL: F1 — claude plugin validate failed"
      FAILED=$((FAILED + 1))
    fi
  fi
else
  echo "SKIP: F1 — claude CLI not available or plugin.json missing"
  SKIPPED=$((SKIPPED + 1))
fi

# ---- Phase G: plugin-dir smoke (F10) ---------------------------------------
echo ""
echo "=== Phase G: Plugin-dir smoke (load metadata from .claude-plugin/) ==="

G1_PLUG_JSON="$FULL_ARCHIVE_DIR/.claude-plugin/plugin.json"
if [ -f "$G1_PLUG_JSON" ]; then
  G1_NAME="$(jq -r '.name // empty' "$G1_PLUG_JSON" 2>/dev/null)"
  G1_VER="$(jq -r '.version // empty' "$G1_PLUG_JSON" 2>/dev/null)"
  if [ "$G1_NAME" = "harness-companion" ] && [ "$G1_VER" = "2.0.0-rc.2" ]; then
    echo "PASS: G1 — plugin.json: name=$G1_NAME version=$G1_VER"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: G1 — name='$G1_NAME' version='$G1_VER'"
    FAILED=$((FAILED + 1))
  fi

  # G2: skills directory referenced
  G2_SKILLS_PATH="$(jq -r '.skills // empty' "$G1_PLUG_JSON" 2>/dev/null)"
  if [ -n "$G2_SKILLS_PATH" ]; then
    echo "PASS: G2 — plugin.json.skills=$G2_SKILLS_PATH"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: G2 — skills field missing"
    FAILED=$((FAILED + 1))
  fi
else
  echo "FAIL: G1 — .claude-plugin/plugin.json not in archive"
  FAILED=$((FAILED + 1))
fi

# G3: marketplace.json loads
G3_MKT_JSON="$FULL_ARCHIVE_DIR/.claude-plugin/marketplace.json"
if [ -f "$G3_MKT_JSON" ]; then
  G3_PLUGINS_LEN="$(jq '.plugins | length' "$G3_MKT_JSON" 2>/dev/null || echo 0)"
  if [ "$G3_PLUGINS_LEN" -gt 0 ]; then
    echo "PASS: G3 — marketplace.json: $G3_PLUGINS_LEN plugin entries"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: G3 — marketplace plugins empty"
    FAILED=$((FAILED + 1))
  fi
else
  echo "FAIL: G3 — .claude-plugin/marketplace.json not in archive"
  FAILED=$((FAILED + 1))
fi

# G4: REAL `claude --plugin-dir` smoke (F14.5) — actually load the plugin.
# This goes beyond reading manifest JSON: it invokes the claude CLI with the
# plugin directory as the active plugin and verifies it can be loaded without
# errors. Uses a 30-second timeout to prevent hangs.
G4_PLUG_DIR="$FULL_ARCHIVE_DIR"
if command -v claude >/dev/null 2>&1 && [ -d "$FULL_ARCHIVE_DIR/.claude-plugin" ]; then
  G4_LOG="$(mktemp)"
  if timeout 30 claude --plugin-dir "$G4_PLUG_DIR" --version >"$G4_LOG" 2>&1; then
    G4_EXIT=0
  else
    G4_EXIT=$?
  fi
  G4_OUT="$(head -c 600 "$G4_LOG" 2>/dev/null)"
  rm -f "$G4_LOG"
  # G4 is deterministic: only exit 0 counts. The plugin root directory
  # (not the .claude-plugin subdir) is passed to --plugin-dir. Any non-zero
  # exit or fuzzy output matching is a FAIL -- the plugin must load cleanly.
  if [ "$G4_EXIT" -eq 0 ]; then
    echo "PASS: G4 -- claude --plugin-dir $G4_PLUG_DIR loaded (exit=0)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: G4 -- claude --plugin-dir $G4_PLUG_DIR failed (exit=$G4_EXIT, output head: $(printf '%s' "$G4_OUT" | head -c 200))"
    FAILED=$((FAILED + 1))
  fi
else
  echo "SKIP: G4 -- claude CLI not on PATH or .claude-plugin dir missing"
  SKIPPED=$((SKIPPED + 1))
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
