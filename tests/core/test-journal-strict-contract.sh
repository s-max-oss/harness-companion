#!/bin/bash
# test-journal-strict-contract.sh — P0-1 / P0-2 / P0-5 NEGATIVE tests
#
# The Codex 终验 demanded FAIL-CLOSED, independently-verifiable journal contracts.
# This file pins them with adversarial inputs:
#
#   A. duplicate pending / duplicate commit / commit-without-pending are rejected
#      by journal_verify_pairs AND journal_replay — a present commit NEVER causes
#      the strict check to be skipped.
#   B. SHA binding — commit.feature_list_sha_after must BYTE-EQUAL the pending's
#      expected_post_sha (sha_after_mismatch); a third-SHA orphan is a blocker
#      (recovery_blocked) and replay rejects the orphan; a journal whose tail sha
#      does not equal the current feature_list.json is rejected (tail_sha_mismatch).
#   C. evidence/run_id EXACT binding — the reachable forgery is a tampered run_id
#      INSIDE the journal's evidence_associate pending (run_id is not sha-bound),
#      which keeps the sha chain intact and forces the structured-array exact
#      comparison to fire (evidence_run_id_mismatch): "r-1" must never match
#      "r-1 forged" / " r-1 " / "r-2"; the exact match (C1) is the positive
#      control and passes.
#   F. journal_migrate_legacy is FAIL-CLOSED (P0-5) — corrupt legacy lines (F1),
#      legacy commit-without-pending (F2), or an install/write failure (F4) →
#      NONZERO with the old files kept and NO checkpoint marker minted; a valid
#      legacy migration (F3) succeeds and preserves the append-only contract
#      (old journal bytes are a STRICT PREFIX of the new journal — history is
#      never lost).
#   G. (three-way recovery states are covered by test-journal-recover.sh; here we
#      additionally prove the migrated journal stays append-only-compatible with
#      the pre-migration journal.)
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

# count_in <needle> <file> — grep -c that is quiet and yields "0" on no match
count_in() {
  grep -c "$1" "$2" 2>/dev/null || true
}

# setup_project <dir> — canonical valid rev1 registry + init journal. Echoes the
# rev1 sha (recorded anchor) on STDOUT.
setup_project() {
  local d="$1"
  mkdir -p "$d/.harness"
  printf '%s\n' '{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}' > "$d/feature_list.json"
  journal_init "$d"
  sha256_file "$d/feature_list.json"
}

REV1_FEATURES='[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]'
REV2_WITH_F002='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"F-002","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}'

# rec_doc <rev1_sha> — the recorded snapshot doc (rev1 F-001 not_started)
rec_doc() {
  printf '{"revision":1,"features":%s,"_recorded_sha":"%s"}' "$REV1_FEATURES" "$1"
}

# ---- A1: duplicate COMMIT is rejected --------------------------------------
D="$(mktemp -d "$TMPDIR/a1-XXXX")"
INIT="$(setup_project "$D")"
JP="$D/.harness/registry-journal.ndjson"
ps="$(printf '%s\n' "$REV2_WITH_F002" | sha256sum 2>/dev/null | awk '{print $1}')"
ok="$(journal_record_pending "$D" add F-002 "" not_started --revision 2 --post-sha "$ps")"
printf '%s\n' "$REV2_WITH_F002" > "$D/feature_list.json"
journal_record_committed "$D" "$ok" "$ps"
# inject a SECOND commit line with the SAME op_key
jq -c --arg k "$ok" 'select(.op == "commit" and .op_key == $k)' "$JP" >> "$JP"
V="$(journal_verify_pairs "$D")"; rc=$?
check "A1a: verify_pairs returns nonzero on duplicate commit" "1" "$rc"
check "A1b: token duplicate_commit" "duplicate_commit" "$V"
jr=0; journal_replay "$D" "$(rec_doc "$INIT")" >/dev/null 2>&1 || jr=$?
check "A1c: replay rejects duplicate commit" "1" "$jr"

