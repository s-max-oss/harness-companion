#!/bin/bash
# test-passing.sh — Passing eligibility test suite (v2)
#
# Tests design §9.1 8-step passing eligibility:
#   1. Find latest association
#   2. Canonical validation (validate_run_log 16-step)
#   3. Terminal must be run_completed with overall_result="passed"
#   4. run_started.required_command_ids.length > 0
#   5. terminal.failed_commands == 0
#   6. Workspace fingerprint match
#   7. Config SHA-256 match
#   8. VCS HEAD match (git repos only)
#
# Plus the explicit cases requested in G1 round 2:
#   - required_command_ids empty + optional command passed → not eligible
#   - overall_result=passed but failed_commands>0 → not eligible
#   - config hash match → eligible; mismatch → not eligible
#   - Git HEAD match → eligible; advance → not eligible
#   - Non-git project correctly skips VCS comparison
#   - All three axes fresh → eligible

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"
GOLDEN_DIR="$TEST_DIR/../golden"

# shellcheck source=../../core/lib/passing.sh
source "$CORE_LIB/passing.sh"
# shellcheck source=../../core/lib/workspace-fingerprint.sh
source "$CORE_LIB/workspace-fingerprint.sh"

PASSED=0
FAILED=0

# Counters for stable error hints and structured assertion handling
assert_passing_eligible() {
  local test_name="$1" feature_id="$2" fl_path="$3" project_dir="$4"
  if output="$(is_eligible_for_passing "$feature_id" "$fl_path" "$project_dir" 2>&1)"; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — expected eligible, got: $output"
    FAILED=$((FAILED + 1))
  fi
}

assert_passing_not_eligible() {
  local test_name="$1" feature_id="$2" fl_path="$3" project_dir="$4" expected_hint="$5"
  if output="$(is_eligible_for_passing "$feature_id" "$fl_path" "$project_dir" 2>&1)"; then
    echo "FAIL: $test_name — expected NOT eligible, but returned 0"
    FAILED=$((FAILED + 1))
  else
    if printf '%s' "$output" | grep -qi "$expected_hint"; then
      echo "PASS: $test_name"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL: $test_name — expected hint '$expected_hint', got: $output"
      FAILED=$((FAILED + 1))
    fi
  fi
}

# ---- shared scaffolding ---------------------------------------------------
# Each test case gets its own TMPDIR so we can manipulate the workspace,
# config, and .harness/ independently. We then make a per-case feature_list
# that references a run_id pointing to a per-case ndjson file.

# A minimal harness config used by most cases. Each case may override or
# modify this content; the SHA-256 of the file content is what run_started
# config_sha256 MUST match.
make_config() {
  local dir="$1"
  mkdir -p "$dir/.harness/logs/runs"
  cat > "$dir/.harness/config.json" <<'CFG'
{
  "version": 1,
  "schema_version": 2,
  "verification_plan": {
    "commands": [
      {
        "id": "typecheck",
        "argv": ["npx", "tsc", "--noEmit"],
        "required_for_passing": true
      },
      {
        "id": "unit-test",
        "argv": ["npm", "run", "test"],
        "required_for_passing": true
      }
    ]
  }
}
CFG
}

# Compute a "clean workspace" placeholder fingerprint matching what
# workspace-fingerprint.sh would return when there are no tracked or untracked
# files modified (i.e., "clean" for a git repo, or computed for non-git).
#
# Rather than try to keep this perfectly in sync with compute_workspace_fingerprint,
# each test case directly invokes compute_workspace_fingerprint to obtain the
# truth value, then bakes that into the run log. This keeps the test honest:
# the "verified" value is whatever the codebase says is current.

