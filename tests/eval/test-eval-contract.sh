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
windows_result_suffix_normalizes() {
  local suffix
  # shellcheck source=../../scripts/dirty-worktree-runtime-support.sh
  . "$ROOT/scripts/dirty-worktree-runtime-support.sh"
  IFS= read -r suffix < <(printf 'transcript.jsonl\r\n')
  suffix="${suffix%$'\r'}"
  [ "$(dwm_runtime_artifact_kind "tests/eval/results/recovery-case.1.20260917T000000Z-1-2.$suffix")" = eval_result ]
}
brief_input_contract_documented() {
  local skill="$1" principles="$2" runner="$3" contract="$4" file
  for file in "$skill" "$principles" "$runner"; do
    grep -Fq 'references/project-brief-input.md' "$file" || return 1
  done
  grep -Fq '"detected_type"' "$contract" \
    && grep -Fq '"initial_project_state"' "$contract" \
    && grep -Fq '"install_packages"' "$contract" \
    && grep -Fq '"destructive_ops"' "$contract" \
    && grep -Fq 'never uses `path`' "$contract" \
    && grep -Fq 'not an array' "$contract" \
    && grep -Fq 'exactly one of `user`, `repo`, `custom`, or `deferred`' "$contract" \
    && grep -Fq 'Execution-critical conflicts' "$contract" \
    && grep -Fq '`markers_seen` (an array of strings)' "$contract" \
    && grep -Fq '`notes` (a string of at most 500' "$contract" \
    && grep -Fq 'Supported conflict pointers are' "$contract" \
    && grep -Fq -- '--validate-brief-only' "$contract" \
    && grep -Fq 'observation of at most 200 characters' "$contract" \
    && grep -Fq 'Before presenting the complete Brief for approval' "$principles" \
    && grep -Fq 'Do not wait until the approved mutation call' "$principles" \
    && grep -Fq 'first approved boundary invocation must be schema-valid' "$runner"
}
brief_input_examples_validate() {
  local validator="$1" root="$2" known mixed
  local target="$root/brief-input-target"
  mkdir -p "$target" || return 1
  known="$(jq -cn '{schema_version:1,goal:"Create a local report",success_criteria:["The report is generated"],detected_type:"python",stack:"python",test_framework:"pytest",cadence:"stable",deadline:null,secrets_handling:"unspecified",external_network:"ask",prohibitions:[],initial_project_state:{is_git_repo:false,has_existing_tests:false,existing_harness_files:[],detection_summary:"Empty fixture"},operation_preferences:{commit:"ask",push:"ask",merge:"ask",release:"ask",install_packages:"ask",external_mutation:"ask",destructive_ops:false},defaults_applied:[{field:"/cadence",value:"stable",rationale:"Documented stable default",source:"spec_default"}],conflicts_resolved:[],type_evidence:null,provenance:{"/goal":{source:"conversation"},"/cadence":{source:"spec_default"}}}')" || return 1
  mixed="$(jq -cn '{schema_version:1,goal:"Keep both runtimes",success_criteria:["Both test suites remain runnable"],detected_type:"mixed",stack:"mixed",test_framework:"pytest-and-jest",cadence:"stable",deadline:null,secrets_handling:"unspecified",external_network:"denied",prohibitions:["No outbound network"],initial_project_state:{is_git_repo:false,has_existing_tests:true,existing_harness_files:[],detection_summary:"Node and Python markers"},operation_preferences:{commit:"denied",push:"denied",merge:"denied",release:"denied",install_packages:"denied",external_mutation:"denied",destructive_ops:false},defaults_applied:[],conflicts_resolved:[{field:"/external_network",repo_evidence:"Policy denies outbound access",user_input:"Keep it disabled",resolution:"user",resolved_value:"denied"}],type_evidence:{markers_seen:["package.json","pyproject.toml"],notes:"Both runtime markers are present."},provenance:{"/goal":{source:"conversation"},"/detected_type":{source:"repo"}}}')" || return 1
  printf '%s' "$known" | bash "$validator" "$target" --brief-stdin --validate-brief-only --non-interactive --host=codex >/dev/null \
    && printf '%s' "$mixed" | bash "$validator" "$target" --brief-stdin --validate-brief-only --non-interactive --host=codex >/dev/null \
    && [ -z "$(find "$target" -mindepth 1 -print -quit)" ]
}
eval_lock_owner_present() {
  local d="$1"
  { [ -f "$d/.claim" ] && [ ! -L "$d/.claim" ]; } \
    || { [ -f "$d/.lr_owner" ] && [ ! -L "$d/.lr_owner" ]; }
}
eval_lock_released() {
  local d="$1" marker
  for marker in .claim .lr_owner lifecycle.json bundle.json; do
    [ ! -e "$d/$marker" ] && [ ! -L "$d/$marker" ] || return 1
  done
  return 0
}
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

