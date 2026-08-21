#!/bin/bash
# harness-init.sh — rc.3 deterministic init executor (F-CONV-06)
#
# Replaces the v1+v2 merge scaffold generator with the frozen rc.3 executor
# contract (docs/superpowers/specs/2026-08-04-harness-init-guided-onboarding.md
# + 2026-08-05-rc3-conversational-layer-addendum.md).
#
# Modes:
#   legacy  : bash scripts/harness-init.sh <dir> [--full] [--host=claude|codex]
#             [--force-config]  — v1 caller; fills placeholder Brief, never aborts.
#   brief   : bash scripts/harness-init.sh <dir> --brief <json> --non-interactive
#             — Agent passes a resolved Brief; missing required fields are rejected.
#   resume  : re-run in an already-initialized project — skips existing files.
#   update  : --update [--apply] — 3-way SHA compare (dry-run prints a plan only).
#   render  : --render-brief — regenerate PROJECT_BRIEF.md from PROJECT_BRIEF.json.
#
# Output manifest (§6.2a): #1-#11 minimal; #12-#14 only with --full.
#
# Bash never prompts (§0.3 C10 / AC-15): no interactive prompt, no stdin reads
# (the only stdin read is the explicit `--brief-stdin` JSON contract).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$ROOT_DIR/templates"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || echo "0.0.0")"
GENERATED_BY="harness-companion v$VERSION"

# shellcheck source=../core/lib/project-detect.sh
source "$ROOT_DIR/core/lib/project-detect.sh"

# ---- argument state ---------------------------------------------------------
TARGET=""
BRIEF_PATH=""
BRIEF_STDIN="false"
NON_INTERACTIVE="false"
UPDATE="false"
APPLY="false"
RENDER_BRIEF="false"
HOST="claude"
MODE="minimal"
FORCE_CONFIG="false"

# ---- helpers ----------------------------------------------------------------

usage() {
  sed -n '2,30p' "$0"
}

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    echo ""
  fi
}

# map the 9-value detected_type to the 6-value config.json `project_type`.
map_project_type() {
  case "$1" in
    node|python|rust|go|docs) printf '%s' "$1" ;;
    *) printf 'generic' ;;   # shell|electron|mixed|unknown → generic
  esac
}

# §3.4: legacy markers present (but no snapshot)?
has_legacy_markers() {
  local t="$1"
  [ -f "$t/.harness/config.json" ] && return 0
  if [ -f "$t/feature_list.json" ] && [ -f "$t/AGENTS.md" ] && [ -f "$t/init.sh" ]; then return 0; fi
  if [ -f "$t/feature_list.json" ] && jq -e 'has("schema_version")' "$t/feature_list.json" >/dev/null 2>&1; then return 0; fi
  return 1
}

# §3.4: snapshot structurally self-consistent?
validate_snapshot() {
  local snap="$1"
  [ -f "$snap" ] || return 1
  jq -e 'type == "object" and .schema_version == 1' "$snap" >/dev/null 2>&1 || return 1
  jq -e '(.templates | type) == "object"' "$snap" >/dev/null 2>&1 || return 1
  jq -e '[.templates[] | .sha256] | all(.[]; (type == "string") and test("^[0-9a-f]{64}$"))' "$snap" >/dev/null 2>&1 || return 1
  jq -e '[.templates[] | .source] | all(.[]; (type == "string") and (length > 0))' "$snap" >/dev/null 2>&1 || return 1
  return 0
}

detect_state() {
  local t="$1"
  if [ -f "$t/.harness/.template-snapshot.json" ]; then
    if validate_snapshot "$t/.harness/.template-snapshot.json"; then
      printf 'managed-valid'
    else
      printf 'managed-inconsistent'
    fi
  elif has_legacy_markers "$t"; then
    printf 'legacy-unmanaged'
  else
    printf 'fresh'
  fi
}

# captured_from_git_rev = harness-companion repo HEAD (or null when no .git).
captured_rev() {
  git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true
}

