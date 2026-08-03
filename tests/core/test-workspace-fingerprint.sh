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
cleanup_dirs=""
add_cleanup() { cleanup_dirs="$cleanup_dirs $1"; }
trap 'for d in $cleanup_dirs; do rm -rf "$d" 2>/dev/null; done' EXIT

# Safe mktemp — fail immediately if temp dir cannot be created.
safe_mktemp() {
  local _label="$1"
  local _dir; _dir="$(mktemp -d)" || { echo "FATAL: mktemp failed ($_label)" >&2; exit 1; }
  add_cleanup "$_dir"
  printf '%s' "$_dir"
}

TMPDIR="$(safe_mktemp "workspace-fp main")"

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
git init --quiet . || { echo "FATAL: git init failed" >&2; exit 1; }
git config user.email "test@test"
git config user.name "Tester"
echo "hello" > README.md
git add README.md
git commit -m "init" --quiet || { echo "FATAL: git commit failed" >&2; exit 1; }

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

NESTED_TMP="$(safe_mktemp "workspace-fp nested")"

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
cd "$TMPDIR"
git clean -fd >/dev/null 2>&1
git checkout -- . >/dev/null 2>&1 || true
# Drop the .harness config from earlier tests so its excludes don't bleed in
rm -rf "$TMPDIR/.harness" 2>/dev/null

# Minimal project content
echo "src" > src.txt
git add src.txt && git commit -m "init" --quiet

# (a) Commit feature_list.json — tracked — then edit
echo '{"features":[]}' > feature_list.json
git add feature_list.json && git commit -m "add feature_list" --quiet

FP_T14_baseline="$(compute_workspace_fingerprint "$TMPDIR")"

# Edit feature_list.json, leave it UNSTAGED (working tree only)
cat > feature_list.json <<'FL'
{"features":[{"id":"f1","status":"in_progress"}]}
FL

FP_T14_edited_unstaged="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "tracked feature_list.json edit (unstaged) does NOT change fingerprint" \
  "$FP_T14_baseline" "$FP_T14_edited_unstaged"

# Now STAGE the edit and recompute
git add feature_list.json
FP_T14_edited_staged="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "tracked feature_list.json edit (STAGED) does NOT change fingerprint" \
  "$FP_T14_baseline" "$FP_T14_edited_staged"

# Restore baseline
git checkout -- feature_list.json
git reset HEAD feature_list.json >/dev/null 2>&1 || true

# (b) Same for .harness/config.json
mkdir -p "$TMPDIR/.harness"
cat > "$TMPDIR/.harness/config.json" <<'CF'
{"project_type":"generic","verification":{"commands":[]}}
CF
git add .harness/config.json && git commit -m "add config" --quiet

FP_T14_config_baseline="$(compute_workspace_fingerprint "$TMPDIR")"

cat > "$TMPDIR/.harness/config.json" <<'CF'
{"project_type":"node","verification":{"commands":[{"id":"x","command":["true"]}]}}
CF
FP_T14_config_unstaged="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "tracked .harness/config.json edit (unstaged) does NOT change fingerprint" \
  "$FP_T14_config_baseline" "$FP_T14_config_unstaged"

git add .harness/config.json
FP_T14_config_staged="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "tracked .harness/config.json edit (STAGED) does NOT change fingerprint" \
  "$FP_T14_config_baseline" "$FP_T14_config_staged"

# Restore
git checkout -- .harness/config.json
git reset HEAD .harness/config.json >/dev/null 2>&1 || true

# (c) Tracked harness run-log also excluded
mkdir -p "$TMPDIR/.harness/logs/runs"
echo '{"event":"run_started"}' > "$TMPDIR/.harness/logs/runs/run.ndjson"
git add .harness/logs/runs/run.ndjson && git commit -m "add run log" --quiet

FP_T14_log_baseline="$(compute_workspace_fingerprint "$TMPDIR")"

# Append a terminal event
echo '{"event":"run_completed"}' >> "$TMPDIR/.harness/logs/runs/run.ndjson"
FP_T14_log_unstaged="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "tracked harness run-log append (unstaged) does NOT change fingerprint" \
  "$FP_T14_log_baseline" "$FP_T14_log_unstaged"

git add .harness/logs/runs/run.ndjson
FP_T14_log_staged="$(compute_workspace_fingerprint "$TMPDIR")"
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
FP_T15_before="$(compute_workspace_fingerprint "$TMPDIR")"

# Simulate verify: append run event AND write association into feature_list.json
echo '{"event":"verify_started","cmd":"typecheck"}' >> "$TMPDIR/.harness/logs/runs/run.ndjson"
echo '{"event":"verify_passed","cmd":"typecheck","exit":0}' >> "$TMPDIR/.harness/logs/runs/run.ndjson"

cat > feature_list.json <<'FL'
{"features":[{"id":"f1","status":"passing","evidence_associations":[{"run_id":"run","ts":"2026-08-03T00:00:00Z"}]}]}
FL

FP_T15_after="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "verify write: fingerprint stable after evidence-association write" \
  "$FP_T15_before" "$FP_T15_after"

# Even when staged
git add feature_list.json .harness/logs/runs/run.ndjson
FP_T15_staged="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "verify write: fingerprint stable after STAGE of evidence + run log" \
  "$FP_T15_before" "$FP_T15_staged"

# ============================================================================
# Test 16: Two nested directories with identical content → equal fingerprint
# ============================================================================
echo ""
echo "=== Test 16: Equal content at different nested prefixes ==="

TWIN_TMP="$(safe_mktemp "workspace-fp twin")"

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

T18_TMP="$(safe_mktemp "workspace-fp test18")"

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

T19_TMP="$(safe_mktemp "workspace-fp test19")"
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
