#!/bin/bash
# checklist.sh — End-of-session verification checklist.
# Run before committing and closing the session.
set -euo pipefail

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  echo -n "  $label ... "
  if "$@" > /dev/null 2>&1; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Session Handoff Checklist ==="
echo ""

# 1. Build verification — prevent dirty exit
echo "[1] Build Verification"
check "typecheck" npx tsc --noEmit
check "build"    npm run build
echo ""

# 2. Feature status sync — prevent status drift
echo "[2] Feature Status Sync"
if [ -f feature_list.json ]; then
  if command -v jq &> /dev/null; then
    IN_PROGRESS=$(jq -r '.features[] | select(.status=="in_progress") | .id' feature_list.json 2>/dev/null || echo "")
    if [ -n "$IN_PROGRESS" ]; then
      echo "  WARNING: Features still in_progress: $IN_PROGRESS"
      echo "  Update their status before ending the session."
      FAIL=$((FAIL + 1))
    else
      echo "  OK: No dangling in_progress features"
      PASS=$((PASS + 1))
    fi
  else
    echo "  SKIP: jq not available"
  fi
else
  echo "  SKIP: feature_list.json not found"
fi
echo ""

# 3. Progress doc updated — prevent context break
echo "[3] Progress Documentation"
if [ -f claude-progress.md ]; then
  echo "  OK: claude-progress.md exists"
  PASS=$((PASS + 1))
else
  echo "  WARNING: claude-progress.md not found — create it before ending"
  FAIL=$((FAIL + 1))
fi
echo ""

# 3b. F13: Run-ID + run-log integrity (every passing feature must have a
# canonical harness-verify NDJSON whose terminal event == passed). Fail-closed:
# missing run_id, missing log file, or non-passed terminal ⇒ FAIL.
echo "[3b] Run-ID + Run-Log Integrity"
if [ -f feature_list.json ] && command -v jq &> /dev/null; then
  RUN_ID_CHECK_FAIL=0
  PASSING_FEATURES=$(jq -r '.features[] | select(.status=="passing") | .id' feature_list.json 2>/dev/null)
  for fid in $PASSING_FEATURES; do
    [ -z "$fid" ] && continue
    HAS_RUN_ID=$(jq -r --arg id "$fid" \
      '(.features[] | select(.id == $id) | .evidence_associations // []) | map(select(.run_id)) | length' \
      feature_list.json 2>/dev/null)
    if [ "$HAS_RUN_ID" = "0" ] || [ -z "$HAS_RUN_ID" ]; then
      echo "  FAIL: $fid has no evidence_association with run_id"
      FAIL=$((FAIL + 1))
      RUN_ID_CHECK_FAIL=1
      continue
    fi
    # Verify each run_id has a real log file with terminal event passed
    RUN_IDS=$(jq -r --arg id "$fid" \
      '(.features[] | select(.id == $id) | .evidence_associations // []) | map(.run_id) | .[]' \
      feature_list.json 2>/dev/null)
    for rid in $RUN_IDS; do
      [ -z "$rid" ] && continue
      LOG=".harness/logs/runs/${rid}.ndjson"
      if [ ! -f "$LOG" ]; then
        echo "  FAIL: $rid — log file missing: $LOG"
        FAIL=$((FAIL + 1))
        RUN_ID_CHECK_FAIL=1
        continue
      fi
      TERM=$(tail -1 "$LOG" 2>/dev/null | jq -r '.event + ":" + .overall_result' 2>/dev/null)
      if [ "$TERM" != "run_completed:passed" ]; then
        echo "  FAIL: $rid — terminal=$TERM (must be run_completed:passed)"
        FAIL=$((FAIL + 1))
        RUN_ID_CHECK_FAIL=1
        continue
      fi
    done
  done
  if [ "$RUN_ID_CHECK_FAIL" = "0" ]; then
    echo "  OK: All passing features have real run_ids with passed terminals"
    PASS=$((PASS + 1))
  fi
elif [ ! -f feature_list.json ]; then
  echo "  SKIP: feature_list.json not found"
