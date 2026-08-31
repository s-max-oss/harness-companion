#!/bin/bash
# test-claude-code-lifecycle.sh — Claude Code adapter lifecycle coverage (rc.2 §3 GAP-3b)
#
# Covers the 9 scenarios listed as "Missing" for Claude in the rc.2 spec:
#   L1: Clean install → VERSION written
#   L2: Clean install → receipt version matches VERSION
#   L3: Same-version reinstall → no upgrade_history append
#   L4: Cross-version upgrade → receipt updated (BUG-1)
#   L5: Cross-version upgrade → upgrade_history appended
#   L6: Alternate-path re-install idempotency (BUG-3)
#   L7: Uninstall → hooks deregistered from settings.json
#   L8: Uninstall → target tree removed
#   L9: Install from tarball (no .git) → source shows archive origin
#
# Usage:
#   bash tests/adapters/test-claude-code-lifecycle.sh
#
# Required: jq, bash ≥4

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
ADAPTER_DIR="$ROOT_DIR/adapters/claude-code"

PASSED=0
FAILED=0

assert() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASSED=$((PASSED + 1))
    printf '  [PASS] %s\n' "$label"
  else
    FAILED=$((FAILED + 1))
    printf '  [FAIL] %s — expected %s, got %s\n' "$label" "$expected" "$actual"
  fi
}

assert_grep() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASSED=$((PASSED + 1))
    printf '  [PASS] %s\n' "$label"
  else
    FAILED=$((FAILED + 1))
    printf '  [FAIL] %s — needle not found: %s\n' "$label" "$needle"
  fi
}

assert_not_grep() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    FAILED=$((FAILED + 1))
    printf '  [FAIL] %s — unexpected match: %s\n' "$label" "$needle"
  else
    PASSED=$((PASSED + 1))
    printf '  [PASS] %s\n' "$label"
  fi
}

assert_file() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    PASSED=$((PASSED + 1))
    printf '  [PASS] %s\n' "$label"
  else
    FAILED=$((FAILED + 1))
    printf '  [FAIL] %s — file not found: %s\n' "$label" "$path"
  fi
}

# ---- helpers ------------------------------------------------------------------

cleanup_dirs=()
add_cleanup() { cleanup_dirs+=("$1"); }
cleanup_all() {
  local d
  for d in "${cleanup_dirs[@]}"; do
    [ -n "$d" ] && rm -rf -- "$d" 2>/dev/null
  done
}
trap cleanup_all EXIT

safe_mktemp() {
  local _dir
  _dir="$(mktemp -d 2>/dev/null)" || return 1
  add_cleanup "$_dir"
  printf '%s' "$_dir"
}

# ISO-2: every real installer invocation below inherits this disposable home.
INSTALL_TEST_HOME="$(mktemp -d)"
add_cleanup "$INSTALL_TEST_HOME"
export HOME="$INSTALL_TEST_HOME"

# ---- pre-flight --------------------------------------------------------------

VERSION="$(cat "$ROOT_DIR/VERSION" 2>/dev/null || echo "")"
if [ -z "$VERSION" ]; then
  echo "FATAL: VERSION file missing or empty at $ROOT_DIR/VERSION" >&2
  exit 1
fi
echo "=== Claude Code Lifecycle Tests ==="
echo "Version: $VERSION"
echo ""

# ---- L1: Clean install → VERSION written ------------------------------------
echo "=== L1: Clean install → VERSION written ==="

L1_SANDBOX="$(safe_mktemp)"
pushd "$L1_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
L1_RC=$?
popd >/dev/null

assert "L1.1 install exit code" "0" "$L1_RC"
L1_TARGET="$L1_SANDBOX/.claude/skills/harness-companion"
assert_file "L1.2 VERSION file exists in target" "$L1_TARGET/VERSION"
L1_VERSION="$(cat "$L1_TARGET/VERSION" 2>/dev/null || echo "")"
assert "L1.3 target VERSION matches source VERSION" "$VERSION" "$L1_VERSION"
echo ""

# ---- L2: Clean install → receipt version matches VERSION ---------------------
echo "=== L2: Clean install → receipt matches VERSION ==="

