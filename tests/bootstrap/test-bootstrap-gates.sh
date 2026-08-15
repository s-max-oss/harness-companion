#!/bin/bash
# test-bootstrap-gates.sh — §5-b.5 immutable/mutable gate + readiness bypass
#
# Six BEHAVIOR tests against the REAL repo init.sh in a throwaway sandbox
# harness replica (never against the live repo):
#
#   1. Legal mutable mutation via harness-feature/lock-registry → gate PASSES.
#      A registry status transition made through the canonical state machine
#      (serialized via lock-registry.sh, revision bumped exactly +1) must NOT
#      fail init.sh. The immutable-integrity step only checks the immutable
#      contract files; a canonical runtime mutation is not a contract breach.
#
#   2. Immutable contract change → gate FAILS.
#      Modifying an immutable file (AGENTS.md) must fail init.sh with exit 1
#      and the specific "immutable AGENTS.md diverged from snapshot" diagnostic
#      (deliberate contract update requires snapshot re-capture).
#
#   3. Forged HARNESS_MASTER_CLEAN_CONFIRMED cannot bypass readiness.
#      The env shortcut does not exist in init.sh; readiness master-clean is
#      verified via Git refs (local master == origin/master). Setting the forged
#      variable must produce the SAME exit code and the SAME "[NO] master not
#      clean via refs" verdict as without it, and must never print "Ready to
#      start work.".
#
#   4. NEW verification run via core/harness-verify.sh → gate PASSES.
#      Append-only run log: a NEW run is a legal mutable-namespace path
#      (.harness/logs/runs/, fingerprint-excluded). Nothing is deleted; the
#      newest run is valid and fresh.
#
#   5. NEW reviewer verdict via core/harness-verdict.sh → gate PASSES.
#      Append-only verdict artifact (.harness/reviews/, fingerprint-excluded
#      §5-b.6): a NEW feature verdict via the canonical writer is a legal
#      mutable-namespace path.
#
#   6. Illegal mutable mutation → gate FAILS.
#      The mutable namespace allows the FILE to change, but registry invariants
#      still hold. The canonical tool refuses a WIP=1 violation (exit 4); a
#      DIRECT jq edit that bypasses the tool and forces WIP=2 must fail closed
#      (exit 1) via init.sh's registry validator.
#
# Each sandbox is a git repo (branch master, no origin/master) with a fresh,
# validator-generated run log (core/harness-verify.sh — never hand-crafted) so
# the pristine baseline is exactly the fail-closed readiness state (exit 2).
#
# Exit 0: all gates behave per §5-b.5 / PLAN fail_closed_start_conditions
# Exit 1: at least one gate misbehaves

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PASSED=0
FAILED=0

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

t_pass() { printf "${GREEN}PASS${NC} %s\n" "$1"; PASSED=$((PASSED + 1)); }
t_fail() { printf "${RED}FAIL${NC} %s — %s\n" "$1" "${2:-}"; FAILED=$((FAILED + 1)); }

# ---- cumulative temp cleanup (mirrors tests/release/test-negative-gates.sh) --
cleanup_dirs=()
add_cleanup() { cleanup_dirs+=("$1"); }
cleanup_all() {
  local d
  for d in "${cleanup_dirs[@]}"; do
    [ -n "$d" ] && rm -rf -- "$d" 2>/dev/null
  done
}
trap cleanup_all EXIT

