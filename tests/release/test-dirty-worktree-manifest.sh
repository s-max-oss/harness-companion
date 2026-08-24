#!/bin/bash
# test-dirty-worktree-manifest.sh — §15.3 / §5-b.5 dirty-worktree manifest gate
#
# Exercises core/lib/dirty-worktree-manifest.sh (emit + compare) and the
# snapshot tool against throwaway git worktrees:
#
#   Canonical emit     — JSONL, 7 required fields, NO mtime, sorted by parsed
#                        .path, recursive directory enumeration, self-reference
#                        exclusion (manifest file + tool).
#   Byte-equal gate    — unchanged dirty tree is valid; immutable contract
#                        changes and non-Harness user-file changes are
#                        violations (not_byte_equal).
#   Mutable namespace  — NEW run paths (.harness/logs/runs/) and NEW verdict
#                        paths (.harness/reviews/) are allowed; NEW paths
#                        OUTSIDE the mutable namespace are violations
#                        (new_non_mutable).
#   P0-5 content rules — existing run NDJSON must stay byte-equal; reviewer
#                        verdicts may only append (recorded bytes must be a
#                        PREFIX of the current file, not_append_only); a
#                        feature_list.json change is governed by the P0-M2
#                        registry manifest contract (canonical schema of both
#                        snapshots, feature-set consistency, append-only
#                        evidence, revision consistency, and PER-REVISION legal
#                        mutation history proven by the append-only journal —
#                        validate_registry_transition → journal_replay replays
#                        single legal edges, NOT end-point reachability; the
#                        tests seed the journal exactly like the CLI's two-phase
#                        commit); only progress/state files (e.g.
#                        claude-progress.md) may differ freely
#                        (content_changed_mutable). The mutable namespace is NOT
#                        arbitrarily modifiable.
#   Append-only        — removals and type changes always violate.
#
# Local-only gate (never CI): every test builds its own git repo.
# Requires: bash, jq, git, sha256sum.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck source=../../core/lib/dirty-worktree-manifest.sh
source "$ROOT_DIR/core/lib/dirty-worktree-manifest.sh"
# P0-M2: the registry gate is journal-driven — the test suite seeds the
# append-only mutation journal exactly like the CLI's two-phase commit.
# shellcheck source=../../core/lib/registry-journal.sh
source "$ROOT_DIR/core/lib/registry-journal.sh"
# rc6 final: runtime-manifest atomic writes need lock-registry.sh sourced.
# shellcheck source=../../core/lib/lock-registry.sh
source "$ROOT_DIR/core/lib/lock-registry.sh"
# Codex r7 + rc6 final: the runtime-artifact byte-binding registry.
# shellcheck source=../../core/lib/runtime-manifest.sh
source "$ROOT_DIR/core/lib/runtime-manifest.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

check() {
  local name="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name — expected $expected, got $got"
    FAILED=$((FAILED + 1))
  fi
}

# ---- helpers ----

# setup_repo <dir> — git repo on master; commit a base .gitignore, then dirty:
#   tracked-but-modified .gitignore
#   untracked immutable harness: .harness/PLAN.json, .harness/config.json
#   untracked mutable run/verdict: .harness/logs/runs/run-1.ndjson,
#                                  .harness/reviews/feature/F-CONV-01.jsonl
#   untracked mutable registry/progress: feature_list.json (revision 1),
#                                        claude-progress.md
#   untracked non-Harness user file: userfile.txt
setup_repo() {
  local d="$1"
  mkdir -p "$d/.harness/logs/runs" "$d/.harness/reviews/feature" "$d/.harness/reviews/phase"
  git -C "$d" init -q
  printf '# base ignore\n' > "$d/.gitignore"
  git -C "$d" -c user.email=t@e.com -c user.name=t add .gitignore
  git -C "$d" -c user.email=t@e.com -c user.name=t commit -q -m base
  local cur
  cur="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ "$cur" != "master" ]; then
    git -C "$d" branch -m "$cur" master 2>/dev/null || true
  fi
  printf '# modified ignore\n' >> "$d/.gitignore"
  # P0-3: the branch-gate first-add gate requires an authoritative PLAN whose
  # branch_gate.target_branch matches the recorded baseline branch AND the
  # current git branch (the fixture renames its branch to master).
  printf '%s\n' '{"schema_version":1,"branch_gate":{"target_branch":"master"}}' > "$d/.harness/PLAN.json"
  printf '{"cfg":1}\n' > "$d/.harness/config.json"
  printf 'run-1\n' > "$d/.harness/logs/runs/run-1.ndjson"
  printf 'verdict-1\n' > "$d/.harness/reviews/feature/F-CONV-01.jsonl"
  # P0-10: the fixture registry must itself be canonical-schema-valid — the
  # registry manifest contract validates BOTH the recorded snapshot and the
  # current file with the repo's own validator (never a bare JSON parse).
  printf '%s\n' '{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}' > "$d/feature_list.json"
  printf 'progress-v1\n' > "$d/claude-progress.md"
  printf 'user-data\n' > "$d/userfile.txt"
}

# set_registry <dir> <json> — overwrite feature_list.json with a canonical registry
set_registry() { printf '%s\n' "$2" > "$1/feature_list.json"; }

# seed_journal_pending <dir> <op> <fid> <from> <to> <rev> <after_json>
#   Append a journal PENDING line mirroring the CLI's two-phase commit
#   (harness-feature.sh / harness-verify.sh --write): the current
#   feature_list.json on disk is the mutation's BEFORE state (sha_before is
#   recorded by journal_record_pending), then write the AFTER registry via
#   set_registry. P0-1: every pending MUST bind its expected_post_sha to the
#   exact after-state bytes — a pending without expected_post_sha is a contract
#   violation that strict replay rejects, so no mutation here may be seeded
#   unbound. Echoes the op_key for the paired seed_journal_commit call.
seed_journal_pending() {
  local d="$1" op="$2" fid="$3" from="$4" to="$5" rev="$6" after="$7"
  local ps
  ps="$(printf '%s\n' "$after" | sha256sum 2>/dev/null | awk '{print $1}')"
  journal_record_pending "$d" "$op" "$fid" "$from" "$to" --revision "$rev" --post-sha "$ps"
  set_registry "$d" "$after"
}

# seed_journal_commit <dir> <op_key>
#   The AFTER registry has already been written (by seed_journal_pending) —
#   record the COMMITTED line with the new feature_list.json sha.
seed_journal_commit() {
  journal_record_committed "$1" "$2" "$(sha256_file "$1/feature_list.json")"
}

# ---- Canonical AFTER-state registries (P0-1 post-sha binding) -----------------
# Each journaled mutation binds its expected_post_sha to the exact bytes of the
# AFTER registry it writes, so the strict replay can PROVE the mutation. These
# constants are the single source for both the bound post-sha and the on-disk
# write (a drift between the two would break the sha chain, not hide it).
A_R1_IP='{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
A_R2_IP='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
A_R2_IP_EV1='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[{"run_id":"r-1"}],"legacy_audit_evidence":[]}]}'
A_R2_IP_EV2='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[{"run_id":"r-1"},{"run_id":"r-2"}],"legacy_audit_evidence":[]}]}'
A_R2_PASS_EV1='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"passing","evidence_associations":[{"run_id":"r-1"}],"legacy_audit_evidence":[]}]}'
A_R3_PASS_EV1='{"revision":3,"schema_version":"2.0.0","features":[{"id":"F-001","status":"passing","evidence_associations":[{"run_id":"r-1"}],"legacy_audit_evidence":[]}]}'
A_R3_IP_EV1='{"revision":3,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[{"run_id":"r-1"}],"legacy_audit_evidence":[]}]}'
A_R4_PASS_EV1='{"revision":4,"schema_version":"2.0.0","features":[{"id":"F-001","status":"passing","evidence_associations":[{"run_id":"r-1"}],"legacy_audit_evidence":[]}]}'
A_R2_NS_EV9='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[{"run_id":"r-9"}],"legacy_audit_evidence":[]}]}'
A_R2_F2_NS='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"F-002","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}'
A_R2_F2_IP='{"revision":2,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"F-002","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
A_R3_F2_IP='{"revision":3,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]},{"id":"F-002","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
A_R3_NS='{"revision":3,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}'
A_R3_BLK='{"revision":3,"schema_version":"2.0.0","features":[{"id":"F-001","status":"blocked","evidence_associations":[],"legacy_audit_evidence":[]}]}'

# reemit <dir> <out> — re-emit a fresh recorded manifest (new baseline)
reemit() { dwm_emit_manifest "$1" "$2"; }

# mf <dir> <suffix> — path for a manifest OUTSIDE the repo tree
mf() { printf '%s.%s.manifest.jsonl' "$1" "$2"; }

# emit + compare, print the compare JSON
cmp_json() {
  local d="$1" out="$2"
  dwm_emit_manifest "$d" "$out" || { echo '{emit_failed:true}'; return 1; }
  dwm_compare_manifest "$d" "$out"
}