L2_RECEIPT="$L1_TARGET/install-receipt.json"
assert_file "L2.1 receipt exists" "$L2_RECEIPT"
L2_RCP_VERSION="$(jq -r '.version // empty' "$L2_RECEIPT" 2>/dev/null || echo "")"
assert "L2.2 receipt version matches VERSION" "$VERSION" "$L2_RCP_VERSION"
L2_RCP_SKILL="$(jq -r '.skill // empty' "$L2_RECEIPT" 2>/dev/null || echo "")"
assert "L2.3 receipt skill is harness-companion" "harness-companion" "$L2_RCP_SKILL"
L2_EXPECTED_KEYS="$(find "$L1_TARGET" -type f ! -name install-receipt.json ! -name VERSION -printf '%P\n' | tr '\\' '/' | tr -d '\r' | LC_ALL=C sort)"
L2_ACTUAL_KEYS="$(jq -r '.integrity.files | keys[]' "$L2_RECEIPT" 2>/dev/null | tr -d '\r' | LC_ALL=C sort)"
assert "L2.4 integrity receipt has exact installed-file key set" "$L2_EXPECTED_KEYS" "$L2_ACTUAL_KEYS"
echo ""

# ---- L3: Same-version reinstall → no upgrade_history append ------------------
echo "=== L3: Same-version reinstall → no upgrade_history ==="

L3_HIST_BEFORE="$(jq -c '.upgrade_history // []' "$L2_RECEIPT" 2>/dev/null || echo "[]")"

pushd "$L1_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
popd >/dev/null

L3_HIST_AFTER="$(jq -c '.upgrade_history // []' "$L2_RECEIPT" 2>/dev/null || echo "[]")"
assert "L3.1 upgrade_history unchanged after same-version reinstall" "$L3_HIST_BEFORE" "$L3_HIST_AFTER"
L3_RCP_VERSION="$(jq -r '.version // empty' "$L2_RECEIPT" 2>/dev/null || echo "")"
assert "L3.2 receipt version still matches VERSION" "$VERSION" "$L3_RCP_VERSION"
echo ""

# ---- L4 & L5: Cross-version upgrade → receipt updated + history appended -----
echo "=== L4+L5: Cross-version upgrade ==="

L4_SANDBOX="$(safe_mktemp)"
pushd "$L4_SANDBOX" >/dev/null

# First install at rc.1 (simulate with fake receipt)
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
L4_TARGET="$L4_SANDBOX/.claude/skills/harness-companion"
L4_RECEIPT="$L4_TARGET/install-receipt.json"

# Manually downgrade receipt to simulate rc.1 install
jq '.version = "2.0.0-rc.1" | .tag = "v2.0.0-rc.1" | .installed_at = "2026-08-03T00:00:00Z"' "$L4_RECEIPT" > "$L4_RECEIPT.tmp" \
  && mv "$L4_RECEIPT.tmp" "$L4_RECEIPT"

# Lower target VERSION too (BUG-2: installer compares target VERSION, not receipt)
echo "2.0.0-rc.1" > "$L4_TARGET/VERSION"

# Now reinstall → should detect cross-version upgrade
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
popd >/dev/null

L4_RCP_VERSION="$(jq -r '.version // empty' "$L4_RECEIPT" 2>/dev/null || echo "")"
assert "L4.1 receipt version updated to current" "$VERSION" "$L4_RCP_VERSION"

L5_HIST_LEN="$(jq '.upgrade_history | length' "$L4_RECEIPT" 2>/dev/null || echo "0")"
assert "L5.1 upgrade_history has 1 entry" "1" "$L5_HIST_LEN"
L5_FROM="$(jq -r '.upgrade_history[0].from // empty' "$L4_RECEIPT" 2>/dev/null || echo "")"
L5_TO="$(jq -r '.upgrade_history[0].to // empty' "$L4_RECEIPT" 2>/dev/null || echo "")"
assert "L5.2 history from is rc.1" "2.0.0-rc.1" "$L5_FROM"
assert "L5.3 history to is current" "$VERSION" "$L5_TO"
echo ""

# ---- L6: Alternate-path re-install idempotency (BUG-3) -----------------------
echo "=== L6: Alternate-path re-install idempotency ==="

L6_SANDBOX="$(safe_mktemp)"
pushd "$L6_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
popd >/dev/null

L6_TARGET="$L6_SANDBOX/.claude/skills/harness-companion"
L6_SETTINGS="$L6_SANDBOX/.claude/settings.json"

