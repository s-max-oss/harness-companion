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
#   update  : --update [--apply --plan-token <sha256>] — 3-way SHA compare.
#             Dry-run prints the token that binds a later apply to the same inputs.
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
BRIEF_VALIDATOR="$SCRIPT_DIR/validate-project-brief.sh"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || echo "0.0.0")"
GENERATED_BY="harness-companion v$VERSION"

[ -f "$BRIEF_VALIDATOR" ] && [ -x "$BRIEF_VALIDATOR" ] && [ ! -L "$BRIEF_VALIDATOR" ] || {
  echo "error: canonical PROJECT_BRIEF validator is missing or unsafe" >&2
  exit 2
}

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
PLAN_TOKEN=""
STAGE_DIR=""
CHANGED_PATHS=()
declare -A EXPECTED_KIND=()
declare -A EXPECTED_SHA=()
EXISTING_BRIEF_SHA=""

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

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

path_state() {
  local p="$1" digest
  if [ -L "$p" ]; then printf 'symlink'; return 0; fi
  if [ -d "$p" ]; then printf 'directory'; return 0; fi
  if [ ! -e "$p" ]; then printf 'missing'; return 0; fi
  digest="$(sha256_file "$p")"
  [ -n "$digest" ] || return 1
  printf 'file:%s' "$digest"
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
  jq -e 'type == "object" and .schema_version == 1
    and (.source_version | type == "string" and length > 0)
    and (has("captured_from_git_rev"))
    and ((.captured_from_git_rev == null) or
         (.captured_from_git_rev | type == "string" and test("^[0-9a-f]{40}$")))' "$snap" >/dev/null 2>&1 || return 1
  jq -e '(.templates | type) == "object"' "$snap" >/dev/null 2>&1 || return 1
  jq -e '[.templates | keys[]] | all(.[];
    (type == "string") and length > 0
    and (test("(^/|(^|/)\\.\\.(/|$)|\\\\)") | not))' "$snap" >/dev/null 2>&1 || return 1
  jq -e '[.templates[] | .sha256] | all(.[]; (type == "string") and test("^[0-9a-f]{64}$"))' "$snap" >/dev/null 2>&1 || return 1
  jq -e '[.templates[] | .source] | all(.[]; (type == "string") and (length > 0)
    and (test("(^/|(^|/)\\.\\.(/|$)|\\\\)") | not))' "$snap" >/dev/null 2>&1 || return 1
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

stage_begin() {
  STAGE_DIR="$(mktemp -d)" || { echo "error: could not create staging directory" >&2; return 1; }
  CHANGED_PATHS=()
  EXPECTED_KIND=()
  EXPECTED_SHA=()
}

stage_mark() {
  local rel="$1" seen
  for seen in "${CHANGED_PATHS[@]}"; do [ "$seen" = "$rel" ] && return 0; done
  CHANGED_PATHS+=("$rel")
}

expect_target_unchanged() { # <target_rel>; bind absent or current sha
  local rel="$1"
  if [ -f "$TARGET/$rel" ]; then
    EXPECTED_KIND["$rel"]="file"
    EXPECTED_SHA["$rel"]="$(sha256_file "$TARGET/$rel")"
  elif [ -e "$TARGET/$rel" ] || [ -L "$TARGET/$rel" ]; then
    EXPECTED_KIND["$rel"]="other"
    EXPECTED_SHA["$rel"]=""
  else
    EXPECTED_KIND["$rel"]="absent"
    EXPECTED_SHA["$rel"]=""
  fi
}

expect_classified_target() { # <target_rel> <sha-at-classification|empty-for-absent>
  local rel="$1" classified_sha="$2"
  if [ -n "$classified_sha" ]; then
    EXPECTED_KIND["$rel"]="file"; EXPECTED_SHA["$rel"]="$classified_sha"
  else
    EXPECTED_KIND["$rel"]="absent"; EXPECTED_SHA["$rel"]=""
  fi
}

target_matches_expectation() { # <target_rel>
  local rel="$1" kind="${EXPECTED_KIND[$1]:-}" now
  [ -z "$kind" ] && return 0
  case "$kind" in
    absent) [ ! -e "$TARGET/$rel" ] && [ ! -L "$TARGET/$rel" ] ;;
    file) [ -f "$TARGET/$rel" ] && [ ! -L "$TARGET/$rel" ] || return 1
          now="$(sha256_file "$TARGET/$rel")"; [ -n "$now" ] && [ "$now" = "${EXPECTED_SHA[$rel]}" ] ;;
    *) return 1 ;;
  esac
}

stage_copy() { # <source_abs> <target_rel>
  local src="$1" rel="$2" out="$STAGE_DIR/$2"
  mkdir -p "$(dirname "$out")" || return 1
  cp "$src" "$out" || return 1
  case "$rel" in init.sh|checklist.sh) chmod +x "$out" || return 1 ;; esac
  stage_mark "$rel"
}

