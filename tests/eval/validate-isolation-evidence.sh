#!/bin/bash
# Validate schema-v3 real-eval isolation evidence without trusting its claims.

set -euo pipefail

[ "$#" -eq 7 ] || {
  echo "usage: validate-isolation-evidence.sh <evidence> <candidate> <source> <workspace> <sandbox-accounts-json> <trust-policy> <probe-command-validator>" >&2
  exit 2
}
EVIDENCE="$1"
CANDIDATE="$2"
CANONICAL_SOURCE="$3"
CANONICAL_WORKSPACE="$4"
LIVE_ACCOUNTS="$5"
TRUST_POLICY="$6"
COMMAND_VALIDATOR="$7"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE_SCRIPT="$SCRIPT_DIR/windows-isolation-probe.ps1"
AGENT_BUILD_VERIFIER="$SCRIPT_DIR/verify-agent-build.sh"

sha() { sha256sum "$1" | awk '{print $1}'; }
for path in "$EVIDENCE" "$CANDIDATE" "$TRUST_POLICY" "$COMMAND_VALIDATOR" "$PROBE_SCRIPT" "$AGENT_BUILD_VERIFIER"; do
  [ -f "$path" ] && [ ! -L "$path" ] || exit 1
done

payload="$(jq -cS '.probe.payload' "$EVIDENCE")" || exit 1
[ "$payload" != null ] || exit 1
payload_sha="$(printf '%s' "$payload" | sha256sum | awk '{print $1}')"
powershell_path="$(jq -r '.probe.executables.powershell.path // empty' "$EVIDENCE")"
whoami_path="$(jq -r '.probe.executables.whoami.path // empty' "$EVIDENCE")"
[ "$powershell_path" = "$(jq -r '.windows_system_tools.powershell.path' "$TRUST_POLICY")" ] || exit 1
[ "$whoami_path" = "$(jq -r '.windows_system_tools.whoami.path' "$TRUST_POLICY")" ] || exit 1
[ "$(jq -r '.probe.executables.powershell.sha256 | ascii_downcase' "$EVIDENCE")" = "$(jq -r '.windows_system_tools.powershell.sha256 | ascii_downcase' "$TRUST_POLICY")" ] || exit 1
[ "$(jq -r '.probe.executables.whoami.sha256 | ascii_downcase' "$EVIDENCE")" = "$(jq -r '.windows_system_tools.whoami.sha256 | ascii_downcase' "$TRUST_POLICY")" ] || exit 1
[ "$(jq -r '.whoami_file' <<< "$payload")" = "$whoami_path" ] || exit 1

controller_file="$(jq -r '.controller_file' <<< "$payload")"
case "$controller_file" in *'\controller\runtime.manifest') ;; *) exit 1 ;; esac
probe_path="${controller_file%'\controller\runtime.manifest'}\agent-bin\isolation-probe.ps1"
[ "$(jq -r '.probe.script.path' "$EVIDENCE")" = "$probe_path" ] || exit 1
[ "$(jq -r '.probe.script.sha256 | ascii_downcase' "$EVIDENCE")" = "$(sha "$PROBE_SCRIPT")" ] || exit 1
expected="& '$powershell_path' -NoProfile -ExecutionPolicy Bypass -File '$probe_path' -ExpectedPayloadSha256 '$payload_sha'"
recorded_b64="$(jq -r '.probe.command_event.command | @base64' "$EVIDENCE")"
expected_b64="$(printf '%s' "$expected" | base64 | tr -d '\r\n')"
wrapper="$(jq -r '.probe.shell_wrapper_path' "$EVIDENCE")"
python "$COMMAND_VALIDATOR" --same-windows-path "$wrapper" "$powershell_path" >/dev/null 2>&1 || exit 1
agent="$(jq -r '.subject.name' "$CANDIDATE")"
version="$(jq -r '.subject.cli_version' "$CANDIDATE")"
agent_sha="$(jq -r '.subject.executable_sha256 | ascii_downcase' "$CANDIDATE")"
runtime_policy="$(bash "$AGENT_BUILD_VERIFIER" --resolve-runtime-policy "$TRUST_POLICY" "$agent" "$version" "$agent_sha")" || exit 1
variants="$(jq -r '.shell_wrapper_argv_variants | tojson | @base64' <<< "$runtime_policy")"
[ -n "$variants" ] || exit 1
identified="$(python "$COMMAND_VALIDATOR" --identify "$recorded_b64" "$expected_b64" "$wrapper" "$variants" 2>/dev/null)" || exit 1
[ "$identified" = "$(jq -r '.probe.shell_wrapper_argv_variant' "$EVIDENCE")" ] || exit 1

