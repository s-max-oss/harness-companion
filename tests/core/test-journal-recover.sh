#!/bin/bash
# test-journal-recover.sh — Contract 3: fail-closed committed append + three-way
# crash recovery (backout / roll-forward / blocker).
#
# Covers negative tests F and G:
#   F: registry 已写入后若 journal commit 追加失败，harness-feature.sh 与
#      harness-verify.sh 必须返回非零，绝不能只打印 warning 后继续成功。事务恢复
#      fail-closed：journal_recover 只有 current SHA 与 expected post SHA 完全相等
#      时才可 roll-forward，否则必须拒绝。
#   G: orphan pending：pre-SHA 相同可 backout；current SHA == expected post-SHA
#      才可 roll-forward；第三种 SHA 必须 blocker。
#
# Requires: bash, jq, git, sha256sum (or shasum -a 256).

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/validate-feature-registry.sh
source "$CORE_LIB/validate-feature-registry.sh"
# shellcheck source=../../core/lib/registry-journal.sh
source "$CORE_LIB/registry-journal.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

check() {
  local name="$1" expected="$2" got="$3"
  if [ "$expected" = "$got" ]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — expected $expected, got $got"
    FAILED=$((FAILED + 1))
  fi
}

# setup_project <dir> — minimal canonical valid rev1 registry (F-001 not_started)
setup_project() {
  local d="$1"
  mkdir -p "$d/.harness"
  printf '%s\n' '{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}' > "$d/feature_list.json"
}

# record_started <dir> — ensure the journal exists (init line) without a mutation
journal_ready() {
  journal_init "$1"
}

# ============================================================================
# F1: committed-append failure is FAIL-CLOSED at the library level.
#   pending (binds expected post-state SHA) → registry updated → committed
#   append fails → journal_record_committed returns NONZERO and the orphan
#   pending (with its expected_post_sha) is retained for recovery.
# ============================================================================
D="$(mktemp -d "$TMPDIR/f1-XXXX")"
setup_project "$D"
JP="$D/.harness/registry-journal.ndjson"
POST='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
post_sha="$(printf '%s\n' "$POST" | sha256sum 2>/dev/null | awk '{print $1}')"
OK="$(journal_record_pending "$D" "status" "F-001" "not_started" "in_progress" --revision "2" --post-sha "$post_sha")"
printf '%s\n' "$POST" > "$D/feature_list.json"
chmod a-w "$JP"
rc=0
journal_record_committed "$D" "$OK" "$post_sha" >/dev/null 2>&1 || rc=$?
chmod u+w "$JP"
check "F1a: committed append failure returns nonzero" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
check "F1b: registry already advanced (recovery point established)" "2" "$(jq -r '.revision' "$D/feature_list.json")"
check "F1c: orphan pending retained for recovery" "1" "$(jq -sr '[.[] | select(.op_key == "'"$OK"'" and .pending == true)] | length' "$JP")"
check "F1d: expected_post_sha bound on the orphan" "$post_sha" "$(jq -sr '[.[] | select(.op_key == "'"$OK"'" and .pending == true) | .expected_post_sha][0]' "$JP")"