compute_initial_state() {
  local is_git=false has_tests=false
  if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then is_git=true; fi
  if [ -f "$TARGET/pytest.ini" ] || \
     { [ -f "$TARGET/pyproject.toml" ] && grep -q '\[tool.pytest\]' "$TARGET/pyproject.toml" 2>/dev/null; } || \
     [ -f "$TARGET/Cargo.toml" ] || \
     { [ -f "$TARGET/package.json" ] && grep -q '"test"' "$TARGET/package.json" 2>/dev/null; } || \
     [ -f "$TARGET/Makefile" ] || \
     compgen -G "$TARGET"/*.bats >/dev/null 2>&1; then
    has_tests=true
  fi
  local existing=() f
  for f in .harness/config.json .harness/.template-snapshot.json feature_list.json AGENTS.md CLAUDE.md init.sh; do
    [ -f "$TARGET/$f" ] && existing+=("$f")
  done
  local existing_json
  existing_json="$(printf '%s\n' "${existing[@]}" | jq -R . 2>/dev/null | jq -sc 'map(select(. != ""))' 2>/dev/null)"
  jq -n -S \
    --argjson git "$is_git" \
    --argjson tests "$has_tests" \
    --arg summary "detected type: $DTYPE" \
    --argjson existing "$existing_json" \
    '{ is_git_repo: $git, has_existing_tests: $tests, existing_harness_files: $existing, detection_summary: $summary }'
}

compute_type_evidence() {
  if [ "$DTYPE" = "mixed" ] || [ "$DTYPE" = "unknown" ]; then
    local markers=() m
    for m in package.json pyproject.toml setup.py requirements.txt Pipfile Cargo.toml go.mod; do
      [ -f "$TARGET/$m" ] && markers+=("$m")
    done
    local markers_json notes
    markers_json="$(printf '%s\n' "${markers[@]}" | jq -R . 2>/dev/null | jq -sc 'map(select(. != ""))' 2>/dev/null)"
    if [ "$DTYPE" = "mixed" ]; then notes="multiple source markers detected; primary type unconfirmed"; else notes="no source markers detected"; fi
    jq -n -S --arg notes "$notes" --argjson markers "$markers_json" '{ markers_seen: $markers, notes: $notes }'
  else
    printf 'null'
  fi
}

# snapshot accumulators + typed render (§8.4 / §8.5).
SNAP_ENTRIES="{}"
snap_add() {  # <target_rel> <source_rel> <sha256>
  SNAP_ENTRIES="$(printf '%s' "$SNAP_ENTRIES" | jq -c --arg k "$1" --arg s "$2" --arg h "$3" '. + {($k): {source: $s, sha256: $h}}')"
}

# render_typed <file> <dest_abs> <target_rel> — by-type/<type>/F else common/F.
render_typed() {
  local f="$1" dest="$2" trel="$3" src="" srel=""
  if [ -f "$TEMPLATES_DIR/by-type/$DTYPE/$f" ]; then
    src="$TEMPLATES_DIR/by-type/$DTYPE/$f"; srel="by-type/$DTYPE/$f"
  else
    src="$TEMPLATES_DIR/common/$f"; srel="common/$f"
  fi
  [ -f "$src" ] || { echo "error: template missing: $src" >&2; return 1; }
  if [ -f "$dest" ] && [ "$FORCE_CONFIG" != "true" ]; then
    return 0   # skip-if-exists
  fi
  cp "$src" "$dest" || { echo "error: write failed: $dest" >&2; return 1; }
  snap_add "$trel" "$srel" "$(sha256_file "$dest")"
  return 0
}

# render_flat <source_rel> <dest_abs> <target_rel> <snapshot_source_rel>
render_flat() {
  local src="$TEMPLATES_DIR/$1" dest="$2" trel="$3" srel="$4"
  [ -f "$src" ] || { echo "error: template missing: $src" >&2; return 1; }
  if [ -f "$dest" ] && [ "$FORCE_CONFIG" != "true" ]; then
    return 0
  fi
  cp "$src" "$dest" || { echo "error: write failed: $dest" >&2; return 1; }
  snap_add "$trel" "$srel" "$(sha256_file "$dest")"
  return 0
}

SNAPSHOT_PATH="$TARGET/.harness/.template-snapshot.json"

write_snapshot() {
  jq -n -S \
    --arg rev "$CAPTURED_REV" \
    --arg ver "$VERSION" \
    --argjson templates "$SNAP_ENTRIES" \
    '{ schema_version: 1, captured_from_git_rev: (if $rev == "" then null else $rev end), source_version: $ver, templates: $templates }' \
    > "$SNAPSHOT_PATH"
}

# build the canonical Brief (22 fields, jq -S sorted). Called after the snapshot
# so template_manifest_digest can be computed from the snapshot file.
build_brief() {
  local digest="$1"
  jq -n -S \
    --argjson in "$INPUT_BRIEF_JSON" \
    --arg dtype "$DTYPE" \
    --arg rev "$CAPTURED_REV" \
    --arg digest "$digest" \
    --arg version "$VERSION" \
    --arg generated_by "$GENERATED_BY" \
    --argjson initial_state "$INITIAL_STATE" \
    --argjson type_evidence "$TYPE_EVIDENCE" \
    --argjson defaults "$DEFAULTS_APPLIED" \
    --argjson op_defaults "$OP_DEFAULTS" \
    '{
       schema_version: 1,
       advisory: true,
       generated_by: $generated_by,
       source_version: $version,
       captured_from_git_rev: (if $rev == "" then null else $rev end),
       template_manifest_digest: $digest,
       detected_type: ($in.detected_type // $dtype),
       goal: ($in.goal // "<unset: goal>"),
       success_criteria: ($in.success_criteria // ["<unset: success criteria>"]),
       cadence: ($in.cadence // "stable"),
       deadline: ($in.deadline // null),
       stack: ($in.stack // $dtype),
       test_framework: ($in.test_framework // "unspecified"),
       secrets_handling: ($in.secrets_handling // "unspecified"),
       external_network: ($in.external_network // "ask"),
       prohibitions: ($in.prohibitions // []),
       initial_project_state: ($initial_state * ($in.initial_project_state // {})),
       operation_preferences: ($op_defaults * ($in.operation_preferences // {})),
       defaults_applied: ($in.defaults_applied // $defaults),
       conflicts_resolved: ($in.conflicts_resolved // []),
       type_evidence: ($in.type_evidence // $type_evidence),
       provenance: ($in.provenance // {})
     }'
}

render_brief_md() {
  local brief_json="$TARGET/.harness/PROJECT_BRIEF.json"
  [ -f "$brief_json" ] || { echo "error: PROJECT_BRIEF.json missing; cannot render MD" >&2; return 1; }
  local schema src_rev src_ver
  schema="$(jq -r '.schema_version' "$brief_json" 2>/dev/null)"
  src_rev="$(jq -r '.captured_from_git_rev // "0000000000000000000000000000000000000000"' "$brief_json" 2>/dev/null)"
  src_ver="$(jq -r '.source_version' "$brief_json" 2>/dev/null)"
  {
    echo "<!-- generated from PROJECT_BRIEF.json schema_version=$schema source_version=$src_ver -->"
    echo "<!-- DO NOT EDIT — regenerate from JSON. On mismatch, JSON is authoritative. -->"
    echo "<!-- git rev $src_rev -->"
    echo ""
    echo "# Project Brief"
    echo ""
    echo "- **Goal**: $(jq -r '.goal' "$brief_json")"
    echo "- **Detected type**: $(jq -r '.detected_type' "$brief_json")"
    echo "- **Stack**: $(jq -r '.stack' "$brief_json")"
    echo "- **Cadence**: $(jq -r '.cadence' "$brief_json")"
    echo "- **Deadline**: $(jq -r '.deadline // "none"' "$brief_json")"
    echo "- **Test framework**: $(jq -r '.test_framework' "$brief_json")"
    echo "- **Secrets handling**: $(jq -r '.secrets_handling' "$brief_json")"
    echo "- **External network**: $(jq -r '.external_network' "$brief_json")"
    echo ""
    echo "## Success criteria"
    echo ""
    jq -r '.success_criteria[] | "- \(.)"' "$brief_json"
    echo ""
    echo "_Advisory. Current-session user instructions take precedence._"
  } > "$TARGET/.harness/PROJECT_BRIEF.md"
  return 0
}

# --update / --apply (3-way SHA compare, §4.4 / §4.5).
do_update() {
  case "$STATE" in
    fresh)
      echo "error: not initialized — nothing to update" >&2
      return 2
      ;;
    managed-inconsistent)
      echo "error: .template-snapshot.json is damaged; cannot update" >&2
      return 2
      ;;
  esac

  local snap="$TARGET/.harness/.template-snapshot.json"
  local plan="" wrote_any=false
  local k src sha_snap sha_now sha_tmpl base
  for k in $(jq -r '.templates | keys[]' "$snap" 2>/dev/null); do
    src="$(jq -r --arg k "$k" '.templates[$k].source' "$snap" 2>/dev/null)"
    sha_snap="$(jq -r --arg k "$k" '.templates[$k].sha256' "$snap" 2>/dev/null)"
    [ -f "$TARGET/$k" ] && sha_now="$(sha256_file "$TARGET/$k")" || sha_now=""
    # re-derive current template content from the recorded source path.
    if [ -f "$TEMPLATES_DIR/$src" ]; then
      sha_tmpl="$(sha256_file "$TEMPLATES_DIR/$src")"
    else
      base="${src##*/}"
      [ -f "$TEMPLATES_DIR/common/$base" ] && sha_tmpl="$(sha256_file "$TEMPLATES_DIR/common/$base")" || sha_tmpl=""
    fi

    if [ -z "$sha_now" ]; then
      plan="$(printf '%s\n%s' "$plan" "  would-create: $k")"
      continue
    fi
    if [ "$sha_now" = "$sha_tmpl" ]; then
      continue   # identical → skip
    fi
    if [ "$sha_now" = "$sha_snap" ] && [ "$sha_tmpl" != "$sha_snap" ]; then
      plan="$(printf '%s\n%s' "$plan" "  would-update (template changed): $k")"
      if [ "$APPLY" = "true" ]; then
        cp "$TEMPLATES_DIR/$src" "$TARGET/$k" 2>/dev/null || true
        snap_add "$k" "$src" "$(sha256_file "$TARGET/$k")"
        wrote_any=true
      fi
    elif [ "$sha_now" != "$sha_tmpl" ] && [ "$sha_now" != "$sha_snap" ]; then
      plan="$(printf '%s\n%s' "$plan" "  would-skip (user modified): $k")"
    fi
  done

  if [ "$APPLY" != "true" ]; then
    echo "=== Update plan (dry-run — no writes) ==="
    printf '%s\n' "$plan" | sed '/^$/d'
    echo "Re-run with --apply to write."
    return 0
  fi

  if [ "$wrote_any" = "true" ]; then
    write_snapshot
    local digest
    digest="$(sha256_file "$SNAPSHOT_PATH")"
    if [ -f "$TARGET/.harness/PROJECT_BRIEF.json" ]; then
      jq --arg d "$digest" '.template_manifest_digest = $d' "$TARGET/.harness/PROJECT_BRIEF.json" \
        > "$TARGET/.harness/PROJECT_BRIEF.json.tmp" 2>/dev/null \
        && mv "$TARGET/.harness/PROJECT_BRIEF.json.tmp" "$TARGET/.harness/PROJECT_BRIEF.json"
      render_brief_md
    fi
  fi
  echo "=== Update applied ==="
  return 0
}

