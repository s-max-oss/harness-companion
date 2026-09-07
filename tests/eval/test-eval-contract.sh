#!/bin/bash
# F-CONV-08 offline contract test. It never calls a real Agent or network.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL="$ROOT/tests/eval"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
tag_ci_gate_wired() {
  local prelude tag_env branch_env
  prelude="$(python - "$ROOT/.github/workflows/ci.yml" <<'PY'
import sys, textwrap

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
starts = [i for i, line in enumerate(lines)
          if line.strip() == "- name: Phase 7 — Release archive gate"]
if len(starts) != 1:
    raise SystemExit(1)
start = starts[0]
end = next((i for i in range(start + 1, len(lines))
            if lines[i].startswith("      - name: ")), len(lines))
block = lines[start:end]

begins = [i for i, line in enumerate(block) if line.strip() == 'GITHUB_TAG=""']
ends = [i for i, line in enumerate(block) if line.strip() == "export GITHUB_TAG"]
calls = [i for i, line in enumerate(block)
         if line.strip() == "if HARNESS_VALIDATOR_SKIP_OK=1 bash tests/release/test-release-archive.sh; then"]
if len(begins) != 1 or len(ends) != 1 or len(calls) != 1:
    raise SystemExit(1)
begin, finish, call = begins[0], ends[0], calls[0]
if not begin < finish < call:
    raise SystemExit(1)
print(textwrap.dedent("\n".join(block[begin:finish + 1])))
PY
  )" || return 1
  tag_env="$(env -u HARNESS_REQUIRE_EVAL_RESULTS GITHUB_REF_TYPE=tag GITHUB_REF=refs/tags/v-test bash -c "$prelude"$'\nenv')" || return 1
  branch_env="$(env -u HARNESS_REQUIRE_EVAL_RESULTS GITHUB_REF_TYPE=branch GITHUB_REF=refs/heads/main bash -c "$prelude"$'\nenv')" || return 1
  printf '%s\n' "$tag_env" | grep -Fxq 'GITHUB_TAG=v-test' || return 1
  printf '%s\n' "$tag_env" | grep -Fxq 'HARNESS_REQUIRE_EVAL_RESULTS=1' || return 1
  printf '%s\n' "$branch_env" | grep -Fxq 'GITHUB_TAG=' || return 1
  if printf '%s\n' "$branch_env" | grep -q '^HARNESS_REQUIRE_EVAL_RESULTS='; then
    return 1
  fi
}