commit_stage() {
  local rollback="$STAGE_DIR/.rollback" rel dest backup i parent resolved_target resolved_parent
  mkdir -p "$rollback" || return 1
  resolved_target="$(cd "$TARGET" && pwd -P)" || return 1
  local committed=()
  for rel in "${CHANGED_PATHS[@]}"; do
    dest="$TARGET/$rel"; backup="$rollback/$rel"
    parent="$(dirname "$dest")"
    # Validate the nearest existing ancestor before mkdir. Otherwise a
    # snapshot-derived parent containing a symlink could make mkdir write
    # outside the project before the later realpath check.
    local probe="$parent"
    while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
      [ "$probe" = "$TARGET" ] && break
      probe="$(dirname "$probe")"
    done
    [ -L "$probe" ] && { echo "error: refusing symlink parent for: $rel" >&2; break; }
    resolved_parent="$(cd "$probe" && pwd -P)" || break
    case "$resolved_parent/" in "$resolved_target/"*) ;; *) echo "error: target parent escapes project root: $rel" >&2; break ;; esac
    mkdir -p "$parent" "$(dirname "$backup")" || break
    resolved_parent="$(cd "$parent" && pwd -P)" || break
    case "$resolved_parent/" in "$resolved_target/"*) ;; *) echo "error: target path escapes project root: $rel" >&2; break ;; esac
    [ -L "$dest" ] && { echo "error: refusing symlink target: $rel" >&2; break; }
    if ! target_matches_expectation "$rel"; then
      echo "error: concurrent target change detected before write: $rel" >&2
      break
    fi
    if [ -e "$dest" ]; then
      cp -p "$dest" "$backup" || break
      printf 'existing' > "$backup.kind"
    else
      printf 'new' > "$backup.kind"
    fi
    local tmp="${dest}.harness-init.$$"
    if ! cp -p "$STAGE_DIR/$rel" "$tmp" || ! mv "$tmp" "$dest"; then
      rm -f "$tmp"
      break
    fi
    committed+=("$rel")
  done
  if [ "${#committed[@]}" -ne "${#CHANGED_PATHS[@]}" ]; then
    for ((i=${#committed[@]}-1; i>=0; i--)); do
      rel="${committed[$i]}"; dest="$TARGET/$rel"; backup="$rollback/$rel"
      if [ "$(cat "$backup.kind" 2>/dev/null)" = "existing" ]; then cp -p "$backup" "$dest" 2>/dev/null || true; else rm -f "$dest"; fi
    done
    echo "error: commit failed; staged changes rolled back" >&2
    return 1
  fi
  return 0
}

desired_source_for() { # <target_rel> [recorded_source]
  local rel="$1" recorded="${2:-}" base
  case "$rel" in
    AGENTS.md|CLAUDE.md|init.sh|checklist.sh)
      base="${rel##*/}"
      if [ -f "$TEMPLATES_DIR/by-type/$DTYPE/$base" ]; then printf 'by-type/%s/%s' "$DTYPE" "$base"; else printf 'common/%s' "$base"; fi ;;
    feature_list.json) printf 'common/feature_list.json' ;;
    .harness/config.json) printf '.harness/config.json.%s.example' "$PROJECT_TYPE" ;;
    session-handoff.md|clean-state-checklist.md) printf '%s' "$rel" ;;
    *) printf '%s' "$recorded" ;;
  esac
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
  if [ -f "$dest" ]; then
    return 0   # skip-if-exists
  fi
  expect_target_unchanged "$trel"
  stage_copy "$src" "$trel" || { echo "error: staging failed: $trel" >&2; return 1; }
  snap_add "$trel" "$srel" "$(sha256_file "$STAGE_DIR/$trel")"
  return 0
}

# render_flat <source_rel> <dest_abs> <target_rel> <snapshot_source_rel>
render_flat() {
  local src="$TEMPLATES_DIR/$1" dest="$2" trel="$3" srel="$4"
  [ -f "$src" ] || { echo "error: template missing: $src" >&2; return 1; }
  if [ -f "$dest" ]; then
    return 0
  fi
  expect_target_unchanged "$trel"
  stage_copy "$src" "$trel" || { echo "error: staging failed: $trel" >&2; return 1; }
  snap_add "$trel" "$srel" "$(sha256_file "$STAGE_DIR/$trel")"
  return 0
}

SNAPSHOT_PATH="$TARGET/.harness/.template-snapshot.json"

