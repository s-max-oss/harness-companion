#!/bin/bash
# init.sh — Scaffold harness-companion v2 into a project (Phase 2)
#
# Usage:
#   bash init.sh [project_dir]
#
# What it does:
#   1. Detect project type (node|python|rust|go|docs|generic)
#   2. Create .harness/logs/runs/ directory
#   3. Copy matching config example → .harness/config.json
#   4. Write v2 feature_list.json with revision: 1
#   5. Update .gitignore to exclude .harness/logs/
#
# Idempotent: re-running updates config.json only if not already present
# (or if --force-config is given).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR"
PROJECT_DIR="${1:-.}"
ROOT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Source detection library
# shellcheck source=../core/lib/project-detect.sh
source "$SCRIPT_DIR/../core/lib/project-detect.sh"

FORCE_CONFIG="false"
for arg in "$@"; do
  case "$arg" in
    --force-config) FORCE_CONFIG="true" ;;
    --help|-h)
      sed -n '2,20p' "$0"
      exit 0
      ;;
  esac
done

if [ ! -d "$ROOT_DIR" ]; then
  echo "init.sh: project dir '$ROOT_DIR' not found" >&2
  exit 1
fi

# ---- 1. Detect project type ----
DETECTED_TYPE="$(detect_project_type "$ROOT_DIR")"
echo "Detected project type: $DETECTED_TYPE"

# ---- 2. Create .harness/logs/runs/ ----
HARNESS_DIR="$ROOT_DIR/.harness"
LOGS_DIR="$HARNESS_DIR/logs/runs"
mkdir -p "$LOGS_DIR"
echo "Created: $LOGS_DIR"

# ---- 3. Copy matching config example ----
EXAMPLE_FILE="$TEMPLATE_DIR/.harness/config.json.${DETECTED_TYPE}.example"
TARGET_CONFIG="$HARNESS_DIR/config.json"
if [ ! -f "$EXAMPLE_FILE" ]; then
  echo "init.sh: example file not found: $EXAMPLE_FILE" >&2
  exit 1
fi

if [ -f "$TARGET_CONFIG" ] && [ "$FORCE_CONFIG" != "true" ]; then
  echo "Existing config found at $TARGET_CONFIG (use --force-config to overwrite); keeping it"
else
  cp "$EXAMPLE_FILE" "$TARGET_CONFIG"
  echo "Wrote: $TARGET_CONFIG (from $DETECTED_TYPE example)"
fi

# ---- 4. Write v2 feature_list.json ----
FEATURE_LIST="$ROOT_DIR/feature_list.json"
if [ ! -f "$FEATURE_LIST" ]; then
  cp "$TEMPLATE_DIR/feature_list.json" "$FEATURE_LIST"
  echo "Wrote: $FEATURE_LIST"
else
  # If existing feature_list.json lacks revision field, back it up (Phase 6
  # migration is out of scope here; we only ensure v2 schema presence)
  if ! jq -e 'has("revision")' "$FEATURE_LIST" >/dev/null 2>&1; then
    BACKUP="${FEATURE_LIST}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$FEATURE_LIST" "$BACKUP"
    cp "$TEMPLATE_DIR/feature_list.json" "$FEATURE_LIST"
    echo "Existing feature_list.json lacked 'revision' field; backed up to $BACKUP and wrote v2 template"
  else
    echo "Existing feature_list.json already has 'revision'; keeping it"
  fi
fi

# ---- 5. Update .gitignore ----
GITIGNORE="$ROOT_DIR/.gitignore"
GITIGNORE_ENTRY=".harness/logs/"
GITIGNORE_ENTRY2=".harness/.registry.lock/"

needs_ignore_update="false"
if [ ! -f "$GITIGNORE" ]; then
  needs_ignore_update="true"
elif ! grep -qF "$GITIGNORE_ENTRY" "$GITIGNORE" 2>/dev/null; then
  needs_ignore_update="true"
fi

if [ "$needs_ignore_update" = "true" ]; then
  {
    [ -f "$GITIGNORE" ] && cat "$GITIGNORE"
    echo ""
    echo "# harness-companion"
    echo "$GITIGNORE_ENTRY"
    echo "$GITIGNORE_ENTRY2"
  } > "${GITIGNORE}.tmp" 2>/dev/null || true
  mv "${GITIGNORE}.tmp" "$GITIGNORE"
  echo "Updated: $GITIGNORE (added harness-companion entries)"
fi

echo ""
echo "harness-companion init complete (type=$DETECTED_TYPE)"
echo "Next steps:"
echo "  1. Review .harness/config.json — adjust commands as needed"
echo "  2. Add features: edit feature_list.json"
echo "  3. Verify: harness-verify.sh <feature_id>"