# ---- A2: duplicate PENDING is rejected --------------------------------------
D="$(mktemp -d "$TMPDIR/a2-XXXX")"
INIT="$(setup_project "$D")"
JP="$D/.harness/registry-journal.ndjson"
ps="$(printf '%s\n' "$REV2_WITH_F002" | sha256sum 2>/dev/null | awk '{print $1}')"
ok="$(journal_record_pending "$D" add F-002 "" not_started --revision 2 --post-sha "$ps")"
printf '%s\n' "$REV2_WITH_F002" > "$D/feature_list.json"
journal_record_committed "$D" "$ok" "$ps"
# inject a SECOND pending line with the SAME op_key
jq -c --arg k "$ok" 'select(.pending == true and .op == "add" and .op_key == $k)' "$JP" >> "$JP"
V="$(journal_verify_pairs "$D")"; rc=$?
check "A2a: verify_pairs returns nonzero on duplicate pending" "1" "$rc"
check "A2b: token duplicate_pending" "duplicate_pending" "$V"
jr=0; journal_replay "$D" "$(rec_doc "$INIT")" >/dev/null 2>&1 || jr=$?
check "A2c: replay rejects duplicate pending" "1" "$jr"

# ---- A3: COMMIT-WITHOUT-PENDING is rejected ---------------------------------
D="$(mktemp -d "$TMPDIR/a3-XXXX")"
INIT="$(setup_project "$D")"
JP="$D/.harness/registry-journal.ndjson"
ps="$(printf '%s\n' "$REV2_WITH_F002" | sha256sum 2>/dev/null | awk '{print $1}')"
ok="$(journal_record_pending "$D" add F-002 "" not_started --revision 2 --post-sha "$ps")"
printf '%s\n' "$REV2_WITH_F002" > "$D/feature_list.json"
journal_record_committed "$D" "$ok" "$ps"
# remove the pending line → the commit is now WITHOUT its pending partner
jq -c 'select(.pending != true or .op != "add")' "$JP" > "$D/.j2" && mv "$D/.j2" "$JP"
V="$(journal_verify_pairs "$D")"; rc=$?
check "A3a: verify_pairs returns nonzero on commit-without-pending" "1" "$rc"
check "A3b: token commit_without_pending" "commit_without_pending" "$V"
jr=0; journal_replay "$D" "$(rec_doc "$INIT")" >/dev/null 2>&1 || jr=$?
check "A3c: replay rejects commit-without-pending" "1" "$jr"

# ---- B1: expected_post_sha MISMATCH is rejected -----------------------------
D="$(mktemp -d "$TMPDIR/b1-XXXX")"
INIT="$(setup_project "$D")"
JP="$D/.harness/registry-journal.ndjson"
ps="$(printf '%s\n' "$REV2_WITH_F002" | sha256sum 2>/dev/null | awk '{print $1}')"
ok="$(journal_record_pending "$D" add F-002 "" not_started --revision 2 --post-sha "$ps")"
printf '%s\n' "$REV2_WITH_F002" > "$D/feature_list.json"
journal_record_committed "$D" "$ok" "$ps"
# corrupt the commit sha_after to a DIFFERENT valid-hex sha (not the expected)
WRONG="0000000000000000000000000000000000000000000000000000000000000000"
jq -c --arg w "$WRONG" 'if (.op == "commit") then .feature_list_sha_after = $w else . end' "$JP" > "$D/.j2" && mv "$D/.j2" "$JP"
V="$(journal_verify_pairs "$D")"; rc=$?
check "B1a: verify_pairs rejects sha_after mismatch" "1" "$rc"
check "B1b: token sha_after_mismatch" "sha_after_mismatch" "$V"
jr=0; journal_replay "$D" "$(rec_doc "$INIT")" >/dev/null 2>&1 || jr=$?
check "B1c: replay rejects sha_after mismatch" "1" "$jr"