# Construct an NDJSON run log with the given run_id, required_command_ids,
# vcs_revision, config_sha256 (or "null"), overall_result, failed_commands,
# passed/failed/skipped, and verified fingerprint.
make_run_log() {
  local dir="$1"
  local run_id="$2"
  local required_json="$3"   # e.g. '["typecheck","unit-test"]' or '[]'
  local vcs_revision="$4"    # e.g. "abc1234def56" or "null"
  local config_sha="$5"      # e.g. "sha256:def456" or "null"
  local verified_fp="$6"     # e.g. "sha256:abc123" or "clean"
  local overall="$7"         # "passed" | "no_checks" | "failed" | "aborted"
  local executed="$8" passed_n="$9" failed_n="${10}" skipped_n="${11}"
  local failed_ids_json="${12}"  # e.g. '[]' or '["unit-test"]'

  local log="$dir/.harness/logs/runs/${run_id}.ndjson"
  local failed_ids_field=""
  if [ "$overall" = "failed" ]; then
    failed_ids_field=",\"failed_command_ids\":${failed_ids_json}"
  fi

  # run_started event
  jq -nc \
    --arg run_id "$run_id" \
    --arg vcs_rev "$vcs_revision" \
    --arg config_sha "$config_sha" \
    --argjson req "$required_json" \
    --arg verified_fp "$verified_fp" \
    '{event:"run_started",schema_version:2,run_id:$run_id,started_at:"2026-07-31T15:12:57Z",project_root:"/test",vcs_revision:$vcs_rev,vcs_revision_source:"git",workspace_fingerprint_initial:$verified_fp,config_sha256:$config_sha,required_command_ids:$req,capability_level:1,feature_id:"feat-x"}' \
    > "$log"

  # command_completed events (one per required; all pass unless overall=failed)
  # Strip CR (Windows Git Bash adds \r to for-loop tokens)
  local cmd_ids
  cmd_ids="$(printf '%s' "$required_json" | jq -r '.[]' | tr -d '\r')"
  local cmd_id
  while IFS= read -r cmd_id; do
    [ -z "$cmd_id" ] && continue
    local exit_code=0
    if [ "$overall" = "failed" ] && printf '%s' "$failed_ids_json" | jq -e --arg c "$cmd_id" 'index($c)' >/dev/null; then
      exit_code=1
    fi
    jq -nc \
      --arg run_id "$run_id" \
      --arg cmd_id "$cmd_id" \
      --argjson exit_code "$exit_code" \
      '{event:"command_completed",schema_version:2,run_id:$run_id,command_id:$cmd_id,command:["x"],command_origin:"configured",confirmation:"not_required",exit_code:$exit_code,started_at:"2026-07-31T15:13:00Z",duration_ms:100,log_artifact:"x.log",log_sha256:"sha256:y"}' \
      >> "$log"
  done <<< "$cmd_ids"

  # terminal event
  local terminal_event="run_completed"
  [ "$overall" = "failed" ] && terminal_event="run_failed"
  [ "$overall" = "aborted" ] && terminal_event="run_aborted"

  jq -nc \
    --arg ev "$terminal_event" \
    --arg run_id "$run_id" \
    --arg overall "$overall" \
    --arg verified_fp "$verified_fp" \
    --argjson planned "$executed" \
    --argjson executed "$executed" \
    --argjson passed_n "$passed_n" \
    --argjson failed_n "$failed_n" \
    --argjson skipped "$skipped_n" \
    --argjson fid "$failed_ids_json" \
    '{event:$ev,schema_version:2,run_id:$run_id,completed_at:"2026-07-31T15:13:12Z",overall_result:$overall,workspace_fingerprint_verified:$verified_fp,planned_commands:$planned,executed_commands:$executed,passed_commands:$passed_n,failed_commands:$failed_n,skipped_commands:$skipped}' \
    >> "$log"

  # Add failed_command_ids if overall=failed
  if [ "$overall" = "failed" ]; then
    # Replace the last line's trailing } with ,"failed_command_ids":[...]}
    local last_line
    last_line="$(tail -1 "$log")"
    local new_line
    new_line="$(printf '%s' "$last_line" | jq -c --argjson fid "$failed_ids_json" '. + {failed_command_ids:$fid}')"
    # rewrite last line
    head -n -1 "$log" > "${log}.tmp"
    printf '%s\n' "$new_line" >> "${log}.tmp"
    mv "${log}.tmp" "$log"
  fi
}

