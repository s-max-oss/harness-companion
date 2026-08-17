#!/bin/bash
# verdict-artifact.sh — Append-only Reviewer verdict artifact (writer + validator)
#
# Reviewer verdicts are persisted as append-only evidence at:
#   .harness/reviews/feature/<feature_id>.jsonl     (per-feature ORIGINAL evidence)
#   .harness/reviews/phase/<phase>.jsonl            (per-phase cumulative reviews)
#   .harness/reviews/maintenance/<feature_id>.jsonl (repository/maintenance)
# Feature records and phase records have SEPARATE schemas (kind split) — a phase
# cumulative review NEVER overwrites per-feature verdict records. A maintenance
# record (kind "maintenance") covers features OUTSIDE the PLAN phases (e.g.
# F-MAINT-01) and is never used for PLAN phase coverage.
#
# Append-only: a re-review (fix_and_resubmit) appends ONE new record with
# attempt = previous attempt + 1; existing records are never rewritten,
# truncated, or deleted. The writer computes the next attempt; the validator
# independently verifies attempt continuity (1, 2, ..., N with no gaps/dups).
#
# Validation invariants (fail-closed, mirroring validate-run-log.sh style):
#   - schema_version == 1
#   - kind == "feature" | "phase" | "maintenance"   (kind schema SPLIT)
#   - feature records: feature_id matching ^[A-Z][A-Z0-9_-]*$, phase integer 1..5
#   - phase records:    phase integer 1..5, feature_ids non-empty array of strings
#   - maintenance records: feature_id matching ^[A-Z][A-Z0-9_-]*$; NO phase
#     (not bound to a PLAN.json phase — see "maintenance" kind below)
#   - attempt integer >= 1
#   - verdict == "PASS" | "FAIL" | "BLOCKER"
#   - base_sha / head_sha are Git OIDs: 40-hex (SHA-1) OR 64-hex (SHA-256)
#   - PASS MUST bind a non-empty verification run_id
#   - run_id (when present) must reference an EXISTING, VALID run log
#     (validate_run_log passes on .harness/logs/runs/<run_id>.ndjson)
#   - P0-4 PASS binding (feature AND phase records): the bound run must be
#       (a) overall_result == "passed"          (not no_checks / failed),
#       (b) FRESH on all three staleness axes — workspace fingerprint,
#           config SHA-256, and VCS revision all match the CURRENT project
#           state, and
#       (c) VCS/head-consistent — the record's head_sha equals the current
#           git HEAD (and the run's vcs_revision equals current HEAD).
#     Fail-closed: if any axis cannot be verified the binding is rejected.
#   - P0-4 phase PASS coverage (FILE-level, phase kind): a phase record with
#     verdict == PASS must cover EVERY feature of that phase — its feature_ids
#     must equal the set of features whose per-feature verdict artifact's latest
#     record has phase == <this phase>, and every covered feature's latest
#     verdict must itself be PASS.
#   - reviewer_host == "subagent" | "manual"
#   - checked: array of strings; reason: string; recorded_at: string
#   - FILE-level: attempts are exactly 1..N in order; all records share the same
#     kind and the same feature_id (feature) / phase (phase) as the file's id
#
# The WRITER additionally enforces that head_sha resolves to a real git object
# when the project is a git repository (no fabricated heads).
#
# Usage:
#   source verdict-artifact.sh
#   verdict_validate_file <project_dir> <kind> <id>        # JSON result, exit 0/1
#   verdict_validate_record <project_dir> <record_json>    # exit 0/1 (stderr)
#   verdict_next_attempt  <project_dir> <kind> <id>        # prints next attempt
#   verdict_append_record <project_dir> <kind> <id> <json> # appends, prints record
#
# Requires bash, jq; git only for the writer's head_sha object check. Sources
# validate-run-log.sh (same directory) for the "valid run" check, and
# workspace-fingerprint.sh for the P0-4 freshness check.

# shellcheck source=validate-run-log.sh
. "$(dirname "${BASH_SOURCE[0]}")/validate-run-log.sh"
# shellcheck source=workspace-fingerprint.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace-fingerprint.sh"
# Codex r7: register appended verdicts in the runtime-manifest byte-binding
# registry (writer-side registration; the DWM gate enforces append-only).
if ! type runtime_register >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "$(dirname "${BASH_SOURCE[0]}")/runtime-manifest.sh" 2>/dev/null || true
fi

# ---- helpers ---------------------------------------------------------------

