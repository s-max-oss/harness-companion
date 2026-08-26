#!/bin/bash
# scripts/acceptance/generate-acceptance-package.sh
#
# Build the current-HEAD acceptance package at
#   .harness/acceptance/<HEAD>/acceptance.json
#   .harness/acceptance/<HEAD>/A-G.log
# binding the canonical run's NDJSON / full-suite.log / maintenance verdict /
# fresh Reviewer verdict / migration record by SHA-256, and append-registering
# BOTH package files in runtime-manifest with their exact on-disk hashes.
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
#   append runtime-manifest entries" window runs under a registry
#   lock on .harness/acceptance/.lock/pkg-write. Two concurrent invocations
#   serialize; partial state from a crashed run is recoverable via the lock's
#   stale-recovery matrix.
#
# Atomic publish:
#   acceptance.json is written to <pkg>/acceptance.json.tmp then mv'd to
#   <pkg>/acceptance.json (POSIX-atomic on the same filesystem).
#   runtime-manifest.jsonl receives both new entries through one validated
#   tmp+mv transaction under the registry lock and dedicated index anchor.
#
# Required env (single input):
#   CANONICAL_NDJSON — absolute path to canonical run's .ndjson (must end in
#                      run_completed with overall_result=passed for the
#                      RUN_ID recorded in run_started)
#
# Exit 0 on success (all fail-closed checks pass + both files written and
# registered in runtime-manifest); non-zero on any failure (no ambiguous
# package, no swallowed error, lock always released).

set -u
SCRIPT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Resolve through Git, then normalize to the MSYS spelling used by the current
# canonical runner. This makes D:/..., /d/..., and caller-relative inputs bind
# to one authoritative project_root string on Windows.
ROOT_DIR="$(git -C "$SCRIPT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "generate-acceptance-package: cannot determine canonical repository root" >&2
  exit 1
}
if command -v cygpath >/dev/null 2>&1; then
  ROOT_DIR="$(cygpath -u "$ROOT_DIR" 2>/dev/null || printf '%s' "$ROOT_DIR")"
fi
ACCEPT_BASE="$ROOT_DIR/.harness/acceptance"
PKG_LOCK_DIR="$ROOT_DIR/.harness/acceptance/.lock/pkg-write"
MAINT_SOURCE_LOCK_DIR="$ROOT_DIR/.harness/.registry.lock/verdict-maintenance-F-MAINT-01"
REVIEWER_SOURCE_LOCK_DIR="$ROOT_DIR/.harness/.registry.lock/verdict-reviewer-F-MAINT-01"

# Source lock + runtime-manifest libs early so we can use acquire_lock and
# runtime-manifest helpers anywhere in the script.
# shellcheck source=../../core/lib/lock-registry.sh
. "$ROOT_DIR/core/lib/lock-registry.sh"
# shellcheck source=../../core/lib/runtime-manifest.sh
. "$ROOT_DIR/core/lib/runtime-manifest.sh"
# shellcheck source=../../core/lib/validate-run-log.sh
. "$ROOT_DIR/core/lib/validate-run-log.sh"
# shellcheck source=validate-acceptance-package.sh
. "$ROOT_DIR/scripts/acceptance/validate-acceptance-package.sh"

# ---- Single required input ----
: "${CANONICAL_NDJSON:?CANONICAL_NDJSON is required (absolute path to canonical NDJSON)}"
if command -v cygpath >/dev/null 2>&1; then
  CANONICAL_NDJSON="$(cygpath -u "$CANONICAL_NDJSON" 2>/dev/null || printf '%s' "$CANONICAL_NDJSON")"
fi
if [ ! -f "$CANONICAL_NDJSON" ]; then
  echo "generate-acceptance-package: CANONICAL_NDJSON does not exist: $CANONICAL_NDJSON" >&2
  exit 1
fi

