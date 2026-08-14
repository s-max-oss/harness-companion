#!/bin/bash
# test-verdict-artifact.sh — Append-only Reviewer verdict artifact test suite
#
# Exercises core/lib/verdict-artifact.sh (writer + validator) and the CLI
# core/harness-verdict.sh: 40/64-hex Git OID support, feature/phase schema
# split, PASS→non-empty verification run_id binding, valid-run check, attempt
# continuity (1..N), writer-side real-head_sha object check, and append-only
# semantics (attempt = previous + 1, never rewrite).
#
# P0-4 additions: a PASS verdict must bind a run that is (a) overall_result ==
# "passed", (b) FRESH on all three staleness axes (workspace fingerprint, config
# SHA-256, VCS revision) against the CURRENT project state, and (c) VCS/head-
# consistent (record head_sha == current git HEAD). A phase PASS must cover
# every feature of that phase.
# P0-11 additions: the authoritative phase feature set is read from
# .harness/PLAN.json (.phases[] .phase → .features[]) — never reverse-engineered
# from existing verdict files; fail-closed when the plan is missing/invalid.
# P0-12 additions: a FEATURE PASS binds a run whose run_started.feature_id equals
# the verdict's feature_id; every feature of a PASSING phase must have its own
# feature_id-matched passed/fresh run.
# Requires: bash, jq, git.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck source=../../core/lib/verdict-artifact.sh
source "$ROOT_DIR/core/lib/verdict-artifact.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

OID40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OID40B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OID64="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

# ---- helpers ----

check() {
  local name="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — expected $expected, got $got"
    FAILED=$((FAILED + 1))
  fi
}

# build_no_checks_run <dir> <run_id> [feature_id] — a VALID but NON-passing run
# log (overall_result "no_checks"): used to prove PASS cannot bind a non-passing
# run. When feature_id is given it is written into run_started (P0-12), so the
# run can pass the feature_id-binding check and fail on overall_result instead.
build_no_checks_run() {
  local d="$1" rid="$2" fid="${3:-}"
  mkdir -p "$d/.harness/logs/runs"
  local r1 r2
  r1="$(jq -cn --arg rid "$rid" --arg fid "${fid:-}" \
    '{schema_version:1, event:"run_started", run_id:$rid,
      started_at:"2026-08-08T00:00:00Z", project_root:"<test>",
      workspace_fingerprint_initial:"fp", config_sha256:"cfg",
      feature_id:($fid | if . == "" then null else . end),
      required_command_ids:[], capability_level:0}')"
  r2="$(jq -cn --arg rid "$rid" \
    '{schema_version:1, event:"run_completed", run_id:$rid,
      completed_at:"2026-08-08T00:01:00Z", overall_result:"no_checks",
      planned_commands:0, executed_commands:0, passed_commands:0,
      failed_commands:0, skipped_commands:0}')"
  printf '%s' "$r1" | jq -c . > "$d/.harness/logs/runs/${rid}.ndjson"
  printf '%s' "$r2" | jq -c . >> "$d/.harness/logs/runs/${rid}.ndjson"
}

# build_passed_run <dir> <run_id> [feature_id] — a REAL passed + fresh run log.
# The run is valid (schema_version 2, one required command completed, terminal
# overall_result "passed") and FRESH at validation time: config_sha256 matches
# the on-disk .harness/config.json, workspace_fingerprint_verified matches the
# current compute_workspace_fingerprint, and vcs_revision matches current git
# HEAD. As long as the caller does not touch the workspace/config/HEAD after
# this call, the run stays fresh. When feature_id is given it is written into
# run_started (P0-12) so a feature PASS can bind the run.
build_passed_run() {
  local d="$1" rid="$2" fid="${3:-}"
  mkdir -p "$d/.harness/logs/runs" "$d/.harness"
  cat > "$d/.harness/config.json" <<'CFG'
{"project_type":"generic","verification":{"commands":[{"id":"c1","command":["true"],"required_for_passing":true}]}}
CFG
  local csha vfp rev
  csha="$(_v_sha256_file "$d/.harness/config.json")"
  if git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    rev="$(git -C "$d" rev-parse --short=12 HEAD)"
  else
    rev="null"
  fi
  vfp="$(compute_workspace_fingerprint "$d")"
  local r1 r2 r3
  r1="$(jq -cn --arg rid "$rid" --arg csha "$csha" --arg vfp "$vfp" --arg rev "$rev" --arg root "$d" --arg fid "${fid:-}" \
    '{schema_version:2, event:"run_started", run_id:$rid,
      started_at:"2026-08-08T00:00:00Z", project_root:$root,
      workspace_fingerprint_initial:$vfp, config_sha256:$csha,
      vcs_revision:$rev, vcs_revision_source:"git",
      feature_id:($fid | if . == "" then null else . end),
      required_command_ids:["c1"], capability_level:1}')"
  r2="$(jq -cn --arg rid "$rid" \
    '{schema_version:2, event:"command_completed", run_id:$rid, command_id:"c1",
      command:["true"], command_origin:"configured", confirmation:"not_required",
      exit_code:0, started_at:"2026-08-08T00:00:01Z", duration_ms:1,
      log_artifact:"", log_sha256:null}')"
  r3="$(jq -cn --arg rid "$rid" --arg vfp "$vfp" \
    '{schema_version:2, event:"run_completed", run_id:$rid,
      completed_at:"2026-08-08T00:01:00Z", overall_result:"passed",
      workspace_fingerprint_verified:$vfp,
      planned_commands:1, executed_commands:1, passed_commands:1,
      failed_commands:0, skipped_commands:0}')"
  printf '%s' "$r1" | jq -c . > "$d/.harness/logs/runs/${rid}.ndjson"
  printf '%s' "$r2" | jq -c . >> "$d/.harness/logs/runs/${rid}.ndjson"
  printf '%s' "$r3" | jq -c . >> "$d/.harness/logs/runs/${rid}.ndjson"
}