# ---- build a throwaway self-host harness replica -----------------------------
# Copies the REAL core/ (canonical validators + verify runner), the contract
# files, and constructs a self-consistent snapshot + Brief. Commits everything
# on branch master (no origin/master), then generates a fresh run log via the
# REAL core/harness-verify.sh. Prints the sandbox path on success.
build_sandbox() {
  local sb
  sb="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp failed" >&2; return 1; }
  # NOTE: do NOT add_cleanup here — build_sandbox runs in a command-substitution
  # SUBSHELL ($(build_sandbox)), so appending to cleanup_dirs inside it mutates a
  # subshell copy that is discarded on return. Callers register the sandbox path
  # (add_cleanup "$SBn") after the subshell returns instead.

  # Canonical validators + verify runner: use the REAL repo core.
  cp -R "$ROOT_DIR/core" "$sb/core" || { echo "FATAL: core copy failed" >&2; return 1; }
  # scripts/ holds a trivial script so the config's syntax-check command glob
  # (`bash -n core/lib/*.sh scripts/*.sh`) expands and passes in the sandbox.
  mkdir -p "$sb/scripts"
  printf '#!/bin/bash\n# sandbox dummy for syntax-check glob\ntrue\n' > "$sb/scripts/_dummy.sh"

  # Self-host contract + runtime files (copies of the real ones).
  mkdir -p "$sb/.harness/logs/runs"
  # Self-contained sandbox config: a trivial syntax-check command that passes
  # inside the sandbox. The REAL repo config now runs the full suite
  # (bash tests/run-all.sh), which requires tests/ — absent here and irrelevant
  # to the §5-b.5 gate this harness replica exercises. Generate a valid, fast
  # command (matching the scripts/_dummy.sh glob below) rather than copy the
  # full-suite config (which would fail for want of tests/).
  cat > "$sb/.harness/config.json" <<'EOF' || return 1
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {
        "id": "bash-syntax",
        "command": ["bash", "-c", "bash -n core/lib/*.sh scripts/*.sh"],
        "required_for_passing": true,
        "timeout_seconds": 3600,
        "command_origin": "configured",
        "confirmation": "not_required"
      }
    ]
  }
}
EOF
  cp "$ROOT_DIR/feature_list.json"     "$sb/feature_list.json"     || return 1
  cp "$ROOT_DIR/AGENTS.md"             "$sb/AGENTS.md"             || return 1
  cp "$ROOT_DIR/CLAUDE.md"             "$sb/CLAUDE.md"             || return 1
  cp "$ROOT_DIR/init.sh"               "$sb/init.sh"               || return 1
  printf '# sandbox progress\n' > "$sb/claude-progress.md"

  # Snapshot: record THIS sandbox's immutable file shas (schema_version 1).
  local cfg_sha ag_sha cl_sha init_sha
  cfg_sha="$(sha256sum "$sb/.harness/config.json" | awk '{print $1}')"
  ag_sha="$(sha256sum "$sb/AGENTS.md" | awk '{print $1}')"
  cl_sha="$(sha256sum "$sb/CLAUDE.md" | awk '{print $1}')"
  init_sha="$(sha256sum "$sb/init.sh" | awk '{print $1}')"
  jq -n --arg cfg "$cfg_sha" --arg ag "$ag_sha" --arg cl "$cl_sha" --arg init "$init_sha" '{
    captured_from_git_rev: "sandbox",
    schema_version: 1,
    source_version: "2.0.0-rc.2",
    templates: {
      ".harness/config.json": { sha256: $cfg, source: "templates/.harness/config.json.generic.example" },
      "AGENTS.md": { sha256: $ag, source: "templates/AGENTS.md" },
      "CLAUDE.md": { sha256: $cl, source: "templates/CLAUDE.md" },
      "init.sh": { sha256: $init, source: "templates/env-init.sh" }
    }
  }' > "$sb/.harness/.template-snapshot.json" || return 1

  # PLAN is committed with the baseline so a ready-sandbox (T7) can declare a
  # machine-readable branch_gate.target_branch without leaving a dirty diff.
  # SANDBOX_PLAN_JSON is set via env prefix by callers that need a richer PLAN;
  # the default declares target_branch=master (this sandbox's branch), so the
  # branch-gate name check is SATISFIED on the default sandbox (P0-3: a PLAN
  # without branch_gate.target_branch now FAILS CLOSED, so the default must name
  # one rather than rely on the old "empty target = no name check" behavior).
  # Codex r4 defect 5: verdict_validate_record requires PLAN.json to declare the
  # feature_id in some .phases[].features[] entry, so the default PLAN must
  # declare F-CONV-01 (and F-CONV-02 — T1/T6 refer to it) in phase 1.
  local plan_json="${SANDBOX_PLAN_JSON:-}"
  if [ -z "$plan_json" ]; then
    plan_json='{ "version": "2.0.0-rc.3", "branch_gate": { "target_branch": "master" }, "phases": [ { "phase": 1, "features": [ "F-CONV-01", "F-CONV-02" ] } ] }'
  fi
  printf '%s\n' "$plan_json" > "$sb/.harness/PLAN.json" || return 1

  # git repo on branch master; origin/master absent → readiness master-clean
  # via refs is NOT satisfied (exactly what test 3 relies on).
  git init -q "$sb" || return 1
  git -C "$sb" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1 || true
  git -C "$sb" add -A >/dev/null 2>&1 || return 1
  git -C "$sb" -c user.name=test -c user.email=test@example.com commit -q -m "sandbox baseline" || {
    echo "FATAL: sandbox baseline commit failed" >&2; return 1; }

  # Brief triple (PROJECT_BRIEF.json + PROJECT_BRIEF.md + .template-snapshot.json)
  # must be self-consistent per core/lib/brief-integrity.sh (init.sh check 9):
  #   - PROJECT_BRIEF.json: schema_version == 1, captured_from_git_rev == a real
  #     Git rev (HEAD of the baseline commit), source_version == ACTUAL generator
  #     v2.0.0-rc.2 (never rc.3), template_manifest_digest == sha256(snapshot).
  #   - PROJECT_BRIEF.md: header parity tokens schema_version / source_version and
  #     a `git rev <hex>` token that PREFIXES the JSON captured_from_git_rev.
  # The Brief is committed in a SECOND commit so the working tree is clean when
  # the run log is generated last (Axis3 records that HEAD; fingerprint clean).
  local snap_sha head_rev
  snap_sha="$(sha256sum "$sb/.harness/.template-snapshot.json" | awk '{print $1}')"
  head_rev="$(git -C "$sb" rev-parse HEAD)"
  jq -n --arg rev "$head_rev" --arg digest "$snap_sha" '{
    schema_version: 1,
    captured_from_git_rev: $rev,
    source_version: "2.0.0-rc.2",
    template_manifest_digest: $digest
  }' > "$sb/.harness/PROJECT_BRIEF.json" || return 1
  {
    printf '<!-- generated from PROJECT_BRIEF.json schema_version=1 source_version=2.0.0-rc.2 -->\n'
    printf '<!-- DO NOT EDIT — regenerate from JSON. On mismatch, JSON is authoritative. -->\n'
    printf '<!-- git rev %s -->\n' "$head_rev"
    printf '\n'
    printf '# Project Brief — sandbox harness replica (advisory test fixture)\n'
  } > "$sb/.harness/PROJECT_BRIEF.md" || return 1
  git -C "$sb" add .harness/PROJECT_BRIEF.json .harness/PROJECT_BRIEF.md >/dev/null 2>&1 || return 1
  git -C "$sb" -c user.name=test -c user.email=test@example.com commit -q -m "sandbox brief triple" || {
    echo "FATAL: sandbox brief commit failed" >&2; return 1; }

  # Fresh run log generated by the REAL verify runner (never hand-crafted).
  # Generated LAST, after the final commit, so the recorded vcs_revision equals
  # current HEAD and the workspace fingerprint stays clean.
  ( cd "$sb" && bash core/harness-verify.sh F-CONV-01 . >/dev/null 2>&1 ) || {
    echo "FATAL: sandbox run-log generation via harness-verify.sh failed" >&2; return 1; }

  printf '%s' "$sb"
}

