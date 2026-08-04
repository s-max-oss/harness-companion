#!/bin/bash
# atomic_write.sh — Write file atomically via mktemp + mv
#
# v2: Ported from v1.1.2 scripts/_lib/atomic_write.sh — no semantic changes.
#
# Usage:
#   source atomic_write.sh
#   atomic_write <path> <content>
#   atomic_write_json <path> <json_content>     # validates JSON first if jq exists
#
# Returns 0 on success, non-zero on failure. On failure, no partial file is left behind.
#
# Why: never overwrite a user's JSON file with a half-written buffer. mktemp creates
# the temp file in the same directory as the target (same filesystem) so the final
# mv is atomic on POSIX.



# Internal: write content to path atomically. Caller must have already validated input.
_atomic_write_impl() {
  local dest="$1"
  local content="$2"

  local dest_dir
  dest_dir="$(dirname "$dest")"
  if [ ! -d "$dest_dir" ]; then
    echo "atomic_write: target directory does not exist: $dest_dir" >&2
    return 1
  fi

  # Use a temp file in the same directory to guarantee same-filesystem atomic mv.
  local tmp
  tmp="$(mktemp "${dest_dir}/.harness-companion.tmp.XXXXXX")"
  if [ -z "$tmp" ]; then
    echo "atomic_write: mktemp failed" >&2
    return 1
  fi

  # Write content, then atomic rename. Preserve permissions if the file existed.
  local mode
  if [ -f "$dest" ]; then
    mode="$(stat -c %a "$dest" 2>/dev/null || stat -f %Lp "$dest" 2>/dev/null || echo "")"
  fi

  # printf %s avoids trailing newline ambiguity; we want exact content.
  printf '%s' "$content" > "$tmp"
  if [ -n "${mode:-}" ]; then
    chmod "$mode" "$tmp" 2>/dev/null || true
  fi

  mv -f "$tmp" "$dest"
}

# Public: atomic_write <path> <content>
atomic_write() {
  if [ $# -lt 2 ]; then
    echo "atomic_write: usage: atomic_write <path> <content>" >&2
    return 2
  fi
  _atomic_write_impl "$1" "$2"
}

# Public: atomic_write_json <path> <json_content>
# Validates the JSON with jq if available, then writes atomically.
atomic_write_json() {
  if [ $# -lt 2 ]; then
    echo "atomic_write_json: usage: atomic_write_json <path> <json_content>" >&2
    return 2
  fi
  local dest="$1"
  local content="$2"

  if command -v jq >/dev/null 2>&1; then
    if ! printf '%s' "$content" | jq . >/dev/null 2>&1; then
      echo "atomic_write_json: refusing to write invalid JSON to $dest" >&2
      return 3
    fi
  fi

  _atomic_write_impl "$dest" "$content"
}
