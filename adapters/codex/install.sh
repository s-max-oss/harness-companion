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
#
# BUG-1 fix (rc.2): Receipt upgrade contract — same-version reinstall updates
# installed_at without appending upgrade_history; cross-version upgrade appends.
#
# BUG-2 fix (rc.2): Reads version from $REPO_ROOT/VERSION; writes $CODEX_DIR/VERSION.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---- Read version (BUG-2: single source of truth) ------------------------------
if [ -f "$REPO_ROOT/VERSION" ]; then
  VERSION="$(cat "$REPO_ROOT/VERSION" | head -1 | tr -d '[:space:]')"
else
  echo "[WARN] No VERSION file at repo root — using fallback '2.0.0'" >&2
  VERSION="2.0.0"
fi

# ---- Detect archive/tarball install (no .git) ----------------------------------
IS_ARCHIVE=0
if ! git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  IS_ARCHIVE=1
fi

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
  echo "Version:    $VERSION"
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
  cp "$ADAPTER_DIR/PHASE5B_STATUS.md" "$CODEX_DIR/adapters/codex/PHASE5B_STATUS.md"
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

  # ---- Write VERSION to target (BUG-2) ----------------------------------------
  printf '%s\n' "$VERSION" > "$CODEX_DIR/VERSION"
  echo "  VERSION = $VERSION"

  # ---- Install receipt (BUG-1 fix: upgrade-safe) ------------------------------
  INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
  RECEIPT="$CODEX_DIR/install-receipt.json"

  # Source metadata — null for archive/tarball installs
  if [ "$IS_ARCHIVE" -eq 1 ]; then
    SOURCE_COMMIT="null"
    SOURCE_COMMIT_SHORT="null"
    SOURCE_TAG=""
    SOURCE_TAG_JSON="null"
    SOURCE_ORIGIN="archive"
  else
    SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    SOURCE_COMMIT_SHORT="$(printf '%s' "$SOURCE_COMMIT" | cut -c1-12)"
    SOURCE_TAG="$(git -C "$REPO_ROOT" tag --points-at HEAD 2>/dev/null | head -1 || true)"
    if [ -n "${SOURCE_TAG:-}" ]; then
      SOURCE_TAG_JSON="\"$SOURCE_TAG\""
    else
      SOURCE_TAG_JSON="null"
    fi
    SOURCE_ORIGIN="git"
  fi

  # Helper: regenerate integrity.files via python3 (works in jq-less envs).
  # F14.2: must walk the actual installed files under $CODEX_DIR and write
  # their sha256 hashes into receipt.integrity.files (not an empty object).
  regenerate_integrity() {
    local receipt_file="$1"
    local target_dir="$2"
    if ! command -v sha256sum >/dev/null 2>&1; then
      echo "  [WARN] sha256sum not available — skipping integrity regeneration" >&2
      return 0
    fi
    if [ ! -f "$receipt_file" ]; then
      echo "  [WARN] receipt file missing — skipping integrity regeneration" >&2
      return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
      TARGET_DIR="$target_dir" RECEIPT_FILE="$receipt_file" python3 - <<'PYEOF'
import hashlib, json, os, sys
target_dir = os.environ["TARGET_DIR"]
receipt_file = os.environ["RECEIPT_FILE"]
SKIP = {"install-receipt.json", "VERSION"}
files = {}
for root, dirs, fnames in os.walk(target_dir):
    dirs.sort()
    for fn in sorted(fnames):
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, target_dir).replace(os.sep, "/")
        if rel in SKIP:
            continue
        try:
            with open(full, "rb") as f:
                h = hashlib.sha256(f.read()).hexdigest()
            files[rel] = h
        except OSError:
            continue
try:
    with open(receipt_file, "r", encoding="utf-8") as f:
        r = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    r = {}
r.setdefault("integrity", {})
r["integrity"]["algorithm"] = "sha256"
r["integrity"]["files"] = files
tmp = receipt_file + ".tmp.integ"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(r, f, indent=2)
    f.write("\n")
