#!/bin/bash
# test-staleness.sh — Three-axis staleness FAIL-CLOSED test suite
#
# Verifies core/lib/staleness.sh fail-closed contract (Item 5):
#   - missing run log  → all axes stale
#   - missing workspace-fingerprint.sh → Axis1 stale (FAIL-CLOSED)
#   - missing jq       → all axes stale (FAIL-CLOSED)
#   - missing sha tool → Axis2 stale (FAIL-CLOSED)
#   - stored vcs_revision but not a git repo → Axis3 stale (FAIL-CLOSED)
#   - no stored vcs_revision → Axis3 NOT stale (design-consistent)
#   - config deleted / changed → Axis2 stale
#   - git repo but HEAD != stored rev → Axis3 stale
#   - clean git repo, all match → fresh on all three axes (positive control)
#
# Fixture run logs are built with jq -n (never hand-typed) — same convention
# as test-validate-run-log.sh. Requires: bash, jq, git.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/staleness.sh
source "$CORE_LIB/staleness.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

JQ_BIN="$(command -v jq)"
JQ_DIR="$(dirname "$JQ_BIN")"

# ---- helpers ----

# build_run_log <project_dir> <run_id> <config_sha> <vcs_rev> <fingerprint>
# Writes .harness/logs/runs/<run_id>.ndjson with run_started + run_completed.
build_run_log() {
  local proj="$1" run_id="$2" cfg_sha="$3" vcs_rev="$4" fp="$5"
  mkdir -p "$proj/.harness/logs/runs"
  jq -n --arg run_id "$run_id" --arg cfg "$cfg_sha" --arg rev "$vcs_rev" --arg fp "$fp" '
    [
      {event:"run_started", run_id:$run_id, started_at:"2026-01-01T00:00:00Z",
       config_sha256:$cfg, vcs_revision:$rev, workspace_fingerprint_initial:$fp,
       required_command_ids:[], capability_level:0, feature_id:"f1"},
      {event:"run_completed", run_id:$run_id, completed_at:"2026-01-01T00:00:01Z",
       overall_result:"no_checks", workspace_fingerprint_verified:$fp,
       planned_commands:0, executed_commands:0, passed_commands:0,
       failed_commands:0, skipped_commands:0}
    ][]' > "$proj/.harness/logs/runs/$run_id.ndjson"
}

assert_stale() {
  local test_name="$1" expected_rc="${2:-0}"
  if [ "$expected_rc" = "0" ]; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — expected stale (return 0), got $expected_rc"
    FAILED=$((FAILED + 1))
  fi
}

assert_fresh() {
  local test_name="$1" expected_rc="${2:-1}"
  if [ "$expected_rc" = "1" ]; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — expected fresh (return 1), got $expected_rc"
    FAILED=$((FAILED + 1))
  fi
}

# ---- T1: missing run log → all three axes stale ----
T1="$(mktemp -d "$TMPDIR/t1-XXXX")"
mkdir -p "$T1/.harness/logs/runs"
ev_is_stale_by_fingerprint "no-such-run" "$T1"; assert_stale "T1a: Axis1 missing run log → stale" "$?"
ev_is_stale_by_config "no-such-run" "$T1"; assert_stale "T1b: Axis2 missing run log → stale" "$?"
ev_is_stale_by_vcs "no-such-run" "$T1"; assert_stale "T1c: Axis3 missing run log → stale" "$?"

# ---- T2: workspace-fingerprint.sh missing → Axis1 stale (FAIL-CLOSED) ----
# Copy staleness.sh to a dir WITHOUT workspace-fingerprint.sh, exercise Axis1.
T2_LIB="$(mktemp -d "$TMPDIR/t2-lib-XXXX")"
cp "$CORE_LIB/staleness.sh" "$T2_LIB/"
T2="$(mktemp -d "$TMPDIR/t2-proj-XXXX")"
build_run_log "$T2" "run-a" "sha256:abc" "deadbeef1234" "clean"
# shellcheck source=/dev/null
. "$T2_LIB/staleness.sh"
T2_ERR="$(mktemp "$TMPDIR/t2-err-XXXX")"
ev_is_stale_by_fingerprint "run-a" "$T2" 2>"$T2_ERR"
T2_RC=$?
assert_stale "T2: Axis1 workspace-fingerprint.sh missing → stale (FAIL-CLOSED)" "$T2_RC"
if grep -q "FAIL-CLOSED" "$T2_ERR"; then
  echo "PASS: T2: FAIL-CLOSED diagnostic emitted"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: T2: expected FAIL-CLOSED diagnostic on stderr"
  FAILED=$((FAILED + 1))
