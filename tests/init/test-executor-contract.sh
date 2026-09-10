#!/bin/bash
# rc.3 deterministic executor regression contract (F-CONV-06/F-CONV-07).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT="$ROOT/scripts/harness-init.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1${2:+ — $2}"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf 'unknown'
}

tree_manifest() {
  local root="$1" path kind mode digest target
  (
    cd "$root" || exit 1
    while IFS= read -r -d '' path; do
      mode="$(mode_of "$path")"
      if [ -L "$path" ]; then
        target="$(readlink "$path")"
        printf 'symlink\t%s\t%s\t%s\n' "$mode" "$path" "$target"
      elif [ -d "$path" ]; then
        printf 'directory\t%s\t%s\n' "$mode" "$path"
      elif [ -f "$path" ]; then
        digest="$(sha256sum "$path" | awk '{print $1}')"
        printf 'file\t%s\t%s\t%s\n' "$mode" "$digest" "$path"
      else
        kind="$(stat -c '%F' "$path" 2>/dev/null || printf 'other')"
        printf 'other\t%s\t%s\t%s\n' "$mode" "$kind" "$path"
      fi
    done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
  )
}

# Exact filesystem shape used by AC-4/AC-11. Unlike tree_manifest (which also
# binds bytes for determinism), this deliberately records every generated path,
# its kind, and whether a regular file is executable. Implicit parent
# directories are included so an unexpected output cannot hide behind a list
# of required-path existence checks.
shape_manifest() {
  local root="$1" path executable
  (
    cd "$root" || exit 1
    while IFS= read -r -d '' path; do
      if [ -L "$path" ]; then
        printf 'symlink\t-\t%s\n' "$path"
      elif [ -d "$path" ]; then
        printf 'directory\t-\t%s\n' "$path"
      elif [ -f "$path" ]; then
        if [ -x "$path" ]; then executable=executable; else executable=non-executable; fi
        printf 'file\t%s\t%s\n' "$executable" "$path"
      else
        printf 'other\t-\t%s\n' "$path"
      fi
    done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
  )
}

EXPECTED_MINIMAL_CLAUDE=$'file\tnon-executable\t./.gitignore\ndirectory\t-\t./.harness\nfile\tnon-executable\t./.harness/.template-snapshot.json\nfile\tnon-executable\t./.harness/PROJECT_BRIEF.json\nfile\tnon-executable\t./.harness/PROJECT_BRIEF.md\nfile\tnon-executable\t./.harness/config.json\ndirectory\t-\t./.harness/logs\ndirectory\t-\t./.harness/logs/runs\nfile\tnon-executable\t./AGENTS.md\nfile\tnon-executable\t./CLAUDE.md\nfile\tnon-executable\t./claude-progress.md\nfile\tnon-executable\t./feature_list.json\nfile\texecutable\t./init.sh'
EXPECTED_FULL_CLAUDE=$'file\tnon-executable\t./.gitignore\ndirectory\t-\t./.harness\nfile\tnon-executable\t./.harness/.template-snapshot.json\nfile\tnon-executable\t./.harness/PROJECT_BRIEF.json\nfile\tnon-executable\t./.harness/PROJECT_BRIEF.md\nfile\tnon-executable\t./.harness/config.json\ndirectory\t-\t./.harness/logs\ndirectory\t-\t./.harness/logs/runs\nfile\tnon-executable\t./AGENTS.md\nfile\tnon-executable\t./CLAUDE.md\nfile\texecutable\t./checklist.sh\nfile\tnon-executable\t./claude-progress.md\nfile\tnon-executable\t./clean-state-checklist.md\nfile\tnon-executable\t./feature_list.json\nfile\texecutable\t./init.sh\nfile\tnon-executable\t./session-handoff.md'
EXPECTED_FULL_CODEX=$'file\tnon-executable\t./.gitignore\ndirectory\t-\t./.harness\nfile\tnon-executable\t./.harness/.template-snapshot.json\nfile\tnon-executable\t./.harness/PROJECT_BRIEF.json\nfile\tnon-executable\t./.harness/PROJECT_BRIEF.md\nfile\tnon-executable\t./.harness/config.json\ndirectory\t-\t./.harness/logs\ndirectory\t-\t./.harness/logs/runs\nfile\tnon-executable\t./AGENTS.md\nfile\tnon-executable\t./CLAUDE.md\nfile\texecutable\t./checklist.sh\nfile\tnon-executable\t./clean-state-checklist.md\nfile\tnon-executable\t./codex-progress.md\nfile\tnon-executable\t./feature_list.json\nfile\texecutable\t./init.sh\nfile\tnon-executable\t./session-handoff.md'