# ---- B2: THIRD-SHA orphan — recover blocks, replay rejects ------------------
D="$(mktemp -d "$TMPDIR/b2-XXXX")"
INIT="$(setup_project "$D")"
JP="$D/.harness/registry-journal.ndjson"
POST3='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
ps3="$(printf '%s\n' "$POST3" | sha256sum 2>/dev/null | awk '{print $1}')"
ok="$(journal_record_pending "$D" status F-001 not_started in_progress --revision 2 --post-sha "$ps3")"
# THIRD sha: a different rev2 content — neither pre (rev1) nor expected post.
EVIL='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"blocked","evidence_associations":[],"legacy_audit_evidence":[]}]}'
printf '%s\n' "$EVIL" > "$D/feature_list.json"
rc=0; journal_recover "$D" >/dev/null 2>&1 || rc=$?
check "B2a: recover blocks on third SHA" "1" "$rc"
check "B2b: recovery_blocked recorded" "1" "$(count_in 'recovery_blocked' "$JP")"
jr=0; journal_replay "$D" "$(rec_doc "$INIT")" >/dev/null 2>&1 || jr=$?
check "B2c: replay rejects the blocked orphan (anchor = rev1, not current)" "1" "$jr"

# ---- B3: journal TAIL sha != current file → rejected ------------------------
D="$(mktemp -d "$TMPDIR/b3-XXXX")"
INIT="$(setup_project "$D")"
JP="$D/.harness/registry-journal.ndjson"
ps="$(printf '%s\n' "$REV2_WITH_F002" | sha256sum 2>/dev/null | awk '{print $1}')"
ok="$(journal_record_pending "$D" add F-002 "" not_started --revision 2 --post-sha "$ps")"
printf '%s\n' "$REV2_WITH_F002" > "$D/feature_list.json"
journal_record_committed "$D" "$ok" "$ps"
# Write a DIFFERENT rev2 content → current file sha != journal tail sha
OTHER='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"F-002","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
printf '%s\n' "$OTHER" > "$D/feature_list.json"
R="$(journal_replay "$D" "$(rec_doc "$INIT")" 2>/dev/null)"
check "B3a: replay rejects tail-sha mismatch" "tail_sha_mismatch" "$R"

# ---- C: evidence/run_id EXACT binding ---------------------------------------
# The reachable forgery is a tampered run_id INSIDE the journal's
# evidence_associate PENDING line (run_id is not sha-bound — tampering it keeps
# the sha chain contiguous, so the exact-array comparison is the ONLY detector).
E="$(mktemp -d "$TMPDIR/c-XXXX")"
mkdir -p "$E/.harness"
REV1_EV='{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
printf '%s\n' "$REV1_EV" > "$E/feature_list.json"
EJP="$E/.harness/registry-journal.ndjson"
journal_init "$E"
EINIT="$(sha256_file "$E/feature_list.json")"
EREC="$(printf '{"revision":1,"features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}],"_recorded_sha":"%s"}' "$EINIT")"
PREV='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[{"run_id":"r-1"}],"legacy_audit_evidence":[]}]}'
p2="$(printf '%s\n' "$PREV" | sha256sum 2>/dev/null | awk '{print $1}')"
ek="$(journal_record_pending "$E" evidence_associate F-001 "" "" --revision 2 --run-id "r-1" --post-sha "$p2")"
printf '%s\n' "$PREV" > "$E/feature_list.json"
journal_record_committed "$E" "$ek" "$p2"

jr=0; journal_replay "$E" "$EREC" >/dev/null 2>&1 || jr=$?
check "C1a: EXACT match (acc=[r-1] cur=[r-1]) valid" "0" "$jr"

# C2: forged run_id in the journal pending (sha chain stays contiguous)
tamper_pending_run_id() {
  jq -c --arg r "$1" 'if (.op == "evidence_associate" and .pending == true) then .run_id = $r else . end' "$EJP" > "$E/.j2" && mv "$E/.j2" "$EJP"
}
tamper_pending_run_id 'r-1 forged'
R="$(journal_replay "$E" "$EREC" 2>/dev/null)"
check "C2a: forged run_id rejected" "evidence_run_id_mismatch" "$R"

tamper_pending_run_id ' r-1 '
R="$(journal_replay "$E" "$EREC" 2>/dev/null)"
check "C3a: whitespace-mangled run_id rejected" "evidence_run_id_mismatch" "$R"

tamper_pending_run_id 'r-2'
R="$(journal_replay "$E" "$EREC" 2>/dev/null)"
check "C4a: replaced run_id rejected" "evidence_run_id_mismatch" "$R"