subject_prompt_backticks_escaped() {
  python - "$1" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next(i for i, line in enumerate(lines) if 'cat > "$prompt" <<EOF' in line)
end = next(i for i in range(start + 1, len(lines)) if lines[i] == "EOF")
for line in lines[start + 1:end]:
    for index, char in enumerate(line):
        if char != chr(96):
            continue
        backslashes = 0
        cursor = index - 1
        while cursor >= 0 and line[cursor] == "\\":
            backslashes += 1
            cursor -= 1
        if backslashes % 2 == 0:
            raise SystemExit(1)
PY
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
    and ((.expected_brief_semantics.success_criteria_forbidden_regexes // []) | type == "array" and all(.[]; type == "string" and length > 0))
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
check "FE-11 has observable network and transcript-bound denial sentinels" jq -e '
  .scenario_ref == "FE-11"
  and ([.objective_sentinels[].kind] | index("file_absent") != null and index("assistant_contains") != null)
  and (.reviewer_rubric.checks | tostring | contains("recorded the denial"))
' "$EVAL/cases/external-network-denial.json"
check "guided-init authority preserves requested denial evidence terms" bash -c '
  grep -Fq "external_network denial" "$1/SKILL.md" &&
  grep -Fq "evaluation transcript" "$1/SKILL.md" &&
  grep -Fq "external_network denial" "$1/references/conversational-principles.md" &&
  grep -Fq "evaluation transcript" "$1/references/conversational-principles.md"
' _ "$ROOT"
check "guided-init resolves relative deadlines and does not question defaults" bash -c '
  grep -Fq "Resolve an unambiguous relative deadline" "$1/SKILL.md" &&
  grep -Fq "Documented Brief defaults are not optional questions" "$1/SKILL.md" &&
  grep -Fq "Documented Brief defaults are not questions" "$1/references/conversational-principles.md" &&
  grep -Fq "due Friday" "$1/references/conversational-principles.md"
' _ "$ROOT"
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
check "post-reboot attestation recovery normalizes native jq CRLF suffixes" bash -c 'grep -Fq "Native Windows jq writes CRLF" "$1" && grep -Fq "transport CR before classifying" "$1"' _ "$EVAL/attest-result.sh"
check "normalized Windows result suffix remains canonically classifiable" windows_result_suffix_normalizes
check "release gate is syntactically valid" bash -n "$EVAL/check-results.sh"
check "real eval sanitizes cross-edition PSModulePath through a trusted absolute env" grep -Fq '"$TRUSTED_WINDOWS_ENV" -u PSModulePath "$WINDOWS_POWERSHELL" "$@"' "$EVAL/run-eval.sh"
check "all eval ACL invocations use the sanitized PowerShell wrapper" bash -c '! grep -Eq "^[[:space:]]*powershell[.]exe[[:space:]]" "$1"' _ "$EVAL/run-eval.sh"
check "real eval fails closed unless the elevated Codex sandbox is provisioned" bash -c 'grep -Fq "sandbox backend" "$1" && grep -Fq "sandbox provisioning" "$1"' _ "$EVAL/run-eval.sh"
check "real eval restores trust only for its disposable roots while ignoring user config" bash -c 'grep -Fq "subject_codex_isolation_flags=(-c" "$1" && grep -Fq "reviewer_codex_isolation_flags=(-c" "$1" && grep -Fq -- "-c \"\$subject_project_trust_config\"" "$1" && grep -Fq -- "-c \"\$reviewer_project_trust_config\"" "$1" && [ "$(grep -Fc -- "\"\${subject_codex_isolation_flags[@]}\"" "$1")" -eq 2 ] && [ "$(grep -Fc -- "\"\${reviewer_codex_isolation_flags[@]}\"" "$1")" -eq 2 ] && [ "$(grep -Fc -- "--ignore-user-config --ignore-rules" "$1")" -eq 4 ] && ! grep -Fq -- "--approve-for-me" "$1"' _ "$EVAL/run-eval.sh"
check "real eval pins the Windows Brief stdin producer to literal compact JSON" bash -c 'grep -Fq "Write-Output '\''<one-line compact JSON>'\''" "$1" && grep -Fq "Do not use a here-string" "$1" && grep -Fq "never as backslash-quote" "$1"' _ "$EVAL/run-eval.sh"
check "real eval authenticates snapshotted Agent executables independently of PATH" bash -c 'grep -Fq "Get-AuthenticodeSignature" "$1" && grep -Fq ".subject == \$expected_subject" "$1" && grep -Fq "subject executable snapshot is not an authentic" "$1"' _ "$EVAL/run-eval.sh"
check "Windows command resolution binds the actual regular exe rather than a PATHEXT alias" bash -c 'grep -Fq "MINGW*|MSYS*|CYGWIN*" "$1" && grep -Fq "[ -f \"\$p.exe\" ] && p=\"\$p.exe\"" "$1" && grep -Fq "[ -f \"\$p\" ] && [ ! -L \"\$p\" ]" "$1"' _ "$EVAL/run-eval.sh"
check "real eval uses a protected absolute GNU timeout" bash -c 'grep -Fq "TRUSTED_WINDOWS_TIMEOUT=\"/c/Program Files/Git/usr/bin/timeout.exe\"" "$1" && grep -Fq "TIMEOUT_BIN=\"\$TRUSTED_WINDOWS_TIMEOUT\"" "$1"' _ "$EVAL/run-eval.sh"
check "real eval launches Codex through a trusted absolute env under a system-only PATH" bash -c 'grep -Fq "TRUSTED_WINDOWS_ENV=\"/c/Program Files/Git/usr/bin/env.exe\"" "$1" && grep -Fq "subject_launch=(\"\$TRUSTED_WINDOWS_ENV\" \"PATH=\$sandbox_path\" \"\$subject_launch_executable\")" "$1" && grep -Fq "System32/WindowsPowerShell/v1.0" "$1" && ! grep -q "RuntimeRoot\|CodexBinRoot" "$1"' _ "$EVAL/run-eval.sh"
check "real eval records an effective Offline-sandbox access probe" bash -c 'grep -Fq "codexsandboxoffline" "$1" && grep -Fq "source_workspace_readable == false" "$1" && grep -Fq "controller_readable == false" "$1" && grep -Fq "user_home_root_listable == false" "$1" && grep -Fq "context_authority_readable == false" "$1" && grep -Fq "user_executable_readable == false" "$1" && grep -Fq "host_temp_writeable == false" "$1"' _ "$EVAL/run-eval.sh"
check "all real eval output directories share one ACL transition lock" grep -Fq 'acl_lock="$ROOT/.harness/eval-acl.lock"' "$EVAL/run-eval.sh"
check "crashed eval state has identity-bound lifecycle recovery" bash -c 'grep -Fq "eval-recovery-journal.json" "$1" && grep -Fq "windows_process_status" "$1" && grep -Fq "lifecycle recovery complete" "$1"' _ "$EVAL/recover-windows-isolation.sh"
check "post-publication failures retain the controller recovery journal" python - "$EVAL/run-eval.sh" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
pattern = (
    r'if \[ "\$restore_failed" = false \] '
    r'&& \[ "\$publication_started" = false \] \\?\s*'
    r'&& \[ "\$SYNTHETIC" = 0 \] '
    r'&& \[ "\$recovery_journal_active" = true \]; then'
)
raise SystemExit(0 if re.search(pattern, text) else 1)
PY
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
check "production probe permits only same-session async completion" grep -Fq 'keep waiting on that existing shell session until it exits; do not launch a second command' "$EVAL/run-eval.sh"
check "production probe validator uses the observed system wrapper and build policy" bash -c 'grep -Fq -- "--identify" "$1" && grep -Fq "probe_shell_variants_b64" "$1"' _ "$EVAL/run-eval.sh"
check "production inner probe stays profile-free and binds a guarded script plus payload hash" bash -c 'grep -Fq -- "-NoProfile -ExecutionPolicy Bypass -File" "$1" && grep -Fq -- "-ExpectedPayloadSha256" "$1" && grep -Fq "probe_script_guard_win" "$1"' _ "$EVAL/run-eval.sh"
check "failed access-boundary probes emit only a path-free boolean summary" bash -c 'grep -Fq "nonce_match:(.nonce == \$nonce)" "$1" && grep -Fq "payload_sha_match:(.payload_sha256 == \$payload_sha)" "$1" && grep -Fq "target_file_readable:(.target_file_readable == true)" "$1" && grep -Fq "source_workspace_readable:(.source_workspace_readable == true)" "$1" && grep -Fq "did not prove the required access boundary: \$probe_boundary_summary" "$1" && ! grep -Fq "did not prove the required access boundary: \$probe_result" "$1"' _ "$EVAL/run-eval.sh"
check "all real Codex exec calls disable login shells" bash -c '[ "$(grep -c "allow_login_shell=false" "$1")" -eq 2 ] && [ "$(grep -Fc -- "\"\${subject_codex_isolation_flags[@]}\"" "$1")" -eq 2 ] && [ "$(grep -Fc -- "\"\${reviewer_codex_isolation_flags[@]}\"" "$1")" -eq 2 ]' _ "$EVAL/run-eval.sh"
check "real Agent inspection stops Git probing after a non-repository result" bash -c 'grep -Fq "do not issue any further Git command" "$1" && grep -Fq "git log --no-ext-diff" "$1" && grep -Fq -- "--no-textconv -5 --oneline" "$1"' _ "$EVAL/run-eval.sh"
check "subject prompt renders Git examples literally instead of executing backticks" subject_prompt_backticks_escaped "$EVAL/run-eval.sh"
check "Agent transport is configurable without a hard-coded proxy endpoint" bash -c 'grep -Fq "HARNESS_EVAL_AGENT_TRANSPORT_MODE" "$1" && grep -Fq "HARNESS_EVAL_AGENT_PROXY_URL" "$1" && grep -Fq "configure_agent_transport" "$1" && ! grep -Eq "127[.]0[.]0[.]1:[0-9]+" "$1"' _ "$EVAL/run-eval.sh"
check "Agent proxy settings stay on the CLI transport and out of the isolated tool shell" bash -c 'grep -Fq "shell_environment_policy.inherit=\"none\"" "$1" && ! grep -Fq "shell_environment_policy.set.HTTP_PROXY" "$1" && ! grep -Fq "shell_environment_policy.set.HTTPS_PROXY" "$1"' _ "$EVAL/run-eval.sh"
check "Agent PowerShell analysis cache is isolated outside the target project" bash -c 'grep -Fq "shell_environment_policy.set.PSModuleAnalysisCachePath" "$1" && grep -Fq "powershell/ModuleAnalysisCache" "$1" && grep -Fq "agent-scratch/powershell/" "$2"' _ "$EVAL/run-eval.sh" "$EVAL/validate-isolation-evidence.sh"
check "real eval performs a bounded Agent transport preflight before ACL isolation" bash -c 'grep -Fq "HARNESS_EVAL_AGENT_PREFLIGHT_SECONDS:-30" "$1" && grep -Fq "run_agent_transport_preflight" "$1" && awk '\''/run_agent_transport_preflight$/ { call=NR } /workspace_root=.*ROOT/ { root=NR } END { exit !(call && root && call < root) }'\'' "$1"' _ "$EVAL/run-eval.sh"
check "assistant evidence matching tolerates Markdown inline-code formatting" bash -c 'grep -Fq "tr -d '\''\\140'\''" "$1"' _ "$EVAL/run-eval.sh"
check "attester binds the exact serializer variant to the evidence and build policy" bash -c 'grep -Fq ".probe.shell_wrapper_argv_variant" "$1" && grep -Fq -- "--identify" "$1" && grep -Fq "probe_shell_variants_b64" "$1" && ! grep -Fq "observed_probe_wrapper" "$1"' _ "$EVAL/attest-result.sh"
check "result gate binds the exact serializer variant without a host PowerShell call" bash -c 'grep -Fq ".probe.shell_wrapper_argv_variant" "$1" && grep -Fq -- "--identify" "$1" && grep -Fq "probe_shell_variants_b64" "$1" && ! grep -Fq "observed_probe_wrapper" "$1" && ! grep -Fq "windows_powershell()" "$1"' _ "$EVAL/check-results.sh"
check "attester and result gate bind source ACL evidence to live roots and account SIDs" bash -c 'for f in "$@"; do grep -Fq "windows_sandbox_accounts_json" "$f" && grep -Fq "canonical_source_host" "$f" && grep -Fq "canonical_workspace_host" "$f" && grep -Fq "live_sandbox_accounts" "$f" || exit 1; done' _ "$EVAL/attest-result.sh" "$EVAL/check-results.sh"
check "guided init keeps approved defaults losslessly machine-representable" bash -c 'grep -Fq "Every decision presented for approval must be represented losslessly" "$1" && grep -Fq "apply only the documented Brief defaults" "$1" && grep -Fiq "do not invent product or implementation defaults" "$1"' _ "$ROOT/SKILL.md"
check "guided init aligns default provenance with exact default pointers" bash -c 'grep -Fq "exact same JSON pointer as its matching" "$1" && grep -Fq "Do not record leaf defaults" "$1"' _ "$ROOT/SKILL.md"
check "guided init exposes one exact pre-mutation Brief input contract" brief_input_contract_documented "$ROOT/SKILL.md" "$ROOT/references/conversational-principles.md" "$EVAL/run-eval.sh" "$ROOT/references/project-brief-input.md"
check "documented Brief variants pass the authoritative read-only input validator" brief_input_examples_validate "$ROOT/scripts/harness-init.sh" "$TMP"
check "conversation guidance does not turn sensible defaults into product architecture" bash -c 'grep -Fq "documented Project Brief defaults" "$1" && grep -Fq "framework," "$1" && grep -Fq "database," "$1" && grep -Fq "explicitly deferred" "$1"' _ "$ROOT/references/conversational-principles.md"
check "guided init defers optional authentication mechanisms once success is observable" bash -c 'grep -Fq "authentication goal requires observable success criteria" "$1" && grep -Fq "sessions, tokens, or API keys" "$1" && grep -Fq "should be deferred" "$1" && grep -Fq "do not re-ask an unanswered optional" "$1"' _ "$ROOT/references/conversational-principles.md"
check "conversation guidance asks each conflict once and isolates one field per menu" bash -c 'grep -Fq "Ask that resolution question exactly once" "$1" && grep -Fq "every menu choice to that field alone" "$1" && grep -Fq "Do not offer" "$1" && grep -Fq "composite alternatives" "$1"' _ "$ROOT/references/conversational-principles.md"
check "execution-critical conflict menu retains an explicit non-executing skip" bash -c 'grep -Fq "Always show all four choices" "$1" && grep -Fq "Skip this for now (initialization will pause)" "$1" && grep -Fq "ends the current setup attempt without execution" "$1"' _ "$ROOT/references/conversational-principles.md"
check "conversation guidance explains novice terms and requires whole-Brief approval" bash -c 'grep -Fq "A `Git repository`" "$1" && grep -Fq "A `test framework`" "$1" && grep -Fq "Approval applies to the complete displayed Brief" "$1" && grep -Fq "confirm only those values" "$1"' _ "$ROOT/references/conversational-principles.md"
check "novice-language mode persists through announcements, commentary, Brief, and post-init" bash -c 'grep -Fq "novice-language mode lasts for the remainder" "$1" && grep -Fq "skill-use announcement" "$1" && grep -Fq "progress/commentary updates" "$1" && grep -Fq "scan all user-facing prose" "$1" && grep -Fq "machine-readable shape" "$1" && grep -Fq "confirmation-based setup command" "$1" && grep -Fq "novice-language mode active in this final response" "$2" && grep -Fq "confirmation-based setup command" "$2"' _ "$ROOT/references/conversational-principles.md" "$ROOT/references/post-init-explanation.md"
check "approved goal and success strings are frozen before the first write" bash -c 'grep -Fq "separate quoted or code-formatted string" "$1" && grep -Fq "character for character" "$1" && grep -Fq "Capitalization, punctuation, and list boundaries are data" "$1" && grep -Fq "Correct a mismatch before invoking the executor" "$1"' _ "$ROOT/references/conversational-principles.md"
check "user-supplied goal and success strings are frozen before first presentation" bash -c 'grep -Fq "frozen as soon as they are" "$1" && grep -Fq "Copy them character for character" "$1" && grep -Fq "do not title-case, add a period" "$1" && grep -Fq "use it only after the user accepts it" "$1"' _ "$ROOT/references/conversational-principles.md"
check "validated Brief bytes survive stateless approval turns" bash -c 'grep -Fq "Validated execution record" "$1" && grep -Fq "conversation-persistent handoff for stateless Agent" "$1" && grep -Fq "copy the record byte-for-byte" "$1" && grep -Fq "do not reconstruct `detection_summary`" "$1"' _ "$ROOT/references/conversational-principles.md"
check "post-init update reuses explicit apply consent without bypassing plan tokens" bash -c 'grep -Fq "do not turn the executor'"'"'s plan token into a second" "$1" && grep -Fq "apply the returned token in the same" "$1" && grep -Fq "Never skip the" "$1"' _ "$ROOT/references/conversational-principles.md"
check "concrete post-init edits display the new value without reconfirming unchanged fields" bash -c 'grep -Fq "load the confirmed on-disk Brief" "$1" && grep -Fq "apply the named edit before showing" "$1" && grep -Fq "Do not echo a" "$1" && grep -Fq "reconfirm unchanged fields" "$1"' _ "$ROOT/references/conversational-principles.md"
check "external-service task intent does not replace explicit network authorization" bash -c 'grep -Fq "distinguish task intent from authorization" "$1" && grep -Fq "does not by itself authorize crossing" "$1" && grep -Fq "separate explicit yes/no authorization" "$1" && grep -Fq "Do not create a network-attempt marker" "$1"' _ "$ROOT/references/conversational-principles.md"
check "post-init explanation requires a guided route for revisitable decisions" bash -c 'grep -Fq "closing step is required after every successful guided initialization" "$1" && grep -Fq "discuss those" "$1" && grep -Fq "rerun `/harness:init`" "$1" && grep -Fq "route forward is incomplete" "$1"' _ "$ROOT/references/post-init-explanation.md"
check "post-init explanation reconciles the approved and executed Brief" bash -c 'grep -Fq "reconcile three views" "$1" && grep -Fq "Account for every entry" "$1" && grep -Fq "null deadline" "$1"' _ "$ROOT/references/post-init-explanation.md"
check "post-init explanation names actual updated paths" bash -c 'grep -Fq "Name every generated file" "$1" && grep -Fq ".harness/PROJECT_BRIEF.json" "$1" && grep -Fq "files actually updated" "$1"' _ "$ROOT/references/post-init-explanation.md"
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
check "real executable guard includes Agent runtimes, system tools, probe, and isolated jq" bash -c 'grep -Fq -- "guard_paths=(\"\$subject_win\" \"\$reviewer_win\" \"\$codex_powershell_guard_win\" \"\$system_powershell_guard_win\" \"\$system_whoami_guard_win\" \"\$probe_script_guard_win\" \"\$trusted_jq_guard_win\")" "$1" && grep -Fq -- "snapshot_executable \"\$user_executable\" \"\$trusted_jq\"" "$1" && grep -Fq -- "sandbox_path=\"\$agent_scratch/tools:" "$1" && grep -Fq -- "sha \"\$system_powershell\"" "$1" && grep -Fq -- "sha \"\$system_whoami\"" "$1" && grep -Fq -- "codex_powershell_locked_authenticode" "$1"' _ "$EVAL/run-eval.sh"
approved_version="$(jq -r '.agents.codex.approved_builds[0].cli_version' "$EVAL/trust/agent-publishers.json")"
approved_digest="$(jq -r '.agents.codex.approved_builds[0].sha256' "$EVAL/trust/agent-publishers.json")"
check "shared production build verifier accepts the exact approved tuple" bash "$EVAL/verify-agent-build.sh" "$EVAL/trust/agent-publishers.json" codex "$approved_version" "$approved_digest"
if bash "$EVAL/verify-agent-build.sh" "$EVAL/trust/agent-publishers.json" codex "$approved_version" "${approved_digest%?}0" >/dev/null 2>&1; then
  bad "shared production build verifier rejects a non-approved digest"
else
  ok "shared production build verifier rejects a non-approved digest"
fi
same_version_count="$(jq -r --arg version 'codex-cli 0.153.4' '[.agents.codex.approved_builds[] | select(.cli_version == $version)] | length' "$EVAL/trust/agent-publishers.json")"
if [ "$same_version_count" -ge 2 ]; then
  while IFS= read -r approved_hot_digest; do
    check "shared production build verifier accepts each exact hot build of one CLI version" bash "$EVAL/verify-agent-build.sh" "$EVAL/trust/agent-publishers.json" codex "codex-cli 0.153.4" "$approved_hot_digest"
  done < <(jq -r --arg version 'codex-cli 0.153.4' '.agents.codex.approved_builds[] | select(.cli_version == $version) | .sha256' "$EVAL/trust/agent-publishers.json" | tr -d '\r')
else
  bad "trust policy records multiple exact hot builds of one CLI version"
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
printf '%s\n' "$compatible_daily_bundle" > "$TMP/compatible-bundle-candidate.json"
check "release bundle verifier accepts one complete compatible signed runtime" bash "$EVAL/verify-agent-build.sh" --verify-bundle-evidence "$EVAL/trust/agent-publishers.json" "$TMP/compatible-bundle-candidate.json"
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
check "release gates reuse the shared approved-or-signed-compatible runtime policy" bash -c '
  for f in "$@"; do
    grep -Fq -- "--resolve-runtime-policy" "$f" || exit 1
  done
' _ "$EVAL/attest-result.sh" "$EVAL/check-results.sh" "$EVAL/validate-isolation-evidence.sh"
check "release gates keep authority-manifest and Agent-runtime hashes distinct" bash -c '
  for f in "$@"; do
    grep -Fq -- "--arg runtime_sha" "$f" || exit 1
    grep -Fq -- "--arg agent_runtime_sha" "$f" || exit 1
  done
' _ "$EVAL/attest-result.sh" "$EVAL/check-results.sh"
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
check "canonical eval writers bind published evidence before releasing locks" bash -c '
  grep -Fq '\''runtime_register_batch "$ROOT" eval_candidate'\'' "$1" \
    && grep -Fq '\''register_candidate_bundle "$base"'\'' "$1" \
    && grep -Fq '\''runtime_register_batch "$ROOT" eval_result'\'' "$2" \
    && grep -Fq '\''register_result_bundle "$base_name"'\'' "$2"
' _ "$EVAL/run-eval.sh" "$EVAL/attest-result.sh"
check "real eval tells the subject the provable read-only command allowlist" bash -c '
  grep -Fq "Every inspection command must be statically provable as read-only" "$1" \
    && grep -Fq "Do not use command" "$1" \
    && grep -Fq "Do not use PowerShell script blocks" "$1" \
    && grep -Fq "inspect an" "$1" \
    && grep -Fq "unfiltered read result instead" "$1" \
    && grep -Fq "outside that allowlist" "$1"
' _ "$EVAL/run-eval.sh"
check "direct Bash wrapper preserves read-only command restrictions" python -B "$EVAL/test-subject-shell-wrapper.py"
check "PowerShell null stderr sink preserves mutation restrictions" python -B "$EVAL/test-subject-powershell-redirection.py"
check "recovery publication paths tolerate native jq CRLF" python -B "$EVAL/test-recovery-publication-paths.py"
eval_run_hash="$(printf 'a%.0s' {1..64})"
eval_run_root="C:/Users/Public/harness-companion-eval/runs/run.$eval_run_hash"
eval_boundary="$eval_run_root/skill-authority/scripts/harness-init-boundary.sh"
eval_brief_validator="$eval_run_root/skill-authority/scripts/harness-init.sh"
eval_target="$eval_run_root/project"
ps_wrapper='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
jq -n --arg target_file "$eval_target/.harness-eval-isolation-sentinel" \
  --arg wrapper "$ps_wrapper" \
  '{probe:{payload:{target_file:$target_file},shell_wrapper_path:$wrapper}}' > "$TMP/subject-isolation.json"
subject_command_pair() {
  local id="$1" command="$2" output="${3:-}" exit_code="${4:-0}"
  jq -cn --arg id "$id" --arg command "$command" --arg output "$output" --argjson exit_code "$exit_code" \
    '{type:"item.started",item:{id:$id,type:"command_execution",command:$command}},
     {type:"item.completed",item:{id:$id,type:"command_execution",command:$command,status:"completed",exit_code:$exit_code,aggregated_output:$output}}'
}
subject_command_pair read-1 'Get-Content -Raw package.json' > "$TMP/subject-read.jsonl"
check "subject-event validator permits read-only inspection" python "$EVAL/validate-subject-events.py" "$TMP/subject-read.jsonl" "$TMP/subject-isolation.json"
subject_command_pair read-boundary-1 "\"$ps_wrapper\" -NoProfile -Command \"Get-Content '$eval_boundary'\"" > "$TMP/subject-read-boundary.jsonl"
check "subject-event validator permits reading the trusted boundary source" python "$EVAL/validate-subject-events.py" "$TMP/subject-read-boundary.jsonl" "$TMP/subject-isolation.json"
preflight_payload_escaped='{\"goal\":\"A\"}'
preflight_command="\"$ps_wrapper\" -NoProfile -Command \"Write-Output '$preflight_payload_escaped' | bash '$eval_brief_validator' '$eval_target' --brief-stdin --validate-brief-only --non-interactive --host=codex\""
subject_command_pair brief-preflight-1 "$preflight_command" '{"valid":true}' > "$TMP/subject-brief-preflight.jsonl"
check "subject-event validator permits the exact read-only Brief preflight" python "$EVAL/validate-subject-events.py" "$TMP/subject-brief-preflight.jsonl" "$TMP/subject-isolation.json"
subject_command_pair brief-preflight-extra-1 "${preflight_command%\"} --update\"" > "$TMP/subject-brief-preflight-extra.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-brief-preflight-extra.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects a mutating Brief preflight variant"; else ok "subject-event validator rejects a mutating Brief preflight variant"; fi
subject_command_pair read-context-1 "\"$ps_wrapper\" -NoProfile -Command \"Select-String -LiteralPath '$eval_boundary' -Pattern 'decision' -Context 2,3\"" > "$TMP/subject-read-context.jsonl"
check "subject-event validator permits literal numeric arrays for read-only parameters" python "$EVAL/validate-subject-events.py" "$TMP/subject-read-context.jsonl" "$TMP/subject-isolation.json"
subject_command_pair read-error-action-1 "\"$ps_wrapper\" -NoProfile -Command \"Get-ChildItem -Force -Name '$eval_target' -ErrorAction SilentlyContinue\"" > "$TMP/subject-read-error-action.jsonl"
check "subject-event validator permits bounded ErrorAction on read-only commands" python "$EVAL/validate-subject-events.py" "$TMP/subject-read-error-action.jsonl" "$TMP/subject-isolation.json"
subject_command_pair read-error-action-inline-1 "\"$ps_wrapper\" -NoProfile -Command \"Get-ChildItem -Force -Name '$eval_target' -ErrorAction:Stop\"" > "$TMP/subject-read-error-action-inline.jsonl"
check "subject-event validator permits bounded inline ErrorAction on read-only commands" python "$EVAL/validate-subject-events.py" "$TMP/subject-read-error-action-inline.jsonl" "$TMP/subject-isolation.json"
subject_command_pair read-error-action-unsafe-1 "\"$ps_wrapper\" -NoProfile -Command \"Get-ChildItem -Force -Name '$eval_target' -ErrorAction Inquire\"" > "$TMP/subject-read-error-action-unsafe.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-read-error-action-unsafe.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects interactive ErrorAction values"; else ok "subject-event validator rejects interactive ErrorAction values"; fi
subject_command_pair read-error-action-missing-1 "\"$ps_wrapper\" -NoProfile -Command \"Get-ChildItem -Force -Name '$eval_target' -ErrorAction\"" > "$TMP/subject-read-error-action-missing.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-read-error-action-missing.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects ErrorAction without a value"; else ok "subject-event validator rejects ErrorAction without a value"; fi
subject_command_pair write-1 'brief=$(mktemp) && jq . input.json > $brief && rm $brief' > "$TMP/subject-transient-write.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-transient-write.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects transient direct writes"; else ok "subject-event validator rejects transient direct writes"; fi
subject_command_pair boundary-1 "printf %s \$BRIEF | bash $eval_boundary $eval_target --decision approve --brief-stdin" > "$TMP/subject-boundary.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects incomplete boundary invocation"; else ok "subject-event validator rejects incomplete boundary invocation"; fi
subject_command_pair boundary-2 "printf %s \$BRIEF | bash $eval_boundary $eval_target --decision approve --brief-stdin --non-interactive --host=codex" > "$TMP/subject-boundary.jsonl"
check "subject-event validator permits the exact approved boundary" python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary.jsonl" "$TMP/subject-isolation.json"
subject_command_pair boundary-failed "printf %s \$BRIEF | bash $eval_boundary $eval_target --decision approve --brief-stdin --non-interactive --host=codex" "schema rejected" 1 > "$TMP/subject-boundary-failed.jsonl"
subject_command_pair boundary-retry "printf %s \$BRIEF | bash $eval_boundary $eval_target --decision approve --brief-stdin --non-interactive --host=codex" "initialized" 0 > "$TMP/subject-boundary-retry.jsonl"
cat "$TMP/subject-boundary-failed.jsonl" "$TMP/subject-boundary-retry.jsonl" > "$TMP/subject-boundary-failed-then-success.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-failed-then-success.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects failed boundary probing before a successful retry"; else ok "subject-event validator rejects failed boundary probing before a successful retry"; fi
update_token="$(printf 'a%.0s' {1..64})"
update_payload_escaped='{\"goal\":\"A\"}'
update_plan_command="\"$ps_wrapper\" -NoProfile -Command \"Write-Output '$update_payload_escaped' | bash '$eval_boundary' '$eval_target' --decision approve --brief-stdin --non-interactive --host=codex --update\""
update_apply_command="\"$ps_wrapper\" -NoProfile -Command \"Write-Output '$update_payload_escaped' | bash '$eval_boundary' '$eval_target' --decision approve --brief-stdin --non-interactive --host=codex --update --apply --plan-token=$update_token\""
subject_command_pair boundary-update-plan "$update_plan_command" "=== Update plan (dry-run — no writes) ===
Plan token: $update_token" > "$TMP/subject-boundary-update-plan.jsonl"
check "subject-event validator permits exact update dry-run boundary" python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-plan.jsonl" "$TMP/subject-isolation.json"
subject_command_pair boundary-update-apply "$update_apply_command" > "$TMP/subject-boundary-update-apply.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-apply.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects standalone update apply"; else ok "subject-event validator rejects standalone update apply"; fi
cat "$TMP/subject-boundary-update-plan.jsonl" "$TMP/subject-boundary-update-apply.jsonl" > "$TMP/subject-boundary-update-sequence.jsonl"
check "subject-event validator permits exact dry-run then token-bound apply" python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-sequence.jsonl" "$TMP/subject-isolation.json"
redacted_update_command="${update_apply_command%$update_token\"}[REDACTED_SECRET]\""
subject_command_pair boundary-update-redacted "$redacted_update_command" "=== Update applied ===
" > "$TMP/subject-boundary-update-redacted.jsonl"
cat "$TMP/subject-boundary-update-plan.jsonl" "$TMP/subject-boundary-update-redacted.jsonl" > "$TMP/subject-boundary-update-redacted-sequence.jsonl"
check "subject-event validator accepts Codex-redacted token after successful executor receipt" python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-redacted-sequence.jsonl" "$TMP/subject-isolation.json"
subject_command_pair boundary-update-redacted-no-receipt "$redacted_update_command" > "$TMP/subject-boundary-update-redacted-no-receipt.jsonl"
cat "$TMP/subject-boundary-update-plan.jsonl" "$TMP/subject-boundary-update-redacted-no-receipt.jsonl" > "$TMP/subject-boundary-update-redacted-no-receipt-sequence.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-redacted-no-receipt-sequence.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects redacted apply without executor receipt"; else ok "subject-event validator rejects redacted apply without executor receipt"; fi
wrong_update_token="$(printf 'b%.0s' {1..64})"
wrong_token_command="${update_apply_command%$update_token\"}$wrong_update_token\""
subject_command_pair boundary-update-wrong-token "$wrong_token_command" > "$TMP/subject-boundary-update-wrong-token.jsonl"
cat "$TMP/subject-boundary-update-plan.jsonl" "$TMP/subject-boundary-update-wrong-token.jsonl" > "$TMP/subject-boundary-update-wrong-sequence.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-wrong-sequence.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects apply token not emitted by dry-run"; else ok "subject-event validator rejects apply token not emitted by dry-run"; fi
changed_payload_command="${update_apply_command/\\\"A\\\"/\\\"B\\\"}"
subject_command_pair boundary-update-changed-payload "$changed_payload_command" > "$TMP/subject-boundary-update-changed-payload.jsonl"
cat "$TMP/subject-boundary-update-plan.jsonl" "$TMP/subject-boundary-update-changed-payload.jsonl" > "$TMP/subject-boundary-update-changed-sequence.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-changed-sequence.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects apply payload changed after dry-run"; else ok "subject-event validator rejects apply payload changed after dry-run"; fi
jq -cn --arg command "$update_apply_command" '{type:"item.started",item:{id:"boundary-update-apply",type:"command_execution",command:$command}}' > "$TMP/subject-boundary-update-early-start.jsonl"
cat "$TMP/subject-boundary-update-plan.jsonl" >> "$TMP/subject-boundary-update-early-start.jsonl"
jq -cn --arg command "$update_apply_command" '{type:"item.completed",item:{id:"boundary-update-apply",type:"command_execution",command:$command,status:"completed",exit_code:0,aggregated_output:""}}' >> "$TMP/subject-boundary-update-early-start.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-early-start.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects apply started before dry-run completed"; else ok "subject-event validator rejects apply started before dry-run completed"; fi
subject_command_pair boundary-update-missing-token "printf %s \$BRIEF | bash $eval_boundary $eval_target --decision approve --brief-stdin --non-interactive --host=codex --update --apply" > "$TMP/subject-boundary-update-missing-token.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-update-missing-token.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects update apply without token"; else ok "subject-event validator rejects update apply without token"; fi
check "real Agent prompt requires token-bound two-step post-init update" bash -c 'grep -Fq "mandatory no-write dry run" "$1" && grep -Fq -- "--update --apply --plan-token=<the 64-lowercase-hex token" "$1" && grep -Fq "byte-identical JSON again" "$1" && grep -Fq "opaque frozen byte string" "$1" && grep -Fq "all success_criteria entries" "$1"' _ "$EVAL/run-eval.sh"
printf '%s\n' '{"type":"item.completed","item":{"id":"file-1","type":"file_change","changes":[{"path":"C:/target/transient.json","kind":"add"}],"status":"completed"}}' > "$TMP/subject-file-change.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-file-change.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects direct file_change events"; else ok "subject-event validator rejects direct file_change events"; fi
subject_command_pair compound-1 "touch C:/target/transient && printf %s \$BRIEF | bash $eval_boundary $eval_target --decision approve --brief-stdin --non-interactive --host=codex" > "$TMP/subject-compound-boundary.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-compound-boundary.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects compound boundary commands"; else ok "subject-event validator rejects compound boundary commands"; fi
subject_command_pair substring-1 "touch C:/target/transient; echo $eval_boundary --decision approve" > "$TMP/subject-boundary-substring.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-boundary-substring.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects boundary substrings"; else ok "subject-event validator rejects boundary substrings"; fi
subject_command_pair direct-1 "bash $eval_run_root/skill-authority/scripts/harness-init.sh $eval_target --brief C:/tmp/brief.json --apply" > "$TMP/subject-direct-executor.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-direct-executor.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects direct executor invocation"; else ok "subject-event validator rejects direct executor invocation"; fi
for mutator in 'git apply patch.diff' 'git diff --output=leak.patch' 'Set-Item env:FLAG changed' 'patch -p1 input.patch' 'dd if=input of=output' 'sed --in-place=.bak s/x/y/ input'; do
  subject_command_pair mutator-1 "$mutator" > "$TMP/subject-allowlist-negative.jsonl"
  if python "$EVAL/validate-subject-events.py" "$TMP/subject-allowlist-negative.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects non-allowlisted mutator: $mutator"; else ok "subject-event validator rejects non-allowlisted mutator: $mutator"; fi
done
subject_command_pair newline-1 $'bash -lc \'cat package.json\nrm -f .eval-network-called\'' > "$TMP/subject-shell-newline.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-shell-newline.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects newline shell composition"; else ok "subject-event validator rejects newline shell composition"; fi
for bypass in \
  "BASH_ENV=./call-production-api.sh bash -lc 'cat pyproject.toml'" \
  "sed -n 'e touch unauthorized' /dev/null" \
  'find . -fprint0 output' \
  'sort -o output input' \
  'sort /O output input' \
  'sort --compress-program=evil input' \
  'rg --pre ./mutator pattern file' \
  "Get-Item victim | ForEach-Object -MemberName Delete"; do
  subject_command_pair bypass-1 "$bypass" > "$TMP/subject-semantic-bypass.jsonl"
  if python "$EVAL/validate-subject-events.py" "$TMP/subject-semantic-bypass.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects semantic bypass: $bypass"; else ok "subject-event validator rejects semantic bypass: $bypass"; fi
done
subject_command_pair path-bash-1 "printf %s \$BRIEF | $eval_target/bash $eval_boundary $eval_target --decision approve --brief-stdin --non-interactive --host=codex" > "$TMP/subject-path-bash.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-path-bash.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects path-selected boundary shell"; else ok "subject-event validator rejects path-selected boundary shell"; fi
subject_command_pair assignment-1 "'$ps_wrapper' -NoProfile -Command '\$env:FLAG = \"changed\"; Get-Content package.json'" > "$TMP/subject-powershell-assignment.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-powershell-assignment.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects PowerShell assignment side effects"; else ok "subject-event validator rejects PowerShell assignment side effects"; fi
mkdir -p "$TMP/subject-module"
printf 'Set-Content -LiteralPath marker -Value loaded\n' > "$TMP/subject-module/evil.psm1"
subject_command_pair module-1 "'$ps_wrapper' -NoProfile -Command 'using module $TMP/subject-module/evil.psm1; Get-Content package.json'" > "$TMP/subject-powershell-module.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-powershell-module.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then
  bad "subject-event validator rejects PowerShell using-module initialization"
elif [ ! -e "$TMP/subject-module/marker" ]; then
  ok "subject-event validator rejects PowerShell using-module before execution"
else
  bad "subject-event validator rejects PowerShell using-module before execution"
fi
jq -cn --arg command 'Set-Item env:FLAG changed' '{type:"item.started",item:{id:"started-only",type:"command_execution",command:$command}}' > "$TMP/subject-started-only.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-started-only.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator audits and pairs item.started commands"; else ok "subject-event validator audits and pairs item.started commands"; fi
subject_command_pair wrong-authority-1 "printf %s \$BRIEF | bash C:/arbitrary/scripts/harness-init-boundary.sh $eval_target --decision approve --brief-stdin --non-interactive --host=codex" > "$TMP/subject-wrong-authority.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-wrong-authority.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator binds the isolated authority path"; else ok "subject-event validator binds the isolated authority path"; fi
subject_command_pair reordered-1 "printf %s \$BRIEF | bash $eval_boundary $eval_target --brief-stdin --decision approve --non-interactive --host=codex" > "$TMP/subject-reordered-boundary.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-reordered-boundary.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects reordered boundary arguments"; else ok "subject-event validator rejects reordered boundary arguments"; fi
subject_command_pair extra-1 "printf %s \$BRIEF | bash $eval_boundary $eval_target --decision approve --brief-stdin --non-interactive --host=codex --force-config" > "$TMP/subject-extra-boundary.jsonl"
if python "$EVAL/validate-subject-events.py" "$TMP/subject-extra-boundary.jsonl" "$TMP/subject-isolation.json" >/dev/null 2>&1; then bad "subject-event validator rejects extra boundary arguments"; else ok "subject-event validator rejects extra boundary arguments"; fi
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
if grep -q 'production signing key must be inside the protected source workspace and outside the repository' "$EVAL/attest-result.sh"; then
  ok "attester confines release keys to ACL-protected roots"
else
  bad "attester confines release keys to ACL-protected roots"
fi
check "tag CI explicitly enables the real-result gate in the Phase 7 execution path" tag_ci_gate_wired

mkdir -p "$TMP/cases" "$TMP/results" "$TMP/results-official" "$TMP/bin" "$TMP/fake-state"
cp "$EVAL/cases/vague-goal.json" "$TMP/cases/"
jq -S -n --arg version "$(tr -d '\r\n' < "$ROOT/VERSION")" '{
  advisory:true,
  cadence:"stable",
  captured_from_git_rev:null,
  conflicts_resolved:[],
  deadline:null,
  defaults_applied:[
    {field:"/cadence",rationale:"Default cadence.",source:"spec_default",value:"stable"},
    {field:"/deadline",rationale:"No deadline was specified.",source:"spec_default",value:null},
    {field:"/secrets_handling",rationale:"No secrets policy was specified.",source:"spec_default",value:"unspecified"},
    {field:"/external_network",rationale:"Ask before external network access.",source:"spec_default",value:"ask"},
    {field:"/prohibitions",rationale:"No project-specific prohibitions were specified.",source:"spec_default",value:[]},
    {field:"/operation_preferences",rationale:"Ask before consequential operations.",source:"spec_default",value:{commit:"ask",destructive_ops:false,external_mutation:"ask",install_packages:"ask",merge:"ask",push:"ask",release:"ask"}}
  ],
  detected_type:"python",
  external_network:"ask",
  generated_by:("harness-companion v" + $version),
  goal:"Build a small web app for managing the team tasks.",
  initial_project_state:{detection_summary:"Python project with pytest.",existing_harness_files:[],has_existing_tests:true,is_git_repo:true},
  operation_preferences:{commit:"ask",destructive_ops:false,external_mutation:"ask",install_packages:"ask",merge:"ask",push:"ask",release:"ask"},
  prohibitions:[],
  provenance:{
    "/cadence":{source:"spec_default"},
    "/deadline":{source:"spec_default"},
    "/detected_type":{marker:"pyproject.toml",source:"repo"},
    "/external_network":{source:"spec_default"},
    "/goal":{source:"conversation"},
    "/operation_preferences":{source:"spec_default"},
    "/prohibitions":{source:"spec_default"},
    "/secrets_handling":{source:"spec_default"},
    "/stack":{marker:"pyproject.toml",source:"repo"},
    "/success_criteria":{source:"conversation"},
    "/test_framework":{marker:"pytest.ini",source:"repo"}
  },
  schema_version:1,
  secrets_handling:"unspecified",
  source_version:$version,
  stack:"python",
  success_criteria:["Users can create tasks.","Users can assign tasks to team members.","Users can mark tasks complete.","The existing test suite passes."],
  template_manifest_digest:"0000000000000000000000000000000000000000000000000000000000000000",
  test_framework:"pytest",
  type_evidence:null
}' > "$TMP/fake-state/project-brief.json"
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
  cp "$state/project-brief.json" .harness/PROJECT_BRIEF.json
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
  cp "$state/project-brief.json" .harness/PROJECT_BRIEF.json
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

for publication_boundary in ready companions authoritative registered; do
  publication_root="$TMP/publication-$publication_boundary"
  publication_stage="$publication_root/.staging-test"
  publication_output="$publication_root/output"
  publication_manifest="$publication_root/bundle.json"
  mkdir -p "$publication_stage" "$publication_output"
  printf '%s\n' companion > "$publication_stage/case.1.test.transcript.jsonl"
  printf '%s\n' authority > "$publication_stage/case.1.test.json"
  python "$EVAL/publication-bundle.py" create "$publication_manifest" eval_candidate case.1.test \
    "$publication_stage" "$publication_output" transcript.jsonl json
  case "$publication_boundary" in
    companions|authoritative|registered)
      python "$EVAL/publish-no-replace.py" "$publication_stage/case.1.test.transcript.jsonl" \
        "$publication_output/case.1.test.transcript.jsonl"
      ;;
  esac
  case "$publication_boundary" in
    authoritative|registered)
      python "$EVAL/publish-no-replace.py" "$publication_stage/case.1.test.json" \
        "$publication_output/case.1.test.json"
      ;;
  esac
  if [ "$publication_boundary" = registered ]; then
    python "$EVAL/publication-bundle.py" remove-tree "$publication_stage" "$publication_root" '.staging-'
  fi
  if python "$EVAL/publication-bundle.py" recover "$publication_manifest" >/dev/null \
    && python "$EVAL/publication-bundle.py" recover "$publication_manifest" >/dev/null \
    && [ "$(cat "$publication_output/case.1.test.transcript.jsonl")" = companion ] \
    && [ "$(cat "$publication_output/case.1.test.json")" = authority ]; then
    ok "publication recovery is idempotent after $publication_boundary boundary"
  else
    bad "publication recovery is idempotent after $publication_boundary boundary"
  fi
