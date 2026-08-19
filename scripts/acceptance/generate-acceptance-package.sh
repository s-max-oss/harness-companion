#!/bin/bash
# scripts/acceptance/generate-acceptance-package.sh
#
# Build the current-HEAD acceptance package at
#   .harness/acceptance/<HEAD>/acceptance.json
#   .harness/acceptance/<HEAD>/A-G.log
# binding the canonical run's NDJSON / full-suite.log / maintenance verdict /
# fresh Reviewer verdict / migration record by SHA-256, and force-replacing
# BOTH files in runtime-manifest with their fresh on-disk hashes.
#
# The package is committed/HEAD-scoped: directory name IS the full HEAD OID.
# Re-running for the same HEAD is idempotent; running for a different HEAD
# writes a sibling directory and never mutates an existing one.
#
# Real-evidence binding contract:
#   The ONLY required input is the absolute path to the canonical run's
#   NDJSON. Every other field (HEAD_OID, RUN_ID, DURATION_MS, COMMAND,
#   EFFECTIVE_TIMEOUT, CONFIG_SHA256, FULL_SUITE_LOG, log_sha256) is read
#   DIRECTLY from the run_started / command_completed / run_completed events
#   in that NDJSON — there is no env-var shortcut that could let a caller
#   fabricate values. effect_timeout is read from .harness/config.json
#   timeout_seconds and matched against the on-disk file's sha256.
#
# Concurrency:
#   The whole "idempotency check + write A-G.log + write acceptance.json +
#   force-replace runtime-manifest entries" window runs under a registry
#   lock on .harness/acceptance/.lock/pkg-write. Two concurrent invocations
#   serialize; partial state from a crashed run is recoverable via the lock's
#   stale-recovery matrix.
#
# Atomic publish:
#   acceptance.json is written to <pkg>/acceptance.json.tmp then mv'd to
#   <pkg>/acceptance.json (POSIX-atomic on the same filesystem).
#   runtime-manifest.jsonl entries are stripped+rebuilt via tmp+mv under the
#   registry lock.
#
# Required env (single input):
#   CANONICAL_NDJSON — absolute path to canonical run's .ndjson (must end in
#                      run_completed with overall_result=passed for the
#                      RUN_ID recorded in run_started)
#
# Exit 0 on success (all fail-closed checks pass + both files written and
# force-replaced in runtime-manifest); non-zero on any failure (no partial
# package, no swallowed error, lock always released).

set -u
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ACCEPT_BASE="$ROOT_DIR/.harness/acceptance"
PKG_LOCK_DIR="$ROOT_DIR/.harness/acceptance/.lock/pkg-write"

# Source lock + runtime-manifest libs early so we can use acquire_lock and
# runtime-manifest helpers anywhere in the script.
# shellcheck source=../../core/lib/lock-registry.sh
. "$ROOT_DIR/core/lib/lock-registry.sh"
# shellcheck source=../../core/lib/runtime-manifest.sh
. "$ROOT_DIR/core/lib/runtime-manifest.sh"
# shellcheck source=../../core/lib/validate-run-log.sh
. "$ROOT_DIR/core/lib/validate-run-log.sh"

# ---- Single required input ----
: "${CANONICAL_NDJSON:?CANONICAL_NDJSON is required (absolute path to canonical NDJSON)}"
if [ ! -f "$CANONICAL_NDJSON" ]; then
  echo "generate-acceptance-package: CANONICAL_NDJSON does not exist: $CANONICAL_NDJSON" >&2
  exit 1
fi

# ---- Helper: portable sha256 of a file's bytes ----
sha256_of() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# ---- Fail-closed check 1: canonical NDJSON must record a successful run ----
# Extract RUN_ID from the first run_started event.
NDJSON_RUN_STARTED="$(grep -E '"event":"run_started"' "$CANONICAL_NDJSON" | head -1)"
if [ -z "$NDJSON_RUN_STARTED" ]; then
  echo "generate-acceptance-package: canonical NDJSON has no run_started event: $CANONICAL_NDJSON" >&2
  exit 1
