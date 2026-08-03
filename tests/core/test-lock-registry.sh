#!/bin/bash
# test-lock-registry.sh — Phase 3 lock-registry contract tests
#
# Verifies per design §7.6:
#   T1. mkdir_lock_fallback — A acquires, B blocks; A releases; B succeeds.
#   T2. owner_token_no_release — A acquires (T_A); release(T_B) rejected; lock_dir persists.
#   T3. stale_recovery_same_host — dead-PID metadata → next acquirer recovers.
#   T4. pid_reuse_not_stolen — alive PID with mismatched start_time → NOT stolen.
#   T5. different_host_within_grace — foreign hostname within 60s → wait.
#   T6. different_host_past_grace — foreign hostname past 60s → recover.
#   T7. metadata_damaged_no_recovery — missing hostname → wait until timeout.
#   T8. cross_host_no_local_pid_check — foreign hostname + dead local PID → wait.
#
# Plus T9: revision monotonically increments when two processes serialize.
#
# All tests are platform-portable (Linux/macOS/Windows Git Bash).

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

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

# Source the lock module (skips with FAIL when not yet implemented)
if ! source "$CORE_LIB/lock-registry.sh" 2>/tmp/src_err; then
  echo "FAIL: lock-registry.sh not present or has syntax error — $(cat /tmp/src_err)"
  echo "============================================"
  echo "Lock Registry Results: 0 passed, 1 failed"
  echo "============================================"
  exit 1
fi

# Helpers ---------------------------------------------------------------------
mk_lock_dir() {
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d"
}

write_lock_meta() {
  local d="$1" pid="$2" start="$3" host="$4" ts="$5" tok="$6"
  printf '%s\n' "$pid" > "$d/pid"
  printf '%s\n' "$start" > "$d/process_start_time"
  printf '%s\n' "$host" > "$d/hostname"
  printf '%s\n' "$ts" > "$d/timestamp"
  printf '%s\n' "$tok" > "$d/token"
}

# ============================================================================
# T1: mkdir_lock_fallback
# ============================================================================
echo ""
echo "=== T1: mkdir_lock_fallback ==="
T1="$TMPROOT/t1"
# lock_dir must NOT exist before fresh acquisition. (If it exists with no
# metadata, acquire_lock treats it as damaged and waits — which is correct
# recovery behavior, not what we want to test here.)
# Parent must exist (plain mkdir is used to preserve POSIX atomicity).
mkdir -p "$T1"
rm -rf "$T1/lock"

# Process A acquires from scratch (mkdir-based mutex creates lock_dir).
TOK1="$(acquire_lock "$T1/lock" 2)" || {
  assert_fail "T1: A acquires fresh lock" "acquire_lock returned $?"
  TOK1=""
}
if [ -n "${TOK1:-}" ]; then
  # B should fail to mkdir (EEXIST). Verify lock_dir exists.
  if [ -d "$T1/lock" ]; then
    assert_pass "T1: A acquires fresh lock; lock_dir exists"
  else
    assert_fail "T1: A acquires fresh lock" "lock_dir missing"
  fi
  # Release
  if release_lock "$T1/lock" "$TOK1"; then
    if [ ! -d "$T1/lock" ]; then
      assert_pass "T1: A releases → lock_dir removed"
    else
      assert_fail "T1: A releases → lock_dir removed" "still present"
    fi
  else
    assert_fail "T1: A release_lock" "exit=$?"
  fi
  # After release, B can acquire. Use 3s timeout: on Windows filesystems the
  # release→acquire handoff can take longer than 1s due to filesystem caching.
  TOK2="$(acquire_lock "$T1/lock" 3)" || assert_fail "T1: B acquires after release" "acquire_lock failed"
  if [ -n "${TOK2:-}" ]; then
    assert_pass "T1: B acquires after A releases"
    release_lock "$T1/lock" "$TOK2" >/dev/null
  fi
fi