brief() {
  local path="$1" dtype="$2"
  jq -n --arg dtype "$dtype" '{
    schema_version:1, detected_type:$dtype, goal:"Ship a deterministic harness",
    success_criteria:["Executor contract passes"], cadence:"stable", deadline:null,
    stack:$dtype, test_framework:"unspecified", secrets_handling:"unspecified",
    external_network:"ask", prohibitions:[],
    operation_preferences:{commit:"ask",push:"ask",merge:"ask",release:"ask",install_packages:"ask",external_mutation:"ask",destructive_ops:false},
    defaults_applied:[], conflicts_resolved:[], provenance:{}, type_evidence:null
  }' > "$path"
}

plan_token() {
  local target="$1"; shift
  bash "$INIT" "$target" --update "$@" 2>/dev/null | sed -n 's/^Plan token: //p' | tail -1
}

# 1. Brief drives every typed output even when the target has no repo markers.
T1="$TMP/brief-python"; mkdir -p "$T1"; brief "$TMP/python.json" python
if bash "$INIT" "$T1" --brief "$TMP/python.json" --non-interactive >/dev/null 2>&1; then
  check "brief type drives config" test "$(jq -r .project_type "$T1/.harness/config.json")" = python
  check "brief type drives AGENTS" cmp -s "$T1/AGENTS.md" "$ROOT/templates/by-type/python/AGENTS.md"
  check "brief type drives CLAUDE" cmp -s "$T1/CLAUDE.md" "$ROOT/templates/by-type/python/CLAUDE.md"
check "brief type drives init" cmp -s "$T1/init.sh" "$ROOT/templates/by-type/python/init.sh"
else
  bad "brief-driven fresh init" "executor exited non-zero"
fi

# AC-4: default mode is exactly the complete minimal manifest (#1-#11).
for file in \
  .harness/PROJECT_BRIEF.json \
  .harness/PROJECT_BRIEF.md \
  .harness/.template-snapshot.json \
  .harness/config.json \
  .gitignore \
  feature_list.json \
  init.sh \
  AGENTS.md \
  CLAUDE.md \
  claude-progress.md; do
  check "minimal manifest file exists: $file" test -f "$T1/$file"
done
check "minimal manifest logs/runs is a directory" test -d "$T1/.harness/logs/runs"
check "minimal gitignore contains logs entry" grep -Fxq '.harness/logs/' "$T1/.gitignore"
check "minimal gitignore contains registry lock entry" grep -Fxq '.harness/.registry.lock/' "$T1/.gitignore"
check "minimal feature registry starts at revision 1" test "$(jq -r '.revision' "$T1/feature_list.json")" = 1
check "minimal init.sh is executable" test -x "$T1/init.sh"
check "minimal Claude output manifest is exact (path, kind, executable mode)" test "$(shape_manifest "$T1")" = "$EXPECTED_MINIMAL_CLAUDE"
check "minimal Brief persists all categories and advisory marker" jq -e '
  .schema_version == 1 and .advisory == true
  and (.goal | type == "string" and test("[^[:space:]]"))
  and (.success_criteria | type == "array" and length > 0 and all(.[]; type == "string" and test("[^[:space:]]")))
  and has("cadence") and has("deadline")
  and has("stack") and has("test_framework")
  and has("secrets_handling") and has("external_network") and has("prohibitions")
  and (.initial_project_state | type == "object")
  and (.operation_preferences | type == "object")
  and (.defaults_applied | type == "array")
  and (.conflicts_resolved | type == "array")
