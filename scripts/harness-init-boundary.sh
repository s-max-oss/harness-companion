#!/bin/bash
# Consent boundary for Agent-guided init. This script does not decide what the
# user wants and never writes target files itself. It makes the already-made
# approve/cancel decision observable and delegates only an approved Brief to
# the deterministic executor.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTOR="$SCRIPT_DIR/harness-init.sh"

usage() {
  cat >&2 <<'EOF'
Usage: harness-init-boundary.sh <target> --decision approve|reject|cancel [executor args...]

approve delegates the remaining arguments to harness-init.sh.
reject/cancel return without invoking the executor or writing the target.
EOF
  exit 2
}

[ "$#" -ge 3 ] || usage
TARGET="$1"
shift
[ "${1:-}" = "--decision" ] || usage
DECISION="${2:-}"
shift 2

case "$DECISION" in
  approve)
    [ -x "$EXECUTOR" ] || {
      echo "error: guided init executor is unavailable" >&2
      exit 2
    }
    exec bash "$EXECUTOR" "$TARGET" "$@"
    ;;
  reject|cancel)
    [ "$#" -eq 0 ] || {
      echo "error: $DECISION does not accept executor arguments" >&2
      exit 2
    }
    printf 'Guided init %s; target unchanged.\n' "$DECISION"
    exit 0
    ;;
  *) usage ;;
esac