done

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
test_context_win='C:\home\.agents\skills\harness-companion\SKILL.md'
test_user_executable_win='C:\home\bin\jq.exe'
test_host_temp_marker_win='C:\home\AppData\Local\Temp\harness-eval-host-temp-test-nonce'
test_agent_home_win="$test_probe_run_root_win\\agent-scratch\\home"
test_agent_temp_win="$test_probe_run_root_win\\agent-scratch\\temp"
test_agent_appdata_win="$test_probe_run_root_win\\agent-scratch\\appdata"
test_agent_localappdata_win="$test_probe_run_root_win\\agent-scratch\\localappdata"
test_agent_psmodule_cache_win="$test_probe_run_root_win\\agent-scratch\\powershell\\ModuleAnalysisCache"
test_probe_payload="$(jq -cnS --arg whoami "$test_whoami_win" --arg target_file "$test_probe_run_root_win\\project\\.harness-eval-isolation-sentinel" --arg source_file "$test_source_win" --arg controller_file "$test_probe_run_root_win\\controller\\runtime.manifest" --arg context_file "$test_context_win" --arg user_executable_file "$test_user_executable_win" --arg host_temp_marker "$test_host_temp_marker_win" --arg shell_home "$test_agent_home_win" --arg shell_temp "$test_agent_temp_win" '{nonce:"test-nonce",target_file:$target_file,source_file:$source_file,controller_file:$controller_file,user_home:"C:\\home",context_file:$context_file,user_executable_file:$user_executable_file,host_temp_marker:$host_temp_marker,whoami_file:$whoami,expected_shell:{home:$shell_home,userprofile:$shell_home,temp:$shell_temp,tmp:$shell_temp}}')"
test_probe_payload_sha="$(printf '%s' "$test_probe_payload" | sha256sum | cut -d ' ' -f 1)"
test_probe_script_win="$test_probe_run_root_win\\agent-bin\\isolation-probe.ps1"
test_probe_script_sha="$(sha256sum "$EVAL/windows-isolation-probe.ps1" | cut -d ' ' -f 1)"
test_probe_command="& '$test_powershell_win' -NoProfile -ExecutionPolicy Bypass -File '$test_probe_script_win' -ExpectedPayloadSha256 '$test_probe_payload_sha'"
test_codex_powershell_suffix="$(jq -r '.windows_runtime_tools.codex_powershell.user_profile_suffix' "$EVAL/trust/agent-publishers.json")"
test_codex_powershell_source_win="C:\\home\\$test_codex_powershell_suffix"
test_codex_powershell_win="$test_probe_run_root_win\\agent-bin\\codex-powershell.exe"
test_codex_powershell_sha="$(jq -r '.windows_runtime_tools.codex_powershell.approved_sha256[0]' "$EVAL/trust/agent-publishers.json")"
test_codex_powershell_subject="$(jq -r '.windows_runtime_tools.codex_powershell.publisher_subject' "$EVAL/trust/agent-publishers.json")"
test_codex_powershell_thumbprint="$(jq -r '.windows_runtime_tools.codex_powershell.publisher_thumbprints[0]' "$EVAL/trust/agent-publishers.json")"
test_probe_command_b64="$(printf '%s' "$test_probe_command" | base64 | tr -d '\r\n')"
test_probe_wrapper_win="$(env -u PSModulePath powershell.exe -NoProfile -Command '$env:SystemRoot + "\System32\WindowsPowerShell\v1.0\powershell.exe"' | tr -d '\r')"
test_probe_variant="powershell-no-profile-command-v1"
test_probe_display="$(python "$EVAL/validate-probe-command.py" --canonical "$test_probe_variant" "$test_probe_command_b64" "$test_probe_wrapper_win")"
test_probe_result="$(jq -cn --arg payload_sha "$test_probe_payload_sha" --arg shell_home "$test_agent_home_win" --arg shell_temp "$test_agent_temp_win" '{nonce:"test-nonce",payload_sha256:$payload_sha,identity:"test-host\\codexsandboxoffline",target_file_readable:true,target_writeable:true,source_workspace_readable:false,controller_readable:false,user_home_root_listable:false,context_authority_readable:false,user_executable_readable:false,host_temp_writeable:false,shell_home:$shell_home,shell_userprofile:$shell_home,shell_temp:$shell_temp,shell_tmp:$shell_temp}')"
 jq -n --arg command "$test_probe_display" --arg output "$test_probe_result"$'\n' --argjson payload "$test_probe_payload" --argjson result "$test_probe_result" --arg workspace_root "$test_workspace_win" --arg source_file "$test_source_win" --arg context_file "$test_context_win" --arg user_executable_file "$test_user_executable_win" --arg host_temp_root 'C:\home\AppData\Local\Temp' --arg offline_sid "$test_offline_sid" --arg online_sid "$test_online_sid" --arg controller_root "$test_probe_controller_root" --arg shell_wrapper_path "$test_probe_wrapper_win" --arg shell_wrapper_argv_variant "$test_probe_variant" --arg probe_script_path "$test_probe_script_win" --arg probe_script_sha "$test_probe_script_sha" --arg powershell_path "$test_powershell_win" --arg powershell_sha "$test_powershell_sha" --arg whoami_path "$test_whoami_win" --arg whoami_sha "$test_whoami_sha" --arg codex_powershell_path "$test_codex_powershell_win" --arg codex_powershell_source_path "$test_codex_powershell_source_win" --arg codex_powershell_sha "$test_codex_powershell_sha" --arg codex_powershell_subject "$test_codex_powershell_subject" --arg codex_powershell_thumbprint "$test_codex_powershell_thumbprint" --arg shell_home "$test_agent_home_win" --arg shell_temp "$test_agent_temp_win" --arg shell_appdata "$test_agent_appdata_win" --arg shell_localappdata "$test_agent_localappdata_win" --arg shell_psmodule_analysis_cache "$test_agent_psmodule_cache_win" '{
   schema_version:3,
   isolation:"windows-native-elevated-acl",
   controller_visible_to_agent:false,
   source_workspace_visible_to_agent:false,
   user_home_root_listable_to_agent:false,
   context_authority_visible_to_agent:false,
   user_executable_visible_to_agent:false,
   host_temp_writeable_to_agent:false,
   network:"codex-workspace-write-offline",
  sandbox_accounts:[
    {Name:"CodexSandboxOffline",Sid:$offline_sid},
    {Name:"CodexSandboxOnline",Sid:$online_sid}
  ],
   denied_roots:[$workspace_root,"C:/home",$controller_root],
   checks:[
     {path:$workspace_root,sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,rights:"ReadAndExecute",denied:true},
     {path:$workspace_root,sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,rights:"ReadAndExecute",denied:true},
     {path:"C:/home",sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,rights:"ReadAndExecute",denied:true},
     {path:"C:/home",sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,rights:"ReadAndExecute",denied:true},
     {path:$controller_root,sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,rights:"ReadAndExecute",denied:true},
     {path:$controller_root,sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,rights:"ReadAndExecute",denied:true}
   ],
   source_file_deny:{
     path:$source_file,
     checks:[
       {sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,rights:"ReadAndExecute",denied:true},
       {sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,rights:"ReadAndExecute",denied:true}
     ]
   },
   context_file_deny:{path:$context_file,checks:[{sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,rights:"ReadAndExecute",denied:true},{sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,rights:"ReadAndExecute",denied:true}]},
   user_executable_deny:{path:$user_executable_file,checks:[{sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,rights:"ReadAndExecute",denied:true},{sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,rights:"ReadAndExecute",denied:true}]},
   host_temp_write_deny:{path:$host_temp_root,checks:[{sandbox_account:"CodexSandboxOffline",sandbox_sid:$offline_sid,rights:"Modify",denied:true},{sandbox_account:"CodexSandboxOnline",sandbox_sid:$online_sid,rights:"Modify",denied:true}]},
   shell_environment_policy:{inherit:"none",home:$shell_home,userprofile:$shell_home,temp:$shell_temp,tmp:$shell_temp,appdata:$shell_appdata,localappdata:$shell_localappdata,psmodule_analysis_cache:$shell_psmodule_analysis_cache},
   probe:{
    command_event:{type:"command_execution",command:$command,aggregated_output:$output,exit_code:0,status:"completed"},
    payload:$payload,
    result:$result,
    shell_wrapper_path:$shell_wrapper_path,
    shell_wrapper_argv_variant:$shell_wrapper_argv_variant,
    script:{path:$probe_script_path,sha256:$probe_script_sha},
     executables:{powershell:{path:$powershell_path,sha256:$powershell_sha},whoami:{path:$whoami_path,sha256:$whoami_sha},codex_powershell:{path:$codex_powershell_path,source_path:$codex_powershell_source_path,sha256:$codex_powershell_sha,authenticode:{status:"Valid",subject:$codex_powershell_subject,thumbprint:$codex_powershell_thumbprint}}},
    sanitized_path:["/c/Windows/System32/WindowsPowerShell/v1.0","/c/Windows/System32","/c/Windows","/c/Program Files/Git/bin","/c/Program Files/Git/usr/bin"]
  }
}' > "$attest_base.isolation.json"
isolation_sha="$(sha256sum "$attest_base.isolation.json" | cut -d ' ' -f 1)"
test_publisher_subject="$(jq -r '.agents.codex.publisher_subject' "$EVAL/trust/agent-publishers.json")"
test_publisher_thumbprint="$(jq -r '.agents.codex.publisher_thumbprints[0]' "$EVAL/trust/agent-publishers.json")"
test_approved_version="$(jq -r '.agents.codex.approved_builds[0].cli_version' "$EVAL/trust/agent-publishers.json")"
test_approved_sha="$(jq -r '.agents.codex.approved_builds[0].sha256' "$EVAL/trust/agent-publishers.json")"
test_approved_components="$(jq -c '.agents.codex.approved_builds[0].components' "$EVAL/trust/agent-publishers.json")"
test_brief_validator_sha="$(sha256sum "$ROOT/scripts/validate-project-brief.sh" | cut -d ' ' -f 1)"
test_subject_event_validator_sha="$(sha256sum "$EVAL/validate-subject-events.py" | cut -d ' ' -f 1)"
test_isolation_validator_sha="$(sha256sum "$EVAL/validate-isolation-evidence.sh" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$isolation_sha" --arg publisher_subject "$test_publisher_subject" --arg publisher_thumbprint "$test_publisher_thumbprint" --arg approved_version "$test_approved_version" --arg approved_sha "$test_approved_sha" --argjson approved_components "$test_approved_components" --arg brief_validator_sha "$test_brief_validator_sha" --arg subject_event_validator_sha "$test_subject_event_validator_sha" --arg isolation_validator_sha "$test_isolation_validator_sha" '
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
   | .authority.project_brief_validator_sha256=$brief_validator_sha
   | .authority.subject_event_validator_sha256=$subject_event_validator_sha
   | .authority.isolation_validator_sha256=$isolation_validator_sha
   | .isolation={kind:"windows-native-elevated-acl",source_workspace_denied:true,context_authority_denied:true,controller_denied:true,host_profile_environment_sanitized:true,host_temp_write_denied:true}
  | .artifact_hashes.isolation=$isolation_sha
  | .attestation={required:true,status:"pending",identity:null,namespace:null,signer_fingerprint:null}
