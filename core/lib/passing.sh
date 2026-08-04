#!/bin/bash
# passing.sh — Run-based passing eligibility via canonical NDJSON run log (v2)
#
# Design §9: Passing Eligibility — 8 steps, fail-closed
# Passing is determined by the LATEST complete run log. Evidence from different
# runs cannot be cobbled together. Uses validate_run_log() for canonical validation
# AND adds explicit, independent semantic checks on top.
#
# Usage:
#   source passing.sh
#   is_eligible_for_passing <feature_id> <feature_list_json> [project_dir]
#
# Returns 0 if eligible, 1 with explanation on stderr otherwise.
#
# Design §9.1 steps (frozen):
#   1. Find latest association for feature_id
#   2. Canonical validation (validate_run_log): all 16 structural checks
#   3. Terminal must be run_completed with overall_result="passed"
#   4. run_started.required_command_ids.length > 0  (at least one required step)
#   5. terminal.failed_commands == 0                  (explicit safety check)
#   6. Workspace fingerprint match (current vs terminal.verified)
#   7. Config SHA-256 match   (run_started.config_sha256 vs current file)
#   8. VCS HEAD match         (run_started.vcs_revision vs git HEAD, git only)
#
# Fail-closed semantics: any axis where the comparison cannot be completed
# (e.g., missing tool, missing config file, missing git) returns NOT eligible.
# The function MUST NOT return eligible unless every step explicitly passes.



# Source validate-run-log if not already sourced
if ! command -v validate_run_log >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=validate-run-log.sh
  source "$SCRIPT_DIR/validate-run-log.sh"
fi