# ---- T1: canonical emit format ----------------------------------------------
D="$(mktemp -d "$TMPDIR/t1-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t1)"
dwm_emit_manifest "$D" "$OUT" || check "T1: emit succeeds" 0 1
# every line is a valid JSON object with exactly the 7 canonical fields
# (feature_list.json records carry `revision` + `registry` — P0-5/P0-10
# registry manifest gate), and never an mtime.
LINES="$(grep -vc '^$' "$OUT")"
BAD_FIELDS="$(jq -r 'select(((keys | sort) != ["git_status","mode","path","sha256","size","symlink_target","type"]) and ((keys | sort) != ["git_status","mode","path","registry","revision","sha256","size","symlink_target","type"])) | "bad:" + .path' "$OUT" 2>/dev/null | head -5)"
check "T1a: every record has the 7 canonical fields (+revision/registry for feature_list.json)" "" "$BAD_FIELDS"
check "T1b: no mtime field" 0 "$(grep -c 'mtime' "$OUT" || true)"
# feature_list.json records carry the registry revision as a JSON number
FL_REV="$(jq -r 'select(.path == "feature_list.json") | .revision // "missing"' "$OUT")"
check "T1i: feature_list.json record carries revision" "1" "$FL_REV"
# sorted by parsed .path
UNSORTED="$(jq -r '.path' "$OUT" | LC_ALL=C sort -c 2>&1 || echo unsorted)"
check "T1c: records sorted by parsed path" "" "$( [ -z "$UNSORTED" ] && echo "" || echo unsorted )"
# file records have sha256 (64 hex) + integer size
BAD_SHA="$(jq -r 'select(.type == "file") | select((.sha256 | type) != "string" or (.sha256 | length) != 64) | .path' "$OUT" | head -3)"
check "T1d: file records carry 64-hex sha256" "" "$BAD_SHA"
# recursive directories: .harness/logs/runs/run-1.ndjson has .harness, .harness/logs,
# .harness/logs/runs ancestors as directory records
HAS_ANC="$(jq -r 'select(.type == "directory") | .path' "$OUT" | grep -c '^\.harness$')"
check "T1e: .harness directory record present (recursive)" 1 "$HAS_ANC"
HAS_RUNS="$(jq -r 'select(.type == "directory") | .path' "$OUT" | grep -c '^\.harness/logs/runs$')"
check "T1f: .harness/logs/runs directory record present" 1 "$HAS_RUNS"
HAS_RUN="$(jq -r 'select(.type == "file") | .path' "$OUT" | grep -c '^\.harness/logs/runs/run-1\.ndjson$')"
check "T1g: run file enumerated" 1 "$HAS_RUN"
HAS_GITIGNORE="$(jq -r 'select(.path == ".gitignore") | .git_status' "$OUT")"
check "T1h: tracked-but-modified .gitignore carries ' M'" " M" "$HAS_GITIGNORE"

# ---- T2: self-reference exclusion -------------------------------------------
# Manifest + tool placed INSIDE the repo must not enumerate themselves.
D="$(mktemp -d "$TMPDIR/t2-XXXX")"
setup_repo "$D"
mkdir -p "$D/tests/fixtures" "$D/tools"
printf '#!/bin/bash\n' > "$D/tools/snapshot-dirty-worktree.sh"
# recorded fixture lives in-repo at the canonical path
dwm_emit_manifest "$D" "$D/tests/fixtures/dirty-worktree-manifest.jsonl" \
  "tests/fixtures/dirty-worktree-manifest.jsonl" "tools/snapshot-dirty-worktree.sh" \
  || check "T2: emit in-repo succeeds" 0 1
FIX="$(jq -r '.path' "$D/tests/fixtures/dirty-worktree-manifest.jsonl" | grep -c 'dirty-worktree-manifest.jsonl' || true)"
check "T2a: manifest never tracks itself" 0 "$FIX"
TOOL="$(jq -r '.path' "$D/tests/fixtures/dirty-worktree-manifest.jsonl" | grep -c 'tools/snapshot-dirty-worktree.sh' || true)"
check "T2b: snapshot tool excluded" 0 "$TOOL"
# and the gate on that in-repo fixture is VALID (nothing outside mutable namespace new)
RES="$(dwm_compare_manifest "$D" "$D/tests/fixtures/dirty-worktree-manifest.jsonl" \
  "tests/fixtures/dirty-worktree-manifest.jsonl" "tools/snapshot-dirty-worktree.sh")"
check "T2c: in-repo recorded manifest gate valid" true "$(printf '%s' "$RES" | jq -r '.valid')"

# ---- T3: unchanged dirty tree → byte-equal, valid ---------------------------
D="$(mktemp -d "$TMPDIR/t3-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t3)"
RES="$(cmp_json "$D" "$OUT")"
check "T3a: unchanged dirty tree valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T3b: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"
check "T3c: no allowed_new" 0 "$(printf '%s' "$RES" | jq '.allowed_new | length')"

# ---- T4: immutable contract change → invalid (not_byte_equal) ---------------
D="$(mktemp -d "$TMPDIR/t4-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t4)"
dwm_emit_manifest "$D" "$OUT"
printf '{"cfg":2}\n' > "$D/.harness/config.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T4a: immutable .harness/config.json change invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T4b: reason not_byte_equal" "not_byte_equal" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"
check "T4c: path is config.json" ".harness/config.json" "$(printf '%s' "$RES" | jq -r '.violations[0].path')"

# ---- T5: non-Harness user dirty file change → invalid -----------------------
D="$(mktemp -d "$TMPDIR/t5-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t5)"
dwm_emit_manifest "$D" "$OUT"
printf 'user-data-CHANGED\n' > "$D/userfile.txt"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T5a: user file change invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T5b: reason not_byte_equal" "not_byte_equal" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"
check "T5c: path is userfile.txt" "userfile.txt" "$(printf '%s' "$RES" | jq -r '.violations[0].path')"

# ---- T6: NEW run path in mutable namespace → valid --------------------------
D="$(mktemp -d "$TMPDIR/t6-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t6)"
dwm_emit_manifest "$D" "$OUT"
printf 'run-2\n' > "$D/.harness/logs/runs/run-2.ndjson"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T6a: new run path allowed" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T6b: run path in allowed_new" "1" "$(printf '%s' "$RES" | jq '[.allowed_new[] | select(contains(".harness/logs/runs/run-2.ndjson"))] | length')"
check "T6c: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# ---- T7: NEW verdict path in mutable namespace → valid ----------------------
D="$(mktemp -d "$TMPDIR/t7-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t7)"
dwm_emit_manifest "$D" "$OUT"
printf 'verdict-2\n' > "$D/.harness/reviews/feature/F-CONV-02.jsonl"
printf 'phase-verdict\n' > "$D/.harness/reviews/phase/1.jsonl"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T7a: new verdict paths allowed" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T7b: feature verdict in allowed_new" "1" "$(printf '%s' "$RES" | jq '[.allowed_new[] | select(contains("F-CONV-02.jsonl"))] | length')"
check "T7c: phase verdict in allowed_new" "1" "$(printf '%s' "$RES" | jq '[.allowed_new[] | select(contains("reviews/phase/1.jsonl"))] | length')"
check "T7d: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# ---- T8: NEW non-mutable path → invalid (new_non_mutable) -------------------
D="$(mktemp -d "$TMPDIR/t8-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t8)"
dwm_emit_manifest "$D" "$OUT"
printf 'new\n' > "$D/newfile.txt"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T8a: new non-mutable path invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T8b: newfile.txt in new_non_mutable" "1" "$(printf '%s' "$RES" | jq '[.new_non_mutable[] | select(. == "newfile.txt")] | length')"

# ---- T9: existing run NDJSON REWRITE → invalid (P0-5 byte-equal) -------------
# A run is ONE file, never re-written: rewriting run-1.ndjson violates even
# though it lives inside the mutable .harness/logs/runs/ namespace.
D="$(mktemp -d "$TMPDIR/t9-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t9)"
dwm_emit_manifest "$D" "$OUT"
printf 'run-1-REWRITTEN\n' > "$D/.harness/logs/runs/run-1.ndjson"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T9a: run NDJSON rewrite invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T9b: reason not_byte_equal" "not_byte_equal" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"
check "T9c: path is run-1.ndjson" ".harness/logs/runs/run-1.ndjson" "$(printf '%s' "$RES" | jq -r '.violations[0].path')"

# ---- T10: recorded path REMOVED → invalid (removed) -------------------------
D="$(mktemp -d "$TMPDIR/t10-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t10)"
dwm_emit_manifest "$D" "$OUT"
rm "$D/.harness/PLAN.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T10a: removal invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T10b: reason removed" "removed" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"

# ---- T11: type change (file → directory) → invalid (type_changed) -----------
D="$(mktemp -d "$TMPDIR/t11-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t11)"
dwm_emit_manifest "$D" "$OUT"
rm "$D/userfile.txt" && mkdir "$D/userfile.txt" && printf 'x\n' > "$D/userfile.txt/inner"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T11a: type change invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T11b: reason type_changed" "type_changed" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"

# ---- T12: git model — empty untracked dirs are invisible, nested dirs recursive ----
# git does NOT track directories, so `git status --porcelain=v1 --untracked-files=all`
# never reports an EMPTY untracked directory — the manifest enumerates exactly the
# git-visible set (files + symlinks; non-empty dirs get recursive directory records).
# An empty dir must therefore NOT appear (matching git), and a nested NON-empty
# untracked dir must get BOTH its directory record and every child.
D="$(mktemp -d "$TMPDIR/t12-XXXX")"
setup_repo "$D"
mkdir "$D/.harness/logs/runs/empty-dir"
mkdir -p "$D/.harness/logs/runs/nested-dir/deep"
printf 'a\n' > "$D/.harness/logs/runs/nested-dir/deep/file.txt"
OUT="$(mf "$D" t12)"
dwm_emit_manifest "$D" "$OUT"
HAS_EMPTY="$(jq -r 'select(.path == ".harness/logs/runs/empty-dir") | .type' "$OUT")"
check "T12a: empty untracked dir NOT enumerated (invisible to git)" "" "$HAS_EMPTY"
HAS_NESTED_DIR="$(jq -r 'select(.path == ".harness/logs/runs/nested-dir") | .type' "$OUT")"
check "T12b: nested non-empty dir gets directory record" "directory" "$HAS_NESTED_DIR"
HAS_DEEP="$(jq -r 'select(.path == ".harness/logs/runs/nested-dir/deep") | .type' "$OUT")"
check "T12c: nested subdir recursed" "directory" "$HAS_DEEP"
HAS_DEEP_FILE="$(jq -r 'select(.path == ".harness/logs/runs/nested-dir/deep/file.txt") | .type' "$OUT")"
check "T12d: deep child file recursed" "file" "$HAS_DEEP_FILE"

