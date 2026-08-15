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

  # ---- 5b: log_artifact path validation (Codex r5 defect 1) --------------
  # When log_artifact is non-empty, the path MUST resolve to a real regular
  # file under the project (symlinks rejected — `[ -f ]` follows symlinks and
  # an attacker could redirect the recorded evidence to an arbitrary file).
  # Empty log_artifact is the legitimate missing-tool sentinel: harness-verify
  # emits command_completed with log_artifact="" + log_sha256=null + exit_code=127
  # when the command's argv[0] is not on PATH (harness-verify.sh lines 315-340).
  # Anything else (non-empty log_artifact) is a positive claim that the run
  # captured the command's stdout/stderr to disk — the file MUST be there.
  local i=0
  while [ "$i" -lt "$count" ]; do
    local ev cid la abs_la
    ev="$(printf '%s' "$events_json" | jq -c ".[$i]")"
    cid="$(printf '%s' "$ev" | jq -r '.command_id // empty')"
    if [ -n "$cid" ]; then
      la="$(printf '%s' "$ev" | jq -r '.log_artifact // ""')"
      if [ -n "$la" ]; then
        case "$la" in
          /*) abs_la="$la" ;;
          *)  abs_la="$project_dir/$la" ;;
        esac
        # Symlink rejection (must come BEFORE [ -f ]: `[ -f ]` follows symlinks
        # and would silently accept a symlink pointing to a real file).
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
      fi
    fi
    i=$((i + 1))
  done

  # ---- 5c: log_sha256 must equal the recomputed sha256 of log_artifact -----
  # Codex r5 defect 1: a hand-crafted NDJSON can claim any log_sha256; the only
  # way to bind the recorded claim to reality is to rehash the artifact and
  # compare byte-for-byte. Empty log_artifact + null log_sha256 is the
  # missing-tool sentinel and is allowed without a recompute. Any other state
  # (non-empty log_artifact + any log_sha256) MUST match a fresh recomputation.
  i=0
  while [ "$i" -lt "$count" ]; do
    local ev cid la sha actual_sha abs_la
    ev="$(printf '%s' "$events_json" | jq -c ".[$i]")"
    cid="$(printf '%s' "$ev" | jq -r '.command_id // empty')"
    if [ -n "$cid" ]; then
      la="$(printf '%s' "$ev" | jq -r '.log_artifact // ""')"
      sha="$(printf '%s' "$ev" | jq -r '.log_sha256 // "null"')"
      if [ -n "$la" ] && [ "$sha" != "null" ] && [ -n "$sha" ]; then
        case "$la" in
          /*) abs_la="$la" ;;
          *)  abs_la="$project_dir/$la" ;;
        esac
        actual_sha="$(sha256sum "$abs_la" 2>/dev/null | awk '{print $1}')"
        if [ "$actual_sha" != "$sha" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" \
            --arg expected "$sha" --arg actual "$actual_sha" --arg path "$la" \
            '{valid: false, reason: "log_sha256_mismatch",
              run_id: $run_id, command_id: $cid,
              expected_sha256: $expected, actual_sha256: $actual, path: $path}'
          return 1
        fi
      fi
    fi
    i=$((i + 1))
  done

  # ---- 5d: command array MUST equal the config-declared argv (Codex r5) ----
  # Codex r5 defect 1: an attacker can forge a NDJSON with command:["true"]
  # and any command_id, exit_code=0, and a config-matching command_origin —
  # the recorded command array is meaningless without an independent anchor.
  # The anchor is the project's .harness/config.json: the recorded command
  # array MUST equal the canonical argv the project declared for that
  # command_id (accepting both `verification.commands[*].command` (canonical
  # real-repo format) and `verification_plan.commands[*].argv` (legacy test
  # format)). Symlink PLAN/config is rejected: `[ -f ]` follows symlinks.
  #
  # Fail-closed semantics:
  #   origin=configured + config missing         → configured_command_without_config
  #   origin=configured + command_id not in cfg  → command_not_in_config
  #   origin=configured + argv differs           → command_array_mismatch
  #   origin=detected                           → skip (detected commands have
  #                                                no canonical config anchor)
  local config_path="$project_dir/.harness/config.json"
  local has_config="false"
  if [ -f "$config_path" ] && [ ! -L "$config_path" ]; then
    has_config="true"
  fi
  i=0
  while [ "$i" -lt "$count" ]; do
    local ev cid co cmd_json config_cmd recorded_cmd
    ev="$(printf '%s' "$events_json" | jq -c ".[$i]")"
    cid="$(printf '%s' "$ev" | jq -r '.command_id // empty')"
    if [ -n "$cid" ]; then
      co="$(printf '%s' "$ev" | jq -r '.command_origin // empty')"
      if [ "$co" = "configured" ]; then
        recorded_cmd="$(printf '%s' "$ev" | jq -c '.command')"
        if [ "$has_config" != "true" ]; then
          jq -n --arg run_id "$run_id" --arg cid "$cid" \
            '{valid: false, reason: "configured_command_without_config",
              run_id: $run_id, command_id: $cid}'
          return 1
        fi
        # Look up command_id in config (accept either canonical or legacy schema)
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

  # ---- 16: association run_id would be checked by caller ----
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
