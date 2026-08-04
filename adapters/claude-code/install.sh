#!/bin/bash
# adapters/claude-code/install.sh — Install the Claude Code adapter + core + v1 wrappers
#
# Phase 4: Implements the Core/Adapter split. Installs:
#   - core/                       (semantic core — engine + libs)
#   - templates/                  (config templates)
#   - adapters/claude-code/       (Claude Code SessionStart + Stop protocol mapping)
#   - scripts/                    (v1 compat wrappers — zero business logic)
#   - VERSION                     (semver from repo root)
#   - install-receipt.json        (upgrade-safe, with integrity manifest)
#
# Usage:
#   bash adapters/claude-code/install.sh [--user|--project] [--symlink-core]
#
# --user:           Install to ~/.claude/skills/harness-companion/ (global, default)
# --project:        Install to ./.claude/skills/harness-companion/ (project-local)
# --symlink-core:   Symlink core/ instead of copying (Linux/macOS only; Windows copies)
#
# Hooks registered in settings.json point at scripts/hooks/*.sh so that
# v1 callers keep working.
#
# BUG-1 fix (rc.2): Receipt upgrade contract — same-version reinstall updates
# installed_at + regenerates integrity.files without appending upgrade_history;
# cross-version upgrade appends upgrade_history[] entry.
#
# BUG-2 fix (rc.2): Reads version from $REPO_ROOT/VERSION; writes $TARGET/VERSION.
#
# BUG-3 fix (rc.2): Hook idempotency uses canonical path resolution (cygpath round-trip
# on MSYS, readlink -f on Linux/macOS). Fail-closed if neither jq nor python3 available.

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

# ---- Resolve target ------------------------------------------------------------
if [ "$MODE" = "--project" ]; then
  TARGET="$(pwd)/.claude/skills/harness-companion"
else
  TARGET="$HOME/.claude/skills/harness-companion"
fi

echo "=== Harness Companion Install (Phase 4 — Claude Code adapter) ==="
echo ""
echo "Version:    $VERSION"
echo "Mode:       $MODE"
echo "Symlink:    $USE_SYMLINK_CORE"
echo "Target:     $TARGET"
echo ""

mkdir -p "$TARGET"

# ---- Copy core/ (or symlink if requested) -------------------------------------
echo "[1/5] Installing core..."
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
echo "[2/5] Installing templates..."
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

# ---- Write VERSION to target (BUG-2) ------------------------------------------
printf '%s\n' "$VERSION" > "$TARGET/VERSION"
echo "  VERSION = $VERSION"

# ---- Make all .sh files executable --------------------------------------------
chmod +x "$TARGET/scripts/"*.sh 2>/dev/null || true
chmod +x "$TARGET/scripts/hooks/"*.sh 2>/dev/null || true
chmod +x "$TARGET/core/"*.sh 2>/dev/null || true
chmod +x "$TARGET/adapters/claude-code/hooks/"*.sh 2>/dev/null || true
chmod +x "$TARGET/adapters/claude-code/install.sh" 2>/dev/null || true

# ===============================================================================
# BUG-1 fix: Receipt upgrade contract
# ===============================================================================

INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

# Source metadata — null for archive/tarball installs
if [ "$IS_ARCHIVE" -eq 1 ]; then
  SOURCE_COMMIT="null"
  SOURCE_COMMIT_SHORT="null"
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

RECEIPT="$TARGET/install-receipt.json"

