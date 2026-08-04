#!/bin/bash
# test-r5-glob.sh — Phase 2 R5 glob semantics contract tests for has_files
#
# Verifies the schema→core contract for applies_when.has_files glob support:
#   G1.  Exact-path pattern matches existing file
#   G1b. Exact-path pattern against missing file → false
#   G2.  Exact-path pattern matches existing directory
#   G3.  * glob matches multiple files
#   G3b. * glob with no matches → false
#   G4.  */** recursive glob via multiple * segments
#   G5.  ? single-character glob
#   G6.  [abc] character-class glob
#   G7.  Glob does NOT match when pattern yields no files
#   G8.  Logical OR across multiple has_files entries
#   G9.  Pattern nonexistent.* does NOT match empty directory
#   G10. Glob matches a directory of test files
#
# Plus E2E tests via harness-verify confirming that command executes/skips
# based on glob resolution.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
CORE_LIB="$CORE_DIR/lib"
VERIFY_SCRIPT="$CORE_DIR/harness-verify.sh"

# shellcheck source=../../core/lib/validate-run-log.sh
source "$CORE_LIB/validate-run-log.sh"
# shellcheck source=../../core/lib/config-validate.sh
source "$CORE_LIB/config-validate.sh"
# shellcheck source=../../core/lib/json-helpers.sh
source "$CORE_LIB/json-helpers.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

assert_pass() {
  local name="$1"
  echo "PASS: $name"
  PASSED=$((PASSED + 1))
}

assert_fail() {
  local name="$1" reason="$2"
  echo "FAIL: $name — $reason"
  FAILED=$((FAILED + 1))
}

# glob_match <pattern> <root> → echoes "true" if any file matches
glob_match() {
  if _hc_glob_match "$1" "$2"; then
    printf 'true'
  else
    printf 'false'
  fi
}

# run_verify <feature_id> <project_dir>
run_verify() {
  set +e
  VERIFY_OUT="$("$VERIFY_SCRIPT" "$1" "$2" 2>&1)"
  VERIFY_RC=$?
  set -e
}

find_log() {
  ls "$2/.harness/logs/runs/"*.ndjson 2>/dev/null | head -1
}

count_cmd_events() {
  local log="$1" cmd_id="$2"
  jq -r "select(.event==\"command_completed\" and .command_id==\"$cmd_id\") | .event" "$log" 2>/dev/null | wc -l
}

# Sets up a minimal git project with a feature_list and a config containing
# the given JSON for one command under .harness/config.json.
# Args: <project_dir> <command_id> <command_argv_json> <has_files_json_array>
setup_project() {
  local dir="$1" cmd_id="$2" cmd_argv="$3" has_files="$4"
  mkdir -p "$dir/.harness"
  git -C "$dir" init --quiet 2>/dev/null
  git -C "$dir" config user.email "t@t"
  git -C "$dir" config user.name "t"
  git -C "$dir" config commit.gpgsign false
  cat > "$dir/feature_list.json" <<'FL'
{"revision":1,"features":[{"id":"feat-1","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}],"last_updated":"2026-08-01"}
FL
  cat > "$dir/.harness/config.json" <<EOF
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {
        "id": "$cmd_id",
        "command": $cmd_argv,
        "required_for_passing": true,
        "command_origin": "configured",
        "confirmation": "not_required",
        "applies_when": { "has_files": $has_files }
      }
    ]
  }
}
EOF
}

# ============================================================================
# Unit tests of _hc_glob_match — assertions made in PARENT shell so counter
# is accurate.
# ============================================================================

echo ""
echo "=== _hc_glob_match unit tests ==="

# G1: exact path, no metachars
G1="$TMPROOT/g1"
mkdir -p "$G1"
touch "$G1/package.json"
if [ "$(glob_match "package.json" "$G1")" = "true" ]; then
  assert_pass "G1: exact path matches existing file"
else
  assert_fail "G1: exact path matches existing file" "no match"
fi

# G1b: exact path against missing file
if [ "$(glob_match "Cargo.toml" "$G1")" = "false" ]; then
  assert_pass "G1b: exact path against missing file is false"
else
  assert_fail "G1b: exact path against missing file is false" "matched unexpectedly"
fi

# G2: exact path matches directory
G2="$TMPROOT/g2"
mkdir -p "$G2/src"
touch "$G2/src/foo.ts"
if [ "$(glob_match "src" "$G2")" = "true" ]; then
  assert_pass "G2: exact path matches existing directory"