# _v_artifact_path <project_dir> <kind> <id> → path (empty on unknown kind)
_v_artifact_path() {
  local project_dir="$1" kind="$2" id="$3"
  case "$kind" in
    feature)     printf '%s/.harness/reviews/feature/%s.jsonl' "$project_dir" "$id" ;;
    phase)       printf '%s/.harness/reviews/phase/%s.jsonl' "$project_dir" "$id" ;;
    maintenance) printf '%s/.harness/reviews/maintenance/%s.jsonl' "$project_dir" "$id" ;;
    *)           printf '' ;;
  esac
}

# _v_is_oid <sha> — 40-hex (SHA-1) or 64-hex (SHA-256) Git OID
_v_is_oid() {
  printf '%s' "$1" | grep -qE '^[0-9a-f]{40}$|^[0-9a-f]{64}$'
}

# _v_sha256_file <file> — canonical SHA-256 with sha256: prefix, or empty.
_v_sha256_file() {
  local f="$1" h
  if command -v sha256sum >/dev/null 2>&1; then
    h="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    h="$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
  else
    return 1
  fi
  [ -n "$h" ] && printf 'sha256:%s' "$h"
}

# _v_require_passed_fresh_run <project_dir> <run_id> <head_sha> [expect_fid]
# P0-4 PASS binding. A Reviewer PASS verdict must be backed by a run that is
#   (a) overall_result == "passed" (a no_checks / failed run is NOT passing),
#   (b) FRESH on all three staleness axes — workspace fingerprint, config
#       SHA-256, and VCS revision all match the CURRENT project state, and
#   (c) VCS/head-consistent — the record's head_sha equals the current git HEAD.
# P0-12: when expect_fid is non-empty (feature verdicts), the run's
# run_started.feature_id MUST equal the verdict's feature_id — a feature PASS
# cannot be backed by another feature's run.
# Fail-closed: if any axis cannot be computed the binding is rejected. The
# reason string is printed on stderr; exit 0/1.
_v_require_passed_fresh_run() {
  local project_dir="$1" run_id="$2" head_sha="$3" expect_fid="${4:-}" fresh="${5:-1}"
  local log_path="$project_dir/.harness/logs/runs/${run_id}.ndjson"
  if [ ! -f "$log_path" ]; then
    echo "run_not_found" >&2
    return 1
  fi
  local validation
  if ! validation="$(validate_run_log "$run_id" "$project_dir" 2>/dev/null)"; then
    echo "run_invalid" >&2
    return 1
  fi
  local run_started terminal
  run_started="$(printf '%s' "$validation" | jq -c '.run_started')"
  terminal="$(printf '%s' "$validation" | jq -c '.terminal')"
  [ -n "$run_started" ] && [ "$run_started" != "null" ] || { echo "run_started_missing" >&2; return 1; }
  [ -n "$terminal" ] && [ "$terminal" != "null" ] || { echo "run_completed_missing" >&2; return 1; }

  # (P0-12) a FEATURE verdict binds a run that belongs to THAT feature
  if [ -n "$expect_fid" ]; then
    local run_fid
    run_fid="$(printf '%s' "$run_started" | jq -r '.feature_id // empty')"
    if [ -z "$run_fid" ] || [ "$run_fid" != "$expect_fid" ]; then
      echo "run_feature_id_mismatch: run $run_id feature_id '${run_fid:-}' != verdict feature_id '$expect_fid'" >&2
      return 1
    fi
  fi

  # (a) the bound run must have PASSED
  local overall
  overall="$(printf '%s' "$terminal" | jq -r '.overall_result // empty')"
  if [ "$overall" != "passed" ]; then
    echo "run_not_passed: run $run_id has overall_result=$overall (expected passed)" >&2
    return 1
  fi

  # (b) Axis 1 — workspace fingerprint (matches passing.sh step 6). FRESHNESS
  # only: a historical attempt is validated for authenticity (its run passed,
  # its base/head are real and ancestral) but is NOT required to match the
  # CURRENT fingerprint — only the latest PASS binds the current state.
  if [ "$fresh" = "1" ]; then
    local verified_fp current_fp
    verified_fp="$(printf '%s' "$terminal" | jq -r '.workspace_fingerprint_verified // empty')"
    if [ -z "$verified_fp" ] || [ "$verified_fp" = "null" ]; then
      echo "run_fingerprint_missing: run $run_id has no workspace_fingerprint_verified" >&2
      return 1
    fi
    current_fp="$(compute_workspace_fingerprint "$project_dir" 2>/dev/null)" || {
      echo "workspace_fingerprint_compute_failed" >&2
      return 1
    }
    [ -n "$current_fp" ] || { echo "workspace_fingerprint_compute_failed" >&2; return 1; }
    if [ "$current_fp" != "$verified_fp" ]; then
      echo "workspace_stale: run $run_id verified '$verified_fp', current '$current_fp'" >&2
      return 1
    fi
  fi

  # (c) Axis 2 — config SHA-256 (matches passing.sh step 7). FRESHNESS only.
  if [ "$fresh" = "1" ]; then
    local stored_cfg current_cfg
    stored_cfg="$(printf '%s' "$run_started" | jq -r '.config_sha256 // empty')"
    if [ -z "$stored_cfg" ] || [ "$stored_cfg" = "null" ]; then
      echo "run_config_sha_missing: run $run_id has no config_sha256" >&2
      return 1
    fi
    current_cfg="$(_v_sha256_file "$project_dir/.harness/config.json")"
    if [ -z "$current_cfg" ]; then
      echo "config_sha_compute_failed" >&2
      return 1
    fi
    if [ "$stored_cfg" != "$current_cfg" ]; then
      echo "config_stale: run $run_id stored '$stored_cfg', current '$current_cfg'" >&2
      return 1
    fi
  fi

  # (d) Axis 3 — VCS revision (matches passing.sh step 8). P0-14: a PASS run in
  # a GIT project must record its vcs_revision — empty/null revision in a git
  # project is vcs_revision_missing (fail-closed), never a silent skip. Non-git
  # projects are unaffected (there is no revision to record). The recorded
  # revision is required to be non-empty for authenticity ALWAYS; it is required
  # to equal CURRENT HEAD only under freshness.
  local stored_rev current_rev
  stored_rev="$(printf '%s' "$run_started" | jq -r '.vcs_revision // empty')"
  if [ -z "$stored_rev" ] || [ "$stored_rev" = "null" ]; then
    if git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
      echo "vcs_revision_missing: run $run_id in a git project records no vcs_revision" >&2
      return 1
    fi
  elif [ "$fresh" = "1" ]; then
    current_rev="$(git -C "$project_dir" rev-parse --short=12 HEAD 2>/dev/null)" || {
      echo "vcs_check_failed" >&2
      return 1
    }
    if [ "$stored_rev" != "$current_rev" ]; then
      echo "vcs_stale: run $run_id stored '$stored_rev', current HEAD '$current_rev'" >&2
      return 1
    fi
  fi

  # (e) head-consistent: head_sha == current git HEAD (full OID). FRESHNESS only.
  # (A historical record's head_sha is a real, ancestor-verified OID via
  # verdict_validate_record; it is only required to equal CURRENT HEAD for the
  # latest PASS.)
  if [ "$fresh" = "1" ] && git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    local cur_head
    cur_head="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)" || { echo "vcs_check_failed" >&2; return 1; }
    if [ "$head_sha" != "$cur_head" ]; then
      echo "head_mismatch: record head_sha '$head_sha' != current HEAD '$cur_head'" >&2
      return 1
    fi
  fi
  return 0
}

