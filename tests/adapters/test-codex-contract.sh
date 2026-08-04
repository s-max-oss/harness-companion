#!/bin/bash
# tests/adapters/test-codex-contract.sh — G5/G5b Codex adapter contract tests
#
# Phase 5b: Real Codex plugin/hooks integration. Tests are SELF-CONTAINED —
# JSON parsing uses python3, NOT jq. The test harness must not hard-depend
# on jq while the adapter supports python3 fallback.
#
# Test groups:
#   Group 1 (structural): plugin.json passes validate_plugin.py, hooks.json
#                          valid, .cmd wrappers, adapter.conf, SKILL.md
#   Group 2 (hook behavior): real SessionStart envelope, real Stop envelope,
#                            PreToolUse permissive, fail-open on all errors
#   Group 3 (adapter purity): forbidden-pattern grep (business logic in core only)
#   Group 4 (self-contained): python3 for all JSON assertions (no jq dep)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
PLUGIN_ROOT="${HARNESS_COMPANION_PLUGIN_ROOT:-$ROOT_DIR}"

PASSED=0
FAILED=0

# ---- Helpers -------------------------------------------------------------------

assert_pass() { PASSED=$((PASSED + 1)); printf '  [PASS] %s\n' "$1"; }
assert_fail() { FAILED=$((FAILED + 1)); printf '  [FAIL] %s %s\n' "$1" "${2:-}"; }

assert_eq() {
  if [ "$2" = "$3" ]; then assert_pass "$1"; else assert_fail "$1" "expected=$2 actual=$3"; fi
}

# python3 JSON assertion helper — self-contained, no jq dependency.
# ALL python3 helpers use encoding='utf-8' for Windows compatibility.
_py_json() {
  local file="$1" expr="$2"
  if [ ! -f "$file" ]; then echo ""; return 1; fi
  python3 -c "
import json, sys
try:
  d = json.load(open(sys.argv[1], encoding='utf-8'))
  path = sys.argv[2]
  if path == '.':
    print(json.dumps(d, ensure_ascii=False))
    sys.exit(0)
  parts = path.lstrip('.').replace('[', '.[').split('.')
  cur = d
  for p in parts:
    if not p: continue
    if p.startswith('[') and p.endswith(']'):
      cur = cur[int(p[1:-1])]
    else:
      cur = cur[p]
  if isinstance(cur, str):
    print(cur)
  else:
    print(json.dumps(cur, ensure_ascii=False))
except (KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError) as e:
  print('', file=sys.stderr)
  sys.exit(1)
" "$file" "$expr" 2>/dev/null || echo ""
}

# _py_json_type <json_file> <expr> → "str", "list", "dict", "NoneType", etc.
_py_json_type() {
  local file="$1" expr="$2"
  python3 -c "
import json, sys
try:
  d = json.load(open(sys.argv[1], encoding='utf-8'))
  parts = sys.argv[2].lstrip('.').replace('[', '.[').split('.')
  cur = d
  for p in parts:
    if not p: continue
    if p.startswith('[') and p.endswith(']'):
      cur = cur[int(p[1:-1])]
    else:
      cur = cur[p]
  print(type(cur).__name__)
except:
  sys.exit(1)
" "$file" "$expr" 2>/dev/null || echo "missing"
}

# _py_valid_json <file> → "yes" or "no"
_py_valid_json() {
  local file="$1"
  python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8')); print('yes')" "$file" 2>/dev/null || echo "no"
}

# _py_has_key <json_file> <key> → "yes" or "no"
_py_has_key() {
  local file="$1" key="$2"
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
print('yes' if '$key' in d else 'no')
" "$file" 2>/dev/null || echo "no"
}

# _py_get <json_file> <key> → value string
_py_get() {
  local file="$1" key="$2"
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
v = d.get('$key', '')
if isinstance(v, str): print(v)
else: print(json.dumps(v, ensure_ascii=False))
" "$file" 2>/dev/null || echo ""
}

# _py_stdin_validate → validates stdin as JSON, returns "yes"/"no"
_py_stdin_valid() {
  python3 -c "import json,sys; json.load(sys.stdin); print('yes')" 2>/dev/null || echo "no"
}

# ============================================================
echo "=== Group 1: Structural (real plugin.json, Phase 5b) ==="
# ============================================================

