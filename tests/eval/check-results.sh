#!/bin/bash
# check-results.sh — fail-closed F-CONV-08 release result gate.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CASES_DIR="$SCRIPT_DIR/cases"
RESULTS_DIR="$SCRIPT_DIR/results"
ALLOWED_SIGNERS="$SCRIPT_DIR/trust/release-allowed-signers"
ATTESTER="$SCRIPT_DIR/attest-result.sh"
ACL_HELPER="$SCRIPT_DIR/windows-isolation-acl.ps1"
PUBLISHER="$SCRIPT_DIR/publish-no-replace.py"
for arg in "$@"; do
  case "$arg" in
    --cases-dir=*) CASES_DIR="${arg#*=}" ;;
    --results-dir=*) RESULTS_DIR="${arg#*=}" ;;
    *) echo "eval-gate: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

for cmd in jq sha256sum find python ssh-keygen; do command -v "$cmd" >/dev/null 2>&1 || { echo "eval-gate: $cmd is required" >&2; exit 2; }; done
[ -d "$CASES_DIR" ] && [ ! -L "$CASES_DIR" ] || { echo "eval-gate: cases directory missing or unsafe" >&2; exit 2; }
[ -d "$RESULTS_DIR" ] && [ ! -L "$RESULTS_DIR" ] || { echo "eval-gate: results directory missing or unsafe" >&2; exit 1; }
[ -f "$ALLOWED_SIGNERS" ] && [ ! -L "$ALLOWED_SIGNERS" ] || { echo "eval-gate: trusted signer anchor missing or unsafe" >&2; exit 2; }
for path in "$ATTESTER" "$ACL_HELPER" "$PUBLISHER"; do [ -f "$path" ] && [ ! -L "$path" ] || { echo "eval-gate: eval authority missing or unsafe: $path" >&2; exit 2; }; done
[ ! -e "$RESULTS_DIR/.eval-write.lock" ] && [ ! -L "$RESULTS_DIR/.eval-write.lock" ] || { echo "eval-gate: result publication is incomplete or locked" >&2; exit 1; }

sha() { sha256sum "$1" | awk '{print $1}'; }
runtime_file_manifest() {
  python - "$1" "$2" <<'PY'
import hashlib, json, os, stat, sys
root, output = os.path.abspath(sys.argv[1]), sys.argv[2]
required = ["SKILL.md", "VERSION", "core/lib/project-detect.sh"]
for rel in required:
    if not os.path.isfile(os.path.join(root, rel)) or os.path.islink(os.path.join(root, rel)):
        raise SystemExit("unsafe runtime authority: " + rel)
paths = required[:]
for top in ("scripts", "templates", "references"):
    top_path = os.path.join(root, top)
    if not os.path.isdir(top_path): raise SystemExit("missing runtime authority: " + top)
    paths.append(top)
    for base, dirs, files in os.walk(top_path, topdown=True, followlinks=False):
        dirs.sort(); files.sort()
        paths.extend(os.path.relpath(os.path.join(base, n), root) for n in dirs + files)
paths.extend(["core", "core/lib"])
records = []
for rel in sorted(set(paths), key=lambda p: p.replace(os.sep, "/").encode("utf-8", "surrogateescape")):
    path = os.path.join(root, rel); st = os.lstat(path)
    rec = {"mode": format(stat.S_IMODE(st.st_mode), "04o"), "path": rel.replace(os.sep, "/")}
    if stat.S_ISLNK(st.st_mode): rec.update(type="symlink", target=os.readlink(path))
    elif stat.S_ISDIR(st.st_mode): rec.update(type="dir")
    elif stat.S_ISREG(st.st_mode):
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""): h.update(chunk)
        rec.update(type="file", sha256=h.hexdigest())
    else: rec.update(type="other")
    records.append(rec)