# _v_phase_coverage <project_dir> <phase_id> <phase_pass_record>
# P0-4/P0-11 phase PASS coverage. The AUTHORITATIVE feature set for a phase is
# read from .harness/PLAN.json (.phases[] .phase == <phase_id> → .features[]) —
# it is NEVER reverse-engineered from existing verdict artifacts. A phase PASS
# must declare feature_ids EQUAL to that set (no omissions, no phantoms) and
# every feature of the phase must have its OWN latest verdict == PASS backed by
# a valid, fresh, feature_id-matched run (verdict_validate_record → P0-12).
# Fail-closed if PLAN.json is missing/unparseable or the phase is unknown.
# Prints a JSON diagnostic; exit 0/1.
_v_phase_coverage() {
  local project_dir="$1" phase_id="$2" phase_rec="$3"
  local declared
  declared="$(printf '%s' "$phase_rec" | jq -c '.feature_ids')"
  # P0-11: authoritative feature set from PLAN.json — never inferred from the
  # existing verdict files.
  local plan="$project_dir/.harness/PLAN.json"
  if [ ! -f "$plan" ]; then
    jq -n --arg path "$plan" '{valid:false, reason:"plan_missing", path:$path}'
    return 1
  fi
  local phase_features_json
  phase_features_json="$(jq -c --arg ph "$phase_id" '[.phases[] | select((.phase | tostring) == $ph) | .features[]?]' "$plan" 2>/dev/null)"
  if [ -z "$phase_features_json" ] || [ "$phase_features_json" = "null" ] || [ "$phase_features_json" = "[]" ]; then
    jq -n --arg ph "$phase_id" '{valid:false, reason:"phase_unknown_or_no_features", phase:$ph}'
    return 1
  fi
  local declared_sorted features_sorted
  declared_sorted="$(printf '%s' "$declared" | jq 'sort')"
  features_sorted="$(printf '%s' "$phase_features_json" | jq 'sort')"
  if [ "$declared_sorted" != "$features_sorted" ]; then
    local phantom omitted
    phantom="$(jq -nc --argjson d "$declared" --argjson f "$phase_features_json" \
      '($d - $f) as $p | if ($p|length)>0 then $p else empty end')"
    omitted="$(jq -nc --argjson d "$declared" --argjson f "$phase_features_json" \
      '($f - $d) as $o | if ($o|length)>0 then $o else empty end')"
    if [ -n "$phantom" ] && [ "$phantom" != "null" ] && [ "$phantom" != "[]" ]; then
      jq -n --argjson phantom "$phantom" '{valid:false, reason:"phase_phantom_feature", phantom:$phantom}'
      return 1
    fi
    jq -n --argjson omitted "$omitted" '{valid:false, reason:"phase_coverage_incomplete", omitted:$omitted}'
    return 1
  fi
  # every feature OF THE PHASE must have its OWN latest verdict == PASS backed
  # by a valid, fresh, feature_id-matched run (verdict_validate_record → P0-12).
  # NOTE: tr -d '\r' — native-Windows jq emits CRLF on multi-line output, and
  # after command substitution + word splitting the FIRST token keeps its CR
  # (MSYS strips only a trailing CRLF). A bare `for fid in $(jq -r '.[]')`
  # would turn the first feature into "F-CONV-01\r" and report a spurious
  # phase_feature_missing_artifact. Same workaround as make_run_log's
  # "Strip CR (Windows Git Bash adds \r to for-loop tokens)".
  local fid
  for fid in $(printf '%s' "$phase_features_json" | jq -r '.[]' | tr -d '\r'); do
    local last_rec fverdict
    last_rec="$(grep -v '^[[:space:]]*$' "$project_dir/.harness/reviews/feature/${fid}.jsonl" 2>/dev/null | tail -1)"
    [ -n "$last_rec" ] || {
      jq -n --arg fid "$fid" '{valid:false, reason:"phase_feature_missing_artifact", feature:$fid}'
      return 1
    }
    fverdict="$(printf '%s' "$last_rec" | jq -r '.verdict // ""' 2>/dev/null)"
    if [ "$fverdict" != "PASS" ]; then
      jq -n --arg fid "$fid" --arg verdict "$fverdict" \
        '{valid:false, reason:"phase_feature_not_passed", feature:$fid, feature_verdict:$verdict}'
      return 1
    fi
    if ! verdict_validate_record "$project_dir" "$last_rec" >/dev/null 2>&1; then
      jq -n --arg fid "$fid" '{valid:false, reason:"phase_feature_invalid_record", feature:$fid}'
      return 1
    fi
  done
  jq -n --argjson features "$phase_features_json" '{valid:true, phase_coverage:$features}'
  return 0
}