# write_plan <dir> <phase> <features...> — writes .harness/PLAN.json declaring
# the AUTHORITATIVE feature set for the given phase (P0-11: phase coverage reads
# the plan, never the verdict files). Must be called BEFORE build_passed_run:
# PLAN.json is untracked and NOT fingerprint-excluded, so it must exist when the
# runs capture their workspace fingerprint.
write_plan() {
  local d="$1" ph="$2"
  shift 2
  local feats
  feats="$(printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0))')"
  mkdir -p "$d/.harness"
  jq -n --argjson ph "$ph" --argjson feats "$feats" \
    '{phases:[{phase:$ph, features:$feats}]}' > "$d/.harness/PLAN.json"
}

# ginit <dir> — git repo with one commit on master
ginit() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m A
  local cur
  cur="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ "$cur" != "master" ]; then
    git -C "$d" branch -m "$cur" master
  fi
}
gcommit() { git -C "$1" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m B; }

# feature_rec <dir> <fid> <phase> <verdict> <run_or_empty> <base> <head> [host]
feature_rec() {
  local d="$1" fid="$2" ph="$3" verdict="$4" run="$5" base="$6" head="$7" host="${8:-subagent}"
  jq -n --arg fid "$fid" --argjson ph "$ph" --arg v "$verdict" --arg r "$run" \
    --arg base "$base" --arg head "$head" --arg host "$host" \
    '{schema_version:1, kind:"feature", feature_id:$fid, phase:$ph, attempt:1,
      verdict:$v, base_sha:$base, head_sha:$head,
      run_id:($r | if . == "" then null else . end),
      reviewer_host:$host, checked:["spec-a"], reason:"test", recorded_at:"2026-08-08T00:00:00Z"}'
}

rec_valid() {
  local d="$1" rec="$2"
  verdict_validate_record "$d" "$rec" >/dev/null 2>&1
  echo "$?"
}

# rec_invalid_reason <dir> <record_json> — stderr of record validation (for
# asserting WHICH P0-4 axis rejected the PASS binding).
rec_invalid_reason() {
  local d="$1" rec="$2"
  verdict_validate_record "$d" "$rec" 2>&1 >/dev/null
}

# mk_feature_artifact <dir> <fid> <phase> <verdict> <run> <base> <head>
# Writes ONE per-feature verdict record (attempt 1) to
# .harness/reviews/feature/<fid>.jsonl.
mk_feature_artifact() {
  local d="$1" fid="$2" ph="$3" verdict="$4" run="$5" base="$6" head="$7"
  mkdir -p "$d/.harness/reviews/feature"
  local rec
  rec="$(feature_rec "$d" "$fid" "$ph" "$verdict" "$run" "$base" "$head")"
  printf '%s' "$rec" | jq -c . >> "$d/.harness/reviews/feature/${fid}.jsonl"
}

# ---- T1: valid feature PASS record (passed+fresh run, real head) → valid ----
D="$(mktemp -d "$TMPDIR/t1-XXXX")"
ginit "$D"
build_passed_run "$D" run-1 F-CONV-01
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$(git -C "$D" rev-parse HEAD)"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-1 "$BASE" "$HEAD")"
check "T1: passed+fresh feature PASS record validates" 0 "$(rec_valid "$D" "$REC")"

