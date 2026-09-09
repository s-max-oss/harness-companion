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
#   2. Strict append-only writes via the cross-platform lock registry
#      (acquire_lock /
#      release_lock from lock-registry.sh) — no in-place mutation, no `|| true`
#      swallowing.
#   3. Hard failure on missing file, missing hash tool, or append error — all
#      runtime_register paths return non-zero. Callers MUST propagate.
#
# Functions:
#   runtime_manifest_path <project_dir>              → registry path
#   runtime_manifest_genesis_value <project_dir>    → genesis string (HEAD OID)
#   runtime_register <project_dir> <rel_path> <kind> → idempotent append (rc≠0 on fail)
#   runtime_register_batch <project_dir> <kind>      → NUL-delimited, one atomic append
#   runtime_register_run <project_dir> <run_id>      → register run NDJSON + logs

# ---- runtime_manifest_path --------------------------------------------------
runtime_manifest_path() {
  printf '%s/.harness/runtime-manifest.jsonl' "$1"
}

# ---- runtime_manifest_genesis_value -----------------------------------------
# The HEAD OID that authorized this registry's creation. DWM validates the
# effective genesis/transition chain and exact registry bytes through the
# dedicated Git index. If unset in the environment, fall back to the current
# commit. Callers that require a particular release HEAD set
# RUNTIME_MANIFEST_GENESIS explicitly.
runtime_manifest_genesis_value() {
  local project_dir="$1"
  if [ -n "${RUNTIME_MANIFEST_GENESIS:-}" ]; then
    printf '%s' "$RUNTIME_MANIFEST_GENESIS"
    return 0
  fi
  if command -v git >/dev/null 2>&1 && \
     git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$project_dir" rev-parse HEAD 2>/dev/null || return 1
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
    # Hash stdin rather than a named Windows path. GNU sha256sum prefixes the
    # digest with a backslash when its filename needs escaping, so `awk $1`
    # would otherwise return `\<digest>` for D:\... paths.
    sha256sum < "$f" 2>/dev/null | awk '{print $1}'
    return $?
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$f" 2>/dev/null | awk '{print $1}'
    return $?
  fi
  return 1
}

_runtime_stdin_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Effective trust anchor.  Genesis is immutable; explicit transitions append a
# hash-chained move to a descendant HEAD without rewriting historical bytes.
_runtime_effective_anchor() {
  jq -rs 'reduce .[] as $o ("";
    if ($o.genesis? | type) == "string" then $o.genesis
    elif ($o.anchor_transition? | type) == "object" then $o.anchor_transition.to
    else . end)' "$1" 2>/dev/null
}

# Dedicated Git index + private ref trust root.  Neither touches the user's
# normal staging area or branches.  The ref keeps the exact-byte blob reachable
# across `git gc`; the alternate index supplies Git's atomic index-lock update.
_runtime_anchor_index() {
  local project_dir="$1" gd
  gd="$(git -C "$project_dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/harness-runtime-index' "$gd"
}

_runtime_anchor_ref() {
  printf '%s' 'refs/harness/runtime-manifest'
}

_runtime_anchor_receipt() {
  local project_dir="$1" gd
  gd="$(git -C "$project_dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/harness-runtime-bootstrap.json' "$gd"
}

_runtime_init_pending_path() {
  local project_dir="$1" gd
  gd="$(git -C "$project_dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/harness-runtime-init.pending' "$gd"
}

_runtime_begin_init_pending() {
  local project_dir="$1" genesis="$2" mode="$3" value1="$4" value2="${5:-}" value3="${6:-}" value4="${7:-}" pending tmp
  pending="$(_runtime_init_pending_path "$project_dir")" || return 1
  [ ! -L "$pending" ] && [ ! -e "$pending" ] || return 1
  tmp="${pending}.tmp.$$"
  if [ "$mode" = "generated" ]; then
    jq -cn --arg g "$genesis" --arg p "$value1" --arg k "$value2" --arg h "$value3" --argjson s "$value4" \
      '{schema_version:1,mode:"generated",genesis:$g,path:$p,kind:$k,sha256:$h,size:$s}' > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; return 1;
      }
  elif [ "$mode" = "explicit" ]; then
    jq -cn --arg g "$genesis" --arg h "$value1" \
      '{schema_version:1,mode:"explicit",genesis:$g,registry_sha256:$h}' > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; return 1;
      }
  else
    return 1
  fi
  if ! mv "$tmp" "$pending" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
}

_runtime_init_pending_valid() {
  local project_dir="$1" expected="$2" mode="$3" value1="$4" value2="${5:-}" value3="${6:-}" value4="${7:-}" pending
  pending="$(_runtime_init_pending_path "$project_dir")" || return 1
  [ ! -L "$pending" ] && [ -f "$pending" ] || return 1
  if [ "$mode" = "generated" ]; then
    jq -e --arg g "$expected" --arg p "$value1" --arg k "$value2" --arg h "$value3" --argjson s "$value4" '
      keys == ["genesis","kind","mode","path","schema_version","sha256","size"]
      and .schema_version == 1 and .mode == "generated" and .genesis == $g
      and .path == $p and .kind == $k and .sha256 == $h and .size == $s
    ' "$pending" >/dev/null 2>&1
  elif [ "$mode" = "explicit" ]; then
    jq -e --arg g "$expected" --arg h "$value1" '
      keys == ["genesis","mode","registry_sha256","schema_version"]
      and .schema_version == 1 and .mode == "explicit" and .genesis == $g
      and .registry_sha256 == $h
    ' "$pending" >/dev/null 2>&1
  else
    return 1
  fi
}

_runtime_generated_registry_exact() {
  local mf="$1" genesis="$2" path="$3" kind="$4" sha="$5" size="$6"
  jq -s -e --arg g "$genesis" --arg p "$path" --arg k "$kind" \
    --arg h "$sha" --argjson s "$size" '
      length == 2 and .[0] == {genesis:$g}
      and .[1] == {path:$p,kind:$k,sha256:$h,size:$s}
    ' "$mf" >/dev/null 2>&1
}

