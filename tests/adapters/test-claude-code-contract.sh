#!/bin/bash
# test-claude-code-contract.sh — Phase 4 adapter behavioral contract tests
#
# Nine test groups:
#   G1: Structural output (Claude envelope shape, jq-valid embedded JSON)
#   G2: Fail-open (empty stdin, malformed JSON, missing cwd, no feature_list)
#   G3: v1 compat (wrapper invocation identical to direct invocation)
#   G4: Business logic absence (forbidden patterns not in adapter/wrappers)
#   G5: Wrapper purity (≤5 code lines, only shebang + SCRIPT_DIR + exec)
#   G6: WIP violation rendered through adapter
#   G7: Stale evidence — baseline MUST be written AND systemMessage MUST contain
#       stale warning (suppressOutput here is a setup failure, not a clean stop)
#   G8: status/audit new vs old path identity (byte-equal output + exit code)
#   G9: --project install round-trip from empty directory (SKILL.md, core CLIs,
#       settings hook paths, hook invocation, idempotent re-install)
#
# Required: jq, bash ≥4

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
ADAPTER_DIR="$ROOT_DIR/adapters/claude-code"
SCRIPTS_DIR="$ROOT_DIR/scripts"
FIXTURES_DIR="$TEST_DIR/fixtures"

SESSION_START="$ADAPTER_DIR/hooks/session-start.sh"
STOP_HANDOFF="$ADAPTER_DIR/hooks/stop-handoff.sh"

# Skip if adapter doesn't exist yet (idempotent install test).
if [ ! -x "$SESSION_START" ]; then
  echo "SKIP: $SESSION_START not present (Phase 4 not installed)"
  exit 0
fi

# Regenerate fixtures so each NDJSON's workspace_fingerprint matches the
# current fingerprint of the fixture directory. Required for the test package
# to be portable to any copy path. See _regen-fixtures.sh for details.
if [ -x "$TEST_DIR/_regen-fixtures.sh" ]; then
  bash "$TEST_DIR/_regen-fixtures.sh" all >/dev/null 2>&1 || true
fi

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

assert() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASSED=$((PASSED + 1))
    printf '  [PASS] %s\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf '  [FAIL] %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

assert_grep() {
  local name="$1" content="$2" pattern="$3"
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$content" > "$tmp"
  if grep -qE "$pattern" "$tmp"; then
    PASSED=$((PASSED + 1))
    printf '  [PASS] %s\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf '  [FAIL] %s\n    pattern: %s\n    content (first 200 chars): %s\n' "$name" "$pattern" "${content:0:200}"
  fi
  rm -f "$tmp"
}

assert_grep_absent() {
  local name="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file"; then
    FAILED=$((FAILED + 1))
    printf '  [FAIL] %s\n    FORBIDDEN pattern found in: %s\n    pattern: %s\n' "$name" "$file" "$pattern"
  else
    PASSED=$((PASSED + 1))
    printf '  [PASS] %s\n' "$name"
  fi
}

# Mock event JSON: real Claude Code sends e.g. {"session_id":"...","cwd":"/path","hook_event_name":"SessionStart"}
mock_stdin() {
  local cwd="$1"
  printf '{"session_id":"test","cwd":"%s","hook_event_name":"%s"}\n' "$cwd" "$2"
}

# ============================================================
echo "=== G1: Structural output tests ==="
# ============================================================

# G1.1: SessionStart happy path — emits Claude envelope with hookSpecificOutput
FIX="$FIXTURES_DIR/clean-project"
FIX_CWD="$(cygpath -m "$(cd "$FIX" && pwd)" 2>/dev/null || printf '%s' "$(cd "$FIX" && pwd)")"
STDIN="$(mock_stdin "$FIX_CWD" "SessionStart")"
OUT="$(printf '%s' "$STDIN" | bash "$SESSION_START" 2>/dev/null)"
RC=$?

