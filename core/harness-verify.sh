#!/bin/bash
# harness-verify.sh — Canonical evidence model verification (v2)
#
# Design §2: Canonical Evidence Data Model
# Writes per-run NDJSON log to .harness/logs/runs/<run_id>.ndjson.
#
# Usage:
#   bash harness-verify.sh [feature_id] [project_dir] [--write]
#
# Exit codes:
#   0  all required commands passed
#   1  at least one required command failed OR no_checks (0 required steps)
#   2  config not found, or jq missing
#
# v2 key changes:
#   - Canonical NDJSON run log (5 event types)
#   - capability_level computed by core (not from config)
#   - workspace fingerprint with git diff (not git diff HEAD)
#   - NUL-delimited temp file outside fingerprint scope
#   - 0-step projects produce run_completed with overall_result: "no_checks"

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/evidence.sh
source "$SKILL_DIR/lib/evidence.sh"
# shellcheck source=lib/validate-run-log.sh
source "$SKILL_DIR/lib/validate-run-log.sh"
# shellcheck source=lib/workspace-fingerprint.sh
source "$SKILL_DIR/lib/workspace-fingerprint.sh"
# shellcheck source=lib/json-helpers.sh
source "$SKILL_DIR/lib/json-helpers.sh"
# shellcheck source=lib/harness-config.sh
source "$SKILL_DIR/lib/harness-config.sh"
# shellcheck source=lib/passing.sh
source "$SKILL_DIR/lib/passing.sh"
# shellcheck source=lib/atomic_write.sh
source "$SKILL_DIR/lib/atomic_write.sh"
# shellcheck source=lib/lock-registry.sh
source "$SKILL_DIR/lib/lock-registry.sh"
# shellcheck source=lib/registry-journal.sh
source "$SKILL_DIR/lib/registry-journal.sh"
# shellcheck source=lib/runtime-manifest.sh
source "$SKILL_DIR/lib/runtime-manifest.sh"

# Keep -e off so command failures are captured, not shell-killing
set +e

register_run_or_die() {
  if ! runtime_register_run "$PROJECT_DIR" "$RUN_ID"; then
    echo "FATAL: failed to register runtime artifacts for run '$RUN_ID'" >&2
    exit 2
  fi
}

FEATURE_ID=""
TARGET="."
WRITE="false"
# Parse args: positional [feature_id] [project_dir], plus flags --write/--help/-h.
# Flags may appear anywhere; positional order is feature_id then project_dir.
positional_count=0
for arg in "$@"; do
  case "$arg" in
    --write) WRITE="true" ;;
    --help|-h)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    -*)
      # Unknown flag — reject so it can't be confused with a positional.
      echo "Error: unknown flag '$arg'" >&2
      exit 2
      ;;
    *)
      positional_count=$((positional_count + 1))
      case "$positional_count" in
        1) FEATURE_ID="$arg" ;;
        2) TARGET="$arg" ;;
        *)
          echo "Error: unexpected positional argument '$arg'" >&2
          exit 2
          ;;
      esac
      ;;
  esac
done

if [ ! -d "$TARGET" ]; then
  echo "Error: directory '$TARGET' not found" >&2
  exit 2
fi

if [ -z "$FEATURE_ID" ]; then
  echo "Usage: harness-verify.sh <feature_id> [project_dir] [--write]" >&2
  echo "Refusing to run without an explicit feature id." >&2
  exit 2
fi

# Normalize path for Windows Git Bash (cygpath -u converts C:\... → /c/...)
if command -v cygpath >/dev/null 2>&1; then
  TARGET="$(cygpath -u "$TARGET" 2>/dev/null || printf '%s' "$TARGET")"
fi
cd "$TARGET" || { echo "Error: cannot cd to '$TARGET'" >&2; exit 2; }
PROJECT_DIR="$(pwd)"
# Double-normalize: pwd on some Windows setups can still emit C:/ style
if command -v cygpath >/dev/null 2>&1; then
  PROJECT_DIR="$(cygpath -u "$PROJECT_DIR" 2>/dev/null || printf '%s' "$PROJECT_DIR")"
fi
FL="$PROJECT_DIR/feature_list.json"

# ---- Prerequisites ----
if [ ! -f "$FL" ]; then
  echo "Error: feature_list.json not found in $PROJECT_DIR" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for /harness:verify." >&2
  echo "Install: winget install jqlang.jq (Windows) | brew install jq (macOS) | apt-get install jq (Linux)" >&2
  exit 2
fi

# Load config
if ! hc_load "$PROJECT_DIR"; then
  echo "Error: .harness/config.json not found in $PROJECT_DIR." >&2
  echo "Run /harness:init to scaffold one." >&2
  exit 2
