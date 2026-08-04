#!/bin/bash
# test-harness-feature.sh — Phase 3 §10 Feature State Machine contract tests
#
# Frozen design §1.2 transition matrix (the ONLY legal edges):
#   not_started → in_progress | blocked | deprecated
#   in_progress → passing | blocked | unverified | deprecated
#   blocked     → in_progress | unverified | deprecated
#   passing     → in_progress | deprecated
#   unverified  → in_progress | deprecated
#   deprecated  → (terminal — no outgoing edges)
#
# --override "<reason>" is required ONLY when target=unverified.
#
# Test layout:
#   F1: 6 valid states recognized
#   F2: invalid state rejected (exit 1)
#   F3: legal transitions table-driven (each legal edge: rc=0, status changed,
#       revision +1; unverified transitions also assert audit record)
#   F4: illegal transitions table-driven (each illegal edge + each self-loop
#       + each deprecated→* + each missing-from-whitelist edge: rc=3,
#       status unchanged, revision unchanged)
#   F5: WIP limit blocks 2nd in_progress (rc=4, revision unchanged)
#   F6: passing-needs-evidence rejected (rc=5, revision unchanged)
#   F7: unverified without --override → rc=6 (revision unchanged)
#   F8: --override writes audit record (by/at/reason)
#   F8b: passing-without-evidence + --override from in_progress → routes to
#        unverified (audit written)
#   F9:  successful add bumps revision by exactly +1
#   F10: failed mutation leaves revision unchanged
#   F11: 5 parallel mutations serialize (revision +5, all transitioned)
#   F12: list subcommand works
#   F13: add subcommand works and bumps revision by exactly +1

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
CORE_LIB="$CORE_DIR/lib"
FEATURE_SCRIPT="$CORE_DIR/harness-feature.sh"
VERIFY_SCRIPT="$CORE_DIR/harness-verify.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

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

# Set up a fresh project with a minimal v2 feature_list.json + config.json.
# Args: <project_dir> [revision] [features_json_array]
setup_project() {
  local dir="$1"
  local rev="${2:-1}"
  local features="${3:-[]}"
  mkdir -p "$dir/.harness"
  printf '{"revision":%s,"features":%s,"last_updated":"2026-08-01"}\n' "$rev" "$features" > "$dir/feature_list.json"
  cat > "$dir/.harness/config.json" <<'EOF'
{
  "project_type": "generic",
  "verification": { "commands": [] }
}
EOF
}

# Read current revision from feature_list.json.
read_revision() {
  jq -r '.revision // 0' "$1/feature_list.json"
}

# Read feature status.
read_status() {
  local dir="$1" id="$2"
  jq -r --arg id "$id" '.features[] | select(.id == $id) | .status' "$dir/feature_list.json"
}

# Run harness-feature.sh safely (set +e around it).
run_hf() {
  local cmd="$1"; shift
  set +e
  OUT="$("$FEATURE_SCRIPT" "$cmd" "$@" 2>&1)"
  RC=$?
  set -e
}

# Seed a single feature in <state>, optionally with real passing-eligible
# evidence (run harness-verify --write once to generate a run log + association).
# Args: <dir> <id> <state> [with_evidence 0|1]
seed_feature() {
  local dir="$1" id="$2" state="$3" with_evidence="${4:-0}"
  setup_project "$dir" 10 "[{\"id\":\"$id\",\"status\":\"$state\",\"evidence_associations\":[],\"legacy_audit_evidence\":[]}]"
  if [ "$with_evidence" = "1" ]; then
    # Initialize a git repo + smoke command and run harness-verify --write
    # to generate a passing-eligible evidence association (real run log,
    # matching workspace fingerprint, config SHA, and vcs revision).
    (
      cd "$dir" || exit 1
      git init --quiet
      git config user.email "t@t"
      git config user.name "t"
      cat > ".harness/config.json" <<'EOF'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"smoke","command":["bash","-c","echo ok && exit 0"],"required_for_passing":true,"command_origin":"configured","confirmation":"not_required"}
    ]
  }
}
EOF
      bash "$ROOT_DIR/core/harness-verify.sh" "$id" --write >/dev/null 2>&1 || true
      # harness-verify --write doesn't change status; if seed asked for a
      # non-in_progress starting state, set it now (and bump revision).
      if [ "$state" != "in_progress" ]; then
        cur_rev="$(jq -r '.revision' feature_list.json)"
        next_rev=$(( cur_rev + 1 ))
        jq --arg s "$state" --argjson r "$next_rev" \
          '(.features[] | select(.id=="'"$id"'") | .status) = $s | .revision = $r' \
          feature_list.json > feature_list.json.tmp
        mv feature_list.json.tmp feature_list.json
      fi
    )
  fi
}

