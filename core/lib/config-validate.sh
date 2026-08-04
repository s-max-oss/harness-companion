#!/bin/bash
# config-validate.sh — Schema validator for .harness/config.json (Phase 2)
#
# Implementation note: we implement schema validation in bash (not by calling
# an external validator like ajv/check-jsonschema). Rationale:
#   1. Schema is small (≈20 lines of meaningful constraints)
#   2. No new external dependency at runtime
#   3. Failure modes are simple enough to encode directly
#   4. Tests can introspect failures via stderr messages
#
# Usage:
#   source config-validate.sh
#   validate_config_schema <config.json> [<schema.json>]
#
# Exit 0 on valid; non-zero with descriptive error on stderr otherwise.
#
# Design contract:
#   - capability_level MUST NOT appear as a user field (design Errata E1)
#   - project_type MUST be one of node|python|rust|go|docs|generic
#   - verification.commands MAY be empty (0-step docs project)
#   - Each command has: id (^[a-z][a-z0-9_-]*$), command (non-empty array),
#     required_for_passing (bool)

# Project type whitelist
VALID_PROJECT_TYPES=("node" "python" "rust" "go" "docs" "generic")

# ---- helpers ---------------------------------------------------------------

_is_valid_project_type() {
  local pt="$1"
  local valid
  for valid in "${VALID_PROJECT_TYPES[@]}"; do
    [ "$pt" = "$valid" ] && return 0
  done
  return 1
}

# id pattern: ^[a-z][a-z0-9_-]*$
_is_valid_id() {
  local id="$1"
  printf '%s' "$id" | grep -qE '^[a-z][a-z0-9_-]*$' 2>/dev/null
}