os.replace(tmp, receipt_file)
PYEOF
      return $?
    fi
    # Fallback: jq-based path
    local f path hash files_json="{}"
    while IFS= read -r f; do
      path="${f#$target_dir/}"
      path="$(printf '%s' "$path" | tr '\\' '/')"
      case "$path" in
        install-receipt.json|VERSION) continue ;;
      esac
      hash="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
      if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
        files_json="$(jq --arg p "$path" --arg h "$hash" '.[$p] = $h' <<<"$files_json")"
      fi
    done < <(find "$target_dir" -type f 2>/dev/null | sort)
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      jq --argjson files "$files_json" '.integrity.files = $files | .integrity.algorithm = "sha256"' "$receipt_file" > "$receipt_file.tmp" \
        && mv "$receipt_file.tmp" "$receipt_file"
    fi
  }

  # Helper: build fresh receipt
  build_fresh_codex_receipt() {
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      SOURCE_COMMIT="$SOURCE_COMMIT" \
      SOURCE_TAG_JSON="$SOURCE_TAG_JSON" \
      INSTALLED_AT="$INSTALLED_AT" \
      CODEX_DIR="$CODEX_DIR" \
      INSTALLED_HOOKS_DIR="$INSTALLED_HOOKS_DIR" \
      VERSION="$VERSION" \
      SOURCE_ORIGIN="$SOURCE_ORIGIN" \
      jq -n \
        --arg adapter codex \
        --arg version "$VERSION" \
        --arg schema "2.0.0" \
        --arg mode "repo-local" \
        --arg commit "$SOURCE_COMMIT" \
        --arg installed_at "$INSTALLED_AT" \
        --arg installed_to "$CODEX_DIR" \
        --arg plugin_root "$INSTALLED_HOOKS_DIR" \
        --arg origin "$SOURCE_ORIGIN" \
        --arg status "code-complete-runtime-e2e-pending" \
        --arg tag_json "$SOURCE_TAG_JSON" \
        '{
          adapter:$adapter, version:$version, schema_version:$schema,
          mode:$mode, status:$status,
          source:{
            repository:"harness-engineering",
            commit:(if $commit == "null" then null else $commit end),
            tag:($tag_json | fromjson),
            origin:$origin
          },
          installed_at:$installed_at, installed_to:$installed_to,
          plugin_root:$plugin_root,
          integrity:{algorithm:"sha256",files:{}},
          upgrade_history:[]
        }' > "$RECEIPT"
    elif command -v python3 >/dev/null 2>&1; then
      SOURCE_COMMIT="$SOURCE_COMMIT" \
      SOURCE_TAG="$SOURCE_TAG" \
      INSTALLED_AT="$INSTALLED_AT" \
      CODEX_DIR="$CODEX_DIR" \
      INSTALLED_HOOKS_DIR="$INSTALLED_HOOKS_DIR" \
      VERSION="$VERSION" \
      SOURCE_ORIGIN="$SOURCE_ORIGIN" \
      python3 - <<'PYEOF'
import json, os
commit = os.environ["SOURCE_COMMIT"]
source_tag = os.environ.get("SOURCE_TAG", "").strip()
receipt = {
  "adapter": "codex",
  "version": os.environ["VERSION"],
  "schema_version": "2.0.0",
  "mode": "repo-local",
  "status": "code-complete-runtime-e2e-pending",
  "source": {
    "repository": "harness-engineering",
    "commit": commit if commit != "null" else None,
    "tag": source_tag if source_tag else None,
    "origin": os.environ["SOURCE_ORIGIN"],
  },
  "installed_at": os.environ["INSTALLED_AT"],
  "installed_to": os.environ["CODEX_DIR"],
  "plugin_root": os.environ["INSTALLED_HOOKS_DIR"],
  "integrity": {"algorithm": "sha256", "files": {}},
  "upgrade_history": [],
}
with open(os.environ["CODEX_DIR"] + "/install-receipt.json", "w") as f:
    json.dump(receipt, f, indent=2)
    f.write("\n")