# ============================================================================
# IMPORTANT (maintainers): OUT files MUST live OUTSIDE the sandbox git tree.
# build_sandbox() commits a baseline and generates a fresh run log, so the
# pristine workspace fingerprint is recorded as clean. Any file written inside
# the sandbox (e.g. `> "$SB1/t1.out"`) becomes an untracked in-scope file that
# enters the workspace fingerprint — making Axis1 stale even on a pristine
# sandbox and failing init.sh for the WRONG reason. Sibling paths like
# "${SB1}.t1.out" keep the tree clean and the staleness check meaningful.
echo "=== T1: legal mutable mutation via harness-feature/lock-registry passes the §5-b.5 gate ==="
SB1="$(build_sandbox)" || exit 1
add_cleanup "$SB1"
OUT1="${SB1}.t1.out"
add_cleanup "$OUT1"
(
  cd "$SB1" || exit 1
  # LEGAL mutable runtime mutation: transition F-CONV-01 → in_progress through
  # the canonical state machine. harness-feature.sh serializes the read-modify-
  # write via lock-registry.sh and bumps `revision` by exactly +1. The registry
  # is fingerprint-excluded → init.sh must NOT fail on it.
  REV_BEFORE="$(jq -r '.revision' feature_list.json)"
  MUT_OUT="$(bash core/harness-feature.sh status . F-CONV-01 in_progress 2>&1)"
  echo "MUT_RC=$?" > "$OUT1"
  echo "REV_BEFORE=$REV_BEFORE" >> "$OUT1"
  echo "REV_AFTER=$(jq -r '.revision' feature_list.json)" >> "$OUT1"
  echo "F1_STATUS=$(jq -r --arg id F-CONV-01 '.features[] | select(.id == $id) | .status' feature_list.json)" >> "$OUT1"
  bash init.sh >> "$OUT1" 2>&1
  echo "RC=$?" >> "$OUT1"
)
T1_MUT_RC="$(grep -oE '^MUT_RC=[0-9]+$' "$OUT1" | cut -d= -f2)"
T1_REV_BEFORE="$(grep -oE '^REV_BEFORE=[0-9]+$' "$OUT1" | cut -d= -f2)"
T1_REV_AFTER="$(grep -oE '^REV_AFTER=[0-9]+$' "$OUT1" | cut -d= -f2)"
T1_F1="$(grep -oE '^F1_STATUS=.*$' "$OUT1" | cut -d= -f2-)"
T1_RC="$(grep -oE '^RC=[0-9]+$' "$OUT1" | cut -d= -f2)"
T1_OUT="$(grep -vE '^RC=|^MUT_RC=|^REV_BEFORE=|^REV_AFTER=|^F1_STATUS=' "$OUT1")"
if [ "$T1_MUT_RC" = "0" ]; then
  t_pass "T1: harness-feature.sh mutation succeeded (rc 0)"
else
  t_fail "T1: harness-feature.sh status rc should be 0, got '$T1_MUT_RC'" "$(printf '%s' "$T1_OUT" | grep -i 'fail\|error' | head -3)"
fi
if [ -n "$T1_REV_BEFORE" ] && [ "$T1_REV_AFTER" = "$((T1_REV_BEFORE + 1))" ]; then
  t_pass "T1: revision bumped exactly +1 via lock-registry ($T1_REV_BEFORE → $T1_REV_AFTER)"
else
  t_fail "T1: revision should be +1 ($T1_REV_BEFORE → $T1_REV_AFTER)"
fi
if [ "$T1_F1" = "in_progress" ]; then
  t_pass "T1: F-CONV-01 transitioned not_started → in_progress"
else
  t_fail "T1: F-CONV-01 status should be in_progress, got '$T1_F1'"
fi
if [ "$T1_RC" = "2" ]; then
  t_pass "T1: legal mutation → exit 2 (checks passed, start conditions unmet)"
else
  t_fail "T1: legal mutation should exit 2, got '$T1_RC'" "$(printf '%s' "$T1_OUT" | grep -i 'fail\|diverged' | head -3)"
fi
if printf '%s' "$T1_OUT" | grep -qF "Init checks passed."; then
  t_pass "T1: init checks passed on legal mutation"
else
  t_fail "T1: expected 'Init checks passed.'"
fi
# Match only an immutable DIVERGENCE (init.sh prints "FAIL: immutable X diverged
# from snapshot"). The OK lines ("OK: immutable X matches snapshot") must NOT trip
# this — a bare "immutable " grep would false-positive on them.
if printf '%s' "$T1_OUT" | grep -qF "FAIL: immutable"; then
  t_fail "T1: legal mutation must not report immutable divergence"
