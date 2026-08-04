#!/bin/bash
# core/harness-audit.sh — 5-axis scoring across the 7 Harness Engineering subsystems (v2)
#
# Ported from v1.1.2 scripts/harness-audit.sh. Uses core/lib/ for shared helpers.
#
# Usage:
#   bash harness-audit.sh [project_dir] [--snapshot-at <git_ref>]
#
# Five axes per subsystem, each scored 0-3:
#   1. existence      — are the canonical files present?
#   2. completeness   — do they contain required sections/fields?
#   3. execution      — can we run the verification chain and produce structured evidence?
#   4. recency        — are files touched within a deterministic window?
#   5. effectiveness  — does the system produce the expected outcome?
#
# The subsystem score is floor(passed * 3 / total) — continuous scale that
# avoids bracket overestimation (e.g. 1/5 → 0, 5/5 → 3, 4/5 → 2). Maximum
# subsystem = 3 when all 5 axes pass. Total = sum of all 7 subsystems, max 21.
#
# Requires: jq (for feature_list.json parsing). Falls back to "unknown" axes when missing.

set -uo pipefail

# Source validator/staleness from this script's directory BEFORE changing cwd.
# The audit's effectiveness axis needs to call validate_run_log + staleness
# helpers against the target project's canonical NDJSON logs. Sourcing before
# cd ensures the helpers load from the install location, regardless of how
# the audit script is invoked.
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate-run-log.sh
[ -f "$SKILL_DIR/lib/validate-run-log.sh" ] && source "$SKILL_DIR/lib/validate-run-log.sh"
# shellcheck source=lib/staleness.sh
[ -f "$SKILL_DIR/lib/staleness.sh" ] && source "$SKILL_DIR/lib/staleness.sh"

TARGET="${1:-.}"
SNAPSHOT_AT=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot-at) SNAPSHOT_AT="${2:-}"; shift 2 ;;
    --help|-h)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

if [ ! -d "$TARGET" ]; then
  echo "Error: directory '$TARGET' not found" >&2
  exit 1
fi

cd "$TARGET"
PROJECT_DIR="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

HAS_JQ=0
if command -v jq >/dev/null 2>&1; then HAS_JQ=1; fi

# --- Helpers -----------------------------------------------------------------

score_axis() {
  local checks_passed="$1"
  local checks_total="$2"
  if [ "$checks_total" = "0" ]; then
    echo "0"
    return
  fi
  # Continuous scale: floor(passed * 3 / total). Max = 3 when all pass.
  # Avoids the old bracket formula overestimating (passed>=3 → 3 regardless of
  # how many checks were actually possible).
  echo $(( checks_passed * 3 / checks_total ))
}

has_section() {
  local file="$1" section="$2"
  [ -f "$file" ] && grep -qE "^#+ +${section}" "$file" 2>/dev/null
}

mtime_epoch() {
  local f="$1"
  if [ ! -f "$f" ]; then echo "0"; return; fi
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0"
}

