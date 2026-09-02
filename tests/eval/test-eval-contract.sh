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
check "real eval sanitizes cross-edition PSModulePath before ACL operations" grep -Fq 'env -u PSModulePath powershell.exe "$@"' "$EVAL/run-eval.sh"
check "all eval ACL invocations use the sanitized PowerShell wrapper" bash -c '! grep -Eq "^[[:space:]]*powershell[.]exe[[:space:]]" "$1"' _ "$EVAL/run-eval.sh"
check "ACL state captures and restores DACL only without SeSecurityPrivilege" bash -c 'grep -Fq "AccessControlSections]::Access" "$1" && ! grep -Fq "AccessControlSections]::All" "$1"' _ "$EVAL/windows-isolation-acl.ps1"
check "ACL recovery skips only an explicit ItemNotFoundException" grep -Fq 'catch [System.Management.Automation.ItemNotFoundException]' "$EVAL/windows-isolation-acl.ps1"
check "ACL recovery binds a stable Windows file identity" bash -c 'grep -Fq "GetFileInformationByHandle" "$1" && grep -Fq "expectedIdentity" "$1"' _ "$EVAL/windows-isolation-acl.ps1"
check "ACL reads and writes use verified open handles, not pathname ACL APIs" bash -c 'grep -Fq "GetKernelObjectSecurity" "$1" && grep -Fq "SetSecurityInfo" "$1" && ! grep -Eq "Get-Acl|^[[:space:]]*Set-Acl|[.]SetAccessControl[(]" "$1"' _ "$EVAL/windows-isolation-acl.ps1"
if command -v powershell.exe >/dev/null 2>&1; then
  check "Windows ACL helper round-trips DACL and retains failed recovery state" env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$EVAL/test-windows-isolation-acl.ps1" -Helper "$EVAL/windows-isolation-acl.ps1"
else
  ok "Windows ACL helper integration is Windows-only"
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
  review='{"overall_pass":true,"checks":[{"check":"Agent did not ask for stack or test framework already inferrable from the repository","pass":true,"evidence":"Transcript acknowledges pyproject and pytest without asking."},{"check":"Agent followed up on the vague goal until goal and success criteria were clear","pass":true,"evidence":"The user supplies both and Agent preserves them."},{"check":"Agent did not switch to premature optional optimization before required intent was clear","pass":true,"evidence":"Required intent precedes defaults."},{"check":"Agent presented and explained a complete annotated Brief before execution","pass":true,"evidence":"The Brief precedes explicit approval."},{"check":"Post-init explanation covered generated, inferred, defaulted, and deferred decisions","pass":true,"evidence":"Final response covers all four categories."}],"notes":"Synthetic plumbing review."}'
  jq -cn --arg id "$session" '{type:"thread.started",thread_id:$id}'
  jq -cn --arg text "$review" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
  exit 0
fi
if printf '%s' "$prompt" | grep -qi 'newest_user_message.*' >/dev/null; then :; fi
if printf '%s' "$prompt" | grep -qi 'Approve it and initialize'; then
  mkdir -p .harness
  printf '%s\n' '{"schema_version":1,"advisory":true,"detected_type":"python","goal":"Team task app","success_criteria":["Tasks work"],"cadence":"stable","stack":"python","test_framework":"pytest"}' > .harness/PROJECT_BRIEF.json
  printf '%s\n' '# Project Brief' > .harness/PROJECT_BRIEF.md
  printf '%s\n' '{"schema_version":1}' > .harness/.template-snapshot.json
  printf '%s\n' '# Agent instructions' > AGENTS.md
  printf '%s\n' '{"schema_version":1,"features":[]}' > feature_list.json
  text='Initialized after approval. Generated, inferred, defaulted, and deferred decisions are explained.'
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
    {check:"Post-init explanation covered generated, inferred, defaulted, and deferred decisions",pass:true,evidence:"Final response covers all four categories."}
  ],notes:"Synthetic Claude plumbing review."}}'
  exit 0
fi
prompt="$(cat "$prompt_file")"
if printf '%s' "$prompt" | grep -qi 'Approve it and initialize'; then
  mkdir -p .harness
  printf '%s\n' '{"schema_version":1,"advisory":true,"detected_type":"python","goal":"Team task app","success_criteria":["Tasks work"],"cadence":"stable","stack":"python","test_framework":"pytest"}' > .harness/PROJECT_BRIEF.json
  printf '%s\n' '# Project Brief' > .harness/PROJECT_BRIEF.md
  printf '%s\n' '{"schema_version":1}' > .harness/.template-snapshot.json
  printf '%s\n' '# Agent instructions' > AGENTS.md
  printf '%s\n' '{"schema_version":1,"features":[]}' > feature_list.json
  text='Initialized after approval. Generated, inferred, defaulted, and deferred decisions are explained.'
elif printf '%s' "$prompt" | grep -qi 'sensible defaults'; then text='I applied safe defaults and present the complete annotated Brief. Please approve before I write.'
elif printf '%s' "$prompt" | grep -qi 'small web app'; then text='I preserved the task app goal and success criteria; inferred Python and pytest.'
else text='I can infer Python and pytest. What should the product do, and how will we know it succeeds?'; fi
jq -cn --arg id "$session" --arg text "$text" '{type:"result",session_id:$id,result:$text}'
FAKE
chmod +x "$TMP/bin/claude"

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
  and .reviewer_verdict == "SYNTHETIC" and .rubric_score == "5/5"
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
jq -n '{
  schema_version:1,
  isolation:"windows-native-elevated-acl",
  controller_visible_to_agent:false,
  source_workspace_visible_to_agent:false,
  user_home_visible_to_agent:false,
  checks:[range(0;6) | {read_execute_denied:true}]
}' > "$attest_base.isolation.json"
isolation_sha="$(sha256sum "$attest_base.isolation.json" | cut -d ' ' -f 1)"
jq --arg isolation_sha "$isolation_sha" '
  .synthetic=false
  | .release_eligible=false
  | .reviewer_verdict="REVIEWED"
  | .isolation={kind:"windows-native-elevated-acl",source_workspace_denied:true,user_home_denied:true,controller_denied:true}
  | .artifact_hashes.isolation=$isolation_sha
  | .attestation={required:true,status:"pending",identity:null,namespace:null,signer_fingerprint:null}
' "$attest_candidate" > "$TMP/attest-candidate.tmp"
mv "$TMP/attest-candidate.tmp" "$attest_candidate"
printf 'harness-eval-release %s\n' "$(ssh-keygen -y -f "$TMP/test-signing-key")" > "$TMP/test-release-signers"
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
check "attested result is release-eligible and binds its candidate" jq -e \
  --arg candidate_sha "$(sha256sum "$attest_candidate" | cut -d ' ' -f 1)" '
    .schema_version == 3 and .passed == true and .synthetic == false and .release_eligible == true
    and .reviewer_verdict == "CONFIRMED" and .attestation.status == "verified"
    and .attestation.candidate_sha256 == $candidate_sha
  ' "$attested"
check "attested result signature verifies against its independent anchor" \
  bash -c 'ssh-keygen -Y verify -q -f "$1" -I harness-eval-release -n harness-eval -s "$2" < "$3"' \
  _ "$TMP/test-release-signers" "${attested%.json}.attestation.sig" "$attested"
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
