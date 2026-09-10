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
    # Windows Codex launches PowerShell through a native -Command wrapper. In
    # that transport, a static single-quoted JSON producer can arrive with one
    # extra JSON-string escaping layer (for example {\"goal\":...}). Accept
    # exactly that representation only when the decoded value is a JSON object;
    # all other malformed input is passed through for the executor to reject.
    if printf '%s\n' "$@" | grep -Fxq -- '--brief-stdin'; then
      brief_payload="$(cat)" || brief_payload=""
      if printf '%s' "$brief_payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
        normalized_brief="$brief_payload"
      else
        normalized_brief="$(printf '"%s"' "$brief_payload" | jq -ce 'fromjson | select(type == "object")' 2>/dev/null)" || normalized_brief="$brief_payload"
      fi
      printf '%s' "$normalized_brief" | bash "$EXECUTOR" "$TARGET" "$@"
      exit $?
    fi
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
