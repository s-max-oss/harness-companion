#!/bin/bash
# rc.3 protected-path gate with the recorded post-PR-B maintenance exception.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="37ecb7f34dd1cbe359605568b1e10cfb65b55326"
AUTH="docs/authorizations/2026-09-10-rc3-maintenance-path-exception.md"
PASS=0
FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

if git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null; then
  ok "protected-path base commit is available"
else
  bad "protected-path base commit is available"
fi

if [ -f "$ROOT/$AUTH" ] && [ ! -L "$ROOT/$AUTH" ] \
  && grep -Fq 'core/harness-verify.sh' "$ROOT/$AUTH" \
  && grep -Fq 'core/lib/config-validate.sh' "$ROOT/$AUTH" \
  && grep -Fq 'core/lib/lock-registry.sh' "$ROOT/$AUTH"; then
  ok "narrow maintenance exception is present and explicit"
else
  bad "narrow maintenance exception is present and explicit"
fi

protected=(
  core/lib/baseline.sh
  core/lib/atomic_write.sh core/lib/evidence.sh core/lib/json-encode.sh
  core/lib/json-helpers.sh core/lib/harness-config.sh core/lib/status-renderer.sh
  core/lib/validate-run-log.sh core/lib/staleness.sh
  core/lib/workspace-fingerprint.sh
  core/harness-feature.sh core/harness-status.sh core/harness-audit.sh
  adapters/claude-code adapters/codex install.sh hooks/hooks.json
  references/harness-files.md references/subsystems-mapping.md
  references/feature-state-machine.md references/verification-config.md
)
for path in "${protected[@]}"; do
  if git -C "$ROOT" diff --quiet "$BASE"..HEAD -- "$path"; then
    ok "protected path unchanged: $path"
  else
    bad "protected path unchanged: $path"
  fi
done

exceptions=(core/harness-verify.sh core/lib/config-validate.sh core/lib/lock-registry.sh)
for path in "${exceptions[@]}"; do
  if git -C "$ROOT" diff --quiet "$BASE"..HEAD -- "$path"; then
    bad "recorded maintenance exception is actually exercised: $path"
  else
    ok "recorded maintenance exception is actually exercised: $path"
  fi
done

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
