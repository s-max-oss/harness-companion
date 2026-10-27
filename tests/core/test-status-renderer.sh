#!/bin/bash
# test-status-renderer.sh — handoff/status rendering and evidence blocks
#
# These cases used to live in the Claude Code adapter contract suite (G10).
# With the host adapters retired they now exercise core/lib/status-renderer.sh
# directly, so the v2 evidence semantics keep their coverage without a host in
# the loop.
#
# Fixtures are built at runtime in a temp directory instead of being committed:
# the canonical NDJSON run logs record absolute artifact paths, so a committed
# fixture breaks as soon as the repository moves (the retired adapter suite had
# a regeneration script for exactly that reason).
#
# Requires: bash, jq, GNU timeout (harness-verify.sh prerequisites).

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/json-helpers.sh
source "$CORE_LIB/json-helpers.sh"
# shellcheck source=../../core/lib/baseline.sh
source "$CORE_LIB/baseline.sh"
# shellcheck source=../../core/lib/status-renderer.sh
source "$CORE_LIB/status-renderer.sh"

export HC_HANDOFF_BUDGET_SEC=0

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
no() {
  FAIL=$((FAIL + 1))
  printf '  [FAIL] %s\n' "$1"
  [ -n "${2:-}" ] && printf '         %s\n' "$2"
  return 0
}
has() { case "$1" in *"$2"*) ok "$3" ;; *) no "$3" "missing: $2" ;; esac; }
hasnt() { case "$1" in *"$2"*) no "$3" "unexpected: $2" ;; *) ok "$3" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc-render-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

CONFIG='{"project_type":"generic","verification":{"commands":[{"id":"echo","command":["bash","-c","echo ok"],"command_origin":"configured","confirmation":"not_required","required_for_passing":true,"timeout_seconds":60}]}}'

# make_project <dir> <feature-json>
make_project() {
  local dir="$1" features="$2"
  mkdir -p "$dir/.harness"
  printf '# %s\n' "$(basename "$dir")" > "$dir/AGENTS.md"
  printf '%s' "$CONFIG" > "$dir/.harness/config.json"
  printf '{"version":"2","schema_version":"2.0.0","revision":1,"features":[%s]}' "$features" \
    > "$dir/feature_list.json"
}

# verified_project <dir> <feature-id>: run the real verification chain and mark
# the feature passing, producing a canonical NDJSON log + association.
verified_project() {
  local dir="$1" fid="$2"
  make_project "$dir" "{\"id\":\"$fid\",\"title\":\"renderer case\",\"status\":\"not_started\",\"evidence_associations\":[],\"legacy_audit_evidence\":[]}"
  bash "$ROOT_DIR/core/harness-feature.sh" status "$dir" "$fid" in_progress >/dev/null 2>&1
  bash "$ROOT_DIR/core/harness-verify.sh" "$fid" "$dir" --write >/dev/null 2>&1
  bash "$ROOT_DIR/core/harness-feature.sh" status "$dir" "$fid" passing >/dev/null 2>&1
}

echo "=== status renderer ==="

# ---- clean project: verified evidence, no issues ------------------------------
CLEAN="$WORK/clean-project"
verified_project "$CLEAN" "F-CLEAN-01"
STATUS="$(sr_status_text "$CLEAN")"
OUT="$(sr_handoff_warnings "$CLEAN")"

has "$STATUS" "## Harness Status - clean-project" "status header names the project"
if [ "$(printf '%s\n' "$STATUS" | sed -n '2p')" = "" ]; then
  ok "status header is followed by a blank line"
else
  no "status header is followed by a blank line" "blocks were joined without a separator"
fi
if printf '%s\n' "$STATUS" | sed -n '3p' | grep -q '^- \[OK\]'; then
  ok "status detail lines start on their own line"
else
  no "status detail lines start on their own line"
fi

hasnt "$OUT" "run-log issues" "clean project emits no run-log issue block"
hasnt "$OUT" "no canonical evidence_associations" "clean project emits no no-association block"
hasnt "$OUT" "run_log_missing" "clean project does not report missing logs"

case "$OUT" in
  *$'\r'*) no "handoff output contains no CR" "CR found (jq/MSYS CRLF leak)" ;;
  *) ok "handoff output contains no CR" ;;
esac
case "$OUT" in
  *"user.[!!]"*) no "warning blocks are newline-separated" "blocks were concatenated" ;;
  *) ok "warning blocks are newline-separated" ;;
esac

# ---- missing run log ----------------------------------------------------------
MISSING="$WORK/missing-log"
make_project "$MISSING" '{"id":"F-MISS-01","title":"missing log","status":"passing","evidence_associations":[{"run_id":"19990101T000000Z-1-1"}],"legacy_audit_evidence":[]}'
OUT="$(sr_handoff_warnings "$MISSING")"
has "$OUT" "run_log_missing" "non-existent run_id reports run_log_missing"
has "$OUT" "F-MISS-01" "missing-log message names the feature"

# ---- corrupted run log --------------------------------------------------------
CORRUPT="$WORK/corrupt-log"
make_project "$CORRUPT" '{"id":"F-CORRUPT-01","title":"corrupt log","status":"passing","evidence_associations":[{"run_id":"19990101T000000Z-2-2"}],"legacy_audit_evidence":[]}'
mkdir -p "$CORRUPT/.harness/logs/runs"
printf 'not-json\n' > "$CORRUPT/.harness/logs/runs/19990101T000000Z-2-2.ndjson"
OUT="$(sr_handoff_warnings "$CORRUPT")"
has "$OUT" "run_log_invalid" "corrupted NDJSON reports run_log_invalid"
has "$OUT" "F-CORRUPT-01" "invalid-log message names the feature"

# ---- stale run (workspace changed after verification) ------------------------
STALE="$WORK/stale-run"
verified_project "$STALE" "F-STALE-01"
printf 'changed after verification\n' >> "$STALE/AGENTS.md"
OUT="$(sr_handoff_warnings "$STALE")"
has "$OUT" "stale_by_fingerprint" "stale run reports stale_by_fingerprint"
has "$OUT" "F-STALE-01" "stale message names the feature"

# ---- passing without associations --------------------------------------------
NOASSOC="$WORK/no-association"
make_project "$NOASSOC" '{"id":"F-NOASSC-01","title":"no association","status":"passing","evidence_associations":[],"legacy_audit_evidence":[]}'
OUT="$(sr_handoff_warnings "$NOASSOC")"
has "$OUT" "no canonical evidence_associations" "passing without associations is reported"
has "$OUT" "F-NOASSC-01" "association message names the feature"

# ---- dangling in_progress -----------------------------------------------------
WIP="$WORK/wip-violation"
make_project "$WIP" '{"id":"F-WIP-01","title":"dangling","status":"in_progress","evidence_associations":[],"legacy_audit_evidence":[]}'
OUT="$(sr_handoff_warnings "$WIP")"
has "$OUT" "Features still in_progress" "dangling in_progress features are reported"

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