fi
RUN_ID="$(printf '%s' "$NDJSON_RUN_STARTED" | jq -r '.run_id // empty')"
if [ -z "$RUN_ID" ]; then
  echo "generate-acceptance-package: canonical NDJSON run_started missing run_id" >&2
  exit 1
fi

# The supplied artifact must be the one authoritative path that
# validate_run_log() resolves for this run_id. This prevents a crafted second
# file from borrowing validation from a legitimate run with the same ID.
EXPECTED_NDJSON="$ROOT_DIR/.harness/logs/runs/$RUN_ID.ndjson"
if [ "$CANONICAL_NDJSON" != "$EXPECTED_NDJSON" ] || [ -L "$CANONICAL_NDJSON" ]; then
  echo "generate-acceptance-package: CANONICAL_NDJSON must equal authoritative run path: $EXPECTED_NDJSON" >&2
  exit 1
fi

# The acceptance package may only bind a run produced by the repository's
# canonical validator. Manual/partial/synthetic NDJSON is never evidence.
VALIDATION="$(validate_run_log "$RUN_ID" "$ROOT_DIR" 2>/dev/null)" || {
  echo "generate-acceptance-package: canonical NDJSON failed validate_run_log" >&2
  exit 1
}
if ! printf '%s' "$VALIDATION" | jq -e '.valid == true' >/dev/null 2>&1; then
  echo "generate-acceptance-package: canonical NDJSON is invalid" >&2
  printf '%s\n' "$VALIDATION" >&2
  exit 1
fi
# Format check
if ! printf '%s' "$RUN_ID" | grep -qE '^[0-9TZ]+-[0-9]+-[0-9]+$'; then
  echo "generate-acceptance-package: RUN_ID has invalid format: $RUN_ID" >&2
  exit 1
fi

# Extract VCS_REVISION (12-char short OID) from run_started for HEAD-matching.
NDJSON_VCS_REV_SHORT="$(printf '%s' "$NDJSON_RUN_STARTED" | jq -r '.vcs_revision // empty')"
if [ -z "$NDJSON_VCS_REV_SHORT" ]; then
  echo "generate-acceptance-package: canonical NDJSON run_started missing vcs_revision" >&2
  exit 1
fi

# Extract CONFIG_SHA256 from run_started.
NDJSON_CONFIG_SHA256="$(printf '%s' "$NDJSON_RUN_STARTED" | jq -r '.config_sha256 // empty')"
if [ -z "$NDJSON_CONFIG_SHA256" ]; then
  echo "generate-acceptance-package: canonical NDJSON run_started missing config_sha256" >&2
  exit 1
fi

# ---- Fail-closed check 2: terminal event must be a passing terminal ----
FINAL_EVENT="$(grep -E '"event":"run_(passed|completed|failed|aborted)"' "$CANONICAL_NDJSON" | tail -1)"
if [ -z "$FINAL_EVENT" ]; then
  echo "generate-acceptance-package: canonical NDJSON has no terminal event" >&2
  exit 1
fi
FINAL_KIND="$(printf '%s' "$FINAL_EVENT" | jq -r '.event // empty')"
FINAL_OVERALL="$(printf '%s' "$FINAL_EVENT" | jq -r '.overall_result // empty')"
FINAL_RUN_ID="$(printf '%s' "$FINAL_EVENT" | jq -r '.run_id // empty')"
FINAL_FAILED_CMDS="$(printf '%s' "$FINAL_EVENT" | jq -r '.failed_commands // 1')"
PASS_TERMINAL_OK=0
if [ "$FINAL_KIND" = "run_completed" ] && [ "$FINAL_OVERALL" = "passed" ] && [ "$FINAL_RUN_ID" = "$RUN_ID" ] && [ "$FINAL_FAILED_CMDS" = "0" ]; then
  PASS_TERMINAL_OK=1
elif [ "$FINAL_KIND" = "run_passed" ] && [ "$FINAL_OVERALL" = "passed" ] && [ "$FINAL_RUN_ID" = "$RUN_ID" ] && [ "$FINAL_FAILED_CMDS" = "0" ]; then
  PASS_TERMINAL_OK=1
