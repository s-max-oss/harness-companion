#!/bin/bash
# tests/release/e2_aggregate.sh — Shared E2 aggregation logic.
#
# Single source of truth for the repo-level E2 verdict. Both the production
# gate (test-release-archive.sh, Phase E2) and the behavior tests
# (test-e2-tag-trigger.sh, cases A1a–A4) source this file — there is
# deliberately only ONE implementation of the aggregation rules.
#
# Contract:
#   - Iterate EVERY workflow file in the given directory (.yml + .yaml).
#     No early `break` on first PASS — every file is checked so a later
#     file's parse error or dep-missing is still observed.
#   - Per-file outcome is one of:
#       0  (FOUND)       release tag trigger detected
#       10 (NOT_FOUND)   valid YAML, no release trigger
#       11 (PARSE_ERR)   YAML parse error
#       2  (DEP_MISSING) PyYAML missing
#   - Aggregation rule (priority order, highest wins):
#       DEP_MISSING seen in any file → FAIL with that message
#       PARSE_ERR seen in any file   → FAIL with that message
#       FOUND seen in any file       → PASS
#       otherwise (only NOT_FOUND)   → FAIL with that message
#
# Public function:
#   e2_aggregate <workflows_dir> <e2_check_py_path>
#
#     <workflows_dir>     directory containing *.yml/*.yaml files to check
#     <e2_check_py_path>  absolute path to e2_check.py (caller resolves;
#                         archive mode uses the in-archive copy, behavior
#                         tests use the in-tree source-repo copy)
#
#   Echoes the verdict on stdout:
#     Line 1: "PASS" or "FAIL"
#     Line 2+: human-readable reason (only when FAIL)
#
#   Always exits 0 so the caller's $? is not affected. Callers should
#   read line 1 of stdout.

# Internal: invoke e2_check.py on a single workflow file.
# Sets E2_OUT (stdout+stderr of python3) and E2_RC.
_e2_check_one() {
  local wf="$1"
  local e2_py="$2"
  E2_OUT="$(python3 "$e2_py" "$wf" 2>&1)"
  E2_RC=$?
}

# Internal: aggregate a set of (rc, out, file) tuples into a verdict.
# Reads from the four lists via globals (set by e2_aggregate).
_e2_compute_verdict() {
  local files_checked="$1"
  if [ -n "$_E2_DEP_MISSING_LIST" ]; then
    echo "FAIL"
    echo "DEP_MISSING (checked $files_checked file(s)):"
    printf '%s' "$_E2_DEP_MISSING_LIST"
  elif [ -n "$_E2_PARSE_ERR_LIST" ]; then
    echo "FAIL"
    echo "PARSE_ERR (checked $files_checked file(s)):"
    printf '%s' "$_E2_PARSE_ERR_LIST"
  elif [ "$_E2_FOUND_COUNT" -gt 0 ]; then
    echo "PASS"
    echo "FOUND (checked $files_checked file(s), FOUND=$_E2_FOUND_COUNT)"
  else
    echo "FAIL"
    echo "NOT_FOUND (checked $files_checked file(s)):"
    printf '%s' "$_E2_NOT_FOUND_LIST"
  fi
}

e2_aggregate() {
  local wfdir="$1"
  # Second arg is the path to e2_check.py. If not provided, fall back to
  # the E2_CHECK_PY environment variable so callers that already set it
  # (test-e2-tag-trigger.sh) don't have to pass it again.
  local e2_py="${2:-${E2_CHECK_PY:-}}"
  if [ -z "$e2_py" ]; then
    echo "FAIL"
    echo "NO_E2_CHECK_PY: e2_aggregate requires either arg 2 or E2_CHECK_PY env var"
    return 0
  fi
  if [ ! -f "$e2_py" ]; then
    echo "FAIL"
    echo "E2_CHECK_PY_MISSING: $e2_py does not exist"
    return 0
  fi
  _E2_FOUND_COUNT=0
  _E2_NOT_FOUND_LIST=""
  _E2_PARSE_ERR_LIST=""
  _E2_DEP_MISSING_LIST=""
  local files_checked=0

  if [ ! -d "$wfdir" ]; then
    echo "FAIL"
    echo "NO_WORKFLOWS_DIR: $wfdir does not exist"
    return 0
  fi

  local wf rc out
  for wf in "$wfdir"/*.yml "$wfdir"/*.yaml; do
    [ -f "$wf" ] || continue
    files_checked=$((files_checked + 1))
    _e2_check_one "$wf" "$e2_py"
    case "$E2_RC" in
      0)
        _E2_FOUND_COUNT=$((_E2_FOUND_COUNT + 1))
        ;;
      10)
        _E2_NOT_FOUND_LIST="${_E2_NOT_FOUND_LIST}${wf}: ${E2_OUT}
"
        ;;
      11)
        _E2_PARSE_ERR_LIST="${_E2_PARSE_ERR_LIST}${wf}: ${E2_OUT}
"
        ;;
      2)
        _E2_DEP_MISSING_LIST="${_E2_DEP_MISSING_LIST}${wf}: ${E2_OUT}
"
        ;;
      *)
        _E2_PARSE_ERR_LIST="${_E2_PARSE_ERR_LIST}${wf}: unexpected rc=$E2_RC — ${E2_OUT}
"
        ;;
    esac
  done

  if [ "$files_checked" -eq 0 ]; then
    echo "FAIL"
    echo "NO_WORKFLOW_FILES: $wfdir contains no .yml/.yaml files"
    return 0
  fi

  _e2_compute_verdict "$files_checked"
  return 0
}
