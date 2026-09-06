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
ISOLATION_PROBE="$SCRIPT_DIR/windows-isolation-probe.ps1"
EXECUTABLE_GUARD="$SCRIPT_DIR/windows-executable-guard.ps1"
ACL_RECOVERY="$SCRIPT_DIR/recover-windows-isolation.sh"
AGENT_PUBLISHERS="$SCRIPT_DIR/trust/agent-publishers.json"
AGENT_BUILD_VERIFIER="$SCRIPT_DIR/verify-agent-build.sh"
PUBLISHER="$SCRIPT_DIR/publish-no-replace.py"
WINDOWS_POWERSHELL="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
WINDOWS_WHOAMI="/c/Windows/System32/whoami.exe"
for arg in "$@"; do
  case "$arg" in
    --cases-dir=*) CASES_DIR="${arg#*=}" ;;
    --results-dir=*) RESULTS_DIR="${arg#*=}" ;;
    *) echo "eval-gate: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

for cmd in jq sha256sum find python ssh-keygen iconv base64 tr; do command -v "$cmd" >/dev/null 2>&1 || { echo "eval-gate: $cmd is required" >&2; exit 2; }; done
[ -d "$CASES_DIR" ] && [ ! -L "$CASES_DIR" ] || { echo "eval-gate: cases directory missing or unsafe" >&2; exit 2; }
[ -d "$RESULTS_DIR" ] && [ ! -L "$RESULTS_DIR" ] || { echo "eval-gate: results directory missing or unsafe" >&2; exit 1; }
[ -f "$ALLOWED_SIGNERS" ] && [ ! -L "$ALLOWED_SIGNERS" ] || { echo "eval-gate: trusted signer anchor missing or unsafe" >&2; exit 2; }
for path in "$ATTESTER" "$ACL_HELPER" "$ACL_RECOVERY" "$ISOLATION_PROBE" "$EXECUTABLE_GUARD" "$AGENT_PUBLISHERS" "$AGENT_BUILD_VERIFIER" "$PUBLISHER"; do [ -f "$path" ] && [ ! -L "$path" ] || { echo "eval-gate: eval authority missing or unsafe: $path" >&2; exit 2; }; done

sha() { sha256sum "$1" | awk '{print $1}'; }
host_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then path="$(cygpath -aw "$path")" || return 1; fi
  python - "$path" <<'PY'
import os, sys
print(os.path.normcase(os.path.realpath(sys.argv[1])).replace(os.sep, "/"))
PY
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

expected_probe_command() {
  local evidence="$1" payload payload_b64 probe_b64 powershell_path powershell_sha whoami_path whoami_sha trusted_powershell_path trusted_powershell_sha trusted_whoami_path trusted_whoami_sha
  payload="$(jq -cS '.probe.payload' "$evidence")" || return 1
  [ "$payload" != null ] || return 1
  powershell_path="$(jq -r '.probe.executables.powershell.path // empty' "$evidence")" || return 1
  powershell_sha="$(jq -r '.probe.executables.powershell.sha256 // empty' "$evidence")" || return 1
  whoami_path="$(jq -r '.probe.executables.whoami.path // empty' "$evidence")" || return 1
  whoami_sha="$(jq -r '.probe.executables.whoami.sha256 // empty' "$evidence")" || return 1
  trusted_powershell_path="$(jq -r '.windows_system_tools.powershell.path // empty' "$AGENT_PUBLISHERS")" || return 1
  trusted_powershell_sha="$(jq -r '.windows_system_tools.powershell.sha256 // empty | ascii_downcase' "$AGENT_PUBLISHERS")" || return 1
  trusted_whoami_path="$(jq -r '.windows_system_tools.whoami.path // empty' "$AGENT_PUBLISHERS")" || return 1
  trusted_whoami_sha="$(jq -r '.windows_system_tools.whoami.sha256 // empty | ascii_downcase' "$AGENT_PUBLISHERS")" || return 1
  [ "$powershell_path" = "$trusted_powershell_path" ] || return 1
  [ "${powershell_sha,,}" = "$trusted_powershell_sha" ] || return 1
  [ "$whoami_path" = "$trusted_whoami_path" ] || return 1
  [ "${whoami_sha,,}" = "$trusted_whoami_sha" ] || return 1
  [ "$(jq -r '.whoami_file // empty' <<< "$payload")" = "$whoami_path" ] || return 1
  payload_b64="$(printf '%s' "$payload" | base64 | tr -d '\r\n')" || return 1
  probe_b64="$(iconv -f UTF-8 -t UTF-16LE < "$ISOLATION_PROBE" | base64 | tr -d '\r\n')" || return 1
  [ -n "$probe_b64" ] || return 1
  printf '$env:HARNESS_EVAL_PROBE_PAYLOAD='"'"'%s'"'"'; & '"'"'%s'"'"' -NoProfile -ExecutionPolicy Bypass -EncodedCommand '"'"'%s'"'"'\n' \
    "$payload_b64" "$powershell_path" "$probe_b64"
}