# ----------------------------------------------------------------------------
echo ""
echo "=== F1+F2: state validation ==="

# F1a: list accepts valid initial state (no features yet, returns 0)
P="$TMPROOT/f1a"
setup_project "$P"
run_hf list "$P"
if [ "$RC" = "0" ]; then
  assert_pass "F1a: list subcommand on empty project exits 0"
else
  assert_fail "F1a: list on empty project" "rc=$RC"
fi

# F1b: all 6 states recognized by the validator (not exited with 1 "Invalid status")
for s in not_started in_progress blocked passing unverified deprecated; do
  P="$TMPROOT/f1b_$s"
  setup_project "$P" 1 '[{"id":"x","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]'
  run_hf status "$P" x "$s"
  # If state validator rejected, RC would be 1 and OUT would say "Invalid status".
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "Invalid status"; then
    assert_fail "F1b: state '$s' should be valid" "rc=$RC out=$OUT"
  fi
done
assert_pass "F1b: all 6 states recognized by validator (not_started|in_progress|blocked|passing|unverified|deprecated)"

# F2: invalid state rejected with exit 1
P="$TMPROOT/f2"
setup_project "$P"
run_hf status "$P" x "garbage"
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "Invalid status"; then
  assert_pass "F2: invalid status 'garbage' rejected with exit 1"
else
  assert_fail "F2: invalid state rejected" "rc=$RC out=$OUT"
fi

# ----------------------------------------------------------------------------
echo ""
echo "=== F3: legal transitions (table-driven, each edge) ==="
# For each legal edge: rc=0, status changed, revision +1.
# Transitions to passing need a seeded evidence_associations entry, otherwise
# they hit the rc=5 evidence gate (tested separately in F6).
# Transitions to unverified require --override "<reason>" and must write audit.

REV_BEFORE_TABLE=10
# Each row: from to override expected_status post-mutation
# Override strings must be single tokens (no whitespace) because the
# `read -r ...` driver splits on IFS whitespace. Use dashes/underscores
# instead of spaces in the reason text.
LEGAL_EDGES=(
  "not_started in_progress ''  in_progress"
  "not_started blocked     ''  blocked"
  "not_started deprecated  ''  deprecated"
  "in_progress blocked     ''  blocked"
  "in_progress passing     ''  passing"      # needs evidence (seeded)
  "in_progress unverified  'manually-approved'  unverified"
  "in_progress deprecated  ''  deprecated"
  "blocked     in_progress ''  in_progress"
  "blocked     unverified  'sprint-deferred'   unverified"
  "blocked     deprecated  ''  deprecated"
  "passing     in_progress ''  in_progress"
  "passing     deprecated  ''  deprecated"
  "unverified  in_progress ''  in_progress"
  "unverified  deprecated  ''  deprecated"
)