# G5.1: plugin.json is valid JSON
PLUGIN_JSON="$PLUGIN_ROOT/.codex-plugin/plugin.json"
if [ -f "$PLUGIN_JSON" ]; then
  VALID="$(_py_valid_json "$PLUGIN_JSON")"
  assert_eq "G5.1 plugin.json exists and is valid JSON" "yes" "$VALID"

  # G5.1a: plugin.json has real name field (not UNSUPPORTED marker)
  PLUGIN_NAME="$(_py_get "$PLUGIN_JSON" "name")"
  assert_eq "G5.1a plugin.json has name=harness-companion" "harness-companion" "$PLUGIN_NAME"

  # G5.1b: plugin.json has real version (semver, including prerelease/build)
  # Per semver.org: MAJOR.MINOR.PATCH(-PRERELEASE)?(+BUILD)?
  PLUGIN_VER="$(_py_get "$PLUGIN_JSON" "version")"
  if echo "$PLUGIN_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
    assert_pass "G5.1b plugin.json version is semver ($PLUGIN_VER)"
  else
    assert_fail "G5.1b plugin.json version is semver" "got=$PLUGIN_VER"
  fi

  # G5.1c: plugin.json has author object with name
  AUTHOR_NAME="$(_py_json "$PLUGIN_JSON" ".author.name")"
  if [ -n "$AUTHOR_NAME" ]; then
    assert_pass "G5.1c plugin.json author.name present ($AUTHOR_NAME)"
  else
    assert_fail "G5.1c plugin.json author.name present"
  fi

  # G5.1d: plugin.json has interface with required fields
  for field in displayName shortDescription longDescription developerName category; do
    VAL="$(_py_json "$PLUGIN_JSON" ".interface.$field")"
    if [ -n "$VAL" ]; then
      assert_pass "G5.1d plugin.json interface.$field present"
    else
      assert_fail "G5.1d plugin.json interface.$field present" "empty"
    fi
  done

  # G5.1e: plugin.json has capabilities array
  CAP_TYPE="$(_py_json_type "$PLUGIN_JSON" ".interface.capabilities")"
  assert_eq "G5.1e plugin.json interface.capabilities is array" "list" "$CAP_TYPE"

  # G5.1f: plugin.json has defaultPrompt (must be string array per Codex spec)
  DP_TYPE="$(_py_json_type "$PLUGIN_JSON" ".interface.defaultPrompt")"
  if [ "$DP_TYPE" = "list" ]; then
    assert_pass "G5.1f plugin.json interface.defaultPrompt is string array"
  else
    assert_fail "G5.1f plugin.json interface.defaultPrompt is string array" "type=$DP_TYPE"
  fi

  # G5.1g: plugin.json does NOT have UNSUPPORTED status field (it's real)
  HAS_STATUS="$(_py_has_key "$PLUGIN_JSON" "status")"
  assert_eq "G5.1g plugin.json has NO status=UNSUPPORTED (real manifest)" "no" "$HAS_STATUS"

  # G5.1h: plugin.json does NOT have superseded_by (was UNSUPPORTED marker)
  HAS_SUPERSEDED="$(_py_has_key "$PLUGIN_JSON" "superseded_by")"
  assert_eq "G5.1h plugin.json has NO superseded_by (UNSUPPORTED revoked)" "no" "$HAS_SUPERSEDED"

  # G5.2: plugin.json passes validate_plugin.py (if available)
  VALIDATOR="$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py"
  if [ -f "$VALIDATOR" ]; then
    if python3 "$VALIDATOR" "$PLUGIN_ROOT" 2>&1; then
      assert_pass "G5.2 plugin.json passes validate_plugin.py"
    else
      assert_fail "G5.2 plugin.json passes validate_plugin.py" "validator rejected"
    fi
  else
    assert_pass "G5.2 plugin.json passes validate_plugin.py [validator not found — skipping]"
  fi
else
  assert_fail "G5.1 plugin.json exists" "missing: $PLUGIN_JSON"
fi

# G5.5: hooks/hooks.json valid JSON
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
if [ -f "$HOOKS_JSON" ]; then
  VALID="$(_py_valid_json "$HOOKS_JSON")"
  assert_eq "G5.5 hooks.json is valid JSON" "yes" "$VALID"

  # G5.5a: hooks.json does NOT have UNSUPPORTED status field
  HAS_STATUS="$(_py_has_key "$HOOKS_JSON" "status")"
  assert_eq "G5.5a hooks.json has NO UNSUPPORTED status field" "no" "$HAS_STATUS"

  # G5.6: top-level "hooks" key is object
  HOOKS_TYPE="$(_py_json_type "$HOOKS_JSON" ".hooks")"
  assert_eq "G5.6 hooks.json has 'hooks' top-level object" "dict" "$HOOKS_TYPE"

  # G5.7: event subkeys are SessionStart, Stop, PreToolUse
  for ev in SessionStart Stop PreToolUse; do
    EV_TYPE="$(_py_json_type "$HOOKS_JSON" ".hooks.$ev")"
    if [ "$EV_TYPE" = "list" ]; then
      assert_pass "G5.7 hooks.json declares event '$ev'"
    else
      assert_fail "G5.7 hooks.json declares event '$ev'" "type=$EV_TYPE"
    fi
  done

  # G5.8: each event has [{hooks:[{type,command,timeout}]}]
  for ev in SessionStart Stop PreToolUse; do
    INNER_TYPE="$(_py_json_type "$HOOKS_JSON" ".hooks.${ev}[0].hooks[0]")"
    assert_eq "G5.8 $ev has hooks entry" "dict" "$INNER_TYPE"
  done

  # G5.11: timeout is in SECONDS (Codex official unit), constraint 0 < timeout <= 30
  for ev in SessionStart Stop PreToolUse; do
    TIMEOUT="$(_py_json "$HOOKS_JSON" ".hooks.${ev}[0].hooks[0].timeout")"
    T_NUM="$(echo "$TIMEOUT" | tr -d ' ')"
    if echo "$T_NUM" | grep -qE '^[0-9]+$'; then
      if [ "$T_NUM" -gt 0 ] 2>/dev/null && [ "$T_NUM" -le 30 ] 2>/dev/null; then
        assert_pass "G5.11 $ev timeout=$T_NUM seconds (in range 1..30)"
      elif [ "$T_NUM" -le 0 ] 2>/dev/null; then
        assert_fail "G5.11 $ev timeout=$T_NUM seconds (MUST be > 0)"
      else
        assert_fail "G5.11 $ev timeout=$T_NUM seconds (MUST be <= 30)"
      fi
    else
      assert_fail "G5.11 $ev timeout is not a valid integer" "got=$T_NUM"
    fi
  done

  # G5.15: hooks.json commands contain ${PLUGIN_ROOT} (plugin-mode variable)
  for ev in SessionStart Stop PreToolUse; do
    CMD="$(_py_json "$HOOKS_JSON" ".hooks.${ev}[0].hooks[0].command")"
    if echo "$CMD" | grep -qF '${PLUGIN_ROOT}'; then
      assert_pass "G5.15 $ev command uses PLUGIN_ROOT env var"
    else
      assert_fail "G5.15 $ev command uses PLUGIN_ROOT env var" "cmd=$CMD"
    fi
  done