# ============================================================================
# T2: owner_token_no_release
# ============================================================================
echo ""
echo "=== T2: owner_token_no_release ==="
T2="$TMPROOT/t2"
# lock_dir must NOT exist for fresh acquisition; parent must exist.
mkdir -p "$T2"
rm -rf "$T2/lock"
TOK_A="$(acquire_lock "$T2/lock" 2)"
if [ -n "${TOK_A:-}" ]; then
  # Try to release with a wrong token
  if release_lock "$T2/lock" "wrong_token_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" 2>/dev/null; then
    assert_fail "T2: release with wrong token rejected" "release succeeded (should fail)"
  else
    rc=$?
    if [ "$rc" = "6" ]; then
      assert_pass "T2: release with wrong token → exit 6"
    else
      assert_fail "T2: wrong-token exit code" "got $rc, expected 6"
    fi
  fi
  # Lock_dir MUST still exist
  if [ -d "$T2/lock" ]; then
    assert_pass "T2: lock_dir still present after rejected release"
  else
    assert_fail "T2: lock_dir persisted" "lock_dir was removed"
  fi
  # Owner can still release
  if release_lock "$T2/lock" "$TOK_A"; then
    assert_pass "T2: owner releases with correct token"
  else
    assert_fail "T2: owner release" "exit=$?"
  fi
fi

# ============================================================================
# T3: stale_recovery_same_host
# ============================================================================
echo ""
echo "=== T3: stale_recovery_same_host ==="
T3="$TMPROOT/t3"
mk_lock_dir "$T3/lock"
# Inject dead-PID metadata with a (synthetic) start_time; same host as $$.
# Use a clearly-dead PID (42424242) so kill -0 returns non-zero.
write_lock_meta "$T3/lock" "42424242" "99999999" "$(hostname)" "$(date +%s)" "old_token"
# Use 5s timeout: stale recovery involves multiple polling iterations on
# slower Windows filesystems (rm -rf + mkdir retry cycle).
TOK3="$(acquire_lock "$T3/lock" 5)" || TOK3=""
if [ -n "${TOK3:-}" ]; then
  assert_pass "T3: dead-PID metadata on same host → recovered"
  release_lock "$T3/lock" "$TOK3" >/dev/null
else
  assert_fail "T3: stale recovery same-host" "acquire_lock returned empty"
fi

# ============================================================================
# T4: pid_reuse_not_stolen
# ============================================================================
echo ""
echo "=== T4: pid_reuse_not_stolen ==="
T4="$TMPROOT/t4"
mk_lock_dir "$T4/lock"
# Alive PID (current shell $$) with WRONG start_time (clearly ancient)
# → acquire_lock should NOT steal the lock.
write_lock_meta "$T4/lock" "$$" "1" "$(hostname)" "$(date +%s)" "owner_token"
# Use short timeout so the test doesn't hang
TOK4="$(acquire_lock "$T4/lock" 1)" || TOK4=""
if [ -z "${TOK4:-}" ]; then
  assert_pass "T4: alive PID with mismatched start_time → NOT stolen (timeout)"
else
  assert_fail "T4: pid_reuse_not_stolen" "lock was stolen — should have waited"
  release_lock "$T4/lock" "$TOK4" >/dev/null
fi
# Clean up the injected lock (it may still be there if not stolen)
rm -rf "$T4/lock"

# ============================================================================
# T5: different_host_within_grace
# ============================================================================
echo ""
echo "=== T5: different_host_within_grace ==="
T5="$TMPROOT/t5"
mk_lock_dir "$T5/lock"
write_lock_meta "$T5/lock" "12345" "99999" "some-other-host.example.com" "$(date +%s)" "x"
# Within 60s cross-host grace → should NOT recover
TOK5="$(acquire_lock "$T5/lock" 1)" || TOK5=""
if [ -z "${TOK5:-}" ]; then
  assert_pass "T5: foreign hostname within grace → NOT recovered (timeout)"