' "$attest_candidate" > "$TMP/attest-candidate.tmp"
mv "$TMP/attest-candidate.tmp" "$attest_candidate"
test_accounts_json="$(jq -cn --arg offline "$test_offline_sid" --arg online "$test_online_sid" '[{Name:"CodexSandboxOffline",Sid:$offline},{Name:"CodexSandboxOnline",Sid:$online}]')"
check "isolation validator binds target and controller to one canonical run root" bash "$EVAL/validate-isolation-evidence.sh" \
  "$attest_base.isolation.json" "$attest_candidate" "$test_source_win" "$test_workspace_win" \
  "$test_accounts_json" "$EVAL/trust/agent-publishers.json" "$EVAL/validate-probe-command.py"
other_probe_run_root_win="C:\\Users\\Public\\harness-companion-eval\\runs\\run.$(printf '1%.0s' {1..64})"
jq --arg target "$other_probe_run_root_win\\project\\.harness-eval-isolation-sentinel" '.probe.payload.target_file=$target' \
  "$attest_base.isolation.json" > "$TMP/cross-run-isolation.json"
cross_payload="$(jq -cS '.probe.payload' "$TMP/cross-run-isolation.json")"
cross_payload_sha="$(printf '%s' "$cross_payload" | sha256sum | cut -d ' ' -f 1)"
cross_probe_command="& '$test_powershell_win' -NoProfile -ExecutionPolicy Bypass -File '$test_probe_script_win' -ExpectedPayloadSha256 '$cross_payload_sha'"
cross_probe_command_b64="$(printf '%s' "$cross_probe_command" | base64 | tr -d '\r\n')"
cross_probe_display="$(python "$EVAL/validate-probe-command.py" --canonical "$test_probe_variant" "$cross_probe_command_b64" "$test_probe_wrapper_win")"
jq --arg sha "$cross_payload_sha" --arg command "$cross_probe_display" '
  .probe.result.payload_sha256=$sha
  | .probe.command_event.command=$command
  | .probe.command_event.aggregated_output=((.probe.result | tojson) + "\n")
