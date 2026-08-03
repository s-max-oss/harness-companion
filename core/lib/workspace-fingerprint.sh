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

# Strip git diff path-header lines of the leading project_prefix.
# When project_dir is a subdir of the git root, git's diff output uses paths
# like "diff --git a/projects/my-app/foo.txt b/projects/my-app/foo.txt". We
# need to feed only "foo.txt" semantics into the fingerprint hash, otherwise
# the fingerprint becomes a function of the absolute location instead of the
# content. Content lines never start with "diff --git a/" or "--- a/" or
# "+++ b/", so the substitution is safe for normal diffs.
#
# project_prefix is the git-relative path WITH a trailing slash (e.g.
# "projects/my-app/") as returned by `git rev-parse --show-prefix`.
#
# CRITICAL — both sides of "diff --git" lines must be stripped independently:
# git's rename detection can emit "diff --git a/OLD b/NEW" where the two
# paths differ. A naive sequential sed pipeline that anchors at `^` for the
# b/ branch will MISS the b/ side because after stripping the a/ side, the
# line no longer starts with "diff --git b/". We therefore:
#   1. Restrict all substitutions to lines starting with the expected prefix
#      so we never mutate content lines (which never start with "diff --git",
#      "--- a/", or "+++ b/").
#   2. For the "diff --git" line, strip the a/ side at start AND strip any
#      " b/<prefix>/" anywhere on that line — this catches renames where the
#      b/ side appears mid-line.
_strip_diff_prefix() {
  local prefix="$1"
  if [ -z "$prefix" ]; then
    cat
    return
  fi
  # Escape regex specials in the prefix so it can be embedded in an awk
  # regex. awk's regex syntax is ERE, so we escape `.+^$(){}|\` (anything
  # special in ERE).
  local safe_prefix
  safe_prefix="$(printf '%s' "$prefix" | sed 's/[.+^$(){}|\\]/\\&/g')"
  # Use awk rather than sed because Git Bash sed mishandles `/` in patterns
  # when the address form `/regex/` is mixed with the path's `/` characters.
  # awk's sub()/gsub() don't need a delimiter char, so the path's `/` is
  # never ambiguous.
  #
  # Address-restricted subs on the four git-diff header lines:
  #   diff --git a/<PREFIX>/X b/<PREFIX>/Y  (rename: a/OLD b/NEW where both
  #                                          may live inside <PREFIX>/)
  #   --- a/<PREFIX>/X
  #   +++ b/<PREFIX>/X
  # We strip the a/ side at start AND any " b/<PREFIX>/" anywhere on the
  # diff --git line so rename cases are covered (the b/ side may appear
  # mid-line after a/ stripping).
  awk -v p="$safe_prefix" '
    /^diff --git a\// {
      sub("^diff --git a/" p, "diff --git a/")
      sub(" b/" p, " b/")
      print
      next
    }
    /^--- a\// { sub("^--- a/" p, "--- a/"); print; next }
    /^\+\+\+ b\// { sub("^+++ b/" p, "+++ b/"); print; next }
    { print }
  '
}

# Convert a glob pattern to an extended-regex pattern.
# * → .*, ? → ., all other regex specials escaped.
_glob_to_regex() {
  printf '%s' "$1" | sed -e 's/[.+^$(){}|\\]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g'
}

# Build a single awk regex that matches ANY path satisfying BUILTIN_EXCLUDES
# or FINGERPRINT_EXCLUDES. Used by _filter_diff_excluded to drop whole-file
# diff chunks for excluded files.
_build_exclude_awk_pat() {
  local pat="" sep="" rx p
  for p in "${BUILTIN_EXCLUDES[@]}"; do
    [ -z "$p" ] && continue
    rx="$(_glob_to_regex "$p")"
    pat="${pat}${sep}${rx}"
    sep="|"
  done
  for p in "${FINGERPRINT_EXCLUDES[@]:-}"; do
    [ -z "$p" ] && continue
    rx="$(_glob_to_regex "$p")"
    pat="${pat}${sep}${rx}"
    sep="|"
  done
  printf '%s' "$pat"
}

