#!/bin/bash
# harness-audit.sh — Comprehensive harness maturity diagnosis
#
# Usage: bash harness-audit.sh [project-dir]
#
# Scores all 7 subsystems 0-3, computes total, ranks improvements.

set -euo pipefail

TARGET="${1:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: Directory '$TARGET' not found."
  exit 1
fi

cd "$TARGET"
PROJECT_NAME=$(basename "$PWD")

# --- Scoring helpers ---------------------------------------------------------

# Score 0-3 for a subsystem
score() {
  echo "$1"
}

# --- Audit each subsystem ----------------------------------------------------

# 1. Knowledge (0-3)
KNOWLEDGE_SCORE=0
KNOWLEDGE_DETAIL=""

if [ -f "AGENTS.md" ] && [ -f "CLAUDE.md" ]; then
  AGENTS_LINES=$(wc -l < "AGENTS.md" 2>/dev/null | tr -d ' ' || echo "0")
  CLAUDE_LINES=$(wc -l < "CLAUDE.md" 2>/dev/null | tr -d ' ' || echo "0")

  # Check if AGENTS.md has startup rules
  if grep -q "Startup Rules\|startup rules\|启动" AGENTS.md 2>/dev/null; then
    KNOWLEDGE_SCORE=2
    KNOWLEDGE_DETAIL="AGENTS.md ($AGENTS_LINES lines, has startup rules), CLAUDE.md ($CLAUDE_LINES lines)"
  else
    KNOWLEDGE_SCORE=1
    KNOWLEDGE_DETAIL="AGENTS.md exists but may be incomplete, CLAUDE.md ($CLAUDE_LINES lines)"
  fi

  # Check for docs/ directory
  if [ -d "docs" ]; then
    DOC_COUNT=$(find docs -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DOC_COUNT" -gt 0 ]; then
      KNOWLEDGE_SCORE=3
      KNOWLEDGE_DETAIL="$KNOWLEDGE_DETAIL, docs/ ($DOC_COUNT files)"
    fi
  fi

  # Check that CLAUDE.md doesn't duplicate AGENTS.md content excessively
  if [ "$CLAUDE_LINES" -gt 200 ]; then
    KNOWLEDGE_DETAIL="$KNOWLEDGE_DETAIL ⚠️ CLAUDE.md is $CLAUDE_LINES lines (should be <200 — quick reference only)"
    if [ "$KNOWLEDGE_SCORE" -gt 1 ]; then
      KNOWLEDGE_SCORE=$((KNOWLEDGE_SCORE - 1))
    fi
  fi
elif [ -f "AGENTS.md" ] || [ -f "CLAUDE.md" ]; then
  KNOWLEDGE_SCORE=1
  KNOWLEDGE_DETAIL="Only one of AGENTS.md/CLAUDE.md exists"
else
  KNOWLEDGE_SCORE=0
  KNOWLEDGE_DETAIL="No AGENTS.md or CLAUDE.md"
fi

# 2. Environment (0-3)
ENV_SCORE=0
ENV_DETAIL=""

if [ -f "init.sh" ]; then
  ENV_SCORE=1
  ENV_DETAIL="init.sh exists"

  # Check coverage
  if grep -q "npm install\|pip install\|yarn install\|pnpm install" init.sh 2>/dev/null; then
    ENV_SCORE=2
    ENV_DETAIL="$ENV_DETAIL, covers install"
  fi
  if grep -q "check\|typecheck\|tsc\|mypy" init.sh 2>/dev/null; then
    ENV_DETAIL="$ENV_DETAIL+check"
  else
    ENV_SCORE=1
  fi
  if grep -q "build\|compile" init.sh 2>/dev/null; then
    ENV_DETAIL="$ENV_DETAIL+build"
  fi
  if grep -q "harness\|harness files\|verifying" init.sh 2>/dev/null; then
    ENV_SCORE=3
    ENV_DETAIL="$ENV_DETAIL+harness audit"
  fi
else
  ENV_SCORE=0
  ENV_DETAIL="No init.sh"
fi

# 3. Progress (0-3)
PROGRESS_SCORE=0
PROGRESS_DETAIL=""

if [ -f "claude-progress.md" ]; then
  PROGRESS_SCORE=1
  PROGRESS_DETAIL="claude-progress.md exists"

  # Check staleness
  if command -v stat &> /dev/null; then
    MTIME=$(stat -c %Y "claude-progress.md" 2>/dev/null || stat -f %m "claude-progress.md" 2>/dev/null || echo "0")
    NOW=$(date +%s 2>/dev/null || echo "0")
    if [ "$MTIME" != "0" ] && [ "$NOW" != "0" ]; then
      AGE=$(( (NOW - MTIME) / 3600 ))
      if [ "$AGE" -lt 24 ]; then
        PROGRESS_SCORE=2
        PROGRESS_DETAIL="$PROGRESS_DETAIL (updated ${AGE}h ago — fresh)"
      else
        PROGRESS_DETAIL="$PROGRESS_DETAIL (updated ${AGE}h ago — stale)"
      fi
    fi
  fi

  # Check for session-handoff.md as bonus
  if [ -f "session-handoff.md" ]; then
    PROGRESS_SCORE=3
    PROGRESS_DETAIL="$PROGRESS_DETAIL, has session-handoff.md"
  fi
else
  PROGRESS_SCORE=0
  PROGRESS_DETAIL="No claude-progress.md"
fi

# 4. Scope/Feature (0-3)
SCOPE_SCORE=0
SCOPE_DETAIL=""

if [ -f "feature_list.json" ]; then
  if command -v jq &> /dev/null; then
    if jq . feature_list.json > /dev/null 2>&1; then
      TOTAL=$(jq '.features | length' feature_list.json 2>/dev/null || echo "0")
      SCOPE_SCORE=1
      SCOPE_DETAIL="feature_list.json ($TOTAL features)"

      # Check for rules
      if jq -e '.rules' feature_list.json > /dev/null 2>&1; then
        SCOPE_SCORE=2
        SCOPE_DETAIL="$SCOPE_DETAIL, has rules"
      fi

      # Check evidence completeness
      PASSING=$(jq '[.features[] | select(.status=="passing" or .status=="pass")] | length' feature_list.json 2>/dev/null || echo "0")
      WITH_EVIDENCE=$(jq '[.features[] | select((.status=="passing" or .status=="pass") and (.evidence | length) > 0)] | length' feature_list.json 2>/dev/null || echo "0")
      if [ "$PASSING" -gt 0 ] && [ "$PASSING" -eq "$WITH_EVIDENCE" ]; then
        SCOPE_SCORE=3
        SCOPE_DETAIL="$SCOPE_DETAIL, all passing features have evidence"
      elif [ "$PASSING" -gt "$WITH_EVIDENCE" ]; then
        MISSING=$((PASSING - WITH_EVIDENCE))
        SCOPE_DETAIL="$SCOPE_DETAIL ($MISSING passing features lack evidence)"
      fi

      # WIP check
      IN_PROGRESS=$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json 2>/dev/null || echo "0")
      if [ "$IN_PROGRESS" -gt 1 ]; then
        SCOPE_DETAIL="$SCOPE_DETAIL ⚠️ WIP violation ($IN_PROGRESS in_progress)"
        if [ "$SCOPE_SCORE" -gt 1 ]; then SCOPE_SCORE=$((SCOPE_SCORE - 1)); fi
      fi
    else
      SCOPE_DETAIL="feature_list.json is INVALID JSON"
    fi
  else
    SCOPE_SCORE=1
    SCOPE_DETAIL="feature_list.json exists (install jq for detailed analysis)"
  fi
