#!/bin/bash
# branch-gate.sh — Stateful branch baseline gate
#
# Replaces the one-shot "target branch == master HEAD" start condition with a
# stateful gate (init.sh Phase 1 readiness condition 5):
#
#   TARGET BRANCH (P0-13): the gate ENFORCES the Phase 1 working branch name on
#     EVERY entry. PLAN IS AUTHORITATIVE — the target branch is read ONLY from
#     .harness/PLAN.json `branch_gate.target_branch`. A caller-provided
#     `branch_gate_target_branch` env variable is IGNORED and can never override
#     or rewrite the gate's decision. PLAN.json is REQUIRED: a missing/corrupt
#     PLAN, or one without branch_gate.target_branch, FAILS CLOSED. Symlink
#     paths (PLAN.json or the state file) are REJECTED — the gate never follows
#     a link.
#
#   FIRST entry (no .harness/branch-gate.json): the current branch tip MUST
#     equal local master's tip (tip==master) AND the current branch must equal
#     the target branch (if configured). On pass, the gate records the branch
#     name and `branch_base_sha` (= the master tip at first entry).
#
#   SUBSEQUENT entries (state file present): READ-ONLY. The current branch must
#     equal the recorded branch, the recorded branch must still equal the
#     target branch (if configured), and the recorded `branch_base_sha` must be
#     an ancestor of current HEAD (`git merge-base --is-ancestor`). Rebase/
#     reset/divergence that drops the recorded base from the ancestry fails
#     closed. The state file is NOT rewritten on subsequent entries — no
#     meaningless per-init `last_verified_at` timestamp churn (P0-2).
#
# State is written ONLY on first entry AND when `branch_gate_allow_record=1` is
# set by the caller (init.sh sets it only after all checks pass), so a
# prior-check failure never leaks a recorded gate. A state-WRITE failure makes
# the gate return 1 — the caller MUST treat a failed record as a blocked ready
# transition (init.sh does NOT `|| true` the record call; a record failure
# fails closed).
#
# Self-pollution (P0-2): the recorded state file .harness/branch-gate.json is a
# harness self-artifact written by a successful init. It is excluded from the
# workspace fingerprint (BUILTIN_EXCLUDES in workspace-fingerprint.sh) and
# classified mutable in dirty-worktree-manifest.sh (DWM_MUTABLE), so a
# successful init never dirties the fingerprint or the dirty-worktree manifest.
#
# Usage:
#   source branch-gate.sh
#   branch_gate_allow_record=1 branch_gate_check [project_dir]
#
# Returns 0 (gate passed) or 1 (gate failed); diagnostics to stderr.

