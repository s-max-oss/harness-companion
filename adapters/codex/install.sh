#!/bin/bash
# adapters/codex/install.sh — Install the Codex adapter (Phase 5b)
#
# Phase 5b: Real Codex plugin/hooks integration. SessionStart injects status
# via hookSpecificOutput.additionalContext; Stop emits handoff warnings via
# systemMessage; PreToolUse exits permissively with "policy not enabled".
#
# Three independent modes. MUST NOT combine modes.
#
# Usage:
#   bash adapters/codex/install.sh                  # plugin mode (instructions only)
#   bash adapters/codex/install.sh --repo [path]    # repo-local install
#   bash adapters/codex/install.sh --user           # user-mode TOML snippet
#
# Mode behavior:
#   - plugin:   not handled by this script — print Codex marketplace instructions.
#   - --repo:   Copy core/ + adapters/codex/ to <target>/.codex/, write
#               <target>/.codex/hooks.json with paths pointing at the
#               COPIES in <target>/.codex/adapters/codex/hooks/. Source-tree
#               removal does NOT break the installed hooks.
#   - --user:   Write ~/.codex/harness-hooks.toml snippet. Do NOT auto-edit
#               ~/.codex/config.toml — print manual merge instructions.
#
# JSON construction in --repo requires `jq` OR `python3`. If neither is
# available, install fails with an actionable error.
#
# All modes: idempotent, backup before modification, trust review prompt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== harness-companion Codex adapter — Phase 5b ==="
echo "SessionStart: status injection  |  Stop: handoff warnings  |  PreToolUse: permissive"
echo ""

# ---- Argument parsing ----------------------------------------------------------
MODE=""
REPO_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      MODE="--repo"
      shift
      if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
        REPO_TARGET="${1:-}"
        shift
      fi
      ;;
    --user)
      MODE="--user"
      shift
      ;;
    --help|-h)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# ---- Backup helper -------------------------------------------------------------
backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
  local backup="${f}.bak.${stamp}"
  cp -p "$f" "$backup"
  echo "  backup written: $backup"
}

# ---- Path helpers --------------------------------------------------------------
to_posix_path() {
  local p="$1"
  printf '%s' "$p" | tr '\\' '/'
}

# ===============================================================================
# Plugin mode (default — no flag)
# ===============================================================================
if [ -z "$MODE" ]; then
  echo "Mode: plugin (instructions only)"
  echo ""
  echo "Plugin mode is handled by Codex marketplace / 'codex plugin install'."
  echo "This script does NOT install the plugin."
  echo ""
  echo "For plugin-mode install, place this repo under your Codex plugins directory"
  echo "or register it in ~/.agents/plugins/marketplace.json."
  echo "For repo-local or user-global install, use --repo <project-dir> or --user."
  exit 0
fi