' "$TMP/cross-run-isolation.json" > "$TMP/cross-run-isolation.tmp"
mv "$TMP/cross-run-isolation.tmp" "$TMP/cross-run-isolation.json"
if bash "$EVAL/validate-isolation-evidence.sh" "$TMP/cross-run-isolation.json" "$attest_candidate" \
  "$test_source_win" "$test_workspace_win" "$test_accounts_json" "$EVAL/trust/agent-publishers.json" \
  "$EVAL/validate-probe-command.py" >/dev/null 2>&1; then
  bad "isolation validator rejects target/controller cross-run binding"
else
  ok "isolation validator rejects target/controller cross-run binding"
fi
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

# Runner, attester, and gate must use the same identity-bound lock protocol.
# A live owner must never be mistaken for an interrupted attester merely
# because it has not written attestation lifecycle files into the lock.
cat > "$TMP/hold-eval-lock.sh" <<'HOLD_LOCK'
#!/bin/bash
set -euo pipefail
. "$1"
lock_path="$2"
ready_file="$3"
release_file="$4"
acquire_lock "$lock_path" 1 >/dev/null
lock_token="$LOCK_REGISTRY_TOKEN"
: > "$ready_file"
while [ ! -e "$release_file" ]; do sleep 0.05; done
release_rc=0
release_lock "$lock_path" "$lock_token" >/dev/null 2>&1 || release_rc=$?
[ "$release_rc" -eq 0 ] || [ "$release_rc" -eq 8 ]
HOLD_LOCK
chmod +x "$TMP/hold-eval-lock.sh"

