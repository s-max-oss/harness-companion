#!/bin/bash
# status-renderer.sh — Plain-text status & handoff renderer (v2)
#
# Phase 4: All business semantics live here so that ANY host adapter
# (Claude Code, Codex, Continue, Cursor) can reuse the same output.
#
# V2 SCHEMA (Phase 1-3 canonical):
#   - feature_list.json uses evidence_associations[] (with run_id), not
#     v1 .evidence[]. v1 legacy_audit_evidence is migration metadata only
#     and is NEVER treated as canonical passing evidence.
#   - Per-run canonical evidence lives at
#       <project>/.harness/logs/runs/<run_id>.ndjson
#     validated by core/lib/validate-run-log.sh (16-step canonical check).
#   - Staleness is checked via core/lib/staleness.sh (3 axes:
#     workspace_fingerprint, config_sha256, vcs_revision) and via
#     validate_run_log (canonical validity).
#   - Top-level .revision is the canonical monotonic counter.
#
# This lib emits plain text only. It has NO knowledge of Claude Code
# envelopes, Codex schemas, or any host protocol. Adapters must
# JSON-encode the result and wrap it in their host-specific envelope.
#
# Usage:
#   source status-renderer.sh
#   sr_status_text <project_dir>           # → plain-text status block on stdout
#   sr_handoff_warnings <project_dir>      # → plain-text warning block on stdout
#
# Returns 0 always. Empty stdout = "nothing to say".

set -u

# Source validate-run-log and staleness helpers if available.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate-run-log.sh
[ -f "$_LIB_DIR/validate-run-log.sh" ] && source "$_LIB_DIR/validate-run-log.sh"
# shellcheck source=staleness.sh
[ -f "$_LIB_DIR/staleness.sh" ] && source "$_LIB_DIR/staleness.sh"

# ============================================================
# File presence checks (SessionStart status block)
# ============================================================

_sr_file_line() {
  local dir="$1" path="$2" label="$3" sev="${4:-ok}"
  if [ -e "$dir/$path" ]; then
    printf -- '- [OK] %s: `%s`\n' "$label" "$path"
  else
    case "$sev" in
      optional)  printf -- '- [--] %s: `%s` (optional, missing)\n' "$label" "$path" ;;
      warn)      printf -- '- [!!] %s: `%s` missing (verify is disabled)\n' "$label" "$path" ;;
      *)         printf -- '- [NO] %s: `%s` MISSING\n' "$label" "$path" ;;
    esac
  fi
}

# ============================================================
# Feature statistics — v2 schema (evidence_associations)
# ============================================================

# _sr_feature_counts <project_dir>
#   Emits "total passing in_progress unverified" on stdout, 0s if jq missing.
_sr_feature_counts() {
  local dir="$1" fl="$dir/feature_list.json"
  if ! command -v jq >/dev/null 2>&1 || [ ! -f "$fl" ]; then
    printf '0 0 0 0'
    return 0
  fi
  local total passing in_progress unverified
  total="$(jq '.features | length' "$fl" 2>/dev/null || echo 0)"
  passing="$(jq '[.features[] | select(.status=="passing")] | length' "$fl" 2>/dev/null || echo 0)"
  in_progress="$(jq '[.features[] | select(.status=="in_progress")] | length' "$fl" 2>/dev/null || echo 0)"
  unverified="$(jq '[.features[] | select(.status=="unverified")] | length' "$fl" 2>/dev/null || echo 0)"
  printf '%s %s %s %s' "$total" "$passing" "$in_progress" "$unverified"
}