else
  assert_fail "T5: cross-host within grace" "lock was recovered prematurely"
  release_lock "$T5/lock" "$TOK5" >/dev/null
fi
rm -rf "$T5/lock"

# ============================================================================
# T6: different_host_past_grace
# ============================================================================
echo ""
echo "=== T6: different_host_past_grace ==="
T6="$TMPROOT/t6"
mk_lock_dir "$T6/lock"
# Foreign hostname + old timestamp (300s ago, well past 60s cross-host grace)
OLD_TS=$(( $(date +%s) - 300 ))
write_lock_meta "$T6/lock" "12345" "99999" "some-other-host.example.com" "$OLD_TS" "x"
# Use 5s timeout: the cross-host recovery path requires multiple polling
# iterations on slower Windows filesystems.
TOK6="$(acquire_lock "$T6/lock" 5)" || TOK6=""
if [ -n "${TOK6:-}" ]; then
  assert_pass "T6: foreign hostname past grace (300s) → recovered"
  release_lock "$T6/lock" "$TOK6" >/dev/null
else
  assert_fail "T6: cross-host past grace" "did not recover stale cross-host lock"
fi

# ============================================================================
# T7: metadata_damaged_no_recovery
# ============================================================================
echo ""
echo "=== T7: metadata_damaged_no_recovery ==="
T7="$TMPROOT/t7"
mk_lock_dir "$T7/lock"
# Write partial metadata: pid only, no hostname → damaged
echo "12345" > "$T7/lock/pid"
echo "$(date +%s)" > "$T7/lock/timestamp"
# Within a short window, must NOT recover (damaged metadata cannot be safely recovered)
TOK7="$(acquire_lock "$T7/lock" 1)" || TOK7=""
if [ -z "${TOK7:-}" ]; then
  assert_pass "T7: damaged metadata (no hostname) → NOT recovered (timeout)"
else
  assert_fail "T7: damaged metadata recovery" "lock was stolen despite missing hostname"
  release_lock "$T7/lock" "$TOK7" >/dev/null
fi
rm -rf "$T7/lock"

# ============================================================================
# T8: cross_host_no_local_pid_check
# ============================================================================
echo ""
echo "=== T8: cross_host_no_local_pid_check ==="
T8="$TMPROOT/t8"
mk_lock_dir "$T8/lock"
# Foreign hostname + PID 42424242 (dead) + fresh timestamp
# Even though local PID 42424242 doesn't exist, MUST NOT recover within grace.
write_lock_meta "$T8/lock" "42424242" "1" "some-other-host.example.com" "$(date +%s)" "x"
TOK8="$(acquire_lock "$T8/lock" 1)" || TOK8=""
if [ -z "${TOK8:-}" ]; then
  assert_pass "T8: foreign hostname + dead local PID → NOT recovered within grace"
else
  assert_fail "T8: cross-host no local PID check" "lock was recovered based on local PID"
  release_lock "$T8/lock" "$TOK8" >/dev/null
fi
rm -rf "$T8/lock"

# ============================================================================
# T9: revision monotonicity (E2E: two serialized writes increment revision)
# ============================================================================
echo ""
echo "=== T9: revision monotonicity via harness-verify --write ==="
T9="$TMPROOT/t9"
mkdir -p "$T9"
git -C "$T9" init --quiet
git -C "$T9" config user.email "t@t"
git -C "$T9" config user.name "t"
mkdir -p "$T9/.harness"
cat > "$T9/feature_list.json" <<'FL'
{"revision":42,"features":[{"id":"feat-a","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"feat-b","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}],"last_updated":"2026-08-01"}
FL
cat > "$T9/.harness/config.json" <<'CFG'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"smoke","command":["bash","-c","echo ok && exit 0"],"required_for_passing":true,"command_origin":"configured","confirmation":"not_required"}
    ]
  }
}
CFG

