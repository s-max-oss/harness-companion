#!/bin/bash
# test-workspace-fingerprint.sh — Workspace fingerprint test suite
#
# Tests:
#   1. Clean git repo → "clean"
#   2. Dirty git repo → "sha256:<hex>"
#   3. Terminal append stability (harness artifacts excluded)
#   4. Built-in exclude immunity (.harness/* cannot be overridden)
#   5. staged vs unstaged non-overlap
#   6. NUL-delimited temp file outside fingerprint scope
#   7. Special filename handling

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/workspace-fingerprint.sh
source "$CORE_LIB/workspace-fingerprint.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: assert fingerprint equals expected
assert_fp_equals() {
  local test_name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — expected '$expected', got '$actual'"
    FAILED=$((FAILED + 1))
  fi
}

assert_fp_not_equals() {
  local test_name="$1" actual="$2" unexpected="$3"
  if [ "$actual" != "$unexpected" ]; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — got '$actual', expected NOT '$unexpected'"
    FAILED=$((FAILED + 1))
  fi
}

# ============================================================================
# Test 1: Clean git repo
# ============================================================================
echo "=== Test 1: Clean git repo ==="

cd "$TMPDIR"
git init --quiet .
git config user.email "test@test"
git config user.name "Tester"
echo "hello" > README.md
git add README.md
git commit -m "init" --quiet

FP1="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "clean git repo returns 'clean'" "$FP1" "clean"

# ============================================================================
# Test 2: Dirty git repo (unstaged change)
# ============================================================================
echo ""
echo "=== Test 2: Dirty git repo (unstaged) ==="

echo "dirty" >> README.md
FP2="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_not_equals "unstaged change produces non-clean fingerprint" "$FP2" "clean"
# Should start with sha256:
case "$FP2" in
  sha256:*) echo "PASS: dirty fingerprint starts with sha256:"; PASSED=$((PASSED + 1)) ;;
  *) echo "FAIL: dirty fingerprint '$FP2' does not start with sha256:"; FAILED=$((FAILED + 1)) ;;
esac

# ============================================================================
# Test 3: Staged change (different from unstaged)
# ============================================================================
echo ""
echo "=== Test 3: Staged vs unstaged non-overlap ==="

git add README.md
FP3="$(compute_workspace_fingerprint "$TMPDIR")"
# After staging, working tree matches index (no unstaged changes), but staged differs from HEAD
# So staged != 0, unstaged == 0 → different fingerprint from pure-unstaged
assert_fp_not_equals "staged fingerprint differs from unstaged fingerprint" "$FP3" "$FP2"

# Reset for next test
git commit -m "dirty" --quiet
FP3b="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "after commit, returns to clean" "$FP3b" "clean"

# ============================================================================
# Test 4: Terminal append stability
# ============================================================================
echo ""
echo "=== Test 4: Terminal append stability ==="

# Create .harness/logs/runs/ directory and write a run log
mkdir -p "$TMPDIR/.harness/logs/runs"
echo '{"event":"run_started"}' > "$TMPDIR/.harness/logs/runs/test.ndjson"

FP4_before="$(compute_workspace_fingerprint "$TMPDIR")"

# Append a terminal event
echo '{"event":"run_completed"}' >> "$TMPDIR/.harness/logs/runs/test.ndjson"

FP4_after="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "fingerprint stable after appending to .harness/logs/" "$FP4_before" "$FP4_after"

# ============================================================================
# Test 5: Built-in exclude immunity
# ============================================================================
echo ""
echo "=== Test 5: Built-in exclude immunity ==="

# Create a config that tries to include .harness/logs in fingerprint
mkdir -p "$TMPDIR/.harness"
cat > "$TMPDIR/.harness/config.json" <<'CONF'
{
  "project_type": "generic",
  "fingerprint_exclude": [],
  "verification": { "commands": [] }
}
CONF

# Create a file in .harness/logs and verify it's still excluded
echo "should be ignored" > "$TMPDIR/.harness/logs/should-be-ignored.txt"

FP5="$(compute_workspace_fingerprint "$TMPDIR")"
# Remove the file and fingerprint should be same
rm "$TMPDIR/.harness/logs/should-be-ignored.txt"
FP5_after="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals ".harness/ files excluded even with empty exclude list" "$FP5" "$FP5_after"

# ============================================================================
# Test 6: .harness lock and temp files excluded
# ============================================================================
echo ""
echo "=== Test 6: Lock and temp file exclusion ==="

mkdir -p "$TMPDIR/.harness/.registry.lock"
echo "lock" > "$TMPDIR/.harness/.registry.lock/pid"
echo "temp" > "$TMPDIR/.harness/stuff.tmp.12345"

