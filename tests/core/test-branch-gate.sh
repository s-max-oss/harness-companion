#!/bin/bash
# test-branch-gate.sh — Stateful branch baseline gate test suite
#
# Exercises branch_gate_check(): FIRST entry requires current branch tip ==
# local master tip (records .harness/branch-gate.json with branch_name +
# branch_base_sha only when branch_gate_allow_record=1); SUBSEQUENT entries
# require the same branch AND the recorded base to be an ancestor of HEAD
# (forward advancement only). Missing git / non-repo / no master all FAIL-CLOSED.
# P0-13: the target branch is read ONLY from .harness/PLAN.json
# branch_gate.target_branch (PLAN authoritative) — the branch_gate_target_branch
# env variable is IGNORED and must not rewrite the decision. The recorded state
# is fully DETERMINISTIC (no first_entry_at timestamp): byte-equal over time AND
# byte-equal across a fresh regeneration.
# Requires: bash, jq, git.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck source=../../core/lib/branch-gate.sh
source "$ROOT_DIR/core/lib/branch-gate.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---- helpers ----

# ginit <dir> — init a repo with one empty commit on a branch named `master`.
ginit() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m A
  local cur
  cur="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ "$cur" != "master" ]; then
    git -C "$d" branch -m "$cur" master
  fi
}

gsha() { git -C "$1" rev-parse HEAD 2>/dev/null; }
gcommit() { git -C "$1" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m "$2"; }

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

# gate_rc <dir> [allow_record] — run the gate, print exit code.
gate_rc() {
  local d="$1" allow="${2:-0}"
  branch_gate_allow_record="$allow" branch_gate_check "$d" >/dev/null 2>&1
  echo "$?"
}

# plan_target <dir> <target> — minimal PLAN.json declaring branch_gate.target_branch.
plan_target() {
  local d="$1" tgt="$2"
  mkdir -p "$d/.harness"
  printf '{"version":"2.0.0-rc.3","branch_gate":{"target_branch":"%s"}}\n' "$tgt" > "$d/.harness/PLAN.json"
}

# ---- T1: first entry, HEAD==master, allow_record=1 → pass + state written ----
D="$(mktemp -d "$TMPDIR/t1-XXXX")"
ginit "$D"
plan_target "$D" master
T1_SHA="$(gsha "$D")"
check "T1: first entry tip==master passes (exit 0)" 0 "$(gate_rc "$D" 1)"
check "T1: state file recorded" yes "$([ -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"
check "T1: recorded branch_name == master" "master" "$(jq -r '.branch_name' "$D/.harness/branch-gate.json" 2>/dev/null)"
check "T1: recorded branch_base_sha == HEAD" "$T1_SHA" "$(jq -r '.branch_base_sha' "$D/.harness/branch-gate.json" 2>/dev/null)"

# ---- T2: first entry, HEAD!=master → fail, NO state written ----
D="$(mktemp -d "$TMPDIR/t2-XXXX")"
ginit "$D"
plan_target "$D" feature
git -C "$D" checkout -q -b feature
gcommit "$D" B
check "T2: first entry tip!=master fails (exit 1)" 1 "$(gate_rc "$D" 1)"
check "T2: no state file leaked on failure" yes "$([ ! -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"

# ---- T3: subsequent entry, same branch, forward commit → pass ----
D="$(mktemp -d "$TMPDIR/t3-XXXX")"
ginit "$D"
plan_target "$D" master
gate_rc "$D" 1 >/dev/null          # record base = A
gcommit "$D" B                     # forward advancement
check "T3: forward advancement on same branch passes (exit 0)" 0 "$(gate_rc "$D")"

# ---- T4: subsequent entry, branch switch → fail ----
D="$(mktemp -d "$TMPDIR/t4-XXXX")"
ginit "$D"
plan_target "$D" master
gate_rc "$D" 1 >/dev/null          # record branch=master
git -C "$D" checkout -q -b other
check "T4: branch switch fails (exit 1)" 1 "$(gate_rc "$D")"