# Run harness-verify --write for feat-a, then feat-b, in sequence.
# Arg order: feature_id, project_dir (optional, default "."), --write (optional).
( cd "$T9" && bash "$ROOT_DIR/core/harness-verify.sh" "feat-a" --write ) > /tmp/t9a.log 2>&1
rc1=$?
( cd "$T9" && bash "$ROOT_DIR/core/harness-verify.sh" "feat-b" --write ) > /tmp/t9b.log 2>&1
rc2=$?
rev_after="$(jq -r '.revision' "$T9/feature_list.json" 2>/dev/null)"
n_assocs="$(jq -r '[.features[] | .evidence_associations | length] | add' "$T9/feature_list.json" 2>/dev/null)"
if [ "$rc1" = "0" ] && [ "$rc2" = "0" ] && [ "$rev_after" = "44" ] && [ "$n_assocs" = "2" ]; then
  assert_pass "T9: revision 42→44, both associations present"
else
  assert_fail "T9: revision monotonicity" "rc1=$rc1 rc2=$rc2 rev=$rev_after n_assocs=$n_assocs"
fi

# ============================================================================
# T10: background concurrency — A holds lock, B blocks; A releases; B succeeds
# ============================================================================
echo ""
echo "=== T10: background A holds, B blocks, then A releases; B acquires ==="
T10="$TMPROOT/t10"
mkdir -p "$T10"
rm -rf "$T10/lock"

# Process A acquires and holds the lock for 2 seconds, then releases.
(
  TOK_A="$(acquire_lock "$T10/lock" 2)" && {
    # Hold the lock — write a flag file B can poll for confirmation.
    echo "A holds lock token=$TOK_A" > "$T10/a_holds"
    sleep 2
    release_lock "$T10/lock" "$TOK_A" >/dev/null 2>&1
    rm -f "$T10/a_holds"
    echo "A released" > "$T10/a_state"
  }
) > "$T10/a.log" 2>&1 &
A_PID=$!

# Wait for A to confirm it holds the lock (poll up to 2s).
waited=0
while [ ! -f "$T10/a_holds" ] && [ "$waited" -lt 20 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
if [ ! -f "$T10/a_holds" ]; then
  assert_fail "T10: A acquired lock within 2s" "A log: $(cat "$T10/a.log" 2>&1)"
fi

# Process B tries to acquire — should block (timeout=5 forces a wait).
T_START=$(date +%s)
TOK_B="$(acquire_lock "$T10/lock" 5)"
B_RC=$?
T_END=$(date +%s)
B_WAIT=$(( T_END - T_START ))

if [ "$B_RC" = "0" ] && [ -n "$TOK_B" ] && [ "$B_WAIT" -ge 1 ]; then
  assert_pass "T10: B blocked while A held lock, then acquired after A release (waited ${B_WAIT}s)"
else
  assert_fail "T10: B blocks/then acquires" "rc=$B_RC tok='$TOK_B' waited=${B_WAIT}s a_log=$(cat "$T10/a.log" 2>&1)"
fi
release_lock "$T10/lock" "$TOK_B" >/dev/null 2>&1 || true

# Wait for A to finish so the cleanup trap can fire.
wait "$A_PID" 2>/dev/null || true

# ============================================================================
# T11: two parallel --write on the same project → revision +2, both assocs
# ============================================================================
echo ""
echo "=== T11: two parallel --write → revision +2, both associations ==="
T11="$TMPROOT/t11"
rm -rf "$T11"
mkdir -p "$T11"
( cd "$T11" && git init --quiet )
( cd "$T11" && git config user.email "t@t" && git config user.name "t" )
mkdir -p "$T11/.harness"
cat > "$T11/feature_list.json" <<'FL'
{"revision":50,"features":[{"id":"p1","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"p2","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}],"last_updated":"2026-08-01"}
FL
cat > "$T11/.harness/config.json" <<'CFG'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {"id":"smoke","command":["bash","-c","echo ok && exit 0"],"required_for_passing":true,"command_origin":"configured","confirmation":"not_required"}
    ]
  }
}
CFG

