#!/bin/bash
# validate-run-log.sh — 16-step canonical run log validation (v2)
#
# Design §3: Canonical Run Log Validation
# Validates a .harness/logs/runs/<run_id>.ndjson file against the canonical
# evidence schema. Used by passing eligibility and migration.
#
# Usage:
#   source validate-run-log.sh
#   validate_run_log <run_id> [project_dir]
#
# Returns:
#   0 + JSON result on stdout: {"valid":true, "run_started":{...}, "terminal":{...}, ...}
#   1 + JSON result on stdout: {"valid":false, "reason":"...", ...}
#   Non-zero exit = validation failure (caller checks .valid)
#
# Requires: bash 4+, jq

# Known event types from design §3.0
KNOWN_EVENTS='["run_started","command_completed","run_completed","run_failed","run_aborted"]'

# ---- validate_event_fields ------------------------------------------------
# Validates required fields, types, and enum values for a single event.
# Returns "" on success, or error string on failure.
_validate_event_fields() {
  local ev="$1"

  local ev_type
  ev_type="$(printf '%s' "$ev" | jq -r '.event // empty')"

  # --- Common fields (all events) ---
  # event: string, already validated
  # schema_version: integer >= 1
  local sv
  sv="$(printf '%s' "$ev" | jq -r '.schema_version // empty')"
  if [ -z "$sv" ]; then
    printf 'missing schema_version'
    return 0
  fi
  if ! printf '%s' "$ev" | jq -e '(.schema_version | type) == "number"' >/dev/null 2>&1; then
    printf 'schema_version must be integer'
    return 0
  fi

  # run_id: string, non-empty
  local rid
  rid="$(printf '%s' "$ev" | jq -r '.run_id // empty')"
  if [ -z "$rid" ]; then
    printf 'missing run_id'
    return 0
  fi

  # --- Per-event required fields ---
  case "$ev_type" in
    run_started)
      # started_at: string
      if ! printf '%s' "$ev" | jq -e '(.started_at | type) == "string"' >/dev/null 2>&1; then
        printf 'run_started: missing or invalid started_at'
        return 0
      fi
      # project_root: string
      if ! printf '%s' "$ev" | jq -e '(.project_root | type) == "string"' >/dev/null 2>&1; then
        printf 'run_started: missing or invalid project_root'
        return 0
      fi
      # workspace_fingerprint_initial: string
      if ! printf '%s' "$ev" | jq -e '(.workspace_fingerprint_initial | type) == "string"' >/dev/null 2>&1; then
        printf 'run_started: missing or invalid workspace_fingerprint_initial'
        return 0
      fi
      # config_sha256: string
      if ! printf '%s' "$ev" | jq -e '(.config_sha256 | type) == "string"' >/dev/null 2>&1; then
        printf 'run_started: missing or invalid config_sha256'
        return 0
      fi
      # required_command_ids: array of strings, no duplicates
      if ! printf '%s' "$ev" | jq -e '(.required_command_ids | type) == "array"' >/dev/null 2>&1; then
        printf 'run_started: missing or invalid required_command_ids'
        return 0
      fi
      # capability_level: integer 0|1|2
      local cl
      cl="$(printf '%s' "$ev" | jq -r '.capability_level // empty')"
      case "$cl" in
        0|1|2) ;;
        *) printf 'run_started: invalid capability_level (must be 0|1|2)'; return 0 ;;
      esac
      ;;

    command_completed)
      # command_id: string, non-empty
      local cid
      cid="$(printf '%s' "$ev" | jq -r '.command_id // empty')"
      if [ -z "$cid" ]; then
        printf 'command_completed: missing or empty command_id'
        return 0
      fi
      # command: array of strings, non-empty
      if ! printf '%s' "$ev" | jq -e '(.command | type) == "array" and (.command | length) > 0' >/dev/null 2>&1; then
        printf 'command_completed: missing or invalid command array'
        return 0
      fi
      # command_origin: enum
      local co
      co="$(printf '%s' "$ev" | jq -r '.command_origin // empty')"
      case "$co" in
        configured|detected) ;;
        *) printf 'command_completed: invalid command_origin (must be configured|detected)'; return 0 ;;
      esac
      # confirmation: enum
      local cf
      cf="$(printf '%s' "$ev" | jq -r '.confirmation // empty')"
      case "$cf" in
        not_required|pending|confirmed|rejected) ;;
        *) printf 'command_completed: invalid confirmation (must be not_required|pending|confirmed|rejected)'; return 0 ;;
      esac
      # exit_code: integer
      if ! printf '%s' "$ev" | jq -e '(.exit_code | type) == "number"' >/dev/null 2>&1; then
        printf 'command_completed: missing or invalid exit_code'
        return 0
      fi
      # started_at: string
      if ! printf '%s' "$ev" | jq -e '(.started_at | type) == "string"' >/dev/null 2>&1; then
        printf 'command_completed: missing or invalid started_at'
        return 0
      fi
      # duration_ms: integer >= 0
      if ! printf '%s' "$ev" | jq -e '(.duration_ms | type) == "number" and .duration_ms >= 0' >/dev/null 2>&1; then
        printf 'command_completed: missing or invalid duration_ms'
        return 0
      fi
      # log_artifact: required string (empty string permitted for missing-tool case
      # where the command was never executed — see harness-verify.sh line 326).
      # CRITICAL (Codex r5 defect 1): without this check, an attacker can hand-
      # craft an NDJSON with any command:["..."] and a fake exit_code — the
      # recorded log_artifact and log_sha256 are the ONLY way to bind the
      # recorded evidence to an actual file on disk. The empty-string allow is
      # scoped to the structurally-verifiable missing-tool path (no log_artifact
      # AND no log_sha256 AND exit_code=127 → tool-not-found sentinel). Any
      # other path with non-empty log_artifact triggers step 5b/5c/5d below.
      if ! printf '%s' "$ev" | jq -e 'has("log_artifact") and (.log_artifact | type) == "string"' >/dev/null 2>&1; then
        printf 'command_completed: missing or non-string log_artifact'
        return 0
      fi
      # log_sha256: required, type string OR null. A real recorded sha256 is a
      # 64-hex string; null is the canonical "no artifact, no hash" sentinel.
      if ! printf '%s' "$ev" | jq -e '
          has("log_sha256") and (
            (.log_sha256 == null) or
            (.log_sha256 | type == "string")
          )
        ' >/dev/null 2>&1; then
        printf 'command_completed: missing or invalid log_sha256 (must be null or string)'
        return 0
      fi
      ;;

    run_completed|run_failed|run_aborted)
      # completed_at: string
      if ! printf '%s' "$ev" | jq -e '(.completed_at | type) == "string"' >/dev/null 2>&1; then
        printf '%s: missing or invalid completed_at' "$ev_type"
        return 0
      fi
      # overall_result: enum per event type
      local ores
      ores="$(printf '%s' "$ev" | jq -r '.overall_result // empty')"
      case "$ev_type" in
        run_completed)
          case "$ores" in
            passed|no_checks) ;;
            *) printf 'run_completed: overall_result must be passed|no_checks'; return 0 ;;
          esac
          ;;
        run_failed)
          if [ "$ores" != "failed" ]; then
            printf 'run_failed: overall_result must be failed'
            return 0
          fi
          ;;
        run_aborted)
          if [ "$ores" != "aborted" ]; then
            printf 'run_aborted: overall_result must be aborted'
            return 0
          fi
          ;;
      esac
      # Count fields: all integers >= 0
      for f in planned_commands executed_commands passed_commands failed_commands skipped_commands; do
        if ! printf '%s' "$ev" | jq -e "(.$f | type) == \"number\" and .$f >= 0" >/dev/null 2>&1; then
          printf '%s: missing or invalid %s' "$ev_type" "$f"
          return 0
        fi
      done
      # not_applicable_command_ids (optional): if present, must be an array of
      # strings (E5 unification — ids of required commands with predicate=false).
      if printf '%s' "$ev" | jq -e 'has("not_applicable_command_ids")' >/dev/null 2>&1; then
        if ! printf '%s' "$ev" | jq -e '(.not_applicable_command_ids | type) == "array" and ([.not_applicable_command_ids[]? | type] | all(. == "string"))' >/dev/null 2>&1; then
          printf '%s: not_applicable_command_ids must be an array of strings' "$ev_type"
          return 0
        fi
      fi
      # run_failed requires failed_command_ids
      if [ "$ev_type" = "run_failed" ]; then
        if ! printf '%s' "$ev" | jq -e '(.failed_command_ids | type) == "array"' >/dev/null 2>&1; then
          printf 'run_failed: missing or invalid failed_command_ids'
          return 0
        fi
      fi
      # run_aborted requires abort_reason
      if [ "$ev_type" = "run_aborted" ]; then
        if ! printf '%s' "$ev" | jq -e '(.abort_reason | type) == "string"' >/dev/null 2>&1; then
          printf 'run_aborted: missing or invalid abort_reason'
          return 0
        fi
      fi
      ;;
  esac

  printf ''
}