write_snapshot() {
  local out="$STAGE_DIR/.harness/.template-snapshot.json"
  mkdir -p "$(dirname "$out")" || return 1
  jq -n -S \
    --arg rev "$CAPTURED_REV" \
    --arg ver "$VERSION" \
    --argjson templates "$SNAP_ENTRIES" \
    '{ schema_version: 1, captured_from_git_rev: (if $rev == "" then null else $rev end), source_version: $ver, templates: $templates }' \
    > "$out" || return 1
  expect_target_unchanged ".harness/.template-snapshot.json"
  stage_mark ".harness/.template-snapshot.json"
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
  local brief_json="${1:-$TARGET/.harness/PROJECT_BRIEF.json}"
  local brief_md="${2:-$TARGET/.harness/PROJECT_BRIEF.md}"
  [ -f "$brief_json" ] || { echo "error: PROJECT_BRIEF.json missing; cannot render MD" >&2; return 1; }
  jq -e 'type == "object" and .schema_version == 1 and .advisory == true
    and (.source_version|type=="string" and length>0)
    and ((.captured_from_git_rev == null) or (.captured_from_git_rev|type=="string" and test("^[0-9a-f]{40}$")))
    and (.goal|type=="string" and test("[^[:space:]]"))
    and (.detected_type|type=="string") and (.stack|type=="string") and (.cadence|type=="string")
    and ((.deadline==null) or (.deadline|type=="string"))
    and (.test_framework|type=="string") and (.secrets_handling|type=="string") and (.external_network|type=="string")
    and (.success_criteria|type=="array" and length>0 and all(.[]; type=="string" and test("[^[:space:]]")))' \
    "$brief_json" >/dev/null 2>&1 || { echo "error: PROJECT_BRIEF.json is invalid; refusing to render" >&2; return 1; }
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
  } > "$brief_md" || return 1
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

  if [ "$STATE" = "legacy-unmanaged" ]; then
    local legacy_material legacy_digest legacy_path legacy_state
    legacy_material="state=legacy-unmanaged
target=$TARGET
host=$HOST
mode=$MODE
detected_type=$DTYPE
source_version=$VERSION
captured_rev=$CAPTURED_REV
force_config=$FORCE_CONFIG"
    for legacy_path in .harness/config.json .harness/.template-snapshot.json .harness/PROJECT_BRIEF.json .harness/PROJECT_BRIEF.md feature_list.json AGENTS.md CLAUDE.md init.sh claude-progress.md codex-progress.md; do
      legacy_state="$(path_state "$TARGET/$legacy_path")" || { echo "error: could not bind update plan: $legacy_path" >&2; return 1; }
      legacy_material="$legacy_material
$legacy_path|$legacy_state"
    done
    legacy_digest="$(printf '%s' "$legacy_material" | sha256_text)"
    [ -n "$legacy_digest" ] || { echo "error: could not hash update plan" >&2; return 1; }
    echo "=== Update plan ($( [ "$APPLY" = "true" ] && echo apply || echo 'dry-run — no writes' )) ==="
    echo "  would-create: .harness/.template-snapshot.json (legacy migration; existing files remain unclaimed)"
    if [ "$APPLY" != "true" ]; then
      echo "Plan token: $legacy_digest"
      echo "Re-run with --apply --plan-token $legacy_digest to write."
      return 0
    fi
    if [ "$UPDATE" = "true" ] && { [ -z "$PLAN_TOKEN" ] || [ "$PLAN_TOKEN" != "$legacy_digest" ]; }; then
      echo "error: update plan token missing or stale; rerun --update dry-run" >&2
      return 2
    fi
    return 3  # caller falls through to the migration-safe fresh renderer
  fi

  local snap="$TARGET/.harness/.template-snapshot.json" snapshot_base_sha plan_material plan_digest
  local brief_path_state brief_md_state
  snapshot_base_sha="$(sha256_file "$snap")"
  [ -n "$snapshot_base_sha" ] || { echo "error: could not hash snapshot" >&2; return 1; }
  brief_path_state="$(path_state "$TARGET/.harness/PROJECT_BRIEF.json")" || { echo "error: could not bind PROJECT_BRIEF.json" >&2; return 1; }
  brief_md_state="$(path_state "$TARGET/.harness/PROJECT_BRIEF.md")" || { echo "error: could not bind PROJECT_BRIEF.md" >&2; return 1; }
  plan_material="state=$STATE
target=$TARGET
host=$HOST
mode=$MODE
detected_type=$DTYPE
source_version=$VERSION
captured_rev=$CAPTURED_REV
force_config=$FORCE_CONFIG
snapshot=$snapshot_base_sha
brief_path=$brief_path_state
brief_md=$brief_md_state"
  if [ -n "$BRIEF_PATH" ]; then
    local brief_input_sha
    brief_input_sha="$(sha256_file "$BRIEF_PATH")"
    [ -n "$brief_input_sha" ] || { echo "error: could not hash Brief input" >&2; return 1; }
    plan_material="$plan_material
brief_input=$brief_input_sha"
  fi
  if [ "$BRIEF_STDIN" = "true" ] && [ "$UPDATE" = "true" ]; then
    echo "error: explicit --update does not support --brief-stdin; use a stable --brief file" >&2
    return 2
  fi
  local plan="" wrote_any=false
  local k src desired sha_snap sha_now sha_tmpl
  SNAP_ENTRIES="$(jq -c '.templates' "$snap")" || return 2
  stage_begin || return 1
  for k in $(jq -r '.templates | keys[]' "$snap" 2>/dev/null | tr -d '\r'); do
    src="$(jq -r --arg k "$k" '.templates[$k].source' "$snap" 2>/dev/null | tr -d '\r')"
    desired="$(desired_source_for "$k" "$src")"
    sha_snap="$(jq -r --arg k "$k" '.templates[$k].sha256' "$snap" 2>/dev/null | tr -d '\r')"
    [ -f "$TARGET/$k" ] && sha_now="$(sha256_file "$TARGET/$k")" || sha_now=""
    if [ -f "$TARGET/$k" ] && [ -z "$sha_now" ]; then rm -rf "$STAGE_DIR"; echo "error: could not hash target: $k" >&2; return 1; fi
    [ -n "$desired" ] && [ -f "$TEMPLATES_DIR/$desired" ] && sha_tmpl="$(sha256_file "$TEMPLATES_DIR/$desired")" || sha_tmpl=""
    plan_material="$plan_material
