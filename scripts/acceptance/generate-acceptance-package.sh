#!/bin/bash
# scripts/acceptance/generate-acceptance-package.sh
#
# Build the current-HEAD acceptance package at
#   .harness/acceptance/<HEAD>/acceptance.json
#   .harness/acceptance/<HEAD>/A-G.log
# bind the canonical run's NDJSON / full-suite.log / maintenance verdict /
# fresh Reviewer verdict / migration record by SHA-256, and atomically
# register BOTH files in runtime-manifest.
#
# The package is committed/HEAD-scoped: directory name IS the full HEAD OID.
# Re-running for the same HEAD is idempotent; running for a different HEAD
# writes a sibling directory and never mutates an existing one.
#
# Required env (all must be valid; this script is fail-closed):
#   HEAD_OID                — 40-hex git OID (the fix-complete commit) — must
#                              equal `git rev-parse HEAD` at run time
#   RUN_ID                  — canonical full-suite run_id — must equal
#                              run_started event in canonical NDJSON
#   DURATION_MS             — integer milliseconds (no approximations)
#   EFFECTIVE_TIMEOUT       — integer seconds recorded in NDJSON command_completed
#   CONFIG_SHA256           — sha256:<64hex> (full 64 hex chars required)
#   CANONICAL_NDJSON        — absolute path to canonical .ndjson (must end
#                              in run_completed with overall_result=passed;
#                              validate-run-log.sh accepts run_completed/#
#                              run_failed/run_aborted as terminal events;
#                              run_completed overall_result=passed is the
#                              canonical passing terminal for a clean run)
#   FULL_SUITE_LOG          — absolute path to canonical full-suite.log
#   MAINTENANCE_VERDICT     — absolute path to .harness/reviews/maintenance/F-MAINT-01.jsonl
#   MIGRATION_RECORD        — absolute path to docs/migrations/2026-08-17-rc6-final-contract-migration.json
#   REVIEWER_VERDICT        — absolute path to a fresh Reviewer verdict file
#                              whose head_sha == HEAD_OID and whose
#                              recorded_at is within the last 24h
# Usage:
#   bash scripts/acceptance/generate-acceptance-package.sh
#
# Exit 0 on success (all fail-closed checks pass + both files written and
# atomically registered); non-zero on any failure (no partial package, no
# swallowed error).

set -u
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ACCEPT_BASE="$ROOT_DIR/.harness/acceptance"

# ---- Validate required env ----
: "${HEAD_OID:?HEAD_OID is required (full 40-hex OID of fix-complete HEAD)}"
: "${RUN_ID:?RUN_ID is required (canonical full-suite run_id)}"
: "${DURATION_MS:?DURATION_MS is required (integer milliseconds)}"
: "${EFFECTIVE_TIMEOUT:?EFFECTIVE_TIMEOUT is required (integer seconds)}"
: "${CONFIG_SHA256:?CONFIG_SHA256 is required (sha256:<64hex>)}"
: "${CANONICAL_NDJSON:?CANONICAL_NDJSON is required (absolute path to canonical NDJSON)}"
: "${FULL_SUITE_LOG:?FULL_SUITE_LOG is required (absolute path to full-suite.log)}"
: "${MAINTENANCE_VERDICT:?MAINTENANCE_VERDICT is required (absolute path to maintenance verdict)}"
: "${MIGRATION_RECORD:?MIGRATION_RECORD is required (absolute path to migration JSON)}"
: "${REVIEWER_VERDICT:?REVIEWER_VERDICT is required (absolute path to fresh Reviewer verdict file)}"

# ---- Fail-closed check 1: HEAD_OID must equal current git HEAD ----
CURRENT_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)" || {
  echo "generate-acceptance-package: cannot determine current HEAD (not a git repo?)" >&2
  exit 1
}
if [ "$HEAD_OID" != "$CURRENT_HEAD" ]; then
  echo "generate-acceptance-package: HEAD_OID mismatch with current git HEAD" >&2
  echo "  HEAD_OID env: $HEAD_OID" >&2
  echo "  current HEAD: $CURRENT_HEAD" >&2
  exit 1
fi

# ---- Fail-closed check 2: HEAD_OID format (40 hex) ----
if ! printf '%s' "$HEAD_OID" | grep -qE '^[0-9a-f]{40}$'; then
  echo "generate-acceptance-package: HEAD_OID must be 40-hex" >&2
  exit 1
fi

# ---- Fail-closed check 3: CONFIG_SHA256 must be exactly sha256:<64hex> ----
if ! printf '%s' "$CONFIG_SHA256" | grep -qE '^sha256:[0-9a-f]{64}$'; then
  echo "generate-acceptance-package: CONFIG_SHA256 must be sha256:<64hex> (full hash, no truncation)" >&2
  echo "  got: $CONFIG_SHA256" >&2
  exit 1