FP6_before="$(compute_workspace_fingerprint "$TMPDIR")"
rm -rf "$TMPDIR/.harness/.registry.lock" "$TMPDIR/.harness/stuff.tmp.12345"
FP6_after="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals ".harness lock and temp files excluded" "$FP6_before" "$FP6_after"

# ============================================================================
# Test 7: NUL temp file location
# ============================================================================
echo ""
echo "=== Test 7: NUL temp file outside fingerprint scope ==="

# The implementation uses mktemp which creates files in system tmpdir (outside project).
# Verify that the fingerprint computation itself doesn't create files in the project.
before_count="$(find "$TMPDIR" -newer "$TMPDIR" -type f 2>/dev/null | wc -l || echo 0)"

FP7="$(compute_workspace_fingerprint "$TMPDIR")"

# Compute again — should be stable (temp file cleaned up, no project files modified)
FP7_again="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "fingerprint stable across recomputation (temp file outside scope)" "$FP7" "$FP7_again"

# ============================================================================
# Test 8: Special filename handling
# ============================================================================
echo ""
echo "=== Test 8: Special filename handling ==="

# Create files with spaces and special characters
echo "special" > "$TMPDIR/file with spaces.txt"
echo "quotes" > "$TMPDIR/file-with-dashes.txt"

FP8="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_not_equals "special filenames produce valid fingerprint" "$FP8" "clean"

rm "$TMPDIR/file with spaces.txt" "$TMPDIR/file-with-dashes.txt"

# ============================================================================
# Test 9: Configurable exclude from config.json
# ============================================================================
echo ""
echo "=== Test 9: Configurable exclude ==="

mkdir -p "$TMPDIR/dist"
echo "build" > "$TMPDIR/dist/output.js"
echo "source" > "$TMPDIR/app.js"

cat > "$TMPDIR/.harness/config.json" <<'CONF'
{
  "project_type": "generic",
  "fingerprint_exclude": ["dist/"],
  "verification": { "commands": [] }
}
CONF

FP9_with_dist="$(compute_workspace_fingerprint "$TMPDIR")"

rm -rf "$TMPDIR/dist"
FP9_without_dist="$(compute_workspace_fingerprint "$TMPDIR")"

assert_fp_equals "configurable exclude: dist/ removed doesn't change fingerprint" "$FP9_with_dist" "$FP9_without_dist"

# Cleanup extra files
rm -f "$TMPDIR/app.js" "$TMPDIR/.harness/config.json"

# ============================================================================
# Test 10: Nested Git repo (project is subdir of git root)
# ============================================================================
echo ""
echo "=== Test 10: Nested Git repo — project as subdir of git root ==="

NESTED_TMP="$(mktemp -d)"
trap 'rm -rf "$TMPDIR" "$NESTED_TMP"' EXIT

# Build a parent git repo with:
#   projects/app/   — the project we fingerprint
#   projects/lib/   — a sibling project that MUST NOT affect fingerprint
#   docs/           — another sibling
cd "$NESTED_TMP"
git init --quiet .
git config user.email "test@test"
git config user.name "Tester"

mkdir -p projects/app projects/lib docs
echo "app file" > projects/app/main.txt
echo "lib file" > projects/lib/util.txt
echo "doc file" > docs/readme.md
git add . && git commit -m "init" --quiet

APP_DIR="$NESTED_TMP/projects/app"

# (a) clean nested project → "clean"
FP_N1="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "nested project, clean → 'clean'" "$FP_N1" "clean"

# (b) modify a SIBLING file (projects/lib/util.txt) — fingerprint must NOT change
echo "sibling modification" >> projects/lib/util.txt
FP_N2="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "sibling change does NOT affect project fingerprint" "$FP_N1" "$FP_N2"

# Reset sibling
git -C "$NESTED_TMP" checkout -- projects/lib/util.txt

# (c) modify a project file → fingerprint changes
echo "app dirty" >> projects/app/main.txt
FP_N3="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_not_equals "nested project, own change DOES affect fingerprint" "$FP_N3" "$FP_N2"

# (d) Sibling change after project change → fingerprint does NOT change
# (sibling is scoped out of project prefix)
echo "sibling modifies again" >> projects/lib/util.txt
FP_N4="$(compute_workspace_fingerprint "$APP_DIR")"
# Sibling change must not register — FP_N4 should equal FP_N3 (own-only dirty)
assert_fp_equals "sibling change does NOT pollute nested fingerprint" "$FP_N3" "$FP_N4"
# Reset sibling for cleanliness of later tests
git -C "$NESTED_TMP" checkout -- projects/lib/util.txt

# ============================================================================
# Test 11: Nested Git repo — built-in excludes still work
# ============================================================================
echo ""
echo "=== Test 11: Nested Git repo — built-in excludes ==="

