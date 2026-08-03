#!/bin/bash
# tests/adapters/test-codex-install-modes.sh — G5 install/uninstall mode tests
#
# Phase 5b: Real Codex plugin/hooks integration. Tests verify install mechanics:
#   - install.sh --repo writes hooks.json with paths to the COPIES in target
#   - Source-tree move safety (hooks resolve after source moved)
#   - python3 fallback when jq unavailable
#   - install.sh --user writes ~/.codex/harness-hooks.toml
#   - uninstall.sh cleans up only what install.sh created
#
# Tests are self-contained for JSON validation (python3).

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
INSTALL="$ROOT_DIR/adapters/codex/install.sh"
UNINSTALL="$ROOT_DIR/adapters/codex/uninstall.sh"

PASSED=0
FAILED=0
TMPHOME=""
TMP_REPO=""
TMP_REPO_SOURCE_COPY=""

cleanup() {
  rm -rf "$TMPHOME" "$TMP_REPO" "$TMP_REPO_SOURCE_COPY" 2>/dev/null || true
}
trap cleanup EXIT

assert_pass() {
  local name="$1"
  PASSED=$((PASSED + 1))
  printf '  [PASS] %s\n' "$name"
}

assert_fail() {
  local name="$1" reason="${2:-}"
  FAILED=$((FAILED + 1))
  printf '  [FAIL] %s %s\n' "$name" "$reason"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    assert_pass "$name"
  else
    assert_fail "$name" "expected=$expected actual=$actual"
  fi
}

# to_posix_path: convert Windows path to POSIX (for grep) on Windows Git Bash.
to_posix() {
  printf '%s' "$1" | tr '\\' '/'
}

# ============================================================
echo "=== Mode 1: plugin (default — no flag) ==="
# ============================================================

# G5.M1: install.sh with no flag prints Codex marketplace instructions
TMPHOME="$(mktemp -d)"
export HOME="$TMPHOME"
out="$(bash "$INSTALL" 2>&1)"
if echo "$out" | grep -qi 'Phase 5b'; then
  assert_pass "G5.M1 install.sh no-flag prints Phase 5b banner"
else
  assert_fail "G5.M1 install.sh no-flag prints Phase 5b banner" "missing"
fi
if echo "$out" | grep -qF 'codex plugin install'; then
  assert_pass "G5.M1 install.sh no-flag prints 'codex plugin install' instructions"
else
  assert_fail "G5.M1 install.sh no-flag prints 'codex plugin install'" "got: $out"
fi
if [ ! -d "$TMPHOME/.codex" ]; then
  assert_pass "G5.M1 install.sh no-flag does NOT create ~/.codex"
else
  assert_fail "G5.M1 install.sh no-flag does NOT create ~/.codex"
fi

# G5.M2: uninstall.sh with no flag prints marketplace instructions
out="$(bash "$UNINSTALL" 2>&1)"
if echo "$out" | grep -qF 'codex plugin uninstall'; then
  assert_pass "G5.M2 uninstall.sh no-flag prints 'codex plugin uninstall' instructions"
else
  assert_fail "G5.M2 uninstall.sh no-flag prints 'codex plugin uninstall'"
fi

# ============================================================
echo ""
echo "=== Mode 2: --repo [path] ==="
# ============================================================

TMP_REPO="$(mktemp -d)"
export HOME="$TMPHOME"

# G5.M3: --repo creates <target>/.codex/hooks.json
bash "$INSTALL" --repo "$TMP_REPO" >/tmp/install_out.$$ 2>&1
INSTALL_OUT="$(cat /tmp/install_out.$$)"
rm -f /tmp/install_out.$$
if [ -f "$TMP_REPO/.codex/hooks.json" ]; then
  assert_pass "G5.M3 --repo creates <target>/.codex/hooks.json"
else
  assert_fail "G5.M3 --repo creates <target>/.codex/hooks.json"
fi

# G5.M3a: install output includes Phase 5b banner
if echo "$INSTALL_OUT" | grep -qi 'Phase 5b'; then
  assert_pass "G5.M3a --repo install output includes Phase 5b banner"
else
  assert_fail "G5.M3a --repo install output includes Phase 5b banner"
fi

