#!/bin/bash
# Exact release checks plus signed-compatible daily runtime admission.

set -euo pipefail
if [ "${1:-}" = "--verify-publisher-identity" ]; then
  [ "$#" -eq 4 ] || { echo "eval-build: usage: verify-agent-build.sh --verify-publisher-identity <policy> <agent> <identity-json>" >&2; exit 2; }
  policy="$2"; agent="$3"; identity="$4"
  [ -f "$policy" ] && [ ! -L "$policy" ] \
    || { echo "eval-build: policy missing or unsafe" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "eval-build: jq is required" >&2; exit 2; }
  jq -e --arg agent "$agent" --argjson identity "$identity" '
    (.agents[$agent] | type == "object")
    and $identity.status == "Valid"
    and $identity.subject == .agents[$agent].publisher_subject
    and ($identity.thumbprint | type == "string" and length > 0)
  ' "$policy" >/dev/null
  exit $?
fi

if [ "${1:-}" = "--resolve-runtime-policy" ]; then
  [ "$#" -eq 5 ] || { echo "eval-build: usage: verify-agent-build.sh --resolve-runtime-policy <policy> <agent> <version> <sha256>" >&2; exit 2; }
  policy="$2"; agent="$3"; version="$4"; digest="${5,,}"
  [ -f "$policy" ] && [ ! -L "$policy" ] \
    || { echo "eval-build: policy missing or unsafe" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "eval-build: jq is required" >&2; exit 2; }
  jq -ce --arg agent "$agent" --arg version "$version" --arg digest "$digest" '
    .agents[$agent] as $agent_policy
    | select($agent_policy | type == "object")
    | [$agent_policy.approved_builds[]? | select(.cli_version == $version)] as $known_version
    | [$known_version[]
        | select((.sha256 | ascii_downcase) == $digest)] as $exact
    | if ($exact | length) == 1 then
        $exact[0] | {
          approval:"exact",
          shell_wrapper_argv_variants,
          components
        }
      elif ($known_version | length) == 0
        and ($version | test($agent_policy.version_pattern))
        and ($digest | test("^[0-9a-f]{64}$"))
        and ($agent_policy.compatible_runtime.shell_wrapper_argv_variants | type == "array" and length > 0)
        and ($agent_policy.compatible_runtime.components | type == "array" and length > 0)
        and all($agent_policy.compatible_runtime.components[]; test("^codex-[a-z0-9-]+[.]exe$"))
      then {
        approval:"compatible",
        shell_wrapper_argv_variants:$agent_policy.compatible_runtime.shell_wrapper_argv_variants,
        components:($agent_policy.compatible_runtime.components
          | map({key:.,value:{sha256:null}}) | from_entries)
      }
      else empty
      end
  ' "$policy"
  exit $?
fi

if [ "${1:-}" = "--verify-daily-bundle" ]; then
  [ "$#" -eq 3 ] || { echo "eval-build: usage: verify-agent-build.sh --verify-daily-bundle <policy> <evidence-json>" >&2; exit 2; }
  policy="$2"; evidence="$3"
  [ -f "$policy" ] && [ ! -L "$policy" ] \
    || { echo "eval-build: policy missing or unsafe" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "eval-build: jq is required" >&2; exit 2; }
  agent="$(jq -er '.subject.name' <<< "$evidence")" || exit 1
  version="$(jq -er '.subject.cli_version' <<< "$evidence")" || exit 1
  digest="$(jq -er '.subject.executable_sha256' <<< "$evidence")" || exit 1
  resolved="$(bash "$0" --resolve-runtime-policy "$policy" "$agent" "$version" "$digest")" || exit 1
  jq -en --argjson candidate "$evidence" --argjson resolved "$resolved" \
    --slurpfile policy "$policy" '
    def norm: gsub("\\\\"; "/") | ascii_downcase;
    def dirname: norm | sub("/[^/]+$"; "");
    def identity_ok($identity; $subject):
      $identity.status == "Valid"
      and $identity.subject == $subject
      and ($identity.thumbprint | type == "string" and length > 0);
    $candidate as $c
    | $policy[0].agents[$c.subject.name] as $agent_policy
    | ($c.subject.executable | dirname) as $runtime_dir
    | $c.subject.name == "codex"
      and $c.reviewer.name == $c.subject.name
      and $c.reviewer.cli_version == $c.subject.cli_version
      and (($c.reviewer.executable_sha256 | ascii_downcase) == ($c.subject.executable_sha256 | ascii_downcase))
      and (($c.reviewer.executable | dirname) == $runtime_dir)
      and ($c.subject.executable | norm | test("/codex([.]exe)?$"))
      and ($c.reviewer.executable | norm | test("/codex([.]exe)?$"))
      and identity_ok($c.subject.authenticode; $agent_policy.publisher_subject)
      and identity_ok($c.reviewer.authenticode; $agent_policy.publisher_subject)
      and (($c.agent_runtime.components | keys | sort) == ($resolved.components | keys | sort))
      and all($resolved.components | to_entries[];
        . as $component
        | ($c.agent_runtime.components[$component.key] | keys | sort) == ["authenticode","sha256","source"]
        and (($c.agent_runtime.components[$component.key].source | dirname) == $runtime_dir)
        and (($c.agent_runtime.components[$component.key].source | norm) == ($runtime_dir + "/" + ($component.key | ascii_downcase)))
        and ($c.agent_runtime.components[$component.key].sha256 | test("^[0-9a-fA-F]{64}$"))
        and ($component.value.sha256 == null
          or (($c.agent_runtime.components[$component.key].sha256 | ascii_downcase) == ($component.value.sha256 | ascii_downcase)))
        and identity_ok($c.agent_runtime.components[$component.key].authenticode; $agent_policy.publisher_subject)
      )
  ' >/dev/null
  exit $?
fi

if [ "${1:-}" = "--verify-bundle-evidence" ]; then
  [ "$#" -eq 3 ] || { echo "eval-build: usage: verify-agent-build.sh --verify-bundle-evidence <policy> <candidate>" >&2; exit 2; }
  policy="$2"; candidate="$3"
  [ -f "$policy" ] && [ ! -L "$policy" ] && [ -f "$candidate" ] && [ ! -L "$candidate" ] \
    || { echo "eval-build: policy or candidate missing or unsafe" >&2; exit 2; }
  candidate_json="$(cat "$candidate")" || exit 1
  bash "$0" --verify-daily-bundle "$policy" "$candidate_json"
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
