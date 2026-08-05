#!/bin/bash
# test-version-sync.sh — Verify all 9 version-bearing artifacts agree
#
# Per rc.2 spec §2 BUG-2 version sync gate, asserts:
#   1. Repo VERSION
#   2. Claude plugin manifest
#   3. Codex plugin manifest
#   4. Claude marketplace
#   5. SKILL.md (version mentioned)
#   6. install-receipt.json (after install)
#   7. Target VERSION (after install)
#   8. README (version badge/text)
#   9. CHANGELOG (section header)
#
# FAIL-CLOSED (per rc.2 G0-rev3 spec §F14):
#   - Missing required artifact = FAIL (not SKIP, not PASS)
#   - Cannot read version field = FAIL (not SKIP)
#   - Optional INFO/PASS promotions are not allowed for items #1-9
#     when the artifact is REQUIRED (see spec §2)
#   - Items #8/README are checked as one combined PASS/FAIL
#
# Usage:
#   bash tests/release/test-version-sync.sh [--installed-target <path>]
#
# By default checks repo artifacts (1-5, 8-9). With --installed-target,
# also checks installed artifacts (6-7) against the target directory.
# Items #6 and #7 REQUIRE --installed-target; without it they FAIL.

set -uo pipefail
# NOTE: pipefail intentionally NOT set so that a broken `grep ... | head`
# pipeline cannot mask a missing file under MSYS2 bash. We use explicit
# rc checks instead.

SOURCE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASSED=0
FAILED=0
SKIPPED=0

echo "============================================"
echo "  test-version-sync.sh (FAIL-CLOSED, F14)"
echo "  Repo: $SOURCE_REPO"
echo "============================================"

# Read expected version from repo VERSION
EXPECTED=""
if [ -f "$SOURCE_REPO/VERSION" ]; then
  EXPECTED="$(head -1 "$SOURCE_REPO/VERSION" | tr -d '[:space:]')"
  echo ""
  echo "Expected version: $EXPECTED (from VERSION)"
else
  echo "FAIL: Repo VERSION file missing at $SOURCE_REPO/VERSION"
  exit 1
fi

check_artifact() {
  local label="$1" path="$2" actual="$3"
  # Normalize: strip leading 'v' prefix if present
  local norm_actual="${actual#v}"
  local norm_expected="${EXPECTED#v}"
  if [ "$norm_actual" = "$norm_expected" ]; then
    echo "PASS: $label = $actual"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $label — expected '$EXPECTED', got '$actual'"
    FAILED=$((FAILED + 1))
  fi
}

echo ""
echo "=== Artifacts check (all 9 items MUST pass — no SKIP) ==="

# 1. Repo VERSION
echo ""
echo "--- #1: Repo VERSION ---"
check_artifact "#1 VERSION" "$SOURCE_REPO/VERSION" "$EXPECTED"

# 2. Claude plugin manifest (REQUIRED — must FAIL if missing or unreadable)
echo ""
echo "--- #2: Claude plugin.json ---"
if [ -f "$SOURCE_REPO/.claude-plugin/plugin.json" ]; then
  CLAUDE_VER=""
  if command -v jq >/dev/null 2>&1; then
    CLAUDE_VER="$(jq -r '.version // ""' "$SOURCE_REPO/.claude-plugin/plugin.json" 2>/dev/null || echo "")"
  elif command -v python3 >/dev/null 2>&1; then
    CLAUDE_VER="$(python3 -c "import json; print(json.load(open('$SOURCE_REPO/.claude-plugin/plugin.json')).get('version',''))" 2>/dev/null || echo "")"
  fi
  if [ -n "$CLAUDE_VER" ]; then
    check_artifact "#2 .claude-plugin/plugin.json" "$SOURCE_REPO/.claude-plugin/plugin.json" "$CLAUDE_VER"
  else
    echo "FAIL: #2 .claude-plugin/plugin.json — cannot read version field (jq and python3 both unavailable or returned empty)"
    FAILED=$((FAILED + 1))
  fi
else
  echo "FAIL: #2 .claude-plugin/plugin.json missing at $SOURCE_REPO/.claude-plugin/plugin.json"
  FAILED=$((FAILED + 1))
