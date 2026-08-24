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
# Requires: bash 4+, jq, sha256sum, git

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
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# ---- validate_acceptance_package -----------------------------------------
# Public entry. See file header for arg semantics.
validate_acceptance_package() {
  local pkg="$1"; shift || { _emit_result false "missing pkg_dir arg"; return 2; }
  local project_dir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project-dir) project_dir="$2"; shift 2;;
      *) shift;;
    esac
  done

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

  # head_oid: 40-hex
  local head_oid
  head_oid="$(jq -r '.head_oid // empty' "$acc")"
  if ! printf '%s' "$head_oid" | grep -qE '^[0-9a-f]{40}$'; then
    _emit_result false "head_oid not 40-hex (got '$head_oid')"
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
  local ag_path ag_dwm
  ag_path="$(jq -r '.a_g_log.path // empty' "$acc")"
  ag_dwm="$(awk '
    /----- BEGIN formal pre-publication DWM transcript -----/ { capture=1; next }
    /----- END formal pre-publication DWM transcript -----/ { capture=0 }
    capture { print }
  ' "$ag_path" 2>/dev/null)"
  if ! grep -Fq "Head:                $head_oid" "$ag_path" 2>/dev/null \
     || ! grep -Fq "Run ID:              $run_id" "$ag_path" 2>/dev/null \
     || ! grep -Fq "Formal DWM exit:     0" "$ag_path" 2>/dev/null \
     || ! printf '%s' "$ag_dwm" | jq -e \
          '.valid == true and (.violations | type == "array") and (.violations | length == 0)' \
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
  local reviewer_path last_vr vr_head vr_verdict vr_run
  reviewer_path="$(jq -r '.reviewer_verdict.path // empty' "$acc")"
  if [ -z "$reviewer_path" ] || [ ! -f "$reviewer_path" ]; then
    _emit_result false "reviewer_verdict.path missing or does not exist"
    return 1
  fi
  last_vr="$(tail -1 "$reviewer_path")"
  vr_head="$(printf '%s' "$last_vr" | jq -r '.head_sha // empty')"
  vr_verdict="$(printf '%s' "$last_vr" | jq -r '.verdict // empty')"
  vr_run="$(printf '%s' "$last_vr" | jq -r '.run_id // empty')"
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
    local current_head
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
    local actual_cfg_sha recorded_cfg_sha
    actual_cfg_sha="$(_sha256_file "$project_dir/.harness/config.json")"
    recorded_cfg_sha="$(printf '%s' "$cfg_sha" | sed 's/^sha256://')"
    if [ "$actual_cfg_sha" != "$recorded_cfg_sha" ]; then
      _emit_result false "config_sha256 does not match on-disk (recorded=$recorded_cfg_sha actual=$actual_cfg_sha)"
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