# Make a feature_list referencing one run_id for one feature
make_feature_list() {
  local dir="$1" feature_id="$2" run_id="$3" extra_features_json="$4"
  jq -nc \
    --arg fid "$feature_id" \
    --arg rid "$run_id" \
    --argjson extra "$extra_features_json" \
    '{
      revision: 1,
      features: (
        [{id:$fid,status:"in_progress",evidence_associations:[{run_id:$rid,associated_at:"2026-07-31T15:14:00Z",associated_by:"user"}]}] + $extra
      ),
      last_updated: "2026-07-31"
    }' > "$dir/feature_list.json"
}

# ============================================================================
# Test 1: Valid passed run → eligible (golden file)
# ============================================================================
echo "=== Test 1: Valid passed run ==="
T1="$(mktemp -d)"
make_config "$T1"
# Use the golden file's content (run_id 20260731T151257Z-12345-32767)
cp "$GOLDEN_DIR/run-log-valid.ndjson" "$T1/.harness/logs/runs/20260731T151257Z-12345-32767.ndjson"
# Use golden config_sha from the run_started event (sha256:def456).
# We'll craft a config whose SHA matches. Easiest: extract from the log and
# make config content with that exact hash. But the design says we MUST hash
# the current config. For this test we synthesize a config whose content is
# the empty object — that won't match. So: we forge a config file whose
# SHA-256 equals the stored one by writing the bytes directly.
# Easier: take any 32-byte content and use its sha256 as the stored value in
# a custom run log. We'll regenerate the log with a hash that matches our
# config.
rm -f "$T1/.harness/logs/runs/20260731T151257Z-12345-32767.ndjson"

# Generate config, compute its hash
printf '{"version":1}\n' > "$T1/.harness/config.json"
T1_CONFIG_SHA="sha256:$(sha256sum "$T1/.harness/config.json" | awk '{print $1}')"

# For non-git (mktemp -d is not a git repo), compute_workspace_fingerprint
# returns "no_git" or a sha256 of the file listing. Make verified_fp match it.
T1_VERIFIED_FP="$(compute_workspace_fingerprint "$T1")"

make_run_log "$T1" "20260731T151257Z-12345-32767" \
  '["typecheck","unit-test"]' "null" "$T1_CONFIG_SHA" "$T1_VERIFIED_FP" \
  "passed" 2 2 0 0 '[]'

make_feature_list "$T1" "feat-ok" "20260731T151257Z-12345-32767" '[]'
assert_passing_eligible "passed run is eligible (canonical valid, fresh config & workspace)" \
  "feat-ok" "$T1/feature_list.json" "$T1"
rm -rf "$T1"

# ============================================================================
# Test 2: no_checks run → not eligible
# ============================================================================
echo ""
echo "=== Test 2: no_checks ==="
T2="$(mktemp -d)"
make_config "$T2"
printf '{"version":1}\n' > "$T2/.harness/config.json"
T2_CONFIG_SHA="sha256:$(sha256sum "$T2/.harness/config.json" | awk '{print $1}')"
T2_VERIFIED_FP="$(compute_workspace_fingerprint "$T2")"
# no_checks terminal: required_command_ids must be [] for validate_run_log
make_run_log "$T2" "20260731T151257Z-00000-00000" '[]' "null" "$T2_CONFIG_SHA" \
  "$T2_VERIFIED_FP" "no_checks" 0 0 0 0 '[]'
make_feature_list "$T2" "feat-nochecks" "20260731T151257Z-00000-00000" '[]'
assert_passing_not_eligible "no_checks run is not eligible (step 3: overall_result)" \
  "feat-nochecks" "$T2/feature_list.json" "$T2" "overall_result_not_passed"
