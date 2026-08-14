#!/usr/bin/env bash
# init.sh — Self-host init: canonical validators + Phase 1 readiness gate.
#
# Run after cloning, when resuming work, or before starting any feature.
# Uses the repo's OWN canonical validators and FAILS CLOSED. No check is
# skipped, jq missing is a FAILURE, and a harness-status failure is a FAILURE:
#   - core/lib/config-validate.sh   validate_config_schema .harness/config.json
#   - core/lib/validate-run-log.sh  validate_run_log on the NEWEST run log
#   - core/lib/staleness.sh         three-axis staleness on the NEWEST run
#   - core/lib/validate-feature-registry.sh  schema/status/revision/WIP validator
#   - core/lib/brief-integrity.sh   Brief JSON/MD + snapshot acyclic integrity
#   - core/harness-status.sh        health dashboard (exit code captured)
#   - feature state / WIP, snapshot / digest / immutable integrity (below)
#
# Exit codes (documented in AGENTS.md / CLAUDE.md):
#   0  all checks pass AND every Phase 1 start condition is met
#       → "Ready to start work."
#   1  init/validator failure (syntax, config, run log, registry, status,
#      WIP, staleness, snapshot/digest/immutable integrity)
#   2  checks pass but Phase 1 start conditions are NOT met → NOT ready
#
# Phase 1 start conditions come from .harness/PLAN.json
# (fail_closed_start_conditions + start_condition_rule). All five are
# verified WITHOUT any forgeable shortcut:
#   - rc.2 merged to master   → git merge-base --is-ancestor
#   - tag v2.0.0-rc.2         → git refs/tags/v2.0.0-rc.2
#   - GitHub pre-release      → MANUAL in-session authorization gate (kept as
#     independent authorization). Confirm it in-session, then set:
#     HARNESS_PRE_RELEASE_CONFIRMED=1
#   - master clean            → git refs: local master == origin/master
#     (no local divergences). Verified automatically — there is NO
#     HARNESS_MASTER_CLEAN_CONFIRMED env var; forging one cannot bypass.
#   - branch baseline gate    → stateful .harness/branch-gate.json. The gate
#     ENFORCES the target branch (PLAN.json branch_gate.target_branch) on every
#     entry. FIRST entry requires current branch tip == master tip (tip==master);
#     later entries are READ-ONLY and allow forward advancement only — current
#     branch must match the recorded branch AND recorded branch_base_sha must be
#     an ancestor of HEAD. Gate state is recorded ONLY on first entry after ALL
#     other conditions pass (so a prior-check failure never leaks a gate), and a
#     record-write failure BLOCKS ready (fail-closed). core/lib/branch-gate.sh.
#
# init.sh never prints "Ready to start work." while any start condition is
# unmet — it fails closed (exit 2) and lists the unmet conditions.
set -uo pipefail

echo "=== Project Init (harness-companion self-host) ==="
echo ""

FAILED=false

# ---- 0. Preflight: jq is REQUIRED (no skip) --------------------------------
echo "[0/9] Preflight..."
if command -v jq >/dev/null 2>&1; then
  echo "  OK: jq $(jq --version 2>/dev/null)"
else
  echo "  FAIL: jq is required but not installed. Install jq and re-run."
  FAILED=true
fi
echo ""

# ---- 1. Syntax-check all shell scripts -------------------------------------
echo "[1/9] Syntax-checking shell scripts..."
SCRIPT_COUNT=0
while IFS= read -r -d '' f; do
  SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
  if ! bash -n "$f" 2>&1; then
    echo "  FAIL: syntax error in $f"
    FAILED=true
  fi
done < <(find core scripts tests adapters -name '*.sh' -type f -print0 2>/dev/null)
echo "  checked $SCRIPT_COUNT script(s)."
echo ""