# Helper: generate integrity.files JSON via jq or python3.
# F14.2: must work in python3-only environments (no jq).
regenerate_integrity() {
  local receipt_file="$1"
  local target_dir="$2"
  local files_json="{}"

  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "[WARN] sha256sum not available — skipping integrity regeneration" >&2
    return 0
  fi
  if [ ! -f "$receipt_file" ]; then
    echo "[WARN] receipt file missing — skipping integrity regeneration" >&2
    return 0
  fi

  # Compute hashes via a single python3 invocation (works in jq-less envs).
  # This collects every regular file under $target_dir, computes sha256, and
  # writes the result into the receipt as .integrity.files.
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

  # Fallback: jq path (only when jq is present AND sha256sum exists)
  local f path hash
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

# Build fresh receipt JSON
build_fresh_receipt() {
  if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
    VERSION="$VERSION" \
    INSTALLED_AT="$INSTALLED_AT" \
    TARGET="$TARGET" \
    SOURCE_COMMIT="$SOURCE_COMMIT" \
    SOURCE_COMMIT_SHORT="$SOURCE_COMMIT_SHORT" \
    SOURCE_TAG_JSON="$SOURCE_TAG_JSON" \
    SOURCE_ORIGIN="$SOURCE_ORIGIN" \
    jq -n \
      --arg skill "harness-companion" \
      --arg version "$VERSION" \
      --arg schema "2.0.0" \
      --arg commit "$SOURCE_COMMIT" \
      --arg commit_short "$SOURCE_COMMIT_SHORT" \
      --arg installed_at "$INSTALLED_AT" \
      --arg installed_to "$TARGET" \
      --arg origin "$SOURCE_ORIGIN" \
      --arg tag_json "$SOURCE_TAG_JSON" \
      '{
        skill: $skill,
        version: $version,
        schema_version: $schema,
        source: {
          repository: "s-max-oss/harness-companion",
          commit: (if $commit == "null" then null else $commit end),
          commit_short: (if $commit_short == "null" then null else $commit_short end),
          tag: ($tag_json | fromjson),
          origin: $origin
        },
        installed_at: $installed_at,
        installed_to: $installed_to,
        integrity: { algorithm: "sha256", files: {} },
        upgrade_history: []
      }' > "$RECEIPT"
    return 0
  elif command -v python3 >/dev/null 2>&1; then
    SOURCE_COMMIT="$SOURCE_COMMIT" \
    SOURCE_COMMIT_SHORT="$SOURCE_COMMIT_SHORT" \
    SOURCE_TAG="${SOURCE_TAG:-}" \
    SOURCE_ORIGIN="$SOURCE_ORIGIN" \
    VERSION="$VERSION" \
    INSTALLED_AT="$INSTALLED_AT" \
    TARGET="$TARGET" \
    python3 - <<'PYEOF'
import json, os
commit = os.environ["SOURCE_COMMIT"]
commit_short = os.environ["SOURCE_COMMIT_SHORT"]
source_tag = os.environ.get("SOURCE_TAG", "").strip()
receipt = {
  "skill": "harness-companion",
  "version": os.environ["VERSION"],
  "schema_version": "2.0.0",
  "source": {
    "repository": "s-max-oss/harness-companion",
    "commit": commit if commit != "null" else None,
    "commit_short": commit_short if commit_short != "null" else None,
    "tag": source_tag if source_tag else None,
    "origin": os.environ["SOURCE_ORIGIN"],
  },
  "installed_at": os.environ["INSTALLED_AT"],
  "installed_to": os.environ["TARGET"],
  "integrity": {"algorithm": "sha256", "files": {}},
  "upgrade_history": [],
}
with open(os.environ["TARGET"] + "/install-receipt.json", "w") as f:
    json.dump(receipt, f, indent=2)
    f.write("\n")
PYEOF
    return 0
  else
    echo "[WARN] Neither jq nor python3 available — writing minimal receipt" >&2
    # F10: minimal fallback must still include source (BUG-3 contract).
    # Build tag JSON literal manually since we have no JSON encoder.
    if [ "$SOURCE_TAG_JSON" = "null" ] || [ -z "$SOURCE_TAG_JSON" ]; then
      TAG_LIT="null"
    else
      TAG_LIT="$SOURCE_TAG_JSON"
    fi
    cat > "$RECEIPT" <<JSON
{
  "skill": "harness-companion",
  "version": "$VERSION",
  "schema_version": "2.0.0",
  "source": {
    "repository": "s-max-oss/harness-companion",
    "commit": $SOURCE_COMMIT,
    "commit_short": $SOURCE_COMMIT_SHORT,
    "tag": $TAG_LIT,
    "origin": "$SOURCE_ORIGIN"
  },
  "installed_at": "$INSTALLED_AT",
  "installed_to": "$TARGET",
  "integrity": { "algorithm": "sha256", "files": {} },
  "upgrade_history": []
}
JSON
  fi
}