# ---- T2: 64-hex OIDs accepted (SHA-256-style OIDs; non-repo dir) → valid ----
D="$(mktemp -d "$TMPDIR/t2-XXXX")"
REC="$(feature_rec "$D" F-CONV-01 1 FAIL "" "$OID64" "$OID64")"
check "T2: 64-hex OIDs accepted" 0 "$(rec_valid "$D" "$REC")"

# ---- T3: base_sha not an OID → invalid ----
D="$(mktemp -d "$TMPDIR/t3-XXXX")"
REC="$(feature_rec "$D" F-CONV-01 1 FAIL "" "not-a-sha" "$OID40")"
check "T3: invalid base_sha rejected" 1 "$(rec_valid "$D" "$REC")"

# ---- T4: head_sha wrong length (30 hex) → invalid ----
D="$(mktemp -d "$TMPDIR/t4-XXXX")"
REC="$(feature_rec "$D" F-CONV-01 1 FAIL "" "$OID40" "abcdef0123456789abcdef0123456789")"
check "T4: head_sha wrong length rejected" 1 "$(rec_valid "$D" "$REC")"

# ---- T5: PASS without run_id → invalid ----
D="$(mktemp -d "$TMPDIR/t5-XXXX")"
REC="$(feature_rec "$D" F-CONV-01 1 PASS "" "$OID40" "$OID40B")"
check "T5: PASS without run_id rejected" 1 "$(rec_valid "$D" "$REC")"

# ---- T6: PASS with run_id that has no run log → invalid ----
D="$(mktemp -d "$TMPDIR/t6-XXXX")"
REC="$(feature_rec "$D" F-CONV-01 1 PASS missing-run "$OID40" "$OID40B")"
check "T6: PASS with nonexistent run_id rejected" 1 "$(rec_valid "$D" "$REC")"

# ---- T7: PASS with run_id whose log is INVALID → invalid ----
D="$(mktemp -d "$TMPDIR/t7-XXXX")"
mkdir -p "$D/.harness/logs/runs"
printf 'not json\n' > "$D/.harness/logs/runs/bad-run.ndjson"
REC="$(feature_rec "$D" F-CONV-01 1 PASS bad-run "$OID40" "$OID40B")"
check "T7: PASS with invalid run log rejected" 1 "$(rec_valid "$D" "$REC")"

# ---- T8: FAIL with null run_id → valid ----
D="$(mktemp -d "$TMPDIR/t8-XXXX")"
REC="$(feature_rec "$D" F-CONV-01 1 FAIL "" "$OID40" "$OID40B")"
check "T8: FAIL with null run_id valid" 0 "$(rec_valid "$D" "$REC")"

# ---- T9: verdict not in enum → invalid ----
D="$(mktemp -d "$TMPDIR/t9-XXXX")"
REC="$(feature_rec "$D" F-CONV-01 1 MAYBE "" "$OID40" "$OID40B")"
check "T9: non-enum verdict rejected" 1 "$(rec_valid "$D" "$REC")"

# ---- T10: phase record with feature_ids → valid; missing feature_ids → invalid ----
D="$(mktemp -d "$TMPDIR/t10-XXXX")"
ginit "$D"
build_passed_run "$D" run-10
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$(git -C "$D" rev-parse HEAD)"
PHREC="$(jq -n --arg run "run-10" --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:1, feature_ids:["F-CONV-01","F-CONV-02"],
    attempt:1, verdict:"PASS", base_sha:$b, head_sha:$h, run_id:$run,
    reviewer_host:"subagent", checked:["spec"], reason:"phase ok", recorded_at:"2026-08-08T00:00:00Z"}')"
check "T10a: phase record with feature_ids validates" 0 "$(rec_valid "$D" "$PHREC")"
PHREC_BAD="$(printf '%s' "$PHREC" | jq 'del(.feature_ids)')"
check "T10b: phase record missing feature_ids rejected" 1 "$(rec_valid "$D" "$PHREC_BAD")"

# ---- T11: feature record missing feature_id → invalid ----
D="$(mktemp -d "$TMPDIR/t11-XXXX")"
REC="$(feature_rec "$D" F-CONV-01 1 FAIL "" "$OID40" "$OID40B")"
REC_NOFID="$(printf '%s' "$REC" | jq 'del(.feature_id)')"
check "T11: feature record missing feature_id rejected" 1 "$(rec_valid "$D" "$REC_NOFID")"

