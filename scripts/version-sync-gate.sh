#!/bin/bash
# version-sync-gate.sh — SHARED version-sync install + test method (P0-7)
#
# Single source of truth for the Phase 5d version-sync FAIL-CLOSED gate. BOTH
# the local full-suite runner (tests/run-all.sh) and CI Phase 5d call THIS
# script, so the temp-install → --installed-target sequence can never diverge
# between local and CI.
#
# Usage:
#   bash version-sync-gate.sh [repo_root]
#
# Behavior (fail-closed, mirrors CI Phase 5d exactly):
#   1. Install the skill into a throwaway temp dir via the canonical
#      adapters/claude-code/install.sh --project. A real install path is NEVER
#      used (zero writes outside the temp dir; ~/.claude/ etc. untouched).
#   2. Run tests/release/test-version-sync.sh with
#      --installed-target "$TMP/.claude/skills/harness-companion" so items #6
#      (receipt) and #7 (target VERSION) are verified against the REAL installed
#      copy. Stdin is closed (< /dev/null) so an installed SessionStart hook
#      that reads stdin can never block the run.
#   3. Remove the temp install; exit with test-version-sync.sh's exit code
#      (the rm rc is never leaked as the gate result).
#
# Exit codes:
#   0  version-sync test passed against the installed copy
#   1  pre-install failed OR test-version-sync.sh failed
#
# Requires: bash, mktemp, and a checkout with adapters/ + tests/ under repo_root.

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

TMP="$(mktemp -d)"
(
  cd "$TMP" || exit 1
  bash "$ROOT/adapters/claude-code/install.sh" --project
) >/dev/null 2>&1
INSTALL_RC=$?

if [ "$INSTALL_RC" -ne 0 ]; then
  echo "version-sync-gate: pre-install failed (rc=$INSTALL_RC) — cannot verify installed artifacts" >&2
  rm -rf "$TMP"
  exit 1
fi

INSTALLED_TARGET="$TMP/.claude/skills/harness-companion"
if [ ! -f "$INSTALLED_TARGET/SKILL.md" ]; then
  echo "version-sync-gate: installed target not found at $INSTALLED_TARGET (no SKILL.md)" >&2
  rm -rf "$TMP"
  exit 1
fi

bash "$ROOT/tests/release/test-version-sync.sh" --installed-target "$INSTALLED_TARGET" < /dev/null
rc=$?

rm -rf "$TMP"
exit "$rc"