else
  assert_fail "G5.5 hooks.json exists" "missing: $HOOKS_JSON"
fi

# G5.12: .codex-plugin/skills/SKILL.md exists with YAML frontmatter
SKILL_MD="$PLUGIN_ROOT/.codex-plugin/skills/SKILL.md"
if [ -f "$SKILL_MD" ]; then
  if head -1 "$SKILL_MD" | grep -q '^---$'; then
    assert_pass "G5.12 SKILL.md has YAML frontmatter"
  else
    assert_fail "G5.12 SKILL.md has YAML frontmatter"
  fi
  LINES="$(wc -l < "$SKILL_MD" | tr -d ' ')"
  if [ "$LINES" -gt 5 ]; then
    assert_pass "G5.12b SKILL.md is non-trivial ($LINES lines)"
  else
    assert_fail "G5.12b SKILL.md is non-trivial" "only $LINES lines"
  fi
else
  assert_fail "G5.12 SKILL.md exists" "missing: $SKILL_MD"
fi

# G5.13: adapter.conf present and parseable
ADAPTER_CONF="$ROOT_DIR/adapters/codex/adapter.conf"
if [ -f "$ADAPTER_CONF" ]; then
  grep -q '^name=codex$' "$ADAPTER_CONF" && assert_pass "G5.13 adapter.conf name=codex" \
    || assert_fail "G5.13 adapter.conf name=codex"
  grep -q '^knowledge_entry=AGENTS.md$' "$ADAPTER_CONF" && assert_pass "G5.13b adapter.conf knowledge_entry=AGENTS.md" \
    || assert_fail "G5.13b adapter.conf knowledge_entry=AGENTS.md"
  # G5.13a: adapter.conf declares status=supported (NOT unsupported)
  if grep -q '^status=supported$' "$ADAPTER_CONF"; then
    assert_pass "G5.13a adapter.conf declares status=supported (UNSUPPORTED revoked)"
  else
    assert_fail "G5.13a adapter.conf declares status=supported" "missing"
  fi
else
  assert_fail "G5.13 adapter.conf exists"
fi

# G5.14: each .cmd wrapper has @echo off + delegates to .sh
for cmd_file in session-start.cmd stop-handoff.cmd pre-tool-use.cmd; do
  f="$ROOT_DIR/adapters/codex/hooks/$cmd_file"
  if [ -f "$f" ]; then
    head -1 "$f" | grep -qiE '@echo off' && assert_pass "G5.14 $cmd_file has @echo off" \
      || assert_fail "G5.14 $cmd_file has @echo off"
    grep -qE "bash|_launcher" "$f" && assert_pass "G5.14b $cmd_file invokes bash (or _launcher)" \
      || assert_fail "G5.14b $cmd_file invokes bash (or _launcher)"
  else
    assert_fail "G5.14 $cmd_file exists"
  fi
done

# G5.10: .sh + .cmd pair for each hook
for ev in session-start stop-handoff pre-tool-use; do
  if [ -f "$ROOT_DIR/adapters/codex/hooks/${ev}.sh" ] \
     && [ -f "$ROOT_DIR/adapters/codex/hooks/${ev}.cmd" ]; then
    assert_pass "G5.10 ${ev}.sh + ${ev}.cmd both present"
  else
    assert_fail "G5.10 ${ev}.sh + ${ev}.cmd both present"
  fi
done

# ============================================================
echo ""
echo "=== Group 2: Hook behavior (real envelopes, Phase 5b) ==="
# ============================================================