# G5.M4: hooks.json paths are absolute and live under <target>/.codex/...
# Critical: must NOT contain the source-tree plugin root path.
SRC_POSIX="$(to_posix "$ROOT_DIR")"
HOOKS_JSON_ABS="$(to_posix "$(cd "$TMP_REPO" && pwd)/.codex/hooks.json")"
if grep -qF "$SRC_POSIX" "$HOOKS_JSON_ABS" 2>/dev/null; then
  assert_fail "G5.M4 --repo hooks.json paths do NOT reference source tree" "still references $SRC_POSIX"
else
  assert_pass "G5.M4 --repo hooks.json paths do NOT reference source tree"
fi
# Path must reference the target's .codex/adapters/codex/hooks/ copy
INSTALLED_HOOKS_DIR_ABS="$(to_posix "$TMP_REPO/.codex/adapters/codex/hooks")"
if grep -qF "$INSTALLED_HOOKS_DIR_ABS" "$HOOKS_JSON_ABS" 2>/dev/null; then
  assert_pass "G5.M4 --repo hooks.json paths reference installed copy ($INSTALLED_HOOKS_DIR_ABS)"
else
  assert_fail "G5.M4 --repo hooks.json paths reference installed copy" "missing $INSTALLED_HOOKS_DIR_ABS"
fi
# No unresolved ${PLUGIN_ROOT} placeholder
if grep -qF '${PLUGIN_ROOT}' "$HOOKS_JSON_ABS" 2>/dev/null; then
  assert_fail "G5.M4 --repo hooks.json has no \${PLUGIN_ROOT} placeholder" "still present"
else
  assert_pass "G5.M4 --repo hooks.json has no \${PLUGIN_ROOT} placeholder"
fi

# G5.M5: hooks.json validates as JSON (python3 self-contained)
if python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8')); print('OK')" "$HOOKS_JSON_ABS" 2>/dev/null | grep -q OK; then
  assert_pass "G5.M5 --repo hooks.json is valid JSON"
else
  assert_fail "G5.M5 --repo hooks.json is valid JSON"
fi

# G5.M6: hooks.json has all 3 events (python3)
for ev in SessionStart Stop PreToolUse; do
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); sys.exit(0 if '$ev' in d.get('hooks',{}) else 1)" "$HOOKS_JSON_ABS" 2>/dev/null; then
    assert_pass "G5.M6 --repo hooks.json has event '$ev'"
  else
    assert_fail "G5.M6 --repo hooks.json has event '$ev'"
  fi
done

# G5.M7: core/ + adapters/codex/ copied into target
if [ -f "$TMP_REPO/.codex/core/harness-verify.sh" ]; then
  assert_pass "G5.M7 --repo copies core/harness-verify.sh"
else
  assert_fail "G5.M7 --repo copies core/harness-verify.sh"
fi
if [ -f "$TMP_REPO/.codex/adapters/codex/hooks/session-start.sh" ]; then
  assert_pass "G5.M7 --repo copies adapters/codex/hooks/session-start.sh"
else
  assert_fail "G5.M7 --repo copies adapters/codex/hooks/session-start.sh"
fi
if [ -f "$TMP_REPO/.codex/adapters/codex/hooks/session-start.cmd" ]; then
  assert_pass "G5.M7 --repo copies adapters/codex/hooks/session-start.cmd"
else
  assert_fail "G5.M7 --repo copies adapters/codex/hooks/session-start.cmd"
fi
if [ -f "$TMP_REPO/.codex/adapters/codex/UNSUPPORTED.md" ]; then
  assert_pass "G5.M7 --repo copies adapters/codex/UNSUPPORTED.md (Phase 5b status doc)"
else
  assert_fail "G5.M7 --repo copies adapters/codex/UNSUPPORTED.md"
fi

# G5.M8: install-receipt.json written + status=supported
if [ -f "$TMP_REPO/.codex/install-receipt.json" ]; then
  assert_pass "G5.M8 --repo writes install-receipt.json"
  MODE_FIELD="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); print(d.get('mode',''))" "$TMP_REPO/.codex/install-receipt.json" 2>/dev/null || echo "")"
  assert_eq "G5.M8 install-receipt.json mode=repo-local" "repo-local" "$MODE_FIELD"
  STATUS_FIELD="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); print(d.get('status',''))" "$TMP_REPO/.codex/install-receipt.json" 2>/dev/null || echo "")"
  assert_eq "G5.M8 install-receipt.json status=supported" "supported" "$STATUS_FIELD"
