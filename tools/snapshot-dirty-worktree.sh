#!/bin/bash
# snapshot-dirty-worktree.sh — §15.3 / §5-b.5 dirty-worktree manifest snapshot + gate
#
# Local-only developer-machine gate (NEVER CI): records the protected dirty path
# set of a git worktree — tracked-but-modified and untracked files that
# `git diff <base>..<head>` cannot see — then verifies later that immutable
# contract files AND non-Harness user dirty files stayed byte-equal, while
# allowing NEW paths and CONTROLLED content changes inside the mutable runtime
# namespace (P0-5): existing run NDJSON byte-equal, reviewer verdict artifacts
# append-only (recorded bytes must prefix the current file), feature_list.json
# revision must advance by exactly +1, and only progress/state files may differ
# freely.
#
# Subcommands:
#   snapshot [out_file] [project_dir]
#       Materialise the current dirty set into <out_file> as canonical JSONL.
#       out_file relative to project_dir (default:
#       tests/fixtures/dirty-worktree-manifest.jsonl). project_dir defaults to
#       the repo root that contains this tool.
#   check [recorded] [project_dir]
#       Re-enumerate and compare against <recorded> (same defaults). Prints the
#       JSON result {valid, violations, allowed_new, new_non_mutable,
#       appended_mutable, feature_revision_advanced, content_changed_mutable}
#       and exits:
#         0  valid (immutable + user paths byte-equal; mutable changes follow
#            the P0-5 append/revision rules; no new non-mutable paths)
#         1  invalid (violations found)
#         2  tool error (not a git repo, jq missing, emit failed)
#
# Self-reference exclusion (spec §15.5): the recorded manifest file itself and
# THIS tool are excluded from the enumerated set — the manifest never tracks
# itself.
#
# Requires: bash, jq, git, sha256sum (or shasum -a 256).
#
# Usage examples (run from the repo root):
#   bash tools/snapshot-dirty-worktree.sh snapshot      # write the fixture
#   bash tools/snapshot-dirty-worktree.sh check         # gate vs the fixture

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../core/lib/dirty-worktree-manifest.sh
source "$ROOT_DIR/core/lib/dirty-worktree-manifest.sh"

DEFAULT_FIXTURE="tests/fixtures/dirty-worktree-manifest.jsonl"
DEFAULT_TOOL="tools/snapshot-dirty-worktree.sh"

usage() {
  cat <<'EOF'
Usage: snapshot-dirty-worktree.sh <snapshot|check> [out_file|recorded] [project_dir]

  snapshot [out_file] [project_dir]
      materialise current dirty set into out_file
      (default: tests/fixtures/dirty-worktree-manifest.jsonl)
  check [recorded] [project_dir]
      compare current dirty set against the recorded manifest
      (default: tests/fixtures/dirty-worktree-manifest.jsonl)
EOF
}

# resolve_against <path> <base>: absolute paths pass through untouched
resolve_against() {
  local p="$1" base="$2"
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$base" "$p" ;;
  esac
}

# cmd_snapshot [out_file] [project_dir]
cmd_snapshot() {
  local out_arg="${1:-$DEFAULT_FIXTURE}"
  local proj="${2:-$ROOT_DIR}"
  local out_file rel_out
  out_file="$(resolve_against "$out_arg" "$proj")"
  # self-reference excludes are repo-relative paths (git status is repo-relative)
  rel_out="$(printf '%s' "$out_arg" | sed 's#^\./##')"
  if ! dwm_emit_manifest "$proj" "$out_file" "$rel_out" "$DEFAULT_TOOL"; then
    echo "snapshot-dirty-worktree: emit failed (rc=$?)" >&2
    return 2
  fi
  local n
  n="$(grep -vc '^$' "$out_file" 2>/dev/null || echo 0)"
  echo "Wrote dirty-worktree manifest to $out_file ($n records)"
  return 0
}

# cmd_check [recorded] [project_dir]
cmd_check() {
  local rec_arg="${1:-$DEFAULT_FIXTURE}"
  local proj="${2:-$ROOT_DIR}"
  local rec_file rel_rec res
  rec_file="$(resolve_against "$rec_arg" "$proj")"
  # self-reference excludes are repo-relative paths (git status is repo-relative)
  rel_rec="$(printf '%s' "$rec_arg" | sed 's#^\./##')"
  if ! res="$(dwm_compare_manifest "$proj" "$rec_file" "$rel_rec" "$DEFAULT_TOOL")"; then
    if printf '%s' "$res" | jq -e '.reason == "emit_failed"' >/dev/null 2>&1; then
      printf '%s\n' "$res"
      return 2
    fi
    printf '%s\n' "$res"
    return 1
  fi
  printf '%s\n' "$res"
  return 0
}

CMD="${1:-help}"
shift || true

case "$CMD" in
  snapshot) cmd_snapshot "$@" ;;
  check)    cmd_check "$@" ;;
  help|--help|-h) usage; exit 0 ;;
  *) echo "snapshot-dirty-worktree: unknown command '$CMD'" >&2; usage >&2; exit 2 ;;
esac