fi
# restore canonical lib for remaining tests
# shellcheck source=../../core/lib/staleness.sh
source "$CORE_LIB/staleness.sh"

# Note on simulating missing deps: define a `command` function that reports
# the named tools as missing (command -v <tool> returns 1) while forwarding
# everything else to the real builtin. It must be defined INLINE in the
# subshell — a helper-local variable is not visible to the nested function
# under `set -u` (bash dynamic scoping), which would kill the subshell.

# ---- T3: jq missing → all three axes stale (FAIL-CLOSED) ----
T3="$(mktemp -d "$TMPDIR/t3-XXXX")"
build_run_log "$T3" "run-a" "sha256:abc" "deadbeef1234" "clean"
(
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "jq" ]; then return 1; fi
    builtin command "$@"
  }
  ev_is_stale_by_fingerprint "run-a" "$T3" 2>/dev/null; R1=$?
  ev_is_stale_by_config "run-a" "$T3" 2>/dev/null; R2=$?
  ev_is_stale_by_vcs "run-a" "$T3" 2>/dev/null; R3=$?
  printf '%s %s %s\n' "$R1" "$R2" "$R3" > "$TMPDIR/t3-rcs"
)
T3_RCS="$(cat "$TMPDIR/t3-rcs" 2>/dev/null)"
if [ "$T3_RCS" = "0 0 0" ]; then
  echo "PASS: T3: jq missing → all three axes stale (FAIL-CLOSED)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: T3: expected '0 0 0', got '$T3_RCS'"
  FAILED=$((FAILED + 1))
fi

# ---- T4: no sha tool → Axis2 stale (FAIL-CLOSED) ----
T4="$(mktemp -d "$TMPDIR/t4-XXXX")"
mkdir -p "$T4/.harness"
printf '{"project_name":"p"}\n' > "$T4/.harness/config.json"
build_run_log "$T4" "run-a" "sha256:$(sha256sum "$T4/.harness/config.json" | awk '{print $1}')" "" "clean"
(
  command() {
    if [ "$1" = "-v" ] && { [ "$2" = "sha256sum" ] || [ "$2" = "shasum" ]; }; then return 1; fi
    builtin command "$@"
  }
  ev_is_stale_by_config "run-a" "$T4" 2>"$TMPDIR/t4-err"
  printf '%s' "$?" > "$TMPDIR/t4-rc"
)
T4_RC="$(cat "$TMPDIR/t4-rc" 2>/dev/null)"
assert_stale "T4: Axis2 no sha tool → stale (FAIL-CLOSED)" "$T4_RC"
if grep -q "FAIL-CLOSED" "$TMPDIR/t4-err" 2>/dev/null; then
  echo "PASS: T4: FAIL-CLOSED diagnostic emitted"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: T4: expected FAIL-CLOSED diagnostic on stderr"
  FAILED=$((FAILED + 1))
fi

# ---- T5: stored vcs_revision but not a git repo → Axis3 stale (FAIL-CLOSED) ----
T5="$(mktemp -d "$TMPDIR/t5-XXXX")"
build_run_log "$T5" "run-a" "sha256:abc" "deadbeef1234" "clean"   # no git init
T5_ERR="$(mktemp "$TMPDIR/t5-err-XXXX")"
ev_is_stale_by_vcs "run-a" "$T5" 2>"$T5_ERR"
T5_RC=$?
assert_stale "T5: Axis3 stored rev, not a git repo → stale (FAIL-CLOSED)" "$T5_RC"
if grep -q "FAIL-CLOSED" "$T5_ERR"; then
  echo "PASS: T5: FAIL-CLOSED diagnostic emitted"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: T5: expected FAIL-CLOSED diagnostic on stderr"
  FAILED=$((FAILED + 1))
fi

# ---- T6: no stored vcs_revision, not a git repo → Axis3 NOT stale ----
T6="$(mktemp -d "$TMPDIR/t6-XXXX")"
build_run_log "$T6" "run-a" "sha256:abc" "" "clean"
ev_is_stale_by_vcs "run-a" "$T6"; assert_fresh "T6: Axis3 no stored rev → not stale (design)" "$?"

