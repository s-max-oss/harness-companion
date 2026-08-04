#!/bin/bash
# harness-feature.sh — feature_list.json management with explicit state machine (v2)
#
# Design §10: Feature State Machine.
# State machine + transitions + WIP limit + passing eligibility + override.
# All mutations serialize through lock-registry.sh and bump `revision` by
# exactly +1 on success. Failed mutations leave `revision` unchanged.
#
# Usage:
#   bash harness-feature.sh list [project_dir]
#   bash harness-feature.sh add <project_dir> <id> [title]
#   bash harness-feature.sh status <project_dir> <id> <new_status> [--override "<reason>"]
#
# Exit codes:
#   0  success (status printed to stdout)
#   1  invalid usage / unknown state / feature not found
#   2  config missing or jq missing
#   3  illegal transition (revision unchanged)
#   4  WIP limit exceeded (revision unchanged)
#   5  passing-needs-evidence rejected (revision unchanged)
#   6  override required for unverified (revision unchanged)
#   7  lock_timeout — could not acquire registry lock
#
# 6 states (frozen per design §10):
#   not_started  — feature is in the spec but work has not begun
#   in_progress  — exactly one feature in_progress at any time (WIP limit)
#   blocked      — work can't continue; see notes
#   passing      — verification has succeeded; evidence_associations non-empty
#   unverified   — manually marked; audit-only; bypasses evidence rule
#   deprecated  — retired from scope (terminal-ish; can be revived)
#
# Legal transitions (per feature-state-machine.md):
#   not_started → in_progress | blocked | deprecated
#   in_progress → passing | blocked | not_started | deprecated
#   blocked     → in_progress | not_started | deprecated
#   unverified  → in_progress | blocked | passing | deprecated
#   passing     → in_progress | deprecated
#   deprecated  → in_progress | not_started

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/atomic_write.sh
source "$SKILL_DIR/lib/atomic_write.sh"
# shellcheck source=lib/json-helpers.sh
source "$SKILL_DIR/lib/json-helpers.sh"
# shellcheck source=lib/harness-config.sh
source "$SKILL_DIR/lib/harness-config.sh"
# shellcheck source=lib/passing.sh
source "$SKILL_DIR/lib/passing.sh"
# shellcheck source=lib/lock-registry.sh
source "$SKILL_DIR/lib/lock-registry.sh"

# Keep -e off so command failures are captured, not shell-killing.
set +e

# ---- helpers ----------------------------------------------------------------

# Legal transitions table. Returns 0 if allowed, 1 otherwise.
# Strict whitelist per frozen design §1.2 (the ONLY legal edges):
#   not_started → in_progress | blocked | deprecated
#   in_progress → passing | blocked | unverified | deprecated
#   blocked     → in_progress | unverified | deprecated
#   passing     → in_progress | deprecated
#   unverified  → in_progress | deprecated
#   deprecated  → (terminal — no outgoing edges)
#
# --override "<reason>" is required ONLY when the target state is unverified.
# All other transitions (including out-of-unverified) are bare.
#
# Notes on rejected edges (must fail-closed with rc=3, revision unchanged):
#   - in_progress → not_started (REMOVED)
#   - blocked     → not_started (REMOVED)
#   - deprecated  → in_progress  (REMOVED — deprecated is terminal)
#   - passing     → unverified   (REMOVED — only in_progress|blocked → unverified)
#   - not_started → unverified   (REMOVED — only in_progress|blocked → unverified)
#   - deprecated  → unverified   (REMOVED — only in_progress|blocked → unverified)
#   - deprecated  → *            (REJECTED — deprecated is terminal)
#   - unverified  → blocked | passing | not_started (REMOVED — only in_progress | deprecated)
#   - self-loops  → REJECTED (e.g. passing → passing, unverified → unverified)
_is_allowed_transition() {
  local from="$1" to="$2"
  case "$from:$to" in
    not_started:in_progress|not_started:blocked|not_started:deprecated|\
    in_progress:passing|in_progress:blocked|in_progress:unverified|in_progress:deprecated|\
    blocked:in_progress|blocked:unverified|blocked:deprecated|\
    passing:in_progress|passing:deprecated|\
    unverified:in_progress|unverified:deprecated) return 0 ;;
    *) return 1 ;;
  esac
}

# Override is required ONLY when target is unverified. Returns 0 if so.
_requires_override() {
  [ "$1" = "unverified" ]
}

