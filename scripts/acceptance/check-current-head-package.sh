#!/bin/bash
# scripts/acceptance/check-current-head-package.sh
#
# Current-HEAD acceptance-package gate. Runs OUTSIDE tests/run-all.sh.
#
# Verifies that .harness/acceptance/<current_HEAD>/acceptance.json exists
# and validates it against the current on-disk state (HEAD, config_sha256,
# canonical NDJSON authoritative path, Reviewer verdict binding to HEAD).
#
# This is the ONLY place where "the final HEAD's package must exist" is
# enforced. tests/release/test-acceptance-package.sh — which IS in run-all.sh
# — does NOT check this; it uses fixed synthetic fixtures to verify the
# validator's logic. This split eliminates the circular dependency where
# the full suite required its own evidence to exist before running.
#
# Usage:
#   bash scripts/acceptance/check-current-head-package.sh [<project_dir>]
#   (defaults to git-toplevel of cwd)
#
# Exit 0 if the package exists and passes full validation, non-zero otherwise.
# A missing package at the current HEAD is a HARD FAILURE (not a skip).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$ROOT_DIR" ] || [ ! -d "$ROOT_DIR" ]; then
  echo "check-current-head-package: cannot determine project root" >&2
  exit 2
fi

# shellcheck source=validate-acceptance-package.sh
. "$SCRIPT_DIR/validate-acceptance-package.sh"

CURRENT_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)" || {
  echo "check-current-head-package: cannot determine current HEAD in $ROOT_DIR" >&2
  exit 2
}
pkg="$ROOT_DIR/.harness/acceptance/$CURRENT_HEAD"

if [ ! -d "$pkg" ]; then
  echo "check-current-head-package: no acceptance package at current HEAD" >&2
  echo "  expected: $pkg" >&2
  echo "  (any old package at a different HEAD is irrelevant — only the current HEAD's package counts)" >&2
  exit 1
fi

result="$(validate_acceptance_package "$pkg" --project-dir "$ROOT_DIR" 2>&1)"
rc=$?
if [ "$rc" != "0" ]; then
  echo "check-current-head-package: package at $pkg failed validation: $result" >&2
  exit 1
fi

# Final authoritative DWM gate. The package contains the pre-publication
# transcript; this second execution covers the package files and their
# runtime-manifest registrations without creating a self-referential artifact.
dwm_result="$(bash "$ROOT_DIR/tools/snapshot-dirty-worktree.sh" check \
  "tests/fixtures/dirty-worktree-manifest.jsonl" "$ROOT_DIR" 2>&1)"
dwm_rc=$?
if [ "$dwm_rc" != "0" ] || ! printf '%s' "$dwm_result" | jq -e '.valid == true' >/dev/null 2>&1; then
  echo "check-current-head-package: formal post-publication DWM failed (rc=$dwm_rc): $dwm_result" >&2
  exit 1
fi
echo "check-current-head-package: PASS ($pkg; formal DWM rc=0)"
exit 0
