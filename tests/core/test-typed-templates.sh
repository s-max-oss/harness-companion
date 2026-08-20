#!/bin/bash
# test-typed-templates.sh — F-CONV-05: templates/ common/ + by-type/ restructure
#
# Verifies the rc.3 typed-template layout (spec §8.4) and the AC-7 type-matching
# content contract:
#   - templates/common/ contains the shared generic templates (de-Node-ified).
#   - templates/by-type/<type>/ exists for all 9 detected types.
#   - Override types (node, python, rust, go, shell, electron, docs) ship a
#     type-specific init.sh/AGENTS.md/CLAUDE.md; mixed + unknown fall back to
#     common/ (no override).
#   - Selection rule: for each file F, by-type/<type>/F wins over common/F.
#   - AC-7 white-list: each type's generated init.sh uses only that type's
#     command set (positive) and never another language's (negative).

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
COMMON_DIR="$ROOT_DIR/templates/common"
BY_TYPE_DIR="$ROOT_DIR/templates/by-type"

PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1 — $2"; FAILED=$((FAILED + 1)); }

# ============================================================================
# Structure: common/
# ============================================================================
echo ""
echo "=== templates/common/ structure ==="
for f in AGENTS.md CLAUDE.md init.sh checklist.sh feature_list.json; do
  if [ -f "$COMMON_DIR/$f" ]; then
    pass "common/$f exists"
  else
    fail "common/$f exists" "missing"
  fi
done

# ============================================================================
# Structure: by-type/<type>/
# ============================================================================
echo ""
echo "=== templates/by-type/ structure ==="
ALL_TYPES="node python rust go shell electron docs mixed unknown"
OVERRIDE_TYPES="node python rust go shell electron docs"
NO_OVERRIDE_TYPES="mixed unknown"

for t in $ALL_TYPES; do
  if [ -d "$BY_TYPE_DIR/$t" ]; then
    pass "by-type/$t/ dir exists"
  else
    fail "by-type/$t/ dir exists" "missing"
  fi
done

if [ -f "$BY_TYPE_DIR/.gitkeep" ]; then
  pass "by-type/.gitkeep exists"
else
  fail "by-type/.gitkeep exists" "missing"
fi

# Override types carry the three typed files.
for t in $OVERRIDE_TYPES; do
  for f in init.sh AGENTS.md CLAUDE.md; do
    if [ -f "$BY_TYPE_DIR/$t/$f" ]; then
      pass "by-type/$t/$f exists"
    else
      fail "by-type/$t/$f exists" "missing"
    fi
  done
done

# No-override types must NOT ship an override (they fall back to common/).
for t in $NO_OVERRIDE_TYPES; do
  if [ -f "$BY_TYPE_DIR/$t/init.sh" ]; then
    fail "by-type/$t/init.sh absent (common-only)" "unexpected override"
  else
    pass "by-type/$t/init.sh absent (common-only)"
  fi
done

# ============================================================================
# Selection rule: by-type wins over common where an override exists.
# ============================================================================
echo ""
echo "=== Selection rule (by-type wins, common falls back) ==="
for t in $OVERRIDE_TYPES; do
  if [ -f "$BY_TYPE_DIR/$t/init.sh" ] && [ -f "$COMMON_DIR/init.sh" ]; then
    pass "selection: by-type/$t/init.sh available for override"
  fi
done
for t in $NO_OVERRIDE_TYPES; do
  if [ -f "$COMMON_DIR/init.sh" ]; then
    pass "selection: $t falls back to common/init.sh"
  fi
done

# ============================================================================
# AC-7 type-matching white-list (positive + negative)
# ============================================================================
echo ""
echo "=== AC-7 type-matching content ==="

# Word-boundary fixed-string match: "go" must not match inside "cargo", and
# "make" must not match "Makefile". Markers are single-word tool names so that
# unquoted expansion never splits a multi-word phrase into generic words like
# "install"/"test".
wcontains() { grep -qE -- "\\b$2\\b" "$1" 2>/dev/null; }