fi

# 3. Codex plugin manifest (REQUIRED — was already FAIL-on-missing; now also FAIL on unreadable)
echo ""
echo "--- #3: Codex plugin.json ---"
if [ -f "$SOURCE_REPO/.codex-plugin/plugin.json" ]; then
  CODEX_VER=""
  if command -v jq >/dev/null 2>&1; then
    CODEX_VER="$(jq -r '.version // ""' "$SOURCE_REPO/.codex-plugin/plugin.json" 2>/dev/null || echo "")"
  elif command -v python3 >/dev/null 2>&1; then
    CODEX_VER="$(python3 -c "import json; print(json.load(open('$SOURCE_REPO/.codex-plugin/plugin.json')).get('version',''))" 2>/dev/null || echo "")"
  fi
  if [ -n "$CODEX_VER" ]; then
    check_artifact "#3 .codex-plugin/plugin.json" "$SOURCE_REPO/.codex-plugin/plugin.json" "$CODEX_VER"
  else
    echo "FAIL: #3 .codex-plugin/plugin.json — cannot read version field"
    FAILED=$((FAILED + 1))
  fi
else
  echo "FAIL: #3 .codex-plugin/plugin.json missing at $SOURCE_REPO/.codex-plugin/plugin.json"
  FAILED=$((FAILED + 1))
fi

# 4. Claude marketplace (REQUIRED — must FAIL if missing or unreadable)
echo ""
echo "--- #4: Claude marketplace.json ---"
if [ -f "$SOURCE_REPO/.claude-plugin/marketplace.json" ]; then
  MARKET_VER=""
  if command -v jq >/dev/null 2>&1; then
    MARKET_VER="$(jq -r '.plugins[0].version // ""' "$SOURCE_REPO/.claude-plugin/marketplace.json" 2>/dev/null || echo "")"
  elif command -v python3 >/dev/null 2>&1; then
    MARKET_VER="$(python3 -c "import json; print(json.load(open('$SOURCE_REPO/.claude-plugin/marketplace.json'))['plugins'][0].get('version',''))" 2>/dev/null || echo "")"
  fi
  if [ -n "$MARKET_VER" ]; then
    check_artifact "#4 .claude-plugin/marketplace.json" "$SOURCE_REPO/.claude-plugin/marketplace.json" "$MARKET_VER"
  else
    echo "FAIL: #4 .claude-plugin/marketplace.json — cannot read version field"
    FAILED=$((FAILED + 1))
  fi
else
  echo "FAIL: #4 .claude-plugin/marketplace.json missing at $SOURCE_REPO/.claude-plugin/marketplace.json"
  FAILED=$((FAILED + 1))
fi

# 5. SKILL.md — REQUIRED must mention the version. (Was INFO+passed; now MUST mention.)
echo ""
echo "--- #5: SKILL.md ---"
if [ -f "$SOURCE_REPO/SKILL.md" ]; then
  if grep -q "$EXPECTED" "$SOURCE_REPO/SKILL.md" 2>/dev/null; then
    echo "PASS: #5 SKILL.md mentions version $EXPECTED"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: #5 SKILL.md does not mention version $EXPECTED"
    FAILED=$((FAILED + 1))
  fi
else
  echo "FAIL: #5 SKILL.md missing at $SOURCE_REPO/SKILL.md"
  FAILED=$((FAILED + 1))
fi