' "$T1/.harness/PROJECT_BRIEF.json"
check "minimal Claude host excludes Codex progress" test ! -e "$T1/codex-progress.md"
check "minimal omits session handoff" test ! -e "$T1/session-handoff.md"
check "minimal omits clean-state checklist" test ! -e "$T1/clean-state-checklist.md"
check "minimal omits checklist.sh" test ! -e "$T1/checklist.sh"
minimal_json_rev="$(jq -r '.captured_from_git_rev' "$T1/.harness/PROJECT_BRIEF.json")"
minimal_md_rev="$(sed -n 's/^<!-- git rev \([0-9a-f]\{40\}\) -->$/\1/p' "$T1/.harness/PROJECT_BRIEF.md")"
minimal_snap_rev="$(jq -r '.captured_from_git_rev' "$T1/.harness/.template-snapshot.json")"
check "minimal Brief JSON and MD revisions agree" test "$minimal_json_rev" = "$minimal_md_rev"
check "minimal Brief and snapshot revisions agree" test "$minimal_json_rev" = "$minimal_snap_rev"

# 2b. Same Brief is deterministic; host changes only the progress filename.
TA="$TMP/deterministic-a"; TB="$TMP/deterministic-b"; TC="$TMP/host-codex"
mkdir -p "$TA" "$TB" "$TC"
brief "$TMP/shell.json" shell
if bash "$INIT" "$TA" --brief "$TMP/shell.json" --non-interactive --host=claude --full >/dev/null 2>&1; then ok "deterministic full run A exits zero"; else bad "deterministic full run A exits zero"; fi
if bash "$INIT" "$TB" --brief "$TMP/shell.json" --non-interactive --host=claude --full >/dev/null 2>&1; then ok "deterministic full run B exits zero"; else bad "deterministic full run B exits zero"; fi
if bash "$INIT" "$TC" --brief "$TMP/shell.json" --non-interactive --host=codex --full >/dev/null 2>&1; then ok "cross-host Codex full run exits zero"; else bad "cross-host Codex full run exits zero"; fi
check "identical Brief produces byte-equal trees" diff -r "$TA" "$TB"
check "identical Brief preserves kinds and executable modes" test "$(tree_manifest "$TA")" = "$(tree_manifest "$TB")"
check "cross-host common artifacts byte-equal" diff -r --exclude=claude-progress.md --exclude=codex-progress.md "$TA" "$TC"
check "full Claude output manifest is exact (path, kind, executable mode)" test "$(shape_manifest "$TA")" = "$EXPECTED_FULL_CLAUDE"
check "full Codex output manifest is exact (path, kind, executable mode)" test "$(shape_manifest "$TC")" = "$EXPECTED_FULL_CODEX"

# AC-4/AC-11/AC-14: enumerate the binding output manifest instead of relying
# on a recursive diff over whatever files happened to be generated.
for target in "$TA" "$TC"; do
  label="$(basename "$target")"
  for file in \
    .harness/PROJECT_BRIEF.json \
    .harness/PROJECT_BRIEF.md \
    .harness/.template-snapshot.json \
    .harness/config.json \
    .gitignore \
    feature_list.json \
    init.sh \
    AGENTS.md \
    CLAUDE.md \
    session-handoff.md \
    clean-state-checklist.md \
    checklist.sh; do
    check "$label manifest file exists: $file" test -f "$target/$file"
  done
  check "$label manifest logs/runs is a directory" test -d "$target/.harness/logs/runs"
  check "$label gitignore contains logs entry" grep -Fxq '.harness/logs/' "$target/.gitignore"
  check "$label gitignore contains registry lock entry" grep -Fxq '.harness/.registry.lock/' "$target/.gitignore"
  check "$label feature registry starts at revision 1" test "$(jq -r '.revision' "$target/feature_list.json")" = 1
  check "$label init.sh is executable" test -x "$target/init.sh"
  check "$label checklist.sh is executable" test -x "$target/checklist.sh"
  check "$label Brief persists all categories and advisory marker" jq -e '
    .schema_version == 1 and .advisory == true
    and (.goal | type == "string" and test("[^[:space:]]"))
    and (.success_criteria | type == "array" and length > 0 and all(.[]; type == "string" and test("[^[:space:]]")))
    and has("cadence") and has("deadline")
    and has("stack") and has("test_framework")
    and has("secrets_handling") and has("external_network") and has("prohibitions")
    and (.initial_project_state | type == "object")
    and (.operation_preferences | type == "object")
    and (.defaults_applied | type == "array")
    and (.conflicts_resolved | type == "array")
  ' "$target/.harness/PROJECT_BRIEF.json"
  json_rev="$(jq -r '.captured_from_git_rev // "0000000000000000000000000000000000000000"' "$target/.harness/PROJECT_BRIEF.json")"
  md_rev="$(sed -n 's/^<!-- git rev \([0-9a-f]\{40\}\) -->$/\1/p' "$target/.harness/PROJECT_BRIEF.md")"
  snap_rev="$(jq -r '.captured_from_git_rev // "0000000000000000000000000000000000000000"' "$target/.harness/.template-snapshot.json")"
  check "$label Brief JSON and MD revisions agree" test "$json_rev" = "$md_rev"
  check "$label Brief and snapshot revisions agree" test "$json_rev" = "$snap_rev"