idx=0
for row in "${LEGAL_EDGES[@]}"; do
  idx=$((idx + 1))
  read -r FROM TO OVERRIDE EXPECTED_STATUS <<<"$row"
  P="$TMPROOT/f3_$idx"
  # Seed with evidence iff target=passing (to satisfy the evidence gate)
  if [ "$TO" = "passing" ]; then
    seed_feature "$P" a "$FROM" 1
  else
    seed_feature "$P" a "$FROM" 0
  fi
  REV_BEFORE="$(read_revision "$P")"
  if [ -n "$OVERRIDE" ]; then
    run_hf status "$P" a "$TO" --override "$OVERRIDE"
  else
    run_hf status "$P" a "$TO"
  fi
  REV_AFTER="$(read_revision "$P")"
  DIFF=$((REV_AFTER - REV_BEFORE))
  POST_STATUS="$(read_status "$P" a)"

  if [ "$RC" = "0" ] && [ "$POST_STATUS" = "$EXPECTED_STATUS" ] && [ "$DIFF" = "1" ]; then
    # For unverified, also assert audit record
    if [ "$TO" = "unverified" ]; then
      audit_reason="$(jq -r '.features[] | select(.id=="a") | .override.reason // "MISSING"' "$P/feature_list.json")"
      audit_by="$(jq -r '.features[] | select(.id=="a") | .override.by // "MISSING"' "$P/feature_list.json")"
      audit_at="$(jq -r '.features[] | select(.id=="a") | .override.at // "MISSING"' "$P/feature_list.json")"
      if [ "$audit_reason" = "$OVERRIDE" ] \
         && [ "$audit_by" != "MISSING" ] && [ -n "$audit_by" ] \
         && [ "$audit_at" != "MISSING" ] && [ -n "$audit_at" ]; then
        assert_pass "F3[${idx}]: $FROM → $TO (revision +1, audit recorded)"
      else
        assert_fail "F3[${idx}]: $FROM → $TO (audit incomplete by='$audit_by' at='$audit_at' reason='$audit_reason')"
      fi
    else
      assert_pass "F3[${idx}]: $FROM → $TO (revision +1)"
    fi
  else
    assert_fail "F3[${idx}]: $FROM → $TO" "rc=$RC post_status=$POST_STATUS diff=$DIFF rev_after=$REV_AFTER"
  fi
done

# ----------------------------------------------------------------------------
echo ""
echo "=== F4: illegal transitions (table-driven, rc=3, revision unchanged) ==="
# Every edge NOT in the legal whitelist must reject with rc=3 and leave
# revision unchanged. This includes self-loops and every deprecated→* edge.

REV_BEFORE_TABLE=10
# Each row: from to override_arg
ILLEGAL_EDGES=(
  # --- Self-loops (none allowed) ---
  "not_started not_started ''"
  "in_progress in_progress ''"
  "blocked     blocked     ''"
  "passing     passing     ''"
  "unverified  unverified  ''"
  "deprecated  deprecated  ''"
  # --- From frozen design §1.2 (NOT in whitelist) ---
  "not_started passing    ''"
  "not_started unverified 'override-should-not-help'"
  "in_progress not_started ''"           # REMOVED
  "blocked     not_started ''"           # REMOVED
  "blocked     passing    ''"
  "passing     not_started ''"
  "passing     blocked    ''"
  "passing     unverified 'override-should-not-help'"
  "unverified  not_started ''"
  "unverified  blocked    ''"
  "unverified  passing    ''"
  # --- deprecated has no outgoing edges (terminal) ---
  "deprecated in_progress ''"            # REMOVED
  "deprecated not_started ''"
  "deprecated blocked    ''"
  "deprecated passing    ''"
  "deprecated unverified 'override-should-not-help'"
)

idx=0
for row in "${ILLEGAL_EDGES[@]}"; do
  idx=$((idx + 1))
  read -r FROM TO OVERRIDE <<<"$row"
  P="$TMPROOT/f4_$idx"
  seed_feature "$P" a "$FROM" 0
  REV_BEFORE="$(read_revision "$P")"
  if [ -n "$OVERRIDE" ]; then
    run_hf status "$P" a "$TO" --override "$OVERRIDE"
  else
    run_hf status "$P" a "$TO"
  fi
  REV_AFTER="$(read_revision "$P")"
  POST_STATUS="$(read_status "$P" a)"

  if [ "$RC" = "3" ] && [ "$REV_AFTER" = "$REV_BEFORE" ] && [ "$POST_STATUS" = "$FROM" ]; then
    assert_pass "F4[${idx}]: $FROM → $TO rejected (rc=3, revision unchanged)"
  else
    assert_fail "F4[${idx}]: $FROM → $TO should be rejected" "rc=$RC rev_before=$REV_BEFORE rev_after=$REV_AFTER post=$POST_STATUS"
  fi