# Helper: invoke a hook and capture stdout, stderr, rc
invoke_hook() {
  local hook="$1" stdin_data="$2"
  printf '%s' "$stdin_data" | bash "$hook" 2>/tmp/codex_ct_stderr.$$ 1>/tmp/codex_ct_stdout.$$
  local rc=$?
  cat /tmp/codex_ct_stdout.$$ /tmp/codex_ct_stderr.$$
  rm -f /tmp/codex_ct_stdout.$$ /tmp/codex_ct_stderr.$$
  return $rc
}

# Create a temp project with feature_list.json so hooks activate
TMP_PROJ="$(mktemp -d)"
cp "$ROOT_DIR/tests/adapters/fixtures/clean-project/feature_list.json" "$TMP_PROJ/"
if [ -d "$ROOT_DIR/tests/adapters/fixtures/clean-project/.harness" ]; then
  cp -r "$ROOT_DIR/tests/adapters/fixtures/clean-project/.harness" "$TMP_PROJ/"
fi

# Helper to extract JSON from hook stdout and validate envelope shape
# _check_envelope <stdout> <envelope_type>
#   envelope_type: "SessionStart" or "Stop" or "continue" or "pre_tool_use"
_check_envelope() {
  local stdout="$1" env_type="$2"
  local valid
  valid="$(printf '%s' "$stdout" | _py_stdin_valid)"
  if [ "$valid" != "yes" ]; then echo "INVALID_JSON"; return 1; fi
  case "$env_type" in
    SessionStart)
      printf '%s' "$stdout" | python3 -c "
import json, sys
d = json.load(sys.stdin)
hso = d.get('hookSpecificOutput', {})
print('OK' if hso.get('hookEventName') == 'SessionStart' and 'additionalContext' in hso else 'BAD:' + json.dumps(d)[:200])
" 2>/dev/null || echo "PARSE_ERROR"
      ;;
    Stop)
      printf '%s' "$stdout" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'systemMessage' in d: print('OK')
elif d.get('continue') == True: print('CONTINUE_ONLY')
else: print('BAD:' + json.dumps(d)[:200])
" 2>/dev/null || echo "PARSE_ERROR"
      ;;
    continue|pre_tool_use)
      printf '%s' "$stdout" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('OK' if d.get('continue') == True else 'BAD:' + json.dumps(d)[:200])
" 2>/dev/null || echo "PARSE_ERROR"
      ;;
  esac
}

# G5.16: session-start.sh with valid project → hookSpecificOutput.additionalContext
HOOK_SS="$ROOT_DIR/adapters/codex/hooks/session-start.sh"
STDIN_SS="{\"cwd\":\"$TMP_PROJ\"}"
STDOUT_SS="$(printf '%s' "$STDIN_SS" | bash "$HOOK_SS" 2>/dev/null)"
RC_SS=$?
if [ "$RC_SS" = "0" ]; then
  assert_pass "G5.16 session-start.sh with valid cwd → exit 0"
else
  assert_fail "G5.16 session-start.sh with valid cwd → exit 0" "rc=$RC_SS"
fi
ENV_CHECK="$(_check_envelope "$STDOUT_SS" "SessionStart")"
if [ "$ENV_CHECK" = "OK" ]; then
  assert_pass "G5.16b session-start.sh → SessionStart envelope (hookSpecificOutput.additionalContext)"
else
  assert_fail "G5.16b session-start.sh → SessionStart envelope" "got=$ENV_CHECK"
fi

# G5.17: stop-handoff.sh with valid project → systemMessage or continue
HOOK_STOP="$ROOT_DIR/adapters/codex/hooks/stop-handoff.sh"
STDIN_STOP="{\"cwd\":\"$TMP_PROJ\"}"
STDOUT_STOP="$(printf '%s' "$STDIN_STOP" | bash "$HOOK_STOP" 2>/dev/null)"
RC_STOP=$?
if [ "$RC_STOP" = "0" ]; then
  assert_pass "G5.17 stop-handoff.sh with valid cwd → exit 0"
else
  assert_fail "G5.17 stop-handoff.sh with valid cwd → exit 0" "rc=$RC_STOP"
fi
ENV_STOP="$(_check_envelope "$STDOUT_STOP" "Stop")"
if [ "$ENV_STOP" = "OK" ] || [ "$ENV_STOP" = "CONTINUE_ONLY" ]; then
  assert_pass "G5.17b stop-handoff.sh → Stop envelope ($ENV_STOP)"
else
  assert_fail "G5.17b stop-handoff.sh → Stop envelope" "got=$ENV_STOP"
fi

# G5.17c: stop-handoff.sh with WIP violation fixture → MUST emit systemMessage
# (not just continue). The clean-project fixture may legitimately emit
# `{"continue":true}` when there are no warnings -- but a project with
# dangling in_progress features MUST produce systemMessage so the user
# sees the warnings.
WIP_FIX="$ROOT_DIR/tests/adapters/fixtures/wip-violation"
if [ -d "$WIP_FIX" ]; then
  STDOUT_WIP="$(printf '{"cwd":"%s"}' "$WIP_FIX" | bash "$HOOK_STOP" 2>/dev/null)"
  ENV_WIP="$(_check_envelope "$STDOUT_WIP" "Stop")"
  # Strict: wip-violation fixture has 2 in_progress features => warnings MUST be present
  if [ "$ENV_WIP" = "OK" ]; then
    assert_pass "G5.17c stop-handoff.sh with WIP fixture → systemMessage (NOT continue-only)"
  else
    assert_fail "G5.17c stop-handoff.sh with WIP fixture → systemMessage" "got=$ENV_WIP"
  fi
