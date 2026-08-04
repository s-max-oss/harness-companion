#!/bin/bash
# json-helpers.sh — JSON input parsing and config loading (v2)
#
# Ported from v1.1.2 json_input.sh + harness_config.sh. Merged into single lib.
#
# Usage:
#   source json-helpers.sh
#
#   # JSON input (hook stdin)
#   ji_init                        # read stdin once
#   ji_field <key>                 # scalar value or empty
#   ji_cwd                         # normalized cwd
#
#   # Harness config
#   hc_load [project_dir]          # load .harness/config.json
#   hc_command_ids                 # list command IDs
#   hc_command_for <id>            # JSON for one command
#   hc_applies <json-command>      # "true" or "false"
#   hc_required_ids                # IDs with required_for_passing: true
#   hc_wip_limit                   # integer (default 1)



# ============================================================================
# JSON Input (from v1.1.2 json_input.sh)
# ============================================================================

JI_INPUT=""
JI_LAST=""
JI_HAVE_INPUT=0

# Source the shared runtime selection if available.
# json-helpers.sh may be sourced before json-encode.sh in some callers.
# shellcheck source=./json-encode.sh
[ -z "${_HC_JSON_RUNTIME_LOADED:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/json-encode.sh" ] && \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/json-encode.sh" 2>/dev/null || true
_HC_JSON_RUNTIME_LOADED=1

ji_init() {
  if [ "$JI_HAVE_INPUT" -eq 1 ]; then
    return 0
  fi
  JI_INPUT="$(cat 2>/dev/null || true)"
  if [ -z "$JI_INPUT" ]; then
    JI_INPUT='{}'
  fi
  JI_HAVE_INPUT=1
}

# _ji_field_impl extracts a single field from JI_INPUT using the shared
# cross-platform JSON runtime (python3 / python / py -3 / jq). Substring
# scanning is intentionally NOT used because it cannot handle escaped
# backslashes, escaped quotes, or unicode in JSON string values.
_ji_field_impl() {
  local key="$1"
  local val=""
  local runtime=""

  if type hc_json_runtime >/dev/null 2>&1; then
    runtime="$(hc_json_runtime)"
  fi

  case "$runtime" in
    python3|python)
      val="$(JI_INPUT="$JI_INPUT" KEY="$key" "$runtime" -c '
import json, os, sys
try:
    data = json.loads(os.environ["JI_INPUT"])
except Exception:
    sys.exit(0)
v = data.get(os.environ["KEY"], None)
if isinstance(v, (str, int, float, bool)):
    print(v)
' 2>/dev/null || true)"
      JI_LAST="$val"
      return 0
      ;;
    py)
      val="$(JI_INPUT="$JI_INPUT" KEY="$key" py -3 -c '
import json, os, sys
try:
    data = json.loads(os.environ["JI_INPUT"])
except Exception:
    sys.exit(0)
v = data.get(os.environ["KEY"], None)
if isinstance(v, (str, int, float, bool)):
    print(v)
' 2>/dev/null || true)"
      JI_LAST="$val"
      return 0
      ;;
    jq)
      val="$(printf '%s' "$JI_INPUT" | jq -r --arg k "$key" 'if (.[$k] // null) | type == "string" then .[$k] else empty end' 2>/dev/null || true)"
      JI_LAST="$val"
      return 0
      ;;
    powershell)
      # PowerShell: write stdin to file (avoids console encoding issues),
      # then have PS parse and extract the field. ConvertFrom-Json handles
      # escaped backslashes and quotes correctly -- no substring scan.
      local tmpfile="${TMPDIR:-/tmp}/hc_json_in.$$"
      printf '%s' "$JI_INPUT" > "$tmpfile"
      val="$(powershell -NoProfile -NonInteractive -Command \
        "Get-Content -LiteralPath '$tmpfile' -Raw | ConvertFrom-Json | ForEach-Object { \$_.$key }" \
        2>/dev/null || true)"
      rm -f "$tmpfile"
      JI_LAST="$val"
      return 0
      ;;
  esac

  # No runtime available -- emit diagnostic and return empty.
  # We deliberately do NOT fall back to substring scanning because it
  # silently mis-parses JSON containing escaped backslashes or quotes.
  printf 'json-helpers: no JSON runtime available (looked for python3/python/py/jq)\n' >&2
  JI_LAST=""
  return 0
}