# ---- F: journal_migrate_legacy FAIL-CLOSED (P0-5) ---------------------------
M="$(mktemp -d "$TMPDIR/f-XXXX")"
mkdir -p "$M/.harness/.registry.lock"
MJP="$M/.harness/registry-journal.ndjson"
setup_project "$M" >/dev/null
LEG="$M/.harness/.registry.lock/journal.ndjson"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
P3='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
p3s="$(printf '%s\n' "$P3" | sha256sum 2>/dev/null | awk '{print $1}')"

# F1: corrupt (non-JSON) legacy → rc 1, legacy KEPT, no marker
printf '%s\n' 'this is not json at all' > "$LEG"
rc=0; journal_migrate_legacy "$M" >/dev/null 2>&1 || rc=$?
check "F1a: corrupt legacy → nonzero" "1" "$rc"
check "F1b: legacy file kept on corrupt" "1" "$( [ -f "$LEG" ] && echo 1 || echo 0 )"
check "F1c: no checkpoint marker minted" "0" "$(count_in 'checkpoint_migrated' "$MJP")"

# F2: legacy COMMIT-WITHOUT-PENDING → rc 1, legacy KEPT, no marker
printf '%s\n' "{\"ts\":\"$TS\",\"op\":\"commit\",\"op_key\":\"bbbbbbbbbbbbbbbb\",\"pending\":false,\"feature_list_sha_after\":\"$p3s\"}" > "$LEG"
rc=0; journal_migrate_legacy "$M" >/dev/null 2>&1 || rc=$?
check "F2a: commit-without-pending legacy → nonzero" "1" "$rc"
check "F2b: legacy file kept" "1" "$( [ -f "$LEG" ] && echo 1 || echo 0 )"
check "F2c: no checkpoint marker minted" "0" "$(count_in 'checkpoint_migrated' "$MJP")"

# F3: VALID legacy (pending WITHOUT expected_post_sha + its commit) → migration
# succeeds, backfill satisfies the strict contract, legacy REMOVED, marker + a
# recovery_backfill record present, and the migrated journal passes strict
# pairing. (Leftover F2 legacy is cleared BEFORE init so no noise is emitted.)
printf '%s\n' '{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}' > "$M/feature_list.json"
rm -f "$LEG"
rm -f "$MJP"; journal_init "$M"
pre2="$(sha256_file "$M/feature_list.json")"
printf '%s\n' "{\"ts\":\"$TS\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"cccccccccccccccc\",\"feature_list_sha_before\":\"$pre2\",\"feature_list_sha_after\":\"$p3s\",\"evidence_run_ids_after\":[],\"run_id\":null}" > "$LEG"
printf '%s\n' "{\"ts\":\"$TS\",\"op\":\"commit\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":false,\"op_key\":\"cccccccccccccccc\",\"feature_list_sha_before\":\"$pre2\",\"feature_list_sha_after\":\"$p3s\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$LEG"
OLD_JP_BYTES="$(cat "$MJP")"
rc=0; journal_migrate_legacy "$M" >/dev/null 2>&1 || rc=$?
check "F3a: valid legacy migration succeeds" "0" "$rc"
check "F3b: legacy file removed after success" "0" "$( [ -f "$LEG" ] && echo 1 || echo 0 )"
check "F3c: checkpoint marker present" "1" "$(count_in 'checkpoint_migrated' "$MJP")"
check "F3d: recovery_backfill record present" "1" "$(count_in 'recovery_backfill' "$MJP")"
check "F3e: migrated journal passes strict pairing" "0" "$(journal_verify_pairs "$M" >/dev/null 2>&1; echo $?)"

# G1 (append-only compatibility): the pre-migration journal bytes are a STRICT
# PREFIX of the migrated journal — history is never lost or rewritten.
NEW_JP_BYTES="$(cat "$MJP")"
case "$NEW_JP_BYTES" in "$OLD_JP_BYTES"*) pref=1 ;; *) pref=0 ;; esac
check "G1a: pre-migration journal is a strict prefix of migrated journal" "1" "$pref"