# ---- _vl_resolve_abs_path ---------------------------------------------------
# Resolve a recorded artifact path to an absolute path for existence/hash
# checks. Accepts POSIX absolute (/...), Windows drive-letter (C:/... and
# C:\...) and UNC (//...) paths as already-absolute; prefixes anything else
# with the project directory. Codex r5 steps 5b/5c recorded Windows mixed
# paths (D:/...) which the old `/*`-only case treated as relative and broke.
_vl_resolve_abs_path() {
  local p="$1" proj="$2"
  case "$p" in
    /*)               printf '%s' "$p" ;;
    [A-Za-z]:/*)      printf '%s' "$p" ;;
    [A-Za-z]:\\*)     printf '%s' "$p" ;;
    *)                printf '%s/%s' "$proj" "$p" ;;
  esac
}

# ---- _vl_canonical_path -----------------------------------------------------
# Resolve a path to its physical absolute form, collapsing '.'/'..' and
# following symlinks. This is what closes the parent-directory-symlink and
# '../' escapes that a naive string-prefix containment check would miss. The
# caller canonicalizes only the PARENT directory of a log_artifact and appends
# the basename, so a symlink at the final component is still detected by the
# separate [ -L ] check rather than being silently followed.
_vl_canonical_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null && return 0
  fi
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$p" 2>/dev/null && return 0
  fi
  # POSIX fallback: cd -P into the (existing) parent to physically resolve it.
  local base d
  base="$(basename "$p")"
  d="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$d" "$base"
}

# Canonical identity used for binding run_started.project_root to the project
# supplied by the validator caller.  MSYS can represent the same Windows path
# as /d/foo, D:/foo, or with a different drive-letter case, so normalize via
# cygpath and compare case-insensitively only for drive-letter paths.
_vl_project_identity() {
  local p="$1" resolved
  resolved="$(_vl_canonical_path "$p")" || return 1
  if command -v cygpath >/dev/null 2>&1; then
    resolved="$(cygpath -m "$resolved" 2>/dev/null || printf '%s' "$resolved")"
  fi
  case "$resolved" in
    [A-Za-z]:/*) resolved="$(printf '%s' "$resolved" | tr '[:upper:]' '[:lower:]')" ;;
  esac
  while [ "$resolved" != "/" ] && [ "${resolved%/}" != "$resolved" ]; do
    resolved="${resolved%/}"
  done
  printf '%s' "$resolved"
}

# ---- validate_run_log -------------------------------------------------------
# The canonical 16-step validation.
# Args: <run_id> [project_dir]
# Output: JSON result on stdout
# Exit: 0 if .valid==true, 1 otherwise
validate_run_log() {
  local run_id="$1"
  local project_dir="${2:-.}"
  local log_path="$project_dir/.harness/logs/runs/${run_id}.ndjson"
  local runs_dir
  runs_dir="$(cd "$project_dir" 2>/dev/null && pwd)/.harness/logs/runs"

  # ---- 1: run_id character whitelist ----
  if ! printf '%s' "$run_id" | grep -qE '^[A-Za-z0-9._-]+$'; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "run_id_invalid_characters", run_id: $run_id}'
    return 1
  fi
  # Path traversal guard
  case "$run_id" in
    *..*|/*|*\\*)
      jq -n --arg run_id "$run_id" '{valid: false, reason: "run_id_path_traversal", run_id: $run_id}'
      return 1
      ;;
  esac

  # ---- 2: Resolved path must be inside runs/ ----
  local resolved
  resolved="$(cd "$(dirname "$log_path")" 2>/dev/null && pwd)/$(basename "$log_path")" || true
  if [ -z "$resolved" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "log_path_resolve_failed", run_id: $run_id}'
    return 1
  fi
  if ! printf '%s' "$resolved" | grep -qF "$runs_dir"; then
    jq -n --arg run_id "$run_id" --arg path "$resolved" --arg root "$runs_dir" \
      '{valid: false, reason: "log_path_escape", run_id: $run_id, path: $path, root: $root}'
    return 1
  fi

  # ---- 3: File must exist and be parseable ----
  if [ ! -f "$log_path" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "run_log_missing", run_id: $run_id}'
    return 1
  fi

  # Parse all non-blank lines as JSON events
  local events_json
  events_json="$(grep -v '^[[:space:]]*$' "$log_path" | jq -R -s '
    split("\n") | map(select(length > 0) | fromjson)
  ' 2>/dev/null)" || {
    jq -n --arg run_id "$run_id" '{valid: false, reason: "unparseable_log", run_id: $run_id}'
    return 1
  }

  local event_count
  event_count="$(printf '%s' "$events_json" | jq 'length')"
  if [ "$event_count" = "0" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "empty_log", run_id: $run_id}'
    return 1
  fi

  # ---- 4: Reject unknown event types ----
  local unknown
  unknown="$(printf '%s' "$events_json" | jq --argjson known "$KNOWN_EVENTS" '
    [.[] | select(.event as $e | $known | index($e) | not)] | .[0].event // empty
  ')"
  if [ -n "$unknown" ]; then
    jq -n --arg run_id "$run_id" --arg event "$unknown" \
      '{valid: false, reason: "unknown_event_type", run_id: $run_id, event: $event}'
    return 1
  fi

  # ---- 5: Validate required fields and types per event ----
  local count
  count="$(printf '%s' "$events_json" | jq 'length')"
  local i
  i=0
  while [ "$i" -lt "$count" ]; do
    local ev
    ev="$(printf '%s' "$events_json" | jq -c ".[$i]")"
    local field_err
    field_err="$(_validate_event_fields "$ev")"
    if [ -n "$field_err" ]; then
      jq -n --arg run_id "$run_id" --argjson line "$((i + 1))" --arg detail "$field_err" \
        '{valid: false, reason: "invalid_event_fields", run_id: $run_id, line: $line, detail: $detail}'
      return 1
    fi
    i=$((i + 1))
  done

  # ---- 5b/5c/5d: command execution evidence binding (Codex r5 defect 1) ----
  # A hand-crafted NDJSON can forge three kinds of command evidence, each of
  # which must be independently bound to reality:
  #   5b — a non-empty log_artifact MUST resolve to a real regular file under
  #        the project (symlinks rejected: `[ -f ]` follows symlinks, letting an
  #        attacker redirect recorded evidence to an arbitrary file). Empty
  #        log_artifact is the legitimate missing-tool sentinel: harness-verify
  #        emits command_completed with log_artifact="" + log_sha256=null +
  #        exit_code=127 when argv[0] is not on PATH.
  #   5c — a non-empty log_artifact + non-null log_sha256 MUST match a fresh
  #        recomputation byte-for-byte (empty artifact + null sha = missing-tool
  #        sentinel, allowed without a recompute).
  #   5d — for origin=configured, the recorded command array MUST equal the
  #        config-declared argv (accepting `verification.commands[*].command`
  #        (canonical) and `verification_plan.commands[*].argv` (legacy)).
  #        Symlink config is rejected: `[ -f ]` follows symlinks.
  #
  # Fail-closed semantics (5d): configured+config missing → configured_command_
  # without_config; configured+id not in cfg → command_not_in_config; argv
  # differs → command_array_mismatch; origin=detected → skip (no config anchor).
  #
  # Perf: these three checks were originally three full scans over `events_json`
  # (one jq spawn per field per scan). They are merged into ONE scan that
  # extracts every field a command_completed event needs in a single jq call,
  # joined on \x1f (unit separator) so backslash Windows paths survive. Check
  # order is preserved per event (5b → 5c → 5d), and each test fixture carries
  # a single defect, so the first-error reported is unchanged.
  local config_path="$project_dir/.harness/config.json"
  local has_config="false"
  if [ -f "$config_path" ] && [ ! -L "$config_path" ]; then
    has_config="true"
  fi
  local i=0
  while [ "$i" -lt "$count" ]; do
    local ev
    ev="$(printf '%s' "$events_json" | jq -c ".[$i]")"
    local fields cid la sha co recorded_cmd abs_la actual_sha config_cmd
    fields="$(printf '%s' "$ev" | jq -r '
        [ .command_id   // "",
          .log_artifact // "",
          (.log_sha256  // "null" | tostring),
          .command_origin // "",
          (.command // [] | tostring)
        ] | join("")')"
    IFS=$'\x1f' read -r cid la sha co recorded_cmd <<< "$fields"
    if [ -n "$cid" ]; then
      # 5b: log_artifact path (symlink, then existence)
      #
      # Codex r6 fix: the previous implementation treated an empty log_artifact
      # (or a null log_sha256) as a SILENT skip whenever exit_code != 127. A
      # hand-crafted NDJSON could therefore record any non-executed command
      # with log_artifact="" + log_sha256=null + exit_code=0 (or any non-127
      # code) and pass validation. The ONLY legitimate missing-tool sentinel is
      # harness-verify's own emission (line ~308): log_artifact="" + log_sha256
      # =null + exit_code=127 — a command whose argv[0] is not on PATH.
      # For any other case the recorded evidence MUST be a real file under
      # the project with a real, recomputable 64-hex sha256.
      #
      # The exit_code is extracted from the same per-event field list (added
      # below) so this check can distinguish the structural sentinel from
      # fabricated gaps. A recorded command with exit_code != 127 must always
      # carry a non-empty log_artifact that resolves to a real regular file
      # AND a non-null 64-hex log_sha256.
      local ec
      ec="$(printf '%s' "$ev" | jq -r '.exit_code // empty')"
      if [ -n "$la" ]; then
        abs_la="$(_vl_resolve_abs_path "$la" "$project_dir")"
        # Reject artifacts whose resolved path escapes the project dir
        # (absolute paths in the recorded log_artifact MUST live inside
        # project_dir; relative paths are joined with project_dir). Without
        # this guard a hand-crafted run can point recorded evidence at any
        # file on the filesystem — including /etc/passwd.
        local proj_abs
        proj_abs="$(cd "$project_dir" 2>/dev/null && pwd)" || {
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg project_dir "$project_dir" \
            '{valid: false, reason: "project_dir_resolve_failed",
              run_id: $run_id, command_id: $cid, project_dir: $project_dir}'
          return 1
        }
        # Canonicalize to physical paths. This resolves '../' escapes AND
        # parent-directory symlinks (e.g. a symlinked .harness/logs/runs/run/
        # that points outside the project). Only the PARENT directory of the
        # artifact is canonicalized — the final component is left untouched so
        # a symlink at that component is caught by the [ -L ] check below.
        local la_dir la_base real_la real_proj
        la_dir="$(dirname "$abs_la")"
        la_base="$(basename "$abs_la")"
        real_proj="$(_vl_canonical_path "$proj_abs")"
        real_la="$(_vl_canonical_path "$la_dir")/$la_base"
        if [ -z "$real_proj" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg project_dir "$project_dir" \
            '{valid: false, reason: "project_dir_resolve_failed",
              run_id: $run_id, command_id: $cid, project_dir: $project_dir}'
          return 1
        fi
        # Normalize both sides via cygpath -m when available (Windows/MSYS
        # records paths as drive-letter absolute while realpath yields
        # POSIX-style /c/... — comparing the two as-is would yield a false
        # outside-project on the recorded-but-legitimate Windows path).
        local norm_abs norm_proj
        if command -v cygpath >/dev/null 2>&1; then
          norm_abs="$(cygpath -m "$real_la" 2>/dev/null || printf '%s' "$real_la")"
          norm_proj="$(cygpath -m "$real_proj" 2>/dev/null || printf '%s' "$real_proj")"
        else
          norm_abs="$real_la"
          norm_proj="$real_proj"
        fi
        # Case-insensitive startswith on Windows (drive-letter paths are
        # case-insensitive); case-sensitive elsewhere.
        local in_project="false"
        case "$norm_abs" in
          "$norm_proj"/*) in_project="true" ;;
          "$norm_proj")   in_project="true" ;;
          *)
            # Try case-insensitive prefix when one side carries a drive letter
            # (Windows). shopt is unavailable in #!/bin/bash on every POSIX
            # variant, so use a portable tr-upper comparison instead.
            local up_abs up_proj
            up_abs="$(printf '%s' "$norm_abs" | tr '[:upper:]' '[:lower:]')"
            up_proj="$(printf '%s' "$norm_proj" | tr '[:upper:]' '[:lower:]')"
            case "$up_abs" in
              "$up_proj"/*) in_project="true" ;;
              "$up_proj")   in_project="true" ;;
            esac
            ;;
        esac
        if [ "$in_project" != "true" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg path "$la" --arg resolved "$abs_la" --arg project_dir "$proj_abs" \
            '{valid: false, reason: "log_artifact_outside_project",
              run_id: $run_id, command_id: $cid, path: $path, resolved: $resolved, project_dir: $project_dir}'
          return 1
        fi
        if [ -L "$abs_la" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg path "$la" \
            '{valid: false, reason: "log_artifact_symlink",
              run_id: $run_id, command_id: $cid, path: $path}'
          return 1
        fi
        if [ ! -f "$abs_la" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg path "$la" \
            '{valid: false, reason: "log_artifact_missing",
              run_id: $run_id, command_id: $cid, path: $path}'
          return 1
        fi
        # 5c: every non-empty artifact — including a command that really ran
        # and returned 127 — requires a real matching hash.  The missing-tool
        # sentinel is exact: artifact="", hash=null, exit_code=127.
        if [ -z "$sha" ] || [ "$sha" = "null" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg ec "$ec" --arg path "$la" \
            '{valid: false, reason: "log_sha256_missing",
              run_id: $run_id, command_id: $cid, exit_code: $ec, path: $path}'
          return 1
        fi
        if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{64}$'; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg ec "$ec" --arg sha "$sha" \
            '{valid: false, reason: "log_sha256_not_64hex",
              run_id: $run_id, command_id: $cid, exit_code: $ec, log_sha256: $sha}'
          return 1
        fi
        actual_sha="$(sha256sum "$abs_la" 2>/dev/null | awk '{print $1}')"
        if [ -z "$actual_sha" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg path "$la" \
            '{valid: false, reason: "log_sha256_recompute_failed",
              run_id: $run_id, command_id: $cid, path: $path}'
          return 1
        fi
        if [ "$actual_sha" != "$sha" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" \
            --arg expected "$sha" --arg actual "$actual_sha" --arg path "$la" \
            '{valid: false, reason: "log_sha256_mismatch",
              run_id: $run_id, command_id: $cid,
              expected_sha256: $expected, actual_sha256: $actual, path: $path}'
          return 1
        fi
      else
        # log_artifact is empty. The ONLY legitimate empty case is the
        # structural missing-tool sentinel (exit_code=127). Any other
        # exit_code must carry a real artifact path.
        if [ -z "$ec" ] || [ "$ec" != "127" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg ec "$ec" \
            '{valid: false, reason: "log_artifact_missing",
              run_id: $run_id, command_id: $cid, exit_code: $ec}'
          return 1
        fi
        if [ "$sha" != "null" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" --arg sha "$sha" \
            '{valid: false, reason: "missing_tool_sentinel_hash_not_null",
              run_id: $run_id, command_id: $cid, log_sha256: $sha}'
          return 1
        fi
      fi
      # 5d: command array vs config anchor
      if [ "$co" = "configured" ]; then
        if [ "$has_config" != "true" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" \
            '{valid: false, reason: "configured_command_without_config",
              run_id: $run_id, command_id: $cid}'
          return 1
        fi
        config_cmd="$(jq -c --arg cid "$cid" '
            ((.verification.commands // .verification_plan.commands // [])
             | map(select(.id == $cid))[0]
             | (.command // .argv))
            // empty
          ' "$config_path" 2>/dev/null)"
        if [ -z "$config_cmd" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" \
            '{valid: false, reason: "command_not_in_config",
              run_id: $run_id, command_id: $cid}'
          return 1
        fi
        if [ "$recorded_cmd" != "$config_cmd" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" \
            --argjson expected "$config_cmd" --argjson actual "$recorded_cmd" \
            '{valid: false, reason: "command_array_mismatch",
              run_id: $run_id, command_id: $cid,
              config_command: $expected, recorded_command: $actual}'
          return 1
        fi
      fi
    fi
    i=$((i + 1))
  done

  # ---- 6: schema_version valid ----
  local sv
  sv="$(printf '%s' "$events_json" | jq '.[0].schema_version')"
  if ! printf '%s' "$events_json" | jq -e '.[0].schema_version >= 1 and .[0].schema_version <= 2' >/dev/null 2>&1; then
    jq -n --arg run_id "$run_id" --argjson found "$sv" \
      '{valid: false, reason: "invalid_schema_version", run_id: $run_id, found: $found}'
    return 1
  fi

  # ---- 7: All events have same schema_version ----
  local mixed
  mixed="$(printf '%s' "$events_json" | jq --argjson sv "$sv" '
    [.[] | select(.schema_version != $sv)] | length
  ')"
  if [ "$mixed" != "0" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "mixed_schema_version", run_id: $run_id}'
    return 1
  fi

  # ---- 8: All events have matching run_id ----
  local mismatch
  mismatch="$(printf '%s' "$events_json" | jq --arg rid "$run_id" '
    [.[] | select(.run_id != $rid)] | length
  ')"
  if [ "$mismatch" != "0" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "run_id_mismatch", run_id: $run_id}'
    return 1
  fi

  # ---- 9: Exactly one run_started, must be first non-blank event ----
  local first_ev
  first_ev="$(printf '%s' "$events_json" | jq -r '.[0].event')"
  if [ "$first_ev" != "run_started" ]; then
    jq -n --arg run_id "$run_id" --arg found "$first_ev" \
      '{valid: false, reason: "first_event_not_run_started", run_id: $run_id, found: $found}'
    return 1
  fi

  local started_count
  started_count="$(printf '%s' "$events_json" | jq '[.[] | select(.event == "run_started")] | length')"
  if [ "$started_count" != "1" ]; then
    jq -n --arg run_id "$run_id" --argjson found "$started_count" \
      '{valid: false, reason: "run_started_count", run_id: $run_id, expected: 1, found: $found}'
    return 1
  fi

  # ---- 10: required_command_ids must not have duplicates ----
  local run_started
  run_started="$(printf '%s' "$events_json" | jq '.[0]')"
  local req_ids_len dup_len
  req_ids_len="$(printf '%s' "$run_started" | jq '.required_command_ids | length')"
  dup_len="$(printf '%s' "$run_started" | jq '.required_command_ids | unique | length')"
  if [ "$req_ids_len" != "$dup_len" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "duplicate_required_command_id", run_id: $run_id}'
    return 1
  fi

  # ---- 11: Exactly one terminal event, must be last non-blank event ----
  local last_idx
  last_idx="$((event_count - 1))"
  local last_ev
  last_ev="$(printf '%s' "$events_json" | jq -r ".[$last_idx].event")"
  case "$last_ev" in
    run_completed|run_failed|run_aborted) ;;
    *)
      jq -n --arg run_id "$run_id" --arg found "$last_ev" \
        '{valid: false, reason: "last_event_not_terminal", run_id: $run_id, found: $found}'
      return 1
      ;;
  esac

  local terminal_count
  terminal_count="$(printf '%s' "$events_json" | jq '[.[] | select(.event | test("^run_(completed|failed|aborted)$"))] | length')"
  if [ "$terminal_count" != "1" ]; then
    jq -n --arg run_id "$run_id" --argjson found "$terminal_count" \
      '{valid: false, reason: "terminal_event_count", run_id: $run_id, expected: 1, found: $found}'
    return 1
  fi

  # ---- 12: command_id uniqueness across command_completed events ----
  local cmd_events
  cmd_events="$(printf '%s' "$events_json" | jq '[.[] | select(.event == "command_completed")]')"
  local cmd_count dup_cmd
  cmd_count="$(printf '%s' "$cmd_events" | jq 'length')"
  dup_cmd="$(printf '%s' "$cmd_events" | jq '[.[].command_id] | unique | length')"
  if [ "$cmd_count" != "$dup_cmd" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "duplicate_command_id", run_id: $run_id}'
    return 1
  fi

  # ---- 13: Required command coverage ----
  # E5 unification: the effective required set = run_started.required_command_ids
  # minus the terminal's not_applicable_command_ids (required commands whose
  # applies_when predicate was false are legitimately excluded from coverage).
  # Every remaining required command must have a command_completed event, or the
  # log is structurally incomplete.
  local completed_ids missing_count eff_required
  completed_ids="$(printf '%s' "$cmd_events" | jq '[.[].command_id]')"
  eff_required="$(printf '%s' "$events_json" | jq -c \
    --argjson last_idx "$last_idx" \
    '.[0].required_command_ids - ((.[$last_idx].not_applicable_command_ids // []) as $na | $na)')"
  missing_count="$(printf '%s' "$events_json" | jq --argjson eff "$eff_required" '
    [.[] | select(.event == "command_completed") | .command_id] as $completed
    | [$eff[] | select(. as $r | $completed | index($r) | not)] | length
  ')"
  if [ "$missing_count" != "0" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "missing_required_command", run_id: $run_id}'
    return 1
  fi

  # ---- 14: Terminal count invariants ----
  local terminal
  terminal="$(printf '%s' "$events_json" | jq ".[$last_idx]")"

  # 14a: executed = passed + failed
  local ex pa fa
  ex="$(printf '%s' "$terminal" | jq '.executed_commands')"
  pa="$(printf '%s' "$terminal" | jq '.passed_commands')"
  fa="$(printf '%s' "$terminal" | jq '.failed_commands')"
  if [ "$ex" != "$((pa + fa))" ]; then
    jq -n --arg run_id "$run_id" --argjson executed "$ex" --argjson passed "$pa" --argjson failed "$fa" \
      '{valid: false, reason: "executed_count_invariant", run_id: $run_id, executed: $executed, passed: $passed, failed: $failed}'
    return 1
  fi

  # 14b: planned = executed + skipped
  local pl sk
  pl="$(printf '%s' "$terminal" | jq '.planned_commands')"
  sk="$(printf '%s' "$terminal" | jq '.skipped_commands')"
  if [ "$pl" != "$((ex + sk))" ]; then
    jq -n --arg run_id "$run_id" --argjson planned "$pl" --argjson executed "$ex" --argjson skipped "$sk" \
      '{valid: false, reason: "planned_count_invariant", run_id: $run_id, planned: $planned, executed: $executed, skipped: $skipped}'
    return 1
  fi

  # 14c: planned >= required_command_ids.length (optional commands allowed)
  # required_command_ids is a subset of all planned commands.
  local req_len
  req_len="$(printf '%s' "$run_started" | jq '.required_command_ids | length')"
  if [ "$pl" -lt "$req_len" ]; then
    jq -n --arg run_id "$run_id" --argjson planned "$pl" --argjson required "$req_len" \
      '{valid: false, reason: "planned_vs_required_mismatch", run_id: $run_id, planned: $planned, required: $required}'
    return 1
  fi

  # 14d: command_completed events = executed
  if [ "$cmd_count" != "$ex" ]; then
    jq -n --arg run_id "$run_id" --argjson cmd_events "$cmd_count" --argjson executed "$ex" \
      '{valid: false, reason: "command_event_count_mismatch", run_id: $run_id, command_events: $cmd_events, executed: $executed}'
    return 1
  fi

  # 14e: terminal claims are derived from the command events, never trusted.
  # A non-zero command cannot be relabelled as passed by forging terminal
  # counters, failed IDs, or overall_result.
  local derived_passed derived_failed derived_failed_ids terminal_failed_ids terminal_event overall
  derived_passed="$(printf '%s' "$cmd_events" | jq '[.[] | select(.exit_code == 0)] | length')"
  derived_failed="$(printf '%s' "$cmd_events" | jq '[.[] | select(.exit_code != 0)] | length')"
  if [ "$pa" != "$derived_passed" ] || [ "$fa" != "$derived_failed" ]; then
    jq -n --arg run_id "$run_id" \
      --argjson claimed_passed "$pa" --argjson actual_passed "$derived_passed" \
      --argjson claimed_failed "$fa" --argjson actual_failed "$derived_failed" \
      '{valid: false, reason: "terminal_command_result_mismatch", run_id: $run_id,
        claimed_passed: $claimed_passed, actual_passed: $actual_passed,
        claimed_failed: $claimed_failed, actual_failed: $actual_failed}'
    return 1
  fi
  terminal_event="$(printf '%s' "$terminal" | jq -r '.event')"
  overall="$(printf '%s' "$terminal" | jq -r '.overall_result')"
  if { [ "$terminal_event" = "run_completed" ] && [ "$overall" = "passed" ]; } && [ "$derived_failed" != "0" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "passed_run_contains_failed_command", run_id: $run_id}'
    return 1
  fi
  if [ "$terminal_event" = "run_completed" ] && [ "$overall" = "no_checks" ] && [ "$cmd_count" != "0" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "no_checks_run_contains_commands", run_id: $run_id}'
    return 1
  fi
  if [ "$terminal_event" = "run_failed" ]; then
    if [ "$derived_failed" = "0" ]; then
      jq -n --arg run_id "$run_id" '{valid: false, reason: "failed_run_without_failed_command", run_id: $run_id}'
      return 1
    fi
    derived_failed_ids="$(printf '%s' "$cmd_events" | jq -c '[.[] | select(.exit_code != 0) | .command_id] | sort')"
    terminal_failed_ids="$(printf '%s' "$terminal" | jq -c '[.failed_command_ids[]] | sort')"
    if [ "$derived_failed_ids" != "$terminal_failed_ids" ]; then
      jq -n --arg run_id "$run_id" --argjson claimed "$terminal_failed_ids" --argjson actual "$derived_failed_ids" \
        '{valid: false, reason: "failed_command_ids_mismatch", run_id: $run_id,
          claimed_failed_command_ids: $claimed, actual_failed_command_ids: $actual}'
      return 1
    fi
  fi

  # ---- 15: Origin–confirmation invariants ----
  local origin_err_count
  origin_err_count="$(printf '%s' "$cmd_events" | jq '
    [.[] | select(
      (.command_origin == "configured" and .confirmation != "not_required") or
      (.command_origin == "detected" and .confirmation != "confirmed")
    )] | length
  ')"
  if [ "$origin_err_count" != "0" ]; then
    jq -n --arg run_id "$run_id" '{valid: false, reason: "origin_confirmation_invariant", run_id: $run_id}'
    return 1
  fi

  # ---- 16: bind the recorded project root to this validator invocation ----
  local recorded_root expected_root recorded_identity expected_identity
  recorded_root="$(printf '%s' "$run_started" | jq -r '.project_root')"
  expected_root="$(cd "$project_dir" 2>/dev/null && pwd)" || expected_root=""
  recorded_identity="$(_vl_project_identity "$recorded_root" 2>/dev/null)" || recorded_identity=""
  expected_identity="$(_vl_project_identity "$expected_root" 2>/dev/null)" || expected_identity=""
  if [ -z "$recorded_identity" ] || [ -z "$expected_identity" ]; then
    jq -n --arg run_id "$run_id" --arg recorded "$recorded_root" --arg expected "$project_dir" \
      '{valid: false, reason: "project_root_resolve_failed", run_id: $run_id,
        recorded_project_root: $recorded, expected_project_root: $expected}'
    return 1
  fi
  if [ "$recorded_identity" != "$expected_identity" ]; then
    jq -n --arg run_id "$run_id" --arg recorded "$recorded_identity" --arg expected "$expected_identity" \
      '{valid: false, reason: "project_root_mismatch", run_id: $run_id,
        recorded_project_root: $recorded, expected_project_root: $expected}'
    return 1
  fi

  # Association run_id is checked by callers that receive an association.
  # (Per design §3.1 step 16: assoc.run_id == run_id. This function doesn't
  # receive an association object — callers verify that separately.)

  # Success
  jq -n --arg run_id "$run_id" \
    --argjson run_started "$run_started" \
    --argjson terminal "$terminal" \
    --argjson command_events "$cmd_events" \
    '{valid: true, run_id: $run_id, run_started: $run_started, terminal: $terminal, command_events: $command_events}'
  return 0
}