# ---- Helper: portable sha256 of a file's bytes ----
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}
utc_epoch() {
  date -u -d "$1" +%s 2>/dev/null && return 0
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}
pending_marker_matches() {
  local marker="$1" expected="$2" size
  [ ! -L "$marker" ] && [ -f "$marker" ] || return 1
  size="$(wc -c < "$marker" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ "$size" = "$((${#expected} + 1))" ] || return 1
  [ "$(cat "$marker" 2>/dev/null)" = "$expected" ] || return 1
  [ "$(tail -c 1 "$marker" 2>/dev/null | od -An -tuC | tr -d '[:space:]')" = "10" ]
}

# release_lock rc=8 means ownership was already removed atomically and only
# token-private filesystem cleanup failed. The protected transaction is
# committed and a successor may already own the shared lock, so callers must
# never report rollback or attempt to undo committed bytes for rc=8.
release_committed_lock() {
  local lock_dir="$1" token="$2" label="${3:-lock}" rc
  release_lock "$lock_dir" "$token"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    8)
      echo "generate-acceptance-package: $label logically released; private cleanup remains" >&2
      return 0
      ;;
    *) return "$rc" ;;
  esac
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
if ! printf '%s' "$HEAD_OID" | grep -qE '^([0-9a-f]{40}|[0-9a-f]{64})$'; then
  echo "generate-acceptance-package: HEAD_OID must be a full git object id: $HEAD_OID" >&2
  exit 1
fi

# Recover an interrupted publication before consulting volatile Reviewer
# freshness.  Recovery itself is strict: a manifest-committed package is only
# finalized after the complete current-HEAD validator passes; an uncommitted
# marked package is rolled back.
EARLY_PKG="$ACCEPT_BASE/$HEAD_OID"
EARLY_PENDING="$EARLY_PKG/.publish-pending"
if [ -e "$EARLY_PENDING" ] || [ -L "$EARLY_PENDING" ]; then
  if [ -L "$EARLY_PKG" ] || [ ! -d "$EARLY_PKG" ] \
     || ! pending_marker_matches "$EARLY_PENDING" "$HEAD_OID"; then
    echo "generate-acceptance-package: invalid pending package marker; refusing recovery" >&2
    exit 1
  fi
  acquire_lock "$PKG_LOCK_DIR" 30 >/dev/null || { echo "cannot lock pending package recovery" >&2; exit 1; }
  early_token="${LOCK_REGISTRY_TOKEN:-}"
  acquire_lock "$MAINT_SOURCE_LOCK_DIR" 30 >/dev/null || {
    release_lock "$PKG_LOCK_DIR" "$early_token" >/dev/null 2>&1 || true
    echo "cannot lock maintenance source for pending recovery" >&2
    exit 1
  }
  early_maint_token="${LOCK_REGISTRY_TOKEN:-}"
  acquire_lock "$REVIEWER_SOURCE_LOCK_DIR" 30 >/dev/null || {
    release_lock "$MAINT_SOURCE_LOCK_DIR" "$early_maint_token" >/dev/null 2>&1 || true
    release_lock "$PKG_LOCK_DIR" "$early_token" >/dev/null 2>&1 || true
    echo "cannot lock Reviewer source for pending recovery" >&2
    exit 1
  }
  early_reviewer_token="${LOCK_REGISTRY_TOKEN:-}"
  early_release_sources() {
    local source_rc=0
    release_committed_lock "$REVIEWER_SOURCE_LOCK_DIR" "$early_reviewer_token" "Reviewer source lock" || source_rc=1
    release_committed_lock "$MAINT_SOURCE_LOCK_DIR" "$early_maint_token" "maintenance source lock" || source_rc=1
    return "$source_rc"
  }
  _runtime_acquire "$ROOT_DIR" || {
    early_release_sources || true
    release_lock "$PKG_LOCK_DIR" "$early_token" >/dev/null 2>&1 || true
    echo "cannot lock runtime-manifest recovery" >&2
    exit 1
  }
  early_runtime_token="${LOCK_REGISTRY_TOKEN:-}"
  early_mf="$(runtime_manifest_path "$ROOT_DIR")"
  if ! _runtime_verify_registry_anchor "$ROOT_DIR" "$early_mf"; then
    if ! _runtime_restore_registry_from_anchor "$ROOT_DIR" "$early_mf"; then
      release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$early_runtime_token" >/dev/null 2>&1 || true
      early_release_sources
      release_lock "$PKG_LOCK_DIR" "$early_token" >/dev/null 2>&1 || true
      echo "generate-acceptance-package: pending recovery cannot restore trusted runtime registry" >&2
      exit 1
    fi
  fi
  early_a=".harness/acceptance/$HEAD_OID/acceptance.json"
  early_g=".harness/acceptance/$HEAD_OID/A-G.log"
  early_n="$(jq -rs --arg a "$early_a" --arg g "$early_g" '[.[] | select(.path? == $a or .path? == $g)] | length' "$early_mf" 2>/dev/null || echo -1)"
  if [ "$early_n" = "2" ]; then
    early_acc_actual="$(sha256_of "$EARLY_PKG/acceptance.json" 2>/dev/null || true)"
    early_ag_actual="$(sha256_of "$EARLY_PKG/A-G.log" 2>/dev/null || true)"
    early_acc_bound="$(jq -rs --arg p "$early_a" '.[] | select(.path? == $p) | .sha256' "$early_mf" 2>/dev/null)"
    early_ag_bound="$(jq -rs --arg p "$early_g" '.[] | select(.path? == $p) | .sha256' "$early_mf" 2>/dev/null)"
    if [ -z "$early_acc_actual" ] || [ "$early_acc_actual" != "$early_acc_bound" ] \
       || [ -z "$early_ag_actual" ] || [ "$early_ag_actual" != "$early_ag_bound" ]; then
      release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$early_runtime_token" >/dev/null 2>&1 || true
      early_release_sources
      release_lock "$PKG_LOCK_DIR" "$early_token" >/dev/null 2>&1 || true
      echo "generate-acceptance-package: pending package does not match manifest bindings" >&2
      exit 1
    fi
    if ! validate_acceptance_package "$EARLY_PKG" --project-dir "$ROOT_DIR" --committed-recovery >/dev/null 2>&1; then
      release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$early_runtime_token" >/dev/null 2>&1 || true
      early_release_sources
      release_lock "$PKG_LOCK_DIR" "$early_token" >/dev/null 2>&1 || true
      echo "generate-acceptance-package: committed pending package fails full validation" >&2
      exit 1
    fi
    release_committed_lock "$(runtime_lock_dir "$ROOT_DIR")" "$early_runtime_token" "runtime recovery lock" || exit 1
    rm -f "$EARLY_PENDING" || exit 1
    early_group_rc=0
    release_committed_lock "$REVIEWER_SOURCE_LOCK_DIR" "$early_reviewer_token" "Reviewer source lock" || early_group_rc=1
    release_committed_lock "$MAINT_SOURCE_LOCK_DIR" "$early_maint_token" "maintenance source lock" || early_group_rc=1
    release_committed_lock "$PKG_LOCK_DIR" "$early_token" "package lock" || early_group_rc=1
    [ "$early_group_rc" -eq 0 ] || exit 1
    echo "acceptance package recovery finalized at $EARLY_PKG"
    exit 0
  elif [ "$early_n" = "0" ]; then
    rm -rf -- "$EARLY_PKG" || {
      release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$early_runtime_token" >/dev/null 2>&1 || true
      early_release_sources
      release_lock "$PKG_LOCK_DIR" "$early_token" >/dev/null 2>&1 || true
      exit 1
    }
    release_committed_lock "$(runtime_lock_dir "$ROOT_DIR")" "$early_runtime_token" "runtime recovery lock" || exit 1
    early_group_rc=0
    early_release_sources || early_group_rc=1
    release_committed_lock "$PKG_LOCK_DIR" "$early_token" "package lock" || early_group_rc=1
    [ "$early_group_rc" -eq 0 ] || exit 1
  else
    release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$early_runtime_token" >/dev/null 2>&1 || true
    early_release_sources
    release_lock "$PKG_LOCK_DIR" "$early_token" >/dev/null 2>&1 || true
    echo "generate-acceptance-package: ambiguous pending registry state" >&2
    exit 1
  fi
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
  ci=0
  while [ "$ci" -lt "$mig_n" ]; do
    ci_path="$(jq -r ".changes[$ci].path" "$mig" 2>/dev/null)"
    ci_new="$(jq -r ".changes[$ci].new_sha256" "$mig" 2>/dev/null)"
    ci_actual="$(sha256_of "$ROOT_DIR/$ci_path" 2>/dev/null || true)"
    if [ "$ci_new" != "$ci_actual" ]; then
      mig_active=0
      break
    fi
    ci=$((ci + 1))
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
VR_EPOCH="$(utc_epoch "$VR_RECORDED_AT" 2>/dev/null || echo 0)"
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
PKG_LOCK_TOKEN="${LOCK_REGISTRY_TOKEN:-}"
if ! acquire_lock "$MAINT_SOURCE_LOCK_DIR" 30 >/dev/null; then
  release_lock "$PKG_LOCK_DIR" "$PKG_LOCK_TOKEN" >/dev/null 2>&1 || true
  echo "generate-acceptance-package: failed to lock maintenance verdict source" >&2
  exit 1
fi
MAINT_SOURCE_LOCK_TOKEN="${LOCK_REGISTRY_TOKEN:-}"
if ! acquire_lock "$REVIEWER_SOURCE_LOCK_DIR" 30 >/dev/null; then
  release_lock "$MAINT_SOURCE_LOCK_DIR" "$MAINT_SOURCE_LOCK_TOKEN" >/dev/null 2>&1 || true
  release_lock "$PKG_LOCK_DIR" "$PKG_LOCK_TOKEN" >/dev/null 2>&1 || true
  echo "generate-acceptance-package: failed to lock Reviewer verdict source" >&2
  exit 1
fi
REVIEWER_SOURCE_LOCK_TOKEN="${LOCK_REGISTRY_TOKEN:-}"
STAGE_DIR=""
cleanup_package_attempt() {
  if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf -- "$STAGE_DIR" 2>/dev/null || true
  fi
  release_lock "$REVIEWER_SOURCE_LOCK_DIR" "$REVIEWER_SOURCE_LOCK_TOKEN" >/dev/null 2>&1 || true
  release_lock "$MAINT_SOURCE_LOCK_DIR" "$MAINT_SOURCE_LOCK_TOKEN" >/dev/null 2>&1 || true
  release_lock "$PKG_LOCK_DIR" "$PKG_LOCK_TOKEN" >/dev/null 2>&1 || true
}
trap cleanup_package_attempt EXIT

# ---- Crash recovery / idempotency ------------------------------------------
PKG_DIR="$ACCEPT_BASE/$HEAD_OID"
PENDING="$PKG_DIR/.publish-pending"
REL_ACC=".harness/acceptance/$HEAD_OID/acceptance.json"
REL_AG=".harness/acceptance/$HEAD_OID/A-G.log"
# Recover a crash that happened before the stage directory was published.
# Only generator-created, HEAD-bound marked directories are eligible.
for stale_stage in "$ACCEPT_BASE"/.stage-"$HEAD_OID"-*; do
  [ -d "$stale_stage" ] || continue
  if [ -L "$stale_stage" ] || ! pending_marker_matches "$stale_stage/.publish-pending" "$HEAD_OID"; then
    echo "generate-acceptance-package: unrecognized stage directory requires audit: $stale_stage" >&2
    exit 1
  fi
  rm -rf -- "$stale_stage" || { echo "cannot recover stale stage: $stale_stage" >&2; exit 1; }
done
if [ -e "$PKG_DIR" ] || [ -L "$PKG_DIR" ]; then
  if [ -L "$PKG_DIR" ] || [ ! -d "$PKG_DIR" ] \
     || ! pending_marker_matches "$PENDING" "$HEAD_OID"; then
    echo "generate-acceptance-package: package already exists; refusing ambiguous overwrite: $PKG_DIR" >&2
    exit 1
  fi
  # A crash can happen only on one side of the package/manifest commit.  If
  # both final bindings are already present, finish by removing the marker.
  # If neither is present, remove only this marked partial package and retry.
  mf_recover="$(runtime_manifest_path "$ROOT_DIR")"
  _runtime_acquire "$ROOT_DIR" || { echo "cannot lock runtime-manifest recovery" >&2; exit 1; }
  recover_runtime_token="${LOCK_REGISTRY_TOKEN:-}"
  if ! _runtime_verify_registry_anchor "$ROOT_DIR" "$mf_recover"; then
    if ! _runtime_restore_registry_from_anchor "$ROOT_DIR" "$mf_recover"; then
      release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$recover_runtime_token" >/dev/null 2>&1 || true
      echo "generate-acceptance-package: cannot restore trusted runtime registry" >&2
      exit 1
    fi
  fi
  recover_count="$(jq -rs --arg a "$REL_ACC" --arg g "$REL_AG" \
    '[.[] | select(.path? == $a or .path? == $g)] | length' "$mf_recover" 2>/dev/null || echo -1)"
  if [ "$recover_count" = "2" ]; then
    recover_acc_sha="$(sha256_of "$PKG_DIR/acceptance.json" 2>/dev/null || true)"
    recover_ag_sha="$(sha256_of "$PKG_DIR/A-G.log" 2>/dev/null || true)"
    bound_acc_sha="$(jq -rs --arg p "$REL_ACC" '.[] | select(.path? == $p) | .sha256' "$mf_recover" 2>/dev/null)"
    bound_ag_sha="$(jq -rs --arg p "$REL_AG" '.[] | select(.path? == $p) | .sha256' "$mf_recover" 2>/dev/null)"
    if [ -z "$recover_acc_sha" ] || [ "$recover_acc_sha" != "$bound_acc_sha" ] \
       || [ -z "$recover_ag_sha" ] || [ "$recover_ag_sha" != "$bound_ag_sha" ]; then
      echo "generate-acceptance-package: pending package bytes do not match committed registry" >&2
      release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$recover_runtime_token" >/dev/null 2>&1 || true
      exit 1
    fi
    if ! validate_acceptance_package "$PKG_DIR" --project-dir "$ROOT_DIR" --committed-recovery >/dev/null 2>&1; then
      echo "generate-acceptance-package: pending package fails full current-HEAD validation" >&2
      release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$recover_runtime_token" >/dev/null 2>&1 || true
      exit 1
    fi
    release_committed_lock "$(runtime_lock_dir "$ROOT_DIR")" "$recover_runtime_token" "runtime recovery lock" || exit 1
    if ! rm -f "$PENDING"; then
      echo "generate-acceptance-package: cannot finalize recovered package" >&2
      exit 1
    fi
    recover_group_rc=0
    release_committed_lock "$REVIEWER_SOURCE_LOCK_DIR" "$REVIEWER_SOURCE_LOCK_TOKEN" "Reviewer source lock" || recover_group_rc=1
    release_committed_lock "$MAINT_SOURCE_LOCK_DIR" "$MAINT_SOURCE_LOCK_TOKEN" "maintenance source lock" || recover_group_rc=1
    release_committed_lock "$PKG_LOCK_DIR" "$PKG_LOCK_TOKEN" "package lock" || recover_group_rc=1
    [ "$recover_group_rc" -eq 0 ] || exit 1
    trap - EXIT
    echo "acceptance package recovery finalized at $PKG_DIR"
    exit 0
  elif [ "$recover_count" = "0" ]; then
    rm -rf -- "$PKG_DIR" || {
      release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$recover_runtime_token" >/dev/null 2>&1 || true
      echo "generate-acceptance-package: cannot remove marked partial package" >&2
      exit 1
    }
    release_committed_lock "$(runtime_lock_dir "$ROOT_DIR")" "$recover_runtime_token" "runtime recovery lock" || exit 1
  else
    release_lock "$(runtime_lock_dir "$ROOT_DIR")" "$recover_runtime_token" >/dev/null 2>&1 || true
    echo "generate-acceptance-package: ambiguous partial publication; manual audit required" >&2
    exit 1
  fi
fi

# ---- Compute SHA-256 helpers (after lock; bytes are stable now) ----
NDJSON_SHA="$(sha256_of "$CANONICAL_NDJSON")"
VERDICT_SHA="$(sha256_of "$MAINTENANCE_VERDICT")"
REVIEWER_VERDICT_SHA="$(sha256_of "$REVIEWER_VERDICT")"
MIGRATION_SHA="$(sha256_of "$MIGRATION_RECORD")"

# ---- Formal live DWM attestation (pre-publication) --------------------------
# Capture a real rc=0 DWM execution in the package itself. This run happens
# immediately before package publication; the current-head checker performs a
# second live DWM after all package files have been registered. The two-step
# design is intentionally non-circular: A-G.log can bind the first transcript,
# while the post-publication gate verifies the final state that includes it.
DWM_COMMAND="bash tools/snapshot-dirty-worktree.sh check tests/fixtures/dirty-worktree-manifest.jsonl <project-root>"
DWM_RESULT="$(bash "$ROOT_DIR/tools/snapshot-dirty-worktree.sh" check \
  "tests/fixtures/dirty-worktree-manifest.jsonl" "$ROOT_DIR" 2>&1)"
DWM_RC=$?
if [ "$DWM_RC" -ne 0 ] || ! printf '%s' "$DWM_RESULT" | jq -e '.valid == true' >/dev/null 2>&1; then
  echo "generate-acceptance-package: formal pre-publication DWM failed (rc=$DWM_RC)" >&2
  printf '%s\n' "$DWM_RESULT" >&2
  exit 1
fi

# Everything is built in a sibling stage directory.  The final directory is
# published by one atomic rename only after all bytes and both registry entries
# have been prepared.
STAGE_DIR="$ACCEPT_BASE/.stage-${HEAD_OID}-$$"
case "$STAGE_DIR" in "$ACCEPT_BASE"/.stage-*) ;; *) echo "unsafe stage path" >&2; exit 1;; esac
mkdir -p "$STAGE_DIR" || exit 1
STAGE_AG="$STAGE_DIR/A-G.log"
STAGE_ACC="$STAGE_DIR/acceptance.json"
FINAL_AG="$PKG_DIR/A-G.log"
FINAL_ACC="$PKG_DIR/acceptance.json"
printf '%s\n' "$HEAD_OID" > "$STAGE_DIR/.publish-pending" || exit 1

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
  echo "Formal DWM command:  $DWM_COMMAND"
  echo "Formal DWM exit:     $DWM_RC"
  echo "Generated at:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "============================================================"
  echo ""
  echo "----- BEGIN canonical full-suite log -----"
} > "$STAGE_AG"
cat "$FULL_SUITE_LOG" >> "$STAGE_AG"
echo "" >> "$STAGE_AG"
echo "----- END canonical full-suite log -----" >> "$STAGE_AG"
echo "" >> "$STAGE_AG"
echo "----- BEGIN formal pre-publication DWM transcript -----" >> "$STAGE_AG"
printf '%s\n' "$DWM_RESULT" >> "$STAGE_AG"
echo "----- END formal pre-publication DWM transcript -----" >> "$STAGE_AG"

