#!/bin/bash
# test-templates.sh — Phase 2: template schema validation tests
#
# Validates each of the 6 example configs against config.schema.json semantics
# (via core/lib/config-validate.sh). Plus asserts no `capability_level` field
# is present in any example.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
TEMPLATES_DIR="$ROOT_DIR/templates"
SCHEMA_FILE="$TEMPLATES_DIR/.harness/config.schema.json"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/config-validate.sh
source "$CORE_LIB/config-validate.sh"

PASSED=0
FAILED=0

assert_pass() {
  local name="$1"
  echo "PASS: $name"
  PASSED=$((PASSED + 1))
}

assert_fail() {
  local name="$1" reason="$2"
  echo "FAIL: $name — $reason"
  FAILED=$((FAILED + 1))
}

# ============================================================================
# Test 1-6: Each of the 6 example configs validates against the schema
# ============================================================================
EXAMPLES=("node" "python" "rust" "go" "docs" "generic")
for t in "${EXAMPLES[@]}"; do
  cfg="$TEMPLATES_DIR/.harness/config.json.${t}.example"
  echo ""
  echo "=== Validating $t example ==="
  if [ ! -f "$cfg" ]; then
    assert_fail "$t example file exists" "missing: $cfg"
    continue
  fi
  if validate_config_schema "$cfg" "$SCHEMA_FILE" 2>/dev/null; then
    assert_pass "config.json.${t}.example validates against schema"
  else
    # Capture stderr for diagnostic
    err="$(validate_config_schema "$cfg" "$SCHEMA_FILE" 2>&1 >/dev/null)"
    assert_fail "config.json.${t}.example validates against schema" "$err"
  fi
done

# ============================================================================
# Test 7-12: Each example has no `capability_level` field
# ============================================================================
for t in "${EXAMPLES[@]}"; do
  cfg="$TEMPLATES_DIR/.harness/config.json.${t}.example"
  echo ""
  echo "=== No capability_level in $t example ==="
  if jq -e 'has("capability_level")' "$cfg" >/dev/null 2>&1; then
    assert_fail "$t example has no capability_level" "field is present"
  else
    assert_pass "$t example has no capability_level"
  fi
done

# ============================================================================
# Test 13: docs example has empty verification.commands
# ============================================================================
echo ""
echo "=== docs example is 0-step ==="
docs_cfg="$TEMPLATES_DIR/.harness/config.json.docs.example"
docs_len="$(jq '.verification.commands | length' "$docs_cfg" 2>/dev/null)"
if [ "$docs_len" = "0" ]; then
  assert_pass "docs example has verification.commands: [] (0-step)"
else
  assert_fail "docs example has verification.commands: []" "got length=$docs_len"
fi

# ============================================================================
# Test 14: 0-step docs project produces no_checks via harness-verify
# (full integration: we run harness-verify on a docs project and check the
# terminal event has overall_result: no_checks)
# ============================================================================
echo ""
echo "=== 0-step docs → no_checks ==="

DOCS_PROJ="$(mktemp -d)"
trap "rm -rf '$DOCS_PROJ'" EXIT

mkdir -p "$DOCS_PROJ/.harness"
cp "$docs_cfg" "$DOCS_PROJ/.harness/config.json"
# Need a feature_list.json too — harness-verify requires it
cp "$TEMPLATES_DIR/feature_list.json" "$DOCS_PROJ/feature_list.json"

cd "$DOCS_PROJ"
bash "$ROOT_DIR/core/harness-verify.sh" "feature-001" "$DOCS_PROJ" 2>&1 | tail -3
RC=$?

LOG_FILE="$(ls "$DOCS_PROJ/.harness/logs/runs/"*.ndjson 2>/dev/null | head -1)"
if [ -z "$LOG_FILE" ]; then
  assert_fail "docs verify produced canonical NDJSON log" "no log file"
elif [ "$RC" != "1" ]; then
  assert_fail "docs verify exits 1 (no_checks)" "got RC=$RC"
else
  overall="$(jq -r 'select(.event=="run_completed") | .overall_result' "$LOG_FILE" 2>/dev/null)"
  planned="$(jq -r 'select(.event=="run_completed") | .planned_commands' "$LOG_FILE" 2>/dev/null)"
  if [ "$overall" = "no_checks" ] && [ "$planned" = "0" ]; then
    assert_pass "docs verify produces run_completed overall_result=no_checks planned_commands=0"
  else
    assert_fail "docs verify terminal event" "overall=$overall planned=$planned"
  fi
fi

# ============================================================================
# Test 15: negative — a config WITH capability_level is REJECTED
# ============================================================================
echo ""
echo "=== Negative: capability_level user field is rejected ==="
NEG="$(mktemp -d)"
trap "rm -rf '$NEG' '$DOCS_PROJ'" EXIT
cat > "$NEG/bad-config.json" <<'BAD'
{
  "project_type": "node",
  "capability_level": 2,
  "verification": { "commands": [] }
}
BAD
if validate_config_schema "$NEG/bad-config.json" 2>/dev/null; then
  assert_fail "config with capability_level is rejected" "validator accepted it"
else
  err="$(validate_config_schema "$NEG/bad-config.json" 2>&1 >/dev/null)"
  if printf '%s' "$err" | grep -qi "capability_level"; then
    assert_pass "config with capability_level is rejected (err mentions capability_level)"
  else
    assert_fail "config with capability_level rejection mentions field name" "got: $err"
  fi
fi

# ============================================================================
# Test 16: negative — invalid project_type is rejected
# ============================================================================
echo ""
echo "=== Negative: invalid project_type is rejected ==="
cat > "$NEG/bad-pt.json" <<'BADPT'
{
  "project_type": "cobol",
  "verification": { "commands": [] }
}
BADPT
if validate_config_schema "$NEG/bad-pt.json" 2>/dev/null; then
  assert_fail "invalid project_type rejected" "validator accepted cobol"
else
  err="$(validate_config_schema "$NEG/bad-pt.json" 2>&1 >/dev/null)"
  if printf '%s' "$err" | grep -qi "invalid project_type"; then
    assert_pass "invalid project_type rejected"
  else
    assert_fail "invalid project_type rejection message" "got: $err"
  fi
fi

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