fi

# Validate config schema (Phase 2.4) — must succeed before we proceed.
# Skips silently if validator not present (compat: validator added in Phase 2).
if [ -f "$SKILL_DIR/lib/config-validate.sh" ]; then
  # shellcheck source=lib/config-validate.sh
  source "$SKILL_DIR/lib/config-validate.sh"
  if ! validate_config_schema "$HC_CONFIG_DIR/.harness/config.json" 2>/dev/null; then
    echo "Error: .harness/config.json failed schema validation." >&2
    validate_config_schema "$HC_CONFIG_DIR/.harness/config.json" >&2 || true
    exit 2
  fi
fi

# Quick feature existence check
if ! jq -e --arg id "$FEATURE_ID" '.features[] | select(.id == $id)' "$FL" >/dev/null 2>&1; then
  echo "Error: feature '$FEATURE_ID' not found in feature_list.json" >&2
  exit 2
fi

# ---- Compute capability_level (core, not from config) ----
CAPABILITY_LEVEL="$(hc_compute_capability_level "$PROJECT_DIR")"

# ---- Generate run_id ----
RUN_ID="$(generate_run_id)"

# ---- Compute workspace fingerprint (initial) ----
WORKSPACE_FP_INITIAL="$(compute_workspace_fingerprint "$PROJECT_DIR")"

# ---- Compute config SHA-256 ----
CONFIG_SHA="$(hc_config_sha256 "$PROJECT_DIR")"

# ---- Build required_command_ids (only required_for_passing commands) ----
REQUIRED_IDS=()
while IFS= read -r cid; do
  cid="${cid%$'\r'}"
  [ -n "$cid" ] && REQUIRED_IDS+=("$cid")
done <<<"$(hc_required_ids)"

# ---- Build all command IDs (entire verification plan) ----
ALL_IDS=()
while IFS= read -r cid; do
  cid="${cid%$'\r'}"
  [ -n "$cid" ] && ALL_IDS+=("$cid")
done <<<"$(hc_command_ids)"

# ---- VCS info ----
VCS_REVISION="null"
VCS_REVISION_SOURCE="null"
if git rev-parse --git-dir >/dev/null 2>&1; then
  VCS_REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || echo 'null')"
  VCS_REVISION_SOURCE="git"
fi

# ---- Ensure run directory ----
RUN_DIR="$(ev_ensure_run_dir "$PROJECT_DIR" "$RUN_ID")"

# ---- Write run_started event ----
REQUIRED_IDS_JSON="$(printf '%s\n' "${REQUIRED_IDS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')"

RUN_STARTED="$(jq -n \
  --arg event "run_started" \
  --argjson schema_version 2 \
  --arg run_id "$RUN_ID" \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg project_root "$PROJECT_DIR" \
  --arg vcs_revision "$VCS_REVISION" \
  --arg vcs_revision_source "$VCS_REVISION_SOURCE" \
  --arg workspace_fingerprint_initial "$WORKSPACE_FP_INITIAL" \
  --arg config_sha256 "$CONFIG_SHA" \
  --argjson required_command_ids "$REQUIRED_IDS_JSON" \
  --argjson capability_level "$CAPABILITY_LEVEL" \
  --arg feature_id "$FEATURE_ID" \
  '{
    event: $event,
    schema_version: $schema_version,
    run_id: $run_id,
    started_at: $started_at,
    project_root: $project_root,
    vcs_revision: (if $vcs_revision == "null" then null else $vcs_revision end),
    vcs_revision_source: (if $vcs_revision_source == "null" then null else $vcs_revision_source end),
    workspace_fingerprint_initial: $workspace_fingerprint_initial,
    config_sha256: $config_sha256,
    required_command_ids: $required_command_ids,
    capability_level: $capability_level,
    feature_id: (if $feature_id == "" then null else $feature_id end)
  }')"

if ! ev_write_run_started "$RUN_ID" "$RUN_STARTED"; then
  echo "FATAL: failed to write run_started event to canonical log" >&2
  exit 2
fi

# ---- Execute commands ----
echo "=== Harness Verify v2 ==="
echo "Project:     $(basename "$PROJECT_DIR")"
echo "Type:        $HC_TYPE"
echo "Feature:     $FEATURE_ID"
echo "Capability:  Level $CAPABILITY_LEVEL"
echo "Run ID:      $RUN_ID"
echo "Write:       $WRITE"
echo ""

PASSED=0
FAILED=0
SKIPPED=0
FAILED_IDS=()
EXECUTED=0
NOT_APPLICABLE_IDS=()