else
  assert_fail "G5.M8 --repo writes install-receipt.json"
fi

# G5.M9: idempotent — running twice does not duplicate
FIRST_HASH="$(sha256sum "$HOOKS_JSON_ABS" | awk '{print $1}')"
bash "$INSTALL" --repo "$TMP_REPO" >/dev/null 2>&1
SECOND_HASH="$(sha256sum "$HOOKS_JSON_ABS" | awk '{print $1}')"
assert_eq "G5.M9 --repo idempotent (hash stable across runs)" "$FIRST_HASH" "$SECOND_HASH"

# G5.M10: backup created when hooks.json pre-exists and changes
TMP_REPO2="$(mktemp -d)"
mkdir -p "$TMP_REPO2/.codex"
printf '{"hooks":{"OtherEvent":[{"hooks":[]}]}}\n' > "$TMP_REPO2/.codex/hooks.json"
bash "$INSTALL" --repo "$TMP_REPO2" >/dev/null 2>&1
BACKUP_COUNT="$(ls -1 "$TMP_REPO2/.codex/hooks.json.bak."* 2>/dev/null | wc -l | tr -d ' ')"
if [ "$BACKUP_COUNT" -gt 0 ]; then
  assert_pass "G5.M10 --repo creates backup of pre-existing hooks.json ($BACKUP_COUNT backup)"
else
  assert_fail "G5.M10 --repo creates backup of pre-existing hooks.json"
fi
rm -rf "$TMP_REPO2" 2>/dev/null

# ============================================================
echo ""
echo "=== Mode 2.x: source-tree-move-safety (critical regression) ==="
# ============================================================
# Per G5-fix: after install.sh --repo, the installed hooks must continue
# to function even if the source tree is moved/renamed. This is the
# user's specific requirement: "源码目录移走后 repo-local hook 仍可执行".

# G5.M11: copy the source tree to a SECOND location, then install from
# that location, then RENAME the source copy and verify the installed
# hooks still resolve and execute.

TMP_REPO_SOURCE_COPY="$(mktemp -d)/src"
mkdir -p "$(dirname "$TMP_REPO_SOURCE_COPY")"
cp -r "$ROOT_DIR" "$TMP_REPO_SOURCE_COPY"

# Run install.sh from the COPIED source location into a target project.
TARGET_FOR_MOVE_TEST="$(mktemp -d)/target"
mkdir -p "$TARGET_FOR_MOVE_TEST"
bash "$TMP_REPO_SOURCE_COPY/adapters/codex/install.sh" --repo "$TARGET_FOR_MOVE_TEST" >/dev/null 2>&1
if [ ! -f "$TARGET_FOR_MOVE_TEST/.codex/hooks.json" ]; then
  assert_fail "G5.M11 --repo from copied source location produces hooks.json"
else
  HOOKS_JSON_IN_TARGET="$(to_posix "$TARGET_FOR_MOVE_TEST/.codex/hooks.json")"
  INSTALLED_HOOKS_IN_TARGET="$(to_posix "$TARGET_FOR_MOVE_TEST/.codex/adapters/codex/hooks")"
  COPIED_SOURCE_DIR="$(to_posix "$TMP_REPO_SOURCE_COPY")"

  # Assert: hooks.json paths do NOT reference the source copy.
  if grep -qF "$COPIED_SOURCE_DIR" "$HOOKS_JSON_IN_TARGET" 2>/dev/null; then
    assert_fail "G5.M11 hooks.json paths do NOT reference source copy" "still references $COPIED_SOURCE_DIR"
  else
    assert_pass "G5.M11 hooks.json paths do NOT reference source copy"
  fi

  # Assert: hooks.json paths DO reference the installed copy in target.
  if grep -qF "$INSTALLED_HOOKS_IN_TARGET" "$HOOKS_JSON_IN_TARGET" 2>/dev/null; then
    assert_pass "G5.M11 hooks.json paths reference installed copy in target"
  else
    assert_fail "G5.M11 hooks.json paths reference installed copy in target" "missing $INSTALLED_HOOKS_IN_TARGET"
  fi

  # NOW: rename the source copy (simulating source-tree move).
  RENAMED="$(dirname "$TMP_REPO_SOURCE_COPY")/src-RENAMED"
  mv "$TMP_REPO_SOURCE_COPY" "$RENAMED"
  TMP_REPO_SOURCE_COPY="$RENAMED"

  # Verify the installed hooks.sh still works (exit 0 + valid JSON envelope).
  HOOK="$TARGET_FOR_MOVE_TEST/.codex/adapters/codex/hooks/session-start.sh"
  STDOUT="$(bash "$HOOK" 2>/dev/null)"
  RC=$?
  if [ "$RC" = "0" ] && echo "$STDOUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'continue' in d or 'hookSpecificOutput' in d" 2>/dev/null; then
    assert_pass "G5.M11 installed hook executes after source-tree move (rc=0, valid envelope)"
  else
    assert_fail "G5.M11 installed hook executes after source-tree move" "rc=$RC stdout=$STDOUT"
  fi