_sr_feature_stats_line() {
  local dir="$1"
  [ ! -f "$dir/feature_list.json" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local counts total passing in_progress unverified
  counts="$(_sr_feature_counts "$dir")"
  total="$(printf '%s' "$counts" | awk '{print $1}')"
  passing="$(printf '%s' "$counts" | awk '{print $2}')"
  in_progress="$(printf '%s' "$counts" | awk '{print $3}')"
  unverified="$(printf '%s' "$counts" | awk '{print $4}')"
  printf -- '- [i] Features: %s/%s passing, %s in_progress, %s unverified\n' \
    "$passing" "$total" "$in_progress" "$unverified"
}

# _sr_revision_line <project_dir>
#   Emits the top-level .revision counter so adapters can detect drift.
_sr_revision_line() {
  local dir="$1"
  [ ! -f "$dir/feature_list.json" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local rev
  rev="$(jq -r '.revision // 0' "$dir/feature_list.json" 2>/dev/null || echo 0)"
  printf -- '- [i] Registry revision: %s\n' "$rev"
}

# _sr_wip_violation_line <project_dir>
#   WIP=1 rule: more than one in_progress is a violation.
_sr_wip_violation_line() {
  local dir="$1"
  [ ! -f "$dir/feature_list.json" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local counts in_progress
  counts="$(_sr_feature_counts "$dir")"
  in_progress="$(printf '%s' "$counts" | awk '{print $3}')"
  if [ "$in_progress" -gt 1 ] 2>/dev/null; then
    printf -- '- [!!] WIP violation: %s features in_progress (WIP=1 rule broken!)\n' "$in_progress"
  fi
}

# _sr_passing_no_evidence_line <project_dir>
#   v2: a passing/unverified feature with ZERO evidence_associations has NO
#   canonical evidence. legacy_audit_evidence is migration metadata only.
_sr_passing_no_evidence_line() {
  local dir="$1"
  [ ! -f "$dir/feature_list.json" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local bad
  bad="$(jq '[.features[]
            | select((.status=="passing" or .status=="unverified")
                     and (((.evidence_associations // []) | length) == 0))]
            | length' \
    "$dir/feature_list.json" 2>/dev/null || echo 0)"
  if [ "$bad" -gt 0 ] 2>/dev/null; then
    printf -- '- [!!] %s passing/unverified features have NO evidence_associations\n' "$bad"
  fi
}

# ============================================================
# Handoff warnings (Stop hook block) — v2 schema
# ============================================================

_sr_uncommitted_files_line() {
  local dir="$1"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local n
    n="$(cd "$dir" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
      printf '[!!] %s uncommitted file(s) in this working tree. Decide whether to commit, stash, or leave them for the user.\n' "$n"
    fi
  fi
}

_sr_dangling_in_progress_line() {
  local dir="$1"
  [ ! -f "$dir/feature_list.json" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local list
  list="$(jq -r '.features[] | select(.status=="in_progress") | "  - \(.id): \(.title)"' \
    "$dir/feature_list.json" 2>/dev/null || true)"
  if [ -n "$list" ]; then
    printf '[!!] Features still in_progress - update their status before stopping:\n%s\n' "$list"
  fi
}

# _sr_passing_unverified_no_evidence_block <project_dir>
#   v2: a passing/unverified feature is canonical only when at least one
#   evidence_association exists. legacy_audit_evidence is migration info only.
_sr_passing_unverified_no_evidence_block() {
  local dir="$1"
  [ ! -f "$dir/feature_list.json" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local list
  list="$(jq -r '.features[]
                 | select((.status=="passing" or .status=="unverified")
                          and (((.evidence_associations // []) | length) == 0))
                 | "  - \(.id): \(.title)"' \
    "$dir/feature_list.json" 2>/dev/null || true)"
  if [ -n "$list" ]; then
    printf '[!!] These features are marked passing/unverified but have no canonical evidence_associations:\n%s\n' "$list"
  fi
}

# _sr_run_log_issue_block <project_dir>
#   For each passing feature, locate its latest evidence_association.run_id
#   and probe the corresponding NDJSON run log via validate_run_log +
#   staleness helpers. Emit [!!] blocks per-feature for missing / invalid /
#   stale run logs. The baseline SHA is read from
#   $HOME/.claude/harness-companion/baselines/<key>.json by the adapter
#   BEFORE calling this lib; for staleness we use the per-run
#   workspace_fingerprint / config_sha256 / vcs_revision comparison
#   (3-axis) instead of the old .evidence.commit baseline check.
_sr_run_log_issue_block() {
  local dir="$1"
  [ ! -f "$dir/feature_list.json" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v validate_run_log >/dev/null 2>&1 || return 0

  # Collect (id, run_id) pairs from latest evidence_associations on passing features.
  local pairs
  pairs="$(jq -r '.features[]
                 | select(.status=="passing")
                 | .id as $fid
                 | (.evidence_associations // []) as $assocs
                 | ($assocs | last) as $a
                 | select($a != null)
                 | "\($fid)\t\($a.run_id)"' \
    "$dir/feature_list.json" 2>/dev/null || true)"
  [ -z "$pairs" ] && return 0

  local any_issue=0
  local out=""
  while IFS=$'\t' read -r fid rid; do
    [ -z "$fid" ] || [ -z "$rid" ] && continue
    local log_path="$dir/.harness/logs/runs/${rid}.ndjson"
    local issue=""
    if [ ! -f "$log_path" ]; then
      issue="run_log_missing (no NDJSON at $log_path)"
    else
      local validation
      if ! validation="$(validate_run_log "$rid" "$dir" 2>/dev/null)"; then
        local reason
        reason="$(printf '%s' "$validation" | jq -r '.reason // "invalid"')"
        issue="run_log_invalid ($reason)"
      elif command -v ev_is_stale_by_fingerprint >/dev/null 2>&1; then
        if ev_is_stale_by_fingerprint "$rid" "$dir" 2>/dev/null; then
          issue="stale_by_fingerprint"
        elif ev_is_stale_by_config "$rid" "$dir" 2>/dev/null; then
          issue="stale_by_config"
        elif ev_is_stale_by_vcs "$rid" "$dir" 2>/dev/null; then
          issue="stale_by_vcs"
        fi
      fi
    fi
    if [ -n "$issue" ]; then
      out+="  - $fid (run $rid): $issue"$'\n'
      any_issue=1
    fi
  done <<<"$pairs"

  if [ "$any_issue" = "1" ]; then
    printf '[!!] Some passing features have run-log issues (validate via core/lib/validate-run-log.sh + staleness.sh):\n%s' "$out"
  fi
}

_sr_checklist_reminder_line() {
  local dir="$1"
  if [ -f "$dir/checklist.sh" ]; then
    printf '[i] Run `bash checklist.sh` to verify a clean handoff.\n'
  else
    printf '[i] Consider running `/harness:handoff` before ending the session.\n'
  fi
}

# ============================================================
# Public API
# ============================================================

sr_status_text() {
  local dir="${1:-.}"
  [ ! -d "$dir" ] && return 0
  [ ! -f "$dir/feature_list.json" ] && return 0

  local out
  out="$(printf '## Harness Status - %s\n\n' "$(basename "$(cd "$dir" && pwd)")")"

  out+="$(_sr_file_line "$dir" "AGENTS.md" "Knowledge")"
  out+="$(_sr_file_line "$dir" "CLAUDE.md" "Knowledge")"
  out+="$(_sr_file_line "$dir" "init.sh" "Environment")"
  out+="$(_sr_file_line "$dir" ".harness/config.json" "Verification config" warn)"
  out+="$(_sr_file_line "$dir" "feature_list.json" "Scope")"

  local pair f label
  for pair in "claude-progress.md:Progress" \
              "session-handoff.md:Handoff" \
              "clean-state-checklist.md:Handoff (checklist)" \
              "checklist.sh:Handoff (checklist.sh)"; do
    f="${pair%:*}"
    label="${pair#*:}"
    out+="$(_sr_file_line "$dir" "$f" "$label" optional)"
  done

  out+="$(_sr_revision_line "$dir")"
  out+="$(_sr_feature_stats_line "$dir")"
  out+="$(_sr_wip_violation_line "$dir")"
  out+="$(_sr_passing_no_evidence_line "$dir")"

  out+=$'\nUse `/harness:status` for the detailed dashboard.\n'

  printf '%s' "$out"
}

sr_handoff_warnings() {
  local dir="${1:-.}"
  [ ! -d "$dir" ] && return 0
  [ ! -f "$dir/feature_list.json" ] && return 0

  local out

  out+="$(_sr_uncommitted_files_line "$dir")"
  out+="$(_sr_dangling_in_progress_line "$dir")"
  out+="$(_sr_passing_unverified_no_evidence_block "$dir")"
  out+="$(_sr_run_log_issue_block "$dir")"
  out+="$(_sr_checklist_reminder_line "$dir")"

  printf '%s' "$out"
}