done

# ----------------------------------------------------------------------------
echo ""
echo "=== F5: WIP limit ==="

# F5a: WIP=1 (default). With feature b already in_progress, try to set a → in_progress.
P="$TMPROOT/f5a"
setup_project "$P" 1 '[{"id":"a","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"b","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]'
REV_BEFORE="$(read_revision "$P")"
run_hf status "$P" a in_progress
REV_AFTER="$(read_revision "$P")"
if [ "$RC" = "4" ] && [ "$REV_AFTER" = "$REV_BEFORE" ]; then
  assert_pass "F5a: WIP=1 blocks 2nd in_progress (rc=4, revision unchanged)"
else
  assert_fail "F5a: WIP limit should block 2nd in_progress" "rc=$RC rev_after=$REV_AFTER"
fi

# F5b: WIP=2 in config — second in_progress allowed.
P2="$TMPROOT/f5b"
mkdir -p "$P2/.harness"
printf '{"revision":1,"features":[{"id":"a","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"b","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}],"last_updated":"2026-08-01"}\n' > "$P2/feature_list.json"
cat > "$P2/.harness/config.json" <<'EOF'
{
  "project_type": "generic",
  "wip_limit": 2,
  "verification": { "commands": [] }
}
EOF
run_hf status "$P2" a in_progress
if [ "$RC" = "0" ] && [ "$(read_status "$P2" a)" = "in_progress" ]; then
  assert_pass "F5b: WIP=2 in config allows 2 in_progress (override honored)"
else
  assert_fail "F5b: WIP=2 override" "rc=$RC"
fi

# ----------------------------------------------------------------------------
echo ""
echo "=== F6: passing-needs-evidence ==="

# F6: feature with no evidence → passing rejected (rc=5)
P="$TMPROOT/f6"
setup_project "$P" 1 '[{"id":"a","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]'
REV_BEFORE="$(read_revision "$P")"
run_hf status "$P" a passing
REV_AFTER="$(read_revision "$P")"
if [ "$RC" = "5" ] && [ "$REV_AFTER" = "$REV_BEFORE" ]; then
  assert_pass "F6: passing without evidence rejected (rc=5, revision unchanged)"
else
  assert_fail "F6: passing without evidence should fail" "rc=$RC rev_after=$REV_AFTER"
fi

# ----------------------------------------------------------------------------
echo ""
echo "=== F7+F8: unverified requires --override + writes audit ==="

# F7: in_progress → unverified without --override → rejected with rc=6
P="$TMPROOT/f7"
setup_project "$P" 1 '[{"id":"a","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]'
REV_BEFORE="$(read_revision "$P")"
run_hf status "$P" a unverified
REV_AFTER="$(read_revision "$P")"
if [ "$RC" = "6" ] && [ "$REV_AFTER" = "$REV_BEFORE" ] && [ "$(read_status "$P" a)" = "in_progress" ]; then
  assert_pass "F7: unverified without --override rejected (rc=6, revision unchanged, status unchanged)"
else
  assert_fail "F7: unverified without override should fail" "rc=$RC rev_after=$REV_AFTER"
fi