fi

# ---- Fail-closed check 4: CONFIG_SHA256 must match actual .harness/config.json ----
ACTUAL_CONFIG_SHA="$(sha256sum "$ROOT_DIR/.harness/config.json" 2>/dev/null | awk '{print $1}')" || {
  echo "generate-acceptance-package: cannot hash .harness/config.json" >&2
  exit 1
}
EXPECTED_CONFIG_SHA="${CONFIG_SHA256#sha256:}"
if [ "$ACTUAL_CONFIG_SHA" != "$EXPECTED_CONFIG_SHA" ]; then
  echo "generate-acceptance-package: CONFIG_SHA256 does not match current .harness/config.json" >&2
  echo "  expected: sha256:$EXPECTED_CONFIG_SHA" >&2
  echo "  actual:   sha256:$ACTUAL_CONFIG_SHA" >&2
  exit 1
fi

# ---- Fail-closed check 5: all referenced files exist ----
for var in CANONICAL_NDJSON FULL_SUITE_LOG MAINTENANCE_VERDICT MIGRATION_RECORD REVIEWER_VERDICT; do
  f="${!var}"
  if [ ! -f "$f" ]; then
    echo "generate-acceptance-package: $var points at missing file: $f" >&2
    exit 1
  fi
done

# ---- Fail-closed check 6: canonical NDJSON must record a successful run ----
# The canonical NDJSON must contain a run_started event whose run_id matches
# RUN_ID, AND a final terminal event (run_completed overall_result=passed,
# or run_failed) with overall_result=passed. Using a failed run as passing
# evidence is a hard violation. The canonical passing terminal is
# run_completed with overall_result=passed; the legacy names run_passed and
# run_failed are accepted by validate-run-log.sh but no harness-verify.sh
# currently emits run_passed (run_completed is the live event).
if ! grep -q "\"run_id\":\"$RUN_ID\"" "$CANONICAL_NDJSON" 2>/dev/null; then
  echo "generate-acceptance-package: RUN_ID $RUN_ID not found in canonical NDJSON" >&2
  exit 1
fi
FINAL_EVENT="$(grep -E '"event":"run_(passed|completed|failed)"' "$CANONICAL_NDJSON" | tail -1)"
if [ -z "$FINAL_EVENT" ]; then
  echo "generate-acceptance-package: canonical NDJSON has no terminal run_completed/run_failed event" >&2
  exit 1
fi
FINAL_EVENT_KIND="$(printf '%s' "$FINAL_EVENT" | jq -r '.event // empty')"
FINAL_OVERALL="$(printf '%s' "$FINAL_EVENT" | jq -r '.overall_result // empty')"
FINAL_RUN_ID_IN_EVT="$(printf '%s' "$FINAL_EVENT" | jq -r '.run_id // empty')"
# Canonical passing terminal: run_completed overall_result=passed with this
# RUN_ID (the current harness-verify emits run_completed; legacy
# run_passed/run_failed are also recognized by validate-run-log.sh). Any
# other terminal kind / overall_result / run_id is a hard violation.
PASS_TERMINAL_OK=0
if [ "$FINAL_EVENT_KIND" = "run_completed" ] && [ "$FINAL_OVERALL" = "passed" ] && [ "$FINAL_RUN_ID_IN_EVT" = "$RUN_ID" ]; then
  PASS_TERMINAL_OK=1
elif [ "$FINAL_EVENT_KIND" = "run_passed" ] && [ "$FINAL_OVERALL" = "passed" ] && [ "$FINAL_RUN_ID_IN_EVT" = "$RUN_ID" ]; then
  PASS_TERMINAL_OK=1
fi
if [ "$PASS_TERMINAL_OK" != "1" ]; then
  echo "generate-acceptance-package: canonical NDJSON terminal is not a passing terminal for RUN_ID" >&2
  echo "  final event: $FINAL_EVENT_KIND" >&2
  echo "  overall_result: $FINAL_OVERALL" >&2
  echo "  final run_id: $FINAL_RUN_ID_IN_EVT (expected $RUN_ID)" >&2
  exit 1
fi
# also: failed_commands must be 0 in the terminal event
FINAL_FAILED_CMDS="$(printf '%s' "$FINAL_EVENT" | jq -r '.failed_commands // 1')"
if [ "$FINAL_FAILED_CMDS" != "0" ]; then
  echo "generate-acceptance-package: canonical run has failed_commands=$FINAL_FAILED_CMDS (must be 0)" >&2
  exit 1
fi