# F4: INSTALL (write) failure — the atomic probe→journal install fails → rc 1,
# the legacy file is KEPT, and NO checkpoint marker is minted. The old files are
# untouched exactly as if migration never ran. (Injected by overriding mv -f
# inside a subshell so only the migration's install step fails.)
printf '%s\n' '{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}' > "$M/feature_list.json"
rm -f "$LEG"
rm -f "$MJP"; journal_init "$M"
pre3="$(sha256_file "$M/feature_list.json")"
printf '%s\n' "{\"ts\":\"$TS\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"dddddddddddddddd\",\"feature_list_sha_before\":\"$pre3\",\"feature_list_sha_after\":\"$p3s\",\"evidence_run_ids_after\":[],\"run_id\":null}" > "$LEG"
printf '%s\n' "{\"ts\":\"$TS\",\"op\":\"commit\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":false,\"op_key\":\"dddddddddddddddd\",\"feature_list_sha_before\":\"$pre3\",\"feature_list_sha_after\":\"$p3s\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$LEG"
BEFORE_JP_BYTES="$(cat "$MJP")"
rc=0
( mv() { return 1; }; journal_migrate_legacy "$M" ) >/dev/null 2>&1 || rc=$?
check "F4a: install failure → nonzero" "1" "$rc"
check "F4b: legacy file preserved on install failure" "1" "$( [ -f "$LEG" ] && echo 1 || echo 0 )"
check "F4c: no checkpoint marker minted" "0" "$(count_in 'checkpoint_migrated' "$MJP")"
AFTER_JP_BYTES="$(cat "$MJP")"
check "F4d: canonical journal byte-identical (untouched on failure)" "1" "$( [ "$BEFORE_JP_BYTES" = "$AFTER_JP_BYTES" ] && echo 1 || echo 0 )"

# ---- H: early-return-when-recorded-sha-equals-current is REJECTED ----------
# Codex item 1: when recorded_doc._recorded_sha == current feature_list.json sha,
# journal_replay previously short-circuited with rc=0 BEFORE running orphan +
# journal_verify_pairs. A present commit is no excuse to skip the strict check.
# Inject a duplicate_pending in the journal while recorded_doc._recorded_sha ==
# current sha; replay MUST return 1, not 0.
H="$(mktemp -d "$TMPDIR/h-XXXX")"
INIT_H="$(setup_project "$H")"
HJP="$H/.harness/registry-journal.ndjson"
HPS="$(printf '%s\n' "$REV2_WITH_F002" | sha256sum 2>/dev/null | awk '{print $1}')"
ok_h="$(journal_record_pending "$H" add F-002 "" not_started --revision 2 --post-sha "$HPS")"
printf '%s\n' "$REV2_WITH_F002" > "$H/feature_list.json"
journal_record_committed "$H" "$ok_h" "$HPS"
CUR_H="$(sha256_file "$H/feature_list.json")"
# recorded_doc whose _recorded_sha == current sha (would trigger the early-return
# at line 638-640 in the unfixed code). The recorded features must be the
# CURRENT features list — schema-valid rev2 with F-001 and F-002 not_started.
H_REC_FEATURES='[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"F-002","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]'
HREC="$(printf '{"revision":2,"features":%s,"_recorded_sha":"%s"}' "$H_REC_FEATURES" "$CUR_H")"
# Inject a SECOND pending line with the SAME op_key — strict pairing must catch it
jq -c --arg k "$ok_h" 'select(.pending == true and .op == "add" and .op_key == $k)' "$HJP" >> "$HJP"
V_H="$(journal_verify_pairs "$H")"; rc_h=$?
check "H0: verify_pairs catches injected duplicate pending" "1" "$rc_h"
check "H0b: token duplicate_pending" "duplicate_pending" "$V_H"
jr_h=0; journal_replay "$H" "$HREC" >/dev/null 2>&1 || jr_h=$?
check "H1: replay rejects duplicate_pending even when recorded_sha == current_sha (no early-return)" "1" "$jr_h"