# ===============================================================================
# Repo-local mode (--repo [path])
# ===============================================================================
if [ "$MODE" = "--repo" ]; then
  TARGET="${REPO_TARGET:-$(pwd)}"
  TARGET="$(cd "$TARGET" && pwd 2>/dev/null || { echo "Error: --repo target '$REPO_TARGET' not a directory" >&2; exit 1; })"
  CODEX_DIR="$TARGET/.codex"
  HOOKS_JSON="$CODEX_DIR/hooks.json"
  # All hook paths point at the COPY in the target tree, NOT at the source.
  INSTALLED_HOOKS_DIR="$CODEX_DIR/adapters/codex/hooks"

  # Resolve installed paths in both POSIX and Windows forms. The COPIES live
  # under the target, so source-tree moves cannot break the installed hooks.
  POSIX_INSTALLED="$(to_posix_path "$INSTALLED_HOOKS_DIR")"
  WINDOWS_INSTALLED="${INSTALLED_HOOKS_DIR//\//\\}"

  echo "Mode:       --repo (repo-local)"
  echo "Target:     $CODEX_DIR"
  echo "HookPath:   $POSIX_INSTALLED"
  echo ""

  mkdir -p "$CODEX_DIR"

  # ---- Copy core/ -------------------------------------------------------------
  echo "[1/4] Installing core..."
  SRC_CORE="$REPO_ROOT/core"
  rm -rf "$CODEX_DIR/core" 2>/dev/null || true
  cp -r "$SRC_CORE" "$CODEX_DIR/core"
  echo "  copied core/ ($(find "$CODEX_DIR/core" -type f | wc -l | tr -d ' ') files)"

  # ---- Copy adapters/codex/ ---------------------------------------------------
  echo "[2/4] Installing Codex adapter..."
  rm -rf "$CODEX_DIR/adapters" 2>/dev/null || true
  mkdir -p "$INSTALLED_HOOKS_DIR"
  cp "$ADAPTER_DIR/hooks/"*.sh "$INSTALLED_HOOKS_DIR/"
  cp "$ADAPTER_DIR/hooks/"*.cmd "$INSTALLED_HOOKS_DIR/"
  cp "$ADAPTER_DIR/install.sh" "$CODEX_DIR/adapters/codex/install.sh"
  cp "$ADAPTER_DIR/adapter.conf" "$CODEX_DIR/adapters/codex/adapter.conf"
  cp "$ADAPTER_DIR/UNSUPPORTED.md" "$CODEX_DIR/adapters/codex/UNSUPPORTED.md"  # renamed to PHASE5B_STATUS.md
  echo "  copied adapters/codex/ → $CODEX_DIR/adapters/codex/"

  # ---- Backup existing hooks.json if present ---------------------------------
  if [ -f "$HOOKS_JSON" ]; then
    if grep -qF "$INSTALLED_HOOKS_DIR/session-start.sh" "$HOOKS_JSON" 2>/dev/null \
       && grep -qF "$INSTALLED_HOOKS_DIR/stop-handoff.sh" "$HOOKS_JSON" 2>/dev/null \
       && grep -qF "$INSTALLED_HOOKS_DIR/pre-tool-use.sh" "$HOOKS_JSON" 2>/dev/null; then
      echo "[3/4] hooks.json already points at installed hooks — leaving as-is (idempotent)"
    else
      echo "[3/4] Backing up existing hooks.json (does not reference installed hooks)..."
      backup_file "$HOOKS_JSON"
    fi
  else
    echo "[3/4] No existing hooks.json — will write fresh"
  fi

  # ---- Construct hooks.json (jq preferred, python3 fallback) ------------------
  echo "[4/4] Writing hooks.json with paths under $POSIX_INSTALLED ..."

  # Construct hook commands using the INSTALLED path (not source tree).
  SS_POSIX="bash \"${POSIX_INSTALLED}/session-start.sh\""
  SS_WIN="${WINDOWS_INSTALLED}\\session-start.cmd"
  STOP_POSIX="bash \"${POSIX_INSTALLED}/stop-handoff.sh\""
  STOP_WIN="${WINDOWS_INSTALLED}\\stop-handoff.cmd"
  PTU_POSIX="bash \"${POSIX_INSTALLED}/pre-tool-use.sh\""
  PTU_WIN="${WINDOWS_INSTALLED}\\pre-tool-use.cmd"

  wrote=0
  # Validate that jq actually works, not just exists in PATH. A stub or
  # broken jq must not silently produce invalid JSON — fall through to
  # python3 in that case.
  if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
    jq -n \
      --arg ss_p "$SS_POSIX" --arg ss_w "$SS_WIN" \
      --arg stop_p "$STOP_POSIX" --arg stop_w "$STOP_WIN" \
      --arg ptu_p "$PTU_POSIX" --arg ptu_w "$PTU_WIN" \
      '{
        hooks: {
          SessionStart: [{hooks: [{type:"command", command:$ss_p, commandWindows:$ss_w, timeout:5}]}],
          Stop:         [{hooks: [{type:"command", command:$stop_p, commandWindows:$stop_w, timeout:5}]}],
          PreToolUse:   [{hooks: [{type:"command", command:$ptu_p, commandWindows:$ptu_w, timeout:5}]}]
        }
      }' > "$HOOKS_JSON"
    wrote=1
    echo "  constructed via jq"
  elif command -v python3 >/dev/null 2>&1; then
    # No-jq fallback. Use python3 json.dumps so Windows backslashes stay
    # safely escaped — heredoc would reduce \\ to \ and break JSON.
    INSTALLED_HOOKS_DIR_WIN="$WINDOWS_INSTALLED" \
    SS_POSIX="$SS_POSIX" SS_WIN="$SS_WIN" \
    STOP_POSIX="$STOP_POSIX" STOP_WIN="$STOP_WIN" \
    PTU_POSIX="$PTU_POSIX" PTU_WIN="$PTU_WIN" \
    HOOKS_JSON="$HOOKS_JSON" \
    python3 - <<'PYEOF'