# ---- 2. Validate .harness/config.json (canonical validator) -----------------
echo "[2/9] Validating .harness/config.json (core/lib/config-validate.sh)..."
if [ -f core/lib/config-validate.sh ]; then
  # shellcheck source=core/lib/config-validate.sh
  . core/lib/config-validate.sh
  if validate_config_schema .harness/config.json; then
    echo "  OK: config.json passes validate_config_schema"
  else
    echo "  FAIL: config.json schema invalid (see validator stderr above)"
    FAILED=true
  fi
else
  echo "  FAIL: core/lib/config-validate.sh missing"
  FAILED=true
fi
echo ""

# ---- 3. Feature registry (canonical validator: schema/status/revision/WIP) ----
echo "[3/9] Feature registry (core/lib/validate-feature-registry.sh)..."
if [ -f core/lib/validate-feature-registry.sh ]; then
  # shellcheck source=core/lib/validate-feature-registry.sh
  . core/lib/validate-feature-registry.sh
  if validate_feature_registry feature_list.json .; then
    echo "  OK: feature_list.json passes validate_feature_registry"
  else
    echo "  FAIL: feature_list.json registry invalid (see validator stderr above)"
    FAILED=true
  fi
else
  echo "  FAIL: core/lib/validate-feature-registry.sh missing"
  FAILED=true
fi
echo ""

# ---- 4. Feature state / WIP check --------------------------------------------
echo "[4/9] Feature state / WIP check..."
if [ -f feature_list.json ]; then
  FEAT_TOTAL="$(jq '.features | length' feature_list.json 2>/dev/null || echo 0)"
  FEAT_NOT_STARTED="$(jq '[.features[] | select(.status=="not_started")] | length' feature_list.json 2>/dev/null || echo 0)"
  FEAT_IN_PROGRESS="$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json 2>/dev/null || echo 0)"
  FEAT_PASSING="$(jq '[.features[] | select(.status=="passing")] | length' feature_list.json 2>/dev/null || echo 0)"
  echo "  status: $FEAT_NOT_STARTED not_started | $FEAT_IN_PROGRESS in_progress | $FEAT_PASSING passing | $FEAT_TOTAL total"
  if [ "$FEAT_IN_PROGRESS" -gt 1 ]; then
    echo "  FAIL: WIP=1 violated — $FEAT_IN_PROGRESS features in_progress"
    FAILED=true
  else
    echo "  OK: WIP=1 satisfied ($FEAT_IN_PROGRESS in_progress)"
  fi
else
  echo "  FAIL: feature_list.json missing"
  FAILED=true
fi
echo ""