A_G_SHA="$(sha256_of "$STAGE_AG")"

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
  --arg a_g_log_path "$FINAL_AG" \
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
   }' > "$STAGE_ACC" || {
    rm -rf -- "$STAGE_DIR"
    echo "generate-acceptance-package: failed to build acceptance.json" >&2
    exit 1
  }

# ---- One registry transaction + one directory publication -----------------
MF="$(runtime_manifest_path "$ROOT_DIR")"
RUNTIME_MANIFEST_GENESIS="$HEAD_OID" _runtime_acquire "$ROOT_DIR" || {
  rm -rf -- "$STAGE_DIR"; echo "cannot acquire runtime-manifest lock" >&2; exit 1;
}
RUNTIME_TOKEN="${LOCK_REGISTRY_TOKEN:-}"
TX_RC=0
ROLLBACK_FAILED=0
MF_BACKUP=""
if [ "$TX_RC" -eq 0 ]; then
  MF_BACKUP="$(_runtime_backup_path "$ROOT_DIR")" || TX_RC=1
fi
if [ "$TX_RC" -eq 0 ] && ! cp "$MF" "$MF_BACKUP" 2>/dev/null; then TX_RC=1; fi
if [ "$TX_RC" -eq 0 ] && ! _runtime_verify_registry_anchor "$ROOT_DIR" "$MF"; then
  echo "generate-acceptance-package: runtime registry differs from dedicated index anchor" >&2
  TX_RC=1