# Use a file descriptor to isolate the loop from commands that read stdin.
# The <<< here-string would be consumed by test scripts, truncating the loop
# after ~5 commands. We open the command list on fd 3 and read from there,
# while every executed command gets </dev/null so it cannot steal the list.
exec 3<<<"$(printf '%s\n' "${ALL_IDS[@]}")"

while IFS= read -r -u 3 cmd_id; do
  [ -z "$cmd_id" ] && continue
  CMD_JSON="$(hc_command_for "$cmd_id")"
  if [ -z "$CMD_JSON" ]; then continue; fi

  APPLIES="$(hc_applies "$CMD_JSON")"
  REQUIRED="$(printf '%s' "$CMD_JSON" | jq -r '.required_for_passing // false')"
  CMD_ORIGIN="$(printf '%s' "$CMD_JSON" | jq -r '.command_origin // "configured"')"
  CONFIRMATION="$(printf '%s' "$CMD_JSON" | jq -r '.confirmation // "not_required"')"

  if [ "$APPLIES" != "true" ]; then
    echo "[skip] $cmd_id: not_applicable (predicate false)"
    # E5 unification: a required command with predicate=false is not_applicable.
    # It is tracked here and EXCLUDED from the effective required set at the
    # coverage gate (and by validate-run-log step 13). Every OTHER required
    # command that is skipped for any other reason still fails the gate.
    NOT_APPLICABLE_IDS+=("$cmd_id")
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # ---- Phase 2 R4.3: origin/confirmation enforcement --------------------
  # detected+pending and detected+rejected MUST NOT execute (design §12).
  # harness-verify MUST NOT auto-promote pending → confirmed after execution.
  # This gate is intentionally a "skip" (not "fail"): an unconfirmed command
  # has not been authorized to run yet; it is not a verification failure.
  if [ "$CMD_ORIGIN" = "detected" ]; then
    case "$CONFIRMATION" in
      not_required|confirmed)
        # OK to execute: detected but user has confirmed (or treats as confirmed)
        : ;;
      pending)
        echo "[skip] $cmd_id: detected+pending — user review required before execution"
        SKIPPED=$((SKIPPED + 1))
        continue
        ;;
      rejected)
        echo "[skip] $cmd_id: detected+rejected — user has rejected this command"
        SKIPPED=$((SKIPPED + 1))
        continue
        ;;
      *)
        echo "[fail] $cmd_id: invalid confirmation '$CONFIRMATION' (must be not_required|pending|confirmed|rejected)"
        FAILED=$((FAILED + 1))
        FAILED_IDS+=("$cmd_id")
        continue
        ;;
    esac
  fi
  # configured origin: all confirmation values are accepted by default. Users
  # MAY downgrade a configured command to pending/rejected to soft-disable it.
  # ------------------------------------------------------------------------

  # Build argv array
  ARGV=()
  while IFS= read -r tok; do
    [ -n "$tok" ] && ARGV+=("$tok")
  done <<<"$(printf '%s' "$CMD_JSON" | jq -r '.command[]' | tr -d '\r')"

  if [ "${#ARGV[@]}" -eq 0 ]; then
    echo "[fail] $cmd_id: cannot determine command"
    FAILED=$((FAILED + 1))
    FAILED_IDS+=("$cmd_id")
    continue
  fi

  # Check tool availability — required commands fail-closed (Issue 6)
  if [ ! -x "${ARGV[0]}" ] && ! command -v "${ARGV[0]}" >/dev/null 2>&1; then
    if [ "$REQUIRED" = "true" ]; then
      echo "[fail] $cmd_id: ${ARGV[0]} not found on PATH (required_for_passing)"
      FAILED=$((FAILED + 1))
      EXECUTED=$((EXECUTED + 1))
      FAILED_IDS+=("$cmd_id")
      # Write a command_completed event with exit_code=127 (command not found)
      # so the canonical log remains structurally complete
      CMD_ORIGIN="$(printf '%s' "$CMD_JSON" | jq -r '.command_origin // "configured"')"
      CONFIRMATION="not_required"
      if [ "$CMD_ORIGIN" = "detected" ]; then
        CONFIRMATION="confirmed"
      fi
      MISSING_TOOL_EVENT="$(jq -n \
        --arg event "command_completed" \
        --argjson schema_version 2 \
        --arg run_id "$RUN_ID" \
        --arg command_id "$cmd_id" \
        --argjson command "$(printf '%s' "$CMD_JSON" | jq '.command')" \
        --arg command_origin "$CMD_ORIGIN" \
        --arg confirmation "$CONFIRMATION" \
        --argjson exit_code 127 \
        --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson duration_ms 0 \
        --arg log_artifact "" \
        --arg log_sha256 "null" \
        '{
          event: $event,
          schema_version: $schema_version,
          run_id: $run_id,
          command_id: $command_id,
          command: $command,
          command_origin: $command_origin,
          confirmation: $confirmation,
          exit_code: $exit_code,
          started_at: $started_at,
          duration_ms: $duration_ms,
          log_artifact: $log_artifact,
          log_sha256: (if $log_sha256 == "null" then null else $log_sha256 end)
        }')"
      if ! ev_write_command_completed "$RUN_ID" "$MISSING_TOOL_EVENT"; then
        # Evidence write failed — try to write run_aborted
        ABORT_EVENT="$(jq -n \
          --arg event "run_aborted" \
          --argjson schema_version 2 \
          --arg run_id "$RUN_ID" \
          --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg overall_result "aborted" \
          --arg abort_reason "evidence_write_failed: command_completed for missing tool $cmd_id" \
          --argjson planned_commands "${#ALL_IDS[@]}" \
          --argjson executed_commands "$EXECUTED" \
          --argjson passed_commands "$PASSED" \
          --argjson failed_commands "$((FAILED))" \
          --argjson skipped_commands "$SKIPPED" \
          '{
            event: $event,
            schema_version: $schema_version,
            run_id: $run_id,
            completed_at: $completed_at,
            overall_result: $overall_result,
            abort_reason: $abort_reason,
            planned_commands: $planned_commands,
            executed_commands: $executed_commands,
            passed_commands: $passed_commands,
            failed_commands: $failed_commands,
            skipped_commands: $skipped_commands
          }')"
        if ev_write_terminal "$RUN_ID" "$ABORT_EVENT"; then
          register_run_or_die
        fi
        echo "FATAL: failed to write command_completed event for $cmd_id" >&2
        exit 2
      fi
      continue
    else
      echo "[skip] $cmd_id: ${ARGV[0]} not found on PATH (optional)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  # Prepare log artifact path
  LOG_FILE="$RUN_DIR/${cmd_id}.log"

  # Resolve timeout from the configured contract (no env-var override — the
  # effective timeout is always written into the run's auditable config_sha256).
  TIMEOUT_SECS="$(printf '%s' "$CMD_JSON" | jq -r '.timeout_seconds // 300')"

  START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  START_MS="$(date +%s)000"

  echo "[run]   $cmd_id: ${ARGV[*]}"

  EXIT_CODE=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "${TIMEOUT_SECS}s" "${ARGV[@]}" </dev/null >"$LOG_FILE" 2>&1
    EXIT_CODE=$?
  else
    "${ARGV[@]}" </dev/null >"$LOG_FILE" 2>&1
    EXIT_CODE=$?
  fi

  END_MS="$(date +%s)000"
  DURATION_MS=$((END_MS - START_MS))
  EXECUTED=$((EXECUTED + 1))

  # Determine command_origin + confirmation
  # configured commands: not_required; detected: confirmed after execution
  CMD_ORIGIN="$(printf '%s' "$CMD_JSON" | jq -r '.command_origin // "configured"')"
  CONFIRMATION="not_required"
  if [ "$CMD_ORIGIN" = "detected" ]; then
    CONFIRMATION="confirmed"
  fi

  # Build canonical command_completed event
  LOG_SHA="$(ev_file_sha256 "$LOG_FILE")"

  CMD_EVENT="$(jq -n \
    --arg event "command_completed" \
    --argjson schema_version 2 \
    --arg run_id "$RUN_ID" \
    --arg command_id "$cmd_id" \
    --argjson command "$(printf '%s' "$CMD_JSON" | jq '.command')" \
    --arg command_origin "$CMD_ORIGIN" \
    --arg confirmation "$CONFIRMATION" \
    --argjson exit_code "$EXIT_CODE" \
    --arg started_at "$START_TS" \
    --argjson duration_ms "$DURATION_MS" \
    --arg log_artifact "$LOG_FILE" \
    --arg log_sha256 "$LOG_SHA" \
    '{
      event: $event,
      schema_version: $schema_version,
      run_id: $run_id,
      command_id: $command_id,
      command: $command,
      command_origin: $command_origin,
      confirmation: $confirmation,
      exit_code: $exit_code,
      started_at: $started_at,
      duration_ms: $duration_ms,
      log_artifact: $log_artifact,
      log_sha256: (if $log_sha256 == "null" then null else $log_sha256 end)
    }')"

  if ! ev_write_command_completed "$RUN_ID" "$CMD_EVENT"; then
    # Evidence write failed — try to write run_aborted, then bail
    ABORT_EVENT="$(jq -n \
      --arg event "run_aborted" \
      --argjson schema_version 2 \
      --arg run_id "$RUN_ID" \
      --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg overall_result "aborted" \
      --arg abort_reason "evidence_write_failed: command_completed for $cmd_id" \
      --argjson planned_commands "${#ALL_IDS[@]}" \
      --argjson executed_commands "$EXECUTED" \
      --argjson passed_commands "$PASSED" \
      --argjson failed_commands "$FAILED" \
      --argjson skipped_commands "$SKIPPED" \
      '{
        event: $event,
        schema_version: $schema_version,
        run_id: $run_id,
        completed_at: $completed_at,
        overall_result: $overall_result,
        abort_reason: $abort_reason,
        planned_commands: $planned_commands,
        executed_commands: $executed_commands,
        passed_commands: $passed_commands,
        failed_commands: $failed_commands,
        skipped_commands: $skipped_commands
      }')"
    if ev_write_terminal "$RUN_ID" "$ABORT_EVENT"; then
      register_run_or_die
    fi
    echo "FATAL: failed to write command_completed event for $cmd_id" >&2
    exit 2
  fi

  if [ "$EXIT_CODE" = "0" ]; then
    echo "[pass]  $cmd_id (exit 0, ${DURATION_MS}ms)"
    PASSED=$((PASSED + 1))
  else
    echo "[fail]  $cmd_id (exit $EXIT_CODE, ${DURATION_MS}ms) — log: $LOG_FILE"
    FAILED=$((FAILED + 1))
    FAILED_IDS+=("$cmd_id")
  fi