# ---- argument parsing -------------------------------------------------------

while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --brief-stdin)      BRIEF_STDIN="true" ;;
    --non-interactive)  NON_INTERACTIVE="true" ;;
    --update)           UPDATE="true" ;;
    --apply)            APPLY="true" ;;
    --render-brief)     RENDER_BRIEF="true" ;;
    --minimal)          MODE="minimal" ;;
    --full)             MODE="full" ;;
    --force-config)     FORCE_CONFIG="true" ;;
    --brief=*)          BRIEF_PATH="${arg#--brief=}" ;;
    --brief)
      shift
      [ $# -gt 0 ] || { echo "error: --brief requires a path" >&2; exit 2; }
      BRIEF_PATH="$1"
      ;;
    --host=*)           HOST="${arg#--host=}" ;;
    --host)
      shift
      [ $# -gt 0 ] || { echo "error: --host requires a value" >&2; exit 2; }
      HOST="$1"
      ;;
    --help|-h)          usage; exit 0 ;;
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
  shift
done

if [ "$HOST" != "claude" ] && [ "$HOST" != "codex" ]; then
  echo "harness-init.sh: invalid --host '$HOST' (must be claude|codex)" >&2
  exit 2
fi

TARGET="${TARGET:-.}"
if [ ! -d "$TARGET" ]; then
  echo "harness-init.sh: target directory '$TARGET' does not exist" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"