rm -rf "$T2"

# ============================================================================
# Test 3: No evidence associations → not eligible (step 1)
# ============================================================================
echo ""
echo "=== Test 3: No evidence associations ==="
T3="$(mktemp -d)"
make_config "$T3"
cat > "$T3/feature_list.json" <<'FL'
{
  "revision": 1,
  "features": [
    {"id": "feat-no-assoc", "status": "in_progress", "evidence_associations": []}
  ],
  "last_updated": "2026-07-31"
}
FL
assert_passing_not_eligible "no evidence associations (step 1)" \
  "feat-no-assoc" "$T3/feature_list.json" "$T3" "no_evidence_association"
rm -rf "$T3"

# ============================================================================
# Test 4: Missing run log → not eligible (step 2)
# ============================================================================
echo ""
echo "=== Test 4: Missing run log ==="
T4="$(mktemp -d)"
make_config "$T4"
make_feature_list "$T4" "feat-missing-log" "nonexistent-run-id" '[]'
assert_passing_not_eligible "missing canonical run log (step 2)" \
  "feat-missing-log" "$T4/feature_list.json" "$T4" "run_log_missing"
rm -rf "$T4"

# ============================================================================
# Test 5: Failed run → not eligible (step 3)
# ============================================================================
echo ""
echo "=== Test 5: Failed run ==="
T5="$(mktemp -d)"
make_config "$T5"
printf '{"version":1}\n' > "$T5/.harness/config.json"
T5_CONFIG_SHA="sha256:$(sha256sum "$T5/.harness/config.json" | awk '{print $1}')"
T5_VERIFIED_FP="$(compute_workspace_fingerprint "$T5")"
make_run_log "$T5" "20260731T151257Z-failed-01" '["unit-test"]' "null" "$T5_CONFIG_SHA" \
  "$T5_VERIFIED_FP" "failed" 1 0 1 0 '["unit-test"]'
make_feature_list "$T5" "feat-failed" "20260731T151257Z-failed-01" '[]'
assert_passing_not_eligible "failed run is not eligible (step 3: terminal=run_failed)" \
  "feat-failed" "$T5/feature_list.json" "$T5" "run_not_completed"
rm -rf "$T5"

# ============================================================================
# Test 6: Nonexistent feature → not eligible (step 1)
# ============================================================================
echo ""
echo "=== Test 6: Nonexistent feature ==="
T6="$(mktemp -d)"
make_config "$T6"
make_feature_list "$T6" "feat-real" "any-run-id" '[]'
assert_passing_not_eligible "nonexistent feature (step 1)" \
  "feat-nonexistent" "$T6/feature_list.json" "$T6" "feature_not_found"
rm -rf "$T6"

# ============================================================================
# Test 7: required_command_ids empty + optional command passed → NOT eligible
#         (design §9.1 step 4: required_command_ids.length > 0 is required,
#         regardless of how many optional commands ran successfully.)
# ============================================================================
echo ""
echo "=== Test 7: empty required_command_ids + optional success → not eligible ==="
T7="$(mktemp -d)"
make_config "$T7"
printf '{"version":1}\n' > "$T7/.harness/config.json"
T7_CONFIG_SHA="sha256:$(sha256sum "$T7/.harness/config.json" | awk '{print $1}')"
T7_VERIFIED_FP="$(compute_workspace_fingerprint "$T7")"
# required_command_ids=[], but execute one command and write terminal passed
# Note: validate_run_log step 14c requires planned >= required (0), so planned=1 is fine.
# But overall_result must be "passed" only if executed > 0 and failed == 0.
# We write run_started (required=[]), then ONE command_completed (representing
# the optional command), then run_completed with overall=passed.
LOG="$T7/.harness/logs/runs/20260731T-optional.ndjson"
jq -nc --arg rid "20260731T-optional" --arg csha "$T7_CONFIG_SHA" --arg vfp "$T7_VERIFIED_FP" \
  '{event:"run_started",schema_version:2,run_id:$rid,started_at:"2026-07-31T15:12:57Z",project_root:"/test",vcs_revision:"null",vcs_revision_source:"none",workspace_fingerprint_initial:$vfp,config_sha256:$csha,required_command_ids:[],capability_level:1,feature_id:"feat-opt"}' \
  > "$LOG"