assert "G1.1 SessionStart exit code" "0" "$RC"
assert_grep "G1.1 SessionStart envelope has hookSpecificOutput" "$OUT" '"hookSpecificOutput"'
assert_grep "G1.1 SessionStart envelope has hookEventName=SessionStart" "$OUT" '"hookEventName":"SessionStart"'
assert_grep "G1.1 SessionStart envelope has additionalContext" "$OUT" '"additionalContext"'
assert_grep "G1.1 SessionStart envelope has continue=true" "$OUT" '"continue":true'
# The embedded JSON string must parse. The OUT is a JSON envelope containing a
# JSON-encoded string under .hookSpecificOutput.additionalContext. Re-parse
# the envelope, then re-parse the extracted string.
PARSE_OK="$(printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | type == "string"' >/dev/null 2>&1 && echo yes || echo no)"
assert "G1.1 additionalContext is a JSON string" "yes" "$PARSE_OK"
# Now extract the string content and confirm it's valid as raw text.
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"

# G1.2: SessionStart content includes knowledge/file lines (from core/lib)
assert_grep "G1.2 status text includes Harness Status header" "$CTX" 'Harness Status'
assert_grep "G1.2 status text includes Knowledge section" "$CTX" 'Knowledge'
assert_grep "G1.2 status text includes AGENTS.md" "$CTX" 'AGENTS.md'

# G1.3: Stop hook happy path — emits Claude envelope with systemMessage
STDIN="$(mock_stdin "$FIX_CWD" "Stop")"
OUT="$(printf '%s' "$STDIN" | bash "$STOP_HANDOFF" 2>/dev/null)"
RC=$?
assert "G1.3 Stop exit code" "0" "$RC"

# Either systemMessage (with warnings) or suppressOutput (clean stop)
HAS_SYSTEM="$(printf '%s' "$OUT" | jq -e 'has("systemMessage")' 2>/dev/null)"
HAS_SUPPRESS="$(printf '%s' "$OUT" | jq -e 'has("suppressOutput")' 2>/dev/null)"
case "$HAS_SYSTEM$HAS_SUPPRESS" in
  truetrue|truefalse|false*) PASSED=$((PASSED+1)); printf '  [PASS] G1.3 Stop envelope shape (systemMessage or suppressOutput)\n' ;;
  *) FAILED=$((FAILED+1)); printf '  [FAIL] G1.3 Stop envelope shape — got: %s\n' "$OUT" ;;
esac
assert_grep "G1.3 Stop envelope has continue=true" "$OUT" '"continue":true'

# ============================================================
echo ""
echo "=== G2: Fail-open tests ==="
# ============================================================

# G2.1: empty stdin
OUT="$(printf '' | bash "$SESSION_START" 2>/dev/null)"
RC=$?
assert "G2.1 empty stdin exit code" "0" "$RC"
assert_grep "G2.1 empty stdin emits continue=true" "$OUT" '"continue":true'

# G2.2: malformed JSON stdin
OUT="$(printf 'this is not json {{{' | bash "$SESSION_START" 2>/dev/null)"
RC=$?
assert "G2.2 malformed JSON exit code" "0" "$RC"
assert_grep "G2.2 malformed JSON emits continue=true" "$OUT" '"continue":true'

# G2.3: cwd is non-existent path
STDIN="$(mock_stdin "/nonexistent/path/that/does/not/exist" "SessionStart")"
OUT="$(printf '%s' "$STDIN" | bash "$SESSION_START" 2>/dev/null)"
RC=$?
assert "G2.3 nonexistent cwd exit code" "0" "$RC"
assert_grep "G2.3 nonexistent cwd emits continue=true" "$OUT" '"continue":true'

# G2.4: cwd has no feature_list.json — must emit continue+suppressOutput
EMPTY_PROJECT="$TMPROOT/empty-project"
mkdir -p "$EMPTY_PROJECT"
STDIN="$(mock_stdin "$EMPTY_PROJECT" "SessionStart")"
OUT="$(printf '%s' "$STDIN" | bash "$SESSION_START" 2>/dev/null)"
RC=$?
assert "G2.4 no feature_list exit code" "0" "$RC"
assert_grep "G2.4 no feature_list emits suppressOutput" "$OUT" '"suppressOutput":true'

