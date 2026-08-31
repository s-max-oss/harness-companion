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
    # Guided approval must carry exactly one resolved Brief. Never fall through
    # to the executor's intentionally preserved legacy placeholder mode.
    brief_inputs=0
    expect_brief_path=false
    for arg in "$@"; do
      if [ "$expect_brief_path" = true ]; then
        [ -n "$arg" ] || {
          echo "error: --brief requires a non-empty path" >&2
          exit 2
        }
        expect_brief_path=false
        continue
      fi
      case "$arg" in
        --brief)
          brief_inputs=$((brief_inputs + 1))
          expect_brief_path=true
          ;;
        --brief=*)
          [ -n "${arg#--brief=}" ] || {
            echo "error: --brief requires a non-empty path" >&2
            exit 2
          }
          brief_inputs=$((brief_inputs + 1))
          ;;
        --brief-stdin)
          brief_inputs=$((brief_inputs + 1))
          ;;
      esac
    done
    [ "$expect_brief_path" = false ] || {
      echo "error: --brief requires a path" >&2
      exit 2
    }
    [ "$brief_inputs" -eq 1 ] || {
      echo "error: approve requires exactly one resolved Brief (--brief or --brief-stdin)" >&2
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