import json, os, sys
hooks_dir_win = os.environ["INSTALLED_HOOKS_DIR_WIN"]
hooks_dir_posix = hooks_dir_win.replace("\\", "/")
data = {
  "hooks": {
    "SessionStart": [{"hooks": [{
      "type": "command",
      "command": os.environ["SS_POSIX"],
      "commandWindows": os.environ["SS_WIN"],
      "timeout": 5,
    }]}],
    "Stop": [{"hooks": [{
      "type": "command",
      "command": os.environ["STOP_POSIX"],
      "commandWindows": os.environ["STOP_WIN"],
      "timeout": 5,
    }]}],
    "PreToolUse": [{"hooks": [{
      "type": "command",
      "command": os.environ["PTU_POSIX"],
      "commandWindows": os.environ["PTU_WIN"],
      "timeout": 5,
    }]}],
  }
}
with open(os.environ["HOOKS_JSON"], "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    wrote=1
    echo "  constructed via python3 (no-jq fallback)"
  else
    echo "  [ERROR] Neither jq nor python3 available — cannot safely construct hooks.json." >&2
    echo "          Install jq (preferred) or python3 to complete --repo install." >&2
    exit 1
  fi

  if [ "$wrote" -eq 1 ]; then
    # Validate the JSON we just wrote. Try jq first (works in normal envs),
    # then python3 (the fallback we just used).
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      jq -e . "$HOOKS_JSON" >/dev/null 2>&1 || { echo "  [ERROR] generated hooks.json failed jq validation" >&2; exit 1; }
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HOOKS_JSON" >/dev/null 2>&1 \
        || { echo "  [ERROR] generated hooks.json failed python3 validation" >&2; exit 1; }
    fi
    echo "  hooks.json written + validated: $HOOKS_JSON"
  fi

  # ---- Trust review -----------------------------------------------------------
  echo ""
  echo "[trust review] Codex hooks will execute:"
  echo "  SessionStart → $SS_POSIX"
  echo "  Stop         → $STOP_POSIX"
  echo "  PreToolUse   → $PTU_POSIX"
  echo ""
  echo "[IMPORTANT] These paths live under $POSIX_INSTALLED — a COPY inside the"
  echo "            target project's .codex/ tree. Source-tree moves do NOT break them."
  echo ""

  # ---- Make all .sh files executable -----------------------------------------
  chmod +x "$CODEX_DIR/core/"*.sh 2>/dev/null || true
  chmod +x "$INSTALLED_HOOKS_DIR/"*.sh 2>/dev/null || true
  chmod +x "$CODEX_DIR/adapters/codex/install.sh" 2>/dev/null || true

  # ---- Install receipt --------------------------------------------------------
  INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
  SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  RECEIPT="$CODEX_DIR/install-receipt.json"

  # Build receipt via jq OR python3 (avoid heredoc backslash issues).
  # Validate jq actually works, not just exists in PATH (a stub must not
  # silently produce invalid output).
  if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
    SOURCE_COMMIT="$SOURCE_COMMIT" \
    INSTALLED_AT="$INSTALLED_AT" \
    CODEX_DIR="$CODEX_DIR" \
    INSTALLED_HOOKS_DIR="$INSTALLED_HOOKS_DIR" \
    jq -n \
      --arg adapter codex \
      --arg ver "2.0.0" \
      --arg schema "2.0.0" \
      --arg mode "repo-local" \
      --arg commit "$SOURCE_COMMIT" \
      --arg installed_at "$INSTALLED_AT" \
      --arg installed_to "$CODEX_DIR" \
      --arg plugin_root "$INSTALLED_HOOKS_DIR" \
      --arg status "supported" \
      '{
        adapter:$adapter, version:$ver, schema_version:$schema,
        mode:$mode, status:$status,
        source:{repository:"harness-engineering", commit:$commit},
        installed_at:$installed_at, installed_to:$installed_to,
        plugin_root:$plugin_root
      }' > "$RECEIPT"
  elif command -v python3 >/dev/null 2>&1; then
    SOURCE_COMMIT="$SOURCE_COMMIT" \
    INSTALLED_AT="$INSTALLED_AT" \
    CODEX_DIR="$CODEX_DIR" \
    INSTALLED_HOOKS_DIR="$INSTALLED_HOOKS_DIR" \
    python3 - <<'PYEOF'
import json, os
receipt = {
  "adapter": "codex",
  "version": "2.0.0",
  "schema_version": "2.0.0",
  "mode": "repo-local",
  "status": "supported",
  "source": {"repository": "harness-engineering", "commit": os.environ["SOURCE_COMMIT"]},
  "installed_at": os.environ["INSTALLED_AT"],
  "installed_to": os.environ["CODEX_DIR"],
  "plugin_root": os.environ["INSTALLED_HOOKS_DIR"],
}
with open(os.environ["CODEX_DIR"] + "/install-receipt.json", "w") as f:
    json.dump(receipt, f, indent=2)
    f.write("\n")
