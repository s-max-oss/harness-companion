#!/bin/bash
# test-v1-compat.sh — harness-companion Phase 2 migration compat tests
#
# Verifies that the standalone repo (s-max-oss/harness-companion) correctly
# absorbs v2 work while preserving v1.1.2 user contracts:
#
#   G1  Six old command entry points exist and are executable
#   G2  v1 compat wrappers forward to core (≤5 lines, exec bash pattern)
#   G3  scripts/harness-init.sh is canonical — actually creates the 4 scaffold files
#   G4  scripts/harness-handoff.sh is canonical — actually outputs a summary
#   G5  scripts/hooks/* forward to adapters/claude-code/hooks/*
#   G6  Top-level install.sh dispatches to adapters (--help / --codex / --all)
#   G7  Plugin manifest version is 2.0.0-rc.1
#   G8  Bilingual README: README.md and README.zh-CN.md both present
#   G9  GitHub URLs unified to https://github.com/s-max-oss/harness-companion
#       — no walkinglabs/ in docs, no s-max-oss/harness-engineering in product fields
#   G10 CHANGELOG.md exists at top level and references the new release
#   G11 README, SKILL.md, CHANGELOG consistently say 2.0.0-rc.1
#
# Run from repo root:
#   bash tests/migration/test-v1-compat.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0

pass() {
  local name="$1"
  echo "PASS: $name"
  PASSED=$((PASSED + 1))
}

fail() {
  local name="$1" reason="$2"
  echo "FAIL: $name — $reason"
  FAILED=$((FAILED + 1))
}

skip() {
  local name="$1" reason="$2"
  echo "SKIP: $name — $reason"
  SKIPPED=$((SKIPPED + 1))
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name (expected=$expected, got=$actual)"
  else
    fail "$name" "expected=$expected, got=$actual"
  fi
}

assert_file_exists() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name ($path)"
  else
    fail "$name" "missing file: $path"
  fi
}

assert_file_executable() {
  local name="$1" path="$2"
  if [ -x "$path" ]; then
    pass "$name"
  else
    fail "$name" "not executable: $path"
  fi
}

assert_contains() {
  local name="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF "$needle" "$file" 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "'$needle' not found in $file"
  fi
}

assert_not_contains() {
  local name="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF "$needle" "$file" 2>/dev/null; then
    fail "$name" "found forbidden '$needle' in $file"
  else
    pass "$name"
  fi
}

# ============================================================================
# G1 — Six old command entry points exist and are executable
# ============================================================================
echo ""
echo "=== G1: Six old command entry points ==="
for cmd in harness-init harness-handoff harness-status harness-feature harness-verify harness-audit; do
  assert_file_exists "G1 scripts/$cmd.sh exists" "$ROOT_DIR/scripts/$cmd.sh"
  assert_file_executable "G1 scripts/$cmd.sh executable" "$ROOT_DIR/scripts/$cmd.sh"
done

# ============================================================================
# G2 — v1 compat wrappers forward to core (≤5 lines, exec bash pattern)
# ============================================================================
echo ""
echo "=== G2: v1 compat wrappers forward to core ==="
for cmd in harness-audit harness-feature harness-status harness-verify; do
  f="$ROOT_DIR/scripts/$cmd.sh"
  if [ -f "$f" ]; then
    # Must contain exec bash SCRIPT_DIR/../core/$(basename "$0") pattern
    if grep -qF 'exec bash "$SCRIPT_DIR/../core/$(basename "$0")"' "$f"; then
      pass "G2 $cmd.sh forwards to core via exec bash"
    else
      fail "G2 $cmd.sh forwards to core" "missing exec bash pattern pointing at ../core"
    fi
    # Non-comment, non-blank line count ≤5
    eff_lines=$(grep -cvE '^[[:space:]]*(#|$)' "$f")
    if [ "$eff_lines" -le 5 ]; then
      pass "G2 $cmd.sh is ≤5 effective lines (got $eff_lines)"
    else
      fail "G2 $cmd.sh is ≤5 lines" "got $eff_lines effective lines"
    fi
  fi
done

# ============================================================================
# G3 — scripts/harness-init.sh is canonical — actually creates 4 files
# ============================================================================
echo ""
echo "=== G3: scripts/harness-init.sh creates 4 scaffold files ==="
TMPINIT="$(mktemp -d)"
trap 'rm -rf "$TMPINIT"' EXIT