# Drop diff chunks whose b/ path matches the exclude pattern. Each chunk
# starts with "diff --git a/X b/Y" and ends at the next "diff --git" or EOF.
# The b/ side is the post-rename name, which is the canonical path for
# staleness bookkeeping.
_filter_diff_excluded() {
  local pat="$1"
  awk -v pat="$pat" '
    BEGIN { skip = 0 }
    /^diff --git/ {
      bpath = ""
      # Format: "diff --git a/X b/Y" — split and take the 4th field
      n = split($0, parts, " ")
      if (n >= 4) {
        bpath = parts[4]
        sub(/^b\//, "", bpath)
      }
      if (pat != "" && bpath ~ pat) {
        skip = 1
        next
      }
      skip = 0
      print
      next
    }
    skip { next }
    { print }
  '
}

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

    # Detect git root and project_prefix — when project_dir is a subdirectory
    # of the git root (monorepo / nested project), git's diff and ls-files
    # output paths are RELATIVE TO GIT ROOT, not project_dir. Without scoping,
    # sibling directories would pollute the fingerprint and the untracked-file
    # hash would point at wrong paths.
    #
    # We use `git rev-parse --show-prefix` (which returns the git-relative path
    # of the cwd WITH a trailing slash, e.g. "projects/my-app/") rather than
    # comparing absolute paths in bash. This avoids cross-platform pitfalls
    # where Git Bash's POSIX-style /tmp paths don't share a prefix with git's
    # Windows-style C:/... toplevel output.
    local git_root=""
    git_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    local project_prefix=""
    project_prefix="$(git -C "$project_dir" rev-parse --show-prefix 2>/dev/null || true)"
    # show-prefix returns "" when cwd IS git root; normalize trailing slash
    case "$project_prefix" in
      ""|"./") project_prefix="" ;;
    esac

    # Build a single awk regex from BUILTIN_EXCLUDES + FINGERPRINT_EXCLUDES.
    # Used to drop whole-file diff chunks from staged/unstaged output — the
    # exclusion must apply uniformly to all three input classes (staged,
    # unstaged, untracked), otherwise a committed feature_list.json or
    # .harness/config.json edit would invalidate the fingerprint and break
    # passing eligibility the moment --write mutates them.
    local exclude_awk_pat=""
    exclude_awk_pat="$(_build_exclude_awk_pat)"

    if [ -z "$project_prefix" ]; then
      # ---- project_dir IS the git root — original behavior ----
      # Staged changes: HEAD vs index (git diff --cached HEAD)
      staged="$(git -C "$project_dir" diff --cached HEAD -- . :/ 2>/dev/null | _filter_diff_excluded "$exclude_awk_pat" || true)"

      # Unstaged changes: index vs working tree (git diff, NOT git diff HEAD)
      # Plan v4 correction: git diff HEAD would double-count staged changes.
      unstaged="$(git -C "$project_dir" diff -- . :/ 2>/dev/null | _filter_diff_excluded "$exclude_awk_pat" || true)"

      # Untracked files
      untracked_files="$(git -C "$project_dir" ls-files --others --exclude-standard 2>/dev/null || true)"
    else
      # ---- project_dir is subdir of git root — scoped behavior ----
      # Run from git_root and use "<project_prefix>" as pathspec so sibling
      # directories are excluded. project_prefix already has the trailing "/",
      # so no extra separator is added. Then strip the project_prefix from
      # diff path lines so the hash reflects project content, not absolute
      # location. Finally, apply the same exclusion filter as the git-root
      # case so tracked and untracked files share one exclude list.
      staged="$(git -C "$git_root" diff --cached HEAD -- "$project_prefix" 2>/dev/null | _strip_diff_prefix "$project_prefix" | _filter_diff_excluded "$exclude_awk_pat" || true)"

      unstaged="$(git -C "$git_root" diff -- "$project_prefix" 2>/dev/null | _strip_diff_prefix "$project_prefix" | _filter_diff_excluded "$exclude_awk_pat" || true)"

      # Untracked: run from git_root with project_prefix as pathspec so the
      # output is scoped to our project AND relative to git_root. Then strip
      # the project_prefix so downstream hashing reads "$project_dir/<path>"
      # correctly.
      #
      # Note: we deliberately do NOT use `git -C "$project_dir"` here. When
      # git's cwd is the subdir, ls-files paths are relative to that subdir
      # (not git_root), which would require a different prefix-strip step and
      # could miss files when pathspec interactions get tricky. Running from
      # git_root with explicit pathspec is the canonical scoping form.
      untracked_files="$(
        git -C "$git_root" ls-files --others --exclude-standard -- "$project_prefix" 2>/dev/null \
          | sed -e "s|^${project_prefix}||" \
          || true
      )"
    fi

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
