#!/bin/bash
# F-CONV-07 / AC-10 + AC-16: automated static contract gates.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ — $2}"; }

# Comments are explicitly outside AC-10; all executable/source text is in
# scope. Keep the pattern assembled so this test does not match itself.
MEM_PATTERN='claude[-_]'"mem"
MEM_MATCHES="$(
  grep -RInE "$MEM_PATTERN" "$ROOT/core" "$ROOT/scripts" "$ROOT/templates" "$ROOT/adapters" "$ROOT/tests" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    || true
)"
if [ -z "$MEM_MATCHES" ]; then
  pass "AC-10 product and test code contain no claude memory integration"
else
  fail "AC-10 product and test code contain no claude memory integration" "$MEM_MATCHES"
fi

# The frozen rc.3 implementation window begins at the branch's Phase-1 gate.
# CI may override this for a PR with an equivalent base SHA.
AC16_BASE_SHA="${HARNESS_AC16_BASE_SHA:-37ecb7f34dd1cbe359605568b1e10cfb65b55326}"
if git -C "$ROOT" cat-file -e "$AC16_BASE_SHA^{commit}" 2>/dev/null; then
  CORE_LIB_DELTA="$(git -C "$ROOT" diff --numstat "$AC16_BASE_SHA..HEAD" -- core/lib \
    | awk '{if ($1 ~ /^[0-9]+$/) total += $1; if ($2 ~ /^[0-9]+$/) total += $2} END {print total + 0}')"
  if [ "$CORE_LIB_DELTA" -lt 50 ]; then
    pass "AC-16 core/lib added+deleted lines remain below 50 (actual=$CORE_LIB_DELTA)"
  else
    fail "AC-16 core/lib added+deleted lines remain below 50" "actual=$CORE_LIB_DELTA"
  fi
else
  fail "AC-16 base commit is available for an auditable line-count gate" "$AC16_BASE_SHA"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