# ---- I: pending strict binding at WRITE time --------------------------------
# Codex item 2+5: the writer must bind expected_post_sha at PENDING time for any
# mutation that mutates the registry, and journal_record_committed must reject
# (rc 1) when the pending's expected_post_sha is null/empty (the existing
# verify_pairs reason is enforced at strict-pairing time, but a writer must
# fail-closed BEFORE the line is appended — Codex item 5).
I="$(mktemp -d "$TMPDIR/i-XXXX")"
setup_project "$I" >/dev/null
IJP="$I/.harness/registry-journal.ndjson"

# I1: add without --post-sha → rc 1, no pending line appended
n_lines_before="$(wc -l < "$IJP" | tr -d ' \t\r')"
rc_i=0; out_i="$(journal_record_pending "$I" add F-002 "" not_started --revision 2 2>&1)"; rc_i=$?
check "I1a: add without --post-sha returns nonzero" "1" "$rc_i"
n_lines_after="$(wc -l < "$IJP" | tr -d ' \t\r')"
check "I1b: no pending line appended on missing --post-sha" "$n_lines_before" "$n_lines_after"

# I2: status without --post-sha → rc 1
rc_i=0; out_i="$(journal_record_pending "$I" status F-001 not_started in_progress --revision 2 2>&1)"; rc_i=$?
check "I2a: status without --post-sha returns nonzero" "1" "$rc_i"

# I3: evidence_associate without --post-sha → rc 1
rc_i=0; out_i="$(journal_record_pending "$I" evidence_associate F-001 "" "" --revision 2 --run-id "r-1" 2>&1)"; rc_i=$?
check "I3a: evidence_associate without --post-sha returns nonzero" "1" "$rc_i"

# I4: --post-sha empty → rc 1 (not silently nullified)
rc_i=0; out_i="$(journal_record_pending "$I" add F-002 "" not_started --revision 2 --post-sha "" 2>&1)"; rc_i=$?
check "I4a: --post-sha empty returns nonzero" "1" "$rc_i"

# I5: --post-sha not 64-hex → rc 1
rc_i=0; out_i="$(journal_record_pending "$I" add F-002 "" not_started --revision 2 --post-sha "deadbeef" 2>&1)"; rc_i=$?
check "I5a: --post-sha not 64-hex returns nonzero" "1" "$rc_i"

# I6: journal_record_committed against a pending lacking expected_post_sha (no
# recovery_backfill) → rc 1. We hand-construct a journal that has a pending
# line WITHOUT expected_post_sha and its committed partner, then call
# journal_record_committed. Since the legacy backfill already populates the
# recovery_backfill record on the journal_init call, we instead verify the WRITE
# check by constructing a journal without recovery_backfill.
I6="$(mktemp -d "$TMPDIR/i6-XXXX")"
mkdir -p "$I6/.harness"
REV0_I6='{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}'
printf '%s\n' "$REV0_I6" > "$I6/feature_list.json"
TS_I6="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
PRE_I6="$(sha256_file "$I6/feature_list.json")"
POST_I6='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
PSHA_I6="$(printf '%s\n' "$POST_I6" | sha256sum | awk '{print $1}')"
# write journal directly (no recovery_backfill, no expected_post_sha on pending)
printf '%s\n' "{\"ts\":\"$TS_I6\",\"op\":\"journal_init\",\"revision\":0,\"feature_id\":null,\"from\":null,\"to\":null,\"pending\":false,\"op_key\":null,\"feature_list_sha_before\":null,\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null}" > "$I6/.harness/registry-journal.ndjson"
printf '%s\n' "{\"ts\":\"$TS_I6\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"eeeeeeeeeeeeeeee\",\"feature_list_sha_before\":\"$PRE_I6\",\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$I6/.harness/registry-journal.ndjson"
# NOTE: write the registry file BEFORE calling committed (commit must be the last
# step). commit() should reject because pending has no expected_post_sha AND no
# recovery_backfill record.
printf '%s\n' "$POST_I6" > "$I6/feature_list.json"
rc_i=0; out_i="$(journal_record_committed "$I6" "eeeeeeeeeeeeeeee" "$PSHA_I6" 2>&1)"; rc_i=$?
check "I6a: commit rejects pending with no expected_post_sha and no recovery_backfill" "1" "$rc_i"