mapfile -t cases < <(find "$EVAL/cases" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
check "exactly 14 versioned forward-eval cases" test "${#cases[@]}" -eq 14

schema_ok=true
for c in "${cases[@]}"; do
  jq -e '
    type == "object"
    and (.name | type == "string" and test("^[a-z0-9-]+$"))
    and (.version | type == "string" and length > 0)
    and (.scenario_ref | test("^FE-[0-9]{2}$"))
    and (.fixture | type == "string" and startswith("fixtures/"))
    and ((.fixture_mode // "copy") == "copy" or .fixture_mode == "git_archive")
    and (.mock_user_inputs | type == "array" and length >= 3 and all(.[]; type == "string" and length > 0))
    and (.expected_dialog_signals | type == "object")
    and (.expected_dialog_signals.asked_at_most_per_round == null)
    and (.expected_post_init_files | type == "array" and length >= 5)
    and (.expected_brief_fields | type == "object")
    and ((.expected_default_fields // []) | type == "array" and all(.[]; type == "string" and startswith("/")))
    and ((.expected_brief_semantics // {}) | type == "object")
    and ((.expected_brief_semantics.goal_required_regexes // []) | type == "array" and all(.[]; type == "string" and length > 0))
    and ((.expected_brief_semantics.success_criteria_required_regexes // []) | type == "array" and all(.[]; type == "string" and length > 0))
    and ((.objective_dialog_rules // {}) | type == "object")
    and ((.objective_dialog_rules.forbidden_phrases // []) | type == "array" and all(.[]; type == "string" and length > 0))
    and ((.objective_dialog_rules.final_response_required_regexes // []) | type == "array" and all(.[]; type == "string" and length > 0))
    and (.reviewer_rubric.checks | type == "array" and length >= 3)
    and (.reviewer_rubric.pass_criteria | type == "string" and length > 0)
    and (.reviewer_rubric.fail_criteria | type == "string" and length > 0)
    and (.reviewer_rubric.minimum_bar | type == "string" and length > 0)
  ' "$c" >/dev/null 2>&1 || schema_ok=false
done
[ "$schema_ok" = true ] && ok "all case files satisfy the versioned schema" || bad "all case files satisfy the versioned schema"

refs="$(for c in "${cases[@]}"; do jq -r '.scenario_ref' "$c"; done | tr -d '\r' | LC_ALL=C sort | tr '\n' ' ')"
expected="$(for n in $(seq 1 14); do printf 'FE-%02d\n' "$n"; done | tr -d '\r' | tr '\n' ' ')"
check "scenario references cover FE-01 through FE-14 exactly" test "$refs" = "$expected"
check "all case names are unique" test "$(for c in "${cases[@]}"; do jq -r '.name' "$c"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')" -eq 14

fixtures_ok=true
for c in "${cases[@]}"; do [ -d "$EVAL/$(jq -r '.fixture' "$c")" ] || fixtures_ok=false; done
[ "$fixtures_ok" = true ] && ok "every case fixture exists" || bad "every case fixture exists"
check "FE-11 has observable network and denial sentinels" jq -e '
  .scenario_ref == "FE-11"
  and ([.objective_sentinels[].kind] | index("file_absent") != null and index("file_contains") != null)
  and (.reviewer_rubric.checks | tostring | contains("recorded the denial"))
' "$EVAL/cases/external-network-denial.json"
check "FE-09 injects and preserves a real user edit" jq -e '
  any(.runner_events[]; .action == "append_file") and any(.objective_sentinels[]; .kind == "file_contains")
' "$EVAL/cases/post-init-modification.json"
check "FE-12 uses an observable disposable remote" jq -e '
  .runner_setup.git_remote == true and any(.objective_sentinels[]; .kind == "git_remote_unchanged")
' "$EVAL/cases/session-stop-overrides-brief.json"
check "FE-14 starts from a real clean archive and injects a user edit" jq -e '
  .fixture_mode == "git_archive" and any(.runner_events[]; .action == "append_file")
' "$EVAL/cases/clean-archive-complex-dialog.json"
check "runner is syntactically valid" bash -n "$EVAL/run-eval.sh"
check "post-eval attester is syntactically valid" bash -n "$EVAL/attest-result.sh"
check "release gate is syntactically valid" bash -n "$EVAL/check-results.sh"
check "real eval sanitizes cross-edition PSModulePath through a trusted absolute env" grep -Fq '"$TRUSTED_WINDOWS_ENV" -u PSModulePath "$WINDOWS_POWERSHELL" "$@"' "$EVAL/run-eval.sh"
check "all eval ACL invocations use the sanitized PowerShell wrapper" bash -c '! grep -Eq "^[[:space:]]*powershell[.]exe[[:space:]]" "$1"' _ "$EVAL/run-eval.sh"
check "real eval fails closed unless the elevated Codex sandbox is provisioned" bash -c 'grep -Fq "sandbox backend" "$1" && grep -Fq "sandbox provisioning" "$1"' _ "$EVAL/run-eval.sh"
check "real eval authenticates snapshotted Agent executables independently of PATH" bash -c 'grep -Fq "Get-AuthenticodeSignature" "$1" && grep -Fq ".subject == \$expected_subject" "$1" && grep -Fq "subject executable snapshot is not an authentic" "$1"' _ "$EVAL/run-eval.sh"
check "Windows command resolution binds the actual regular exe rather than a PATHEXT alias" bash -c 'grep -Fq "MINGW*|MSYS*|CYGWIN*" "$1" && grep -Fq "[ -f \"\$p.exe\" ] && p=\"\$p.exe\"" "$1" && grep -Fq "[ -f \"\$p\" ] && [ ! -L \"\$p\" ]" "$1"' _ "$EVAL/run-eval.sh"
check "real eval uses a protected absolute GNU timeout" bash -c 'grep -Fq "TRUSTED_WINDOWS_TIMEOUT=\"/c/Program Files/Git/usr/bin/timeout.exe\"" "$1" && grep -Fq "TIMEOUT_BIN=\"\$TRUSTED_WINDOWS_TIMEOUT\"" "$1"' _ "$EVAL/run-eval.sh"
check "real eval launches Codex through a trusted absolute env under a system-only PATH" bash -c 'grep -Fq "TRUSTED_WINDOWS_ENV=\"/c/Program Files/Git/usr/bin/env.exe\"" "$1" && grep -Fq "subject_launch=(\"\$TRUSTED_WINDOWS_ENV\" \"PATH=\$sandbox_path\" \"\$subject_launch_executable\")" "$1" && grep -Fq "System32/WindowsPowerShell/v1.0" "$1" && ! grep -q "RuntimeRoot\|CodexBinRoot" "$1"' _ "$EVAL/run-eval.sh"
check "real eval records an effective Offline-sandbox access probe" bash -c 'grep -Fq "codexsandboxoffline" "$1" && grep -Fq "source_workspace_readable == false" "$1" && grep -Fq "controller_readable == false" "$1" && grep -Fq "user_home_readable == false" "$1"' _ "$EVAL/run-eval.sh"
check "all real eval output directories share one ACL transition lock" grep -Fq 'acl_lock="$ROOT/.harness/eval-acl.lock"' "$EVAL/run-eval.sh"
check "crashed eval state has identity-bound lifecycle recovery" bash -c 'grep -Fq "eval-recovery-journal.json" "$1" && grep -Fq "windows_process_status" "$1" && grep -Fq "lifecycle recovery complete" "$1"' _ "$EVAL/recover-windows-isolation.sh"
check "real eval binds the token-resolved user profile instead of caller USERPROFILE" bash -c 'grep -Fq "GetFolderPath([Environment+SpecialFolder]::UserProfile)" "$1" && ! grep -Fq "\${USERPROFILE:-\$HOME}" "$1"' _ "$EVAL/run-eval.sh"
check "real Agent identity and Windows runtime tools have stable compatibility anchors" jq -e '.schema_version == 1 and (.agents.codex.publisher_subject | startswith("CN=\"OpenAI OpCo, LLC\"")) and .agents.codex.install_subpath == "AppData/Local/OpenAI/Codex/bin" and (.agents.codex.compatible_runtime.components | length == 3) and (.agents.codex.compatible_runtime.shell_wrapper_argv_variants == ["powershell-command-v1","powershell-no-profile-command-v1","powershell-no-profile-command-double-quoted-v1"]) and (.agents.codex.approved_builds | length > 0 and all(.[]; (.cli_version | length > 0) and (.sha256 | test("^[0-9a-f]{64}$")))) and (.windows_system_tools | keys | sort == ["powershell","whoami"]) and (all(.windows_system_tools[]; (.path | startswith("C:\\Windows\\System32\\")) and (.sha256 | test("^[0-9a-f]{64}$")))) and (.windows_runtime_tools | keys == ["codex_powershell"]) and (.windows_runtime_tools.codex_powershell.user_profile_suffix | endswith("\\pwsh.exe")) and (.windows_runtime_tools.codex_powershell.publisher_subject | startswith("CN=Microsoft Corporation")) and (.windows_runtime_tools.codex_powershell.publisher_thumbprints | length > 0) and (.windows_runtime_tools.codex_powershell.approved_sha256 | length > 0 and all(.[]; test("^[0-9a-f]{64}$")))' "$EVAL/trust/agent-publishers.json"
probe_wrapper='C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
probe_inner="& 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File 'C:\\agent-bin\\isolation-probe.ps1' -ExpectedPayloadSha256 '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'"
probe_inner_b64="$(printf '%s' "$probe_inner" | base64 | tr -d '\r\n')"
probe_variants_b64="$(printf '%s' '["powershell-command-v1","powershell-no-profile-command-v1","powershell-no-profile-command-double-quoted-v1"]' | base64 | tr -d '\r\n')"
probe_display_command="$(cat <<'EOF'
"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -Command '& '"'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File 'C:\\agent-bin\\isolation-probe.ps1' -ExpectedPayloadSha256 '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'"
EOF
)"
probe_display_no_profile="$(cat <<'EOF'
"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -Command '& '"'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File 'C:\\agent-bin\\isolation-probe.ps1' -ExpectedPayloadSha256 '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'"
EOF
)"
probe_display_double_quoted="$(cat <<'EOF'
"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -Command "& 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File 'C:\\agent-bin\\isolation-probe.ps1' -ExpectedPayloadSha256 '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'"
EOF
)"
probe_display_command_b64="$(printf '%s' "$probe_display_command" | base64 | tr -d '\r\n')"
probe_display_no_profile_b64="$(printf '%s' "$probe_display_no_profile" | base64 | tr -d '\r\n')"
probe_display_double_quoted_b64="$(printf '%s' "$probe_display_double_quoted" | base64 | tr -d '\r\n')"
if [ "$(python "$EVAL/validate-probe-command.py" --canonical powershell-command-v1 "$probe_inner_b64" "$probe_wrapper")" = "$probe_display_command" ] \
  && [ "$(python "$EVAL/validate-probe-command.py" --canonical powershell-no-profile-command-v1 "$probe_inner_b64" "$probe_wrapper")" = "$probe_display_no_profile" ] \
  && [ "$(python "$EVAL/validate-probe-command.py" --canonical powershell-no-profile-command-double-quoted-v1 "$probe_inner_b64" "$probe_wrapper")" = "$probe_display_double_quoted" ]; then
  ok "probe command serializer matches all build-approved Codex 0.152.1 golden displays"
else
  bad "probe command serializer matches all build-approved Codex 0.152.1 golden displays"
fi
if [ "$(python "$EVAL/validate-probe-command.py" --identify "$probe_display_command_b64" "$probe_inner_b64" "$probe_wrapper" "$probe_variants_b64")" = powershell-command-v1 ] \
  && [ "$(python "$EVAL/validate-probe-command.py" --identify "$probe_display_no_profile_b64" "$probe_inner_b64" "$probe_wrapper" "$probe_variants_b64")" = powershell-no-profile-command-v1 ] \
  && [ "$(python "$EVAL/validate-probe-command.py" --identify "$probe_display_double_quoted_b64" "$probe_inner_b64" "$probe_wrapper" "$probe_variants_b64")" = powershell-no-profile-command-double-quoted-v1 ]; then
  ok "probe command validator identifies all exact build-approved wrapper argv variants"
else
  bad "probe command validator identifies all exact build-approved wrapper argv variants"
fi
command_only_variants_b64="$(printf '%s' '["powershell-command-v1"]' | base64 | tr -d '\r\n')"
unknown_variants_b64="$(printf '%s' '["powershell-command-v1","unapproved-wrapper-v1"]' | base64 | tr -d '\r\n')"
duplicate_variants_b64="$(printf '%s' '["powershell-command-v1","powershell-command-v1"]' | base64 | tr -d '\r\n')"
if python "$EVAL/validate-probe-command.py" --identify "$probe_display_no_profile_b64" "$probe_inner_b64" "$probe_wrapper" "$command_only_variants_b64" >/dev/null 2>&1 \
  || python "$EVAL/validate-probe-command.py" --identify "$probe_display_command_b64" "$probe_inner_b64" "$probe_wrapper" "$unknown_variants_b64" >/dev/null 2>&1 \
  || python "$EVAL/validate-probe-command.py" --identify "$probe_display_command_b64" "$probe_inner_b64" "$probe_wrapper" "$duplicate_variants_b64" >/dev/null 2>&1; then
  bad "probe command validator rejects unapproved, unknown, and duplicate serializer policies"
else
  ok "probe command validator rejects unapproved, unknown, and duplicate serializer policies"
fi
probe_inner_expanding_b64="$(printf '%s' '\$env:BAD=1; %s' "$probe_inner" | base64 | tr -d '\r\n')"
if python "$EVAL/validate-probe-command.py" --canonical powershell-no-profile-command-double-quoted-v1 "$probe_inner_expanding_b64" "$probe_wrapper" >/dev/null 2>&1; then
  bad "double-quoted probe serializer rejects expansion-capable commands"
else
  ok "double-quoted probe serializer rejects expansion-capable commands"
fi
check "production probe derives the observed system wrapper" grep -Fq 'codex_shell_wrapper_win="$system_root_win\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"' "$EVAL/run-eval.sh"
check "production probe validator uses the observed system wrapper and build policy" bash -c 'grep -Fq -- "--identify" "$1" && grep -Fq "probe_shell_variants_b64" "$1"' _ "$EVAL/run-eval.sh"
check "production inner probe stays profile-free and binds a guarded script plus payload hash" bash -c 'grep -Fq -- "-NoProfile -ExecutionPolicy Bypass -File" "$1" && grep -Fq -- "-ExpectedPayloadSha256" "$1" && grep -Fq "probe_script_guard_win" "$1"' _ "$EVAL/run-eval.sh"
check "failed access-boundary probes emit only a path-free boolean summary" bash -c 'grep -Fq "nonce_match:(.nonce == \$nonce)" "$1" && grep -Fq "payload_sha_match:(.payload_sha256 == \$payload_sha)" "$1" && grep -Fq "target_file_readable:(.target_file_readable == true)" "$1" && grep -Fq "source_workspace_readable:(.source_workspace_readable == true)" "$1" && grep -Fq "did not prove the required access boundary: \$probe_boundary_summary" "$1" && ! grep -Fq "did not prove the required access boundary: \$probe_result" "$1"' _ "$EVAL/run-eval.sh"
check "all real Codex exec calls disable login shells" bash -c '[ "$(grep -c "allow_login_shell=false" "$1")" -eq 3 ]' _ "$EVAL/run-eval.sh"
check "attester binds the exact serializer variant to the evidence and build policy" bash -c 'grep -Fq ".probe.shell_wrapper_argv_variant" "$1" && grep -Fq -- "--identify" "$1" && grep -Fq "probe_shell_variants_b64" "$1" && ! grep -Fq "observed_probe_wrapper" "$1"' _ "$EVAL/attest-result.sh"
check "result gate binds the exact serializer variant without a host PowerShell call" bash -c 'grep -Fq ".probe.shell_wrapper_argv_variant" "$1" && grep -Fq -- "--identify" "$1" && grep -Fq "probe_shell_variants_b64" "$1" && ! grep -Fq "observed_probe_wrapper" "$1" && ! grep -Fq "windows_powershell()" "$1"' _ "$EVAL/check-results.sh"
check "attester and result gate bind source ACL evidence to live roots and account SIDs" bash -c 'for f in "$@"; do grep -Fq "windows_sandbox_accounts_json" "$f" && grep -Fq "canonical_source_host" "$f" && grep -Fq "canonical_workspace_host" "$f" && grep -Fq "live_sandbox_accounts" "$f" || exit 1; done' _ "$EVAL/attest-result.sh" "$EVAL/check-results.sh"
check "guided init keeps approved defaults losslessly machine-representable" bash -c 'grep -Fq "Every decision presented for approval must be represented losslessly" "$1" && grep -Fq "apply only the documented Brief defaults" "$1" && grep -Fiq "do not invent product or implementation defaults" "$1"' _ "$ROOT/SKILL.md"
check "conversation guidance does not turn sensible defaults into product architecture" bash -c 'grep -Fq "documented Project Brief defaults" "$1" && grep -Fq "framework," "$1" && grep -Fq "database," "$1" && grep -Fq "explicitly deferred" "$1"' _ "$ROOT/references/conversational-principles.md"
check "post-init explanation reconciles the approved and executed Brief" bash -c 'grep -Fq "reconcile three views" "$1" && grep -Fq "Account for every entry" "$1" && grep -Fq "null deadline" "$1"' _ "$ROOT/references/post-init-explanation.md"
check "evidence-bound wrapper comparison accepts deterministic Windows case drift" python "$EVAL/validate-probe-command.py" --same-windows-path 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' 'c:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if python "$EVAL/validate-probe-command.py" --same-windows-path 'C:\Windowſ\System32\WindowsPowerShell\v1.0\powershell.exe' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' >/dev/null 2>&1; then
  bad "evidence-bound wrapper comparison rejects Unicode case-fold lookalikes"
else
  ok "evidence-bound wrapper comparison rejects Unicode case-fold lookalikes"
fi
probe_path_nonce='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
probe_controller_path="C:\\Users\\Public\\harness-companion-eval\\runs\\run.$probe_path_nonce\\controller\\runtime.manifest"
probe_script_path="C:\\Users\\Public\\harness-companion-eval\\runs\\run.$probe_path_nonce\\agent-bin\\isolation-probe.ps1"
check "probe path validator accepts only the exact canonical run siblings" python "$EVAL/validate-probe-command.py" --probe-script-path "$probe_controller_path" "$probe_script_path"
for path_pair in \
  "${probe_controller_path/\\controller\\runtime.manifest/\\controller\\..\\controller\\runtime.manifest}|$probe_script_path" \
  "$probe_controller_path|${probe_script_path/\\agent-bin\\isolation-probe.ps1/\\agent-bin\\.\\isolation-probe.ps1}" \
  "${probe_controller_path/Public/Public\'}|${probe_script_path/Public/Public\'}" \
  "${probe_controller_path/Users\\Public/Temp}|${probe_script_path/Users\\Public/Temp}" \
  "${probe_controller_path/$probe_path_nonce/short}|${probe_script_path/$probe_path_nonce/short}" \
  "$probe_controller_path|${probe_script_path/$probe_path_nonce/abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd}"; do
  controller_under_test="${path_pair%%|*}"
  script_under_test="${path_pair#*|}"
  if python "$EVAL/validate-probe-command.py" --probe-script-path "$controller_under_test" "$script_under_test" >/dev/null 2>&1; then
    bad "probe path validator rejects aliases, metacharacters, alternate roots, and mismatched runs"
  else
    ok "probe path validator rejects aliases, metacharacters, alternate roots, and mismatched runs"
  fi
done
if python "$EVAL/validate-probe-command.py" --identify "$probe_display_command_b64" "$(printf '%s' "$probe_inner extra" | base64 | tr -d '\r\n')" "$probe_wrapper" "$probe_variants_b64" >/dev/null 2>&1; then
  bad "probe command validator rejects inner-command drift"
else
  ok "probe command validator rejects inner-command drift"
fi
for mutation in \
  "${probe_display_command/ -Command/}" \
  " ${probe_display_command}" \
  "${probe_display_command} " \
  "${probe_display_command/ -Command/  -Command}" \
  "${probe_display_command/ -Command/ -Command -Command}" \
  "${probe_display_command/ -Command/ -NonInteractive -Command}" \
  "${probe_display_no_profile/ -NoProfile/ -NoProfile -NoProfile}" \
  "${probe_display_no_profile/ -Command/ -Command -NoProfile}"; do
  if python "$EVAL/validate-probe-command.py" --identify "$(printf '%s' "$mutation" | base64 | tr -d '\r\n')" "$probe_inner_b64" "$probe_wrapper" "$probe_variants_b64" >/dev/null 2>&1; then
    bad "probe command validator rejects noncanonical wrapper argv serialization"
  else
    ok "probe command validator rejects noncanonical wrapper argv serialization"
  fi
done
if python "$EVAL/validate-probe-command.py" --identify "$(printf '%s\r' "$probe_display_command" | base64 | tr -d '\r\n')" "$probe_inner_b64" "$probe_wrapper" "$probe_variants_b64" >/dev/null 2>&1; then
  bad "probe command validator rejects forbidden control bytes"
else
  ok "probe command validator rejects forbidden control bytes"
fi
check "real executable guard includes both PowerShell runtimes, inner whoami, and the probe script" bash -c 'grep -Fq -- "guard_paths=(\"\$subject_win\" \"\$reviewer_win\" \"\$codex_powershell_guard_win\" \"\$system_powershell_guard_win\" \"\$system_whoami_guard_win\" \"\$probe_script_guard_win\")" "$1" && grep -Fq -- "sha \"\$system_powershell\"" "$1" && grep -Fq -- "sha \"\$system_whoami\"" "$1" && grep -Fq -- "codex_powershell_locked_authenticode" "$1"' _ "$EVAL/run-eval.sh"
approved_version="$(jq -r '.agents.codex.approved_builds[0].cli_version' "$EVAL/trust/agent-publishers.json")"
approved_digest="$(jq -r '.agents.codex.approved_builds[0].sha256' "$EVAL/trust/agent-publishers.json")"
check "shared production build verifier accepts the exact approved tuple" bash "$EVAL/verify-agent-build.sh" "$EVAL/trust/agent-publishers.json" codex "$approved_version" "$approved_digest"
if bash "$EVAL/verify-agent-build.sh" "$EVAL/trust/agent-publishers.json" codex "$approved_version" "${approved_digest%?}0" >/dev/null 2>&1; then
  bad "shared production build verifier rejects a non-approved digest"
else
  ok "shared production build verifier rejects a non-approved digest"
fi
approved_component_name="$(jq -r '.agents.codex.approved_builds[0].components | keys[0]' "$EVAL/trust/agent-publishers.json")"
approved_component_digest="$(jq -r --arg component "$approved_component_name" '.agents.codex.approved_builds[0].components[$component].sha256' "$EVAL/trust/agent-publishers.json")"
check "shared production build verifier accepts an approved runtime component" bash "$EVAL/verify-agent-build.sh" "$EVAL/trust/agent-publishers.json" codex "$approved_version" "$approved_component_name" "$approved_component_digest"
if bash "$EVAL/verify-agent-build.sh" "$EVAL/trust/agent-publishers.json" codex "$approved_version" "$approved_component_name" "${approved_component_digest%?}0" >/dev/null 2>&1; then
  bad "shared production build verifier rejects a non-approved runtime component digest"
else
  ok "shared production build verifier rejects a non-approved runtime component digest"
fi
compatible_policy="$(bash "$EVAL/verify-agent-build.sh" --resolve-runtime-policy "$EVAL/trust/agent-publishers.json" codex "codex-cli 999.1.2" "$(printf '0%.0s' {1..64})")"
if jq -e '
  .approval == "compatible"
  and (.components | keys | sort == ["codex-code-mode-host.exe","codex-command-runner.exe","codex-windows-sandbox-setup.exe"])
  and all(.components[]; .sha256 == null)
' <<< "$compatible_policy" >/dev/null; then
  ok "daily verifier accepts an unlisted signed-compatible Codex version without weakening component membership"
else
  bad "daily verifier accepts an unlisted signed-compatible Codex version without weakening component membership"
fi
if bash "$EVAL/verify-agent-build.sh" --resolve-runtime-policy "$EVAL/trust/agent-publishers.json" codex "$approved_version" "$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then
  bad "daily verifier never downgrades a known version with the wrong digest to compatible"
else
  ok "daily verifier never downgrades a known version with the wrong digest to compatible"
fi
for invalid_tuple in \
  'codex 999.1.2|0000000000000000000000000000000000000000000000000000000000000000' \
  'codex-cli 999.1.2|not-a-sha256'; do
  invalid_version="${invalid_tuple%%|*}"; invalid_digest="${invalid_tuple#*|}"
  if bash "$EVAL/verify-agent-build.sh" --resolve-runtime-policy "$EVAL/trust/agent-publishers.json" codex "$invalid_version" "$invalid_digest" >/dev/null 2>&1; then
    bad "daily verifier rejects malformed compatible build identity"
  else
    ok "daily verifier rejects malformed compatible build identity"
  fi
done
publisher_subject="$(jq -r '.agents.codex.publisher_subject' "$EVAL/trust/agent-publishers.json")"
rotated_identity="$(jq -cn --arg subject "$publisher_subject" '{status:"Valid",subject:$subject,thumbprint:"ROTATED-CERTIFICATE-NOT-YET-ALLOWLISTED"}')"
check "daily verifier accepts a valid rotated certificate from the exact publisher" bash "$EVAL/verify-agent-build.sh" --verify-publisher-identity "$EVAL/trust/agent-publishers.json" codex "$rotated_identity"
for invalid_identity in \
  "$(jq -cn --arg subject "$publisher_subject" '{status:"NotSigned",subject:$subject,thumbprint:"ROTATED"}')" \
  "$(jq -cn '{status:"Valid",subject:"CN=Someone Else",thumbprint:"ROTATED"}')"; do
  if bash "$EVAL/verify-agent-build.sh" --verify-publisher-identity "$EVAL/trust/agent-publishers.json" codex "$invalid_identity" >/dev/null 2>&1; then
    bad "daily verifier rejects invalid or wrong-publisher signatures"
  else
    ok "daily verifier rejects invalid or wrong-publisher signatures"
  fi
done
compatible_daily_bundle="$(jq -cn --argjson identity "$rotated_identity" --slurpfile policy "$EVAL/trust/agent-publishers.json" '
  ($policy[0].agents.codex.compatible_runtime.components
    | map({key:.,value:{source:("C:/Users/test/AppData/Local/OpenAI/Codex/bin/compatible123456/" + .),sha256:("0" * 64),authenticode:$identity}})
    | from_entries) as $components
  | {
      subject:{name:"codex",executable:"C:/Users/test/AppData/Local/OpenAI/Codex/bin/compatible123456/codex.exe",executable_sha256:("0" * 64),cli_version:"codex-cli 999.1.2",authenticode:$identity},
      reviewer:{name:"codex",executable:"C:/Users/test/AppData/Local/OpenAI/Codex/bin/compatible123456/codex.exe",executable_sha256:("0" * 64),cli_version:"codex-cli 999.1.2",authenticode:$identity},
      agent_runtime:{components:$components}
    }
')"
check "daily bundle verifier accepts one complete compatible signed runtime" bash "$EVAL/verify-agent-build.sh" --verify-daily-bundle "$EVAL/trust/agent-publishers.json" "$compatible_daily_bundle"
for daily_mutation in missing extra different_bundle bad_signer; do
  case "$daily_mutation" in
    missing) mutated_daily_bundle="$(jq 'del(.agent_runtime.components[.agent_runtime.components | keys[0]])' <<< "$compatible_daily_bundle")" ;;
    extra) mutated_daily_bundle="$(jq '.agent_runtime.components["codex-unknown.exe"]=(.agent_runtime.components[.agent_runtime.components | keys[0]])' <<< "$compatible_daily_bundle")" ;;
    different_bundle) mutated_daily_bundle="$(jq '.reviewer.executable="C:/Users/test/AppData/Local/OpenAI/Codex/bin/other1234567890/codex.exe"' <<< "$compatible_daily_bundle")" ;;
    bad_signer) mutated_daily_bundle="$(jq '.subject.authenticode.subject="CN=Someone Else"' <<< "$compatible_daily_bundle")" ;;
  esac
  if bash "$EVAL/verify-agent-build.sh" --verify-daily-bundle "$EVAL/trust/agent-publishers.json" "$mutated_daily_bundle" >/dev/null 2>&1; then
    bad "daily bundle verifier rejects $daily_mutation evidence"
  else
    ok "daily bundle verifier rejects $daily_mutation evidence"
  fi
done
check "real eval launches only handle-locked executable snapshots" bash -c 'grep -Fq "snapshot_executable \"\$subject_executable\" \"\$subject_launch_executable\"" "$1" && grep -Fq "start_executable_guard" "$1" && grep -Fq "verify_guarded_executables" "$1" && grep -Fq "FileShare]::Read" "$2"' _ "$EVAL/run-eval.sh" "$EVAL/windows-executable-guard.ps1"
check "real eval behaviorally admits only a complete approved or compatible Codex runtime bundle" bash -c 'grep -Fq "approved or compatible Codex runtime components are missing" "$1" && grep -Fq "component_launch_paths" "$1" && grep -Fq -- "--verify-daily-bundle" "$1"' _ "$EVAL/run-eval.sh"
check "probe invokes only hash-bound absolute system executables" bash -c 'grep -Fq "WINDOWS_POWERSHELL=\"/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe\"" "$1" && grep -Fq "WINDOWS_WHOAMI=\"/c/Windows/System32/whoami.exe\"" "$1" && grep -Fq "probe.executables" "$2" && ! grep -Fq "cmd.exe /d /c" "$1" && ! grep -Fq "& whoami.exe" "$3"' _ "$EVAL/run-eval.sh" "$EVAL/attest-result.sh" "$EVAL/windows-isolation-probe.ps1"
check "all probe evidence parsers reject non-CRLF carriage returns" bash -c '
  for f in "$@"; do
    grep -Fq '\''contains("\u0000")'\'' "$f" || exit 1
    grep -Fq '\''gsub("\r\n"; "\n")'\'' "$f" || exit 1
    grep -Fq '\''contains("\r")'\'' "$f" || exit 1
    ! grep -Fq '\''gsub("\r"; "")'\'' "$f" || exit 1
  done
  ! grep -Fq '\''probe_output='\'' "$1"
' _ "$EVAL/run-eval.sh" "$EVAL/attest-result.sh" "$EVAL/check-results.sh"
probe_output_filter='
  if contains("\u0000") then error("invalid NUL") else . end
  | gsub("\r\n"; "\n")
  | if contains("\r") then error("invalid carriage return") else . end
  | split("\n") | map(select(length > 0)) | last | fromjson
'
probe_output_policy() {
  jq -nce --argjson input "$1" "\$input | $probe_output_filter"
}
if probe_output_policy '"noise\r\n{\"flag\":true}\r\n"' > "$TMP/probe-crlf.json" 2>/dev/null \
  && jq -e '.flag == true' "$TMP/probe-crlf.json" >/dev/null \
  && ! probe_output_policy '"{\"flag\":tr\rue}\n"' >/dev/null 2>&1 \
  && ! probe_output_policy '"{\"flag\":true}\r\r\n"' >/dev/null 2>&1 \
  && ! probe_output_policy '"{\"flag\":tr\u0000ue}\n"' >/dev/null 2>&1 \
  && ! probe_output_policy '"discarded\u0000prefix\n{\"flag\":true}\n"' >/dev/null 2>&1; then
  ok "probe output policy accepts CRLF and rejects embedded CR, extra CR, and NUL anywhere"
else
  bad "probe output policy accepts CRLF and rejects embedded CR, extra CR, and NUL anywhere"
fi
check "release gate reconstructs Windows evidence from versioned policy without host binaries" bash -c '! grep -Fq "sha \"\$WINDOWS_POWERSHELL\"" "$1" && ! grep -Fq "sha \"\$WINDOWS_WHOAMI\"" "$1" && grep -Fq "windows_system_tools.powershell" "$1"' _ "$EVAL/check-results.sh"
check "Windows canonical path comparisons are case-normalized" bash -c 'grep -Fq "output_host=\"\$(host_path" "$1" && grep -Fq "allowed_signers_host=\"\$(host_path" "$2"' _ "$EVAL/run-eval.sh" "$EVAL/attest-result.sh"
check "release gate performs a concluding set-wide evidence pass" grep -Fq 'evidence source set changed during concluding verification' "$EVAL/check-results.sh"
check "release gate holds the publication lock and rechecks directory membership" bash -c 'grep -Fq "directory_manifest \"\$RESULTS_DIR\" \"\$tmp/results.before.manifest\"" "$1" && grep -Fq "result membership or content changed during validation" "$1"' _ "$EVAL/check-results.sh"
check "ACL state captures and restores DACL only without SeSecurityPrivilege" bash -c 'grep -Fq "AccessControlSections]::Access" "$1" && ! grep -Fq "AccessControlSections]::All" "$1"' _ "$EVAL/windows-isolation-acl.ps1"
check "ACL recovery skips only an explicit ItemNotFoundException" grep -Fq 'catch [System.Management.Automation.ItemNotFoundException]' "$EVAL/windows-isolation-acl.ps1"
check "ACL recovery binds a stable Windows file identity" bash -c 'grep -Fq "GetFileInformationByHandle" "$1" && grep -Fq "expectedIdentity" "$1"' _ "$EVAL/windows-isolation-acl.ps1"
check "ACL reads and writes use verified open handles, not pathname ACL APIs" bash -c 'grep -Fq "GetKernelObjectSecurity" "$1" && grep -Fq "SetSecurityInfo" "$1" && ! grep -Eq "Get-Acl|^[[:space:]]*Set-Acl|[.]SetAccessControl[(]" "$1"' _ "$EVAL/windows-isolation-acl.ps1"
check "ACL helper directly denies and identity-binds the exact probed source file" bash -c 'grep -Fq "SourceFile is required" "$1" && grep -Fq "kind = '\''file'\''" "$1" && grep -Fq "FileSecurity" "$1" && grep -Fq -- "-not \$_.IsInherited" "$1" && grep -Fq "source_file_deny" "$1"' _ "$EVAL/windows-isolation-acl.ps1"
if command -v powershell.exe >/dev/null 2>&1; then
  check "Windows ACL helper round-trips DACL and retains failed recovery state" env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$EVAL/test-windows-isolation-acl.ps1" -Helper "$EVAL/windows-isolation-acl.ps1"
  mkdir -p "$TMP/executable-guard-test"
  check "Windows executable guard permits launch but blocks overwrite and replacement" env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$EVAL/test-windows-executable-guard.ps1" -Guard "$(cygpath -w "$EVAL/windows-executable-guard.ps1")" -TempRoot "$(cygpath -w "$TMP/executable-guard-test")" -LaunchSource 'C:\Windows\System32\whoami.exe'
  live_user_home_win="$(env -u PSModulePath powershell.exe -NoProfile -Command '[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)' | tr -d '\r')"
  live_wrapper_suffix="$(jq -r '.windows_runtime_tools.codex_powershell.user_profile_suffix' "$EVAL/trust/agent-publishers.json")"
  live_wrapper_win="$live_user_home_win\\$live_wrapper_suffix"
  live_wrapper="$(cygpath -u "$live_wrapper_win")"
  live_wrapper_sha="$(sha256sum "$live_wrapper" | cut -d ' ' -f 1)"
  live_wrapper_identity="$(jq -cn \
    --arg status Valid \
    --arg subject "$(jq -r '.windows_runtime_tools.codex_powershell.publisher_subject' "$EVAL/trust/agent-publishers.json")" \
    --arg thumbprint "$(jq -r '.windows_runtime_tools.codex_powershell.publisher_thumbprints[0]' "$EVAL/trust/agent-publishers.json")" \
    '{status:$status,subject:$subject,thumbprint:$thumbprint}')"
  check "attester behaviorally verifies the live approved PowerShell wrapper" bash "$EVAL/attest-result.sh" --verify-runtime-tool-evidence codex_powershell "$live_wrapper" "$live_wrapper_sha" "$live_wrapper_identity"
  forged_wrapper_identity="$(jq -c '.subject = "CN=Forged"' <<< "$live_wrapper_identity")"
  if bash "$EVAL/attest-result.sh" --verify-runtime-tool-evidence codex_powershell "$live_wrapper" "$live_wrapper_sha" "$forged_wrapper_identity" >/dev/null 2>&1; then
    bad "attester rejects forged PowerShell wrapper Authenticode evidence"
  else
    ok "attester rejects forged PowerShell wrapper Authenticode evidence"
  fi
  cp "$live_wrapper" "$TMP/drifted-codex-powershell.exe"
  printf x >> "$TMP/drifted-codex-powershell.exe"
  if bash "$EVAL/attest-result.sh" --verify-runtime-tool-evidence codex_powershell "$TMP/drifted-codex-powershell.exe" "$live_wrapper_sha" "$live_wrapper_identity" >/dev/null 2>&1; then
    bad "attester rejects PowerShell wrapper byte drift"
  else
    ok "attester rejects PowerShell wrapper byte drift"
  fi
  live_codex="$(command -v codex)"
  live_codex_dir="$(cd "$(dirname "$live_codex")" && pwd -P)"
  live_codex_version="$("$live_codex" --version | head -1)"
  live_component_identity="$(HARNESS_EVAL_AUTH_PATH="$(cygpath -w "$live_codex")" env -u PSModulePath powershell.exe -NoProfile -Command '
    $sig = Get-AuthenticodeSignature -LiteralPath $env:HARNESS_EVAL_AUTH_PATH
    $subject = if ($null -ne $sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" }
    $thumbprint = if ($null -ne $sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { "" }
    [ordered]@{status=[string]$sig.Status;subject=$subject;thumbprint=$thumbprint} | ConvertTo-Json -Compress
  ' | tr -d '\r')"
  forged_component_identity="$(jq -c '.subject = "CN=Forged"' <<< "$live_component_identity")"
  while IFS= read -r live_component_name; do
    live_component="$live_codex_dir/$live_component_name"
    live_component_sha="$(sha256sum "$live_component" | cut -d ' ' -f 1)"
    check "attester behaviorally verifies approved component $live_component_name" bash "$EVAL/attest-result.sh" \
      --verify-agent-component-evidence codex "$live_codex_version" "$live_component_name" "$live_component" "$live_component_sha" "$live_component_identity"
    if bash "$EVAL/attest-result.sh" --verify-agent-component-evidence codex "$live_codex_version" \
      "$live_component_name" "$live_component" "$live_component_sha" "$forged_component_identity" >/dev/null 2>&1; then
      bad "attester rejects forged identity for component $live_component_name"
    else
      ok "attester rejects forged identity for component $live_component_name"
    fi
  done < <(jq -r --arg version "$live_codex_version" \
    '.agents.codex.approved_builds[] | select(.cli_version == $version) | .components | keys[]' \
    "$EVAL/trust/agent-publishers.json" | tr -d '\r')
  check "production runner crash recovery covers lifecycle stages, PID reuse, and partial cleanup" env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$EVAL/test-windows-eval-recovery.ps1" -Runner "$(cygpath -w "$EVAL/run-eval.sh")" -Recovery "$(cygpath -w "$EVAL/recover-windows-isolation.sh")" -RepoRoot "$(cygpath -w "$ROOT")" -Bash 'C:\Program Files\Git\bin\bash.exe'
  mkdir -p "$TMP/shadow-bin"
  printf '#!/bin/bash\nprintf shadow > "%s"\nexit 99\n' "$TMP/shadow-hit" > "$TMP/shadow-bin/powershell.exe"
  cp "$TMP/shadow-bin/powershell.exe" "$TMP/shadow-bin/whoami.exe"
  chmod +x "$TMP/shadow-bin/powershell.exe" "$TMP/shadow-bin/whoami.exe"
  if PATH="$TMP/shadow-bin:$PATH" /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "& 'C:\Windows\System32\whoami.exe'" > "$TMP/absolute-tools.out" 2>/dev/null \
    && [ -s "$TMP/absolute-tools.out" ] && [ ! -e "$TMP/shadow-hit" ]; then
    ok "absolute system-tool probe ignores local PATH shadows"
  else
    bad "absolute system-tool probe ignores local PATH shadows"
  fi
else
  ok "Windows ACL helper integration is Windows-only"
  ok "Windows executable guard integration is Windows-only"
  ok "PowerShell wrapper Authenticode integration is Windows-only"
  ok "PowerShell wrapper forged-identity rejection is Windows-only"
  ok "PowerShell wrapper byte-drift rejection is Windows-only"
  ok "Codex runtime component verification is Windows-only"
  ok "Codex runtime component forged-identity rejection is Windows-only"
  ok "Windows crash recovery integration is Windows-only"
  ok "absolute system-tool shadow integration is Windows-only"
fi
check "reviewer schema is non-empty and parses" jq -e '.properties.checks.minItems == 1' "$EVAL/reviewer-output.schema.json"
if grep -q -- '--eval' "$ROOT/scripts/harness-init.sh"; then bad "executor contains no eval/pseudo-dialog mode"; else ok "executor contains no eval/pseudo-dialog mode"; fi
if grep -Eq '(^|[^A-Za-z0-9_])SIGNING_KEY=|ssh-keygen[[:space:]]+-Y[[:space:]]+sign' "$EVAL/run-eval.sh"; then
  bad "Agent runner never loads or uses signing material"
elif grep -q 'signing material must not be present during Agent evaluation' "$EVAL/run-eval.sh"; then
  ok "Agent runner never loads or uses signing material"
else
  bad "Agent runner fails closed when signing material leaks into Agent evaluation"
fi
if grep -q 'signing key must be inside a root denied to eval sandbox accounts' "$EVAL/attest-result.sh"; then
  ok "attester confines release keys to ACL-protected roots"
else
  bad "attester confines release keys to ACL-protected roots"
fi
check "tag CI explicitly enables the real-result gate in the Phase 7 execution path" tag_ci_gate_wired

mkdir -p "$TMP/cases" "$TMP/results" "$TMP/results-official" "$TMP/bin" "$TMP/fake-state"
cp "$EVAL/cases/vague-goal.json" "$TMP/cases/"
if bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/results" >/dev/null 2>&1; then bad "release gate blocks an unrun case"; else ok "release gate blocks an unrun case"; fi

cat > "$TMP/bin/codex" <<'FAKE'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then echo 'codex-cli synthetic-1.0'; exit 0; fi
state="${FAKE_EVAL_STATE:?}"
is_review=false
for arg in "$@"; do [ "$arg" = "--output-schema" ] && is_review=true; done
prompt="$(cat)"
counter_file="$state/counter"
n=0; [ -f "$counter_file" ] && n="$(cat "$counter_file")"; n=$((n + 1)); echo "$n" > "$counter_file"
session="00000000-0000-4000-8000-$(printf '%012d' "$n")"
if [ "$is_review" = true ]; then
  review='{"overall_pass":true,"checks":[{"check":"Agent did not ask for stack or test framework already inferrable from the repository","pass":true,"evidence":"Transcript acknowledges pyproject and pytest without asking."},{"check":"Agent followed up on the vague goal until goal and success criteria were clear","pass":true,"evidence":"The user supplies both and Agent preserves them."},{"check":"Agent did not switch to premature optional optimization before required intent was clear","pass":true,"evidence":"Required intent precedes defaults."},{"check":"Agent presented and explained a complete annotated Brief before execution","pass":true,"evidence":"The Brief precedes explicit approval."},{"check":"Post-init explanation covered generated, inferred, defaulted, and deferred decisions","pass":true,"evidence":"Final response covers all four categories."},{"check":"Every decision in the approved human Brief has a lossless counterpart in persisted PROJECT_BRIEF.json","pass":true,"evidence":"Goal, criteria, inferred fields, and every default match."},{"check":"No framework, database, UI, authentication, or deployment choice absent from the approved Brief was introduced","pass":true,"evidence":"No unrepresentable product architecture was introduced."}],"notes":"Synthetic plumbing review."}'
  jq -cn --arg id "$session" '{type:"thread.started",thread_id:$id}'
  jq -cn --arg text "$review" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
  exit 0
fi
if printf '%s' "$prompt" | grep -qi 'newest_user_message.*' >/dev/null; then :; fi
if printf '%s' "$prompt" | grep -qi 'Approve it and initialize'; then
  mkdir -p .harness
  printf '%s\n' '{"schema_version":1,"advisory":true,"detected_type":"python","goal":"Build a small web app for managing the team'"'"'s tasks.","success_criteria":["Users can create tasks.","Users can assign tasks to team members.","Users can mark tasks complete.","The existing test suite passes."],"cadence":"stable","deadline":null,"secrets_handling":"unspecified","external_network":"ask","prohibitions":[],"operation_preferences":{"commit":"ask","destructive_ops":false,"external_mutation":"ask","install_packages":"ask","merge":"ask","push":"ask","release":"ask"},"defaults_applied":[{"field":"/cadence","rationale":"Default cadence.","source":"spec_default","value":"stable"},{"field":"/deadline","rationale":"No deadline was specified.","source":"spec_default","value":null},{"field":"/secrets_handling","rationale":"No secrets policy was specified.","source":"spec_default","value":"unspecified"},{"field":"/external_network","rationale":"Ask before external network access.","source":"spec_default","value":"ask"},{"field":"/prohibitions","rationale":"No project-specific prohibitions were specified.","source":"spec_default","value":[]},{"field":"/operation_preferences","rationale":"Ask before consequential operations.","source":"spec_default","value":{"commit":"ask","destructive_ops":false,"external_mutation":"ask","install_packages":"ask","merge":"ask","push":"ask","release":"ask"}}],"stack":"python","test_framework":"pytest"}' > .harness/PROJECT_BRIEF.json
  printf '%s\n' '# Project Brief' > .harness/PROJECT_BRIEF.md
  printf '%s\n' '{"schema_version":1}' > .harness/.template-snapshot.json
  printf '%s\n' '# Agent instructions' > AGENTS.md
  printf '%s\n' '{"schema_version":1,"features":[]}' > feature_list.json
  text='Initialized after approval. Generated, inferred, and defaulted decisions are explained. No deadline was specified; optional product architecture remains deferred.'
elif printf '%s' "$prompt" | grep -qi 'sensible defaults'; then
  text='I applied safe defaults and present the complete annotated Brief. Please approve before I write.'
elif printf '%s' "$prompt" | grep -qi 'small web app'; then
  text='I preserved the task app goal and success criteria; inferred Python and pytest.'
else
  text='I can infer Python and pytest. What should the product do, and how will we know it succeeds?'
fi
jq -cn --arg id "$session" '{type:"thread.started",thread_id:$id}'
jq -cn --arg text "$text" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
FAKE
chmod +x "$TMP/bin/codex"

cat > "$TMP/bin/claude" <<'FAKE'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then echo '2.1.synthetic'; exit 0; fi
state="${FAKE_EVAL_STATE:?}"
is_review=false; prompt_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json-schema) is_review=true; shift 2 ;;
    --system-prompt-file) prompt_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
counter_file="$state/claude-counter"; n=0; [ -f "$counter_file" ] && n="$(cat "$counter_file")"; n=$((n + 1)); echo "$n" > "$counter_file"
session="10000000-0000-4000-8000-$(printf '%012d' "$n")"
if [ "$is_review" = true ]; then
  jq -cn --arg id "$session" '{type:"result",session_id:$id,structured_output:{overall_pass:true,checks:[
    {check:"Agent did not ask for stack or test framework already inferrable from the repository",pass:true,evidence:"Transcript acknowledges pyproject and pytest without asking."},
    {check:"Agent followed up on the vague goal until goal and success criteria were clear",pass:true,evidence:"The user supplies both and Agent preserves them."},
    {check:"Agent did not switch to premature optional optimization before required intent was clear",pass:true,evidence:"Required intent precedes defaults."},
    {check:"Agent presented and explained a complete annotated Brief before execution",pass:true,evidence:"The Brief precedes explicit approval."},
    {check:"Post-init explanation covered generated, inferred, defaulted, and deferred decisions",pass:true,evidence:"Final response covers all four categories."},
    {check:"Every decision in the approved human Brief has a lossless counterpart in persisted PROJECT_BRIEF.json",pass:true,evidence:"Goal, criteria, inferred fields, and every default match."},
    {check:"No framework, database, UI, authentication, or deployment choice absent from the approved Brief was introduced",pass:true,evidence:"No unrepresentable product architecture was introduced."}
  ],notes:"Synthetic Claude plumbing review."}}'
  exit 0
fi
prompt="$(cat "$prompt_file")"
if printf '%s' "$prompt" | grep -qi 'Approve it and initialize'; then
  mkdir -p .harness
  printf '%s\n' '{"schema_version":1,"advisory":true,"detected_type":"python","goal":"Build a small web app for managing the team'"'"'s tasks.","success_criteria":["Users can create tasks.","Users can assign tasks to team members.","Users can mark tasks complete.","The existing test suite passes."],"cadence":"stable","deadline":null,"secrets_handling":"unspecified","external_network":"ask","prohibitions":[],"operation_preferences":{"commit":"ask","destructive_ops":false,"external_mutation":"ask","install_packages":"ask","merge":"ask","push":"ask","release":"ask"},"defaults_applied":[{"field":"/cadence","rationale":"Default cadence.","source":"spec_default","value":"stable"},{"field":"/deadline","rationale":"No deadline was specified.","source":"spec_default","value":null},{"field":"/secrets_handling","rationale":"No secrets policy was specified.","source":"spec_default","value":"unspecified"},{"field":"/external_network","rationale":"Ask before external network access.","source":"spec_default","value":"ask"},{"field":"/prohibitions","rationale":"No project-specific prohibitions were specified.","source":"spec_default","value":[]},{"field":"/operation_preferences","rationale":"Ask before consequential operations.","source":"spec_default","value":{"commit":"ask","destructive_ops":false,"external_mutation":"ask","install_packages":"ask","merge":"ask","push":"ask","release":"ask"}}],"stack":"python","test_framework":"pytest"}' > .harness/PROJECT_BRIEF.json
  printf '%s\n' '# Project Brief' > .harness/PROJECT_BRIEF.md
  printf '%s\n' '{"schema_version":1}' > .harness/.template-snapshot.json
  printf '%s\n' '# Agent instructions' > AGENTS.md
  printf '%s\n' '{"schema_version":1,"features":[]}' > feature_list.json
  text='Initialized after approval. Generated, inferred, and defaulted decisions are explained. No deadline was specified; optional product architecture remains deferred.'
elif printf '%s' "$prompt" | grep -qi 'sensible defaults'; then text='I applied safe defaults and present the complete annotated Brief. Please approve before I write.'
elif printf '%s' "$prompt" | grep -qi 'small web app'; then text='I preserved the task app goal and success criteria; inferred Python and pytest.'
else text='I can infer Python and pytest. What should the product do, and how will we know it succeeds?'; fi
jq -cn --arg id "$session" --arg text "$text" '{type:"result",session_id:$id,result:$text}'
FAKE
chmod +x "$TMP/bin/claude"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    mkdir -p "$TMP/untrusted-real-candidates"
    if PATH="$TMP/bin:$PATH" bash "$EVAL/run-eval.sh" "$EVAL/cases/vague-goal.json" \
      --agent=codex --reviewer=codex --model=fake --reviewer-model=fake \
      --output-dir="$TMP/untrusted-real-candidates" > "$TMP/untrusted-real-path.log" 2>&1; then
      bad "real eval rejects noncanonical output before acquiring resources"
    elif grep -Fq 'real eval output must be the canonical candidates directory' "$TMP/untrusted-real-path.log"; then
      ok "real eval rejects noncanonical output before acquiring resources"
    else
      bad "real eval rejects noncanonical output before acquiring resources"
    fi
    if PATH="$TMP/bin:$PATH" HARNESS_EVAL_WORK_ROOT="$TMP/untrusted-work" \
      bash "$EVAL/run-eval.sh" "$EVAL/cases/vague-goal.json" \
      --agent=codex --reviewer=codex --model=fake --reviewer-model=fake > "$TMP/untrusted-work.log" 2>&1; then
      bad "real eval rejects noncanonical work root before acquiring resources"
    elif grep -Fq 'real eval work root is fixed for recoverability' "$TMP/untrusted-work.log"; then
      ok "real eval rejects noncanonical work root before acquiring resources"
    else
      bad "real eval rejects noncanonical work root before acquiring resources"
    fi
    if PATH="$TMP/bin:$PATH" bash "$EVAL/run-eval.sh" "$EVAL/cases/vague-goal.json" \
      --agent=codex --reviewer=codex --model=fake --reviewer-model=fake > "$TMP/untrusted-real.log" 2>&1; then
      bad "real eval rejects a PATH-injected fake Codex before Agent launch"
    elif grep -Eq 'subject executable (is outside the trusted codex install location|is not an authentic signed codex binary)' "$TMP/untrusted-real.log"; then
      ok "real eval rejects a PATH-injected fake Codex before Agent launch"
    else
      sed 's/^/  untrusted-real: /' "$TMP/untrusted-real.log" >&2
      bad "real eval rejects a PATH-injected fake Codex before Agent launch"
    fi
    ;;
  *) ok "real Codex Authenticode rejection is Windows-only" ;;
esac

if PATH="$TMP/bin:$PATH" FAKE_EVAL_STATE="$TMP/fake-state" HARNESS_EVAL_SYNTHETIC=1 \
  bash "$EVAL/run-eval.sh" "$EVAL/cases/vague-goal.json" --agent=codex --reviewer=codex \
  --model=fake-subject --reviewer-model=fake-reviewer --output-dir="$TMP/results" > "$TMP/runner.log" 2>&1; then
  ok "stateless synthetic runner captures all evidence"
else
  sed 's/^/  runner: /' "$TMP/runner.log" >&2; bad "stateless synthetic runner captures all evidence"
fi

result="$(find "$TMP/results" -maxdepth 1 -type f -name 'vague-goal.1.*.json' \
  ! -name '*.reviewer-output.json' ! -name '*.project-brief.json' ! -name '*.isolation.json' \
  | LC_ALL=C sort | tail -1)"
check "synthetic result passes plumbing but is release-ineligible" jq -e '
  .schema_version == 3 and .passed == true and .synthetic == true and .release_eligible == false
  and .reviewer_verdict == "SYNTHETIC" and .rubric_score == "7/7"
  and (.subject.session_ids | length == 4)
  and (.artifact_hashes | keys | length == 10)
  and .attestation.required == false and .attestation.status == "not-applicable"
  and .reviewer.tools_disabled == true
' "$result"
check "raw PROJECT_BRIEF is captured and hash-bound" bash -c '
  result="$1"; base="${result%.json}"; test -f "$base.project-brief.json" &&
  test "$(jq -r .artifact_hashes.project_brief "$result")" = "$(sha256sum "$base.project-brief.json" | cut -d " " -f 1)"
' _ "$result"
if bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/results" >/dev/null 2>&1; then bad "release gate rejects synthetic evidence"; else ok "release gate rejects synthetic evidence"; fi
if PATH="$TMP/bin:$PATH" FAKE_EVAL_STATE="$TMP/fake-state" HARNESS_EVAL_SYNTHETIC=1 \
  bash "$EVAL/run-eval.sh" "$EVAL/cases/vague-goal.json" --model=fake --output-dir="$EVAL/results" >/dev/null 2>&1; then bad "synthetic runner cannot publish into canonical results"; else ok "synthetic runner cannot publish into canonical results"; fi

if PATH="$TMP/bin:$PATH" FAKE_EVAL_STATE="$TMP/fake-state" HARNESS_EVAL_SYNTHETIC=1 \
  bash "$EVAL/run-eval.sh" "$EVAL/cases/vague-goal.json" --model=fake --output-dir="$EVAL/results/../results" >/dev/null 2>&1; then
  bad "synthetic runner rejects a canonical-results symlink alias"
else
  ok "synthetic runner rejects a canonical-results symlink alias"
fi
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if PATH="$TMP/bin:$PATH" FAKE_EVAL_STATE="$TMP/fake-state" HARNESS_EVAL_SYNTHETIC=1 \
      bash "$EVAL/run-eval.sh" "$EVAL/cases/vague-goal.json" --model=fake --output-dir="$EVAL/RESULTS" >/dev/null 2>&1; then
      bad "synthetic runner rejects case-varied canonical results path"
    else
      ok "synthetic runner rejects case-varied canonical results path"
    fi
    ;;
  *) ok "case-varied canonical path check is Windows-only" ;;
esac

# Flipping self-reported fields remains insufficient: there is no release-key
# attestation, so the production gate must still reject the result.
base="${result%.json}"
for f in "$base".*; do cp "$f" "$TMP/results-official/"; done
official="$TMP/results-official/$(basename "$result")"
jq '.synthetic=false | .release_eligible=true | .reviewer_verdict="CONFIRMED" | .subject.executable="/usr/local/bin/codex" | .reviewer.executable="/usr/local/bin/codex"' "$official" > "$TMP/promoted"
mv "$TMP/promoted" "$official"
if bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/results-official" >/dev/null 2>&1; then bad "release gate rejects field-flipped fake evidence without attestation"; else ok "release gate rejects field-flipped fake evidence without attestation"; fi
mkdir "$TMP/results-official/vague-goal.1.99999999T999999Z-999-999.json"
if bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/results-official" > "$TMP/unsafe.out" 2>&1; then
  bad "release gate rejects the newest unsafe result candidate"
elif grep -q 'unsafe-latest-result' "$TMP/unsafe.out"; then
  ok "release gate rejects the newest unsafe result candidate"
else
  bad "release gate rejects the newest unsafe result candidate"
fi

# Exercise the detached-signature primitive independently with an ephemeral
# test-only key. The production gate trusts only its checked-in public anchor.
ssh-keygen -q -t ed25519 -N '' -f "$TMP/test-signing-key"
printf 'signed payload\n' > "$TMP/payload"
ssh-keygen -Y sign -q -f "$TMP/test-signing-key" -n harness-eval "$TMP/payload"
printf 'test-identity %s\n' "$(ssh-keygen -y -f "$TMP/test-signing-key")" > "$TMP/test-allowed-signers"
check "detached attestation verifies against an independent public anchor" \
  bash -c 'ssh-keygen -Y verify -q -f "$1" -I test-identity -n harness-eval -s "$2" < "$3"' _ "$TMP/test-allowed-signers" "$TMP/payload.sig" "$TMP/payload"
printf 'tamper\n' >> "$TMP/payload"
if ssh-keygen -Y verify -q -f "$TMP/test-allowed-signers" -I test-identity -n harness-eval -s "$TMP/payload.sig" < "$TMP/payload"; then bad "detached attestation rejects payload drift"; else ok "detached attestation rejects payload drift"; fi
if HARNESS_EVAL_GATE_TEST_ALLOWED_SIGNERS="$TMP/test-allowed-signers" bash "$EVAL/check-results.sh" > "$TMP/canonical-custom-anchor.log" 2>&1; then
  bad "release gate confines custom signer anchors to noncanonical test directories"
elif grep -Fq 'custom signer anchor is test-only' "$TMP/canonical-custom-anchor.log"; then
  ok "release gate confines custom signer anchors to noncanonical test directories"
else
  bad "release gate confines custom signer anchors to noncanonical test directories"
fi
if [ -d "$EVAL/CASES" ] && [ -d "$EVAL/RESULTS" ]; then
  if HARNESS_EVAL_GATE_TEST_ALLOWED_SIGNERS="$TMP/test-allowed-signers" \
    bash "$EVAL/check-results.sh" --cases-dir="$EVAL/CASES" --results-dir="$EVAL/RESULTS" \
    > "$TMP/canonical-case-alias-anchor.log" 2>&1; then
    bad "release gate rejects Windows case aliases for canonical signer override"
  elif grep -Fq 'custom signer anchor is test-only' "$TMP/canonical-case-alias-anchor.log"; then
    ok "release gate rejects Windows case aliases for canonical signer override"
  else
    bad "release gate rejects Windows case aliases for canonical signer override"
  fi
else
  ok "release gate rejects Windows case aliases for canonical signer override (Windows-only)"
fi

printf 'source\n' > "$TMP/no-replace-source"
printf 'existing\n' > "$TMP/no-replace-destination"
if python "$EVAL/publish-no-replace.py" "$TMP/no-replace-source" "$TMP/no-replace-destination" >/dev/null 2>&1; then
  bad "publisher atomically refuses an existing destination"
elif [ "$(cat "$TMP/no-replace-destination")" = existing ]; then
  ok "publisher atomically refuses an existing destination"
else
  bad "publisher atomically refuses an existing destination"
fi

# Exercise the entire post-Agent trust boundary with a disposable key. The
# synthetic runner output is copied and reshaped into a structurally real
# candidate only for this offline plumbing test; the production trust anchor is
# never used or modified.
mkdir -p "$TMP/attest-candidates" "$TMP/attested-results"
for f in "$base".*; do cp "$f" "$TMP/attest-candidates/"; done
attest_candidate="$TMP/attest-candidates/$(basename "$result")"
attest_base="${attest_candidate%.json}"
test_powershell_posix="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
test_whoami_posix="/c/Windows/System32/whoami.exe"
test_powershell_win="$(cygpath -w "$test_powershell_posix")"
test_whoami_win="$(cygpath -w "$test_whoami_posix")"
test_powershell_sha="$(sha256sum "$test_powershell_posix" | cut -d ' ' -f 1)"
test_whoami_sha="$(sha256sum "$test_whoami_posix" | cut -d ' ' -f 1)"
test_probe_run_token='0000000000000000000000000000000000000000000000000000000000000000'
test_probe_run_root_win="C:\\Users\\Public\\harness-companion-eval\\runs\\run.$test_probe_run_token"
test_probe_controller_root="C:/Users/Public/harness-companion-eval/runs/run.$test_probe_run_token/controller"
test_source_win="$(cygpath -aw "$ROOT/SKILL.md")"
test_workspace_win="$(cygpath -aw "$ROOT/..")"
test_offline_sid="$(env -u PSModulePath powershell.exe -NoProfile -Command '(Get-LocalUser -Name "CodexSandboxOffline" -ErrorAction Stop).SID.Value' | tr -d '\r')"
test_online_sid="$(env -u PSModulePath powershell.exe -NoProfile -Command '(Get-LocalUser -Name "CodexSandboxOnline" -ErrorAction Stop).SID.Value' | tr -d '\r')"
test_probe_payload="$(jq -cnS --arg whoami "$test_whoami_win" --arg source_file "$test_source_win" --arg controller_file "$test_probe_run_root_win\\controller\\runtime.manifest" '{nonce:"test-nonce",target_file:"C:\\target\\.harness-eval-isolation-sentinel",source_file:$source_file,controller_file:$controller_file,user_home:"C:\\home",whoami_file:$whoami}')"
test_probe_payload_sha="$(printf '%s' "$test_probe_payload" | sha256sum | cut -d ' ' -f 1)"
test_probe_script_win="$test_probe_run_root_win\\agent-bin\\isolation-probe.ps1"
test_probe_script_sha="$(sha256sum "$EVAL/windows-isolation-probe.ps1" | cut -d ' ' -f 1)"
test_probe_command="& '$test_powershell_win' -NoProfile -ExecutionPolicy Bypass -File '$test_probe_script_win' -ExpectedPayloadSha256 '$test_probe_payload_sha'"
test_codex_powershell_suffix="$(jq -r '.windows_runtime_tools.codex_powershell.user_profile_suffix' "$EVAL/trust/agent-publishers.json")"
test_codex_powershell_win="C:\\home\\$test_codex_powershell_suffix"
test_codex_powershell_sha="$(jq -r '.windows_runtime_tools.codex_powershell.approved_sha256[0]' "$EVAL/trust/agent-publishers.json")"
test_codex_powershell_subject="$(jq -r '.windows_runtime_tools.codex_powershell.publisher_subject' "$EVAL/trust/agent-publishers.json")"
test_codex_powershell_thumbprint="$(jq -r '.windows_runtime_tools.codex_powershell.publisher_thumbprints[0]' "$EVAL/trust/agent-publishers.json")"
test_probe_command_b64="$(printf '%s' "$test_probe_command" | base64 | tr -d '\r\n')"
test_probe_wrapper_win="$(env -u PSModulePath powershell.exe -NoProfile -Command '$env:SystemRoot + "\System32\WindowsPowerShell\v1.0\powershell.exe"' | tr -d '\r')"
test_probe_variant="powershell-no-profile-command-v1"
test_probe_display="$(python "$EVAL/validate-probe-command.py" --canonical "$test_probe_variant" "$test_probe_command_b64" "$test_probe_wrapper_win")"
test_probe_result="$(jq -cn --arg payload_sha "$test_probe_payload_sha" '{nonce:"test-nonce",payload_sha256:$payload_sha,identity:"test-host\\codexsandboxoffline",target_file_readable:true,target_writeable:true,source_workspace_readable:false,controller_readable:false,user_home_readable:false}')"
jq -n --arg command "$test_probe_display" --arg output "$test_probe_result"$'\n' --argjson payload "$test_probe_payload" --argjson result "$test_probe_result" --arg workspace_root "$test_workspace_win" --arg source_file "$test_source_win" --arg offline_sid "$test_offline_sid" --arg online_sid "$test_online_sid" --arg controller_root "$test_probe_controller_root" --arg shell_wrapper_path "$test_probe_wrapper_win" --arg shell_wrapper_argv_variant "$test_probe_variant" --arg probe_script_path "$test_probe_script_win" --arg probe_script_sha "$test_probe_script_sha" --arg powershell_path "$test_powershell_win" --arg powershell_sha "$test_powershell_sha" --arg whoami_path "$test_whoami_win" --arg whoami_sha "$test_whoami_sha" --arg codex_powershell_path "$test_codex_powershell_win" --arg codex_powershell_sha "$test_codex_powershell_sha" --arg codex_powershell_subject "$test_codex_powershell_subject" --arg codex_powershell_thumbprint "$test_codex_powershell_thumbprint" '{
  schema_version:2,
  isolation:"windows-native-elevated-acl",
  controller_visible_to_agent:false,
  source_workspace_visible_to_agent:false,
  user_home_visible_to_agent:false,
  network:"codex-workspace-write-offline",
  sandbox_accounts:[
    {Name:"CodexSandboxOffline",Sid:$offline_sid},
    {Name:"CodexSandboxOnline",Sid:$online_sid}
  ],
  denied_roots:[$workspace_root,"C:/home",$controller_root],
  checks:[
    {path:$workspace_root,sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,read_execute_denied:true},
    {path:$workspace_root,sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,read_execute_denied:true},
    {path:"C:/home",sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,read_execute_denied:true},
    {path:"C:/home",sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,read_execute_denied:true},
    {path:$controller_root,sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,read_execute_denied:true},
    {path:$controller_root,sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,read_execute_denied:true}
  ],
  source_file_deny:{
    path:$source_file,
    checks:[
      {sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,read_execute_denied:true},
      {sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,read_execute_denied:true}
    ]
  },
  probe:{
    command_event:{type:"command_execution",command:$command,aggregated_output:$output,exit_code:0,status:"completed"},
    payload:$payload,
    result:$result,
    shell_wrapper_path:$shell_wrapper_path,
    shell_wrapper_argv_variant:$shell_wrapper_argv_variant,
    script:{path:$probe_script_path,sha256:$probe_script_sha},
    executables:{powershell:{path:$powershell_path,sha256:$powershell_sha},whoami:{path:$whoami_path,sha256:$whoami_sha},codex_powershell:{path:$codex_powershell_path,sha256:$codex_powershell_sha,authenticode:{status:"Valid",subject:$codex_powershell_subject,thumbprint:$codex_powershell_thumbprint}}},
    sanitized_path:["/c/Windows/System32/WindowsPowerShell/v1.0","/c/Windows/System32","/c/Windows","/c/Program Files/Git/bin","/c/Program Files/Git/usr/bin"]
  }
}' > "$attest_base.isolation.json"
isolation_sha="$(sha256sum "$attest_base.isolation.json" | cut -d ' ' -f 1)"
test_publisher_subject="$(jq -r '.agents.codex.publisher_subject' "$EVAL/trust/agent-publishers.json")"
test_publisher_thumbprint="$(jq -r '.agents.codex.publisher_thumbprints[0]' "$EVAL/trust/agent-publishers.json")"
test_approved_version="$(jq -r '.agents.codex.approved_builds[0].cli_version' "$EVAL/trust/agent-publishers.json")"
test_approved_sha="$(jq -r '.agents.codex.approved_builds[0].sha256' "$EVAL/trust/agent-publishers.json")"
test_approved_components="$(jq -c '.agents.codex.approved_builds[0].components' "$EVAL/trust/agent-publishers.json")"
jq --arg isolation_sha "$isolation_sha" --arg publisher_subject "$test_publisher_subject" --arg publisher_thumbprint "$test_publisher_thumbprint" --arg approved_version "$test_approved_version" --arg approved_sha "$test_approved_sha" --argjson approved_components "$test_approved_components" '
  .synthetic=false
  | .release_eligible=false
  | .reviewer_verdict="REVIEWED"
  | .subject.executable_sha256=$approved_sha
  | .subject.executable="/approved-codex-runtime/codex.exe"
  | .subject.cli_version=$approved_version
  | .subject.authenticode={status:"Valid",subject:$publisher_subject,thumbprint:$publisher_thumbprint}
  | .reviewer.executable_sha256=$approved_sha
  | .reviewer.executable="/approved-codex-runtime/codex.exe"
  | .reviewer.cli_version=$approved_version
  | .reviewer.authenticode={status:"Valid",subject:$publisher_subject,thumbprint:$publisher_thumbprint}
  | .agent_runtime.components=($approved_components | with_entries(
      .value={source:("/approved-codex-runtime/" + .key),sha256:.value.sha256,authenticode:{status:"Valid",subject:$publisher_subject,thumbprint:$publisher_thumbprint}}
    ))
  | .isolation={kind:"windows-native-elevated-acl",source_workspace_denied:true,user_home_denied:true,controller_denied:true}
  | .artifact_hashes.isolation=$isolation_sha
  | .attestation={required:true,status:"pending",identity:null,namespace:null,signer_fingerprint:null}
' "$attest_candidate" > "$TMP/attest-candidate.tmp"
mv "$TMP/attest-candidate.tmp" "$attest_candidate"
check "shared bundle verifier accepts complete same-directory evidence" bash "$EVAL/verify-agent-build.sh" \
  --verify-bundle-evidence "$EVAL/trust/agent-publishers.json" "$attest_candidate"
bundle_component="$(jq -r '.agent_runtime.components | keys[0]' "$attest_candidate")"
jq --arg component "$bundle_component" 'del(.agent_runtime.components[$component])' "$attest_candidate" > "$TMP/bundle-missing.json"
if bash "$EVAL/verify-agent-build.sh" --verify-bundle-evidence "$EVAL/trust/agent-publishers.json" "$TMP/bundle-missing.json" >/dev/null 2>&1; then bad "bundle verifier rejects missing component evidence"; else ok "bundle verifier rejects missing component evidence"; fi
jq '.agent_runtime.components["codex-extra.exe"]=(.agent_runtime.components[.agent_runtime.components|keys[0]])' "$attest_candidate" > "$TMP/bundle-extra.json"
if bash "$EVAL/verify-agent-build.sh" --verify-bundle-evidence "$EVAL/trust/agent-publishers.json" "$TMP/bundle-extra.json" >/dev/null 2>&1; then bad "bundle verifier rejects extra component evidence"; else ok "bundle verifier rejects extra component evidence"; fi
jq --arg component "$bundle_component" '.agent_runtime.components[$component]={source:"/approved-codex-runtime/bad.exe",sha256:"bad",authenticode:{}}' "$attest_candidate" > "$TMP/bundle-malformed.json"
if bash "$EVAL/verify-agent-build.sh" --verify-bundle-evidence "$EVAL/trust/agent-publishers.json" "$TMP/bundle-malformed.json" >/dev/null 2>&1; then bad "bundle verifier rejects malformed component evidence"; else ok "bundle verifier rejects malformed component evidence"; fi
jq --arg component "$bundle_component" '.agent_runtime.components[$component].source=("/different-runtime/" + $component)' "$attest_candidate" > "$TMP/bundle-component-path.json"
if bash "$EVAL/verify-agent-build.sh" --verify-bundle-evidence "$EVAL/trust/agent-publishers.json" "$TMP/bundle-component-path.json" >/dev/null 2>&1; then bad "bundle verifier rejects cross-directory component evidence"; else ok "bundle verifier rejects cross-directory component evidence"; fi
jq '.reviewer.executable="/different-runtime/codex.exe"' "$attest_candidate" > "$TMP/bundle-reviewer-path.json"
if bash "$EVAL/verify-agent-build.sh" --verify-bundle-evidence "$EVAL/trust/agent-publishers.json" "$TMP/bundle-reviewer-path.json" >/dev/null 2>&1; then bad "bundle verifier rejects cross-directory Reviewer evidence"; else ok "bundle verifier rejects cross-directory Reviewer evidence"; fi
printf 'harness-eval-release %s\n' "$(ssh-keygen -y -f "$TMP/test-signing-key")" > "$TMP/test-release-signers"
mkdir -p "$TMP/wrong-build-candidates" "$TMP/wrong-build-results"
for f in "$attest_base".*; do cp "$f" "$TMP/wrong-build-candidates/"; done
wrong_build_candidate="$TMP/wrong-build-candidates/$(basename "$attest_candidate")"
jq '.subject.cli_version="codex-cli unapproved" | .reviewer.cli_version="codex-cli unapproved"' "$wrong_build_candidate" > "$TMP/wrong-build.tmp"
mv "$TMP/wrong-build.tmp" "$wrong_build_candidate"
if bash "$EVAL/attest-result.sh" "$wrong_build_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/wrong-build-candidates" \
  --results-dir="$TMP/wrong-build-results" --allowed-signers="$TMP/test-release-signers" \
  > "$TMP/wrong-build.log" 2>&1; then
  bad "attester rejects a same-publisher executable outside the approved build set"
else
  ok "attester rejects a same-publisher executable outside the approved build set"
fi
mkdir -p "$TMP/wrong-wrapper-candidates" "$TMP/wrong-wrapper-results"
for f in "$attest_base".*; do cp "$f" "$TMP/wrong-wrapper-candidates/"; done
wrong_wrapper_candidate="$TMP/wrong-wrapper-candidates/$(basename "$attest_candidate")"
wrong_wrapper_base="${wrong_wrapper_candidate%.json}"
jq '.probe.shell_wrapper_path="C:\\Windows\\System32\\cmd.exe"' "$wrong_wrapper_base.isolation.json" > "$TMP/wrong-wrapper-isolation.tmp"
mv "$TMP/wrong-wrapper-isolation.tmp" "$wrong_wrapper_base.isolation.json"
wrong_wrapper_sha="$(sha256sum "$wrong_wrapper_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$wrong_wrapper_sha" '.artifact_hashes.isolation=$isolation_sha' "$wrong_wrapper_candidate" > "$TMP/wrong-wrapper-candidate.tmp"
mv "$TMP/wrong-wrapper-candidate.tmp" "$wrong_wrapper_candidate"
if bash "$EVAL/attest-result.sh" "$wrong_wrapper_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/wrong-wrapper-candidates" \
  --results-dir="$TMP/wrong-wrapper-results" --allowed-signers="$TMP/test-release-signers" \
  > "$TMP/wrong-wrapper.log" 2>&1; then
  bad "attester rejects a forged evidence-bound shell wrapper"
elif grep -Fq 'recorded Codex shell wrapper does not match the trusted system PowerShell' "$TMP/wrong-wrapper.log"; then
  ok "attester rejects a forged evidence-bound shell wrapper"
else
  sed 's/^/  wrong-wrapper: /' "$TMP/wrong-wrapper.log" >&2
  bad "attester rejects a forged evidence-bound shell wrapper"
fi
mkdir -p "$TMP/wrong-variant-candidates" "$TMP/wrong-variant-results"
for f in "$attest_base".*; do cp "$f" "$TMP/wrong-variant-candidates/"; done
wrong_variant_candidate="$TMP/wrong-variant-candidates/$(basename "$attest_candidate")"
wrong_variant_base="${wrong_variant_candidate%.json}"
jq '.probe.shell_wrapper_argv_variant="powershell-command-v1"' "$wrong_variant_base.isolation.json" > "$TMP/wrong-variant-isolation.tmp"
mv "$TMP/wrong-variant-isolation.tmp" "$wrong_variant_base.isolation.json"
wrong_variant_sha="$(sha256sum "$wrong_variant_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$wrong_variant_sha" '.artifact_hashes.isolation=$isolation_sha' "$wrong_variant_candidate" > "$TMP/wrong-variant-candidate.tmp"
mv "$TMP/wrong-variant-candidate.tmp" "$wrong_variant_candidate"
if bash "$EVAL/attest-result.sh" "$wrong_variant_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/wrong-variant-candidates" \
  --results-dir="$TMP/wrong-variant-results" --allowed-signers="$TMP/test-release-signers" \
  > "$TMP/wrong-variant.log" 2>&1; then
  bad "attester rejects a forged probe serializer variant"
elif grep -Fq 'serializer variant was not evidence-bound' "$TMP/wrong-variant.log"; then
  ok "attester rejects a forged probe serializer variant"
else
  sed 's/^/  wrong-variant: /' "$TMP/wrong-variant.log" >&2
  bad "attester rejects a forged probe serializer variant"
fi
for probe_tamper in script-path payload-hash source-deny-path source-deny-check; do
  tamper_candidates="$TMP/$probe_tamper-candidates"
  tamper_results="$TMP/$probe_tamper-results"
  mkdir -p "$tamper_candidates" "$tamper_results"
  for f in "$attest_base".*; do cp "$f" "$tamper_candidates/"; done
  tamper_candidate="$tamper_candidates/$(basename "$attest_candidate")"
  tamper_base="${tamper_candidate%.json}"
  if [ "$probe_tamper" = script-path ]; then
    jq '.probe.script.path="C:\\attacker\\isolation-probe.ps1"' "$tamper_base.isolation.json" > "$TMP/$probe_tamper-isolation.tmp"
  elif [ "$probe_tamper" = payload-hash ]; then
    jq --arg bad '0000000000000000000000000000000000000000000000000000000000000000' \
      '.probe.result.payload_sha256=$bad | .probe.command_event.aggregated_output=((.probe.result | tojson) + "\n")' \
      "$tamper_base.isolation.json" > "$TMP/$probe_tamper-isolation.tmp"
  elif [ "$probe_tamper" = source-deny-path ]; then
    jq '.source_file_deny.path="C:\\attacker\\SKILL.md"' \
      "$tamper_base.isolation.json" > "$TMP/$probe_tamper-isolation.tmp"
  else
    jq '.source_file_deny.checks[0].sandbox_sid="S-1-5-21-1-2-3-1002"' \
      "$tamper_base.isolation.json" > "$TMP/$probe_tamper-isolation.tmp"
  fi
  mv "$TMP/$probe_tamper-isolation.tmp" "$tamper_base.isolation.json"
  tamper_sha="$(sha256sum "$tamper_base.isolation.json" | cut -d ' ' -f 1)"
  jq --arg isolation_sha "$tamper_sha" '.artifact_hashes.isolation=$isolation_sha' "$tamper_candidate" > "$TMP/$probe_tamper-candidate.tmp"
  mv "$TMP/$probe_tamper-candidate.tmp" "$tamper_candidate"
  if bash "$EVAL/attest-result.sh" "$tamper_candidate" \
    --signing-key="$TMP/test-signing-key" --candidates-dir="$tamper_candidates" \
    --results-dir="$tamper_results" --allowed-signers="$TMP/test-release-signers" \
    > "$TMP/$probe_tamper.log" 2>&1; then
    bad "attester rejects forged probe $probe_tamper evidence"
  else
    ok "attester rejects forged probe $probe_tamper evidence"
  fi
done

mkdir -p "$TMP/coherent-sid-candidates" "$TMP/coherent-sid-results"
for f in "$attest_base".*; do cp "$f" "$TMP/coherent-sid-candidates/"; done
coherent_sid_candidate="$TMP/coherent-sid-candidates/$(basename "$attest_candidate")"
coherent_sid_base="${coherent_sid_candidate%.json}"
jq --arg offline 'S-1-5-21-9-8-7-6001' --arg online 'S-1-5-21-9-8-7-6002' '
  .sandbox_accounts |= map(if .Name == "CodexSandboxOffline" then .Sid=$offline else .Sid=$online end)
  | .checks |= map(if .sandbox_account == "CodexSandboxOffline" then .sandbox_sid=$offline else .sandbox_sid=$online end)
  | .source_file_deny.checks |= map(if .sandbox_account == "CodexSandboxOffline" then .sandbox_sid=$offline else .sandbox_sid=$online end)
' "$coherent_sid_base.isolation.json" > "$TMP/coherent-sid-isolation.tmp"
mv "$TMP/coherent-sid-isolation.tmp" "$coherent_sid_base.isolation.json"
coherent_sid_sha="$(sha256sum "$coherent_sid_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$coherent_sid_sha" '.artifact_hashes.isolation=$isolation_sha' "$coherent_sid_candidate" > "$TMP/coherent-sid-candidate.tmp"
mv "$TMP/coherent-sid-candidate.tmp" "$coherent_sid_candidate"
if bash "$EVAL/attest-result.sh" "$coherent_sid_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/coherent-sid-candidates" \
  --results-dir="$TMP/coherent-sid-results" --allowed-signers="$TMP/test-release-signers" \
  > "$TMP/coherent-sid.log" 2>&1; then
  bad "attester rejects coherently forged sandbox-account SID evidence"
else
  ok "attester rejects coherently forged sandbox-account SID evidence"
fi

mkdir -p "$TMP/coherent-source-candidates" "$TMP/coherent-source-results"
for f in "$attest_base".*; do cp "$f" "$TMP/coherent-source-candidates/"; done
coherent_source_candidate="$TMP/coherent-source-candidates/$(basename "$attest_candidate")"
coherent_source_base="${coherent_source_candidate%.json}"
coherent_forged_root='C:\forged-workspace'
coherent_forged_source='C:\forged-workspace\SKILL.md'
jq --arg root "$coherent_forged_root" --arg source "$coherent_forged_source" '
  .denied_roots[0] as $old
  | .denied_roots[0]=$root
  | .checks |= map(if .path == $old then .path=$root else . end)
  | .source_file_deny.path=$source
  | .probe.payload.source_file=$source
' "$coherent_source_base.isolation.json" > "$TMP/coherent-source-isolation.tmp"
mv "$TMP/coherent-source-isolation.tmp" "$coherent_source_base.isolation.json"
coherent_payload_sha="$(jq -cS -j '.probe.payload' "$coherent_source_base.isolation.json" | sha256sum | cut -d ' ' -f 1)"
coherent_probe_command="& '$test_powershell_win' -NoProfile -ExecutionPolicy Bypass -File '$test_probe_script_win' -ExpectedPayloadSha256 '$coherent_payload_sha'"
coherent_probe_b64="$(printf '%s' "$coherent_probe_command" | base64 | tr -d '\r\n')"
coherent_probe_display="$(python "$EVAL/validate-probe-command.py" --canonical "$test_probe_variant" "$coherent_probe_b64" "$test_probe_wrapper_win")"
jq --arg payload_sha "$coherent_payload_sha" --arg command "$coherent_probe_display" '
  .probe.result.payload_sha256=$payload_sha
  | .probe.command_event.command=$command
  | .probe.command_event.aggregated_output=((.probe.result | tojson) + "\n")
' "$coherent_source_base.isolation.json" > "$TMP/coherent-source-rebound.tmp"
mv "$TMP/coherent-source-rebound.tmp" "$coherent_source_base.isolation.json"
coherent_source_sha="$(sha256sum "$coherent_source_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$coherent_source_sha" '.artifact_hashes.isolation=$isolation_sha' "$coherent_source_candidate" > "$TMP/coherent-source-candidate.tmp"
mv "$TMP/coherent-source-candidate.tmp" "$coherent_source_candidate"
if bash "$EVAL/attest-result.sh" "$coherent_source_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/coherent-source-candidates" \
  --results-dir="$TMP/coherent-source-results" --allowed-signers="$TMP/test-release-signers" \
  > "$TMP/coherent-source.log" 2>&1; then
  bad "attester rejects coherently forged source-root evidence"
else
  ok "attester rejects coherently forged source-root evidence"
fi

if bash "$EVAL/attest-result.sh" "$attest_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/attest-candidates" \
  --results-dir="$TMP/attested-results" --allowed-signers="$TMP/test-release-signers" \
  > "$TMP/attest.log" 2>&1; then
  ok "separate post-Agent attester promotes a validated candidate"
else
  sed 's/^/  attester: /' "$TMP/attest.log" >&2
  bad "separate post-Agent attester promotes a validated candidate"
fi
attested="$TMP/attested-results/$(basename "$result")"
attested_base="${attested%.json}"
check "attested result is release-eligible and binds its candidate" jq -e \
  --arg candidate_sha "$(sha256sum "$attest_candidate" | cut -d ' ' -f 1)" '
    .schema_version == 3 and .passed == true and .synthetic == false and .release_eligible == true
    and .reviewer_verdict == "CONFIRMED" and .attestation.status == "verified"
    and .attestation.candidate_sha256 == $candidate_sha
  ' "$attested"
check "attested result signature verifies against its independent anchor" \
  bash -c 'ssh-keygen -Y verify -q -f "$1" -I harness-eval-release -n harness-eval -s "$2" < "$3"' \
  _ "$TMP/test-release-signers" "${attested%.json}.attestation.sig" "$attested"

# Even a correctly signed result must not let forged isolation evidence pass
# the independent release gate. Rebind the companion hash, then sign the
# altered result with the authorized test-only key so signature verification
# succeeds before the semantic wrapper check fails.
mkdir -p "$TMP/gate-forged-wrapper-results"
for f in "$attested_base".*; do cp "$f" "$TMP/gate-forged-wrapper-results/"; done
gate_forged_result="$TMP/gate-forged-wrapper-results/$(basename "$attested")"
gate_forged_base="${gate_forged_result%.json}"
jq '.probe.shell_wrapper_path="C:\\Windows\\System32\\cmd.exe"' "$gate_forged_base.isolation.json" > "$TMP/gate-forged-isolation.tmp"
mv "$TMP/gate-forged-isolation.tmp" "$gate_forged_base.isolation.json"
gate_forged_isolation_sha="$(sha256sum "$gate_forged_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$gate_forged_isolation_sha" '.artifact_hashes.isolation=$isolation_sha' "$gate_forged_result" > "$TMP/gate-forged-result.tmp"
mv "$TMP/gate-forged-result.tmp" "$gate_forged_result"
rm -f -- "$gate_forged_base.attestation.sig"
ssh-keygen -Y sign -q -f "$TMP/test-signing-key" -n harness-eval "$gate_forged_result"
mv "$gate_forged_result.sig" "$gate_forged_base.attestation.sig"
check "forged-wrapper gate fixture has a valid independent signature" \
  bash -c 'ssh-keygen -Y verify -q -f "$1" -I harness-eval-release -n harness-eval -s "$2" < "$3"' \
  _ "$TMP/test-release-signers" "$gate_forged_base.attestation.sig" "$gate_forged_result"
if HARNESS_EVAL_GATE_TEST_ALLOWED_SIGNERS="$TMP/test-release-signers" \
  bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/gate-forged-wrapper-results" \
  > "$TMP/gate-forged-wrapper.log" 2>&1; then
  bad "release gate rejects validly signed forged-wrapper evidence"
elif grep -Fq 'vague-goal@1(failed-stale-synthetic-unconfirmed-or-unbound)' "$TMP/gate-forged-wrapper.log"; then
  ok "release gate rejects validly signed forged-wrapper evidence"
else
  sed 's/^/  gate-forged-wrapper: /' "$TMP/gate-forged-wrapper.log" >&2
  bad "release gate rejects validly signed forged-wrapper evidence"
fi

mkdir -p "$TMP/gate-forged-variant-results"
for f in "$attested_base".*; do cp "$f" "$TMP/gate-forged-variant-results/"; done
gate_forged_variant_result="$TMP/gate-forged-variant-results/$(basename "$attested")"
gate_forged_variant_base="${gate_forged_variant_result%.json}"
jq '.probe.shell_wrapper_argv_variant="powershell-command-v1"' "$gate_forged_variant_base.isolation.json" > "$TMP/gate-forged-variant-isolation.tmp"
mv "$TMP/gate-forged-variant-isolation.tmp" "$gate_forged_variant_base.isolation.json"
gate_forged_variant_isolation_sha="$(sha256sum "$gate_forged_variant_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$gate_forged_variant_isolation_sha" '.artifact_hashes.isolation=$isolation_sha' "$gate_forged_variant_result" > "$TMP/gate-forged-variant-result.tmp"
mv "$TMP/gate-forged-variant-result.tmp" "$gate_forged_variant_result"
rm -f -- "$gate_forged_variant_base.attestation.sig"
ssh-keygen -Y sign -q -f "$TMP/test-signing-key" -n harness-eval "$gate_forged_variant_result"
mv "$gate_forged_variant_result.sig" "$gate_forged_variant_base.attestation.sig"
if HARNESS_EVAL_GATE_TEST_ALLOWED_SIGNERS="$TMP/test-release-signers" \
  bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/gate-forged-variant-results" \
  > "$TMP/gate-forged-variant.log" 2>&1; then
  bad "release gate rejects validly signed forged serializer-variant evidence"
elif grep -Fq 'vague-goal@1(failed-stale-synthetic-unconfirmed-or-unbound)' "$TMP/gate-forged-variant.log"; then
  ok "release gate rejects validly signed forged serializer-variant evidence"
else
  sed 's/^/  gate-forged-variant: /' "$TMP/gate-forged-variant.log" >&2
  bad "release gate rejects validly signed forged serializer-variant evidence"
fi

mkdir -p "$TMP/gate-forged-source-deny-results"
for f in "$attested_base".*; do cp "$f" "$TMP/gate-forged-source-deny-results/"; done
gate_forged_source_result="$TMP/gate-forged-source-deny-results/$(basename "$attested")"
gate_forged_source_base="${gate_forged_source_result%.json}"
jq --arg root "$coherent_forged_root" --arg source "$coherent_forged_source" '
  .denied_roots[0] as $old
  | .denied_roots[0]=$root
  | .checks |= map(if .path == $old then .path=$root else . end)
  | .source_file_deny.path=$source
  | .probe.payload.source_file=$source
' "$gate_forged_source_base.isolation.json" > "$TMP/gate-forged-source-isolation.tmp"
mv "$TMP/gate-forged-source-isolation.tmp" "$gate_forged_source_base.isolation.json"
gate_forged_source_payload_sha="$(jq -cS -j '.probe.payload' "$gate_forged_source_base.isolation.json" | sha256sum | cut -d ' ' -f 1)"
gate_forged_source_command="& '$test_powershell_win' -NoProfile -ExecutionPolicy Bypass -File '$test_probe_script_win' -ExpectedPayloadSha256 '$gate_forged_source_payload_sha'"
gate_forged_source_command_b64="$(printf '%s' "$gate_forged_source_command" | base64 | tr -d '\r\n')"
gate_forged_source_display="$(python "$EVAL/validate-probe-command.py" --canonical "$test_probe_variant" "$gate_forged_source_command_b64" "$test_probe_wrapper_win")"
jq --arg payload_sha "$gate_forged_source_payload_sha" --arg command "$gate_forged_source_display" '
  .probe.result.payload_sha256=$payload_sha
  | .probe.command_event.command=$command
  | .probe.command_event.aggregated_output=((.probe.result | tojson) + "\n")
' "$gate_forged_source_base.isolation.json" > "$TMP/gate-forged-source-rebound.tmp"
mv "$TMP/gate-forged-source-rebound.tmp" "$gate_forged_source_base.isolation.json"
gate_forged_source_isolation_sha="$(sha256sum "$gate_forged_source_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$gate_forged_source_isolation_sha" '.artifact_hashes.isolation=$isolation_sha' "$gate_forged_source_result" > "$TMP/gate-forged-source-result.tmp"
mv "$TMP/gate-forged-source-result.tmp" "$gate_forged_source_result"
rm -f -- "$gate_forged_source_base.attestation.sig"
ssh-keygen -Y sign -q -f "$TMP/test-signing-key" -n harness-eval "$gate_forged_source_result"
mv "$gate_forged_source_result.sig" "$gate_forged_source_base.attestation.sig"
if HARNESS_EVAL_GATE_TEST_ALLOWED_SIGNERS="$TMP/test-release-signers" \
  bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/gate-forged-source-deny-results" \
  > "$TMP/gate-forged-source-deny.log" 2>&1; then
  bad "release gate rejects validly signed forged direct source-deny evidence"
elif grep -Fq 'vague-goal@1(failed-stale-synthetic-unconfirmed-or-unbound)' "$TMP/gate-forged-source-deny.log"; then
  ok "release gate rejects validly signed forged direct source-deny evidence"
else
  sed 's/^/  gate-forged-source-deny: /' "$TMP/gate-forged-source-deny.log" >&2
  bad "release gate rejects validly signed forged direct source-deny evidence"
fi

mkdir -p "$TMP/gate-forged-sid-results"
for f in "$attested_base".*; do cp "$f" "$TMP/gate-forged-sid-results/"; done
gate_forged_sid_result="$TMP/gate-forged-sid-results/$(basename "$attested")"
gate_forged_sid_base="${gate_forged_sid_result%.json}"
jq --arg offline 'S-1-5-21-9-8-7-6001' --arg online 'S-1-5-21-9-8-7-6002' '
  .sandbox_accounts |= map(if .Name == "CodexSandboxOffline" then .Sid=$offline else .Sid=$online end)
  | .checks |= map(if .sandbox_account == "CodexSandboxOffline" then .sandbox_sid=$offline else .sandbox_sid=$online end)
  | .source_file_deny.checks |= map(if .sandbox_account == "CodexSandboxOffline" then .sandbox_sid=$offline else .sandbox_sid=$online end)
' "$gate_forged_sid_base.isolation.json" > "$TMP/gate-forged-sid-isolation.tmp"
mv "$TMP/gate-forged-sid-isolation.tmp" "$gate_forged_sid_base.isolation.json"
gate_forged_sid_isolation_sha="$(sha256sum "$gate_forged_sid_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$gate_forged_sid_isolation_sha" '.artifact_hashes.isolation=$isolation_sha' "$gate_forged_sid_result" > "$TMP/gate-forged-sid-result.tmp"
mv "$TMP/gate-forged-sid-result.tmp" "$gate_forged_sid_result"
rm -f -- "$gate_forged_sid_base.attestation.sig"
ssh-keygen -Y sign -q -f "$TMP/test-signing-key" -n harness-eval "$gate_forged_sid_result"
mv "$gate_forged_sid_result.sig" "$gate_forged_sid_base.attestation.sig"
if HARNESS_EVAL_GATE_TEST_ALLOWED_SIGNERS="$TMP/test-release-signers" \
  bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/gate-forged-sid-results" \
  > "$TMP/gate-forged-sid.log" 2>&1; then
  bad "release gate rejects validly signed coherent sandbox-account SID forgery"
elif grep -Fq 'vague-goal@1(failed-stale-synthetic-unconfirmed-or-unbound)' "$TMP/gate-forged-sid.log"; then
  ok "release gate rejects validly signed coherent sandbox-account SID forgery"
else
  sed 's/^/  gate-forged-sid: /' "$TMP/gate-forged-sid.log" >&2
  bad "release gate rejects validly signed coherent sandbox-account SID forgery"
fi

# The release gate validates a private snapshot, then verifies that every
# authoritative source still has the same identity and bytes before passing.
mkdir -p "$TMP/gate-race-results"
for f in "$attested_base".*; do cp "$f" "$TMP/gate-race-results/"; done
cat > "$TMP/gate-race-hook.sh" <<'HOOK'
#!/bin/bash
set -euo pipefail
printf '\n' >> "$1"
HOOK
chmod +x "$TMP/gate-race-hook.sh"
if HARNESS_EVAL_GATE_TEST_AFTER_SNAPSHOT_HOOK="$TMP/gate-race-hook.sh" \
  bash "$EVAL/check-results.sh" --cases-dir="$TMP/cases" --results-dir="$TMP/gate-race-results" \
  > "$TMP/gate-race.log" 2>&1; then
  bad "release gate rejects evidence changed after its private snapshot"
elif grep -Fq 'evidence changed during validation' "$TMP/gate-race.log"; then
  ok "release gate rejects evidence changed after its private snapshot"
else
  sed 's/^/  gate-race: /' "$TMP/gate-race.log" >&2
  bad "release gate rejects evidence changed after its private snapshot"
fi

# A passing result object supplied beside a nonce-only command output is not
# proof that the effective sandbox process observed those values.
mkdir -p "$TMP/probe-tamper-candidates" "$TMP/probe-tamper-results"
for f in "$attest_base".*; do cp "$f" "$TMP/probe-tamper-candidates/"; done
probe_tamper_candidate="$TMP/probe-tamper-candidates/$(basename "$attest_candidate")"
probe_tamper_base="${probe_tamper_candidate%.json}"
jq '.probe.command_event.aggregated_output="{\"nonce\":\"test-nonce\"}\n"' "$probe_tamper_base.isolation.json" > "$TMP/probe-tamper-isolation.tmp"
mv "$TMP/probe-tamper-isolation.tmp" "$probe_tamper_base.isolation.json"
probe_tamper_sha="$(sha256sum "$probe_tamper_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$probe_tamper_sha" '.artifact_hashes.isolation=$isolation_sha' "$probe_tamper_candidate" > "$TMP/probe-tamper-candidate.tmp"
mv "$TMP/probe-tamper-candidate.tmp" "$probe_tamper_candidate"
if bash "$EVAL/attest-result.sh" "$probe_tamper_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/probe-tamper-candidates" \
  --results-dir="$TMP/probe-tamper-results" --allowed-signers="$TMP/test-release-signers" \
  > "$TMP/probe-tamper.log" 2>&1; then
  bad "attester binds effective probe claims to command output"
elif grep -Fq 'isolation evidence is incomplete' "$TMP/probe-tamper.log"; then
  ok "attester binds effective probe claims to command output"
else
  sed 's/^/  probe-tamper: /' "$TMP/probe-tamper.log" >&2
  bad "attester binds effective probe claims to command output"
fi

attested_sha="$(sha256sum "$attested" | cut -d ' ' -f 1)"
if bash "$EVAL/attest-result.sh" "$attest_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/attest-candidates" \
  --results-dir="$TMP/attested-results" --allowed-signers="$TMP/test-release-signers" \
  >/dev/null 2>&1; then
  bad "attester refuses to replace an existing result"
elif [ "$attested_sha" = "$(sha256sum "$attested" | cut -d ' ' -f 1)" ] && [ ! -e "$TMP/attested-results/.eval-write.lock" ]; then
  ok "attester refuses replacement and releases a clean pre-publication lock"
else
  bad "attester refuses replacement and releases a clean pre-publication lock"
fi

# An attacker that replaces a candidate after structural validation must not
# race the attester into signing or publishing a different byte stream.
mkdir -p "$TMP/swap-candidates" "$TMP/swap-results"
for f in "$attest_base".*; do cp "$f" "$TMP/swap-candidates/"; done
swap_candidate="$TMP/swap-candidates/$(basename "$attest_candidate")"
cat > "$TMP/swap-after-snapshot.sh" <<'HOOK'
#!/bin/bash
set -euo pipefail
printf '\n' >> "$1"
HOOK
chmod +x "$TMP/swap-after-snapshot.sh"
if HARNESS_EVAL_TEST_AFTER_SNAPSHOT_HOOK="$TMP/swap-after-snapshot.sh" bash "$EVAL/attest-result.sh" "$swap_candidate" --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/swap-candidates" --results-dir="$TMP/swap-results" --allowed-signers="$TMP/test-release-signers" > "$TMP/swap-attest.log" 2>&1; then
  bad "attester rejects a candidate swap after private snapshot"
elif grep -Fq 'candidate input drifted after validation' "$TMP/swap-attest.log" && [ ! -e "$TMP/swap-results/$(basename "$attested")" ] && [ ! -e "$TMP/swap-results/.eval-write.lock" ] && [ ! -e "$TMP/swap-candidates/.eval-agent.lock" ]; then
  ok "attester rejects a candidate swap after private snapshot"
else
  sed 's/^/  swap-attester: /' "$TMP/swap-attest.log" >&2
  bad "attester rejects a candidate swap after private snapshot"
fi

# Exercise the narrower race after the verifier has read an opened descriptor
# but before it re-resolves the pathname. Preserve bytes and mtime so identity
# is the signal that closes the gap.
mkdir -p "$TMP/recheck-candidates" "$TMP/recheck-results"
for f in "$attest_base".*; do cp "$f" "$TMP/recheck-candidates/"; done
recheck_candidate="$TMP/recheck-candidates/$(basename "$attest_candidate")"
cat > "$TMP/swap-during-recheck.sh" <<'HOOK'
#!/bin/bash
set -euo pipefail
replacement="$1.replacement"
cp -p "$1" "$replacement"
mv -f "$replacement" "$1"
HOOK
chmod +x "$TMP/swap-during-recheck.sh"
if HARNESS_EVAL_TEST_DURING_RECHECK_HOOK="$TMP/swap-during-recheck.sh" bash "$EVAL/attest-result.sh" "$recheck_candidate" --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/recheck-candidates" --results-dir="$TMP/recheck-results" --allowed-signers="$TMP/test-release-signers" > "$TMP/recheck-attest.log" 2>&1; then
  bad "attester detects pathname replacement during final recheck"
elif grep -Fq 'recheck source path changed after reading' "$TMP/recheck-attest.log" && [ ! -e "$TMP/recheck-results/$(basename "$attested")" ] && [ ! -e "$TMP/recheck-results/.eval-write.lock" ] && [ ! -e "$TMP/recheck-candidates/.eval-agent.lock" ]; then
  ok "attester detects pathname replacement during final recheck"
else
  sed 's/^/  recheck-attester: /' "$TMP/recheck-attest.log" >&2
  bad "attester detects pathname replacement during final recheck"
fi

# Replace the first source only after its individual source+snapshot checks
# have passed. The final all-source identity pass must still reject the set.
mkdir -p "$TMP/set-recheck-candidates" "$TMP/set-recheck-results"
for f in "$attest_base".*; do cp "$f" "$TMP/set-recheck-candidates/"; done
set_recheck_candidate="$TMP/set-recheck-candidates/$(basename "$attest_candidate")"
if HARNESS_EVAL_TEST_AFTER_FIRST_RECHECK_HOOK="$TMP/swap-during-recheck.sh" bash "$EVAL/attest-result.sh" "$set_recheck_candidate" --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/set-recheck-candidates" --results-dir="$TMP/set-recheck-results" --allowed-signers="$TMP/test-release-signers" > "$TMP/set-recheck-attest.log" 2>&1; then
  bad "attester detects early-source replacement during later set verification"
elif grep -Fq 'candidate input set changed after final recheck' "$TMP/set-recheck-attest.log" && [ ! -e "$TMP/set-recheck-results/$(basename "$attested")" ] && [ ! -e "$TMP/set-recheck-results/.eval-write.lock" ] && [ ! -e "$TMP/set-recheck-candidates/.eval-agent.lock" ]; then
  ok "attester detects early-source replacement during later set verification"
else
  sed 's/^/  set-recheck-attester: /' "$TMP/set-recheck-attest.log" >&2
  bad "attester detects early-source replacement during later set verification"
fi

mkdir -p "$TMP/results-claude"
if PATH="$TMP/bin:$PATH" FAKE_EVAL_STATE="$TMP/fake-state" HARNESS_EVAL_SYNTHETIC=1 \
  bash "$EVAL/run-eval.sh" "$EVAL/cases/vague-goal.json" --agent=claude --reviewer=claude \
  --model=fake-subject --reviewer-model=fake-reviewer --output-dir="$TMP/results-claude" >/dev/null 2>&1; then
  claude_result="$(find "$TMP/results-claude" -maxdepth 1 -type f -name 'vague-goal.1.*.json' \
    ! -name '*.reviewer-output.json' ! -name '*.project-brief.json' ! -name '*.isolation.json' \
    | head -1)"
  check "Claude stateless subject and Reviewer use the same synthetic contract" jq -e '.passed == true and .synthetic == true and (.subject.session_ids|length==4)' "$claude_result"
else
  bad "Claude stateless subject and Reviewer use the same synthetic contract"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