# ---- verdict_validate_record ----------------------------------------------
# Validates ONE verdict record against the (kind-split) schema. stderr on
# failure; exit 0/1.
verdict_validate_record() {
  local project_dir="$1"
  local rec="$2"
  # fresh=1 (default): a PASS record must bind the CURRENT head/run/fingerprint.
  # fresh=0: a HISTORICAL attempt is validated for authenticity only — its
  # recorded base/head must be real and ancestral and its run must exist and
  # validate, but it is NOT required to match the current state (only the
  # latest PASS binds current HEAD).
  local fresh="${3:-1}"

  if ! printf '%s' "$rec" | jq -e '.schema_version == 1' >/dev/null 2>&1; then
    echo "verdict: record schema_version != 1" >&2
    return 1
  fi
  local kind
  kind="$(printf '%s' "$rec" | jq -r '.kind // empty')"
  case "$kind" in
    feature|phase|maintenance) ;;
    *) echo "verdict: kind must be feature|phase|maintenance" >&2; return 1 ;;
  esac
  # phase 1..5 is a feature/phase invariant. The maintenance kind is a
  # repository-level verdict (F-MAINT-01 and future maintenance features) NOT
  # bound to any PLAN.json phase, so it carries no `phase` field and is never
  # subject to PLAN phase membership or phase coverage.
  if [ "$kind" = "feature" ] || [ "$kind" = "phase" ]; then
    if ! printf '%s' "$rec" | jq -e '(.phase | type) == "number" and .phase >= 1 and .phase <= 5' >/dev/null 2>&1; then
      echo "verdict: phase must be integer 1..5" >&2
      return 1
    fi
  fi
  if [ "$kind" = "feature" ] || [ "$kind" = "maintenance" ]; then
    local fid
    fid="$(printf '%s' "$rec" | jq -r '.feature_id // empty')"
    if ! printf '%s' "$fid" | grep -qE '^[A-Z][A-Z0-9_-]*$'; then
      echo "verdict: $kind record requires valid feature_id" >&2
      return 1
    fi
    # The PLAN.json phase-membership + phase-match checks below apply ONLY to
    # `feature` records. A `maintenance` record (F-MAINT-01 and future
    # maintenance features) is a repository-level verdict NOT bound to any
    # PLAN.json phase — it has no `phase` field and is never subject to phase
    # coverage (see verdict_validate_file / _v_phase_coverage).
    if [ "$kind" = "feature" ]; then
    # Codex r4: a feature verdict's `phase` MUST equal the feature's declared
    # phase in .harness/PLAN.json (no `phase` reassignment out of band). The
    # record's own `phase` is a per-record label; the AUTHORITATIVE source of
    # which phase a feature belongs to is PLAN.json's `.phases[].features[]`.
    # Without this check, a feature declared in phase 1 can be re-reviewed as
    # phase 5 and the validator will not notice — review-state machine stays
    # coherent only when the record's phase matches the PLAN phase.
    # Fail-closed: a missing/unparseable PLAN is rejected (no implicit allow);
    # a feature unknown to PLAN is rejected (no fallback); a phase mismatch
    # is rejected (no coercion).
    local plan="$project_dir/.harness/PLAN.json"
    local rec_phase
    rec_phase="$(printf '%s' "$rec" | jq -r '.phase')"
    if [ ! -f "$plan" ]; then
      echo "verdict: PLAN.json missing — cannot verify feature_id belongs to declared phase" >&2
      return 1
    fi
    if [ -L "$plan" ]; then
      echo "verdict: PLAN.json is a symlink — refusing (must be a regular file)" >&2
      return 1
    fi
    if ! jq -e 'type == "object" and (.phases | type) == "array"' "$plan" >/dev/null 2>&1; then
      echo "verdict: PLAN.json missing required .phases array" >&2
      return 1
    fi
    local declared_phase
    declared_phase="$(jq -r --arg fid "$fid" '[.phases[] | select((.features // []) | index($fid)) | .phase] | first // empty' "$plan" 2>/dev/null)"
    if [ -z "$declared_phase" ] || [ "$declared_phase" = "null" ]; then
      echo "verdict: feature_id '$fid' is not declared in any PLAN.json phase" >&2
      return 1
    fi
    if [ "$rec_phase" != "$declared_phase" ]; then
      echo "verdict: record phase=$rec_phase does not match PLAN-declared phase=$declared_phase for feature '$fid'" >&2
      return 1
    fi
    fi
  elif [ "$kind" = "phase" ]; then
    if ! printf '%s' "$rec" | jq -e '(.feature_ids | type) == "array" and (.feature_ids | length) > 0 and ([.feature_ids[]? | type] | all(. == "string"))' >/dev/null 2>&1; then
      echo "verdict: phase record requires non-empty feature_ids array of strings" >&2
      return 1
    fi
    # Codex r4: a phase record's `feature_ids` set must be a SUBSET of the
    # features declared in PLAN.json for the record's `phase`. PLAN.json
    # is the AUTHORITATIVE source of which features belong to which phase;
    # a verdict cannot claim a feature is in this phase when PLAN says it
    # belongs to another (phantom-phase-feature) — even though
    # _v_phase_coverage enforces equality on PASS, this rule prevents
    # phantom features from appearing in BLOCKER / FAIL / earlier attempts.
    # Fail-closed: a feature_ids entry not in PLAN is rejected.
    local plan="$project_dir/.harness/PLAN.json"
    if [ ! -f "$plan" ]; then
      echo "verdict: PLAN.json missing — cannot verify phase feature_ids belong to declared phase" >&2
      return 1
    fi
    if [ -L "$plan" ]; then
      echo "verdict: PLAN.json is a symlink — refusing (must be a regular file)" >&2
      return 1
    fi
    if ! jq -e 'type == "object" and (.phases | type) == "array"' "$plan" >/dev/null 2>&1; then
      echo "verdict: PLAN.json missing required .phases array" >&2
      return 1
    fi
    local rec_phase
    rec_phase="$(printf '%s' "$rec" | jq -r '.phase')"
    local phase_features_json
    phase_features_json="$(jq -c --argjson ph "$rec_phase" '[.phases[] | select((.phase | tostring) == ($ph | tostring)) | .features[]?] // empty | .' "$plan" 2>/dev/null)"
    if [ -z "$phase_features_json" ] || [ "$phase_features_json" = "null" ] || [ "$phase_features_json" = "[]" ]; then
      echo "verdict: phase=$rec_phase is unknown in PLAN.json" >&2
      return 1
    fi
    local phantom_in_phase
    phantom_in_phase="$(jq -nc --argjson rec "$(printf '%s' "$rec" | jq -c '.feature_ids')" --argjson plan "$phase_features_json" \
      '($rec - $plan) as $p | if ($p|length)>0 then $p else empty end' 2>/dev/null)"
    if [ -n "$phantom_in_phase" ] && [ "$phantom_in_phase" != "null" ] && [ "$phantom_in_phase" != "[]" ]; then
      echo "verdict: phase record claims feature_ids not in PLAN.json for phase=$rec_phase: $phantom_in_phase" >&2
      return 1
    fi
  fi
  if ! printf '%s' "$rec" | jq -e '(.attempt | type) == "number" and .attempt >= 1' >/dev/null 2>&1; then
    echo "verdict: attempt must be integer >= 1" >&2
    return 1
  fi
  local verdict
  verdict="$(printf '%s' "$rec" | jq -r '.verdict // empty')"
  case "$verdict" in
    PASS|FAIL|BLOCKER) ;;
    *) echo "verdict: verdict must be PASS|FAIL|BLOCKER" >&2; return 1 ;;
  esac
  # OIDs: 40-hex or 64-hex (support both SHA-1 and SHA-256 repos)
  local base head
  base="$(printf '%s' "$rec" | jq -r '.base_sha // empty')"
  head="$(printf '%s' "$rec" | jq -r '.head_sha // empty')"
  if ! _v_is_oid "$base"; then
    echo "verdict: base_sha must be a 40- or 64-hex Git OID" >&2
    return 1
  fi
  if ! _v_is_oid "$head"; then
    echo "verdict: head_sha must be a 40- or 64-hex Git OID" >&2
    return 1
  fi
  # Codex r6 fix: base_sha is not only a FORMAT-validated hex string — it MUST
  # also be a REAL git commit object AND an ancestor of head_sha (the recorded
  # baseline must prove the diff from base→head). Without this check, a hand-
  # crafted verdict can name a fabricated base (e.g. 40-zero OID) and pass
  # validation; the diff is then unverifiable, and the review's claimed
  # coverage window is whatever the record says it is. This mirrors the
  # `_dwm_validate_branch_gate_first_add` real-oid + ancestor-of-HEAD pattern
  # (see core/lib/dirty-worktree-manifest.sh). Skipped when the project is
  # not a git repo (no OID semantics to verify).
  if command -v git >/dev/null 2>&1 && git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$project_dir" cat-file -e "$base^{commit}" 2>/dev/null \
       && ! git -C "$project_dir" cat-file -e "$base" 2>/dev/null; then
      echo "verdict: base_sha $base is not a real git object in $project_dir" >&2
      return 1
    fi
    if ! git -C "$project_dir" merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
      echo "verdict: base_sha $base is not an ancestor of head_sha $head" >&2
      return 1
    fi
  fi
  # PASS MUST bind a non-empty verification run_id
  local run_id
  run_id="$(printf '%s' "$rec" | jq -r '.run_id // ""')"
  if [ "$verdict" = "PASS" ] && [ -z "$run_id" ]; then
    echo "verdict: PASS must bind a non-empty verification run_id" >&2
    return 1
  fi
  if [ -n "$run_id" ]; then
    if ! printf '%s' "$rec" | jq -e '(.run_id | type) == "string" and (.run_id | length) > 0' >/dev/null 2>&1; then
      echo "verdict: run_id must be a non-empty string" >&2
      return 1
    fi
    # valid run: the run log must exist AND pass validate_run_log
    local run_log="$project_dir/.harness/logs/runs/${run_id}.ndjson"
    if [ ! -f "$run_log" ]; then
      echo "verdict: run_id $run_id does not reference an existing run log" >&2
      return 1
    fi
    if ! validate_run_log "$run_id" "$project_dir" 2>/dev/null | jq -e '.valid == true' >/dev/null 2>&1; then
      echo "verdict: run_id $run_id references an INVALID run log" >&2
      return 1
    fi
  fi
  # P0-4: a PASS verdict binds a run that is passed, fresh on all three
  # staleness axes, and VCS/head-consistent with the CURRENT project state.
  # P0-12: a FEATURE PASS additionally binds a run whose run_started.feature_id
  # equals the verdict's feature_id — a feature cannot be passed by another
  # feature's run. Phase records are not feature-scoped (no expect_fid).
  if [ "$verdict" = "PASS" ] && [ -n "$run_id" ]; then
    local pass_reason
    if [ "$kind" = "feature" ] || [ "$kind" = "maintenance" ]; then
      pass_reason="$( _v_require_passed_fresh_run "$project_dir" "$run_id" "$head" "$fid" "$fresh" 2>&1 )"
    else
      pass_reason="$( _v_require_passed_fresh_run "$project_dir" "$run_id" "$head" "" "$fresh" 2>&1 )"
    fi
    if [ $? -ne 0 ]; then
      echo "verdict: PASS run binding rejected — ${pass_reason}" >&2
      return 1
    fi
  fi
  local host
  host="$(printf '%s' "$rec" | jq -r '.reviewer_host // empty')"
  case "$host" in
    subagent|manual) ;;
    *) echo "verdict: reviewer_host must be subagent|manual" >&2; return 1 ;;
  esac
  if ! printf '%s' "$rec" | jq -e '(.checked | type) == "array" and ([.checked[]? | type] | all(. == "string"))' >/dev/null 2>&1; then
    echo "verdict: checked must be an array of strings" >&2
    return 1
  fi
  if ! printf '%s' "$rec" | jq -e '(.reason | type) == "string"' >/dev/null 2>&1; then
    echo "verdict: reason must be a string" >&2
    return 1
  fi
  if ! printf '%s' "$rec" | jq -e '(.recorded_at | type) == "string"' >/dev/null 2>&1; then
    echo "verdict: recorded_at must be a string" >&2
    return 1
  fi
  return 0
}