if bash "$ROOT_DIR/scripts/harness-init.sh" "$TMPINIT" >/dev/null 2>&1; then
  for f in AGENTS.md CLAUDE.md feature_list.json init.sh; do
    if [ -f "$TMPINIT/$f" ]; then
      pass "G3 init.sh created $f"
    else
      fail "G3 init.sh created $f" "file missing after init"
    fi
  done
  # init.sh should be executable
  if [ -x "$TMPINIT/init.sh" ]; then
    pass "G3 init.sh is executable"
  else
    fail "G3 init.sh is executable" "chmod +x was not applied"
  fi
else
  fail "G3 harness-init.sh invocation" "exit non-zero"
fi

# ============================================================================
# G4 — scripts/harness-handoff.sh is canonical — actually outputs a summary
# ============================================================================
echo ""
echo "=== G4: scripts/harness-handoff.sh outputs summary ==="
TMPHAND="$(mktemp -d)"
trap 'rm -rf "$TMPHAND"' EXIT

# Set up a minimal harness project
echo '{"features":[],"last_updated":"2026-08-03"}' > "$TMPHAND/feature_list.json"
mkdir -p "$TMPHAND/.git"

if bash "$ROOT_DIR/scripts/harness-handoff.sh" "$TMPHAND" >/dev/null 2>&1; then
  pass "G4 harness-handoff.sh exits 0"
else
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "G4 harness-handoff.sh exits 0"
  else
    fail "G4 harness-handoff.sh invocation" "exit=$rc"
  fi
fi

# The output of handoff should contain the Handoff Summary header
HANDOFF_OUT="$(bash "$ROOT_DIR/scripts/harness-handoff.sh" "$TMPHAND" 2>&1 || true)"
if printf '%s\n' "$HANDOFF_OUT" | grep -q "Handoff Summary"; then
  pass "G4 harness-handoff.sh prints 'Handoff Summary'"
else
  fail "G4 harness-handoff.sh prints summary" "no 'Handoff Summary' line in output"
fi

# ============================================================================
# G5 — scripts/hooks/* forward to adapters/claude-code/hooks/*
# ============================================================================
echo ""
echo "=== G5: scripts/hooks/* forward to Claude Code adapter ==="
for hook in session-start stop-handoff; do
  f="$ROOT_DIR/scripts/hooks/$hook.sh"
  if [ -f "$f" ]; then
    if grep -qF 'exec bash "$SCRIPT_DIR/../../adapters/claude-code/hooks/$(basename "$0")"' "$f"; then
      pass "G5 hooks/$hook.sh forwards to claude-code adapter"
    else
      fail "G5 hooks/$hook.sh forwards to claude-code adapter" "missing exec bash pattern"
    fi
    eff_lines=$(grep -cvE '^[[:space:]]*(#|$)' "$f")
    if [ "$eff_lines" -le 5 ]; then
      pass "G5 hooks/$hook.sh is ≤5 effective lines (got $eff_lines)"
    else
      fail "G5 hooks/$hook.sh is ≤5 lines" "got $eff_lines effective lines"
    fi
  else
    fail "G5 scripts/hooks/$hook.sh exists" "missing file"
  fi
done

# ============================================================================
# G6 — Top-level install.sh dispatches (--help / --codex / --all)
# ============================================================================
echo ""
echo "=== G6: install.sh top-level dispatcher ==="
assert_file_exists "G6 install.sh exists at top level" "$ROOT_DIR/install.sh"
assert_file_executable "G6 install.sh is executable" "$ROOT_DIR/install.sh"

# --help should print usage (first line or "harness-companion")
if bash "$ROOT_DIR/install.sh" --help 2>&1 | grep -qi "harness-companion"; then
  pass "G6 install.sh --help shows harness-companion usage"
else
  fail "G6 install.sh --help" "no harness-companion banner"
fi

# --help should mention --codex and --all
if bash "$ROOT_DIR/install.sh" --help 2>&1 | grep -q "\-\-codex"; then
  pass "G6 install.sh --help mentions --codex"
else
  fail "G6 install.sh --help mentions --codex" "missing"
fi
if bash "$ROOT_DIR/install.sh" --help 2>&1 | grep -q "\-\-all"; then
  pass "G6 install.sh --help mentions --all"
else
  fail "G6 install.sh --help mentions --all" "missing"
fi

