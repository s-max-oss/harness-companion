#!/bin/bash
# scripts/acceptance/validate-acceptance-package.sh
#
# Schema + binding validator for the acceptance package at
#   <pkg_dir>/acceptance.json
#
# This is the shared validator used by:
#   - tests/release/test-acceptance-package.sh — fixed-fixture unit test
#     (synthetic package in mktemp dir, validator called WITHOUT --project-dir;
#      shape + sha-bindings only, no current-HEAD check)
#   - scripts/acceptance/check-current-head-package.sh — current-HEAD gate
#     (validator called WITH --project-dir; additionally checks head_oid ==
#      git HEAD, config_sha256 == on-disk, reviewer verdict binds to HEAD)
#
# Splitting the in-run test from the current-HEAD gate eliminates the
# circular dependency where tests/run-all.sh required the final package to
# pre-exist before a canonical run could even be attempted.
#
# Sourceable API:
#   source validate-acceptance-package.sh
#   validate_acceptance_package <pkg_dir> [--project-dir <project_dir>]
#
# Direct call API:
#   bash scripts/acceptance/validate-acceptance-package.sh <pkg_dir> \
#       [--project-dir <project_dir>]
#
# Exit: 0 + stdout JSON {"valid":true,...} on success
#       1 + stdout JSON {"valid":false,"reason":...} on failure
#       2 + usage error (bad args / missing pkg_dir)
#
# Requires: bash 4+, jq, sha256sum (or shasum), git

# Known bound fields in acceptance.json. Each entry has {path, sha256}.
BOUND_FIELDS=(canonical_ndjson full_suite_log maintenance_verdict reviewer_verdict a_g_log migration_record)

# ---- _emit_result ---------------------------------------------------------
# Print a JSON result line and return the appropriate code.
_emit_result() {
  local valid="$1"; shift
  local reason="${1:-}"
  if [ "$valid" = "true" ]; then
    printf '{"valid":true}\n'
    return 0
  fi
  printf '{"valid":false,"reason":"%s"}\n' "$reason"
  return 1
}

# ---- _sha256_file ---------------------------------------------------------
_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

_utc_epoch() {
  local ts="$1"
  date -u -d "$ts" +%s 2>/dev/null && return 0
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null
}

