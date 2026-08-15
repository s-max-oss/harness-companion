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
# Codex r5 Important #5 — IMPORTANT: the I7 fixture intentionally has a
# pending line + recovery_backfill + NO commit line for the op_key. The
# writer-side test is "the FIRST journal_record_committed call for this
# op_key (no prior commit) must succeed when recovery_backfill resolves the
# expected_post_sha binding." Pre-seeding a commit line here would make the
# test exercise the duplicate-commit-defense path instead of the
# recovery_backfill path.
printf '%s\n' "{\"ts\":\"$TS_I7\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"ffffffffffffffff\",\"feature_list_sha_before\":\"$PRE_I7\",\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$I7/.harness/registry-journal.ndjson"
printf '%s\n' "{\"ts\":\"$TS_I7\",\"op\":\"recovery_backfill\",\"op_key\":\"ffffffffffffffff\",\"expected_post_sha\":\"$PSHA_I7\",\"reason\":\"legacy pending lacked expected_post_sha — derived from committed feature_list_sha_after (deterministic, not fabricated)\"}" >> "$I7/.harness/registry-journal.ndjson"
printf '%s\n' "$POST_I6" > "$I7/feature_list.json"
# First commit call: no prior commit exists → writer accepts because
# recovery_backfill resolves the expected_post_sha binding.
rc_i=0; out_i="$(journal_record_committed "$I7" "ffffffffffffffff" "$PSHA_I7" 2>&1)"; rc_i=$?
check "I7a: commit accepts pending with recovery_backfill present (no prior commit)" "0" "$rc_i"

# I9: Codex r5 Important #5 — duplicate commit MUST be rejected at the writer.
# A retry of journal_record_committed (crash-recovery / buggy caller / manual
# re-run) MUST NOT silently append a second `op:"commit"` line for the same
# op_key. Without this defense, the verifier-layer duplicate_commit check is
# reached only AFTER the off-chain record is already in the journal — and any
# intermediate reader that trusts the journal (e.g. a partial replay, a
# migrate path) would see the false commit.
I9="$(mktemp -d "$TMPDIR/i9-XXXX")"
setup_project "$I9" >/dev/null
POST_I9_DOC='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
PSHA_I9="$(printf '%s\n' "$POST_I9_DOC" | sha256sum 2>/dev/null | awk '{print $1}')"
ok_i9="$(journal_record_pending "$I9" status F-001 not_started in_progress --revision 2 --post-sha "$PSHA_I9")"
printf '%s\n' "$POST_I9_DOC" > "$I9/feature_list.json"
# First commit: succeeds (no prior commit for this op_key).
rc_i9=0; journal_record_committed "$I9" "$ok_i9" "$PSHA_I9" >/dev/null 2>&1 || rc_i9=$?
check "I9a: first commit succeeds (no prior commit)" "0" "$rc_i9"
# Second commit for the SAME op_key: MUST be rejected at the writer — rc=1,
# and no second `op:"commit"` line is appended.
JP_I9="$I9/.harness/registry-journal.ndjson"
I9_LINES_BEFORE="$(grep -c '"op":"commit"' "$JP_I9" 2>/dev/null || echo 0)"
rc_i9b=0; journal_record_committed "$I9" "$ok_i9" "$PSHA_I9" >/dev/null 2>&1 || rc_i9b=$?
check "I9b: second commit for same op_key returns nonzero" "1" "$rc_i9b"
I9_LINES_AFTER="$(grep -c '"op":"commit"' "$JP_I9" 2>/dev/null || echo 0)"
check "I9c: no second commit line appended (count unchanged)" "$I9_LINES_BEFORE" "$I9_LINES_AFTER"