# ---- 5. Newest run log (canonical validator; NDJSON must come from core) ----
RUN_ID=""
echo "[5/9] Newest run log (core/lib/validate-run-log.sh)..."
shopt -s nullglob
RUNS=(.harness/logs/runs/*.ndjson)
shopt -u nullglob
if [ "${#RUNS[@]}" -eq 0 ]; then
  echo "  FAIL: no run log in .harness/logs/runs/ (init evidence missing — generate via core/harness-verify.sh, never hand-craft NDJSON)"
  FAILED=true
elif [ -f core/lib/validate-run-log.sh ]; then
  # shellcheck source=core/lib/validate-run-log.sh
  . core/lib/validate-run-log.sh
  RUN_ID="$(basename "${RUNS[-1]}" .ndjson)"
  VALIDATION="$(validate_run_log "$RUN_ID" .)"
  VALID_STATUS=$?
  if [ "$VALID_STATUS" -eq 0 ] && printf '%s' "$VALIDATION" | jq -e '.valid == true' >/dev/null 2>&1; then
    echo "  OK: run log $RUN_ID valid (.valid=true)"
  else
    echo "  FAIL: run log $RUN_ID invalid (validator exit $VALID_STATUS)"
    printf '%s\n' "$VALIDATION"
    FAILED=true
  fi
else
  echo "  FAIL: core/lib/validate-run-log.sh missing"
  FAILED=true
fi
echo ""

# ---- 6. Three-axis staleness on the newest run (canonical) -------------------
# FAIL-CLOSED: a run id exists (step 5 already required a valid run log), so a
# MISSING staleness validator is a FAILURE (exit 1), never a skip. Skipping is
# allowed ONLY when there is no run id — and step 5 has already failed in that
# case if a run log was required.
echo "[6/9] Three-axis staleness (core/lib/staleness.sh)..."
if [ -n "$RUN_ID" ]; then
  if [ -f core/lib/staleness.sh ]; then
    # shellcheck source=core/lib/staleness.sh
    . core/lib/staleness.sh
    A1=false; A2=false; A3=false
    if ev_is_stale_by_fingerprint "$RUN_ID" .; then A1=true; fi
    if ev_is_stale_by_config "$RUN_ID" .; then A2=true; fi
    if ev_is_stale_by_vcs "$RUN_ID" .; then A3=true; fi
    if [ "$A1" = true ] || [ "$A2" = true ] || [ "$A3" = true ]; then
      echo "  FAIL: run $RUN_ID is stale (Axis1 fingerprint=$A1, Axis2 config=$A2, Axis3 vcs=$A3) — regenerate via core/harness-verify.sh"
      FAILED=true
    else
      echo "  OK: run $RUN_ID fresh on all 3 axes"
    fi
  else
    echo "  FAIL: core/lib/staleness.sh missing (run $RUN_ID requires three-axis staleness)"
    FAILED=true
  fi
else
  echo "  SKIP: staleness not evaluated (no run id) — step 5 already failed if a run log was required"
fi
echo ""

# ---- 7. Harness status (canonical; exit code captured, never swallowed) -----
echo "[7/9] Harness status (core/harness-status.sh)..."
if [ -f core/harness-status.sh ]; then
  if bash core/harness-status.sh .; then
    echo "  OK: harness-status.sh exit 0"
  else
    echo "  FAIL: harness-status.sh exited non-zero"
    FAILED=true
  fi
else
  echo "  FAIL: core/harness-status.sh missing"
  FAILED=true
fi
echo ""

# ---- 8. Harness file presence -----------------------------------------------
echo "[8/9] Harness file presence..."
for file in AGENTS.md CLAUDE.md feature_list.json init.sh claude-progress.md \
            .harness/PROJECT_BRIEF.json .harness/PROJECT_BRIEF.md .harness/PLAN.json \
            .harness/config.json .harness/.template-snapshot.json; do
  if [ -f "$file" ]; then
    echo "  OK: $file"
  else
    echo "  FAIL: $file MISSING"
    FAILED=true
  fi
done
echo ""

# ---- 9. Brief / snapshot acyclic integrity + immutable template shas ---------
echo "[9/9] Brief / snapshot acyclic integrity + immutable template shas..."
if [ -f core/lib/brief-integrity.sh ]; then
  # shellcheck source=core/lib/brief-integrity.sh
  . core/lib/brief-integrity.sh
  if validate_brief_integrity .; then
    echo "  OK: Brief JSON/MD presence + parity, snapshot schema, digest, acyclic integrity valid"
  else
    echo "  FAIL: brief integrity invalid (see validator stderr above)"
    FAILED=true
  fi
else
  echo "  FAIL: core/lib/brief-integrity.sh missing"
  FAILED=true
fi
for entry in ".harness/config.json" "AGENTS.md" "CLAUDE.md" "init.sh"; do
  REC="$(jq -r --arg e "$entry" '.templates[$e].sha256 // ""' .harness/.template-snapshot.json 2>/dev/null)"
  ACT="$(sha256sum "$entry" 2>/dev/null | cut -d' ' -f1)"
  if [ -n "$REC" ] && [ "$REC" = "$ACT" ]; then
    echo "  OK: immutable $entry matches snapshot ($REC)"
  else
    echo "  FAIL: immutable $entry diverged from snapshot (recorded $REC, on-disk $ACT) — deliberate contract update + snapshot recapture required"
    FAILED=true
  fi
done
echo ""

# ---- Summary ------------------------------------------------------------------
if [ "$FAILED" = true ]; then
  echo "=== Init FAILED. Fix the failures above before continuing. ==="
  exit 1
fi
echo "=== Init checks passed. ==="

# ---- Phase 1 readiness gate (fail-closed) -------------------------------------
# Conditions are from .harness/PLAN.json fail_closed_start_conditions.
# start_condition_rule: if ANY condition is unmet, the Agent fails closed and
# does not begin Phase 1. Never print "Ready to start work." while unmet.
echo ""
echo "=== Phase 1 start-condition readiness gate ==="
NOT_READY=false

# 1. "rc.2 merged to master (distribution/rc2-hardening → master)"
if git show-ref --verify --quiet refs/heads/distribution/rc2-hardening >/dev/null \
   && git show-ref --verify --quiet refs/heads/master >/dev/null \
   && git merge-base --is-ancestor distribution/rc2-hardening refs/heads/master 2>/dev/null; then
  echo "  [OK] rc.2 (distribution/rc2-hardening) is merged into master"
else
  echo "  [NO] rc.2 is NOT merged into master (distribution/rc2-hardening → master required)"
  NOT_READY=true
fi

# 2. "rc.2 tag cut (v2.0.0-rc.2)"
if git rev-parse --verify --quiet refs/tags/v2.0.0-rc.2 >/dev/null; then
  echo "  [OK] tag v2.0.0-rc.2 exists"
else
  echo "  [NO] tag v2.0.0-rc.2 does not exist (rc.2 must be tagged first)"
  NOT_READY=true
fi

# 3. "rc.2 GitHub pre-release created (release gate)" — MANUAL authorization gate
if [ "${HARNESS_PRE_RELEASE_CONFIRMED:-0}" = "1" ]; then
  echo "  [OK] rc.2 GitHub pre-release confirmed in-session (HARNESS_PRE_RELEASE_CONFIRMED=1)"
else
  echo "  [--] rc.2 GitHub pre-release: MANUAL in-session authorization gate. Confirm it exists in-session, then set HARNESS_PRE_RELEASE_CONFIRMED=1."
  NOT_READY=true
fi

# 4. "master clean (git checkout master && git pull, no local divergences)" — via Git refs
LOCAL_MASTER="$(git rev-parse --verify --quiet refs/heads/master 2>/dev/null || echo '')"
REMOTE_MASTER="$(git rev-parse --verify --quiet refs/remotes/origin/master 2>/dev/null || echo '')"
if [ -n "$LOCAL_MASTER" ] && [ -n "$REMOTE_MASTER" ] && [ "$LOCAL_MASTER" = "$REMOTE_MASTER" ]; then
  echo "  [OK] master clean via refs (local master == origin/master == $LOCAL_MASTER)"
else
  echo "  [NO] master not clean via refs (local master=$LOCAL_MASTER, origin/master=$REMOTE_MASTER; must be equal — no local divergences)"
  NOT_READY=true
fi

# 5. "branch baseline gate" — stateful (core/lib/branch-gate.sh)
# shellcheck source=core/lib/branch-gate.sh
. core/lib/branch-gate.sh
if branch_gate_check .; then
  echo "  [OK] branch gate passed (current branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown))"
else
  echo "  [NO] branch gate failed (first entry requires tip==master; later entries require forward advancement from recorded branch_base_sha)"
  NOT_READY=true
fi

echo ""
if [ "$NOT_READY" = true ]; then
  echo "=== Init checks PASSED, but Phase 1 start conditions are NOT met. ==="
  echo "NOT ready to start Phase 1. Resolve the unmet conditions above; no Phase 1 work begins."
  exit 2
else
  # All conditions passed → now record the branch-gate state. State is written
  # ONLY when EVERYTHING is ready (so a failed init never leaks a gate) and only
  # on first entry (subsequent entries are read-only — no timestamp churn).
  # P0-2: a state-write failure BLOCKS the ready transition — never swallow it.
  if branch_gate_allow_record=1 branch_gate_check . >/dev/null 2>&1; then
    echo "=== All Phase 1 start conditions met. Ready to start work. ==="
    exit 0
  else
    echo "=== Init checks PASSED and all start conditions are met, but the branch-gate state record FAILED — fail-closed, NOT ready. ==="
    exit 1
  fi
fi