done
check "claude host progress path" test -f "$TA/claude-progress.md"
check "claude host excludes codex progress path" test ! -e "$TA/codex-progress.md"
check "codex host progress path" test -f "$TC/codex-progress.md"
check "codex host excludes claude progress path" test ! -e "$TC/claude-progress.md"

# 2. Schema failure is fail-closed and writes zero target bytes.
T2="$TMP/invalid"; mkdir -p "$T2"; printf sentinel > "$T2/sentinel"
jq '.cadence="sometimes"' "$TMP/python.json" > "$TMP/invalid.json"
BEFORE="$(tree_manifest "$T2")"
if bash "$INIT" "$T2" --brief "$TMP/invalid.json" --non-interactive >/dev/null 2>&1; then
  bad "invalid enum rejected"
else
  AFTER="$(tree_manifest "$T2")"
  check "invalid enum leaves target byte-equal" test "$BEFORE" = "$AFTER"
fi
for invalid_filter in '.deadline="2026-02-30"' '.initial_project_state={is_git_repo:"yes"}' '.defaults_applied=[{field:"/x",rationale:"r",source:"spec_default"}]' '.prohibitions=[""]'; do
  jq "$invalid_filter" "$TMP/python.json" > "$TMP/invalid-nested.json"
  BEFORE="$(tree_manifest "$T2")"
  if bash "$INIT" "$T2" --brief "$TMP/invalid-nested.json" --non-interactive >/dev/null 2>&1; then
    bad "invalid nested Brief field rejected ($invalid_filter)"
  else
    ok "invalid nested Brief field rejected ($invalid_filter)"
    AFTER="$(tree_manifest "$T2")"
    check "invalid nested Brief leaves full tree unchanged ($invalid_filter)" test "$BEFORE" = "$AFTER"
  fi
done

# 3. Resume merges partial Brief fields and protects user-modified templates.
printf '\nuser-owned-line\n' >> "$T1/AGENTS.md"
AGENTS_SHA="$(sha256sum "$T1/AGENTS.md" | awk '{print $1}')"
printf '{"test_framework":"pytest"}\n' > "$TMP/partial.json"
if bash "$INIT" "$T1" --brief "$TMP/partial.json" --non-interactive >/dev/null 2>&1; then
  check "resume preserves goal" test "$(jq -r .goal "$T1/.harness/PROJECT_BRIEF.json")" = "Ship a deterministic harness"
  check "resume applies explicit field" test "$(jq -r .test_framework "$T1/.harness/PROJECT_BRIEF.json")" = pytest
  check "resume protects user file" test "$(sha256sum "$T1/AGENTS.md" | awk '{print $1}')" = "$AGENTS_SHA"
  check "resume preserves snapshot entries" test "$(jq '.templates|length' "$T1/.harness/.template-snapshot.json")" -ge 5
else
  bad "partial Brief resume" "executor exited non-zero"
fi

# 4. Update recreates a missing tracked file and retains every snapshot entry.
COUNT_BEFORE="$(jq '.templates|length' "$T1/.harness/.template-snapshot.json")"
rm "$T1/CLAUDE.md"
T1_UPDATE_TOKEN="$(plan_token "$T1")"
if bash "$INIT" "$T1" --update --apply --plan-token "$T1_UPDATE_TOKEN" >/dev/null 2>&1; then
  check "update recreates missing tracked file" test -f "$T1/CLAUDE.md"
  check "update retains snapshot entries" test "$(jq '.templates|length' "$T1/.harness/.template-snapshot.json")" -eq "$COUNT_BEFORE"
else
  bad "update apply" "executor exited non-zero"
fi