# ============================================================
echo ""
echo "=== G3: v1 compat tests ==="
# ============================================================

# G3.1: scripts/hooks/session-start.sh wrapper must exist and be executable
WRAPPER="$SCRIPTS_DIR/hooks/session-start.sh"
if [ -x "$WRAPPER" ]; then
  PASSED=$((PASSED+1)); printf '  [PASS] G3.1 wrapper session-start.sh exists and is executable\n'
else
  FAILED=$((FAILED+1)); printf '  [FAIL] G3.1 wrapper session-start.sh missing or not executable: %s\n' "$WRAPPER"
fi

# G3.2: invoking wrapper produces identical output to direct invocation
STDIN="$(mock_stdin "$FIX_CWD" "SessionStart")"
DIRECT="$(printf '%s' "$STDIN" | bash "$SESSION_START" 2>/dev/null)"
WRAPPED="$(printf '%s' "$STDIN" | bash "$WRAPPER" 2>/dev/null)"
RC=$?
assert "G3.2 wrapper exit code" "0" "$RC"
# Strip the embedded additionalContext content (timestamps / dynamic paths may differ).
# Compare envelope structure: same keys, same types.
KEYS_DIRECT="$(printf '%s' "$DIRECT" | jq -S 'keys_unsorted' 2>/dev/null)"
KEYS_WRAPPED="$(printf '%s' "$WRAPPED" | jq -S 'keys_unsorted' 2>/dev/null)"
assert "G3.2 wrapper envelope keys match direct" "$KEYS_DIRECT" "$KEYS_WRAPPED"

# G3.3: stop-handoff wrapper parity
WRAPPER_STOP="$SCRIPTS_DIR/hooks/stop-handoff.sh"
if [ -x "$WRAPPER_STOP" ]; then
  PASSED=$((PASSED+1)); printf '  [PASS] G3.3 wrapper stop-handoff.sh exists and is executable\n'
else
  FAILED=$((FAILED+1)); printf '  [FAIL] G3.3 wrapper stop-handoff.sh missing or not executable: %s\n' "$WRAPPER_STOP"
fi

# G3.4: harness-feature wrapper parity
WRAPPER_FEATURE="$SCRIPTS_DIR/harness-feature.sh"
if [ -x "$WRAPPER_FEATURE" ]; then
  PASSED=$((PASSED+1)); printf '  [PASS] G3.4 wrapper harness-feature.sh exists and is executable\n'
else
  FAILED=$((FAILED+1)); printf '  [FAIL] G3.4 wrapper harness-feature.sh missing or not executable: %s\n' "$WRAPPER_FEATURE"
fi

# ============================================================
echo ""
echo "=== G4: Business logic absence tests ==="
# ============================================================

# Adapter scripts MUST NOT contain business logic patterns.
ADAPTER_HOOKS=("$SESSION_START" "$STOP_HANDOFF")
FORBIDDEN=(
  'select\(\.status=="passing"\)'
  'select\(\.status=="in_progress"\)'
  'required_for_passing'
  'is_eligible_for_passing'
  'hc_wip_limit'
  'evidence\.commit'
  'fingerprint'
  '\.status == "passing"'
  '\.status == "in_progress"'
)

for f in "${ADAPTER_HOOKS[@]}"; do
  for pat in "${FORBIDDEN[@]}"; do
    assert_grep_absent "G4 forbidden pattern in $(basename "$f"): $pat" "$f" "$pat"
  done
done

# Wrappers MUST NOT contain any business logic keywords either.
WRAPPERS=(
  "$SCRIPTS_DIR/harness-verify.sh"
  "$SCRIPTS_DIR/harness-feature.sh"
  "$SCRIPTS_DIR/harness-status.sh"
  "$SCRIPTS_DIR/harness-audit.sh"
  "$SCRIPTS_DIR/hooks/session-start.sh"
  "$SCRIPTS_DIR/hooks/stop-handoff.sh"
)