# Resolve an exact blob path from the private ref without `ref:path` syntax.
# MSYS rewrites arguments containing `:/` as Windows paths, corrupting Git's
# revision/path separator (for example `refs/...:.harness/...`). `ls-tree --`
# keeps revision and path in separate argv entries and is portable everywhere.
_runtime_ref_blob_oid() {
  local project_dir="$1" ref="$2" path="$3" row oid kind
  row="$(git -C "$project_dir" ls-tree -r "$ref" -- "$path" 2>/dev/null)" || return 1
  [ "$(printf '%s\n' "$row" | sed '/^$/d' | wc -l | tr -d '[:space:]')" = "1" ] || return 1
  kind="$(printf '%s\n' "$row" | awk 'NR==1 {print $2}')"
  oid="$(printf '%s\n' "$row" | awk 'NR==1 {print $3}')"
  [ "$kind" = "blob" ] && printf '%s' "$oid"
}

_runtime_read_ref_blob() {
  local project_dir="$1" ref="$2" path="$3" oid
  oid="$(_runtime_ref_blob_oid "$project_dir" "$ref" "$path")" || return 1
  git -C "$project_dir" cat-file blob "$oid" 2>/dev/null
}

_runtime_anchor_metadata_valid() {
  local project_dir="$1" receipt ref receipt_oid ref_receipt_oid
  receipt="$(_runtime_anchor_receipt "$project_dir")" || return 1
  [ ! -L "$receipt" ] && [ -f "$receipt" ] || return 1
  jq -e '
    keys == ["bootstrap_effective_anchor","bootstrap_registry_sha256","mode","schema_version"]
    and .schema_version == 1
    and (.mode == "generated" or .mode == "explicit")
    and (.bootstrap_effective_anchor | test("^([0-9a-f]{40}|[0-9a-f]{64})$"))
    and (.bootstrap_registry_sha256 | test("^[0-9a-f]{64}$"))
  ' "$receipt" >/dev/null 2>&1 || return 1
  # The receipt is audit evidence, so bind its exact bytes into the private
  # ref rather than trusting a mutable sidecar on schema alone. The alternate
  # index copy is checked by _runtime_verify_registry_anchor; ref-only checking
  # here intentionally keeps a missing index recoverable.
  ref="$(_runtime_anchor_ref)"
  receipt_oid="$(git -C "$project_dir" hash-object --no-filters -- "$receipt" 2>/dev/null)" || return 1
  ref_receipt_oid="$(_runtime_ref_blob_oid "$project_dir" "$ref" ".harness/runtime-bootstrap-receipt.json")" || return 1
  [ "$receipt_oid" = "$ref_receipt_oid" ]
}

_runtime_anchor_state_any() {
  local project_dir="$1" idx receipt ref
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  receipt="$(_runtime_anchor_receipt "$project_dir")" || return 1
  ref="$(_runtime_anchor_ref)"
  { [ -e "$idx" ] || [ -L "$idx" ]; } \
    || { [ -e "$receipt" ] || [ -L "$receipt" ]; } \
    || git -C "$project_dir" show-ref --verify --quiet "$ref" 2>/dev/null
}

_runtime_anchor_state_recoverable() {
  local project_dir="$1" ref
  ref="$(_runtime_anchor_ref)"
  _runtime_anchor_metadata_valid "$project_dir" \
    && git -C "$project_dir" show-ref --verify --quiet "$ref" 2>/dev/null
}

_runtime_prepare_empty_index() {
  local project_dir="$1" idx
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  if [ -L "$idx" ] || [ -e "$idx" ]; then return 1; fi
  GIT_INDEX_FILE="$idx" git -C "$project_dir" read-tree --empty >/dev/null 2>&1
}

_runtime_commit_anchor() {
  local project_dir="$1" mf="$2" idx rel blob tree old_ref new_ref ref receipt receipt_blob
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  [ ! -L "$idx" ] && [ -f "$idx" ] || return 1
  rel="${mf#"$project_dir"/}"
  blob="$(git -C "$project_dir" hash-object -w --no-filters -- "$mf" 2>/dev/null)" || return 1
  GIT_INDEX_FILE="$idx" git -C "$project_dir" update-index --add --cacheinfo 100644 "$blob" "$rel" \
    >/dev/null 2>&1 || return 1
  receipt="$(_runtime_anchor_receipt "$project_dir")" || return 1
  [ ! -L "$receipt" ] && [ -f "$receipt" ] || return 1
  receipt_blob="$(git -C "$project_dir" hash-object -w --no-filters -- "$receipt" 2>/dev/null)" || return 1
  GIT_INDEX_FILE="$idx" git -C "$project_dir" update-index --add --cacheinfo \
    100644 "$receipt_blob" ".harness/runtime-bootstrap-receipt.json" >/dev/null 2>&1 || return 1
  tree="$(GIT_INDEX_FILE="$idx" git -C "$project_dir" write-tree 2>/dev/null)" || return 1
  ref="$(_runtime_anchor_ref)"
  old_ref="$(git -C "$project_dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)"
  if [ -n "$old_ref" ]; then
    new_ref="$(printf 'harness runtime-manifest anchor\n' | git -C "$project_dir" \
      -c user.name=harness-companion -c user.email=harness@local \
      commit-tree "$tree" -p "$old_ref" 2>/dev/null)" || return 1
    git -C "$project_dir" update-ref "$ref" "$new_ref" "$old_ref" >/dev/null 2>&1 || return 1
  else
    new_ref="$(printf 'harness runtime-manifest anchor\n' | git -C "$project_dir" \
      -c user.name=harness-companion -c user.email=harness@local \
      commit-tree "$tree" 2>/dev/null)" || return 1
    git -C "$project_dir" update-ref "$ref" "$new_ref" >/dev/null 2>&1 || return 1
  fi
}