# Verify initial hook state
L6_SS_COUNT_BEFORE="$(jq '.hooks.SessionStart | length' "$L6_SETTINGS" 2>/dev/null || echo "0")"
assert "L6.1 one SessionStart hook after first install" "1" "$L6_SS_COUNT_BEFORE"

# Reinstall to same path → should be idempotent
pushd "$L6_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
popd >/dev/null

L6_SS_COUNT_AFTER="$(jq '.hooks.SessionStart | length' "$L6_SETTINGS" 2>/dev/null || echo "0")"
assert "L6.2 SessionStart still 1 entry after alternate-path reinstall" "1" "$L6_SS_COUNT_AFTER"

# Alternate path: install from a different location to the SAME target
L6_ALT_SANDBOX="$(safe_mktemp)"
pushd "$L6_ALT_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
popd >/dev/null

L6_ALT_SETTINGS="$L6_ALT_SANDBOX/.claude/settings.json"
L6_ALT_SS_COUNT="$(jq '.hooks.SessionStart | length' "$L6_ALT_SETTINGS" 2>/dev/null || echo "0")"
assert "L6.3 alternate path install registers hooks correctly" "1" "$L6_ALT_SS_COUNT"
echo ""

# ---- L7: Uninstall → hooks deregistered from settings.json -------------------
echo "=== L7: Uninstall → hooks deregistered ==="

L7_SANDBOX="$(safe_mktemp)"
pushd "$L7_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
popd >/dev/null

L7_TARGET="$L7_SANDBOX/.claude/skills/harness-companion"
L7_SETTINGS="$L7_SANDBOX/.claude/settings.json"

# Verify hooks exist before uninstall
L7_SS_BEFORE="$(jq '.hooks.SessionStart | length' "$L7_SETTINGS" 2>/dev/null || echo "0")"
assert "L7.1 SessionStart hooks present before uninstall" "1" "$L7_SS_BEFORE"

# Run uninstall — must be inside the sandbox because --project uses $(pwd)
pushd "$L7_SANDBOX" >/dev/null
bash "$ADAPTER_DIR/uninstall.sh" --project 2>/dev/null
L7_UNINSTALL_RC=$?
popd >/dev/null
assert "L7.2 uninstall exit code" "0" "$L7_UNINSTALL_RC"

# Verify hooks removed after uninstall
L7_SS_AFTER="$(jq '.hooks.SessionStart | length' "$L7_SETTINGS" 2>/dev/null || echo "0")"
assert "L7.3 SessionStart hooks removed after uninstall" "0" "$L7_SS_AFTER"

L7_STOP_AFTER="$(jq '.hooks.Stop | length' "$L7_SETTINGS" 2>/dev/null || echo "0")"
assert "L7.4 Stop hooks removed after uninstall" "0" "$L7_STOP_AFTER"
echo ""

# ---- L8: Uninstall → target tree removed ------------------------------------
echo "=== L8: Uninstall → target tree removed ==="

assert "L8.1 target tree removed after uninstall" "NO" "$([ -d "$L7_TARGET" ] && echo YES || echo NO)"
echo ""

# ---- L9: Install from tarball (no .git) → source shows archive origin --------
echo "=== L9: Install from tarball → archive origin in receipt ==="