# ---- T7: config deleted → Axis2 stale ----
T7="$(mktemp -d "$TMPDIR/t7-XXXX")"
mkdir -p "$T7/.harness"
printf '{"project_name":"p"}\n' > "$T7/.harness/config.json"
CFG7_SHA="sha256:$(sha256sum "$T7/.harness/config.json" | awk '{print $1}')"
build_run_log "$T7" "run-a" "$CFG7_SHA" "" "clean"
rm -f "$T7/.harness/config.json"
ev_is_stale_by_config "run-a" "$T7"; assert_stale "T7: Axis2 config deleted → stale" "$?"

# ---- T8: config changed → Axis2 stale ----
T8="$(mktemp -d "$TMPDIR/t8-XXXX")"
mkdir -p "$T8/.harness"
printf '{"project_name":"p"}\n' > "$T8/.harness/config.json"
CFG8_SHA="sha256:$(sha256sum "$T8/.harness/config.json" | awk '{print $1}')"
build_run_log "$T8" "run-a" "$CFG8_SHA" "" "clean"
printf '{"project_name":"p","extra":true}\n' > "$T8/.harness/config.json"
ev_is_stale_by_config "run-a" "$T8"; assert_stale "T8: Axis2 config changed → stale" "$?"

# ---- T9: git repo but HEAD != stored rev → Axis3 stale ----
T9="$(mktemp -d "$TMPDIR/t9-XXXX")"
git -C "$T9" init -q
git -C "$T9" config user.email "t@t"
git -C "$T9" config user.name "t"
printf 'hello\n' > "$T9/README.md"
git -C "$T9" add README.md
git -C "$T9" commit -qm "init"
build_run_log "$T9" "run-a" "sha256:abc" "deadbeef1234" "clean"   # WRONG rev
ev_is_stale_by_vcs "run-a" "$T9"; assert_stale "T9: Axis3 HEAD != stored rev → stale" "$?"

# ---- T10: clean git repo, all match → fresh on all three axes ----
T10="$(mktemp -d "$TMPDIR/t10-XXXX")"
git -C "$T10" init -q
git -C "$T10" config user.email "t@t"
git -C "$T10" config user.name "t"
mkdir -p "$T10/.harness"
printf '{"project_name":"p"}\n' > "$T10/.harness/config.json"
printf '{"revision":1,"features":[]}\n' > "$T10/feature_list.json"
CFG10_SHA="sha256:$(sha256sum "$T10/.harness/config.json" | awk '{print $1}')"
# commit the base tree first, THEN write the run log (run log is excluded from
# fingerprint) so the tree stays clean.
git -C "$T10" add -A
git -C "$T10" commit -qm "base"
REV10="$(git -C "$T10" rev-parse --short=12 HEAD)"
build_run_log "$T10" "run-a" "$CFG10_SHA" "$REV10" "clean"
ev_is_stale_by_fingerprint "run-a" "$T10"; R10A=$?
ev_is_stale_by_config "run-a" "$T10"; R10B=$?
ev_is_stale_by_vcs "run-a" "$T10"; R10C=$?
if [ "$R10A" = "1" ] && [ "$R10B" = "1" ] && [ "$R10C" = "1" ]; then
  echo "PASS: T10: clean repo, all match → fresh on all three axes"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: T10: expected 1 1 1 (fresh), got $R10A $R10B $R10C"
  FAILED=$((FAILED + 1))
fi

# ---- T11: git project + no stored vcs_revision → Axis3 stale (P0-14) ----
# A PASS run inside a git project MUST record its vcs_revision; a missing
# revision is unverifiable → fail-closed stale. (T6 covers the non-git case,
# which is unaffected and stays fresh.)
T11="$(mktemp -d "$TMPDIR/t11-XXXX")"
git -C "$T11" init -q
git -C "$T11" config user.email "t@t"
git -C "$T11" config user.name "t"
printf 'hello\n' > "$T11/README.md"
git -C "$T11" add README.md
git -C "$T11" commit -qm "init"
build_run_log "$T11" "run-a" "sha256:abc" "" "clean"   # git project, NO rev
T11_ERR="$(mktemp "$TMPDIR/t11-err-XXXX")"
ev_is_stale_by_vcs "run-a" "$T11" 2>"$T11_ERR"
T11_RC=$?
assert_stale "T11: Axis3 git project, no stored rev → stale (P0-14 fail-closed)" "$T11_RC"
if grep -q "FAIL-CLOSED" "$T11_ERR"; then
  echo "PASS: T11: FAIL-CLOSED diagnostic emitted"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: T11: expected FAIL-CLOSED diagnostic on stderr"
  FAILED=$((FAILED + 1))
fi

echo ""
echo "Staleness Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