else
  assert_fail "G2: exact path matches existing directory" "no match"
fi

# G3: * matches multiple files
G3="$TMPROOT/g3"
mkdir -p "$G3/src"
touch "$G3/src/a.py" "$G3/src/b.py" "$G3/src/c.txt"
if [ "$(glob_match "src/*.py" "$G3")" = "true" ]; then
  assert_pass "G3: src/*.py matches multiple .py files"
else
  assert_fail "G3: src/*.py matches multiple .py files" "no match"
fi

# G3b: * with no matching extension → false
if [ "$(glob_match "src/*.rs" "$G3")" = "false" ]; then
  assert_pass "G3b: src/*.rs does NOT match .py files"
else
  assert_fail "G3b: src/*.rs does NOT match .py files" "matched unexpectedly"
fi

# G4: multi-segment recursive glob
G4="$TMPROOT/g4"
mkdir -p "$G4/src/deep/nested"
touch "$G4/src/deep/nested/file.py" "$G4/src/top.py"
if [ "$(glob_match "src/*/*/*.py" "$G4")" = "true" ]; then
  assert_pass "G4: src/*/*/*.py recursive matches nested file"
else
  assert_fail "G4: src/*/*/*.py recursive" "no match"
fi

# G5: ? single-character glob
G5="$TMPROOT/g5"
mkdir -p "$G5"
touch "$G5/a.txt" "$G5/b.txt" "$G5/cc.txt"
if [ "$(glob_match "?.txt" "$G5")" = "true" ]; then
  assert_pass "G5: ?.txt matches single-char filenames (a.txt, b.txt)"
else
  assert_fail "G5: ?.txt matches single-char filenames" "no match"
fi

# G5b: ? does NOT match multi-char filenames
if [ "$(glob_match "?.txt" "$G5")" = "true" ]; then
  # cc.txt exists but ?.txt must match at least one — verify both a.txt and
  # cc.txt can't both match (a.txt does, cc.txt doesn't, but the result is
  # still true). Instead, test cc.txt alone.
  G5B="$TMPROOT/g5b"
  mkdir -p "$G5B"
  touch "$G5B/cc.txt"
  if [ "$(glob_match "?.txt" "$G5B")" = "false" ]; then
    assert_pass "G5b: ?.txt does NOT match multi-char filenames"
  else
    assert_fail "G5b: ?.txt should NOT match cc.txt" "matched"
  fi
fi

# G6: [abc] character class
G6="$TMPROOT/g6"
mkdir -p "$G6"
touch "$G6/a.py" "$G6/b.py" "$G6/d.py"
if [ "$(glob_match "[ab].py" "$G6")" = "true" ]; then
  assert_pass "G6: [ab].py matches a.py and b.py"
else
  assert_fail "G6: [ab].py matches a.py and b.py" "no match"
fi

# G6b: character class does NOT match excluded letters
G6B="$TMPROOT/g6b"
mkdir -p "$G6B"
touch "$G6B/d.py"
if [ "$(glob_match "[ab].py" "$G6B")" = "false" ]; then
  assert_pass "G6b: [ab].py does NOT match d.py"
else
  assert_fail "G6b: [ab].py should NOT match d.py" "matched"
fi

# G7: glob with no matches anywhere
G7="$TMPROOT/g7"
mkdir -p "$G7"
if [ "$(glob_match "src/*.py" "$G7")" = "false" ]; then
  assert_pass "G7: src/*.py with no src/ → false"
else
  assert_fail "G7: src/*.py with no src/" "matched unexpectedly"
fi

# G9: pattern `nonexistent.*` does NOT match empty directory
if [ "$(glob_match "nonexistent.*" "$G7")" = "false" ]; then
  assert_pass "G9: nonexistent.* does NOT match empty dir"
else
  assert_fail "G9: nonexistent.* should NOT match empty dir" "matched"
fi

# G10: glob matches a directory of test files
G10="$TMPROOT/g10"
mkdir -p "$G10/tests"
touch "$G10/tests/test_one.py" "$G10/tests/test_two.py"
if [ "$(glob_match "tests/test_*.py" "$G10")" = "true" ]; then
  assert_pass "G10: tests/test_*.py matches any test_*.py"
else
  assert_fail "G10: tests/test_*.py matches any test_*.py" "no match"
fi

# ============================================================================
# E2E tests via harness-verify
# ============================================================================

echo ""
echo "=== E2E: has_files glob via harness-verify ==="

# E1: has_files=["src/*.py"] with src/foo.py → command executes
E1="$TMPROOT/e1"
mkdir -p "$E1/src"
touch "$E1/src/foo.py"
setup_project "$E1" "glob-cmd" '["bash","-c","echo glob-matched && exit 0"]' '["src/*.py"]'
run_verify "feat-1" "$E1"
LOG="$(find_log "feat-1" "$E1")"
if [ -n "$LOG" ]; then
  n="$(count_cmd_events "$LOG" "glob-cmd")"
  if [ "$n" = "1" ]; then
    assert_pass "E1: has_files=[\"src/*.py\"] with src/foo.py → executes"
  else
    assert_fail "E1: glob matches → executes" "got $n events"
  fi
else
  assert_fail "E1: log produced" "no log"
fi

# E2: has_files=["src/*.py"] with empty src/ → command skipped
E2="$TMPROOT/e2"
mkdir -p "$E2/src"
setup_project "$E2" "glob-cmd" '["bash","-c","echo glob-matched && exit 0"]' '["src/*.py"]'
run_verify "feat-1" "$E2"
LOG="$(find_log "feat-1" "$E2")"
if [ -n "$LOG" ]; then
  n="$(count_cmd_events "$LOG" "glob-cmd")"
  if [ "$n" = "0" ] && printf '%s' "$VERIFY_OUT" | grep -q "not_applicable"; then
    assert_pass "E2: has_files=[\"src/*.py\"] with empty src/ → skipped (not_applicable)"
  else
    assert_fail "E2: glob no-match → skipped" "events=$n"
  fi
else
  assert_fail "E2: log produced" "no log"
fi

# E3: has_files=["package.json","*.lock"] with only yarn.lock → executes (OR)
E3="$TMPROOT/e3"
mkdir -p "$E3"
touch "$E3/yarn.lock"
setup_project "$E3" "glob-cmd" '["bash","-c","echo lock-matched && exit 0"]' '["package.json","*.lock"]'
run_verify "feat-1" "$E3"
LOG="$(find_log "feat-1" "$E3")"
if [ -n "$LOG" ]; then
  n="$(count_cmd_events "$LOG" "glob-cmd")"
  if [ "$n" = "1" ]; then
    assert_pass "E3: has_files=[\"package.json\",\"*.lock\"] with yarn.lock → executes (logical OR)"
  else
    assert_fail "E3: OR semantics" "got $n events"
  fi
else
  assert_fail "E3: log produced" "no log"
fi

# E4: has_files=["*.toml"] with pyproject.toml → executes (exact-match fallback)
E4="$TMPROOT/e4"
mkdir -p "$E4"
touch "$E4/pyproject.toml"
setup_project "$E4" "glob-cmd" '["bash","-c","echo toml && exit 0"]' '["*.toml"]'
run_verify "feat-1" "$E4"
LOG="$(find_log "feat-1" "$E4")"
if [ -n "$LOG" ]; then
  n="$(count_cmd_events "$LOG" "glob-cmd")"
  if [ "$n" = "1" ]; then
    assert_pass "E4: has_files=[\"*.toml\"] with pyproject.toml → executes"
  else
    assert_fail "E4: *.toml matches pyproject.toml" "got $n events"
  fi
fi

# E5: has_files=["src/*.py"] with no matches AND no [skip] in verify output
# (regression: ensures skipped command is correctly counted, not failed)
E5="$TMPROOT/e5"
mkdir -p "$E5"
setup_project "$E5" "glob-cmd" '["bash","-c","echo matched && exit 1"]' '["nonexistent/*.xyz"]'
run_verify "feat-1" "$E5"
LOG="$(find_log "feat-1" "$E5")"
if [ -n "$LOG" ]; then
  n_exec="$(count_cmd_events "$LOG" "glob-cmd")"
  # E5 has a required command that, if it ran with exit 1, would mark run
  # as failed. Confirm: command did NOT run (0 events), and overall is
  # not failed (because required-but-skipped is treated as skipped, not failed).
  overall="$(jq -r 'select(.event=="run_completed" or .event=="run_failed") | .overall_result' "$LOG" 2>/dev/null)"
  if [ "$n_exec" = "0" ] && [ "$overall" != "failed" ]; then
    assert_pass "E5: glob no-match → required command SKIPPED (not failed) — overall=$overall"
  else
    assert_fail "E5: skipped required command must not mark run as failed" "events=$n_exec overall=$overall"
  fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "R5 Glob Results: $PASSED passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0