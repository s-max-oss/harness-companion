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

ISO1_BAD=""
while IFS= read -r test_file; do
  [ -n "$test_file" ] || continue
  if [ "$test_file" = "$ROOT/tests/run-all.sh" ]; then
    grep -Fq 'export HOME="$SUITE_ISOLATION_ROOT/home"' "$test_file" \
      || ISO1_BAD="$ISO1_BAD ${test_file#"$ROOT/"}"
  elif grep -Eq '^INSTALL_TEST_HOME="\$\(mktemp -d' "$test_file" \
       && grep -Fq 'export HOME="$INSTALL_TEST_HOME"' "$test_file"; then
    : # Explicit file-local disposable HOME binding.
  else
    ISO1_BAD="$ISO1_BAD ${test_file#"$ROOT/"}"
  fi
done < <(
  grep -RIlE '(~|\$\{?HOME\}?)/(\.claude|\.agents)/' "$ROOT/tests" \
    | while IFS= read -r candidate; do
        grep -nE '(~|\$\{?HOME\}?)/(\.claude|\.agents)/' "$candidate" \
          | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null && printf '%s\n' "$candidate"
      done \
    | LC_ALL=C sort -u
)
if [ -z "$ISO1_BAD" ]; then
  pass "ISO-1 every HOME-scoped Claude/Agents path is bound to a disposable HOME"
else
  fail "ISO-1 every HOME-scoped Claude/Agents path is bound to a disposable HOME" "$ISO1_BAD"
fi

ISO2_BAD=""
while IFS= read -r test_file; do
  literal_call=false
  assigned_call=false
  grep -Eq '^[[:space:]]*(if[[:space:]]+)?bash[[:space:]].*(^|/)install\.sh(["[:space:]]|$)' "$test_file" && literal_call=true
  if grep -Eq '^[A-Z0-9_]*INSTALL(ER)?=".*install\.sh"' "$test_file" \
     && grep -Eq 'bash[[:space:]]+"\$[A-Z0-9_]*INSTALL(ER)?"' "$test_file"; then
    assigned_call=true
  fi
  if [ "$literal_call" = true ] || [ "$assigned_call" = true ]; then
    if { grep -Eq '^INSTALL_TEST_HOME="\$\(mktemp -d' "$test_file" \
         || grep -Fq 'safe_mktemp INSTALL_TEST_HOME iso2-home' "$test_file"; } \
       && grep -Fq 'export HOME="$INSTALL_TEST_HOME"' "$test_file"; then
      :
    elif grep -Eq '^TMPHOME="\$\(mktemp -d' "$test_file" \
         && grep -Fq 'export HOME="$TMPHOME"' "$test_file"; then
      :
    else
      ISO2_BAD="$ISO2_BAD ${test_file#"$ROOT/"}"
    fi
  fi
done < <(find "$ROOT/tests" -name 'test-*.sh' -type f | LC_ALL=C sort)
if [ -z "$ISO2_BAD" ]; then
  pass "ISO-2 every actual installer invocation is bound to a file-local disposable HOME"
else
  fail "ISO-2 every actual installer invocation is bound to a file-local disposable HOME" "$ISO2_BAD"
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