_runtime_write_bootstrap_receipt() {
  local project_dir="$1" mf="$2" mode="$3" receipt tmp sha effective
  receipt="$(_runtime_anchor_receipt "$project_dir")" || return 1
  [ ! -L "$receipt" ] && [ ! -e "$receipt" ] || return 1
  sha="$(_runtime_file_sha256 "$mf")" || return 1
  effective="$(_runtime_effective_anchor "$mf")" || return 1
  tmp="${receipt}.tmp.$$"
  if ! jq -cn --arg m "$mode" --arg s "$sha" --arg e "$effective" \
      '{schema_version:1,mode:$m,bootstrap_registry_sha256:$s,bootstrap_effective_anchor:$e}' \
      > "$tmp" 2>/dev/null || ! mv "$tmp" "$receipt" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
}

_runtime_remove_anchor_state() {
  local project_dir="$1" idx receipt ref old_ref="" ref_rc=0
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  receipt="$(_runtime_anchor_receipt "$project_dir")" || return 1
  ref="$(_runtime_anchor_ref)"
  git -C "$project_dir" show-ref --verify --quiet "$ref" 2>/dev/null
  ref_rc=$?
  if [ "$ref_rc" -eq 0 ]; then
    old_ref="$(git -C "$project_dir" rev-parse --verify "$ref" 2>/dev/null)" || return 1
    git -C "$project_dir" update-ref -d "$ref" "$old_ref" >/dev/null 2>&1 || return 1
    git -C "$project_dir" show-ref --verify --quiet "$ref" 2>/dev/null
    ref_rc=$?
    [ "$ref_rc" -eq 1 ] || return 1
  elif [ "$ref_rc" -ne 1 ]; then
    return 1
  fi
  rm -f -- "$idx" "$receipt" || return 1
  [ ! -e "$idx" ] && [ ! -L "$idx" ] && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
}

_runtime_bootstrap_registry_anchor() {
  local project_dir="$1" mf="$2" expected_sha="$3" mode="${4:-explicit}" \
    bind_path="${5:-}" bind_kind="${6:-}" bind_sha="${7:-}" bind_size="${8:-}" idx receipt ref actual
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  receipt="$(_runtime_anchor_receipt "$project_dir")" || return 1
  ref="$(_runtime_anchor_ref)"
  [ ! -L "$idx" ] && [ ! -e "$idx" ] || return 1
  [ ! -L "$receipt" ] && [ ! -e "$receipt" ] || return 1
  git -C "$project_dir" show-ref --verify --quiet "$ref" && return 1
  _runtime_validate_registry "$project_dir" "$mf" || return 1
  if [ "$mode" = "generated" ]; then
    [ -n "$bind_path" ] && [ -n "$bind_kind" ] && [ -n "$bind_sha" ] && [ -n "$bind_size" ] \
      && _runtime_generated_registry_exact "$mf" "$(_runtime_effective_anchor "$mf")" \
           "$bind_path" "$bind_kind" "$bind_sha" "$bind_size" || return 1
  fi
  actual="$(_runtime_file_sha256 "$mf")" || return 1
  [ "$actual" = "$expected_sha" ] || return 1
  _runtime_prepare_empty_index "$project_dir" || return 1
  if ! _runtime_write_bootstrap_receipt "$project_dir" "$mf" "$mode" \
     || ! _runtime_commit_anchor "$project_dir" "$mf" \
     || ! { actual="$(_runtime_file_sha256 "$mf")" && [ "$actual" = "$expected_sha" ]; } \
     || ! _runtime_verify_registry_anchor "$project_dir" "$mf"; then
    _runtime_remove_anchor_state "$project_dir" >/dev/null 2>&1 || true
    return 1
  fi
}

_runtime_anchor_registry() {
  local project_dir="$1" mf="$2" idx ref
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  ref="$(_runtime_anchor_ref)"
  [ ! -L "$idx" ] && [ -f "$idx" ] || return 1
  _runtime_anchor_metadata_valid "$project_dir" || return 1
  git -C "$project_dir" show-ref --verify --quiet "$ref" || return 1
  _runtime_commit_anchor "$project_dir" "$mf" || return 1
  _runtime_verify_registry_anchor "$project_dir" "$mf"
}

_runtime_verify_registry_anchor() {
  local project_dir="$1" mf="$2" idx rel file_oid index_oid ref_oid ref receipt receipt_oid index_receipt_oid ref_receipt_oid
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  [ ! -L "$idx" ] && [ -f "$idx" ] || return 1
  _runtime_anchor_metadata_valid "$project_dir" || return 1
  rel="${mf#"$project_dir"/}"
  ref="$(_runtime_anchor_ref)"
  file_oid="$(git -C "$project_dir" hash-object --no-filters -- "$mf" 2>/dev/null)" || return 1
  index_oid="$(GIT_INDEX_FILE="$idx" git -C "$project_dir" rev-parse ":$rel" 2>/dev/null)" || return 1
  ref_oid="$(_runtime_ref_blob_oid "$project_dir" "$ref" "$rel")" || return 1
  receipt="$(_runtime_anchor_receipt "$project_dir")" || return 1
  receipt_oid="$(git -C "$project_dir" hash-object --no-filters -- "$receipt" 2>/dev/null)" || return 1
  index_receipt_oid="$(GIT_INDEX_FILE="$idx" git -C "$project_dir" rev-parse ":.harness/runtime-bootstrap-receipt.json" 2>/dev/null)" || return 1
  ref_receipt_oid="$(_runtime_ref_blob_oid "$project_dir" "$ref" ".harness/runtime-bootstrap-receipt.json")" || return 1
  [ "$file_oid" = "$index_oid" ] && [ "$file_oid" = "$ref_oid" ] \
    && [ "$receipt_oid" = "$index_receipt_oid" ] && [ "$receipt_oid" = "$ref_receipt_oid" ]
}

