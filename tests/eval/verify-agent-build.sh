#!/bin/bash
# Exact Agent build allowlist check shared by the runner and attester.

set -euo pipefail
if [ "${1:-}" = "--verify-bundle-evidence" ]; then
  [ "$#" -eq 3 ] || { echo "eval-build: usage: verify-agent-build.sh --verify-bundle-evidence <policy> <candidate>" >&2; exit 2; }
  policy="$2"; candidate="$3"
  [ -f "$policy" ] && [ ! -L "$policy" ] && [ -f "$candidate" ] && [ ! -L "$candidate" ] \
    || { echo "eval-build: policy or candidate missing or unsafe" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "eval-build: jq is required" >&2; exit 2; }
  jq -e --slurpfile candidate "$candidate" '
    def norm: gsub("\\\\"; "/") | ascii_downcase;
    def dirname: norm | sub("/[^/]+$"; "");
    . as $policy
    | $candidate[0] as $c
    | ($c.subject.executable | dirname) as $runtime_dir
    | [$policy.agents[$c.subject.name].approved_builds[]?
        | select(.cli_version == $c.subject.cli_version
          and (.sha256 | ascii_downcase) == ($c.subject.executable_sha256 | ascii_downcase))] as $builds
    | ($builds | length) == 1
      and $c.subject.name == "codex"
      and $c.reviewer.name == $c.subject.name
      and $c.reviewer.cli_version == $c.subject.cli_version
      and (($c.reviewer.executable_sha256 | ascii_downcase) == ($c.subject.executable_sha256 | ascii_downcase))
      and (($c.reviewer.executable | dirname) == $runtime_dir)
      and ($c.subject.executable | norm | test("/codex([.]exe)?$"))
      and ($c.reviewer.executable | norm | test("/codex([.]exe)?$"))
      and ($builds[0].components | type == "object" and length > 0)
      and (($c.agent_runtime.components | keys | sort) == ($builds[0].components | keys | sort))
      and all($builds[0].components | to_entries[];
        . as $component
        | ($component.key | test("^codex-[a-z0-9-]+[.]exe$"))
        and ($c.agent_runtime.components[$component.key] | keys | sort) == ["authenticode","sha256","source"]
        and (($c.agent_runtime.components[$component.key].source | norm) == ($runtime_dir + "/" + ($component.key | ascii_downcase)))
        and (($c.agent_runtime.components[$component.key].sha256 | ascii_downcase) == ($component.value.sha256 | ascii_downcase))
        and ($c.agent_runtime.components[$component.key].authenticode | keys | sort) == ["status","subject","thumbprint"]
        and $c.agent_runtime.components[$component.key].authenticode.status == "Valid"
        and $c.agent_runtime.components[$component.key].authenticode.subject == $policy.agents.codex.publisher_subject
        and ($c.agent_runtime.components[$component.key].authenticode.thumbprint as $thumbprint
          | ($policy.agents.codex.publisher_thumbprints | index($thumbprint)) != null)
      )
  ' "$policy" >/dev/null
  exit $?
fi

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