# When target is unverified, the origin must be in_progress or blocked.
# Other origins (not_started, passing, unverified, deprecated) are rejected
# even with --override.
_is_valid_unverified_origin() {
  case "$1" in
    in_progress|blocked) return 0 ;;
    *) return 1 ;;
  esac
}

# Read current revision from feature_list.json under lock. Echoes 0 if missing.
_read_revision() {
  local fl="$1"
  jq -r '.revision // 0' "$fl" 2>/dev/null || echo 0
}

# Build a new feature_list.json with revision+1 and the mutation applied.
# On success: echoes new content, returns 0.
# On failure: writes error to stderr, returns non-zero; revision unchanged.
_apply_mutation_locked() {
  local fl="$1" jq_program="$2"
  local current_rev
  current_rev="$(_read_revision "$fl")"
  local next_rev=$(( current_rev + 1 ))

  local new_content
  if ! new_content="$(jq --argjson rev "$next_rev" "$jq_program" "$fl")"; then
    echo "harness-feature: jq mutation failed (revision unchanged)" >&2
    return 1
  fi

  # Verify revision in the new content is exactly current+1 (defense).
  local computed_rev
  computed_rev="$(printf '%s' "$new_content" | jq -r '.revision // 0' 2>/dev/null)"
  if [ "$computed_rev" != "$next_rev" ]; then
    echo "harness-feature: revision invariant violation (computed=$computed_rev expected=$next_rev)" >&2
    return 1
  fi

  printf '%s' "$new_content"
}

# Acquire registry lock in the calling shell. Must NOT use $(...) capture —
# flock backend holds the lock via FD 9 in this shell, and a subshell would
# release the kernel lock when it exits. The token is exposed via
# $LOCK_REGISTRY_TOKEN; release_lock reads from env.
# Returns 0 on success, 7 on lock_timeout.
_acquire_lock_in_caller() {
  local lock_dir="$1"
  # Ensure the parent directory exists, but DO NOT pre-create lock_dir itself:
  # `mkdir -p "$lock_dir/.."` would mkdir the lock_dir as an intermediate
  # directory and break acquire_lock's atomic-mkdir primitive.
  local parent_dir
  parent_dir="$(dirname "$lock_dir")"
  if [ ! -d "$parent_dir" ]; then
    mkdir -p "$parent_dir" 2>/dev/null || true
  fi
  if ! acquire_lock "$lock_dir" 10; then
    echo "harness-feature: lock_timeout — could not acquire registry lock after 10s" >&2
    return 7
  fi
  return 0
}

# ---- list -------------------------------------------------------------------
cmd_list() {
  local dir="${1:-.}"
  local fl="$dir/feature_list.json"
  if [ ! -f "$fl" ]; then
    echo "Error: feature_list.json not found in $dir" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required" >&2
    return 2
  fi

  local rev total passing in_progress blocked not_started unverified deprecated
  rev="$(_read_revision "$fl")"
  total="$(jq '.features | length' "$fl")"
  passing="$(jq '[.features[] | select(.status=="passing")] | length' "$fl")"
  in_progress="$(jq '[.features[] | select(.status=="in_progress")] | length' "$fl")"
  blocked="$(jq '[.features[] | select(.status=="blocked")] | length' "$fl")"
  not_started="$(jq '[.features[] | select(.status=="not_started")] | length' "$fl")"
  unverified="$(jq '[.features[] | select(.status=="unverified")] | length' "$fl")"
  deprecated="$(jq '[.features[] | select(.status=="deprecated")] | length' "$fl")"

  echo "Features in $(basename "$dir") (revision: $rev):"
  echo ""
  if [ "$total" = "0" ]; then
    echo "  (no features defined)"
    echo ""
    echo "Add one with: harness-feature.sh add $dir <id> [title]"
    return 0
  fi
  printf "  %-22s %-13s %s\n" "ID" "Status" "Evidence"
  printf "  %-22s %-13s %s\n" "----------------------" "-------------" "--------"
  while IFS=$'\t' read -r id status n_ev; do
    printf "  %-22s %-13s %s\n" "$id" "$status" "$n_ev"
  done < <(jq -r '.features[] | [.id, .status, (.evidence_associations | length)] | @tsv' "$fl")

  echo ""
  echo "  $passing passing | $in_progress in_progress | $unverified unverified | $not_started not_started | $blocked blocked | $deprecated deprecated"
}

