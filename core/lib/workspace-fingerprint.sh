#!/bin/bash
# workspace-fingerprint.sh — Compute workspace fingerprint (v2)
#
# Design §11: Workspace Fingerprint
# Computes a stable hash of workspace state, excluding harness self-artifacts.
#
# Usage:
#   source workspace-fingerprint.sh
#   compute_workspace_fingerprint [project_dir]
#
# Returns fingerprint string on stdout:
#   "clean"            — clean git working tree
#   "sha256:<hex>"     — dirty working tree (or no-git content hash)
#   "no_git"           — no VCS, no verification_scope configured
#
# Key corrections from plan v4:
#   - unstaged: git diff (index vs working tree), NOT git diff HEAD
#   - staged:   git diff --cached HEAD
#   - NUL-delimited stream via temp file OUTSIDE fingerprint scope
#   - Built-in excludes (.harness/) are non-overridable



# Built-in excludes — MUST, not user-overridable (design §11.0)
# feature_list.json: registry of feature→run evidence. --write mutates this
#   file outside the verification lifecycle; including it in the fingerprint
#   would invalidate passing eligibility the moment an association is written.
# .harness/config.json: has its own staleness axis (config_sha256). Counting
#   it in the workspace fingerprint would double-count and create confusion
#   when --config or similar tool touches it.
BUILTIN_EXCLUDES=(
  ".harness/logs/"
  ".harness/.registry.lock/"
  ".harness/*.tmp.*"
  "feature_list.json"
  ".harness/config.json"
)

# Default configurable excludes (design §11.0)
DEFAULT_EXCLUDES=(
  "node_modules/"
  ".git/"
  "__pycache__/"
  "*.pyc"
  ".DS_Store"
  "Thumbs.db"
)

# ---- helpers ---------------------------------------------------------------

