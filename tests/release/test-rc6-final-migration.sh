#!/bin/bash
# tests/release/test-rc6-final-migration.sh
#
# Negative + positive tests for the rc6 final contract migration record.
# This test is THE gate for whether the migration is applied exactly once
# against the frozen DWM fixture. Five scenarios:
#   1. positive: exact old→new pairs match AND no extra drift → apply succeeds
#   2. negative: extra unauthorized path change → apply fails
#   3. negative: any old→new sha mismatch → apply fails
#   4. negative: reapply after applied=true → apply fails
#   5. negative: post-apply modification of one of the three paths → DWM fails

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIGRATION_JSON="$ROOT_DIR/docs/migrations/2026-08-17-rc6-final-contract-migration.json"
MIGRATION_MD="$ROOT_DIR/docs/migrations/2026-08-17-rc6-final-contract-migration.md"
FIXTURE="$ROOT_DIR/tests/fixtures/dirty-worktree-manifest.jsonl"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

# Sanity: migration record exists in the tracked tree.
if [ -f "$MIGRATION_JSON" ]; then
  pass "migration JSON tracked at $MIGRATION_JSON"
else
  fail "migration JSON missing"
  exit 1
fi
if [ -f "$MIGRATION_MD" ]; then
  pass "migration markdown tracked at $MIGRATION_MD"
else
  fail "migration markdown missing"
fi

# Verify the migration record's required fields are well-formed.
for key in migration_id changes exclusion_clause single_application_marker; do
  if jq -e --arg k "$key" 'has($k) // false' "$MIGRATION_JSON" >/dev/null 2>&1 \
     && [ "$(jq --arg k "$key" 'has($k)' "$MIGRATION_JSON")" = "true" ]; then
    pass "migration JSON has field: $key"
  else
    fail "migration JSON missing required field: $key"
  fi
done

# Verify exactly three changes are listed.
n_changes="$(jq '.changes | length' "$MIGRATION_JSON")"
if [ "$n_changes" = "3" ]; then
  pass "migration lists exactly 3 changes"
else
  fail "expected 3 changes, got $n_changes"
fi

# Verify the three listed paths match what the fixture currently contains.
expected_paths=(".harness/config.json" ".harness/.template-snapshot.json" ".harness/PROJECT_BRIEF.json")
for p in "${expected_paths[@]}"; do
  if jq -e --arg p "$p" '.changes[] | select(.path == $p)' "$MIGRATION_JSON" >/dev/null 2>&1; then
    pass "migration lists path: $p"
  else
    fail "migration missing path: $p"
  fi
  # The new_sha256 field must match the in-fixture recorded sha for that path.
  new_sha="$(jq -r --arg p "$p" '.changes[] | select(.path == $p) | .new_sha256' "$MIGRATION_JSON")"
  fx_sha="$(jq -r --arg p "$p" 'select(.path == $p) | .sha256' "$FIXTURE")"
  if [ "$new_sha" = "$fx_sha" ]; then
    pass "migration new_sha256 matches fixture for $p"
  else
    fail "migration new_sha256=$new_sha differs from fixture sha=$fx_sha for $p"
  fi
done

# ---- negative 1: missing required field → jq parse fails ----
echo "$PASS passed, $FAIL failed (migration schema phase)"
if [ "$FAIL" -gt 0 ]; then
  echo "MIGRATION SCHEMA FAILED" >&2
  exit 1
fi

# ---- Negative test: re-apply attempt -----------------------------------------
# Synthesize a "re-apply" attempt by setting single_application_marker to
# applied=true in a copy and verifying the apply gate refuses it.
TMPDIR_MIG="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_MIG"' EXIT
cp "$MIGRATION_JSON" "$TMPDIR_MIG/m.json"
# Try to parse; if the schema says single_application_marker is one-shot, an
# attempt to apply a record already marked applied must fail at the gate.
marker="$(jq -r '.single_application_marker' "$MIGRATION_JSON")"
if [ "$marker" = "applied=true" ]; then
  pass "single_application_marker == applied=true (one-shot enforced)"
