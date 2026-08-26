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

# write_test_config — overwrite .harness/config.json with a custom shape that
# declares the listed command_ids so validate_run_log step 5d can match
# recorded argv against the config anchor. Codex r5 defect 1 makes this
# required; without it, the recorded command array is meaningless to the
# validator. The shape mirrors make_config's verification_plan so canonical
# and legacy schema paths in validate_run_log both find the ids.
#
# Args:
#   $1 — dir
#   $2 — JSON array of {id, argv} objects, e.g. '[{"id":"x","argv":["a"]}]'
#        (plain strings are also accepted and get argv=["x"] by default)
write_test_config() {
  local dir="$1"
  local cmds_json="$2"
  # Normalize: if the first element is a string, wrap each as {id,argv:["x"]}.
  local commands
  commands="$(printf '%s' "$cmds_json" | jq -c '
    if (.[0] | type) == "string" then
      map({id: ., argv: ["x"], required_for_passing: true})
    else
      map(. + {required_for_passing: (true)})
    end
  ')"
  jq -nc \
    --argjson commands "$commands" \
    '{version: 1, schema_version: 2, verification_plan: {commands: $commands}}' \
    > "$dir/.harness/config.json"
}

# write_test_config_for — variant that takes a list of id→argv pairs as
# positional arguments (id1 argv1_json id2 argv2_json ...). Used by tests
# whose hand-crafted command_completed events have non-["x"] argv.
write_test_config_for() {
  local dir="$1"
  shift
  local commands="[]"
  while [ $# -gt 0 ]; do
    local cid="$1" argv="$2"
    commands="$(printf '%s' "$commands" | jq -c \
      --arg cid "$cid" --argjson argv "$argv" \
      '. + [{id: $cid, argv: $argv, required_for_passing: true}]'
    )"
    shift 2
  done
  jq -nc \
    --argjson commands "$commands" \
    '{version: 1, schema_version: 2, verification_plan: {commands: $commands}}' \
    > "$dir/.harness/config.json"
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
#
# Codex r5 defect 1: validate_run_log step 5d requires that the recorded
# command array equal the config-declared argv (otherwise command_array_mismatch
# fires). make_run_log therefore looks up each command_id's argv in the
# project_dir's .harness/config.json and writes that array into the run log;
# for unknown command_ids it falls back to ["x"] (a placeholder that signals
# the test is intentionally NOT exercising the config-anchor path).
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
  local feature_id="${13:-feat-x}"  # Codex r4: run's feature_id; default "feat-x" for legacy callers

  local log="$dir/.harness/logs/runs/${run_id}.ndjson"
  local config_path="$dir/.harness/config.json"
  local failed_ids_field=""
  if [ "$overall" = "failed" ]; then
    failed_ids_field=",\"failed_command_ids\":${failed_ids_json}"
  fi

  # Codex r6 (blocker ①): validate_run_log now requires a real log_artifact +
  # log_sha256 for any command_completed with exit_code != 127. Build a per-
  # command log file under .harness/logs/runs/<run_id>/<cmd_id>.log, write
  # bytes, and embed the relative path + sha into the NDJSON event. Failed
  # commands (exit_code:1) keep the same contract — the test is asserting the
  # failing-command eligibility hint, not the log-artifact binding.
  mkdir -p "$dir/.harness/logs/runs/${run_id}"

  # run_started event
  jq -nc \
    --arg run_id "$run_id" \
    --arg vcs_rev "$vcs_revision" \
    --arg config_sha "$config_sha" \
    --argjson req "$required_json" \
    --arg verified_fp "$verified_fp" \
    --arg fid "$feature_id" \
    --arg project_root "$dir" \
    '{event:"run_started",schema_version:2,run_id:$run_id,started_at:"2026-07-31T15:12:57Z",project_root:$project_root,vcs_revision:$vcs_rev,vcs_revision_source:"git",workspace_fingerprint_initial:$verified_fp,config_sha256:$config_sha,required_command_ids:$req,capability_level:1,feature_id:$fid}' \
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
    # Look up argv for this command_id from config (canonical or legacy schema);
    # fall back to ["x"] if the id is not declared so tests that don't care about
    # the config-anchor can still produce a structurally valid run log.
    local cmd_argv
    if [ -f "$config_path" ]; then
      cmd_argv="$(jq -c --arg cid "$cmd_id" '
          ((.verification.commands // .verification_plan.commands // [])
           | map(select(.id == $cid))[0]
           | (.command // .argv))
          // ["x"]
        ' "$config_path" 2>/dev/null)"
      if [ -z "$cmd_argv" ]; then cmd_argv='["x"]'; fi
    else
      cmd_argv='["x"]'
    fi
    # Write a real log file for this command and bind its sha (r6 block ①).
    local log_rel log_sha
    log_rel=".harness/logs/runs/${run_id}/${cmd_id}.log"
    printf '%s\n' "log for ${run_id}/${cmd_id} exit=${exit_code}" > "$dir/$log_rel"
    log_sha="$(sha256sum "$dir/$log_rel" | awk '{print $1}')"
    jq -nc \
      --arg run_id "$run_id" \
      --arg cmd_id "$cmd_id" \
      --argjson exit_code "$exit_code" \
      --argjson cmd_argv "$cmd_argv" \
      --arg la "$log_rel" \
      --arg lsh "$log_sha" \
      '{event:"command_completed",schema_version:2,run_id:$run_id,command_id:$cmd_id,command:$cmd_argv,command_origin:"configured",confirmation:"not_required",exit_code:$exit_code,started_at:"2026-07-31T15:13:00Z",duration_ms:100,log_artifact:$la,log_sha256:$lsh}' \
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
write_test_config "$T1" '["typecheck","unit-test"]'
T1_CONFIG_SHA="sha256:$(sha256sum "$T1/.harness/config.json" | awk '{print $1}')"

# For non-git (mktemp -d is not a git repo), compute_workspace_fingerprint
# returns "no_git" or a sha256 of the file listing. Make verified_fp match it.
T1_VERIFIED_FP="$(compute_workspace_fingerprint "$T1")"

make_run_log "$T1" "20260731T151257Z-12345-32767" \
  '["typecheck","unit-test"]' "null" "$T1_CONFIG_SHA" "$T1_VERIFIED_FP" \
  "passed" 2 2 0 0 '[]' "feat-ok"

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
write_test_config "$T2" '[]'
T2_CONFIG_SHA="sha256:$(sha256sum "$T2/.harness/config.json" | awk '{print $1}')"
T2_VERIFIED_FP="$(compute_workspace_fingerprint "$T2")"
# no_checks terminal: required_command_ids must be [] for validate_run_log
make_run_log "$T2" "20260731T151257Z-00000-00000" '[]' "null" "$T2_CONFIG_SHA" \
  "$T2_VERIFIED_FP" "no_checks" 0 0 0 0 '[]' "feat-nochecks"
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
write_test_config "$T5" '["unit-test"]'
T5_CONFIG_SHA="sha256:$(sha256sum "$T5/.harness/config.json" | awk '{print $1}')"
T5_VERIFIED_FP="$(compute_workspace_fingerprint "$T5")"
make_run_log "$T5" "20260731T151257Z-failed-01" '["unit-test"]' "null" "$T5_CONFIG_SHA" \
  "$T5_VERIFIED_FP" "failed" 1 0 1 0 '["unit-test"]' "feat-failed"
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
# optional-lint is hand-crafted below with command=["echo","ok"]; declare it
# explicitly with matching argv so validate_run_log step 5d finds it in the
# config (otherwise command_array_mismatch fires).
write_test_config_for "$T7" "optional-lint" '["echo","ok"]'
T7_CONFIG_SHA="sha256:$(sha256sum "$T7/.harness/config.json" | awk '{print $1}')"
T7_VERIFIED_FP="$(compute_workspace_fingerprint "$T7")"
# required_command_ids=[], but execute one command and write terminal passed
# Note: validate_run_log step 14c requires planned >= required (0), so planned=1 is fine.
# But overall_result must be "passed" only if executed > 0 and failed == 0.
# We write run_started (required=[]), then ONE command_completed (representing
# the optional command), then run_completed with overall=passed.
LOG="$T7/.harness/logs/runs/20260731T-optional.ndjson"
jq -nc --arg rid "20260731T-optional" --arg csha "$T7_CONFIG_SHA" --arg vfp "$T7_VERIFIED_FP" --arg root "$T7" \
  '{event:"run_started",schema_version:2,run_id:$rid,started_at:"2026-07-31T15:12:57Z",project_root:$root,vcs_revision:"null",vcs_revision_source:"none",workspace_fingerprint_initial:$vfp,config_sha256:$csha,required_command_ids:[],capability_level:1,feature_id:"feat-opt"}' \
  > "$LOG"
# Codex r6 (block ①): bind a real log_artifact + log_sha256 (exit_code:0).
LOG_REL=".harness/logs/runs/20260731T-optional/optional-lint.log"
mkdir -p "$T7/.harness/logs/runs/20260731T-optional"
printf 'log for 20260731T-optional/optional-lint\n' > "$T7/$LOG_REL"
LOG_SHA="$(sha256sum "$T7/$LOG_REL" | awk '{print $1}')"
jq -nc --arg rid "20260731T-optional" --arg la "$LOG_REL" --arg lsh "$LOG_SHA" \
  '{event:"command_completed",schema_version:2,run_id:$rid,command_id:"optional-lint",command:["echo","ok"],command_origin:"detected",confirmation:"confirmed",exit_code:0,started_at:"2026-07-31T15:13:00Z",duration_ms:50,log_artifact:$la,log_sha256:$lsh}' \
  >> "$LOG"
jq -nc --arg rid "20260731T-optional" --arg vfp "$T7_VERIFIED_FP" \
  '{event:"run_completed",schema_version:2,run_id:$rid,completed_at:"2026-07-31T15:13:12Z",overall_result:"passed",workspace_fingerprint_verified:$vfp,planned_commands:1,executed_commands:1,passed_commands:1,failed_commands:0,skipped_commands:0}' \
  >> "$LOG"
make_feature_list "$T7" "feat-opt" "20260731T-optional" '[]'
assert_passing_not_eligible "empty required_command_ids + optional command passed → not eligible (step 4)" \
  "feat-opt" "$T7/feature_list.json" "$T7" "no_required_steps"
rm -rf "$T7"

# ============================================================================
# Test 8: overall_result=passed but failed_commands>0 → NOT eligible.
# The canonical run-log validator now derives terminal counters from command
# events, so this forgery is rejected before the passing-layer step-5 check.
# ============================================================================
echo ""
echo "=== Test 8: overall_result=passed but failed_commands>0 → not eligible ==="
T8="$(mktemp -d)"
make_config "$T8"
write_test_config "$T8" '["c1"]'
T8_CONFIG_SHA="sha256:$(sha256sum "$T8/.harness/config.json" | awk '{print $1}')"
T8_VERIFIED_FP="$(compute_workspace_fingerprint "$T8")"
# Forge a terminal event with overall_result="passed" but failed_commands=1.
LOG="$T8/.harness/logs/runs/20260731T-inconsistent.ndjson"
jq -nc --arg rid "20260731T-inconsistent" --arg csha "$T8_CONFIG_SHA" --arg vfp "$T8_VERIFIED_FP" --arg root "$T8" \
  --argjson req '["c1"]' \
  '{event:"run_started",schema_version:2,run_id:$rid,started_at:"2026-07-31T15:12:57Z",project_root:$root,vcs_revision:"null",vcs_revision_source:"none",workspace_fingerprint_initial:$vfp,config_sha256:$csha,required_command_ids:$req,capability_level:1,feature_id:"feat-incon"}' \
  > "$LOG"
# Codex r6 (block ①): bind real log_artifact + log_sha256 (exit_code:0).
LOG8_REL=".harness/logs/runs/20260731T-inconsistent/c1.log"
mkdir -p "$T8/.harness/logs/runs/20260731T-inconsistent"
printf 'log for 20260731T-inconsistent/c1\n' > "$T8/$LOG8_REL"
LOG8_SHA="$(sha256sum "$T8/$LOG8_REL" | awk '{print $1}')"
jq -nc --arg rid "20260731T-inconsistent" --arg la "$LOG8_REL" --arg lsh "$LOG8_SHA" \
  '{event:"command_completed",schema_version:2,run_id:$rid,command_id:"c1",command:["x"],command_origin:"configured",confirmation:"not_required",exit_code:0,started_at:"2026-07-31T15:13:00Z",duration_ms:50,log_artifact:$la,log_sha256:$lsh}' \
  >> "$LOG"
jq -nc --arg rid "20260731T-inconsistent" --arg vfp "$T8_VERIFIED_FP" \
  '{event:"run_completed",schema_version:2,run_id:$rid,completed_at:"2026-07-31T15:13:12Z",overall_result:"passed",workspace_fingerprint_verified:$vfp,planned_commands:1,executed_commands:1,passed_commands:0,failed_commands:1,skipped_commands:0}' \
  >> "$LOG"
make_feature_list "$T8" "feat-incon" "20260731T-inconsistent" '[]'
assert_passing_not_eligible "passed overall + failed_commands>0 → not eligible (step 5)" \
  "feat-incon" "$T8/feature_list.json" "$T8" "terminal_command_result_mismatch"
rm -rf "$T8"

# ============================================================================
# Test 9: config hash consistent → eligible (step 7)
# ============================================================================
echo ""
echo "=== Test 9: config hash match → eligible ==="
T9="$(mktemp -d)"
make_config "$T9"
write_test_config "$T9" '["typecheck"]'
T9_CONFIG_SHA="sha256:$(sha256sum "$T9/.harness/config.json" | awk '{print $1}')"
T9_VERIFIED_FP="$(compute_workspace_fingerprint "$T9")"
make_run_log "$T9" "20260731T-cfgmatch" '["typecheck"]' "null" "$T9_CONFIG_SHA" \
  "$T9_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-cfgmatch"
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
write_test_config "$T10" '["typecheck"]'
T10_ORIG_SHA="sha256:$(sha256sum "$T10/.harness/config.json" | awk '{print $1}')"
T10_VERIFIED_FP="$(compute_workspace_fingerprint "$T10")"
make_run_log "$T10" "20260731T-cfgstale" '["typecheck"]' "null" "$T10_ORIG_SHA" \
  "$T10_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-cfgstale"
# Now mutate config.json — keep the typecheck declaration intact (otherwise
# validate_run_log step 5d fires command_not_in_config BEFORE passing.sh
# step 7 gets a chance to detect the SHA mismatch). The version bump alone
# changes the SHA so passing.sh step 7 fires config_changed_since_run.
printf '{"version":2,"verification_plan":{"commands":[{"id":"typecheck","argv":["x"],"required_for_passing":true}]}}\n' \
  > "$T10/.harness/config.json"
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
write_test_config "$T11" '["typecheck"]'
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
  "$T11_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-vcsmatch"
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
write_test_config "$T12" '["typecheck"]'
T12_CONFIG_SHA="sha256:$(sha256sum "$T12/.harness/config.json" | awk '{print $1}')"
git -C "$T12" init -q 2>/dev/null
git -C "$T12" config user.email "test@test"
git -C "$T12" config user.name  "test"
git -C "$T12" config commit.gpgsign false
git -C "$T12" add -A 2>/dev/null
git -C "$T12" commit -q -m "init" 2>/dev/null
T12_OLD_HEAD="$(git -C "$T12" rev-parse --short=12 HEAD 2>/dev/null)"
T12_VERIFIED_FP="$(compute_workspace_fingerprint "$T12")"
make_run_log "$T12" "20260731T-vcsstale" '["typecheck"]' "$T12_OLD_HEAD" "$T12_CONFIG_SHA" "$T12_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-vcsstale"
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
write_test_config "$T13" '["typecheck"]'
T13_CONFIG_SHA="sha256:$(sha256sum "$T13/.harness/config.json" | awk '{print $1}')"
T13_VERIFIED_FP="$(compute_workspace_fingerprint "$T13")"
# vcs_revision=null means step 8 is skipped
make_run_log "$T13" "20260731T-nongit" '["typecheck"]' "null" "$T13_CONFIG_SHA" \
  "$T13_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-nongit"
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
write_test_config "$T14" '["typecheck"]'
T14_CONFIG_SHA="sha256:$(sha256sum "$T14/.harness/config.json" | awk '{print $1}')"
T14_VERIFIED_FP="$(compute_workspace_fingerprint "$T14")"
make_run_log "$T14" "20260731T-fpstale" '["typecheck"]' "null" "$T14_CONFIG_SHA" \
  "$T14_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-fpstale"
# Now modify a tracked file (workspace fingerprint step 6 check)
printf "changed\n" > "$T14/foo.txt"
make_feature_list "$T14" "feat-fpstale" "20260731T-fpstale" '[]'
assert_passing_not_eligible "workspace modified → not eligible (step 6)" \
  "feat-fpstale" "$T14/feature_list.json" "$T14" "workspace_changed_since_verification"
rm -rf "$T14"

# ============================================================================
# Test 15: passed terminal but 0 effective required steps → not eligible (step 4)
#          (P0-3) Adversarial run: overall_result="passed" yet every required
#          command is in not_applicable_command_ids. Step 4 must judge on the
#          EFFECTIVE required set (required − not_applicable), so this run is
#          NOT eligible — same decision harness-verify makes (no_checks, exit 1).
# ============================================================================
echo ""
echo "=== Test 15: passed but 0 effective required → not eligible ==="
T15="$(mktemp -d)"
make_config "$T15"
# c1/c2 hand-crafted below with command:["x"]; declare both so step 5d passes.
write_test_config "$T15" '["c1","c2"]'
T15_CONFIG_SHA="sha256:$(sha256sum "$T15/.harness/config.json" | awk '{print $1}')"
T15_VERIFIED_FP="$(compute_workspace_fingerprint "$T15")"
# Hand-crafted log: required=["c1","c2"], terminal not_applicable=["c1","c2"].
# validate_run_log step 13 effective required = [] → structurally valid; but
# passing.sh step 4 must still refuse eligibility.
LOG="$T15/.harness/logs/runs/20260731T-zeroeff.ndjson"
jq -nc --arg rid "20260731T-zeroeff" --arg csha "$T15_CONFIG_SHA" --arg vfp "$T15_VERIFIED_FP" --arg root "$T15" \
  --argjson req '["c1","c2"]' \
  '{event:"run_started",schema_version:2,run_id:$rid,started_at:"2026-07-31T15:12:57Z",project_root:$root,vcs_revision:"null",vcs_revision_source:"none",workspace_fingerprint_initial:$vfp,config_sha256:$csha,required_command_ids:$req,capability_level:1,feature_id:"feat-zeroeff"}' \
  > "$LOG"
# Codex r6 (block ①): bind real log_artifact + log_sha256 (exit_code:0).
mkdir -p "$T15/.harness/logs/runs/20260731T-zeroeff"
for cid in c1 c2; do
  LOG15_REL=".harness/logs/runs/20260731T-zeroeff/${cid}.log"
  printf 'log for 20260731T-zeroeff/%s\n' "$cid" > "$T15/$LOG15_REL"
  LOG15_SHA="$(sha256sum "$T15/$LOG15_REL" | awk '{print $1}')"
  jq -nc --arg rid "20260731T-zeroeff" --arg cid "$cid" --arg la "$LOG15_REL" --arg lsh "$LOG15_SHA" \
    '{event:"command_completed",schema_version:2,run_id:$rid,command_id:$cid,command:["x"],command_origin:"configured",confirmation:"not_required",exit_code:0,started_at:"2026-07-31T15:13:00Z",duration_ms:50,log_artifact:$la,log_sha256:$lsh}' \
    >> "$LOG"
done
jq -nc --arg rid "20260731T-zeroeff" --arg vfp "$T15_VERIFIED_FP" \
  --argjson na '["c1","c2"]' \
  '{event:"run_completed",schema_version:2,run_id:$rid,completed_at:"2026-07-31T15:13:12Z",overall_result:"passed",workspace_fingerprint_verified:$vfp,planned_commands:2,executed_commands:2,passed_commands:2,failed_commands:0,skipped_commands:0,not_applicable_command_ids:$na}' \
  >> "$LOG"
make_feature_list "$T15" "feat-zeroeff" "20260731T-zeroeff" '[]'
assert_passing_not_eligible "passed terminal + 0 effective required → not eligible (step 4)" \
  "feat-zeroeff" "$T15/feature_list.json" "$T15" "no_required_steps"
rm -rf "$T15"

# ============================================================================
# Test 16: Git project + PASS run MISSING vcs_revision → not eligible (step 8)
#          (P0-14) A PASS run inside a git project MUST record its vcs_revision.
#          Empty/null revision = unverifiable → fail-closed. Non-git projects
#          (Test 13) are unaffected and stay eligible.
# ============================================================================
echo ""
echo "=== Test 16: git project + missing vcs_revision → not eligible ==="
T16="$(mktemp -d)"
make_config "$T16"
write_test_config "$T16" '["typecheck"]'
T16_CONFIG_SHA="sha256:$(sha256sum "$T16/.harness/config.json" | awk '{print $1}')"
git -C "$T16" init -q 2>/dev/null
git -C "$T16" config user.email "test@test"
git -C "$T16" config user.name  "test"
git -C "$T16" config commit.gpgsign false
git -C "$T16" add -A 2>/dev/null
git -C "$T16" commit -q -m "init" 2>/dev/null
T16_VERIFIED_FP="$(compute_workspace_fingerprint "$T16")"
# vcs_revision=null inside a git project → missing revision, fail-closed
make_run_log "$T16" "20260809T-norev" '["typecheck"]' "null" "$T16_CONFIG_SHA" \
  "$T16_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-norev"
make_feature_list "$T16" "feat-norev" "20260809T-norev" '[]'
assert_passing_not_eligible "git project + run missing vcs_revision → not eligible (step 8)" \
  "feat-norev" "$T16/feature_list.json" "$T16" "vcs_revision_missing"
rm -rf "$T16"

# ============================================================================
# Test 17 (Codex r4): cross-feature run pollution guard (step 2b)
#   Run's run_started.feature_id must equal the target feature_id.
#   A passing run for feat-A must NOT make feat-B passing, even if feat-B's
#   evidence_associations reference A's run_id.
# ============================================================================
echo ""
echo "=== Test 17: cross-feature run pollution guard (step 2b) ==="
T17="$(mktemp -d)"
make_config "$T17"
write_test_config "$T17" '["typecheck"]'
T17_CONFIG_SHA="sha256:$(sha256sum "$T17/.harness/config.json" | awk '{print $1}')"
T17_VERIFIED_FP="$(compute_workspace_fingerprint "$T17")"
# Run log records feature_id="feat-A" (a clean passing run for A).
make_run_log "$T17" "20260809T-xfeat" '["typecheck"]' "null" "$T17_CONFIG_SHA" \
  "$T17_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-A"
# But the feature_list mistakenly associates it with feat-B (cross-feature pollution).
make_feature_list "$T17" "feat-B" "20260809T-xfeat" '[]'
assert_passing_not_eligible "cross-feature run (feat-A log, feat-B target) → not eligible (step 2b)" \
  "feat-B" "$T17/feature_list.json" "$T17" "feature_id_mismatch"
rm -rf "$T17"

# ============================================================================
# Test 18 (Codex r4): run_started.feature_id empty → not eligible (step 2b)
# ============================================================================
echo ""
echo "=== Test 18: empty run_started.feature_id → not eligible (step 2b) ==="
T18="$(mktemp -d)"
make_config "$T18"
write_test_config "$T18" '["typecheck"]'
T18_CONFIG_SHA="sha256:$(sha256sum "$T18/.harness/config.json" | awk '{print $1}')"
T18_VERIFIED_FP="$(compute_workspace_fingerprint "$T18")"
# Build a valid run log via make_run_log, then strip feature_id.
make_run_log "$T18" "20260809T-nofid" '["typecheck"]' "null" "$T18_CONFIG_SHA" \
  "$T18_VERIFIED_FP" "passed" 1 1 0 0 '[]' "feat-X"
jq -c '.feature_id |= ""' "$T18/.harness/logs/runs/20260809T-nofid.ndjson" > "$T18/.harness/logs/runs/20260809T-nofid.ndjson.new" \
  && mv "$T18/.harness/logs/runs/20260809T-nofid.ndjson.new" "$T18/.harness/logs/runs/20260809T-nofid.ndjson"
# First line: replace with feature_id=""
head -1 "$T18/.harness/logs/runs/20260809T-nofid.ndjson" | \
  jq -c 'del(.feature_id)' > "$T18/.harness/logs/runs/20260809T-nofid.ndjson.l1"
sed -n '2,$p' "$T18/.harness/logs/runs/20260809T-nofid.ndjson" > "$T18/.harness/logs/runs/20260809T-nofid.ndjson.tail"
cat "$T18/.harness/logs/runs/20260809T-nofid.ndjson.l1" "$T18/.harness/logs/runs/20260809T-nofid.ndjson.tail" \
  > "$T18/.harness/logs/runs/20260809T-nofid.ndjson.new"
mv "$T18/.harness/logs/runs/20260809T-nofid.ndjson.new" "$T18/.harness/logs/runs/20260809T-nofid.ndjson"
rm -f "$T18/.harness/logs/runs/20260809T-nofid.ndjson.l1" "$T18/.harness/logs/runs/20260809T-nofid.ndjson.tail"
make_feature_list "$T18" "feat-X" "20260809T-nofid" '[]'
assert_passing_not_eligible "empty run_started.feature_id → not eligible (step 2b)" \
  "feat-X" "$T18/feature_list.json" "$T18" "feature_id_missing_in_run_started"
rm -rf "$T18"

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