# ---- T13: snapshot tool end-to-end (snapshot + check + error paths) ---------
# snapshot into an out-of-tree path via the tool (project_dir = temp repo),
# then check → valid. Also verify the tool's error exit codes.
D="$(mktemp -d "$TMPDIR/t13-XXXX")"
setup_repo "$D"
TOOL_PATH="$ROOT_DIR/tools/snapshot-dirty-worktree.sh"
OUT13="$(mf "$D" t13)"
bash "$TOOL_PATH" snapshot "$OUT13" "$D" >/dev/null 2>&1
check "T13a: tool snapshot rc 0" 0 "$?"
check "T13b: snapshot produced a manifest" 1 "$([ -s "$OUT13" ] && echo 1 || echo 0)"
RES="$(bash "$TOOL_PATH" check "$OUT13" "$D" 2>/dev/null)"
check "T13c: tool check valid after snapshot" true "$(printf '%s' "$RES" | jq -r '.valid')"
# unknown command → exit 2
bash "$TOOL_PATH" bogus >/dev/null 2>&1
check "T13d: unknown command exits 2" 2 "$?"
# non-git dir → snapshot exits 2 (tool error, not invalid)
NOTGIT="$(mktemp -d "$TMPDIR/t13ng-XXXX")"
bash "$TOOL_PATH" snapshot "$(mf "$NOTGIT" ng)" "$NOTGIT" >/dev/null 2>&1
check "T13e: snapshot on non-git dir exits 2" 2 "$?"

# ---- T14: verdict APPEND → valid (recorded bytes are a PREFIX) ---------------
D="$(mktemp -d "$TMPDIR/t14-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t14)"
dwm_emit_manifest "$D" "$OUT"
printf 'verdict-1-APPENDED\n' >> "$D/.harness/reviews/feature/F-CONV-01.jsonl"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T14a: verdict append valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T14b: F-CONV-01.jsonl in appended_mutable" "1" "$(printf '%s' "$RES" | jq '[.appended_mutable[] | select(contains("F-CONV-01.jsonl"))] | length')"
check "T14c: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# ---- T15: verdict REWRITE → invalid (not_append_only) ------------------------
D="$(mktemp -d "$TMPDIR/t15-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t15)"
dwm_emit_manifest "$D" "$OUT"
printf 'VERDICT-REWRITTEN\n' > "$D/.harness/reviews/feature/F-CONV-01.jsonl"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T15a: verdict rewrite invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T15b: reason not_append_only" "not_append_only" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"
check "T15c: path is F-CONV-01.jsonl" ".harness/reviews/feature/F-CONV-01.jsonl" "$(printf '%s' "$RES" | jq -r '.violations[0].path')"

# ---- T16: feature_list.json LEGAL mutation → valid (P0-M2 journal-driven) -----
# A single legal mutation (not_started → in_progress, revision +1), PROVEN by a
# journal entry whose sha_before anchors the recorded snapshot and whose
# single edge is legal.
D="$(mktemp -d "$TMPDIR/t16-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t16)"
dwm_emit_manifest "$D" "$OUT"
OK="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "2" "$A_R2_IP")"
seed_journal_commit "$D" "$OK"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T16a: single legal mutation (rev+1) valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T16b: feature_list.json in feature_revision_advanced" "1" "$(printf '%s' "$RES" | jq '[.feature_revision_advanced[] | select(. == "feature_list.json")] | length')"
check "T16c: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# A Phase may apply MULTIPLE legal mutations between two manifest snapshots.
# not_started → passing over revision +3 is accepted ONLY when the journal proves
# every PER-REVISION step: not_started→in_progress (status, rev+1), r-1 appended
# (evidence_associate, rev+1), then in_progress→passing (status, rev+1) —
# per-revision auditability, NOT a transitive jump. Two components of the strict
# contract make the evidence step MANDATORY: (a) P0-2 exact binding — the final
# passing state carries evidence r-1, which replay can only attribute if a
# journaled evidence_associate op proves it (else evidence_run_id_mismatch);
# (b) canonical schema — passing REQUIRES non-empty evidence_associations
# (validate-feature-registry.sh), so an evidence-free passing after-state is not
# schema-valid at all. Each after-state must be exactly what the journaled ops
# prove.
D="$(mktemp -d "$TMPDIR/t16m-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t16m)"
dwm_emit_manifest "$D" "$OUT"
OK1="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "2" "$A_R2_IP")"
seed_journal_commit "$D" "$OK1"
OK2="$(journal_record_pending "$D" "evidence_associate" "F-001" "" "" --run-id "r-1" --revision "3" --post-sha "$(printf '%s\n' "$A_R3_IP_EV1" | sha256sum 2>/dev/null | awk '{print $1}')")"
set_registry "$D" "$A_R3_IP_EV1"
seed_journal_commit "$D" "$OK2"
OK3="$(seed_journal_pending "$D" "status" "F-001" "in_progress" "passing" "4" "$A_R4_PASS_EV1")"
seed_journal_commit "$D" "$OK3"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T16d: legal multi-mutation not_started→passing rev+3 valid (per-revision journal)" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T16e: multi-mutation no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# ---- T16n: MANDATED negative — not_started rev1 → passing rev2 must FAIL -------
# A SINGLE journaled step from not_started directly to passing is NOT a legal
# single edge (no in_progress in between). The per-revision replay must reject
# it with illegal_status_transition — end-point reachability is explicitly NOT
# sufficient (P0-M2 mandate: "not_started rev1 → passing rev2 必须失败").
D="$(mktemp -d "$TMPDIR/t16n-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t16n)"
dwm_emit_manifest "$D" "$OUT"
OK="$(seed_journal_pending "$D" "status" "F-001" "not_started" "passing" "2" "$A_R2_PASS_EV1")"
# The current registry must be SCHEMA-VALID (passing requires evidence) so the
# replay reaches the state-machine check instead of failing earlier on schema.
seed_journal_commit "$D" "$OK"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T16f: not_started rev1 → passing rev2 single jump invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T16g: reason illegal_registry_transition" "illegal_registry_transition" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"
check "T16h: detail illegal_status_transition" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("illegal_status_transition") | if . then 1 else 0 end')"

# ---- T17: content change WITHOUT revision advance → invalid (P0-M2) ----------
# The journaled edge is legal and replays cleanly, but the revision did NOT
# advance with the content change → revision_consistency violation.
D="$(mktemp -d "$TMPDIR/t17-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t17)"
dwm_emit_manifest "$D" "$OUT"
OK="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "1" "$A_R1_IP")"
seed_journal_commit "$D" "$OK"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T17a: content change w/o rev advance invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T17b: reason illegal_registry_transition" "illegal_registry_transition" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"
check "T17c: detail revision_consistency" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("revision_consistency") | if . then 1 else 0 end')"

# ---- T18: revision JUMP with IDENTICAL content → invalid (fabrication) --------
D="$(mktemp -d "$TMPDIR/t18-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t18)"
dwm_emit_manifest "$D" "$OUT"
set_registry "$D" '{"revision":101,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}'
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T18a: rev jump same content invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T18b: reason illegal_registry_transition" "illegal_registry_transition" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"
check "T18c: detail revision_consistency" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("revision_consistency") | if . then 1 else 0 end')"

# ---- T20: ILLEGAL status transition → invalid (P0-M2) ------------------------
# Establish a recorded baseline where F-001 is in_progress (via a journaled
# legal edge), then attempt in_progress → not_started — journaled so the
# per-revision replay must REJECT the illegal single edge.
D="$(mktemp -d "$TMPDIR/t20-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t20)"
dwm_emit_manifest "$D" "$OUT"
OK1="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "2" "$A_R2_IP")"
seed_journal_commit "$D" "$OK1"
reemit "$D" "$OUT"
OK2="$(seed_journal_pending "$D" "status" "F-001" "in_progress" "not_started" "3" "$A_R3_NS")"
seed_journal_commit "$D" "$OK2"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T20a: illegal in_progress→not_started invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T20b: reason illegal_registry_transition" "illegal_registry_transition" "$(printf '%s' "$RES" | jq -r '.violations[0].reason')"
check "T20c: detail illegal_status_transition" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("illegal_status_transition") | if . then 1 else 0 end')"

# ---- T21: evidence REMOVED → invalid (append-only) ---------------------------
# Baseline (rev2 in_progress with evidence) is journaled legally; the rev3
# change drops evidence with NO journal entry — caught by the shape append-only
# rule (evidence_not_append_only).
D="$(mktemp -d "$TMPDIR/t21-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t21)"
dwm_emit_manifest "$D" "$OUT"
OK1="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "2" "$A_R2_IP_EV1")"
seed_journal_commit "$D" "$OK1"
reemit "$D" "$OUT"
set_registry "$D" '{"revision":3,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}]}'
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T21a: evidence removal invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T21b: detail evidence_not_append_only" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("evidence_not_append_only") | if . then 1 else 0 end')"

# ---- T22: feature REMOVED → invalid (append-only) ----------------------------
# Baseline (rev2 F-001 + F-002, F-002 added legally via the journal) is the
# recorded snapshot; the rev3 change removes F-002 with NO journal entry —
# caught by the shape rule (feature_removed) and by the replay final-state
# mismatch.
D="$(mktemp -d "$TMPDIR/t22-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t22)"
dwm_emit_manifest "$D" "$OUT"
OK1="$(seed_journal_pending "$D" "add" "F-002" "" "not_started" "2" "$A_R2_F2_NS")"
seed_journal_commit "$D" "$OK1"
reemit "$D" "$OUT"
set_registry "$D" '{"revision":3,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}'
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T22a: feature removal invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T22b: detail feature_removed" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("feature_removed") | if . then 1 else 0 end')"

# ---- T23: NEW feature added at in_progress → invalid -------------------------
# The journal records the add op's intent (to=in_progress); the journal replay
# rejects it with add_not_not_started. (Contract 5 removed the redundant static
# new_feature_not_not_started rule — the replay now proves the chain, so a
# feature added directly at a non-not_started status is caught here instead.)
D="$(mktemp -d "$TMPDIR/t23-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t23)"
dwm_emit_manifest "$D" "$OUT"
OK="$(seed_journal_pending "$D" "add" "F-002" "" "in_progress" "2" "$A_R2_F2_IP")"
seed_journal_commit "$D" "$OK"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T23a: new feature added at in_progress invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T23b: detail journal_add_not_not_started" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("add_not_not_started") | if . then 1 else 0 end')"