done

# Close fd 3
exec 3<&-

# ---- Effective required set (P0-3) ----
# effective required = required_command_ids − not_applicable_command_ids.
# Computed ONCE here, before terminal dispatch, so every downstream consumer
# (the no_checks decision below and the required-coverage gate) uses the SAME
# value. A required command with predicate=false is not_applicable and
# contributes nothing to the effective set; a required command that is
# applicable but never executed still counts, and the coverage gate fails on it.
EFFECTIVE_REQUIRED=()
for req_id in "${REQUIRED_IDS[@]}"; do
  [ -z "$req_id" ] && continue
  if printf '%s\n' "${NOT_APPLICABLE_IDS[@]}" | grep -qxF "$req_id"; then
    continue
  fi
  EFFECTIVE_REQUIRED+=("$req_id")
done

# ---- Compute workspace fingerprint (verified) ----
# Terminal event append must NOT change fingerprint (harness artifacts excluded)
WORKSPACE_FP_VERIFIED="$(compute_workspace_fingerprint "$PROJECT_DIR")"

# ---- Write terminal event ----
PLANNED="${#ALL_IDS[@]}"
COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# E5 unification: serialize the not_applicable command ids for every terminal
# event. Present on ALL terminals so the coverage check downstream (both the
# gate here and validate-run-log step 13) can compute the effective required
# set = required_command_ids − not_applicable_command_ids.
NA_JSON="$(printf '%s\n' "${NOT_APPLICABLE_IDS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')"

echo ""
echo "───────────────────────────────────────"

if [ "$PLANNED" -eq 0 ]; then
  # ---- no_checks path (no commands at all in the plan) ----
  TERMINAL="$(jq -n \
    --arg event "run_completed" \
    --argjson schema_version 2 \
    --arg run_id "$RUN_ID" \
    --arg completed_at "$COMPLETED_AT" \
    --arg overall_result "no_checks" \
    --arg workspace_fingerprint_verified "$WORKSPACE_FP_VERIFIED" \
    --argjson planned_commands 0 \
    --argjson executed_commands "$EXECUTED" \
    --argjson passed_commands "$PASSED" \
    --argjson failed_commands "$FAILED" \
    --argjson skipped_commands "$SKIPPED" \
    --argjson not_applicable_command_ids "$NA_JSON" \
    '{
      event: $event,
      schema_version: $schema_version,
      run_id: $run_id,
      completed_at: $completed_at,
      overall_result: $overall_result,
      workspace_fingerprint_verified: $workspace_fingerprint_verified,
      planned_commands: $planned_commands,
      executed_commands: $executed_commands,
      passed_commands: $passed_commands,
      failed_commands: $failed_commands,
      skipped_commands: $skipped_commands,
      not_applicable_command_ids: $not_applicable_command_ids
    }')"

  if ! ev_write_terminal "$RUN_ID" "$TERMINAL"; then
    echo "FATAL: failed to write run_completed (no_checks) terminal event" >&2
    exit 2
  fi
  register_run_or_die
  echo "Result: no_checks (0 verification steps configured)"
  echo "Add verification commands to .harness/config.json to enable passing eligibility."
