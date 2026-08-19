#!/bin/bash
# tests/release/test-acceptance-package.sh
#
# Validate the schema of the CURRENT-HEAD acceptance package and verify
# that all bound SHA-256 fields match the on-disk bytes. The test is
# FAIL-CLOSED: it must find a package at .harness/acceptance/<current_HEAD>/,
# and any old package at a different HEAD is irrelevant.
#
# This is a unit test for the acceptance package shape — it does NOT
# generate the package (that requires the canonical full-suite run, which
# the generator drives).
#
# Schema invariants:
#   schema_version       integer >= 1
#   head_oid             40-hex AND equals current git HEAD
#   run_id               matches ^[0-9TZ]+-[0-9]+-[0-9]+$ AND equals the
#                        run_id of the canonical NDJSON's run_started event
#   duration_ms          integer > 0
#   effective_timeout    integer >= 1
#   config_sha256        sha256:<64hex> AND matches current .harness/config.json
#   canonical_ndjson     { path, sha256 } where sha256 == sha256(<path>)
#                        AND file tail is run_completed with overall_result=passed
#                        (the current harness-verify emits run_completed; the
#                        legacy run_passed name is also accepted)
#   full_suite_log       { path, sha256 } where sha256 == sha256(<path>)
#   maintenance_verdict  { path, sha256 } where sha256 == sha256(<path>)
#   reviewer_verdict     { path, sha256 } where sha256 == sha256(<path>)
#                        AND freshest line has head_sha == HEAD_OID
#   a_g_log              { path, sha256 } where sha256 == sha256(<path>)
#   migration_record     { path, sha256 } where sha256 == sha256(<path>)
#   generated_at         ISO-8601 UTC Z
#
# If no package exists at .harness/acceptance/<current_HEAD>/, the test
# FAILS (does not skip). The rc6 final round must have a current-HEAD
# package; a missing package is a hard violation.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACCEPT_BASE="$ROOT_DIR/.harness/acceptance"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ---- Locate the package for the CURRENT HEAD ----
CURRENT_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)" || {
  fail "cannot determine current HEAD (not a git repo?)"
  echo "=== Acceptance Package Test Results: $PASS passed, $FAIL failed ==="
  exit 1
}

pkg="$ACCEPT_BASE/$CURRENT_HEAD"
if [ ! -d "$pkg" ]; then
  fail "no acceptance package at \$ACCEPT_BASE/\$CURRENT_HEAD: $pkg"
  echo "  (any old package at a different HEAD is irrelevant — only the current HEAD's package counts)"
  echo "=== Acceptance Package Test Results: $PASS passed, $FAIL failed ==="
  exit 1
fi
acc_json="$pkg/acceptance.json"
ag_log="$pkg/A-G.log"

if [ ! -f "$acc_json" ]; then
  fail "missing acceptance.json at $pkg"
fi
if [ ! -f "$ag_log" ]; then
  fail "missing A-G.log at $pkg"
fi
# If acceptance.json or A-G.log missing, we cannot proceed with the rest of
# the schema checks; bail out early.
if [ ! -f "$acc_json" ] || [ ! -f "$ag_log" ]; then
  echo "=== Acceptance Package Test Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

# Helper: extract + assert.
field_assert() {
  local json="$1" jq_path="$2" pattern="$3" desc="$4"
  local val
  val="$(jq -r "$jq_path" "$json" 2>/dev/null)"
  if printf '%s' "$val" | grep -qE "$pattern"; then
    pass "$desc"
  else
    fail "$desc (got '$val', expected pattern /$pattern/)"
  fi
}

# Field-level asserts
if jq -e '(.schema_version | type) == "number" and .schema_version == 1' "$acc_json" >/dev/null 2>&1; then
  pass "schema_version is integer 1"
else
  fail "schema_version must be integer 1"
fi
field_assert "$acc_json" '.head_oid'         '^[0-9a-f]{40}$'            "head_oid 40-hex"
field_assert "$acc_json" '.run_id'           '^[0-9TZ]+-[0-9]+-[0-9]+$'   "run_id canonical format"
field_assert "$acc_json" '.config_sha256'    '^sha256:[0-9a-f]{64}$'      "config_sha256 sha256:<64hex>"