# ---- validate_acceptance_package -----------------------------------------
# Public entry. See file header for arg semantics.
validate_acceptance_package() {
  local pkg="$1"; shift || { _emit_result false "missing pkg_dir arg"; return 2; }
  local project_dir="" committed_recovery=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project-dir) project_dir="$2"; shift 2;;
      --committed-recovery) committed_recovery=1; shift;;
      *) shift;;
    esac
  done
  if [ -n "$project_dir" ]; then
    # Normalize relative paths and MSYS `/d/...` spellings to the same exact
    # Git path recorded by canonical run artifacts on Windows. Authoritative
    # path checks below remain literal and fail-closed after normalization.
    local project_arg="$project_dir"
    project_dir="$(git -C "$project_arg" rev-parse --show-toplevel 2>/dev/null)" || {
      _emit_result false "cannot determine canonical project root from $project_arg"
      return 1
    }
    if command -v cygpath >/dev/null 2>&1; then
      project_dir="$(cygpath -u "$project_dir" 2>/dev/null || printf '%s' "$project_dir")"
    fi
  fi

  if [ ! -d "$pkg" ]; then
    _emit_result false "pkg_dir does not exist: $pkg"
    return 1
  fi
  local acc="$pkg/acceptance.json"
  if [ ! -f "$acc" ]; then
    _emit_result false "missing acceptance.json at $pkg"
    return 1
  fi

  # schema_version: integer == 1
  if ! jq -e '(.schema_version | type) == "number" and .schema_version == 1' "$acc" >/dev/null 2>&1; then
    _emit_result false "schema_version must be integer 1"
    return 1
  fi

  # head_oid: SHA-1 or SHA-256 git object id
  local head_oid
  head_oid="$(jq -r '.head_oid // empty' "$acc")"
  if ! printf '%s' "$head_oid" | grep -qE '^([0-9a-f]{40}|[0-9a-f]{64})$'; then
    _emit_result false "head_oid not a full git object id (got '$head_oid')"
    return 1
  fi

  # run_id: canonical format
  local run_id
  run_id="$(jq -r '.run_id // empty' "$acc")"
  if ! printf '%s' "$run_id" | grep -qE '^[0-9TZ]+-[0-9]+-[0-9]+$'; then
    _emit_result false "run_id not canonical format (got '$run_id')"
    return 1
  fi

  # config_sha256: sha256:<64hex>
  local cfg_sha
  cfg_sha="$(jq -r '.config_sha256 // empty' "$acc")"
  if ! printf '%s' "$cfg_sha" | grep -qE '^sha256:[0-9a-f]{64}$'; then
    _emit_result false "config_sha256 not sha256:<64hex> (got '$cfg_sha')"
    return 1
  fi

  # duration_ms: positive integer
  if ! jq -e '.duration_ms | type == "number" and floor == . and . > 0' "$acc" >/dev/null 2>&1; then
    _emit_result false "duration_ms must be positive integer"
    return 1
  fi

  # effective_timeout: integer >= 1
  if ! jq -e '.effective_timeout | type == "number" and floor == . and . >= 1' "$acc" >/dev/null 2>&1; then
    _emit_result false "effective_timeout must be integer >= 1"
    return 1
  fi
  if [ "$(jq -r '.canonical_command // empty' "$acc")" != "bash tests/run-all.sh" ]; then
    _emit_result false "canonical_command must be exact full-suite contract"
    return 1
  fi

  # Each bound field: {path, sha256} where sha256 matches on-disk
  for entry in "${BOUND_FIELDS[@]}"; do
    local p s_recorded s_actual
    p="$(jq -r --arg k "$entry" '.[$k].path // empty' "$acc")"
    s_recorded="$(jq -r --arg k "$entry" '.[$k].sha256 // empty' "$acc")"
    if [ -z "$p" ]; then
      _emit_result false "$entry.path missing"
        return 1
      fi
    if [ ! -f "$p" ]; then
      _emit_result false "$entry.path does not exist: $p"
        return 1
      fi
    s_actual="$(_sha256_file "$p")"
    if [ "$s_recorded" != "$s_actual" ]; then
      _emit_result false "$entry.sha256 mismatch (recorded=$s_recorded actual=$s_actual)"
      return 1
    fi
  done

  # A-G.log must retain a real, HEAD/run-bound formal DWM rc=0 transcript.
  # The current-head checker independently reruns DWM after publication; this
  # retained transcript proves the package was also clean immediately before
  # its own files were published and avoids relying on an ephemeral console.
  local ag_path ag_dwm begin_count end_count begin_line end_line
  ag_path="$(jq -r '.a_g_log.path // empty' "$acc")"
  begin_count="$(grep -cFx -- '----- BEGIN formal pre-publication DWM transcript -----' "$ag_path" 2>/dev/null || true)"
  end_count="$(grep -cFx -- '----- END formal pre-publication DWM transcript -----' "$ag_path" 2>/dev/null || true)"
  begin_line="$(grep -nFx -- '----- BEGIN formal pre-publication DWM transcript -----' "$ag_path" 2>/dev/null | cut -d: -f1)"
  end_line="$(grep -nFx -- '----- END formal pre-publication DWM transcript -----' "$ag_path" 2>/dev/null | cut -d: -f1)"
  ag_dwm="$(awk '
    $0 == "----- BEGIN formal pre-publication DWM transcript -----" { capture=1; next }
    $0 == "----- END formal pre-publication DWM transcript -----" { capture=0; next }
    capture { print }
  ' "$ag_path" 2>/dev/null)"
  if [ "$begin_count" != "1" ] || [ "$end_count" != "1" ] \
     || [ -z "$begin_line" ] || [ -z "$end_line" ] || [ "$begin_line" -ge "$end_line" ] \
     || ! grep -Fq "Head:                $head_oid" "$ag_path" 2>/dev/null \
     || ! grep -Fq "Run ID:              $run_id" "$ag_path" 2>/dev/null \
     || ! grep -Fq "Formal DWM exit:     0" "$ag_path" 2>/dev/null \
     || ! printf '%s' "$ag_dwm" | jq -s -e \
          'length == 1
           and (.[0] | keys) == ["allowed_new","appended_mutable","changed_mutable","content_changed_mutable","feature_revision_advanced","new_non_mutable","paired_rewrite_violations","runtime_paired_rewrite","valid","violations"]
           and .[0].valid == true
           and (.[0].violations | type == "array") and (.[0].violations | length == 0)
           and (.[0].allowed_new | type == "array")
           and (.[0].new_non_mutable | type == "array") and (.[0].new_non_mutable | length == 0)
           and (.[0].changed_mutable | type == "array")
           and (.[0].appended_mutable | type == "array")
           and (.[0].feature_revision_advanced | type == "array")
           and (.[0].content_changed_mutable | type == "array")
            and (.[0].runtime_paired_rewrite | type == "array") and (.[0].runtime_paired_rewrite | length == 0)
           and (.[0].paired_rewrite_violations | type == "array") and (.[0].paired_rewrite_violations | length == 0)' \
          >/dev/null 2>&1; then
    _emit_result false "a_g_log missing HEAD/run-bound formal DWM rc0 transcript"
    return 1
  fi

  # Canonical NDJSON terminal must be a passing terminal (run_completed or
  # run_passed with overall_result=passed, failed_commands=0). We do NOT call
  # validate_run_log here because that validator requires the NDJSON to live
  # at <project_dir>/.harness/logs/runs/<run_id>.ndjson. Instead we replicate
  # the terminal-event check directly so the validator is project-dir-agnostic
  # and the test can run against a temp package without a project_root.
  local ndjson_path
  ndjson_path="$(jq -r '.canonical_ndjson.path // empty' "$acc")"
  if [ -z "$ndjson_path" ] || [ ! -f "$ndjson_path" ]; then
    _emit_result false "canonical_ndjson.path missing or does not exist"
    return 1
  fi
  # Reject symlinks — the canonical NDJSON must be the authoritative file.
  if [ -L "$ndjson_path" ]; then
    _emit_result false "canonical_ndjson.path must not be a symlink"
    return 1
  fi
  local ndjson_run_id
  ndjson_run_id="$(jq -r '.run_id // empty' "$acc")"
  if ! grep -q "\"run_id\":\"$ndjson_run_id\"" "$ndjson_path" 2>/dev/null; then
    _emit_result false "canonical NDJSON does not contain run_id $ndjson_run_id"
    return 1
  fi
  local terminal_event terminal_kind terminal_overall terminal_failed
  terminal_event="$(grep -E '"event":"run_(passed|completed|failed|aborted)"' "$ndjson_path" | tail -1)"
  if [ -z "$terminal_event" ]; then
    _emit_result false "canonical NDJSON has no terminal run_completed/run_failed event"
    return 1
  fi
  terminal_kind="$(printf '%s' "$terminal_event" | jq -r '.event // empty')"
  terminal_overall="$(printf '%s' "$terminal_event" | jq -r '.overall_result // empty')"
  terminal_failed="$(printf '%s' "$terminal_event" | jq -r '.failed_commands // 1')"
  local pass_ok=0
  if { [ "$terminal_kind" = "run_completed" ] || [ "$terminal_kind" = "run_passed" ]; } \
     && [ "$terminal_overall" = "passed" ] && [ "$terminal_failed" = "0" ]; then
    pass_ok=1
  fi
  if [ "$pass_ok" != "1" ]; then
    _emit_result false "canonical NDJSON terminal not passing (kind=$terminal_kind overall=$terminal_overall failed=$terminal_failed)"
    return 1
  fi

  # Reviewer verdict freshness + HEAD binding (always checked; requires
  # --project-dir to compare head_sha against current HEAD).
  local reviewer_path last_vr vr_head vr_verdict vr_run vr_recorded vr_epoch now_epoch age_s
  reviewer_path="$(jq -r '.reviewer_verdict.path // empty' "$acc")"
  if [ -n "$project_dir" ] \
     && [ "$reviewer_path" != "$project_dir/.harness/reviews/reviewer/F-MAINT-01.jsonl" ]; then
    _emit_result false "reviewer verdict path is not authoritative"
    return 1
  fi
  if [ -z "$reviewer_path" ] || [ -L "$reviewer_path" ] || [ ! -f "$reviewer_path" ]; then
    _emit_result false "reviewer_verdict.path missing or does not exist"
    return 1
  fi
  # A project-backed validation delegates the complete lifecycle to the one
  # canonical verdict validator below. That validator intentionally preserves
  # the immutable pre-attempt Reviewer prefix while requiring every current
  # record (especially the latest record) to use the strict numeric schema.
  # Reimplementing the lifecycle here rejected that valid historical prefix
  # before the canonical validator could inspect it. Project-agnostic packages
  # have no canonical validator context, so retain the standalone shape check.
  if [ -z "$project_dir" ] && ! jq -s -e '
      length > 0 and ([.[].attempt] == [range(1; length + 1)]) and all(.[];
        ((.schema_version | type) == "number") and .schema_version == 1
        and .kind == "reviewer" and .feature_id == "F-MAINT-01"
        and (.verdict == "PASS" or .verdict == "FAIL" or .verdict == "BLOCKER")
        and (.base_sha | type == "string") and (.head_sha | type == "string")
        and ((.run_id == null) or (.run_id | type == "string"))
        and (.reviewer_host | type == "string")
        and (.checked | type == "array")
        and (.reason | type == "string") and (.reason | length > 0)
        and (.recorded_at | type == "string"))
    ' "$reviewer_path" >/dev/null 2>&1; then
    _emit_result false "reviewer verdict artifact lifecycle contains an invalid record"
    return 1
  fi
  last_vr="$(tail -1 "$reviewer_path")"
  if ! printf '%s' "$last_vr" | jq -e '
      ((.schema_version | type) == "number") and .schema_version == 1
      and .kind == "reviewer" and .feature_id == "F-MAINT-01"
      and (.checked | type == "array") and (.checked | length > 0)
      and (.reason | type == "string") and (.reason | length > 0)
    ' >/dev/null 2>&1; then
    _emit_result false "reviewer verdict latest record has invalid schema"
    return 1
  fi
  vr_head="$(printf '%s' "$last_vr" | jq -r '.head_sha // empty')"
  vr_verdict="$(printf '%s' "$last_vr" | jq -r '.verdict // empty')"
  vr_run="$(printf '%s' "$last_vr" | jq -r '.run_id // empty')"
  vr_recorded="$(printf '%s' "$last_vr" | jq -r '.recorded_at // empty')"
  if [ "$vr_verdict" != "PASS" ]; then
    _emit_result false "reviewer verdict is not PASS (got '$vr_verdict')"
    return 1
  fi
  if [ "$vr_run" != "$ndjson_run_id" ]; then
    _emit_result false "reviewer verdict run_id != canonical run_id (verdict=$vr_run recorded=$ndjson_run_id)"
    return 1
  fi
  # If --project-dir given: additionally bind to current state.
  if [ -n "$project_dir" ]; then
    local current_head run_validation started cmd terminal
    current_head="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)" || {
      _emit_result false "cannot determine current HEAD in $project_dir"
      return 1
    }
    if [ "$head_oid" != "$current_head" ]; then
      _emit_result false "head_oid does not match current HEAD (recorded=$head_oid current=$current_head)"
      return 1
    fi
    if [ "$vr_head" != "$current_head" ]; then
      _emit_result false "reviewer verdict head_sha != current HEAD (verdict=$vr_head current=$current_head)"
      return 1
    fi
    if [ "$committed_recovery" = "1" ]; then
      now_epoch="$(_utc_epoch "$(jq -r '.generated_at // empty' "$acc")" 2>/dev/null || true)"
      if [ -z "$now_epoch" ]; then
        _emit_result false "acceptance generated_at is not parseable for committed recovery"
        return 1
      fi
    else
      now_epoch="$(date -u +%s)"
    fi
    vr_epoch="$(_utc_epoch "$vr_recorded" 2>/dev/null || true)"
    if [ -z "$vr_epoch" ]; then
      _emit_result false "reviewer verdict recorded_at is not parseable"
      return 1
    fi
    age_s=$((now_epoch - vr_epoch))
    if [ "$age_s" -lt 0 ] || [ "$age_s" -gt 86400 ]; then
      _emit_result false "reviewer verdict is not fresh (age=${age_s}s)"
      return 1
    fi
    # Require the complete append-only Reviewer lifecycle, not just a
    # hand-crafted latest line. This makes the canonical locked writer part of
    # acceptance eligibility.
    # shellcheck source=../../core/lib/verdict-artifact.sh
    . "$project_dir/core/lib/verdict-artifact.sh"
    local reviewer_validation
    reviewer_validation="$(verdict_validate_file "$project_dir" reviewer F-MAINT-01 2>/dev/null)" || {
      _emit_result false "F-MAINT-01 Reviewer lifecycle invalid"
      return 1
    }
    if ! printf '%s' "$reviewer_validation" | jq -e '.valid == true' >/dev/null 2>&1; then
      _emit_result false "F-MAINT-01 Reviewer verdict invalid"
      return 1
    fi
    # Run-log validity is necessary but not sufficient: bind every event and
    # every package field to this one current-HEAD canonical execution.
    # shellcheck source=../../core/lib/validate-run-log.sh
    . "$project_dir/core/lib/validate-run-log.sh"
    run_validation="$(validate_run_log "$ndjson_run_id" "$project_dir" 2>/dev/null)" || {
      _emit_result false "canonical NDJSON failed validate_run_log"
      return 1
    }
    if ! printf '%s' "$run_validation" | jq -e '.valid == true' >/dev/null 2>&1; then
      _emit_result false "canonical NDJSON is not valid"
      return 1
    fi
    if ! jq -s -e --arg r "$ndjson_run_id" '
        length == 3 and all(.[]; .run_id == $r)
        and ([.[] | select(.event == "run_started")] | length == 1)
        and ([.[] | select(.event == "command_completed")] | length == 1)
        and ([.[] | select(.event == "run_completed")] | length == 1)
        and .[-1].event == "run_completed"
      ' "$ndjson_path" >/dev/null 2>&1; then
      _emit_result false "canonical NDJSON must be exactly one start, command, and passing terminal for run_id"
      return 1
    fi
    started="$(jq -c 'select(.event == "run_started")' "$ndjson_path")"
    cmd="$(jq -c 'select(.event == "command_completed")' "$ndjson_path")"
    terminal="$(jq -c 'select(.event == "run_completed")' "$ndjson_path")"
    local started_rev resolved_started_rev cmd_id cmd_argv cmd_log cmd_log_sha pkg_log pkg_log_sha pkg_duration
    started_rev="$(printf '%s' "$started" | jq -r '.vcs_revision // empty')"
    resolved_started_rev="$(git -C "$project_dir" rev-parse "$started_rev^{commit}" 2>/dev/null || true)"
    if [ "$resolved_started_rev" != "$current_head" ]; then
      _emit_result false "canonical run_started vcs_revision != current HEAD"
      return 1
    fi
    if [ "$(printf '%s' "$started" | jq -r '.config_sha256 // empty')" != "$cfg_sha" ]; then
      _emit_result false "canonical run_started config_sha256 != acceptance config_sha256"
      return 1
    fi
    if [ "$(printf '%s' "$started" | jq -r '.project_root // empty')" != "$project_dir" ] \
       || [ "$(printf '%s' "$started" | jq -c '.required_command_ids')" != '["full-suite"]' ] \
       || [ "$(printf '%s' "$started" | jq -r '.feature_id // empty')" != 'F-MAINT-01' ]; then
      _emit_result false "canonical run_started root/required commands/feature scope mismatch"
      return 1
    fi
    cmd_id="$(printf '%s' "$cmd" | jq -r '.command_id // empty')"
    cmd_argv="$(printf '%s' "$cmd" | jq -c '.command')"
    if [ "$cmd_id" != "full-suite" ] || [ "$cmd_argv" != '["bash","tests/run-all.sh"]' ] \
       || [ "$(printf '%s' "$cmd" | jq -r '.command_origin // empty')" != 'configured' ] \
       || [ "$(jq -r '.canonical_command // empty' "$acc")" != 'bash tests/run-all.sh' ]; then
      _emit_result false "canonical command is not exact full-suite contract"
      return 1
    fi
    if [ "$(printf '%s' "$cmd" | jq -r '.exit_code')" != "0" ] \
       || [ "$(printf '%s' "$terminal" | jq -r '.overall_result')" != "passed" ] \
       || [ "$(printf '%s' "$terminal" | jq -r '.failed_commands')" != "0" ]; then
      _emit_result false "canonical command or terminal is not passing"
      return 1
    fi
    cmd_log="$(printf '%s' "$cmd" | jq -r '.log_artifact // empty')"
    cmd_log_sha="$(printf '%s' "$cmd" | jq -r '.log_sha256 // empty')"
    pkg_log="$(jq -r '.full_suite_log.path // empty' "$acc")"
    pkg_log_sha="$(jq -r '.full_suite_log.sha256 // empty' "$acc")"
    pkg_duration="$(jq -r '.duration_ms' "$acc")"
    if [ "$cmd_log" != "$pkg_log" ] || [ "$cmd_log_sha" != "$pkg_log_sha" ] \
       || [ "$(printf '%s' "$cmd" | jq -r '.duration_ms')" != "$pkg_duration" ]; then
      _emit_result false "canonical command log/hash/duration not exactly bound to package"
      return 1
    fi
    local actual_cfg_sha recorded_cfg_sha
    actual_cfg_sha="$(_sha256_file "$project_dir/.harness/config.json")"
    recorded_cfg_sha="$(printf '%s' "$cfg_sha" | sed 's/^sha256://')"
    if [ "$actual_cfg_sha" != "$recorded_cfg_sha" ]; then
      _emit_result false "config_sha256 does not match on-disk (recorded=$recorded_cfg_sha actual=$actual_cfg_sha)"
      return 1
    fi
    local config_timeout package_timeout maint_validation maint_path last_maint
    config_timeout="$(jq -r '.verification.commands[0].timeout_seconds // empty' "$project_dir/.harness/config.json")"
    package_timeout="$(jq -r '.effective_timeout' "$acc")"
    if [ "$config_timeout" != "$package_timeout" ]; then
      _emit_result false "effective_timeout does not match canonical config"
      return 1
    fi
    maint_path="$(jq -r '.maintenance_verdict.path // empty' "$acc")"
    if [ "$maint_path" != "$project_dir/.harness/reviews/maintenance/F-MAINT-01.jsonl" ]; then
      _emit_result false "maintenance verdict path is not authoritative"
      return 1
    fi
    last_maint="$(tail -1 "$maint_path" 2>/dev/null)"
    if ! printf '%s' "$last_maint" | jq -e --arg h "$current_head" --arg r "$ndjson_run_id" '
        .kind == "maintenance" and .feature_id == "F-MAINT-01"
        and .verdict == "PASS" and .head_sha == $h and .run_id == $r
      ' >/dev/null 2>&1; then
      _emit_result false "maintenance verdict does not bind exact package HEAD/run"
      return 1
    fi
    # Maintenance artifact is the formal passing-eligibility gate: its latest
    # PASS must bind this run and all three freshness axes at current HEAD.
    # shellcheck source=../../core/lib/verdict-artifact.sh
    . "$project_dir/core/lib/verdict-artifact.sh"
    maint_validation="$(verdict_validate_file "$project_dir" maintenance F-MAINT-01 2>/dev/null)" || {
      _emit_result false "F-MAINT-01 maintenance lifecycle/passing eligibility invalid"
      return 1
    }
    if ! printf '%s' "$maint_validation" | jq -e '.valid == true' >/dev/null 2>&1; then
      _emit_result false "F-MAINT-01 maintenance verdict invalid"
      return 1
    fi
    # Canonical NDJSON path must equal the authoritative location for run_id.
    local expected_ndjson
    expected_ndjson="$project_dir/.harness/logs/runs/$ndjson_run_id.ndjson"
    if [ "$ndjson_path" != "$expected_ndjson" ]; then
      _emit_result false "canonical NDJSON path not authoritative (got=$ndjson_path expected=$expected_ndjson)"
      return 1
    fi
  fi

  _emit_result true
  return 0
}

# ---- Direct-call entry (when not sourced) --------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "usage: validate-acceptance-package.sh <pkg_dir> [--project-dir <project_dir>]" >&2
    exit 2
  fi
  validate_acceptance_package "$@"
  exit $?
fi
