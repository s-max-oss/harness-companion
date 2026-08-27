#!/bin/bash
# test-brief-integrity.sh — Acyclic Brief/snapshot integrity test suite
#
# Exercises validate_brief_integrity(): PROJECT_BRIEF.json schema/fields,
# PROJECT_BRIEF.md presence + header parity (schema_version / source_version /
# git rev), snapshot schema, digest (template_manifest_digest == sha256 of
# snapshot), and the acyclic rule (snapshot must not reference the Brief).
# Requires: bash, jq, sha256sum.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/brief-integrity.sh
source "$CORE_LIB/brief-integrity.sh"
# shellcheck source=../../core/lib/template-contract-migration.sh
source "$CORE_LIB/template-contract-migration.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

REV="c5ca2127792c21135ea76847e274971696cc4a32"

# ---- helpers ----

assert_valid() {
  local test_name="$1" project="${2:-.}"
  if validate_brief_integrity "$project" >/dev/null 2>&1; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — expected valid (exit 0)"
    FAILED=$((FAILED + 1))
  fi
}

assert_invalid() {
  local test_name="$1" project="${2:-.}"
  if validate_brief_integrity "$project" >/dev/null 2>&1; then
    echo "FAIL: $test_name — expected invalid (exit 1)"
    FAILED=$((FAILED + 1))
  else
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  fi
}

# build_project <dir> — construct a VALID brief triple in <dir>/.harness
build_project() {
  local dir="$1"
  mkdir -p "$dir/.harness"
  # snapshot WITHOUT any Brief reference (acyclic)
  jq -n --arg rev "$REV" \
    '{captured_from_git_rev:$rev, schema_version:1, source_version:"2.0.0-rc.2",
      templates:{".harness/config.json":{sha256:"c43af489f15b60f5d480800063869a801adae82bc18552a3334e650f87610553",source:"t"},
                 "AGENTS.md":{sha256:"6e787f7a6167a18110dfb9bd1462836e36c5cea472da0271dfe915bdbe634d69",source:"t"},
                 "init.sh":{sha256:"468b3c16290fd7cdd8fc6bb09e3a0336ddff30c4ebad0546cbc6751724e7cef1",source:"t"}}}' \
    > "$dir/.harness/.template-snapshot.json"
  local snap_sha
  snap_sha="$(sha256sum "$dir/.harness/.template-snapshot.json" | awk '{print $1}')"
  jq -n --arg rev "$REV" --arg digest "$snap_sha" \
    '{advisory:true, captured_from_git_rev:$rev, schema_version:1,
      source_version:"2.0.0-rc.2", generated_by:"harness-companion v2.0.0-rc.2",
      template_manifest_digest:$digest, goal:"g", success_criteria:["a"]}' \
    > "$dir/.harness/PROJECT_BRIEF.json"
  printf '%s\n' '<!-- generated from PROJECT_BRIEF.json schema_version=1 source_version=2.0.0-rc.2 -->' \
    '<!-- DO NOT EDIT — regenerate from JSON. On mismatch, JSON is authoritative. -->' \
    "<!-- git rev $REV -->" \
    '' \
    '# Project Brief' > "$dir/.harness/PROJECT_BRIEF.md"
}

# ---- T1: valid triple built from scratch ----
P1="$(mktemp -d "$TMPDIR/p1-XXXX")"
build_project "$P1"
assert_valid "T1: valid brief/snapshot triple → 0" "$P1"

# ---- T1b: real repo triple (presence/parity on actual files) ----
if [ -f "$ROOT_DIR/.harness/PROJECT_BRIEF.json" ] \
   && [ -f "$ROOT_DIR/.harness/PROJECT_BRIEF.md" ] \
   && [ -f "$ROOT_DIR/.harness/.template-snapshot.json" ]; then
  assert_valid "T1b: real repo brief triple valid" "$ROOT_DIR"
else
  echo "SKIP: T1b — repo brief files incomplete"
fi

# ---- T2: missing PROJECT_BRIEF.md ----
P2="$(mktemp -d "$TMPDIR/p2-XXXX")"
build_project "$P2"
rm -f "$P2/.harness/PROJECT_BRIEF.md"
assert_invalid "T2: missing PROJECT_BRIEF.md → 1" "$P2"