else
  t_pass "T1: no immutable divergence reported for a legal mutation"
fi

echo ""
echo "=== T2: immutable contract change fails the §5-b.5 gate ==="
SB2="$(build_sandbox)" || exit 1
add_cleanup "$SB2"
OUT2="${SB2}.t2.out"
add_cleanup "$OUT2"
(
  cd "$SB2" || exit 1
  # Immutable contract change: append to AGENTS.md (fingerprint-relevant AND
  # immutable). Regenerate a fresh run log so staleness stays green and the
  # ONLY failure is the §5-b.5 immutable-integrity gate.
  printf '\n# CONTRACT-CHANGE-PROBE\n' >> AGENTS.md
  bash core/harness-verify.sh F-CONV-01 . >/dev/null 2>&1
  bash init.sh > "$OUT2" 2>&1
  echo "RC=$?" >> "$OUT2"
)
T2_RC="$(grep -oE '^RC=[0-9]+$' "$OUT2" | cut -d= -f2)"
T2_OUT="$(grep -v '^RC=' "$OUT2")"
if [ "$T2_RC" = "1" ]; then
  t_pass "T2: immutable change → exit 1 (init/validator failure)"
else
  t_fail "T2: immutable change should exit 1, got '$T2_RC'" "$(printf '%s' "$T2_OUT" | grep -i 'fail\|diverged' | head -3)"
fi
if printf '%s' "$T2_OUT" | grep -qF "immutable AGENTS.md diverged from snapshot"; then
  t_pass "T2: immutable divergence diagnostic emitted"
else
  t_fail "T2: expected 'immutable AGENTS.md diverged from snapshot'"
fi
# Match only a staleness FAILURE (init.sh prints "FAIL: run ... is stale ...").
# The section header "[6/9] Three-axis staleness" contains the substring
# "is stale" — a bare "is stale" grep would false-positive on it.
if printf '%s' "$T2_OUT" | grep -qF "FAIL: run "; then
  t_fail "T2: failure must be the immutable gate, not staleness (run log was regenerated)"
else
  t_pass "T2: failure isolated to the immutable gate (staleness fresh)"
fi

echo ""
echo "=== T3: forged HARNESS_MASTER_CLEAN_CONFIRMED cannot bypass readiness ==="
SB3="$(build_sandbox)" || exit 1
add_cleanup "$SB3"
OUT3="${SB3}.t3.out"
add_cleanup "$OUT3"
(
  cd "$SB3" || exit 1
  HARNESS_MASTER_CLEAN_CONFIRMED=1 bash init.sh > "$OUT3" 2>&1
  echo "RC=$?" >> "$OUT3"
)
T3_RC="$(grep -oE '^RC=[0-9]+$' "$OUT3" | cut -d= -f2)"
T3_OUT="$(grep -v '^RC=' "$OUT3")"
if [ "$T3_RC" = "2" ]; then
  t_pass "T3: forged env var → still exit 2 (start conditions unmet)"
else
  t_fail "T3: forged env var should still exit 2, got '$T3_RC'" "$(printf '%s' "$T3_OUT" | grep -i 'ready\|master\|\[NO\]' | head -3)"
fi
if printf '%s' "$T3_OUT" | grep -qF "[NO] master not clean via refs"; then
  t_pass "T3: master-clean evaluated via Git refs ([NO] — no origin/master in sandbox)"
else
  t_fail "T3: expected '[NO] master not clean via refs'"
fi
if printf '%s' "$T3_OUT" | grep -qF "Ready to start work."; then
  t_fail "T3: forged env var must never print 'Ready to start work.'"
else
  t_pass "T3: no 'Ready to start work.' despite forged env var"
fi
# Static assertion: the shortcut must not exist in init.sh at all. The header
# comment may mention the env var name in prose, so we grep only for an
# EXECUTABLE reference (parameter expansion = init.sh actually reading it).
if grep -qE '\$\{HARNESS_MASTER_CLEAN_CONFIRMED' "$ROOT_DIR/init.sh"; then
  t_fail "T3-static" "init.sh still reads HARNESS_MASTER_CLEAN_CONFIRMED (bypass surface)"
else
  t_pass "T3-static: init.sh never reads a HARNESS_MASTER_CLEAN_CONFIRMED env var"
fi

# Baseline parity: without the env var, exit code and master verdict are identical.
OUT3B="${SB3}.t3b.out"
add_cleanup "$OUT3B"
(
  cd "$SB3" || exit 1
  bash init.sh > "$OUT3B" 2>&1
  echo "RC=$?" >> "$OUT3B"
)
T3B_RC="$(grep -oE '^RC=[0-9]+$' "$OUT3B" | cut -d= -f2)"
T3B_OUT="$(grep -v '^RC=' "$OUT3B")"
if [ "$T3_RC" = "$T3B_RC" ]; then
  t_pass "T3: exit code identical with and without forged var ($T3_RC == $T3B_RC)"
else
  t_fail "T3: exit code differs — with var $T3_RC, without var $T3B_RC"
fi