fi

# ============================================================
echo ""
echo "=== Mode 2.y: no-jq fallback (python3 only) ==="
# ============================================================
# Per G5-fix: install.sh --repo must work on Windows Git Bash where jq may
# be absent. The python3 fallback path must produce a valid hooks.json.

TMP_REPO_NOJQ="$(mktemp -d)"
# Build a PATH where `jq` is a non-functional stub, but everything else
# (bash, python3, basic tools) resolves normally. We achieve this by
# prepending a directory containing ONLY a fake `jq` to the system PATH —
# everything else falls through to the original PATH lookup.
NOJQ_PATH_DIR="$(mktemp -d)"
cat > "$NOJQ_PATH_DIR/jq" <<'STUB'
#!/bin/sh
# Fake jq stub — install.sh should treat this as "jq not available"
# and fall through to its python3 fallback.
echo "jq-fake-stub 127.0" "$@"
exit 127
STUB
chmod +x "$NOJQ_PATH_DIR/jq"
NOJQ_PATH="$NOJQ_PATH_DIR:$PATH"
# Sanity: this PATH must NOT have a real jq
if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1; then
  JQ_VER="$(PATH="$NOJQ_PATH" jq --version 2>&1 | head -1)"
  if echo "$JQ_VER" | grep -qi 'fake'; then
    assert_pass "G5.M12 no-jq test setup: jq stub active (PATH points at fake)"
  else
    assert_fail "G5.M12 no-jq test setup: jq stub active" "jq real: $JQ_VER"
  fi
else
  assert_pass "G5.M12 no-jq test setup: jq stub present (exit 127)"
fi

PATH="$NOJQ_PATH" bash "$INSTALL" --repo "$TMP_REPO_NOJQ" >/tmp/nojq_out.$$ 2>&1
NOJQ_RC=$?
NOJQ_OUT="$(cat /tmp/nojq_out.$$)"
rm -f /tmp/nojq_out.$$

HOOKS_JSON_NOJQ="$TMP_REPO_NOJQ/.codex/hooks.json"
if [ "$NOJQ_RC" = "0" ] && [ -f "$HOOKS_JSON_NOJQ" ]; then
  assert_pass "G5.M12 --repo no-jq install exits 0 and writes hooks.json"

  # Validate JSON — use python3 (only available) to confirm valid.
  if PATH="$NOJQ_PATH" python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8')); print('OK')" \
      "$HOOKS_JSON_NOJQ" >/tmp/nojq_validate.$$ 2>&1; then
    assert_pass "G5.M12 --repo no-jq install produces valid JSON (python3 validates)"
  else
    assert_fail "G5.M12 --repo no-jq install produces valid JSON" \
      "python3 failed: $(cat /tmp/nojq_validate.$$)"
  fi
  rm -f /tmp/nojq_validate.$$

  # Confirm "constructed via python3" message
  if echo "$NOJQ_OUT" | grep -qi 'python3'; then
    assert_pass "G5.M12 --repo no-jq install reports python3 fallback path"
  else
    assert_fail "G5.M12 --repo no-jq install reports python3 fallback path" \
      "no python3 mention in install output"
  fi

  # Confirm all 3 events present
  EVENTS_PRESENT=0
  for ev in SessionStart Stop PreToolUse; do
    if PATH="$NOJQ_PATH" python3 -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); sys.exit(0 if '${ev}' in d['hooks'] else 1)" "$HOOKS_JSON_NOJQ" >/dev/null 2>&1; then
      EVENTS_PRESENT=$((EVENTS_PRESENT + 1))
    fi
  done
  assert_eq "G5.M12 --repo no-jq hooks.json has all 3 events" "3" "$EVENTS_PRESENT"