# Restore the working registry from the durable private ref after an interrupted
# multi-resource transaction, then atomically reconstruct the alternate index.
_runtime_restore_registry_from_anchor() {
  local project_dir="$1" mf="$2" idx rel tmp tmp_idx ref
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  # Never replace a caller-controlled symlink in Git metadata or at the
  # working registry path. A missing/corrupt regular alternate index is
  # recoverable from the private ref; a symlink is an explicit obstacle.
  [ ! -L "$idx" ] && [ ! -L "$mf" ] || return 1
  _runtime_anchor_metadata_valid "$project_dir" || return 1
  rel="${mf#"$project_dir"/}"
  ref="$(_runtime_anchor_ref)"
  tmp="${mf}.restore.$$"
  if ! _runtime_read_ref_blob "$project_dir" "$ref" "$rel" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! _runtime_validate_registry "$project_dir" "$tmp" || ! mv "$tmp" "$mf" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  tmp_idx="${idx}.restore.$$"
  rm -f "$tmp_idx" "$tmp_idx.lock"
  if ! GIT_INDEX_FILE="$tmp_idx" git -C "$project_dir" read-tree "$ref^{tree}" >/dev/null 2>&1 \
     || ! mv "$tmp_idx" "$idx" 2>/dev/null; then
    rm -f "$tmp_idx" "$tmp_idx.lock"
    return 1
  fi
  _runtime_verify_registry_anchor "$project_dir" "$mf"
}

# Finish the narrow crash window where a fresh bootstrap committed the durable
# private ref but had not yet written its receipt (or alternate index).  The
# valid init marker proves this is the generated-bootstrap transaction, while
# the ref — not the mutable working file — supplies the authoritative bytes.
_runtime_recover_generated_anchor() {
  local project_dir="$1" mf="$2" expected="$3" mode="$4" value1="$5" value2="${6:-}" value3="${7:-}" value4="${8:-}" idx receipt ref rel tmp tmp_idx
  _runtime_init_pending_valid "$project_dir" "$expected" "$mode" "$value1" "$value2" "$value3" "$value4" || return 1
  idx="$(_runtime_anchor_index "$project_dir")" || return 1
  receipt="$(_runtime_anchor_receipt "$project_dir")" || return 1
  ref="$(_runtime_anchor_ref)"
  [ ! -L "$idx" ] && [ ! -L "$receipt" ] && [ ! -L "$mf" ] || return 1
  git -C "$project_dir" show-ref --verify --quiet "$ref" 2>/dev/null || return 1
  rel="${mf#"$project_dir"/}"
  tmp="${mf}.recover.$$"
  tmp_idx="${idx}.recover.$$"
  rm -f "$tmp" "$tmp_idx" "$tmp_idx.lock"
  if ! _runtime_read_ref_blob "$project_dir" "$ref" "$rel" > "$tmp" 2>/dev/null \
     || ! RUNTIME_MANIFEST_GENESIS="$expected" _runtime_validate_registry "$project_dir" "$tmp" \
     || { [ "$mode" = "generated" ] && ! _runtime_generated_registry_exact "$tmp" "$expected" \
            "$value1" "$value2" "$value3" "$value4"; } \
     || { [ "$mode" = "explicit" ] && [ "$(_runtime_file_sha256 "$tmp" 2>/dev/null)" != "$value1" ]; } \
     || ! mv "$tmp" "$mf" 2>/dev/null \
     || ! GIT_INDEX_FILE="$tmp_idx" git -C "$project_dir" read-tree "$ref^{tree}" >/dev/null 2>&1 \
     || ! mv "$tmp_idx" "$idx" 2>/dev/null; then
    rm -f "$tmp" "$tmp_idx" "$tmp_idx.lock"
    return 1
  fi
  if [ -e "$receipt" ]; then
    [ -f "$receipt" ] || return 1
    rm -f "$receipt" || return 1
  fi
  _runtime_write_bootstrap_receipt "$project_dir" "$mf" "$mode" \
    && _runtime_verify_registry_anchor "$project_dir" "$mf"
}

_runtime_backup_path() {
  local project_dir="$1" gd
  gd="$(git -C "$project_dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  mktemp "$gd/runtime-manifest-backup.XXXXXX"
}