else
  echo "  SKIP: jq not available"
fi
echo ""

# 3c. F13: Fixture contamination — refuse to mark passing if .harness/ contains
# stale orphan run directories older than 7 days with no .ndjson companion.
# Detects "abandoned run" markers left behind by crashed harnesses.
echo "[3c] Fixture Contamination"
STALE_DIRS=0
if [ -d .harness/logs/runs ]; then
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    [ -f "$d.ndjson" ] && continue
    # No .ndjson companion ⇒ orphan run dir
    STALE_DIRS=$((STALE_DIRS + 1))
  done < <(find .harness/logs/runs -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi
if [ "$STALE_DIRS" -gt 0 ]; then
  echo "  FAIL: $STALE_DIRS orphan run dirs without .ndjson companion"
  FAIL=$((FAIL + 1))
else
  echo "  OK: No orphan run dirs"
  PASS=$((PASS + 1))
fi
echo ""

# 3d. F13: Orphan harness processes — refuse to mark passing if any harness
# subprocess (harness-verify, harness-feature, harness-audit) is still running
# in the background. Detects leaks from prior failed runs.
echo "[3d] Orphan Harness Processes"
ORPHAN_PROCS=0
if command -v ps &> /dev/null; then
  if ps -eo comm,args 2>/dev/null | grep -E 'harness-(verify|feature|audit)' | grep -v grep | grep -v "checklist.sh" > /dev/null 2>&1; then
    ORPHAN_PROCS=$(ps -eo args 2>/dev/null | grep -E 'harness-(verify|feature|audit)' | grep -v grep | grep -v "checklist.sh" | wc -l | tr -d ' ')
  fi
fi
if [ "$ORPHAN_PROCS" -gt 0 ]; then
  echo "  FAIL: $ORPHAN_PROCS orphan harness process(es) running"
  FAIL=$((FAIL + 1))
else
  echo "  OK: No orphan harness processes"
  PASS=$((PASS + 1))
fi
echo ""

# 3e. F13: Expired session handoff — if session-handoff.md exists, its
# timestamp must be within the last 24 hours. Otherwise the handoff context
# has rotted and is no longer trustworthy.
echo "[3e] Session Handoff Freshness"
if [ -f session-handoff.md ]; then
  H_TS=$(grep -E '^#[^|]*\|[0-9T:-]{19}' session-handoff.md 2>/dev/null | head -1 \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
  if [ -n "$H_TS" ]; then
    H_EPOCH=$(date -d "$H_TS" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE=$((NOW_EPOCH - H_EPOCH))
    if [ "$AGE" -gt 86400 ]; then
      echo "  FAIL: session-handoff.md is $((AGE/3600))h old (limit 24h)"
      FAIL=$((FAIL + 1))
    else
      echo "  OK: session-handoff.md is fresh ($((AGE/3600))h old)"
      PASS=$((PASS + 1))
    fi
  else
    echo "  SKIP: session-handoff.md timestamp not parseable"
  fi
else
  echo "  SKIP: session-handoff.md not present"
fi
echo ""

# 4. Change record — prevent fuzzy changes
echo "[4] Change Record"
if git rev-parse --git-dir > /dev/null 2>&1; then
  UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$UNCOMMITTED" -gt 0 ]; then
    echo "  WARNING: $UNCOMMITTED uncommitted files"
    git diff --stat HEAD 2>/dev/null || true
    FAIL=$((FAIL + 1))
  else
    echo "  OK: Working tree clean"
    PASS=$((PASS + 1))
  fi
else
  echo "  SKIP: Not a git repository"
fi
echo ""

# 5. Agent log close marker
echo "[5] Agent Log Close"
if [ -f agent.log ]; then
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"ts\":\"$TIMESTAMP\",\"step\":-1,\"action\":\"CLOSE\"}" >> agent.log
  echo "  OK: CLOSE marker written to agent.log"
  PASS=$((PASS + 1))
else
  echo "  SKIP: agent.log not found"
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Fix the failures above before ending the session."
  exit 1
else
  echo "Clean handoff ready. Safe to commit and end session."
fi
