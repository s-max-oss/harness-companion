#!/bin/bash
# evidence.sh — Canonical NDJSON run log writer (v2)
#
# Design §2: Canonical Evidence Data Model
# Five event types: run_started, command_completed, run_completed, run_failed, run_aborted
# Each run writes to .harness/logs/runs/<run_id>.ndjson — append-only, immutable.
#
# Usage:
#   source evidence.sh
#   generate_run_id                                  # → "20260731T151257Z-12345-32767"
#   ev_write_event <log_path> <event_json>           # append one JSON line + flush
#   ev_write_run_started <run_id> <event_json>       # writes run_started as first line
#   ev_write_command_completed <run_id> <event_json> # writes command_completed
#   ev_write_terminal <run_id> <event_json>          # writes terminal + fsync
#   ev_ensure_run_dir <project_dir> <run_id>         # ensures .harness/logs/runs/<run_id>/
#
# Requires jq. Fails closed (returns non-zero) if jq is absent.



# ---- helpers ---------------------------------------------------------------

ev_has_jq() {
  command -v jq >/dev/null 2>&1
}

# Compute git commit SHA, or "null" if not a git repo.
ev_git_commit() {
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git rev-parse --short=12 HEAD 2>/dev/null || printf 'null'
  else
    printf 'null'
  fi
}

# Compute SHA-256 of a file. Returns "null" if file is missing or sha256sum unavailable.
ev_file_sha256() {
  local f="$1"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    printf 'null'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  printf 'null'
}

# Compute SHA-256 of a string.
ev_string_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf 'null'
  fi
}

# ---- generate_run_id -------------------------------------------------------
# Produces a unique run identifier: timestamp-PID-RANDOM
# Example: "20260731T151257Z-12345-32767"
generate_run_id() {
  local ts pid rand
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
  pid="$$"
  rand="${RANDOM:-0}"
  printf '%s-%s-%s' "$ts" "$pid" "$rand"
}

# ---- run directory ---------------------------------------------------------
# Ensures .harness/logs/runs/<run_id>/ exists for per-command log artifacts.
ev_ensure_run_dir() {
  local project_dir="$1"
  local run_id="$2"
  local d="$project_dir/.harness/logs/runs/$run_id"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}

# ---- low-level write -------------------------------------------------------
# Append a single JSON line to the run log NDJSON file. Creates the file if needed.
# Returns 0 on success, non-zero on jq failure.
ev_write_event() {
  local log_path="$1"
  local event_json="$2"

  if ! ev_has_jq; then
    echo "evidence: jq required for event writing" >&2
    return 2
  fi

  # Validate the event is valid JSON
  if ! printf '%s' "$event_json" | jq . >/dev/null 2>&1; then
    echo "evidence: refusing to write invalid JSON event" >&2
    return 3
  fi

  # Ensure parent directory exists
  local log_dir
  log_dir="$(dirname "$log_path")"
  mkdir -p "$log_dir" 2>/dev/null || true

  # Append one compact NDJSON line (jq -c ensures single-line, no embedded newlines)
  printf '%s' "$event_json" | jq -c . >> "$log_path" || {
    echo "evidence: jq -c . failed while writing event" >&2
    return 4
  }
}

# ---- typed event writers ---------------------------------------------------

# Write run_started as the first line of the log.
ev_write_run_started() {
  local run_id="$1"
  local event_json="$2"
  local log_path=".harness/logs/runs/${run_id}.ndjson"

  # Verify it's a run_started event
  local ev_type
  ev_type="$(printf '%s' "$event_json" | jq -r '.event // empty')"
  if [ "$ev_type" != "run_started" ]; then
    echo "evidence: ev_write_run_started requires event=run_started, got '$ev_type'" >&2
    return 3
  fi

  ev_write_event "$log_path" "$event_json"
}

# Write command_completed event.
ev_write_command_completed() {
  local run_id="$1"
  local event_json="$2"
  local log_path=".harness/logs/runs/${run_id}.ndjson"

  local ev_type
  ev_type="$(printf '%s' "$event_json" | jq -r '.event // empty')"
  if [ "$ev_type" != "command_completed" ]; then
    echo "evidence: ev_write_command_completed requires event=command_completed, got '$ev_type'" >&2
    return 3
  fi

  ev_write_event "$log_path" "$event_json"
}

# Write terminal event (run_completed, run_failed, or run_aborted).
# MUST be the last event written for this run.
ev_write_terminal() {
  local run_id="$1"
  local event_json="$2"
  local log_path=".harness/logs/runs/${run_id}.ndjson"

  local ev_type
  ev_type="$(printf '%s' "$event_json" | jq -r '.event // empty')"
  case "$ev_type" in
    run_completed|run_failed|run_aborted) ;;
    *)
      echo "evidence: ev_write_terminal requires a terminal event, got '$ev_type'" >&2
      return 3
      ;;
  esac

  ev_write_event "$log_path" "$event_json"
}

# ---- utility: read run log -------------------------------------------------
ev_read_run_log() {
  local run_id="$1"
  local project_dir="${2:-.}"
  local log_path="$project_dir/.harness/logs/runs/${run_id}.ndjson"
  if [ ! -f "$log_path" ]; then
    return 1
  fi
  cat "$log_path"
}