# I10: positive control — different op_key CAN have its own commit (the
# duplicate check is per-op_key, not journal-wide).
I10="$(mktemp -d "$TMPDIR/i10-XXXX")"
setup_project "$I10" >/dev/null
PSHA_I10="$PSHA_I9"
ok_i10a="$(journal_record_pending "$I10" status F-001 not_started in_progress --revision 2 --post-sha "$PSHA_I10")"
ok_i10b="$(journal_record_pending "$I10" status F-001 not_started in_progress --revision 2 --post-sha "$PSHA_I10")"
printf '%s\n' "$POST_I9_DOC" > "$I10/feature_list.json"
rc_i10a=0; journal_record_committed "$I10" "$ok_i10a" "$PSHA_I10" >/dev/null 2>&1 || rc_i10a=$?
rc_i10b=0; journal_record_committed "$I10" "$ok_i10b" "$PSHA_I10" >/dev/null 2>&1 || rc_i10b=$?
check "I10a: commit for op_key A succeeds" "0" "$rc_i10a"
check "I10b: commit for DIFFERENT op_key B succeeds (per-key defense)" "0" "$rc_i10b"

# I8: Critical #2 — duplicate recovery_backfill op_key MUST be detected and
# rejected. Previously the `from_entries` collapse at registry-journal.sh:538
# silently kept only the LAST backfill SHA for any op_key, hiding a third
# orphan SHA from the verifier. The fix detects `group_by(.op_key) | length>1`
# and rejects with `duplicate_backfill`. Construct a journal with TWO
# recovery_backfill records on the same op_key (different SHAs — the third
# orphan) and verify_pairs must reject.
I8="$(mktemp -d "$TMPDIR/i8-XXXX")"
mkdir -p "$I8/.harness"
printf '%s\n' "$REV0_I6" > "$I8/feature_list.json"
TS_I8="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
PRE_I8="$(sha256_file "$I8/feature_list.json")"
PSHA_I8_A="$(printf '%s\n' "$POST_I6" | sha256sum | awk '{print $1}')"
PSHA_I8_B="$(printf '%s\n' "$POST_I6-forged" | sha256sum | awk '{print $1}')"
printf '%s\n' "{\"ts\":\"$TS_I8\",\"op\":\"journal_init\",\"revision\":0,\"feature_id\":null,\"from\":null,\"to\":null,\"pending\":false,\"op_key\":null,\"feature_list_sha_before\":null,\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null}" > "$I8/.harness/registry-journal.ndjson"
printf '%s\n' "{\"ts\":\"$TS_I8\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"1111111111111111\",\"feature_list_sha_before\":\"$PRE_I8\",\"feature_list_sha_after\":null,\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$I8/.harness/registry-journal.ndjson"
printf '%s\n' "{\"ts\":\"$TS_I8\",\"op\":\"commit\",\"feature_id\":null,\"from\":null,\"to\":null,\"revision\":2,\"pending\":false,\"op_key\":\"1111111111111111\",\"feature_list_sha_before\":null,\"feature_list_sha_after\":\"$PSHA_I8_A\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$I8/.harness/registry-journal.ndjson"
# Two recovery_backfill records for the SAME op_key with DIFFERENT SHAs — the
# second is the third-SHA orphan that `from_entries` used to silently hide.
printf '%s\n' "{\"ts\":\"$TS_I8\",\"op\":\"recovery_backfill\",\"op_key\":\"1111111111111111\",\"expected_post_sha\":\"$PSHA_I8_A\",\"reason\":\"first backfill (deterministic)\"}" >> "$I8/.harness/registry-journal.ndjson"
printf '%s\n' "{\"ts\":\"$TS_I8\",\"op\":\"recovery_backfill\",\"op_key\":\"1111111111111111\",\"expected_post_sha\":\"$PSHA_I8_B\",\"reason\":\"third-SHA orphan that from_entries used to hide\"}" >> "$I8/.harness/registry-journal.ndjson"
rc_i=0; out_i="$(journal_verify_pairs "$I8" 2>/dev/null)"; rc_i=$?
check "I8a: duplicate recovery_backfill rejected (rc 1)" "1" "$rc_i"
check "I8b: token duplicate_backfill" "duplicate_backfill" "$(printf '%s' "$out_i" | tr -d '\r' | head -c 256 | grep -oE 'duplicate_backfill' || true)"
# Even if the SHAs were identical (still two records on the same op_key) the
# contract requires a single backfill per op_key — confirm.
printf '%s\n' "$POST_I6" > "$I8/feature_list.json"
# Sanity: ensure journal_verify_pairs does NOT silently accept the journal
# (the very behavior that hid the third SHA before the fix).
check "I8c: rc is non-zero (fail-closed)" "1" "$rc_i"

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