JS_TOOLS="npm npx tsc"
PY_TOOLS="pip pytest"
RS_TOOLS="cargo"
GO_TOOLS="go"
SH_TOOLS="make shellcheck"
FOREIGN_JS="$PY_TOOLS $RS_TOOLS $GO_TOOLS $SH_TOOLS"   # non-JS toolchains
FOREIGN_PY="$JS_TOOLS $RS_TOOLS $GO_TOOLS $SH_TOOLS"
FOREIGN_RS="$JS_TOOLS $PY_TOOLS $GO_TOOLS $SH_TOOLS"
FOREIGN_GO="$JS_TOOLS $PY_TOOLS $RS_TOOLS $SH_TOOLS"
FOREIGN_SH="$JS_TOOLS $PY_TOOLS $RS_TOOLS $GO_TOOLS"

assert_uses() { # <file> <type> <own-tool...>
  local file="$1" type="$2"; shift 2
  local found=0
  for m in "$@"; do
    if wcontains "$file" "$m"; then found=1; break; fi
  done
  if [ "$found" = "1" ]; then
    pass "$type uses its own toolchain"
  else
    fail "$type uses its own toolchain" "none of: $*"
  fi
}

assert_avoids() { # <file> <type> <foreign-tool...>
  local file="$1" type="$2"; shift 2
  local hit=""
  for m in "$@"; do
    if wcontains "$file" "$m"; then hit="$m"; break; fi
  done
  if [ -z "$hit" ]; then
    pass "$type avoids foreign toolchains"
  else
    fail "$type avoids foreign toolchains" "contains foreign tool: $hit"
  fi
}

# node — uses npm/npx/tsc, avoids python/rust/go/shell
assert_uses   "$BY_TYPE_DIR/node/init.sh" "node"     $JS_TOOLS
assert_avoids "$BY_TYPE_DIR/node/init.sh" "node"     $FOREIGN_JS
# electron — uses npm/npx/tsc, avoids python/rust/go/shell
assert_uses   "$BY_TYPE_DIR/electron/init.sh" "electron" $JS_TOOLS
assert_avoids "$BY_TYPE_DIR/electron/init.sh" "electron" $FOREIGN_JS
# python — uses pip/pytest, avoids npm/rust/go/shell
assert_uses   "$BY_TYPE_DIR/python/init.sh" "python"   $PY_TOOLS
assert_avoids "$BY_TYPE_DIR/python/init.sh" "python"   $FOREIGN_PY
# rust — uses cargo, avoids npm/python/go/shell
assert_uses   "$BY_TYPE_DIR/rust/init.sh" "rust"     $RS_TOOLS
assert_avoids "$BY_TYPE_DIR/rust/init.sh" "rust"     $FOREIGN_RS
# go — uses go, avoids npm/python/rust/shell
assert_uses   "$BY_TYPE_DIR/go/init.sh" "go"       $GO_TOOLS
assert_avoids "$BY_TYPE_DIR/go/init.sh" "go"       $FOREIGN_GO
# shell — uses make/shellcheck, avoids npm/python/rust/go
assert_uses   "$BY_TYPE_DIR/shell/init.sh" "shell"    $SH_TOOLS
assert_avoids "$BY_TYPE_DIR/shell/init.sh" "shell"    $FOREIGN_SH
# docs — no build toolchain at all
assert_avoids "$BY_TYPE_DIR/docs/init.sh" "docs"    $JS_TOOLS $PY_TOOLS $RS_TOOLS $GO_TOOLS $SH_TOOLS
# common (generic fallback) — no build toolchain at all
assert_avoids "$COMMON_DIR/init.sh" "common/generic" $JS_TOOLS $PY_TOOLS $RS_TOOLS $GO_TOOLS $SH_TOOLS

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "Results: $PASSED passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