branch_gate_check() {
  local project_dir="${1:-.}"
  local state_file="$project_dir/.harness/branch-gate.json"

  # ---- git must be available and the dir must be a repo ----
  if ! command -v git >/dev/null 2>&1; then
    echo "branch-gate: git missing — gate cannot be evaluated, FAIL-CLOSED" >&2
    return 1
  fi
  if ! git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "branch-gate: $project_dir is not a git repository — gate cannot be evaluated, FAIL-CLOSED" >&2
    return 1
  fi
  local local_master
  local_master="$(git -C "$project_dir" rev-parse --verify --quiet refs/heads/master 2>/dev/null || echo '')"
  if [ -z "$local_master" ]; then
    echo "branch-gate: local master does not exist — gate requires a master baseline, FAIL-CLOSED" >&2
    return 1
  fi

  local head cur_branch
  head="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo '')"
  cur_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ -z "$head" ] || [ -z "$cur_branch" ] || [ "$cur_branch" = "HEAD" ]; then
    echo "branch-gate: cannot resolve HEAD/current branch — FAIL-CLOSED" >&2
    return 1
  fi

  # ---- P0-13: resolve and enforce the target branch name ----
  # PLAN IS AUTHORITATIVE. The target branch is read ONLY from
  # .harness/PLAN.json branch_gate.target_branch. The `branch_gate_target_branch`
  # env variable is deliberately NOT consulted — an environment override must
  # never rewrite the gate's decision.
  #
  # P0-3 (Codex items 6 + 7): PLAN.json is REQUIRED. A missing or corrupt PLAN,
  # or a PLAN that declares no target_branch, FAILS CLOSED — it must never
  # degrade to "no name check". Symlink paths are REJECTED before any read, so
  # the gate never follows a link (PLAN.json or the state file).
  local plan="$project_dir/.harness/PLAN.json"
  if [ -L "$plan" ]; then
    echo "branch-gate: PLAN.json is a symlink — rejected (the gate never follows a link), FAIL-CLOSED" >&2
    return 1
  fi
  if [ ! -f "$plan" ]; then
    echo "branch-gate: PLAN.json missing — branch policy is mandatory, FAIL-CLOSED" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "branch-gate: jq missing — cannot parse PLAN, FAIL-CLOSED" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$plan" >/dev/null 2>&1; then
    echo "branch-gate: PLAN.json is not valid JSON — FAIL-CLOSED" >&2
    return 1
  fi
  local target_branch=""
  target_branch="$(jq -r '.branch_gate.target_branch // ""' "$plan" 2>/dev/null || true)"
  if [ -z "$target_branch" ] || [ "$target_branch" = "null" ]; then
    echo "branch-gate: PLAN.json declares no branch_gate.target_branch — FAIL-CLOSED" >&2
    return 1
  fi
  if [ "$cur_branch" != "$target_branch" ]; then
    echo "branch-gate: current branch '$cur_branch' != target branch '$target_branch' (Phase 1 working branch) — FAIL-CLOSED" >&2
    return 1
  fi

  # P0-3 (Codex item 7): reject a symlink state file before reading/writing —
  # the gate never follows a link (a symlink to a valid state would otherwise
  # pass, silently writing through the link to an attacker-chosen file).
  if [ -L "$state_file" ]; then
    echo "branch-gate: state file $state_file is a symlink — rejected, FAIL-CLOSED" >&2
    return 1
  fi

  # ---- FIRST entry: no recorded state ----
  if [ ! -f "$state_file" ]; then
    if [ "$head" != "$local_master" ]; then
      echo "branch-gate: first entry requires current branch tip == master tip (HEAD=$head, master=$local_master)" >&2
      return 1
    fi
    if [ "${branch_gate_allow_record:-0}" = "1" ]; then
      mkdir -p "$project_dir/.harness"
      # P0-13: the recorded state is fully DETERMINISTIC — {schema_version,
      # branch_base_sha, branch_name} only, no timestamp. A fresh regeneration
      # with identical inputs is byte-equal to the original, and subsequent
      # checks never rewrite it (read-only).
      if jq -n --arg sha "$head" --arg branch "${target_branch:-$cur_branch}" \
        '{schema_version:1, branch_base_sha:$sha, branch_name:$branch}' \
        > "$state_file" 2>/dev/null; then
        echo "branch-gate: first entry recorded (branch=${target_branch:-$cur_branch}, base=$head)" >&2
      else
        echo "branch-gate: FAILED to write first-entry state to $state_file — record failure BLOCKS ready (fail-closed)" >&2
        return 1
      fi
    fi
    return 0
  fi

  # ---- SUBSEQUENT entry: recorded state present (READ-ONLY) ----
  if ! jq -e '.schema_version == 1' "$state_file" >/dev/null 2>&1; then
    echo "branch-gate: state file invalid (schema_version != 1): $state_file" >&2
    return 1
  fi
  local rec_branch rec_base
  rec_branch="$(jq -r '.branch_name // ""' "$state_file" 2>/dev/null)"
  rec_base="$(jq -r '.branch_base_sha // ""' "$state_file" 2>/dev/null)"
  if [ -z "$rec_branch" ] || [ -z "$rec_base" ]; then
    echo "branch-gate: state file missing branch_name/branch_base_sha" >&2
    return 1
  fi
  if [ "$cur_branch" != "$rec_branch" ]; then
    echo "branch-gate: branch changed ($rec_branch → $cur_branch); gate is per-branch" >&2
    return 1
  fi
  # Defense in depth: if a target branch is configured, the RECORDED branch must
  # still equal it — a re-baseline recorded on any other branch is illegal.
  if [ -n "$target_branch" ] && [ "$rec_branch" != "$target_branch" ]; then
    echo "branch-gate: recorded branch '$rec_branch' != target branch '$target_branch' — re-baseline required" >&2
    return 1
  fi
  # recorded base must be an ancestor of current HEAD → forward advancement only
  if ! git -C "$project_dir" merge-base --is-ancestor "$rec_base" "$head" 2>/dev/null; then
    echo "branch-gate: recorded base $rec_base is not an ancestor of HEAD $head — history rewritten/diverged; gate fails closed" >&2
    return 1
  fi
  # P0-2: NO last_verified_at update on subsequent entries. The state file is
  # append-once; per-init re-stamping is meaningless churn and would turn every
  # init into a dirty-worktree write (self-pollution).
  return 0
}