# ---- Fail-closed check 7: fresh Reviewer verdict must exist and bind to HEAD ----
# The verdict file is a JSONL where the LAST line is the freshest. The
# freshest line must have head_sha == HEAD_OID. recorded_at must be within
# the last 24h of NOW (a stale verdict cannot be used as fresh evidence for a
# new HEAD).
LAST_VERDICT="$(tail -1 "$REVIEWER_VERDICT" 2>/dev/null)" || {
  echo "generate-acceptance-package: REVIEWER_VERDICT file unreadable: $REVIEWER_VERDICT" >&2
  exit 1
}
if [ -z "$LAST_VERDICT" ]; then
  echo "generate-acceptance-package: REVIEWER_VERDICT file is empty" >&2
  exit 1
fi
VR_HEAD="$(printf '%s' "$LAST_VERDICT" | jq -r '.head_sha // empty')"
VR_VERDICT="$(printf '%s' "$LAST_VERDICT" | jq -r '.verdict // empty')"
VR_RUN="$(printf '%s' "$LAST_VERDICT" | jq -r '.run_id // empty')"
VR_RECORDED_AT="$(printf '%s' "$LAST_VERDICT" | jq -r '.recorded_at // empty')"
if [ "$VR_HEAD" != "$HEAD_OID" ]; then
  echo "generate-acceptance-package: fresh Reviewer verdict head_sha != HEAD_OID" >&2
  echo "  freshest verdict head_sha: $VR_HEAD" >&2
  echo "  HEAD_OID:                  $HEAD_OID" >&2
  exit 1
fi
if [ "$VR_VERDICT" != "PASS" ]; then
  echo "generate-acceptance-package: fresh Reviewer verdict is not PASS" >&2
  echo "  verdict: $VR_VERDICT" >&2
  exit 1
fi
if [ "$VR_RUN" != "$RUN_ID" ]; then
  echo "generate-acceptance-package: fresh Reviewer verdict run_id != RUN_ID" >&2
  echo "  verdict run_id: $VR_RUN" >&2
  echo "  RUN_ID:         $RUN_ID" >&2
  exit 1
fi
# recency: 24h window. Use portable date math: parse recorded_at as epoch
# seconds and compare to NOW.
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

# ---- Fail-closed check 8: DURATION_MS / EFFECTIVE_TIMEOUT must be integers ----
if ! printf '%s' "$DURATION_MS" | grep -qE '^[0-9]+$'; then
  echo "generate-acceptance-package: DURATION_MS must be integer (got '$DURATION_MS')" >&2
  exit 1
fi
if ! printf '%s' "$EFFECTIVE_TIMEOUT" | grep -qE '^[0-9]+$'; then
  echo "generate-acceptance-package: EFFECTIVE_TIMEOUT must be integer (got '$EFFECTIVE_TIMEOUT')" >&2
  exit 1
fi

# ---- Idempotency: existing package at this HEAD is left alone ----
PKG_DIR="$ACCEPT_BASE/$HEAD_OID"
if [ -d "$PKG_DIR" ] && [ -f "$PKG_DIR/acceptance.json" ] && [ -f "$PKG_DIR/A-G.log" ]; then
  echo "generate-acceptance-package: package already exists at $PKG_DIR — leaving untouched" >&2
  exit 0
fi

mkdir -p "$PKG_DIR"

# ---- Compute SHA-256 helpers ----
sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

NDJSON_SHA="$(sha256_of "$CANONICAL_NDJSON")"
LOG_SHA="$(sha256_of "$FULL_SUITE_LOG")"
VERDICT_SHA="$(sha256_of "$MAINTENANCE_VERDICT")"
REVIEWER_VERDICT_SHA="$(sha256_of "$REVIEWER_VERDICT")"
MIGRATION_SHA="$(sha256_of "$MIGRATION_RECORD")"
A_G_LOG="$PKG_DIR/A-G.log"
ACCEPT_JSON="$PKG_DIR/acceptance.json"

# ---- Run the targeted A-G tests, capture every output line into A-G.log ----
# These are the tests that prove each blocker category was fixed at the
# current HEAD. We run them with bash -c so each suite's stdout/stderr is
# captured; the resulting A-G.log is bound by runtime-manifest so any later
# tampering is caught by DWM.

# Suite selection (mapping blocker categories A-G to test scripts).
# A: timeout_seconds integer boundary → tests/core/test-r4-contracts.sh
# B: log_artifact containment → tests/core/test-validate-run-log.sh
# C: DWM runtime-artifact immutability → tests/release/test-dirty-worktree-manifest.sh
# D: Reviewer attempt semantics → tests/core/test-verdict-artifact.sh
# E: journal strict contract → tests/core/test-journal-strict-contract.sh
# F: recovery + migration → tests/core/test-journal-recover.sh + tests/migration/test-v1-compat.sh
# G: branch-gate fail-closed + rc6 migration → tests/release/test-rc6-final-migration.sh
TARGETED_SUITES=(
  "A:tests/core/test-r4-contracts.sh"
  "B:tests/core/test-validate-run-log.sh"
  "C:tests/release/test-dirty-worktree-manifest.sh"
  "D:tests/core/test-verdict-artifact.sh"
  "E:tests/core/test-journal-strict-contract.sh"
  "F:tests/core/test-journal-recover.sh"
  "F2:tests/migration/test-v1-compat.sh"
  "G:tests/release/test-rc6-final-migration.sh"
)