fi
if [ "$PASS_TERMINAL_OK" != "1" ]; then
  echo "generate-acceptance-package: canonical NDJSON terminal is not a passing terminal" >&2
  echo "  event: $FINAL_KIND" >&2
  echo "  overall_result: $FINAL_OVERALL" >&2
  echo "  run_id: $FINAL_RUN_ID (expected $RUN_ID)" >&2
  echo "  failed_commands: $FINAL_FAILED_CMDS (expected 0)" >&2
  exit 1
fi

# ---- Fail-closed check 3: HEAD must match current git HEAD ----
# Use the FULL 40-hex OID expanded from NDJSON_VCS_REV_SHORT to verify the
# recorded HEAD equals the current working tree's HEAD.
if ! NDJSON_HEAD_FULL="$(git -C "$ROOT_DIR" rev-parse "$NDJSON_VCS_REV_SHORT" 2>/dev/null)"; then
  echo "generate-acceptance-package: canonical NDJSON's vcs_revision '$NDJSON_VCS_REV_SHORT' is not a resolvable git object" >&2
  exit 1
fi
HEAD_OID="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)" || {
  echo "generate-acceptance-package: cannot determine current HEAD (not a git repo?)" >&2
  exit 1
}
if [ "$NDJSON_HEAD_FULL" != "$HEAD_OID" ]; then
  echo "generate-acceptance-package: canonical NDJSON's HEAD != current git HEAD" >&2
  echo "  NDJSON vcs_revision: $NDJSON_VCS_REV_SHORT → $NDJSON_HEAD_FULL" >&2
  echo "  current HEAD:        $HEAD_OID" >&2
  exit 1
fi
if ! printf '%s' "$HEAD_OID" | grep -qE '^[0-9a-f]{40}$'; then
  echo "generate-acceptance-package: HEAD_OID must be 40-hex: $HEAD_OID" >&2
  exit 1
fi

# ---- Fail-closed check 4: CONFIG_SHA256 must match on-disk .harness/config.json ----
ACTUAL_CONFIG_SHA="$(sha256_of "$ROOT_DIR/.harness/config.json")"
EXPECTED_CONFIG_SHA="${NDJSON_CONFIG_SHA256#sha256:}"
if [ "$ACTUAL_CONFIG_SHA" != "$EXPECTED_CONFIG_SHA" ]; then
  echo "generate-acceptance-package: NDJSON config_sha256 does not match current .harness/config.json" >&2
  echo "  NDJSON:    $NDJSON_CONFIG_SHA256" >&2
  echo "  on-disk:   sha256:$ACTUAL_CONFIG_SHA" >&2
  exit 1
fi

# ---- Fail-closed check 5: EFFECTIVE_TIMEOUT read from .harness/config.json ----
# The on-disk schema (per core/lib/config-validate.sh) places timeout_seconds
# inside each verification command: `.verification.commands[$i].timeout_seconds`.
# The release contract has exactly one canonical command.
EFFECTIVE_TIMEOUT="$(jq -r '
  if has("verification") and (.verification | type == "object")
     and (.verification | has("commands")) and (.verification.commands | type == "array")
     and (.verification.commands | length > 0)
     and (.verification.commands[0] | has("timeout_seconds"))
  then .verification.commands[0].timeout_seconds
  elif has("timeout_seconds")
  then .timeout_seconds
  else empty
  end
' "$ROOT_DIR/.harness/config.json")"
if [ -z "$EFFECTIVE_TIMEOUT" ]; then
  echo "generate-acceptance-package: .harness/config.json missing timeout_seconds at .verification.commands[0].timeout_seconds (or top-level .timeout_seconds)" >&2
  exit 1
fi
if ! printf '%s' "$EFFECTIVE_TIMEOUT" | grep -qE '^[0-9]+$'; then
  echo "generate-acceptance-package: timeout_seconds must be integer: $EFFECTIVE_TIMEOUT" >&2
  exit 1
fi
if [ "$EFFECTIVE_TIMEOUT" -lt 1 ]; then
  echo "generate-acceptance-package: timeout_seconds must be >= 1" >&2
  exit 1
fi