# ---- verdict_validate_file ------------------------------------------------
# Validates a whole artifact file: per-record schema + attempt continuity
# (1..N, no gaps/dups) + kind/id consistency. JSON result on stdout, exit 0/1.
verdict_validate_file() {
  local project_dir="$1" kind="$2" id="$3"
  local path
  path="$(_v_artifact_path "$project_dir" "$kind" "$id")"
  if [ -z "$path" ]; then
    jq -n --arg kind "$kind" '{valid:false, reason:"unknown_kind", kind:$kind}'
    return 1
  fi
  if [ ! -f "$path" ]; then
    jq -n --arg path "$path" '{valid:false, reason:"artifact_missing", path:$path}'
    return 1
  fi
  local records
  records="$(grep -v '^[[:space:]]*$' "$path" | jq -R -s '
    split("\n") | map(select(length > 0) | fromjson)
  ' 2>/dev/null)" || {
    jq -n --arg path "$path" '{valid:false, reason:"unparseable_artifact", path:$path}'
    return 1
  }
  local n
  n="$(printf '%s' "$records" | jq 'length')"
  if [ "$n" = "0" ]; then
    jq -n --arg path "$path" '{valid:false, reason:"empty_artifact", path:$path}'
    return 1
  fi
  local i
  i=0
  while [ "$i" -lt "$n" ]; do
    local rec
    rec="$(printf '%s' "$records" | jq -c ".[$i]")"
    local attempt expect
    attempt="$(printf '%s' "$rec" | jq -r '.attempt // empty')"
    expect=$((i + 1))
    if [ "$attempt" != "$expect" ]; then
      jq -n --argjson line $((i + 1)) --argjson found "${attempt:-0}" --argjson expected "$expect" \
        '{valid:false, reason:"attempt_gap_or_dup", line:$line, found:$found, expected:$expected}'
      return 1
    fi
    # Historical attempts (i < n-1) validate authenticity only (fresh=0); the
    # LATEST record (i == n-1) binds current head/run/fingerprint (fresh=1).
    # This is what makes the whole maintenance verdict file pass
    # verdict_validate_file even though only the last attempt's base/head match
    # the CURRENT repo state — each earlier attempt's base/head are still
    # real-oid + ancestor-verified inside verdict_validate_record.
    local rec_fresh
    if [ "$i" -eq $((n - 1)) ]; then
      rec_fresh=1
    else
      rec_fresh=0
    fi
    if ! verdict_validate_record "$project_dir" "$rec" "$rec_fresh" >/dev/null 2>&1; then
      jq -n --argjson line $((i + 1)) '{valid:false, reason:"invalid_record", line:$line}'
      return 1
    fi
    local rkind
    rkind="$(printf '%s' "$rec" | jq -r '.kind')"
    if [ "$rkind" != "$kind" ]; then
      jq -n --argjson line $((i + 1)) --arg found "$rkind" --arg expected "$kind" \
        '{valid:false, reason:"kind_mismatch", line:$line, found:$found, expected:$expected}'
      return 1
    fi
    if [ "$kind" = "feature" ] || [ "$kind" = "maintenance" ]; then
      local rfid
      rfid="$(printf '%s' "$rec" | jq -r '.feature_id')"
      if [ "$rfid" != "$id" ]; then
        jq -n --argjson line $((i + 1)) --arg found "$rfid" --arg expected "$id" \
          '{valid:false, reason:"feature_id_mismatch", line:$line, found:$found, expected:$expected}'
        return 1
      fi
    else
      local rph
      rph="$(printf '%s' "$rec" | jq -r '.phase')"
      if [ "$rph" != "$id" ]; then
        jq -n --argjson line $((i + 1)) --arg found "$rph" --arg expected "$id" \
          '{valid:false, reason:"phase_mismatch", line:$line, found:$found, expected:$expected}'
        return 1
      fi
    fi
    i=$((i + 1))
  done
  # P0-4: a phase PASS must cover every feature of that phase. The LATEST
  # record decides the active phase verdict; only a PASS needs coverage.
  if [ "$kind" = "phase" ]; then
    local last_rec last_verdict cov_json
    last_rec="$(printf '%s' "$records" | jq -c ".[$((n - 1))]")"
    last_verdict="$(printf '%s' "$last_rec" | jq -r '.verdict')"
    if [ "$last_verdict" = "PASS" ]; then
      cov_json="$(_v_phase_coverage "$project_dir" "$id" "$last_rec")"
      if ! printf '%s' "$cov_json" | jq -e '.valid == true' >/dev/null 2>&1; then
        jq -n --argjson detail "$cov_json" '{valid:false, reason:"phase_coverage_failed", detail:$detail}'
        return 1
      fi
    fi
  fi
  jq -n --arg path "$path" --argjson records "$n" '{valid:true, path:$path, records:$records}'
  return 0
}