# ============================================================================
# F1y (Contract 3 negative): journal_record_committed with a WRONG sha_after
#   (≠ the pending's expected_post_sha) is FAIL-CLOSED at the library level —
#   returns nonzero and appends NO commit line, so the wrong SHA is never
#   minted into a commit. The pending (with its bound expected_post_sha) is
#   retained and journal_recover still rolls forward EXACTLY.
# ============================================================================
DY="$(mktemp -d "$TMPDIR/f1y-XXXX")"
setup_project "$DY"
JPY="$DY/.harness/registry-journal.ndjson"
POSTY='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
posty_sha="$(printf '%s\n' "$POSTY" | sha256sum 2>/dev/null | awk '{print $1}')"
OKY="$(journal_record_pending "$DY" "status" "F-001" "not_started" "in_progress" --revision "2" --post-sha "$posty_sha")"
printf '%s\n' "$POSTY" > "$DY/feature_list.json"
WRONG_SHA="0000000000000000000000000000000000000000000000000000000000000000"
rc=0
journal_record_committed "$DY" "$OKY" "$WRONG_SHA" >/dev/null 2>&1 || rc=$?
check "F1y: wrong sha_after returns nonzero" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
check "F1y: no commit line minted for the wrong sha" "0" "$(jq -sr '[.[] | select(.op_key == "'"$OKY"'" and .pending == false)] | length' "$JPY")"
check "F1y: pending retained for exact recovery" "1" "$(jq -sr '[.[] | select(.op_key == "'"$OKY"'" and .pending == true)] | length' "$JPY")"
rc=0
journal_recover "$DY" >/dev/null 2>&1 || rc=$?
check "F1y: recovery still rolls forward EXACTLY (current == expected_post_sha)" "0" "$rc"
check "F1y: recovery commit line present" "1" "$(jq -sr '[.[] | select(.op_key == "'"$OKY"'" and .pending == false and .op == "commit")] | length' "$JPY")"

# ============================================================================
# F2: after the journal is writable again, journal_recover rolls FORWARD exactly
#   (current SHA == expected post-state SHA), appends the recovery commit, and
#   the recovered chain is accepted by journal_replay. Idempotent.
# ============================================================================
rc=0
journal_recover "$D" >/dev/null 2>&1 || rc=$?
check "F2a: recover rolls forward (rc 0)" "0" "$rc"
check "F2b: recovery commit line appended" "1" "$(jq -sr '[.[] | select(.op_key == "'"$OK"'" and .pending == false and .op == "commit")] | length' "$JP")"
check "F2c: recovery_note marks the roll-forward" "1" "$(jq -sr '[.[] | select(.op_key == "'"$OK"'" and .recovery_note != null)] | length' "$JP")"
rc=0
journal_recover "$D" >/dev/null 2>&1 || rc=$?
check "F2d: recover is idempotent" "0" "$rc"

# ============================================================================
# G1: orphan pending + current == pre-SHA → BACKOUT (append-only, Codex item 3).
#   The orphan pending line is PRESERVED in the audit trail; a
#   recovery_backout record is APPENDED. journal_replay and journal_verify_pairs
#   filter out op_keys with a recovery_backout record so they no longer
#   count as orphan or as a mutation edge.
# ============================================================================
D="$(mktemp -d "$TMPDIR/g1-XXXX")"
setup_project "$D"
JP="$D/.harness/registry-journal.ndjson"
PRE_G1="$(sha256_file "$D/feature_list.json")"
# Build a strict-binding orphan so the strict-pairing flow runs end-to-end:
TS_G1="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
POST_G1='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
POST_G1_SHA="$(printf '%s\n' "$POST_G1" | sha256sum 2>/dev/null | awk '{print $1}')"
printf '%s\n' "{\"ts\":\"$TS_G1\",\"op\":\"journal_init\",\"revision\":0,\"feature_id\":null,\"from\":null,\"to\":null,\"pending\":false,\"op_key\":null,\"feature_list_sha_before\":null,\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null}" > "$JP"
printf '%s\n' "{\"ts\":\"$TS_G1\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"g1g1g1g1g1g1g1g1\",\"feature_list_sha_before\":\"$PRE_G1\",\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null,\"expected_post_sha\":\"$POST_G1_SHA\"}" >> "$JP"
OK="g1g1g1g1g1g1g1g1"
# registry unchanged → current == pre-SHA
rc=0
journal_recover "$D" >/dev/null 2>&1 || rc=$?
check "G1a: backout rc 0" "0" "$rc"
# Codex item 3: append-only — pending RETAINED in journal, NOT truncated.
check "G1b: pending line preserved (append-only)" "1" "$(jq -sr '[.[] | select(.op_key == "'"$OK"'" and .pending == true)] | length' "$JP")"
check "G1c: recovery_backout recorded" "1" "$(jq -sr '[.[] | select(.op == "recovery_backout" and .op_key == "'"$OK"'")] | length' "$JP")"
# G1d: replay accepts the chain (op_key filtered via recovery_backout, no
# pending-no-commit violation, no extra mutation edge).
REC_G1="$(printf '{"revision":1,"features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}],"_recorded_sha":"%s"}' "$PRE_G1")"
jr=0
journal_replay "$D" "$REC_G1" >/dev/null 2>&1 || jr=$?
check "G1d: replay accepts the backout-augmented chain (rc 0)" "0" "$jr"