# F8: in_progress → unverified WITH --override writes audit (by/at/reason)
P="$TMPROOT/f8"
setup_project "$P" 1 '[{"id":"a","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]'
REV_BEFORE="$(read_revision "$P")"
run_hf status "$P" a unverified --override "manual approval pending evidence"
REV_AFTER="$(read_revision "$P")"
DIFF=$((REV_AFTER - REV_BEFORE))
if [ "$RC" = "0" ] && [ "$DIFF" = "1" ] && [ "$(read_status "$P" a)" = "unverified" ]; then
  audit_reason="$(jq -r '.features[] | select(.id=="a") | .override.reason // "MISSING"' "$P/feature_list.json")"
  audit_by="$(jq -r '.features[] | select(.id=="a") | .override.by // "MISSING"' "$P/feature_list.json")"
  audit_at="$(jq -r '.features[] | select(.id=="a") | .override.at // "MISSING"' "$P/feature_list.json")"
  if [ "$audit_reason" = "manual approval pending evidence" ] \
     && [ "$audit_by" != "MISSING" ] && [ -n "$audit_by" ] \
     && [ "$audit_at" != "MISSING" ] && [ -n "$audit_at" ]; then
    assert_pass "F8: --override writes audit record (by/at/reason), revision +1"
  else
    assert_fail "F8: audit record incomplete" "by='$audit_by' at='$audit_at' reason='$audit_reason'"
  fi
else
  assert_fail "F8: --override should write audit" "rc=$RC diff=$DIFF"
fi

# F8b: passing-without-evidence + --override from in_progress → routes to
# unverified, audit written. in_progress IS a valid unverified origin.
P="$TMPROOT/f8b"
setup_project "$P" 1 '[{"id":"a","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]'
run_hf status "$P" a passing --override "skipping evidence for now"
if [ "$RC" = "0" ] && [ "$(read_status "$P" a)" = "unverified" ]; then
  audit_reason="$(jq -r '.features[] | select(.id=="a") | .override.reason // "MISSING"' "$P/feature_list.json")"
  if [ "$audit_reason" = "skipping evidence for now" ]; then
    assert_pass "F8b: passing-without-evidence + --override routes to unverified + audit"
  else
    assert_fail "F8b: audit reason missing" "reason='$audit_reason'"
  fi
else
  assert_fail "F8b: should route to unverified" "rc=$RC status=$(read_status "$P" a)"
fi

# F8c: passing-without-evidence + --override from passing → REJECTED
# (passing is not a valid unverified origin per design §1.2).
P="$TMPROOT/f8c"
seed_feature "$P" a passing 0
run_hf status "$P" a passing --override "should not work from passing"
REV_AFTER="$(read_revision "$P")"
if [ "$RC" != "0" ] && [ "$REV_AFTER" = "10" ] && [ "$(read_status "$P" a)" = "passing" ]; then
  assert_pass "F8c: passing-without-evidence + --override from passing rejected (origin invalid)"
else
  assert_fail "F8c: should reject from passing origin" "rc=$RC rev_after=$REV_AFTER status=$(read_status "$P" a)"
fi

# ----------------------------------------------------------------------------
echo ""
echo "=== F9+F10: revision monotonicity ==="

# F9: successful add bumps revision by exactly +1
P="$TMPROOT/f9"
setup_project "$P" 7
REV_BEFORE="$(read_revision "$P")"
run_hf add "$P" new-feature
REV_AFTER="$(read_revision "$P")"
DIFF=$((REV_AFTER - REV_BEFORE))
if [ "$RC" = "0" ] && [ "$DIFF" = "1" ]; then
  assert_pass "F9: successful add bumps revision by exactly +1 (7 → 8)"
else
  assert_fail "F9: revision +1 on add" "rc=$RC rev_before=$REV_BEFORE rev_after=$REV_AFTER diff=$DIFF"
fi

# F10: failed transition leaves revision unchanged
P="$TMPROOT/f10"
setup_project "$P" 11 '[{"id":"a","status":"passing","evidence_associations":[],"legacy_audit_evidence":[]}]'
REV_BEFORE="$(read_revision "$P")"
run_hf status "$P" a not_started   # illegal transition
REV_AFTER="$(read_revision "$P")"
if [ "$RC" != "0" ] && [ "$REV_AFTER" = "$REV_BEFORE" ]; then
  assert_pass "F10: failed mutation leaves revision unchanged ($REV_BEFORE)"
else
  assert_fail "F10: failed mutation must not bump revision" "rc=$RC rev_after=$REV_AFTER"
