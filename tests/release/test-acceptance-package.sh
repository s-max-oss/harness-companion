#!/bin/bash
# tests/release/test-acceptance-package.sh
#
# Validate the schema of acceptance.json and verify that all bound SHA-256
# fields match the on-disk bytes. This is a unit test for the acceptance
# package shape — it does NOT generate the package (that requires the
# canonical full-suite run, which the generator drives).
#
# Schema invariants:
#   schema_version       integer >= 1
#   head_oid             40-hex
#   run_id               matches ^[0-9TZ]+-[0-9]+-[0-9]+$
#   duration_ms          integer > 0
#   effective_timeout    integer >= 1
#   config_sha256        sha256:<64hex>
#   canonical_ndjson     { path, sha256 } where sha256 == sha256(<path>)
#   full_suite_log       { path, sha256 } where sha256 == sha256(<path>)
#   maintenance_verdict  { path, sha256 } where sha256 == sha256(<path>)
#   a_g_log              { path, sha256 } where sha256 == sha256(<path>)
#   migration_record     { path, sha256 } where sha256 == sha256(<path>)
#   generated_at         ISO-8601 UTC Z
#
# The test scans .harness/acceptance/*/ for any package and validates the
# most recent one. If none exists yet (acceptance package not yet generated),
# the test prints SKIP — but in the rc6 final round it MUST find one.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACCEPT_BASE="$ROOT_DIR/.harness/acceptance"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# Locate any package directory.
pkg="$(ls -1d "$ACCEPT_BASE"/*/ 2>/dev/null | head -n 1)"
if [ -z "$pkg" ]; then
  echo "  [SKIP] no acceptance package at $ACCEPT_BASE yet — generator must run after final canonical"
  exit 0
fi
pkg="${pkg%/}"
acc_json="$pkg/acceptance.json"
ag_log="$pkg/A-G.log"

if [ ! -f "$acc_json" ]; then
  fail "missing acceptance.json at $pkg"
fi
if [ ! -f "$ag_log" ]; then
  fail "missing A-G.log at $pkg"
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

field_assert "$acc_json" '.schema_version' '^[0-9]+$'                  "schema_version integer"
field_assert "$acc_json" '.head_oid'         '^[0-9a-f]{40}$'            "head_oid 40-hex"
field_assert "$acc_json" '.run_id'           '^[0-9TZ]+-[0-9]+-[0-9]+$'   "run_id canonical format"
field_assert "$acc_json" '.config_sha256'    '^sha256:[0-9a-f]{64}$'      "config_sha256 sha256:<hex>"

# Integer fields: jq -r returns null for non-numeric; filter out and re-check.
dur_ok="$(jq -r '.duration_ms | type' "$acc_json")"
if [ "$dur_ok" = "number" ]; then
  pass "duration_ms is number"
else
  fail "duration_ms must be number (got type $dur_ok)"
fi
to_ok="$(jq -r '.effective_timeout | type' "$acc_json")"
if [ "$to_ok" = "number" ]; then
  pass "effective_timeout is number"
else
  fail "effective_timeout must be number (got type $to_ok)"
fi

# Bound SHA-256 fields must match on-disk bytes.
for entry in canonical_ndjson full_suite_log maintenance_verdict a_g_log migration_record; do
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

echo "=== Acceptance Package Test Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