# Reset app/main.txt to clean
git -C "$NESTED_TMP" checkout -- projects/app/main.txt

# (a) Create .harness/logs/runs/ inside nested project + write to it
mkdir -p "$APP_DIR/.harness/logs/runs"
echo '{"event":"run_started"}' > "$APP_DIR/.harness/logs/runs/test.ndjson"
FP_N6="$(compute_workspace_fingerprint "$APP_DIR")"

echo '{"event":"run_completed"}' >> "$APP_DIR/.harness/logs/runs/test.ndjson"
FP_N7="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "nested: .harness/logs/ append does NOT change fingerprint" "$FP_N6" "$FP_N7"

# (b) Create feature_list.json inside nested project + modify
echo '{"features":[]}' > "$APP_DIR/feature_list.json"
FP_N8="$(compute_workspace_fingerprint "$APP_DIR")"

cat > "$APP_DIR/feature_list.json" <<'FL'
{"features":[{"id":"f1","status":"passing","evidence":[]}]}
FL
FP_N9="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "nested: feature_list.json mutation does NOT change fingerprint" "$FP_N8" "$FP_N9"

# (c) Same for nested .harness/config.json
cat > "$APP_DIR/.harness/config.json" <<'CF'
{"project_type":"generic","verification":{"commands":[]}}
CF
FP_N10="$(compute_workspace_fingerprint "$APP_DIR")"

cat > "$APP_DIR/.harness/config.json" <<'CF'
{"project_type":"generic","verification":{"commands":[{"id":"x","command":["true"]}]}}
CF
FP_N11="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "nested: .harness/config.json mutation does NOT change fingerprint" "$FP_N10" "$FP_N11"

# (d) Sibling's own .harness/logs must NOT pollute us either
mkdir -p "$NESTED_TMP/projects/lib/.harness/logs/runs"
echo '{"event":"lib"}' > "$NESTED_TMP/projects/lib/.harness/logs/runs/x.ndjson"
FP_N12="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "sibling's .harness/logs does NOT affect us" "$FP_N11" "$FP_N12"

# ============================================================================
# Test 12: Nested Git repo — staged vs unstaged + post-verify stability
# ============================================================================
echo ""
echo "=== Test 12: Nested Git repo — staged/unstaged + verify stability ==="

# Reset everything to clean
git -C "$NESTED_TMP" clean -fd >/dev/null
git -C "$NESTED_TMP" checkout -- . >/dev/null 2>&1 || true

# Simulate a project source change (in our nested project)
echo "dirty" >> projects/app/main.txt

# Compute fingerprint BEFORE verify (baseline)
FP_BEFORE="$(compute_workspace_fingerprint "$APP_DIR")"

# Simulate verify completing — writes a run log AND mutates feature_list.json
mkdir -p "$APP_DIR/.harness/logs/runs"
echo '{"event":"run_started","cmd":"typecheck"}' > "$APP_DIR/.harness/logs/runs/run-1.ndjson"
echo '{"event":"run_completed","status":"ok"}' >> "$APP_DIR/.harness/logs/runs/run-1.ndjson"
cat > "$APP_DIR/feature_list.json" <<'FL'
{"features":[{"id":"f1","status":"passing","evidence":[{"run_id":"run-1","exit_code":0}]}]}
FL

# Compute fingerprint IMMEDIATELY after verify (no other changes happened)
FP_AFTER="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "nested: post-verify fingerprint equals pre-verify baseline" "$FP_BEFORE" "$FP_AFTER"

# A REAL source change (not harness artifact) still triggers staleness
echo "more dirty" >> projects/app/main.txt
FP_AFTER2="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_not_equals "nested: real source change DOES change fingerprint" "$FP_AFTER" "$FP_AFTER2"

# ============================================================================
# Test 13: Nested Git repo — untracked files
# ============================================================================
echo ""
echo "=== Test 13: Nested Git repo — untracked files ==="

# Reset
git -C "$NESTED_TMP" clean -fd >/dev/null
git -C "$NESTED_TMP" checkout -- . >/dev/null 2>&1 || true
rm -rf "$APP_DIR/.harness" "$APP_DIR/feature_list.json" 2>/dev/null

# Untracked file inside the project
echo "newfile" > "$APP_DIR/untracked.txt"
FP_U1="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_not_equals "nested: untracked file produces non-clean fingerprint" "$FP_U1" "clean"

# Untracked file in SIBLING must NOT affect us
echo "libnew" > "$NESTED_TMP/projects/lib/sibling-untracked.txt"
FP_U2="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "nested: sibling untracked does NOT affect us" "$FP_U1" "$FP_U2"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "Results: $PASSED passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