# HEAD must equal current HEAD
HEAD_OID_RECORDED="$(jq -r '.head_oid' "$acc_json")"
if [ "$HEAD_OID_RECORDED" = "$CURRENT_HEAD" ]; then
  pass "head_oid matches current git HEAD"
else
  fail "head_oid does not match current HEAD (recorded=$HEAD_OID_RECORDED current=$CURRENT_HEAD)"
fi

# config_sha256 must match the actual on-disk config.json
ACTUAL_CONFIG_SHA="$(sha256sum "$ROOT_DIR/.harness/config.json" 2>/dev/null | awk '{print $1}')"
RECORDED_CONFIG_SHA="${HEAD_OID_RECORDED_CONFIG_SHA:-}"  # placeholder to avoid unbound
RECORDED_CONFIG_SHA="$(jq -r '.config_sha256' "$acc_json" | sed 's/^sha256://')"
if [ "$ACTUAL_CONFIG_SHA" = "$RECORDED_CONFIG_SHA" ]; then
  pass "config_sha256 matches current .harness/config.json"
else
  fail "config_sha256 mismatch (recorded=$RECORDED_CONFIG_SHA actual=$ACTUAL_CONFIG_SHA)"
fi

# Integer fields: jq -r returns null for non-numeric; filter out and re-check.
if jq -e '.duration_ms | type == "number" and floor == . and . > 0' "$acc_json" >/dev/null 2>&1; then
  pass "duration_ms is a positive integer"
else
  fail "duration_ms must be a positive integer"
fi
if jq -e '.effective_timeout | type == "number" and floor == . and . >= 1' "$acc_json" >/dev/null 2>&1; then
  pass "effective_timeout is an integer >= 1"
else
  fail "effective_timeout must be an integer >= 1"
fi

# Bound SHA-256 fields must match on-disk bytes.
for entry in canonical_ndjson full_suite_log maintenance_verdict reviewer_verdict a_g_log migration_record; do
  p="$(jq -r --arg k "$entry" '.[$k].path' "$acc_json")"
  s_recorded="$(jq -r --arg k "$entry" '.[$k].sha256' "$acc_json")"
  if [ -z "$p" ] || [ "$p" = "null" ]; then
    fail "$entry.path missing"
    continue
  fi
  if [ ! -f "$p" ]; then
    fail "$entry.path does not exist: $p"
    continue
  fi
  s_actual="$(sha256sum "$p" | awk '{print $1}')"
  if [ "$s_recorded" = "$s_actual" ]; then
    pass "$entry sha256 matches on-disk bytes"
  else
    fail "$entry sha256 mismatch (recorded=$s_recorded actual=$s_actual)"
  fi
done