# ---- add --------------------------------------------------------------------
cmd_add() {
  local dir="$1"
  local id="$2"
  local title="${3:-}"

  if [ -z "$dir" ] || [ -z "$id" ]; then
    echo "Error: usage: harness-feature.sh add <project_dir> <id> [title]" >&2
    return 1
  fi

  local fl="$dir/feature_list.json"
  if [ ! -f "$fl" ]; then
    echo "Error: feature_list.json not found in $dir" >&2
    return 2
  fi
  if jq -e --arg id "$id" '.features[] | select(.id == $id)' "$fl" >/dev/null 2>&1; then
    echo "Error: feature '$id' already exists." >&2
    return 1
  fi

  # Acquire lock for the mutation. acquire_lock must NOT be wrapped in $()
  # — the flock backend keeps the kernel lock via FD 9 in this shell; a
  # subshell would release it. Token is exposed via $LOCK_REGISTRY_TOKEN.
  local LOCK_DIR="$dir/.harness/.registry.lock"
  if ! _acquire_lock_in_caller "$LOCK_DIR"; then
    return 7
  fi
  trap 'release_lock "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

  local today
  today="$(date +%Y-%m-%d)"

  # Build jq program: add feature with status=not_started, bump revision.
  local jq_program
  jq_program='.features += [{"id": $id, "status": "not_started", "evidence_associations": [], "legacy_audit_evidence": []}]
              | .revision = $rev
              | .last_updated = $today'

  # Compute current rev and the next rev explicitly.
  local current_rev next_rev
  current_rev="$(_read_revision "$fl")"
  next_rev=$(( current_rev + 1 ))

  local new_content
  if ! new_content="$(jq --arg id "$id" --arg today "$today" --argjson rev "$next_rev" \
       "$jq_program" "$fl")"; then
    echo "harness-feature: jq add failed (revision unchanged)" >&2
    return 1
  fi

  if ! atomic_write_json "$fl" "$new_content"; then
    echo "harness-feature: atomic_write_json failed for $fl (revision unchanged)" >&2
    return 1
  fi

  release_lock "$LOCK_DIR" >/dev/null 2>&1 || true
  trap - EXIT
  echo "Feature '$id' added (status=not_started, revision → $next_rev)${title:+ — $title}"
}