fi
RUNTIME_MANIFEST_GENESIS="$HEAD_OID" _runtime_validate_registry "$ROOT_DIR" "$MF" || TX_RC=1
# Re-read every mutable/authoritative source after acquiring the runtime lock.
# Hashes and latest-record checks performed before this lock are only
# preliminary; a concurrent verdict append or artifact replacement must abort
# publication rather than bind a mixture of pre- and post-append bytes.
if [ "$TX_RC" -eq 0 ]; then
  CURRENT_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
  CURRENT_NDJSON_SHA="$(sha256_of "$CANONICAL_NDJSON" 2>/dev/null || true)"
  CURRENT_LOG_SHA="$(sha256_of "$FULL_SUITE_LOG" 2>/dev/null || true)"
  CURRENT_MAINT_SHA="$(sha256_of "$MAINTENANCE_VERDICT" 2>/dev/null || true)"
  CURRENT_REVIEWER_SHA="$(sha256_of "$REVIEWER_VERDICT" 2>/dev/null || true)"
  CURRENT_MIGRATION_SHA="$(sha256_of "$MIGRATION_RECORD" 2>/dev/null || true)"
  CURRENT_CONFIG_SHA="$(sha256_of "$ROOT_DIR/.harness/config.json" 2>/dev/null || true)"
  if [ "$CURRENT_HEAD" != "$HEAD_OID" ] \
     || [ "$CURRENT_NDJSON_SHA" != "$NDJSON_SHA" ] \
     || [ "$CURRENT_LOG_SHA" != "$FULL_SUITE_LOG_SHA" ] \
     || [ "$CURRENT_MAINT_SHA" != "$VERDICT_SHA" ] \
     || [ "$CURRENT_REVIEWER_SHA" != "$REVIEWER_VERDICT_SHA" ] \
     || [ "$CURRENT_MIGRATION_SHA" != "$MIGRATION_SHA" ] \
     || [ "$CURRENT_CONFIG_SHA" != "$EXPECTED_CONFIG_SHA" ] \
     || [ "$(tail -1 "$MAINTENANCE_VERDICT" 2>/dev/null)" != "$LAST_MAINT" ] \
     || [ "$(tail -1 "$REVIEWER_VERDICT" 2>/dev/null)" != "$LAST_VERDICT" ]; then
    echo "generate-acceptance-package: authoritative inputs changed during package construction" >&2
    TX_RC=1
  fi