_runtime_rollback_registry() {
  local project_dir="$1" mf="$2" backup="$3" existed="$4" remove_new_anchor="${5:-0}"
  if [ "$existed" = "1" ]; then
    [ -n "$backup" ] && cp "$backup" "$mf" 2>/dev/null || return 1
    _runtime_anchor_registry "$project_dir" "$mf"
  else
    rm -f -- "$mf" || return 1
    if [ "$remove_new_anchor" = "1" ]; then
      _runtime_remove_anchor_state "$project_dir"
    fi
  fi
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
# /runtime-manifest.  The parent is only a container.  Never remove an empty
# parent or leaf here: mkdir acquisition is atomic but metadata creation is
# necessarily later, so an empty directory can be a live holder in its
# initialization window.  Stale recovery belongs to the lock primitive, where
# ownership can be rechecked safely.
#   - acquire_lock's stdout prints the lock token (callers can pass it to
#     release_lock without a subshell). runtime-manifest must NOT leak that
#     token into callers' stdout. Redirect to /dev/null and rely on
#     $LOCK_REGISTRY_TOKEN (set by acquire_lock into the env) for release.
_runtime_acquire() {
  local project_dir="$1"
  local lockdir parent
  lockdir="$(runtime_lock_dir "$project_dir")"
  parent="$(dirname "$lockdir")"
  mkdir -p "$parent" || return 1
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

# ---- _runtime_validate_registry ---------------------------------------------
# Fail-closed validation of an EXISTING registry, called under the registry
# lock after genesis bootstrap. Enforces three invariants:
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
  if [ -L "$mf" ] || [ ! -f "$mf" ]; then
    echo "runtime-manifest: registry must be a regular non-symlink file" >&2
    return 1
  fi
  if [ "$(tail -c 1 "$mf" 2>/dev/null | od -An -tuC | tr -d '[:space:]')" != "10" ]; then
    echo "runtime-manifest: registry must end with LF (fail-closed)" >&2
    return 1
  fi
  local raw line idx=0 gen_count=0 gen_idx=-1 gen_val="" effective=""
  local prefix_bytes="" prefix_sha tr_from tr_to tr_prev
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    idx=$((idx + 1))
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      echo "runtime-manifest: registry line $idx is not valid JSON (fail-closed)" >&2
      return 1
    fi
    if printf '%s' "$line" | jq -e 'has("genesis")' >/dev/null 2>&1; then
      if ! printf '%s' "$line" | jq -e '
          keys == ["genesis"] and (.genesis | type == "string")
          and (.genesis | test("^([0-9a-f]{40}|[0-9a-f]{64})$"))
        ' >/dev/null 2>&1; then
        echo "runtime-manifest: invalid genesis schema" >&2
        return 1
      fi
      gen_count=$((gen_count + 1))
      if [ "$gen_count" -gt 1 ]; then
        echo "runtime-manifest: registry has duplicate genesis lines (fail-closed)" >&2
        return 1
      fi
      gen_idx=$idx
      gen_val="$(printf '%s' "$line" | jq -r '.genesis // empty' 2>/dev/null)"
      effective="$gen_val"
    elif printf '%s' "$line" | jq -e 'has("anchor_transition")' >/dev/null 2>&1; then
      if ! printf '%s' "$line" | jq -e '
          keys == ["anchor_transition"] and
          (.anchor_transition | keys == ["from","previous_sha256","to"]) and
          (.anchor_transition.from | type == "string") and
          (.anchor_transition.to | type == "string") and
          (.anchor_transition.previous_sha256 | test("^[0-9a-f]{64}$"))
        ' >/dev/null 2>&1; then
        echo "runtime-manifest: invalid anchor transition at line $idx" >&2
        return 1
      fi
      tr_from="$(printf '%s' "$line" | jq -r '.anchor_transition.from')"
      tr_to="$(printf '%s' "$line" | jq -r '.anchor_transition.to')"
      tr_prev="$(printf '%s' "$line" | jq -r '.anchor_transition.previous_sha256')"
      prefix_sha="$(printf '%s' "$prefix_bytes" | _runtime_stdin_sha256)" || return 1
      if [ -z "$effective" ] || [ "$tr_from" != "$effective" ] || [ "$tr_prev" != "$prefix_sha" ]; then
        echo "runtime-manifest: anchor transition chain mismatch at line $idx" >&2
        return 1
      fi
      if command -v git >/dev/null 2>&1 && git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
        if ! git -C "$project_dir" merge-base --is-ancestor "$tr_from" "$tr_to" 2>/dev/null; then
          echo "runtime-manifest: anchor transition is not descendant-bound" >&2
          return 1
        fi
      fi
      effective="$tr_to"
    fi
    prefix_bytes="${prefix_bytes}${raw}"$'\n'
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
  if [ -n "${RUNTIME_MANIFEST_GENESIS:-}" ] && [ "$effective" != "${RUNTIME_MANIFEST_GENESIS}" ]; then
    echo "runtime-manifest: effective anchor mismatch (expected ${RUNTIME_MANIFEST_GENESIS}, got $effective) (fail-closed)" >&2
    return 1
  fi
  return 0
}

# Append an auditable, history-preserving trust-anchor transition.  This is the
# only supported way to move an existing registry to a new release HEAD.
runtime_transition_anchor() {
  local project_dir="$1" to="$2" mf from prev tmp token rc=0 backup="" changed=0 retain_backup=0
  mf="$(runtime_manifest_path "$project_dir")"
  if [ -L "$mf" ] || [ ! -f "$mf" ]; then
    echo "runtime-manifest: transition requires regular non-symlink registry" >&2
    return 1
  fi
  _runtime_acquire "$project_dir" || return 1
  token="${LOCK_REGISTRY_TOKEN:-}"
  if ! _runtime_verify_registry_anchor "$project_dir" "$mf"; then
    if ! _runtime_restore_registry_from_anchor "$project_dir" "$mf"; then
      echo "runtime-manifest: transition requires an existing trusted anchor" >&2
      rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    backup="$(_runtime_backup_path "$project_dir")" || rc=1
    [ "$rc" -ne 0 ] || cp "$mf" "$backup" || rc=1
  fi
  if [ "$rc" -eq 0 ] && ! _runtime_validate_registry "$project_dir" "$mf"; then
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    from="$(_runtime_effective_anchor "$mf")"
    if [ "$from" = "$to" ]; then
      rc=0
    elif ! git -C "$project_dir" merge-base --is-ancestor "$from" "$to" 2>/dev/null; then
      echo "runtime-manifest: refusing non-descendant anchor transition $from -> $to" >&2
      rc=1
    else
      prev="$(_runtime_file_sha256 "$mf")" || rc=1
      tmp="${mf}.transition.$$"
      if [ "$rc" -eq 0 ] && ! {
        cat "$mf" && jq -cn --arg f "$from" --arg t "$to" --arg p "$prev" \
          '{anchor_transition:{from:$f,to:$t,previous_sha256:$p}}';
      } > "$tmp" 2>/dev/null; then rc=1; fi
      if [ "$rc" -eq 0 ] && ! RUNTIME_MANIFEST_GENESIS="$to" _runtime_validate_registry "$project_dir" "$tmp"; then rc=1; fi
      if [ "$rc" -eq 0 ] && mv "$tmp" "$mf" 2>/dev/null; then changed=1; else rc=1; fi
      rm -f "$tmp"
    fi
  fi
  if [ "$rc" -eq 0 ] && [ "$changed" = "1" ] && ! _runtime_anchor_registry "$project_dir" "$mf"; then
    echo "runtime-manifest: failed to update dedicated index anchor" >&2
    if ! _runtime_rollback_registry "$project_dir" "$mf" "$backup" 1 >/dev/null 2>&1; then
      echo "runtime-manifest: transition rollback failed" >&2
      retain_backup=1
    fi
    rc=1
  fi
  local release_rc=0
  release_lock "$(runtime_lock_dir "$project_dir")" "$token" || release_rc=$?
  if [ "$release_rc" -ne 0 ] && [ "$release_rc" -ne 8 ]; then
    # rc6/7 cannot prove this caller still owns the lock; stale recovery or a
    # successor may already have replaced the claim. Never write a rollback
    # after uncertain ownership. Keep the backup for serialized recovery.
    retain_backup=1
    release_lock "$(runtime_lock_dir "$project_dir")" "$token" >/dev/null 2>&1 || true
    rc=1
  elif [ "$release_rc" -eq 8 ]; then
    echo "runtime-manifest: transition committed; lock cleanup incomplete" >&2
  fi
  if [ "$retain_backup" = "0" ]; then
    rm -f "$backup"
  elif [ -n "$backup" ]; then
    echo "runtime-manifest: retained recovery backup at $backup" >&2
  fi
  return "$rc"
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
  if [ -L "$f" ] || [ ! -f "$f" ]; then
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
  local lock_rc=0 backup="" registry_existed=0 changed=0 bootstrap_required=0 init_pending="" expected_genesis="" new_registry_sha="" anchor_created_this_tx=0
  local pending_present=0 pending_valid=0 ref_present=0 retain_backup=0 rollback_ok=1
  local existing_h="" existing_k="" existing_s="" actual_h="" actual_s="" pending_artifact_sha="" pending_artifact_size=""
  [ -f "$mf" ] && registry_existed=1
  init_pending="$(_runtime_init_pending_path "$project_dir")" || lock_rc=1
  expected_genesis="$(runtime_manifest_genesis_value "$project_dir")" || lock_rc=1
  pending_artifact_sha="$(_runtime_file_sha256 "$f")" || lock_rc=1
  pending_artifact_size="$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r')"
  [ -n "$pending_artifact_size" ] || lock_rc=1
  if [ "$lock_rc" -eq 0 ] && { [ -e "$init_pending" ] || [ -L "$init_pending" ]; }; then
    pending_present=1
    if _runtime_init_pending_valid "$project_dir" "$expected_genesis" generated \
        "$rel" "$kind" "$pending_artifact_sha" "$pending_artifact_size"; then
      pending_valid=1
    else
      echo "runtime-manifest: invalid pending marker beside trusted anchor" >&2
      lock_rc=1
    fi
  fi
  if [ "$lock_rc" -eq 0 ] && git -C "$project_dir" show-ref --verify --quiet "$(_runtime_anchor_ref)" 2>/dev/null; then
    ref_present=1
  fi
  if [ "$lock_rc" -eq 0 ] && _runtime_anchor_state_recoverable "$project_dir"; then
    if ! _runtime_verify_registry_anchor "$project_dir" "$mf"; then
      if ! _runtime_restore_registry_from_anchor "$project_dir" "$mf"; then
        echo "runtime-manifest: trusted registry recovery failed" >&2
        lock_rc=1
      else
        registry_existed=1
      fi
    fi
    if [ "$lock_rc" -eq 0 ] && [ "$pending_present" = "1" ]; then
      rm -f "$init_pending" || lock_rc=1
    fi
  elif [ "$lock_rc" -eq 0 ] && [ "$ref_present" = "1" ] && [ "$pending_valid" = "1" ]; then
    if ! _runtime_recover_generated_anchor "$project_dir" "$mf" "$expected_genesis" generated \
        "$rel" "$kind" "$pending_artifact_sha" "$pending_artifact_size"; then
      echo "runtime-manifest: incomplete generated anchor recovery failed" >&2
      lock_rc=1
    else
      registry_existed=1
      rm -f "$init_pending" || lock_rc=1
    fi
  elif [ "$lock_rc" -eq 0 ] && _runtime_anchor_state_any "$project_dir"; then
    # Before the private ref is committed, an interrupted generated bootstrap
    # may contain an index-only partial anchor plus either the genesis-only or
    # fully appended registry.  The marker lives inside the trusted Git
    # metadata and binds the expected genesis; discard only the non-durable
    # anchor fragments, retain any regular registry bytes, and let the normal
    # validate/append/bootstrap path finish the same transaction.
    if [ "$pending_valid" = "1" ] && [ "$ref_present" = "0" ] \
       && { [ ! -e "$mf" ] || { [ ! -L "$mf" ] && [ -f "$mf" ]; }; }; then
      _runtime_remove_anchor_state "$project_dir" || lock_rc=1
      if [ ! -f "$mf" ]; then
        rm -f "$init_pending" || lock_rc=1
        pending_present=0
        pending_valid=0
      else
        registry_existed=0
        bootstrap_required=1
      fi
    else
      echo "runtime-manifest: partial or invalid anchor state (fail-closed)" >&2
      lock_rc=1
    fi
  elif [ "$lock_rc" -eq 0 ] && [ "$pending_present" = "1" ]; then
    if [ "$pending_valid" = "1" ] && [ ! -L "$mf" ] && [ -f "$mf" ]; then
      # Crash before _runtime_prepare_empty_index: resume from the atomically
      # written, structurally validated registry instead of deleting it or
      # silently adopting an unrelated legacy file.
      registry_existed=0
      bootstrap_required=1
    elif [ "$pending_valid" = "1" ] && [ ! -e "$mf" ] && [ ! -L "$mf" ]; then
      rm -f "$init_pending" || lock_rc=1
      pending_present=0
      pending_valid=0
    else
      echo "runtime-manifest: initialization recovery state is invalid" >&2
      lock_rc=1
    fi
  elif [ "$lock_rc" -eq 0 ] && [ "$registry_existed" = "1" ]; then
    echo "runtime-manifest: existing registry is unanchored; explicit bootstrap required" >&2
    lock_rc=1
  fi
  {
    # Bootstrap a truly absent registry. An EXISTING registry without genesis
    # is never repaired here: it may be a legacy file, but it is
    # indistinguishable from a registry whose trust root was deleted. Treat it
    # as tampering and leave its bytes untouched. Any legacy conversion must
    # happen through a separately audited, explicit migration before normal
    # registration is allowed.
    if [ ! -f "$mf" ]; then
      if [ "$lock_rc" -eq 0 ] && [ "$pending_present" = "0" ] \
         && ! _runtime_begin_init_pending "$project_dir" "$expected_genesis" generated \
              "$rel" "$kind" "$pending_artifact_sha" "$pending_artifact_size"; then
        lock_rc=1
      fi
      if [ "$lock_rc" -eq 0 ] && ! _runtime_init_registry "$project_dir" "$mf"; then
        lock_rc=1
      fi
    fi
    if [ "$lock_rc" -eq 0 ]; then
      # Validate the (possibly just-created) registry before
      # trusting it: valid JSONL, unique genesis at line 0, genesis == expected
      # HEAD. Fail-closed — a stale, duplicate, or tampered genesis aborts the
      # registration rather than appending to a corrupt registry.
      if ! _runtime_validate_registry "$project_dir" "$mf"; then
        lock_rc=1
      fi
    fi
    if [ "$lock_rc" -eq 0 ] && [ "$registry_existed" = "1" ]; then
      backup="$(_runtime_backup_path "$project_dir")" || lock_rc=1
      [ "$lock_rc" -ne 0 ] || cp "$mf" "$backup" || lock_rc=1
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
            changed=1
          fi
        fi
      fi
    fi
  } || lock_rc=1
  # A resumed pre-ref bootstrap may already contain this exact path, leaving
  # changed=0 through the idempotency branch. bootstrap_required makes trust
  # finalization independent of whether this invocation appended new bytes.
  if [ "$lock_rc" -eq 0 ] && [ "$registry_existed" = "0" ]; then
    existing_h="$(jq -rs --arg p "$rel" '.[] | select(.path? == $p) | .sha256' "$mf" 2>/dev/null)"
    existing_k="$(jq -rs --arg p "$rel" '.[] | select(.path? == $p) | .kind' "$mf" 2>/dev/null)"
    existing_s="$(jq -rs --arg p "$rel" '.[] | select(.path? == $p) | .size' "$mf" 2>/dev/null)"
    actual_h="$(_runtime_file_sha256 "$f" 2>/dev/null || true)"
    actual_s="$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r')"
    if [ "$existing_h" != "$actual_h" ] || [ "$existing_k" != "$kind" ] \
       || [ "$existing_s" != "$actual_s" ] \
        || ! _runtime_generated_registry_exact "$mf" "$expected_genesis" "$rel" "$kind" \
             "$pending_artifact_sha" "$pending_artifact_size"; then
      echo "runtime-manifest: pending bootstrap entry does not match current artifact" >&2
      lock_rc=1
    fi
  fi
  if [ "$lock_rc" -eq 0 ] && { [ "$changed" = "1" ] || [ "$bootstrap_required" = "1" ]; }; then
    if [ "$registry_existed" = "1" ]; then
      _runtime_anchor_registry "$project_dir" "$mf" || lock_rc=1
    else
      new_registry_sha="$(_runtime_file_sha256 "$mf")" || lock_rc=1
      # From this point onward a failed bootstrap may have published any subset
      # of index/receipt/ref state. Rollback must always attempt full removal.
      [ "$lock_rc" -ne 0 ] || anchor_created_this_tx=1
      [ "$lock_rc" -ne 0 ] || _runtime_bootstrap_registry_anchor \
        "$project_dir" "$mf" "$new_registry_sha" generated \
        "$rel" "$kind" "$pending_artifact_sha" "$pending_artifact_size" || lock_rc=1
      if [ "$lock_rc" -eq 0 ]; then rm -f "$init_pending" || lock_rc=1; fi
    fi
  fi
  if [ "$lock_rc" -ne 0 ] && { [ "$changed" = "1" ] || [ "$registry_existed" = "0" ]; }; then
    echo "runtime-manifest: dedicated index anchoring failed; rolling back registry" >&2
    if ! _runtime_rollback_registry "$project_dir" "$mf" "$backup" "$registry_existed" "$anchor_created_this_tx" >/dev/null 2>&1; then
      echo "runtime-manifest: registration rollback failed" >&2
      retain_backup=1
      rollback_ok=0
    fi
    if [ "$registry_existed" = "0" ] && [ "$rollback_ok" = "1" ]; then
      rm -f "$init_pending" || { rollback_ok=0; retain_backup=1; }
    fi
  fi
  local release_rc=0
  _runtime_release "$project_dir" || release_rc=$?
  if [ "$release_rc" -ne 0 ] && [ "$release_rc" -ne 8 ]; then
    echo "runtime-manifest: failed to release registry lock" >&2
    # Ownership is unknown/lost. Do not overwrite a possible successor; the
    # committed registration is idempotent and recovery material is retained.
    retain_backup=1
    _runtime_release "$project_dir" >/dev/null 2>&1 || true
    lock_rc=1
  elif [ "$release_rc" -eq 8 ]; then
    echo "runtime-manifest: registration committed; lock cleanup incomplete" >&2
  fi
  if [ "$retain_backup" = "0" ]; then
    rm -f "$backup"
  elif [ -n "$backup" ]; then
    echo "runtime-manifest: retained recovery backup at $backup" >&2
  fi
  return "$lock_rc"
}

# ---- runtime_register_batch -------------------------------------------------
# Register a NUL-delimited stream of repository-relative paths under one kind.
# This is the scalable equivalent of repeated runtime_register calls for a
# recovered artifact set: it verifies the existing dedicated anchor, appends
# every new record to a private same-directory file, validates the completed
# registry, publishes it once, and updates the Git index anchor once. The live
# registry is restored byte-for-byte if the anchor update fails.
#
# An anchored registry must already exist. Normal producers should continue to
# use runtime_register for first creation and one-at-a-time publication.
runtime_register_batch() {
  local project_dir="$1" kind="$2" rel seen f mf tmp backup="" rc=0 changed=0 release_rc=0 retain_backup=0
  local -a rels=()
  case "$kind" in
    eval_candidate|eval_result) ;;
    *)
      echo "runtime-manifest: unsupported batch artifact kind: $kind" >&2
      return 1
      ;;
  esac
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    for seen in "${rels[@]}"; do
      if [ "$seen" = "$rel" ]; then
        echo "runtime-manifest: duplicate path in batch: $rel" >&2
        return 1
      fi
    done
    rels+=("$rel")
  done
  [ "${#rels[@]}" -gt 0 ] || return 0

  project_dir="$(cd "$project_dir" 2>/dev/null && pwd)" || return 1
  mf="$(runtime_manifest_path "$project_dir")"
  if [ -L "$mf" ] || [ ! -f "$mf" ]; then
    echo "runtime-manifest: batch registration requires an existing regular registry" >&2
    return 1
  fi

  # Reject the whole batch before taking the lock if any source is already
  # missing or is a symlink. Sources are checked again while hashing below.
  for rel in "${rels[@]}"; do
    f="$project_dir/$rel"
    if [ -L "$f" ] || [ ! -f "$f" ]; then
      echo "runtime-manifest: refusing to batch-register missing file: $rel" >&2
      return 1
    fi
  done

  _runtime_acquire "$project_dir" || {
    echo "runtime-manifest: failed to acquire registry lock" >&2
    return 1
  }

  tmp="${mf}.batch.$$"
  if ! _runtime_verify_registry_anchor "$project_dir" "$mf" \
     || ! _runtime_validate_registry "$project_dir" "$mf"; then
    echo "runtime-manifest: existing registry or dedicated anchor is invalid" >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    backup="$(_runtime_backup_path "$project_dir")" || rc=1
    [ "$rc" -ne 0 ] || cp "$mf" "$backup" || rc=1
    [ "$rc" -ne 0 ] || cp "$mf" "$tmp" || rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    for rel in "${rels[@]}"; do
      f="$project_dir/$rel"
      local h sz
      if [ -L "$f" ] || [ ! -f "$f" ] || ! h="$(_runtime_file_sha256 "$f")"; then
        echo "runtime-manifest: batch source changed or hash failed: $rel" >&2
        rc=1
        break
      fi
      sz="$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r')"
      if [ -z "$sz" ]; then
        echo "runtime-manifest: failed to measure batch entry for $rel" >&2
        rc=1
        break
      fi
      if jq -e -s --arg p "$rel" 'any(.[]; .path? == $p)' "$tmp" >/dev/null 2>&1; then
        if ! jq -e -s --arg p "$rel" --arg k "$kind" --arg h "$h" --argjson s "$sz" '
          ([.[] | select(.path? == $p)] | length) == 1
          and any(.[]; .path? == $p and .kind == $k and .sha256 == $h and .size == $s)
        ' "$tmp" >/dev/null 2>&1; then
          echo "runtime-manifest: existing batch binding does not match current artifact: $rel" >&2
          rc=1
          break
        fi
        continue
      fi
      if ! jq -cn --arg p "$rel" --arg k "$kind" --arg h "$h" --argjson s "$sz" \
          '{path:$p, kind:$k, sha256:$h, size:$s}' >>"$tmp" 2>/dev/null; then
        echo "runtime-manifest: failed to build batch entry for $rel" >&2
        rc=1
        break
      fi
      changed=1
    done
  fi

  if [ "$rc" -eq 0 ] && [ "$changed" = "1" ]; then
    if ! _runtime_validate_registry "$project_dir" "$tmp" || ! mv "$tmp" "$mf" 2>/dev/null; then
      echo "runtime-manifest: batch registry validation or publication failed" >&2
      rc=1
    elif ! _runtime_anchor_registry "$project_dir" "$mf"; then
      echo "runtime-manifest: batch anchor update failed; rolling back registry" >&2
      if ! _runtime_rollback_registry "$project_dir" "$mf" "$backup" 1 >/dev/null 2>&1; then
        echo "runtime-manifest: batch rollback failed" >&2
        retain_backup=1
      fi
      rc=1
    fi
  fi

  rm -f "$tmp"
  _runtime_release "$project_dir" || release_rc=$?
  if [ "$release_rc" -ne 0 ] && [ "$release_rc" -ne 8 ]; then
    echo "runtime-manifest: failed to release registry lock after batch" >&2
    # Ownership is uncertain. Keep the exact pre-publication bytes for a
    # serialized recovery instead of deleting the only trustworthy rollback.
    retain_backup=1
    _runtime_release "$project_dir" >/dev/null 2>&1 || true
    rc=1
  elif [ "$release_rc" -eq 8 ]; then
    echo "runtime-manifest: batch committed; lock cleanup incomplete" >&2
  fi
  if [ "$retain_backup" = "0" ]; then
    [ -z "$backup" ] || rm -f "$backup"
  elif [ -n "$backup" ]; then
    echo "runtime-manifest: retained batch recovery backup at $backup" >&2
  fi
  return "$rc"
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