# ---- status -----------------------------------------------------------------
cmd_status() {
  local dir="$1"
  local id="$2"
  local new_status="$3"
  shift 3
  local override_reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --override)
        override_reason="${2:?--override requires a non-empty reason}"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  if [ -z "$dir" ] || [ -z "$id" ] || [ -z "$new_status" ]; then
    echo "Error: usage: harness-feature.sh status <project_dir> <id> <new_status> [--override \"<reason>\"]" >&2
    return 1
  fi

  # Validate the new status.
  case "$new_status" in
    not_started|in_progress|blocked|passing|unverified|deprecated) ;;
    *)
      echo "Error: Invalid status '$new_status'." >&2
      echo "Use: not_started | in_progress | blocked | passing | unverified | deprecated" >&2
      return 1
      ;;
  esac

  local fl="$dir/feature_list.json"
  if [ ! -f "$fl" ]; then
    echo "Error: feature_list.json not found in $dir" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required" >&2
    return 2
  fi

  # Acquire lock — all read-modify-write is serialized.
  local LOCK_DIR="$dir/.harness/.registry.lock"
  if ! _acquire_lock_in_caller "$LOCK_DIR"; then
    return 7
  fi
  trap 'release_lock "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

  # Read current state (under lock).
  local current_status
  current_status="$(jq -r --arg id "$id" '.features[] | select(.id == $id) | .status' "$fl" 2>/dev/null)"
  if [ -z "$current_status" ] || [ "$current_status" = "null" ]; then
    echo "Error: feature '$id' not found." >&2
    return 1
  fi

  # Enforce allowed transitions.
  if ! _is_allowed_transition "$current_status" "$new_status"; then
    echo "Error: transition $current_status → $new_status is not allowed." >&2
    return 3
  fi

  # WIP limit on promote-to-in_progress.
  if [ "$new_status" = "in_progress" ]; then
    local wip_limit
    wip_limit="$(hc_wip_limit "$dir")"
    local others
    others="$(jq --arg id "$id" '[.features[] | select(.id != $id and .status == "in_progress")] | length' "$fl" 2>/dev/null)"
    if [ -n "$others" ] && [ "$others" -ge "$wip_limit" ]; then
      local names
      names="$(jq -r --arg id "$id" '[.features[] | select(.id != $id and .status == "in_progress") | .id] | join(", ")' "$fl" 2>/dev/null)"
      echo "Error: WIP limit reached ($wip_limit). Other in_progress: $names" >&2
      return 4
    fi
  fi

  # Passing-needs-evidence.
  if [ "$new_status" = "passing" ]; then
    if ! is_eligible_for_passing "$id" "$fl" "$dir"; then
      if [ -z "$override_reason" ]; then
        echo "Error: feature '$id' has no passing-eligible evidence." >&2
        echo "Run harness-verify.sh '$id' '$dir' --write first." >&2
        echo "If you must proceed anyway, use: status $id unverified --override \"<reason>\"" >&2
        return 5
      fi
      # --override provided: route to unverified instead of passing.
      # unverified requires the current state to be in_progress or blocked
      # (per design §1.2). Other origins must reject even with --override.
      if ! _is_valid_unverified_origin "$current_status"; then
        echo "Error: --override routing to 'unverified' only allowed from in_progress|blocked (current=$current_status)." >&2
        return 5
      fi
      echo "Note: forcing via --override → routing to 'unverified' instead of 'passing'."
      new_status="unverified"
    fi
  fi

  # unverified requires --override AND current state must be in_progress|blocked.
  if [ "$new_status" = "unverified" ]; then
    if [ -z "$override_reason" ]; then
      echo "Error: 'unverified' requires --override \"<reason>\"" >&2
      return 6
    fi
    if ! _is_valid_unverified_origin "$current_status"; then
      echo "Error: --override routing to 'unverified' only allowed from in_progress|blocked (current=$current_status)." >&2
      return 6
    fi
  fi

  # Build jq program. For unverified, also write the audit record.
  local today current_rev next_rev jq_program
  today="$(date +%Y-%m-%d)"
  current_rev="$(_read_revision "$fl")"
  next_rev=$(( current_rev + 1 ))

  if [ "$new_status" = "unverified" ]; then
    local by
    by="${HARNESS_OPERATOR:-$(whoami 2>/dev/null || echo unknown)}"
    local at
    at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
    jq_program='(.features[] | select(.id == $id) | .status) = $status
                | (.features[] | select(.id == $id) | .override) = {by: $by, at: $at, reason: $reason}
                | .revision = $rev
                | .last_updated = $today'
    local new_content
    if ! new_content="$(jq --arg id "$id" --arg status "$new_status" --arg by "$by" --arg at "$at" \
         --arg reason "$override_reason" --arg today "$today" --argjson rev "$next_rev" \
         "$jq_program" "$fl")"; then
      echo "harness-feature: jq status mutation failed (revision unchanged)" >&2
      return 1
    fi
    if ! atomic_write_json "$fl" "$new_content"; then
      echo "harness-feature: atomic_write_json failed (revision unchanged)" >&2
      return 1
    fi
  else
    jq_program='(.features[] | select(.id == $id) | .status) = $status
                | .revision = $rev
                | .last_updated = $today'
    local new_content
    if ! new_content="$(jq --arg id "$id" --arg status "$new_status" \
         --arg today "$today" --argjson rev "$next_rev" \
         "$jq_program" "$fl")"; then
      echo "harness-feature: jq status mutation failed (revision unchanged)" >&2
      return 1
    fi
    if ! atomic_write_json "$fl" "$new_content"; then
      echo "harness-feature: atomic_write_json failed (revision unchanged)" >&2
      return 1
    fi
  fi

  release_lock "$LOCK_DIR" >/dev/null 2>&1 || true
  trap - EXIT
  echo "Feature '$id' $current_status → $new_status (revision → $next_rev)"
}

# ---- main dispatch ----------------------------------------------------------
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  list|ls)         cmd_list "${1:-.}" ;;
  add)             cmd_add "${1:-}" "${2:-}" "${3:-}" ;;
  status)          cmd_status "$@" ;;
  help|--help|-h)
    echo "Usage: harness-feature.sh {list|add|status} [args...]"
    echo ""
    echo "Commands:"
    echo "  list [project_dir]"
    echo "  add <project_dir> <id> [title]"
    echo "  status <project_dir> <id> <new_status> [--override \"<reason>\"]"
    echo ""
    echo "States: not_started | in_progress | blocked | passing | unverified | deprecated"
    exit 0
    ;;
  *)
    echo "Error: unknown command '$COMMAND'" >&2
    exit 1
    ;;
esac