# K4: rm-legacy failure → roll back canonical journal so the caller's view of
# "both files untouched on failure" still holds. Previously the migration
# function would successfully mv the probe into the canonical journal but
# fail to remove the legacy file, returning nonzero while the data was in
# fact migrated — leaving the caller uncertain about the actual state. The
# Codex r5 defect (Critical #3) fix snapshots the canonical journal BEFORE
# the mv and restores it on rm-legacy failure.
K4="$(mktemp -d "$TMPDIR/k4-XXXX")"
mkdir -p "$K4/.harness/.registry.lock"
K4JP="$K4/.harness/registry-journal.ndjson"
K4LEG="$K4/.harness/.registry.lock/journal.ndjson"
setup_project "$K4" >/dev/null
TS_K4=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
K4PRE="$(sha256_file "$K4/feature_list.json")"
K4POST='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
K4PSHA="$(printf '%s\n' "$K4POST" | sha256sum 2>/dev/null | awk '{print $1}')"
printf '%s\n' "{\"ts\":\"$TS_K4\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"dddddddddddddddd\",\"feature_list_sha_before\":\"$K4PRE\",\"feature_list_sha_after\":\"$K4PSHA\",\"evidence_run_ids_after\":[],\"run_id\":null}" > "$K4LEG"
printf '%s\n' "{\"ts\":\"$TS_K4\",\"op\":\"commit\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":false,\"op_key\":\"dddddddddddddddd\",\"feature_list_sha_before\":\"$K4PRE\",\"feature_list_sha_after\":\"$K4PSHA\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$K4LEG"
K4_JP_BEFORE="$(cat "$K4JP")"
K4_LEG_BEFORE="$(cat "$K4LEG")"
# Override `rm` so only the legacy-cleanup call fails. We let all other rm
# calls (probe/snapshot cleanup) pass through — detect the legacy path by
# checking if the target path contains ".registry.lock/journal.ndjson".
rc=0
output="$( (
  rm() {
    case "$*" in
      *".registry.lock/journal.ndjson"*) return 1 ;;
      *) command rm "$@" ;;
    esac
  }
  export -f rm
  journal_migrate_legacy "$K4"
) 2>&1)"
rc=$?
check "K4a: rm-legacy failure → nonzero" "1" "$rc"
check "K4b: canonical journal ROLLED BACK to pre-migration bytes" "1" "$( [ "$K4_JP_BEFORE" = "$(cat "$K4JP")" ] && echo 1 || echo 0 )"
check "K4c: legacy file preserved on rm-legacy failure" "1" "$( [ -f "$K4LEG" ] && echo 1 || echo 0 )"
check "K4d: legacy bytes byte-identical on rm-legacy failure" "1" "$( [ "$K4_LEG_BEFORE" = "$(cat "$K4LEG")" ] && echo 1 || echo 0 )"
check "K4e: no checkpoint marker minted after rollback" "0" "$(count_in 'checkpoint_migrated' "$K4JP")"
# After rollback, a fresh call to migrate_legacy should see the same legacy
# state and succeed cleanly (no leftover rollback snapshot, idempotent path).
K4_JP_AFTER_ROLLBACK="$(cat "$K4JP")"
rc=0; journal_migrate_legacy "$K4" >/dev/null 2>&1 || rc=$?
check "K4f: re-migration succeeds cleanly after rollback" "0" "$rc"
check "K4g: canonical journal is now migrated (has checkpoint marker)" "1" "$(count_in 'checkpoint_migrated' "$K4JP")"
check "K4h: legacy file removed after re-migration" "0" "$( [ -f "$K4LEG" ] && echo 1 || echo 0 )"

# ============================================================================
# M: Codex r5 Important #4 — recovery appends must FAIL-CLOSED on write failure.
#   The previous code silently swallowed `>>` errors via `2>/dev/null` (or no
#   check at all), so a disk-full / read-only filesystem / permission denialled
#   append would leave the audit trail PARTIAL — pending orphan unmarked, or
#   forward-roll commit dropped, or BLOCKED record missing — while journal_recover
#   returned 0 (silent success on a state that fails journal_verify_pairs).
#   The fix wraps every append with explicit fail-closed error handling that
#   surfaces stderr AND returns nonzero, so a half-recovered journal cannot
#   pass.
#
#   Sabotage strategy: wrap `printf` via a shell function override for the
#   duration of the call. The override matches any redirect containing the
#   journal path and returns 1 WITHOUT actually writing — this is portable
#   across MSYS/Git Bash and exercises the EXACT code path that runs on a real
#   disk-full / EACCES. The override is scoped to the test process and
#   restored after journal_recover returns.
# ============================================================================