# ============================================================================
# G2: orphan pending + current == expected post-SHA → ROLL-FORWARD, and the
#   recovered commit is proven by journal_replay.
# ============================================================================
D="$(mktemp -d "$TMPDIR/g2-XXXX")"
setup_project "$D"
JP="$D/.harness/registry-journal.ndjson"
INIT_SHA="$(sha256_file "$D/feature_list.json")"
POST2='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
post2_sha="$(printf '%s\n' "$POST2" | sha256sum 2>/dev/null | awk '{print $1}')"
OK="$(journal_record_pending "$D" "status" "F-001" "not_started" "in_progress" --revision "2" --post-sha "$post2_sha")"
printf '%s\n' "$POST2" > "$D/feature_list.json"
rc=0
journal_recover "$D" >/dev/null 2>&1 || rc=$?
check "G2a: roll-forward rc 0" "0" "$rc"
check "G2b: recovery commit line present" "1" "$(jq -sr '[.[] | select(.op_key == "'"$OK"'" and .pending == false and .op == "commit")] | length' "$JP")"
# replay PROVES the recovered commit is the exact expected post-state
REC_DOC="$(printf '{"revision":1,"features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}],"_recorded_sha":"%s"}' "$INIT_SHA")"
jr=0
journal_replay "$D" "$REC_DOC" >/dev/null 2>&1 || jr=$?
check "G2c: replay accepts the recovered chain (valid)" "0" "$jr"

# ============================================================================
# G3: orphan pending + a THIRD SHA (neither pre nor expected post) → BLOCKER.
#   journal_recover returns 1, logs recovery_blocked, never mints the external
#   SHA into a commit; journal_init is also blocked (fail-closed on next mutation).
# ============================================================================
D="$(mktemp -d "$TMPDIR/g3-XXXX")"
setup_project "$D"
JP="$D/.harness/registry-journal.ndjson"
POST3='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
post3_sha="$(printf '%s\n' "$POST3" | sha256sum 2>/dev/null | awk '{print $1}')"
OK="$(journal_record_pending "$D" "status" "F-001" "not_started" "in_progress" --revision "2" --post-sha "$post3_sha")"
# THIRD sha: a different rev2 content — neither pre (rev1) nor expected post.
EVIL='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"blocked","evidence_associations":[],"legacy_audit_evidence":[]}]}'
printf '%s\n' "$EVIL" > "$D/feature_list.json"
rc=0
journal_recover "$D" >/dev/null 2>&1 || rc=$?
check "G3a: third-SHA recover blocks (rc 1)" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
check "G3b: recovery_blocked recorded" "1" "$(jq -sr '[.[] | select(.op == "recovery_blocked" and .op_key == "'"$OK"'")] | length' "$JP")"
check "G3c: external SHA NOT minted into a commit" "0" "$(jq -sr '[.[] | select(.op == "commit" and .op_key == "'"$OK"'")] | length' "$JP")"
rc=0
journal_init "$D" >/dev/null 2>&1 || rc=$?
check "G3d: journal_init blocked by the orphan (rc 1)" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"

