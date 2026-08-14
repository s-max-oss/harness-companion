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
      # P0-14: a PASS run inside a git project MUST record its vcs_revision
      # (fail-closed: git project + no stored rev is never passing-eligible).
      # An unborn HEAD records `vcs_revision: null`, so commit the seed tree
      # first — this mirrors the real flow (verify only after first commit)
      # and gives the evidence run a genuine revision to match.
      git add -A
      git commit -qm "seed evidence base"
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

# F1a: list on an EMPTY registry (features:[]) FAILS CLOSED (P0-6) — list
# validates the registry with the canonical validator before printing, and an
# empty features array is invalid there → exit 1, no listing rendered.
P="$TMPROOT/f1a"
setup_project "$P"
run_hf list "$P"
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "failed canonical registry validation"; then
  assert_pass "F1a: list on empty registry fails closed (rc=1, no listing)"
else
  assert_fail "F1a: list on empty registry" "rc=$RC out=$OUT"
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
  # `read` splits on IFS whitespace, so a row's `''` marker arrives as a
  # non-empty 2-char literal — NOT an empty string. Normalize it here so a
  # "no override" row genuinely runs without --override. Otherwise the spurious
  # override silently routes an ineligible→passing transition to 'unverified'
  # (rc=0) instead of failing loudly (rc=5), masking eligibility regressions.
  if [ "$OVERRIDE" = "''" ]; then OVERRIDE=""; fi
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
  if [ "$OVERRIDE" = "''" ]; then OVERRIDE=""; fi   # same `''` literal normalization as F3
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

# F6b (P0-14): git project whose evidence run records NO vcs_revision (unborn
# HEAD → harness-verify stamps vcs_revision null) → passing MUST be rejected
# with rc=5 and leave status unchanged. This pins the F3[5] regression: such a
# run is never passing-eligible, and the failure must NOT be silently routed to
# 'unverified' (the pre-fix F3 driver passed a spurious --override "''" which
# masked this exactly this way).
P="$TMPROOT/f6b"
setup_project "$P" 1 '[{"id":"a","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]'
(
  cd "$P" || exit 1
  git init --quiet
  git config user.email "t@t"
  git config user.name "t"
  # Leave the repo UNCOMMITTED on purpose → harness-verify records vcs_revision null
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
  bash "$ROOT_DIR/core/harness-verify.sh" a --write >/dev/null 2>&1 || true
)
REV_BEFORE="$(read_revision "$P")"
run_hf status "$P" a passing
REV_AFTER="$(read_revision "$P")"
if [ "$RC" = "5" ] && [ "$REV_AFTER" = "$REV_BEFORE" ] && [ "$(read_status "$P" a)" = "in_progress" ]; then
  assert_pass "F6b: git project, evidence run without vcs_revision → passing rejected rc=5 (P0-14 fail-closed)"
else
  assert_fail "F6b: git project, evidence run without vcs_revision" "rc=$RC rev_after=$REV_AFTER post=$(read_status "$P" a)"
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
# This test is about serialization correctness (all applied, no losses), NOT
# timeout semantics. Two machine-dependent hazards would otherwise make it
# flaky on slow filesystems (MSYS):
#   (1) the 10s default lock budget: 5-way serialized contention can exceed it
#       for late-starting writers, who legitimately fail closed (exit 7) and
#       have their mutation dropped → revision < +5;
#   (2) a bounded poll loop shorter than the serialization time reads state
#       while a writer is still queued → under-counts revision.
# So we give the contention scenario a generous budget AND wait for every
# process (each self-terminates at its lock deadline, so `wait` is bounded).
export LOCK_TIMEOUT_S=120
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

# Wait for ALL writers to finish before asserting. Each writer self-terminates
# at its lock deadline (≤ LOCK_TIMEOUT_S), so waiting on every PID is bounded;
# a fixed short poll cap would instead read state mid-serialization on slow
# machines (see comment above).
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
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
unset LOCK_TIMEOUT_S

# ----------------------------------------------------------------------------
echo ""
echo "=== F12+F13: list and add ==="

# F12: list shows summary (registry must be VALID for list to render — the
# passing feature carries an evidence association and ids are uppercase, per the
# canonical validator).
P="$TMPROOT/f12"
FEATURES='[{"id":"F-A","status":"passing","evidence_associations":[{"run_id":"r1","command_id":"smoke"}],"legacy_audit_evidence":[]},{"id":"F-B","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]'
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
echo "=== E: concurrent same-ID adds → exactly one succeeds (P0-4) ==="

