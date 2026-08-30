#!/bin/bash
# F-CONV-07 / AC-12: repository tests use isolated homes and targets.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT="$ROOT/scripts/harness-init.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ISOLATED_HOME="$TMP/home"
SIMULATED_INSTALL="$ISOLATED_HOME/.claude/skills/harness-companion"
TARGET="$TMP/target"
mkdir -p "$SIMULATED_INSTALL" "$TARGET"
printf 'must-not-change\n' > "$SIMULATED_INSTALL/.sentinel"
SENTINEL_BEFORE="$(sha256sum "$SIMULATED_INSTALL/.sentinel" | awk '{print $1}')"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ — $2}"; }

if grep -R -nE '(^|[^$[:alnum:]_])~/(\.claude|\.agents)/' "$ROOT/tests" >/dev/null 2>&1; then
  fail "ISO-1 tests contain no literal real-home install path"
else
  pass "ISO-1 tests contain no literal real-home install path"
fi

ISO2_BAD=""
while IFS= read -r test_file; do
  if grep -q 'install\.sh' "$test_file" \
     && ! grep -Eq 'mktemp -d|INSTALL_TARGET=|HOME=' "$test_file"; then
    ISO2_BAD="$ISO2_BAD ${test_file#"$ROOT/"}"
  fi
done < <(find "$ROOT/tests" -name 'test-*.sh' -type f | LC_ALL=C sort)
if [ -z "$ISO2_BAD" ]; then
  pass "ISO-2 install tests declare an isolated HOME or install target"
else
  fail "ISO-2 install tests declare an isolated HOME or install target" "$ISO2_BAD"
fi

if grep -qE 'HOME=.*runner\.temp|HOME=.*RUNNER_TEMP|echo "HOME=.*GITHUB_ENV' "$ROOT/.github/workflows/ci.yml"; then
  pass "ISO-3 CI sets HOME to runner temp"
else
  fail "ISO-3 CI sets HOME to runner temp"
fi
if grep -Fq 'export HOME="$SUITE_ISOLATION_ROOT/home"' "$ROOT/tests/run-all.sh" \
   && grep -Fq 'ISO-4 full-suite simulated installed-skill sentinel unchanged' "$ROOT/tests/run-all.sh"; then
  pass "ISO-4 full-suite runner isolates HOME and verifies its sentinel"
else
  fail "ISO-4 full-suite runner isolates HOME and verifies its sentinel"
fi

jq -n '{schema_version:1,detected_type:"docs",goal:"Isolation check",success_criteria:["No external writes"],cadence:"stable",deadline:null,stack:"docs",test_framework:"none",secrets_handling:"unspecified",external_network:"denied",prohibitions:[],operation_preferences:{commit:"ask",push:"ask",merge:"ask",release:"ask",install_packages:"denied",external_mutation:"denied",destructive_ops:false},defaults_applied:[],conflicts_resolved:[],provenance:{},type_evidence:null}' > "$TMP/brief.json"

if HOME="$ISOLATED_HOME" bash "$INIT" "$TARGET" --brief "$TMP/brief.json" --non-interactive >/dev/null 2>&1; then
  pass "isolated executor fixture completes"
else
  fail "isolated executor fixture completes"
fi

SENTINEL_AFTER="$(sha256sum "$SIMULATED_INSTALL/.sentinel" | awk '{print $1}')"
if [ "$SENTINEL_BEFORE" = "$SENTINEL_AFTER" ]; then
  pass "ISO-4 simulated installed-skill sentinel is unchanged"
else
  fail "ISO-4 simulated installed-skill sentinel is unchanged"
fi
if [ ! -e "$ISOLATED_HOME/.agents" ]; then
  pass "executor creates no simulated agents home state"
else
  fail "executor creates no simulated agents home state"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