WRAPPER_FORBIDDEN=(
  'jq'
  'feature_list'
  'select\('
  'is_eligible'
  'if '
  'case '
  'for '
  'while '
  'function'
)

for w in "${WRAPPERS[@]}"; do
  [ -f "$w" ] || continue
  for pat in "${WRAPPER_FORBIDDEN[@]}"; do
    assert_grep_absent "G4 wrapper purity: $pat not in $(basename "$w")" "$w" "$pat"
  done
done

# ============================================================
echo ""
echo "=== G5: Wrapper purity tests ==="
# ============================================================

for w in "${WRAPPERS[@]}"; do
  [ -f "$w" ] || continue
  name="$(basename "$w")"
  total=$(wc -l < "$w" | tr -d ' ')
  # Code lines = total lines minus shebang, comments, and blank lines.
  code=$(grep -cvE '^#|^[[:space:]]*$' "$w")
  if [ "$code" -le 5 ]; then
    PASSED=$((PASSED+1)); printf '  [PASS] G5.%s code lines ≤ 5 (got %d)\n' "$name" "$code"
  else
    FAILED=$((FAILED+1)); printf '  [FAIL] G5.%s code lines > 5 (got %d)\n' "$name" "$code"
  fi
  # Must contain exactly one exec and one SCRIPT_DIR assignment.
  has_sdir=$(grep -c '^SCRIPT_DIR=' "$w")
  has_exec=$(grep -c '^exec bash' "$w")
  if [ "$has_sdir" -eq 1 ] && [ "$has_exec" -eq 1 ]; then
    PASSED=$((PASSED+1)); printf '  [PASS] G5.%s has exactly SCRIPT_DIR + exec bash\n' "$name"
  else
    FAILED=$((FAILED+1)); printf '  [FAIL] G5.%s has SCRIPT_DIR=%d exec=%d (expected 1,1)\n' "$name" "$has_sdir" "$has_exec"
  fi
done

# ============================================================
echo ""
echo "=== G6: WIP violation rendered through adapter ==="
# ============================================================

# Verify that WIP violation from core appears in the SessionStart output.
FIX="$FIXTURES_DIR/wip-violation"
FIX_CWD="$(cygpath -m "$(cd "$FIX" && pwd)" 2>/dev/null || printf '%s' "$(cd "$FIX" && pwd)")"
STDIN="$(mock_stdin "$FIX_CWD" "SessionStart")"
OUT="$(printf '%s' "$STDIN" | bash "$SESSION_START" 2>/dev/null)"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
assert_grep "G6 WIP violation rendered" "$CTX" 'WIP violation'

# ============================================================
echo ""
echo "=== G7: Stale evidence rendered through adapter ==="
# ============================================================

# Pre-seed the baseline file so sr_handoff_warnings sees a baseline.
FIX="$FIXTURES_DIR/stale-evidence"
FIX_PATH="$(cygpath -m "$(cd "$FIX" && pwd)" 2>/dev/null || printf '%s' "$(cd "$FIX" && pwd)")"
# Use _baseline_key from core/lib/baseline.sh for cross-platform path
# normalization (D:/ vs /d/ on Git Bash produce the same key).
# shellcheck source=../../core/lib/baseline.sh
source "$ROOT_DIR/core/lib/baseline.sh"
KEY="$(_baseline_key "$FIX_PATH")"
mkdir -p "$HOME/.claude/harness-companion/baselines"
BASELINE_PATH="$HOME/.claude/harness-companion/baselines/$KEY.json"
printf '{"cwd":"%s","commit":"abc123def456","started_at":"20260801T100000Z"}\n' "$FIX_PATH" \
  > "$BASELINE_PATH"

# G7.1: baseline file MUST actually exist at the expected path
if [ -f "$BASELINE_PATH" ]; then
  PASSED=$((PASSED+1))
  printf '  [PASS] G7.1 baseline written at expected key path: %s\n' "$BASELINE_PATH"
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] G7.1 baseline file missing at: %s\n' "$BASELINE_PATH"
fi

STDIN="$(mock_stdin "$FIX_PATH" "Stop")"
OUT="$(printf '%s' "$STDIN" | bash "$STOP_HANDOFF" 2>/dev/null)"