PYEOF
  fi
  echo "  receipt written: $RECEIPT"

  echo ""
  echo "=== Repo-local install complete (Phase 5b) ==="
  echo "  hooks.json:    $HOOKS_JSON"
  echo "  core/:         $CODEX_DIR/core/"
  echo "  adapter/:      $CODEX_DIR/adapters/codex/"
  echo "  installed at:  $INSTALLED_AT"
  echo ""
  echo "SessionStart status injection and Stop handoff warnings are active."
  echo "PreToolUse is permissive (policy not enabled)."
  exit 0
fi

# ===============================================================================
# User mode (--user)
# ===============================================================================
if [ "$MODE" = "--user" ]; then
  USER_CODEX="${HOME}/.codex"
  SNIPPET="$USER_CODEX/harness-hooks.toml"

  echo "Mode:       --user"
  echo "Snippet:    $SNIPPET"
  echo ""
  echo "NOTE: --user mode points paths at the SOURCE tree (the location you ran"
  echo "      install.sh from). For source-tree-move safety, prefer --repo mode."
  echo ""

  mkdir -p "$USER_CODEX"

  # ---- Backup if existing ----------------------------------------------------
  if [ -f "$SNIPPET" ]; then
    backup_file "$SNIPPET"
  fi

  # Source-tree path for the snippet (user-mode is explicit about this).
  POSIX_SOURCE="$(to_posix_path "$REPO_ROOT")"
  WIN_SOURCE="${REPO_ROOT//\//\\}"
  WIN_SOURCE_ESC="${WIN_SOURCE//\\/\\\\}"

  {
    printf '# harness-companion v2 hooks (Codex adapter) — Phase 5b\n'
    printf '# Generated by adapters/codex/install.sh --user\n'
    printf '#\n'
    printf '# SessionStart injects status via hookSpecificOutput.additionalContext.\n'
    printf '# Stop emits handoff warnings via systemMessage.\n'
    printf '# PreToolUse exits permissively (policy not enabled).\n'
    printf '#\n'
    printf '# Merge each [[hooks.<Event>]] / [[hooks.<Event>.hooks]] block into your\n'
    printf '# ~/.codex/config.toml manually. Paths below point at the SOURCE tree\n'
    printf '# (%s); if you move the source tree, re-run install.sh or switch to --repo.\n' "$POSIX_SOURCE"
    printf '\n'
    printf '[[hooks.SessionStart]]\n'
    printf '[[hooks.SessionStart.hooks]]\n'
    printf 'type = "command"\n'
    printf 'command = "bash \\"%s/adapters/codex/hooks/session-start.sh\\""\n' "$POSIX_SOURCE"
    printf 'commandWindows = "%s\\\\adapters\\\\codex\\\\hooks\\\\session-start.cmd"\n' "$WIN_SOURCE_ESC"
    printf 'timeout = 5\n'
    printf '\n'
    printf '[[hooks.Stop]]\n'
    printf '[[hooks.Stop.hooks]]\n'
    printf 'type = "command"\n'
    printf 'command = "bash \\"%s/adapters/codex/hooks/stop-handoff.sh\\""\n' "$POSIX_SOURCE"
    printf 'commandWindows = "%s\\\\adapters\\\\codex\\\\hooks\\\\stop-handoff.cmd"\n' "$WIN_SOURCE_ESC"
    printf 'timeout = 5\n'
    printf '\n'
    printf '[[hooks.PreToolUse]]\n'
    printf '[[hooks.PreToolUse.hooks]]\n'
    printf 'type = "command"\n'
    printf 'command = "bash \\"%s/adapters/codex/hooks/pre-tool-use.sh\\""\n' "$POSIX_SOURCE"
    printf 'commandWindows = "%s\\\\adapters\\\\codex\\\\hooks\\\\pre-tool-use.cmd"\n' "$WIN_SOURCE_ESC"
    printf 'timeout = 5\n'
  } > "$SNIPPET"

  echo ""
  echo "[trust review] Codex hooks will execute:"
  echo "  SessionStart → bash \"${POSIX_SOURCE}/adapters/codex/hooks/session-start.sh\""
  echo "  Stop         → bash \"${POSIX_SOURCE}/adapters/codex/hooks/stop-handoff.sh\""
  echo "  PreToolUse   → bash \"${POSIX_SOURCE}/adapters/codex/hooks/pre-tool-use.sh\""
  echo ""

  echo "=== User-mode install complete (Phase 5b) ==="
  echo ""
  echo "Snippet written to: $SNIPPET"
  echo ""
  echo "Next steps:"
  echo "  1. Manually merge the contents of $SNIPPET into ~/.codex/config.toml."
  echo "     This script does NOT auto-edit config.toml."
  echo "  2. Restart Codex to load the merged hooks."
  exit 0
fi

echo "Error: unknown mode '$MODE'" >&2
exit 2