else
  SCOPE_SCORE=0
  SCOPE_DETAIL="No feature_list.json"
fi

# 5. Verification (0-3)
VERIFY_SCORE=0
VERIFY_DETAIL=""

if [ -f "checklist.sh" ]; then
  VERIFY_SCORE=2
  VERIFY_DETAIL="checklist.sh exists"
else
  VERIFY_DETAIL="No checklist.sh"
fi

# Check for test suite
if [ -f "package.json" ]; then
  HAS_TEST=$(grep -c '"test"' package.json 2>/dev/null || echo "0")
  if [ "$HAS_TEST" != "0" ]; then
    if [ "$VERIFY_SCORE" -lt 2 ]; then VERIFY_SCORE=1; fi
    VERIFY_DETAIL="$VERIFY_DETAIL, has test script"
  fi
fi

# Check for full chain
if [ -f "checklist.sh" ] && grep -q "typecheck\|tsc" checklist.sh 2>/dev/null && grep -q "build" checklist.sh 2>/dev/null; then
  VERIFY_SCORE=3
  VERIFY_DETAIL="$VERIFY_DETAIL (covers typecheck+build)"
fi

if [ "$VERIFY_SCORE" -eq 0 ]; then
  VERIFY_DETAIL="No checklist.sh, no test script"
