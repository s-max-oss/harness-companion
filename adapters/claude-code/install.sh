#!/bin/bash
# adapters/claude-code/install.sh — Install the Claude Code adapter + core + v1 wrappers
#
# Phase 4: Implements the Core/Adapter split. Installs:
#   - core/                       (semantic core — engine + libs)
#   - templates/                  (config templates)
#   - adapters/claude-code/       (Claude Code SessionStart + Stop protocol mapping)
#   - scripts/                    (v1 compat wrappers — zero business logic)
#
# Usage:
#   bash adapters/claude-code/install.sh [--user|--project] [--symlink-core]
#
# --user:           Install to ~/.claude/skills/harness-companion/ (global, default)
# --project:        Install to ./.claude/skills/harness-companion/ (project-local)
# --symlink-core:   Symlink core/ instead of copying (Linux/macOS only; Windows copies)
#
# Hooks registered in ~/.claude/settings.json point at scripts/hooks/*.sh so that
# v1 callers keep working.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE="--user"
USE_SYMLINK_CORE=0
for arg in "$@"; do
  case "$arg" in
    --user)    MODE="--user" ;;
    --project) MODE="--project" ;;
    --symlink-core) USE_SYMLINK_CORE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ---- Windows symlink safety ----------------------------------------------------
# Git Bash on Windows reports itself as "Linux" via uname but mklink / ln -s
# produce broken links or require admin. Detect Windows reliably.
IS_WINDOWS=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|CYGWIN*|MSYS*) IS_WINDOWS=1 ;;
esac

if [ "$USE_SYMLINK_CORE" -eq 1 ] && [ "$IS_WINDOWS" -eq 1 ]; then
  echo "Note: --symlink-core is not supported on Windows; falling back to copy." >&2
  USE_SYMLINK_CORE=0
fi

# ---- Resolve target ------------------------------------------------------------
if [ "$MODE" = "--project" ]; then
  TARGET="$(pwd)/.claude/skills/harness-companion"
else
  TARGET="$HOME/.claude/skills/harness-companion"
fi

echo "=== Harness Companion Install (Phase 4 — Claude Code adapter) ==="
echo ""
echo "Mode:       $MODE"
echo "Symlink:    $USE_SYMLINK_CORE"
echo "Target:     $TARGET"
echo ""

mkdir -p "$TARGET"

# ---- Copy core/ (or symlink if requested) -------------------------------------
echo "[1/4] Installing core..."
SRC_CORE="$REPO_ROOT/core"
if [ "$USE_SYMLINK_CORE" -eq 1 ]; then
  ln -sfn "$SRC_CORE" "$TARGET/core"
  echo "  symlinked core -> $SRC_CORE"
else
  rm -rf "$TARGET/core" 2>/dev/null || true
  cp -r "$SRC_CORE" "$TARGET/core"
  echo "  copied core/ ($(find "$TARGET/core" -type f | wc -l | tr -d ' ') files)"
fi

# ---- Copy templates/ -----------------------------------------------------------
echo "[2/4] Installing templates..."
rm -rf "$TARGET/templates" 2>/dev/null || true
cp -r "$REPO_ROOT/templates" "$TARGET/templates"
echo "  copied templates/ ($(find "$TARGET/templates" -type f | wc -l | tr -d ' ') files)"

# ---- Copy adapters/claude-code/ -----------------------------------------------
echo "[3/5] Installing Claude Code adapter..."
rm -rf "$TARGET/adapters" 2>/dev/null || true
mkdir -p "$TARGET/adapters/claude-code/hooks"
cp "$ADAPTER_DIR/hooks/"*.sh "$TARGET/adapters/claude-code/hooks/"
cp "$ADAPTER_DIR/install.sh" "$TARGET/adapters/claude-code/install.sh" 2>/dev/null || true
echo "  copied adapters/claude-code/hooks/"

# ---- Copy scripts/ (v1 compat wrappers — never symlinks) ----------------------
echo "[4/5] Installing v1 compat wrappers..."
rm -rf "$TARGET/scripts" 2>/dev/null || true
mkdir -p "$TARGET/scripts/hooks"
for f in "$REPO_ROOT/scripts/"*.sh; do
  [ -f "$f" ] && cp "$f" "$TARGET/scripts/$(basename "$f")"
done
for f in "$REPO_ROOT/scripts/hooks/"*.sh; do
  [ -f "$f" ] && cp "$f" "$TARGET/scripts/hooks/$(basename "$f")"
done
echo "  copied scripts/ ($(find "$TARGET/scripts" -type f -name '*.sh' | wc -l | tr -d ' ') wrapper files)"

# ---- Copy SKILL.md (so Claude Code can discover this skill) ------------------
echo "[5/5] Installing SKILL.md..."
if [ -f "$REPO_ROOT/SKILL.md" ]; then
  cp "$REPO_ROOT/SKILL.md" "$TARGET/SKILL.md"
  echo "  copied SKILL.md ($(wc -l < "$TARGET/SKILL.md" | tr -d ' ') lines)"
else
  echo "  [WARN] SKILL.md missing in source tree — skill will not be discoverable" >&2
fi

# ---- Make all .sh files executable --------------------------------------------
chmod +x "$TARGET/scripts/"*.sh 2>/dev/null || true
chmod +x "$TARGET/scripts/hooks/"*.sh 2>/dev/null || true
chmod +x "$TARGET/core/"*.sh 2>/dev/null || true
chmod +x "$TARGET/adapters/claude-code/hooks/"*.sh 2>/dev/null || true
chmod +x "$TARGET/adapters/claude-code/install.sh" 2>/dev/null || true

# ---- Stamp installed_at + generate integrity manifest -------------------------
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