# ============================================================================
# F3: harness-feature.sh CLI returns NONZERO on committed-append failure (never
#   warn-and-continue). The registry is already updated (atomic write), the
#   orphan pending with expected_post_sha is retained, and journal_recover rolls
#   it forward exactly; journal_replay then proves the CLI's mutation chain.
#   Crash injection: a background watcher makes the journal read-only as soon as
#   the CLI's pending line lands (between pending and committed). Retried until
#   the injection lands.
# ============================================================================
D3=""
injected=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  D3="$(mktemp -d "$TMPDIR/f3-$attempt-XXXX")"
  setup_project "$D3"
  JP3="$D3/.harness/registry-journal.ndjson"
  init3="$(sha256_file "$D3/feature_list.json")"
  ( while ! grep -q '"pending":true' "$JP3" 2>/dev/null; do :; done; chmod a-w "$JP3" 2>/dev/null; ) &
  WPID=$!
  bash "$ROOT_DIR/core/harness-feature.sh" add "$D3" "F-002" "inject" >/dev/null 2>&1
  rc=$?
  chmod u+w "$JP3" 2>/dev/null || true
  kill "$WPID" 2>/dev/null || true
  wait "$WPID" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then injected=1; break; fi
  rm -rf "$D3"
done
check "F3a: CLI add exits nonzero when committed append fails" "1" "$injected"
check "F3b: registry advanced (atomic write completed — recovery point)" "2" "$(jq -r '.revision' "$D3/feature_list.json")"
check "F3c: F-002 present at not_started" "not_started" "$(jq -r '.features[] | select(.id == "F-002") | .status' "$D3/feature_list.json")"
check "F3d: no committed line — orphan pending retained" "0" "$(jq -sr '[.[] | select(.op == "commit")] | length' "$JP3")"
rc=0
journal_recover "$D3" >/dev/null 2>&1 || rc=$?
check "F3e: recovery rolls forward after unblocking" "0" "$rc"
REC3="$(printf '{"revision":1,"features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}],"_recorded_sha":"%s"}' "$init3")"
jr=0
journal_replay "$D3" "$REC3" >/dev/null 2>&1 || jr=$?
check "F3f: replay proves the CLI's recovered add chain" "0" "$jr"

# ============================================================================
# F4: harness-verify.sh --write returns NONZERO on committed-append failure
#   (same fail-closed contract; exit 2). The evidence association is already in
#   the registry (recovery point) and journal_recover rolls it forward.
# ============================================================================
D4=""
injected=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  D4="$(mktemp -d "$TMPDIR/f4-$attempt-XXXX")"
  mkdir -p "$D4/.harness"
  printf '%s\n' '{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}' > "$D4/feature_list.json"
  init4="$(sha256_file "$D4/feature_list.json")"
  printf '%s\n' '{"project_type":"generic","verification":{"commands":[{"id":"ok","command":["bash","-c","exit 0"],"required_for_passing":true}]}}' > "$D4/.harness/config.json"
  printf '# Test Project\n' > "$D4/CLAUDE.md"
  git -C "$D4" init -q
  JP4="$D4/.harness/registry-journal.ndjson"
  ( while ! grep -q '"pending":true' "$JP4" 2>/dev/null; do :; done; chmod a-w "$JP4" 2>/dev/null; ) &
  WPID=$!
  bash "$ROOT_DIR/core/harness-verify.sh" "F-001" "$D4" --write >/dev/null 2>&1
  rc=$?
  chmod u+w "$JP4" 2>/dev/null || true
  kill "$WPID" 2>/dev/null || true
  wait "$WPID" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then injected=1; break; fi
  rm -rf "$D4"
done
check "F4a: verify --write exits nonzero when committed append fails" "1" "$injected"
check "F4b: evidence association already written (recovery point)" "1" "$(jq -r '[.features[] | select(.id == "F-001") | .evidence_associations[]?] | length' "$D4/feature_list.json")"
check "F4c: no committed line — orphan pending retained" "0" "$(jq -sr '[.[] | select(.op == "commit")] | length' "$JP4")"
rc=0
journal_recover "$D4" >/dev/null 2>&1 || rc=$?
check "F4d: recovery rolls the verify mutation forward" "0" "$rc"
REC4="$(printf '{"revision":1,"features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}],"_recorded_sha":"%s"}' "$init4")"
jr=0
journal_replay "$D4" "$REC4" >/dev/null 2>&1 || jr=$?
check "F4e: replay proves the recovered evidence_associate chain" "0" "$jr"