# ---- T12: writer append-only — attempts 1,2,3 contiguous; validate passes ----
D="$(mktemp -d "$TMPDIR/t12-XXXX")"
ginit "$D"
gcommit "$D"
BASE="$(git -C "$D" rev-parse HEAD~1 2>/dev/null || git -C "$D" rev-parse HEAD)"
HEAD="$(git -C "$D" rev-parse HEAD)"
A1="$(verdict_append_record "$D" feature F-CONV-01 "$(feature_rec "$D" F-CONV-01 1 FAIL "" "$BASE" "$HEAD")")"
A2="$(verdict_append_record "$D" feature F-CONV-01 "$(feature_rec "$D" F-CONV-01 1 FAIL "" "$BASE" "$HEAD")")"
A3="$(verdict_append_record "$D" feature F-CONV-01 "$(feature_rec "$D" F-CONV-01 1 FAIL "" "$BASE" "$HEAD")")"
check "T12a: attempt 1 on first append" 1 "$(printf '%s' "$A1" | jq '.attempt')"
check "T12b: attempt 2 on second append" 2 "$(printf '%s' "$A2" | jq '.attempt')"
check "T12c: attempt 3 on third append" 3 "$(printf '%s' "$A3" | jq '.attempt')"
check "T12d: next_attempt is 4" 4 "$(verdict_next_attempt "$D" feature F-CONV-01)"
check "T12e: file validates (attempts 1..3)" true "$(verdict_validate_file "$D" feature F-CONV-01 | jq -r '.valid')"

# ---- T13: writer refuses fabricated head_sha (not a real git object) ----
D="$(mktemp -d "$TMPDIR/t13-XXXX")"
ginit "$D"
BASE="$(git -C "$D" rev-parse HEAD)"
build_passed_run "$D" run-13
FAB="$(feature_rec "$D" F-CONV-01 1 PASS run-13 "$BASE" "$OID40B")"
OUT="$(verdict_append_record "$D" feature F-CONV-01 "$FAB" 2>&1)"
check "T13: fabricated head_sha refused by writer" 1 "$([ -z "$(printf '%s' "$OUT" | jq -r '.verdict // empty' 2>/dev/null)" ] && echo 1 || echo 0)"
check "T13b: no record appended" yes "$([ ! -f "$D/.harness/reviews/feature/F-CONV-01.jsonl" ] && echo yes || echo no)"

# ---- T14: validate_file — attempt gap detected ----
D="$(mktemp -d "$TMPDIR/t14-XXXX")"
ginit "$D"
gcommit "$D"
BASE="$(git -C "$D" rev-parse HEAD~1 2>/dev/null || git -C "$D" rev-parse HEAD)"
HEAD="$(git -C "$D" rev-parse HEAD)"
verdict_append_record "$D" feature F-CONV-01 "$(feature_rec "$D" F-CONV-01 1 FAIL "" "$BASE" "$HEAD")" >/dev/null
verdict_append_record "$D" feature F-CONV-01 "$(feature_rec "$D" F-CONV-01 1 FAIL "" "$BASE" "$HEAD")" >/dev/null
sed -i '2s/"attempt":2/"attempt":9/' "$D/.harness/reviews/feature/F-CONV-01.jsonl"
RES="$(verdict_validate_file "$D" feature F-CONV-01)"
check "T14: attempt gap detected (line 2)" "attempt_gap_or_dup" "$(printf '%s' "$RES" | jq -r '.reason')"

# ---- T15: validate_file — missing artifact → invalid ----
D="$(mktemp -d "$TMPDIR/t15-XXXX")"
RES="$(verdict_validate_file "$D" feature F-CONV-99)"
check "T15: missing artifact invalid" "artifact_missing" "$(printf '%s' "$RES" | jq -r '.reason')"

# ---- T16: validate_file — kind mismatch in file ----
D="$(mktemp -d "$TMPDIR/t16-XXXX")"
ginit "$D"
gcommit "$D"
BASE="$(git -C "$D" rev-parse HEAD~1 2>/dev/null || git -C "$D" rev-parse HEAD)"
HEAD="$(git -C "$D" rev-parse HEAD)"
verdict_append_record "$D" feature F-CONV-01 "$(feature_rec "$D" F-CONV-01 1 FAIL "" "$BASE" "$HEAD")" >/dev/null
jq -n --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:1, feature_ids:["F-CONV-01"],
    attempt:2, verdict:"FAIL", base_sha:$b, head_sha:$h, run_id:null,
    reviewer_host:"subagent", checked:["s"], reason:"x", recorded_at:"2026-08-08T00:00:00Z"}' \
  | jq -c . >> "$D/.harness/reviews/feature/F-CONV-01.jsonl"
RES="$(verdict_validate_file "$D" feature F-CONV-01)"
check "T16: kind mismatch in file rejected" "kind_mismatch" "$(printf '%s' "$RES" | jq -r '.reason')"

