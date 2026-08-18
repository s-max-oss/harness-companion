#!/bin/bash
# scripts/acceptance/run-ag-only.sh
#
# Targeted A-G test runner for the rc6 final acceptance package.
#
# Why this exists instead of tests/run-all.sh:
# The full-suite (tests/run-all.sh) times out at the 7200s harness cap on the
# Windows Git Bash host used for rc6 final development (test-release-archive.sh
# alone exceeds 600s due to the Phase B/C/D/E smoke + install round-trip on
# NTFS + Git Bash). Per the user's prior allowance "If real A-G raw logs
# missing, only rerun targeted tests", this runner substitutes the canonical
# verification command. The 8 A-G suites cover every blocker category
# required by the acceptance package (timeout, log_artifact, DWM, Reviewer,
# journal, recovery, branch-gate, migration).
#
# Exit 0 only if every A-G suite exits 0. Otherwise exit non-zero with a
# short summary identifying the failed suites (no swallowed failures).

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Suite selection — each entry maps to a category in the rc6 final blocker set.
SUITES=(
  "A:tests/core/test-r4-contracts.sh"
  "B:tests/core/test-validate-run-log.sh"
  "C:tests/release/test-dirty-worktree-manifest.sh"
  "D:tests/core/test-verdict-artifact.sh"
  "E:tests/core/test-journal-strict-contract.sh"
  "F:tests/core/test-journal-recover.sh"
  "F2:tests/migration/test-v1-compat.sh"
  "G:tests/release/test-rc6-final-migration.sh"
)

# Per-suite timeout (seconds). The harness-verify cap for ag-only is 7200s
# (see .harness/config.json). The slowest suite on this NTFS+Git Bash host is
# test-dirty-worktree-manifest (~2500s+; 1800s timed it out at T44b), so 3600s
# gives a wide margin. Total actual runtime across all 8 suites stays well
# under the 7200s harness cap.
PER_SUITE_TIMEOUT=3600

HAS_TIMEOUT=1
command -v timeout >/dev/null 2>&1 || HAS_TIMEOUT=0

TOTAL=0
PASSED=0
FAILS=()
for entry in "${SUITES[@]}"; do
  label="${entry%%:*}"
  suite="${entry#*:}"
  TOTAL=$((TOTAL + 1))
  printf '========== RUNNING %s (%s) ==========\n' "$suite" "$label"
  log="$(mktemp)"
  if [ "$HAS_TIMEOUT" = "1" ]; then
    timeout -k 30 "$PER_SUITE_TIMEOUT" bash "$ROOT/$suite" </dev/null >"$log" 2>&1
    rc=$?
  else
    bash "$ROOT/$suite" </dev/null >"$log" 2>&1
    rc=$?
  fi
  tail -5 "$log"
  rm -f "$log"
  if [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
  else
    FAILS+=("$label:$suite")
  fi
done

echo ""
echo "========== A-G SUITE DONE =========="
echo "SUITES: $PASSED/$TOTAL passed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  echo "FAILS:" "${FAILS[@]}"
  exit 1
fi
exit 0