# ---- Fail-closed check 6: locate the canonical command_completed event ----
# The canonical run's effective work happens in command_completed events.
# Take the LAST command_completed (in case of multi-command runs); bind to
# its command / duration / log_artifact / log_sha256. If the run has zero
# command_completed events, that is a hard violation.
LAST_CMD_EVENT="$(grep -E '"event":"command_completed"' "$CANONICAL_NDJSON" | tail -1)"
if [ -z "$LAST_CMD_EVENT" ]; then
  echo "generate-acceptance-package: canonical NDJSON has no command_completed event" >&2
  exit 1
fi
CMD_EVENT_COUNT="$(grep -cE '"event":"command_completed"' "$CANONICAL_NDJSON" || true)"
if [ "$CMD_EVENT_COUNT" != "1" ]; then
  echo "generate-acceptance-package: canonical run must contain exactly one command_completed event" >&2
  exit 1
fi
DURATION_MS="$(printf '%s' "$LAST_CMD_EVENT" | jq -r '.duration_ms // empty')"
if [ -z "$DURATION_MS" ] || ! printf '%s' "$DURATION_MS" | grep -qE '^[0-9]+$'; then
  echo "generate-acceptance-package: command_completed duration_ms must be integer: '$DURATION_MS'" >&2
  exit 1
fi
if [ "$DURATION_MS" -le 0 ]; then
  echo "generate-acceptance-package: command_completed duration_ms must be > 0" >&2
  exit 1
fi
# Full command: join the JSON array as a single string for evidence clarity.
COMMAND="$(printf '%s' "$LAST_CMD_EVENT" | jq -r '.command | join(" ")')"
if [ -z "$COMMAND" ]; then
  echo "generate-acceptance-package: command_completed command must be a non-empty array" >&2
  exit 1
fi
CONFIG_COMMAND="$(jq -c '.verification.commands[0].command' "$ROOT_DIR/.harness/config.json")"
EVENT_COMMAND="$(printf '%s' "$LAST_CMD_EVENT" | jq -c '.command')"
CONFIG_ID="$(jq -r '.verification.commands[0].id' "$ROOT_DIR/.harness/config.json")"
EVENT_ID="$(printf '%s' "$LAST_CMD_EVENT" | jq -r '.command_id // empty')"
if [ "$CONFIG_COMMAND" != '["bash","tests/run-all.sh"]' ] || [ "$CONFIG_ID" != "full-suite" ]; then
  echo "generate-acceptance-package: configured canonical contract must be full-suite: bash tests/run-all.sh" >&2
  exit 1
fi
if [ "$EVENT_COMMAND" != "$CONFIG_COMMAND" ] || [ "$EVENT_ID" != "$CONFIG_ID" ]; then
  echo "generate-acceptance-package: command event does not exactly match canonical config" >&2
  exit 1
fi
LOG_ARTIFACT="$(printf '%s' "$LAST_CMD_EVENT" | jq -r '.log_artifact // empty')"
if [ -z "$LOG_ARTIFACT" ] || [ "$LOG_ARTIFACT" = "null" ]; then
  echo "generate-acceptance-package: command_completed log_artifact missing" >&2
  exit 1
fi
if [ ! -f "$LOG_ARTIFACT" ]; then
  echo "generate-acceptance-package: command_completed log_artifact does not exist: $LOG_ARTIFACT" >&2
  exit 1
fi
NDJSON_LOG_SHA256_RECORDED="$(printf '%s' "$LAST_CMD_EVENT" | jq -r '.log_sha256 // empty')"
ACTUAL_LOG_SHA256="$(sha256_of "$LOG_ARTIFACT")"
if [ "$NDJSON_LOG_SHA256_RECORDED" != "$ACTUAL_LOG_SHA256" ]; then
  echo "generate-acceptance-package: command_completed log_sha256 does not match on-disk log_artifact" >&2
  echo "  NDJSON:    $NDJSON_LOG_SHA256_RECORDED" >&2
  echo "  on-disk:   $ACTUAL_LOG_SHA256" >&2
  exit 1
fi