else
  assert_pass "G5.17c stop-handoff.sh with WIP fixture [fixture missing — skipping]"
fi

# G5.17d: SessionStart with JSON containing Windows-path backslashes
# (must parse correctly via cross-platform parser, not substring scan)
HOOK_SS="$ROOT_DIR/adapters/codex/hooks/session-start.sh"
WIN_JSON='{"cwd":"C:\Users\foo\bar"}'
STDOUT_WIN="$(printf '%s' "$WIN_JSON" | bash "$HOOK_SS" 2>/dev/null)"
RC_WIN=$?
ENV_WIN="$(_check_envelope "$STDOUT_WIN" "continue")"
# We do NOT assert on output content (path does not exist on test machine),
# but we MUST assert that the hook does not crash on valid JSON with
# backslash escapes. If the parser fails to handle backslashes, the cwd
# extraction produces empty string, and the hook returns continue-only.
# That is fail-open behavior -- acceptable. The key property is: rc=0
# and valid JSON envelope, NO crash on backslashes.
if [ "$RC_WIN" = "0" ] && [ "$ENV_WIN" = "OK" ]; then
  assert_pass "G5.17d session-start.sh parses JSON with backslash escapes (no crash)"
else
  assert_fail "G5.17d session-start.sh parses JSON with backslash escapes" "rc=$RC_WIN env=$ENV_WIN"
fi

# G5.18: pre-tool-use.sh → exit 0, {"continue":true}, stderr has "policy not enabled"
HOOK_PTU="$ROOT_DIR/adapters/codex/hooks/pre-tool-use.sh"
STDIN_PTU="{\"cwd\":\"$TMP_PROJ\"}"
STDERR_PTU="$(printf '%s' "$STDIN_PTU" | bash "$HOOK_PTU" 2>/tmp/codex_ptu_e.$$ 1>/tmp/codex_ptu_o.$$; echo $? > /tmp/codex_ptu_r.$$)"
RC_PTU="$(cat /tmp/codex_ptu_r.$$)"
STDOUT_PTU="$(cat /tmp/codex_ptu_o.$$)"
STDERR_PTU_C="$(cat /tmp/codex_ptu_e.$$)"
rm -f /tmp/codex_ptu_o.$$ /tmp/codex_ptu_e.$$ /tmp/codex_ptu_r.$$

if [ "$RC_PTU" = "0" ]; then
  assert_pass "G5.18 pre-tool-use.sh → exit 0"
else
  assert_fail "G5.18 pre-tool-use.sh → exit 0" "rc=$RC_PTU"
fi
ENV_PTU="$(_check_envelope "$STDOUT_PTU" "pre_tool_use")"
if [ "$ENV_PTU" = "OK" ]; then
  assert_pass "G5.18b pre-tool-use.sh → {\"continue\":true}"
else
  assert_fail "G5.18b pre-tool-use.sh → {\"continue\":true}" "got=$ENV_PTU"
fi
if echo "$STDERR_PTU_C" | grep -qi 'policy not enabled'; then
  assert_pass "G5.18c pre-tool-use.sh stderr: 'policy not enabled' (NOT protocol-absent)"
else
  assert_fail "G5.18c pre-tool-use.sh stderr: 'policy not enabled'" "got=$STDERR_PTU_C"
fi

# G5.19: fail-open — empty stdin → {"continue":true} exit 0
for ev in session-start stop-handoff pre-tool-use; do
  HOOK="$ROOT_DIR/adapters/codex/hooks/${ev}.sh"
  STDOUT="$(printf '%s' "" | bash "$HOOK" 2>/dev/null)"
  RC=$?
  ENV="$(_check_envelope "$STDOUT" "continue")"
  if [ "$RC" = "0" ] && [ "$ENV" = "OK" ]; then
    assert_pass "G5.19 ${ev}.sh empty stdin → {\"continue\":true} exit 0"
  else
    assert_fail "G5.19 ${ev}.sh empty stdin → {\"continue\":true} exit 0" "rc=$RC env=$ENV"
  fi
done

