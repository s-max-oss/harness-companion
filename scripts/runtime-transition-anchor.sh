#!/bin/bash
# Explicit, append-only runtime-manifest trust-anchor transition.
# Usage: bash scripts/runtime-transition-anchor.sh [project_dir] [new_head]
#        bash scripts/runtime-transition-anchor.sh [project_dir] [new_head] --bootstrap-sha <sha256>

set -uo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
TARGET="${2:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)}"
if [ -z "$ROOT" ] || [ -z "$TARGET" ]; then
  echo "runtime-transition-anchor: project and target HEAD are required" >&2
  exit 2
fi
ROOT="$(cd "$ROOT" && pwd)" || exit 2

# shellcheck source=../core/lib/lock-registry.sh
. "$ROOT/core/lib/lock-registry.sh"
# shellcheck source=../core/lib/runtime-manifest.sh
. "$ROOT/core/lib/runtime-manifest.sh"

TARGET="$(git -C "$ROOT" rev-parse "$TARGET^{commit}" 2>/dev/null)" || {
  echo "runtime-transition-anchor: target is not a commit" >&2
  exit 1
}
CURRENT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || exit 1
if [ "$TARGET" != "$CURRENT" ]; then
  echo "runtime-transition-anchor: target must be current HEAD ($CURRENT)" >&2
  exit 1
fi
MF="$(runtime_manifest_path "$ROOT")"
_runtime_acquire "$ROOT" || { echo "runtime-transition-anchor: cannot acquire runtime lock" >&2; exit 1; }
BOOTSTRAP_TOKEN="${LOCK_REGISTRY_TOKEN:-}"
BOOTSTRAP_RC=0
BEFORE_SHA="$(_runtime_file_sha256 "$MF")" || BOOTSTRAP_RC=1
BEFORE_SIZE="$(wc -c < "$MF" 2>/dev/null | tr -d '[:space:]')"
FROM_ANCHOR="$(_runtime_effective_anchor "$MF" 2>/dev/null || true)"
PENDING="$(_runtime_init_pending_path "$ROOT" 2>/dev/null || true)"
if [ "$BOOTSTRAP_RC" -eq 0 ] && _runtime_verify_registry_anchor "$ROOT" "$MF"; then
  # A crash after the ref/index/receipt commit but before marker removal is a
  # committed bootstrap, not an error. Validate that marker against the
  # anchored effective value, then finalize it before any transition changes
  # that value.
  if [ -n "$PENDING" ] && { [ -e "$PENDING" ] || [ -L "$PENDING" ]; }; then
    if _runtime_init_pending_valid "$ROOT" "$FROM_ANCHOR" explicit "$BEFORE_SHA"; then
      rm -f "$PENDING" || BOOTSTRAP_RC=1
    else
      echo "runtime-transition-anchor: invalid marker beside complete trusted anchor" >&2
      BOOTSTRAP_RC=1
    fi
  fi
elif [ "$BOOTSTRAP_RC" -eq 0 ]; then
  if [ "${3:-}" != "--bootstrap-sha" ] || [ -z "${4:-}" ] \
     || [ "$BEFORE_SHA" != "$4" ] || [ -z "$FROM_ANCHOR" ]; then
    echo "runtime-transition-anchor: trusted anchor missing; explicit --bootstrap-sha of current bytes is required" >&2
    BOOTSTRAP_RC=1
  else
    PENDING="$(_runtime_init_pending_path "$ROOT")" || BOOTSTRAP_RC=1
    if [ "$BOOTSTRAP_RC" -eq 0 ] && { [ -e "$PENDING" ] || [ -L "$PENDING" ]; }; then
      if ! _runtime_init_pending_valid "$ROOT" "$FROM_ANCHOR" explicit "$BEFORE_SHA"; then
        echo "runtime-transition-anchor: invalid bootstrap recovery marker" >&2
        BOOTSTRAP_RC=1
      elif git -C "$ROOT" show-ref --verify --quiet "$(_runtime_anchor_ref)" 2>/dev/null; then
        _runtime_recover_generated_anchor "$ROOT" "$MF" "$FROM_ANCHOR" explicit "$BEFORE_SHA" || BOOTSTRAP_RC=1
      else
        _runtime_remove_anchor_state "$ROOT" || BOOTSTRAP_RC=1
      fi
    fi
    if [ "$BOOTSTRAP_RC" -eq 0 ] && ! _runtime_verify_registry_anchor "$ROOT" "$MF"; then
      if [ ! -e "$PENDING" ] && ! _runtime_begin_init_pending "$ROOT" "$FROM_ANCHOR" explicit "$BEFORE_SHA"; then
        BOOTSTRAP_RC=1
      fi
      [ "$BOOTSTRAP_RC" -ne 0 ] || _runtime_bootstrap_registry_anchor "$ROOT" "$MF" "$4" explicit || BOOTSTRAP_RC=1
    fi
    if [ "$BOOTSTRAP_RC" -eq 0 ]; then
      rm -f "$PENDING" || BOOTSTRAP_RC=1
    fi
  fi
fi
RELEASE_RC=0
_runtime_release "$ROOT" || RELEASE_RC=$?
if [ "$RELEASE_RC" -eq 8 ]; then
  echo "runtime-transition-anchor: bootstrap committed; private lock cleanup incomplete" >&2
elif [ "$RELEASE_RC" -ne 0 ]; then
  BOOTSTRAP_RC=1
fi
if [ "$BOOTSTRAP_RC" -ne 0 ]; then exit 1; fi
if [ "${3:-}" = "--bootstrap-sha" ]; then
  echo "runtime-transition-anchor: bootstrapped/verified exact registry sha256 $4"
fi
runtime_transition_anchor "$ROOT" "$TARGET" || exit 1
AFTER_SIZE="$(wc -c < "$MF" | tr -d '[:space:]')"
EFFECTIVE="$(_runtime_effective_anchor "$MF")"
if [ "$EFFECTIVE" != "$TARGET" ] || [ "$AFTER_SIZE" -lt "$BEFORE_SIZE" ]; then
  echo "runtime-transition-anchor: postcondition failed" >&2
  exit 1
fi
PREFIX_SHA="$(head -c "$BEFORE_SIZE" "$MF" | _runtime_stdin_sha256)" || exit 1
if [ "$PREFIX_SHA" != "$BEFORE_SHA" ]; then
  echo "runtime-transition-anchor: historical prefix changed" >&2
  exit 1
fi
echo "runtime-transition-anchor: PASS ($TARGET; historical prefix preserved)"
