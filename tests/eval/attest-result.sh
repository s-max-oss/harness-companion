#!/bin/bash
# attest-result.sh — promote one completed unsigned eval candidate.
#
# This command must run only after run-eval.sh has exited.  It is the sole
# process that receives the release private key.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CASES_DIR="$SCRIPT_DIR/cases"
CANDIDATES_DIR="$SCRIPT_DIR/candidates"
RESULTS_DIR="$SCRIPT_DIR/results"
ALLOWED_SIGNERS="$SCRIPT_DIR/trust/release-allowed-signers"
RUNNER="$SCRIPT_DIR/run-eval.sh"
SCHEMA="$SCRIPT_DIR/reviewer-output.schema.json"
ACL_HELPER="$SCRIPT_DIR/windows-isolation-acl.ps1"
PUBLISHER="$SCRIPT_DIR/publish-no-replace.py"

die() { echo "eval-attest: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
sha() { sha256sum "$1" | awk '{print $1}'; }

host_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -am "$1" | tr '[:upper:]' '[:lower:]'
  else
    python - "$1" <<'PY'
import os, sys
print(os.path.normcase(os.path.realpath(sys.argv[1])).replace(os.sep, "/"))
PY
  fi
}

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

CANDIDATE="${1:-}"
[ -n "$CANDIDATE" ] || die "usage: attest-result.sh <candidate.json> --signing-key=<path> [--candidates-dir=<dir>] [--results-dir=<dir>] [--allowed-signers=<file>]"
shift
SIGNING_KEY="${HARNESS_EVAL_SIGNING_KEY:-}"
for arg in "$@"; do
  case "$arg" in
    --signing-key=*) SIGNING_KEY="${arg#*=}" ;;
    --candidates-dir=*) CANDIDATES_DIR="${arg#*=}" ;;
    --results-dir=*) RESULTS_DIR="${arg#*=}" ;;
    --allowed-signers=*) ALLOWED_SIGNERS="${arg#*=}" ;;
    *) die "unknown argument: $arg" ;;
  esac
done

for cmd in jq sha256sum python ssh-keygen mktemp cp find tr grep; do need "$cmd"; done
for path in "$RUNNER" "$SCHEMA" "$ACL_HELPER" "$PUBLISHER" "$ALLOWED_SIGNERS"; do
  [ -f "$path" ] && [ ! -L "$path" ] || die "authority missing or unsafe: $path"