# ============================================================================
# G7 — Plugin manifest version is 2.0.0-rc.1
# ============================================================================
echo ""
echo "=== G7: Plugin manifest ==="
if [ -f "$ROOT_DIR/.codex-plugin/plugin.json" ]; then
  v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$ROOT_DIR/.codex-plugin/plugin.json" | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  assert_eq "G7 plugin.json version" "2.0.0-rc.1" "$v"
else
  fail "G7 plugin.json exists" "missing file"
fi

# ============================================================================
# G8 — Bilingual README
# ============================================================================
echo ""
echo "=== G8: Bilingual README ==="
assert_file_exists "G8 README.md exists" "$ROOT_DIR/README.md"
assert_file_exists "G8 README.zh-CN.md exists" "$ROOT_DIR/README.zh-CN.md"

# README.md must link to README.zh-CN.md (cross-reference)
if grep -q "README.zh-CN.md" "$ROOT_DIR/README.md" 2>/dev/null; then
  pass "G8 README.md references README.zh-CN.md"
else
  fail "G8 README.md references README.zh-CN.md" "no cross-reference found"
fi
if grep -q "README.md" "$ROOT_DIR/README.zh-CN.md" 2>/dev/null; then
  pass "G8 README.zh-CN.md references README.md"
else
  fail "G8 README.zh-CN.md references README.md" "no cross-reference found"
fi

# ============================================================================
# G9 — GitHub URLs unified to https://github.com/s-max-oss/harness-companion
# ============================================================================
echo ""
echo "=== G9: GitHub URL unification ==="
TARGET_URL="https://github.com/s-max-oss/harness-companion"

# Documents that must contain the canonical URL
for doc in README.md README.zh-CN.md SKILL.md CHANGELOG.md .codex-plugin/plugin.json; do
  fp="$ROOT_DIR/$doc"
  if [ -f "$fp" ]; then
    if grep -qF "$TARGET_URL" "$fp" 2>/dev/null; then
      pass "G9 $doc contains $TARGET_URL"
    else
      fail "G9 $doc contains $TARGET_URL" "missing canonical URL"
    fi
  fi
done

# Forbidden URLs in product docs
forbidden_in_product=(
  "https://github.com/walkinglabs"
  "s-max-oss/harness-engineering"
)
# walkinglabs is allowed only as a brief mention in the "Learn Harness Engineering" course
# attribution in README — but s-max-oss/harness-engineering (course fork) must NOT
# appear in the *product* surface area (plugin.json homepage/repo).
if [ -f "$ROOT_DIR/.codex-plugin/plugin.json" ]; then
  for needle in "${forbidden_in_product[@]}"; do
    if grep -qF "$needle" "$ROOT_DIR/.codex-plugin/plugin.json" 2>/dev/null; then
      fail "G9 plugin.json forbids '$needle'" "found forbidden URL"
    else
      pass "G9 plugin.json forbids '$needle'"
    fi
  done
else
  fail "G9 plugin.json exists" "missing"
fi

# walkinglabs is only acceptable as the upstream course attribution in README files.
# Skip the broader scan — we only verify that the product surface (plugin.json,
# install paths, SKILL.md code examples) does NOT link to walkinglabs.
for doc in SKILL.md install.sh .codex-plugin/plugin.json; do
  fp="$ROOT_DIR/$doc"
  if [ -f "$fp" ]; then
    if grep -qF "walkinglabs" "$fp" 2>/dev/null; then
      fail "G9 $doc forbids walkinglabs URL" "found walkinglabs in product surface"
    else
      pass "G9 $doc does not reference walkinglabs"
    fi
  fi
done

# ============================================================================
# G10 — CHANGELOG.md exists at top level
# ============================================================================
echo ""
echo "=== G10: CHANGELOG.md ==="
assert_file_exists "G10 CHANGELOG.md exists" "$ROOT_DIR/CHANGELOG.md"

# Must reference the 2.x release line
if grep -qE '2\.0\.0-rc\.1|2\.0\.0' "$ROOT_DIR/CHANGELOG.md" 2>/dev/null; then
  pass "G10 CHANGELOG.md mentions 2.0.0 / 2.0.0-rc.1"
else
  fail "G10 CHANGELOG.md mentions 2.0.0" "no version reference"
fi

# ============================================================================
# G11 — README, SKILL.md, CHANGELOG version mentions are consistent
# ============================================================================
echo ""
echo "=== G11: Version consistency ==="
for doc in README.md README.zh-CN.md SKILL.md CHANGELOG.md; do
  fp="$ROOT_DIR/$doc"
  if [ -f "$fp" ] && grep -q "2.0.0-rc.1" "$fp" 2>/dev/null; then
    pass "G11 $doc mentions 2.0.0-rc.1"
  else
    fail "G11 $doc mentions 2.0.0-rc.1" "missing"
  fi
