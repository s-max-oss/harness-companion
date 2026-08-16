#!/bin/bash
# runtime-manifest.sh — persistent runtime-artifact byte-binding registry
#
# Codex r7 fix (item 3). The frozen dirty-worktree fixture pre-dates the latest
# canonical run, so the canonical run's NDJSON + command logs + reviewer verdict
# enter the DWM gate as `allowed_new` indefinitely — their bytes are never bound
# and a later tamper is invisible. This registry closes that hole by binding the
# FIRST-SEEN bytes of every runtime artifact in the mutable namespace:
#
#   .harness/logs/runs/<run_id>.ndjson      kind=ndjson  → byte-immutable
#   .harness/logs/runs/<run_id>/<cmd>.log   kind=log     → byte-immutable
#   .harness/reviews/**/*.jsonl             kind=verdict → append-only (the
#                                             registered bytes must remain a
#                                             PREFIX of the current file)
#
# The registry lives at <project_dir>/.harness/runtime-manifest.jsonl (one
# compact JSON object per line, appended-only). Writers register an artifact
# immediately after creating it; the DWM gate (dirty-worktree-manifest.sh)
# reads the registry and enforces the per-kind rule against current bytes.
#
# Functions:
#   runtime_manifest_path <project_dir>              → registry path
#   runtime_register <project_dir> <rel_path> <kind> → idempotent append
#   runtime_register_run <project_dir> <run_id>      → register run NDJSON + logs
#
# `runtime_register` is idempotent: a path is recorded ONCE (its first-seen
# bytes); re-registering the same path is a no-op so a verdict that later grows
# by append keeps its first-seen binding intact.

# ---- runtime_manifest_path --------------------------------------------------
runtime_manifest_path() {
  printf '%s/.harness/runtime-manifest.jsonl' "$1"
}

# ---- _runtime_file_sha256 ----------------------------------------------------
# Canonical SHA-256 of a file's bytes, or "null" when unavailable.
_runtime_file_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    printf 'null'
  fi
}

# ---- runtime_register -------------------------------------------------------
# Bind the first-seen bytes of <rel_path> (relative to <project_dir>) under
# <kind>. Skips silently for missing files / missing hash tooling. Idempotent:
# an already-registered path is never rewritten.
runtime_register() {
  local project_dir="$1" rel="$2" kind="$3"
  local f="$project_dir/$rel" mf h sz
  [ -f "$f" ] || return 0
  mf="$(runtime_manifest_path "$project_dir")"
  # Idempotency: skip if this exact path is already bound.
  if [ -f "$mf" ] && jq -e -s --arg p "$rel" 'any(.[]; .path == $p)' "$mf" >/dev/null 2>&1; then
    return 0
  fi
  h="$(_runtime_file_sha256 "$f")"
  { [ -z "$h" ] || [ "$h" = "null" ]; } && return 0
  sz="$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r')"
  [ -z "$sz" ] && sz=0
  mkdir -p "$(dirname "$mf")"
  jq -cn --arg p "$rel" --arg k "$kind" --arg h "$h" --argjson s "$sz" \
    '{path:$p, kind:$k, sha256:$h, size:$s}' >> "$mf" 2>/dev/null || true
  return 0
}

# ---- runtime_register_run ---------------------------------------------------
# Register a completed run's NDJSON and every per-command log under its run dir.
runtime_register_run() {
  local project_dir="$1" run_id="$2"
  runtime_register "$project_dir" ".harness/logs/runs/${run_id}.ndjson" "ndjson" || true
  local logf
  for logf in "$project_dir/.harness/logs/runs/${run_id}"/*.log; do
    [ -f "$logf" ] || continue
    runtime_register "$project_dir" ".harness/logs/runs/${run_id}/$(basename "$logf")" "log" || true
  done
  return 0
}