fi

# 6. Observability (0-3)
OBSERVE_SCORE=0
OBSERVE_DETAIL=""

if [ -f "agent.log" ]; then
  OBSERVE_SCORE=1
  OBSERVE_DETAIL="agent.log exists"

  # Check for CLOSE marker
  if tail -1 "agent.log" 2>/dev/null | grep -q '"CLOSE"'; then
    OBSERVE_DETAIL="$OBSERVE_DETAIL (clean close ✓)"
  else
    OBSERVE_DETAIL="$OBSERVE_DETAIL (no CLOSE marker)"
  fi

  # Check for structured logging in source
  if grep -r "logger\|logging\|log\." src/ 2>/dev/null | head -1 > /dev/null; then
    OBSERVE_SCORE=2
    OBSERVE_DETAIL="$OBSERVE_DETAIL, structured logging in source"
  fi
else
  OBSERVE_SCORE=0
  OBSERVE_DETAIL="No agent.log"
fi

# Check for benchmark/evaluator
if [ -f "scripts/benchmark.sh" ] || [ -f "evaluator-rubric.md" ]; then
  OBSERVE_SCORE=3
  OBSERVE_DETAIL="$OBSERVE_DETAIL, has benchmark/evaluator"
fi

# 7. Handoff/Automation (0-3)
HANDOFF_SCORE=0
HANDOFF_DETAIL=""

if [ -f "session-handoff.md" ]; then
  HANDOFF_SCORE=1
  HANDOFF_DETAIL="session-handoff.md exists"
fi

if [ -f "clean-state-checklist.md" ]; then
  HANDOFF_SCORE=2
  HANDOFF_DETAIL="$HANDOFF_DETAIL, clean-state-checklist.md exists"
fi

if [ -f "checklist.sh" ] && [ -x "checklist.sh" ]; then
  HANDOFF_SCORE=2
  HANDOFF_DETAIL="$HANDOFF_DETAIL, checklist.sh executable"
fi

if [ -f "loop.sh" ]; then
  HANDOFF_SCORE=3
  HANDOFF_DETAIL="$HANDOFF_DETAIL, loop.sh (automation)"
fi

# --- Compute total -----------------------------------------------------------
TOTAL=$((KNOWLEDGE_SCORE + ENV_SCORE + PROGRESS_SCORE + SCOPE_SCORE + VERIFY_SCORE + OBSERVE_SCORE + HANDOFF_SCORE))
MAX=21
PCT=$(( TOTAL * 100 / MAX ))

# --- Output ------------------------------------------------------------------

echo "Harness Audit: $PROJECT_NAME"
echo "══════════════════════════════════════════"
echo ""

printf "  %-16s %s  %s\n" "Subsystem" "Score" "Detail"
printf "  %-16s %s  %s\n" "----------------" "-----" "------"
printf "  %-16s %d/3   %s\n" "Knowledge"       "$KNOWLEDGE_SCORE" "$KNOWLEDGE_DETAIL"
printf "  %-16s %d/3   %s\n" "Environment"     "$ENV_SCORE"       "$ENV_DETAIL"
printf "  %-16s %d/3   %s\n" "Progress"        "$PROGRESS_SCORE"  "$PROGRESS_DETAIL"
printf "  %-16s %d/3   %s\n" "Scope/Feature"   "$SCOPE_SCORE"     "$SCOPE_DETAIL"
printf "  %-16s %d/3   %s\n" "Verification"    "$VERIFY_SCORE"    "$VERIFY_DETAIL"
printf "  %-16s %d/3   %s\n" "Observability"   "$OBSERVE_SCORE"   "$OBSERVE_DETAIL"
printf "  %-16s %d/3   %s\n" "Handoff/Auto"    "$HANDOFF_SCORE"   "$HANDOFF_DETAIL"