# ---- T17: CLI end-to-end append + validate (passed+fresh run) ----
D="$(mktemp -d "$TMPDIR/t17-XXXX")"
ginit "$D"
gcommit "$D"
BASE="$(git -C "$D" rev-parse HEAD~1 2>/dev/null || git -C "$D" rev-parse HEAD)"
HEAD="$(git -C "$D" rev-parse HEAD)"
build_passed_run "$D" cli-run F-CONV-07
CLI_OUT="$(bash "$ROOT_DIR/core/harness-verdict.sh" append "$D" feature F-CONV-07 \
  --verdict PASS --run cli-run --base "$BASE" --head "$HEAD" --phase 1 \
  --host manual --checked spec-7,test-7 --reason "cli e2e")"
check "T17a: CLI append attempt 1" 1 "$(printf '%s' "$CLI_OUT" | jq '.attempt')"
check "T17b: CLI append host manual" "manual" "$(printf '%s' "$CLI_OUT" | jq -r '.reviewer_host')"
check "T17c: CLI validate valid" true "$(bash "$ROOT_DIR/core/harness-verdict.sh" validate "$D" feature F-CONV-07 | jq -r '.valid')"
check "T17d: CLI next attempt 2" 2 "$(bash "$ROOT_DIR/core/harness-verdict.sh" next "$D" feature F-CONV-07)"

# ---- T18: CLI refuses PASS without --run ----
D="$(mktemp -d "$TMPDIR/t18-XXXX")"
ginit "$D"
BASE="$(git -C "$D" rev-parse HEAD)"
OUT="$(bash "$ROOT_DIR/core/harness-verdict.sh" append "$D" feature F-CONV-01 \
  --verdict PASS --base "$BASE" --head "$OID40B" --phase 1 2>&1)"
check "T18: CLI PASS without --run refused" 1 "$([ -f "$D/.harness/reviews/feature/F-CONV-01.jsonl" ] && echo 0 || echo 1)"

# ---- P0-4: PASS run-binding negatives ----

# T19: PASS cannot bind a valid but NON-passing (no_checks) run
D="$(mktemp -d "$TMPDIR/t19-XXXX")"
ginit "$D"
build_no_checks_run "$D" run-nc F-CONV-01
HEAD="$(git -C "$D" rev-parse HEAD)"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-nc "$HEAD" "$HEAD")"
check "T19: PASS binding a no_checks run rejected" 1 "$(rec_valid "$D" "$REC")"
REASON="$(rec_invalid_reason "$D" "$REC")"
check "T19b: reason run_not_passed" yes "$(printf '%s' "$REASON" | grep -q 'run_not_passed' && echo yes || echo no)"

# T20: PASS binding a passed run but config CHANGED after the run → config_stale
D="$(mktemp -d "$TMPDIR/t20-XXXX")"
ginit "$D"
build_passed_run "$D" run-cfg F-CONV-01
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
printf '{"project_type":"generic","verification":{"commands":[]}}\n' > "$D/.harness/config.json"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-cfg "$BASE" "$HEAD")"
check "T20: PASS binding a config-stale run rejected" 1 "$(rec_valid "$D" "$REC")"
REASON="$(rec_invalid_reason "$D" "$REC")"
check "T20b: reason config_stale" yes "$(printf '%s' "$REASON" | grep -q 'config_stale' && echo yes || echo no)"

# T21: PASS binding a passed run but the WORKSPACE changed after the run →
# workspace_stale (only axis 1 trips: config + HEAD unchanged)
D="$(mktemp -d "$TMPDIR/t21-XXXX")"
ginit "$D"
printf 'tracked\n' > "$D/tracked.txt"
git -C "$D" add tracked.txt
git -C "$D" -c user.email=test@example.com -c user.name=test commit -q -m t
build_passed_run "$D" run-ws F-CONV-01
HEAD="$(git -C "$D" rev-parse HEAD)"
printf 'dirty\n' > "$D/tracked.txt"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-ws "$HEAD" "$HEAD")"
check "T21: PASS binding a workspace-stale run rejected" 1 "$(rec_valid "$D" "$REC")"
REASON="$(rec_invalid_reason "$D" "$REC")"
check "T21b: reason workspace_stale" yes "$(printf '%s' "$REASON" | grep -q 'workspace_stale' && echo yes || echo no)"