# ---- T5: recorded base no longer an ancestor (history rewritten) → fail ----
D="$(mktemp -d "$TMPDIR/t5-XXXX")"
ginit "$D"
plan_target "$D" master
T5_A="$(gsha "$D")"
gcommit "$D" B
gate_rc "$D" 1 >/dev/null          # record base = B
git -C "$D" reset -q --hard "$T5_A"
check "T5: base dropped from ancestry fails (exit 1)" 1 "$(gate_rc "$D")"

# ---- T6: first entry passes but allow_record=0 → no state written ----
D="$(mktemp -d "$TMPDIR/t6-XXXX")"
ginit "$D"
plan_target "$D" master
check "T6: pass without recording (exit 0)" 0 "$(gate_rc "$D" 0)"
check "T6: no state written when allow_record=0" yes "$([ ! -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"

# ---- T7: not a git repo → fail-closed ----
D="$(mktemp -d "$TMPDIR/t7-XXXX")"
check "T7: non-repo fails closed (exit 1)" 1 "$(gate_rc "$D" 1)"

# ---- T8: git repo with no master branch → fail-closed ----
D="$(mktemp -d "$TMPDIR/t8-XXXX")"
git -C "$D" init -q
check "T8: no local master fails closed (exit 1)" 1 "$(gate_rc "$D" 1)"

# ---- T9: existing state file with bad schema_version → fail ----
D="$(mktemp -d "$TMPDIR/t9-XXXX")"
ginit "$D"
plan_target "$D" master
mkdir -p "$D/.harness"
printf '{"schema_version":2,"branch_name":"master","branch_base_sha":"%s"}\n' "$(gsha "$D")" \
  > "$D/.harness/branch-gate.json"
check "T9: state file schema_version != 1 fails (exit 1)" 1 "$(gate_rc "$D")"

# ---- T10: state file missing branch_base_sha → fail ----
D="$(mktemp -d "$TMPDIR/t10-XXXX")"
ginit "$D"
plan_target "$D" master
mkdir -p "$D/.harness"
printf '{"schema_version":1,"branch_name":"master"}\n' > "$D/.harness/branch-gate.json"
check "T10: state file missing branch_base_sha fails (exit 1)" 1 "$(gate_rc "$D")"

# ============================================================================
# P0-2 additions — target-branch enforcement, ready→commit→re-entry, write
# failure blocks, no timestamp churn.
# ============================================================================

# ---- T11: P0-13 target branch enforcement — PLAN authoritative ----
D="$(mktemp -d "$TMPDIR/t11-XXXX")"
ginit "$D"
plan_target "$D" feature
# First entry on the WRONG target fails even though tip == master.
git -C "$D" checkout -q -b other                 # tip == master, wrong target
check "T11: wrong target branch fails on first entry (exit 1)" 1 "$(gate_rc "$D" 1)"
check "T11: no state leaked on wrong-target first entry" yes \
  "$([ ! -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"
# On the CORRECT target → passes and records.
git -C "$D" checkout -q master
git -C "$D" branch -q -D other
git -C "$D" checkout -q -b feature               # correct target (tip == master)
check "T11: correct target branch passes first entry (exit 0)" 0 "$(gate_rc "$D" 1)"
check "T11: recorded branch_name == target branch" "feature" \
  "$(jq -r '.branch_name' "$D/.harness/branch-gate.json" 2>/dev/null)"
# A caller env override is IGNORED — an override naming a DIFFERENT target must
# not change the gate's decision or rewrite the recorded branch.
check "T11: env override does not alter recorded branch (PLAN authoritative)" "feature" \
  "$(branch_gate_target_branch=rc3-other gate_rc "$D" 1 >/dev/null 2>&1; jq -r '.branch_name' "$D/.harness/branch-gate.json" 2>/dev/null)"