echo ""
echo "──────────────────────────────────────────"
echo "Total: $TOTAL/$MAX ($PCT%)"
echo ""

# --- Improvement recommendations ---------------------------------------------
echo "Top improvements (by impact):"
echo ""

# Collect improvements: score, subsystem, action, effort
improvements=""

if [ "$KNOWLEDGE_SCORE" -lt 2 ]; then
  improvements+="0|Knowledge|Create AGENTS.md and CLAUDE.md from templates|5 min (+$((2 - KNOWLEDGE_SCORE)) pts)\n"
fi
if [ "$KNOWLEDGE_SCORE" -eq 2 ]; then
  improvements+="1|Knowledge|Add docs/ directory with ARCHITECTURE.md and PRODUCT.md|30 min (+1 pt)\n"
fi

if [ "$ENV_SCORE" -lt 2 ]; then
  improvements+="0|Environment|Create init.sh with install+check+build steps|10 min (+$((2 - ENV_SCORE)) pts)\n"
fi
if [ "$ENV_SCORE" -eq 2 ]; then
  improvements+="1|Environment|Extend init.sh to audit harness files|5 min (+1 pt)\n"
fi

if [ "$PROGRESS_SCORE" -lt 1 ]; then
  improvements+="0|Progress|Create claude-progress.md|5 min (+1 pt)\n"
fi
if [ "$PROGRESS_SCORE" -eq 1 ]; then
  improvements+="1|Progress|Update claude-progress.md (stale)|2 min (+1 pt)\n"
fi
if [ "$PROGRESS_SCORE" -eq 2 ]; then
  improvements+="1|Progress|Add session-handoff.md for fast resumption|5 min (+1 pt)\n"
fi

if [ "$SCOPE_SCORE" -lt 1 ]; then
  improvements+="0|Scope|Create feature_list.json|10 min (+1 pt)\n"
fi
if [ "$SCOPE_SCORE" -ge 1 ] && [ "$SCOPE_SCORE" -lt 3 ]; then
  improvements+="1|Scope|Fill evidence for passing features|5 min/feature (+1 pt)\n"
fi

if [ "$VERIFY_SCORE" -lt 1 ]; then
  improvements+="0|Verification|Add test script to package.json|15 min (+1 pt)\n"
fi
if [ "$VERIFY_SCORE" -eq 1 ] || [ "$VERIFY_SCORE" -eq 2 ]; then
  improvements+="1|Verification|Create checklist.sh with full typecheck+build check|5 min (+1 pt)\n"
fi

if [ "$OBSERVE_SCORE" -lt 1 ]; then
  improvements+="1|Observability|Start logging agent actions to agent.log|5 min (+1 pt)\n"
fi
if [ "$OBSERVE_SCORE" -eq 1 ]; then
  improvements+="1|Observability|Add structured logging to service layer|30 min (+1 pt)\n"
fi

if [ "$HANDOFF_SCORE" -lt 1 ]; then
  improvements+="1|Handoff|Create session-handoff.md from template|3 min (+1 pt)\n"
fi
if [ "$HANDOFF_SCORE" -eq 1 ] || [ "$HANDOFF_SCORE" -eq 2 ]; then
  improvements+="1|Handoff|Create clean-state-checklist.md|5 min (+1 pt)\n"
fi

# Sort by impact (priority 0 = critical, 1 = nice-to-have)
echo -e "$improvements" | sort | while IFS='|' read -r priority subsystem action effort; do
  if [ -n "$subsystem" ]; then
    printf "  [%s] %s — %s\n" "$subsystem" "$action" "$effort"
  fi
done

echo ""
echo "Run /harness:init to generate missing files from templates."