echo ""
echo "=== T4: NEW verification run via core/harness-verify.sh is a legal mutable mutation ==="
SB4="$(build_sandbox)" || exit 1
add_cleanup "$SB4"
OUT4="${SB4}.t4.out"
add_cleanup "$OUT4"
(
  cd "$SB4" || exit 1
  # Append-only run log: a NEW run generated by the canonical runner is a legal
  # mutable-namespace path (.harness/logs/runs/ is fingerprint-excluded). Nothing
  # is deleted; the newest run is valid and fresh → init.sh exits 2, not 1.
  RUNS_BEFORE="$(ls .harness/logs/runs/*.ndjson 2>/dev/null | wc -l | tr -d ' ')"
  echo "RUNS_BEFORE=$RUNS_BEFORE" > "$OUT4"
  bash core/harness-verify.sh F-CONV-01 . >/dev/null 2>&1
  echo "NEW_RUN_RC=$?" >> "$OUT4"
  RUNS_AFTER="$(ls .harness/logs/runs/*.ndjson 2>/dev/null | wc -l | tr -d ' ')"
  echo "RUNS_AFTER=$RUNS_AFTER" >> "$OUT4"
  bash init.sh >> "$OUT4" 2>&1
  echo "RC=$?" >> "$OUT4"
)
T4_NEW_RC="$(grep -oE '^NEW_RUN_RC=[0-9]+$' "$OUT4" | cut -d= -f2)"
T4_BEFORE="$(grep -oE '^RUNS_BEFORE=[0-9]+$' "$OUT4" | cut -d= -f2)"
T4_AFTER="$(grep -oE '^RUNS_AFTER=[0-9]+$' "$OUT4" | cut -d= -f2)"
T4_RC="$(grep -oE '^RC=[0-9]+$' "$OUT4" | cut -d= -f2)"
T4_OUT="$(grep -vE '^RC=|^NEW_RUN_RC=|^RUNS_BEFORE=|^RUNS_AFTER=' "$OUT4")"
if [ "$T4_NEW_RC" = "0" ]; then
  t_pass "T4: new run generated via harness-verify.sh (rc 0)"
else
  t_fail "T4: harness-verify.sh rc should be 0, got '$T4_NEW_RC'"
fi
if [ "$T4_AFTER" = "$((T4_BEFORE + 1))" ]; then
  t_pass "T4: exactly one NEW run path appended (append-only, $T4_BEFORE → $T4_AFTER)"
else
  t_fail "T4: run count should grow by 1 ($T4_BEFORE → $T4_AFTER)"
fi
if [ "$T4_RC" = "2" ]; then
  t_pass "T4: new run → exit 2 (checks passed, start conditions unmet)"
else
  t_fail "T4: new run should exit 2, got '$T4_RC'" "$(printf '%s' "$T4_OUT" | grep -i 'fail\|stale\|diverged' | head -3)"
fi
if printf '%s' "$T4_OUT" | grep -qF "Init checks passed."; then
  t_pass "T4: init checks passed on new run"
else
  t_fail "T4: expected 'Init checks passed.'"
fi
# Match only a staleness FAILURE (init.sh prints "FAIL: run ... is stale ...").
# The section header "[6/9] Three-axis staleness" contains "is stale" in prose —
# anchor on the FAIL prefix to avoid a false positive.
if printf '%s' "$T4_OUT" | grep -qF "FAIL: run "; then
  t_fail "T4: newest run must be fresh, not stale"
else
  t_pass "T4: newest run fresh on all 3 axes"
fi

echo ""
echo "=== T5: NEW reviewer verdict via core/harness-verdict.sh is a legal mutable mutation ==="
SB5="$(build_sandbox)" || exit 1
add_cleanup "$SB5"
OUT5="${SB5}.t5.out"
add_cleanup "$OUT5"
(
  cd "$SB5" || exit 1
  # Append-only verdict artifact (.harness/reviews/ is fingerprint-excluded §5-b.6):
  # a NEW feature verdict via the canonical writer is a legal mutable-namespace
  # path → init.sh exits 2, not 1.
  HEAD_SHA="$(git rev-parse HEAD)"
  bash core/harness-verdict.sh append . feature F-CONV-01 \
    --verdict FAIL --base "$HEAD_SHA" --head "$HEAD_SHA" --phase 1 \
    --host manual --checked spec-a --reason "sandbox new-verdict test" >/dev/null 2>&1
  echo "VERDICT_RC=$?" > "$OUT5"
  echo "VERDICT_FILE=$([ -f .harness/reviews/feature/F-CONV-01.jsonl ] && echo yes || echo no)" >> "$OUT5"
  echo "VERDICT_VALID=$(bash core/harness-verdict.sh validate . feature F-CONV-01 2>/dev/null | jq -r '.valid')" >> "$OUT5"
  bash init.sh >> "$OUT5" 2>&1
  echo "RC=$?" >> "$OUT5"
)
T5_VERDICT_RC="$(grep -oE '^VERDICT_RC=[0-9]+$' "$OUT5" | cut -d= -f2)"
T5_FILE="$(grep -oE '^VERDICT_FILE=.*$' "$OUT5" | cut -d= -f2-)"
T5_VALID="$(grep -oE '^VERDICT_VALID=.*$' "$OUT5" | cut -d= -f2-)"
T5_RC="$(grep -oE '^RC=[0-9]+$' "$OUT5" | cut -d= -f2)"
T5_OUT="$(grep -vE '^RC=|^VERDICT_RC=|^VERDICT_FILE=|^VERDICT_VALID=' "$OUT5")"
if [ "$T5_VERDICT_RC" = "0" ]; then
  t_pass "T5: verdict appended via harness-verdict.sh (rc 0)"
