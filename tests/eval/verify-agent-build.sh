#!/bin/bash
# Exact Agent build allowlist check shared by the runner and attester.

set -euo pipefail
[ "$#" -eq 4 ] || { echo "eval-build: usage: verify-agent-build.sh <policy> <agent> <version> <sha256>" >&2; exit 2; }
policy="$1"; agent="$2"; version="$3"; digest="${4,,}"
[ -f "$policy" ] && [ ! -L "$policy" ] || { echo "eval-build: policy missing or unsafe" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "eval-build: jq is required" >&2; exit 2; }
jq -e --arg agent "$agent" --arg version "$version" --arg digest "$digest" '
  [.agents[$agent].approved_builds[]?
    | select(.cli_version == $version and (.sha256 | ascii_downcase) == $digest)]
  | length == 1
' "$policy" >/dev/null
