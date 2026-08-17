#!/bin/bash
# scripts/acceptance/generate-acceptance-package.sh
#
# Build the current-HEAD acceptance package at
#   .harness/acceptance/<HEAD>/acceptance.json
#   .harness/acceptance/<HEAD>/A-G.log
# bind the canonical run's NDJSON / full-suite.log / maintenance verdict by
# SHA-256, and atomically register BOTH files in runtime-manifest.
#
# The package is committed/HEAD-scoped: directory name IS the full HEAD OID.
# Re-running for the same HEAD is idempotent; running for a different HEAD
# writes a sibling directory and never mutates an existing one.
#
# Required env:
#   HEAD_OID                — 40-hex git OID (the fix-complete commit)
#   RUN_ID                  — canonical full-suite run_id
#   DURATION_MS             — integer milliseconds (no approximations)
#   EFFECTIVE_TIMEOUT       — integer seconds recorded in NDJSON command_completed
#   CONFIG_SHA256           — sha256:<hex> from run_started
#   CANONICAL_NDJSON        — absolute path to canonical .ndjson
#   FULL_SUITE_LOG          — absolute path to canonical full-suite.log
#   MAINTENANCE_VERDICT     — absolute path to .harness/reviews/maintenance/F-MAINT-01.jsonl
#   MIGRATION_RECORD        — absolute path to docs/migrations/2026-08-17-rc6-final-contract-migration.json
# Usage:
#   bash scripts/acceptance/generate-acceptance-package.sh
#
# Exit 0 on success (both files written and atomically registered); non-zero
# on any failure (no partial package, no swallowed error).

set -u
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ACCEPT_BASE="$ROOT_DIR/.harness/acceptance"

# ---- Validate required env ----
: "${HEAD_OID:?HEAD_OID is required (full 40-hex OID of fix-complete HEAD)}"
: "${RUN_ID:?RUN_ID is required (canonical full-suite run_id)}"
: "${DURATION_MS:?DURATION_MS is required (integer milliseconds)}"
: "${EFFECTIVE_TIMEOUT:?EFFECTIVE_TIMEOUT is required (integer seconds)}"
: "${CONFIG_SHA256:?CONFIG_SHA256 is required (sha256:<hex>)}"
: "${CANONICAL_NDJSON:?CANONICAL_NDJSON is required (absolute path to canonical NDJSON)}"
: "${FULL_SUITE_LOG:?FULL_SUITE_LOG is required (absolute path to full-suite.log)}"
: "${MAINTENANCE_VERDICT:?MAINTENANCE_VERDICT is required (absolute path to maintenance verdict)}"
: "${MIGRATION_RECORD:?MIGRATION_RECORD is required (absolute path to migration JSON)}"

# ---- Validate OID format ----
if ! printf '%s' "$HEAD_OID" | grep -qE '^[0-9a-f]{40}$'; then
  echo "generate-acceptance-package: HEAD_OID must be 40-hex" >&2
  exit 1
fi

# ---- Validate all referenced files exist ----
for var in CANONICAL_NDJSON FULL_SUITE_LOG MAINTENANCE_VERDICT MIGRATION_RECORD; do
  f="${!var}"
  if [ ! -f "$f" ]; then
    echo "generate-acceptance-package: $var points at missing file: $f" >&2
    exit 1
  fi
done

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
     a_g_log:         { path: $a_g_log_path,         sha256: $a_g_log_sha256         },
     migration_record:{ path: $migration_record_path, sha256: $migration_record_sha256 },
     generated_at: $generated_at
   }' > "$ACCEPT_JSON.tmp" || {
    rm -f "$ACCEPT_JSON.tmp"
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
    exit 1
  }
RUNTIME_MANIFEST_GENESIS="$HEAD_OID" \
  runtime_register "$ROOT_DIR" ".harness/acceptance/$HEAD_OID/A-G.log" "log" || {
    echo "generate-acceptance-package: runtime_register failed for A-G.log" >&2
    exit 1
  }

echo "acceptance package written to $PKG_DIR"
echo "  acceptance.json sha256: $(sha256_of "$ACCEPT_JSON")"
echo "  A-G.log sha256:         $A_G_SHA"
exit 0