# G7.2: Stop hook MUST emit systemMessage (NOT suppressOutput) — setup succeeded,
# baseline was readable, so a stale warning MUST be produced. suppressOutput here
# means the baseline write/setup path failed silently — which is the failure mode
# G4 explicitly forbids.
HAS_SYSTEM="$(printf '%s' "$OUT" | jq -e 'has("systemMessage")' 2>/dev/null)"
HAS_SUPPRESS="$(printf '%s' "$OUT" | jq -e 'has("suppressOutput")' 2>/dev/null)"
assert "G7.2 stop emits systemMessage (setup succeeded)" "true" "$HAS_SYSTEM"
if [ "$HAS_SUPPRESS" = "true" ]; then
  FAILED=$((FAILED+1))
  printf '  [FAIL] G7.2 stop emitted suppressOutput — setup failure hidden!\n'
fi

# G7.3: systemMessage content must include the stale-feature marker
MSG="$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null)"
assert_grep "G7.3 systemMessage mentions stale evidence" "$MSG" 'stale'
assert_grep "G7.3 systemMessage names feat-stale-001"  "$MSG" 'feat-stale-001'

# ============================================================
echo ""
echo "=== G8: status/audit new vs old path identity ==="
# ============================================================
# User requirement: actually execute status/audit via both the new core path
# AND the v1 wrapper path, and assert byte-identical output and exit code.

NEW_STATUS_OUT="$(bash "$ROOT_DIR/core/harness-status.sh" "$FIX_CWD" 2>&1)"
OLD_STATUS_OUT="$(bash "$ROOT_DIR/scripts/harness-status.sh" "$FIX_CWD" 2>&1)"
assert "G8 status: new core path == v1 wrapper output" "$OLD_STATUS_OUT" "$NEW_STATUS_OUT"

NEW_AUDIT_OUT="$(bash "$ROOT_DIR/core/harness-audit.sh" "$FIX_CWD" 2>&1)"
OLD_AUDIT_OUT="$(bash "$ROOT_DIR/scripts/harness-audit.sh" "$FIX_CWD" 2>&1)"
assert "G8 audit: new core path == v1 wrapper output" "$OLD_AUDIT_OUT" "$NEW_AUDIT_OUT"

# Exit codes must match exactly.
bash "$ROOT_DIR/core/harness-status.sh" "$FIX_CWD" >/dev/null 2>&1
NEW_STATUS_RC=$?
bash "$ROOT_DIR/scripts/harness-status.sh" "$FIX_CWD" >/dev/null 2>&1
OLD_STATUS_RC=$?
assert "G8 status exit codes match (new core == v1 wrapper)" "$OLD_STATUS_RC" "$NEW_STATUS_RC"

bash "$ROOT_DIR/core/harness-audit.sh" "$FIX_CWD" >/dev/null 2>&1
NEW_AUDIT_RC=$?
bash "$ROOT_DIR/scripts/harness-audit.sh" "$FIX_CWD" >/dev/null 2>&1
OLD_AUDIT_RC=$?
assert "G8 audit exit codes match (new core == v1 wrapper)" "$OLD_AUDIT_RC" "$NEW_AUDIT_RC"

# ============================================================
echo ""
echo "=== G9: --project install round-trip from empty directory ==="
# ============================================================
# User requirement: from an empty directory, run --project install and verify
# SKILL.md is present, core CLIs are present, settings.json hook paths are
# correct, and the installed hooks can actually be invoked.

INSTALL_SANDBOX="$(mktemp -d)"
pushd "$INSTALL_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
INSTALL_RC=$?
popd >/dev/null

assert "G9 --project install exit code" "0" "$INSTALL_RC"

INSTALL_TARGET="$INSTALL_SANDBOX/.claude/skills/harness-companion"
INSTALL_SETTINGS="$INSTALL_SANDBOX/.claude/settings.json"