elif [ "${#EFFECTIVE_REQUIRED[@]}" -eq 0 ]; then
  # ---- no_checks path (0 EFFECTIVE required steps) ----
  # P0-3: the no_checks decision is the EFFECTIVE required set, NOT the raw
  # required list. Two distinct reasons land here:
  #   (a) no required commands at all (optional-only config), OR
  #   (b) every required command was not_applicable (predicate=false) — the run
  #       executed no applicable required check and MUST NOT report "passed".
  # Either way the terminal is overall_result="no_checks" and the exit is
  # NON-passing (1) — never a passed run with zero effective checks.
  TERMINAL="$(jq -n \
    --arg event "run_completed" \
    --argjson schema_version 2 \
    --arg run_id "$RUN_ID" \
    --arg completed_at "$COMPLETED_AT" \
    --arg overall_result "no_checks" \
    --arg workspace_fingerprint_verified "$WORKSPACE_FP_VERIFIED" \
    --argjson planned_commands "$PLANNED" \
    --argjson executed_commands "$EXECUTED" \
    --argjson passed_commands "$PASSED" \
    --argjson failed_commands "$FAILED" \
    --argjson skipped_commands "$SKIPPED" \
    --argjson not_applicable_command_ids "$NA_JSON" \
    '{
      event: $event,
      schema_version: $schema_version,
      run_id: $run_id,
      completed_at: $completed_at,
      overall_result: $overall_result,
      workspace_fingerprint_verified: $workspace_fingerprint_verified,
      planned_commands: $planned_commands,
      executed_commands: $executed_commands,
      passed_commands: $passed_commands,
      failed_commands: $failed_commands,
      skipped_commands: $skipped_commands,
      not_applicable_command_ids: $not_applicable_command_ids
    }')"

  if ! ev_write_terminal "$RUN_ID" "$TERMINAL"; then
    echo "FATAL: failed to write run_completed (no_checks) terminal event" >&2
    exit 2
  fi
  register_run_or_die
  if [ "${#REQUIRED_IDS[@]}" -eq 0 ]; then
    echo "Result: no_checks (0 required verification steps — only optional commands configured)"
    echo "Mark at least one command required_for_passing: true to enable passing eligibility."
  else
    echo "Result: no_checks (0 effective required steps — every required command was not_applicable)"
    echo "A run with no applicable required checks is NOT passing."
  fi