fi

# F10b: failed add (duplicate id) leaves revision unchanged
P="$TMPROOT/f10b"
setup_project "$P" 11 '[{"id":"a","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]'
REV_BEFORE="$(read_revision "$P")"
run_hf add "$P" a
REV_AFTER="$(read_revision "$P")"
if [ "$RC" != "0" ] && [ "$REV_AFTER" = "$REV_BEFORE" ]; then
  assert_pass "F10b: duplicate add leaves revision unchanged"
else
  assert_fail "F10b: duplicate add must not bump revision" "rc=$RC rev_after=$REV_AFTER"
fi

# ----------------------------------------------------------------------------
echo ""
echo "=== F11: concurrent mutations serialize ==="

# F11: 5 parallel status mutations on different features — final revision
# must be exactly N + 5 (no losses, no double-writes).
P="$TMPROOT/f11"
FEATURES=""
for i in 1 2 3 4 5; do
  if [ -n "$FEATURES" ]; then FEATURES="$FEATURES,"; fi
  FEATURES="${FEATURES}{\"id\":\"f$i\",\"status\":\"not_started\",\"evidence_associations\":[],\"legacy_audit_evidence\":[]}"
done
setup_project "$P" 20 "[$FEATURES]"
REV_BEFORE="$(read_revision "$P")"

# Run 5 parallel: each transitions not_started → blocked.
PIDS=()
for i in 1 2 3 4 5; do
  ( "$FEATURE_SCRIPT" status "$P" "f$i" blocked >/dev/null 2>&1 ) &
  PIDS+=($!)
done

# Wait for all with timeout.
WAITED=0
while [ "${#PIDS[@]}" -gt 0 ] && [ "$WAITED" -lt 30 ]; do
  NEW_PIDS=()
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      NEW_PIDS+=("$pid")
    fi
  done
  PIDS=("${NEW_PIDS[@]}")
  sleep 0.5
  WAITED=$((WAITED + 1))
done

REV_AFTER="$(read_revision "$P")"
DIFF=$((REV_AFTER - REV_BEFORE))

ALL_BLOCKED=true
for i in 1 2 3 4 5; do
  if [ "$(read_status "$P" "f$i")" != "blocked" ]; then
    ALL_BLOCKED=false
  fi
done

if [ "$DIFF" = "5" ] && [ "$ALL_BLOCKED" = "true" ]; then
  assert_pass "F11: 5 parallel mutations → revision +5, all features transitioned"
else
  assert_fail "F11: parallel mutations must serialize" "rev_before=$REV_BEFORE rev_after=$REV_AFTER diff=$DIFF all_blocked=$ALL_BLOCKED"
fi

# ----------------------------------------------------------------------------
echo ""
echo "=== F12+F13: list and add ==="

# F12: list shows summary
P="$TMPROOT/f12"
FEATURES='[{"id":"a","status":"passing","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"b","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]'
setup_project "$P" 50 "$FEATURES"
run_hf list "$P"
if [ "$RC" = "0" ] \
   && printf '%s' "$OUT" | grep -q "1 passing" \
   && printf '%s' "$OUT" | grep -q "1 in_progress" \
   && printf '%s' "$OUT" | grep -q "revision: 50"; then
  assert_pass "F12: list shows summary (1 passing, 1 in_progress, revision 50)"
else
  assert_fail "F12: list summary" "rc=$RC out=$OUT"
fi

# F13: add to empty project
P="$TMPROOT/f13"
setup_project "$P" 100 "[]"
run_hf add "$P" feat-x
if [ "$RC" = "0" ] && [ "$(read_status "$P" feat-x)" = "not_started" ] && [ "$(read_revision "$P")" = "101" ]; then
  assert_pass "F13: add creates feature with status=not_started, revision +1"
else
  assert_fail "F13: add" "rc=$RC status=$(read_status "$P" feat-x) rev=$(read_revision "$P")"
fi

# ----------------------------------------------------------------------------
echo ""
echo "============================================"
echo "F-Results: $PASSED passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0