# Check if a path matches any exclude glob pattern.
# Uses grep for pattern matching; returns 0 (true) if excluded.
_is_excluded() {
  local path="$1"
  local pattern
  # Built-in excludes always checked first — not overridable
  # Supports glob patterns: * → .*, ? → ., literal otherwise
  local escaped
  for pattern in "${BUILTIN_EXCLUDES[@]}"; do
    escaped="$(printf '%s' "$pattern" | sed 's/\./\\./g; s/[*]/.*/g; s/[?]/./g')"
    if printf '%s' "$path" | grep -qE "$escaped" 2>/dev/null; then
      return 0
    fi
  done
  # Configurable excludes
  for pattern in "${FINGERPRINT_EXCLUDES[@]:-}"; do
    [ -z "$pattern" ] && continue
    escaped="$(printf '%s' "$pattern" | sed 's/\./\\./g; s/[*]/.*/g; s/[?]/./g')"
    if printf '%s' "$path" | grep -qE "$escaped" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Check if a path is within verification scope.
# Default: everything in project_dir is in scope.
# If config specifies verification_scope, only that subtree is in scope.
_is_in_scope() {
  local path="$1"
  local scope="${VERIFICATION_SCOPE:-}"
  if [ -z "$scope" ]; then
    return 0  # everything in scope
  fi
  # scope is a root-relative path; path must start with it
  case "$path" in
    "$scope"|"$scope/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Compute SHA-256 of a regular file.
_sha256_file() {
  local f="$1"
  if [ ! -f "$f" ]; then
    printf 'null'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    printf 'null'
  fi
}

# Compute SHA-256 of stdin content (for git diff output).
_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    printf 'null'
  fi
}

# ---- compute_workspace_fingerprint -----------------------------------------
# Args: [project_dir] (defaults to .)
# Output: fingerprint string on stdout
compute_workspace_fingerprint() {
  local project_dir="${1:-.}"

  # Load configurable excludes from .harness/config.json if present
  local config_file="$project_dir/.harness/config.json"
  FINGERPRINT_EXCLUDES=()
  if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1; then
    # Read user-configured excludes; defaults used if field absent
    local user_excludes
    user_excludes="$(jq -r '.fingerprint_exclude[]? // empty' "$config_file" 2>/dev/null || true)"
    if [ -n "$user_excludes" ]; then
      while IFS= read -r pat; do
        [ -n "$pat" ] && FINGERPRINT_EXCLUDES+=("$pat")
      done <<<"$user_excludes"
    fi
  fi
  # Ensure defaults for any not explicitly set
  if [ "${#FINGERPRINT_EXCLUDES[@]}" -eq 0 ]; then
    FINGERPRINT_EXCLUDES=("${DEFAULT_EXCLUDES[@]}")
  fi

  # Read verification scope
  VERIFICATION_SCOPE=""
  if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1; then
    VERIFICATION_SCOPE="$(jq -r '.verification_scope // empty' "$config_file" 2>/dev/null || true)"
  fi

  # ---- Git path ----
  if git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    local staged unstaged untracked_files

    # Staged changes: HEAD vs index (git diff --cached HEAD)
    staged="$(git -C "$project_dir" diff --cached HEAD -- . :/ 2>/dev/null || true)"

    # Unstaged changes: index vs working tree (git diff, NOT git diff HEAD)
    # Plan v4 correction: git diff HEAD would double-count staged changes.
    unstaged="$(git -C "$project_dir" diff -- . :/ 2>/dev/null || true)"

    # Untracked files
    untracked_files="$(git -C "$project_dir" ls-files --others --exclude-standard 2>/dev/null || true)"

    # Build sorted, NUL-delimited path:hash sequence
    # NUL bytes MUST NOT be stored in bash variables — use a temp file outside
    # fingerprint scope (design §11.1).
    local tmpfile entries_count
    tmpfile="$(mktemp -t harness-fp-XXXXXX 2>/dev/null || mktemp 2>/dev/null || printf '/tmp/harness-fp-%s' "$$")"
    entries_count=0

    if [ -n "$untracked_files" ]; then
      local f
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        if _is_excluded "$f"; then continue; fi
        if ! _is_in_scope "$f"; then continue; fi
        if [ ! -f "$project_dir/$f" ]; then continue; fi
        local fhash
        fhash="$(_sha256_file "$project_dir/$f")"
        # Write path\0hash\0 to temp file
        printf '%s\0%s\0' "$f" "$fhash" >> "$tmpfile"
        entries_count=$((entries_count + 1))
      done <<<"$untracked_files"
    fi

    # Combined output: staged + separator + unstaged + separator + untracked blob
    local combined=""
    if [ -n "$staged" ] || [ -n "$unstaged" ] || [ "$entries_count" -gt 0 ]; then
      # Sort the temp file entries by path (NUL-delimited sort)
      # We use sort -z for NUL-delimited records
      # Compute final hash by piping all parts through sha256.
      # IMPORTANT: NUL bytes must NOT be stored in bash variables — pipe
      # everything directly into the hash function.
      local final_hash
      final_hash="$(
        {
          { printf '%s' "$staged";   printf '\0---STAGED---\0'; }
          { printf '%s' "$unstaged"; printf '\0---UNSTAGED---\0'; }
          if [ "$entries_count" -gt 0 ]; then
            sort -z < "$tmpfile" 2>/dev/null || cat "$tmpfile"
          fi
        } | _sha256_stdin
      )"
      rm -f "$tmpfile"
      printf 'sha256:%s' "$final_hash"
    else
      rm -f "$tmpfile"
      printf 'clean'
    fi
    return 0
  fi

  # ---- No-git path ----
  # Hash configurable verification scope
  local scope_dir="$project_dir"
  if [ -n "${VERIFICATION_SCOPE:-}" ]; then
    scope_dir="$project_dir/$VERIFICATION_SCOPE"
    if [ ! -d "$scope_dir" ]; then
      printf 'no_git'
      return 0
    fi
  fi

  # List all files in scope, excluding fingerprints
  local tmpfile
  tmpfile="$(mktemp -t harness-fp-XXXXXX 2>/dev/null || mktemp 2>/dev/null || printf '/tmp/harness-fp-%s' "$$")"
  local entries_count
  entries_count=0

  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local rel="${f#$project_dir/}"
    if _is_excluded "$rel"; then continue; fi
    if ! _is_in_scope "$rel"; then continue; fi
    if [ ! -f "$f" ]; then continue; fi
    local fhash
    fhash="$(_sha256_file "$f")"
    printf '%s\0%s\0' "$rel" "$fhash" >> "$tmpfile"
    entries_count=$((entries_count + 1))
  done < <(find "$scope_dir" -type f 2>/dev/null || true)

  if [ "$entries_count" -gt 0 ]; then
    local final_hash
    final_hash="$(sort -z < "$tmpfile" 2>/dev/null | _sha256_stdin || { cat "$tmpfile" | _sha256_stdin; })"
    rm -f "$tmpfile"
    printf 'sha256:%s' "$final_hash"
  else
    rm -f "$tmpfile"
    printf 'no_git'
  fi
}
