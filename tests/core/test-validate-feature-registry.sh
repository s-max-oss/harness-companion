#!/bin/bash
# test-validate-feature-registry.sh — Feature registry validator test suite
#
# Exercises validate_feature_registry(): valid registry (real repo file),
# revision, status enum, id format/unique, evidence arrays, passing-needs-
# evidence, and WIP limit. Requires: bash, jq.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/validate-feature-registry.sh
source "$CORE_LIB/validate-feature-registry.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---- helpers ----

# make_registry <revision> <json-features-array-literal>  → registry object JSON
make_registry() {
  jq -n --argjson revision "$1" --argjson features "$2" \
    '{revision:$revision, version:"2", schema_version:"2.0.0", single_active_feature:true, features:$features}'
}

assert_valid() {
  local test_name="$1" fl="$2" project="${3:-.}"
  if validate_feature_registry "$fl" "$project" >/dev/null 2>&1; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — expected valid (exit 0)"
    FAILED=$((FAILED + 1))
  fi
}

assert_invalid() {
  local test_name="$1" fl="$2" project="${3:-.}"
  if validate_feature_registry "$fl" "$project" >/dev/null 2>&1; then
    echo "FAIL: $test_name — expected invalid (exit 1)"
    FAILED=$((FAILED + 1))
  else
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  fi
}

# feature( <id> <status> [evidence_associations...] ) → feature object literal
feature() {
  local id="$1" status="$2"; shift 2
  jq -nc --arg id "$id" --arg status "$status" --argjson ev "[$(printf '%s' "$@")]" \
    '{id:$id, status:$status, evidence_associations:$ev, legacy_audit_evidence:[]}'
}

# ---- T1: valid registry (the real repo file) ----
if [ -f "$ROOT_DIR/feature_list.json" ]; then
  assert_valid "T1: real repo feature_list.json valid" "$ROOT_DIR/feature_list.json" "$ROOT_DIR"
else
  echo "SKIP: T1 — repo feature_list.json not found"
fi

F1="$(feature F-CONV-01 not_started)"
F2="$(feature F-CONV-02 not_started)"

# ---- T2: minimal valid registry ----
V2="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$F1]" > "$V2"
assert_valid "T2: minimal valid registry (revision 1, one feature)" "$V2" "$TMPDIR"

# ---- T3: invalid JSON ----
V3="$(mktemp "$TMPDIR/reg-XXXX.json")"
printf '{this is not json}\n' > "$V3"
assert_invalid "T3: invalid JSON → 1" "$V3"

# ---- T4: top level not an object ----
V4="$(mktemp "$TMPDIR/reg-XXXX.json")"
printf '["nope"]\n' > "$V4"
assert_invalid "T4: top level not an object → 1" "$V4"

# ---- T5: revision is a string ----
V5="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry '"2"' "[$F1]" > "$V5"
assert_invalid "T5: revision string → 1" "$V5"

# ---- T6: revision negative ----
V6="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry -3 "[$F1]" > "$V6"
assert_invalid "T6: negative revision → 1" "$V6"

# ---- T7: revision float (non-integer) ----
V7="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1.5 "[$F1]" > "$V7"
assert_invalid "T7: non-integer revision → 1" "$V7"

# ---- T8: empty features array ----
V8="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 '[]' > "$V8"
assert_invalid "T8: empty features → 1" "$V8"

# ---- T9: duplicate ids ----
V9="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$F1, $F1]" > "$V9"
assert_invalid "T9: duplicate feature id → 1" "$V9"

# ---- T10: invalid id (lowercase start) ----
V10="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"lower-start", status:"not_started", evidence_associations:[], legacy_audit_evidence:[]}')]" > "$V10"
assert_invalid "T10: lowercase-leading id → 1" "$V10"

# ---- T11: invalid id (illegal char) ----
V11="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"F-CONV-01!", status:"not_started", evidence_associations:[], legacy_audit_evidence:[]}')]" > "$V11"
assert_invalid "T11: id with illegal char → 1" "$V11"

# ---- T12: invalid status ----
V12="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"F-CONV-01", status:"bogus", evidence_associations:[], legacy_audit_evidence:[]}')]" > "$V12"
assert_invalid "T12: invalid status → 1" "$V12"

# ---- T13: passing without evidence ----
V13="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"F-CONV-01", status:"passing", evidence_associations:[], legacy_audit_evidence:[]}')]" > "$V13"
assert_invalid "T13: passing without evidence → 1" "$V13"

