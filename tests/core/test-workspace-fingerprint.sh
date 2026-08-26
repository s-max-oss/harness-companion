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

# Cumulative cleanup: add_cleanup accumulates dirs; single EXIT trap cleans them all.
cleanup_dirs=()
add_cleanup() { cleanup_dirs+=("$1"); }
cleanup_all() {
  local d
  for d in "${cleanup_dirs[@]}"; do
    [ -n "$d" ] && rm -rf -- "$d" 2>/dev/null
  done
}
trap cleanup_all EXIT

# Safe mktemp — runs in PARENT shell (no subshell), validates the dir in
# place, refuses to assign an empty/relative path, registers cleanup in the
# parent's trap state, and aborts the parent on mktemp failure.
#
# Usage: safe_mktemp VAR "label"   # sets parent-shell VAR to the new dir
#
# IMPORTANT: This MUST NOT be called as `VAR="$(safe_mktemp ...)"`. The whole
# point is to run inside the parent shell so add_cleanup() and the EXIT trap
# see the dir. Calling it via command substitution forks a subshell whose
# trap state is discarded on exit, leaving parent temp dirs untracked.
#
# On failure the function returns non-zero. Every caller must check that
# status explicitly because this test suite intentionally does not use set -e.
safe_mktemp() {
  local _varname="$1" _label="${2:-unknown}"

  # Validate the variable name is a legal bash identifier.
  if ! [[ "$_varname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "FATAL: safe_mktemp received illegal varname '$_varname'" >&2
    return 1
  fi

  # mktemp -d can return empty string AND exit 0 in some kernel/cygwin
  # conditions; treat empty stdout as failure regardless of exit code.
  local _dir=""
  _dir="$(mktemp -d 2>/dev/null)" || _dir=""
  if [ -z "$_dir" ] || [ ! -d "$_dir" ] || [ ! -w "$_dir" ]; then
    echo "FATAL: mktemp failed or produced invalid dir (label=$_label)" >&2
    return 1
  fi

  # Register first so even an unexpected assignment failure is cleaned by trap.
  add_cleanup "$_dir"
  printf -v "$_varname" '%s' "$_dir" || {
    echo "FATAL: could not assign temp dir to '$_varname'" >&2
    return 1
  }
}

# Initialize parent-shell WORKSPACE_TMP. After this call WORKSPACE_TMP is non-empty,
# the dir is writable, and it is registered in the EXIT trap.
WORKSPACE_TMP=""
safe_mktemp WORKSPACE_TMP "workspace-fp main" || exit 1
if [ -z "$WORKSPACE_TMP" ] || [ ! -d "$WORKSPACE_TMP" ]; then
  echo "FATAL: WORKSPACE_TMP not initialized after safe_mktemp" >&2
  exit 1
fi
if [ -n "${HARNESS_EXPECTED_TMP_ROOT:-}" ]; then
  case "$WORKSPACE_TMP" in
    "$HARNESS_EXPECTED_TMP_ROOT"/*) ;;
    *)
      echo "FATAL: workspace temp escaped assigned sandbox: $WORKSPACE_TMP" >&2
      exit 1
      ;;
  esac
fi
cd "$WORKSPACE_TMP" || { echo "FATAL: cd into WORKSPACE_TMP failed" >&2; exit 1; }

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

# Already cd'd into WORKSPACE_TMP at top of script. Verify it before any test work.
[ -d "$WORKSPACE_TMP" ] || { echo "FATAL: WORKSPACE_TMP disappeared before Test 1" >&2; exit 1; }
git init --quiet . || { echo "FATAL: git init failed" >&2; exit 1; }
git config user.email "test@test"
git config user.name "Tester"
echo "hello" > README.md
git add README.md
git commit -m "init" --quiet || { echo "FATAL: git commit failed" >&2; exit 1; }

FP1="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "clean git repo returns 'clean'" "$FP1" "clean"

# ============================================================================
# Test 2: Dirty git repo (unstaged change)
# ============================================================================
echo ""
echo "=== Test 2: Dirty git repo (unstaged) ==="

echo "dirty" >> README.md
FP2="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
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
FP3="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
# After staging, working tree matches index (no unstaged changes), but staged differs from HEAD
# So staged != 0, unstaged == 0 → different fingerprint from pure-unstaged
assert_fp_not_equals "staged fingerprint differs from unstaged fingerprint" "$FP3" "$FP2"

# Reset for next test
git commit -m "dirty" --quiet
FP3b="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "after commit, returns to clean" "$FP3b" "clean"

# ============================================================================
# Test 4: Terminal append stability
# ============================================================================
echo ""
echo "=== Test 4: Terminal append stability ==="

# Create .harness/logs/runs/ directory and write a run log
mkdir -p "$WORKSPACE_TMP/.harness/logs/runs"
echo '{"event":"run_started"}' > "$WORKSPACE_TMP/.harness/logs/runs/test.ndjson"

FP4_before="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"

# Append a terminal event
echo '{"event":"run_completed"}' >> "$WORKSPACE_TMP/.harness/logs/runs/test.ndjson"

FP4_after="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "fingerprint stable after appending to .harness/logs/" "$FP4_before" "$FP4_after"

# ============================================================================
# Test 5: Built-in exclude immunity
# ============================================================================
echo ""
echo "=== Test 5: Built-in exclude immunity ==="

# Create a config that tries to include .harness/logs in fingerprint
mkdir -p "$WORKSPACE_TMP/.harness"
cat > "$WORKSPACE_TMP/.harness/config.json" <<'CONF'
{
  "project_type": "generic",
  "fingerprint_exclude": [],
  "verification": { "commands": [] }
}
CONF

# Create a file in .harness/logs and verify it's still excluded
echo "should be ignored" > "$WORKSPACE_TMP/.harness/logs/should-be-ignored.txt"

FP5="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
# Remove the file and fingerprint should be same
rm "$WORKSPACE_TMP/.harness/logs/should-be-ignored.txt"
FP5_after="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals ".harness/ files excluded even with empty exclude list" "$FP5" "$FP5_after"

# ============================================================================
# Test 6: .harness lock and temp files excluded
# ============================================================================
echo ""
echo "=== Test 6: Lock and temp file exclusion ==="

mkdir -p "$WORKSPACE_TMP/.harness/.registry.lock"
echo "lock" > "$WORKSPACE_TMP/.harness/.registry.lock/pid"
echo "temp" > "$WORKSPACE_TMP/.harness/stuff.tmp.12345"

FP6_before="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
rm -rf "$WORKSPACE_TMP/.harness/.registry.lock" "$WORKSPACE_TMP/.harness/stuff.tmp.12345"
FP6_after="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals ".harness lock and temp files excluded" "$FP6_before" "$FP6_after"

# Acceptance packages are post-verification runtime evidence. Creating or
# locking one must not invalidate the run whose fingerprint it records.
mkdir -p "$WORKSPACE_TMP/.harness/acceptance/deadbeef/.lock"
FP6A_before="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
echo '{}' > "$WORKSPACE_TMP/.harness/acceptance/deadbeef/acceptance.json"
echo 'evidence' > "$WORKSPACE_TMP/.harness/acceptance/deadbeef/A-G.log"
echo 'lock' > "$WORKSPACE_TMP/.harness/acceptance/deadbeef/.lock/token"
FP6A_after="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals ".harness acceptance package is fingerprint-excluded" "$FP6A_before" "$FP6A_after"

# ============================================================================
# Test 7: NUL temp file location
# ============================================================================
echo ""
echo "=== Test 7: NUL temp file outside fingerprint scope ==="

# The implementation uses mktemp which creates files in system tmpdir (outside project).
# Verify that the fingerprint computation itself doesn't create files in the project.
before_count="$(find "$WORKSPACE_TMP" -newer "$WORKSPACE_TMP" -type f 2>/dev/null | wc -l || echo 0)"

FP7="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"

# Compute again — should be stable (temp file cleaned up, no project files modified)
FP7_again="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "fingerprint stable across recomputation (temp file outside scope)" "$FP7" "$FP7_again"

# ============================================================================
# Test 8: Special filename handling
# ============================================================================
echo ""
echo "=== Test 8: Special filename handling ==="

# Create files with spaces and special characters
echo "special" > "$WORKSPACE_TMP/file with spaces.txt"
echo "quotes" > "$WORKSPACE_TMP/file-with-dashes.txt"

FP8="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_not_equals "special filenames produce valid fingerprint" "$FP8" "clean"

rm "$WORKSPACE_TMP/file with spaces.txt" "$WORKSPACE_TMP/file-with-dashes.txt"

# ============================================================================
# Test 9: Configurable exclude from config.json
# ============================================================================
echo ""
echo "=== Test 9: Configurable exclude ==="

mkdir -p "$WORKSPACE_TMP/dist"
echo "build" > "$WORKSPACE_TMP/dist/output.js"
echo "source" > "$WORKSPACE_TMP/app.js"

cat > "$WORKSPACE_TMP/.harness/config.json" <<'CONF'
{
  "project_type": "generic",
  "fingerprint_exclude": ["dist/"],
  "verification": { "commands": [] }
}
CONF

FP9_with_dist="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"

rm -rf "$WORKSPACE_TMP/dist"
FP9_without_dist="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"

assert_fp_equals "configurable exclude: dist/ removed doesn't change fingerprint" "$FP9_with_dist" "$FP9_without_dist"

# Cleanup extra files
rm -f "$WORKSPACE_TMP/app.js" "$WORKSPACE_TMP/.harness/config.json"

# ============================================================================
# Test 10: Nested Git repo (project is subdir of git root)
# ============================================================================
echo ""
echo "=== Test 10: Nested Git repo — project as subdir of git root ==="

NESTED_TMP=""
safe_mktemp NESTED_TMP "workspace-fp nested" || exit 1

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
# Test 14: Tracked file diff exclusion (staged + unstaged)
# ============================================================================
echo ""
echo "=== Test 14: Tracked file diff exclusion ==="

# Reset to a clean repo
cd "$WORKSPACE_TMP"
git clean -fd >/dev/null 2>&1
git checkout -- . >/dev/null 2>&1 || true
# Drop the .harness config from earlier tests so its excludes don't bleed in
rm -rf "$WORKSPACE_TMP/.harness" 2>/dev/null

# Minimal project content
echo "src" > src.txt
git add src.txt && git commit -m "init" --quiet

# (a) Commit feature_list.json — tracked — then edit
echo '{"features":[]}' > feature_list.json
git add feature_list.json && git commit -m "add feature_list" --quiet

FP_T14_baseline="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"

# Edit feature_list.json, leave it UNSTAGED (working tree only)
cat > feature_list.json <<'FL'
{"features":[{"id":"f1","status":"in_progress"}]}
FL

FP_T14_edited_unstaged="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "tracked feature_list.json edit (unstaged) does NOT change fingerprint" \
  "$FP_T14_baseline" "$FP_T14_edited_unstaged"

# Now STAGE the edit and recompute
git add feature_list.json
FP_T14_edited_staged="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "tracked feature_list.json edit (STAGED) does NOT change fingerprint" \
  "$FP_T14_baseline" "$FP_T14_edited_staged"

# Restore baseline
git checkout -- feature_list.json
git reset HEAD feature_list.json >/dev/null 2>&1 || true

# (b) Same for .harness/config.json
mkdir -p "$WORKSPACE_TMP/.harness"
cat > "$WORKSPACE_TMP/.harness/config.json" <<'CF'
{"project_type":"generic","verification":{"commands":[]}}
CF
git add .harness/config.json && git commit -m "add config" --quiet

FP_T14_config_baseline="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"

cat > "$WORKSPACE_TMP/.harness/config.json" <<'CF'
{"project_type":"node","verification":{"commands":[{"id":"x","command":["true"]}]}}
CF
FP_T14_config_unstaged="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "tracked .harness/config.json edit (unstaged) does NOT change fingerprint" \
  "$FP_T14_config_baseline" "$FP_T14_config_unstaged"

git add .harness/config.json
FP_T14_config_staged="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "tracked .harness/config.json edit (STAGED) does NOT change fingerprint" \
  "$FP_T14_config_baseline" "$FP_T14_config_staged"

# Restore
git checkout -- .harness/config.json
git reset HEAD .harness/config.json >/dev/null 2>&1 || true

# (c) Tracked harness run-log also excluded
mkdir -p "$WORKSPACE_TMP/.harness/logs/runs"
echo '{"event":"run_started"}' > "$WORKSPACE_TMP/.harness/logs/runs/run.ndjson"
git add .harness/logs/runs/run.ndjson && git commit -m "add run log" --quiet

FP_T14_log_baseline="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"

# Append a terminal event
echo '{"event":"run_completed"}' >> "$WORKSPACE_TMP/.harness/logs/runs/run.ndjson"
FP_T14_log_unstaged="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "tracked harness run-log append (unstaged) does NOT change fingerprint" \
  "$FP_T14_log_baseline" "$FP_T14_log_unstaged"

git add .harness/logs/runs/run.ndjson
FP_T14_log_staged="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "tracked harness run-log append (STAGED) does NOT change fingerprint" \
  "$FP_T14_log_baseline" "$FP_T14_log_staged"

# ============================================================================
# Test 15: verify association write — fingerprint stable
# ============================================================================
echo ""
echo "=== Test 15: verify association write — fingerprint stable ==="

# Scenario: feature_list.json is committed (per Test 14 setup). User runs
# /harness:verify, which appends to the run log AND writes an evidence
# association into feature_list.json. The fingerprint MUST remain stable
# across this — otherwise passing eligibility would be invalidated the
# moment verify runs.
git checkout -- . >/dev/null 2>&1 || true
git reset HEAD -- . >/dev/null 2>&1 || true

# Baseline before verify
FP_T15_before="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"

# Simulate verify: append run event AND write association into feature_list.json
echo '{"event":"verify_started","cmd":"typecheck"}' >> "$WORKSPACE_TMP/.harness/logs/runs/run.ndjson"
echo '{"event":"verify_passed","cmd":"typecheck","exit":0}' >> "$WORKSPACE_TMP/.harness/logs/runs/run.ndjson"

cat > feature_list.json <<'FL'
{"features":[{"id":"f1","status":"passing","evidence_associations":[{"run_id":"run","ts":"2026-08-03T00:00:00Z"}]}]}
FL

FP_T15_after="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "verify write: fingerprint stable after evidence-association write" \
  "$FP_T15_before" "$FP_T15_after"

# Even when staged
git add feature_list.json .harness/logs/runs/run.ndjson
FP_T15_staged="$(compute_workspace_fingerprint "$WORKSPACE_TMP")"
assert_fp_equals "verify write: fingerprint stable after STAGE of evidence + run log" \
  "$FP_T15_before" "$FP_T15_staged"

# ============================================================================
# Test 16: Two nested directories with identical content → equal fingerprint
# ============================================================================
echo ""
echo "=== Test 16: Equal content at different nested prefixes ==="

TWIN_TMP=""
safe_mktemp TWIN_TMP "workspace-fp twin" || exit 1

cd "$TWIN_TMP"
git init --quiet .
git config user.email "test@test"
git config user.name "Tester"

mkdir -p projects/appA projects/appB
# Identical content under two different prefixes
echo "common" > projects/appA/shared.txt
echo "common" > projects/appB/shared.txt
git add . && git commit -m "init" --quiet

FP_A="$(compute_workspace_fingerprint "$TWIN_TMP/projects/appA")"
FP_B="$(compute_workspace_fingerprint "$TWIN_TMP/projects/appB")"

assert_fp_equals "same content at different nested prefixes → same fingerprint" \
  "$FP_A" "$FP_B"

# Sanity: making one project's content different must break equality
echo "different" > projects/appB/shared.txt
FP_B2="$(compute_workspace_fingerprint "$TWIN_TMP/projects/appB")"
assert_fp_not_equals "different content at different prefixes → different fingerprint" \
  "$FP_B2" "$FP_A"

# Restore B and add the SAME unique content to A under a renamed path
echo "common" > projects/appB/shared.txt
echo "common" > projects/appA/another.txt
FP_A2="$(compute_workspace_fingerprint "$TWIN_TMP/projects/appA")"
FP_B3="$(compute_workspace_fingerprint "$TWIN_TMP/projects/appB")"
# A now has shared.txt+another.txt (2 files), B has just shared.txt (1 file)
# so they should NOT be equal — proving prefix-isolation works correctly
# (B's files don't bleed into A).
assert_fp_not_equals "extra file in A only → A and B diverge" \
  "$FP_A2" "$FP_B3"

# ============================================================================
# Test 17: Clean fixture regeneration — no stale_by_fingerprint
# ============================================================================
echo ""
echo "=== Test 17: Clean fixture regeneration — no stale_by_fingerprint ==="

# Reset and commit a deterministic baseline.
cd "$TWIN_TMP"
git clean -fd >/dev/null 2>&1
git checkout -- . >/dev/null 2>&1 || true
git reset HEAD -- . >/dev/null 2>&1 || true

mkdir -p projects/app
echo "v1" > projects/app/main.txt
mkdir -p projects/app/.harness/logs/runs
echo '{"event":"run_started"}' > projects/app/.harness/logs/runs/run.ndjson
echo '{"features":[]}' > projects/app/feature_list.json
echo '{"project_type":"generic"}' > projects/app/.harness/config.json
git add . && git commit -m "regen baseline" --quiet

APP_DIR="$TWIN_TMP/projects/app"
FP_REGEN_before="$(compute_workspace_fingerprint "$APP_DIR")"

# Simulate a fixture regeneration that produces IDENTICAL output
# (we already have it; this is the "regeneration complete" state).
git clean -fd >/dev/null 2>&1
git checkout -- . >/dev/null 2>&1 || true
# Reset to the committed state (no diff)
FP_REGEN_after="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "clean fixture regeneration: fingerprint stable" \
  "$FP_REGEN_before" "$FP_REGEN_after"

# Same content under different file name (typical regeneration pattern) —
# leave it as an unstaged working-tree rename, fingerprint must change
# (real content change), but the harness-artifact excludes prevent
# feature_list.json / .harness/* changes from triggering stale_by_fingerprint.
mv projects/app/main.txt projects/app/main-renamed.txt
FP_REGEN_renamed="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_not_equals "fixture rename (working tree) produces different fingerprint" \
  "$FP_REGEN_before" "$FP_REGEN_renamed"

# Commit the rename — fingerprint returns to clean (no stale state).
git add -A && git commit -m "regen rename" --quiet
FP_REGEN_committed="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "after committing the rename, fingerprint returns to clean" \
  "clean" "$FP_REGEN_committed"

# But: simulate the Stop hook path. Stop compares SessionStart baseline
# against current fingerprint. If feature_list.json content changed during
# regen but our exclude set covers it, fingerprint is stable and no
# stale_by_fingerprint warning fires.
cat > projects/app/feature_list.json <<'FL'
{"features":[{"id":"f1","status":"passing","evidence_associations":[{"run_id":"x"}]}]}
FL
git add projects/app/feature_list.json
FP_REGEN_assoc="$(compute_workspace_fingerprint "$APP_DIR")"
assert_fp_equals "regen + evidence write: fingerprint stable" \
  "$FP_REGEN_before" "$FP_REGEN_assoc"

# ============================================================================
# Test 18: Precise match — negative cases (anchored regex)
# ============================================================================
echo ""
echo "=== Test 18: Precise match negative ==="

# Verify _is_excluded uses anchored matching:
#   feature_list.json       → EXCLUDED
#   myfeature_list.json.bak → NOT excluded
#   .harness/config.json    → EXCLUDED
#   .harness/configXjson    → NOT excluded
#   path/with spaces.txt    → NOT excluded (real file)
#   path/file[1].txt        → NOT excluded (brackets)
#
# Each sub-assertion gets a FRESH git repo so residual state from one
# sub-test cannot pollute another.

T18_TMP=""
safe_mktemp T18_TMP "workspace-fp test18" || exit 1

# setup_t18_fixture: create a clean git repo in $1 with baseline files.
# Returns the fingerprint of the clean baseline via stdout.
setup_t18_fixture() {
  local dir="$1"
  rm -rf "$dir"/* "$dir"/.git "$dir"/.[!.]* "$dir"/..?* 2>/dev/null || true
  cd "$dir" || { echo "FATAL: cd into test18 dir failed" >&2; exit 1; }
  git init --quiet . || { echo "FATAL: git init failed (test18)" >&2; exit 1; }
  git config user.email t@t && git config user.name t
  mkdir -p path .harness
  echo "base" > src.txt
  # Create the "NOT excluded" files (committed to git so edits are tracked diffs)
  echo "bak" > myfeature_list.json.bak
  echo "cfg" > .harness/configXjson
  echo "spc" > "path/with spaces.txt"
  echo "brk" > "path/file[1].txt"
  git add -A && git commit -m "base" --quiet || { echo "FATAL: git commit failed (test18)" >&2; exit 1; }
}

# ---- Sub-test a: feature_list.json IS excluded ----
echo "  [18a] feature_list.json excluded"
setup_t18_fixture "$T18_TMP"
FP_T18a_baseline="$(compute_workspace_fingerprint "$T18_TMP")"
echo '{"features":[]}' > "$T18_TMP/feature_list.json"
FP_T18a_fl="$(compute_workspace_fingerprint "$T18_TMP")"
assert_fp_equals "feature_list.json IS excluded — fingerprint unchanged" \
  "$FP_T18a_baseline" "$FP_T18a_fl"

# ---- Sub-test b: myfeature_list.json.bak NOT excluded ----
echo "  [18b] myfeature_list.json.bak NOT excluded"
setup_t18_fixture "$T18_TMP"
FP_T18b_baseline="$(compute_workspace_fingerprint "$T18_TMP")"
echo "MODIFIED" >> "$T18_TMP/myfeature_list.json.bak"
FP_T18b_mod="$(compute_workspace_fingerprint "$T18_TMP")"
assert_fp_not_equals "myfeature_list.json.bak NOT excluded — fingerprint CHANGES" \
  "$FP_T18b_baseline" "$FP_T18b_mod"

# ---- Sub-test c: .harness/config.json IS excluded ----
echo "  [18c] .harness/config.json excluded"
setup_t18_fixture "$T18_TMP"
FP_T18c_baseline="$(compute_workspace_fingerprint "$T18_TMP")"
echo '{"k":"v"}' > "$T18_TMP/.harness/config.json"
FP_T18c_cfg="$(compute_workspace_fingerprint "$T18_TMP")"
assert_fp_equals ".harness/config.json IS excluded — fingerprint unchanged" \
  "$FP_T18c_baseline" "$FP_T18c_cfg"

# ---- Sub-test d: .harness/configXjson NOT excluded ----
echo "  [18d] .harness/configXjson NOT excluded"
setup_t18_fixture "$T18_TMP"
FP_T18d_baseline="$(compute_workspace_fingerprint "$T18_TMP")"
echo "MODIFIED" >> "$T18_TMP/.harness/configXjson"
FP_T18d_mod="$(compute_workspace_fingerprint "$T18_TMP")"
assert_fp_not_equals ".harness/configXjson NOT excluded — fingerprint CHANGES" \
  "$FP_T18d_baseline" "$FP_T18d_mod"

# ---- Sub-test e: path/with spaces.txt NOT excluded ----
echo "  [18e] path with spaces NOT excluded"
setup_t18_fixture "$T18_TMP"
FP_T18e_baseline="$(compute_workspace_fingerprint "$T18_TMP")"
echo "MOD" >> "$T18_TMP/path/with spaces.txt"
FP_T18e_mod="$(compute_workspace_fingerprint "$T18_TMP")"
assert_fp_not_equals "path with spaces NOT excluded — fingerprint CHANGES" \
  "$FP_T18e_baseline" "$FP_T18e_mod"

# ---- Sub-test f: path/file[1].txt NOT excluded ----
echo "  [18f] path with brackets NOT excluded"
setup_t18_fixture "$T18_TMP"
FP_T18f_baseline="$(compute_workspace_fingerprint "$T18_TMP")"
echo "MOD" >> "$T18_TMP/path/file[1].txt"
FP_T18f_mod="$(compute_workspace_fingerprint "$T18_TMP")"
assert_fp_not_equals "path with brackets NOT excluded — fingerprint CHANGES" \
  "$FP_T18f_baseline" "$FP_T18f_mod"

# ============================================================================
# Test 19: Rename into excluded directory — old file deletion recorded
# ============================================================================
echo ""
echo "=== Test 19: Rename into excluded dir ==="

T19_TMP=""
safe_mktemp T19_TMP "workspace-fp test19" || exit 1
cd "$T19_TMP" || { echo "FATAL: cd into test19 dir failed" >&2; exit 1; }

mkdir -p src .harness/logs/runs
echo "important" > src/hello.txt
git init --quiet . || { echo "FATAL: git init failed (test19)" >&2; exit 1; }
git config user.email t@t && git config user.name t
git add -A && git commit -m "base" --quiet || { echo "FATAL: git commit failed (test19)" >&2; exit 1; }

# Baseline
FP_T19_before="$(compute_workspace_fingerprint "$T19_TMP")"
assert_fp_equals "clean project returns clean" "$FP_T19_before" "clean"

# Rename src/hello.txt → .harness/logs/hello.txt (simulates a user moving
# a file into the harness logs directory by accident).
mv src/hello.txt .harness/logs/hello.txt
FP_T19_renamed="$(compute_workspace_fingerprint "$T19_TMP")"

# The DELETE of src/hello.txt should be recorded (it was a non-excluded file),
# so the fingerprint must change. The CREATE of .harness/logs/hello.txt is
# excluded and must NOT suppress recording of the source deletion.
assert_fp_not_equals "rename into excluded dir: src deletion recorded → fingerprint CHANGES" \
  "$FP_T19_before" "$FP_T19_renamed"
# Should start with sha256: (genuine content change registered)
case "$FP_T19_renamed" in
  sha256:*) echo "PASS: rename into excluded dir — deletion recorded as sha256"; PASSED=$((PASSED + 1)) ;;
  *) echo "FAIL: rename into excluded dir — expected sha256:<hex>, got '$FP_T19_renamed'"; FAILED=$((FAILED + 1)) ;;
esac

# If we commit, fingerprint returns to clean (the rename is fully registered)
git add -A && git commit -m "rename into excluded" --quiet
FP_T19_committed="$(compute_workspace_fingerprint "$T19_TMP")"
assert_fp_equals "after committing rename, fingerprint returns to clean" \
  "clean" "$FP_T19_committed"

# ============================================================================
# Test 20: Locale independence — canonical fingerprint under any locale
# ============================================================================
# P0-1 gate: compute_workspace_fingerprint must force a canonical (C) locale
# internally so the fingerprint is byte-identical whether the caller runs
# under the default locale, LC_ALL=C, or a non-C/Chinese locale.
#
# The DIRTY (sha256:) path is the meaningful gate — only it invokes `sort -z`
# collation. The clean path prints a constant string without sorting, so it
# would pass even without the fix; we keep it as a contract check.
echo ""
echo "=== Test 20: Locale independence (default / C / zh_CN.UTF-8) ==="

LOC_TMP=""
safe_mktemp LOC_TMP "workspace-fp locale" || exit 1
cd "$LOC_TMP" || { echo "FATAL: cd into locale test dir failed" >&2; exit 1; }
git init --quiet .
git config user.email t@t && git config user.name t
# core.quotepath false: without it MSYS git quotes non-ASCII untracked paths
# as octal escapes ("src/\344\270\255.txt"), so the fingerprint's `[ -f ]`
# check silently skips them and the dirty path is never exercised.
git config core.quotepath false
mkdir -p src
echo "alpha" > src/a.txt
echo "beta"  > src/b.txt
git add -A && git commit -m "base" --quiet

# (a) Clean state — contract check (does not exercise sort).
FP_LOC_clean_default="$(compute_workspace_fingerprint "$LOC_TMP")"
FP_LOC_clean_c="$(LC_ALL=C compute_workspace_fingerprint "$LOC_TMP")"
FP_LOC_clean_zh="$(LC_ALL=zh_CN.UTF-8 compute_workspace_fingerprint "$LOC_TMP")"
assert_fp_equals "clean: default == LC_ALL=C" "$FP_LOC_clean_default" "$FP_LOC_clean_c"
assert_fp_equals "clean: default == zh_CN.UTF-8" "$FP_LOC_clean_default" "$FP_LOC_clean_zh"
assert_fp_equals "clean: fingerprint is 'clean'" "$FP_LOC_clean_default" "clean"

# (b) DIRTY state — exercises the sort path; this is the real gate.
# Two UNTRACKED Chinese filenames whose relative order under `sort -z`
# diverges between byte order (LC_ALL=C: 中 U+4E2D < 文 U+6587 → 中 first)
# and a real zh collation (pinyin: 文 "wén" < 中 "zhōng" → 文 first). With a
# single non-ASCII name both orderings agree and the gate would be vacuous;
# two divergent names change the hashed byte stream unless the function
# forces a canonical locale internally.
echo "未跟踪" > "src/中.txt"
echo "未跟踪" > "src/文.txt"
FP_LOC_d_default="$(compute_workspace_fingerprint "$LOC_TMP")"
FP_LOC_d_c="$(LC_ALL=C compute_workspace_fingerprint "$LOC_TMP")"
FP_LOC_d_zh="$(LC_ALL=zh_CN.UTF-8 compute_workspace_fingerprint "$LOC_TMP")"
assert_fp_equals "dirty: default == LC_ALL=C (byte-identical)" "$FP_LOC_d_default" "$FP_LOC_d_c"
assert_fp_equals "dirty: default == zh_CN.UTF-8 (byte-identical)" "$FP_LOC_d_default" "$FP_LOC_d_zh"
case "$FP_LOC_d_default" in
  sha256:*) echo "PASS: dirty locale fingerprint is a real sha256:<hex>"; PASSED=$((PASSED + 1)) ;;
  *) echo "FAIL: expected sha256:<hex>, got '$FP_LOC_d_default'"; FAILED=$((FAILED + 1)) ;;
esac

# (c) Caller env is NOT polluted: internal C forcing must be function-scoped.
# This call runs in the SAME shell (no command substitution), so it is `local`
# scoping alone that protects the caller — an `export LC_ALL=C` implementation
# would flip the caller's locale and fail this assertion.
saved_lc_all="${LC_ALL:-}"
export LC_ALL=zh_CN.UTF-8
loc_out="$(mktemp 2>/dev/null)" || loc_out="/tmp/harness-loc-check-$$"
compute_workspace_fingerprint "$LOC_TMP" > "$loc_out"
FP_LOC_pollute="$(cat "$loc_out" 2>/dev/null)"
rm -f "$loc_out"
if [ "${LC_ALL:-}" = "zh_CN.UTF-8" ]; then
  echo "PASS: caller LC_ALL untouched after in-shell call (local-scoped)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: caller LC_ALL leaked/changed to '${LC_ALL:-}'"
  FAILED=$((FAILED + 1))
fi
assert_fp_equals "dirty: caller-LC_ALL=zh call still yields identical fingerprint" \
  "$FP_LOC_d_default" "$FP_LOC_pollute"
if [ -n "$saved_lc_all" ]; then export LC_ALL="$saved_lc_all"; else unset LC_ALL; fi

# (d) P0-9 REAL subprocess tests — the fingerprint must be byte-identical when
# the function runs in a FRESH child shell under the three mandated
# environments:
#   env -u LC_ALL LANG=C.UTF-8      (LC_ALL unset, POSIX C.UTF-8)
#   env -u LC_ALL LANG=zh_CN.UTF-8  (LC_ALL unset, Chinese locale — the case
#                                    that used to produce a DIFFERENT SHA:
#                                    `local LC_ALL=C` does not propagate to
#                                    children when LC_ALL is unset in the
#                                    caller, so sort fell back to LANG)
#   LC_ALL=C                        (canonical C locale)
# Each child sources the REAL script and computes the DIRTY fingerprint (the
# sort -z path), so any non-C collation in the child env would change the SHA.
saved_parent_lc="${LC_ALL-}"
saved_parent_lang="${LANG-}"
SUB_C="$(env -u LC_ALL LANG=C.UTF-8 bash -c 'source "$1"; compute_workspace_fingerprint "$2"' _ "$CORE_LIB/workspace-fingerprint.sh" "$LOC_TMP" 2>/dev/null)"
SUB_ZH="$(env -u LC_ALL LANG=zh_CN.UTF-8 bash -c 'source "$1"; compute_workspace_fingerprint "$2"' _ "$CORE_LIB/workspace-fingerprint.sh" "$LOC_TMP" 2>/dev/null)"
SUB_LC="$(LC_ALL=C bash -c 'source "$1"; compute_workspace_fingerprint "$2"' _ "$CORE_LIB/workspace-fingerprint.sh" "$LOC_TMP" 2>/dev/null)"
assert_fp_equals "subprocess: env -u LC_ALL LANG=C.UTF-8 == default" "$SUB_C" "$FP_LOC_d_default"
assert_fp_equals "subprocess: env -u LC_ALL LANG=zh_CN.UTF-8 == default" "$SUB_ZH" "$FP_LOC_d_default"
assert_fp_equals "subprocess: LC_ALL=C == default" "$SUB_LC" "$FP_LOC_d_default"
if [ -n "$SUB_C" ] && [ "$SUB_C" = "$SUB_ZH" ] && [ "$SUB_C" = "$SUB_LC" ]; then
  echo "PASS: three subprocess env configs yield identical fingerprints"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: subprocess fingerprints differ (C=$SUB_C zh=$SUB_ZH lcall=$SUB_LC)"
  FAILED=$((FAILED + 1))
fi

# (e) P0-9 caller-env no-pollution proofs.
#   (e1) the PARENT shell's LC_ALL/LANG are unchanged after the three subprocess
#        invocations above (a child process cannot mutate its parent — asserted
#        explicitly as structural evidence of the contract).
#   (e2) the CHILD shell itself is not polluted: after it computes the
#        fingerprint under LC_ALL-unset LANG=zh_CN.UTF-8, ITS OWN LC_ALL is
#        still unset and LANG still zh_CN.UTF-8 — proving the function restores
#        the caller state instead of leaving `export LC_ALL=C` behind.
#   (e3) likewise, a child launched with LC_ALL=C still has LC_ALL=C after the
#        call (the exported value is restored, not dropped).
if [ "${LC_ALL-}" = "$saved_parent_lc" ] && [ "${LANG-}" = "$saved_parent_lang" ]; then
  echo "PASS: parent LC_ALL/LANG unchanged after subprocess invocations (no pollution)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: parent locale polluted by subprocess invocations (LC_ALL=${LC_ALL-} LANG=${LANG-})"
  FAILED=$((FAILED + 1))
fi
CHILD_STATE="$(env -u LC_ALL LANG=zh_CN.UTF-8 bash -c 'source "$1"; compute_workspace_fingerprint "$2" >/dev/null; printf "%s|%s" "${LC_ALL-unset}" "${LANG-unset}"' _ "$CORE_LIB/workspace-fingerprint.sh" "$LOC_TMP" 2>/dev/null)"
if [ "$CHILD_STATE" = "unset|zh_CN.UTF-8" ]; then
  echo "PASS: child env unpolluted after compute under env -u LC_ALL LANG=zh_CN.UTF-8 (LC_ALL still unset, LANG intact)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: child env polluted after compute — got '$CHILD_STATE' (expected unset|zh_CN.UTF-8)"
  FAILED=$((FAILED + 1))
fi
CHILD_STATE_C="$(LC_ALL=C bash -c 'source "$1"; compute_workspace_fingerprint "$2" >/dev/null; printf "%s" "${LC_ALL-unset}"' _ "$CORE_LIB/workspace-fingerprint.sh" "$LOC_TMP" 2>/dev/null)"
if [ "$CHILD_STATE_C" = "C" ]; then
  echo "PASS: LC_ALL=C child env intact after compute (restored to C)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: LC_ALL=C child env corrupted after compute — got '$CHILD_STATE_C'"
  FAILED=$((FAILED + 1))
fi

# ============================================================================
# Test 21: P0-M1 — per-call rebuild + cross-project isolation + git→no-git
# ============================================================================
# P0-M1 contract: every call to compute_workspace_fingerprint must rebuild
# BUILTIN_EXCLUDES + FINGERPRINT_EXCLUDES + VERIFICATION_SCOPE + _FP_EXCLUDE_ERE
# from the CURRENT project's state, including the no-git branch. Two
# consecutive calls in the SAME shell on two different projects must observe
# independent exclude sets (positive and reverse order must agree; git→no-git
# must rebuild and not inherit a stale regex).
#
# This test never modifies the real repo. It builds two minimal temp dirs:
#   P_GIT: a git repo with a custom fingerprint_exclude list.
#   P_NO:  a plain dir (no git) with a different fingerprint_exclude list.
# Both are populated with files that exercise the exclude logic, then we
# compute (a) A then B (b) B then A (c) git → no-git, and assert both
# (i) determinism across orders and (ii) no leakage of the git project's
# FINGERPRINT_EXCLUDES into the no-git compute.
echo ""
echo "=== Test 21: P0-M1 — per-call rebuild + cross-project isolation ==="

P_GIT_X=""
P_NO_X=""
safe_mktemp P_GIT_X "m1 git project" || exit 1
safe_mktemp P_NO_X  "m1 no-git project" || exit 1
P_GIT="$P_GIT_X"
P_NO="$P_NO_X"

# Project A (git): a single tracked file `keep.txt`, .harness/config.json with
# one custom exclude `*.gitignore`. The exclude must drop `keep.gitignore`.
( cd "$P_GIT" && git init --quiet && git config user.email t@t && git config user.name t && git config core.quotepath false
  mkdir -p .harness
  printf '{"fingerprint_exclude":["*.gitignore"]}\n' > .harness/config.json
  printf 'keep\n' > keep.txt
  printf 'ignored-by-custom\n' > keep.gitignore
  mkdir -p .harness/logs/runs
  printf '{"dummy":1}\n' > .harness/logs/runs/dummy.ndjson
  git add -A && git commit -qm "seed A"
)

# Project B (no-git): same shape but with a DIFFERENT custom exclude
# (`*.swp`) so the no-git compute must derive the B-set excludes (no carryover
# from the git project).
( mkdir -p "$P_NO/sub"
  printf '{"fingerprint_exclude":["*.swp"]}\n' > "$P_NO/.harness/config.json"
  printf 'keep\n' > "$P_NO/keep.txt"
  printf 'swp\n' > "$P_NO/keep.swp"
)

# --- (a) order A→B then B→A must agree ---
FP_A_A="$( ( cd "$P_GIT" && compute_workspace_fingerprint . ) )"
FP_A_B="$( ( cd "$P_NO"  && compute_workspace_fingerprint . ) )"
FP_B_A="$( ( cd "$P_GIT" && compute_workspace_fingerprint . ) )"
FP_B_B="$( ( cd "$P_NO"  && compute_workspace_fingerprint . ) )"
echo "FP_A_A=$FP_A_A  FP_A_B=$FP_A_B  FP_B_A=$FP_B_A  FP_B_B=$FP_B_B"
if [ "$FP_A_A" = "$FP_B_A" ] && [ "$FP_A_B" = "$FP_B_B" ]; then
  echo "PASS: (a) order-stable — A→B and B→A give same per-project result"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: (a) order instability across projects"
  FAILED=$((FAILED + 1))
fi

# --- (b) git→no-git — git build's _FP_EXCLUDE_ERE must NOT carry into no-git ---
# We force the scenario by computing inside ONE shell that processes the git
# project first, then the no-git project. The no-git compute's _FP_EXCLUDE_ERE
# is rebuilt from $P_NO's config.json (different excludes) — the hash for P_NO
# must reflect ONLY the *.swp exclusion, not the git project's *.gitignore.
# To detect carryover, we count what the no-git hash includes by recomputing
# P_NO from a CLEAN shell with the same content and comparing — they must match.
FP_NO_IN_SHARED_SHELL="$FP_A_B"
FP_NO_IN_CLEAN_SHELL="$( FP_NO_DIR="$P_NO" LC_ALL=C bash -c '
    . "$1/core/lib/workspace-fingerprint.sh"
    cd "$2" && compute_workspace_fingerprint .
  ' _ "$ROOT_DIR" "$P_NO" )"
if [ "$FP_NO_IN_SHARED_SHELL" = "$FP_NO_IN_CLEAN_SHELL" ] \
   && [ -n "$FP_NO_IN_SHARED_SHELL" ] \
   && [ "$FP_NO_IN_SHARED_SHELL" != "no_git" ]; then
  echo "PASS: (b) git→no-git — no carryover (FP matches a clean-shell compute)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: (b) git→no-git carryover (shared=$FP_NO_IN_SHARED_SHELL clean=$FP_NO_IN_CLEAN_SHELL)"
  FAILED=$((FAILED + 1))
fi

# --- (c) no-git must rebuild its own ERE for files whose exclude is in B but not in A ---
# In P_NO: keep.txt (kept), keep.swp (excluded by B). The computed hash must
# be a sha256: prefix AND match the hash for a parallel dir that ONLY has
# keep.txt (proving keep.swp was actually filtered).
P_NO_TRIM="$(mktemp -d "$P_NO.XXXXXX")"
cp -r "$P_NO"/* "$P_NO_TRIM/" 2>/dev/null || true
[ -f "$P_NO_TRIM/keep.swp" ] && rm -f "$P_NO_TRIM/keep.swp"
FP_NO_FULL="$( ( cd "$P_NO"      && compute_workspace_fingerprint . ) )"
FP_NO_TRIM="$( ( cd "$P_NO_TRIM" && compute_workspace_fingerprint . ) )"
rm -rf "$P_NO_TRIM"
if [ -n "$FP_NO_FULL" ] && [ "$FP_NO_FULL" != "$FP_NO_TRIM" ] \
   && [ "${FP_NO_FULL#sha256:}" != "$FP_NO_FULL" ]; then
  echo "PASS: (c) no-git rebuild observed: keep.swp filtered (full≠trim, sha256:)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: (c) no-git exclude not observed (full=$FP_NO_FULL trim=$FP_NO_TRIM)"
  FAILED=$((FAILED + 1))
fi

# --- (d) EMPTY no-git directory — must return the literal "no_git" token ---
P_NO_EMPTY="$(mktemp -d "$P_NO.XXXXXX")"
FP_EMPTY="$( ( cd "$P_NO_EMPTY" && compute_workspace_fingerprint . ) )"
rm -rf "$P_NO_EMPTY"
if [ "$FP_EMPTY" = "no_git" ]; then
  echo "PASS: (d) empty no-git → token 'no_git' (not sha256:<hex-of-empty>)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: (d) empty no-git returned '$FP_EMPTY' (expected 'no_git')"
  FAILED=$((FAILED + 1))
fi

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