elif [ "$FAILED" -gt 0 ]; then
  # ---- run_failed path ----
  FAILED_IDS_JSON="$(printf '%s\n' "${FAILED_IDS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')"

  TERMINAL="$(jq -n \
    --arg event "run_failed" \
    --argjson schema_version 2 \
    --arg run_id "$RUN_ID" \
    --arg completed_at "$COMPLETED_AT" \
    --arg overall_result "failed" \
    --arg workspace_fingerprint_verified "$WORKSPACE_FP_VERIFIED" \
    --argjson planned_commands "$PLANNED" \
    --argjson executed_commands "$EXECUTED" \
    --argjson passed_commands "$PASSED" \
    --argjson failed_commands "$FAILED" \
    --argjson skipped_commands "$SKIPPED" \
    --argjson not_applicable_command_ids "$NA_JSON" \
    --argjson failed_command_ids "$FAILED_IDS_JSON" \
    '{
      event: $event,
      schema_version: $schema_version,
      run_id: $run_id,
      completed_at: $completed_at,
      overall_result: $overall_result,
      workspace_fingerprint_verified: $workspace_fingerprint_verified,
      planned_commands: $planned_commands,
      executed_commands: $executed_commands,
      passed_commands: $passed_commands,
      failed_commands: $failed_commands,
      skipped_commands: $skipped_commands,
      failed_command_ids: $failed_command_ids,
      not_applicable_command_ids: $not_applicable_command_ids
    }')"

  if ! ev_write_terminal "$RUN_ID" "$TERMINAL"; then
    echo "FATAL: failed to write run_failed terminal event" >&2
    exit 2
  fi
  register_run_or_die
  echo "Result: FAILED ($FAILED command(s) failed)"
  echo "Failed: ${FAILED_IDS[*]}"

