#!/bin/bash
# Exact Agent build allowlist check shared by the runner and attester.

set -euo pipefail
if [ "$#" -eq 4 ]; then
  policy="$1"; agent="$2"; version="$3"; component=""; digest="${4,,}"
elif [ "$#" -eq 5 ]; then
  policy="$1"; agent="$2"; version="$3"; component="$4"; digest="${5,,}"
else
  echo "eval-build: usage: verify-agent-build.sh <policy> <agent> <version> [<component>] <sha256>" >&2
  exit 2
fi
[ -f "$policy" ] && [ ! -L "$policy" ] || { echo "eval-build: policy missing or unsafe" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "eval-build: jq is required" >&2; exit 2; }
if [ -z "$component" ]; then
  jq -e --arg agent "$agent" --arg version "$version" --arg digest "$digest" '
    [.agents[$agent].approved_builds[]?
      | select(.cli_version == $version and (.sha256 | ascii_downcase) == $digest)]
    | length == 1
  ' "$policy" >/dev/null
else
  jq -e --arg agent "$agent" --arg version "$version" --arg component "$component" --arg digest "$digest" '
    [.agents[$agent].approved_builds[]?
      | select(.cli_version == $version)
      | .components[$component]?
      | select((.sha256 | ascii_downcase) == $digest)]
    | length == 1
  ' "$policy" >/dev/null
fi