done

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Migration Compat Test Summary ==="
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "SKIPPED: $SKIPPED"
echo ""

# ============================================================================
# G12 — Init produces the full v2 scaffold (P0-1 acceptance)
# ============================================================================
echo ""
echo "=== G12: /harness:init produces v2 scaffold for node/python/docs/generic ==="

init_e2e() {
  local name="$1"
  local marker="$2"
  local expected_type="$3"

  local tmp; tmp="$(mktemp -d)"
  if [ -n "$marker" ]; then
    touch "$tmp/$marker"
  fi

  if ! bash "$ROOT_DIR/scripts/harness-init.sh" "$tmp" >/dev/null 2>&1; then
    fail "G12 $name: init exit non-zero" "see output"
    rm -rf "$tmp"
    return
  fi

  # Required files
  for f in AGENTS.md CLAUDE.md init.sh feature_list.json .harness/config.json .gitignore; do
    if [ ! -f "$tmp/$f" ]; then
      fail "G12 $name: missing $f after init" "absent"
      rm -rf "$tmp"
      return
    fi
  done
  pass "G12 $name: all 6 required files present (AGENTS.md/CLAUDE.md/init.sh/feature_list.json/.harness/config.json/.gitignore)"

  # .harness/logs/runs/ must exist
  if [ ! -d "$tmp/.harness/logs/runs" ]; then
    fail "G12 $name: .harness/logs/runs/ missing" "absent"
    rm -rf "$tmp"
    return
  fi
  pass "G12 $name: .harness/logs/runs/ exists"

  # feature_list.json must be v2 schema (revision: 1)
  local rev
  rev="$(jq -r '.revision' "$tmp/feature_list.json" 2>/dev/null)"
  if [ "$rev" = "1" ]; then
    pass "G12 $name: feature_list.json revision=1 (v2 schema)"
  else
    fail "G12 $name: feature_list.json revision" "expected 1, got '$rev'"
  fi

  # .harness/config.json must have detected project_type
  local got_type
  got_type="$(jq -r '.project_type' "$tmp/.harness/config.json" 2>/dev/null)"
  if [ "$got_type" = "$expected_type" ]; then
    pass "G12 $name: project_type=$expected_type (auto-detected)"
  else
    fail "G12 $name: project_type" "expected $expected_type, got $got_type"
  fi

  # .gitignore must contain .harness/logs/
  if grep -qF ".harness/logs/" "$tmp/.gitignore" 2>/dev/null; then
    pass "G12 $name: .gitignore contains .harness/logs/"
  else
    fail "G12 $name: .gitignore missing .harness/logs/" "absent"
  fi

  # init.sh must be executable
  if [ -x "$tmp/init.sh" ]; then
    pass "G12 $name: init.sh is executable"
  else
    fail "G12 $name: init.sh executable" "chmod +x missing"
  fi

  # E2E: status/feature/verify must read v2 scaffold without crashing
  local status_rc feature_rc verify_rc
  bash "$ROOT_DIR/scripts/harness-status.sh" "$tmp" >/dev/null 2>&1
  status_rc=$?
  cd "$tmp"
  bash "$ROOT_DIR/scripts/harness-feature.sh" list >/dev/null 2>&1
  feature_rc=$?
  cd "$ROOT_DIR"
  if [ "$status_rc" -eq 0 ]; then
    pass "G12 $name: harness-status.sh reads v2 scaffold (exit 0)"
  else
    fail "G12 $name: harness-status.sh" "exit=$status_rc"
  fi
  if [ "$feature_rc" -eq 0 ]; then
    pass "G12 $name: harness-feature.sh reads v2 scaffold (exit 0)"
  else
    fail "G12 $name: harness-feature.sh" "exit=$feature_rc"
  fi
  # harness-verify.sh may legitimately exit non-zero on empty project (commands fail)
  # — we only assert it READ the scaffold successfully (got past config parse)
  bash "$ROOT_DIR/scripts/harness-verify.sh" feature-001 "$tmp" >/dev/null 2>&1
  verify_rc=$?
  if [ "$verify_rc" -ne 0 ]; then
    # Non-zero is OK here (commands fail on empty project), but the script must
    # have read the config + written a log. Check for log dir entry.
    if ls "$tmp/.harness/logs/runs/"*.ndjson >/dev/null 2>&1; then
      pass "G12 $name: harness-verify.sh read v2 config + wrote run log (commands may legitimately fail)"
    else
      fail "G12 $name: harness-verify.sh" "no run log written — config not read"
    fi
  else
    pass "G12 $name: harness-verify.sh ran successfully on v2 scaffold"
  fi

  rm -rf "$tmp"
}

