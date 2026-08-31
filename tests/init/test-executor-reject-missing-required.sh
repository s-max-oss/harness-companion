#!/bin/bash
# F-CONV-07 / AC-13a: resolved Briefs missing required fields fail closed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT="$ROOT/scripts/harness-init.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ — $2}"; }

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf 'unknown'
}

tree_manifest() {
  local root="$1" path mode digest target
  (
    cd "$root" || exit 1
    while IFS= read -r -d '' path; do
      mode="$(mode_of "$path")"
      if [ -L "$path" ]; then
        target="$(readlink "$path")"
        printf 'symlink\t%s\t%s\t%s\n' "$mode" "$path" "$target"
      elif [ -d "$path" ]; then
        printf 'directory\t%s\t%s\n' "$mode" "$path"
      elif [ -f "$path" ]; then
        digest="$(sha256sum "$path" | awk '{print $1}')"
        printf 'file\t%s\t%s\t%s\n' "$mode" "$digest" "$path"
      else
        printf 'other\t%s\t%s\n' "$mode" "$path"
      fi
    done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
  )
}

jq -n '{
  schema_version:1, detected_type:"python", goal:"Required goal",
  success_criteria:["Required criterion"], cadence:"stable", deadline:null,
  stack:"python", test_framework:"pytest", secrets_handling:"unspecified",
  external_network:"ask", prohibitions:[],
  operation_preferences:{commit:"ask",push:"ask",merge:"ask",release:"ask",install_packages:"ask",external_mutation:"ask",destructive_ops:false},
  defaults_applied:[], conflicts_resolved:[], provenance:{}, type_evidence:null
}' > "$TMP/valid.json"

run_case() {
  local name="$1" filter="$2" field="$3"
  local target="$TMP/target-$name" brief="$TMP/$name.json" err="$TMP/$name.err"
  local before after
  mkdir -p "$target/empty-dir"
  printf 'sentinel\n' > "$target/sentinel.txt"
  jq "$filter" "$TMP/valid.json" > "$brief"
  before="$(tree_manifest "$target")"

  if bash "$INIT" "$target" --brief "$brief" --non-interactive > /dev/null 2> "$err"; then
    fail "$name exits non-zero"
  else
    pass "$name exits non-zero"
  fi
  if grep -Fq "error: required field '$field' is missing or empty" "$err"; then
    pass "$name reports exact required-field diagnostic"
  else
    fail "$name reports exact required-field diagnostic" "$(tail -n 1 "$err")"
  fi
  after="$(tree_manifest "$target")"
  if [ "$before" = "$after" ]; then
    pass "$name leaves complete target tree unchanged"
  else
    fail "$name leaves complete target tree unchanged"
  fi
}

run_case missing-goal 'del(.goal)' goal
run_case empty-goal '.goal="   "' goal
run_case missing-success-criteria 'del(.success_criteria)' success_criteria
run_case empty-success-criteria '.success_criteria=[]' success_criteria
run_case whitespace-success-criterion '.success_criteria=["   "]' success_criteria

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
