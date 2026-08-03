#!/bin/bash
# test-init.sh — Phase 2: project-type detection and init.sh tests
#
# Verifies:
#   - detect_project_type correctly classifies node/python/rust/go/docs/generic
#   - init.sh scaffolds the right config example for each detected type
#   - docs init produces 0-step config (no_checks)
#   - .gitignore is updated with .harness/logs/

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"
TEMPLATES_DIR="$ROOT_DIR/templates"

# shellcheck source=../../core/lib/project-detect.sh
source "$CORE_LIB/project-detect.sh"

PASSED=0
FAILED=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name (expected=$expected, got=$actual)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — expected=$expected, got=$actual"
    FAILED=$((FAILED + 1))
  fi
}

assert_file_exists() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — file missing: $path"
    FAILED=$((FAILED + 1))
  fi
}

# ============================================================================
# Project-type detection tests
# ============================================================================
echo ""
echo "=== Project-type detection ==="

# Set up minimal marker files in temp dirs
TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

# 1. node
mkdir -p "$TMP/node"
touch "$TMP/node/package.json"
got="$(detect_project_type "$TMP/node")"
assert_eq "node: package.json → node" "node" "$got"

# 2. python (pyproject.toml)
mkdir -p "$TMP/pyproject"
touch "$TMP/pyproject/pyproject.toml"
got="$(detect_project_type "$TMP/pyproject")"
assert_eq "python: pyproject.toml → python" "python" "$got"

# 3. python (setup.py fallback)
mkdir -p "$TMP/setup-py"
touch "$TMP/setup-py/setup.py"
got="$(detect_project_type "$TMP/setup-py")"
assert_eq "python: setup.py → python" "python" "$got"

# 4. python (requirements.txt fallback)
mkdir -p "$TMP/requirements"
touch "$TMP/requirements/requirements.txt"
got="$(detect_project_type "$TMP/requirements")"
assert_eq "python: requirements.txt → python" "python" "$got"

# 5. rust
mkdir -p "$TMP/rust"
touch "$TMP/rust/Cargo.toml"
got="$(detect_project_type "$TMP/rust")"
assert_eq "rust: Cargo.toml → rust" "rust" "$got"

# 6. go
mkdir -p "$TMP/go"
touch "$TMP/go/go.mod"
got="$(detect_project_type "$TMP/go")"
assert_eq "go: go.mod → go" "go" "$got"

# 7. docs (no source markers + has *.md)
mkdir -p "$TMP/docs"
touch "$TMP/docs/README.md"
got="$(detect_project_type "$TMP/docs")"
assert_eq "docs: *.md at root, no source markers → docs" "docs" "$got"

# 8. generic (empty dir)
mkdir -p "$TMP/empty"
got="$(detect_project_type "$TMP/empty")"
assert_eq "generic: empty dir → generic" "generic" "$got"

# 9. precedence — node wins over docs (has package.json + README.md)
mkdir -p "$TMP/node-docs"
touch "$TMP/node-docs/package.json"
touch "$TMP/node-docs/README.md"
got="$(detect_project_type "$TMP/node-docs")"
assert_eq "precedence: package.json + README.md → node (not docs)" "node" "$got"

# 10. python wins over docs
mkdir -p "$TMP/py-docs"
touch "$TMP/py-docs/pyproject.toml"
touch "$TMP/py-docs/README.md"
got="$(detect_project_type "$TMP/py-docs")"
assert_eq "precedence: pyproject.toml + README.md → python (not docs)" "python" "$got"

# 11. docs detection: docs/ subdirectory also qualifies
mkdir -p "$TMP/docs-sub"
mkdir -p "$TMP/docs-sub/docs"
touch "$TMP/docs-sub/docs/index.md"
got="$(detect_project_type "$TMP/docs-sub")"
assert_eq "docs: docs/ subdirectory → docs" "docs" "$got"

# ============================================================================
# init.sh integration tests
# ============================================================================
echo ""
echo "=== init.sh integration ==="

