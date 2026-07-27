#!/bin/bash
# harness-feature.sh — feature_list.json management
#
# Usage:
#   bash harness-feature.sh list                    # List all features
#   bash harness-feature.sh add <id> <title>        # Add a new feature
#   bash harness-feature.sh status <id> <status>    # Update feature status
#
# Requires: jq (for JSON manipulation)

set -euo pipefail

TARGET="${TARGET_DIR:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: Directory '$TARGET' not found."
  exit 1
fi

cd "$TARGET"

if [ ! -f "feature_list.json" ]; then
  echo "Error: feature_list.json not found. Run /harness:init first."
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required for feature management. Install it first."
  echo "  winget install jqlang.jq   (Windows)"
  echo "  brew install jq            (macOS)"
  echo "  apt-get install jq         (Linux)"
  exit 1
fi

COMMAND="${1:-list}"

# --- List features -----------------------------------------------------------
list_features() {
  echo "Features in $(basename "$PWD"):"
  echo ""

  if ! jq . feature_list.json > /dev/null 2>&1; then
    echo "Error: feature_list.json is not valid JSON."
    exit 1
  fi

  TOTAL=$(jq '.features | length' feature_list.json)

  if [ "$TOTAL" -eq 0 ]; then
    echo "  (no features defined)"
    echo ""
    echo "Add one with: /harness:feature add <id> <title>"
    exit 0
  fi

  printf "  %-4s %-20s %-14s %s\n" "Pri" "ID" "Status" "Title"
  printf "  %-4s %-20s %-14s %s\n" "---" "--------------------" "--------------" "-----"

  jq -r '.features[] | "  \(.priority // "-")    \(.id)                    \(.status)              \(.title)"' feature_list.json 2>/dev/null | \
    while IFS= read -r line; do
      # Color-code status
      if echo "$line" | grep -q "passing\|pass"; then
        echo "$line ✅"
      elif echo "$line" | grep -q "in_progress"; then
        echo "$line 🔄"
      elif echo "$line" | grep -q "blocked"; then
        echo "$line 🚫"
      else
        echo "$line ⬜"
      fi
    done

  echo ""

  # Summary
  PASSING=$(jq '[.features[] | select(.status=="passing" or .status=="pass")] | length' feature_list.json)
  IN_PROGRESS=$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json)
  echo "  $PASSING/$TOTAL passing | $IN_PROGRESS in_progress"
}

# --- Add feature -------------------------------------------------------------
add_feature() {
  local id="$1"
  local title="$2"
  local area="${3:-general}"
  local priority="${4:-99}"

  # Check if id already exists
  EXISTS=$(jq -r --arg id "$id" '.features[] | select(.id==$id) | .id' feature_list.json 2>/dev/null || echo "")
  if [ -n "$EXISTS" ]; then
    echo "Error: Feature '$id' already exists."
    exit 1
  fi

  # Build new feature JSON
  NEW_FEATURE=$(jq -n \
    --arg id "$id" \
    --arg title "$title" \
    --arg area "$area" \
    --argjson priority "$priority" \
    '{
      id: $id,
      priority: $priority,
      area: $area,
      title: $title,
      user_visible_behavior: "",
      status: "not_started",
      verification: [],
      evidence: [],
      notes: ""
    }')

  # Add to features array
  jq --argjson feature "$NEW_FEATURE" \
     '.features += [$feature] | .last_updated = "'"$(date +%Y-%m-%d)"'"' \
     feature_list.json > feature_list.json.tmp

  mv feature_list.json.tmp feature_list.json

  echo "Feature '$id' added: $title (status: not_started)"
  echo "Don't forget to fill in user_visible_behavior and verification steps."
}

# --- Update status -----------------------------------------------------------
update_status() {
  local id="$1"
  local new_status="$2"

  # Validate status value
  case "$new_status" in
    not_started|in_progress|blocked|passing|pass)
      ;;
    *)
      echo "Error: Invalid status '$new_status'. Use: not_started, in_progress, blocked, passing"
      exit 1
      ;;
  esac

  # Check feature exists
  EXISTS=$(jq -r --arg id "$id" '.features[] | select(.id==$id) | .id' feature_list.json 2>/dev/null || echo "")
  if [ -z "$EXISTS" ]; then
    echo "Error: Feature '$id' not found."
    exit 1
  fi

  # WIP=1 check: if setting to in_progress, ensure no other is already in_progress
  if [ "$new_status" = "in_progress" ]; then
    CURRENT_IN_PROGRESS=$(jq -r --arg id "$id" '.features[] | select(.status=="in_progress" and .id!=$id) | .id' feature_list.json 2>/dev/null || echo "")
    if [ -n "$CURRENT_IN_PROGRESS" ]; then
      echo "⚠️  WIP=1 rule: '$CURRENT_IN_PROGRESS' is already in_progress."
      echo "    Finish it first, or mark it as blocked/not_started."
      echo "    Override with: --force"
      if [ "${3:-}" != "--force" ]; then
        exit 1
      fi
      echo "    (forced)"
    fi
  fi

  # Evidence check: if marking as passing, check evidence
  if [ "$new_status" = "passing" ] || [ "$new_status" = "pass" ]; then
    HAS_EVIDENCE=$(jq -r --arg id "$id" '.features[] | select(.id==$id) | (.evidence | length)' feature_list.json)
    if [ "$HAS_EVIDENCE" = "0" ] || [ -z "$HAS_EVIDENCE" ]; then
      echo "⚠️  Feature '$id' has no evidence. Run /harness:verify first."
      if [ "${3:-}" != "--force" ]; then
        exit 1
      fi
      echo "    (forced)"
    fi
  fi

  # Update
  jq --arg id "$id" --arg status "$new_status" \
     '(.features[] | select(.id==$id) | .status) = $status | .last_updated = "'"$(date +%Y-%m-%d)"'"' \
     feature_list.json > feature_list.json.tmp

  mv feature_list.json.tmp feature_list.json

  echo "Feature '$id' status → $new_status"
}

# --- Main dispatch -----------------------------------------------------------
case "$COMMAND" in
  list|ls)
    list_features
    ;;
  add)
    if [ $# -lt 3 ]; then
      echo "Usage: harness-feature.sh add <id> <title> [area] [priority]"
      exit 1
    fi
    add_feature "$2" "$3" "${4:-general}" "${5:-99}"
    ;;
  status)
    if [ $# -lt 3 ]; then
      echo "Usage: harness-feature.sh status <id> <new-status> [--force]"
      exit 1
    fi
    update_status "$2" "$3" "${4:-}"
    ;;
  *)
    echo "Usage: harness-feature.sh {list|add|status} [args...]"
    echo ""
    echo "Commands:"
    echo "  list                        List all features"
    echo "  add <id> <title>            Add a new feature"
    echo "  status <id> <new-status>    Update feature status"
    exit 1
    ;;
esac