# Subsequent entry on a DIFFERENT branch fails (per-branch + target mismatch).
git -C "$D" checkout -q -b other2
check "T11: subsequent entry on non-target branch fails (exit 1)" 1 "$(gate_rc "$D" 1)"

# ---- T12: ready (record) → feature commit → second entry still passes ----
# The user-level "首次 ready → feature commit → 第二次 init 仍通过 branch gate"
# contract, exercised at the gate level (init.sh's record call is
# branch_gate_allow_record=1 branch_gate_check .).
D="$(mktemp -d "$TMPDIR/t12-XXXX")"
ginit "$D"
plan_target "$D" rc3-guided-conversational-init
git -C "$D" checkout -q -b rc3-guided-conversational-init   # tip == master
check "T12: first entry records on PLAN target branch (exit 0)" 0 "$(gate_rc "$D" 1)"
check "T12: state recorded" yes \
  "$([ -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"
check "T12: recorded branch == target" "rc3-guided-conversational-init" \
  "$(jq -r '.branch_name' "$D/.harness/branch-gate.json" 2>/dev/null)"
gcommit "$D" B          # feature commit — base stays an ancestor of HEAD
# Second entry (init's record path, allow_record=1) still passes: forward
# advancement only, read-only re-validation, no re-baseline needed.
check "T12: second entry after feature commit still passes (exit 0)" 0 "$(gate_rc "$D" 1)"

# ---- T13: byte-equal over time — subsequent entries never rewrite the state ----
D="$(mktemp -d "$TMPDIR/t13-XXXX")"
ginit "$D"
plan_target "$D" master
gate_rc "$D" 1 >/dev/null    # record (first entry)
S1="$(sha256sum "$D/.harness/branch-gate.json" | awk '{print $1}')"
gate_rc "$D" 1 >/dev/null    # subsequent, allow_record=1
S2="$(sha256sum "$D/.harness/branch-gate.json" | awk '{print $1}')"
check "T13: state file byte-identical after subsequent init (no rewrite)" "$S1" "$S2"

# ---- T14: state-write failure BLOCKS ready (P0-2) ----
D="$(mktemp -d "$TMPDIR/t14-XXXX")"
ginit "$D"
plan_target "$D" master
# A directory at the state path makes the record write fail (jq cannot redirect
# output into a directory), so the gate MUST return 1 (blocked), never a silent
# pass that init.sh would `|| true` away.
mkdir -p "$D/.harness/branch-gate.json"
check "T14: record-write failure blocks first entry (exit 1)" 1 "$(gate_rc "$D" 1)"
check "T14: no state file on blocked record" yes \
  "$([ ! -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"

# ---- T15: target branch resolved from PLAN.json branch_gate.target_branch ----
D="$(mktemp -d "$TMPDIR/t15-XXXX")"
ginit "$D"
plan_target "$D" feature
git -C "$D" checkout -q -b feature
check "T15: PLAN-declared target branch passes (exit 0)" 0 "$(gate_rc "$D" 1)"
check "T15: PLAN-declared target recorded as branch_name" "feature" \
  "$(jq -r '.branch_name' "$D/.harness/branch-gate.json" 2>/dev/null)"
D2="$(mktemp -d "$TMPDIR/t15b-XXXX")"
ginit "$D2"
plan_target "$D2" feature
git -C "$D2" checkout -q -b other
check "T15: PLAN-declared target, wrong branch fails (exit 1)" 1 "$(gate_rc "$D2" 1)"

# ---- T16: byte-equal across a FRESH regeneration (deterministic state) ----
# The recorded state carries no timestamp (P0-13), so a first-entry regeneration
# with identical inputs (same branch, same base SHA) is byte-identical to the
# original generation.
D="$(mktemp -d "$TMPDIR/t16-XXXX")"
ginit "$D"
plan_target "$D" master
gate_rc "$D" 1 >/dev/null    # first generation
S1="$(sha256sum "$D/.harness/branch-gate.json" | awk '{print $1}')"
rm -f "$D/.harness/branch-gate.json"
gate_rc "$D" 1 >/dev/null    # regenerate (first entry again, identical inputs)
S2="$(sha256sum "$D/.harness/branch-gate.json" | awk '{print $1}')"
check "T16: regenerated state byte-identical (deterministic, no timestamp)" "$S1" "$S2"

