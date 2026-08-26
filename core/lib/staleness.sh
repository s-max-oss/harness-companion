#!/bin/bash
# staleness.sh — Evidence staleness checks (v2)
#
# Design §10: Evidence Staleness — three-axis staleness check:
#   Axis 1: Workspace fingerprint mismatch (current vs verified)
#   Axis 2: Config change (config_sha256 mismatch)
#   Axis 3: VCS revision change (vcs_revision mismatch)
#
# Usage:
#   source staleness.sh
#   ev_is_stale_by_fingerprint <run_id> [project_dir]     # Axis 1
#   ev_is_stale_by_config <run_id> [project_dir]           # Axis 2
#   ev_is_stale_by_vcs <run_id> [project_dir]              # Axis 3
#
# Each returns 0 (true = stale) or 1 (false = not stale).



# ---- Axis 1: Workspace fingerprint ----
ev_is_stale_by_fingerprint() {
  local run_id="$1"
  local project_dir="${2:-.}"
  local log_path="$project_dir/.harness/logs/runs/${run_id}.ndjson"

  if [ ! -f "$log_path" ]; then
    return 0  # missing log → stale
  fi

  # Load fingerprint script if available. FAIL-CLOSED: a missing required
  # dependency (workspace-fingerprint.sh or jq) means we cannot verify the
  # fingerprint axis, so the evidence is stale — never silently "fresh".
  local fp_script
  fp_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workspace-fingerprint.sh"
  if [ ! -f "$fp_script" ]; then
    echo "staleness: FAIL-CLOSED — workspace-fingerprint.sh missing; Axis1 treated as stale" >&2
    return 0
  fi
  # shellcheck source=workspace-fingerprint.sh
  source "$fp_script"

  if ! command -v jq >/dev/null 2>&1; then
    echo "staleness: FAIL-CLOSED — jq missing; Axis1 treated as stale" >&2
    return 0
  fi

  local verified_fp current_fp
  verified_fp="$(jq -r 'select(.event == "run_completed" or .event == "run_failed" or .event == "run_aborted") | .workspace_fingerprint_verified // empty' "$log_path" 2>/dev/null | tail -1)"
  if [ -z "$verified_fp" ]; then
    return 0  # no fingerprint in log → stale
  fi

  current_fp="$(compute_workspace_fingerprint "$project_dir")"
  if [ "$current_fp" != "$verified_fp" ]; then
    return 0  # mismatch → stale
  fi

  return 1  # match → not stale
}

# ---- Axis 2: Config SHA-256 ----
ev_is_stale_by_config() {
  local run_id="$1"
  local project_dir="${2:-.}"
  local log_path="$project_dir/.harness/logs/runs/${run_id}.ndjson"
  local config_path="$project_dir/.harness/config.json"

  if [ ! -f "$log_path" ]; then
    return 0
  fi
  # FAIL-CLOSED: jq missing → cannot verify the config axis → stale.
  if ! command -v jq >/dev/null 2>&1; then
    echo "staleness: FAIL-CLOSED — jq missing; Axis2 treated as stale" >&2
    return 0
  fi

  local stored_sha
  stored_sha="$(jq -r 'select(.event == "run_started") | .config_sha256 // empty' "$log_path" 2>/dev/null | head -1)"
  if [ -z "$stored_sha" ]; then
    return 0
  fi

  if [ ! -f "$config_path" ]; then
    return 0  # config deleted → stale
  fi

  local current_sha
  if command -v sha256sum >/dev/null 2>&1; then
    current_sha="sha256:$(sha256sum "$config_path" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    current_sha="sha256:$(shasum -a 256 "$config_path" | awk '{print $1}')"
  else
    echo "staleness: FAIL-CLOSED — no sha tool; Axis2 treated as stale" >&2
    return 0
  fi

  if [ "$stored_sha" != "$current_sha" ]; then
    return 0
  fi

  return 1
}

# ---- Axis 3: VCS revision ----
ev_is_stale_by_vcs() {
  local run_id="$1"
  local project_dir="${2:-.}"
  local log_path="$project_dir/.harness/logs/runs/${run_id}.ndjson"

  if [ ! -f "$log_path" ]; then
    return 0
  fi
  # FAIL-CLOSED: jq missing → cannot verify the VCS axis → stale.
  if ! command -v jq >/dev/null 2>&1; then
    echo "staleness: FAIL-CLOSED — jq missing; Axis3 treated as stale" >&2
    return 0
  fi

  local stored_rev
  stored_rev="$(jq -r 'select(.event == "run_started") | .vcs_revision // empty' "$log_path" 2>/dev/null | head -1)"

  if [ -z "$stored_rev" ] || [ "$stored_rev" = "null" ]; then
    # P0-14: in a GIT project a missing revision is unverifiable → stale
    # (fail-closed). Only non-git projects skip the axis — there is no revision
    # to record or compare.
    if command -v git >/dev/null 2>&1 && git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
      echo "staleness: FAIL-CLOSED — git project but run has no vcs_revision; Axis3 treated as stale" >&2
      return 0
    fi
    return 1  # non-git project → no stored revision → nothing to compare → not stale
  fi

  # A stored revision exists, so the axis must be verifiable. FAIL-CLOSED:
  # git missing or the project is not (any longer) a git repo → inconsistent,
  # cannot confirm the recorded revision → stale.
  if ! command -v git >/dev/null 2>&1; then
    echo "staleness: FAIL-CLOSED — git missing; Axis3 treated as stale" >&2
    return 0
  fi
  if ! git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "staleness: FAIL-CLOSED — stored vcs_revision but not a git repo; Axis3 treated as stale" >&2
    return 0
  fi

  local current_rev
  current_rev="$(git -C "$project_dir" rev-parse --short=12 HEAD 2>/dev/null || echo '')"

  if [ "$stored_rev" != "$current_rev" ]; then
    return 0
  fi

  return 1
}