jq -nc --arg rid "20260731T-optional" \
  '{event:"command_completed",schema_version:2,run_id:$rid,command_id:"optional-lint",command:["echo","ok"],command_origin:"detected",confirmation:"confirmed",exit_code:0,started_at:"2026-07-31T15:13:00Z",duration_ms:50,log_artifact:"o.log",log_sha256:"sha256:o"}' \
  >> "$LOG"
jq -nc --arg rid "20260731T-optional" --arg vfp "$T7_VERIFIED_FP" \
  '{event:"run_completed",schema_version:2,run_id:$rid,completed_at:"2026-07-31T15:13:12Z",overall_result:"passed",workspace_fingerprint_verified:$vfp,planned_commands:1,executed_commands:1,passed_commands:1,failed_commands:0,skipped_commands:0}' \
  >> "$LOG"
make_feature_list "$T7" "feat-opt" "20260731T-optional" '[]'
assert_passing_not_eligible "empty required_command_ids + optional command passed → not eligible (step 4)" \
  "feat-opt" "$T7/feature_list.json" "$T7" "no_required_steps"
rm -rf "$T7"

# ============================================================================
# Test 8: overall_result=passed but failed_commands>0 → NOT eligible
#         (design §9.1 step 5: explicit failed_commands==0 check,
#         independent of overall_result.)
# ============================================================================
echo ""
echo "=== Test 8: overall_result=passed but failed_commands>0 → not eligible ==="
T8="$(mktemp -d)"
make_config "$T8"
printf '{"version":1}\n' > "$T8/.harness/config.json"
T8_CONFIG_SHA="sha256:$(sha256sum "$T8/.harness/config.json" | awk '{print $1}')"
T8_VERIFIED_FP="$(compute_workspace_fingerprint "$T8")"
# Forge a terminal event with overall_result="passed" but failed_commands=1
# This SHOULD be caught by the explicit step 5 safety check.
LOG="$T8/.harness/logs/runs/20260731T-inconsistent.ndjson"
jq -nc --arg rid "20260731T-inconsistent" --arg csha "$T8_CONFIG_SHA" --arg vfp "$T8_VERIFIED_FP" \
  --argjson req '["c1"]' \
  '{event:"run_started",schema_version:2,run_id:$rid,started_at:"2026-07-31T15:12:57Z",project_root:"/test",vcs_revision:"null",vcs_revision_source:"none",workspace_fingerprint_initial:$vfp,config_sha256:$csha,required_command_ids:$req,capability_level:1,feature_id:"feat-incon"}' \
  > "$LOG"
jq -nc --arg rid "20260731T-inconsistent" \
  '{event:"command_completed",schema_version:2,run_id:$rid,command_id:"c1",command:["x"],command_origin:"configured",confirmation:"not_required",exit_code:0,started_at:"2026-07-31T15:13:00Z",duration_ms:50,log_artifact:"c1.log",log_sha256:"sha256:c1"}' \
  >> "$LOG"
jq -nc --arg rid "20260731T-inconsistent" --arg vfp "$T8_VERIFIED_FP" \
  '{event:"run_completed",schema_version:2,run_id:$rid,completed_at:"2026-07-31T15:13:12Z",overall_result:"passed",workspace_fingerprint_verified:$vfp,planned_commands:1,executed_commands:1,passed_commands:0,failed_commands:1,skipped_commands:0}' \
  >> "$LOG"