# ---- Canonical NDJSON must be a successful run ----
NDJSON_PATH="$(jq -r '.canonical_ndjson.path' "$acc_json")"
if [ -f "$NDJSON_PATH" ]; then
  RUN_ID_RECORDED="$(jq -r '.run_id' "$acc_json")"
  EXPECTED_NDJSON="$ROOT_DIR/.harness/logs/runs/$RUN_ID_RECORDED.ndjson"
  if [ "$NDJSON_PATH" = "$EXPECTED_NDJSON" ] && [ ! -L "$NDJSON_PATH" ]; then
    pass "canonical NDJSON path is authoritative for run_id"
  else
    fail "canonical NDJSON path is not authoritative (got=$NDJSON_PATH expected=$EXPECTED_NDJSON)"
  fi
  # Use the production validator, then require the exact immutable canonical
  # command rather than accepting any passing terminal.
  # shellcheck source=../../core/lib/validate-run-log.sh
  . "$ROOT_DIR/core/lib/validate-run-log.sh"
  VALIDATION="$(validate_run_log "$RUN_ID_RECORDED" "$ROOT_DIR" 2>/dev/null)" || VALIDATION='{"valid":false}'
  if printf '%s' "$VALIDATION" | jq -e '.valid == true' >/dev/null 2>&1; then
    pass "canonical NDJSON passes validate_run_log"
  else
    fail "canonical NDJSON fails validate_run_log"
  fi
  CMD_COUNT="$(grep -cE '"event":"command_completed"' "$NDJSON_PATH" || true)"
  CMD_JSON="$(grep -E '"event":"command_completed"' "$NDJSON_PATH" | tail -1 | jq -c '.command')"
  CMD_ID="$(grep -E '"event":"command_completed"' "$NDJSON_PATH" | tail -1 | jq -r '.command_id // empty')"
  if [ "$CMD_COUNT" = "1" ] && [ "$CMD_ID" = "full-suite" ] && [ "$CMD_JSON" = '["bash","tests/run-all.sh"]' ]; then
    pass "canonical command is exact bash tests/run-all.sh"
  else
    fail "canonical command mismatch/count (count=$CMD_COUNT id=$CMD_ID argv=$CMD_JSON)"
  fi
  if grep -q "\"run_id\":\"$RUN_ID_RECORDED\"" "$NDJSON_PATH" 2>/dev/null; then
    pass "RUN_ID found in canonical NDJSON"
  else
    fail "RUN_ID $RUN_ID_RECORDED not found in canonical NDJSON"
  fi
  FINAL_EVENT="$(grep -E '"event":"run_(passed|completed|failed)"' "$NDJSON_PATH" | tail -1)"
  if [ -n "$FINAL_EVENT" ]; then
    FINAL_KIND="$(printf '%s' "$FINAL_EVENT" | jq -r '.event // empty')"
    FINAL_OVERALL="$(printf '%s' "$FINAL_EVENT" | jq -r '.overall_result // empty')"
    FINAL_FAILED="$(printf '%s' "$FINAL_EVENT" | jq -r '.failed_commands // 1')"
    PASS_OK=0
    if [ "$FINAL_KIND" = "run_completed" ] && [ "$FINAL_OVERALL" = "passed" ] && [ "$FINAL_FAILED" = "0" ]; then
      PASS_OK=1
    elif [ "$FINAL_KIND" = "run_passed" ] && [ "$FINAL_OVERALL" = "passed" ] && [ "$FINAL_FAILED" = "0" ]; then
      PASS_OK=1
    fi
    if [ "$PASS_OK" = "1" ]; then
      pass "canonical NDJSON terminal is a passing terminal (kind=$FINAL_KIND) with 0 failed commands"
    else
      fail "canonical NDJSON terminal is not a passing terminal (kind=$FINAL_KIND overall=$FINAL_OVERALL failed=$FINAL_FAILED)"
    fi
  else
    fail "canonical NDJSON has no terminal run_completed/run_failed event"
  fi
fi

# ---- Reviewer verdict must be fresh and bind to HEAD ----
REVIEWER_PATH="$(jq -r '.reviewer_verdict.path' "$acc_json")"
if [ -f "$REVIEWER_PATH" ]; then
  LAST_VR="$(tail -1 "$REVIEWER_PATH")"
  VR_HEAD="$(printf '%s' "$LAST_VR" | jq -r '.head_sha // empty')"
  VR_VERDICT="$(printf '%s' "$LAST_VR" | jq -r '.verdict // empty')"
  VR_RUN="$(printf '%s' "$LAST_VR" | jq -r '.run_id // empty')"
  if [ "$VR_HEAD" = "$CURRENT_HEAD" ]; then
    pass "fresh Reviewer verdict head_sha == current HEAD"
  else
    fail "fresh Reviewer verdict head_sha != current HEAD (verdict=$VR_HEAD current=$CURRENT_HEAD)"
  fi
  if [ "$VR_VERDICT" = "PASS" ]; then
    pass "fresh Reviewer verdict is PASS"
  else
    fail "fresh Reviewer verdict is not PASS (got $VR_VERDICT)"
  fi
  RUN_ID_RECORDED="$(jq -r '.run_id' "$acc_json")"
  if [ "$VR_RUN" = "$RUN_ID_RECORDED" ]; then
    pass "fresh Reviewer verdict run_id matches canonical RUN_ID"
  else
    fail "fresh Reviewer verdict run_id != RUN_ID (verdict=$VR_RUN recorded=$RUN_ID_RECORDED)"
  fi
fi

echo "=== Acceptance Package Test Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