# Two concurrent --write invocations, redirected to per-process logs.
( cd "$T11" && bash "$ROOT_DIR/core/harness-verify.sh" "p1" --write ) > "$T11/p1.log" 2>&1 &
P1=$!
( cd "$T11" && bash "$ROOT_DIR/core/harness-verify.sh" "p2" --write ) > "$T11/p2.log" 2>&1 &
P2=$!
wait "$P1" 2>/dev/null || true
wait "$P2" 2>/dev/null || true

rev_after="$(jq -r '.revision' "$T11/feature_list.json" 2>/dev/null)"
n_assocs="$(jq -r '[.features[] | .evidence_associations | length] | add' "$T11/feature_list.json" 2>/dev/null)"
p1_n="$(jq -r --arg id "p1" '[.features[] | select(.id == $id) | .evidence_associations | length] | add // 0' "$T11/feature_list.json" 2>/dev/null)"
p2_n="$(jq -r --arg id "p2" '[.features[] | select(.id == $id) | .evidence_associations | length] | add // 0' "$T11/feature_list.json" 2>/dev/null)"
lock_remaining="no"
[ -d "$T11/.harness/.registry.lock" ] && lock_remaining="yes"

if [ "$rev_after" = "52" ] && [ "$n_assocs" = "2" ] && [ "$p1_n" = "1" ] && [ "$p2_n" = "1" ] && [ "$lock_remaining" = "no" ]; then
  assert_pass "T11: revision 50→52, both p1+p2 associations preserved, lock_dir cleaned"
else
  assert_fail "T11: parallel --write serialization" "rev=$rev_after n=$n_assocs p1=$p1_n p2=$p2_n lock=$lock_remaining"
fi

# ============================================================================
# T12: timeout=5 — caller asks for too little, lock held by another, exits 5
# ============================================================================
echo ""
echo "=== T12: timeout=5 with held lock → exit 5 (lock_timeout) ==="
T12="$TMPROOT/t12"
mkdir -p "$T12"
rm -rf "$T12/lock"

# Holder: pre-create lock_dir with alive-PID + mismatched start_time so the
# lock is judged NOT stale (T4 behavior). Caller's only recourse is timeout.
mkdir -p "$T12/lock"
write_lock_meta "$T12/lock" "$$" "1" "$(hostname)" "$(date +%s)" "frozen_token"

T_START=$(date +%s)
LOCK_RC=0
acquire_lock "$T12/lock" 5 >/dev/null 2>&1 || LOCK_RC=$?
T_END=$(date +%s)
LOCK_WAIT=$(( T_END - T_START ))

if [ "$LOCK_RC" = "5" ] && [ "$LOCK_WAIT" -ge 4 ] && [ "$LOCK_WAIT" -le 7 ]; then
  assert_pass "T12: timeout=5 with held lock → exit 5 after ${LOCK_WAIT}s (no stealing)"
else
  assert_fail "T12: timeout=5 fails closed" "rc=$LOCK_RC waited=${LOCK_WAIT}s (expected ~5s)"
fi
rm -rf "$T12/lock"

# ============================================================================
# T13: flock backend contention — A holds lock in same shell, B blocks
# ============================================================================
# Per G3 re-verification: prove that under LOCK_REGISTRY_BACKEND=flock, B
# cannot acquire the lock until A's mutation completes and A releases.
# Skipped when flock(1) is not installed (e.g., Windows Git Bash).
echo ""
echo "=== T13: flock backend contention (skipped if flock absent) ==="
T13="$TMPROOT/t13"
mkdir -p "$T13"
rm -rf "$T13/lock"
if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP: T13: flock(1) not installed on this platform — test skipped (Linux-only)"
else
  # Write a tiny harness that:
  #   1. Sources lock-registry.sh with LOCK_REGISTRY_BACKEND=flock
  #   2. Acquires the lock in its own shell (NOT $())
  #   3. Writes a sentinel file the test will check
  #   4. Sleeps 3s to hold the lock
  #   5. Releases
  HOLDER="$T13/holder.sh"
  WAITER="$T13/waiter.sh"
  cat > "$HOLDER" <<'HOLDER_EOF'