make_feature_list "$T8" "feat-incon" "20260731T-inconsistent" '[]'
assert_passing_not_eligible "passed overall + failed_commands>0 → not eligible (step 5)" \
  "feat-incon" "$T8/feature_list.json" "$T8" "command_failed"
rm -rf "$T8"

# ============================================================================
# Test 9: config hash consistent → eligible (step 7)
# ============================================================================
echo ""
echo "=== Test 9: config hash match → eligible ==="
T9="$(mktemp -d)"
make_config "$T9"
printf '{"version":1}\n' > "$T9/.harness/config.json"
T9_CONFIG_SHA="sha256:$(sha256sum "$T9/.harness/config.json" | awk '{print $1}')"
T9_VERIFIED_FP="$(compute_workspace_fingerprint "$T9")"
make_run_log "$T9" "20260731T-cfgmatch" '["typecheck"]' "null" "$T9_CONFIG_SHA" \
  "$T9_VERIFIED_FP" "passed" 1 1 0 0 '[]'
make_feature_list "$T9" "feat-cfgmatch" "20260731T-cfgmatch" '[]'
assert_passing_eligible "config SHA matches → eligible (step 7)" \
  "feat-cfgmatch" "$T9/feature_list.json" "$T9"
rm -rf "$T9"

# ============================================================================
# Test 10: config modified after run → not eligible (step 7)
# ============================================================================
echo ""
echo "=== Test 10: config changed → not eligible ==="
T10="$(mktemp -d)"
make_config "$T10"
printf '{"version":1}\n' > "$T10/.harness/config.json"
T10_ORIG_SHA="sha256:$(sha256sum "$T10/.harness/config.json" | awk '{print $1}')"
T10_VERIFIED_FP="$(compute_workspace_fingerprint "$T10")"
make_run_log "$T10" "20260731T-cfgstale" '["typecheck"]' "null" "$T10_ORIG_SHA" \
  "$T10_VERIFIED_FP" "passed" 1 1 0 0 '[]'
# Now mutate config.json
printf '{"version":2}\n' > "$T10/.harness/config.json"
make_feature_list "$T10" "feat-cfgstale" "20260731T-cfgstale" '[]'
assert_passing_not_eligible "config modified → not eligible (step 7)" \
  "feat-cfgstale" "$T10/feature_list.json" "$T10" "config_changed_since_run"
rm -rf "$T10"

# ============================================================================
# Test 11: Git HEAD matches → eligible (step 8)
# ============================================================================
echo ""
echo "=== Test 11: Git HEAD matches → eligible ==="
T11="$(mktemp -d)"
make_config "$T11"
printf '{"version":1}\n' > "$T11/.harness/config.json"
T11_CONFIG_SHA="sha256:$(sha256sum "$T11/.harness/config.json" | awk '{print $1}')"
# Initialize git so this is a git repo
git -C "$T11" init -q 2>/dev/null
git -C "$T11" config user.email "test@test"
git -C "$T11" config user.name  "test"
git -C "$T11" config commit.gpgsign false
git -C "$T11" add -A 2>/dev/null
git -C "$T11" commit -q -m "init" 2>/dev/null
T11_HEAD="$(git -C "$T11" rev-parse --short=12 HEAD 2>/dev/null)"
T11_VERIFIED_FP="$(compute_workspace_fingerprint "$T11")"
make_run_log "$T11" "20260731T-vcsmatch" '["typecheck"]' "$T11_HEAD" "$T11_CONFIG_SHA" \
  "$T11_VERIFIED_FP" "passed" 1 1 0 0 '[]'
make_feature_list "$T11" "feat-vcsmatch" "20260731T-vcsmatch" '[]'
assert_passing_eligible "Git HEAD matches → eligible (step 8)" \
  "feat-vcsmatch" "$T11/feature_list.json" "$T11"
rm -rf "$T11"

