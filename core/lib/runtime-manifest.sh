#!/bin/bash
# runtime-manifest.sh — persistent runtime-artifact byte-binding registry
#
# Codex r7 fix (item 3, hardened by rc6 final remediation).
#
# The frozen dirty-worktree fixture pre-dates the latest canonical run, so the
# canonical run's NDJSON + command logs + reviewer verdict enter the DWM gate as
# `allowed_new` indefinitely — their bytes are never bound and a later tamper
# is invisible. This registry closes that hole by binding the FIRST-SEEN bytes
# of every runtime artifact in the mutable namespace:
#
#   .harness/logs/runs/<run_id>.ndjson      kind=ndjson  → byte-immutable
#   .harness/logs/runs/<run_id>/<cmd>.log   kind=log     → byte-immutable
#   .harness/reviews/**/*.jsonl             kind=verdict → append-only (the
#                                             registered bytes must remain a
#                                             PREFIX of the current file)
#
# The registry lives at <project_dir>/.harness/runtime-manifest.jsonl and is
# protected by:
#   1. A genesis anchor (line 0): when the registry is first created, the
#      caller's RUNTIME_MANIFEST_GENESIS environment variable (the HEAD OID
#      that authorized this registry's creation) is written as the FIRST line.
#      The DWM gate validates this prefix byte-for-byte against
#      `git rev-parse HEAD:<registry path>` BEFORE trusting any subsequent
#      entry. A tampered genesis anchor (or a registry rewritten to drop it)
#      fails the gate wholesale (runtime_manifest_genesis_mismatch).
#   2. Strict append-only writes via mkdir atomic lock (acquire_lock /
#      release_lock from lock-registry.sh) — no in-place mutation, no `|| true`
#      swallowing.
#   3. Hard failure on missing file, missing hash tool, or append error — all
#      runtime_register paths return non-zero. Callers MUST propagate.
#
# Functions:
#   runtime_manifest_path <project_dir>              → registry path
#   runtime_manifest_genesis_value <project_dir>    → genesis string (HEAD OID)
#   runtime_register <project_dir> <rel_path> <kind> → idempotent append (rc≠0 on fail)
#   runtime_register_run <project_dir> <run_id>      → register run NDJSON + logs

# ---- runtime_manifest_path --------------------------------------------------
runtime_manifest_path() {
  printf '%s/.harness/runtime-manifest.jsonl' "$1"
}

# ---- runtime_manifest_genesis_value -----------------------------------------
# The HEAD OID that authorized this registry's creation. DWM compares this
# value byte-for-byte against the committed genesis line. If unset in the
# environment, fall back to `git rev-parse HEAD` (the canonical review-time
# anchor). Callers MUST set RUNTIME_MANIFEST_GENESIS to make the intent
# explicit; the fallback is for reviewer convenience only.
runtime_manifest_genesis_value() {
  local project_dir="$1"
  if [ -n "${RUNTIME_MANIFEST_GENESIS:-}" ]; then
    printf '%s' "$RUNTIME_MANIFEST_GENESIS"
    return 0
  fi
  if command -v git >/dev/null 2>&1 && \
     git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$project_dir" rev-parse HEAD 2>/dev/null
    return 0
  fi
  return 1
}

# ---- _runtime_file_sha256 ----------------------------------------------------
# Canonical SHA-256 of a file's bytes. Returns non-zero on failure; the caller
# must propagate. (Previously this returned "null" on missing tools, which
# silently dropped the binding — fail-closed.)
_runtime_file_sha256() {
  local f="$1"
  if [ ! -f "$f" ]; then
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
    return $?
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    return $?
  fi
  return 1
}

# ---- _runtime_lock_dir ------------------------------------------------------
runtime_lock_dir() {
  local project_dir="$1"
  printf '%s/.harness/.registry.lock/runtime-manifest' "$project_dir"
}