# E: two concurrent `add <dir> <same-new-id>` must serialize under the registry
# lock — the duplicate-ID check MUST run INSIDE the lock against the CURRENT
# registry (P0-4). Without that, an unlocked TOCTOU pre-check lets BOTH processes
# pass (neither sees the other's not-yet-written feature) and BOTH write a
# duplicate-feature registry. Under the lock, the loser re-reads after the winner
# commits, sees the feature, and fails closed (return 1). Assertions:
#   (1) exactly one of the two exits 0, the other exits nonzero;
#   (2) the registry carries the feature EXACTLY once (never a duplicate-feature
#       registry) and revision advanced by exactly +1;
#   (3) the journal records EXACTLY one pending+committed add pair (the loser
#       fails before journal_init, so it appends nothing).
# Generous lock budget (like F11) so the loser waits for the lock instead of
# timing out (exit 7) on a slow MSYS filesystem.
export LOCK_TIMEOUT_S=120
P="$TMPROOT/p0-4"
setup_project "$P" 7 "[]"
( "$FEATURE_SCRIPT" add "$P" "E-ADD" >/dev/null 2>&1 ) &
P1=$!
( "$FEATURE_SCRIPT" add "$P" "E-ADD" >/dev/null 2>&1 ) &
P2=$!
set +e
wait "$P1" 2>/dev/null; RC1=$?
wait "$P2" 2>/dev/null; RC2=$?
set -e
unset LOCK_TIMEOUT_S

N_OK=0
[ "$RC1" -eq 0 ] && N_OK=$((N_OK + 1))
[ "$RC2" -eq 0 ] && N_OK=$((N_OK + 1))
COUNT="$(jq '[.features[] | select(.id == "E-ADD")] | length' "$P/feature_list.json" 2>/dev/null || echo -1)"
REV_AFTER="$(read_revision "$P")"
JPEND="$(jq -sr '[.[] | select(.op == "add" and .pending == true)] | length' "$P/.harness/registry-journal.ndjson" 2>/dev/null || echo -1)"
JCOMMIT="$(jq -sr '[.[] | select(.op == "commit" and .pending == false)] | length' "$P/.harness/registry-journal.ndjson" 2>/dev/null || echo -1)"

if [ "$N_OK" = "1" ] && [ "$COUNT" = "1" ] && [ "$REV_AFTER" = "8" ] && [ "$JPEND" = "1" ] && [ "$JCOMMIT" = "1" ]; then
  assert_pass "E: concurrent same-ID adds → exactly one success, one committed add pair, no duplicate feature"
else
  assert_fail "E: concurrent same-ID add must serialize under the lock" "rc1=$RC1 rc2=$RC2 ok=$N_OK count=$COUNT rev=$REV_AFTER pending=$JPEND commit=$JCOMMIT"
fi

# ----------------------------------------------------------------------------
echo ""
echo "=== E2: failure branch releases the registry lock (P0-4, Codex item 9) ==="

# P0-4 (Codex item 9): a failing command that acquires the registry lock and
# then returns EARLY (before an explicit release_lock) must still release the
# lockdir. The EXIT trap is the safety net, but it references $LOCK_DIR — which
# was historically `local` to cmd_add/cmd_status. A `local` goes out of scope
# when the function returns, so the trap fired `release_lock ""` (usage error,
# swallowed by `|| true`) and LEAKED the lockdir, leaving the next command to
# stall on a stale lock. The fix makes LOCK_DIR a global so the trap releases
# on every early-return path. Assert the lockdir is GONE after each failing
# command, never a lingering `.harness/.registry.lock`.
#
# (1) duplicate-ID add — cmd_add returns 1 inside the lock (the canonical P0-4
#     same-ID race loser path).
P="$TMPROOT/p0-4-lock1"
setup_project "$P" 3 "[{\"id\":\"F-EXIST\",\"status\":\"not_started\",\"evidence_associations\":[],\"legacy_audit_evidence\":[]}]"
set +e
"$FEATURE_SCRIPT" add "$P" "F-EXIST" >/dev/null 2>&1
RC1=$?
set -e
LOCK1="yes"; [ -d "$P/.harness/.registry.lock" ] || LOCK1="no"
if [ "$RC1" != "0" ] && [ "$LOCK1" = "no" ]; then
  assert_pass "E2: duplicate-ID add fails (rc=$RC1) AND releases the lockdir"
else
  assert_fail "E2: duplicate-ID add must fail and release the lockdir" "rc=$RC1 lockdir_present=$LOCK1"
fi

# (2) invalid status transition — cmd_status returns 3 inside the lock.
P="$TMPROOT/p0-4-lock2"
setup_project "$P" 4 "[{\"id\":\"F-T\",\"status\":\"not_started\",\"evidence_associations\":[],\"legacy_audit_evidence\":[]}]"
set +e
"$FEATURE_SCRIPT" status "$P" "F-T" "passing" >/dev/null 2>&1
RC2=$?
set -e
LOCK2="yes"; [ -d "$P/.harness/.registry.lock" ] || LOCK2="no"
if [ "$RC2" != "0" ] && [ "$LOCK2" = "no" ]; then
  assert_pass "E2: invalid transition fails (rc=$RC2) AND releases the lockdir"
else
  assert_fail "E2: invalid transition must fail and release the lockdir" "rc=$RC2 lockdir_present=$LOCK2"
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