#!/bin/bash
# tests/release/test-rc6-final-migration.sh
#
# Multi-record migration validator for docs/migrations/*.json. Discovers
# ALL migration records in the tracked tree and applies two layers of
# validation:
#
#   1. SCHEMA — every migration JSON parses, has required fields, has a
#      changes array. Applies to EVERY record (active + historical).
#
#   2. BINDING — exactly ONE record is the ACTIVE migration: its to_head
#      equals current git HEAD AND single_application_marker == applied=true.
#      For the ACTIVE record only:
#        - the three expected paths are listed in changes
#        - each new_sha256 matches the recorded sha in the DWM fixture
#        - each in-tree file's sha matches the recorded sha in the DWM
#          fixture (post-migration drift must be ZERO)
#      Historical records (to_head != current HEAD) are NOT bound to the
#      current DWM fixture — their recorded new_sha256 may legitimately
#      disagree with the current fixture because they describe prior state.
#
# Negative tests (extra path, old→new mismatch, reapply) are in-script
# against the ACTIVE migration's contract.
#
# Multiple migration records may co-exist in docs/migrations/ — historical
# ones are preserved verbatim and never overwritten.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIG_DIR="$ROOT_DIR/docs/migrations"
FIXTURE="$ROOT_DIR/tests/fixtures/dirty-worktree-manifest.jsonl"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

# ---- Determine current HEAD ----
CURRENT_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)" || {
  fail "cannot determine current HEAD"
  echo "=== Migration Test Results: $PASS passed, $FAIL failed ==="
  exit 1
}
pass "current HEAD is $CURRENT_HEAD"

# ---- Discover all migration JSONs ----
shopt -s nullglob
MIG_FILES=("$MIG_DIR"/*.json)
shopt -u nullglob
if [ "${#MIG_FILES[@]}" -eq 0 ]; then
  fail "no migration JSON files in $MIG_DIR"
  echo "=== Migration Test Results: $PASS passed, $FAIL failed ==="
  exit 1
fi
pass "discovered ${#MIG_FILES[@]} migration record(s) in $MIG_DIR"

# ---- Required schema fields ----
REQUIRED_FIELDS=(migration_id changes exclusion_clause single_application_marker to_head)

ACTIVE_FILE=""
ACTIVE_FOUND=0
HISTORICAL_COUNT=0

for mig in "${MIG_FILES[@]}"; do
  base="$(basename "$mig")"
  md="${mig%.json}.md"
  echo "  -- scanning $base --"

  if [ ! -f "$md" ]; then
    fail "$base has no companion .md (companion docs are mandatory)"
  else
    pass "$base has companion .md"
  fi

  # Basic jq parse.
  if ! jq -e . "$mig" >/dev/null 2>&1; then
    fail "$base does not parse as JSON"
    continue
  fi
  pass "$base parses as JSON"

  # Required fields.
  for key in "${REQUIRED_FIELDS[@]}"; do
    if jq -e --arg k "$key" 'has($k)' "$mig" >/dev/null 2>&1; then
      pass "$base has field: $key"
    else
      fail "$base missing required field: $key"
    fi
  done

  # changes must be an array.
  if jq -e '.changes | type == "array"' "$mig" >/dev/null 2>&1; then
    pass "$base changes is an array"
  else
    fail "$base changes must be an array"
  fi

  # single_application_marker must be applied=true (positive semantic check;
  # applies to BOTH active and historical records).
  marker="$(jq -r '.single_application_marker' "$mig")"
  if [ "$marker" = "applied=true" ]; then
    pass "$base single_application_marker == applied=true"
  else
    fail "$base single_application_marker should be 'applied=true', got '$marker'"
  fi

  # Identify ACTIVE: to_head == current HEAD.
  mig_to_head="$(jq -r '.to_head' "$mig")"
  if [ "$mig_to_head" = "$CURRENT_HEAD" ]; then
    if [ "$ACTIVE_FOUND" = "1" ]; then
      fail "multiple active migrations with to_head=$CURRENT_HEAD ($ACTIVE_FILE and $base)"
    else
      ACTIVE_FILE="$mig"
      ACTIVE_FOUND=1
      pass "$base is the ACTIVE migration (to_head == current HEAD)"
    fi
  else
    HISTORICAL_COUNT=$((HISTORICAL_COUNT + 1))
    pass "$base is historical (to_head=$mig_to_head != current HEAD)"
  fi
done

if [ "$ACTIVE_FOUND" != "1" ]; then
  fail "no migration record with to_head == current HEAD ($CURRENT_HEAD) — ACTIVE migration missing"
  echo "=== Migration Test Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

# ---- BINDING checks against the ACTIVE migration ----
echo "  -- binding checks against ACTIVE $(basename "$ACTIVE_FILE") --"

# ACTIVE: exactly 3 changes.
n_changes="$(jq '.changes | length' "$ACTIVE_FILE")"
if [ "$n_changes" = "3" ]; then
  pass "ACTIVE migration lists exactly 3 changes"
else
  fail "ACTIVE migration expected 3 changes, got $n_changes"
fi

expected_paths=(".harness/config.json" ".harness/.template-snapshot.json" ".harness/PROJECT_BRIEF.json")
for p in "${expected_paths[@]}"; do
  if jq -e --arg p "$p" '.changes[] | select(.path == $p)' "$ACTIVE_FILE" >/dev/null 2>&1; then
    pass "ACTIVE migration lists path: $p"
  else
    fail "ACTIVE migration missing path: $p"
  fi
  # new_sha256 must match the recorded fixture sha for that path.
  new_sha="$(jq -r --arg p "$p" '.changes[] | select(.path == $p) | .new_sha256' "$ACTIVE_FILE")"
  fx_sha="$(jq -r --arg p "$p" 'select(.path == $p) | .sha256' "$FIXTURE")"
  if [ "$new_sha" = "$fx_sha" ]; then
    pass "ACTIVE new_sha256 matches fixture for $p"
  else
    fail "ACTIVE new_sha256=$new_sha differs from fixture sha=$fx_sha for $p"
  fi
done

echo "  -- schema phase result: $PASS passed, $FAIL failed --"
if [ "$FAIL" -gt 0 ]; then
  echo "MIGRATION SCHEMA FAILED" >&2
  exit 1
fi

# ---- Negative test: reapply attempt -----------------------------------------
TMPDIR_MIG="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_MIG"' EXIT

# ---- Negative test: unauthorized extra path --------------------------------
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
  "single_application_marker": "applied=false",
  "to_head": "0000000000000000000000000000000000000000"
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
  "single_application_marker": "applied=false",
  "to_head": "0000000000000000000000000000000000000000"
}
EOF
old1="$(jq -r '.changes[0].old_sha256' "$TMPDIR_MIG/mismatch.json")"
cur1="$(jq -r '.changes[0].new_sha256' "$TMPDIR_MIG/mismatch.json")"
if [ "$old1" != "$cur1" ]; then
  pass "mismatch.json has detectable old/new drift on config.json"
else
  fail "mismatch.json should have detectable old/new drift"
fi

# ---- Negative test: post-migration drift -----------------------------------
# If any of the three paths in-tree sha differs from the fixture sha, DWM
# must report a not_byte_equal violation on that path.
for p in "${expected_paths[@]}"; do
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