# ---- T24: NEW feature starting not_started → valid ---------------------------
# The add op is journaled (to=not_started, rev+1); replay + shape both pass.
D="$(mktemp -d "$TMPDIR/t24-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t24)"
dwm_emit_manifest "$D" "$OUT"
OK="$(seed_journal_pending "$D" "add" "F-002" "" "not_started" "2" "$A_R2_F2_NS")"
seed_journal_commit "$D" "$OK"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T24a: new feature not_started valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T24b: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# ---- T25: evidence REORDERED → invalid (append-only prefix) ------------------
# Baseline (rev2 in_progress with evidence [r-1, r-2]) is journaled legally; the
# rev3 change reorders evidence — caught by the shape append-only prefix rule.
D="$(mktemp -d "$TMPDIR/t25-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t25)"
dwm_emit_manifest "$D" "$OUT"
OK1="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "2" "$A_R2_IP_EV2")"
seed_journal_commit "$D" "$OK1"
reemit "$D" "$OUT"
set_registry "$D" '{"revision":3,"schema_version":"2.0.0","features":[{"id":"F-001","status":"in_progress","evidence_associations":[{"run_id":"r-2"},{"run_id":"r-1"}],"legacy_audit_evidence":[]}]}'
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T25a: evidence reorder invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T25b: detail evidence_not_append_only" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("evidence_not_append_only") | if . then 1 else 0 end')"

# ---- T26: evidence REMOVAL bundled with a legal journaled mutation → invalid --
# Reviewer Critical #1 regression: the SHAPE violations must feed `valid`. A
# legal status edge (in_progress→blocked) is journaled, but the SAME file write
# drops the evidence associations. The content-addressed sha chain replays
# cleanly — only the shape append-only rule can catch it. Without the fix the
# gate returned valid=true and silently dropped the evidence removal.
D="$(mktemp -d "$TMPDIR/t26-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t26)"
dwm_emit_manifest "$D" "$OUT"
OK1="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "2" "$A_R2_IP_EV1")"
seed_journal_commit "$D" "$OK1"
reemit "$D" "$OUT"
OK2="$(seed_journal_pending "$D" "status" "F-001" "in_progress" "blocked" "3" "$A_R3_BLK")"
seed_journal_commit "$D" "$OK2"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T26a: evidence removal bundled with legal mutation invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T26b: detail evidence_not_append_only" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("evidence_not_append_only") | if . then 1 else 0 end')"

# ---- T27: TAMPERED journal (non-append-only) caught even when NOT the last
# changed path → invalid (Reviewer Critical #2 CRLF regression: multi-path
# changes must still route the journal into its append-only arm).
D="$(mktemp -d "$TMPDIR/t27-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t27)"
dwm_emit_manifest "$D" "$OUT"
OK="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "2" "$A_R2_IP")"
seed_journal_commit "$D" "$OK"
reemit "$D" "$OUT"
# Tamper: rewrite the journal in-place (drop the first line) — non-append-only.
jt="$(mktemp)"
tail -n +2 "$D/.harness/registry-journal.ndjson" > "$jt" && mv "$jt" "$D/.harness/registry-journal.ndjson"
printf 'progress\n' > "$D/claude-progress.md"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T27a: tampered journal invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T27b: reason not_append_only" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.reason == "not_append_only")] | length')"

# ---- T28: journaled mutation claims WRONG revision → invalid (revision_mismatch)
# Reviewer Minor #3: per-revision auditability — a mutation whose journaled
# revision does not match recorded_revision + ordinal cannot have produced the
# recorded→current transition, even with a contiguous sha chain.
D="$(mktemp -d "$TMPDIR/t28-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t28)"
dwm_emit_manifest "$D" "$OUT"
OK1="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "2" "$A_R2_IP")"
seed_journal_commit "$D" "$OK1"
reemit "$D" "$OUT"
OK2="$(seed_journal_pending "$D" "status" "F-001" "in_progress" "blocked" "5" "$A_R3_BLK")"
seed_journal_commit "$D" "$OK2"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T28a: wrong journal revision invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T28b: detail revision_mismatch" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("revision_mismatch") | if . then 1 else 0 end')"

# ---- T29: branch-gate FIRST APPEARANCE is allowed (P0-M3) --------------------
# .harness/branch-gate.json is in DWM_MUTABLE → a NEW appearance is allowed_new
# (first-add allowed), not a violation.
D="$(mktemp -d "$TMPDIR/t29-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t29)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T29a: branch-gate first appearance valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T29b: branch-gate in allowed_new" "1" "$(printf '%s' "$RES" | jq -r '[.allowed_new[] | select(. == ".harness/branch-gate.json")] | length')"

# ---- T30: branch-gate REWRITE of the recorded baseline → must fail (P0-M3) ---
D="$(mktemp -d "$TMPDIR/t30-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t30)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
reemit "$D" "$OUT"
# Rewrite the baseline with different bytes (e.g. base_sha tampered).
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"0000000000000000000000000000000000000000\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T30a: branch-gate rewrite invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T30b: reason not_byte_equal" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "not_byte_equal")] | length')"

# ---- T31: branch-gate rewrite as an INTERMEDIATE changed line → must fail ----
# Reviewer Minor #1: pins the CRLF/multi-path interaction. With a concurrent
# change to claude-progress.md (sorts AFTER branch-gate), branch-gate.json is an
# intermediate changed line — if the `tr -d '\r'` strip regressed, the exact-match
# arm would silently never fire and the rewrite would be (wrongly) accepted.
D="$(mktemp -d "$TMPDIR/t31-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t31)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
reemit "$D" "$OUT"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"0000000000000000000000000000000000000000\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
printf 'progress\n' > "$D/claude-progress.md"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T31a: branch-gate rewrite (intermediate line) invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T31b: exactly one not_byte_equal for branch-gate" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "not_byte_equal")] | length')"

# ---- T32 (Contract 1 negative): mutation with NULL revision → replay fails ----
# Even a content-addressed contiguous chain must be rejected when a journal line
# carries revision:null — a null revision can never be the provable +1
# continuation (contract: mutation revision must be a non-null integer).
D="$(mktemp -d "$TMPDIR/t32-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t32)"
dwm_emit_manifest "$D" "$OUT"
OK="$(seed_journal_pending "$D" "status" "F-001" "not_started" "in_progress" "null" "$A_R2_IP")"
seed_journal_commit "$D" "$OK"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T32a: null mutation revision invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T32b: detail pending_no_revision" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("pending_no_revision") | if . then 1 else 0 end')"

# ---- T33 (Contract 2 negative): evidence_associate run_id does NOT match the ----
# ---- actually-appended association → replay fails ---------------------------
# The journal claims run r-WRONG but the appended association is r-9. F-001's
# status stays not_started (the recorded snapshot's status) so the ONLY diff is
# the evidence — the replay's evidence binding (recorded + journal-appended must
# prefix current) must reject it with evidence_run_id_mismatch.
D="$(mktemp -d "$TMPDIR/t33-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t33)"
dwm_emit_manifest "$D" "$OUT"
OK="$(journal_record_pending "$D" "evidence_associate" "F-001" "" "" --run-id "r-WRONG" --revision "2" --post-sha "$(printf '%s\n' "$A_R2_NS_EV9" | sha256sum 2>/dev/null | awk '{print $1}')")"
set_registry "$D" "$A_R2_NS_EV9"
seed_journal_commit "$D" "$OK"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T33a: journal run_id != appended association invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T33b: detail evidence_run_id_mismatch" "1" "$(printf '%s' "$RES" | jq -r '.violations[0].detail | test("evidence_run_id_mismatch") | if . then 1 else 0 end')"

# ---- T34 (Contract 4 negative): FIRST-ADD branch-gate.json that is not JSON ----
# A brand-new branch-gate.json may NOT enter through the mutable-namespace hole:
# not-json must FAIL (invalid_branch_gate/not_json), not be allowed_new.
D="$(mktemp -d "$TMPDIR/t34-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t34)"
dwm_emit_manifest "$D" "$OUT"
printf 'this is not json at all\n' > "$D/.harness/branch-gate.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T34a: first-add branch-gate not-json invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T34b: branch-gate NOT in allowed_new" 0 "$(printf '%s' "$RES" | jq '[.allowed_new[] | select(. == ".harness/branch-gate.json")] | length')"
check "T34c: violation invalid_branch_gate detail not_json" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("not_json")))] | length')"

# ---- T34d (Contract 4 negative): FIRST-ADD branch-gate as a DIRECTORY --------
# A directory at the branch-gate path is tampering, not a state file: it must
# NOT bypass first-add validation as "no file" — it must fail (not_json).
D="$(mktemp -d "$TMPDIR/t34d-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t34d)"
dwm_emit_manifest "$D" "$OUT"
mkdir -p "$D/.harness/branch-gate.json"
printf 'tampered\n' > "$D/.harness/branch-gate.json/nested.txt"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T34d: first-add branch-gate as directory invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T34e: branch-gate directory NOT in allowed_new" 0 "$(printf '%s' "$RES" | jq '[.allowed_new[] | select(. == ".harness/branch-gate.json")] | length')"
check "T34f: violation invalid_branch_gate detail not_json" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("not_json")))] | length')"

# ---- T35 (Contract 4 negative): FIRST-ADD branch-gate with a FABRICATED git ----
# ---- OID → must fail (not_real_oid) -----------------------------------------
D="$(mktemp -d "$TMPDIR/t35-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t35)"
dwm_emit_manifest "$D" "$OUT"
printf '%s' '{"schema_version":1,"branch_base_sha":"1111111111111111111111111111111111111111","branch_name":"master"}' > "$D/.harness/branch-gate.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T35a: first-add branch-gate fabricated OID invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T35b: violation invalid_branch_gate detail not_real_oid" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and (.detail | test("not_real_oid")))] | length')"

