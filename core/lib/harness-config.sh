#!/bin/bash
# harness-config.sh — .harness/config.json loader with capability computation (v2)
#
# Usage:
#   source harness-config.sh
#   hc_compute_capability_level [project_dir]    # → 0|1|2
#   hc_config_sha256 [project_dir]               # → "sha256:<hex>" or "null"
#   hc_get_verification_scope [project_dir]      # → path or empty
#
# Design Errata E1: capability_level is COMPUTED by core, not a user field.



# ---- capability_level computation ------------------------------------------
# L0: knowledge_entry file exists (CLAUDE.md, AGENTS.md, CODEBUDDY.md, etc.)
# L1: L0 + .harness/config.json exists with verification plan (0+ commands)
# L2: L1 + feature_list.json exists with registry schema (has revision field)
hc_compute_capability_level() {
  local project_dir="${1:-.}"
  local level=0

  # Check L0: knowledge entry
  local has_knowledge=0
  for f in CLAUDE.md AGENTS.md CODEBUDDY.md GEMINI.md .cursorrules .windsurfrules; do
    if [ -f "$project_dir/$f" ]; then
      has_knowledge=1
      break
    fi
  done
  if [ "$has_knowledge" -eq 0 ]; then
    printf '0'
    return 0
  fi
  level=0

  # Check L1: config.json with verification plan
  local cfg="$project_dir/.harness/config.json"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    local has_commands
    has_commands="$(jq -r '.verification.commands // empty' "$cfg" 2>/dev/null || true)"
    if [ -n "$has_commands" ]; then
      level=1
    fi
  fi

  # Check L2: feature_list.json with registry schema (revision field)
  local fl="$project_dir/feature_list.json"
  if [ -f "$fl" ] && command -v jq >/dev/null 2>&1; then
    local has_revision
    has_revision="$(jq -r '.revision // empty' "$fl" 2>/dev/null || true)"
    if [ -n "$has_revision" ] && [ "$level" -ge 1 ]; then
      level=2
    fi
  fi

  printf '%d' "$level"
}

# ---- config SHA-256 --------------------------------------------------------
hc_config_sha256() {
  local project_dir="${1:-.}"
  local cfg="$project_dir/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    printf 'null'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256:%s' "$(sha256sum "$cfg" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    printf 'sha256:%s' "$(shasum -a 256 "$cfg" | awk '{print $1}')"
  else
    printf 'null'
  fi
}

# ---- verification scope ----------------------------------------------------
hc_get_verification_scope() {
  local project_dir="${1:-.}"
  local cfg="$project_dir/.harness/config.json"
  if [ ! -f "$cfg" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  jq -r '.verification_scope // empty' "$cfg" 2>/dev/null || true
}

# ---- WIP limit -------------------------------------------------------------
# Design §10: max number of features concurrently in `in_progress`.
# Default: 1 (single-focus). Override via .harness/config.json "wip_limit": <int>.
hc_wip_limit() {
  local project_dir="${1:-.}"
  local cfg="$project_dir/.harness/config.json"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    local v
    v="$(jq -r '.wip_limit // empty' "$cfg" 2>/dev/null || true)"
    if [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null; then
      printf '%d' "$v"
      return 0
    fi
  fi
  printf '1'
}