fi
if [ "$TX_RC" -eq 0 ] && jq -e -s --arg a "$REL_ACC" --arg g "$REL_AG" \
    'any(.[]; .path? == $a or .path? == $g)' "$MF" >/dev/null 2>&1; then
  echo "generate-acceptance-package: target paths already registered" >&2
  TX_RC=1
fi
ACC_SHA="$(sha256_of "$STAGE_ACC")" || TX_RC=1
ACC_SIZE="$(wc -c < "$STAGE_ACC" | tr -d ' \t\r')"
AG_SIZE="$(wc -c < "$STAGE_AG" | tr -d ' \t\r')"
MF_NEW="${MF}.package.$$"
if [ "$TX_RC" -eq 0 ] && ! {
  cat "$MF" &&
  jq -cn --arg p "$REL_ACC" --arg h "$ACC_SHA" --argjson s "$ACC_SIZE" '{path:$p,kind:"acceptance",sha256:$h,size:$s}' &&
  jq -cn --arg p "$REL_AG" --arg h "$A_G_SHA" --argjson s "$AG_SIZE" '{path:$p,kind:"log",sha256:$h,size:$s}';
} > "$MF_NEW" 2>/dev/null; then TX_RC=1; fi
if [ "$TX_RC" -eq 0 ] && ! RUNTIME_MANIFEST_GENESIS="$HEAD_OID" \
    _runtime_validate_registry "$ROOT_DIR" "$MF_NEW"; then TX_RC=1; fi