for active_role in runner gate; do
  active_candidates="$TMP/active-$active_role-candidates"
  active_results="$TMP/active-$active_role-results"
  active_ready="$TMP/active-$active_role.ready"
  active_release="$TMP/active-$active_role.release"
  mkdir -p "$active_candidates" "$active_results"
  for f in "$attest_base".*; do cp "$f" "$active_candidates/"; done
  active_candidate="$active_candidates/$(basename "$attest_candidate")"
  if [ "$active_role" = runner ]; then
    active_lock="$active_candidates/.eval-agent.lock"
  else
    active_lock="$active_results/.eval-write.lock"
  fi
  bash "$TMP/hold-eval-lock.sh" "$ROOT/core/lib/lock-registry.sh" \
    "$active_lock" "$active_ready" "$active_release" &
  active_holder_pid=$!
  active_waits=0
  while [ ! -e "$active_ready" ] && kill -0 "$active_holder_pid" 2>/dev/null \
      && [ "$active_waits" -lt 200 ]; do
    sleep 0.05
    active_waits=$((active_waits + 1))
  done
  active_attest_rc=0
  bash "$EVAL/attest-result.sh" "$active_candidate" \
    --signing-key="$TMP/test-signing-key" --candidates-dir="$active_candidates" \
    --results-dir="$active_results" --allowed-signers="$TMP/test-release-signers" \
    > "$TMP/active-$active_role-attest.log" 2>&1 || active_attest_rc=$?
  active_owner_intact=false
  if [ "$active_attest_rc" -ne 0 ] && kill -0 "$active_holder_pid" 2>/dev/null \
      && eval_lock_owner_present "$active_lock"; then
    active_owner_intact=true
  fi
  : > "$active_release"
  active_holder_rc=0
  wait "$active_holder_pid" || active_holder_rc=$?
  if [ "$active_owner_intact" = true ] && [ "$active_holder_rc" -eq 0 ] \
      && eval_lock_released "$active_lock"; then
    ok "attester refuses the active $active_role identity lock without stealing it"
  else
    sed "s/^/  active-$active_role: /" "$TMP/active-$active_role-attest.log" >&2
    bad "attester refuses the active $active_role identity lock without stealing it"
  fi