# ---- T3: MD schema_version mismatch ----
P3="$(mktemp -d "$TMPDIR/p3-XXXX")"
build_project "$P3"
sed -i 's/schema_version=1/schema_version=2/' "$P3/.harness/PROJECT_BRIEF.md"
assert_invalid "T3: MD schema_version mismatch → 1" "$P3"

# ---- T4: MD source_version mismatch ----
P4="$(mktemp -d "$TMPDIR/p4-XXXX")"
build_project "$P4"
sed -i 's/source_version=2.0.0-rc.2/source_version=9.9.9/' "$P4/.harness/PROJECT_BRIEF.md"
assert_invalid "T4: MD source_version mismatch → 1" "$P4"

# ---- T5: MD rev not a prefix of JSON rev ----
P5="$(mktemp -d "$TMPDIR/p5-XXXX")"
build_project "$P5"
sed -i "s/git rev $REV/git rev 1111111111111111111111111111111111111111/" "$P5/.harness/PROJECT_BRIEF.md"
assert_invalid "T5: MD rev not a prefix of JSON rev → 1" "$P5"

# ---- T6: digest mismatch (Brief digest != snapshot sha) ----
P6="$(mktemp -d "$TMPDIR/p6-XXXX")"
build_project "$P6"
jq '.template_manifest_digest = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$P6/.harness/PROJECT_BRIEF.json" > "$P6/.harness/PROJECT_BRIEF.json.tmp"
mv "$P6/.harness/PROJECT_BRIEF.json.tmp" "$P6/.harness/PROJECT_BRIEF.json"
assert_invalid "T6: Brief digest != snapshot sha → 1" "$P6"

# ---- T7: snapshot references PROJECT_BRIEF.json (cycle) ----
P7="$(mktemp -d "$TMPDIR/p7-XXXX")"
build_project "$P7"
jq '.templates[".harness/PROJECT_BRIEF.json"] = {sha256:"0000000000000000000000000000000000000000000000000000000000000000",source:"brief"}' \
  "$P7/.harness/.template-snapshot.json" > "$P7/.harness/.template-snapshot.json.tmp"
mv "$P7/.harness/.template-snapshot.json.tmp" "$P7/.harness/.template-snapshot.json"
# digest must be recomputed to reflect the (now cyclic) snapshot; do so so the
# failure is purely the acyclic rule.
SNAP_SHA7="$(sha256sum "$P7/.harness/.template-snapshot.json" | awk '{print $1}')"
jq --arg d "$SNAP_SHA7" '.template_manifest_digest = $d' \
  "$P7/.harness/PROJECT_BRIEF.json" > "$P7/.harness/PROJECT_BRIEF.json.tmp"
mv "$P7/.harness/PROJECT_BRIEF.json.tmp" "$P7/.harness/PROJECT_BRIEF.json"
assert_invalid "T7: snapshot references PROJECT_BRIEF.json (cycle) → 1" "$P7"

# ---- T8: missing snapshot ----
P8="$(mktemp -d "$TMPDIR/p8-XXXX")"
build_project "$P8"
rm -f "$P8/.harness/.template-snapshot.json"
assert_invalid "T8: missing snapshot → 1" "$P8"

# ---- T9: snapshot schema_version != 1 ----
P9="$(mktemp -d "$TMPDIR/p9-XXXX")"
build_project "$P9"
jq '.schema_version = 2' "$P9/.harness/.template-snapshot.json" > "$P9/.harness/.template-snapshot.json.tmp"
mv "$P9/.harness/.template-snapshot.json.tmp" "$P9/.harness/.template-snapshot.json"
assert_invalid "T9: snapshot schema_version != 1 → 1" "$P9"

# ---- T10: JSON schema_version != 1 ----
P10="$(mktemp -d "$TMPDIR/p10-XXXX")"
build_project "$P10"
jq '.schema_version = 2' "$P10/.harness/PROJECT_BRIEF.json" > "$P10/.harness/PROJECT_BRIEF.json.tmp"
mv "$P10/.harness/PROJECT_BRIEF.json.tmp" "$P10/.harness/PROJECT_BRIEF.json"
assert_invalid "T10: JSON schema_version != 1 → 1" "$P10"

# ---- T11: missing PROJECT_BRIEF.json ----
P11="$(mktemp -d "$TMPDIR/p11-XXXX")"
build_project "$P11"
rm -f "$P11/.harness/PROJECT_BRIEF.json"
assert_invalid "T11: missing PROJECT_BRIEF.json → 1" "$P11"