# ============================================================================
# P0-3 additions (Codex items 6 + 7) — branch gate is FAIL-CLOSED on a missing
# or corrupt PLAN, and REJECTS symlink paths (never follows the link).
# ============================================================================

# ---- T17: missing PLAN.json → FAIL-CLOSED, no state written ----
D="$(mktemp -d "$TMPDIR/t17-XXXX")"
ginit "$D"
check "T17: missing PLAN fails closed (exit 1)" 1 "$(gate_rc "$D" 1)"
check "T17: no state written on missing PLAN" yes \
  "$([ ! -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"

# ---- T18: corrupt PLAN.json (invalid JSON) → FAIL-CLOSED, no state written ----
D="$(mktemp -d "$TMPDIR/t18-XXXX")"
ginit "$D"
mkdir -p "$D/.harness"
printf '{ this is not valid json\n' > "$D/.harness/PLAN.json"
check "T18: corrupt PLAN fails closed (exit 1)" 1 "$(gate_rc "$D" 1)"
check "T18: no state written on corrupt PLAN" yes \
  "$([ ! -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"

# ---- T19: valid JSON PLAN with no target_branch → FAIL-CLOSED, no state ----
D="$(mktemp -d "$TMPDIR/t19-XXXX")"
ginit "$D"
mkdir -p "$D/.harness"
printf '{"version":"2.0.0-rc.3","branch_gate":{}}\n' > "$D/.harness/PLAN.json"
check "T19: PLAN without target_branch fails closed (exit 1)" 1 "$(gate_rc "$D" 1)"
check "T19: no state written on target-less PLAN" yes \
  "$([ ! -f "$D/.harness/branch-gate.json" ] && echo yes || echo no)"

# ---- T20: symlink state file rejected (never follow the link) ----
D="$(mktemp -d "$TMPDIR/t20-XXXX")"
ginit "$D"
plan_target "$D" master
gate_rc "$D" 1 >/dev/null          # record a valid first entry
rm -f "$D/.harness/branch-gate.json"
printf '{"schema_version":1,"branch_name":"master","branch_base_sha":"%s"}\n' \
  "$(gsha "$D")" > "$D/.harness/elsewhere.json"
# `ln -s` on MSYS may silently COPY instead of link — only assert when a REAL
# symlink was produced (a copy is a regular file and would not exercise the
# reject-symlink path, so it must SKIP rather than false-fail).
if ln -s "elsewhere.json" "$D/.harness/branch-gate.json" 2>/dev/null \
   && [ -L "$D/.harness/branch-gate.json" ]; then
  check "T20: symlink state file rejected (exit 1)" 1 "$(gate_rc "$D" 1)"
else
  echo "  [SKIP] T20 symlink state file — real symlink creation unsupported on this platform"
fi

# ---- T21: symlink PLAN.json rejected (never follow the link) ----
D="$(mktemp -d "$TMPDIR/t21-XXXX")"
ginit "$D"
mkdir -p "$D/.harness"
printf '{"version":"2.0.0-rc.3","branch_gate":{"target_branch":"master"}}\n' \
  > "$D/.harness/real-plan.json"
if ln -s "real-plan.json" "$D/.harness/PLAN.json" 2>/dev/null \
   && [ -L "$D/.harness/PLAN.json" ]; then
  check "T21: symlink PLAN rejected (exit 1)" 1 "$(gate_rc "$D" 1)"
else
  echo "  [SKIP] T21 symlink PLAN — real symlink creation unsupported on this platform"
fi

echo ""
echo "Branch-Gate Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