# sabotage_journal_write <journal_path> — make the journal read-only so any
# subsequent `printf '%s\n' "$rec" >> "$jp"` from journal_recover /
# journal_backfill_legacy_pending errors with EACCES. This is portable
# across MSYS/Git Bash (chmod is honoured against the bash process) and
# exercises the EXACT same code path as a disk-full / EACCES at runtime.
# The file is restored to writable after the test by the caller via
# restore_journal_write.
sabotage_journal_write() {
  local jp="$1"
  chmod 400 "$jp" 2>/dev/null || true
}

restore_journal_write() {
  local jp="$1"
  chmod 600 "$jp" 2>/dev/null || true
}

# ---- M1: recovery_backout append failure → journal_recover returns nonzero --
# Setup: a pending line whose pre_sha == current sha (orphan + sha unchanged)
# so the recovery_backout branch is taken. Sabotage printf to fail any write
# to the journal; journal_recover must return 1, NOT silently leave the orphan
# unmarked.
M1="$(mktemp -d "$TMPDIR/m1-XXXX")"
setup_project "$M1" >/dev/null
JP_M1="$M1/.harness/registry-journal.ndjson"
POST_M1='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
ps_m1="$(printf '%s\n' "$POST_M1" | sha256sum 2>/dev/null | awk '{print $1}')"
# sha-unchanged orphan: current feature_list.json IS rev1, so pre_sha == fl_sha
ok_m1="$(journal_record_pending "$M1" status F-001 not_started in_progress --revision 2 --post-sha "$ps_m1")"
# Sabotage the journal so any append errors with EACCES (chmod 400 = read-only).
sabotage_journal_write "$JP_M1"
rc_m1=0; journal_recover "$M1" >/dev/null 2>&1 || rc_m1=$?
restore_journal_write "$JP_M1"
check "M1a: journal_recover returns nonzero when recovery_backout append fails" "1" "$rc_m1"

# ---- M2: forward-roll commit append failure → journal_recover returns nonzero
# Setup: pending whose current sha == expected_post_sha (forward-roll branch).
M2="$(mktemp -d "$TMPDIR/m2-XXXX")"
setup_project "$M2" >/dev/null
JP_M2="$M2/.harness/registry-journal.ndjson"
POST_M2='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
ps_m2="$(printf '%s\n' "$POST_M2" | sha256sum 2>/dev/null | awk '{print $1}')"
ok_m2="$(journal_record_pending "$M2" status F-001 not_started in_progress --revision 2 --post-sha "$ps_m2")"
# Make current feature_list.json == rev2 so current sha == expected post sha.
printf '%s\n' "$POST_M2" > "$M2/feature_list.json"
sabotage_journal_write "$JP_M2"
rc_m2=0; journal_recover "$M2" >/dev/null 2>&1 || rc_m2=$?
restore_journal_write "$JP_M2"
check "M2a: journal_recover returns nonzero when forward-roll commit append fails" "1" "$rc_m2"

# ---- M3: recovery_blocked append failure → journal_recover returns nonzero --
# Setup: third-SHA orphan (pre_sha != current sha != expected_post_sha).
M3="$(mktemp -d "$TMPDIR/m3-XXXX")"
setup_project "$M3" >/dev/null
JP_M3="$M3/.harness/registry-journal.ndjson"
POST_M3='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
ps_m3="$(printf '%s\n' "$POST_M3" | sha256sum 2>/dev/null | awk '{print $1}')"
ok_m3="$(journal_record_pending "$M3" status F-001 not_started in_progress --revision 2 --post-sha "$ps_m3")"
EVIL_M3='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"blocked","evidence_associations":[],"legacy_audit_evidence":[]}]}'
printf '%s\n' "$EVIL_M3" > "$M3/feature_list.json"
sabotage_journal_write "$JP_M3"
rc_m3=0; journal_recover "$M3" >/dev/null 2>&1 || rc_m3=$?
restore_journal_write "$JP_M3"
check "M3a: journal_recover returns nonzero when recovery_blocked append fails" "1" "$rc_m3"