# 4b. A sandboxed Agent may stream one byte-identical Brief for explicit
# update dry-run and apply. The token binds both the payload and target state.
STDIN_UPDATE='{"goal":"Ship through the guarded stdin update"}'
STDIN_BEFORE="$(tree_manifest "$T1")"
STDIN_PLAN="$(printf '%s' "$STDIN_UPDATE" | bash "$INIT" "$T1" --brief-stdin --non-interactive --host=codex --update 2>/dev/null)"
STDIN_TOKEN="$(printf '%s\n' "$STDIN_PLAN" | sed -n 's/^Plan token: //p' | tail -1)"
check "stdin update dry-run emits a bound token" bash -c 'printf %s "$1" | grep -qE "^[0-9a-f]{64}$"' _ "$STDIN_TOKEN"
check "stdin update dry-run writes zero target bytes" test "$STDIN_BEFORE" = "$(tree_manifest "$T1")"
if printf '%s' '{"goal":"Changed after dry-run"}' | bash "$INIT" "$T1" --brief-stdin --non-interactive --host=codex --update --apply --plan-token "$STDIN_TOKEN" >/dev/null 2>&1; then
  bad "stdin update token rejects a changed payload before any state change"
else
  check "changed stdin payload leaves pre-apply target unchanged" test "$STDIN_BEFORE" = "$(tree_manifest "$T1")"
fi
if printf '%s\n' "$STDIN_UPDATE" | bash "$INIT" "$T1" --brief-stdin --non-interactive --host=codex --update --apply --plan-token "$STDIN_TOKEN" >/dev/null 2>&1; then
  bad "stdin update token rejects a trailing-LF payload alias"
else
  check "trailing-LF payload leaves pre-apply target unchanged" test "$STDIN_BEFORE" = "$(tree_manifest "$T1")"
fi
if printf '%s\0ignored' "$STDIN_UPDATE" | bash "$INIT" "$T1" --brief-stdin --non-interactive --host=codex --update --apply --plan-token "$STDIN_TOKEN" >/dev/null 2>&1; then
  bad "stdin update rejects a NUL-delimited payload alias"
else
  check "NUL-delimited payload leaves pre-apply target unchanged" test "$STDIN_BEFORE" = "$(tree_manifest "$T1")"
fi
if printf '%s' "$STDIN_UPDATE" | bash "$INIT" "$T1" --brief-stdin --non-interactive --host=codex --update --apply --plan-token "$STDIN_TOKEN" >/dev/null 2>&1; then
  check "stdin update applies the approved goal" test "$(jq -r .goal "$T1/.harness/PROJECT_BRIEF.json")" = "Ship through the guarded stdin update"
  check "stdin update preserves user file" test "$(sha256sum "$T1/AGENTS.md" | awk '{print $1}')" = "$AGENTS_SHA"
else
  bad "stdin update apply" "executor exited non-zero"
fi

# 5. --force-config never overwrites non-config artifacts.
printf '\nforce-protected\n' >> "$T1/init.sh"
INIT_SHA="$(sha256sum "$T1/init.sh" | awk '{print $1}')"
printf '{"project_type":"broken"}\n' > "$T1/.harness/config.json"
T1_FORCE_TOKEN="$(plan_token "$T1" --force-config)"
if bash "$INIT" "$T1" --update --apply --force-config --plan-token "$T1_FORCE_TOKEN" >/dev/null 2>&1; then
  check "force-config restores only config" test "$(jq -r .project_type "$T1/.harness/config.json")" = python
  check "force-config protects init.sh" test "$(sha256sum "$T1/init.sh" | awk '{print $1}')" = "$INIT_SHA"
else
  bad "force-config invocation" "executor exited non-zero"
fi