# T22: PASS binding a passed run but git HEAD ADVANCED after the run → vcs_stale
D="$(mktemp -d "$TMPDIR/t22-XXXX")"
ginit "$D"
build_passed_run "$D" run-vcs F-CONV-01
OLD_HEAD="$(git -C "$D" rev-parse HEAD)"
gcommit "$D"
NEW_HEAD="$(git -C "$D" rev-parse HEAD)"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-vcs "$OLD_HEAD" "$NEW_HEAD")"
check "T22: PASS binding a VCS-stale run rejected" 1 "$(rec_valid "$D" "$REC")"
REASON="$(rec_invalid_reason "$D" "$REC")"
check "T22b: reason vcs_stale" yes "$(printf '%s' "$REASON" | grep -q 'vcs_stale' && echo yes || echo no)"

# T23: PASS binding a fresh run but record head_sha != current HEAD → head_mismatch
D="$(mktemp -d "$TMPDIR/t23-XXXX")"
ginit "$D"
build_passed_run "$D" run-head F-CONV-01
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-head "$BASE" "$OID40B")"
check "T23: PASS with head_sha != current HEAD rejected" 1 "$(rec_valid "$D" "$REC")"
REASON="$(rec_invalid_reason "$D" "$REC")"
check "T23b: reason head_mismatch" yes "$(printf '%s' "$REASON" | grep -q 'head_mismatch' && echo yes || echo no)"

# ---- P0-4/P0-11/P0-12: phase PASS coverage (PLAN-authoritative) ----

# T24: phase PASS covers ALL PLAN features, each with its OWN passed/fresh
# feature-scoped run → valid
D="$(mktemp -d "$TMPDIR/t24-XXXX")"
ginit "$D"
write_plan "$D" 1 F-CONV-01 F-CONV-02
build_passed_run "$D" run-f1 F-CONV-01
build_passed_run "$D" run-f2 F-CONV-02
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
mk_feature_artifact "$D" F-CONV-01 1 PASS run-f1 "$BASE" "$HEAD"
mk_feature_artifact "$D" F-CONV-02 1 PASS run-f2 "$BASE" "$HEAD"
build_passed_run "$D" run-ph
mkdir -p "$D/.harness/reviews/phase"
jq -n --arg run "run-ph" --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:1, feature_ids:["F-CONV-01","F-CONV-02"],
    attempt:1, verdict:"PASS", base_sha:$b, head_sha:$h, run_id:$run,
    reviewer_host:"subagent", checked:["spec"], reason:"phase ok", recorded_at:"2026-08-08T00:00:00Z"}' \
  | jq -c . > "$D/.harness/reviews/phase/1.jsonl"
RES="$(verdict_validate_file "$D" phase 1)"
check "T24: phase PASS covering all PLAN features valid" true "$(printf '%s' "$RES" | jq -r '.valid')"

# T25: phase PASS OMITS a PLAN feature → coverage incomplete
D="$(mktemp -d "$TMPDIR/t25-XXXX")"
ginit "$D"
write_plan "$D" 1 F-CONV-01 F-CONV-02
build_passed_run "$D" run-f1 F-CONV-01
build_passed_run "$D" run-f2 F-CONV-02
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
mk_feature_artifact "$D" F-CONV-01 1 PASS run-f1 "$BASE" "$HEAD"
mk_feature_artifact "$D" F-CONV-02 1 PASS run-f2 "$BASE" "$HEAD"
build_passed_run "$D" run-ph
mkdir -p "$D/.harness/reviews/phase"
jq -n --arg run "run-ph" --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:1, feature_ids:["F-CONV-01"],
    attempt:1, verdict:"PASS", base_sha:$b, head_sha:$h, run_id:$run,
    reviewer_host:"subagent", checked:["spec"], reason:"phase ok", recorded_at:"2026-08-08T00:00:00Z"}' \
  | jq -c . > "$D/.harness/reviews/phase/1.jsonl"
RES="$(verdict_validate_file "$D" phase 1)"
check "T25: phase PASS omitting a PLAN feature rejected" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T25b: reason phase_coverage_failed" "phase_coverage_failed" "$(printf '%s' "$RES" | jq -r '.reason')"
check "T25c: detail incomplete" "phase_coverage_incomplete" "$(printf '%s' "$RES" | jq -r '.detail.reason')"

# T26: phase PASS declares a PHANTOM feature (not in the PLAN) → rejected
D="$(mktemp -d "$TMPDIR/t26-XXXX")"
ginit "$D"
write_plan "$D" 1 F-CONV-01
build_passed_run "$D" run-f1 F-CONV-01
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
mk_feature_artifact "$D" F-CONV-01 1 PASS run-f1 "$BASE" "$HEAD"
build_passed_run "$D" run-ph
mkdir -p "$D/.harness/reviews/phase"
jq -n --arg run "run-ph" --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:1, feature_ids:["F-CONV-01","F-PHANTOM"],
    attempt:1, verdict:"PASS", base_sha:$b, head_sha:$h, run_id:$run,
    reviewer_host:"subagent", checked:["spec"], reason:"phase ok", recorded_at:"2026-08-08T00:00:00Z"}' \
  | jq -c . > "$D/.harness/reviews/phase/1.jsonl"