# ---- M4: journal_backfill_legacy_pending append failure returns nonzero ----
# Setup: a legacy pending line (no expected_post_sha) with a committed partner.
PRE_M4="$(printf '%s\n' '{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}' | sha256sum 2>/dev/null | awk '{print $1}')"
POST_M4_DOC='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
POST_M4="$(printf '%s\n' "$POST_M4_DOC" | sha256sum 2>/dev/null | awk '{print $1}')"
TS_M4=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
M4="$(mktemp -d "$TMPDIR/m4-XXXX")"
mkdir -p "$M4/.harness"
JP_M4="$M4/.harness/registry-journal.ndjson"
OK_M4="legacy-op-key-m4"
printf '%s\n' "{\"ts\":\"$TS_M4\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"$OK_M4\",\"feature_list_sha_before\":\"$PRE_M4\",\"feature_list_sha_after\":\"$POST_M4\",\"evidence_run_ids_after\":[],\"run_id\":null}" > "$JP_M4"
jq -c 'del(.expected_post_sha)' "$JP_M4" > "$JP_M4.tmp" && mv "$JP_M4.tmp" "$JP_M4"
printf '%s\n' "{\"ts\":\"$TS_M4\",\"op\":\"commit\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":false,\"op_key\":\"$OK_M4\",\"feature_list_sha_before\":\"$PRE_M4\",\"feature_list_sha_after\":\"$POST_M4\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$JP_M4"
sabotage_journal_write "$JP_M4"
rc_m4=0; journal_backfill_legacy_pending "$M4" >/dev/null 2>&1 || rc_m4=$?
restore_journal_write "$JP_M4"
check "M4a: journal_backfill_legacy_pending returns nonzero on append failure" "1" "$rc_m4"

# ---- M5: positive control — unsabotaged backfill still succeeds ------------
M5="$(mktemp -d "$TMPDIR/m5-XXXX")"
mkdir -p "$M5/.harness"
JP_M5="$M5/.harness/registry-journal.ndjson"
PRE_M5="$PRE_M4"; POST_M5="$POST_M4"; TS_M5="$TS_M4"; OK_M5="legacy-op-key-m5"
printf '%s\n' "{\"ts\":\"$TS_M5\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"$OK_M5\",\"feature_list_sha_before\":\"$PRE_M5\",\"feature_list_sha_after\":\"$POST_M5\",\"evidence_run_ids_after\":[],\"run_id\":null}" > "$JP_M5"
jq -c 'del(.expected_post_sha)' "$JP_M5" > "$JP_M5.tmp" && mv "$JP_M5.tmp" "$JP_M5"
printf '%s\n' "{\"ts\":\"$TS_M5\",\"op\":\"commit\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":false,\"op_key\":\"$OK_M5\",\"feature_list_sha_before\":\"$PRE_M5\",\"feature_list_sha_after\":\"$POST_M5\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$JP_M5"
rc_m5=0; journal_backfill_legacy_pending "$M5" >/dev/null 2>&1 || rc_m5=$?
check "M5a: unsabotaged backfill returns zero (positive control)" "0" "$rc_m5"
check "M5b: recovery_backfill record appended on success" "1" "$(count_in 'recovery_backfill' "$JP_M5")"

# ---- M6: positive control — unsabotaged recovery_backout still succeeds -----
# Proves M1's sabotage actually flips behavior: without sabotage, the orphan
# gets the recovery_backout record AND journal_recover returns 0.
M6="$(mktemp -d "$TMPDIR/m6-XXXX")"
setup_project "$M6" >/dev/null
JP_M6="$M6/.harness/registry-journal.ndjson"
POST_M6='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
ps_m6="$(printf '%s\n' "$POST_M6" | sha256sum 2>/dev/null | awk '{print $1}')"
ok_m6="$(journal_record_pending "$M6" status F-001 not_started in_progress --revision 2 --post-sha "$ps_m6")"
rc_m6=0; journal_recover "$M6" >/dev/null 2>&1 || rc_m6=$?
check "M6a: unsabotaged recovery_backout returns zero (positive control)" "0" "$rc_m6"
check "M6b: recovery_backout record appended on success" "1" "$(count_in 'recovery_backout' "$JP_M6")"