git_last_change_epoch() {
  local f="$1"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git log -1 --format=%ct -- "$f" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

recent_within_hours() {
  local f="$1" hours="$2"
  local cutoff now last
  cutoff="$(date +%s)"
  now="$cutoff"
  last="$(git_last_change_epoch "$f")"
  if [ "$last" = "0" ]; then last="$(mtime_epoch "$f")"; fi
  if [ "$last" = "0" ]; then echo "false"; return; fi
  local age=$(( (now - last) / 3600 ))
  if [ "$age" -le "$hours" ]; then echo "true"; else echo "false"; fi
}

record_evidence() {
  local label="$1" detail="$2"
  printf '    - %s: %s\n' "$label" "$detail"
}

# --- Per-subsystem scoring ----------------------------------------------------

# ---- 1. Knowledge ----
audit_knowledge() {
  local p=0 total=0
  local evidence=""

  total=$((total + 1))
  if [ -f "AGENTS.md" ] && [ -f "CLAUDE.md" ]; then p=$((p+1)); evidence+="$(record_evidence existence 'AGENTS.md+CLAUDE.md present')"
  else evidence+="$(record_evidence existence 'AGENTS.md or CLAUDE.md missing')"; fi

  total=$((total + 1))
  if has_section AGENTS.md "Startup Rules" && has_section AGENTS.md "Definition of Done"; then
    p=$((p+1))
    evidence+="$(record_evidence completeness 'AGENTS.md has Startup Rules + DoD')"
  else
    evidence+="$(record_evidence completeness 'AGENTS.md missing required sections')"
  fi

  total=$((total + 1))
  if [ -d "docs" ] && [ "$(find docs -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
    p=$((p+1))
    evidence+="$(record_evidence execution 'docs/ contains at least one .md')"
  else
    evidence+="$(record_evidence execution 'docs/ empty or missing')"
  fi

  total=$((total + 1))
  if [ "$(recent_within_hours AGENTS.md 168)" = "true" ]; then
    p=$((p+1))
    evidence+="$(record_evidence recency 'AGENTS.md updated within 7 days')"
  else
    evidence+="$(record_evidence recency 'AGENTS.md stale or untracked')"
  fi

  total=$((total + 1))
  if [ -f CLAUDE.md ]; then
    local cl
    cl="$(wc -l < CLAUDE.md | tr -d ' ')"
    if [ "$cl" -lt 200 ]; then
      p=$((p+1))
      evidence+="$(record_evidence effectiveness "CLAUDE.md is $cl lines (concise)")"
    else
      evidence+="$(record_evidence effectiveness "CLAUDE.md is $cl lines (bloated)")"
    fi
  else
    evidence+="$(record_evidence effectiveness 'CLAUDE.md missing')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 2. Environment ----
audit_environment() {
  local p=0 total=0 evidence=""
  total=$((total + 1))
  if [ -f "init.sh" ]; then p=$((p+1)); evidence+="$(record_evidence existence 'init.sh present')"
  else evidence+="$(record_evidence existence 'init.sh missing')"; fi

  total=$((total + 1))
  local ok=0
  if grep -qE 'npm install|pip install|yarn|pnpm' init.sh 2>/dev/null; then ok=$((ok+1)); fi
  if grep -qiE 'check|typecheck|tsc|mypy|ruff' init.sh 2>/dev/null; then ok=$((ok+1)); fi
  if grep -qiE 'build|compile' init.sh 2>/dev/null; then ok=$((ok+1)); fi
  if [ "$ok" -ge 2 ]; then p=$((p+1)); evidence+="$(record_evidence completeness "init.sh covers $ok/3 of install/check/build")"
  else evidence+="$(record_evidence completeness "init.sh only covers $ok/3")"; fi

  total=$((total + 1))
  if [ -f ".harness/config.json" ]; then p=$((p+1)); evidence+="$(record_evidence execution '.harness/config.json present (verifiable)')"
  else evidence+="$(record_evidence execution '.harness/config.json missing (config-driven verification disabled)')"; fi

  total=$((total + 1))
  if [ "$(recent_within_hours init.sh 168)" = "true" ]; then
    p=$((p+1))
    evidence+="$(record_evidence recency 'init.sh updated within 7 days')"
  else
    evidence+="$(record_evidence recency 'init.sh stale')"
  fi

  total=$((total + 1))
  if [ -x init.sh ] && [ -d ".harness/logs" ]; then
    p=$((p+1))
    evidence+="$(record_evidence effectiveness 'init.sh executable; verify logs directory exists')"
  else
    evidence+="$(record_evidence effectiveness 'init.sh not executable or no verify logs')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 3. Progress ----
audit_progress() {
  local p=0 total=0 evidence=""

  total=$((total + 1))
  if [ -f "claude-progress.md" ]; then p=$((p+1)); evidence+="$(record_evidence existence 'claude-progress.md present')"
  else evidence+="$(record_evidence existence 'claude-progress.md missing')"; fi

  total=$((total + 1))
  local ok=0
  if grep -qiE 'Current Verified State|verified state' claude-progress.md 2>/dev/null; then ok=$((ok+1)); fi
  if grep -qE 'Session [0-9]+|Session Log' claude-progress.md 2>/dev/null; then ok=$((ok+1)); fi
  if [ "$ok" -ge 1 ]; then p=$((p+1)); evidence+="$(record_evidence completeness "claude-progress.md has $ok/2 expected sections")"
  else evidence+="$(record_evidence completeness 'claude-progress.md missing structure')"; fi

  total=$((total + 1))
  if [ "$(recent_within_hours claude-progress.md 168)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence execution 'updated within 7 days')"
  else evidence+="$(record_evidence execution 'stale (>7 days)')"; fi

  total=$((total + 1))
  if [ "$(recent_within_hours claude-progress.md 720)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence recency 'updated within 30 days')"
  else evidence+="$(record_evidence recency 'older than 30 days')"; fi

  total=$((total + 1))
  if [ -f session-handoff.md ] && [ "$(recent_within_hours session-handoff.md 720)" = "true" ]; then
    p=$((p+1))
    evidence+="$(record_evidence effectiveness 'session-handoff.md exists and recent')"
  else
    evidence+="$(record_evidence effectiveness 'session-handoff.md missing or stale')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 4. Scope/Feature ----
# V2 schema (Phase 1-3 canonical): feature_list.json uses
#   - top-level .revision (monotonic counter)
#   - .features[].evidence_associations[] (with run_id) for canonical evidence
#   - .features[].legacy_audit_evidence[] as migration audit info ONLY
#     (never treated as canonical passing evidence)
# Audit no longer requires v1 .rules{}. Instead it checks:
#   - revision present + monotonic-compatible (>= 0)
#   - status legality (one of: not_started, in_progress, passing, blocked,
#     unverified, deprecated)
#   - association structure (each assoc has run_id, run_id is non-empty
#     string; references real NDJSON log under .harness/logs/runs/)
#   - canonical run-log verifiability (validate_run_log returns valid:true)
audit_scope() {
  local p=0 total=0 evidence=""
  total=$((total + 1))
  if [ -f feature_list.json ]; then p=$((p+1)); evidence+="$(record_evidence existence 'feature_list.json present')"
  else evidence+="$(record_evidence existence 'feature_list.json missing')"; fi

  total=$((total + 1))
  # v2: revision present + non-negative (replaces v1 .rules completeness)
  if [ "$HAS_JQ" = "1" ]; then
    local rev
    rev="$(jq -r '.revision // null' feature_list.json 2>/dev/null || echo null)"
    if [ "$rev" != "null" ] && [ "$rev" -ge 0 ] 2>/dev/null; then
      p=$((p+1))
      evidence+="$(record_evidence completeness "top-level .revision=$rev (v2 canonical counter)")"
    else
      evidence+="$(record_evidence completeness 'top-level .revision missing or invalid')"
    fi
  else
    evidence+="$(record_evidence completeness 'jq unavailable — cannot read .revision')"
  fi

  total=$((total + 1))
  # v2: association structure (replace v1 .evidence[]? count)
  if [ "$HAS_JQ" = "1" ]; then
    local assoc_count assoc_valid
    assoc_count="$(jq '[.features[].evidence_associations[]? | select(type == "object")] | length' feature_list.json 2>/dev/null || echo 0)"
    assoc_valid="$(jq '[.features[].evidence_associations[]? | select(.run_id != null and (.run_id | length) > 0)] | length' feature_list.json 2>/dev/null || echo 0)"
    if [ "$assoc_count" -gt 0 ] && [ "$assoc_valid" = "$assoc_count" ]; then
      p=$((p+1))
      evidence+="$(record_evidence execution "$assoc_valid/$assoc_count evidence_associations have run_id")"
    else
      evidence+="$(record_evidence execution "$assoc_valid/$assoc_count evidence_associations have run_id")"
    fi
  else
    evidence+="$(record_evidence execution 'jq unavailable — cannot assess association shape')"
  fi

  total=$((total + 1))
  if [ "$(recent_within_hours feature_list.json 168)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence recency 'feature_list.json updated within 7 days')"
  else evidence+="$(record_evidence recency 'feature_list.json stale')"; fi

  total=$((total + 1))
  if [ "$HAS_JQ" = "1" ]; then
    local wip bad_passing
    # v2: bad_passing uses evidence_associations, NOT v1 .evidence
    wip="$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json)"
    bad_passing="$(jq '[.features[] | select((.status=="passing" or .status=="unverified") and (((.evidence_associations // []) | length) == 0))] | length' feature_list.json)"
    if [ "$wip" -le 1 ] && [ "$bad_passing" = "0" ]; then
      p=$((p+1))
      evidence+="$(record_evidence effectiveness "WIP=$wip (≤1), bad_passing=0 (no association-less passing features)")"
    else
      evidence+="$(record_evidence effectiveness "WIP=$wip, $bad_passing unverified/passing without evidence_associations")"
    fi
  else
    evidence+="$(record_evidence effectiveness 'jq unavailable — cannot assess WIP/evidence')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 5. Verification ----
audit_verification() {
  local p=0 total=0 evidence=""

  total=$((total + 1))
  if [ -f checklist.sh ]; then
    p=$((p+1))
    evidence+="$(record_evidence existence 'checklist.sh present')"
  elif [ -f .harness/config.json ]; then
    p=$((p+1))
    evidence+="$(record_evidence existence '.harness/config.json present (no checklist.sh)')"
  else
    evidence+="$(record_evidence existence 'no checklist.sh or config.json')"
  fi

  total=$((total + 1))
  local ok=0
  if grep -qiE 'typecheck|tsc' checklist.sh 2>/dev/null; then ok=$((ok+1)); fi
  if grep -qiE 'build|compile' checklist.sh 2>/dev/null; then ok=$((ok+1)); fi
  if [ "$ok" -ge 2 ]; then p=$((p+1)); evidence+="$(record_evidence completeness "checklist.sh covers typecheck+build")"
  else evidence+="$(record_evidence completeness "checklist.sh covers $ok/2")"; fi

  total=$((total + 1))
  if [ -d ".harness/logs" ] && [ "$(ls -1 .harness/logs 2>/dev/null | wc -l)" -gt 0 ]; then
    p=$((p+1))
    evidence+="$(record_evidence execution "verify log artifacts present ($(ls -1 .harness/logs | wc -l) files)")"
  else
    evidence+="$(record_evidence execution 'no verify log artifacts')"
  fi

  total=$((total + 1))
  local recent_log=""
  if [ -d ".harness/logs" ]; then
    recent_log="$(find .harness/logs -type f -mtime -1 2>/dev/null | head -1)"
  fi
  if [ -n "$recent_log" ]; then p=$((p+1)); evidence+="$(record_evidence recency "recent verify log: $(basename "$recent_log")")"
  else evidence+="$(record_evidence recency 'no verify logs in last 24h')"; fi

  total=$((total + 1))
  # v2: green = passing features whose latest evidence_association points at
  # a CANONICALLY VALID run log (validate_run_log returns valid:true), with
  # terminal.overall_result == passed. NOT counting .evidence[].exit_code=0
  # anymore — that was v1.
  #
  # Required: validate_run_log + staleness are sourced from script dir above,
  # so they are available even after cd.
  if [ "$HAS_JQ" = "1" ] && [ -f feature_list.json ] && command -v validate_run_log >/dev/null 2>&1; then
    local green=0 missing=0 corrupt=0 stale=0 no_assoc=0
    # Count all passing features (regardless of associations) and iterate
    # their latest evidence_associations[].run_id. Empty run_id → no_assoc.
    total_passing="$(jq '[.features[] | select(.status=="passing")] | length' feature_list.json 2>/dev/null)"
    [ -z "$total_passing" ] && total_passing=0
    local rid
    while IFS= read -r rid; do
      if [ -z "$rid" ]; then
        no_assoc=$((no_assoc + 1))
        continue
      fi
      local log_path=".harness/logs/runs/${rid}.ndjson"
      if [ ! -f "$log_path" ]; then
        missing=$((missing + 1))
        continue
      fi
      local validation
      if ! validation="$(validate_run_log "$rid" "." 2>/dev/null)"; then
        corrupt=$((corrupt + 1))
        continue
      fi
      local ores
      ores="$(jq -r 'select(.event=="run_completed") | .overall_result // empty' "$log_path" 2>/dev/null | tail -1)"
      if [ "$ores" != "passed" ]; then
        corrupt=$((corrupt + 1))
        continue
      fi
      # Staleness probe — any axis fires → stale
      local is_stale=0
      if command -v ev_is_stale_by_fingerprint >/dev/null 2>&1 && ev_is_stale_by_fingerprint "$rid" "." 2>/dev/null; then
        is_stale=1
      elif command -v ev_is_stale_by_config >/dev/null 2>&1 && ev_is_stale_by_config "$rid" "." 2>/dev/null; then
        is_stale=1
      elif command -v ev_is_stale_by_vcs >/dev/null 2>&1 && ev_is_stale_by_vcs "$rid" "." 2>/dev/null; then
        is_stale=1
      fi
      if [ "$is_stale" = "1" ]; then
        stale=$((stale + 1))
        continue
      fi
      green=$((green + 1))
    done < <(jq -r '.features[]
                     | select(.status=="passing")
                     | (.evidence_associations // [] | last) as $a
                     | if $a == null then "" else $a.run_id end' \
            feature_list.json 2>/dev/null | tr -d '\r')
    if [ "$total_passing" -gt 0 ]; then
      evidence+="$(record_evidence effectiveness "passing=$total_passing green=$green missing=$missing corrupt=$corrupt stale=$stale no_assoc=$no_assoc")"
      if [ "$green" -gt 0 ]; then
        p=$((p+1))
      fi
    else
      evidence+="$(record_evidence effectiveness 'no passing features in registry')"
    fi
  else
    evidence+="$(record_evidence effectiveness 'validate_run_log unavailable — cannot assess canonical run logs')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 6. Observability ----
audit_observability() {
  local p=0 total=0 evidence=""

  total=$((total + 1))
  if [ -f agent.log ]; then p=$((p+1)); evidence+="$(record_evidence existence 'agent.log present')"
  else evidence+="$(record_evidence existence 'agent.log missing')"; fi

  total=$((total + 1))
  local has_close=0
  if [ -f agent.log ] && grep -q '"CLOSE"' agent.log 2>/dev/null; then has_close=1; fi
  if [ "$has_close" = "1" ]; then p=$((p+1)); evidence+="$(record_evidence completeness 'agent.log has CLOSE marker')"
  else evidence+="$(record_evidence completeness 'agent.log missing CLOSE marker')"; fi

  total=$((total + 1))
  local ndjson_count=0
  if [ -f agent.log ]; then ndjson_count="$(grep -c '^{' agent.log 2>/dev/null | head -1)"; fi
  if [ "$ndjson_count" -gt 1 ]; then p=$((p+1)); evidence+="$(record_evidence execution "agent.log has $ndjson_count ndjson lines")"
  else evidence+="$(record_evidence execution "agent.log has $ndjson_count ndjson lines")"; fi

  total=$((total + 1))
  if [ -f agent.log ] && [ "$(recent_within_hours agent.log 168)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence recency 'agent.log updated within 7 days')"
  else evidence+="$(record_evidence recency 'agent.log stale or missing')"; fi

  total=$((total + 1))
  local last_line=""
  if [ -f agent.log ]; then last_line="$(tail -1 agent.log 2>/dev/null)"; fi
  if echo "$last_line" | grep -q '"CLOSE"'; then p=$((p+1)); evidence+="$(record_evidence effectiveness 'last agent.log line is CLOSE (clean exit)')"
  else evidence+="$(record_evidence effectiveness 'last agent.log line is not CLOSE')"; fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 7. Handoff/Automation ----
audit_handoff() {
  local p=0 total=0 evidence=""

  total=$((total + 1))
  if [ -f session-handoff.md ]; then p=$((p+1)); evidence+="$(record_evidence existence 'session-handoff.md present')"
  else evidence+="$(record_evidence existence 'session-handoff.md missing')"; fi

  total=$((total + 1))
  if [ -f clean-state-checklist.md ]; then p=$((p+1)); evidence+="$(record_evidence completeness 'clean-state-checklist.md present')"
  else evidence+="$(record_evidence completeness 'clean-state-checklist.md missing')"; fi

  total=$((total + 1))
  if [ -x checklist.sh ]; then p=$((p+1)); evidence+="$(record_evidence execution 'checklist.sh executable')"
  else evidence+="$(record_evidence execution 'checklist.sh not executable')"; fi

  total=$((total + 1))
  if [ -f session-handoff.md ] && [ "$(recent_within_hours session-handoff.md 168)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence recency 'session-handoff.md updated within 7 days')"
  else evidence+="$(record_evidence recency 'session-handoff.md stale')"; fi

  total=$((total + 1))
  if [ -f loop.sh ]; then
    local loop_lines
    loop_lines="$(wc -l < loop.sh 2>/dev/null | tr -d ' ')"
    if [ "$loop_lines" -ge 5 ]; then
      p=$((p+1))
      evidence+="$(record_evidence effectiveness "loop.sh present with $loop_lines lines (substantive)")"
    else
      evidence+="$(record_evidence effectiveness "loop.sh present but only $loop_lines lines (insufficient)")"
    fi
  else
    evidence+="$(record_evidence effectiveness 'loop.sh missing (manual handoff required)')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# --- Run all subsystems -------------------------------------------------------
run_and_split() {
  local label="$1"
  local block
  block="$("$@" 2>/dev/null)"
  SCORE_LINE="$(printf '%s\n' "$block" | head -1)"
  EVIDENCE_LINES="$(printf '%s\n' "$block" | tail -n +2)"
}

run_and_split audit_knowledge;       K_SCORE="$SCORE_LINE";       K_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_environment;     E_SCORE="$SCORE_LINE";       E_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_progress;        P_SCORE="$SCORE_LINE";       P_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_scope;           S_SCORE="$SCORE_LINE";       S_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_verification;    V_SCORE="$SCORE_LINE";       V_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_observability;   O_SCORE="$SCORE_LINE";       O_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_handoff;         H_SCORE="$SCORE_LINE";       H_EVIDENCE="$EVIDENCE_LINES"

TOTAL=$((K_SCORE + E_SCORE + P_SCORE + S_SCORE + V_SCORE + O_SCORE + H_SCORE))

# --- Output -------------------------------------------------------------------
echo "Harness Audit: $PROJECT_NAME"
[ -n "$SNAPSHOT_AT" ] && echo "Snapshot at: $SNAPSHOT_AT"
echo "════════════════════════════════════════════"
printf "  %-15s %s\n" "Subsystem" "Score"
printf "  %-15s %s\n" "---------------" "-----"
printf "  %-15s %d/3\n" "Knowledge"      "$K_SCORE"
printf "  %-15s %d/3\n" "Environment"    "$E_SCORE"
printf "  %-15s %d/3\n" "Progress"       "$P_SCORE"
printf "  %-15s %d/3\n" "Scope/Feature"  "$S_SCORE"
printf "  %-15s %d/3\n" "Verification"   "$V_SCORE"
printf "  %-15s %d/3\n" "Observability"  "$O_SCORE"
printf "  %-15s %d/3\n" "Handoff/Auto"   "$H_SCORE"
echo ""
echo "────────────────────────────────────────────"
echo "Total: $TOTAL/21"
echo ""

if [ "${HARNESS_VERBOSE:-0}" = "1" ]; then
  echo "Evidence per score:"
  echo ""
  echo "[Knowledge]"
  printf '%s\n' "$K_EVIDENCE"
  echo "[Environment]"
  printf '%s\n' "$E_EVIDENCE"
  echo "[Progress]"
  printf '%s\n' "$P_EVIDENCE"
  echo "[Scope/Feature]"
  printf '%s\n' "$S_EVIDENCE"
  echo "[Verification]"
  printf '%s\n' "$V_EVIDENCE"
  echo "[Observability]"
  printf '%s\n' "$O_EVIDENCE"
  echo "[Handoff/Automation]"
  printf '%s\n' "$H_EVIDENCE"
fi