# 6. Legacy-unmanaged update is explicit: dry-run zero writes; apply creates a
# snapshot that does not claim provenance for pre-existing files.
T6="$TMP/legacy"; mkdir -p "$T6/.harness"
printf 'user agents\n' > "$T6/AGENTS.md"
printf '{"schema_version":1}\n' > "$T6/feature_list.json"
printf '#!/bin/bash\n' > "$T6/init.sh"
LEGACY_BEFORE="$(find "$T6" -type f -print0 | sort -z | xargs -0 sha256sum)"
T6_TOKEN="$(plan_token "$T6")"
LEGACY_AFTER="$(find "$T6" -type f -print0 | sort -z | xargs -0 sha256sum)"
check "legacy update dry-run writes zero bytes" test "$LEGACY_BEFORE" = "$LEGACY_AFTER"
if bash "$INIT" "$T6" --update --apply --plan-token "$T6_TOKEN" >/dev/null 2>&1; then
  check "legacy apply creates snapshot" test -f "$T6/.harness/.template-snapshot.json"
  if jq -e '.templates | has("AGENTS.md") or has("feature_list.json") or has("init.sh")' "$T6/.harness/.template-snapshot.json" >/dev/null; then
    bad "legacy snapshot does not backfill provenance"
  else
    ok "legacy snapshot does not backfill provenance"
  fi
else
  bad "legacy update apply" "executor exited non-zero"
fi

# 6b. A dry-run token is invalid as soon as any bound target changes. In
# particular, --force-config cannot overwrite edits made after confirmation.
printf '{"project_type":"stale-plan"}\n' > "$T1/.harness/config.json"
STALE_TOKEN="$(plan_token "$T1" --force-config)"
printf '{"project_type":"edited-after-plan"}\n' > "$T1/.harness/config.json"
STALE_SHA="$(sha256sum "$T1/.harness/config.json" | awk '{print $1}')"
if bash "$INIT" "$T1" --update --apply --force-config --plan-token "$STALE_TOKEN" >/dev/null 2>&1; then
  bad "stale update token rejected"
else
  ok "stale update token rejected"
  check "stale token preserves post-plan edit" test "$(sha256sum "$T1/.harness/config.json" | awk '{print $1}')" = "$STALE_SHA"
fi

# 7. Structurally incomplete snapshot is rejected before any mutation.
T7="$TMP/bad-snapshot"; mkdir -p "$T7/.harness"
printf '{"schema_version":1,"templates":{}}\n' > "$T7/.harness/.template-snapshot.json"
BAD_SHA="$(sha256sum "$T7/.harness/.template-snapshot.json" | awk '{print $1}')"
if bash "$INIT" "$T7" --update --apply >/dev/null 2>&1; then
  bad "incomplete snapshot rejected"
else
check "incomplete snapshot unchanged" test "$(sha256sum "$T7/.harness/.template-snapshot.json" | awk '{print $1}')" = "$BAD_SHA"
fi

# 8. A commit-phase failure rolls back every earlier staged path.
T8="$TMP/atomic"; mkdir -p "$T8/CLAUDE.md"; printf 'sentinel\n' > "$T8/CLAUDE.md/keep"
TREE_BEFORE="$(find "$T8" -printf '%y %P\n' | LC_ALL=C sort; find "$T8" -type f -print0 | sort -z | xargs -0 sha256sum)"
if bash "$INIT" "$T8" --brief "$TMP/python.json" --non-interactive >/dev/null 2>&1; then
  bad "commit conflict fails closed"
else
  TREE_AFTER="$(find "$T8" -printf '%y %P\n' | LC_ALL=C sort; find "$T8" -type f -print0 | sort -z | xargs -0 sha256sum)"
  check "commit failure rolls back target tree" test "$TREE_BEFORE" = "$TREE_AFTER"
fi

# 9. Standalone renderer validates canonical JSON and preserves prior MD on
# malformed input.
T9="$TMP/render-invalid"; mkdir -p "$T9/.harness"
printf '{bad\n' > "$T9/.harness/PROJECT_BRIEF.json"
printf 'keep-md\n' > "$T9/.harness/PROJECT_BRIEF.md"
MD_SHA="$(sha256sum "$T9/.harness/PROJECT_BRIEF.md" | awk '{print $1}')"
if bash "$INIT" "$T9" --render-brief >/dev/null 2>&1; then
  bad "invalid Brief render rejected"
else
  check "invalid Brief render preserves MD" test "$(sha256sum "$T9/.harness/PROJECT_BRIEF.md" | awk '{print $1}')" = "$MD_SHA"
fi

if grep -nE '(^|[;&|[:space:]])read([[:space:]]|$)' "$INIT" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vF "if IFS= read -r -d '' INPUT_BRIEF_JSON; then" >/dev/null; then
  bad "executor contains an unapproved read"
else
  ok "executor contains only the explicit non-interactive Brief stdin read"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