else
  t_fail "T5: harness-verdict.sh append rc should be 0, got '$T5_VERDICT_RC'"
fi
if [ "$T5_FILE" = "yes" ]; then
  t_pass "T5: new verdict artifact created (.harness/reviews/feature/F-CONV-01.jsonl)"
else
  t_fail "T5: verdict artifact not created"
fi
if [ "$T5_VALID" = "true" ]; then
  t_pass "T5: appended verdict validates (repo validator)"
else
  t_fail "T5: verdict validator did not report .valid=true (got '$T5_VALID')"
fi
if [ "$T5_RC" = "2" ]; then
  t_pass "T5: new verdict → exit 2 (checks passed, start conditions unmet)"
else
  t_fail "T5: new verdict should exit 2, got '$T5_RC'" "$(printf '%s' "$T5_OUT" | grep -i 'fail\|stale\|diverged' | head -3)"
fi
if printf '%s' "$T5_OUT" | grep -qF "Init checks passed."; then
  t_pass "T5: init checks passed on new verdict"
else
  t_fail "T5: expected 'Init checks passed.'"
fi

echo ""
echo "=== T6: illegal mutable mutation fails (bypassing harness-feature/lock-registry) ==="
SB6="$(build_sandbox)" || exit 1
add_cleanup "$SB6"
OUT6="${SB6}.t6.out"
add_cleanup "$OUT6"
(
  cd "$SB6" || exit 1
  # 1. The canonical tool allows the FIRST promotion (not_started → in_progress).
  bash core/harness-feature.sh status . F-CONV-01 in_progress >/dev/null 2>&1
  echo "FIRST_RC=$?" > "$OUT6"
  # 2. The canonical tool REFUSES the SECOND promotion — WIP=1 → exit 4.
  bash core/harness-feature.sh status . F-CONV-02 in_progress >/dev/null 2>&1
  echo "SECOND_RC=$?" >> "$OUT6"
  # 3. A DIRECT edit bypasses the tool and forces WIP=2. The mutable namespace
  #    allows the FILE to change — but registry invariants are enforced by
  #    init.sh's validator, so the bypass must FAIL closed (exit 1).
  jq '(.features[] | select(.id == "F-CONV-01") | .status) = "in_progress"
     | (.features[] | select(.id == "F-CONV-02") | .status) = "in_progress"' \
     feature_list.json > feature_list.json.tmp && mv feature_list.json.tmp feature_list.json
  echo "DIRECT_RC=$?" >> "$OUT6"
  bash init.sh >> "$OUT6" 2>&1
  echo "RC=$?" >> "$OUT6"
)
T6_FIRST="$(grep -oE '^FIRST_RC=[0-9]+$' "$OUT6" | cut -d= -f2)"
T6_SECOND="$(grep -oE '^SECOND_RC=[0-9]+$' "$OUT6" | cut -d= -f2)"
T6_DIRECT="$(grep -oE '^DIRECT_RC=[0-9]+$' "$OUT6" | cut -d= -f2)"
T6_RC="$(grep -oE '^RC=[0-9]+$' "$OUT6" | cut -d= -f2)"
T6_OUT="$(grep -vE '^RC=|^FIRST_RC=|^SECOND_RC=|^DIRECT_RC=' "$OUT6")"
if [ "$T6_FIRST" = "0" ]; then
  t_pass "T6: first promotion via tool succeeds (rc 0)"
else
  t_fail "T6: first promotion rc should be 0, got '$T6_FIRST'"
fi
if [ "$T6_SECOND" = "4" ]; then
  t_pass "T6: second promotion refused by tool (rc 4 — WIP=1)"
else
  t_fail "T6: second promotion rc should be 4 (WIP=1), got '$T6_SECOND'"
fi
if [ "$T6_DIRECT" = "0" ]; then
  t_pass "T6: direct jq edit succeeds — the bypass exists"
else
  t_fail "T6: direct jq edit should succeed (that is the bypass being tested)"
fi
if [ "$T6_RC" = "1" ]; then
  t_pass "T6: bypass → exit 1 (init/validator failure)"
else
  t_fail "T6: illegal mutation should exit 1, got '$T6_RC'" "$(printf '%s' "$T6_OUT" | grep -i 'WIP\|registry\|fail' | head -3)"
fi
# The WIP invariant is enforced twice: validate_feature_registry (check 3) and
# the init.sh WIP=1 check (check 4). Either diagnostic proves the gate caught it.
if printf '%s' "$T6_OUT" | grep -qE "WIP limit exceeded|WIP=1 violated"; then
  t_pass "T6: WIP invariant diagnostic emitted (registry validator / WIP check)"
else
  t_fail "T6: expected a WIP invariant diagnostic in init.sh output"
fi