directory_manifest() {
  python - "$1" "$2" "${3:-}" <<'PY'
import hashlib, json, os, stat, sys
root, output, ignored_root_name = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3]
records = []
for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
    if base == root and ignored_root_name:
        dirs[:] = [d for d in dirs if d != ignored_root_name]
        files = [f for f in files if f != ignored_root_name]
    dirs.sort(); files.sort()
    for name in dirs + files:
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        st = os.lstat(path)
        rec = {"path": rel, "mode": format(stat.S_IMODE(st.st_mode), "04o")}
        if stat.S_ISLNK(st.st_mode): rec.update(type="symlink", target=os.readlink(path))
        elif stat.S_ISDIR(st.st_mode): rec.update(type="dir")
        elif stat.S_ISREG(st.st_mode):
            h = hashlib.sha256()
            flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(path, flags)
            try:
                for chunk in iter(lambda: os.read(fd, 1024 * 1024), b""): h.update(chunk)
            finally: os.close(fd)
            rec.update(type="file", sha256=h.hexdigest())
        else: rec.update(type="other")
        records.append(rec)
records.sort(key=lambda rec: rec["path"].encode("utf-8", "surrogateescape"))
with open(output, "x", encoding="utf-8", newline="\n") as fh:
    for rec in records:
        fh.write(json.dumps(rec, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

# Read each signed result and all of its companions from one stable, private
# snapshot. Validation never mixes pathname reads from concurrently replaceable
# files in the public results directory.
snapshot_evidence_set() {
  python - "$@" <<'PY'
import hashlib, json, os, stat, sys

manifest = sys.argv[1]
args = sys.argv[2:]
if not args or len(args) % 2:
    raise SystemExit("snapshot requires SRC DST pairs")

def signature(st):
    return {
        "dev": int(st.st_dev), "ino": int(st.st_ino),
        "size": int(st.st_size), "mtime_ns": int(st.st_mtime_ns),
    }

records = []
for source, destination in zip(args[0::2], args[1::2]):
    source = os.path.abspath(source)
    destination = os.path.abspath(destination)
    before = os.lstat(source)
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit("unsafe evidence source: " + source)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    src = os.open(source, flags)
    opened = os.fstat(src)
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        os.close(src)
        raise SystemExit("evidence source changed while opening: " + source)
    dst = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
    digest = hashlib.sha256()
    try:
        while True:
            chunk = os.read(src, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                view = view[os.write(dst, view):]
        os.fsync(dst)
        after_fd = os.fstat(src)
    finally:
        os.close(dst)
        os.close(src)
    after_path = os.lstat(source)
    if signature(before) != signature(after_fd) or not stat.S_ISREG(after_path.st_mode) or signature(before) != signature(after_path):
        raise SystemExit("evidence source changed while reading: " + source)
    records.append({
        "source": source, "snapshot": destination,
        "sha256": digest.hexdigest(), "signature": signature(before),
    })

for rec in records:
    current = os.lstat(rec["source"])
    if not stat.S_ISREG(current.st_mode) or signature(current) != rec["signature"]:
        raise SystemExit("evidence source set changed: " + rec["source"])

with open(manifest, "x", encoding="utf-8", newline="\n") as fh:
    json.dump(records, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
    fh.flush()
    os.fsync(fh.fileno())
PY
}

verify_evidence_sources() {
  python - "$1" <<'PY'
import hashlib, json, os, stat, sys

def signature(st):
    return {
        "dev": int(st.st_dev), "ino": int(st.st_ino),
        "size": int(st.st_size), "mtime_ns": int(st.st_mtime_ns),
    }

with open(sys.argv[1], encoding="utf-8") as fh:
    records = json.load(fh)
for rec in records:
    path = rec["source"]
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or signature(before) != rec["signature"]:
        raise SystemExit("evidence source identity changed: " + path)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    digest = hashlib.sha256()
    try:
        opened = os.fstat(fd)
        if signature(opened) != rec["signature"]:
            raise SystemExit("evidence source changed while reopening: " + path)
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after_fd = os.fstat(fd)
    finally:
        os.close(fd)
    after_path = os.lstat(path)
    if (signature(after_fd) != rec["signature"] or signature(after_path) != rec["signature"]
            or digest.hexdigest() != rec["sha256"]):
        raise SystemExit("evidence source changed during final verification: " + path)

# Close the sequential gap across the whole set: after every member has been
# rehashed once, repeat an identity+digest pass over all authoritative names.
for rec in records:
    path = rec["source"]
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or signature(before) != rec["signature"]:
        raise SystemExit("evidence source set changed: " + path)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    digest = hashlib.sha256()
    try:
        opened = os.fstat(fd)
        if signature(opened) != rec["signature"]:
            raise SystemExit("evidence source set changed while reopening: " + path)
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after_fd = os.fstat(fd)
    finally:
        os.close(fd)
    after_path = os.lstat(path)
    if (not stat.S_ISREG(after_path.st_mode) or signature(after_fd) != rec["signature"]
            or signature(after_path) != rec["signature"] or digest.hexdigest() != rec["sha256"]):
        raise SystemExit("evidence source set changed during concluding verification: " + path)
PY
}

publication_lock="$RESULTS_DIR/.eval-write.lock"
if ! mkdir "$publication_lock" 2>/dev/null; then
  echo "eval-gate: result publication is incomplete or another gate is active" >&2
  exit 1
fi
gate_lock_owned=true
tmp="$(mktemp -d)" || { rmdir "$publication_lock" 2>/dev/null || true; exit 2; }
cleanup() {
  if [ -n "${tmp:-}" ] && [ -d "$tmp" ]; then rm -rf -- "$tmp"; fi
  if [ "${gate_lock_owned:-false}" = true ]; then rmdir "$publication_lock" 2>/dev/null || true; fi
}
trap cleanup EXIT
directory_manifest "$CASES_DIR" "$tmp/cases.before.manifest" || { echo "eval-gate: case authority snapshot failed" >&2; exit 2; }
directory_manifest "$RESULTS_DIR" "$tmp/results.before.manifest" ".eval-write.lock" || { echo "eval-gate: result snapshot failed" >&2; exit 2; }
runtime_file_manifest "$ROOT" "$tmp/runtime.manifest" || { echo "eval-gate: current runtime authority is unsafe" >&2; exit 2; }
runtime_sha="$(sha "$tmp/runtime.manifest")"
skill_sha="$(sha "$ROOT/SKILL.md")"
runner_sha="$(sha "$SCRIPT_DIR/run-eval.sh")"
schema_sha="$(sha "$SCRIPT_DIR/reviewer-output.schema.json")"
attester_sha="$(sha "$ATTESTER")"
isolation_helper_sha="$(sha "$ACL_HELPER")"
isolation_probe_sha="$(sha "$ISOLATION_PROBE")"
executable_guard_sha="$(sha "$EXECUTABLE_GUARD")"
isolation_recovery_sha="$(sha "$ACL_RECOVERY")"
agent_publishers_sha="$(sha "$AGENT_PUBLISHERS")"
agent_build_verifier_sha="$(sha "$AGENT_BUILD_VERIFIER")"
publisher_sha="$(sha "$PUBLISHER")"
allowed_signers_sha="$(sha "$ALLOWED_SIGNERS")"
codex_publisher_subject="$(jq -r '.agents.codex.publisher_subject // empty' "$AGENT_PUBLISHERS")"
codex_publisher_thumbprints="$(jq -c '.agents.codex.publisher_thumbprints // []' "$AGENT_PUBLISHERS")"
codex_approved_builds="$(jq -c '.agents.codex.approved_builds // []' "$AGENT_PUBLISHERS")"
[ -n "$codex_publisher_subject" ] && [ "$codex_publisher_thumbprints" != '[]' ] && [ "$codex_approved_builds" != '[]' ] || { echo "eval-gate: Agent publisher policy is invalid" >&2; exit 2; }
trusted_fingerprint="$(awk '$1 == "harness-eval-release" {print $2, $3; exit}' "$ALLOWED_SIGNERS" | ssh-keygen -lf - -E sha256 | awk '{print $2}')"
[ -n "$trusted_fingerprint" ] || { echo "eval-gate: trusted signer fingerprint unavailable" >&2; exit 2; }

artifact_suffixes=(transcript.jsonl tree.sha256 subject-events.jsonl reviewer-events.jsonl turn-trees.jsonl evaluator-events.jsonl reviewer-output.json objective-checks.jsonl project-brief.json isolation.json)
artifact_keys=(transcript tree subject_events reviewer_events turn_trees evaluator_events reviewer_output objective_checks project_brief isolation)

total=0
confirmed=0
failed=''
snapshot_manifests=()
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

  source_latest="$latest"
  source_base="${source_latest%.json}"
  snapshot_dir="$tmp/snapshot-$total"
  snapshot_manifest="$tmp/snapshot-$total.manifest.json"
  mkdir "$snapshot_dir"
  snapshot_args=("$source_latest" "$snapshot_dir/$(basename "$source_latest")")
  for suffix in "${artifact_suffixes[@]}"; do
    snapshot_args+=("$source_base.$suffix" "$snapshot_dir/$(basename "$source_base.$suffix")")
  done
  snapshot_args+=("$source_base.attestation.sig" "$snapshot_dir/$(basename "$source_base.attestation.sig")")
  if ! snapshot_evidence_set "$snapshot_manifest" "${snapshot_args[@]}"; then
    failed="$failed $name@$version(unsafe-or-racing-evidence-set)"
    continue
  fi
  snapshot_manifests+=("$snapshot_manifest")
  latest="$snapshot_dir/$(basename "$source_latest")"

  if [ -n "${HARNESS_EVAL_GATE_TEST_AFTER_SNAPSHOT_HOOK:-}" ]; then
    results_abs="$(cd "$RESULTS_DIR" && pwd -P)"
    canonical_results_abs="$(cd "$SCRIPT_DIR/results" && pwd -P)"
    [ "$results_abs" != "$canonical_results_abs" ] || { echo "eval-gate: snapshot hook is test-only" >&2; exit 2; }
    [ -f "$HARNESS_EVAL_GATE_TEST_AFTER_SNAPSHOT_HOOK" ] && [ ! -L "$HARNESS_EVAL_GATE_TEST_AFTER_SNAPSHOT_HOOK" ] \
      || { echo "eval-gate: snapshot hook missing or unsafe" >&2; exit 2; }
    bash "$HARNESS_EVAL_GATE_TEST_AFTER_SNAPSHOT_HOOK" "$source_latest" \
      || { echo "eval-gate: snapshot hook failed" >&2; exit 2; }
  fi

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
  expected_probe="$(expected_probe_command "$base.isolation.json" 2>/dev/null || true)"
  if [ -n "$expected_probe" ] && jq -e --arg expected_probe "$expected_probe" '
    def norm: gsub("\\\\"; "/") | ascii_downcase | sub("/+$"; "");
    . as $e
    | ([$e.denied_roots[] | norm]) as $roots
    | ($e.probe.payload.target_file | norm) as $target
    | ($e.probe.payload.source_file | norm) as $source
    | ($e.probe.payload.controller_file | norm) as $controller_file
    | ($e.probe.payload.user_home | norm) as $user_home
    | $e.schema_version == 2 and $e.isolation == "windows-native-elevated-acl"
    and $e.controller_visible_to_agent == false and $e.source_workspace_visible_to_agent == false
    and $e.user_home_visible_to_agent == false
    and $e.network == "codex-workspace-write-offline"
    and ($e.sandbox_accounts | type == "array" and length == 2)
    and ([$e.sandbox_accounts[].Name] | sort == ["CodexSandboxOffline", "CodexSandboxOnline"])
    and ([$e.sandbox_accounts[].Sid] | unique | length == 2 and all(.[]; test("^S-[0-9-]+$")))
    and ($e.denied_roots | type == "array" and length == 3 and (unique | length == 3) and all(.[]; type == "string" and length > 0))
    and ($e.checks | type == "array" and length == 6 and all(.[]; .read_execute_denied == true))
    and ([
      $e.denied_roots[] as $root
      | $e.sandbox_accounts[] as $account
      | (([$e.checks[] | select(
        .path == $root
        and .sandbox_account == $account.Name
        and .sandbox_sid == $account.Sid
        and .read_execute_denied == true
      )] | length) == 1)
    ] | length == 6 and all)
    and $e.probe.command_event.type == "command_execution"
    and $e.probe.command_event.status == "completed"
    and $e.probe.command_event.exit_code == 0
    and $e.probe.command_event.command == $expected_probe
    and (($e.probe.command_event.aggregated_output
      | split("\n") | map(rtrimstr("\r")) | map(select(length > 0)) | last | fromjson) == $e.probe.result)
    and ($e.probe.payload | keys | sort == ["controller_file","nonce","source_file","target_file","user_home","whoami_file"])
    and ($e.probe.executables | keys | sort == ["powershell","whoami"])
    and (all($e.probe.executables[]; (.path | type == "string" and length > 0) and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
    and ($e.probe.result | keys | sort == ["controller_readable","identity","nonce","source_workspace_readable","target_file_readable","target_writeable","user_home_readable"])
    and $e.probe.payload.nonce == $e.probe.result.nonce
    and ($e.probe.result.nonce | type == "string" and length > 0)
    and ($source | startswith($roots[0] + "/")) and ($source | endswith("/skill.md"))
    and $user_home == $roots[1]
    and ($controller_file | startswith($roots[2] + "/")) and ($controller_file | endswith("/runtime.manifest"))
    and ([range(0; $roots|length) as $i | ($target | startswith($roots[$i] + "/") | not)] | all)
    and ($e.probe.result.identity | ascii_downcase | endswith("\\codexsandboxoffline"))
    and $e.probe.result.target_file_readable == true
    and $e.probe.result.target_writeable == true
    and $e.probe.result.source_workspace_readable == false
    and $e.probe.result.controller_readable == false
    and $e.probe.result.user_home_readable == false
    and ($e.probe.sanitized_path | type == "array" and length >= 4
      and all(.[]; type == "string" and length > 0 and ((ascii_downcase | contains("/users/")) | not)))
  ' "$base.isolation.json" >/dev/null 2>&1; then isolation_valid=true; fi

  if [ "$bound" = true ] && [ "$signature_valid" = true ] && [ "$brief_valid" = true ] && [ "$isolation_valid" = true ] && jq -e \
    --arg name "$name" --arg version "$version" --arg scenario "$scenario" \
    --arg case_sha "$(sha "$case_file")" --arg skill_sha "$skill_sha" --arg runtime_sha "$runtime_sha" \
    --arg runner_sha "$runner_sha" --arg schema_sha "$schema_sha" --arg rubric_sha "$(sha "$tmp/rubric.json")" --arg signer_fingerprint "$trusted_fingerprint" \
    --arg attester_sha "$attester_sha" --arg isolation_helper_sha "$isolation_helper_sha" --arg isolation_recovery_sha "$isolation_recovery_sha" --arg isolation_probe_sha "$isolation_probe_sha" --arg executable_guard_sha "$executable_guard_sha" --arg agent_publishers_sha "$agent_publishers_sha" --arg agent_build_verifier_sha "$agent_build_verifier_sha" --arg publisher_sha "$publisher_sha" \
    --arg codex_publisher_subject "$codex_publisher_subject" --argjson codex_publisher_thumbprints "$codex_publisher_thumbprints" --argjson approved_builds "$codex_approved_builds" \
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
      and .authority.isolation_recovery_sha256 == $isolation_recovery_sha
      and .authority.isolation_probe_sha256 == $isolation_probe_sha
      and .authority.executable_guard_sha256 == $executable_guard_sha
      and .authority.agent_publishers_sha256 == $agent_publishers_sha
      and .authority.agent_build_verifier_sha256 == $agent_build_verifier_sha
      and .authority.publisher_sha256 == $publisher_sha
      and .isolation.kind == "windows-native-elevated-acl"
      and .isolation.source_workspace_denied == true and .isolation.user_home_denied == true and .isolation.controller_denied == true
      and (.rubric_details.checks | type == "array" and length > 0 and all(.[]; .pass == true))
      and (.objective_checks | type == "array" and length > 0 and all(.[]; .pass == true))
      and (.rubric_score | capture("^(?<p>[0-9]+)/(?<t>[0-9]+)$") | (.p|tonumber) == (.t|tonumber))
      and .subject.name == "codex"
      and (.subject.executable | type == "string" and test("/(codex|codex.exe)$"; "i"))
      and (.subject.executable_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
      and (.subject.authenticode.status == "Valid")
      and .subject.authenticode.subject == $codex_publisher_subject
      and (.subject.authenticode.thumbprint as $thumbprint | ($codex_publisher_thumbprints | index($thumbprint)) != null)
      and (.subject.cli_version | type == "string" and length > 0)
      and (.subject as $agent | any($approved_builds[]; .cli_version == $agent.cli_version and (.sha256 | ascii_downcase) == $agent.executable_sha256))
      and (.subject.model | type == "string" and length > 0)
      and (.subject.session_ids | type == "array" and length == $input_count and (unique|length) == $input_count and all(.[]; type == "string" and length > 0))
      and .reviewer.name == "codex"
      and (.reviewer.executable | type == "string" and test("/(codex|codex.exe|claude|claude.exe)$"; "i"))
      and (.reviewer.executable_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
      and (.reviewer.authenticode.status == "Valid")
      and .reviewer.authenticode.subject == $codex_publisher_subject
      and (.reviewer.authenticode.thumbprint as $thumbprint | ($codex_publisher_thumbprints | index($thumbprint)) != null)
      and (.reviewer.cli_version | type == "string" and length > 0)
      and (.reviewer as $agent | any($approved_builds[]; .cli_version == $agent.cli_version and (.sha256 | ascii_downcase) == $agent.executable_sha256))
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

for snapshot_manifest in "${snapshot_manifests[@]}"; do
  verify_evidence_sources "$snapshot_manifest" || { echo "eval-gate: evidence changed during validation" >&2; exit 1; }
done

# The cooperative publication lock spans the full gate. Recompute both public
# directory memberships and every current authority after all per-case checks.
[ -d "$publication_lock" ] && [ ! -L "$publication_lock" ] || { echo "eval-gate: publication lock changed during validation" >&2; exit 1; }
directory_manifest "$CASES_DIR" "$tmp/cases.after.manifest" || { echo "eval-gate: final case authority snapshot failed" >&2; exit 2; }
directory_manifest "$RESULTS_DIR" "$tmp/results.after.manifest" ".eval-write.lock" || { echo "eval-gate: final result snapshot failed" >&2; exit 2; }
[ "$(sha "$tmp/cases.before.manifest")" = "$(sha "$tmp/cases.after.manifest")" ] \
  || { echo "eval-gate: case authority membership or content changed during validation" >&2; exit 1; }
[ "$(sha "$tmp/results.before.manifest")" = "$(sha "$tmp/results.after.manifest")" ] \
  || { echo "eval-gate: result membership or content changed during validation" >&2; exit 1; }
runtime_file_manifest "$ROOT" "$tmp/runtime.after.manifest" || { echo "eval-gate: final runtime authority snapshot failed" >&2; exit 2; }
[ "$runtime_sha" = "$(sha "$tmp/runtime.after.manifest")" ] \
  && [ "$skill_sha" = "$(sha "$ROOT/SKILL.md")" ] \
  && [ "$runner_sha" = "$(sha "$SCRIPT_DIR/run-eval.sh")" ] \
  && [ "$schema_sha" = "$(sha "$SCRIPT_DIR/reviewer-output.schema.json")" ] \
  && [ "$attester_sha" = "$(sha "$ATTESTER")" ] \
  && [ "$isolation_helper_sha" = "$(sha "$ACL_HELPER")" ] \
  && [ "$isolation_recovery_sha" = "$(sha "$ACL_RECOVERY")" ] \
  && [ "$isolation_probe_sha" = "$(sha "$ISOLATION_PROBE")" ] \
  && [ "$executable_guard_sha" = "$(sha "$EXECUTABLE_GUARD")" ] \
  && [ "$agent_publishers_sha" = "$(sha "$AGENT_PUBLISHERS")" ] \
  && [ "$agent_build_verifier_sha" = "$(sha "$AGENT_BUILD_VERIFIER")" ] \
  && [ "$publisher_sha" = "$(sha "$PUBLISHER")" ] \
  && [ "$allowed_signers_sha" = "$(sha "$ALLOWED_SIGNERS")" ] \
  || { echo "eval-gate: current authority changed during validation" >&2; exit 1; }

[ "$total" -gt 0 ] || { echo "eval-gate: no cases found" >&2; exit 2; }
echo "eval-gate: $confirmed/$total current cases passed with real CONFIRMED evidence"
if [ -n "$failed" ]; then echo "eval-gate: blocking:$failed" >&2; exit 1; fi