# ============================================================================
# J: recovery is APPEND-ONLY (Codex item 3)
#   journal_recover must NEVER overwrite or truncate the journal file. An
#   orphan pending (current == pre-SHA) is backed out by APPENDING a
#   recovery_backout record that marks the orphan op_key — the orphan pending
#   line itself is preserved in the audit trail. DWM append-only contract
#   (recorded bytes are a PREFIX of current bytes) is satisfied at all times.
# ============================================================================
DJ="$(mktemp -d "$TMPDIR/j-XXXX")"
setup_project "$DJ"
JJP="$DJ/.harness/registry-journal.ndjson"
journal_ready "$DJ"
PRE_J="$(sha256_file "$DJ/feature_list.json")"
# Inject a strict-binding orphan (with expected_post_sha) so journal_recover
# exercises the strict-pairing → backout flow. The expected_post_sha is the
# hash of POST_J; current == pre_SHA → BACKOUT (append-only recovery_backout).
TS_J="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
POST_J='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
POST_J_SHA="$(printf '%s\n' "$POST_J" | sha256sum 2>/dev/null | awk '{print $1}')"
printf '%s\n' "{\"ts\":\"$TS_J\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"0a0a0a0a0a0a0a0a\",\"feature_list_sha_before\":\"$PRE_J\",\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null,\"expected_post_sha\":\"$POST_J_SHA\"}" >> "$JJP"
BEFORE_BYTES="$(cat "$JJP")"
BEFORE_LINES="$(wc -l < "$JJP" | tr -d ' \t\r')"
rc=0
journal_recover "$DJ" >/dev/null 2>&1 || rc=$?
check "J1: backout returns rc 0" "0" "$rc"
AFTER_BYTES="$(cat "$JJP")"
AFTER_LINES="$(wc -l < "$JJP" | tr -d ' \t\r')"
# J2: journal bytes strictly grew (append-only — never truncated)
case "$AFTER_BYTES" in "$BEFORE_BYTES"*) check "J2: journal bytes strictly grew (append-only)" "1" "1" ;; *) check "J2: journal bytes strictly grew (append-only)" "1" "0" ;; esac
check "J3: line count grew by exactly one (the backout record)" "$((BEFORE_LINES + 1))" "$AFTER_LINES"
check "J4: recovery_backout line appended" "1" "$(jq -sr '[.[] | select(.op == "recovery_backout" and .op_key == "0a0a0a0a0a0a0a0a")] | length' "$JJP")"
check "J5: orphan pending retained in audit trail" "1" "$(jq -sr '[.[] | select(.op_key == "0a0a0a0a0a0a0a0a" and .pending == true)] | length' "$JJP")"

# J6: replay accepts the append-only chain (orphan op is filtered out by the
# recovery_backout marker, leaving zero pending-without-commit violations)
JR_J="$(mktemp -d "$TMPDIR/jr-XXXX")"
cp -r "$DJ/." "$JR_J/"
JR_JP="$JR_J/.harness/registry-journal.ndjson"
REC_J="$(printf '{"revision":1,"features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}],"_recorded_sha":"%s"}' "$PRE_J")"
jr=0
journal_replay "$JR_J" "$REC_J" >/dev/null 2>&1 || jr=$?
check "J6: replay accepts the backout-augmented chain (orphan filtered)" "0" "$jr"

# J7: idempotency — running journal_recover a SECOND time must be a no-op (no
# extra backout lines, same line count, same rc 0)
LINES_BEFORE_RE="$(wc -l < "$JJP" | tr -d ' \t\r')"
rc=0
journal_recover "$DJ" >/dev/null 2>&1 || rc=$?
check "J7a: idempotent recover rc 0" "0" "$rc"
LINES_AFTER_RE="$(wc -l < "$JJP" | tr -d ' \t\r')"
check "J7b: idempotent recover does not append (line count unchanged)" "$LINES_BEFORE_RE" "$LINES_AFTER_RE"
check "J7c: idempotent recover leaves exactly ONE recovery_backout for the op_key" "1" "$(jq -sr '[.[] | select(.op == "recovery_backout" and .op_key == "0a0a0a0a0a0a0a0a")] | length' "$JJP")"

echo ""
echo "Journal-Recover Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