$k|source=$src|desired=$desired|snapshot=$sha_snap|current=${sha_now:-missing}|template=${sha_tmpl:-missing}"

    if [ -z "$sha_now" ]; then
      if [ -z "$sha_tmpl" ]; then
        plan="$(printf '%s\n%s' "$plan" "  would-skip (template unavailable): $k")"
        continue
      fi
      plan="$(printf '%s\n%s' "$plan" "  would-create: $k")"
      if [ "$APPLY" = "true" ]; then
        expect_classified_target "$k" "$sha_now"
        stage_copy "$TEMPLATES_DIR/$desired" "$k" || { rm -rf "$STAGE_DIR"; return 1; }
        snap_add "$k" "$desired" "$sha_tmpl"
        wrote_any=true
      fi
      continue
    fi
    if [ -n "$sha_tmpl" ] && [ "$sha_now" = "$sha_tmpl" ]; then
      snap_add "$k" "$desired" "$sha_tmpl"
      continue   # identical → skip
    fi
    if [ "$k" = ".harness/config.json" ] && [ "$FORCE_CONFIG" = "true" ] && [ -n "$sha_tmpl" ]; then
      plan="$(printf '%s\n%s' "$plan" "  would-update (--force-config): $k")"
      if [ "$APPLY" = "true" ]; then
        expect_classified_target "$k" "$sha_now"
        stage_copy "$TEMPLATES_DIR/$desired" "$k" || { rm -rf "$STAGE_DIR"; return 1; }
        snap_add "$k" "$desired" "$sha_tmpl"; wrote_any=true
      fi
    elif [ "$sha_now" = "$sha_snap" ] && [ -n "$sha_tmpl" ] && [ "$sha_tmpl" != "$sha_snap" ]; then
      plan="$(printf '%s\n%s' "$plan" "  would-update (template changed): $k")"
      if [ "$APPLY" = "true" ]; then
        expect_classified_target "$k" "$sha_now"
        stage_copy "$TEMPLATES_DIR/$desired" "$k" || { rm -rf "$STAGE_DIR"; return 1; }
        snap_add "$k" "$desired" "$sha_tmpl"
        wrote_any=true
      fi
    elif [ "$sha_now" != "$sha_tmpl" ] && [ "$sha_now" != "$sha_snap" ]; then
      plan="$(printf '%s\n%s' "$plan" "  would-skip (user modified): $k")"
    fi
  done

  plan_digest="$(printf '%s' "$plan_material" | sha256_text)"
  [ -n "$plan_digest" ] || { rm -rf "$STAGE_DIR"; echo "error: could not hash update plan" >&2; return 1; }

  if [ "$APPLY" != "true" ]; then
    echo "=== Update plan (dry-run — no writes) ==="
    printf '%s\n' "$plan" | sed '/^$/d'
    echo "Plan token: $plan_digest"
    echo "Re-run with --apply --plan-token $plan_digest to write."
    rm -rf "$STAGE_DIR"
    return 0
  fi

  if [ "$UPDATE" = "true" ] && { [ -z "$PLAN_TOKEN" ] || [ "$PLAN_TOKEN" != "$plan_digest" ]; }; then
    rm -rf "$STAGE_DIR"
    echo "error: update plan token missing or stale; rerun --update dry-run" >&2
    return 2
  fi

  if [ "$wrote_any" = "true" ]; then
    write_snapshot || { rm -rf "$STAGE_DIR"; return 1; }
    expect_classified_target ".harness/.template-snapshot.json" "$snapshot_base_sha"
  fi
  local snap_for_digest="$snap" digest brief_out md_out
  [ "$wrote_any" = "true" ] && snap_for_digest="$STAGE_DIR/.harness/.template-snapshot.json"
  digest="$(sha256_file "$snap_for_digest")"
  if [ -n "$BRIEF_PATH" ] || [ "$BRIEF_STDIN" = "true" ]; then
    brief_out="$STAGE_DIR/.harness/PROJECT_BRIEF.json"; md_out="$STAGE_DIR/.harness/PROJECT_BRIEF.md"
    mkdir -p "$(dirname "$brief_out")" || { rm -rf "$STAGE_DIR"; return 1; }
    build_brief "$digest" > "$brief_out" || { rm -rf "$STAGE_DIR"; return 1; }
    bash "$BRIEF_VALIDATOR" "$brief_out" --expected-version="$VERSION" || { rm -rf "$STAGE_DIR"; return 2; }
    render_brief_md "$brief_out" "$md_out" || { rm -rf "$STAGE_DIR"; return 1; }
    if [ -n "$EXISTING_BRIEF_SHA" ]; then expect_classified_target ".harness/PROJECT_BRIEF.json" "$EXISTING_BRIEF_SHA"; else expect_target_unchanged ".harness/PROJECT_BRIEF.json"; fi
    expect_target_unchanged ".harness/PROJECT_BRIEF.md"
    stage_mark ".harness/PROJECT_BRIEF.json"; stage_mark ".harness/PROJECT_BRIEF.md"
  elif [ "$wrote_any" = "true" ] && [ -f "$TARGET/.harness/PROJECT_BRIEF.json" ]; then
    brief_out="$STAGE_DIR/.harness/PROJECT_BRIEF.json"; md_out="$STAGE_DIR/.harness/PROJECT_BRIEF.md"
    mkdir -p "$(dirname "$brief_out")" || { rm -rf "$STAGE_DIR"; return 1; }
    local brief_base_sha
    brief_base_sha="$(sha256_file "$TARGET/.harness/PROJECT_BRIEF.json")"
    [ -n "$brief_base_sha" ] || { rm -rf "$STAGE_DIR"; return 1; }
    jq -S --arg d "$digest" '.template_manifest_digest = $d' "$TARGET/.harness/PROJECT_BRIEF.json" > "$brief_out" || { rm -rf "$STAGE_DIR"; return 1; }
    bash "$BRIEF_VALIDATOR" "$brief_out" --expected-version="$VERSION" || { rm -rf "$STAGE_DIR"; return 2; }
    render_brief_md "$brief_out" "$md_out" || { rm -rf "$STAGE_DIR"; return 1; }
    expect_classified_target ".harness/PROJECT_BRIEF.json" "$brief_base_sha"; expect_target_unchanged ".harness/PROJECT_BRIEF.md"
    stage_mark ".harness/PROJECT_BRIEF.json"; stage_mark ".harness/PROJECT_BRIEF.md"
  fi
  if [ "${#CHANGED_PATHS[@]}" -gt 0 ]; then commit_stage || { rm -rf "$STAGE_DIR"; return 1; }; fi
  rm -rf "$STAGE_DIR"
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
    --plan-token=*)     PLAN_TOKEN="${arg#--plan-token=}" ;;
    --plan-token)
      shift
      [ $# -gt 0 ] || { echo "error: --plan-token requires a value" >&2; exit 2; }
      PLAN_TOKEN="$1"
      ;;
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
if [ -n "$PLAN_TOKEN" ] && ! printf '%s' "$PLAN_TOKEN" | grep -qE '^[0-9a-f]{64}$'; then
  echo "harness-init.sh: invalid --plan-token (must be 64 lowercase hex characters)" >&2
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
REPO_DTYPE="$(detect_project_type "$TARGET")"
DTYPE="$REPO_DTYPE"
PROJECT_TYPE="$(map_project_type "$DTYPE")"
CAPTURED_REV="$(captured_rev)"
STATE="$(detect_state "$TARGET")"
SNAPSHOT_PATH="$TARGET/.harness/.template-snapshot.json"

# ---- Brief input ------------------------------------------------------------

INPUT_BRIEF_JSON="{}"

# §7.2.1 defaults + legacy placeholders.
OP_DEFAULTS='{"commit":"ask","push":"ask","merge":"ask","release":"ask","install_packages":"ask","external_mutation":"ask","destructive_ops":false}'

# Validate every caller-provided field before any target write. Optional fields
# may be omitted (the canonical builder supplies spec defaults), but when
# present their type/enum/shape is fail-closed.
validate_brief_input() {
  printf '%s' "$1" | jq -e '
    def valid_date:
      capture("^(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})$") as $x
      | ($x.y|tonumber) as $y | ($x.m|tonumber) as $m | ($x.d|tonumber) as $d
      | ($m >= 1 and $m <= 12 and $d >= 1
         and $d <= ([31,(if (($y%4==0 and $y%100!=0) or $y%400==0) then 29 else 28 end),31,30,31,30,31,31,30,31,30,31][$m-1]));
    type == "object"
    and ((has("schema_version") | not) or .schema_version == 1)
    and (.goal | type == "string" and test("[^[:space:]]") and length <= 500)
    and (.success_criteria | type == "array" and length >= 1 and length <= 7
         and all(.[]; type == "string" and test("[^[:space:]]")))
    and ((has("detected_type") | not) or (.detected_type | IN("node","python","rust","go","shell","electron","mixed","docs","unknown")))
    and ((has("stack") | not) or (.stack | IN("node","python","rust","go","shell","electron","mixed","docs","unknown")))
    and ((has("cadence") | not) or (.cadence | IN("stable","weekly","daily","oneoff")))
    and ((has("deadline") | not) or .deadline == null or (.deadline | type == "string" and valid_date))
    and ((has("test_framework") | not) or (.test_framework | type == "string" and length > 0 and length <= 50))
    and ((has("secrets_handling") | not) or (.secrets_handling | IN("env-file","vault","keyring","unspecified")))
    and ((has("external_network") | not) or (.external_network | IN("ask","allowed","denied")))
    and ((has("prohibitions") | not) or (.prohibitions | type == "array" and length <= 20 and all(.[]; type == "string" and test("[^[:space:]]") and length <= 200)))
    and ((has("initial_project_state") | not) or (.initial_project_state | type == "object"
         and all(to_entries[];
           (.key | IN("is_git_repo","has_existing_tests","existing_harness_files","detection_summary"))
           and (if (.key|IN("is_git_repo","has_existing_tests")) then (.value|type)=="boolean"
                elif .key=="existing_harness_files" then (.value|type)=="array" and all(.value[]; type=="string")
                else (.value|type)=="string" and (.value|length)<=200 end))))
    and ((has("operation_preferences") | not) or
         (.operation_preferences | type == "object"
          and all(to_entries[]; if .key == "destructive_ops" then (.value|type)=="boolean"
                                else (.key|IN("commit","push","merge","release","install_packages","external_mutation"))
                                  and (.value|IN("ask","auto","denied")) end)))
    and ((has("defaults_applied") | not) or (.defaults_applied | type == "array" and all(.[ ];
         type == "object" and has("value") and (.field|type=="string" and startswith("/"))
         and (.rationale|type=="string" and length<=200)
         and (.source|IN("spec_default","legacy_placeholder")))))
    and ((has("conflicts_resolved") | not) or (.conflicts_resolved | type == "array" and all(.[ ];
         type == "object" and (.field|type=="string" and startswith("/"))
         and (.repo_evidence|type=="string") and (.user_input|type=="string")
         and (.resolution|IN("user","repo","custom","deferred")) and has("resolved_value")
         and (if .resolution=="deferred" then .resolved_value==null else .resolved_value!=null end))))
    and ((has("provenance") | not) or (.provenance | type == "object" and all(to_entries[];
         (.key|startswith("/")) and (.value|type=="object")
         and (.value.source|IN("conversation","repo","environment","cli","spec_default","legacy_placeholder","existing_brief")))))
    and (if (.detected_type // "") | IN("mixed","unknown")
         then (.type_evidence | type == "object")
           and (.type_evidence.markers_seen | type == "array" and all(.[]; type=="string"))
           and (.type_evidence.notes | type == "string" and length <= 500)
         else ((has("type_evidence") | not) or .type_evidence == null or (.type_evidence|type=="object")) end)
  ' >/dev/null 2>&1
}

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
  # Resume inputs may intentionally contain only changed fields. Merge them
  # over the existing canonical Brief before validation so confirmed values,
  # nested preferences, defaults, conflicts, and provenance are preserved.
  if [ "$STATE" = "managed-valid" ] && [ -f "$TARGET/.harness/PROJECT_BRIEF.json" ]; then
    EXISTING_BRIEF_SHA="$(sha256_file "$TARGET/.harness/PROJECT_BRIEF.json")"
    [ -n "$EXISTING_BRIEF_SHA" ] || { echo "error: could not hash existing PROJECT_BRIEF.json" >&2; exit 2; }
    EXISTING_BRIEF_JSON="$(cat "$TARGET/.harness/PROJECT_BRIEF.json" 2>/dev/null)" || EXISTING_BRIEF_JSON=""
    [ "$(sha256_file "$TARGET/.harness/PROJECT_BRIEF.json")" = "$EXISTING_BRIEF_SHA" ] || { echo "error: PROJECT_BRIEF.json changed during read" >&2; exit 2; }
    if ! printf '%s' "$EXISTING_BRIEF_JSON" | jq -e 'type=="object"' >/dev/null 2>&1; then
      echo "error: existing PROJECT_BRIEF.json is invalid" >&2; exit 2
    fi
    INPUT_BRIEF_JSON="$(jq -n --argjson old "$EXISTING_BRIEF_JSON" --argjson new "$INPUT_BRIEF_JSON" '
      ($old * $new)
      | .initial_project_state = (($old.initial_project_state // {}) * ($new.initial_project_state // {}))
      | .operation_preferences = (($old.operation_preferences // {}) * ($new.operation_preferences // {}))
      | .provenance = (($old.provenance // {}) * ($new.provenance // {}))')" || exit 2
  fi
  if ! printf '%s' "$INPUT_BRIEF_JSON" | jq -e '(.goal | type) == "string" and (.goal | test("[^[:space:]]")) and (.goal | length) <= 500' >/dev/null 2>&1; then
    echo "error: required field 'goal' is missing or empty" >&2
    exit 2
  fi
  if ! printf '%s' "$INPUT_BRIEF_JSON" | jq -e '(.success_criteria | type) == "array" and (.success_criteria | length) >= 1 and (.success_criteria | length) <= 7 and ([.success_criteria[] | (type == "string") and test("[^[:space:]]")] | all)' >/dev/null 2>&1; then
    echo "error: required field 'success_criteria' is missing or empty" >&2
    exit 2
  fi
  if ! validate_brief_input "$INPUT_BRIEF_JSON"; then
    echo "error: Brief: schema or enum validation failed" >&2
    exit 2
  fi
fi

# On the resolved Brief path, template/config selection is Brief-driven. Repo
# detection is only the fallback for fields that the Agent legitimately left
# absent and for legacy mode.
if [ -n "$BRIEF_PATH" ] || [ "$BRIEF_STDIN" = "true" ]; then
  DTYPE="$(printf '%s' "$INPUT_BRIEF_JSON" | jq -r --arg d "$REPO_DTYPE" '.detected_type // $d' | tr -d '\r')"
elif [ "$STATE" = "managed-valid" ] && [ -f "$TARGET/.harness/PROJECT_BRIEF.json" ]; then
  DTYPE="$(jq -r --arg d "$REPO_DTYPE" '.detected_type // $d' "$TARGET/.harness/PROJECT_BRIEF.json" 2>/dev/null | tr -d '\r' || printf '%s' "$REPO_DTYPE")"
fi
PROJECT_TYPE="$(map_project_type "$DTYPE")"
INITIAL_STATE="$(compute_initial_state)"
TYPE_EVIDENCE="$(compute_type_evidence)"

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
  bash "$BRIEF_VALIDATOR" "$TARGET/.harness/PROJECT_BRIEF.json" --expected-version="$VERSION" || exit 2
  stage_begin || exit 1
  mkdir -p "$STAGE_DIR/.harness" || { rm -rf "$STAGE_DIR"; exit 1; }
  render_source_sha="$(sha256_file "$TARGET/.harness/PROJECT_BRIEF.json")"
  [ -n "$render_source_sha" ] || { echo "error: could not hash PROJECT_BRIEF.json" >&2; rm -rf "$STAGE_DIR"; exit 1; }
  if ! render_brief_md "$TARGET/.harness/PROJECT_BRIEF.json" "$STAGE_DIR/.harness/PROJECT_BRIEF.md"; then rm -rf "$STAGE_DIR"; exit 1; fi
  [ "$(sha256_file "$TARGET/.harness/PROJECT_BRIEF.json")" = "$render_source_sha" ] || { echo "error: PROJECT_BRIEF.json changed during render" >&2; rm -rf "$STAGE_DIR"; exit 1; }
  expect_target_unchanged ".harness/PROJECT_BRIEF.md"
  stage_mark ".harness/PROJECT_BRIEF.md"
  if [ "$(sha256_file "$TARGET/.harness/PROJECT_BRIEF.json")" = "$render_source_sha" ] && commit_stage; then rm -rf "$STAGE_DIR"; exit 0; fi
  rm -rf "$STAGE_DIR"; exit 1
fi

if [ "$UPDATE" = "true" ]; then
  do_update
  update_rc=$?
  [ "$update_rc" -eq 3 ] || exit "$update_rc"
fi

if [ "$STATE" = "managed-inconsistent" ]; then
  echo "error: .harness/.template-snapshot.json is damaged (managed-inconsistent); back it up and enter the explicit recovery flow" >&2
  exit 2
fi

if [ "$STATE" = "managed-valid" ]; then
  if [ -n "$BRIEF_PATH" ] || [ "$BRIEF_STDIN" = "true" ]; then
    # A resolved Brief is the confirmation token for resume. Run the same
    # 3-way engine as explicit update and merge the Brief fields above.
    APPLY="true"
    do_update
    exit $?
  fi
  if [ "$FORCE_CONFIG" = "true" ]; then
    APPLY="true"
    do_update
    exit $?
  fi
  # §3.4.1 legacy-skip-existing: already initialized, no overwrite.
  echo "harness-init.sh: project already initialized (managed-valid); skipping existing files"
  echo "  (use --update to upgrade templates, or --brief to resume with a confirmed Brief)"
  exit 0
fi

# ---- render manifest --------------------------------------------------------

# Fresh init / legacy-unmanaged initial write. #1-#3 always written on fresh;
# #4-#14 skip-if-exists (never overwrite user files).
stage_begin || exit 1

# #9 AGENTS.md, #10 CLAUDE.md, #8 init.sh (typed).
render_typed "AGENTS.md" "$TARGET/AGENTS.md" "AGENTS.md" || { rm -rf "$STAGE_DIR"; exit 1; }
render_typed "CLAUDE.md" "$TARGET/CLAUDE.md" "CLAUDE.md" || { rm -rf "$STAGE_DIR"; exit 1; }
render_typed "init.sh"   "$TARGET/init.sh"   "init.sh" || { rm -rf "$STAGE_DIR"; exit 1; }

# #7 feature_list.json (type-agnostic, from common/).
render_flat "common/feature_list.json" "$TARGET/feature_list.json" "feature_list.json" "common/feature_list.json" || { rm -rf "$STAGE_DIR"; exit 1; }

# #4 .harness/config.json (type-matched example).
CONFIG_SRC="$TEMPLATES_DIR/.harness/config.json.${PROJECT_TYPE}.example"
CONFIG_SREL=".harness/config.json.${PROJECT_TYPE}.example"
if [ ! -f "$CONFIG_SRC" ]; then
  echo "error: config example missing: $CONFIG_SRC" >&2
  rm -rf "$STAGE_DIR"
  exit 1
fi
if [ ! -f "$TARGET/.harness/config.json" ] || [ "$FORCE_CONFIG" = "true" ]; then
  expect_target_unchanged ".harness/config.json"
  stage_copy "$CONFIG_SRC" ".harness/config.json" || { echo "error: staging failed: config.json" >&2; rm -rf "$STAGE_DIR"; exit 1; }
  snap_add ".harness/config.json" "$CONFIG_SREL" "$(sha256_file "$STAGE_DIR/.harness/config.json")"
fi

# #11 progress (host-specific; NOT recorded in the snapshot — it would break
# AC-14 cross-host byte-equality of the snapshot).
PROGRESS_DEST="$TARGET/claude-progress.md"
[ "$HOST" = "codex" ] && PROGRESS_DEST="$TARGET/codex-progress.md"
if [ ! -f "$PROGRESS_DEST" ]; then
  expect_target_unchanged "${PROGRESS_DEST##*/}"
  stage_copy "$TEMPLATES_DIR/claude-progress.md" "${PROGRESS_DEST##*/}" || { echo "error: staging failed: progress" >&2; rm -rf "$STAGE_DIR"; exit 1; }
fi

# #6 .gitignore append (never overwrite user entries).
GITIGNORE="$TARGET/.gitignore"
if ! { [ -f "$GITIGNORE" ] && grep -Fxq '.harness/logs/' "$GITIGNORE" && grep -Fxq '.harness/.registry.lock/' "$GITIGNORE"; }; then
  mkdir -p "$STAGE_DIR"
  {
    if [ -f "$GITIGNORE" ]; then cat "$GITIGNORE"; [ ! -s "$GITIGNORE" ] || echo ""; fi
    echo "# harness-companion"
    echo ".harness/logs/"
    echo ".harness/.registry.lock/"
  } > "$STAGE_DIR/.gitignore" || { rm -rf "$STAGE_DIR"; exit 1; }
  expect_target_unchanged ".gitignore"
  stage_mark ".gitignore"
fi

# --full extras: #12 session-handoff.md, #13 clean-state-checklist.md, #14 checklist.sh.
if [ "$MODE" = "full" ]; then
  render_flat "session-handoff.md"       "$TARGET/session-handoff.md"       "session-handoff.md"       "session-handoff.md" || { rm -rf "$STAGE_DIR"; exit 1; }
  render_flat "clean-state-checklist.md" "$TARGET/clean-state-checklist.md" "clean-state-checklist.md" "clean-state-checklist.md" || { rm -rf "$STAGE_DIR"; exit 1; }
  render_typed "checklist.sh"            "$TARGET/checklist.sh"            "checklist.sh" || { rm -rf "$STAGE_DIR"; exit 1; }
fi

# ---- snapshot + brief -------------------------------------------------------

write_snapshot || { rm -rf "$STAGE_DIR"; exit 1; }
SNAPSHOT_DIGEST="$(sha256_file "$STAGE_DIR/.harness/.template-snapshot.json")"

mkdir -p "$STAGE_DIR/.harness"
build_brief "$SNAPSHOT_DIGEST" > "$STAGE_DIR/.harness/PROJECT_BRIEF.json" || { rm -rf "$STAGE_DIR"; exit 1; }
if ! bash "$BRIEF_VALIDATOR" "$STAGE_DIR/.harness/PROJECT_BRIEF.json" --expected-version="$VERSION"; then
  echo "error: generated PROJECT_BRIEF.json does not satisfy the canonical contract" >&2
  rm -rf "$STAGE_DIR"
  exit 2
fi
render_brief_md "$STAGE_DIR/.harness/PROJECT_BRIEF.json" "$STAGE_DIR/.harness/PROJECT_BRIEF.md" || { rm -rf "$STAGE_DIR"; exit 1; }
expect_target_unchanged ".harness/PROJECT_BRIEF.json"; expect_target_unchanged ".harness/PROJECT_BRIEF.md"
stage_mark ".harness/PROJECT_BRIEF.json"; stage_mark ".harness/PROJECT_BRIEF.md"
LOGS_PREEXISTED=false
HARNESS_PREEXISTED=false
[ -d "$TARGET/.harness/logs/runs" ] && LOGS_PREEXISTED=true
[ -d "$TARGET/.harness" ] && HARNESS_PREEXISTED=true
for guarded_dir in "$TARGET/.harness" "$TARGET/.harness/logs" "$TARGET/.harness/logs/runs"; do
  if [ -L "$guarded_dir" ]; then
    echo "error: refusing symlink directory in managed path: ${guarded_dir#"$TARGET/"}" >&2
    rm -rf "$STAGE_DIR"; exit 1
  fi
done
mkdir -p "$TARGET/.harness/logs/runs" || { echo "error: could not create run log directory" >&2; rm -rf "$STAGE_DIR"; exit 1; }
if ! commit_stage; then
  if [ "$LOGS_PREEXISTED" != "true" ]; then
    rmdir "$TARGET/.harness/logs/runs" "$TARGET/.harness/logs" 2>/dev/null || true
    [ "$HARNESS_PREEXISTED" = "true" ] || rmdir "$TARGET/.harness" 2>/dev/null || true
  fi
  rm -rf "$STAGE_DIR"; exit 1
fi
rm -rf "$STAGE_DIR"

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