# 6 & 7: Installed artifacts (only if --installed-target provided)
INSTALLED_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --installed-target)
      shift
      INSTALLED_TARGET="${1:-}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "$INSTALLED_TARGET" ]; then
  echo ""
  echo "--- #6: install-receipt.json ---"
  if [ -f "$INSTALLED_TARGET/install-receipt.json" ]; then
    RECEIPT_VER=""
    if command -v jq >/dev/null 2>&1; then
      RECEIPT_VER="$(jq -r '.version // ""' "$INSTALLED_TARGET/install-receipt.json" 2>/dev/null || echo "")"
    elif command -v python3 >/dev/null 2>&1; then
      RECEIPT_VER="$(python3 -c "import json; print(json.load(open('$INSTALLED_TARGET/install-receipt.json')).get('version',''))" 2>/dev/null || echo "")"
    fi
    if [ -n "$RECEIPT_VER" ]; then
      check_artifact "#6 install-receipt.json" "$INSTALLED_TARGET/install-receipt.json" "$RECEIPT_VER"
    else
      echo "FAIL: #6 install-receipt.json — cannot read version"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "FAIL: #6 install-receipt.json missing at $INSTALLED_TARGET"
    FAILED=$((FAILED + 1))
  fi

  echo ""
  echo "--- #7: Target VERSION ---"
  if [ -f "$INSTALLED_TARGET/VERSION" ]; then
    TARGET_VER="$(head -1 "$INSTALLED_TARGET/VERSION" | tr -d '[:space:]')"
    if [ -n "$TARGET_VER" ]; then
      check_artifact "#7 \$TARGET/VERSION" "$INSTALLED_TARGET/VERSION" "$TARGET_VER"
    else
      echo "FAIL: #7 VERSION empty at $INSTALLED_TARGET/VERSION"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "FAIL: #7 VERSION missing at $INSTALLED_TARGET/VERSION"
    FAILED=$((FAILED + 1))
  fi
else
  # FAIL-CLOSED: --installed-target is REQUIRED for the rc.2 sync gate.
  # Without it, items #6 and #7 cannot be verified, so they MUST FAIL.
  echo ""
  echo "--- #6: install-receipt.json ---"
  echo "FAIL: #6 install-receipt.json — --installed-target <path> was NOT provided; cannot verify installed receipt"
  FAILED=$((FAILED + 1))

  echo ""
  echo "--- #7: Target VERSION ---"
  echo "FAIL: #7 target VERSION — --installed-target <path> was NOT provided; cannot verify installed VERSION"
  FAILED=$((FAILED + 1))
fi

# 8. README (each must independently match when both exist)
echo ""
echo "--- #8: README.md + README.zh-CN.md ---"
README_ALL_OK=1
if [ -f "$SOURCE_REPO/README.md" ]; then
  if grep -q "$EXPECTED" "$SOURCE_REPO/README.md" 2>/dev/null; then
    echo "  PASS: #8 README.md mentions version $EXPECTED"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: #8 README.md does not mention version $EXPECTED"
    FAILED=$((FAILED + 1))
    README_ALL_OK=0
  fi
else
  echo "  FAIL: #8 README.md missing at $SOURCE_REPO/README.md"
  FAILED=$((FAILED + 1))
  README_ALL_OK=0
fi
if [ -f "$SOURCE_REPO/README.zh-CN.md" ]; then
  if grep -q "$EXPECTED" "$SOURCE_REPO/README.zh-CN.md" 2>/dev/null; then
    echo "  PASS: #8 README.zh-CN.md mentions version $EXPECTED"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: #8 README.zh-CN.md does not mention version $EXPECTED"
    FAILED=$((FAILED + 1))
    README_ALL_OK=0
  fi
else
  echo "  INFO: #8 README.zh-CN.md not present (English README is the canonical)"
fi

# 9. CHANGELOG — REQUIRED must mention version
echo ""
echo "--- #9: CHANGELOG.md ---"
if [ -f "$SOURCE_REPO/CHANGELOG.md" ]; then
  if grep -q "\[${EXPECTED#v}\]" "$SOURCE_REPO/CHANGELOG.md" 2>/dev/null || grep -q "$EXPECTED" "$SOURCE_REPO/CHANGELOG.md" 2>/dev/null; then
    echo "PASS: #9 CHANGELOG.md mentions version $EXPECTED"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: #9 CHANGELOG.md does not mention version $EXPECTED"
    FAILED=$((FAILED + 1))
  fi
else
  echo "FAIL: #9 CHANGELOG.md missing at $SOURCE_REPO/CHANGELOG.md"
  FAILED=$((FAILED + 1))
fi

echo ""
echo "============================================"
echo "  Version Sync Summary (FAIL-CLOSED)"
echo "  Passed:  $PASSED"
echo "  Failed:  $FAILED"
echo "  Skipped: 0 (all SKIP paths converted to FAIL)"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0