PYEOF
    fi
  }

  # Build receipt with upgrade logic
  if [ ! -f "$RECEIPT" ]; then
    # Fresh install
    echo "  [receipt] Fresh install — writing new receipt"
    build_fresh_codex_receipt

    # F7: Validate freshly-built receipt
    if [ -f "$RECEIPT" ]; then
      if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
        jq -e . "$RECEIPT" >/dev/null 2>&1 || {
          echo "  [ERROR] generated receipt failed jq validation: $RECEIPT" >&2
          exit 1
        }
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$RECEIPT" >/dev/null 2>&1 || {
          echo "  [ERROR] generated receipt failed python3 validation: $RECEIPT" >&2
          exit 1
        }
      fi
    else
      echo "  [ERROR] receipt file was not created: $RECEIPT" >&2
      exit 1
    fi

    # F14.2: regenerate integrity.files by walking the installed tree
    regenerate_integrity "$RECEIPT" "$CODEX_DIR"
  else
    # Existing receipt: check version for upgrade
    OLD_VERSION=""
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      OLD_VERSION="$(jq -r '.version // ""' "$RECEIPT" 2>/dev/null || echo "")"
    elif command -v python3 >/dev/null 2>&1; then
      OLD_VERSION="$(python3 -c "import json; d=json.load(open('$RECEIPT')); print(d.get('version',''))" 2>/dev/null || echo "")"
    fi

    if [ "$OLD_VERSION" = "$VERSION" ]; then
      # Same-version reinstall: update installed_at + regenerate integrity,
      # NO upgrade_history. Integrity must reflect current disk state even on
      # same-version reinstall (files may have been tampered or repaired).
      echo "  [receipt] Same-version reinstall ($VERSION) — updating installed_at + integrity"
      if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
        jq --arg ts "$INSTALLED_AT" '.installed_at = $ts' "$RECEIPT" > "$RECEIPT.tmp" \
          && mv "$RECEIPT.tmp" "$RECEIPT"
      fi
      # F14.2/G0-rev2: regenerate integrity on same-version reinstall
      regenerate_integrity "$RECEIPT" "$CODEX_DIR"
    elif [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$VERSION" ]; then
      # Cross-version upgrade: update version, source, installed_at; append upgrade_history
      echo "  [receipt] Upgrade: $OLD_VERSION → $VERSION — appending upgrade_history"
      if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
        jq \
          --arg version "$VERSION" \
          --arg commit "$SOURCE_COMMIT" \
          --arg ts "$INSTALLED_AT" \
          --arg origin "$SOURCE_ORIGIN" \
          --arg old_ver "$OLD_VERSION" \
          --arg new_ver "$VERSION" \
          --arg at "$INSTALLED_AT" \
          --arg tag_json "$SOURCE_TAG_JSON" \
          '.version = $version
           | .source.commit = (if $commit == "null" then null else $commit end)
           | .source.tag = ($tag_json | fromjson)
           | .source.origin = $origin
           | .installed_at = $ts
           | .upgrade_history += [{from: $old_ver, to: $new_ver, at: $at}]' \
          "$RECEIPT" > "$RECEIPT.tmp" \
          && mv "$RECEIPT.tmp" "$RECEIPT"
      elif command -v python3 >/dev/null 2>&1; then
        OLD_VERSION="$OLD_VERSION" \
        VERSION="$VERSION" \
        INSTALLED_AT="$INSTALLED_AT" \
        SOURCE_COMMIT="$SOURCE_COMMIT" \
        SOURCE_TAG="$SOURCE_TAG" \
        SOURCE_ORIGIN="$SOURCE_ORIGIN" \
        RECEIPT="$RECEIPT" \
        python3 - <<'PYEOF'
import json, os
receipt_file = os.environ["RECEIPT"]
with open(receipt_file) as f:
    r = json.load(f)
commit = os.environ["SOURCE_COMMIT"]
source_tag = os.environ.get("SOURCE_TAG", "").strip()
r["version"] = os.environ["VERSION"]
r["source"]["commit"] = commit if commit != "null" else None
r["source"]["tag"] = source_tag if source_tag else None
r["source"]["origin"] = os.environ["SOURCE_ORIGIN"]
r["installed_at"] = os.environ["INSTALLED_AT"]
r.setdefault("upgrade_history", []).append({
    "from": os.environ["OLD_VERSION"],
    "to": os.environ["VERSION"],
    "at": os.environ["INSTALLED_AT"],
})
with open(receipt_file, "w") as f:
    json.dump(r, f, indent=2)
    f.write("\n")
PYEOF
      fi

      # F14.2: regenerate integrity.files after upgrade mutation
      regenerate_integrity "$RECEIPT" "$CODEX_DIR"
    else
      # Can't determine old version — update what we can
      echo "  [receipt] Unknown prior version — updating installed_at"
      if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
        jq --arg ts "$INSTALLED_AT" '.installed_at = $ts' "$RECEIPT" > "$RECEIPT.tmp" \
          && mv "$RECEIPT.tmp" "$RECEIPT"
      fi
    fi

    # F7: Validate receipt is still valid JSON after mutation
    if [ -f "$RECEIPT" ]; then
      if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
        jq -e . "$RECEIPT" >/dev/null 2>&1 || {
          echo "  [ERROR] receipt became invalid JSON after upgrade mutation: $RECEIPT" >&2
          exit 1
        }
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$RECEIPT" >/dev/null 2>&1 || {
          echo "  [ERROR] receipt became invalid JSON after upgrade mutation: $RECEIPT" >&2
          exit 1
        }
      fi
    fi
  fi
  echo "  receipt written: $RECEIPT"

  # F7: Final receipt sanity check — must contain required fields
  if [ -f "$RECEIPT" ]; then
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      if ! jq -e '.version and .adapter and .installed_at and .installed_to and .integrity and .upgrade_history and .source' "$RECEIPT" >/dev/null 2>&1; then
        echo "  [ERROR] receipt missing required fields (version, adapter, installed_at, installed_to, integrity, upgrade_history, source)" >&2
        exit 1
      fi
    elif command -v python3 >/dev/null 2>&1; then
      if ! python3 -c "
import json, sys
r = json.load(open(sys.argv[1]))
for k in ('version','adapter','installed_at','installed_to','integrity','upgrade_history','source'):
    assert k in r, f'missing field: {k}'
" "$RECEIPT" >/dev/null 2>&1; then
        echo "  [ERROR] receipt missing required fields" >&2
        exit 1
      fi
    fi
  fi

  echo ""
  echo "=== Repo-local install complete (Phase 5b) ==="
  echo "  version:        $VERSION"
  echo "  hooks.json:     $HOOKS_JSON"
  echo "  core/:          $CODEX_DIR/core/"
  echo "  adapter/:       $CODEX_DIR/adapters/codex/"
  echo "  installed at:   $INSTALLED_AT"
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
  echo "Version:    $VERSION"
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