# 12. init on a node project writes node example
INIT_NODE="$(mktemp -d)"
mkdir -p "$INIT_NODE"
touch "$INIT_NODE/package.json"
bash "$TEMPLATES_DIR/init.sh" "$INIT_NODE" 2>&1 | tail -3 > /dev/null
got_type="$(jq -r '.project_type' "$INIT_NODE/.harness/config.json" 2>/dev/null)"
assert_eq "init.sh on node project writes node config" "node" "$got_type"
assert_file_exists "init.sh created feature_list.json" "$INIT_NODE/feature_list.json"
if [ -d "$INIT_NODE/.harness/logs/runs" ]; then
  echo "PASS: init.sh created .harness/logs/runs/ directory"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: init.sh created .harness/logs/runs/ — directory missing"
  FAILED=$((FAILED + 1))
fi
if grep -qF ".harness/logs/" "$INIT_NODE/.gitignore" 2>/dev/null; then
  echo "PASS: init.sh updated .gitignore"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: init.sh updated .gitignore — no .harness/logs/ entry"
  FAILED=$((FAILED + 1))
fi

# 13. init on a docs project writes 0-step docs config
INIT_DOCS="$(mktemp -d)"
mkdir -p "$INIT_DOCS"
touch "$INIT_DOCS/README.md"
touch "$INIT_DOCS/CONTRIBUTING.md"
bash "$TEMPLATES_DIR/init.sh" "$INIT_DOCS" 2>&1 | tail -3 > /dev/null
got_type="$(jq -r '.project_type' "$INIT_DOCS/.harness/config.json" 2>/dev/null)"
assert_eq "init.sh on docs project writes docs config" "docs" "$got_type"
got_len="$(jq '.verification.commands | length' "$INIT_DOCS/.harness/config.json" 2>/dev/null)"
assert_eq "init.sh on docs project → verification.commands: []" "0" "$got_len"

# 14. init is idempotent (second run doesn't overwrite without --force-config)
bash "$TEMPLATES_DIR/init.sh" "$INIT_DOCS" 2>&1 | tail -3 > /dev/null
# No change should have occurred
got_type2="$(jq -r '.project_type' "$INIT_DOCS/.harness/config.json" 2>/dev/null)"
assert_eq "init.sh idempotent: type unchanged on re-run" "docs" "$got_type2"

# 15. init on a python project writes python example
INIT_PY="$(mktemp -d)"
mkdir -p "$INIT_PY"
touch "$INIT_PY/pyproject.toml"
bash "$TEMPLATES_DIR/init.sh" "$INIT_PY" 2>&1 | tail -3 > /dev/null
got_type="$(jq -r '.project_type' "$INIT_PY/.harness/config.json" 2>/dev/null)"
assert_eq "init.sh on python project writes python config" "python" "$got_type"

# 16. init on a rust project writes rust example
INIT_RUST="$(mktemp -d)"
mkdir -p "$INIT_RUST"
touch "$INIT_RUST/Cargo.toml"
bash "$TEMPLATES_DIR/init.sh" "$INIT_RUST" 2>&1 | tail -3 > /dev/null
got_type="$(jq -r '.project_type' "$INIT_RUST/.harness/config.json" 2>/dev/null)"
assert_eq "init.sh on rust project writes rust config" "rust" "$got_type"

# 17. init on a go project writes go example
INIT_GO="$(mktemp -d)"
mkdir -p "$INIT_GO"
touch "$INIT_GO/go.mod"
bash "$TEMPLATES_DIR/init.sh" "$INIT_GO" 2>&1 | tail -3 > /dev/null
got_type="$(jq -r '.project_type' "$INIT_GO/.harness/config.json" 2>/dev/null)"
assert_eq "init.sh on go project writes go config" "go" "$got_type"

# 18. init on empty project writes generic example
INIT_EMPTY="$(mktemp -d)"
mkdir -p "$INIT_EMPTY"
bash "$TEMPLATES_DIR/init.sh" "$INIT_EMPTY" 2>&1 | tail -3 > /dev/null
got_type="$(jq -r '.project_type' "$INIT_EMPTY/.harness/config.json" 2>/dev/null)"
assert_eq "init.sh on empty project writes generic config" "generic" "$got_type"

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