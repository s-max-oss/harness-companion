#!/bin/bash
# tests/release/test-e2-tag-trigger.sh
#
# Behavior tests for the E2 tag trigger check. Two layers:
#
#   Layer 1 (per-file, P1–P5, N1–N16): each case writes a single workflow
#   fixture, invokes E2_parse_tag_trigger, and asserts the structured exit
#   code returned by e2_check.py:
#       0  = release tag trigger detected          (PASS)
#       10 = valid YAML, no release trigger         (NOT_FOUND)
#       11 = YAML parse error                       (PARSE_ERR)
#       2  = PyYAML missing                         (DEP_MISSING)
#
#   Layer 2 (repo-level aggregation, A1–A4): each case builds a workflow
#   directory with TWO files (or one legal + one illegal), then runs the
#   same aggregation logic that test-release-archive.sh uses, and asserts
#   the resulting verdict (PASS / FAIL).
#
# This test runs in its own mktemp sandbox; the source repo is untouched.

set -uo pipefail

PASSED=0
FAILED=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  [PASS] $label"
    PASSED=$((PASSED + 1))
  else
    echo "  [FAIL] $label — expected $expected, got $actual"
    FAILED=$((FAILED + 1))
  fi
}

# Resolve E2_CHECK_PY against SOURCE_REPO (absolute). $(dirname "$0") would
# be wrong inside the test-release-archive.sh context because that script
# does `cd` into the extracted archive during Phase B.
SOURCE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
E2_CHECK_PY="$SOURCE_REPO/tests/release/e2_check.py"
E2_parse_tag_trigger() {
  python3 "$E2_CHECK_PY" "$1"
  return $?
}

# ---- Per-file aggregation logic ----
#
# Production aggregation lives in tests/release/e2_aggregate.sh — the SAME
# function the production gate (test-release-archive.sh Phase E2) calls.
# This test exercises the real production aggregator end-to-end; there is
# NO duplicated aggregation logic here. If e2_aggregate.sh changes, the
# A1a–A4 tests follow automatically.
# shellcheck disable=SC1091
. "$SOURCE_REPO/tests/release/e2_aggregate.sh"
E2_aggregate() {
  e2_aggregate "$@"
}

# ---- Check PyYAML availability ----
# We always run the PyYAML-MISSING test below, so the import-fatal gate is
# intentionally deferred to after that case runs (otherwise it would shortcut).
PYYAML_AVAILABLE=1
if ! python3 -c "import yaml" 2>/dev/null; then
  PYYAML_AVAILABLE=0
fi

# Sandbox for fixtures
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.github/workflows"

# Each case writes a workflow file then invokes E2_parse_tag_trigger.

# ---- POSITIVE CASES (single file, expect rc=0) ----

# P1: inline array 'v*'
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [master]
    tags: ['v*']
  pull_request:
    branches: [master]
jobs:
  test:
    runs-on: ubuntu-latest
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "P1 inline array tags: ['v*']" "0" "$?"

# P2: multi-line list 'v*'
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [master]
    tags:
      - 'v*'
  pull_request:
    branches: [master]
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "P2 multi-line list tags: ['v*']" "0" "$?"

# P3: specific version pattern
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "P3 specific version pattern" "0" "$?"

# P4: numeric version pattern
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags:
      - 'v1.2.3'
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "P4 numeric v1.2.3" "0" "$?"

# P5: real-world workflow shape — `name:` is the FIRST top-level key (the
# GitHub-recommended ordering), and `on:` comes later. E2 must accept this
# shape because real workflows start with name:, not on:.
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
name: harness-companion CI
on:
  push:
    branches: [master]
    tags: ['v*']
  pull_request:
    branches: [master]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "P5 real-world shape: name first, on: later" "0" "$?"

# ---- NEGATIVE CASES (single file, expect rc=10/11) ----

# N1: comment-only fake tag trigger (no actual on.push.tags) → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
# tags: ['v*']
on:
  push:
    branches: [master]
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N1 comment-faked trigger (no actual tags)" "10" "$?"

