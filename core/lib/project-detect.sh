#!/bin/bash
# project-detect.sh — Detect project type from project files (Phase 2)
#
# Design: detection order is significant — more specific markers win.
#   1. node    — package.json
#   2. python  — pyproject.toml OR setup.py OR requirements.txt
#   3. rust    — Cargo.toml
#   4. go      — go.mod
#   5. docs    — no source markers AND docs present (e.g. .md files at root)
#   6. generic — fallback
#
# Usage:
#   source project-detect.sh
#   detect_project_type [project_dir]
#
# Output: one of "node" | "python" | "rust" | "go" | "docs" | "generic"

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
# Order matters: specific markers first; docs is a "no-source" fallback; generic is the
# final fallback.
detect_project_type() {
  local dir="${1:-.}"
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
  if detect_docs "$dir"; then
    printf 'docs'
    return 0
  fi
  printf 'generic'
  return 0
}