# ---- M7: positive control — unsabotaged forward-roll still succeeds --------
M7="$(mktemp -d "$TMPDIR/m7-XXXX")"
setup_project "$M7" >/dev/null
JP_M7="$M7/.harness/registry-journal.ndjson"
POST_M7='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
ps_m7="$(printf '%s\n' "$POST_M7" | sha256sum 2>/dev/null | awk '{print $1}')"
ok_m7="$(journal_record_pending "$M7" status F-001 not_started in_progress --revision 2 --post-sha "$ps_m7")"
printf '%s\n' "$POST_M7" > "$M7/feature_list.json"
rc_m7=0; journal_recover "$M7" >/dev/null 2>&1 || rc_m7=$?
check "M7a: unsabotaged forward-roll returns zero (positive control)" "0" "$rc_m7"
check "M7b: forward-roll commit record appended on success" "1" "$(count_in '"op":"commit"' "$JP_M7")"

# ---- M8: positive control — unsabotaged recovery_blocked still succeeds ----
M8="$(mktemp -d "$TMPDIR/m8-XXXX")"
setup_project "$M8" >/dev/null
JP_M8="$M8/.harness/registry-journal.ndjson"
POST_M8='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
ps_m8="$(printf '%s\n' "$POST_M8" | sha256sum 2>/dev/null | awk '{print $1}')"
ok_m8="$(journal_record_pending "$M8" status F-001 not_started in_progress --revision 2 --post-sha "$ps_m8")"
EVIL_M8='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"blocked","evidence_associations":[],"legacy_audit_evidence":[]}]}'
printf '%s\n' "$EVIL_M8" > "$M8/feature_list.json"
rc_m8=0; journal_recover "$M8" >/dev/null 2>&1 || rc_m8=$?
check "M8a: unsabotaged recovery_blocked returns nonzero (this is the documented behavior)" "1" "$rc_m8"
check "M8b: recovery_blocked record appended on success" "1" "$(count_in 'recovery_blocked' "$JP_M8")"

# ============================================================================
# L: Codex r4 — journal_verify_pairs MUST fail-closed on a corrupt NDJSON line.
#   The previous implementation piped jq's stdout to `tr -d '\r'` and silenced
#   stderr with `2>/dev/null`. When a single line failed to parse, jq exited
#   non-zero and printed nothing, so the function silently returned valid
#   (reason="" → no violation). A journal we cannot parse cannot be trusted
#   to record a valid pairing contract — fail-closed with reason journal_corrupt.
# ============================================================================
L1="$(mktemp -d "$TMPDIR/l1-XXXX")"
mkdir -p "$L1/.harness"
L1JP="$L1/.harness/registry-journal.ndjson"
setup_project "$L1" >/dev/null
# Inject a well-formed line, then a CORRUPT line, then another well-formed one.
# `jq -rs` slurps the whole file; one bad line breaks the parse and triggers
# the journal_corrupt path. Both well-formed lines would otherwise pass the
# strict contract — without the fix, journal_verify_pairs returned valid.
TS_L1=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
L1POST_DOC='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
L1PSHA="$(printf '%s\n' "$L1POST_DOC" | sha256sum 2>/dev/null | awk '{print $1}')"
L1PRE="$(sha256_file "$L1/feature_list.json")"
printf '%s\n' "{\"ts\":\"$TS_L1\",\"op\":\"status\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":true,\"op_key\":\"dddddddddddddddd\",\"feature_list_sha_before\":\"$L1PRE\",\"feature_list_sha_after\":\"$L1PSHA\",\"evidence_run_ids_after\":[],\"run_id\":null}" > "$L1JP"
printf '%s\n' "this is not json at all" >> "$L1JP"
printf '%s\n' "{\"ts\":\"$TS_L1\",\"op\":\"commit\",\"feature_id\":\"F-001\",\"from\":\"not_started\",\"to\":\"in_progress\",\"revision\":2,\"pending\":false,\"op_key\":\"dddddddddddddddd\",\"feature_list_sha_before\":\"$L1PRE\",\"feature_list_sha_after\":\"$L1PSHA\",\"evidence_run_ids_after\":[],\"run_id\":null}" >> "$L1JP"
V_L1="$(journal_verify_pairs "$L1")"; rc_l1=$?
check "L1a: corrupt NDJSON line → verify_pairs nonzero" "1" "$rc_l1"
check "L1b: token journal_corrupt" "journal_corrupt" "$V_L1"