echo ""
echo "=== T7: first init READY → feature commit → second init still READY (P0-2 branch gate) ==="
# The user-level P0-2 contract exercised through the REAL init.sh, not just the
# lib: a sandbox whose PLAN declares branch_gate.target_branch and where ALL
# five fail_closed_start_conditions hold must reach READY (exit 0) on the FIRST
# init, recording .harness/branch-gate.json exactly once; a feature commit on
# the target branch plus a regenerated run log (Axis3 fresh) must keep the
# SECOND init READY (forward advancement from the recorded branch_base_sha).
# Also proves a successful init does NOT self-pollute the workspace fingerprint
# (branch-gate.json is BUILTIN_EXCLUDES → fingerprint still clean after the
# record) and does NOT re-stamp the gate state (state file byte-identical).
SANDBOX_PLAN_JSON='{ "version": "2.0.0-rc.3", "branch_gate": { "target_branch": "rc3-guided-conversational-init" } }'
SB7="$(SANDBOX_PLAN_JSON="$SANDBOX_PLAN_JSON" build_sandbox)" || exit 1
add_cleanup "$SB7"
OUT7="${SB7}.t7.out"
add_cleanup "$OUT7"
# Bare origin must live OUTSIDE the sandbox git tree (sibling path) so the
# master-clean-via-refs condition is satisfiable without an external network.
BARE7="${SB7}.bare"
add_cleanup "$BARE7"
(
  cd "$SB7" || exit 1
  # Make every fail_closed_start_condition hold.
  git branch distribution/rc2-hardening master >/dev/null 2>&1    # cond 1: rc.2 merged
  git tag v2.0.0-rc.2 >/dev/null 2>&1                             # cond 2: rc.2 tag
  git init -q --bare "$BARE7" 2>/dev/null
  git remote add origin "$BARE7" 2>/dev/null
  git push -q -u origin master >/dev/null 2>&1                    # cond 4: origin/master == master
  echo "PUSH_RC=$?" > "$OUT7"
  git checkout -q -b rc3-guided-conversational-init master        # cond 5: target branch at master tip
  echo "CHECKOUT_RC=$?" >> "$OUT7"
  echo "CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD)" >> "$OUT7"

  # FIRST init: all 9 checks + all 5 start conditions pass → READY (exit 0).
  # HARNESS_PRE_RELEASE_CONFIRMED=1 is the in-session manual gate (cond 3).
  HARNESS_PRE_RELEASE_CONFIRMED=1 bash init.sh >> "$OUT7" 2>&1
  echo "RC1=$?" >> "$OUT7"
  echo "GATE_FILE=$([ -f .harness/branch-gate.json ] && echo yes || echo no)" >> "$OUT7"
  echo "STATE1=$(sha256sum .harness/branch-gate.json 2>/dev/null | awk '{print $1}')" >> "$OUT7"
  # A successful init must NOT self-pollute the fingerprint: branch-gate.json is
  # now untracked, yet the fingerprint must still read clean (BUILTIN_EXCLUDES).
  # shellcheck source=../lib/workspace-fingerprint.sh
  . core/lib/workspace-fingerprint.sh
  echo "FP1=$(compute_workspace_fingerprint .)" >> "$OUT7"

  # Feature commit on the target branch, then regenerate the run log so Axis3
  # (vcs_revision) is fresh — otherwise staleness would mask the gate result.
  printf 'feature marker\n' > src-marker.txt
  git add -A >/dev/null 2>&1
  git -c user.name=test -c user.email=test@example.com commit -q -m "feature commit"
  echo "COMMIT_RC=$?" >> "$OUT7"
  bash core/harness-verify.sh F-CONV-01 . >/dev/null 2>&1
  echo "VERIFY_RC=$?" >> "$OUT7"

  # SECOND init: branch gate must still pass (read-only re-validation, forward
  # advancement from recorded base; target branch unchanged) → still READY.
  HARNESS_PRE_RELEASE_CONFIRMED=1 bash init.sh >> "$OUT7" 2>&1
  echo "RC2=$?" >> "$OUT7"
  echo "STATE2=$(sha256sum .harness/branch-gate.json 2>/dev/null | awk '{print $1}')" >> "$OUT7"
)
T7_PUSH="$(grep -oE '^PUSH_RC=[0-9]+$' "$OUT7" | cut -d= -f2)"
T7_CHECKOUT="$(grep -oE '^CHECKOUT_RC=[0-9]+$' "$OUT7" | cut -d= -f2)"
T7_CUR="$(grep -oE '^CUR_BRANCH=.*$' "$OUT7" | cut -d= -f2-)"
T7_RC1="$(grep -oE '^RC1=[0-9]+$' "$OUT7" | cut -d= -f2)"
T7_GATE="$(grep -oE '^GATE_FILE=.*$' "$OUT7" | cut -d= -f2-)"
T7_FP1="$(grep -oE '^FP1=.*$' "$OUT7" | cut -d= -f2-)"
T7_COMMIT="$(grep -oE '^COMMIT_RC=[0-9]+$' "$OUT7" | cut -d= -f2)"
T7_VERIFY="$(grep -oE '^VERIFY_RC=[0-9]+$' "$OUT7" | cut -d= -f2)"
T7_RC2="$(grep -oE '^RC2=[0-9]+$' "$OUT7" | cut -d= -f2)"
T7_S1="$(grep -oE '^STATE1=[0-9a-f]+$' "$OUT7" | cut -d= -f2)"
T7_S2="$(grep -oE '^STATE2=[0-9a-f]+$' "$OUT7" | cut -d= -f2)"
T7_OUT="$(grep -vE '^PUSH_RC=|^CHECKOUT_RC=|^CUR_BRANCH=|^RC1=|^GATE_FILE=|^FP1=|^COMMIT_RC=|^VERIFY_RC=|^RC2=|^STATE1=|^STATE2=' "$OUT7")"
if [ "$T7_PUSH" = "0" ] && [ "$T7_CHECKOUT" = "0" ] && [ "$T7_CUR" = "rc3-guided-conversational-init" ]; then
  t_pass "T7: sandbox readiness setup (push rc 0, checkout rc 0, branch=$T7_CUR)"