PROJECT_NAME="$(basename "$TARGET")"

# ---- recon (read-only; run BEFORE any write so detection reflects true state) ----
DTYPE="$(detect_project_type "$TARGET")"
PROJECT_TYPE="$(map_project_type "$DTYPE")"
CAPTURED_REV="$(captured_rev)"
STATE="$(detect_state "$TARGET")"
SNAPSHOT_PATH="$TARGET/.harness/.template-snapshot.json"

INITIAL_STATE="$(compute_initial_state)"
TYPE_EVIDENCE="$(compute_type_evidence)"

# ---- Brief input ------------------------------------------------------------

INPUT_BRIEF_JSON="{}"

# §7.2.1 defaults + legacy placeholders.
OP_DEFAULTS='{"commit":"ask","push":"ask","merge":"ask","release":"ask","install_packages":"ask","external_mutation":"ask","destructive_ops":false}'

# AC-13a: in --brief / --brief-stdin mode, goal + success_criteria are required.
if [ -n "$BRIEF_PATH" ] || [ "$BRIEF_STDIN" = "true" ]; then
  if [ "$BRIEF_STDIN" = "true" ]; then
    INPUT_BRIEF_JSON="$(cat)" || INPUT_BRIEF_JSON=""
  else
    INPUT_BRIEF_JSON="$(cat "$BRIEF_PATH" 2>/dev/null)" || INPUT_BRIEF_JSON=""
  fi
  if ! printf '%s' "$INPUT_BRIEF_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "error: Brief: not a valid JSON object" >&2
    exit 2
  fi
  if ! printf '%s' "$INPUT_BRIEF_JSON" | jq -e '(.goal | type) == "string" and (.goal | test("[^[:space:]]")) and (.goal | length) <= 500' >/dev/null 2>&1; then
    echo "error: required field 'goal' is missing or empty" >&2
    exit 2
  fi
  if ! printf '%s' "$INPUT_BRIEF_JSON" | jq -e '(.success_criteria | type) == "array" and (.success_criteria | length) >= 1 and (.success_criteria | length) <= 7 and ([.success_criteria[] | (type == "string") and test("[^[:space:]]")] | all)' >/dev/null 2>&1; then
    echo "error: required field 'success_criteria' is missing or empty" >&2
    exit 2
  fi
