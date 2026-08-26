#!/bin/bash
# harness-verdict.sh — Append-only Reviewer verdict artifact CLI
#
# Wraps core/lib/verdict-artifact.sh for recording and validating independent
# Reviewer verdicts. Feature verdicts, phase verdicts, and maintenance verdicts
# use SEPARATE schemas (kind split) and live in separate append-only files:
#   .harness/reviews/feature/<feature_id>.jsonl
#   .harness/reviews/phase/<phase>.jsonl
#   .harness/reviews/maintenance/<feature_id>.jsonl
#
# Usage:
#   bash harness-verdict.sh append <project_dir> <feature|phase|maintenance> <id> \
#       --verdict PASS|FAIL|BLOCKER \
#       --run <run_id>          # verification run id (REQUIRED for PASS) \
#       --base <sha> --head <sha>   # 40- or 64-hex Git OIDs \
#       [--host subagent|manual]    # default: subagent \
#       [--checked spec-ref,test-id,...] \
#       [--reason "justification"] \
#       [--feature-ids A,B,...]     # phase records only \
#       [--phase N]                 # feature records: feature's phase (1..5)
#
#   bash harness-verdict.sh validate <project_dir> <feature|phase|maintenance> <id>
#   bash harness-verdict.sh next <project_dir> <feature|phase|maintenance> <id>
#
# Append semantics: each re-review appends ONE new record with attempt =
# previous + 1. Existing records are never rewritten, truncated, or deleted.
# The record is fully validated before appending (attempt continuity, OID
# format, PASS→non-empty run_id, valid run, real git head_sha).
#
# Exit codes:
#   0  success (append prints the appended record; validate prints JSON result)
#   1  invalid usage / validation failure / append refused
#   2  required dependency missing (jq, lib)
#
# Requires: bash, jq, git (for the head_sha object check).

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/verdict-artifact.sh
source "$SKILL_DIR/lib/verdict-artifact.sh"

# ---- helpers ---------------------------------------------------------------

v_usage() {
  cat <<'EOF'
Usage: harness-verdict.sh <command> [args...]

Commands:
  append <project_dir> <feature|phase|maintenance> <id> --verdict PASS|FAIL|BLOCKER \
      --run <run_id> --base <sha> --head <sha> \
      [--host subagent|manual] [--checked a,b] [--reason "..."] \
      [--feature-ids A,B] [--phase N]
  validate <project_dir> <feature|phase|maintenance> <id>
  next <project_dir> <feature|phase|maintenance> <id>

Append-only: attempt = previous + 1; records are never rewritten or deleted.
PASS verdicts MUST bind a non-empty verification run_id.
base_sha/head_sha are 40- or 64-hex Git OIDs (head_sha must be a real object).
EOF
}

# cmd_append <project_dir> <kind> <id> [flags...]
cmd_append() {
  local project_dir="$1" kind="$2" id="$3"
  shift 3

  local verdict="" run_id="" base_sha="" head_sha="" host="subagent" checked="" reason="" feature_ids="" phase=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verdict)   verdict="$2"; shift 2 ;;
      --run)       run_id="$2"; shift 2 ;;
      --base)      base_sha="$2"; shift 2 ;;
      --head)      head_sha="$2"; shift 2 ;;
      --host)      host="$2"; shift 2 ;;
      --checked)   checked="$2"; shift 2 ;;
      --reason)    reason="$2"; shift 2 ;;
      --feature-ids) feature_ids="$2"; shift 2 ;;
      --phase)     phase="$2"; shift 2 ;;
      *) echo "harness-verdict: unknown option '$1'" >&2; v_usage >&2; return 1 ;;
    esac
  done

  if [ "$verdict" != "PASS" ] && [ "$verdict" != "FAIL" ] && [ "$verdict" != "BLOCKER" ]; then
    echo "harness-verdict: --verdict required (PASS|FAIL|BLOCKER)" >&2
    return 1
  fi
  if [ -z "$base_sha" ] || [ -z "$head_sha" ]; then
    echo "harness-verdict: --base and --head (Git OIDs) required" >&2
    return 1
  fi
  if [ "$host" != "subagent" ] && [ "$host" != "manual" ]; then
    echo "harness-verdict: --host must be subagent|manual" >&2
    return 1
  fi

  local checked_json
  if [ -n "$checked" ]; then
    checked_json="$(printf '%s' "$checked" | jq -R -c 'split(",") | map(select(length > 0))' 2>/dev/null)"
  else
    checked_json="[]"
  fi

  local now record
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

  if [ "$kind" = "feature" ]; then
    if [ -z "$phase" ]; then
      echo "harness-verdict: feature records require --phase <1..5>" >&2
      return 1
    fi
    record="$(jq -n --arg kind "$kind" --arg fid "$id" --argjson ph "$phase" \
      --arg verdict "$verdict" --arg base "$base_sha" --arg head "$head_sha" \
      --arg run "$run_id" --arg host "$host" --argjson checked "$checked_json" \
      --arg reason "$reason" --arg now "$now" \
      '{schema_version:1, kind:$kind, feature_id:$fid, phase:$ph,
        verdict:$verdict, base_sha:$base, head_sha:$head,
        run_id:($run | if . == "" then null else . end),
        reviewer_host:$host, checked:$checked, reason:$reason, recorded_at:$now}')"
  elif [ "$kind" = "maintenance" ] || [ "$kind" = "reviewer" ]; then
    record="$(jq -n --arg kind "$kind" --arg fid "$id" \
      --arg verdict "$verdict" --arg base "$base_sha" --arg head "$head_sha" \
      --arg run "$run_id" --arg host "$host" --argjson checked "$checked_json" \
      --arg reason "$reason" --arg now "$now" \
      '{schema_version:1, kind:$kind, feature_id:$fid,
        verdict:$verdict, base_sha:$base, head_sha:$head,
        run_id:($run | if . == "" then null else . end),
        reviewer_host:$host, checked:$checked, reason:$reason, recorded_at:$now}')"
  else
    if [ -z "$feature_ids" ]; then
      echo "harness-verdict: phase records require --feature-ids" >&2
      return 1
    fi
    record="$(printf '%s' "$feature_ids" | jq -R -c 'split(",") | map(select(length > 0))' 2>/dev/null \
      | jq --arg kind "$kind" --argjson ph "$id" \
           --arg verdict "$verdict" --arg base "$base_sha" --arg head "$head_sha" \
           --arg run "$run_id" --arg host "$host" --argjson checked "$checked_json" \
           --arg reason "$reason" --arg now "$now" \
        '{schema_version:1, kind:$kind, phase:$ph, feature_ids:.,
          verdict:$verdict, base_sha:$base, head_sha:$head,
          run_id:($run | if . == "" then null else . end),
          reviewer_host:$host, checked:$checked, reason:$reason, recorded_at:$now}')"
  fi

  local appended
  if ! appended="$(verdict_append_record "$project_dir" "$kind" "$id" "$record")"; then
    echo "harness-verdict: append refused (see validator stderr above)" >&2
    return 1
  fi
  printf '%s\n' "$appended"
  return 0
}

# ---- main dispatch ----------------------------------------------------------
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  append)    cmd_append "$@" ;;
  validate)  verdict_validate_file "$1" "$2" "$3" ;;
  next)      verdict_next_attempt "$1" "$2" "$3"; echo ;;
  help|--help|-h) v_usage; exit 0 ;;
  *) echo "Error: unknown command '$COMMAND'" >&2; v_usage >&2; exit 1 ;;
esac