if [ ! -f "$RECEIPT" ]; then
  # ---- Fresh install: write new receipt ---------------------------------------
  echo "[receipt] Fresh install — writing new receipt"
  build_fresh_receipt

  # ---- Validate receipt JSON was actually written and parses -----------------
  # F7: Python-only backend silent success — must verify, not assume.
  if [ -f "$RECEIPT" ]; then
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      jq -e . "$RECEIPT" >/dev/null 2>&1 || {
        echo "[ERROR] generated receipt failed jq validation: $RECEIPT" >&2
        exit 1
      }
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$RECEIPT" >/dev/null 2>&1 || {
        echo "[ERROR] generated receipt failed python3 validation: $RECEIPT" >&2
        exit 1
      }
    fi
  else
    echo "[ERROR] receipt file was not created: $RECEIPT" >&2
    exit 1
  fi
else
  # ---- Existing receipt: upgrade logic ----------------------------------------
  OLD_VERSION=""
  if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
    OLD_VERSION="$(jq -r '.version // ""' "$RECEIPT" 2>/dev/null || echo "")"
  elif command -v python3 >/dev/null 2>&1; then
    OLD_VERSION="$(python3 -c "import json; d=json.load(open('$RECEIPT')); print(d.get('version',''))" 2>/dev/null || echo "")"
  fi

  if [ "$OLD_VERSION" = "$VERSION" ]; then
    # Same-version reinstall: update installed_at, regenerate integrity, NO upgrade_history
    echo "[receipt] Same-version reinstall ($VERSION) — updating installed_at, regenerating integrity"
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      jq --arg ts "$INSTALLED_AT" '.installed_at = $ts' "$RECEIPT" > "$RECEIPT.tmp" \
        && mv "$RECEIPT.tmp" "$RECEIPT"
    fi
  elif [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$VERSION" ]; then
    # Cross-version upgrade: update version, source, installed_at; append upgrade_history
    echo "[receipt] Upgrade: $OLD_VERSION → $VERSION — appending upgrade_history"
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      jq \
        --arg version "$VERSION" \
        --arg commit "$SOURCE_COMMIT" \
        --arg commit_short "$SOURCE_COMMIT_SHORT" \
        --arg ts "$INSTALLED_AT" \
        --arg origin "$SOURCE_ORIGIN" \
        --arg old_ver "$OLD_VERSION" \
        --arg new_ver "$VERSION" \
        --arg at "$INSTALLED_AT" \
        --arg tag_json "$SOURCE_TAG_JSON" \
        '.version = $version
         | .source.commit = (if $commit == "null" then null else $commit end)
         | .source.commit_short = (if $commit_short == "null" then null else $commit_short end)
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
      SOURCE_COMMIT_SHORT="$SOURCE_COMMIT_SHORT" \
      SOURCE_TAG="${SOURCE_TAG:-}" \
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
r["source"]["commit_short"] = os.environ["SOURCE_COMMIT_SHORT"] if os.environ["SOURCE_COMMIT_SHORT"] != "null" else None
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
  else
    # Can't determine old version — update what we can
    echo "[receipt] Unknown prior version — updating installed_at"
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      jq --arg ts "$INSTALLED_AT" '.installed_at = $ts' "$RECEIPT" > "$RECEIPT.tmp" \
        && mv "$RECEIPT.tmp" "$RECEIPT"
    fi
  fi

  # F7: Validate receipt is still valid JSON after mutation
  if [ -f "$RECEIPT" ]; then
    if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
      jq -e . "$RECEIPT" >/dev/null 2>&1 || {
        echo "[ERROR] receipt became invalid JSON after upgrade mutation: $RECEIPT" >&2
        exit 1
      }
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$RECEIPT" >/dev/null 2>&1 || {
        echo "[ERROR] receipt became invalid JSON after upgrade mutation: $RECEIPT" >&2
        exit 1
      }
    fi
  fi
fi

# Regenerate integrity.files on every install run
echo "[integrity] Regenerating integrity manifest..."
regenerate_integrity "$RECEIPT" "$TARGET"
echo "  integrity regenerated"

# F7: Final receipt sanity check — must be valid JSON, must contain required fields
if [ -f "$RECEIPT" ]; then
  if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
    if ! jq -e '.version and .skill and .installed_at and .installed_to and .integrity and .upgrade_history and .source' "$RECEIPT" >/dev/null 2>&1; then
      echo "[ERROR] receipt missing required fields (version, skill, installed_at, installed_to, integrity, upgrade_history)" >&2
      exit 1
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "
import json, sys
r = json.load(open(sys.argv[1]))
for k in ('version','skill','installed_at','installed_to','integrity','upgrade_history'):
    assert k in r, f'missing field: {k}'
