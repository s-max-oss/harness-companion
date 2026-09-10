#!/bin/bash
# Runtime-evidence helpers for core/lib/dirty-worktree-manifest.sh.

dwm_runtime_artifact_kind() {
  local p="$1"
  case "$p" in
    ".harness/logs/runs/"*.ndjson) printf '%s\n' ndjson; return 0 ;;
    ".harness/logs/runs/"*.log) printf '%s\n' log; return 0 ;;
    ".harness/reviews/"*.jsonl) printf '%s\n' verdict; return 0 ;;
    ".harness/acceptance/"*/acceptance.json) printf '%s\n' acceptance; return 0 ;;
    ".harness/acceptance/"*/A-G.log) printf '%s\n' log; return 0 ;;
  esac
  if [[ "$p" =~ ^tests/eval/candidates/[A-Za-z0-9][A-Za-z0-9_-]*\.[0-9]+\.[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+\.(transcript\.jsonl|tree\.sha256|subject-events\.jsonl|reviewer-events\.jsonl|turn-trees\.jsonl|evaluator-events\.jsonl|reviewer-output\.json|objective-checks\.jsonl|project-brief\.json|isolation\.json|json)$ ]]; then
    printf '%s\n' eval_candidate
    return 0
  fi
  if [[ "$p" =~ ^tests/eval/results/[A-Za-z0-9][A-Za-z0-9_-]*\.[0-9]+\.[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+\.(transcript\.jsonl|tree\.sha256|subject-events\.jsonl|reviewer-events\.jsonl|turn-trees\.jsonl|evaluator-events\.jsonl|reviewer-output\.json|objective-checks\.jsonl|project-brief\.json|isolation\.json|attestation\.sig|json)$ ]]; then
    printf '%s\n' eval_result
    return 0
  fi
  case "$p" in tests/eval/candidates/*|tests/eval/results/*) printf '%s\n' eval_invalid; return 0 ;; esac
  return 1
}

# Uses the caller's dynamically scoped arrays. File-backed jq inputs avoid the
# Windows command-line length limit for large immutable evidence collections.
dwm_finalize_result_streaming() {
  local result="$1" mv_file am_file fa_file ccm_file final jq_rc
  mv_file="$(mktemp)" || return 2
  am_file="$(mktemp)" || { rm -f "$mv_file"; return 2; }
  fa_file="$(mktemp)" || { rm -f "$mv_file" "$am_file"; return 2; }
  ccm_file="$(mktemp)" || { rm -f "$mv_file" "$am_file" "$fa_file"; return 2; }
  printf '%s\n' "${mutable_violations[@]}" | jq -c 'select(length > 0)' >"$mv_file" || {
    rm -f "$mv_file" "$am_file" "$fa_file" "$ccm_file"; return 2;
  }
  printf '%s\n' "${appended_mutable[@]}" | jq -R -c 'select(length > 0)' >"$am_file"
  printf '%s\n' "${feature_advanced[@]}" | jq -R -c 'select(length > 0)' >"$fa_file"
  printf '%s\n' "${content_changed_mutable[@]}" | jq -R -c 'select(length > 0)' >"$ccm_file"
  final="$(printf '%s\n' "$result" | jq -c \
    --slurpfile mv "$mv_file" --slurpfile am "$am_file" \
    --slurpfile fa "$fa_file" --slurpfile ccm "$ccm_file" \
    '.violations = (.violations + $mv) | .appended_mutable = $am | .feature_revision_advanced = $fa | .content_changed_mutable = $ccm | .valid = ((.violations | length) == 0 and (.new_non_mutable | length) == 0)')"
  jq_rc=$?
  rm -f "$mv_file" "$am_file" "$fa_file" "$ccm_file"
  [ "$jq_rc" -eq 0 ] || return 2
  printf '%s\n' "$final"
}
