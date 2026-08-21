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

# 2b. Same Brief is deterministic; host changes only the progress filename.
TA="$TMP/deterministic-a"; TB="$TMP/deterministic-b"; TC="$TMP/host-codex"
mkdir -p "$TA" "$TB" "$TC"
brief "$TMP/shell.json" shell
bash "$INIT" "$TA" --brief "$TMP/shell.json" --non-interactive --host=claude >/dev/null 2>&1
bash "$INIT" "$TB" --brief "$TMP/shell.json" --non-interactive --host=claude >/dev/null 2>&1
bash "$INIT" "$TC" --brief "$TMP/shell.json" --non-interactive --host=codex >/dev/null 2>&1
check "identical Brief produces byte-equal trees" diff -r "$TA" "$TB"
check "cross-host common artifacts byte-equal" diff -r --exclude=claude-progress.md --exclude=codex-progress.md "$TA" "$TC"
check "claude host progress path" test -f "$TA/claude-progress.md"
check "codex host progress path" test -f "$TC/codex-progress.md"

# 2. Schema failure is fail-closed and writes zero target bytes.
T2="$TMP/invalid"; mkdir -p "$T2"; printf sentinel > "$T2/sentinel"
jq '.cadence="sometimes"' "$TMP/python.json" > "$TMP/invalid.json"
BEFORE="$(find "$T2" -type f -print0 | sort -z | xargs -0 sha256sum)"
if bash "$INIT" "$T2" --brief "$TMP/invalid.json" --non-interactive >/dev/null 2>&1; then
  bad "invalid enum rejected"
else
  AFTER="$(find "$T2" -type f -print0 | sort -z | xargs -0 sha256sum)"
  check "invalid enum leaves target byte-equal" test "$BEFORE" = "$AFTER"
fi
for invalid_filter in '.deadline="2026-02-30"' '.initial_project_state={is_git_repo:"yes"}' '.defaults_applied=[{field:"/x",rationale:"r",source:"spec_default"}]' '.prohibitions=[""]'; do
  jq "$invalid_filter" "$TMP/python.json" > "$TMP/invalid-nested.json"
  if bash "$INIT" "$T2" --brief "$TMP/invalid-nested.json" --non-interactive >/dev/null 2>&1; then
    bad "invalid nested Brief field rejected ($invalid_filter)"
  else
    ok "invalid nested Brief field rejected ($invalid_filter)"
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
if bash "$INIT" "$T1" --update --apply >/dev/null 2>&1; then
  check "update recreates missing tracked file" test -f "$T1/CLAUDE.md"
  check "update retains snapshot entries" test "$(jq '.templates|length' "$T1/.harness/.template-snapshot.json")" -eq "$COUNT_BEFORE"
else
  bad "update apply" "executor exited non-zero"
fi

# 5. --force-config never overwrites non-config artifacts.
printf '\nforce-protected\n' >> "$T1/init.sh"
INIT_SHA="$(sha256sum "$T1/init.sh" | awk '{print $1}')"
printf '{"project_type":"broken"}\n' > "$T1/.harness/config.json"
if bash "$INIT" "$T1" --force-config >/dev/null 2>&1; then
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
bash "$INIT" "$T6" --update >/dev/null 2>&1
LEGACY_AFTER="$(find "$T6" -type f -print0 | sort -z | xargs -0 sha256sum)"
check "legacy update dry-run writes zero bytes" test "$LEGACY_BEFORE" = "$LEGACY_AFTER"
if bash "$INIT" "$T6" --update --apply >/dev/null 2>&1; then
  check "legacy apply creates snapshot" test -f "$T6/.harness/.template-snapshot.json"
  if jq -e '.templates | has("AGENTS.md") or has("feature_list.json") or has("init.sh")' "$T6/.harness/.template-snapshot.json" >/dev/null; then
    bad "legacy snapshot does not backfill provenance"
  else
    ok "legacy snapshot does not backfill provenance"
  fi
else
  bad "legacy update apply" "executor exited non-zero"
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

if grep -nE 'read -[pr] ' "$INIT" >/dev/null; then bad "executor contains interactive prompt read"; else ok "executor contains no interactive prompt read"; fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