# N2: tags under jobs.tags (wrong location) → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [master]
jobs:
  test:
    tags: ['v*']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N2 jobs.tags (wrong location)" "10" "$?"

# N3: broken YAML → PARSE_ERR (rc=11)
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['v*
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N3 broken YAML" "11" "$?"

# N4: missing tags key entirely → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [master]
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N4 missing tags key" "10" "$?"

# N5: non-release tag pattern (random string) → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['release']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N5 non-release pattern ('release')" "10" "$?"

# N6: non-release pattern (just 'v') → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['v']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N6 non-release pattern ('v' alone)" "10" "$?"

# N7: empty tags list → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: []
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N7 empty tags list" "10" "$?"

# N8: tags is not a list (string with non-release content) → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: 'just-a-string'
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N8 non-release string" "10" "$?"

# N9: missing on: block entirely → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
jobs:
  test:
    runs-on: ubuntu-latest
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N9 missing on: block" "10" "$?"

# N10: missing push: block → NOT_FOUND
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  pull_request:
    branches: [master]
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N10 missing push: block" "10" "$?"

# N11: vbogus* — starts with v + content, has *, but content is non-numeric.
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['vbogus*']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N11 vbogus* — not a release pattern" "10" "$?"

# N12: v[ — truncated bracket class glob (no closing bracket content).
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['v[']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N12 v[ — truncated bracket class" "10" "$?"

# N13: fake top-level true: key (PyYAML 1.1 coerces true to boolean True;
# under the string-key loader it becomes the boolean True, NOT the string
# "on", so E2 sees no top-level on: trigger and reports NOT_FOUND).
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
true:
  push:
    tags: ['v*']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N13 fake top-level true: key" "10" "$?"

# N14: yes: also coerces to boolean True in YAML 1.1 — same as N13.
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
yes:
  push:
    tags: ['v*']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N14 fake top-level yes: key" "10" "$?"

# N15: legitimate on: with valid tags but NO jobs section → rc=0 PASS.
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'
      - 'v1.2.3'
jobs: {}
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N15 multi-pattern valid triggers" "0" "$?"

# N16: PyYAML-missing behavior — temporarily hide yaml from PYTHONPATH.
if [ "$PYYAML_AVAILABLE" -eq 1 ]; then
  cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['v*']
YAML
  E2_STUB_DIR="$(mktemp -d)"
  cat > "$E2_STUB_DIR/yaml.py" <<'PYEOF'
import sys
raise ImportError("stub: PyYAML forced unavailable for E2 negative test")
PYEOF
  PYTHONPATH="$E2_STUB_DIR" E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
  N16_RC=$?
  rm -rf "$E2_STUB_DIR"
  assert_eq "N16 PyYAML missing → exit 2 (fail-closed)" "2" "$N16_RC"
fi

# N17: v[0-9]bogus* — the bracket class body [0-9] is fine, but the trailing
# `bogus*` is not a recognized pattern form. After the v3-final tightening,
# the bracket class is validated independently, then the overall pattern
# must match the documented allowlist. v[0-9]bogus* does NOT match any of:
# v*, vX.Y.Z, vX.Y.Z.W, vX.Y.*, v[N]+anything-without-dot → FAIL.
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['v[0-9]bogus*']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N17 v[0-9]bogus* — not a documented allowlist form" "10" "$?"

# N18: v[---]whatever — the bracket class body is `---`, which is not a
# valid `digit(s)-digit(s)` range nor a single alnum char. Lock in rejection.
cat > "$TMP/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    tags: ['v[---]whatever']
YAML
E2_parse_tag_trigger "$TMP/.github/workflows/ci.yml" > /dev/null 2>&1
assert_eq "N18 v[---]whatever — malformed bracket class" "10" "$?"

# ---- AGGREGATION CASES (multi-file, expect PASS/FAIL on the verdict) ----
#
# A1: legal + corrupted file, BOTH orderings → FAIL (parse error must propagate)
# A2: legal release workflow + ordinary non-release workflow → PASS
# A3: top-level true: + nested on: → FAIL (true: is not a trigger under the
#     string-key loader, so the nested on: is not a top-level trigger)
# A4: top-level true: + a real quoted "on": key → PASS, only "on" counts

# A1a: legal first, corrupted second — must still FAIL with PARSE_ERR
rm -f "$TMP/.github/workflows"/*.yml
cat > "$TMP/.github/workflows/01-legal.yml" <<'YAML'
name: legal
on:
  push:
    tags: ['v*']
jobs:
  test:
    runs-on: ubuntu-latest
YAML
cat > "$TMP/.github/workflows/02-corrupted.yml" <<'YAML'
on:
  push:
    tags: ['v*
YAML
A1A_VERDICT="$(E2_aggregate "$TMP/.github/workflows" | head -1)"
assert_eq "A1a legal-then-corrupted → FAIL" "FAIL" "$A1A_VERDICT"

# A1b: corrupted first, legal second — must still FAIL with PARSE_ERR
rm -f "$TMP/.github/workflows"/*.yml
cat > "$TMP/.github/workflows/01-corrupted.yml" <<'YAML'
on:
  push:
    tags: ['v*
YAML
cat > "$TMP/.github/workflows/02-legal.yml" <<'YAML'
name: legal
on:
  push:
    tags: ['v*']
jobs:
  test:
    runs-on: ubuntu-latest
YAML
A1B_VERDICT="$(E2_aggregate "$TMP/.github/workflows" | head -1)"
assert_eq "A1b corrupted-then-legal → FAIL" "FAIL" "$A1B_VERDICT"

# A2: legal release workflow + ordinary non-release workflow → PASS
rm -f "$TMP/.github/workflows"/*.yml
cat > "$TMP/.github/workflows/01-release.yml" <<'YAML'
name: release
on:
  push:
    tags: ['v*']
jobs:
  test:
    runs-on: ubuntu-latest
YAML
cat > "$TMP/.github/workflows/02-non-release.yml" <<'YAML'
name: non-release
on:
  push:
    branches: [master]
  pull_request:
    branches: [master]
jobs:
  docs:
    runs-on: ubuntu-latest
YAML
A2_VERDICT="$(E2_aggregate "$TMP/.github/workflows" | head -1)"
assert_eq "A2 legal release + non-release → PASS" "PASS" "$A2_VERDICT"

# A3: top-level true: + nested on: (no quoted "on": anywhere) → FAIL.
# The boolean True key is NOT the string "on", so E2 sees no top-level
# trigger. The nested on: under true: is NOT a top-level trigger.
rm -f "$TMP/.github/workflows"/*.yml
cat > "$TMP/.github/workflows/01-fake-trigger.yml" <<'YAML'
name: fake-trigger
true:
  push:
    tags: ['v*']
jobs:
  test:
    runs-on: ubuntu-latest
YAML
cat > "$TMP/.github/workflows/02-nested-on.yml" <<'YAML'
name: nested-on
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo
        on:
          tags: ['v*']
YAML
A3_VERDICT="$(E2_aggregate "$TMP/.github/workflows" | head -1)"
assert_eq "A3 top-level true: + nested on: → FAIL" "FAIL" "$A3_VERDICT"

# A4: top-level true: + a REAL quoted "on": key. Only the string "on"
# counts; the boolean True block is ignored. E2 must find the release
# trigger under the quoted "on": key and PASS.
rm -f "$TMP/.github/workflows"/*.yml
cat > "$TMP/.github/workflows/01-quoted-on.yml" <<'YAML'
name: quoted-on
"on":
  push:
    tags: ['v*']
jobs:
  test:
    runs-on: ubuntu-latest
YAML
cat > "$TMP/.github/workflows/02-true-block.yml" <<'YAML'
name: true-block
true:
  push:
    tags: ['bogus']
YAML
A4_VERDICT="$(E2_aggregate "$TMP/.github/workflows" | head -1)"
assert_eq "A4 top-level true: + quoted \"on\": → PASS" "PASS" "$A4_VERDICT"

echo ""
echo "=== E2 Behavior Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