# ============================================================================
# Test 12: Git HEAD advances → not eligible (step 8)
# ============================================================================
echo ""
echo "=== Test 12: Git HEAD advanced → not eligible ==="
T12="$(mktemp -d)"
make_config "$T12"
printf '{"version":1}\n' > "$T12/.harness/config.json"
T12_CONFIG_SHA="sha256:$(sha256sum "$T12/.harness/config.json" | awk '{print $1}')"
git -C "$T12" init -q 2>/dev/null
git -C "$T12" config user.email "test@test"
git -C "$T12" config user.name  "test"
git -C "$T12" config commit.gpgsign false
git -C "$T12" add -A 2>/dev/null
git -C "$T12" commit -q -m "init" 2>/dev/null
T12_OLD_HEAD="$(git -C "$T12" rev-parse --short=12 HEAD 2>/dev/null)"
T12_VERIFIED_FP="$(compute_workspace_fingerprint "$T12")"
make_run_log "$T12" "20260731T-vcsstale" '["typecheck"]' "$T12_OLD_HEAD" "$T12_CONFIG_SHA" "$T12_VERIFIED_FP" "passed" 1 1 0 0 '[]'
# Now advance HEAD
echo "extra" > "$T12/extra.txt"
git -C "$T12" add -A 2>/dev/null
git -C "$T12" commit -q -m "advance" 2>/dev/null
make_feature_list "$T12" "feat-vcsstale" "20260731T-vcsstale" '[]'
assert_passing_not_eligible "Git HEAD advanced not eligible (step 8)" "feat-vcsstale" "$T12/feature_list.json" "$T12" "vcs_moved_since_run"
rm -rf "$T12"

# ============================================================================
# Test 13: Non-git project → VCS comparison skipped, eligible if axes match
# ============================================================================
echo ""
echo "=== Test 13: Non-git project → VCS skipped, eligible ==="
T13="$(mktemp -d)"
make_config "$T13"
printf '{"version":1}\n' > "$T13/.harness/config.json"
T13_CONFIG_SHA="sha256:$(sha256sum "$T13/.harness/config.json" | awk '{print $1}')"
T13_VERIFIED_FP="$(compute_workspace_fingerprint "$T13")"
# vcs_revision=null means step 8 is skipped
make_run_log "$T13" "20260731T-nongit" '["typecheck"]' "null" "$T13_CONFIG_SHA" \
  "$T13_VERIFIED_FP" "passed" 1 1 0 0 '[]'
make_feature_list "$T13" "feat-nongit" "20260731T-nongit" '[]'
assert_passing_eligible "non-git project: VCS skipped → eligible (step 8)" \
  "feat-nongit" "$T13/feature_list.json" "$T13"
rm -rf "$T13"

# ============================================================================
# Test 14: Workspace fingerprint mismatch → not eligible (step 6)
# ============================================================================
echo ""
echo "=== Test 14: workspace changed → not eligible ==="
T14="$(mktemp -d)"
make_config "$T14"
printf '{"version":1}\n' > "$T14/.harness/config.json"
T14_CONFIG_SHA="sha256:$(sha256sum "$T14/.harness/config.json" | awk '{print $1}')"
T14_VERIFIED_FP="$(compute_workspace_fingerprint "$T14")"
make_run_log "$T14" "20260731T-fpstale" '["typecheck"]' "null" "$T14_CONFIG_SHA" \
  "$T14_VERIFIED_FP" "passed" 1 1 0 0 '[]'
# Now modify a tracked file (workspace fingerprint step 6 check)
printf "changed\n" > "$T14/foo.txt"
make_feature_list "$T14" "feat-fpstale" "20260731T-fpstale" '[]'
assert_passing_not_eligible "workspace modified → not eligible (step 6)" \
  "feat-fpstale" "$T14/feature_list.json" "$T14" "workspace_changed_since_verification"
rm -rf "$T14"

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