# I7: but the SAME scenario with a recovery_backfill record present should be
# accepted (legacy compat — the existing journal_verify_pairs already requires
# this; ensure the writer is consistent).
I7="$(mktemp -d "$TMPDIR/i7-XXXX")"
mkdir -p "$I7/.harness"
printf '%s\n' "$REV0_I6" > "$I7/feature_list.json"
TS_I7="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
PRE_I7="$(sha256_file "$I7/feature_list.json")"
PSHA_I7="$(printf '%s\n' "$POST_I6" | sha256sum | awk '{print $1}')"
printf '%s\n' "{\"ts\":\"$TS_I7\",\"op\":\"journal_init\",\"revision\":0,\"feature_id\":null,\"from\":null,\"to\":null,\"pending\":false,\"op_key\":null,\"feature_list_sha_before\":null,\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null}" > "$I7/.harness/registry-journal.ndjson"
printf '%s\n' "{\"ts\":\"$TS_I7\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"ffffffffffffffff\",\"feature_list_sha_before\":\"$PRE_I7\",\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$I7/.harness/registry-journal.ndjson"
printf '%s\n' "{\"ts\":\"$TS_I7\",\"op\":\"commit\",\"feature_id\":null,\"from\":null,\"to\":null,\"revision\":2,\"pending\":false,\"op_key\":\"ffffffffffffffff\",\"feature_list_sha_before\":null,\"feature_list_sha_after\":\"$PSHA_I7\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$I7/.harness/registry-journal.ndjson"
printf '%s\n' "{\"ts\":\"$TS_I7\",\"op\":\"recovery_backfill\",\"op_key\":\"ffffffffffffffff\",\"expected_post_sha\":\"$PSHA_I7\",\"reason\":\"legacy pending lacked expected_post_sha — derived from committed feature_list_sha_after (deterministic, not fabricated)\"}" >> "$I7/.harness/registry-journal.ndjson"
printf '%s\n' "$POST_I6" > "$I7/feature_list.json"
# Write a SECOND commit to trigger the writer-side check. Pending is the one
# we just constructed (no expected_post_sha) but recovery_backfill is present.
# Writer must accept because the existing backfill resolves the binding.
rc_i=0; out_i="$(journal_record_committed "$I7" "ffffffffffffffff" "$PSHA_I7" 2>&1)"; rc_i=$?
check "I7a: commit accepts pending with recovery_backfill present" "0" "$rc_i"

# ---- K: legacy migration fail-atomic (Codex item 4) ------------------------
# Three mid-stage failure scenarios each MUST restore the canonical journal AND
# the legacy file to their pre-migration byte-identical state. The "no swap
# unless both files fully migrated" contract means:
#   K1 — legacy line validate fails (probe not assembled)
#   K2 — probe assembly / verify_pairs fails (probe built but journal unchanged)
#   K3 — probe install (mv) fails AFTER legacy file has been staged aside
# On any of these failures, BOTH `$jp` and `$legacy` must remain byte-equal to
# their pre-call state; no checkpoint_migrated is ever minted.
K1="$(mktemp -d "$TMPDIR/k1-XXXX")"
mkdir -p "$K1/.harness/.registry.lock"
K1JP="$K1/.harness/registry-journal.ndjson"
K1LEG="$K1/.harness/.registry.lock/journal.ndjson"
setup_project "$K1" >/dev/null
# Corrupt legacy (non-JSON line)
printf '%s\n' 'this is not json at all' >> "$K1LEG"
K1_JP_BEFORE="$(cat "$K1JP")"
K1_LEG_BEFORE="$(cat "$K1LEG")"
rc=0; journal_migrate_legacy "$K1" >/dev/null 2>&1 || rc=$?
check "K1a: corrupt legacy → nonzero" "1" "$rc"
check "K1b: canonical journal untouched" "$K1_JP_BEFORE" "$(cat "$K1JP")"
check "K1c: legacy file untouched" "$K1_LEG_BEFORE" "$(cat "$K1LEG")"
check "K1d: no checkpoint marker minted" "0" "$(count_in 'checkpoint_migrated' "$K1JP")"