fi

# legacy mode placeholder defaults_applied (§3.2): goal + success_criteria were
# filled with placeholders; record them so status can flag the Brief as placeholder.
DEFAULTS_APPLIED="[]"
if [ -z "$BRIEF_PATH" ] && [ "$BRIEF_STDIN" != "true" ]; then
  DEFAULTS_APPLIED='[
    {"field":"/goal","value":"<unset: goal>","rationale":"legacy mode: no goal provided; v1 back-compat placeholder","source":"legacy_placeholder"},
    {"field":"/success_criteria","value":["<unset: success criteria>"],"rationale":"legacy mode: no success criteria provided; v1 back-compat placeholder","source":"legacy_placeholder"}
  ]'
fi

# ---- mode dispatch ----------------------------------------------------------

if [ "$RENDER_BRIEF" = "true" ]; then
  render_brief_md
  exit $?
fi

if [ "$UPDATE" = "true" ]; then
  do_update
  exit $?
fi

if [ "$STATE" = "managed-inconsistent" ]; then
  echo "error: .harness/.template-snapshot.json is damaged (managed-inconsistent); back it up and enter the explicit recovery flow" >&2
  exit 2
fi

if [ "$STATE" = "managed-valid" ] && [ -z "$BRIEF_PATH" ] && [ "$BRIEF_STDIN" != "true" ]; then
  # §3.4.1 legacy-skip-existing: already initialized, no overwrite.
  echo "harness-init.sh: project already initialized (managed-valid); skipping existing files"
  echo "  (use --update to upgrade templates, or --brief to re-initialize)"
  exit 0
fi

# ---- render manifest --------------------------------------------------------

# Fresh init / legacy-unmanaged initial write. #1-#3 always written on fresh;
# #4-#14 skip-if-exists (never overwrite user files).
mkdir -p "$TARGET/.harness/logs/runs"

# #9 AGENTS.md, #10 CLAUDE.md, #8 init.sh (typed).
render_typed "AGENTS.md" "$TARGET/AGENTS.md" "AGENTS.md"
render_typed "CLAUDE.md" "$TARGET/CLAUDE.md" "CLAUDE.md"
render_typed "init.sh"   "$TARGET/init.sh"   "init.sh"
chmod +x "$TARGET/init.sh" 2>/dev/null || true