RECEIPT="$TARGET/install-receipt.json"
if [ ! -f "$RECEIPT" ]; then
  cat > "$RECEIPT" <<JSON
{
  "skill": "harness-companion",
  "version": "2.0.0",
  "schema_version": "2.0.0",
  "source": {
    "repository": "harness-engineering",
    "branch": "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)",
    "commit": "$SOURCE_COMMIT",
    "commit_short": "$(printf '%s' "$SOURCE_COMMIT" | cut -c1-12)"
  },
  "installed_at": "$INSTALLED_AT",
  "installed_to": "$TARGET",
  "integrity": {
    "algorithm": "sha256",
    "files": {}
  }
}
JSON
fi

if command -v jq >/dev/null 2>&1; then
  jq --arg ts "$INSTALLED_AT" '.installed_at = $ts' "$RECEIPT" > "$RECEIPT.tmp" \
    && mv "$RECEIPT.tmp" "$RECEIPT"
fi

# Generate SHA-256 hashes for the v1 compat scripts (so the receipt documents
# the wrappers that get invoked).
if command -v jq >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
  files_json="$(jq -c '.integrity.files // {}' "$RECEIPT")"
  for path in \
    "scripts/harness-verify.sh" \
    "scripts/harness-feature.sh" \
    "scripts/harness-status.sh" \
    "scripts/harness-audit.sh" \
    "scripts/hooks/session-start.sh" \
    "scripts/hooks/stop-handoff.sh" \
    "adapters/claude-code/hooks/session-start.sh" \
    "adapters/claude-code/hooks/stop-handoff.sh"; do
    f="$TARGET/$path"
    [ -f "$f" ] || continue
    h="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
    files_json="$(jq --arg p "$path" --arg h "$h" '.[$p] = $h' <<<"$files_json")"
  done
  jq --argjson files "$files_json" '.integrity.files = $files' "$RECEIPT" > "$RECEIPT.tmp" \
    && mv "$RECEIPT.tmp" "$RECEIPT"
fi

# ---- Register hooks in settings.json (real mutation; idempotent) ------------
if [ "$MODE" = "--project" ]; then
  SETTINGS_FILE="$(pwd)/.claude/settings.json"
  mkdir -p "$(dirname "$SETTINGS_FILE")" 2>/dev/null || true
else
  SETTINGS_FILE="$HOME/.claude/settings.json"
  mkdir -p "$(dirname "$SETTINGS_FILE")" 2>/dev/null || true
fi

HOOK_SS_CMD="bash $TARGET/scripts/hooks/session-start.sh"
HOOK_STOP_CMD="bash $TARGET/scripts/hooks/stop-handoff.sh"

register_hooks() {
  local settings="$1"
  local hook_ss_cmd="$2"
  local hook_stop_cmd="$3"

  # Idempotency: if both our commands are already in the file, do nothing.
  if [ -f "$settings" ] && grep -qF "$hook_ss_cmd" "$settings" 2>/dev/null \
                          && grep -qF "$hook_stop_cmd" "$settings" 2>/dev/null; then
    echo "  hooks already registered in $settings (idempotent)"
    return 0
  fi

  # Backup BEFORE mutating (unique timestamped filename).
  if [ -f "$settings" ]; then
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
    local backup="${settings}.bak.${stamp}"
    cp -p "$settings" "$backup"
    echo "  backup written: $backup"
  fi

  # Build the new settings via jq — merge into existing structure if present.
  # Strategy:
  #   1. If file missing or invalid JSON, start from {}.
  #   2. Ensure .hooks exists (object).
  #   3. Ensure .hooks.SessionStart exists as an array.
  #   4. Append our SessionStart entry unless a command-matching entry already exists.
  #   5. Same for .hooks.Stop.
  local tmp="${settings}.tmp.$$"
  if [ -f "$settings" ] && jq -e . "$settings" >/dev/null 2>&1; then
    cp "$settings" "$tmp"
  else
    printf '{}\n' > "$tmp"
  fi

  jq --arg ss_cmd "$hook_ss_cmd" --arg stop_cmd "$hook_stop_cmd" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    .hooks.Stop         //= [] |
    ( .hooks.SessionStart |= (if any(.[]?.hooks[]?; .command == $ss_cmd)
                              then . else . + [{"matcher":"startup|resume","hooks":[{"type":"command","command":$ss_cmd,"timeout":5000}]}] end)
    ) |
    ( .hooks.Stop         |= (if any(.[]?.hooks[]?; .command == $stop_cmd)
                              then . else . + [{"matcher":"*","hooks":[{"type":"command","command":$stop_cmd,"timeout":5000}]}] end)
    )
  ' "$tmp" > "${tmp}.out" && mv "${tmp}.out" "$settings"
  rm -f "$tmp"

  echo "  hooks registered: $settings"
}

echo ""
echo "[hooks] Registering hooks in settings.json..."
register_hooks "$SETTINGS_FILE" "$HOOK_SS_CMD" "$HOOK_STOP_CMD"

echo ""
echo "=== Install Complete ==="
echo ""
echo "Installed:"
echo "  core/                              $([ -d "$TARGET/core" ] && echo OK || echo MISSING)"
echo "  templates/                         $([ -d "$TARGET/templates" ] && echo OK || echo MISSING)"
echo "  adapters/claude-code/hooks/        $(ls "$TARGET/adapters/claude-code/hooks/"*.sh 2>/dev/null | wc -l | tr -d ' ') hooks"
echo "  scripts/ (v1 wrappers)             $(ls "$TARGET/scripts/"*.sh "$TARGET/scripts/hooks/"*.sh 2>/dev/null | wc -l | tr -d ' ') wrappers"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code to load hooks."
echo "  2. In a harness project, try: /harness:status"