else
  assert_fail "G5.M12 --repo no-jq install exits 0 and writes hooks.json" \
    "rc=$NOJQ_RC output: $NOJQ_OUT"
fi
rm -rf "$TMP_REPO_NOJQ" "$NOJQ_PATH_DIR" 2>/dev/null

# ============================================================
echo ""
echo "=== Mode 2 cleanup: uninstall --repo ==="
# ============================================================

# G5.M13: uninstall --repo removes created files
bash "$UNINSTALL" --repo "$TMP_REPO" >/dev/null 2>&1
if [ ! -d "$TMP_REPO/.codex/adapters/codex" ]; then
  assert_pass "G5.M13 uninstall --repo removes adapters/codex/"
else
  assert_fail "G5.M13 uninstall --repo removes adapters/codex/"
fi
if [ ! -d "$TMP_REPO/.codex/core" ]; then
  assert_pass "G5.M13 uninstall --repo removes core/"
else
  assert_fail "G5.M13 uninstall --repo removes core/"
fi

# ============================================================
echo ""
echo "=== Mode 3: --user ==="
# ============================================================

# G5.M14: --user writes ~/.codex/harness-hooks.toml
bash "$INSTALL" --user >/dev/null 2>&1
if [ -f "$TMPHOME/.codex/harness-hooks.toml" ]; then
  assert_pass "G5.M14 --user writes ~/.codex/harness-hooks.toml"
else
  assert_fail "G5.M14 --user writes ~/.codex/harness-hooks.toml"
fi

# G5.M15: --user does NOT modify ~/.codex/config.toml
if [ ! -f "$TMPHOME/.codex/config.toml" ]; then
  assert_pass "G5.M15 --user does NOT create ~/.codex/config.toml"
else
  assert_fail "G5.M15 --user does NOT create ~/.codex/config.toml"
fi

# G5.M16: --user snippet is valid TOML-ish format
SNIPPET="$TMPHOME/.codex/harness-hooks.toml"
for block in '[[hooks.SessionStart]]' '[[hooks.Stop]]' '[[hooks.PreToolUse]]'; do
  if grep -qF "$block" "$SNIPPET"; then
    assert_pass "G5.M16 snippet contains $block"
  else
    assert_fail "G5.M16 snippet contains $block"
  fi
done

# G5.M17: --user snippet has no <INSTALL_PATH> placeholder
if grep -qF '<INSTALL_PATH>' "$SNIPPET" 2>/dev/null; then
  assert_fail "G5.M17 --user snippet has no <INSTALL_PATH> placeholder" "still present"
else
  assert_pass "G5.M17 --user snippet has no <INSTALL_PATH> placeholder"
fi

# G5.M18: --user snippet mentions Phase 5b (not UNSUPPORTED)
if grep -qF 'Phase 5b' "$SNIPPET"; then
  assert_pass "G5.M18 --user snippet mentions Phase 5b"
else
  assert_fail "G5.M18 --user snippet mentions Phase 5b"
fi

# G5.M19: uninstall --user removes snippet; prints manual removal instructions
out="$(bash "$UNINSTALL" --user 2>&1)"
if [ ! -f "$TMPHOME/.codex/harness-hooks.toml" ]; then
  assert_pass "G5.M19 uninstall --user removes snippet"
else
  assert_fail "G5.M19 uninstall --user removes snippet"
fi
if echo "$out" | grep -qE 'config\.toml|hooks\.SessionStart'; then
  assert_pass "G5.M19 uninstall --user prints manual removal instructions"
else
  assert_fail "G5.M19 uninstall --user prints manual removal instructions"
fi
if [ ! -f "$TMPHOME/.codex/config.toml" ]; then
  assert_pass "G5.M19 uninstall --user does NOT create config.toml"
else
  assert_fail "G5.M19 uninstall --user does NOT create config.toml"
fi

# ============================================================
echo ""
echo "=== Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then exit 1; fi
exit 0