done
[ -n "$SIGNING_KEY" ] && [ -f "$SIGNING_KEY" ] && [ ! -L "$SIGNING_KEY" ] || die "a regular non-symlink signing key is required"
SIGNING_KEY="$(cd "$(dirname "$SIGNING_KEY")" && pwd -P)/$(basename "$SIGNING_KEY")"
[ -d "$CANDIDATES_DIR" ] && [ ! -L "$CANDIDATES_DIR" ] || die "candidate directory missing or unsafe"
mkdir -p "$RESULTS_DIR"
[ -d "$RESULTS_DIR" ] && [ ! -L "$RESULTS_DIR" ] || die "results directory missing or unsafe"
candidates_abs="$(cd "$CANDIDATES_DIR" && pwd -P)"
results_abs="$(cd "$RESULTS_DIR" && pwd -P)"
allowed_signers_abs="$(cd "$(dirname "$ALLOWED_SIGNERS")" && pwd -P)/$(basename "$ALLOWED_SIGNERS")"
canonical_allowed_signers="$(cd "$(dirname "$SCRIPT_DIR/trust/release-allowed-signers")" && pwd -P)/release-allowed-signers"
if [ "$allowed_signers_abs" = "$canonical_allowed_signers" ]; then
  key_host="$(host_path "$SIGNING_KEY")"
  workspace_host="$(host_path "$(cd "$ROOT/.." && pwd -P)")"
  user_home_host="$(host_path "${USERPROFILE:-$HOME}")"
  case "$key_host" in
    "$workspace_host"/*|"$user_home_host"/*) ;;
    *) die "signing key must be inside a root denied to eval sandbox accounts" ;;
  esac
else
  [ "$candidates_abs" != "$(cd "$SCRIPT_DIR/candidates" && pwd -P)" ] \
    && [ "$results_abs" != "$(cd "$SCRIPT_DIR/results" && pwd -P)" ] \
    || die "custom trust anchors are test-only and cannot publish to canonical directories"
fi
[ ! -e "$CANDIDATES_DIR/.eval-agent.lock" ] && [ ! -L "$CANDIDATES_DIR/.eval-agent.lock" ] || die "Agent evaluation is still active or stale"
[ ! -e "$CANDIDATES_DIR/.eval-write.lock" ] && [ ! -L "$CANDIDATES_DIR/.eval-write.lock" ] || die "candidate publication is incomplete"

publication_lock="$RESULTS_DIR/.eval-write.lock"
if ! mkdir "$publication_lock" 2>/dev/null; then die "result publication lock exists: $publication_lock"; fi
publication_started=false
tmp=""
cleanup() {
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then rm -rf -- "$tmp"; fi
  if [ "$publication_started" = false ] && [ -d "$publication_lock" ]; then rmdir "$publication_lock" 2>/dev/null || true; fi
}
trap cleanup EXIT

[ -f "$CANDIDATE" ] && [ ! -L "$CANDIDATE" ] || die "candidate missing or unsafe"
candidate_abs="$(cd "$(dirname "$CANDIDATE")" && pwd -P)/$(basename "$CANDIDATE")"
case "$candidate_abs" in "$candidates_abs"/*.json) ;; *) die "candidate is outside the authoritative candidate directory" ;; esac
case "$(basename "$candidate_abs")" in *.reviewer-output.json|*[!A-Za-z0-9._-]*) die "unsafe candidate name" ;; esac

case_name="$(jq -r '.case // empty' "$candidate_abs")"
case_version="$(jq -r '.case_version // empty' "$candidate_abs")"
scenario="$(jq -r '.scenario_ref // empty' "$candidate_abs")"
case_file=""
while IFS= read -r candidate_case; do
  if [ "$(jq -r '.name // empty' "$candidate_case")" = "$case_name" ]; then
    [ -z "$case_file" ] || die "duplicate case authority for $case_name"
    case_file="$candidate_case"
  fi
done < <(find "$CASES_DIR" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
[ -n "$case_file" ] && [ ! -L "$case_file" ] || die "current case authority not found"

tmp="$(mktemp -d "$RESULTS_DIR/.attest.XXXXXX")" || die "attestation staging failed"

runtime_file_manifest "$ROOT" "$tmp/runtime.manifest" || die "current runtime authority is unsafe"
jq -cS '.reviewer_rubric' "$case_file" > "$tmp/rubric.json"
input_count="$(jq '.mock_user_inputs | length' "$case_file")"
base="${candidate_abs%.json}"
base_name="$(basename "$base")"
case "$base_name" in "$case_name.$case_version."*) ;; *) die "candidate filename does not match case authority" ;; esac
artifact_suffixes=(transcript.jsonl tree.sha256 subject-events.jsonl reviewer-events.jsonl turn-trees.jsonl evaluator-events.jsonl reviewer-output.json objective-checks.jsonl project-brief.json isolation.json)
artifact_keys=(transcript tree subject_events reviewer_events turn_trees evaluator_events reviewer_output objective_checks project_brief isolation)

for ((i=0; i<${#artifact_suffixes[@]}; i++)); do
  path="$base.${artifact_suffixes[$i]}"
  key="${artifact_keys[$i]}"
  [ -f "$path" ] && [ ! -L "$path" ] || die "candidate companion missing or unsafe: $path"
  [ "$(jq -r --arg key "$key" '.artifact_hashes[$key] // empty' "$candidate_abs")" = "$(sha "$path")" ] \
    || die "candidate companion hash mismatch: $key"
done

jq -e 'type == "object"' "$base.project-brief.json" >/dev/null || die "captured PROJECT_BRIEF.json is invalid"
jq -e '
  .schema_version == 1
  and .isolation == "windows-native-elevated-acl"
  and .controller_visible_to_agent == false
  and .source_workspace_visible_to_agent == false
  and .user_home_visible_to_agent == false
  and (.checks | type == "array" and length == 6 and all(.[]; .read_execute_denied == true))
' "$base.isolation.json" >/dev/null || die "isolation evidence is incomplete"

signer_public="$(ssh-keygen -y -f "$SIGNING_KEY" | tr -d '\r')" || die "could not read signing key"
signer_fingerprint="$(printf '%s\n' "$signer_public" | ssh-keygen -lf - -E sha256 | awk '{print $2}' | tr -d '\r')"
authorized_fingerprints="$(awk '$1 == "harness-eval-release" {print $2, $3}' "$ALLOWED_SIGNERS" \
  | ssh-keygen -lf - -E sha256 | awk '{print $2}' | tr -d '\r')"
printf '%s\n' "$authorized_fingerprints" | grep -Fxq -- "$signer_fingerprint" \
  || die "signing key is not authorized by the selected trust anchor"

jq -e \
  --arg name "$case_name" --arg version "$case_version" --arg scenario "$scenario" \
  --arg case_sha "$(sha "$case_file")" --arg skill_sha "$(sha "$ROOT/SKILL.md")" --arg runtime_sha "$(sha "$tmp/runtime.manifest")" \
  --arg runner_sha "$(sha "$RUNNER")" --arg schema_sha "$(sha "$SCHEMA")" --arg rubric_sha "$(sha "$tmp/rubric.json")" \
  --arg attester_sha "$(sha "$SCRIPT_DIR/attest-result.sh")" --arg isolation_sha "$(sha "$ACL_HELPER")" --arg publisher_sha "$(sha "$PUBLISHER")" \
  --argjson input_count "$input_count" '
    .schema_version == 3 and .case == $name and .case_version == $version
    and .spec_version == "2.0.0-rc.3" and .scenario_ref == $scenario
    and .passed == true and .synthetic == false and .release_eligible == false
    and .reviewer_verdict == "REVIEWED"
    and .attestation.required == true and .attestation.status == "pending"
    and .attestation.identity == null and .attestation.namespace == null and .attestation.signer_fingerprint == null
    and .authority.case_sha256 == $case_sha and .authority.skill_sha256 == $skill_sha
    and .authority.runtime_manifest_sha256 == $runtime_sha and .authority.runner_sha256 == $runner_sha
    and .authority.reviewer_schema_sha256 == $schema_sha and .authority.canonical_rubric_sha256 == $rubric_sha
    and .authority.attester_sha256 == $attester_sha and .authority.isolation_helper_sha256 == $isolation_sha
    and .authority.publisher_sha256 == $publisher_sha
    and .isolation.kind == "windows-native-elevated-acl"
    and .isolation.source_workspace_denied == true and .isolation.user_home_denied == true and .isolation.controller_denied == true
    and (.rubric_details.checks | type == "array" and length > 0 and all(.[]; .pass == true))
    and (.objective_checks | type == "array" and length > 0 and all(.[]; .pass == true))
    and (.rubric_score | capture("^(?<p>[0-9]+)/(?<t>[0-9]+)$") | (.p|tonumber) == (.t|tonumber))
    and .subject.name == "codex"
    and (.subject.executable | type == "string" and test("/(codex|codex.exe)$"; "i"))
    and (.subject.cli_version | type == "string" and length > 0) and (.subject.model | type == "string" and length > 0)
    and (.subject.session_ids | type == "array" and length == $input_count and (unique|length) == $input_count and all(.[]; type == "string" and length > 0))
    and (.reviewer.name == "codex" or .reviewer.name == "claude") and .reviewer.tools_disabled == true
    and (.reviewer.cli_version | type == "string" and length > 0) and (.reviewer.model | type == "string" and length > 0)
    and (.reviewer.session_id | type == "string" and length > 0)
    and (.reviewer.session_id as $rid | (.subject.session_ids | index($rid)) == null)
    and (.artifact_hashes | keys | sort == ["evaluator_events","isolation","objective_checks","project_brief","reviewer_events","reviewer_output","subject_events","transcript","tree","turn_trees"])
  ' "$candidate_abs" >/dev/null || die "candidate is stale, failed, synthetic, unisolated, or structurally invalid"

candidate_sha="$(sha "$candidate_abs")"
promoted="$tmp/$base_name.json"
jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg fingerprint "$signer_fingerprint" --arg candidate_sha "$candidate_sha" '
  .release_eligible = true
  | .reviewer_verdict = "CONFIRMED"
  | .attestation = {
      required:true,
      status:"verified",
      identity:"harness-eval-release",
      namespace:"harness-eval",
      signer_fingerprint:$fingerprint,
      candidate_sha256:$candidate_sha,
      attested_at:$now
    }
' "$candidate_abs" > "$promoted"

ssh-keygen -Y sign -q -f "$SIGNING_KEY" -n harness-eval "$promoted"
mv "$promoted.sig" "$tmp/$base_name.attestation.sig"
for suffix in "${artifact_suffixes[@]}"; do cp "$base.$suffix" "$tmp/$base_name.$suffix"; done

publish_args=()
for suffix in "${artifact_suffixes[@]}"; do publish_args+=("$tmp/$base_name.$suffix" "$RESULTS_DIR/$base_name.$suffix"); done
for ((i=1; i<${#publish_args[@]}; i+=2)); do
  [ ! -e "${publish_args[$i]}" ] && [ ! -L "${publish_args[$i]}" ] || die "result destination already exists: ${publish_args[$i]}"
done
[ ! -e "$RESULTS_DIR/$base_name.attestation.sig" ] && [ ! -L "$RESULTS_DIR/$base_name.attestation.sig" ] \
  || die "result destination already exists: $RESULTS_DIR/$base_name.attestation.sig"
[ ! -e "$RESULTS_DIR/$base_name.json" ] && [ ! -L "$RESULTS_DIR/$base_name.json" ] \
  || die "result destination already exists: $RESULTS_DIR/$base_name.json"
publication_started=true
python "$PUBLISHER" "${publish_args[@]}" || die "result companion publication failed; lock retained"
python "$PUBLISHER" "$tmp/$base_name.attestation.sig" "$RESULTS_DIR/$base_name.attestation.sig" \
  || die "result signature publication failed; lock retained"
python "$PUBLISHER" "$promoted" "$RESULTS_DIR/$base_name.json" \
  || die "authoritative result publication failed; lock retained"
rmdir "$publication_lock"
publication_lock=""

echo "eval-attest: result=$RESULTS_DIR/$base_name.json"
echo "eval-attest: candidate_sha256=$candidate_sha signer=$signer_fingerprint"
