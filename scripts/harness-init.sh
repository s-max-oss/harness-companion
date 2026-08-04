#!/bin/bash
# harness-init.sh — Unified v1+v2 project scaffold generator
#
# Phase 2 merge: combines v1 (AGENTS.md, CLAUDE.md, project env init.sh) and
# v2 (.harness/config.json + project-type detection, .harness/logs/runs/, v2
# feature_list.json with revision: 1, .gitignore updates) into one entry point.
#
# Usage:
#   bash harness-init.sh [project_dir] [--minimal|--full] [--host=claude|codex] [--force-config]
#
# Output (in target project):
#   AGENTS.md                              (always)
#   CLAUDE.md                              (--host=claude, default) OR
#   codex-progress.md                      (--host=codex)
#   init.sh                                (project environment helper, executable)
#   .harness/config.json                   (project-type specific example)
#   .harness/logs/runs/                    (run-log directory)
#   feature_list.json                      (v2 schema, revision: 1)
#   .gitignore                             (added .harness/logs/ etc.)
#
# --full adds: claude-progress.md, session-handoff.md, clean-state-checklist.md, checklist.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$ROOT_DIR/templates"
V2_INIT="$TEMPLATES_DIR/init.sh"

# ---- Argument parsing -------------------------------------------------------
TARGET=""
MODE="--minimal"
HOST="claude"
FORCE_CONFIG="false"

for arg in "$@"; do
  case "$arg" in
    --minimal|--full) MODE="$arg" ;;
    --host=*)         HOST="${arg#--host=}" ;;
    --force-config)   FORCE_CONFIG="true" ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    -*)
      echo "harness-init.sh: unknown flag '$arg'" >&2
      exit 2
      ;;
    *)
      if [ -z "$TARGET" ]; then
        TARGET="$arg"
      else
        echo "harness-init.sh: multiple target dirs not supported: '$TARGET' and '$arg'" >&2
        exit 2
      fi
      ;;
  esac
done

TARGET="${TARGET:-.}"
if [ ! -d "$TARGET" ]; then
  echo "harness-init.sh: target directory '$TARGET' does not exist" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"
PROJECT_NAME="$(basename "$TARGET")"

echo "=== Harness Init (v1+v2 merge): $PROJECT_NAME ==="
echo "Mode:  $MODE"
echo "Host:  $HOST"
echo ""

# ---- helper: copy template with placeholder replacement ---------------------
copy_template() {
  local src="$1" dest="$2" description="$3"
  if [ -f "$dest" ]; then
    echo "  SKIP: $dest already exists"
    return
  fi
  if [ ! -f "$src" ]; then
    echo "  MISSING TEMPLATE: $src"
    return
  fi
  sed -e "s/replace-with-project-name/$PROJECT_NAME/g" \
      -e "s/YYYY-MM-DD/$(date +%Y-%m-%d 2>/dev/null || date +%F)/g" \
      -e "s/\[Replace with a short paragraph describing what this project is and its key characteristics.\]/[Describe your project here.]/g" \
      -e "s/\[One-sentence summary of what this project is.\]/[Your project summary here.]/g" \
      -e "s/\[Add your project-specific conventions here\]//g" \
      -e "s/\[Add your project's key rules here\]//g" \
      -e "s/\[Describe the architectural layers of your project. For Electron apps:\]//g" \
      "$src" > "$dest"
  echo "  OK: $dest ($description)"
}

# ---- Phase C: v2 scaffold (.harness/*, v2 feature_list.json, .gitignore) ----
# Run BEFORE Phase A so that project-type detection (which inspects *.md,
# package.json, etc.) reflects the user's true target state — not the AGENTS.md
# or CLAUDE.md we are about to scaffold.
echo ""
echo "[Phase C — v2 .harness scaffold (run first so detection reflects target state)]"

if [ ! -f "$V2_INIT" ]; then
  echo "  ERROR: v2 init.sh template missing at $V2_INIT" >&2
  exit 1
fi

V2_FLAGS=()
[ "$FORCE_CONFIG" = "true" ] && V2_FLAGS+=(--force-config)
bash "$V2_INIT" "$TARGET" "${V2_FLAGS[@]}"

# ---- Phase A: v1 scaffold (knowledge + project env init.sh) ----------------
echo ""
echo "[Phase A — v1 knowledge + project env scaffold]"

copy_template "$TEMPLATES_DIR/AGENTS.md" "$TARGET/AGENTS.md" "Agent operating manual (universal entry)"

if [ "$HOST" = "codex" ]; then
  copy_template "$TEMPLATES_DIR/claude-progress.md" "$TARGET/codex-progress.md" "Codex progress log"
else
  copy_template "$TEMPLATES_DIR/CLAUDE.md" "$TARGET/CLAUDE.md" "Claude Code quick reference"
fi

# Project environment helper init.sh — comes from templates/env-init.sh
# (different from the v2 templates/init.sh scaffold generator — this is the
# per-project env verification script that v1 users expect).
copy_template "$TEMPLATES_DIR/env-init.sh" "$TARGET/init.sh" "Project environment helper (chmod +x below)"
if [ -f "$TARGET/init.sh" ]; then
  chmod +x "$TARGET/init.sh" 2>/dev/null || true
  echo "  OK: init.sh made executable"
fi

# ---- Phase B: --full extra files --------------------------------------------
if [ "$MODE" = "--full" ]; then
  echo ""
  echo "[Phase A.5 — --full extra files]"
  if [ "$HOST" = "codex" ]; then
    copy_template "$TEMPLATES_DIR/claude-progress.md" "$TARGET/codex-progress.md" "Codex progress log"
  else
    copy_template "$TEMPLATES_DIR/claude-progress.md" "$TARGET/claude-progress.md" "Session progress log"
  fi
  copy_template "$TEMPLATES_DIR/session-handoff.md"      "$TARGET/session-handoff.md"      "Session handoff doc"
  copy_template "$TEMPLATES_DIR/clean-state-checklist.md" "$TARGET/clean-state-checklist.md" "Pre-commit verification"
  copy_template "$TEMPLATES_DIR/checklist.sh"             "$TARGET/checklist.sh"             "Executable handoff checklist"
  if [ -f "$TARGET/checklist.sh" ]; then
    chmod +x "$TARGET/checklist.sh" 2>/dev/null || true
    echo "  OK: checklist.sh made executable"
  fi
fi

echo ""
echo "=== Harness scaffold complete (v1+v2 merge) ==="
echo ""
echo "Created:"
echo "  Knowledge entry:  AGENTS.md (universal) + $([ "$HOST" = "codex" ] && echo codex-progress.md || echo CLAUDE.md)"
echo "  Env helper:       init.sh (executable)"
echo "  v2 config:        .harness/config.json (auto-detected type)"
echo "  v2 run logs:      .harness/logs/runs/"
echo "  v2 features:      feature_list.json (revision: 1)"
echo "  .gitignore:       .harness/logs/ + .harness/.registry.lock/"
echo ""
echo "Next steps:"
echo "  1. Review .harness/config.json — adjust verification commands"
echo "  2. Edit feature_list.json — add your real features"
echo "  3. Run 'bash init.sh' to verify the project environment"