" "$RECEIPT" >/dev/null 2>&1; then
      echo "[ERROR] receipt missing required fields" >&2
      exit 1
    fi
  fi
fi

# ===============================================================================
# BUG-3 fix: Hook path normalization + fail-closed
# ===============================================================================

# ---- Canonical path resolver --------------------------------------------------
# F12 (LR3 full BUG-3 matrix): canonical_path must:
#   - Round-trip through cygpath on MSYS to normalize /c/Users vs C:\Users
#   - Resolve symlinks (junctions on Windows) via readlink -f so the SAME
#     real inode yields the SAME canonical string regardless of access path
#   - Normalize case-only differences on Windows (cygpath -aw upper-cases the
#     drive letter; on case-insensitive NTFS, readlink -f returns the on-disk
#     form which is whatever the directory was created with).
canonical_path() {
  local p="$1"
  local resolved=""

  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
      if command -v cygpath >/dev/null 2>&1; then
        # Round-trip: POSIX → Windows → POSIX forces canonical MSYS form
        resolved="$(cygpath -u "$(cygpath -aw "$p" 2>/dev/null)" 2>/dev/null || echo "")"
        if [ -n "$resolved" ]; then
          # Resolve symlinks/junctions if GNU readlink is available (Git Bash ships it)
          if command -v readlink >/dev/null 2>&1; then
            local resolved2
            resolved2="$(readlink -f "$resolved" 2>/dev/null || echo "")"
            if [ -n "$resolved2" ]; then
              resolved="$resolved2"
            fi
          fi
          # Re-round-trip through cygpath in case readlink -f emitted Windows-style
          if command -v cygpath >/dev/null 2>&1 && printf '%s' "$resolved" | grep -q '\\\\'; then
            local resolved3
            resolved3="$(cygpath -u "$resolved" 2>/dev/null || echo "")"
            if [ -n "$resolved3" ]; then
              resolved="$resolved3"
            fi
          fi
          printf '%s' "$resolved"
          return 0
        fi
      fi
      # Fallback: basic normalization
      printf '%s' "$p" | tr '\\' '/'
      return 0
      ;;
    *)
      if command -v readlink >/dev/null 2>&1; then
        resolved="$(readlink -f "$p" 2>/dev/null || echo "")"
        if [ -n "$resolved" ]; then
          printf '%s' "$resolved"
          return 0
        fi
      fi
      if command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath "$p" 2>/dev/null || echo "")"
        if [ -n "$resolved" ]; then
          printf '%s' "$resolved"
          return 0
        fi
      fi
      printf '%s' "$p"
      return 0
      ;;
  esac
}

# Extract the script path from a hook command string.
# Expected format: bash "/path/to/script.sh" or bash /path/to/script.sh
extract_script_path() {
  local cmd="$1"
  # Strip leading "bash " (or "bash" alone)
  local path="$(printf '%s' "$cmd" | sed -E 's/^bash[[:space:]]+//')"
  # Strip surrounding quotes
  path="$(printf '%s' "$path" | sed -E 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
  printf '%s' "$path"
}

# ---- Settings file ------------------------------------------------------------
if [ "$MODE" = "--project" ]; then
  SETTINGS_FILE="$(pwd)/.claude/settings.json"
  mkdir -p "$(dirname "$SETTINGS_FILE")" 2>/dev/null || true
else
  SETTINGS_FILE="$HOME/.claude/settings.json"
  mkdir -p "$(dirname "$SETTINGS_FILE")" 2>/dev/null || true
fi

HOOK_SS_CMD="bash \"$TARGET/scripts/hooks/session-start.sh\""
HOOK_STOP_CMD="bash \"$TARGET/scripts/hooks/stop-handoff.sh\""

# Pre-compute canonical hook script paths
HOOK_SS_SCRIPT_PATH="$(extract_script_path "$HOOK_SS_CMD")"
HOOK_STOP_SCRIPT_PATH="$(extract_script_path "$HOOK_STOP_CMD")"
CANON_SS="$(canonical_path "$HOOK_SS_SCRIPT_PATH")"
CANON_STOP="$(canonical_path "$HOOK_STOP_SCRIPT_PATH")"