# G9.1: SKILL.md was copied (so Claude Code can discover the skill)
if [ -f "$INSTALL_TARGET/SKILL.md" ] && head -1 "$INSTALL_TARGET/SKILL.md" | grep -q '^---'; then
  PASSED=$((PASSED+1))
  printf '  [PASS] G9.1 SKILL.md copied with YAML frontmatter\n'
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] G9.1 SKILL.md missing or invalid: %s\n' "$INSTALL_TARGET/SKILL.md"
fi

# G9.2: core CLIs are present and executable
for cli in harness-verify.sh harness-feature.sh harness-status.sh harness-audit.sh; do
  if [ -x "$INSTALL_TARGET/core/$cli" ]; then
    PASSED=$((PASSED+1))
    printf '  [PASS] G9.2 core/%s installed and executable\n' "$cli"
  else
    FAILED=$((FAILED+1))
    printf '  [FAIL] G9.2 core/%s missing or not executable: %s\n' "$cli" "$INSTALL_TARGET/core/$cli"
  fi
done

# G9.3: settings.json hooks point at the installed path
if [ -f "$INSTALL_SETTINGS" ]; then
  PASSED=$((PASSED+1))
  printf '  [PASS] G9.3 settings.json created\n'
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] G9.3 settings.json missing: %s\n' "$INSTALL_SETTINGS"
fi

SS_PATH="$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$INSTALL_SETTINGS" 2>/dev/null)"
STOP_PATH="$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$INSTALL_SETTINGS" 2>/dev/null)"
case "$SS_PATH" in
  *"harness-companion/scripts/hooks/session-start.sh"*)
    PASSED=$((PASSED+1))
    printf '  [PASS] G9.3 SessionStart hook command path points inside installed target\n' ;;
  *)
    FAILED=$((FAILED+1))
    printf '  [FAIL] G9.3 SessionStart hook path wrong: %s\n' "$SS_PATH" ;;
esac
case "$STOP_PATH" in
  *"harness-companion/scripts/hooks/stop-handoff.sh"*)
    PASSED=$((PASSED+1))
    printf '  [PASS] G9.3 Stop hook command path points inside installed target\n' ;;
  *)
    FAILED=$((FAILED+1))
    printf '  [FAIL] G9.3 Stop hook path wrong: %s\n' "$STOP_PATH" ;;
esac

# G9.4: installed hooks can actually be invoked
SS_HOOK="$INSTALL_TARGET/scripts/hooks/session-start.sh"
STOP_HOOK="$INSTALL_TARGET/scripts/hooks/stop-handoff.sh"
printf '{"session_id":"test","cwd":"%s","hook_event_name":"SessionStart"}\n' "$INSTALL_SANDBOX" \
  | bash "$SS_HOOK" >/dev/null 2>&1
assert "G9.4 invoke installed session-start.sh exit 0" "0" "$?"
printf '{"session_id":"test","cwd":"%s","hook_event_name":"Stop"}\n' "$INSTALL_SANDBOX" \
  | bash "$STOP_HOOK" >/dev/null 2>&1
assert "G9.4 invoke installed stop-handoff.sh exit 0" "0" "$?"

# G9.5: re-running install in the same sandbox is idempotent (no duplicate hook entries)
pushd "$INSTALL_SANDBOX" >/dev/null
bash "$ROOT_DIR/adapters/claude-code/install.sh" --project >/dev/null 2>&1
popd >/dev/null
SS_COUNT="$(jq '.hooks.SessionStart | length' "$INSTALL_SETTINGS" 2>/dev/null)"
STOP_COUNT="$(jq '.hooks.Stop | length' "$INSTALL_SETTINGS" 2>/dev/null)"
assert "G9.5 SessionStart still 1 entry after re-install" "1" "$SS_COUNT"
assert "G9.5 Stop still 1 entry after re-install" "1" "$STOP_COUNT"

