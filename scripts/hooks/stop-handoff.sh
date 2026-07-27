#!/bin/bash
# stop-handoff.sh — Harness Companion Stop hook
#
# Reads hook event from stdin, checks project for uncommitted changes
# and harness state, and reminds about handoff before session ends.
#
# Graceful: exits silently if no harness files found.
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

# --- Only activate if harness files exist -----------------------------------
if [ ! -f "feature_list.json" ]; then
  echo '{"continue":true}'
  exit 0
fi

# --- Build reminder message -------------------------------------------------

MESSAGE=""

# Check for uncommitted changes
if git rev-parse --git-dir > /dev/null 2>&1; then
  UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$UNCOMMITTED" -gt 0 ]; then
    MESSAGE+="⚠️ $UNCOMMITTED uncommitted file(s) — commit before ending session.\n"
  fi
fi

# Check for dangling in_progress features
if command -v jq &> /dev/null && [ -f "feature_list.json" ]; then
  IN_PROGRESS=$(jq -r '.features[] | select(.status=="in_progress") | "  - \(.id): \(.title)"' feature_list.json 2>/dev/null || echo "")
  if [ -n "$IN_PROGRESS" ]; then
    MESSAGE+="⚠️ Features still in_progress — update their status:\n$IN_PROGRESS\n"
  fi

  # Check for passing features without evidence
  NO_EVIDENCE=$(jq -r '.features[] | select(.status=="passing" and (.evidence | length) == 0) | "  - \(.id): \(.title)"' feature_list.json 2>/dev/null || echo "")
  if [ -n "$NO_EVIDENCE" ]; then
    MESSAGE+="⚠️ Features marked passing but have NO evidence:\n$NO_EVIDENCE\n"
  fi
fi

# Check if checklist.sh exists and remind to run it
if [ -f "checklist.sh" ]; then
  MESSAGE+="💡 Run \`bash checklist.sh\` to verify clean handoff.\n"
else
  MESSAGE+="💡 Run \`/harness:handoff\` before ending the session.\n"
fi

# --- Output -----------------------------------------------------------------
if [ -z "$MESSAGE" ]; then
  # All clean — silent
  echo '{"continue":true,"suppressOutput":true}'
else
  MESSAGE_ESCAPED=$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
  cat <<EOF
{"continue":true,"systemMessage":"$MESSAGE_ESCAPED"}
EOF
fi

exit 0