# ---- T36 (Contract 5 positive): EARLY snapshot → add at not_started → legal ----
# ---- transition to a NON-not_started final state must be VALID ---------------
# The recorded snapshot PREDATES F-002; the journal proves add(not_started) →
# status(in_progress). The final state is proven by full journal replay. The old
# static new_feature_not_not_started rule FALSELY rejected this legal lifecycle
# (previously forced the fixture to be re-shot at rev5).
D="$(mktemp -d "$TMPDIR/t36-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t36)"
dwm_emit_manifest "$D" "$OUT"
OK1="$(seed_journal_pending "$D" "add" "F-002" "" "not_started" "2" "$A_R2_F2_NS")"
seed_journal_commit "$D" "$OK1"
OK2="$(seed_journal_pending "$D" "status" "F-002" "not_started" "in_progress" "3" "$A_R3_F2_IP")"
seed_journal_commit "$D" "$OK2"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T36a: early-snapshot add→in_progress legal chain valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T36b: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# ---- T19: claude-progress.md content change → valid (state file) -------------
D="$(mktemp -d "$TMPDIR/t19-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t19)"
dwm_emit_manifest "$D" "$OUT"
printf 'progress-v2\n' > "$D/claude-progress.md"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T19a: progress change valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T19b: claude-progress.md in content_changed_mutable" "1" "$(printf '%s' "$RES" | jq '[.content_changed_mutable[] | select(. == "claude-progress.md")] | length')"
check "T19c: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# ----------------------------------------------------------------------------
# ---- D-tests: P0-3 branch-gate FIRST-ADD strict negative cases --------------
# setup_repo writes an authoritative PLAN ({branch_gate:{target_branch:"master"}})
# and renames the fixture branch to master, so a branch-gate first-add with a
# real HEAD base sha is VALID (T29). Each D-case breaks a DIFFERENT link in
# that valid chain (PLAN missing / bad / untargeted, recorded branch != PLAN
# target, current branch != recorded branch, symlink, non-ancestor base,
# non-tip base, unresolvable current branch, absent master) and must fail
# closed with the exact gate token as detail. Assertions select the
# branch-gate violation (path + reason + detail) specifically; a few cases
# mutate PLAN as part of the setup, so a collateral non-gate violation on
# PLAN.json may coexist and is ignored by the select.

# ---- D1: first-add branch-gate with MISSING PLAN → plan_missing -------------
D="$(mktemp -d "$TMPDIR/d1-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d1)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
rm -f "$D/.harness/PLAN.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D1a: first-add branch-gate with missing PLAN invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D1b: violation invalid_branch_gate detail plan_missing" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("plan_missing")))] | length')"

# ---- D2: first-add branch-gate with BAD-JSON PLAN → plan_bad_json -----------
D="$(mktemp -d "$TMPDIR/d2-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d2)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
printf 'this is not json\n' > "$D/.harness/PLAN.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D2a: first-add branch-gate with bad-JSON PLAN invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D2b: violation invalid_branch_gate detail plan_bad_json" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("plan_bad_json")))] | length')"

# ---- D3: first-add branch-gate with UNTARGETED PLAN → plan_no_target ---------
D="$(mktemp -d "$TMPDIR/d3-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d3)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
printf '%s\n' '{"schema_version":1}' > "$D/.harness/PLAN.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D3a: first-add branch-gate with untargeted PLAN invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D3b: violation invalid_branch_gate detail plan_no_target" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("plan_no_target")))] | length')"

# ---- D4: recorded branch != PLAN target branch → branch_mismatch -------------
D="$(mktemp -d "$TMPDIR/d4-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d4)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
printf '%s\n' '{"schema_version":1,"branch_gate":{"target_branch":"main"}}' > "$D/.harness/PLAN.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D4a: recorded branch != PLAN target invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D4b: violation invalid_branch_gate detail branch_mismatch" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("branch_mismatch")))] | length')"

# ---- D5: current branch != recorded branch_name → current_branch_mismatch ----
D="$(mktemp -d "$TMPDIR/d5-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d5)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
# Move the gate onto a DIFFERENT branch than the recorded baseline: the recorded
# master baseline is not this repo's baseline when HEAD is on another branch.
git -C "$D" checkout -q -b side 2>/dev/null || git -C "$D" branch -q -m master side 2>/dev/null || true
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D5a: current branch != recorded branch_name invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D5b: violation invalid_branch_gate detail current_branch_mismatch" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("current_branch_mismatch")))] | length')"

# ---- D6: first-add branch-gate as SYMLINK → symlink_rejected -----------------
# A symlink at the branch-gate path is tampering: it must NOT bypass validation
# by resolving to a regular file elsewhere — the gate rejects it before any
# follow-the-link test. Symlink creation is platform-gated (Git Bash on Windows
# /tmp flattens POSIX symlinks — see test-bug3-matrix.sh M5): where unsupported
# the assertion is skipped, matching the repo's existing convention.
D="$(mktemp -d "$TMPDIR/d6-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d6)"
dwm_emit_manifest "$D" "$OUT"
if ln -s "elsewhere.json" "$D/.harness/branch-gate.json" 2>/dev/null; then
  RES="$(dwm_compare_manifest "$D" "$OUT")"
  check "D6a: first-add branch-gate as symlink invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
  check "D6b: violation invalid_branch_gate detail symlink_rejected" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("symlink_rejected")))] | length')"
else
  echo "  [SKIP] D6 symlink branch-gate — symlink creation unsupported on this platform"
fi

# ---- D7: first-add branch-gate with real-but-NON-ANCESTOR base → not_ancestor --
# A real git OID that is NOT an ancestor of HEAD (a commit on a divergent branch)
# must fail — the baseline must prove forward advancement from an ancestor, not
# an unrelated commit.
D="$(mktemp -d "$TMPDIR/d7-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d7)"
dwm_emit_manifest "$D" "$OUT"
# Build a divergent commit that is NOT reachable from master HEAD.
git -C "$D" checkout -q -b side2 2>/dev/null || true
printf 'side\n' > "$D/side-note.txt"
git -C "$D" add side-note.txt
git -C "$D" -c user.email=t@e.com -c user.name=t commit -q -m "side commit" 2>/dev/null
side_sha="$(git -C "$D" rev-parse HEAD)"
git -C "$D" checkout -q master 2>/dev/null || true
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$side_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D7a: first-add branch-gate with non-ancestor base invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D7b: violation invalid_branch_gate detail not_ancestor" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("not_ancestor")))] | length')"

# ---- D8: first-add base != master TIP → not_first_baseline -------------------
# The expected FIRST baseline is the real master tip at the time. Once master has
# advanced (HEAD moved), a base that is an ancestor but NOT HEAD is rejected at
# first-add — an arbitrary ancestor is not "the master tip when the baseline was
# recorded".
D="$(mktemp -d "$TMPDIR/d8-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d8)"
dwm_emit_manifest "$D" "$OUT"
# Advance master by one commit so the original commit is an ancestor but not HEAD.
printf '# advance\n' >> "$D/.gitignore"
git -C "$D" add .gitignore
git -C "$D" -c user.email=t@e.com -c user.name=t commit -q -m "advance master" 2>/dev/null
old_sha="$(git -C "$D" rev-parse HEAD~1)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$old_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D8a: first-add base != master tip invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D8b: violation invalid_branch_gate detail not_first_baseline" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("not_first_baseline")))] | length')"

# ---- D9: first-add branch-gate with NO current branch → current_branch_mismatch --
# An unborn HEAD (empty repo) has no real current branch: git reports the literal
# placeholder "HEAD", which can never equal a recorded branch_name, so the gate
# rejects — a baseline recorded on a branch that is not the branch the gate is
# running on is not this repo's baseline (P0-3). The empty-branch guard in
# _dwm_validate_branch_gate_first_add ([ -z "$cur_branch" ]) is defense-in-depth
# for a fully-unresolvable branch; git reports "HEAD" for unborn/detached/deleted
# refs, so the empty path is not directly reachable through a git repo — D9 pins
# the unborn fail-closed OUTCOME (via "HEAD" != recorded branch_name) and the
# check order, not the empty-guard line itself.
D="$(mktemp -d "$TMPDIR/d9-XXXX")"
git -C "$D" init -q
mkdir -p "$D/.harness"
printf '%s\n' '{"schema_version":1,"branch_gate":{"target_branch":"master"}}' > "$D/.harness/PLAN.json"
printf '%s\n' '{"revision":1,"schema_version":"2.0.0","features":[{"id":"F-001","status":"not_started","evidence_associations":[],"legacy_audit_evidence":[]}]}' > "$D/feature_list.json"
OUT="$(mf "$D" d9)"
dwm_emit_manifest "$D" "$OUT"
# base_sha: any well-formed hex — current_branch_mismatch fires before any OID check.
printf '%s' '{"schema_version":1,"branch_base_sha":"0000000000000000000000000000000000000000","branch_name":"master"}' > "$D/.harness/branch-gate.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D9a: first-add branch-gate with no current branch invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D9b: violation invalid_branch_gate detail current_branch_mismatch" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("current_branch_mismatch")))] | length')"

# ---- D10: first-add branch-gate with NO master ref → not_first_baseline ---------
# The first baseline must prove the REAL master tip at the time. A repo whose
# master ref has been removed cannot prove that, so an otherwise-consistent
# baseline (real oid, ancestor of HEAD, branch/PLAN all "main") fails closed
# instead of being accepted (P0-3). NOTE: this case necessarily renames the
# branch AND rewrites PLAN (bn/cur/PLAN must all name "main" so the branch-name
# chain passes and the absent-master guard is the FIRST token to fire); the
# collateral PLAN.json byte change is expected — the assertions select the
# branch-gate violation path specifically.
D="$(mktemp -d "$TMPDIR/d10-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d10)"
dwm_emit_manifest "$D" "$OUT"
git -C "$D" branch -m master main 2>/dev/null || true
base_sha="$(git -C "$D" rev-parse HEAD)"
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"main\"}" > "$D/.harness/branch-gate.json"
printf '%s\n' '{"schema_version":1,"branch_gate":{"target_branch":"main"}}' > "$D/.harness/PLAN.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D10a: first-add branch-gate with no master ref invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D10b: violation invalid_branch_gate detail not_first_baseline" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("not_first_baseline")))] | length')"