if [ "$TX_RC" -eq 0 ] && ! mv "$STAGE_DIR" "$PKG_DIR" 2>/dev/null; then TX_RC=1; fi
if [ "$TX_RC" -eq 0 ] && ! mv "$MF_NEW" "$MF" 2>/dev/null; then
  # Manifest is still the original. Roll package publication back to its
  # marked stage; a later run can recover it deterministically.
  mv "$PKG_DIR" "$STAGE_DIR" 2>/dev/null || true
  TX_RC=1
fi
if [ "$TX_RC" -eq 0 ] && ! _runtime_anchor_registry "$ROOT_DIR" "$MF"; then
  echo "generate-acceptance-package: failed to anchor published runtime registry; rolling back" >&2
  if [ -n "$MF_BACKUP" ] && cp "$MF_BACKUP" "$MF" 2>/dev/null \
     && _runtime_anchor_registry "$ROOT_DIR" "$MF"; then
    mv "$PKG_DIR" "$STAGE_DIR" 2>/dev/null || true
  else
    echo "generate-acceptance-package: registry rollback failed; pending marker retained" >&2
    ROLLBACK_FAILED=1
  fi
  TX_RC=1
fi
# Validate the actually published bytes while the registry transaction remains
# locked.  This catches a source mutation or binding discrepancy that occurs
# after staging but before the commit marker can be finalized.
if [ "$TX_RC" -eq 0 ] && ! validate_acceptance_package "$PKG_DIR" --project-dir "$ROOT_DIR" >/dev/null 2>&1; then
  echo "generate-acceptance-package: published package failed final validation; rolling back" >&2
  if [ -n "$MF_BACKUP" ] && cp "$MF_BACKUP" "$MF" 2>/dev/null \
     && _runtime_anchor_registry "$ROOT_DIR" "$MF"; then
    mv "$PKG_DIR" "$STAGE_DIR" 2>/dev/null || true
  else
    echo "generate-acceptance-package: final-validation rollback failed; pending marker retained" >&2
    ROLLBACK_FAILED=1
  fi
  TX_RC=1