# ---- Hook registration with path-normalized idempotency -----------------------
register_hooks() {
  local settings="$1"
  local hook_ss_cmd="$2"
  local hook_stop_cmd="$3"

  # --- Idempotency check using canonical path comparison -----------------------
  local has_jq=0
  if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
    has_jq=1
  fi
  local has_python=0
  if command -v python3 >/dev/null 2>&1; then
    has_python=1
  fi

  # BUG-3 fail-closed: if neither jq nor python3, refuse to mutate settings.json
  if [ "$has_jq" -eq 0 ] && [ "$has_python" -eq 0 ]; then
    echo "ERROR: Cannot safely check for existing hooks — neither jq nor python3 is available." >&2
    echo "       Install jq (recommended) or python3 to proceed, or manually verify that" >&2
    echo "       SessionStart and Stop hooks in $settings do not already reference" >&2
    echo "       $TARGET/scripts/hooks/ before re-running with HARNESS_SKIP_HOOK_CHECK=1." >&2
    return 1
  fi

  # If explicit skip requested, proceed without idempotency check
  if [ "${HARNESS_SKIP_HOOK_CHECK:-0}" = "1" ]; then
    echo "  HARNESS_SKIP_HOOK_CHECK=1 — skipping hook idempotency check"
  elif [ -f "$settings" ]; then
    # Extract existing SessionStart + Stop hook command paths and canonicalize them
    local ss_exists=0 stop_exists=0

    if [ "$has_jq" -eq 1 ]; then
      # Extract all SessionStart hook commands using jq
      local existing_ss_cmds=""
      existing_ss_cmds="$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$settings" 2>/dev/null || echo "")"

      if [ -n "$existing_ss_cmds" ]; then
        while IFS= read -r existing_cmd; do
          [ -z "$existing_cmd" ] && continue
          local existing_path=""
          existing_path="$(extract_script_path "$existing_cmd")"
          local canon_existing=""
          canon_existing="$(canonical_path "$existing_path")"
          if [ "$canon_existing" = "$CANON_SS" ]; then
            ss_exists=1
            break
          fi
        done <<<"$existing_ss_cmds"
      fi

      # Extract all Stop hook commands using jq
      local existing_stop_cmds=""
      existing_stop_cmds="$(jq -r '.hooks.Stop[]?.hooks[]?.command // empty' "$settings" 2>/dev/null || echo "")"

      if [ -n "$existing_stop_cmds" ]; then
        while IFS= read -r existing_cmd; do
          [ -z "$existing_cmd" ] && continue
          local existing_path=""
          existing_path="$(extract_script_path "$existing_cmd")"
          local canon_existing=""
          canon_existing="$(canonical_path "$existing_path")"
          if [ "$canon_existing" = "$CANON_STOP" ]; then
            stop_exists=1
            break
          fi
        done <<<"$existing_stop_cmds"
      fi
    elif [ "$has_python" -eq 1 ]; then
      # Use python3 to extract raw existing hook paths from settings.json.
      # Python must NOT canonicalize — only Bash's canonical_path() does that.
      # This keeps the BUG-3 "single normalizer" contract intact.
      local _py_script=""
      _py_script="${settings}.pycheck.$$"
      cat > "$_py_script" <<'PYEOF'
import json, sys, os
settings_file = os.environ["SETTINGS_FILE"]

def extract_path(cmd):
    import re
    p = re.sub(r'^bash\s+', '', cmd)
    p = p.strip().strip('"').strip("'")
    return p

raw_ss = []
raw_stop = []
try:
    with open(settings_file) as f:
        data = json.load(f)
    hooks = data.get("hooks", {})
    for entry in hooks.get("SessionStart", []):
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            if cmd:
                raw_ss.append(extract_path(cmd))
    for entry in hooks.get("Stop", []):
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            if cmd:
                raw_stop.append(extract_path(cmd))
except (json.JSONDecodeError, FileNotFoundError, KeyError):
    pass