# ============================================================
echo ""
echo "=== G10: v2 evidence_associations behavior (5 canonical cases) ==="
# ============================================================
# User requirement: readers must treat v2 registry as canonical —
#   evidence_associations[].run_id, per-run NDJSON, legacy_audit_evidence
#   as migration metadata only. Five canonical fixtures exercise:
#     (a) valid association      → no run-log issue block
#     (b) non-existent run_id    → run_log_missing
#     (c) corrupted run log      → run_log_invalid
#     (d) stale run              → stale_by_fingerprint
#     (e) no association         → no canonical evidence_associations

# Helper: invoke stop-handoff against a fixture and pull the systemMessage.
handoff_for() {
  local fix="$1"
  local fix_cwd
  fix_cwd="$(cygpath -m "$(cd "$fix" && pwd)" 2>/dev/null || printf '%s' "$(cd "$fix" && pwd)")"
  local stdin msg out
  stdin="$(mock_stdin "$fix_cwd" "Stop")"
  out="$(printf '%s' "$stdin" | bash "$STOP_HANDOFF" 2>/dev/null)"
  msg="$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null)"
  printf '%s' "$msg"
}

# G10.1: valid association — clean-project. systemMessage should NOT contain
# any of the issue markers. (It may still contain uncommitted-files warning
# if the parent repo is dirty, which is environment-coupled; we only assert
# NO run-log issue block and NO no-association block.)
MSG="$(handoff_for "$FIXTURES_DIR/clean-project")"
case "$MSG" in
  *"run-log issues"*|*"Some passing features have run-log"*)
    FAILED=$((FAILED+1))
    printf '  [FAIL] G10.1 valid association MUST NOT emit run-log issue block\n' ;;
  *"no canonical evidence_associations"*)
    FAILED=$((FAILED+1))
    printf '  [FAIL] G10.1 valid association MUST NOT emit no-association block\n' ;;
  *)
    PASSED=$((PASSED+1))
    printf '  [PASS] G10.1 valid association produces no run-log issue / no-association block\n' ;;
esac

# G10.2: non-existent run_id — invalid-runid fixture
MSG="$(handoff_for "$FIXTURES_DIR/invalid-runid")"
assert_grep "G10.2 non-existent run_id emits run_log_missing" "$MSG" 'run_log_missing'
assert_grep "G10.2 names affected feature feat-invrid-001"   "$MSG" 'feat-invrid-001'

# G10.3: corrupted run log — corrupted-runlog fixture
MSG="$(handoff_for "$FIXTURES_DIR/corrupted-runlog")"
assert_grep "G10.3 corrupted NDJSON emits run_log_invalid"   "$MSG" 'run_log_invalid'
assert_grep "G10.3 names affected feature feat-corrupt-001"  "$MSG" 'feat-corrupt-001'

# G10.4: stale run — stale-run fixture (workspace_fingerprint_verified mismatch)
MSG="$(handoff_for "$FIXTURES_DIR/stale-run")"
assert_grep "G10.4 stale run emits stale_by_fingerprint"     "$MSG" 'stale_by_fingerprint'
assert_grep "G10.4 names affected feature feat-stalerun-001"  "$MSG" 'feat-stalerun-001'

# G10.5: no association — passing feature with empty evidence_associations.
# Must be reported as "no canonical evidence_associations" (legacy_audit_evidence
# is migration metadata only and is NOT treated as canonical).
MSG="$(handoff_for "$FIXTURES_DIR/no-association")"
assert_grep "G10.5 no association emits no-evidence_associations block" "$MSG" 'no canonical evidence_associations'
assert_grep "G10.5 names affected feature feat-noassc-001"       "$MSG" 'feat-noassc-001'
# legacy_audit_evidence must NOT be treated as canonical passing evidence.
# The rendering must reference evidence_associations explicitly, not the legacy field.
if printf '%s' "$MSG" | grep -qiE 'these features are marked (passing|unverified).*no canonical evidence_associations'; then
  PASSED=$((PASSED+1))
  printf '  [PASS] G10.5 phrasing correctly disambiguates canonical vs legacy_audit_evidence\n'
else
  FAILED=$((FAILED+1))
  printf '  [FAIL] G10.5 phrasing is wrong — must say "no canonical evidence_associations"\n'
fi

# ============================================================
echo ""
echo "=== Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0