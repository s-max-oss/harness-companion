#!/bin/bash
# project-detect.sh — Detect project type from project files (Phase 2)
#
# Design: detection order is significant — more specific markers win.
#   mixed → electron → node → python → rust → go → shell → docs → unknown
#
# Usage:
#   source project-detect.sh
#   detect_project_type [project_dir]
#
# Output: node | python | rust | go | shell | electron | mixed | docs | unknown

# ---- detection rules --------------------------------------------------------
# Each rule returns 0 if the project matches the type. First match wins.

_has_file() {
  local dir="$1" name="$2"
  [ -f "$dir/$name" ]
}

detect_node() {
  local d="$1"
  _has_file "$d" "package.json"
}

detect_python() {
  local d="$1"
  _has_file "$d" "pyproject.toml" || \
  _has_file "$d" "setup.py" || \
  _has_file "$d" "requirements.txt" || \
  _has_file "$d" "Pipfile"
}

detect_rust() {
  local d="$1"
  _has_file "$d" "Cargo.toml"
}

detect_go() {
  local d="$1"
  _has_file "$d" "go.mod"
}

# shell project: no source markers; Makefile / *.mk / *.sh at root.
detect_shell() {
  local d="$1"
  if detect_node "$d" || detect_python "$d" || detect_rust "$d" || detect_go "$d"; then return 1; fi
  _has_file "$d" "Makefile" || compgen -G "$d/*.mk" >/dev/null 2>&1 || compgen -G "$d/*.sh" >/dev/null 2>&1
}

# electron project: package.json with electron/tauri/nw in dependencies.
detect_electron() {
  local d="$1"
  _has_file "$d" "package.json" && grep -qE '"(electron|tauri|nw)"' "$d/package.json" 2>/dev/null
}

# mixed project: ≥2 distinct source markers among node/python/rust/go.
detect_mixed() {
  local d="$1" c=0
  detect_node "$d" && c=$((c+1))
  detect_python "$d" && c=$((c+1))
  detect_rust "$d" && c=$((c+1))
  detect_go "$d" && c=$((c+1))
  [ "$c" -ge 2 ]
}

# docs project: no source-code markers AND has markdown documentation files.
# We require ≥1 .md file at root or under docs/ subdirectory.
detect_docs() {
  local d="$1"
  # Skip if any source marker is present
  if detect_node "$d" || detect_python "$d" || detect_rust "$d" || detect_go "$d"; then
    return 1
  fi
  # Has at least one markdown file at root
  if compgen -G "$d/*.md" >/dev/null 2>&1; then
    return 0
  fi
  # Or has a docs/ directory
  if [ -d "$d/docs" ]; then
    return 0
  fi
  return 1
}

# ---- main entry point -------------------------------------------------------
# Order matters: specific markers first; shell/docs are "no-source" fallbacks;
# unknown is the final fallback.
detect_project_type() {
  local dir="${1:-.}"
  detect_mixed "$dir" && { printf 'mixed'; return 0; }
  detect_electron "$dir" && { printf 'electron'; return 0; }
  if detect_node "$dir"; then
    printf 'node'
    return 0
  fi
  if detect_python "$dir"; then
    printf 'python'
    return 0
  fi
  if detect_rust "$dir"; then
    printf 'rust'
    return 0
  fi
  if detect_go "$dir"; then
    printf 'go'
    return 0
  fi
  detect_shell "$dir" && { printf 'shell'; return 0; }
  if detect_docs "$dir"; then
    printf 'docs'
    return 0
  fi
  printf 'unknown'
  return 0
}