# ---- D11: first-add base != master TIP when target branch is AHEAD of master ----
# Codex item 8: when the target branch has advanced AHEAD of master
# (HEAD != master tip), the old master-tip == HEAD special-case never fires, so
# ANY real ancestor of HEAD still passes — the gate never proves base == master
# tip. The expected FIRST baseline is the REAL master tip at the time
# (branch-gate.sh records branch_base_sha = master tip on first entry, and master
# does not advance during Phase 1). A base that is a real ancestor of HEAD but
# NOT the master tip must fail even when the target branch is ahead. NOTE: this
# case necessarily checks out a feature branch AND rewrites PLAN (bn/cur/PLAN
# must all name "feature" so the branch-name chain passes and the master-tip
# guard is the FIRST token to fire); the collateral PLAN.json byte change and the
# .gitignore advance are expected — the assertions select the branch-gate
# violation path specifically.
D="$(mktemp -d "$TMPDIR/d11-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d11)"
dwm_emit_manifest "$D" "$OUT"
# Advance master by one commit (X1 → X2), then branch AHEAD of it (T1 = X2 + 1):
# the recorded base X1 is a real ancestor of HEAD but not the master tip X2.
printf '# advance\n' >> "$D/.gitignore"
git -C "$D" add .gitignore
git -C "$D" -c user.email=t@e.com -c user.name=t commit -q -m "advance master" 2>/dev/null
git -C "$D" checkout -q -b feature 2>/dev/null
printf 'feat\n' > "$D/feat.txt"
git -C "$D" add feat.txt
git -C "$D" -c user.email=t@e.com -c user.name=t commit -q -m "feature ahead" 2>/dev/null
base_sha="$(git -C "$D" rev-parse HEAD~2)"   # X1 — a real ancestor, != master tip X2
printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"feature\"}" > "$D/.harness/branch-gate.json"
printf '%s\n' '{"schema_version":1,"branch_gate":{"target_branch":"feature"}}' > "$D/.harness/PLAN.json"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "D11a: first-add base != master tip (target ahead) invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "D11b: violation invalid_branch_gate detail not_first_baseline" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("not_first_baseline")))] | length')"

# ---- T37 (Codex r4): gitignored run log REMOVAL must be detected ------------
# The .harness/logs/ directory IS in .gitignore, so `git status --porcelain`
# never reports run-log files. The manifest must enumerate them directly so a
# deletion of a recorded run is detectable (without this fix the deletion is
# invisible to the gate — `valid=true` even after the run is gone).
D="$(mktemp -d "$TMPDIR/t37-XXXX")"
setup_repo "$D"
# Make .harness/logs/ gitignored (matches the real repo's .gitignore).
printf '.harness/logs/\n' >> "$D/.gitignore"
git -C "$D" add .gitignore
git -C "$D" -c user.email=t@e.com -c user.name=t commit -q -m "ignore logs" 2>/dev/null
# The file is in the dir we just gitignored — git status no longer reports it.
printf 'run-1\n' > "$D/.harness/logs/runs/run-1.ndjson"
OUT="$(mf "$D" t37)"
dwm_emit_manifest "$D" "$OUT"
# The manifest MUST contain the run-log record (Codex r4 fix).
HAS_RUN="$(jq -r 'select(.path == ".harness/logs/runs/run-1.ndjson") | .path' "$OUT" | head -1)"
check "T37a: gitignored run-log file enumerated by manifest" ".harness/logs/runs/run-1.ndjson" "$HAS_RUN"
# Marker `!!` distinguishes manifest-enumerated gitignored entries from
# the `??` git-status untracked entries (diagnostic only — compare logic
# does not act on git_status, but the field must be present and non-null).
GIT_ST="$(jq -r 'select(.path == ".harness/logs/runs/run-1.ndjson") | .git_status' "$OUT")"
check "T37b: run-log record carries manifest-enumerated marker" "!!" "$GIT_ST"
# Baseline gates valid: nothing else has changed.
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T37c: gitignored-run baseline valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
# Now REMOVE the recorded run log — must be detected.
rm "$D/.harness/logs/runs/run-1.ndjson"
RES2="$(dwm_compare_manifest "$D" "$OUT")"
check "T37d: gitignored run-log removal invalid" false "$(printf '%s' "$RES2" | jq -r '.valid')"
check "T37e: violation reason removed" "removed" "$(printf '%s' "$RES2" | jq -r '.violations[] | select(.path == ".harness/logs/runs/run-1.ndjson") | .reason')"
check "T37f: exactly one violation" 1 "$(printf '%s' "$RES2" | jq '.violations | length')"

# ---- T38 (Codex r4): gitignored run log REWRITE must be detected -------------
# Same gitignored dir — a recorded run's bytes get rewritten; the per-class
# rule (`.harness/logs/runs/*.ndjson — existing run NDJSON must stay BYTE-EQUAL`)
# must fire even though git status never saw the file in the first place.
D="$(mktemp -d "$TMPDIR/t38-XXXX")"
setup_repo "$D"
printf '.harness/logs/\n' >> "$D/.gitignore"
git -C "$D" add .gitignore
git -C "$D" -c user.email=t@e.com -c user.name=t commit -q -m "ignore logs" 2>/dev/null
printf 'run-1\n' > "$D/.harness/logs/runs/run-1.ndjson"
OUT="$(mf "$D" t38)"
dwm_emit_manifest "$D" "$OUT"
# Rewrite the run-log bytes.
printf 'run-1-REWRITTEN\n' > "$D/.harness/logs/runs/run-1.ndjson"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T38a: gitignored run-log rewrite invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T38b: violation reason not_byte_equal" "not_byte_equal" "$(printf '%s' "$RES" | jq -r '.violations[] | select(.path == ".harness/logs/runs/run-1.ndjson") | .reason')"
check "T38c: exactly one violation" 1 "$(printf '%s' "$RES" | jq '.violations | length')"

# ---- T39 (Codex r4): gitignored NEW run log → allowed_new (positive) ----------
# Same gitignored dir — adding a new run-log file is allowed (mutable namespace
# new path), confirming the new enumeration integrates with allowed_new instead
# of being misclassified as new_non_mutable.
D="$(mktemp -d "$TMPDIR/t39-XXXX")"
setup_repo "$D"
printf '.harness/logs/\n' >> "$D/.gitignore"
git -C "$D" add .gitignore
git -C "$D" -c user.email=t@e.com -c user.name=t commit -q -m "ignore logs" 2>/dev/null
# A recorded run-log establishes the baseline's run-log inventory.
printf 'run-1\n' > "$D/.harness/logs/runs/run-1.ndjson"
OUT="$(mf "$D" t39)"
dwm_emit_manifest "$D" "$OUT"
# Add a NEW run-log file.
printf 'run-2\n' > "$D/.harness/logs/runs/run-2.ndjson"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T39a: new gitignored run-log valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T39b: run-2.ndjson in allowed_new" "1" "$(printf '%s' "$RES" | jq '[.allowed_new[] | select(. == ".harness/logs/runs/run-2.ndjson")] | length')"
check "T39c: no violations" 0 "$(printf '%s' "$RES" | jq '.violations | length')"

# ---- T40 (Codex r7 item 3): runtime-artifact byte-binding — joint tamper -----
# The frozen fixture pre-dates the canonical run, so its NDJSON + command log +
# reviewer verdict enter as `allowed_new` and are NOT byte-bound by the fixture.
# The runtime-manifest registry binds their first-seen bytes; once registered, a
# joint tamper of NDJSON + log + verdict must fail the formal DWM gate even
# though NONE of the three is in the recorded fixture (all three are allowed_new
# — without the registry the gate would return valid=true and the tamper would
# be invisible). This pins the "no long-term allowed_new bypass" contract.
D="$(mktemp -d "$TMPDIR/t40-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t40)"
dwm_emit_manifest "$D" "$OUT"
# Canonical-run artifacts that post-date the recorded fixture:
printf 'run-2\n' > "$D/.harness/logs/runs/run-2.ndjson"
mkdir -p "$D/.harness/logs/runs/run-2"
printf 'full-suite log\n' > "$D/.harness/logs/runs/run-2/full-suite.log"
printf 'verdict-2\n' > "$D/.harness/reviews/feature/F-CONV-02.jsonl"
# Bind their first-seen bytes exactly as the writers/bootstrap would.
runtime_register "$D" ".harness/logs/runs/run-2.ndjson" "ndjson"
runtime_register "$D" ".harness/logs/runs/run-2/full-suite.log" "log"
runtime_register "$D" ".harness/reviews/feature/F-CONV-02.jsonl" "verdict"
# Joint tamper: rewrite NDJSON + log in place, and rewrite (not append) the verdict.
printf 'run-2-TAMPERED\n' > "$D/.harness/logs/runs/run-2.ndjson"
printf 'full-suite log TAMPERED\n' > "$D/.harness/logs/runs/run-2/full-suite.log"
printf 'verdict-2-TAMPERED\n' > "$D/.harness/reviews/feature/F-CONV-02.jsonl"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T40a: joint tamper of registered allowed_new artifacts invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T40b: run NDJSON tamper → runtime_artifact_not_byte_equal" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/logs/runs/run-2.ndjson" and .reason == "runtime_artifact_not_byte_equal")] | length')"
check "T40c: command log tamper → runtime_artifact_not_byte_equal" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/logs/runs/run-2/full-suite.log" and .reason == "runtime_artifact_not_byte_equal")] | length')"
check "T40d: verdict tamper → runtime_artifact_not_append_only" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/reviews/feature/F-CONV-02.jsonl" and .reason == "runtime_artifact_not_append_only")] | length')"