RES="$(verdict_validate_file "$D" phase 1)"
check "T26: phase PASS with phantom feature rejected" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T26b: detail phantom" "phase_phantom_feature" "$(printf '%s' "$RES" | jq -r '.detail.reason')"

# T27: phase PASS covers all PLAN features but ONE feature's latest verdict is
# FAIL → phase_feature_not_passed
D="$(mktemp -d "$TMPDIR/t27-XXXX")"
ginit "$D"
write_plan "$D" 1 F-CONV-01 F-CONV-02
build_passed_run "$D" run-f1 F-CONV-01
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
mk_feature_artifact "$D" F-CONV-01 1 PASS run-f1 "$BASE" "$HEAD"
mk_feature_artifact "$D" F-CONV-02 1 FAIL "" "$BASE" "$HEAD"
build_passed_run "$D" run-ph
mkdir -p "$D/.harness/reviews/phase"
jq -n --arg run "run-ph" --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:1, feature_ids:["F-CONV-01","F-CONV-02"],
    attempt:1, verdict:"PASS", base_sha:$b, head_sha:$h, run_id:$run,
    reviewer_host:"subagent", checked:["spec"], reason:"phase ok", recorded_at:"2026-08-08T00:00:00Z"}' \
  | jq -c . > "$D/.harness/reviews/phase/1.jsonl"
RES="$(verdict_validate_file "$D" phase 1)"
check "T27: phase PASS with a FAIL feature rejected" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T27b: detail not_passed" "phase_feature_not_passed" "$(printf '%s' "$RES" | jq -r '.detail.reason')"
check "T27c: offending feature" "F-CONV-02" "$(printf '%s' "$RES" | jq -r '.detail.feature')"

# ---- P0-12: feature PASS run binding — run_started.feature_id == verdict id ----

# T28: feature PASS binding a run scoped to ANOTHER feature → run_feature_id_mismatch
D="$(mktemp -d "$TMPDIR/t28-XXXX")"
ginit "$D"
build_passed_run "$D" run-x F-CONV-02
HEAD="$(git -C "$D" rev-parse HEAD)"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-x "$HEAD" "$HEAD")"
check "T28: feature PASS binding another feature's run rejected" 1 "$(rec_valid "$D" "$REC")"
REASON="$(rec_invalid_reason "$D" "$REC")"
check "T28b: reason run_feature_id_mismatch" yes "$(printf '%s' "$REASON" | grep -q 'run_feature_id_mismatch' && echo yes || echo no)"

# T29: feature PASS binding a run with NO feature_id (unscoped run) → rejected
# (fail-closed: a feature PASS cannot be backed by a phase/unscoped run)
D="$(mktemp -d "$TMPDIR/t29-XXXX")"
ginit "$D"
build_passed_run "$D" run-nofid
HEAD="$(git -C "$D" rev-parse HEAD)"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-nofid "$HEAD" "$HEAD")"
check "T29: feature PASS binding an unscoped run rejected" 1 "$(rec_valid "$D" "$REC")"
REASON="$(rec_invalid_reason "$D" "$REC")"
check "T29b: reason run_feature_id_mismatch" yes "$(printf '%s' "$REASON" | grep -q 'run_feature_id_mismatch' && echo yes || echo no)"

# ---- P0-11: phase coverage is PLAN-authoritative ----

# T30: phase PASS without a PLAN.json → fail-closed plan_missing
D="$(mktemp -d "$TMPDIR/t30-XXXX")"
ginit "$D"
build_passed_run "$D" run-f1 F-CONV-01
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
mk_feature_artifact "$D" F-CONV-01 1 PASS run-f1 "$BASE" "$HEAD"
build_passed_run "$D" run-ph
mkdir -p "$D/.harness/reviews/phase"
jq -n --arg run "run-ph" --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:1, feature_ids:["F-CONV-01"],
    attempt:1, verdict:"PASS", base_sha:$b, head_sha:$h, run_id:$run,
    reviewer_host:"subagent", checked:["spec"], reason:"phase ok", recorded_at:"2026-08-08T00:00:00Z"}' \
  | jq -c . > "$D/.harness/reviews/phase/1.jsonl"
RES="$(verdict_validate_file "$D" phase 1)"
check "T30: phase PASS without PLAN.json rejected" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T30b: detail plan_missing" "plan_missing" "$(printf '%s' "$RES" | jq -r '.detail.reason')"