ji_field() {
  if [ $# -lt 1 ]; then
    echo "ji_field requires a key argument" >&2
    return 0
  fi
  if [ "$JI_HAVE_INPUT" -eq 0 ]; then
    ji_init
  fi
  _ji_field_impl "$1"
  printf '%s' "$JI_LAST"
}

ji_cwd() {
  if [ "$JI_HAVE_INPUT" -eq 0 ]; then
    ji_init
  fi
  _ji_field_impl "cwd"
  local raw="$JI_LAST"
  if [ -z "$raw" ]; then
    return 0
  fi
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$raw" 2>/dev/null || printf '%s' "$raw"
    return 0
  fi
  printf '%s' "$raw" | sed 's/\\/\//g'
}

# ============================================================================
# Harness Config (from v1.1.2 harness_config.sh)
# ============================================================================

HC_LOADED=0
HC_CONFIG_DIR=""
HC_TYPE=""

_hc_jq_string() {
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" 'if (.[$k] | type) == "string" then .[$k] else empty end' "$file" 2>/dev/null
    return 0
  fi
  local pat="\"$key\":\""
  local rest
  rest="$(grep -o "\"$key\":\"[^\"]*\"" "$file" 2>/dev/null | head -1 || true)"
  if [ -z "$rest" ]; then
    return 0
  fi
  printf '%s' "$rest" | sed "s/\"$key\":\"//; s/\"$//"
}

_hc_jq_int() {
  local file="$1" key="$2" fallback="$3"
  if command -v jq >/dev/null 2>&1; then
    local v
    v="$(jq -r --arg k "$key" 'if (.[$k] | type) == "number" then (.[$k] | tostring) else empty end' "$file" 2>/dev/null || true)"
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  fi
  printf '%s' "$fallback"
}

hc_load() {
  local dir="${1:-.}"
  if [ ! -d "$dir" ]; then
    return 1
  fi
  HC_CONFIG_DIR="$(cd "$dir" 2>/dev/null && pwd)"

  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    HC_LOADED=0
    HC_TYPE="generic"
    return 1
  fi

  HC_TYPE="$(_hc_jq_string "$cfg" project_type)"
  if [ -z "$HC_TYPE" ]; then
    HC_TYPE="generic"
  fi
  HC_LOADED=1
  return 0
}

hc_command_ids() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r '.verification.commands[]?.id // empty' "$cfg" 2>/dev/null | tr -d '\r'
  fi
}

hc_command_for() {
  local id="$1"
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -c --arg id "$id" '.verification.commands[] | select(.id == $id)' "$cfg" 2>/dev/null
  fi
}

hc_applies() {
  local cmd_json="$1"
  if [ -z "$cmd_json" ]; then
    printf 'false'
    return 0
  fi

  # Canonical predicate name (Phase 2 R4): applies_when.has_files[]
  # A command applies iff (a) it has no applies_when predicate, OR
  # (b) at least one path in has_files exists in the project root.
  # Returns "true" or "false" on stdout.
  #
  # Glob semantics (Phase 2 R5):
  #   Each entry is a shell glob pattern (relative to HC_CONFIG_DIR).
  #   Patterns may contain * ? [...] metacharacters.
  #   A pattern with no glob metacharacters behaves as an exact path match
  #   (e.g. "package.json" matches <root>/package.json, NOT a directory).
  #   The pattern is interpreted by bash (case/com pgen), so semantics are
  #   platform-consistent with the user's shell.
  if ! command -v jq >/dev/null 2>&1; then
    printf 'true'
    return 0
  fi

  local has_files
  has_files="$(printf '%s' "$cmd_json" | jq -r '.applies_when.has_files[]? // empty' 2>/dev/null || true)"

  if [ -z "$has_files" ]; then
    printf 'true'
    return 0
  fi

  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # Escape slashes for case-pattern use (slash is literal in bash globs,
    # so we only need to handle the pattern itself).
    if _hc_glob_match "$f" "$HC_CONFIG_DIR"; then
      printf 'true'
      return 0
    fi
  done <<<"$has_files"
  printf 'false'
  return 0
}

# _hc_glob_match <pattern> <root>
# Returns 0 if any entry under <root> matches <pattern> as a shell glob.
# Patterns without glob metacharacters (* ? [) behave as exact relative-path
# checks via [ -e ].
_hc_glob_match() {
  local pattern="$1"
  local root="$2"
  case "$pattern" in
    *'*'*|*'?'*|*'['*)
      # Real glob: expand via compgen -G in the root directory.
      # compgen prints each match on its own line; empty output means no match.
      local matches
      matches="$(cd "$root" 2>/dev/null && compgen -G "$pattern" 2>/dev/null)"
      [ -n "$matches" ]
      ;;
    *)
      # No glob metachars → exact path check (matches directories and files).
      [ -e "$root/$pattern" ]
      ;;
  esac
}

hc_required_ids() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  jq -r '.verification.commands[] | select(.required_for_passing == true) | .id' "$cfg" 2>/dev/null
}

hc_wip_limit() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    printf '1'
    return 0
  fi
  _hc_jq_int "$cfg" wip_limit 1
}
