#!/bin/bash
# core/lib/json-encode.sh — Cross-platform JSON string encoder (Phase 5b)
#
# Provides `hc_json_encode_string` which encodes a string as a JSON string
# literal (e.g., `hello "world"` -> `"hello \"world\""`). Used by adapters
# that must wrap plain text into JSON envelopes without depending on a
# single language runtime.
#
# Encoder selection (first available wins, with REAL EXECUTION PROBE):
#   1. python3       (cross-platform, pre-installed on most dev systems)
#   2. python        (Windows Python launcher alias)
#   3. py -3         (Windows Python launcher explicit version)
#   4. jq -Rs        (jqlang, often bundled with Git for Windows via WinGet)
#   5. powershell    (Windows-native, ConvertTo-Json -Compress)
#
# Each encoder must pass a real execution probe (not just `command -v`)
# because on Windows the py.exe launcher can exist on PATH even when no
# Python interpreter is installed -- it prints "No installed Python found!"
# and exits non-zero. A PATH-existence check would falsely select py and
# every subsequent json call would fail.
#
# If no runtime passes its probe, the helper prints an empty string AND
# emits a diagnostic to stderr naming the encoders that were tried.
# Callers MUST check the return value and fail-open if empty.
#
# No business logic lives here. This is purely a string-encoding shim.

# hc_json_encoder_available <name>
#   Returns 0 if the named encoder is callable AND can execute a trivial
#   JSON round-trip probe. Returns 1 otherwise -- including when the
#   binary exists but the runtime is broken (e.g. py.exe with no Python).
hc_json_encoder_available() {
  case "$1" in
    python3)
      command -v python3 >/dev/null 2>&1 || return 1
      python3 -c 'import json,sys; print(json.dumps("ok"))' >/dev/null 2>&1 || return 1
      ;;
    python)
      command -v python >/dev/null 2>&1 || return 1
      python -c 'import json,sys; print(json.dumps("ok"))' >/dev/null 2>&1 || return 1
      ;;
    py)
      command -v py >/dev/null 2>&1 || return 1
      py -3 -c 'import json,sys; print(json.dumps("ok"))' >/dev/null 2>&1 || return 1
      ;;
    jq)
      command -v jq >/dev/null 2>&1 || return 1
      echo '{}' | jq -e . >/dev/null 2>&1 || return 1
      ;;
    powershell)
      command -v powershell >/dev/null 2>&1 || return 1
      powershell -NoProfile -NonInteractive -Command \
        '"ok" | ConvertTo-Json -Compress | Out-Null' >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

# hc_json_runtime — print first available JSON-aware runtime.
# Shared by json-encode.sh (write) and json-helpers.sh (read) so they
# cannot disagree about what JSON support exists on this machine.
hc_json_runtime() {
  if hc_json_encoder_available python3;   then echo "python3";    return; fi
  if hc_json_encoder_available python;    then echo "python";     return; fi
  if hc_json_encoder_available py;        then echo "py";         return; fi
  if hc_json_encoder_available jq;        then echo "jq";         return; fi
  if hc_json_encoder_available powershell; then echo "powershell"; return; fi
  echo ""
}

# hc_json_encode_string <text>
#   Writes the JSON-string-encoded form of <text> to stdout.
#   On no available encoder: writes "" to stdout and diagnostic to stderr.
#   Returns 0 on success, 1 on failure (caller should fail-open).
hc_json_encode_string() {
  local text="$1"
  if hc_json_encoder_available python3; then
    printf '%s' "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null && return 0
  fi
  if hc_json_encoder_available python; then
    printf '%s' "$text" | python -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null && return 0
  fi
  if hc_json_encoder_available py; then
    printf '%s' "$text" | py -3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null && return 0
  fi
  if hc_json_encoder_available jq; then
    printf '%s' "$text" | jq -Rs . 2>/dev/null && return 0
  fi
  if hc_json_encoder_available powershell; then
    # PowerShell: write input to a file to avoid stdin quoting hell,
    # then have PS read it via Get-Content -Raw and emit the JSON form.
    # Get-Content preserves all bytes (including UTF-8) without mangling.
    local tmpfile="${TMPDIR:-/tmp}/hc_json_in.$$"
    printf '%s' "$text" > "$tmpfile"
    local encoded
    encoded="$(powershell -NoProfile -NonInteractive -Command \
      "Get-Content -LiteralPath '$tmpfile' -Raw | ConvertTo-Json -Compress" \
      2>/dev/null || true)"
    rm -f "$tmpfile"
    if [ -n "$encoded" ]; then
      printf '%s' "$encoded"
      return 0
    fi
  fi
  # No encoder available — emit diagnostic, return 1.
  printf 'hc_json_encode_string: no encoder available (tried python3, python, py -3, jq, powershell)\n' >&2
  return 1
}

# hc_json_encoder_name — print the name of the encoder that will be used
hc_json_encoder_name() {
  hc_json_runtime
}