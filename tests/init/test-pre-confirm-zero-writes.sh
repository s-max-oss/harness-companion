#!/bin/bash
# F-CONV-07 / AC-3: a guided rejection never crosses the executor boundary.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOUNDARY="$ROOT/scripts/harness-init-boundary.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARGET="$TMP/target"
mkdir -p "$TARGET/empty-dir"
printf 'user-owned\n' > "$TARGET/sentinel.txt"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ — $2}"; }

tree_manifest() {
  local root="$1" path mode digest target
  (
    cd "$root" || exit 1
    while IFS= read -r -d '' path; do
      mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || printf 'unknown')"
      if [ -L "$path" ]; then
        target="$(readlink "$path")"
        printf 'symlink\t%s\t%s\t%s\n' "$mode" "$path" "$target"
      elif [ -d "$path" ]; then
        printf 'directory\t%s\t%s\n' "$mode" "$path"
      else
        digest="$(sha256sum "$path" | awk '{print $1}')"
        printf 'file\t%s\t%s\t%s\n' "$mode" "$digest" "$path"
      fi
    done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
  )
}

for decision in reject cancel; do
  before="$(tree_manifest "$TARGET")"
  if output="$(bash "$BOUNDARY" "$TARGET" --decision "$decision" 2>&1)"; then
    pass "real guided boundary accepts $decision"
  else
    fail "real guided boundary accepts $decision" "$output"
  fi
  after="$(tree_manifest "$TARGET")"
  if [ "$before" = "$after" ]; then
    pass "guided $decision leaves full target tree byte-identical"
  else
    fail "guided $decision leaves full target tree byte-identical"
  fi
done

# Positive control: approval crosses the same production boundary and reaches
# the real executor, so the reject assertions cannot pass via an always-no-op
# test double.
APPROVED="$TMP/approved"
mkdir -p "$APPROVED"
jq -n '{schema_version:1,detected_type:"docs",goal:"Approved goal",success_criteria:["Approved criterion"],cadence:"stable",deadline:null,stack:"docs",test_framework:"none",secrets_handling:"unspecified",external_network:"ask",prohibitions:[],operation_preferences:{commit:"ask",push:"ask",merge:"ask",release:"ask",install_packages:"ask",external_mutation:"ask",destructive_ops:false},defaults_applied:[],conflicts_resolved:[],provenance:{},type_evidence:null}' > "$TMP/brief.json"
if cat "$TMP/brief.json" | bash "$BOUNDARY" "$APPROVED" --decision approve --brief-stdin --non-interactive --host=claude >/dev/null 2>&1; then
  pass "guided approval delegates the documented brief-stdin wire to the real executor"
else
  fail "guided approval delegates the documented brief-stdin wire to the real executor"
fi
if [ -f "$APPROVED/.harness/PROJECT_BRIEF.json" ]; then
  pass "guided approval produces executor artifact"
else
  fail "guided approval produces executor artifact"
fi

MALFORMED="$TMP/malformed-approval"
mkdir -p "$MALFORMED"
printf 'sentinel\n' > "$MALFORMED/sentinel"
before="$(tree_manifest "$MALFORMED")"
if bash "$BOUNDARY" "$MALFORMED" --decision approve >/dev/null 2>&1; then
  fail "approve without a resolved Brief fails closed"
else
  pass "approve without a resolved Brief fails closed"
fi
after="$(tree_manifest "$MALFORMED")"
if [ "$before" = "$after" ]; then
  pass "malformed approval leaves full target tree byte-identical"
else
  fail "malformed approval leaves full target tree byte-identical"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