# T31: phase PASS for a phase NOT in PLAN.json → phase_unknown_or_no_features
D="$(mktemp -d "$TMPDIR/t31-XXXX")"
ginit "$D"
write_plan "$D" 1 F-CONV-01
build_passed_run "$D" run-f1 F-CONV-01
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
mk_feature_artifact "$D" F-CONV-01 1 PASS run-f1 "$BASE" "$HEAD"
build_passed_run "$D" run-ph
mkdir -p "$D/.harness/reviews/phase"
jq -n --arg run "run-ph" --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:2, feature_ids:["F-CONV-01"],
    attempt:1, verdict:"PASS", base_sha:$b, head_sha:$h, run_id:$run,
    reviewer_host:"subagent", checked:["spec"], reason:"phase ok", recorded_at:"2026-08-08T00:00:00Z"}' \
  | jq -c . > "$D/.harness/reviews/phase/2.jsonl"
RES="$(verdict_validate_file "$D" phase 2)"
check "T31: phase PASS for unknown phase rejected" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T31b: detail phase_unknown_or_no_features" "phase_unknown_or_no_features" "$(printf '%s' "$RES" | jq -r '.detail.reason')"

# T32: the coverage set comes from PLAN.json, NOT the verdict files — a PASS
# artifact for a feature NOT in the phase does not change the required set, and
# declaring exactly the PLAN set is valid (the non-PLAN artifact is ignored)
D="$(mktemp -d "$TMPDIR/t32-XXXX")"
ginit "$D"
write_plan "$D" 1 F-CONV-01
build_passed_run "$D" run-f1 F-CONV-01
build_passed_run "$D" run-extra F-CONV-09
BASE="$(git -C "$D" rev-parse HEAD)"
HEAD="$BASE"
mk_feature_artifact "$D" F-CONV-01 1 PASS run-f1 "$BASE" "$HEAD"
mk_feature_artifact "$D" F-CONV-09 1 PASS run-extra "$BASE" "$HEAD"
build_passed_run "$D" run-ph
mkdir -p "$D/.harness/reviews/phase"
jq -n --arg run "run-ph" --arg b "$BASE" --arg h "$HEAD" \
  '{schema_version:1, kind:"phase", phase:1, feature_ids:["F-CONV-01"],
    attempt:1, verdict:"PASS", base_sha:$b, head_sha:$h, run_id:$run,
    reviewer_host:"subagent", checked:["spec"], reason:"phase ok", recorded_at:"2026-08-08T00:00:00Z"}' \
  | jq -c . > "$D/.harness/reviews/phase/1.jsonl"
RES="$(verdict_validate_file "$D" phase 1)"
check "T32: non-PLAN PASS artifact ignored (PLAN authoritative)" true "$(printf '%s' "$RES" | jq -r '.valid')"

# ---- P0-14: PASS binding a run with NO vcs_revision in a git project ----

# T33: a real passed+fresh run is built, then vcs_revision is STRIPPED from
# run_started. The run stays canonical (the run-log validator does not require
# vcs_revision) but in a GIT project the missing revision is unverifiable →
# vcs_revision_missing (fail-closed), never a silent skip.
#
# The rewrite MUST use `jq -c` + `tr -d '\r'`: without `-c` the native-Windows
# jq pretty-prints the `if/then/else` output (each record split across physical
# lines, CRLF separators) — which is not NDJSON and fails as `unparseable_log`
# BEFORE the three-axis check, masking the P0-14 reason this test asserts.
D="$(mktemp -d "$TMPDIR/t33-XXXX")"
ginit "$D"
build_passed_run "$D" run-norev F-CONV-01
jq -c 'if .event == "run_started" then del(.vcs_revision) else . end' \
  "$D/.harness/logs/runs/run-norev.ndjson" | tr -d '\r' \
  > "$D/.harness/logs/runs/run-norev.tmp"
mv "$D/.harness/logs/runs/run-norev.tmp" "$D/.harness/logs/runs/run-norev.ndjson"
HEAD="$(git -C "$D" rev-parse HEAD)"
REC="$(feature_rec "$D" F-CONV-01 1 PASS run-norev "$HEAD" "$HEAD")"
check "T33: git-project PASS binding a run with no vcs_revision rejected" 1 "$(rec_valid "$D" "$REC")"
REASON="$(rec_invalid_reason "$D" "$REC")"
check "T33b: reason vcs_revision_missing" yes "$(printf '%s' "$REASON" | grep -q 'vcs_revision_missing' && echo yes || echo no)"

echo ""
echo "Verdict-Artifact Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
