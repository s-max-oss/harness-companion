#!/bin/bash
# baseline.sh — Persist and read per-cwd commit baselines for hook coordination.
#
# Ported from v1.1.2 scripts/_lib/baseline.sh — no semantic changes.
#
# The session-start hook writes the current HEAD SHA + UTC timestamp to
# ~/.claude/harness-companion/baselines/<cwd-hash>. The stop hook reads it and
# uses the saved SHA as the "trusted baseline" for stale-evidence judgement.
#
# All operations are fail-open. A missing baseline is treated as "no baseline
# available" — the stop hook then falls back to current HEAD.

set -u

HC_BASELINE_DIR="${HOME}/.claude/harness-companion/baselines"
mkdir -p "$HC_BASELINE_DIR" 2>/dev/null || HC_BASELINE_DIR="/tmp"

_baseline_key() {
  local cwd="$1"
  # Path normalization for cross-platform key stability.
  # Git Bash on Windows maps "D:/foo" to "/d/foo" after `cd`, so the same
  # physical path produces two different keys. Normalize to a canonical form:
  #   - backslashes → forward slashes
  #   - lowercase the leading drive letter (D:/, /d/, etc.)
  #   - strip the drive letter prefix entirely
  # Result: "D:/foo/bar" and "/d/foo/bar" both produce "foo/bar".
  cwd="${cwd//\\/}"      # backslashes → forward slashes
  cwd="${cwd,,}"          # lowercase the leading drive letter
  cwd="${cwd#d:/}"; cwd="${cwd#c:/}"; cwd="${cwd#/d}"; cwd="${cwd#/c}"
  cwd="${cwd#/}"          # strip any remaining leading slash
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$cwd" | sha256sum | awk '{print $1}' | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$cwd" | shasum -a 256 | awk '{print $1}' | cut -c1-16
  else
    local h=5381 c
    while IFS= read -r -n1 c; do
      h=$(( (h * 33 + $(printf '%d' "'$c") )))
    done <<<"$cwd"
    printf '%x' "$h"
  fi
}

hc_baseline_write() {
  local cwd="$1"
  local sha="$2"
  local ts="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)}"
  [ -z "$cwd" ] && return 1
  [ -z "$sha" ] && return 1
  local key
  key="$(_baseline_key "$cwd")"
  local f="$HC_BASELINE_DIR/$key.json"
  local escaped_cwd escaped_sha escaped_ts
  escaped_cwd="${cwd//\\/\\\\}"
  escaped_cwd="${escaped_cwd//\"/\\\"}"
  escaped_sha="${sha//\\/\\\\}"
  escaped_sha="${escaped_sha//\"/\\\"}"
  escaped_ts="${ts//\\/\\\\}"
  escaped_ts="${escaped_ts//\"/\\\"}"
  printf '{"cwd":"%s","commit":"%s","started_at":"%s"}\n' \
    "$escaped_cwd" "$escaped_sha" "$escaped_ts" > "$f" 2>/dev/null || true
}

hc_baseline_read_commit() {
  local cwd="$1"
  [ -z "$cwd" ] && { printf ''; return 0; }
  local key
  key="$(_baseline_key "$cwd")"
  local f="$HC_BASELINE_DIR/$key.json"
  if [ ! -f "$f" ]; then
    printf ''
    return 0
  fi
  sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1
}

hc_baseline_clear() {
  local cwd="$1"
  [ -z "$cwd" ] && return 0
  local key
  key="$(_baseline_key "$cwd")"
  rm -f "$HC_BASELINE_DIR/$key.json" 2>/dev/null || true
}