# ---- main validator --------------------------------------------------------
# Args: config_path [schema_path]
# schema_path is accepted for API compatibility but currently unused (we
# implement the rules directly to avoid external dependency).
validate_config_schema() {
  local config="$1"
  local schema="${2:-}"

  if [ -z "$config" ] || [ ! -f "$config" ]; then
    echo "validate_config_schema: config file not found: '$config'" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "validate_config_schema: jq is required" >&2
    return 1
  fi

  # Top-level parse
  if ! jq . "$config" >/dev/null 2>&1; then
    echo "validate_config_schema: '$config' is not valid JSON" >&2
    return 1
  fi

  # Reject capability_level as user field (design Errata E1)
  if jq -e 'has("capability_level")' "$config" >/dev/null 2>&1; then
    echo "validate_config_schema: capability_level is computed by core (design Errata E1); it must NOT appear in user config" >&2
    return 1
  fi

  # project_type required + must be whitelisted
  local pt
  pt="$(jq -r '.project_type // empty' "$config" 2>/dev/null)"
  if [ -z "$pt" ]; then
    echo "validate_config_schema: missing required field 'project_type'" >&2
    return 1
  fi
  if ! _is_valid_project_type "$pt"; then
    echo "validate_config_schema: invalid project_type '$pt' (must be one of: ${VALID_PROJECT_TYPES[*]})" >&2
    return 1
  fi

  # verification required
  if ! jq -e 'has("verification")' "$config" >/dev/null 2>&1; then
    echo "validate_config_schema: missing required field 'verification'" >&2
    return 1
  fi
  if ! jq -e '.verification | type == "object"' "$config" >/dev/null 2>&1; then
    echo "validate_config_schema: 'verification' must be an object" >&2
    return 1
  fi
  if ! jq -e '.verification | has("commands")' "$config" >/dev/null 2>&1; then
    echo "validate_config_schema: missing required field 'verification.commands'" >&2
    return 1
  fi
  if ! jq -e '.verification.commands | type == "array"' "$config" >/dev/null 2>&1; then
    echo "validate_config_schema: 'verification.commands' must be an array" >&2
    return 1
  fi

  # fingerprint_exclude, if present, must be array of strings
  if jq -e 'has("fingerprint_exclude")' "$config" >/dev/null 2>&1; then
    if ! jq -e '.fingerprint_exclude | type == "array"' "$config" >/dev/null 2>&1; then
      echo "validate_config_schema: 'fingerprint_exclude' must be an array" >&2
      return 1
    fi
    local bad_item
    bad_item="$(jq -r '.fingerprint_exclude[]? | select(type != "string") | "non-string"' "$config" 2>/dev/null | head -1)"
    if [ -n "$bad_item" ]; then
      echo "validate_config_schema: 'fingerprint_exclude' must contain only strings" >&2
      return 1
    fi
  fi

  # verification_scope, if present, must be a string
  if jq -e 'has("verification_scope")' "$config" >/dev/null 2>&1; then
    if ! jq -e '.verification_scope | type == "string"' "$config" >/dev/null 2>&1; then
      echo "validate_config_schema: 'verification_scope' must be a string" >&2
      return 1
    fi
  fi

  # Per-command validation (if any commands present)
  local cmd_count
  cmd_count="$(jq '.verification.commands | length' "$config" 2>/dev/null)"
  local i
  for i in $(seq 0 $((cmd_count - 1))); do
    local cmd_id cmd_origin
    cmd_id="$(jq -r ".verification.commands[$i].id // empty" "$config" 2>/dev/null)"
    if [ -z "$cmd_id" ]; then
      echo "validate_config_schema: command[$i] missing required 'id'" >&2
      return 1
    fi
    if ! _is_valid_id "$cmd_id"; then
      echo "validate_config_schema: command[$i].id '$cmd_id' must match ^[a-z][a-z0-9_-]*$" >&2
      return 1
    fi
    if ! jq -e ".verification.commands[$i].command | type == \"array\" and length > 0" "$config" >/dev/null 2>&1; then
      echo "validate_config_schema: command[$i] ('$cmd_id') missing or empty 'command' array" >&2
      return 1
    fi
    if ! jq -e ".verification.commands[$i].command | all(.[]; type == \"string\")" "$config" >/dev/null 2>&1; then
      echo "validate_config_schema: command[$i] ('$cmd_id') 'command' must be array of strings" >&2
      return 1
    fi
    if ! jq -e ".verification.commands[$i].required_for_passing | type == \"boolean\"" "$config" >/dev/null 2>&1; then
      echo "validate_config_schema: command[$i] ('$cmd_id') missing 'required_for_passing' (boolean)" >&2
      return 1
    fi
    # Optional: command_origin enum
    cmd_origin="$(jq -r ".verification.commands[$i].command_origin // empty" "$config" 2>/dev/null)"
    if [ -n "$cmd_origin" ]; then
      if [ "$cmd_origin" != "configured" ] && [ "$cmd_origin" != "detected" ]; then
        echo "validate_config_schema: command[$i] ('$cmd_id') invalid command_origin '$cmd_origin'" >&2
        return 1
      fi
    fi
    # Optional: confirmation enum
    local confirmation
    confirmation="$(jq -r ".verification.commands[$i].confirmation // empty" "$config" 2>/dev/null)"
    if [ -n "$confirmation" ]; then
      case "$confirmation" in
        not_required|pending|confirmed|rejected) : ;;
        *)
          echo "validate_config_schema: command[$i] ('$cmd_id') invalid confirmation '$confirmation'" >&2
          return 1
          ;;
      esac
    fi
    # Phase 2 R4.3: configured+pending and configured+rejected are INVALID combinations
    # (configured commands don't go through a user review state; only detected commands
    # use pending/confirmed/rejected to gate review). Reject at schema time.
    if [ -z "$cmd_origin" ]; then
      cmd_origin="configured"
    fi
    if [ -z "$confirmation" ]; then
      confirmation="not_required"
    fi
    if [ "$cmd_origin" = "configured" ]; then
      if [ "$confirmation" = "pending" ] || [ "$confirmation" = "rejected" ]; then
        echo "validate_config_schema: command[$i] ('$cmd_id') configured+$confirmation is invalid (configured origin must be not_required or confirmed)" >&2
        return 1
      fi
    fi
    # Optional: timeout_seconds must be positive integer
    if jq -e ".verification.commands[$i] | has(\"timeout_seconds\")" "$config" >/dev/null 2>&1; then
      if ! jq -e ".verification.commands[$i].timeout_seconds | type == \"number\" and . > 0" "$config" >/dev/null 2>&1; then
        echo "validate_config_schema: command[$i] ('$cmd_id') timeout_seconds must be positive number" >&2
        return 1
      fi
    fi
  done

  # Check duplicate command ids within the array
  local dups
  dups="$(jq -r '[.verification.commands[].id] | group_by(.) | map(select(length>1)) | .[][0]' "$config" 2>/dev/null)"
  if [ -n "$dups" ]; then
    echo "validate_config_schema: duplicate command ids: $dups" >&2
    return 1
  fi

  return 0
}