# FULL_SUITE_LOG is the canonical command's log_artifact (the canonical
# harness-verify run wrote it. Its sha256 is bound both in the NDJSON
# command_completed event AND in acceptance.json as full_suite_log.sha256.
FULL_SUITE_LOG="$LOG_ARTIFACT"
FULL_SUITE_LOG_SHA="$ACTUAL_LOG_SHA256"

# ---- Fail-closed check 7: locate maintenance + ACTIVE migration record + Reviewer verdict ----
# These three paths are derived from convention (no env vars). The Reviewer
# verdict file must be the freshest line whose head_sha == HEAD_OID and
# whose recorded_at is within the last 24h. The migration record is the
# ACTIVE one (to_head == HEAD_OID, single_application_marker == applied=true)
# discovered in docs/migrations/*.json; historical records are skipped.
MAINTENANCE_VERDICT="$ROOT_DIR/.harness/reviews/maintenance/F-MAINT-01.jsonl"
if [ ! -f "$MAINTENANCE_VERDICT" ]; then
  echo "generate-acceptance-package: maintenance verdict file missing: $MAINTENANCE_VERDICT" >&2
  exit 1
fi
# Discover the ACTIVE migration record. ACTIVE is defined by CONTENT (its
# new_sha256 values currently match the in-tree runtime artifacts for all
# paths it declares to change), NOT by to_head. to_head is treated as a
# historical marker — HEAD churn since the migration's to_head was recorded
# does not invalidate the binding. Multiple *.json files may co-exist in
# docs/migrations/ — historical ones are preserved verbatim and must NOT
# be bound by the acceptance package.
shopt -s nullglob
ACTIVE_MIG=""
for mig in "$ROOT_DIR"/docs/migrations/*.json; do
  mig_marker="$(jq -r '.single_application_marker // empty' "$mig" 2>/dev/null)"
  [ "$mig_marker" = "applied=true" ] || continue
  mig_n="$(jq '.changes | length' "$mig" 2>/dev/null)" || continue
  mig_active=1
  for ci in $(seq 0 $((mig_n - 1))); do
    ci_path="$(jq -r ".changes[$ci].path" "$mig" 2>/dev/null)"
    ci_new="$(jq -r ".changes[$ci].new_sha256" "$mig" 2>/dev/null)"
    ci_actual="$(sha256sum "$ROOT_DIR/$ci_path" 2>/dev/null | awk '{print $1}')"
    if [ "$ci_new" != "$ci_actual" ]; then
      mig_active=0
      break
    fi
  done
  if [ "$mig_active" = "1" ]; then
    ACTIVE_MIG="$mig"
    break
  fi
done
shopt -u nullglob
if [ -z "$ACTIVE_MIG" ]; then
  echo "generate-acceptance-package: no ACTIVE migration record found in docs/migrations/ whose new_sha256 currently matches the in-tree runtime artifacts" >&2
  exit 1
fi
MIGRATION_RECORD="$ACTIVE_MIG"
REVIEWER_VERDICT="$ROOT_DIR/.harness/reviews/reviewer/F-MAINT-01.jsonl"
if [ ! -f "$REVIEWER_VERDICT" ]; then
  echo "generate-acceptance-package: reviewer verdict file missing: $REVIEWER_VERDICT" >&2
  exit 1
fi

# Reviewer verdict: freshest line must bind to HEAD_OID, verdict=PASS,
# run_id=RUN_ID, recorded_at within last 24h.
LAST_VERDICT="$(tail -1 "$REVIEWER_VERDICT")"
if [ -z "$LAST_VERDICT" ]; then
  echo "generate-acceptance-package: REVIEWER verdict file is empty" >&2
  exit 1
fi
VR_HEAD="$(printf '%s' "$LAST_VERDICT" | jq -r '.head_sha // empty')"
VR_VERDICT="$(printf '%s' "$LAST_VERDICT" | jq -r '.verdict // empty')"
VR_RUN="$(printf '%s' "$LAST_VERDICT" | jq -r '.run_id // empty')"
VR_RECORDED_AT="$(printf '%s' "$LAST_VERDICT" | jq -r '.recorded_at // empty')"
if [ "$VR_HEAD" != "$HEAD_OID" ]; then
  echo "generate-acceptance-package: fresh Reviewer verdict head_sha != HEAD_OID" >&2
  echo "  freshest head_sha: $VR_HEAD" >&2
  echo "  HEAD_OID:          $HEAD_OID" >&2
  exit 1
fi
if [ "$VR_VERDICT" != "PASS" ]; then
  echo "generate-acceptance-package: fresh Reviewer verdict is not PASS" >&2
  exit 1
fi
if [ "$VR_RUN" != "$RUN_ID" ]; then
  echo "generate-acceptance-package: fresh Reviewer verdict run_id != RUN_ID" >&2
  echo "  verdict run_id: $VR_RUN" >&2
  echo "  RUN_ID:          $RUN_ID" >&2
  exit 1
fi
NOW_EPOCH="$(date -u +%s)"
VR_EPOCH="$(date -u -d "$VR_RECORDED_AT" +%s 2>/dev/null || echo 0)"
if [ "$VR_EPOCH" -le 0 ]; then
  echo "generate-acceptance-package: REVIEWER verdict recorded_at unparseable: $VR_RECORDED_AT" >&2
  exit 1
fi
AGE_S=$((NOW_EPOCH - VR_EPOCH))
if [ "$AGE_S" -gt 86400 ] || [ "$AGE_S" -lt 0 ]; then
  echo "generate-acceptance-package: REVIEWER verdict not fresh (age=${AGE_S}s, max 86400s)" >&2
  exit 1
fi

# Maintenance verdict: freshest line must bind to HEAD_OID + RUN_ID.
LAST_MAINT="$(tail -1 "$MAINTENANCE_VERDICT")"
MV_HEAD="$(printf '%s' "$LAST_MAINT" | jq -r '.head_sha // empty')"
MV_RUN="$(printf '%s' "$LAST_MAINT" | jq -r '.run_id // empty')"
if [ "$MV_HEAD" != "$HEAD_OID" ]; then
  echo "generate-acceptance-package: fresh maintenance verdict head_sha != HEAD_OID ($MV_HEAD vs $HEAD_OID)" >&2
  exit 1
fi
if [ "$MV_RUN" != "$RUN_ID" ]; then
  echo "generate-acceptance-package: fresh maintenance verdict run_id != RUN_ID ($MV_RUN vs $RUN_ID)" >&2
  exit 1
fi

# ---- Acquire concurrency lock on the package write window ----
acquire_lock "$PKG_LOCK_DIR" 30 >/dev/null || {
  echo "generate-acceptance-package: failed to acquire package-write lock" >&2
  exit 1
}
trap 'release_lock "$PKG_LOCK_DIR" "${LOCK_REGISTRY_TOKEN:-}" >/dev/null 2>&1 || true' EXIT

# ---- Idempotency: existing package at this HEAD is left untouched ----
PKG_DIR="$ACCEPT_BASE/$HEAD_OID"
if [ -e "$PKG_DIR" ]; then
  echo "generate-acceptance-package: package already exists; refusing ambiguous overwrite: $PKG_DIR" >&2
  exit 1
fi

mkdir -p "$PKG_DIR"

# ---- Compute SHA-256 helpers (after lock; bytes are stable now) ----
NDJSON_SHA="$(sha256_of "$CANONICAL_NDJSON")"
VERDICT_SHA="$(sha256_of "$MAINTENANCE_VERDICT")"
REVIEWER_VERDICT_SHA="$(sha256_of "$REVIEWER_VERDICT")"
MIGRATION_SHA="$(sha256_of "$MIGRATION_RECORD")"

A_G_LOG="$PKG_DIR/A-G.log"
ACCEPT_JSON="$PKG_DIR/acceptance.json"

# ---- Build A-G.log: copy the canonical FULL_SUITE_LOG and
# prepend a header recording every binding for human inspection. The
# canonical FULL_SUITE_LOG's sha256 IS bound both in the NDJSON
# command_completed event AND in acceptance.json.full_suite_log.sha256 —
# re-running the A-G suites inside the generator would produce a DIFFERENT
# artifact with a DIFFERENT sha256, breaking the run_id/DURATION_MS binding.
# The header is bytes-pure text, so its sha256 is computable after write.
{
  echo "============================================================"
  echo "RC6 FINAL ACCEPTANCE PACKAGE — A-G SUITE LOG"
  echo "Head:                $HEAD_OID"
  echo "Run ID:              $RUN_ID"
  echo "Duration:            ${DURATION_MS} ms"
  echo "Effective timeout:   ${EFFECTIVE_TIMEOUT} s"
  echo "Config sha256:       $NDJSON_CONFIG_SHA256"
  echo "Canonical NDJSON:    $CANONICAL_NDJSON"
  echo "  sha256:            $NDJSON_SHA"
  echo "Canonical command:   $COMMAND"
  echo "Full-suite log:      $FULL_SUITE_LOG"
  echo "  sha256:            $FULL_SUITE_LOG_SHA"
  echo "Maintenance verdict: $MAINTENANCE_VERDICT"
  echo "  sha256:            $VERDICT_SHA"
  echo "Reviewer verdict:    $REVIEWER_VERDICT"
  echo "  sha256:            $REVIEWER_VERDICT_SHA"
  echo "Migration record:    $MIGRATION_RECORD"
  echo "  sha256:            $MIGRATION_SHA"
  echo "Generated at:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "============================================================"
  echo ""
  echo "----- BEGIN canonical full-suite log -----"
} > "$A_G_LOG"
cat "$FULL_SUITE_LOG" >> "$A_G_LOG"
echo "" >> "$A_G_LOG"
echo "----- END canonical full-suite log -----" >> "$A_G_LOG"

A_G_SHA="$(sha256_of "$A_G_LOG")"

# ---- Build acceptance.json ----------------------------------------------------
jq -n \
  --argjson schema_version 1 \
  --arg head_oid "$HEAD_OID" \
  --arg run_id "$RUN_ID" \
  --argjson duration_ms "$DURATION_MS" \
  --argjson effective_timeout "$EFFECTIVE_TIMEOUT" \
  --arg config_sha256 "$NDJSON_CONFIG_SHA256" \
  --arg canonical_command "$COMMAND" \
  --arg canonical_ndjson_path "$CANONICAL_NDJSON" \
  --arg canonical_ndjson_sha256 "$NDJSON_SHA" \
  --arg full_suite_log_path "$FULL_SUITE_LOG" \
  --arg full_suite_log_sha256 "$FULL_SUITE_LOG_SHA" \
  --arg maintenance_verdict_path "$MAINTENANCE_VERDICT" \
  --arg maintenance_verdict_sha256 "$VERDICT_SHA" \
  --arg reviewer_verdict_path "$REVIEWER_VERDICT" \
  --arg reviewer_verdict_sha256 "$REVIEWER_VERDICT_SHA" \
  --arg a_g_log_path "$A_G_LOG" \
  --arg a_g_log_sha256 "$A_G_SHA" \
  --arg migration_record_path "$MIGRATION_RECORD" \
  --arg migration_record_sha256 "$MIGRATION_SHA" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     schema_version: $schema_version,
     head_oid: $head_oid,
     run_id: $run_id,
     duration_ms: $duration_ms,
     effective_timeout: $effective_timeout,
     config_sha256: $config_sha256,
     canonical_command: $canonical_command,
     canonical_ndjson: { path: $canonical_ndjson_path, sha256: $canonical_ndjson_sha256 },
     full_suite_log:  { path: $full_suite_log_path,  sha256: $full_suite_log_sha256  },
     maintenance_verdict: { path: $maintenance_verdict_path, sha256: $maintenance_verdict_sha256 },
     reviewer_verdict: { path: $reviewer_verdict_path, sha256: $reviewer_verdict_sha256 },
     a_g_log:         { path: $a_g_log_path,         sha256: $a_g_log_sha256         },
     migration_record:{ path: $migration_record_path, sha256: $migration_record_sha256 },
     generated_at: $generated_at
   }' > "$ACCEPT_JSON.tmp" || {
    rm -f "$ACCEPT_JSON.tmp"
    rm -rf "$PKG_DIR"
    echo "generate-acceptance-package: failed to build acceptance.json" >&2
    exit 1
  }

# ---- Atomic move (publish) ----
mv "$ACCEPT_JSON.tmp" "$ACCEPT_JSON"

# ---- Force-replace runtime-manifest entries for both files ----
# runtime_register is idempotent (skips if path already bound). For changed
# content, we must explicitly strip the old line(s) and append the fresh
# entry, all under the runtime-manifest lock so concurrent writers cannot
# interleave.
runtime_replace() {
  local rel="$1" kind="$2"
  local f="$ROOT_DIR/$rel" mf
  if [ ! -f "$f" ]; then
    echo "generate-acceptance-package: runtime_replace: missing file $rel" >&2
    return 1
  fi
  local h sz
  h="$(sha256_of "$f")" || return 1
  sz="$(wc -c < "$f" | tr -d ' \t\r')"
  [ -n "$sz" ] || sz=0
  mf="$(runtime_manifest_path "$ROOT_DIR")"
  mkdir -p "$(dirname "$mf")"
  # The runtime-manifest lock is the same lock used by all registry writers.
  _runtime_acquire "$ROOT_DIR" || return 1
  local lock_rc=0
  {
    # Bootstrap registry (genesis) if absent
    if [ ! -f "$mf" ]; then
      if ! _runtime_init_registry "$ROOT_DIR" "$mf"; then
        lock_rc=1
      fi
    elif ! head -1 "$mf" 2>/dev/null | jq -e 'has("genesis")' >/dev/null 2>&1; then
      if ! _runtime_prepend_genesis "$ROOT_DIR" "$mf"; then
        lock_rc=1
      fi
    fi
    # Strip any existing entries for this path (preserve genesis + everything else).
    # jq reads each NDJSON object as a separate input.  Filter the input
    # object itself; `.[]` would instead emit that object's scalar values and
    # corrupt the registry into a sequence of strings/numbers.
    if [ "$lock_rc" -eq 0 ]; then
      local tmp="${mf}.replace.$$"
      if ! jq -c --arg p "$rel" 'select((.path? // "") != $p)' "$mf" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        lock_rc=1
      elif ! mv "$tmp" "$mf" 2>/dev/null; then
        rm -f "$tmp"
        lock_rc=1
      fi
    fi
    # Append the fresh entry
    if [ "$lock_rc" -eq 0 ]; then
      local tmp="${mf}.tmp.$$"
      if ! jq -cn --arg p "$rel" --arg k "$kind" --arg h "$h" --argjson s "$sz" \
          '{path:$p, kind:$k, sha256:$h, size:$s}' > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        lock_rc=1
      elif ! (cat "$mf" 2>/dev/null; cat "$tmp") > "${mf}.new.$$" 2>/dev/null; then
        rm -f "$tmp" "${mf}.new.$$"
        lock_rc=1
      elif ! mv "${mf}.new.$$" "$mf" 2>/dev/null; then
        rm -f "$tmp" "${mf}.new.$$"
        lock_rc=1
      else
        rm -f "$tmp"
      fi
    fi
  } || lock_rc=1
  _runtime_release "$ROOT_DIR" || true
  return "$lock_rc"
}

RUNTIME_MANIFEST_GENESIS="$HEAD_OID" \
  runtime_replace ".harness/acceptance/$HEAD_OID/acceptance.json" "acceptance" || {
    echo "generate-acceptance-package: runtime_replace failed for acceptance.json" >&2
    rm -rf "$PKG_DIR"
    exit 1
  }
RUNTIME_MANIFEST_GENESIS="$HEAD_OID" \
  runtime_replace ".harness/acceptance/$HEAD_OID/A-G.log" "log" || {
    echo "generate-acceptance-package: runtime_replace failed for A-G.log" >&2
    rm -rf "$PKG_DIR"
    exit 1
  }

echo "acceptance package written to $PKG_DIR"
echo "  acceptance.json sha256: $(sha256_of "$ACCEPT_JSON")"
echo "  A-G.log sha256:         $A_G_SHA"
echo "  bound to RUN_ID:        $RUN_ID"
echo "  bound to HEAD_OID:      $HEAD_OID"
exit 0