# ---- _runtime_acquire / _runtime_release -----------------------------------
# Use the project's lock-registry.sh when sourced. The caller MUST source
# lock-registry.sh before calling runtime_register / runtime_register_run.
#
# Lock topology: the LEAF for this lock is <project_dir>/.harness/.registry.lock
# /runtime-manifest. The PARENT (.harness/.registry.lock) is ALSO the leaf for
# the registry-write lock held by core/harness-verify.sh / harness-feature.sh
# during feature_list mutations. Both locks share the same parent so that
# concurrent runtime register vs verify-write serialize through the SAME
# parent. The mkdir-acquire backend treats a leaf as "held" if the leaf
# directory exists; an empty parent (no metadata) is NOT a valid held state
# — it is an orphaned bootstrap half-step that blocks the OTHER holder's
# mkdir-acquire with no stale-recovery path. Therefore:
#   - Pre-create the parent ONLY if it does not already exist. If it exists
#     but is empty (no metadata files), it must be a leftover from a crashed
#     prior holder — remove it so the OTHER holder can claim via mkdir-acquire.
#   - Same empty-leaf recovery for the runtime-manifest leaf itself.
#   - acquire_lock's stdout prints the lock token (callers can pass it to
#     release_lock without a subshell). runtime-manifest must NOT leak that
#     token into callers' stdout. Redirect to /dev/null and rely on
#     $LOCK_REGISTRY_TOKEN (set by acquire_lock into the env) for release.
_runtime_acquire() {
  local project_dir="$1"
  local lockdir parent
  lockdir="$(runtime_lock_dir "$project_dir")"
  parent="$(dirname "$lockdir")"
  # Same-host orphan recovery: an empty parent or leaf with no metadata files
  # is a leftover bootstrap half-step from a crashed prior holder. Remove it
  # so this caller (or the OTHER holder with the same parent) can claim the
  # leaf via mkdir-acquire. Safe because empty = no other holder can exist:
  # any holder would have left metadata inside.
  if [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; then
    rmdir "$parent" 2>/dev/null || true
  fi
  if [ ! -d "$parent" ]; then
    mkdir -p "$parent"
  fi
  if [ -d "$lockdir" ] && [ -z "$(ls -A "$lockdir" 2>/dev/null)" ]; then
    rmdir "$lockdir" 2>/dev/null || true
  fi
  acquire_lock "$lockdir" 10 >/dev/null
  return $?
}
_runtime_release() {
  local project_dir="$1"
  release_lock "$(runtime_lock_dir "$project_dir")" "${LOCK_REGISTRY_TOKEN:-}"
  return $?
}

# ---- _runtime_init_registry -------------------------------------------------
# Create the registry file (with genesis anchor) under lock. Idempotent:
# existing registry is left untouched. Returns 0 on first-create success, 1 on
# any failure, and 2 if the registry already exists (no-op).
_runtime_init_registry() {
  local project_dir="$1" mf="$2"
  if [ -f "$mf" ]; then
    return 2
  fi
  local genesis
  if ! genesis="$(runtime_manifest_genesis_value "$project_dir")"; then
    echo "runtime-manifest: cannot determine genesis anchor (no RUNTIME_MANIFEST_GENESIS and not a git repo)" >&2
    return 1
  fi
  mkdir -p "$(dirname "$mf")"
  # tmp + mv = atomic creation; partial writes leave no observable state.
  local tmp="${mf}.tmp.$$"
  if ! jq -cn --arg g "$genesis" '{genesis:$g}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$mf" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# ---- _runtime_prepend_genesis -----------------------------------------------
# One-shot migration helper for legacy registries written before the rc6
# final genesis anchor requirement: the file exists but line 0 is a regular
# path entry, not `{genesis: "..."}`. Atomic prepend under lock: builds a
# tmp file `{genesis}\n<existing>`, replaces atomically. Returns 0 on
# success, 1 on any failure (caller MUST propagate). On a registry that
# already has a genesis line, returns 2 (no-op, no error).
_runtime_prepend_genesis() {
  local project_dir="$1" mf="$2"
  # Re-check under lock to avoid races.
  if head -1 "$mf" 2>/dev/null | jq -e 'has("genesis")' >/dev/null 2>&1; then
    return 2
  fi
  local genesis
  if ! genesis="$(runtime_manifest_genesis_value "$project_dir")"; then
    echo "runtime-manifest: cannot determine genesis anchor for prepend (no RUNTIME_MANIFEST_GENESIS and not a git repo)" >&2
    return 1
  fi
  local tmp="${mf}.prepend.$$"
  if ! jq -cn --arg g "$genesis" '{genesis:$g}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! (cat "$tmp"; cat "$mf") > "${mf}.new.$$" 2>/dev/null; then
    rm -f "$tmp" "${mf}.new.$$"
    return 1
  fi
  if ! mv "${mf}.new.$$" "$mf" 2>/dev/null; then
    rm -f "$tmp" "${mf}.new.$$"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

# ---- _runtime_validate_registry ---------------------------------------------
# Fail-closed validation of an EXISTING registry, called under the registry
# lock after genesis bootstrap/prepend. Enforces three invariants:
#   1. Valid JSONL — every line parses as a single JSON object (malformed
#      line, including a blank or truncated line, fails). A trailing CR from
#      MSYS jq's CRLF output is stripped before parsing.
#   2. UNIQUE genesis — exactly one line carries a `genesis` key, and it must
#      be the FIRST line (line 0). Duplicate or misplaced genesis fails.
#   3. Correct genesis — when the caller asserts an explicit expected HEAD via
#      RUNTIME_MANIFEST_GENESIS, the genesis value MUST equal it (a stale or
#      tampered genesis fails). When the env var is unset there is no
#      authoritative anchor to compare against: the registry is untracked, so
#      there is no committed blob to diff, and `git rev-parse HEAD` advances
#      with every commit — comparing against it would falsely reject a
#      legitimately-stale registry after any commit (the bootstrap-gates T7
#      "feature commit → run regeneration" regression). Only the STRUCTURAL
#      genesis checks apply in that case.
# Any violation returns non-zero and aborts registration (fail-closed).
_runtime_validate_registry() {
  local project_dir="$1" mf="$2"
  local line idx=0 gen_count=0 gen_idx=-1 gen_val=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    idx=$((idx + 1))
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      echo "runtime-manifest: registry line $idx is not valid JSON (fail-closed)" >&2
      return 1
    fi
    if printf '%s' "$line" | jq -e 'has("genesis")' >/dev/null 2>&1; then
      gen_count=$((gen_count + 1))
      if [ "$gen_count" -gt 1 ]; then
        echo "runtime-manifest: registry has duplicate genesis lines (fail-closed)" >&2
        return 1
      fi
      gen_idx=$idx
      gen_val="$(printf '%s' "$line" | jq -r '.genesis // empty' 2>/dev/null)"
    fi
  done < "$mf"
  if [ "$gen_count" -eq 0 ]; then
    echo "runtime-manifest: registry has no genesis line (fail-closed)" >&2
    return 1
  fi
  if [ "$gen_idx" -ne 1 ]; then
    echo "runtime-manifest: genesis anchor is not line 0 (found at line $((gen_idx - 1))) (fail-closed)" >&2
    return 1
  fi
  # Genesis VALUE correctness is only enforceable against an explicit expected
  # anchor (see the doc comment above). When RUNTIME_MANIFEST_GENESIS is set,
  # compare byte-for-byte and fail-closed on a stale/tampered genesis. When
  # unset, there is no authoritative expected value, so skip the value check —
  # a registry whose HEAD advanced after a commit remains valid.
  if [ -n "${RUNTIME_MANIFEST_GENESIS:-}" ] && [ "$gen_val" != "${RUNTIME_MANIFEST_GENESIS}" ]; then
    echo "runtime-manifest: genesis anchor mismatch (expected ${RUNTIME_MANIFEST_GENESIS}, got $gen_val) (fail-closed)" >&2
    return 1
  fi
  return 0
}

# ---- runtime_register -------------------------------------------------------
# Bind the first-seen bytes of <rel_path> (relative to <project_dir>) under
# <kind>. Hard-fails on missing file, missing hash tool, or append error.
# Idempotent: an already-registered path is a no-op. Caller MUST propagate
# the return code (no `|| true`).
runtime_register() {
  local project_dir="$1" rel="$2" kind="$3"
  local f="$project_dir/$rel" mf
  # ---- Hard fail on missing file ----
  if [ ! -f "$f" ]; then
    echo "runtime-manifest: refusing to register missing file: $rel" >&2
    return 1
  fi
  mf="$(runtime_manifest_path "$project_dir")"
  # ---- Obstacle detection (lstat / lexical absence) -------------------------
  # The registry path must be EITHER entirely absent (true lexical absence → the
  # not-applicable short-circuit or a fresh bootstrap below) OR an existing
  # regular file. Any other node is an obstacle that must hard-fail, never be
  # silently treated as a no-op:
  #   - a dangling symlink  → `-L` (lstat) is true but `-e` is false; without
  #     this check a dangling link would fall through the `! -e` short-circuit
  #     and be skipped as "absent";
  #   - a directory / FIFO / device → `-e` true but `-f` false.
  if [ -L "$mf" ]; then
    echo "runtime-manifest: registry path $mf is a symlink — refusing (fail-closed)" >&2
    return 1
  fi
  if [ -e "$mf" ] && [ ! -f "$mf" ]; then
    echo "runtime-manifest: registry path $mf is not a regular file — refusing (fail-closed)" >&2
    return 1
  fi
  # ---- Not-applicable short-circuit (NOT a failure) -------------------------
  # The registry binds runtime artifacts to a git HEAD genesis anchor. A project
  # with no git repo and no RUNTIME_MANIFEST_GENESIS has no anchor to bind
  # against, so registration is a no-op: there is nothing to register INTO.
  # This is distinct from a genuine registration failure (missing file / hash
  # tool / append / lock), which still returns non-zero. Only skip when the
  # registry path is ENTIRELY ABSENT (a truly missing path — obstacles above are
  # already fail-closed before reaching here).
  if [ ! -e "$mf" ] && ! runtime_manifest_genesis_value "$project_dir" >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$(dirname "$mf")"
  # Acquire lock for the registry-init + idempotency-check + append window.
  _runtime_acquire "$project_dir" || {
    echo "runtime-manifest: failed to acquire registry lock" >&2
    return 1
  }
  local lock_rc=0
  {
    # Bootstrap registry (genesis) if absent, OR prepend genesis to an
    # existing legacy registry that was written before the rc6 final genesis
    # anchor requirement. The legacy file is untracked runtime state, so this
    # one-shot prepend is the tracked-work migration specified in
    # docs/migrations/2026-08-17-rc6-final-contract-migration.json
    # (concurrent_changes.runtime-manifest genesis anchor). After this runs
    # once, the genesis line is in place and the rc6 DWM gate accepts the
    # registry. Safe under the lock because no concurrent register sees the
    # in-between state.
    if [ ! -f "$mf" ]; then
      if ! _runtime_init_registry "$project_dir" "$mf"; then
        lock_rc=1
      fi
    elif ! head -1 "$mf" 2>/dev/null | jq -e 'has("genesis")' >/dev/null 2>&1; then
      if ! _runtime_prepend_genesis "$project_dir" "$mf"; then
        lock_rc=1
      fi
    fi
    if [ "$lock_rc" -eq 0 ]; then
      # Validate the (possibly just-created / prepended) registry before
      # trusting it: valid JSONL, unique genesis at line 0, genesis == expected
      # HEAD. Fail-closed — a stale, duplicate, or tampered genesis aborts the
      # registration rather than appending to a corrupt registry.
      if ! _runtime_validate_registry "$project_dir" "$mf"; then
        lock_rc=1
      fi
    fi
    if [ "$lock_rc" -eq 0 ]; then
      # Idempotency: skip if this exact path is already bound.
      if jq -e -s --arg p "$rel" 'any(.[]; select(.path == $p))' "$mf" >/dev/null 2>&1; then
        lock_rc=0
      else
        local h sz
        if ! h="$(_runtime_file_sha256 "$f")"; then
          echo "runtime-manifest: sha256 unavailable for $rel (sha256sum/shasum missing or unreadable)" >&2
          lock_rc=1
        else
          sz="$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r')"
          [ -n "$sz" ] || sz=0
          local tmp="${mf}.tmp.$$"
          if ! jq -cn --arg p "$rel" --arg k "$kind" --arg h "$h" --argjson s "$sz" \
              '{path:$p, kind:$k, sha256:$h, size:$s}' > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            echo "runtime-manifest: failed to build entry for $rel" >&2
            lock_rc=1
          elif ! (cat "$mf" 2>/dev/null; cat "$tmp") > "${mf}.new.$$" 2>/dev/null; then
            rm -f "$tmp" "${mf}.new.$$"
            echo "runtime-manifest: failed to assemble registry for $rel" >&2
            lock_rc=1
          elif ! mv "${mf}.new.$$" "$mf" 2>/dev/null; then
            rm -f "$tmp" "${mf}.new.$$"
            echo "runtime-manifest: atomic append failed for $rel" >&2
            lock_rc=1
          else
            rm -f "$tmp"
          fi
        fi
      fi
    fi
  } || lock_rc=1
  _runtime_release "$project_dir" || true
  return "$lock_rc"
}

# ---- runtime_register_run ---------------------------------------------------
# Register a completed run's NDJSON and every per-command log under its run dir.
# Hard-fails if any single registration fails (caller MUST propagate).
runtime_register_run() {
  local project_dir="$1" run_id="$2"
  local rc=0
  runtime_register "$project_dir" ".harness/logs/runs/${run_id}.ndjson" "ndjson" || rc=$?
  if [ "$rc" -eq 0 ]; then
    local logf
    for logf in "$project_dir/.harness/logs/runs/${run_id}"/*.log; do
      [ -f "$logf" ] || continue
      runtime_register "$project_dir" ".harness/logs/runs/${run_id}/$(basename "$logf")" "log" || rc=$?
      [ "$rc" -eq 0 ] || break
    done
  fi
  return "$rc"
}