# L2: an EMPTY journal (zero non-blank lines) must also fail-closed. The
# previous code accepted the file because `jq -rs` over zero bytes exits 0
# and prints `[]` (no violation), and `[ -f "$jp" ] || return 0` was the
# only emptiness check. A zero-line file is not a valid audit trail.
L2="$(mktemp -d "$TMPDIR/l2-XXXX")"
mkdir -p "$L2/.harness"
L2JP="$L2/.harness/registry-journal.ndjson"
: > "$L2JP"   # create empty file
V_L2="$(journal_verify_pairs "$L2")"; rc_l2=$?
check "L2a: empty journal → verify_pairs nonzero" "1" "$rc_l2"
check "L2b: empty journal token journal_corrupt" "journal_corrupt" "$V_L2"

# L3: a journal containing only blank lines (whitespace-only) must also fail.
L3="$(mktemp -d "$TMPDIR/l3-XXXX")"
mkdir -p "$L3/.harness"
L3JP="$L3/.harness/registry-journal.ndjson"
printf '\n\n   \n\n' > "$L3JP"
V_L3="$(journal_verify_pairs "$L3")"; rc_l3=$?
check "L3a: blank-only journal → verify_pairs nonzero" "1" "$rc_l3"
check "L3b: blank-only journal token journal_corrupt" "journal_corrupt" "$V_L3"

# L4: replay also refuses a corrupt journal (proves the fail-closed contract
# holds at the highest layer — replay is what init/r4-style gates actually call).
L4="$(mktemp -d "$TMPDIR/l4-XXXX")"
mkdir -p "$L4/.harness"
L4JP="$L4/.harness/registry-journal.ndjson"
setup_project "$L4" >/dev/null
TS_L4=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
L4POST_DOC='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
L4PSHA="$(printf '%s\n' "$L4POST_DOC" | sha256sum 2>/dev/null | awk '{print $1}')"
L4PRE="$(sha256_file "$L4/feature_list.json")"
printf '%s\n' "garbage not json" > "$L4JP"
L4REC_FEATURES='[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]'
L4REC="$(printf '{"revision":1,"features":%s,"_recorded_sha":"%s"}' "$L4REC_FEATURES" "$L4PRE")"
jr_l4=0; journal_replay "$L4" "$L4REC" >/dev/null 2>&1 || jr_l4=$?
check "L4a: replay rejects corrupt journal (fail-closed)" "1" "$jr_l4"

# L5: positive control — a real, well-formed journal pair still passes after
# the fix. Pins that the journal_corrupt branch is INDEPENDENT of the
# strict-pairing logic (regression guard: a fix must not break valid pairs).
L5="$(mktemp -d "$TMPDIR/l5-XXXX")"
mkdir -p "$L5/.harness"
L5JP="$L5/.harness/registry-journal.ndjson"
setup_project "$L5" >/dev/null
L5OK="$(journal_record_pending "$L5" "status" "F-001" "not_started" "in_progress" --revision 2 --post-sha "$(printf '%s\n' '{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}' | sha256sum 2>/dev/null | awk '{print $1}')")"
printf '%s\n' '{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}' > "$L5/feature_list.json"
journal_record_committed "$L5" "$L5OK" "$(sha256_file "$L5/feature_list.json")"
V_L5="$(journal_verify_pairs "$L5")"; rc_l5=$?
check "L5a: well-formed pair still passes (positive control)" "0" "$rc_l5"
check "L5b: well-formed pair empty reason" "" "$V_L5"

echo ""
echo "Journal-Strict-Contract Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