# ---- verdict_next_attempt -------------------------------------------------
# Prints the attempt number the NEXT re-review will use (previous + 1, or 1).
verdict_next_attempt() {
  local project_dir="$1" kind="$2" id="$3"
  local path
  path="$(_v_artifact_path "$project_dir" "$kind" "$id")"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    printf '1'
    return 0
  fi
  local last
  last="$(grep -v '^[[:space:]]*$' "$path" 2>/dev/null | tail -1 | jq -r '.attempt // 0' 2>/dev/null)"
  [ -n "$last" ] || last=0
  printf '%s' "$((last + 1))"
}

# ---- verdict_append_record -------------------------------------------------
# Appends ONE new record (attempt auto-set to next) to the artifact. The record
# is fully validated BEFORE the append — a re-review never modifies prior
# records. When the project is a git repo, head_sha must resolve to a real git
# object. Prints the appended record; exit 0/1.
verdict_append_record() {
  local project_dir="$1" kind="$2" id="$3" json="$4"
  local path
  path="$(_v_artifact_path "$project_dir" "$kind" "$id")"
  if [ -z "$path" ]; then
    echo "verdict: invalid kind '$kind'" >&2
    return 1
  fi
  local attempt rec
  attempt="$(verdict_next_attempt "$project_dir" "$kind" "$id")"
  rec="$(printf '%s' "$json" | jq -c --argjson a "$attempt" '.attempt = $a' 2>/dev/null)" || {
    echo "verdict: refusing to append invalid JSON" >&2
    return 1
  }
  # writer-side integrity: head_sha must be a real git object in a git repo
  local head
  head="$(printf '%s' "$rec" | jq -r '.head_sha // ""')"
  if command -v git >/dev/null 2>&1 && git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$project_dir" cat-file -e "$head^{commit}" 2>/dev/null \
       && ! git -C "$project_dir" cat-file -e "$head" 2>/dev/null; then
      echo "verdict: head_sha $head is not a real git object in $project_dir — refusing to record" >&2
      return 1
    fi
  fi
  if ! verdict_validate_record "$project_dir" "$rec"; then
    echo "verdict: refusing to append invalid record" >&2
    return 1
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s' "$rec" | jq -c . >> "$path" || {
    echo "verdict: append failed for $path" >&2
    return 1
  }
  # Codex r7 + rc6 final remediation: bind the verdict's first-seen bytes in
  # the runtime-manifest registry so the DWM gate enforces append-only on
  # later checks (idempotent — a later append never rewrites the first-seen
  # binding). All registration failures are HARD failures (rc6 final: the
  # previous `|| true` swallowed registry-write errors and produced a silent
  # trust gap).
  if type runtime_register >/dev/null 2>&1; then
    runtime_register "$project_dir" ".harness/reviews/$kind/$id.jsonl" "verdict"
  fi
  printf '%s' "$rec"
  return 0
}