done

mkdir -p "$TMP/recovery-attest-candidates" "$TMP/recovery-attested-results"
for f in "$attest_base".*; do cp "$f" "$TMP/recovery-attest-candidates/"; done
recovery_attest_candidate="$TMP/recovery-attest-candidates/$(basename "$attest_candidate")"
recovery_attest_base="${recovery_attest_candidate%.json}"
if HARNESS_EVAL_TEST_PUBLICATION_STOP_AFTER=companions \
  bash "$EVAL/attest-result.sh" "$recovery_attest_candidate" \
    --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/recovery-attest-candidates" \
    --results-dir="$TMP/recovery-attested-results" --allowed-signers="$TMP/test-release-signers" \
    > "$TMP/recovery-attest-stop.log" 2>&1; then
  bad "production attester preserves interrupted publication for retry"
elif [ "$?" -eq 99 ] \
  && [ -d "$TMP/recovery-attest-candidates/.eval-agent.lock" ] \
  && [ -f "$TMP/recovery-attested-results/.eval-write.lock/bundle.json" ] \
  && [ ! -e "$TMP/recovery-attested-results/$(basename "$recovery_attest_candidate")" ]; then
  ok "production attester preserves interrupted publication for retry"
else
  sed 's/^/  recovery-stop: /' "$TMP/recovery-attest-stop.log" >&2
  bad "production attester preserves interrupted publication for retry"