# #7 feature_list.json (type-agnostic, from common/).
render_flat "common/feature_list.json" "$TARGET/feature_list.json" "feature_list.json" "common/feature_list.json"

# #4 .harness/config.json (type-matched example).
CONFIG_SRC="$TEMPLATES_DIR/.harness/config.json.${PROJECT_TYPE}.example"
CONFIG_SREL=".harness/config.json.${PROJECT_TYPE}.example"
if [ ! -f "$CONFIG_SRC" ]; then
  echo "error: config example missing: $CONFIG_SRC" >&2
  exit 1
fi
if [ ! -f "$TARGET/.harness/config.json" ] || [ "$FORCE_CONFIG" = "true" ]; then
  cp "$CONFIG_SRC" "$TARGET/.harness/config.json" || { echo "error: write failed: config.json" >&2; exit 1; }
fi
snap_add ".harness/config.json" "$CONFIG_SREL" "$(sha256_file "$TARGET/.harness/config.json")"

# #11 progress (host-specific; NOT recorded in the snapshot — it would break
# AC-14 cross-host byte-equality of the snapshot).
PROGRESS_DEST="$TARGET/claude-progress.md"
[ "$HOST" = "codex" ] && PROGRESS_DEST="$TARGET/codex-progress.md"
if [ ! -f "$PROGRESS_DEST" ] || [ "$FORCE_CONFIG" = "true" ]; then
  cp "$TEMPLATES_DIR/claude-progress.md" "$PROGRESS_DEST" 2>/dev/null || true
fi

# #6 .gitignore append (never overwrite user entries).
GITIGNORE="$TARGET/.gitignore"
{
  if [ -f "$GITIGNORE" ]; then cat "$GITIGNORE"; echo ""; fi
  echo "# harness-companion"
  echo ".harness/logs/"
  echo ".harness/.registry.lock/"
} > "${GITIGNORE}.tmp" 2>/dev/null || true
mv "${GITIGNORE}.tmp" "$GITIGNORE" 2>/dev/null || true

# --full extras: #12 session-handoff.md, #13 clean-state-checklist.md, #14 checklist.sh.
if [ "$MODE" = "full" ]; then
  render_flat "session-handoff.md"       "$TARGET/session-handoff.md"       "session-handoff.md"       "session-handoff.md"
  render_flat "clean-state-checklist.md" "$TARGET/clean-state-checklist.md" "clean-state-checklist.md" "clean-state-checklist.md"
  render_typed "checklist.sh"            "$TARGET/checklist.sh"            "checklist.sh"
  chmod +x "$TARGET/checklist.sh" 2>/dev/null || true
fi

# ---- snapshot + brief -------------------------------------------------------

write_snapshot
SNAPSHOT_DIGEST="$(sha256_file "$SNAPSHOT_PATH")"

build_brief "$SNAPSHOT_DIGEST" > "$TARGET/.harness/PROJECT_BRIEF.json"
render_brief_md

# ---- report ----------------------------------------------------------------

echo "=== Harness init complete (rc.3 executor) ==="
echo "Detected type: $DTYPE  (project_type: $PROJECT_TYPE)"
echo "Host: $HOST   Mode: $MODE   State: $STATE"
echo ""
echo "Wrote:"
echo "  .harness/PROJECT_BRIEF.json   (#1)"
echo "  .harness/PROJECT_BRIEF.md     (#2)"
echo "  .harness/.template-snapshot.json (#3)"
echo "  .harness/config.json          (#4)"
echo "  .harness/logs/runs/           (#5)"
echo "  .gitignore                    (#6 appended)"
echo "  feature_list.json             (#7)"
echo "  init.sh                       (#8, executable)"
echo "  AGENTS.md                     (#9)"
echo "  CLAUDE.md                     (#10)"
echo "  ${PROGRESS_DEST##*/}          (#11, host-specific)"
[ "$MODE" = "full" ] && echo "  session-handoff.md / clean-state-checklist.md / checklist.sh (#12-#14)"
echo ""
if [ -z "$BRIEF_PATH" ] && [ "$BRIEF_STDIN" != "true" ]; then
  echo "warning: legacy mode ran; PROJECT_BRIEF.json contains placeholder fields — review and edit" >&2
fi

exit 0