# ---- is_eligible_for_passing -----------------------------------------------
# Implements design §9.1 8-step algorithm. Every step is a guard.
is_eligible_for_passing() {
  local fid="$1"
  local fl="$2"
  local project_dir="${3:-.}"

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for passing eligibility check." >&2
    return 1
  fi

  # ===========================================================================
  # Step 1: Find latest association for feature_id
  # ===========================================================================
  if ! jq -e --arg id "$fid" '.features[] | select(.id == $id)' "$fl" >/dev/null 2>&1; then
    echo "Error: feature_not_found — feature '$fid' missing from registry" >&2
    return 1
  fi

  local latest_assoc
  latest_assoc="$(jq -c --arg fid "$fid" '
    [.features[] | select(.id == $fid) | .evidence_associations[]?] | last
  ' "$fl" 2>/dev/null)" || true
  if [ -z "$latest_assoc" ] || [ "$latest_assoc" = "null" ]; then
    echo "Error: no_evidence_association — feature '$fid' has no associations" >&2
    return 1
  fi

  local run_id
  run_id="$(printf '%s' "$latest_assoc" | jq -r '.run_id // empty')"
  if [ -z "$run_id" ]; then
    echo "Error: association missing run_id for '$fid'" >&2
    return 1
  fi

  # ===========================================================================
  # Step 2: Canonical validation — all 16 structural checks
  # ===========================================================================
  local log_path="$project_dir/.harness/logs/runs/${run_id}.ndjson"
  if [ ! -f "$log_path" ]; then
    echo "Error: run_log_missing — log not found for run_id '$run_id'" >&2
    return 1
  fi

  local validation
  if ! validation="$(validate_run_log "$run_id" "$project_dir" 2>/dev/null)"; then
    local reason
    reason="$(printf '%s' "$validation" | jq -r '.reason // "unknown"')"
    echo "Error: run_log_invalid — $reason (run_id=$run_id)" >&2
    return 1
  fi

  local run_started terminal
  run_started="$(printf '%s' "$validation" | jq -c '.run_started')"
  terminal="$(printf '%s' "$validation" | jq -c '.terminal')"

  # ===========================================================================
  # Step 3: Terminal must be run_completed with overall_result="passed"
  # ===========================================================================
  local term_event overall_result
  term_event="$(printf '%s' "$terminal" | jq -r '.event // empty')"
  if [ "$term_event" != "run_completed" ]; then
    echo "Error: run_not_completed — terminal event is '$term_event'" >&2
    return 1
  fi

  overall_result="$(printf '%s' "$terminal" | jq -r '.overall_result // empty')"
  if [ "$overall_result" != "passed" ]; then
    echo "Error: overall_result_not_passed — got '$overall_result'" >&2
    if [ "$overall_result" = "no_checks" ]; then
      echo "Feature '$fid' has no verification steps configured. Add at least one required command." >&2
    fi
    return 1
  fi

  # ===========================================================================
  # Step 4: At least one required step (run_started.required_command_ids.length > 0)
  # ===========================================================================
  local req_len
  req_len="$(printf '%s' "$run_started" | jq '.required_command_ids | length')"
  if [ "$req_len" -eq 0 ]; then
    echo "Error: no_required_steps — required_command_ids is empty" >&2
    return 1
  fi

  # ===========================================================================
  # Step 5: All commands passed — explicit failed_commands == 0 check
  #         (validate_run_log covers invariants; this is the independent safety net.)
  # ===========================================================================
  local failed_commands
  failed_commands="$(printf '%s' "$terminal" | jq -r '.failed_commands // 0')"
  if [ "$failed_commands" -ne 0 ]; then
    echo "Error: command_failed — failed_commands=$failed_commands (must be 0)" >&2
    return 1
  fi

  # ===========================================================================
  # Step 6: Workspace fingerprint match (current vs terminal.verified)
  #         FAIL-CLOSED: cannot compute fingerprint → NOT eligible.
  # ===========================================================================
  local fp_script="${BASH_SOURCE[0]%/*}/workspace-fingerprint.sh"
  if [ ! -f "$fp_script" ]; then
    echo "Error: workspace_fingerprint_unavailable — workspace-fingerprint.sh missing" >&2
    return 1
  fi
  # shellcheck source=workspace-fingerprint.sh
  source "$fp_script"

  if ! command -v compute_workspace_fingerprint >/dev/null 2>&1; then
    echo "Error: workspace_fingerprint_unavailable — compute_workspace_fingerprint not loaded" >&2
    return 1
  fi

  local current_fp verified_fp
  current_fp="$(compute_workspace_fingerprint "$project_dir" 2>/dev/null)" || {
    echo "Error: workspace_fingerprint_compute_failed" >&2
    return 1
  }
  if [ -z "$current_fp" ] || [ "$current_fp" = "null" ]; then
    echo "Error: workspace_fingerprint_compute_failed — empty fingerprint" >&2
    return 1
  fi

  verified_fp="$(printf '%s' "$terminal" | jq -r '.workspace_fingerprint_verified // empty')"
  if [ -z "$verified_fp" ] || [ "$verified_fp" = "null" ]; then
    echo "Error: workspace_fingerprint_missing_in_terminal" >&2
    return 1
  fi

  if [ "$current_fp" != "$verified_fp" ]; then
    echo "Error: workspace_changed_since_verification — current='$current_fp' verified='$verified_fp'" >&2
    return 1
  fi

  # ===========================================================================
  # Step 7: Config SHA-256 match (run_started.config_sha256 vs current file)
  #         FAIL-CLOSED: missing tool or missing config → NOT eligible.
  # ===========================================================================
  local stored_config_sha current_config_sha config_path
  stored_config_sha="$(printf '%s' "$run_started" | jq -r '.config_sha256 // empty')"
  if [ -z "$stored_config_sha" ] || [ "$stored_config_sha" = "null" ]; then
    echo "Error: config_sha_missing_in_run_started" >&2
    return 1
  fi

  config_path="$project_dir/.harness/config.json"
  if [ ! -f "$config_path" ]; then
    echo "Error: config_file_missing — $config_path not found" >&2
    return 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    current_config_sha="sha256:$(sha256sum "$config_path" 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    current_config_sha="sha256:$(shasum -a 256 "$config_path" 2>/dev/null | awk '{print $1}')"
  else
    echo "Error: sha256_tool_unavailable — neither sha256sum nor shasum found" >&2
    return 1
  fi

  if [ -z "$current_config_sha" ] || [ "$current_config_sha" = "sha256:" ]; then
    echo "Error: config_hash_compute_failed" >&2
    return 1
  fi

  if [ "$stored_config_sha" != "$current_config_sha" ]; then
    echo "Error: config_changed_since_run — stored='$stored_config_sha' current='$current_config_sha'" >&2
    return 1
  fi

  # ===========================================================================
  # Step 8: VCS HEAD match (git repos only; non-git silently skipped per design)
  # ===========================================================================
  local stored_rev current_rev
  stored_rev="$(printf '%s' "$run_started" | jq -r '.vcs_revision // empty')"

  if [ -n "$stored_rev" ] && [ "$stored_rev" != "null" ]; then
    # Stored revision present: we MUST verify it. If git is unavailable
    # OR not a repo, the comparison fails closed.
    if ! command -v git >/dev/null 2>&1; then
      echo "Error: vcs_check_unavailable — git not on PATH but stored revision exists" >&2
      return 1
    fi

    if ! git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
      echo "Error: vcs_check_unavailable — not a git repo but stored revision exists" >&2
      return 1
    fi

    current_rev="$(git -C "$project_dir" rev-parse --short=12 HEAD 2>/dev/null)" || {
      echo "Error: vcs_check_failed — git rev-parse errored" >&2
      return 1
    }
    if [ -z "$current_rev" ]; then
      echo "Error: vcs_check_failed — git rev-parse returned empty" >&2
      return 1
    fi

    if [ "$stored_rev" != "$current_rev" ]; then
      echo "Error: vcs_moved_since_run — stored='$stored_rev' head='$current_rev'" >&2
      return 1
    fi
  fi
  # If stored_rev is empty/null, the run pre-dates VCS tracking; design §9.1
  # specifies this comparison only when run_started.vcs_revision != null.

  return 0
}