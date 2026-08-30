#!/bin/bash
# F-CONV-07: prove the real executor selects and emits the correct typed files.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT="$ROOT/scripts/harness-init.sh"
FIXTURE="$ROOT/tests/init/fixtures/type-command-whitelist.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ — $2}"; }

check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

brief() {
  local path="$1" dtype="$2"
  jq -n --arg dtype "$dtype" '{
    schema_version: 1,
    detected_type: $dtype,
    goal: "Verify deterministic typed output",
    success_criteria: ["Generated files match the selected project type"],
    cadence: "stable",
    deadline: null,
    stack: $dtype,
    test_framework: "unspecified",
    secrets_handling: "unspecified",
    external_network: "ask",
    prohibitions: [],
    operation_preferences: {
      commit: "ask", push: "ask", merge: "ask", release: "ask",
      install_packages: "ask", external_mutation: "ask",
      destructive_ops: false
    },
    defaults_applied: [],
    conflicts_resolved: [],
    provenance: {},
    type_evidence: null
  }' > "$path"
}

contains_marker() {
  local file="$1" marker="$2"
  grep -qE -- "(^|[^[:alnum:]_])${marker}([^[:alnum:]_]|$)" "$file" 2>/dev/null
}

if ! jq -e '
  .schema_version == 1
  and (.types | type == "array" and length == 7)
  and ([.types[].detected_type] | sort == (["docs","electron","go","node","python","rust","shell"] | sort))
  and all(.types[];
    (.detected_type | type == "string")
    and (.project_type | IN("node","python","rust","go","docs","generic"))
    and (.required | type == "array")
    and (.forbidden | type == "array"))
' "$FIXTURE" >/dev/null; then
  fail "type-command whitelist fixture is valid"
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi
pass "type-command whitelist fixture is valid"

while IFS= read -r row; do
  dtype="$(printf '%s' "$row" | jq -r '.detected_type')"
  expected_project_type="$(printf '%s' "$row" | jq -r '.project_type')"
  target="$TMP/$dtype"
  brief_path="$TMP/$dtype-brief.json"
  mkdir -p "$target"
  brief "$brief_path" "$dtype"

  if output="$(bash "$INIT" "$target" --brief "$brief_path" --non-interactive --host=claude 2>&1)"; then
    pass "$dtype executor completes"
  else
    fail "$dtype executor completes" "$(printf '%s' "$output" | tail -n 1)"
    continue
  fi

  check "$dtype canonical Brief keeps detected type" \
    test "$(jq -r '.detected_type' "$target/.harness/PROJECT_BRIEF.json")" = "$dtype"
  check "$dtype config maps to supported project_type" \
    test "$(jq -r '.project_type' "$target/.harness/config.json")" = "$expected_project_type"
  check "$dtype config is the mapped config template" \
    cmp -s "$target/.harness/config.json" "$ROOT/templates/.harness/config.json.$expected_project_type.example"

  for file in init.sh AGENTS.md CLAUDE.md; do
    check "$dtype generated $file matches typed template" \
      cmp -s "$target/$file" "$ROOT/templates/by-type/$dtype/$file"
    check "$dtype snapshot records typed source for $file" \
      test "$(jq -r --arg file "$file" '.templates[$file].source' "$target/.harness/.template-snapshot.json")" = "by-type/$dtype/$file"
  done

  while IFS= read -r marker; do
    marker="${marker//$'\r'/}"
    if contains_marker "$target/init.sh" "$marker"; then
      pass "$dtype generated init.sh contains required tool $marker"
    else
      fail "$dtype generated init.sh contains required tool $marker"
    fi
  done < <(printf '%s' "$row" | jq -r '.required[]')

  while IFS= read -r marker; do
    marker="${marker//$'\r'/}"
    if contains_marker "$target/init.sh" "$marker"; then
      fail "$dtype generated init.sh excludes foreign tool $marker"
    else
      pass "$dtype generated init.sh excludes foreign tool $marker"
    fi
  done < <(printf '%s' "$row" | jq -r '.forbidden[]')
done < <(jq -c '.types[]' "$FIXTURE")

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