else
  # ---- Required-coverage gate: every applicable required command MUST run ----
  # E5 unification: a required command with predicate=false is "not_applicable"
  # and is excluded from the effective required set (see NOT_APPLICABLE_IDS).
  # But ANY other required command that was skipped/never-executed (e.g.
  # detected+pending, or an earlier command consumed the loop's stdin) is an
  # applicable-but-missed command and STILL fails the gate — the run is not
  # passed while coverage of an applicable required command is incomplete.
  # EFFECTIVE_REQUIRED was computed ONCE before terminal dispatch (see above),
  # so this branch and the no_checks branch share the exact same set.
  MISSING_REQUIRED=()
  for req_id in "${EFFECTIVE_REQUIRED[@]}"; do
    [ -z "$req_id" ] && continue
    if ! grep -q "\"command_id\":\"$req_id\"" ".harness/logs/runs/${RUN_ID}.ndjson" 2>/dev/null; then
      MISSING_REQUIRED+=("$req_id")
    fi
  done

  if [ "${#MISSING_REQUIRED[@]}" -gt 0 ]; then
    echo "[FAIL] Required-coverage gate: ${#MISSING_REQUIRED[@]} required command(s) not executed: ${MISSING_REQUIRED[*]}"
    MISSING_JSON="$(printf '%s