fi
if bash "$EVAL/attest-result.sh" "$recovery_attest_candidate" \
  --signing-key="$TMP/test-signing-key" --candidates-dir="$TMP/recovery-attest-candidates" \
  --results-dir="$TMP/recovery-attested-results" --allowed-signers="$TMP/test-release-signers" \
  > "$TMP/recovery-attest-retry.log" 2>&1 \
  && [ -f "$TMP/recovery-attested-results/$(basename "$recovery_attest_candidate")" ] \
  && eval_lock_released "$TMP/recovery-attested-results/.eval-write.lock" \
  && eval_lock_released "$TMP/recovery-attest-candidates/.eval-agent.lock"; then
  ok "production attester retry completes and retires interrupted publication"
else
  sed 's/^/  recovery-retry: /' "$TMP/recovery-attest-retry.log" >&2
  bad "production attester retry completes and retires interrupted publication"
fi
recovery_attested="$TMP/recovery-attested-results/$(basename "$result")"
check "recovered production attestation remains signed and release-eligible" jq -e \
  --arg candidate_sha "$(sha256sum "$recovery_attest_candidate" | cut -d ' ' -f 1)" '
    .schema_version == 3 and .release_eligible == true and .attestation.status == "verified"
    and .attestation.candidate_sha256 == $candidate_sha
  ' "$recovery_attested"
check "recovered production attestation signature verifies" \
  bash -c 'ssh-keygen -Y verify -q -f "$1" -I harness-eval-release -n harness-eval -s "$2" < "$3"' \
  _ "$TMP/test-release-signers" "${recovery_attested%.json}.attestation.sig" "$recovery_attested"

# A hard process death must be recoverable at every durable pre-publication
# boundary. These use SIGKILL so the attester EXIT trap cannot hide a missing
# lifecycle transition or stale-owner proof.
for crash_boundary in candidate_lock result_lock stage_planned stage_created result_generated signed manifest_created; do
  crash_candidates="$TMP/crash-$crash_boundary-candidates"
  crash_results="$TMP/crash-$crash_boundary-results"
  mkdir -p "$crash_candidates" "$crash_results"
  for f in "$attest_base".*; do cp "$f" "$crash_candidates/"; done
  crash_candidate="$crash_candidates/$(basename "$attest_candidate")"
  if HARNESS_EVAL_TEST_CRASH_AFTER="$crash_boundary" \
    bash "$EVAL/attest-result.sh" "$crash_candidate" \
      --signing-key="$TMP/test-signing-key" --candidates-dir="$crash_candidates" \
      --results-dir="$crash_results" --allowed-signers="$TMP/test-release-signers" \
      > "$TMP/crash-$crash_boundary.log" 2>&1; then
    bad "attester is forcibly interrupted after $crash_boundary"
    continue
  elif [ ! -d "$crash_candidates/.eval-agent.lock" ]; then
    bad "attester retains identity-bound recovery state after $crash_boundary"
    continue
  else
    ok "attester retains identity-bound recovery state after $crash_boundary"
  fi
  if bash "$EVAL/attest-result.sh" "$crash_candidate" \
      --signing-key="$TMP/test-signing-key" --candidates-dir="$crash_candidates" \
      --results-dir="$crash_results" --allowed-signers="$TMP/test-release-signers" \
      > "$TMP/crash-$crash_boundary-retry.log" 2>&1 \
    && [ -f "$crash_results/$(basename "$attest_candidate")" ] \
    && eval_lock_released "$crash_results/.eval-write.lock" \
    && eval_lock_released "$crash_candidates/.eval-agent.lock" \
    && ! find "$crash_results" -mindepth 1 -maxdepth 1 -name '.attest.*' -print -quit | grep -q .; then
    ok "attester safely retries after hard interruption at $crash_boundary"
  else
    sed "s/^/  crash-$crash_boundary-retry: /" "$TMP/crash-$crash_boundary-retry.log" >&2
    bad "attester safely retries after hard interruption at $crash_boundary"
  fi
done

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
elif grep -Eq 'isolation evidence( v3)? is incomplete' "$TMP/probe-tamper.log"; then
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
elif [ "$attested_sha" = "$(sha256sum "$attested" | cut -d ' ' -f 1)" ] \
  && eval_lock_released "$TMP/attested-results/.eval-write.lock"; then
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
elif grep -Fq 'candidate input drifted after validation' "$TMP/swap-attest.log" \
  && [ ! -e "$TMP/swap-results/$(basename "$attested")" ] \
  && eval_lock_released "$TMP/swap-results/.eval-write.lock" \
  && eval_lock_released "$TMP/swap-candidates/.eval-agent.lock"; then
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
elif grep -Fq 'recheck source path changed after reading' "$TMP/recheck-attest.log" \
  && [ ! -e "$TMP/recheck-results/$(basename "$attested")" ] \
  && eval_lock_released "$TMP/recheck-results/.eval-write.lock" \
  && eval_lock_released "$TMP/recheck-candidates/.eval-agent.lock"; then
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
elif grep -Fq 'candidate input set changed after final recheck' "$TMP/set-recheck-attest.log" \
  && [ ! -e "$TMP/set-recheck-results/$(basename "$attested")" ] \
  && eval_lock_released "$TMP/set-recheck-results/.eval-write.lock" \
  && eval_lock_released "$TMP/set-recheck-candidates/.eval-agent.lock"; then
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