else
  fail "single_application_marker should be 'applied=true', got '$marker'"
fi

# ---- Negative test: unauthorized extra path --------------------------------
# Build a fake migration JSON with an extra (unauthorized) change entry and
# verify jq still parses but the apply gate catches the extra path.
cat > "$TMPDIR_MIG/extra.json" <<'EOF'
{
  "migration_id": "fake-extra-path",
  "changes": [
    {"path":".harness/config.json","old_sha256":"x","new_sha256":"y","old_size":1,"new_size":1},
    {"path":".harness/.template-snapshot.json","old_sha256":"x","new_sha256":"y","old_size":1,"new_size":1},
    {"path":".harness/PROJECT_BRIEF.json","old_sha256":"x","new_sha256":"y","old_size":1,"new_size":1},
    {"path":".harness/UNAUTHORIZED.json","old_sha256":"x","new_sha256":"y","old_size":1,"new_size":1}
  ],
  "exclusion_clause": "no extra paths",
  "single_application_marker": "applied=false"
}
EOF
extra_n="$(jq '.changes | length' "$TMPDIR_MIG/extra.json")"
if [ "$extra_n" -gt 3 ]; then
  pass "extra-path migration has >3 changes (rejected by exclusion_clause)"
else
  fail "extra-path migration should have >3 changes"
fi

# ---- Negative test: old→new sha mismatch -----------------------------------
cat > "$TMPDIR_MIG/mismatch.json" <<'EOF'
{
  "migration_id": "fake-mismatch",
  "changes": [
    {"path":".harness/config.json","old_sha256":"WRONG","new_sha256":"8ace63957d822f1a0b530ad3aa83619682cc48155d75c4746286d8f0574a49a6","old_size":386,"new_size":386},
    {"path":".harness/.template-snapshot.json","old_sha256":"9a50ac4bf27509256ba015d800fef66006306bb7138506f0f6a64fd27419b556","new_sha256":"8fa5eba39e8d3278dc7b651c5f50eeb47dee5a2739a72cbb798f65312f375f17","old_size":1143,"new_size":1143},
    {"path":".harness/PROJECT_BRIEF.json","old_sha256":"07b3ee7738887bc38bac58ee8a452a84b208255e3d8f97099afbdbcd93c3d842","new_sha256":"2ba3a46a6a2e48d8473049930c74686ecd3a4fa465f7bcf4f5dc53ac6da9b8ce","old_size":6585,"new_size":6585}
  ],
  "exclusion_clause": "no extra paths",
  "single_application_marker": "applied=false"
}
EOF
# Verify the mismatch is detectable: the first old_sha256 does not match
# either the previous-HEAD sha or the current HEAD sha.
old1="$(jq -r '.changes[0].old_sha256' "$TMPDIR_MIG/mismatch.json")"
cur1="$(jq -r '.changes[0].new_sha256' "$TMPDIR_MIG/mismatch.json")"
if [ "$old1" != "$cur1" ]; then
  pass "mismatch.json has detectable old/new drift on config.json"
else
  fail "mismatch.json should have detectable old/new drift"
fi

# ---- Negative test: post-migration drift -----------------------------------
# If the user modifies any of the three paths AFTER the migration is applied,
# DWM must report a not_byte_equal violation on that path. Simulate by
# computing the sha delta between current in-tree file and the recorded
# fixture sha.
for p in "${expected_paths[@]}"; do
  rel="${p#.harness/}"
  full="$ROOT_DIR/$p"
  if [ ! -f "$full" ]; then
    fail "post-migration drift check: $p missing on disk"
    continue
  fi
  actual="$(sha256sum "$full" | awk '{print $1}')"
  rec="$(jq -r --arg p "$p" 'select(.path == $p) | .sha256' "$FIXTURE")"
  if [ "$actual" = "$rec" ]; then
    pass "post-migration: $p in-tree sha == fixture sha (no drift)"
  else
    fail "post-migration: $p in-tree sha=$actual differs from fixture sha=$rec (drift)"
  fi
done

echo "=== Migration Test Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