' "${MISSING_REQUIRED[@]}" | jq -R -s 'split("
") | map(select(length > 0))')"
    TERMINAL="$(jq -n --arg event "run_failed" --argjson schema_version 2 --arg run_id "$RUN_ID" --arg completed_at "$COMPLETED_AT" --arg overall_result "failed" --arg workspace_fingerprint_verified "$WORKSPACE_FP_VERIFIED" --argjson planned_commands "$PLANNED" --argjson executed_commands "$EXECUTED" --argjson passed_commands "$PASSED" --argjson failed_commands "$FAILED" --argjson skipped_commands "$SKIPPED" --argjson failed_command_ids "$MISSING_JSON" --argjson not_applicable_command_ids "$NA_JSON" '{
      event: $event,
      schema_version: $schema_version,
      run_id: $run_id,
      completed_at: $completed_at,
      overall_result: $overall_result,
      workspace_fingerprint_verified: $workspace_fingerprint_verified,
      planned_commands: $planned_commands,
      executed_commands: $executed_commands,
      passed_commands: $passed_commands,
      failed_commands: $failed_commands,
      skipped_commands: $skipped_commands,
      failed_command_ids: $failed_command_ids,
      not_applicable_command_ids: $not_applicable_command_ids
    }')"
    if ! ev_write_terminal "$RUN_ID" "$TERMINAL"; then
      echo "FATAL: failed to write run_failed terminal event" >&2
      exit 2
    fi
    echo "Result: FAILED (required-coverage: ${#MISSING_REQUIRED[@]} required command(s) never executed)"
    register_run_or_die
    exit 1
  fi

  # ---- run_completed (passed) path ----
  TERMINAL="$(jq -n --arg event "run_completed" --argjson schema_version 2 --arg run_id "$RUN_ID" --arg completed_at "$COMPLETED_AT" --arg overall_result "passed" --arg workspace_fingerprint_verified "$WORKSPACE_FP_VERIFIED" --argjson planned_commands "$PLANNED" --argjson executed_commands "$EXECUTED" --argjson passed_commands "$PASSED" --argjson failed_commands "$FAILED" --argjson skipped_commands "$SKIPPED" --argjson not_applicable_command_ids "$NA_JSON" '{
      event: $event,
      schema_version: $schema_version,
      run_id: $run_id,
      completed_at: $completed_at,
      overall_result: $overall_result,
      workspace_fingerprint_verified: $workspace_fingerprint_verified,
      planned_commands: $planned_commands,
      executed_commands: $executed_commands,
      passed_commands: $passed_commands,
      failed_commands: $failed_commands,
      skipped_commands: $skipped_commands,
      not_applicable_command_ids: $not_applicable_command_ids
    }')"

  if ! ev_write_terminal "$RUN_ID" "$TERMINAL"; then
    echo "FATAL: failed to write run_completed (passed) terminal event" >&2
    exit 2
  fi
  register_run_or_die

  # ---- Optionally update feature_list.json ----
  if [ "$WRITE" = "true" ]; then
    echo "Evidence written to .harness/logs/runs/${RUN_ID}.ndjson"

    # Create evidence association
    TODAY="$(date +%Y-%m-%d)"
    ASSOC="$(jq -n --arg run_id "$RUN_ID" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
      run_id: $run_id,
      associated_at: $at,
      associated_by: "user"
    }')"

    new_content=""
    # ---- Lock the registry for the read-modify-write ----
    # Two concurrent --write invocations must serialize. Without the lock,
    # last-writer-wins and one association is lost. The lock is scoped to
    # .harness/.registry.lock/ and is keyed by token (release is owner-safe).
    LOCK_DIR="$PROJECT_DIR/.harness/.registry.lock"
    # Parent .harness/ is guaranteed to exist at this point (logs dir was
    # created above). The lock primitive uses plain mkdir for POSIX-atomic
    # mutual exclusion, so the parent must pre-exist.
    # IMPORTANT: a sibling lock (runtime-manifest) holds a sub-leaf under
    # this same parent. If that sibling recently released while holding the
    # leaf, the leaf is gone — but it may have left the PARENT empty if
    # nothing else was inside. The mkdir-acquire backend treats an empty
    # leaf as "locked by unknown owner" (no metadata → stale-recovery
    # can't evaluate), and the 10s timeout burns down. Detect that case
    # (parent exists but empty) and rmdir it so the backend can claim it
    # cleanly. Safe: empty parent = no other holder can exist on any path.
    if [ -d "$LOCK_DIR" ] && [ -z "$(ls -A "$LOCK_DIR" 2>/dev/null)" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    # IMPORTANT: do NOT wrap acquire_lock in $(...) — for the flock backend,
    # the FD that holds the kernel lock must outlive the subshell. Calling
    # acquire_lock directly keeps FD 9 open in this shell; the token is
    # exposed via $LOCK_REGISTRY_TOKEN. release_lock reads from env (or 2nd
    # arg).
    acquire_lock "$LOCK_DIR" 10 >/dev/null || {
      rc=$?
      echo "verify: lock_timeout — could not acquire registry lock after 10s" >&2
      exit "$rc"
    }
    # Ensure release on any exit path. trap is set AFTER acquire so we only
    # release if we actually hold the token.
    trap 'release_lock "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

    # Read current revision under lock for monotonic increment. jq treats
    # a missing revision as null; coerce to 0 so first write starts at 1.
    current_revision="$(jq -r '.revision // 0' "$FL" 2>/dev/null || echo 0)"
    next_revision=$(( current_revision + 1 ))

    # P0-M2: the evidence-association mutation is itself a journaled mutation.
    # journal_record_pending captures the pre-mutation SHA; the committed line
    # records the post-mutation SHA so the DWM registry gate can prove this
    # append is a legal, per-revision journaled mutation.
    journal_init "$PROJECT_DIR" || { echo "verify: journal_init failed" >&2; exit 2; }

    if new_content="$(jq --arg fid "$FEATURE_ID" --argjson assoc "$ASSOC" \
        --arg today "$TODAY" --argjson rev "$next_revision" \
      '(.features[] | select(.id == $fid) | .evidence_associations) += [$assoc]
       | .revision = $rev
       | .last_updated = $today' \
      "$FL")"; then
      # Contract 3: bind the deterministic expected post-state SHA (sha of the
      # exact content about to be atomic-written) BEFORE journaling pending, so
      # recovery can roll-forward only on that exact SHA.
      # NOTE: this block runs at top-level script scope (not inside a function),
      # so `local` is illegal here — plain assignments create globals, which is
      # exactly what the journal pair (verify_op_key / verify_post_sha) needs.
      verify_post_sha="$(printf '%s' "$new_content" | sha256sum 2>/dev/null | awk '{print $1}')"
      [ -z "$verify_post_sha" ] && { command -v shasum >/dev/null 2>&1 \
        && verify_post_sha="$(printf '%s' "$new_content" | shasum -a 256 | awk '{print $1}')"; } || true
      [ -z "$verify_post_sha" ] && verify_post_sha="null"
      verify_op_key="$(journal_record_pending "$PROJECT_DIR" "evidence_associate" \
        "$FEATURE_ID" "" "" --run-id "$RUN_ID" --revision "$next_revision" --post-sha "$verify_post_sha")" || {
        echo "verify: journal pending failed (registry unchanged)" >&2; exit 2; }
      atomic_write_json "$FL" "$new_content" || {
        echo "verify: atomic_write_json failed for $FL" >&2
        exit 2
      }
      # Contract 3 (fail-closed): a committed-append failure after the registry
      # was already updated MUST fail the run (never warn-and-continue). The
      # pending line carries expected_post_sha so the next journal_init recovery
      # rolls forward exactly.
      journal_record_committed "$PROJECT_DIR" "$verify_op_key" "$verify_post_sha" || {
        echo "verify: journal committed failed (registry already updated — pending orphan will roll-forward on next mutation)" >&2
        exit 2
      }
      echo "Association added to feature_list.json (revision → $next_revision)"
    else
      echo "verify: jq evidence mutation failed (registry unchanged)" >&2
      exit 2
    fi
    # Release the lock now (trap is a safety net for unexpected exits).
    release_lock "$LOCK_DIR" >/dev/null 2>&1 || true
    trap - EXIT
  else
    echo "Run log written to .harness/logs/runs/${RUN_ID}.ndjson"
    echo "Re-run with --write to associate evidence with feature '$FEATURE_ID'."
  fi

  echo "Result: PASSED ($PASSED/$PLANNED commands)"
  exit 0
fi

exit 1