init_e2e "node"     "package.json"     "node"
init_e2e "python"   "pyproject.toml"   "python"
init_e2e "docs"     "README.md"        "docs"
init_e2e "generic"  ""                 "generic"

# ============================================================================
# G13 — Six project-type config examples + schema are tracked in Git
# ============================================================================
echo ""
echo "=== G13: 6 project-type config examples + schema tracked in Git ==="
for t in node python rust go docs generic; do
  fp="templates/.harness/config.json.${t}.example"
  if [ -f "$ROOT_DIR/$fp" ]; then
    pass "G13 templates/.harness/config.json.${t}.example exists"
  else
    fail "G13 templates/.harness/config.json.${t}.example exists" "missing"
  fi
done
assert_file_exists "G13 templates/.harness/config.schema.json" "$ROOT_DIR/templates/.harness/config.schema.json"

# Also check git ls-files (not just working tree)
echo ""
echo "  --- git ls-files for templates/.harness/ ---"
git -C "$ROOT_DIR" ls-files templates/.harness/ 2>&1 | sed 's/^/    /'
tracked_count=$(git -C "$ROOT_DIR" ls-files templates/.harness/ | wc -l | tr -d ' ')
if [ "$tracked_count" -eq 7 ]; then
  pass "G13 git tracks all 7 templates/.harness/ files"
else
  fail "G13 git tracks 7 templates/.harness/ files" "tracked=$tracked_count"
fi

# git archive HEAD verification (per user requirement: must be in commit, not just working tree)
ARCHIVE_TMP="$(mktemp -d)"
git -C "$ROOT_DIR" archive HEAD -- 'templates/.harness/*' | tar -x -C "$ARCHIVE_TMP"
archive_count=$(find "$ARCHIVE_TMP/templates/.harness/" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$archive_count" -eq 7 ]; then
  pass "G13 git archive HEAD contains all 7 templates/.harness/ files"
else
  fail "G13 git archive HEAD contains 7 files" "archive=$archive_count"
fi
rm -rf "$ARCHIVE_TMP"

# ============================================================================
# G14 — Codex host produces codex-progress.md instead of CLAUDE.md
# ============================================================================
echo ""
echo "=== G14: --host=codex produces codex-progress.md ==="
TMP_CODEX="$(mktemp -d)"
touch "$TMP_CODEX/package.json"
bash "$ROOT_DIR/scripts/harness-init.sh" "$TMP_CODEX" --host=codex >/dev/null 2>&1
if [ -f "$TMP_CODEX/codex-progress.md" ] && [ ! -f "$TMP_CODEX/CLAUDE.md" ]; then
  pass "G14 --host=codex wrote codex-progress.md (and skipped CLAUDE.md)"
else
  fail "G14 --host=codex" "codex-progress.md=$( [ -f "$TMP_CODEX/codex-progress.md" ] && echo Y || echo N ) CLAUDE.md=$( [ -f "$TMP_CODEX/CLAUDE.md" ] && echo Y || echo N )"
fi
rm -rf "$TMP_CODEX"

# ============================================================================
# G15 — --full mode produces the 4 extra files
# ============================================================================
echo ""
echo "=== G15: --full produces extra files ==="
TMP_FULL="$(mktemp -d)"
touch "$TMP_FULL/package.json"
bash "$ROOT_DIR/scripts/harness-init.sh" "$TMP_FULL" --full >/dev/null 2>&1
for f in claude-progress.md session-handoff.md clean-state-checklist.md checklist.sh; do
  if [ -f "$TMP_FULL/$f" ]; then
    pass "G15 --full produced $f"
  else
    fail "G15 --full produced $f" "missing"
  fi
done
if [ -x "$TMP_FULL/checklist.sh" ]; then
  pass "G15 --full checklist.sh is executable"
else
  fail "G15 --full checklist.sh executable" "chmod +x missing"
fi
rm -rf "$TMP_FULL"

echo ""
echo "=== Migration Compat Test Summary ==="
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "SKIPPED: $SKIPPED"
echo ""

if [ "$FAILED" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi

echo "RESULT: PASS"
exit 0