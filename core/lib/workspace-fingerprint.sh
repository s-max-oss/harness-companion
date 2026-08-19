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
# .harness/reviews/: append-only Reviewer verdict artifacts (§5-b.6). New
#   verdict files are runtime state written outside the verification lifecycle
#   (via core/harness-verdict.sh); including them in the fingerprint would make
#   every review a staleness breach.
# .harness/branch-gate.json: stateful Phase 1 branch-baseline gate (P0-2).
#   Recorded ONCE by a successful init (core/lib/branch-gate.sh). Including it
#   in the fingerprint would make every ready-transition an Axis1 staleness
#   breach — a successful init must not self-pollute the fingerprint.
# .harness/registry-journal.ndjson: append-only mutation journal (P0-M2).
#   Every feature_list.json mutation appends a line; the journal is runtime
#   state written by harness-feature.sh itself, so including it in the
#   fingerprint would make every feature status change a staleness breach.
# .harness/runtime-manifest.jsonl: runtime-artifact byte-binding registry
#   (Codex r7). Written by runtime_register / runtime_register_run during
#   verification and review; it binds first-seen bytes of run NDJSON, command
#   logs, and verdicts so the DWM gate can enforce immutability/append-only.
#   It is runtime state written by the harness itself AFTER the run's
#   fingerprint is captured, so including it in the fingerprint would make
#   every self-registration a staleness breach (the same reason
#   registry-journal.ndjson and reviews/ are excluded).
BUILTIN_EXCLUDES=(
  ".harness/logs/"
  ".harness/reviews/"
  ".harness/acceptance/"
  ".harness/.registry.lock/"
  ".harness/*.tmp.*"
  ".harness/branch-gate.json"
  ".harness/registry-journal.ndjson"
  ".harness/runtime-manifest.jsonl"
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
# The awk sub() calls use [.] for literal dots instead of \. — this avoids
# the "escape sequence `\.' treated as plain `.'" warning on GNU awk ≥5.
_strip_diff_prefix() {
  local prefix="$1"
  if [ -z "$prefix" ]; then
    cat
    return
  fi
  # Escape regex specials. Use [.] for dots so awk never warns.
  local safe_prefix
  safe_prefix="$(printf '%s' "$prefix" | sed \
    -e 's/\./[.]/g' \
    -e 's/[+^$(){}|\\]/\\&/g')"
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

# Convert a glob exclude pattern to an ERE fragment with proper anchoring.
#
# Anchoring rules (so "feature_list.json" does NOT match "myfeature_list.json.bak"):
#   literal (no * or ?)     → ^<regex>$
#   ends with /             → ^<regex>     (prefix match)
#   wildcard (* or ?)       → ^<regex>$
#
# Dots are rendered as [.] (not \.) so awk never emits "escape sequence"
# warnings. Glob * → [^/]*, ? → [^/].
_glob_to_regex() {
  local raw="$1"
  local has_wildcard=0 trailing_slash=0
  case "$raw" in *"*"*|*"?"*) has_wildcard=1 ;; esac
  case "$raw" in */) trailing_slash=1 ;; esac

  # Pure-bash escape of ERE specials (no sed forks) — output is identical to
  # the former `printf '%s' "$raw" | sed -e 's/\\/\\\\/g' -e 's/\./[.]/g' \
  # -e 's/[+^$(){}|]/\\&/g'`. Backslash first, then dot (→ [.] to suppress awk
  # warnings), then the + ^ $ ( ) { } | set, each prefixed with a backslash.
  # Each replacement is literal in the pattern position, so no collation and
  # no locale dependence (keeps P0-9 determinism).
  local rx="$raw"
  rx="${rx//\\/\\\\}"
  rx="${rx//./[.]}"
  local ch
  for ch in '+' '^' '$' '(' ')' '{' '}' '|'; do
    rx="${rx//"$ch"/\\$ch}"
  done

  # Step 2: convert glob wildcards (glob * crosses '/', ERE [^/]* does not —
  # keep the SAME [^/]* the sed version produced, not a bare '*')
  if [ "$has_wildcard" -eq 1 ]; then
    rx="${rx//\*/[^/]*}"
    rx="${rx//\?/[^/]}"
  fi

  # Step 3: anchor
  if [ "$has_wildcard" -eq 1 ]; then
    printf '^%s$' "$rx"
  elif [ "$trailing_slash" -eq 1 ]; then
    printf '^%s' "$rx"
  else
    printf '^%s$' "$rx"
  fi
}

# Build a single awk ERE alternation from BUILTIN_EXCLUDES + FINGERPRINT_EXCLUDES.
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