jq -e \
  --arg canonical_source "$CANONICAL_SOURCE" \
  --arg canonical_workspace "$CANONICAL_WORKSPACE" \
  --arg payload_sha "$payload_sha" \
  --arg probe_sha "$(sha "$PROBE_SCRIPT")" \
  --argjson live_accounts "$LIVE_ACCOUNTS" \
  --arg wrapper_subject "$(jq -r '.windows_runtime_tools.codex_powershell.publisher_subject' "$TRUST_POLICY")" \
  --argjson wrapper_thumbprints "$(jq -c '.windows_runtime_tools.codex_powershell.publisher_thumbprints' "$TRUST_POLICY")" \
  --argjson wrapper_hashes "$(jq -c '.windows_runtime_tools.codex_powershell.approved_sha256 | map(ascii_downcase)' "$TRUST_POLICY")" '
  def norm: gsub("\\\\"; "/") | ascii_downcase | sub("/+$"; "");
  def exact_checks($block; $path; $rights):
    ($block | type == "object" and (keys | sort) == ["checks","path"])
    and (($block.path | norm) == ($path | norm))
    and ($block.checks | type == "array" and length == 2
      and all(.[];
        type == "object"
        and (keys | sort) == ["denied","rights","sandbox_account","sandbox_sid"]
        and .denied == true and .rights == $rights))
    and ([
      $live_accounts[] as $account
      | (([$block.checks[] | select(
          .sandbox_account == $account.Name and .sandbox_sid == $account.Sid
          and .denied == true and .rights == $rights
        )] | length) == 1)
    ] | length == 2 and all);
  . as $e
  | ([$e.denied_roots[] | norm]) as $roots
  | ($e.probe.payload.target_file | norm) as $target
  | ($e.probe.payload.source_file | norm) as $source
  | ($e.probe.payload.controller_file | norm) as $controller
  | ($controller | sub("/controller/runtime\\.manifest$"; "")) as $run_root
  | ($e.probe.payload.user_home | norm) as $user_home
  | ($e.probe.payload.context_file | norm) as $context
  | ($e.probe.payload.user_executable_file | norm) as $user_exe
  | ($e.probe.payload.host_temp_marker | norm | sub("/[^/]+$"; "")) as $host_temp
  | $e.schema_version == 3 and $e.isolation == "windows-native-elevated-acl"
  and $e.network == "codex-workspace-write-offline"
  and $e.controller_visible_to_agent == false
  and $e.source_workspace_visible_to_agent == false
  and $e.user_home_root_listable_to_agent == false
  and $e.context_authority_visible_to_agent == false
  and $e.user_executable_visible_to_agent == false
  and $e.host_temp_writeable_to_agent == false
  and ($e.sandbox_accounts | sort_by(.Name)) == ($live_accounts | sort_by(.Name))
  and ([$e.sandbox_accounts[].Name] | sort == ["CodexSandboxOffline","CodexSandboxOnline"])
  and ([$e.sandbox_accounts[].Sid] | unique | length == 2 and all(.[]; test("^S-[0-9-]+$")))
  and ($e.denied_roots | type == "array" and length == 3 and (unique | length) == 3)
  and ($roots[0] == ($canonical_workspace | norm))
  and ($user_home == $roots[1])
  and ($controller | startswith($roots[2] + "/"))
  and ($e.checks | type == "array" and length == 6
    and all(.[]; (keys | sort) == ["denied","path","rights","sandbox_account","sandbox_sid"]
      and .denied == true and .rights == "ReadAndExecute"))
  and ([
    $e.denied_roots[] as $root | $live_accounts[] as $account
    | (([$e.checks[] | select(.path == $root and .sandbox_account == $account.Name
      and .sandbox_sid == $account.Sid and .denied == true and .rights == "ReadAndExecute")] | length) == 1)
  ] | length == 6 and all)
  and exact_checks($e.source_file_deny; $e.probe.payload.source_file; "ReadAndExecute")
  and exact_checks($e.context_file_deny; $e.probe.payload.context_file; "ReadAndExecute")
  and exact_checks($e.user_executable_deny; $e.probe.payload.user_executable_file; "ReadAndExecute")
  and exact_checks($e.host_temp_write_deny; $host_temp; "Modify")
  and ($source == ($canonical_source | norm) and ($source | startswith($roots[0] + "/")))
  and ($context | startswith($user_home + "/.agents/skills/harness-companion/"))
  and ($context | endswith("/skill.md"))
  and ($user_exe | startswith($user_home + "/"))
  and ($host_temp | startswith($user_home + "/"))
  and ($target == ($run_root + "/project/.harness-eval-isolation-sentinel"))
  and ([range(0; $roots|length) as $i | ($target | startswith($roots[$i] + "/") | not)] | all)
  and ($e.shell_environment_policy | type == "object"
    and (keys | sort) == ["appdata","home","inherit","localappdata","psmodule_analysis_cache","temp","tmp","userprofile"]
    and .inherit == "none"
    and ((.home|norm) == (.userprofile|norm)) and ((.temp|norm) == (.tmp|norm))
    and (.home|norm|startswith($run_root + "/agent-scratch/"))
    and (.temp|norm|startswith($run_root + "/agent-scratch/"))
    and (.appdata|norm|startswith($run_root + "/agent-scratch/"))
    and (.localappdata|norm|startswith($run_root + "/agent-scratch/"))
    and (.psmodule_analysis_cache|norm|startswith($run_root + "/agent-scratch/powershell/")))
  and ($e.probe.payload | keys | sort == ["context_file","controller_file","expected_shell","host_temp_marker","nonce","source_file","target_file","user_executable_file","user_home","whoami_file"])
  and ($e.probe.payload.expected_shell | keys | sort == ["home","temp","tmp","userprofile"])
  and ($e.probe.result | keys | sort == ["context_authority_readable","controller_readable","host_temp_writeable","identity","nonce","payload_sha256","shell_home","shell_temp","shell_tmp","shell_userprofile","source_workspace_readable","target_file_readable","target_writeable","user_executable_readable","user_home_root_listable"])
  and $e.probe.payload.nonce == $e.probe.result.nonce
  and $e.probe.result.payload_sha256 == $payload_sha
  and ($e.probe.result.identity | ascii_downcase | endswith("\\codexsandboxoffline"))
  and $e.probe.result.target_file_readable == true and $e.probe.result.target_writeable == true
  and $e.probe.result.source_workspace_readable == false and $e.probe.result.controller_readable == false
  and $e.probe.result.user_home_root_listable == false
  and $e.probe.result.context_authority_readable == false
  and $e.probe.result.user_executable_readable == false
  and $e.probe.result.host_temp_writeable == false
  and (($e.probe.result.shell_home|norm) == ($e.probe.payload.expected_shell.home|norm))
  and (($e.probe.result.shell_userprofile|norm) == ($e.probe.payload.expected_shell.userprofile|norm))
  and (($e.probe.result.shell_temp|norm) == ($e.probe.payload.expected_shell.temp|norm))
  and (($e.probe.result.shell_tmp|norm) == ($e.probe.payload.expected_shell.tmp|norm))
  and (($e.probe.command_event.aggregated_output | gsub("\r\n";"\n") | split("\n") | map(select(length>0)) | last | fromjson) == $e.probe.result)
  and ($e.probe.script.sha256 == $probe_sha)
  and ($e.probe.executables | keys | sort == ["codex_powershell","powershell","whoami"])
  and (($e.probe.executables.codex_powershell.path|norm) == ($run_root + "/agent-bin/codex-powershell.exe"))
  and ($e.probe.executables.codex_powershell.source_path|norm|startswith($user_home + "/"))
  and (($e.probe.executables.codex_powershell.sha256|ascii_downcase) as $x | $wrapper_hashes|index($x) != null)
  and $e.probe.executables.codex_powershell.authenticode.status == "Valid"
  and $e.probe.executables.codex_powershell.authenticode.subject == $wrapper_subject
  and ($e.probe.executables.codex_powershell.authenticode.thumbprint as $x | $wrapper_thumbprints|index($x) != null)
  and ($e.probe.sanitized_path | type == "array" and length >= 4
    and all(.[]; type == "string" and length > 0 and ((ascii_downcase|contains("/users/"))|not)))
' "$EVIDENCE" >/dev/null