# ---- T14: passing WITH evidence valid ----
V14="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"F-CONV-01", status:"passing", evidence_associations:["core/harness-verify.sh"], legacy_audit_evidence:[]}')]" > "$V14"
assert_valid "T14: passing with evidence → 0" "$V14"

# ---- T14b (Contract 2, negative C): passing feature with [{}] evidence invalid ----
# A passing feature MUST have real evidence; an empty object {} binds no run_id
# and must be rejected by the per-item evidence_associations structure check.
V14b="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"F-CONV-01", status:"passing", evidence_associations:[{}], legacy_audit_evidence:[]}')]" > "$V14b"
assert_invalid "T14b: passing with [{}] evidence → 1" "$V14b"

# ---- T14c (Contract 2): object with EMPTY run_id invalid ----
V14c="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"F-CONV-01", status:"passing", evidence_associations:[{"run_id":""}], legacy_audit_evidence:[]}')]" > "$V14c"
assert_invalid "T14c: evidence object empty run_id → 1" "$V14c"

# ---- T14d (Contract 2): object with WRONG-TYPE run_id invalid ----
V14d="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"F-CONV-01", status:"passing", evidence_associations:[{"run_id":123}], legacy_audit_evidence:[]}')]" > "$V14d"
assert_invalid "T14d: evidence object numeric run_id → 1" "$V14d"

# ---- T14e (Contract 2 positive): object with valid non-empty string run_id ok ----
V14e="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$(jq -nc '{id:"F-CONV-01", status:"passing", evidence_associations:[{"run_id":"20260810T043039Z-821-29827"}], legacy_audit_evidence:[]}')]" > "$V14e"
assert_valid "T14e: evidence object valid run_id → 0" "$V14e"

# ---- T15: WIP limit exceeded (2 in_progress, default limit 1) ----
V15="$(mktemp "$TMPDIR/reg-XXXX.json")"
IP1="$(feature F-CONV-01 in_progress)"
IP2="$(feature F-CONV-02 in_progress)"
make_registry 1 "[$IP1, $IP2]" > "$V15"
assert_invalid "T15: WIP 2 > limit 1 → 1" "$V15"

# ---- T16: WIP within limit (2 in_progress, wip_limit 3 via config) ----
V16="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$IP1, $IP2]" > "$V16"
PROJ16="$(mktemp -d "$TMPDIR/proj16-XXXX")"
mkdir -p "$PROJ16/.harness"
printf '{"project_name":"p","wip_limit":3}\n' > "$PROJ16/.harness/config.json"
assert_valid "T16: WIP 2 <= limit 3 (config override) → 0" "$V16" "$PROJ16"

# ---- T17: one in_progress (limit 1) valid ----
V17="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "[$IP1, $F2]" > "$V17"
assert_valid "T17: WIP 1 <= limit 1 → 0" "$V17" "$TMPDIR"

# ---- T18: non-array evidence_associations ----
V18="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "$(jq -nc '{id:"F-CONV-01", status:"not_started", evidence_associations:"oops", legacy_audit_evidence:[]}')" > "$V18"
assert_invalid "T18: evidence_associations not an array → 1" "$V18"

# ---- T19: missing file ----
assert_invalid "T19: missing feature_list.json → 1" "$TMPDIR/does-not-exist.json" "$TMPDIR"

# ---- T20: all 6 statuses, single in_progress (limit 1) → valid ----
ALL_STATES="$(jq -nc '
  [{id:"F-01",status:"not_started",evidence_associations:[],legacy_audit_evidence:[]},
   {id:"F-02",status:"in_progress",evidence_associations:[],legacy_audit_evidence:[]},
   {id:"F-03",status:"blocked",evidence_associations:[],legacy_audit_evidence:[]},
   {id:"F-04",status:"passing",evidence_associations:["x"],legacy_audit_evidence:[]},
   {id:"F-05",status:"unverified",evidence_associations:[],legacy_audit_evidence:[]},
   {id:"F-06",status:"deprecated",evidence_associations:[],legacy_audit_evidence:[]}]')"
V20="$(mktemp "$TMPDIR/reg-XXXX.json")"
make_registry 1 "$ALL_STATES" > "$V20"
assert_valid "T20: all 6 statuses valid, WIP 1 <= limit 1 → 0" "$V20" "$TMPDIR"

echo ""
echo "Validate-Feature-Registry Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