# K2: legacy with a commit-without-pending — verify_pairs fails on the probe
K2="$(mktemp -d "$TMPDIR/k2-XXXX")"
mkdir -p "$K2/.harness/.registry.lock"
K2JP="$K2/.harness/registry-journal.ndjson"
K2LEG="$K2/.harness/.registry.lock/journal.ndjson"
setup_project "$K2" >/dev/null
TS_K2=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
# Compute SHA of the rev2 registry by piping through printf + sha256sum (no
# inline JSON literal — bash parser sees {} from JSON as command grouping).
K2POST_DOC='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
PSHA_K2="$(printf '%s\n' "$K2POST_DOC" | sha256sum 2>/dev/null | awk '{print $1}')"
printf '%s\n' "{\"ts\":\"$TS_K2\",\"op\":\"commit\",\"op_key\":\"bbbbbbbbbbbbbbbb\",\"pending\":false,\"feature_list_sha_after\":\"$PSHA_K2\"}" >> "$K2LEG"
K2_JP_BEFORE="$(cat "$K2JP")"
K2_LEG_BEFORE="$(cat "$K2LEG")"
rc=0; journal_migrate_legacy "$K2" >/dev/null 2>&1 || rc=$?
check "K2a: commit-without-pending → nonzero" "1" "$rc"
check "K2b: canonical journal untouched" "$K2_JP_BEFORE" "$(cat "$K2JP")"
check "K2c: legacy file untouched" "$K2_LEG_BEFORE" "$(cat "$K2LEG")"
check "K2d: no checkpoint marker minted" "0" "$(count_in 'checkpoint_migrated' "$K2JP")"

# K3: install (write) failure → rc 1, legacy file KEPT, NO checkpoint marker.
# Same injection as F4: override `mv -f` in a subshell so only the probe→journal
# install step fails, then assert fail-atomic byte-identity of BOTH files. This
# is the Codex item-4 named scenario — a write failure on a VALID legacy line.
K3="$(mktemp -d "$TMPDIR/k3-XXXX")"
mkdir -p "$K3/.harness/.registry.lock"
K3JP="$K3/.harness/registry-journal.ndjson"
K3LEG="$K3/.harness/.registry.lock/journal.ndjson"
setup_project "$K3" >/dev/null
TS_K3=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
K3PRE="$(sha256_file "$K3/feature_list.json")"
K3POST='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
K3PSHA="$(printf '%s\n' "$K3POST" | sha256sum 2>/dev/null | awk '{print $1}')"
printf '%s\n' "{\"ts\":\"$TS_K3\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"cccccccccccccccc\",\"feature_list_sha_before\":\"$K3PRE\",\"feature_list_sha_after\":\"$K3PSHA\",\"evidence_run_ids_after\":[],\"run_id\":null}" > "$K3LEG"
printf '%s\n' "{\"ts\":\"$TS_K3\",\"op\":\"commit\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":false,\"op_key\":\"cccccccccccccccc\",\"feature_list_sha_before\":\"$K3PRE\",\"feature_list_sha_after\":\"$K3PSHA\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$K3LEG"
K3_JP_BEFORE="$(cat "$K3JP")"
K3_LEG_BEFORE="$(cat "$K3LEG")"
rc=0
( mv() { return 1; }; journal_migrate_legacy "$K3" ) >/dev/null 2>&1 || rc=$?
check "K3a: install failure → nonzero" "1" "$rc"
check "K3b: canonical journal byte-identical (untouched on install failure)" "1" "$( [ "$K3_JP_BEFORE" = "$(cat "$K3JP")" ] && echo 1 || echo 0 )"
check "K3c: legacy file preserved on install failure" "1" "$( [ -f "$K3LEG" ] && echo 1 || echo 0 )"
check "K3d: legacy bytes byte-identical on install failure" "1" "$( [ "$K3_LEG_BEFORE" = "$(cat "$K3LEG")" ] && echo 1 || echo 0 )"
check "K3e: no checkpoint marker minted" "0" "$(count_in 'checkpoint_migrated' "$K3JP")"

echo ""
echo "Journal-Strict-Contract Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