# G5.20: fail-open — malformed JSON → {"continue":true} exit 0
for ev in session-start stop-handoff pre-tool-use; do
  HOOK="$ROOT_DIR/adapters/codex/hooks/${ev}.sh"
  STDOUT="$(printf '%s' "{not valid" | bash "$HOOK" 2>/dev/null)"
  RC=$?
  ENV="$(_check_envelope "$STDOUT" "continue")"
  if [ "$RC" = "0" ] && [ "$ENV" = "OK" ]; then
    assert_pass "G5.20 ${ev}.sh malformed JSON → {\"continue\":true} exit 0"
  else
    assert_fail "G5.20 ${ev}.sh malformed JSON → {\"continue\":true} exit 0" "rc=$RC env=$ENV"
  fi
done

# G5.21: fail-open — nonexistent cwd → {"continue":true} exit 0
for ev in session-start stop-handoff pre-tool-use; do
  HOOK="$ROOT_DIR/adapters/codex/hooks/${ev}.sh"
  STDOUT="$(printf '%s' '{"cwd":"/does/not/exist/deadbeef"}' | bash "$HOOK" 2>/dev/null)"
  RC=$?
  ENV="$(_check_envelope "$STDOUT" "continue")"
  if [ "$RC" = "0" ] && [ "$ENV" = "OK" ]; then
    assert_pass "G5.21 ${ev}.sh nonexistent cwd → {\"continue\":true} exit 0"
  else
    assert_fail "G5.21 ${ev}.sh nonexistent cwd → {\"continue\":true} exit 0" "rc=$RC env=$ENV"
  fi
done

# G5.22: pre-tool-use.sh works without feature_list.json (fires per tool call)
HOOK="$ROOT_DIR/adapters/codex/hooks/pre-tool-use.sh"
TMP_NOFL="$(mktemp -d)"
STDOUT="$(printf '%s' "{\"cwd\":\"$TMP_NOFL\"}" | bash "$HOOK" 2>/tmp/codex_g22_e.$$)"
RC=$?
STDERR="$(cat /tmp/codex_g22_e.$$)"
rm -f /tmp/codex_g22_e.$$
ENV="$(_check_envelope "$STDOUT" "pre_tool_use")"
if [ "$RC" = "0" ] && [ "$ENV" = "OK" ] && echo "$STDERR" | grep -qi 'policy not enabled'; then
  assert_pass "G5.22 pre-tool-use.sh works without feature_list.json (permissive)"
else
  assert_fail "G5.22 pre-tool-use.sh works without feature_list.json" "rc=$RC env=$ENV stderr=$STDERR"
fi
rm -rf "$TMP_NOFL" 2>/dev/null || true

# G5.23: hooks do NOT emit "UNSUPPORTED" to stderr (protocol IS supported)
for ev in session-start stop-handoff pre-tool-use; do
  HOOK="$ROOT_DIR/adapters/codex/hooks/${ev}.sh"
  STDOUT="$(printf '%s' "" | bash "$HOOK" 2>/tmp/codex_g23_e.$$)"
  STDERR="$(cat /tmp/codex_g23_e.$$)"
  rm -f /tmp/codex_g23_e.$$
  if echo "$STDERR" | grep -qi 'UNSUPPORTED'; then
    assert_fail "G5.23 ${ev}.sh does NOT emit UNSUPPORTED on stderr" "still says UNSUPPORTED"
  else
    assert_pass "G5.23 ${ev}.sh does NOT emit UNSUPPORTED on stderr (UNSUPPORTED revoked)"
  fi
done

# Cleanup temp
rm -rf "$TMP_PROJ" 2>/dev/null || true

# ============================================================
echo ""
echo "=== Group 2.x: Real cmd.exe behavior (commandWindows, Phase 5b) ==="
# ============================================================

# These tests invoke the .cmd wrappers via real cmd.exe, verifying the
# Git Bash environment is properly initialized and hooks produce correct
# output — not just silently fail-open.

TMP_PROJ2="$(mktemp -d)"
cp "$ROOT_DIR/tests/adapters/fixtures/clean-project/feature_list.json" "$TMP_PROJ2/" 2>/dev/null || echo '{"features":[]}' > "$TMP_PROJ2/feature_list.json"

CMD_TEST_PY="$TEST_DIR/_cmd_test.py"
if [ -f "$CMD_TEST_PY" ]; then
  for hook_name in session-start stop-handoff pre-tool-use; do
    TMP_RESULTS="/tmp/codex_cmd_r.$$"
    python3 "$CMD_TEST_PY" "$hook_name" "$TMP_PROJ2" > "$TMP_RESULTS" 2>/dev/null
    while IFS='|' read -r status label detail; do
      [ -z "$status" ] && continue
      if [ "$status" = "PASS" ]; then
        assert_pass "$label"
      else
        assert_fail "$label" "$detail"
      fi
    done < "$TMP_RESULTS"
    rm -f "$TMP_RESULTS"
  done

  # Also run stop-handoff.cmd against the wip-violation fixture via cmd.exe.
  # This fixture has 2 in_progress features, so the hook MUST emit
  # systemMessage (not just {"continue":true}) -- proving that a real
  # cwd-parse + warning-render path produces a Codex envelope.
  WIP_FIX_CMD="$ROOT_DIR/tests/adapters/fixtures/wip-violation"
  if [ -d "$WIP_FIX_CMD" ]; then
    TMP_RESULTS="/tmp/codex_cmd_wip.$$"
    python3 "$CMD_TEST_PY" stop-handoff "$WIP_FIX_CMD" > "$TMP_RESULTS" 2>/dev/null
    while IFS='|' read -r status label detail; do
      [ -z "$status" ] && continue
      if [ "$status" = "PASS" ]; then
        assert_pass "[wip-fixture] $label"
      else
        assert_fail "[wip-fixture] $label" "$detail"
      fi
    done < "$TMP_RESULTS"
    rm -f "$TMP_RESULTS"
  fi
else
  assert_fail "G5.24 _cmd_test.py helper missing" "$CMD_TEST_PY"
fi

rm -rf "$TMP_PROJ2" 2>/dev/null || true

# ============================================================
echo ""
echo "=== Group 2.y: No-python3 environment (cross-platform encoder, Phase 5b) ==="
# ============================================================

# These tests invoke the .cmd wrappers via real cmd.exe with python3,
# python, and WindowsApps REMOVED from PATH. They prove the hook does NOT
# depend on any specific runtime -- the cross-platform encoder helper
# (python3 / python / py -3 / jq -Rs) finds an available encoder.
#
# The python3 test driver is itself not on PATH for the subprocess, so the
# hook cannot fall back to "the test runner's python". It must find jq or
# another encoder to produce a real Codex envelope.

TMP_PROJ3="$(mktemp -d)"
cp "$ROOT_DIR/tests/adapters/fixtures/clean-project/feature_list.json" "$TMP_PROJ3/" 2>/dev/null || echo '{"features":[]}' > "$TMP_PROJ3/feature_list.json"

if [ -f "$CMD_TEST_PY" ]; then
  for hook_name in session-start stop-handoff pre-tool-use; do
    TMP_RESULTS="/tmp/codex_no_py_r.$$"
    python3 "$CMD_TEST_PY" "$hook_name" "$TMP_PROJ3" --no-python3 > "$TMP_RESULTS" 2>/dev/null
    while IFS='|' read -r status label detail; do
      [ -z "$status" ] && continue
      if [ "$status" = "PASS" ]; then
        assert_pass "[no-python3] $label"
      else
        assert_fail "[no-python3] $label" "$detail"
      fi
    done < "$TMP_RESULTS"
    rm -f "$TMP_RESULTS"
  done
else
  assert_fail "[no-python3] G5.50 _cmd_test.py helper missing" "$CMD_TEST_PY"
fi

rm -rf "$TMP_PROJ3" 2>/dev/null || true

# ============================================================
echo ""
echo "=== Group 2.z: Fake-python3 PATH (runtime probe correctness, Phase 5b) ==="
# ============================================================

# Simulates "py.exe exists on PATH but no Python is installed" by:
#   1. Stripping every directory containing python/python3/WindowsApps
#   2. Prepending a temp dir with stub python3/python/py/.cmd scripts
#      that print "No installed Python found!" and exit 9009
# The hook's runtime probe MUST detect that all three Python runtimes are
# unusable, fall through to jq or powershell, and still produce correct
# output -- proving the probe is a real execution test, not just a
# `command -v` existence check.

TMP_PROJ4="$(mktemp -d)"
cp "$ROOT_DIR/tests/adapters/fixtures/clean-project/feature_list.json" "$TMP_PROJ4/" 2>/dev/null || echo '{"features":[]}' > "$TMP_PROJ4/feature_list.json"
WIP_FIX_FAKE="$ROOT_DIR/tests/adapters/fixtures/wip-violation"

if [ -f "$CMD_TEST_PY" ]; then
  # 4a: All three hooks under fake-python3 against clean-project fixture.
  for hook_name in session-start stop-handoff pre-tool-use; do
    TMP_RESULTS="/tmp/codex_fake_py.$$"
    python3 "$CMD_TEST_PY" "$hook_name" "$TMP_PROJ4" --fake-python3 > "$TMP_RESULTS" 2>/dev/null
    while IFS='|' read -r status label detail; do
      [ -z "$status" ] && continue
      if [ "$status" = "PASS" ]; then
        assert_pass "[fake-python3] $label"
      else
        assert_fail "[fake-python3] $label" "$detail"
      fi
    done < "$TMP_RESULTS"
    rm -f "$TMP_RESULTS"
  done

  # 4b: stop-handoff.cmd against the wip-violation fixture under fake-python3.
  # This is the critical case: even when Python is "available" but broken,
  # the WIP fixture's warnings MUST reach the user via systemMessage
  # (proves the probe correctly skipped the fake py.exe and used jq/PS).
  if [ -d "$WIP_FIX_FAKE" ]; then
    TMP_RESULTS="/tmp/codex_fake_py_wip.$$"
    python3 "$CMD_TEST_PY" stop-handoff "$WIP_FIX_FAKE" --fake-python3 > "$TMP_RESULTS" 2>/dev/null
    while IFS='|' read -r status label detail; do
      [ -z "$status" ] && continue
      if [ "$status" = "PASS" ]; then
        assert_pass "[fake-python3+wip] $label"
      else
        assert_fail "[fake-python3+wip] $label" "$detail"
      fi
    done < "$TMP_RESULTS"
    rm -f "$TMP_RESULTS"
  fi
else
  assert_fail "[fake-python3] G5.55 _cmd_test.py helper missing" "$CMD_TEST_PY"
fi

rm -rf "$TMP_PROJ4" 2>/dev/null || true

# G5.56: verify the runtime probe itself does an execution test, not just
# command-exists. We source json-encode.sh and assert hc_json_encoder_available
# python3 returns false on a fake stub that exists but fails.
if [ -f "$CMD_TEST_PY" ]; then
  PROBE_OUT="$(mktemp)"
  HC_FAKE_DIR="$(mktemp -d)"
  if [ -n "$HC_FAKE_DIR" ]; then
    # Drop a fake python3 in HC_FAKE_DIR that fails
    cat > "$HC_FAKE_DIR/python3" <<'EOF'
#!/bin/sh
echo "No installed Python found!" >&2
exit 127
EOF
    chmod +x "$HC_FAKE_DIR/python3"
    # Invoke bash with HC_FAKE_DIR prepended to PATH, source the lib, run probe
    (cd /tmp && PATH="$HC_FAKE_DIR:$PATH" bash -c '
      source "'"$ROOT_DIR"'/core/lib/json-encode.sh" 2>/dev/null
      if hc_json_encoder_available python3; then
        echo "PROBE_FAIL: accepted fake python3"
        exit 1
      else
        echo "PROBE_OK: rejected fake python3"
        exit 0
      fi
    ') > "$PROBE_OUT" 2>&1
    if grep -q "PROBE_OK" "$PROBE_OUT"; then
      assert_pass "G5.56 runtime probe rejects fake python3 (no Python installed)"
    else
      assert_fail "G5.56 runtime probe rejects fake python3" "got=$(cat "$PROBE_OUT")"
    fi
    rm -rf "$HC_FAKE_DIR"
  fi
  rm -f "$PROBE_OUT"
fi

# ============================================================
echo ""
echo "=== Group 3: Adapter purity (business logic only in core) ==="
# ============================================================

FORBIDDEN_PATTERNS=(
  'select\(\.status=="passing"\)'
  'select\(\.status=="in_progress"\)'
  'required_for_passing'
  'is_eligible_for_passing'
  'hc_wip_limit'
  '\.evidence\.commit'
  'validate_run_log'
)

i=30
for pat in "${FORBIDDEN_PATTERNS[@]}"; do
  matches="$(grep -rEn "$pat" "$ROOT_DIR/adapters/codex/hooks/"*.sh 2>/dev/null || true)"
  if [ -z "$matches" ]; then
    assert_pass "G5.${i} adapter hooks/*.sh free of pattern: $pat"
  else
    assert_fail "G5.${i} adapter hooks/*.sh free of pattern: $pat" "found: $matches"
  fi
  i=$((i + 1))
done

# G5.37: workspace fingerprint computation absent from adapter
FP_MATCH="$(grep -rEn 'compute_workspace_fingerprint|workspace_fingerprint_initial' "$ROOT_DIR/adapters/codex/" 2>/dev/null || true)"
if [ -z "$FP_MATCH" ]; then
  assert_pass "G5.37 adapter has no workspace fingerprint computation"
else
  assert_fail "G5.37 adapter has no workspace fingerprint computation" "found: $FP_MATCH"
fi

# ============================================================
echo ""
echo "=== Group 4: Self-contained (python3 JSON, no jq dependency) ==="
# ============================================================

# G5.40: test file itself uses python3 for JSON, not jq as a JSON tool.
# Exclude self-check and comment lines from the search.
JQ_LINES="$(grep -n 'jq ' "$TEST_DIR/test-codex-contract.sh" 2>/dev/null | grep -v 'G5.40\|#.*jq\|assert.*jq\|grep.*jq\|echo.*jq\|no jq' || true)"
if [ -z "$JQ_LINES" ]; then
  assert_pass "G5.40 contract tests are jq-free (self-contained python3)"
else
  assert_fail "G5.40 contract tests are jq-free (self-contained python3)" "found jq: $JQ_LINES"
fi

# G5.41: python3 is available for test JSON parsing
if command -v python3 >/dev/null 2>&1; then
  assert_pass "G5.41 python3 available for test JSON parsing"
else
  assert_fail "G5.41 python3 available for test JSON parsing"
fi

# G5.42: install.sh has python3 fallback (not jq-only)
if grep -q 'command -v python3' "$ROOT_DIR/adapters/codex/install.sh"; then
  assert_pass "G5.42 install.sh has python3 fallback for JSON construction"
else
  assert_fail "G5.42 install.sh has python3 fallback for JSON construction"
fi

# G5.43: install.sh functional jq gate (echo '{}' | jq -e . check)
if grep -q "echo '{}' | jq -e" "$ROOT_DIR/adapters/codex/install.sh"; then
  assert_pass "G5.43 install.sh has functional jq gate (not just PATH check)"
else
  assert_fail "G5.43 install.sh has functional jq gate (not just PATH check)"
fi

# ============================================================
echo ""
echo "=== Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then exit 1; fi
exit 0