# ---- T41 (Codex r7 item 3): registered verdict APPEND stays valid ------------
# A legitimate re-review APPENDS one record; the registry's append-only binding
# (registered bytes are a PREFIX of current) must NOT flag it — the negative
# T40 proves tamper detection, this positive pins the no-false-positive side.
D="$(mktemp -d "$TMPDIR/t41-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t41)"
dwm_emit_manifest "$D" "$OUT"
# rc6 final: also register setup_repo's run-1.ndjson (a runtime artifact) so
# it doesn't trigger an "unregistered" violation and pollute the assertion.
runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson"
runtime_register "$D" ".harness/reviews/feature/F-CONV-01.jsonl" "verdict"
printf 'verdict-1-APPENDED\n' >> "$D/.harness/reviews/feature/F-CONV-01.jsonl"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T41a: registered verdict append still valid" true "$(printf '%s' "$RES" | jq -r '.valid')"
check "T41b: no runtime_artifact violations" 0 "$(printf '%s' "$RES" | jq '[.violations[] | select(.reason | startswith("runtime_artifact"))] | length')"

# ---- T42 (Codex rc6 final blocker ①): unregistered runtime artifact rejected ---
# A new NDJSON appears under .harness/logs/runs/ without ever being registered
# in .harness/runtime-manifest.jsonl. The gate MUST reject (rc6 final: the
# previous `continue` allowed an attacker to introduce a forged artifact by
# editing only the file bytes — no manifest entry required).
D="$(mktemp -d "$TMPDIR/t42-XXXX")"
setup_repo "$D"
# Initialize the registry WITH a genesis anchor + register the existing run-1
# artifact, so the runtime-artifact code path is active. THEN introduce a new
# NDJSON that is NOT registered → the gate must reject.
HEAD_SHA_T42="$(git -C "$D" rev-parse HEAD)"
printf '{"genesis":"%s"}\n' "$HEAD_SHA_T42" > "$D/.harness/runtime-manifest.jsonl"
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA_T42" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
# Now introduce the unregistered artifact.
mkdir -p "$D/.harness/logs/runs/run-unreg"
printf '{"event":"run_started","schema_version":2,"run_id":"run-unreg","started_at":"2026-01-01T00:00:00Z","project_root":"%s","vcs_revision":"%s","vcs_revision_source":"git","workspace_fingerprint_initial":"sha256:%s","config_sha256":"sha256:%s","required_command_ids":["c1"],"capability_level":2,"feature_id":"F-MAINT-01"}\n' \
  "$D" "$HEAD_SHA_T42" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$D/.harness/logs/runs/run-unreg.ndjson"
OUT="$(mf "$D" t42)"
dwm_emit_manifest "$D" "$OUT"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T42a: unregistered runtime artifact invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T42b: violation runtime_artifact_unregistered" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/logs/runs/run-unreg.ndjson" and .reason == "runtime_artifact_unregistered")] | length')"

# ---- T43 (Codex rc6 final blocker ①+②): joint tamper of registry+artifact ----
# Attacker changes the NDJSON AND the registry's recorded sha/size in lockstep.
# The previous code trusted the registry as authoritative, so this passed.
# rc6 final: the registry is genesis-anchored to HEAD, so tampering with the
# registry itself shifts the genesis anchor (or breaks the byte prefix) and
# fails the gate.
D="$(mktemp -d "$TMPDIR/t43-XXXX")"
setup_repo "$D"
mkdir -p "$D/.harness/logs/runs/run-tamper"
# Use a fixed captured sha256/size as the "registered" first-seen state.
ORIG_BYTES='{"event":"run_started","schema_version":2,"run_id":"run-tamper","started_at":"2026-01-01T00:00:00Z"}'
printf '%s\n' "$ORIG_BYTES" > "$D/.harness/logs/runs/run-tamper.ndjson"
ORIG_SHA="$(sha256sum "$D/.harness/logs/runs/run-tamper.ndjson" | awk '{print $1}')"
ORIG_SZ="$(wc -c < "$D/.harness/logs/runs/run-tamper.ndjson")"
# Pre-create the registry with a genesis anchor + a binding for run-tamper.ndjson.
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
printf '{"genesis":"%s"}\n' "$HEAD_SHA" > "$D/.harness/runtime-manifest.jsonl"
# Register ALL existing runtime artifacts (the ones setup_repo creates), so
# the runtime-artifact code path doesn't fire on legitimate fixtures.
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/reviews/feature/F-CONV-01.jsonl" "verdict" >/dev/null 2>&1
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-tamper.ndjson" "ndjson" >/dev/null 2>&1
# First capture manifest while clean → should be valid.
OUT="$(mf "$D" t43-baseline)"
dwm_emit_manifest "$D" "$OUT"
RES_BASE="$(dwm_compare_manifest "$D" "$OUT")"
check "T43a: clean state with genesis valid" true "$(printf '%s' "$RES_BASE" | jq -r '.valid')"
# Now: rewrite BOTH the artifact (tampered bytes) AND the registry line
# (matching new sha/size, but appending a duplicate path → registry wholesale
# rejection). The duplicate-path guard plus the genesis anchor make this
# fail. The attacker bypasses runtime_register's idempotency by editing the
# file directly — the duplicate guard in dwm_compare_manifest catches the
# forged second binding.
printf '%s\n' "${ORIG_BYTES}TAMPERED" > "$D/.harness/logs/runs/run-tamper.ndjson"
NEW_SHA="$(sha256sum "$D/.harness/logs/runs/run-tamper.ndjson" | awk '{print $1}')"
NEW_SZ="$(wc -c < "$D/.harness/logs/runs/run-tamper.ndjson")"
# Append a SECOND binding for the same path with the tampered hash (bypassing
# runtime_register, which would otherwise dedup).
printf '{"path":".harness/logs/runs/run-tamper.ndjson","kind":"ndjson","sha256":"%s","size":%s}\n' "$NEW_SHA" "$NEW_SZ" >> "$D/.harness/runtime-manifest.jsonl"
OUT2="$(mf "$D" t43-tamper)"
dwm_emit_manifest "$D" "$OUT2"
RES_TAMPER="$(dwm_compare_manifest "$D" "$OUT2")"
check "T43b: registry duplicate path → invalid" false "$(printf '%s' "$RES_TAMPER" | jq -r '.valid')"
check "T43c: violation runtime_manifest_duplicate_path" "1" "$(printf '%s' "$RES_TAMPER" | jq '[.violations[] | select(.reason == "runtime_manifest_duplicate_path")] | length')"

# ---- T44 (Codex rc6 final): genesis anchor mismatch ---------------------------
# Set RUNTIME_MANIFEST_GENESIS to a value different from the in-tree genesis
# line. The gate MUST reject (rc6 final: previously the registry was trusted
# as-is, allowing a tampered genesis to silently pass).
D="$(mktemp -d "$TMPDIR/t44-XXXX")"
setup_repo "$D"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
# In-tree genesis says HEAD; env override says a DIFFERENT OID. Register the
# setup_repo runtime artifacts so the test fails on the genesis mismatch
# (not on a chain of unregistered violations).
printf '{"genesis":"%s"}\n' "$HEAD_SHA" > "$D/.harness/runtime-manifest.jsonl"
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/reviews/feature/F-CONV-01.jsonl" "verdict" >/dev/null 2>&1
OUT="$(mf "$D" t44)"
dwm_emit_manifest "$D" "$OUT"
# Run with a different expected genesis.
RES="$(RUNTIME_MANIFEST_GENESIS="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" dwm_compare_manifest "$D" "$OUT")"
check "T44a: genesis env override mismatch invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T44b: violation runtime_manifest_genesis_mismatch" "1" "$(printf '%s' "$RES" | jq '[.violations[] | select(.reason == "runtime_manifest_genesis_mismatch")] | length')"

# ---- T45 (Codex rc6 final): missing genesis anchor ----------------------------
D="$(mktemp -d "$TMPDIR/t45-XXXX")"
setup_repo "$D"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
# Registry exists but its first line is NOT a genesis line (attacker dropped it).
# Register the existing runtime artifacts first, then drop the genesis line so
# the gate fires on the missing-genesis reason (not unregistered chain).
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/reviews/feature/F-CONV-01.jsonl" "verdict" >/dev/null 2>&1
# Now read the existing registry and rewrite it WITHOUT the genesis anchor.
existing_lines="$(tail -n +2 "$D/.harness/runtime-manifest.jsonl")"
printf '%s\n' "$existing_lines" > "$D/.harness/runtime-manifest.jsonl"
OUT="$(mf "$D" t45)"
dwm_emit_manifest "$D" "$OUT"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T45a: missing genesis line invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
check "T45b: violation runtime_manifest_genesis_missing" "1" "$(printf '%s' "$RES" | jq '[.violations[] | select(.reason == "runtime_manifest_genesis_missing")] | length')"

# ---- T46: an existing registry with no genesis is never auto-repaired --------
# A legacy registry and a registry whose trust root was deleted are
# indistinguishable. Normal registration must therefore fail closed and leave
# the existing bytes untouched. Legacy conversion belongs to an explicit,
# separately audited migration boundary.
D="$(mktemp -d "$TMPDIR/t46-XXXX")"
setup_repo "$D"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
# Simulate an existing registry after its genesis was removed.
mkdir -p "$D/.harness"
printf '{"path":"%s","kind":"ndjson","sha256":"%s","size":%s}\n' \
  ".harness/logs/runs/run-1.ndjson" \
  "0000000000000000000000000000000000000000000000000000000000000000" 0 \
  > "$D/.harness/runtime-manifest.jsonl"
before_sha="$(_runtime_file_sha256 "$D/.harness/runtime-manifest.jsonl")"
before_size="$(wc -c < "$D/.harness/runtime-manifest.jsonl" | tr -d '[:space:]')"
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
register_rc=$?
after_sha="$(_runtime_file_sha256 "$D/.harness/runtime-manifest.jsonl")"
after_size="$(wc -c < "$D/.harness/runtime-manifest.jsonl" | tr -d '[:space:]')"
check "T46a: missing-genesis registration fails closed" "1" "$register_rc"
check "T46b: failed registration preserves byte-exact registry hash" "$before_sha" "$after_sha"
check "T46c: failed registration preserves byte-exact registry size" "$before_size" "$after_size"
check "T46d: failed registration does not synthesize genesis" "0" "$(jq -s '[.[] | select(has("genesis"))] | length' "$D/.harness/runtime-manifest.jsonl")"