#!/bin/bash
set -uo pipefail
LOCK_DIR="$1"
SENTINEL="$2"
source "$CORE_LIB/lock-registry.sh"
export LOCK_REGISTRY_BACKEND=flock
acquire_lock "$LOCK_DIR" 5 || { echo "HOLDER: acquire failed" >&2; exit 7; }
date +%s.%N > "$SENTINEL"
sleep 3
release_lock "$LOCK_DIR"
exit 0
HOLDER_EOF
  cat > "$WAITER" <<'WAITER_EOF'
#!/bin/bash
set -uo pipefail
LOCK_DIR="$1"
START_SENTINEL="$2"
T_START=$(date +%s.%N)
source "$CORE_LIB/lock-registry.sh"
export LOCK_REGISTRY_BACKEND=flock
acquire_lock "$LOCK_DIR" 10 || { echo "WAITER: acquire failed" >&2; exit 7; }
T_END=$(date +%s.%N)
# Record our waited time in seconds (with one decimal)
awk -v s "$T_START" -v e "$T_END" 'BEGIN { printf "%.1f\n", e - s }' > "${START_SENTINEL}.waited"
release_lock "$LOCK_DIR"
exit 0
WAITER_EOF
  chmod +x "$HOLDER" "$WAITER"

  # Launch holder first; as soon as the sentinel file appears, launch waiter.
  ( CORE_LIB="$CORE_LIB" bash "$HOLDER" "$T13/lock" "$T13/holder_started" ) &
  HOLDER_PID=$!
  # Wait up to 5s for holder to write the sentinel.
  WAITED=0
  while [ ! -f "$T13/holder_started" ] && [ "$WAITED" -lt 50 ]; do
    sleep 0.1
    WAITED=$((WAITED + 1))
  done
  if [ ! -f "$T13/holder_started" ]; then
    assert_fail "T13: holder did not start" "no sentinel"
    kill -9 "$HOLDER_PID" 2>/dev/null || true
  else
    T_WAIT_START=$(date +%s.%N)
    ( CORE_LIB="$CORE_LIB" bash "$WAITER" "$T13/lock" "$T13/waiter_started" ) &
    WAITER_PID=$!

    # Waiter should NOT acquire before holder finishes (≥3s wait).
    if [ -f "$T13/waiter_started.waited" ]; then
      # Both finished — analyze.
      WAIT_TIME="$(cat "$T13/waiter_started.waited")"
      # Compare wait time ≥ 2.5s (holder held for 3s, waiter must wait at least
      # most of that).
      WAIT_OK=$(awk -v w "$WAIT_TIME" 'BEGIN { print (w >= 2.5) ? "yes" : "no" }')
      # Both processes should have exited 0.
      wait "$HOLDER_PID"; HOLDER_RC=$?
      wait "$WAITER_PID"; WAITER_RC=$?
      if [ "$WAIT_OK" = "yes" ] && [ "$HOLDER_RC" = "0" ] && [ "$WAITER_RC" = "0" ]; then
        assert_pass "T13: flock contention — waiter blocked ≥2.5s while holder mutated (waited=${WAIT_TIME}s)"
      else
        assert_fail "T13: flock contention" "waited=${WAIT_TIME}s holder_rc=$HOLDER_RC waiter_rc=$WAITER_RC"
      fi
    else
      assert_fail "T13: waiter did not complete" "no waited file"
      kill -9 "$WAITER_PID" "$HOLDER_PID" 2>/dev/null || true
    fi
  fi
  rm -rf "$T13/lock" "$T13/holder_started" "$T13/waiter_started.waited"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "Lock Registry Results: $PASSED passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0