# Print raw paths, one per line, NUL-delimited groups
sys.stdout.write("\n".join(raw_ss) + "\n---SS/STOP---\n" + "\n".join(raw_stop))
PYEOF
      SETTINGS_FILE="$settings" python3 "$_py_script" 2>/dev/null > "${_py_script}.out" || true
      if [ -s "${_py_script}.out" ]; then
        # Canonicalize extracted paths through Bash's canonical_path()
        local in_stop=0
        while IFS= read -r raw_path; do
          [ -z "$raw_path" ] && continue
          if [ "$raw_path" = "---SS/STOP---" ]; then
            in_stop=1
            continue
          fi
          local canon_extracted=""
          canon_extracted="$(canonical_path "$raw_path")"
          if [ "$in_stop" -eq 0 ] && [ "$canon_extracted" = "$CANON_SS" ]; then
            ss_exists=1
          elif [ "$in_stop" -eq 1 ] && [ "$canon_extracted" = "$CANON_STOP" ]; then
            stop_exists=1
          fi
        done < "${_py_script}.out"
      fi
      rm -f "$_py_script" "${_py_script}.out"
    fi

    if [ "$ss_exists" = "1" ] && [ "$stop_exists" = "1" ]; then
      echo "  hooks already registered in $settings (idempotent — canonical path match)"
      return 0
    fi
  fi

  # Backup BEFORE mutating (unique timestamped filename).
  if [ -f "$settings" ]; then
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
    local backup="${settings}.bak.${stamp}"
    cp -p "$settings" "$backup"
    echo "  backup written: $backup"
  fi

  # F14.1: choose writer backend UP FRONT, no unconditional jq fallback.
  # If neither jq nor python3 is available, refuse to mutate settings.json.
  local writer_rc=1
  local tmp="${settings}.tmp.$$"

  if [ "$has_jq" -eq 1 ]; then
    # jq writer
    if [ -f "$settings" ] && jq -e . "$settings" >/dev/null 2>&1; then
      cp "$settings" "$tmp"
    else
      printf '{}\n' > "$tmp"
    fi
    if jq --arg ss_cmd "$hook_ss_cmd" --arg stop_cmd "$hook_stop_cmd" '
      .hooks //= {} |
      .hooks.SessionStart //= [] |
      .hooks.Stop         //= [] |
      ( .hooks.SessionStart |= (if any(.[]?.hooks[]?; .command == $ss_cmd)
                                then . else . + [{"matcher":"startup|resume","hooks":[{"type":"command","command":$ss_cmd,"timeout":5000}]}] end)
      ) |
      ( .hooks.Stop         |= (if any(.[]?.hooks[]?; .command == $stop_cmd)
                                then . else . + [{"matcher":"*","hooks":[{"type":"command","command":$stop_cmd,"timeout":5000}]}] end)
      )
    ' "$tmp" > "${tmp}.out" 2>/dev/null; then
      mv "${tmp}.out" "$settings"
      writer_rc=0
    else
      rm -f "$tmp" "${tmp}.out"
    fi
  elif [ "$has_python" -eq 1 ]; then
    # python3 writer — must NOT silently no-op. Build full settings via python
    # and write atomically. Fail-closed on any error.
    local _py_writer="${settings}.pywrite.$$"
    cat > "$_py_writer" <<'PYEOF'
import json, os, sys
settings_file = os.environ["SETTINGS_FILE"]
ss_cmd = os.environ["HOOK_SS_CMD"]
stop_cmd = os.environ["HOOK_STOP_CMD"]

try:
    try:
        with open(settings_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        data = {}
    hooks = data.setdefault("hooks", {})
    ss = hooks.setdefault("SessionStart", [])
    if not any(
        h.get("command") == ss_cmd
        for entry in ss
        for h in entry.get("hooks", [])
    ):
        ss.append({
            "matcher": "startup|resume",
            "hooks": [{"type": "command", "command": ss_cmd, "timeout": 5000}],
        })
    stop = hooks.setdefault("Stop", [])
    if not any(
        h.get("command") == stop_cmd
        for entry in stop
        for h in entry.get("hooks", [])
    ):
        stop.append({
            "matcher": "*",
            "hooks": [{"type": "command", "command": stop_cmd, "timeout": 5000}],
        })
    tmp = settings_file + ".tmp.py"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_file)