# ---- D12 (Codex r4): symlink PLAN.json is rejected, not followed ------------
# `[ -f ]` follows symlinks, so without the explicit symlink guard a symlink →
# valid-PLAN would be accepted, allowing the baseline gate's branch policy to
# be redirected to an attacker-controlled file. Symlink creation is
# platform-gated (see D6); where unsupported the assertion is skipped.
D="$(mktemp -d "$TMPDIR/d12-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" d12)"
dwm_emit_manifest "$D" "$OUT"
base_sha="$(git -C "$D" rev-parse HEAD)"
# Build a real PLAN.json at a separate path, then redirect via symlink.
TMP_PLAN="$(mktemp -d)"
printf '%s\n' '{"schema_version":1,"branch_gate":{"target_branch":"master"}}' > "$TMP_PLAN/real-plan.json"
if ln -s "$TMP_PLAN/real-plan.json" "$D/.harness/PLAN.json" 2>/dev/null; then
  printf '%s' "{\"schema_version\":1,\"branch_base_sha\":\"$base_sha\",\"branch_name\":\"master\"}" > "$D/.harness/branch-gate.json"
  RES="$(dwm_compare_manifest "$D" "$OUT")"
  check "D12a: symlink PLAN.json invalid" false "$(printf '%s' "$RES" | jq -r '.valid')"
  check "D12b: violation invalid_branch_gate detail plan_symlink" "1" "$(printf '%s' "$RES" | jq -r '[.violations[] | select(.path == ".harness/branch-gate.json" and .reason == "invalid_branch_gate" and (.detail | test("plan_symlink")))] | length')"
else
  echo "  [SKIP] D12 symlink PLAN.json — symlink creation unsupported on this platform"
fi
rm -rf "$TMP_PLAN"

# ---- D13 (Codex r4): config-validate also rejects symlink config.json --------
# The same symlink-following bug lives in validate_config_schema: `[ -f ]`
# follows symlinks, so a symlink → valid-config would be accepted, allowing
# verification policy to be redirected to an attacker-controlled file. This
# pins the related vulnerability at the config-validate layer. Symlink
# creation is platform-gated (see D6 / D12); on Windows Git Bash `ln -s`
# silently creates a regular file copy, defeating the test — skip there.
D="$(mktemp -d "$TMPDIR/d13-XXXX")"
mkdir -p "$D/.harness"
TMP_CFG="$(mktemp -d)"
printf '%s\n' '{"project_type":"generic","verification":{"commands":[]}}' > "$TMP_CFG/real.json"
ln -s "$TMP_CFG/real.json" "$D/.harness/config.json" 2>/dev/null
# Probe: did the symlink survive? `readlink` returns the target only for real
# symlinks; on Windows Git Bash `ln -s` falls back to a file copy and the
# test cannot exercise the symlink path.
if [ -L "$D/.harness/config.json" ]; then
  # shellcheck disable=SC1090
  if source "$ROOT_DIR/core/lib/config-validate.sh" 2>/dev/null; then
    rc=0; out="$(validate_config_schema "$D/.harness/config.json" 2>&1)"; rc=$?
    check "D13a: symlink config.json → nonzero" "1" "$rc"
    case "$out" in
      *symlink*) check "D13b: detail mentions symlink" "1" "1" ;;
      *) check "D13b: detail mentions symlink" "1" "0" ;;
    esac
  else
    echo "  [SKIP] D13 config-validate symlink — could not source validator"
  fi
else
  echo "  [SKIP] D13 config-validate symlink — symlink creation unsupported on this platform"
fi
rm -rf "$TMP_CFG"

# ---- T47: acceptance artifacts are mutable only when registry-bound --------
D="$(mktemp -d "$TMPDIR/t47-XXXX")"
setup_repo "$D"
OUT="$(mf "$D" t47)"
dwm_emit_manifest "$D" "$OUT"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" ndjson
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/reviews/feature/F-CONV-01.jsonl" verdict
mkdir -p "$D/.harness/acceptance/$HEAD_SHA"
printf '%s\n' '{"schema_version":1}' > "$D/.harness/acceptance/$HEAD_SHA/acceptance.json"
printf '%s\n' 'A-G evidence' > "$D/.harness/acceptance/$HEAD_SHA/A-G.log"
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/acceptance/$HEAD_SHA/acceptance.json" acceptance
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/acceptance/$HEAD_SHA/A-G.log" log
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T47a: registered acceptance artifacts accepted" true "$(printf '%s' "$RES" | jq -r '.valid')"
printf '%s\n' 'unregistered' > "$D/.harness/acceptance/$HEAD_SHA/unregistered.log"
RES="$(dwm_compare_manifest "$D" "$OUT")"
check "T47b: unregistered acceptance artifact rejected" 1 "$(printf '%s' "$RES" | jq '[.violations[] | select(.reason == "runtime_artifact_unregistered")] | length')"

# ---- T48 (rc6 final remediation R1): runtime_register fail-closed on stale genesis ---
# An EXISTING registry whose genesis anchor does not match the expected HEAD must
# be rejected by runtime_register ITSELF (rc≠0, no append) — not merely caught
# later at the DWM gate (T44). This closes the window where a stale registry
# would otherwise be silently re-anchored or appended-to during registration.
D="$(mktemp -d "$TMPDIR/t48-XXXX")"
setup_repo "$D"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
mkdir -p "$D/.harness"
printf '{"genesis":"1111111111111111111111111111111111111111111111111111111111111111"}\n' \
  > "$D/.harness/runtime-manifest.jsonl"
lines_before="$(wc -l < "$D/.harness/runtime-manifest.jsonl" | tr -d '[:space:]')"
rc=0
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
rc=$?
lines_after="$(wc -l < "$D/.harness/runtime-manifest.jsonl" | tr -d '[:space:]')"
check "T48a: stale genesis fails closed" 1 "$rc"
check "T48b: stale genesis appends nothing" "$lines_before" "$lines_after"

# ---- T49 (rc6 final remediation R1): runtime_register fail-closed on malformed JSONL ---
# A registry carrying a non-JSON line must abort registration. Line 0 is a valid
# genesis so the prepend path does not mask the violation; validation catches the
# malformed second line.
D="$(mktemp -d "$TMPDIR/t49-XXXX")"
setup_repo "$D"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
mkdir -p "$D/.harness"
printf '{"genesis":"%s"}\nthis is not valid json\n' "$HEAD_SHA" > "$D/.harness/runtime-manifest.jsonl"
lines_before="$(wc -l < "$D/.harness/runtime-manifest.jsonl" | tr -d '[:space:]')"
rc=0
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
rc=$?
lines_after="$(wc -l < "$D/.harness/runtime-manifest.jsonl" | tr -d '[:space:]')"
check "T49a: malformed registry fails closed" 1 "$rc"
check "T49b: malformed registry appends nothing" "$lines_before" "$lines_after"

# ---- T50 (rc6 final remediation R1): runtime_register fail-closed on duplicate genesis ---
D="$(mktemp -d "$TMPDIR/t50-XXXX")"
setup_repo "$D"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
mkdir -p "$D/.harness"
printf '{"genesis":"%s"}\n{"genesis":"%s"}\n' "$HEAD_SHA" "$HEAD_SHA" > "$D/.harness/runtime-manifest.jsonl"
lines_before="$(wc -l < "$D/.harness/runtime-manifest.jsonl" | tr -d '[:space:]')"
rc=0
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
rc=$?
lines_after="$(wc -l < "$D/.harness/runtime-manifest.jsonl" | tr -d '[:space:]')"
check "T50a: duplicate genesis fails closed" 1 "$rc"
check "T50b: duplicate genesis appends nothing" "$lines_before" "$lines_after"

# ---- T51 (rc6 final remediation R1): runtime_register fail-closed on dangling symlink ---
# A dangling symlink at the registry path is an obstacle, not "absent": without
# the lstat (-L) guard it would fall through the `! -e` short-circuit and be
# silently treated as a no-op. Symlink creation is platform-gated (see D12/D13);
# where unsupported the assertion is skipped.
D="$(mktemp -d "$TMPDIR/t51-XXXX")"
setup_repo "$D"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
mkdir -p "$D/.harness"
rm -f "$D/.harness/runtime-manifest.jsonl"
ln -s "/nonexistent/reg-target-$$" "$D/.harness/runtime-manifest.jsonl" 2>/dev/null
if [ -L "$D/.harness/runtime-manifest.jsonl" ]; then
  rc=0
  RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
  rc=$?
  check "T51a: dangling symlink registry fails closed" 1 "$rc"
  check "T51b: dangling symlink left untouched (still a symlink)" "symlink" "$([ -L "$D/.harness/runtime-manifest.jsonl" ] && echo symlink || echo replaced)"
else
  echo "  [SKIP] T51 dangling symlink — symlink creation unsupported on this platform"
fi

# ---- T52 (rc6 final remediation R1): runtime_register fail-closed on directory obstacle ---
# A directory at the registry path is an obstacle: `-e` true but `-f` false. It
# must hard-fail (never silently skip as "absent" nor be treated as an empty file).
D="$(mktemp -d "$TMPDIR/t52-XXXX")"
setup_repo "$D"
HEAD_SHA="$(git -C "$D" rev-parse HEAD)"
mkdir -p "$D/.harness/runtime-manifest.jsonl"
rc=0
RUNTIME_MANIFEST_GENESIS="$HEAD_SHA" runtime_register "$D" ".harness/logs/runs/run-1.ndjson" "ndjson" >/dev/null 2>&1
rc=$?
check "T52a: directory obstacle fails closed" 1 "$rc"

echo ""
echo "Dirty-Worktree-Manifest Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