# ---- T12: deliberate immutable evolution uses a committed migration --------
P12="$(mktemp -d "$TMPDIR/p12-XXXX")"
mkdir -p "$P12/.harness" "$P12/docs/template-contract-migrations"
git -C "$P12" init -q
git -C "$P12" config user.email test@example.invalid
git -C "$P12" config user.name harness-test
printf '%s\n' 'config-v1' > "$P12/.harness/config.json"
printf '%s\n' 'agents-v1' > "$P12/AGENTS.md"
printf '%s\n' 'claude-v1' > "$P12/CLAUDE.md"
printf '%s\n' 'init-v1' > "$P12/init.sh"
C12="$(_tcm_sha256_file "$P12/.harness/config.json")"
A12_OLD="$(_tcm_sha256_file "$P12/AGENTS.md")"
CL12_OLD="$(_tcm_sha256_file "$P12/CLAUDE.md")"
I12_OLD="$(_tcm_sha256_file "$P12/init.sh")"
jq -n --arg c "$C12" --arg a "$A12_OLD" --arg cl "$CL12_OLD" --arg i "$I12_OLD" \
  '{schema_version:1,source_version:"test",captured_from_git_rev:null,
    templates:{".harness/config.json":{source:"t",sha256:$c},
      "AGENTS.md":{source:"t",sha256:$a},"CLAUDE.md":{source:"t",sha256:$cl},
      "init.sh":{source:"t",sha256:$i}}}' > "$P12/.harness/.template-snapshot.json"
printf '%s\n' 'agents-v2' > "$P12/AGENTS.md"
printf '%s\n' 'claude-v2' > "$P12/CLAUDE.md"
printf '%s\n' 'init-v2' > "$P12/init.sh"
git -C "$P12" add -- .harness AGENTS.md CLAUDE.md init.sh
git -C "$P12" commit -qm 'base contract evolution'
P12_PARENT="$(git -C "$P12" rev-parse HEAD)"
P12_SNAP="$(_tcm_sha256_file "$P12/.harness/.template-snapshot.json")"
A12_NEW="$(_tcm_sha256_file "$P12/AGENTS.md")"
CL12_NEW="$(_tcm_sha256_file "$P12/CLAUDE.md")"
I12_NEW="$(_tcm_sha256_file "$P12/init.sh")"
jq -n --arg parent "$P12_PARENT" --arg snap "$P12_SNAP" \
  --arg ao "$A12_OLD" --arg an "$A12_NEW" --arg co "$CL12_OLD" --arg cn "$CL12_NEW" \
  --arg io "$I12_OLD" --arg inn "$I12_NEW" \
  '{schema_version:1,migration_id:"test-contract-v2",authorization_parent:$parent,
    snapshot_sha256:$snap,reason:"test deliberate contract evolution",
    changes:[{path:"AGENTS.md",snapshot_sha256:$ao,authorized_sha256:$an},
      {path:"CLAUDE.md",snapshot_sha256:$co,authorized_sha256:$cn},
      {path:"init.sh",snapshot_sha256:$io,authorized_sha256:$inn}]}' \
  > "$P12/docs/template-contract-migrations/test.json"
git -C "$P12" add -- docs/template-contract-migrations/test.json
git -C "$P12" commit -qm 'authorize contract evolution'
T12_ID="$(validate_template_contract_migration "$P12" "$P12/.harness/.template-snapshot.json" \
  .harness/config.json AGENTS.md CLAUDE.md init.sh 2>/dev/null)"; T12_RC=$?
if [ "$T12_RC" = 0 ] && [ "$T12_ID" = "test-contract-v2" ]; then
  echo "PASS: T12a: exact committed migration authorizes deliberate evolution"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: T12a: exact committed migration should authorize evolution"
  FAILED=$((FAILED + 1))
fi
printf '%s\n' 'tampered-after-authorization' > "$P12/AGENTS.md"
if validate_template_contract_migration "$P12" "$P12/.harness/.template-snapshot.json" \
    .harness/config.json AGENTS.md CLAUDE.md init.sh >/dev/null 2>&1; then
  echo "FAIL: T12b: post-authorization drift must fail closed"
  FAILED=$((FAILED + 1))
else
  echo "PASS: T12b: post-authorization drift fails closed"
  PASSED=$((PASSED + 1))
fi

echo ""
echo "Brief-Integrity Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