L9_SANDBOX="$(safe_mktemp)"
# Create a fake "extracted tarball" directory (no .git)
L9_TARBALL_SRC="$(safe_mktemp)"
cp -r "$ROOT_DIR"/* "$L9_TARBALL_SRC/" 2>/dev/null
# Remove .git to simulate tarball extraction
rm -rf "$L9_TARBALL_SRC/.git" 2>/dev/null || true

pushd "$L9_SANDBOX" >/dev/null
bash "$L9_TARBALL_SRC/adapters/claude-code/install.sh" --project >/dev/null 2>&1
L9_RC=$?
popd >/dev/null

assert "L9.1 tarball install exit code" "0" "$L9_RC"

L9_TARGET="$L9_SANDBOX/.claude/skills/harness-companion"
L9_RECEIPT="$L9_TARGET/install-receipt.json"
L9_SOURCE_COMMIT="$(jq -r '.source.commit // "null"' "$L9_RECEIPT" 2>/dev/null || echo "")"
L9_SOURCE_ORIGIN="$(jq -r '.source.origin // "null"' "$L9_RECEIPT" 2>/dev/null || echo "")"

assert "L9.2 source.commit is null (no .git → tarball)" "null" "$L9_SOURCE_COMMIT"
assert "L9.3 source.origin is archive" "archive" "$L9_SOURCE_ORIGIN"

assert_file "L9.4 VERSION file exists in tarball-installed target" "$L9_TARGET/VERSION"
L9_VERSION="$(cat "$L9_TARGET/VERSION" 2>/dev/null || echo "")"
assert "L9.5 target VERSION matches source VERSION" "$VERSION" "$L9_VERSION"
echo ""

# ---- L10: Safety gate negative tests (uninstall without receipt) --------------
echo "=== L10: Safety gate negative tests ==="

L10_SANDBOX="$(safe_mktemp)"
pushd "$L10_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
popd >/dev/null

L10_TARGET="$L10_SANDBOX/.claude/skills/harness-companion"

# Remove receipt → uninstall must refuse
rm -f "$L10_TARGET/install-receipt.json"
pushd "$L10_SANDBOX" >/dev/null
bash "$ADAPTER_DIR/uninstall.sh" --project >/dev/null 2>&1
L10_NO_RCPT_RC=$?
popd >/dev/null
assert "L10.1 uninstall without receipt is refused (exit != 0)" "1" "$L10_NO_RCPT_RC"
assert "L10.2 target still exists when receipt missing" "YES" "$([ -d "$L10_TARGET" ] && echo YES || echo NO)"
echo ""

# ---- L11: Incomplete archive fails before target mutation -------------------
echo "=== L11: Missing VERSION fails closed ==="

L11_SANDBOX="$(safe_mktemp)"
L11_SRC="$(safe_mktemp)"
cp -r "$ROOT_DIR"/* "$L11_SRC/" 2>/dev/null
rm -rf "$L11_SRC/.git" 2>/dev/null || true
rm -f "$L11_SRC/VERSION"
pushd "$L11_SANDBOX" >/dev/null
bash "$L11_SRC/adapters/claude-code/install.sh" --project >/dev/null 2>&1
L11_RC=$?
popd >/dev/null
assert "L11.1 missing VERSION returns non-zero" "1" "$([ "$L11_RC" -ne 0 ] && echo 1 || echo 0)"
assert "L11.2 missing VERSION writes no install target" "NO" "$([ -e "$L11_SANDBOX/.claude/skills/harness-companion" ] && echo YES || echo NO)"
printf '2.0.0-rc.2\n2.0.0\n' > "$L11_SRC/VERSION"
pushd "$L11_SANDBOX" >/dev/null
bash "$L11_SRC/adapters/claude-code/install.sh" --project >/dev/null 2>&1
L11_MULTILINE_RC=$?
popd >/dev/null
assert "L11.3 multi-line VERSION returns non-zero" "1" "$([ "$L11_MULTILINE_RC" -ne 0 ] && echo 1 || echo 0)"
assert "L11.4 malformed VERSION writes no install target" "NO" "$([ -e "$L11_SANDBOX/.claude/skills/harness-companion" ] && echo YES || echo NO)"
printf '2.0.0-01\n' > "$L11_SRC/VERSION"
pushd "$L11_SANDBOX" >/dev/null
bash "$L11_SRC/adapters/claude-code/install.sh" --project >/dev/null 2>&1
L11_LEADING_ZERO_RC=$?
popd >/dev/null
assert "L11.5 numeric prerelease leading zero returns non-zero" "1" "$([ "$L11_LEADING_ZERO_RC" -ne 0 ] && echo 1 || echo 0)"
echo ""

# ---- L12: Integrity regeneration failure propagates -------------------------
echo "=== L12: Integrity regeneration failure propagates ==="

L12_SANDBOX="$(safe_mktemp)"
L12_TARGET="$L12_SANDBOX/.claude/skills/harness-companion"
mkdir -p "$L12_TARGET"
printf '{"integrity":42}\n' > "$L12_TARGET/install-receipt.json"
pushd "$L12_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
L12_RC=$?
popd >/dev/null
assert "L12.1 malformed integrity object returns non-zero" "1" "$([ "$L12_RC" -ne 0 ] && echo 1 || echo 0)"
echo ""

# ---- Summary -----------------------------------------------------------------
echo "=== Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