with open(output, "w", encoding="utf-8", newline="\n") as fh:
    for rec in records: fh.write(json.dumps(rec, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT
runtime_file_manifest "$ROOT" "$tmp/runtime.manifest" || { echo "eval-gate: current runtime authority is unsafe" >&2; exit 2; }
runtime_sha="$(sha "$tmp/runtime.manifest")"
skill_sha="$(sha "$ROOT/SKILL.md")"
runner_sha="$(sha "$SCRIPT_DIR/run-eval.sh")"
schema_sha="$(sha "$SCRIPT_DIR/reviewer-output.schema.json")"
attester_sha="$(sha "$ATTESTER")"
isolation_helper_sha="$(sha "$ACL_HELPER")"
publisher_sha="$(sha "$PUBLISHER")"
trusted_fingerprint="$(awk '$1 == "harness-eval-release" {print $2, $3; exit}' "$ALLOWED_SIGNERS" | ssh-keygen -lf - -E sha256 | awk '{print $2}')"
[ -n "$trusted_fingerprint" ] || { echo "eval-gate: trusted signer fingerprint unavailable" >&2; exit 2; }

artifact_suffixes=(transcript.jsonl tree.sha256 subject-events.jsonl reviewer-events.jsonl turn-trees.jsonl evaluator-events.jsonl reviewer-output.json objective-checks.jsonl project-brief.json isolation.json)
artifact_keys=(transcript tree subject_events reviewer_events turn_trees evaluator_events reviewer_output objective_checks project_brief isolation)

total=0
confirmed=0
failed=''
while IFS= read -r case_file; do
  total=$((total + 1))
  name="$(jq -r '.name // empty' "$case_file")"
  version="$(jq -r '.version // empty' "$case_file")"
  scenario="$(jq -r '.scenario_ref // empty' "$case_file")"
  if [ -z "$name" ] || [ -z "$version" ] || [ -z "$scenario" ] || [ -L "$case_file" ]; then failed="$failed invalid-case:$(basename "$case_file")"; continue; fi
  latest="$(find "$RESULTS_DIR" -maxdepth 1 -name "$name.$version.*.json" \
    ! -name '*.reviewer-output.json' ! -name '*.project-brief.json' ! -name '*.isolation.json' \
    -print | LC_ALL=C sort | tail -1)"
  if [ -z "$latest" ]; then failed="$failed $name@$version(unrun)"; continue; fi
  if [ -L "$latest" ] || [ ! -f "$latest" ]; then failed="$failed $name@$version(unsafe-latest-result)"; continue; fi

  jq -cS '.reviewer_rubric' "$case_file" > "$tmp/rubric.json"
  input_count="$(jq '.mock_user_inputs | length' "$case_file")"
  base="${latest%.json}"
  signature="$base.attestation.sig"
  bound=true
  for ((i=0; i<${#artifact_suffixes[@]}; i++)); do
    path="$base.${artifact_suffixes[$i]}"
    key="${artifact_keys[$i]}"
    if [ ! -f "$path" ] || [ -L "$path" ] || [ "$(jq -r --arg key "$key" '.artifact_hashes[$key] // empty' "$latest")" != "$(sha "$path" 2>/dev/null || true)" ]; then bound=false; fi
  done

  signature_valid=false
  if [ -f "$signature" ] && [ ! -L "$signature" ] && \
    ssh-keygen -Y verify -q -f "$ALLOWED_SIGNERS" -I harness-eval-release -n harness-eval -s "$signature" < "$latest"; then
    signature_valid=true
  fi

  brief_valid=false
  if jq -e 'type == "object"' "$base.project-brief.json" >/dev/null 2>&1; then brief_valid=true; fi
  isolation_valid=false
  if jq -e '
    .schema_version == 1 and .isolation == "windows-native-elevated-acl"
    and .controller_visible_to_agent == false and .source_workspace_visible_to_agent == false
    and .user_home_visible_to_agent == false
    and (.checks | type == "array" and length == 6 and all(.[]; .read_execute_denied == true))
  ' "$base.isolation.json" >/dev/null 2>&1; then isolation_valid=true; fi

  if [ "$bound" = true ] && [ "$signature_valid" = true ] && [ "$brief_valid" = true ] && [ "$isolation_valid" = true ] && jq -e \
    --arg name "$name" --arg version "$version" --arg scenario "$scenario" \
    --arg case_sha "$(sha "$case_file")" --arg skill_sha "$skill_sha" --arg runtime_sha "$runtime_sha" \
    --arg runner_sha "$runner_sha" --arg schema_sha "$schema_sha" --arg rubric_sha "$(sha "$tmp/rubric.json")" --arg signer_fingerprint "$trusted_fingerprint" \
    --arg attester_sha "$attester_sha" --arg isolation_helper_sha "$isolation_helper_sha" --arg publisher_sha "$publisher_sha" \
    --argjson input_count "$input_count" '
      .schema_version == 3 and .case == $name and .case_version == $version
      and .spec_version == "2.0.0-rc.3" and .scenario_ref == $scenario
      and .passed == true and .synthetic == false and .release_eligible == true
      and .reviewer_verdict == "CONFIRMED"
      and .attestation.required == true and .attestation.status == "verified" and .attestation.identity == "harness-eval-release"
      and .attestation.namespace == "harness-eval"
      and .attestation.signer_fingerprint == $signer_fingerprint
      and (.attestation.candidate_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
      and (.attestation.attested_at | type == "string" and length > 0)
      and .authority.case_sha256 == $case_sha
      and .authority.skill_sha256 == $skill_sha
      and .authority.runtime_manifest_sha256 == $runtime_sha
      and .authority.runner_sha256 == $runner_sha
      and .authority.reviewer_schema_sha256 == $schema_sha
      and .authority.canonical_rubric_sha256 == $rubric_sha
      and .authority.attester_sha256 == $attester_sha
      and .authority.isolation_helper_sha256 == $isolation_helper_sha
      and .authority.publisher_sha256 == $publisher_sha
      and .isolation.kind == "windows-native-elevated-acl"
      and .isolation.source_workspace_denied == true and .isolation.user_home_denied == true and .isolation.controller_denied == true
      and (.rubric_details.checks | type == "array" and length > 0 and all(.[]; .pass == true))
      and (.objective_checks | type == "array" and length > 0 and all(.[]; .pass == true))
      and (.rubric_score | capture("^(?<p>[0-9]+)/(?<t>[0-9]+)$") | (.p|tonumber) == (.t|tonumber))
      and .subject.name == "codex"
      and (.subject.executable | type == "string" and test("/(codex|codex.exe)$"; "i"))
      and (.subject.cli_version | type == "string" and length > 0)
      and (.subject.model | type == "string" and length > 0)
      and (.subject.session_ids | type == "array" and length == $input_count and (unique|length) == $input_count and all(.[]; type == "string" and length > 0))
      and (.reviewer.name == "codex" or .reviewer.name == "claude")
      and (.reviewer.executable | type == "string" and test("/(codex|codex.exe|claude|claude.exe)$"; "i"))
      and (.reviewer.cli_version | type == "string" and length > 0)
      and (.reviewer.model | type == "string" and length > 0)
      and (.reviewer.session_id | type == "string" and length > 0)
      and .reviewer.tools_disabled == true
      and (.reviewer.session_id as $rid | (.subject.session_ids | index($rid)) == null)
      and (.artifact_hashes | keys | sort == ["evaluator_events","isolation","objective_checks","project_brief","reviewer_events","reviewer_output","subject_events","transcript","tree","turn_trees"])
    ' "$latest" >/dev/null 2>&1; then
    confirmed=$((confirmed + 1))
  else
    failed="$failed $name@$version(failed-stale-synthetic-unconfirmed-or-unbound)"
  fi
done < <(find "$CASES_DIR" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)

[ "$total" -gt 0 ] || { echo "eval-gate: no cases found" >&2; exit 2; }
echo "eval-gate: $confirmed/$total current cases passed with real CONFIRMED evidence"
if [ -n "$failed" ]; then echo "eval-gate: blocking:$failed" >&2; exit 1; fi