except Exception as exc:
    print(f"PYWRITE_FAIL: {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF
    if SETTINGS_FILE="$settings" \
       HOOK_SS_CMD="$hook_ss_cmd" \
       HOOK_STOP_CMD="$hook_stop_cmd" \
       python3 "$_py_writer" 2>/dev/null; then
      writer_rc=0
    fi
    rm -f "$_py_writer"
  fi

  rm -f "$tmp"

  if [ "$writer_rc" -ne 0 ]; then
    echo "ERROR: Failed to write hooks to $settings — refusing to continue." >&2
    echo "       Install jq (recommended) or python3 to register hooks." >&2
    return 1
  fi

  # F14.1: verify the write actually landed. Re-read settings.json and confirm
  # both hook commands are present. Without this, a silent writer failure
  # would print "hooks registered" with settings.json unchanged.
  # CRITICAL: verify must use the SAME backend that wrote (jq or python3),
  # not whatever command -v resolves first. A shadowed/fake jq would write
  # nothing real but still be found by command -v.
  local verify_rc=1
  if [ "$has_jq" -eq 1 ]; then
    local has_ss has_stop
    has_ss="$(jq --arg c "$hook_ss_cmd" \
      '[.hooks.SessionStart[]?.hooks[]?.command // empty] | any(. == $c)' \
      "$settings" 2>/dev/null || echo false)"
    has_stop="$(jq --arg c "$hook_stop_cmd" \
      '[.hooks.Stop[]?.hooks[]?.command // empty] | any(. == $c)' \
      "$settings" 2>/dev/null || echo false)"
    if [ "$has_ss" = "true" ] && [ "$has_stop" = "true" ]; then
      verify_rc=0
    fi
  elif [ "$has_python" -eq 1 ]; then
    local _py_verify="${settings}.pyverify.$$"
    cat > "$_py_verify" <<'PYEOF'
import json, os, sys
data = json.load(open(os.environ["SETTINGS_FILE"]))
hooks = data.get("hooks", {})
def has(entries, target):
    for e in entries:
        for h in e.get("hooks", []):
            if h.get("command") == target:
                return True
    return False
sys.exit(0 if (has(hooks.get("SessionStart", []), os.environ["HOOK_SS_CMD"])
               and has(hooks.get("Stop", []), os.environ["HOOK_STOP_CMD"]))
         else 1)
PYEOF
    if SETTINGS_FILE="$settings" \
       HOOK_SS_CMD="$hook_ss_cmd" \
       HOOK_STOP_CMD="$hook_stop_cmd" \
       python3 "$_py_verify" 2>/dev/null; then
      verify_rc=0
    fi
    rm -f "$_py_verify"
  fi

  if [ "$verify_rc" -ne 0 ]; then
    echo "ERROR: hooks write completed but verification of $settings failed — refusing." >&2
    echo "       Re-run with debug to inspect $settings." >&2
    return 1
  fi

  echo "  hooks registered: $settings"
}

echo ""
echo "[hooks] Registering hooks in settings.json..."
if ! register_hooks "$SETTINGS_FILE" "$HOOK_SS_CMD" "$HOOK_STOP_CMD"; then
  echo "FATAL: register_hooks failed — refusing to claim install success." >&2
  exit 1
fi

echo ""
echo "=== Install Complete ==="
echo ""
echo "Version:   $VERSION"
echo "Installed:"
echo "  VERSION                            $(cat "$TARGET/VERSION" 2>/dev/null || echo MISSING)"
echo "  core/                              $([ -d "$TARGET/core" ] && echo OK || echo MISSING)"
echo "  templates/                         $([ -d "$TARGET/templates" ] && echo OK || echo MISSING)"
echo "  adapters/claude-code/hooks/        $(ls "$TARGET/adapters/claude-code/hooks/"*.sh 2>/dev/null | wc -l | tr -d ' ') hooks"
echo "  scripts/ (v1 wrappers)             $(ls "$TARGET/scripts/"*.sh "$TARGET/scripts/hooks/"*.sh 2>/dev/null | wc -l | tr -d ' ') wrappers"
echo "  install-receipt.json               $([ -f "$TARGET/install-receipt.json" ] && echo OK || echo MISSING)"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code to load hooks."
echo "  2. In a harness project, try: /harness:status"