# Drop diff chunks whose BOTH a/ and b/ paths match an exclude pattern.
# If only ONE side is excluded (e.g. "diff --git a/src/hello.txt b/.harness/logs/hello.txt"
# — a rename from a non-excluded file INTO an excluded directory), the chunk
# is KEPT so the deletion of the original file is still recorded in the fingerprint.
#
# Chunks where both sides are excluded are dropped entirely.
_filter_diff_excluded() {
  local pat="$1"
  awk -v pat="$pat" '
    BEGIN { skip = 0 }
    /^diff --git/ {
      apath = ""; bpath = ""
      n = split($0, parts, " ")
      if (n >= 3) { apath = parts[3]; sub(/^a\//, "", apath) }
      if (n >= 4) { bpath = parts[4]; sub(/^b\//, "", bpath) }
      a_excl = (pat != "" && apath ~ pat)
      b_excl = (pat != "" && bpath ~ pat)
      if (a_excl && b_excl) {
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

# Combined anchored ERE over BUILTIN_EXCLUDES + FINGERPRINT_EXCLUDES.
# Built ONCE per compute (see _compute_workspace_fingerprint_inner) and reused
# by _is_excluded. The previous per-pattern loop re-derived a regex (2 sed
# forks) and spawned a grep for EVERY pattern on EVERY path — on MSYS each
# fork+exec costs ~150 ms, so a dirty tree with many untracked files turned a
# single staleness check into a multi-minute crawl (~1500 forks). Matching via
# bash's built-in `[[ $path =~ $ere ]]` (POSIX ERE) spawns nothing and is
# byte-identical to grep -E for this pattern set: dots become [.], wildcards
# [^/]*, no collation-dependent classes, so it is also locale-independent.
_FP_EXCLUDE_ERE=""

# Check if a path matches any exclude glob pattern.
# Returns 0 (true) if excluded. Uses the precomputed anchored ERE so
# "feature_list.json" does NOT match "myfeature_list.json.bak".
_is_excluded() {
  local path="$1"
  if [ -z "$_FP_EXCLUDE_ERE" ]; then
    # Direct call outside a compute (e.g. a helper): derive once from the arrays.
    _FP_EXCLUDE_ERE="$(_build_exclude_awk_pat)"
  fi
  [[ "$path" =~ $_FP_EXCLUDE_ERE ]] && return 0
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

  # P0-9: Force canonical C locale for the ENTIRE computation so the
  # fingerprint is byte-for-byte deterministic regardless of the caller's
  # environment. Without this, `sort -z` collation (and character-class
  # handling in awk/grep) differs between locales, so a non-C locale (e.g.
  # zh_CN.UTF-8) could reorder untracked-file entries or match exclusions
  # differently and change the SHA.
  #
  # `local LC_ALL=C` alone is NOT sufficient (P0-9 propagation bug): bash
  # auto-exports a `local` variable ONLY when it shadows an inherited
  # environment variable. When the caller has LC_ALL completely UNSET
  # (`env -u LC_ALL LANG=zh_CN.UTF-8`), the local C assignment never reaches
  # the `sort -z`/`awk` children, which silently fall back to LANG's collation
  # and produce a DIFFERENT fingerprint. We therefore `export LC_ALL=C` for
  # the duration and restore the caller's EXACT prior state (value AND export
  # attribute) before returning, so the caller's environment is never polluted.
  local _fp_saved_lc_val="${LC_ALL-}"
  local _fp_lc_had_set=0 _fp_lc_in_env=0
  [ -n "${LC_ALL+x}" ] && _fp_lc_had_set=1
  env | grep -q '^LC_ALL=' && _fp_lc_in_env=1
  export LC_ALL=C

  local _fp_rc=0
  _compute_workspace_fingerprint_inner "$project_dir"
  _fp_rc=$?

  # Restore the caller's exact LC_ALL state (value AND export attribute).
  if [ "$_fp_lc_had_set" = 1 ]; then
    if [ "$_fp_lc_in_env" = 1 ]; then
      export LC_ALL="$_fp_saved_lc_val"
    else
      export -n LC_ALL 2>/dev/null || unset LC_ALL
      LC_ALL="$_fp_saved_lc_val"
    fi
  else
    unset LC_ALL 2>/dev/null
  fi
  return "$_fp_rc"
}

# The computation body — runs under the wrapper's exported LC_ALL=C. Kept as a
# separate function so compute_workspace_fingerprint has a single restore point.
#
# P0-M1: every call re-derives BUILTIN_EXCLUDES + FINGERPRINT_EXCLUDES +
# VERIFICATION_SCOPE from the CURRENT project's .harness/config.json (or the
# hard-coded defaults if absent) and rebuilds the combined ERE. No caller-side
# state carries across projects, so back-to-back fingerprint calls on two
# different projects (regardless of git vs no-git) see independent sets.
_compute_workspace_fingerprint_inner() {
  local project_dir="${1:-.}"

  # P0-M1: clear stale per-call state so two back-to-back calls on DIFFERENT
  # projects cannot leak ERE/scope across the boundary. BUILTIN_EXCLUDES is a
  # module-level constant; only FINGERPRINT_EXCLUDES / VERIFICATION_SCOPE /
  # _FP_EXCLUDE_ERE are per-call.
  FINGERPRINT_EXCLUDES=()
  VERIFICATION_SCOPE=""
  _FP_EXCLUDE_ERE=""

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
    # Reuse the SAME combined ERE for _is_excluded (builtin =~, zero forks).
    _FP_EXCLUDE_ERE="$exclude_awk_pat"

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

  # P0-M1: rebuild the combined ERE from the FRESHLY-LOADED FINGERPRINT_EXCLUDES
  # (and the constant BUILTIN_EXCLUDES) so the no-git path cannot accidentally
  # inherit a stale regex from a previous compute in the same shell — and so
  # two consecutive no-git computes on different projects observe independent
  # exclude sets.
  _FP_EXCLUDE_ERE="$(_build_exclude_awk_pat)"

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
