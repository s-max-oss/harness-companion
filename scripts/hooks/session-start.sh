#!/bin/bash
# session-start.sh — Harness Companion SessionStart hook
#
# Reads hook event from stdin, checks project for harness files,
# and injects harness status into Claude's context.
#
# Graceful: exits silently if no harness files found (non-harness project).
# Non-blocking: always returns {"continue":true}.

set -euo pipefail

# Read stdin (hook event JSON)
INPUT=$(cat)

# Extract cwd from the hook input
CWD=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/"cwd":"//;s/"//')

if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  echo '{"continue":true}'
  exit 0
fi

cd "$CWD" 2>/dev/null || { echo '{"continue":true}'; exit 0; }

# --- Harness detection: only activate if feature_list.json exists ----------
if [ ! -f "feature_list.json" ]; then
  echo '{"continue":true}'
  exit 0
fi

# --- Build status context ---------------------------------------------------

STATUS="## Harness Status — $(basename "$CWD")\n\n"

# Check each harness file
check_file() {
  local file="$1"
  local label="$2"
  if [ -f "$file" ]; then
    STATUS+="- ✅ $label: \`$file\`\n"
  else
    STATUS+="- ❌ $label: \`$file\` MISSING\n"
  fi
}

check_file "AGENTS.md" "Knowledge (AGENTS.md)"
check_file "CLAUDE.md" "Knowledge (CLAUDE.md)"
check_file "init.sh" "Environment (init.sh)"
check_file "feature_list.json" "Scope (feature_list.json)"
check_file "claude-progress.md" "Progress (claude-progress.md)"
check_file "session-handoff.md" "Handoff (session-handoff.md)"
check_file "clean-state-checklist.md" "Handoff (clean-state-checklist.md)"
check_file "checklist.sh" "Handoff (checklist.sh)"

# Feature statistics (if jq available)
if command -v jq &> /dev/null && [ -f "feature_list.json" ]; then
  TOTAL=$(jq '.features | length' feature_list.json 2>/dev/null || echo "0")
  PASSING=$(jq '[.features[] | select(.status=="passing" or .status=="pass")] | length' feature_list.json 2>/dev/null || echo "0")
  IN_PROGRESS=$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json 2>/dev/null || echo "0")
  NOT_STARTED=$(jq '[.features[] | select(.status=="not_started")] | length' feature_list.json 2>/dev/null || echo "0")
  STATUS+="- 📊 Features: $PASSING/$TOTAL passing"
  if [ "$IN_PROGRESS" -gt 0 ]; then
    STATUS+=", $IN_PROGRESS in_progress"
  fi
  if [ "$NOT_STARTED" -gt 0 ]; then
    STATUS+=", $NOT_STARTED not_started"
  fi
  STATUS+="\n"

  # WIP=1 check
  if [ "$IN_PROGRESS" -gt 1 ]; then
    STATUS+="- ⚠️ WIP violation: $IN_PROGRESS features in_progress (WIP=1 rule broken!)\n"
  fi
fi

# Progress staleness check
if [ -f "claude-progress.md" ]; then
  # Check if modified in last 24 hours (86400 seconds)
  if command -v stat &> /dev/null; then
    MTIME=$(stat -c %Y "claude-progress.md" 2>/dev/null || stat -f %m "claude-progress.md" 2>/dev/null || echo "0")
    NOW=$(date +%s 2>/dev/null || echo "0")
    if [ "$MTIME" != "0" ] && [ "$NOW" != "0" ]; then
      AGE=$(( (NOW - MTIME) / 3600 ))
      if [ "$AGE" -gt 24 ]; then
        STATUS+="- ⚠️ claude-progress.md last updated ${AGE}h ago — stale!\n"
      fi
    fi
  fi
fi

# Agent.log check
if [ -f "agent.log" ]; then
  # Check if last line has CLOSE marker
  LAST_LINE=$(tail -1 "agent.log" 2>/dev/null || echo "")
  if ! echo "$LAST_LINE" | grep -q '"CLOSE"'; then
    STATUS+="- ⚠️ agent.log has no CLOSE marker — previous session may not have exited cleanly\n"
  fi
fi

STATUS+="\nUse \`/harness:status\` for detailed health dashboard."

# --- Output hook response ---------------------------------------------------
# Escape for JSON: backslash and double-quote
STATUS_ESCAPED=$(printf '%s' "$STATUS" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')

cat <<EOF
{"continue":true,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"$STATUS_ESCAPED"}}
EOF

exit 0