else
  t_fail "T7: readiness setup failed (push=$T7_PUSH checkout=$T7_CHECKOUT branch=$T7_CUR)"
fi
if [ "$T7_RC1" = "0" ]; then
  t_pass "T7: first init reaches READY (exit 0, all checks + start conditions)"
else
  t_fail "T7: first init should exit 0, got '$T7_RC1'" "$(printf '%s' "$T7_OUT" | grep -i 'fail\|\[NO\]\|not ready' | head -3)"
fi
if [ "$T7_GATE" = "yes" ]; then
  t_pass "T7: branch-gate state recorded by first init (.harness/branch-gate.json)"
else
  t_fail "T7: first init must record .harness/branch-gate.json"
fi
if [ "$T7_FP1" = "clean" ]; then
  t_pass "T7: fingerprint clean after gate record (successful init does not self-pollute Axis1)"
else
  t_fail "T7: fingerprint should be clean after gate record, got '$T7_FP1'" "$(printf '%s' "$T7_OUT" | grep -i 'stale\|fingerprint' | head -3)"
fi
if [ "$T7_COMMIT" = "0" ] && [ "$T7_VERIFY" = "0" ]; then
  t_pass "T7: feature commit + run-log regeneration succeeded (rc 0)"
else
  t_fail "T7: feature commit (rc $T7_COMMIT) / run regeneration (rc $T7_VERIFY) failed"
fi
if [ "$T7_RC2" = "0" ]; then
  t_pass "T7: SECOND init after feature commit still READY (branch-gate forward advancement)"
else
  t_fail "T7: second init should exit 0 after feature commit, got '$T7_RC2'" "$(printf '%s' "$T7_OUT" | grep -i 'fail\|stale\|\[NO\]\|not ready' | head -3)"
fi
if [ -n "$T7_S1" ] && [ "$T7_S1" = "$T7_S2" ]; then
  t_pass "T7: gate state byte-identical across inits (no timestamp churn, $T7_S1)"
else
  t_fail "T7: gate state changed between inits (STATE1=$T7_S1 STATE2=$T7_S2)"
fi
if [ "$(printf '%s' "$T7_OUT" | grep -cF 'Ready to start work.')" = "2" ]; then
  t_pass "T7: both inits printed 'Ready to start work.'"
else
  t_fail "T7: expected 'Ready to start work.' exactly twice (once per init)"
fi

echo ""
echo "=== T8: MISSING staleness validator fails closed (P0-6) ==="
# A run id exists in the pristine sandbox (baseline generated one), so a MISSING
# core/lib/staleness.sh is a FAILURE (exit 1), never a SKIP. Only the sandbox's
# throwaway core/ copy is mutated — the real repo core/ is untouched.
SB8="$(build_sandbox)" || exit 1
add_cleanup "$SB8"
OUT8="${SB8}.t8.out"
add_cleanup "$OUT8"
(
  cd "$SB8" || exit 1
  rm -f core/lib/staleness.sh
  echo "STALENESS_LIB_MISSING=$([ ! -f core/lib/staleness.sh ] && echo yes || echo no)" > "$OUT8"
  bash init.sh >> "$OUT8" 2>&1
  echo "RC=$?" >> "$OUT8"
)
T8_MISSING="$(grep -oE '^STALENESS_LIB_MISSING=.*$' "$OUT8" | cut -d= -f2-)"
T8_RC="$(grep -oE '^RC=[0-9]+$' "$OUT8" | cut -d= -f2)"
T8_OUT="$(grep -vE '^RC=|^STALENESS_LIB_MISSING=' "$OUT8")"
if [ "$T8_MISSING" = "yes" ]; then
  t_pass "T8: sandbox staleness lib removed (the failure being tested)"
else
  t_fail "T8: staleness lib should be missing in the sandbox"
fi
if [ "$T8_RC" = "1" ]; then
  t_pass "T8: missing staleness validator → exit 1 (fail-closed, never a skip)"
else
  t_fail "T8: missing staleness validator should exit 1, got '$T8_RC'" "$(printf '%s' "$T8_OUT" | grep -i 'fail\|stale\|skip' | head -3)"
fi
if printf '%s' "$T8_OUT" | grep -qF "core/lib/staleness.sh missing"; then
  t_pass "T8: missing-validator diagnostic emitted"
else
  t_fail "T8: expected 'core/lib/staleness.sh missing' in init.sh output"
fi
if printf '%s' "$T8_OUT" | grep -qE '^\[6/9\]'; then
  t_pass "T8: step [6/9] ran and failed closed"
else
  t_fail "T8: step [6/9] header missing from init.sh output"
fi

echo ""
echo "============================================"
echo "  test-bootstrap-gates.sh summary"
echo "  Passed: $PASSED | Failed: $FAILED"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "FATAL: $FAILED bootstrap gate test(s) failed — §5-b.5 classification or"
  echo "readiness bypass protection is broken. RELEASE BLOCKER."
  exit 1
fi
exit 0