fi
rm -f "$MF_NEW"
if ! release_committed_lock "$(runtime_lock_dir "$ROOT_DIR")" "$RUNTIME_TOKEN" "runtime-manifest lock"; then TX_RC=1; fi
if [ "$ROLLBACK_FAILED" = "0" ]; then
  rm -f "$MF_BACKUP"
elif [ -n "$MF_BACKUP" ]; then
  echo "generate-acceptance-package: retained registry recovery backup at $MF_BACKUP" >&2
fi
if [ "$TX_RC" -ne 0 ]; then
  [ -d "$STAGE_DIR" ] && rm -rf -- "$STAGE_DIR"
  echo "generate-acceptance-package: fail-atomic publication failed" >&2
  exit 1
fi

# The marker is the publication commit bit. Remove it while both authoritative
# verdict-source locks and the package lock remain held, after the runtime
# transaction is durable. This leaves no window for a concurrent verdict append
# to stale the just-validated hashes before publication commits.
if ! rm -f "$PENDING"; then
  echo "generate-acceptance-package: failed to finalize package marker" >&2
  exit 1
fi
FINAL_RELEASE_RC=0
release_committed_lock "$REVIEWER_SOURCE_LOCK_DIR" "$REVIEWER_SOURCE_LOCK_TOKEN" "Reviewer source lock" || FINAL_RELEASE_RC=1
release_committed_lock "$MAINT_SOURCE_LOCK_DIR" "$MAINT_SOURCE_LOCK_TOKEN" "maintenance source lock" || FINAL_RELEASE_RC=1
release_committed_lock "$PKG_LOCK_DIR" "$PKG_LOCK_TOKEN" "package lock" || FINAL_RELEASE_RC=1
if [ "$FINAL_RELEASE_RC" -ne 0 ]; then
  echo "generate-acceptance-package: one or more publication locks were not released" >&2
  exit 1
fi
trap - EXIT

echo "acceptance package written to $PKG_DIR"
echo "  acceptance.json sha256: $(sha256_of "$FINAL_ACC")"
echo "  A-G.log sha256:         $A_G_SHA"
echo "  bound to RUN_ID:        $RUN_ID"
echo "  bound to HEAD_OID:      $HEAD_OID"
exit 0