# Header
{
  echo "============================================================"
  echo "RC6 FINAL ACCEPTANCE PACKAGE — TARGETED A-G TEST LOG"
  echo "HEAD_OID:        $HEAD_OID"
  echo "RUN_ID:          $RUN_ID"
  echo "DURATION_MS:     $DURATION_MS"
  echo "EFFECTIVE_TIMEOUT: $EFFECTIVE_TIMEOUT"
  echo "CONFIG_SHA256:   $CONFIG_SHA256"
  echo "CANONICAL_NDJSON:$CANONICAL_NDJSON"
  echo "  SHA-256:       $NDJSON_SHA"
  echo "FULL_SUITE_LOG:  $FULL_SUITE_LOG"
  echo "  SHA-256:       $LOG_SHA"
  echo "MAINTENANCE_VERDICT: $MAINTENANCE_VERDICT"
  echo "  SHA-256:       $VERDICT_SHA"
  echo "REVIEWER_VERDICT: $REVIEWER_VERDICT"
  echo "  SHA-256:       $REVIEWER_VERDICT_SHA"
  echo "MIGRATION_RECORD: $MIGRATION_RECORD"
  echo "  SHA-256:       $MIGRATION_SHA"
  echo "Generated at:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "============================================================"
  echo ""
} > "$A_G_LOG"

overall_rc=0
for entry in "${TARGETED_SUITES[@]}"; do
  label="${entry%%:*}"
  suite="${entry#*:}"
  echo "----- Category $label: $suite -----" >> "$A_G_LOG"
  echo "Command: bash $suite" >> "$A_G_LOG"
  if ! bash "$ROOT_DIR/$suite" >> "$A_G_LOG" 2>&1; then
    echo "  CATEGORY $label: $suite EXIT NON-ZERO" >> "$A_G_LOG"
    overall_rc=1
  else
    echo "  CATEGORY $label: $suite EXIT 0" >> "$A_G_LOG"
  fi
  echo "" >> "$A_G_LOG"
done

if [ "$overall_rc" -ne 0 ]; then
  echo "generate-acceptance-package: at least one A-G suite failed; aborting" >&2
  rm -rf "$PKG_DIR"
  exit 1
fi

A_G_SHA="$(sha256_of "$A_G_LOG")"

# ---- Build acceptance.json ----------------------------------------------------
jq -n \
  --arg schema_version "1" \
  --arg head_oid "$HEAD_OID" \
  --arg run_id "$RUN_ID" \
  --argjson duration_ms "$DURATION_MS" \
  --argjson effective_timeout "$EFFECTIVE_TIMEOUT" \
  --arg config_sha256 "$CONFIG_SHA256" \
  --arg canonical_ndjson_path "$CANONICAL_NDJSON" \
  --arg canonical_ndjson_sha256 "$NDJSON_SHA" \
  --arg full_suite_log_path "$FULL_SUITE_LOG" \
  --arg full_suite_log_sha256 "$LOG_SHA" \
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

# ---- Atomic move -------------------------------------------------------------
mv "$ACCEPT_JSON.tmp" "$ACCEPT_JSON"

# ---- Atomically register both files in runtime-manifest ---------------------
# Source lock + runtime-manifest, then register. Both registrations must
# succeed; any failure aborts.
# shellcheck source=../../core/lib/lock-registry.sh
. "$ROOT_DIR/core/lib/lock-registry.sh"
# shellcheck source=../../core/lib/runtime-manifest.sh
. "$ROOT_DIR/core/lib/runtime-manifest.sh"

RUNTIME_MANIFEST_GENESIS="$HEAD_OID" \
  runtime_register "$ROOT_DIR" ".harness/acceptance/$HEAD_OID/acceptance.json" "log" || {
    echo "generate-acceptance-package: runtime_register failed for acceptance.json" >&2
    rm -rf "$PKG_DIR"
    exit 1
  }
RUNTIME_MANIFEST_GENESIS="$HEAD_OID" \
  runtime_register "$ROOT_DIR" ".harness/acceptance/$HEAD_OID/A-G.log" "log" || {
    echo "generate-acceptance-package: runtime_register failed for A-G.log" >&2
    rm -rf "$PKG_DIR"
    exit 1
  }

echo "acceptance package written to $PKG_DIR"
echo "  acceptance.json sha256: $(sha256_of "$ACCEPT_JSON")"
echo "  A-G.log sha256:         $A_G_SHA"
exit 0
