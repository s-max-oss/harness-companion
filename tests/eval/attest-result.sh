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
ACL_RECOVERY="$SCRIPT_DIR/recover-windows-isolation.sh"
ISOLATION_PROBE="$SCRIPT_DIR/windows-isolation-probe.ps1"
PROBE_COMMAND_VALIDATOR="$SCRIPT_DIR/validate-probe-command.py"
EXECUTABLE_GUARD="$SCRIPT_DIR/windows-executable-guard.ps1"
AGENT_PUBLISHERS="$SCRIPT_DIR/trust/agent-publishers.json"
AGENT_BUILD_VERIFIER="$SCRIPT_DIR/verify-agent-build.sh"
PUBLISHER="$SCRIPT_DIR/publish-no-replace.py"
WINDOWS_POWERSHELL="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
WINDOWS_WHOAMI="/c/Windows/System32/whoami.exe"
TRUSTED_WINDOWS_ENV="/c/Program Files/Git/usr/bin/env.exe"

die() { echo "eval-attest: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
sha() { sha256sum "$1" | awk '{print $1}'; }

# Copy a candidate and every bound companion into private staging without
# following links or replacing a destination. The source metadata is checked
# before/after each read and again after the whole set has been imported, so a
# concurrent replacement cannot create a mixed snapshot. A manifest retained
# in private staging supports the final pre-publication recheck.
snapshot_inputs() {
  python - "$@" <<'PY'
import hashlib, json, os, stat, sys

manifest = sys.argv[1]
args = sys.argv[2:]
if len(args) == 0 or len(args) % 2:
    raise SystemExit("snapshot requires SRC DST pairs")

def signature(st):
    # Windows may advance st_ctime when a freshly copied file is first opened;
    # identity, size, mtime, and the independently checked digest are stable.
    return {
        "dev": int(st.st_dev), "ino": int(st.st_ino),
        "size": int(st.st_size), "mtime_ns": int(st.st_mtime_ns),
    }

def open_source(path):
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit("unsafe snapshot source: " + path)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        os.close(fd)
        raise SystemExit("snapshot source changed while opening: " + path)
    return fd, before

records = []
for source, destination in zip(args[0::2], args[1::2]):
    source = os.path.abspath(source)
    destination = os.path.abspath(destination)
    fd, before = open_source(source)
    out = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0),
        0o600,
    )
    digest = hashlib.sha256()
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(out, view)
                view = view[written:]
        os.fsync(out)
        after_fd = os.fstat(fd)
    finally:
        os.close(out)
        os.close(fd)
    if signature(before) != signature(after_fd):
        raise SystemExit(
            "snapshot source changed while reading: "
            + source + " before=" + repr(signature(before))
            + " after=" + repr(signature(after_fd))
        )
    after_path = os.lstat(source)
    if not stat.S_ISREG(after_path.st_mode) or signature(before) != signature(after_path):
        raise SystemExit("snapshot source was replaced: " + source)
    records.append({
        "source": source,
        "snapshot": destination,
        "sha256": digest.hexdigest(),
        "signature": signature(before),
    })

# Close the set-level race: every source must still name the exact file
# identity imported above after all members have been copied.
for rec in records:
    current = os.lstat(rec["source"])
    if not stat.S_ISREG(current.st_mode) or signature(current) != rec["signature"]:
        raise SystemExit("snapshot source set changed: " + rec["source"])

fd = os.open(
    manifest,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0),
    0o600,
)
with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(records, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
    fh.flush()
    os.fsync(fh.fileno())
PY
}

verify_snapshot_sources() {
  python - "$1" <<'PY'
import hashlib, json, os, stat, subprocess, sys

recheck_hook = os.environ.get("HARNESS_EVAL_TEST_DURING_RECHECK_HOOK", "")
recheck_target = os.path.normcase(os.path.abspath(
    os.environ.get("HARNESS_EVAL_TEST_DURING_RECHECK_TARGET", "")
))
after_first_hook = os.environ.get("HARNESS_EVAL_TEST_AFTER_FIRST_RECHECK_HOOK", "")

def signature(st):
    # See snapshot_inputs: st_ctime is not a stable read-only signal on Windows.
    return {
        "dev": int(st.st_dev), "ino": int(st.st_ino),
        "size": int(st.st_size), "mtime_ns": int(st.st_mtime_ns),
    }

def digest_regular(path):
    global recheck_hook
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit("unsafe recheck source: " + path)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    opened = os.fstat(fd)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        os.close(fd)
        raise SystemExit("recheck source changed while opening: " + path)
    h = hashlib.sha256()
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    if signature(before) != signature(after):
        raise SystemExit("recheck source changed while reading: " + path)
    if recheck_hook and os.path.normcase(os.path.abspath(path)) == recheck_target:
        subprocess.run(["bash", recheck_hook, path], check=True)
        recheck_hook = ""
    after_path = os.lstat(path)
    if not stat.S_ISREG(after_path.st_mode) or signature(after_path) != signature(before):
        raise SystemExit("recheck source path changed after reading: " + path)
    return before, h.hexdigest()

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    records = json.load(fh)
for index, rec in enumerate(records):
    current, source_sha = digest_regular(rec["source"])
    if signature(current) != rec["signature"] or source_sha != rec["sha256"]:
        raise SystemExit("candidate input changed after snapshot: " + rec["source"])
    _, snapshot_sha = digest_regular(rec["snapshot"])
    if snapshot_sha != rec["sha256"]:
        raise SystemExit("private snapshot changed: " + rec["snapshot"])
    if index == 0 and after_first_hook:
        subprocess.run(["bash", after_first_hook, rec["source"]], check=True)

# Close the sequential-verification gap: an early source may change while later
# records are being checked, so resolve every authoritative pathname once more.
for rec in records:
    current = os.lstat(rec["source"])
    if not stat.S_ISREG(current.st_mode) or signature(current) != rec["signature"]:
        raise SystemExit("candidate input set changed after final recheck: " + rec["source"])
PY
}

host_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then path="$(cygpath -aw "$path")" || return 1; fi
  python - "$path" <<'PY'
import os, sys
print(os.path.normcase(os.path.realpath(sys.argv[1])).replace(os.sep, "/"))
PY
}

windows_powershell() {
  [ -f "$WINDOWS_POWERSHELL" ] && [ ! -L "$WINDOWS_POWERSHELL" ] || return 127
  [ -f "$TRUSTED_WINDOWS_ENV" ] && [ -x "$TRUSTED_WINDOWS_ENV" ] && [ ! -L "$TRUSTED_WINDOWS_ENV" ] || return 127
  "$TRUSTED_WINDOWS_ENV" -u PSModulePath "$WINDOWS_POWERSHELL" "$@"
}

official_agent_identity() {
  local agent="$1" executable="$2" executable_win identity policy expected_subject expected_thumbprints
  [ -f "$executable" ] && [ -x "$executable" ] && [ ! -L "$executable" ] || return 1
  policy="$(jq -ce --arg agent "$agent" '.agents[$agent]' "$AGENT_PUBLISHERS")" || return 1
  expected_subject="$(jq -r '.publisher_subject' <<< "$policy")" || return 1
  expected_thumbprints="$(jq -c '.publisher_thumbprints' <<< "$policy")" || return 1
  executable_win="$(cygpath -w "$executable")" || return 1
  identity="$(HARNESS_EVAL_AUTH_PATH="$executable_win" windows_powershell -NoProfile -Command '
    $sig = Get-AuthenticodeSignature -LiteralPath $env:HARNESS_EVAL_AUTH_PATH
    $subject = if ($null -ne $sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" }
    $thumbprint = if ($null -ne $sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { "" }
    [ordered]@{status=[string]$sig.Status;subject=$subject;thumbprint=$thumbprint} | ConvertTo-Json -Compress
  ' | tr -d '\r')" || return 1
  jq -e --arg expected_subject "$expected_subject" --argjson expected_thumbprints "$expected_thumbprints" '
    .status == "Valid"
    and .subject == $expected_subject
    and (.thumbprint as $thumbprint | ($expected_thumbprints | index($thumbprint)) != null)
  ' <<< "$identity" >/dev/null || return 1
  printf '%s\n' "$identity"
}

official_runtime_tool_identity() {
  local tool="$1" executable="$2" executable_win identity policy expected_subject expected_thumbprints
  [ -f "$executable" ] && [ -x "$executable" ] && [ ! -L "$executable" ] || return 1
  policy="$(jq -ce --arg tool "$tool" '.windows_runtime_tools[$tool]' "$AGENT_PUBLISHERS")" || return 1
  expected_subject="$(jq -r '.publisher_subject' <<< "$policy")" || return 1
  expected_thumbprints="$(jq -c '.publisher_thumbprints' <<< "$policy")" || return 1
  executable_win="$(cygpath -w "$executable")" || return 1
  identity="$(HARNESS_EVAL_AUTH_PATH="$executable_win" windows_powershell -NoProfile -Command '
    $sig = Get-AuthenticodeSignature -LiteralPath $env:HARNESS_EVAL_AUTH_PATH
    $subject = if ($null -ne $sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" }
    $thumbprint = if ($null -ne $sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { "" }
    [ordered]@{status=[string]$sig.Status;subject=$subject;thumbprint=$thumbprint} | ConvertTo-Json -Compress
  ' | tr -d '\r')" || return 1
  jq -e --arg expected_subject "$expected_subject" --argjson expected_thumbprints "$expected_thumbprints" '
    .status == "Valid"
    and .subject == $expected_subject
    and (.thumbprint as $thumbprint | ($expected_thumbprints | index($thumbprint)) != null)
  ' <<< "$identity" >/dev/null || return 1
  printf '%s\n' "$identity"
}

verify_runtime_tool_evidence() {
  local tool="$1" executable="$2" expected_sha="$3" expected_identity="$4" actual_identity approved_hashes
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -e 'type == "object" and keys == ["status","subject","thumbprint"]
    and all(.status,.subject,.thumbprint; type == "string" and length > 0)' <<< "$expected_identity" >/dev/null \
    || return 1
  actual_identity="$(official_runtime_tool_identity "$tool" "$executable")" || return 1
  approved_hashes="$(jq -c --arg tool "$tool" '.windows_runtime_tools[$tool].approved_sha256 // [] | map(ascii_downcase)' "$AGENT_PUBLISHERS")" \
    || return 1
  [ "$(sha "$executable")" = "$expected_sha" ] \
    && jq -e --arg sha "$expected_sha" 'index($sha) != null' <<< "$approved_hashes" >/dev/null \
    && jq -en --argjson expected "$expected_identity" --argjson actual "$actual_identity" '$actual == $expected' >/dev/null \
    || return 1
  printf '%s\n' "$actual_identity"
}

official_agent_build() {
  bash "$AGENT_BUILD_VERIFIER" "$AGENT_PUBLISHERS" "$1" "$2" "$3"
}

official_agent_component_build() {
  bash "$AGENT_BUILD_VERIFIER" "$AGENT_PUBLISHERS" "$1" "$2" "$3" "$4"
}

verify_agent_component_evidence() {
  local agent="$1" version="$2" component="$3" executable="$4" expected_sha="$5" expected_identity="$6" actual_identity
  [[ "$component" =~ ^codex-[a-z0-9-]+[.]exe$ ]] || return 1
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -e 'type == "object" and keys == ["status","subject","thumbprint"]
    and all(.status,.subject,.thumbprint; type == "string" and length > 0)' <<< "$expected_identity" >/dev/null \
    || return 1
  actual_identity="$(official_agent_identity "$agent" "$executable")" || return 1
  [ "$(sha "$executable")" = "$expected_sha" ] \
    && official_agent_component_build "$agent" "$version" "$component" "$expected_sha" \
    && jq -en --argjson expected "$expected_identity" --argjson actual "$actual_identity" '$actual == $expected' >/dev/null \
    || return 1
  printf '%s\n' "$actual_identity"
}

official_agent_path() {
  local agent="$1" executable="$2" user_home="$3" executable_host home_host install_subpath prefix relative executable_names
  executable_host="$(host_path "$executable")" || return 1
  home_host="$(host_path "$user_home")" || return 1
  install_subpath="$(jq -r --arg agent "$agent" '.agents[$agent].install_subpath // empty | ascii_downcase' "$AGENT_PUBLISHERS")" || return 1
  executable_names="$(jq -c --arg agent "$agent" '.agents[$agent].executable_names // [] | map(ascii_downcase)' "$AGENT_PUBLISHERS")" || return 1
  [ -n "$install_subpath" ] && [ "$executable_names" != '[]' ] || return 1
  prefix="$home_host/$install_subpath/"
  case "$executable_host" in "$prefix"*) ;; *) return 1 ;; esac
  relative="${executable_host#"$prefix"}"
  [[ "$relative" =~ ^[0-9a-f]{16}/([^/]+)$ ]] || return 1
  jq -e --arg name "${BASH_REMATCH[1]}" 'index($name) != null' <<< "$executable_names" >/dev/null
}

expected_probe_command() {
  local evidence="$1" payload payload_sha powershell_path powershell_sha whoami_path whoami_sha trusted_powershell_path trusted_powershell_sha trusted_whoami_path trusted_whoami_sha controller_file controller_suffix script_path recorded_script_path recorded_script_sha
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
  payload_sha="$(printf '%s' "$payload" | sha256sum | awk '{print $1}')" || return 1
  controller_file="$(jq -r '.controller_file // empty' <<< "$payload")" || return 1
  controller_suffix='\controller\runtime.manifest'
  case "$controller_file" in *"$controller_suffix") ;; *) return 1 ;; esac
  script_path="${controller_file%"$controller_suffix"}\agent-bin\isolation-probe.ps1"
  recorded_script_path="$(jq -r '.probe.script.path // empty' "$evidence")" || return 1
  recorded_script_sha="$(jq -r '.probe.script.sha256 // empty | ascii_downcase' "$evidence")" || return 1
  [ "$recorded_script_path" = "$script_path" ] || return 1
  python "$PROBE_COMMAND_VALIDATOR" --probe-script-path "$controller_file" "$recorded_script_path" >/dev/null 2>&1 || return 1
  [ "$recorded_script_sha" = "$(sha "$ISOLATION_PROBE")" ] || return 1
  printf '& '"'"'%s'"'"' -NoProfile -ExecutionPolicy Bypass -File '"'"'%s'"'"' -ExpectedPayloadSha256 '"'"'%s'"'"'\n' \
    "$powershell_path" "$script_path" "$payload_sha"
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

if [ "${1:-}" = "--verify-runtime-tool-evidence" ]; then
  [ "$#" -eq 5 ] || die "usage: attest-result.sh --verify-runtime-tool-evidence <tool> <executable> <sha256> <identity-json>"
  need jq
  need cygpath
  verify_runtime_tool_evidence "$2" "$3" "$4" "$5" \
    || die "runtime tool evidence verification failed"
  exit 0
fi

if [ "${1:-}" = "--verify-agent-component-evidence" ]; then
  [ "$#" -eq 7 ] || die "usage: attest-result.sh --verify-agent-component-evidence <agent> <version> <component> <executable> <sha256> <identity-json>"
  need jq
  need cygpath
  verify_agent_component_evidence "$2" "$3" "$4" "$5" "$6" "$7" \
    || die "Agent runtime component evidence verification failed"
  exit 0
fi

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

for cmd in jq sha256sum python ssh-keygen mktemp cp find tr grep iconv base64; do need "$cmd"; done
for path in "$RUNNER" "$SCHEMA" "$ACL_HELPER" "$ACL_RECOVERY" "$ISOLATION_PROBE" "$PROBE_COMMAND_VALIDATOR" "$EXECUTABLE_GUARD" "$AGENT_PUBLISHERS" "$AGENT_BUILD_VERIFIER" "$PUBLISHER" "$ALLOWED_SIGNERS"; do
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
candidates_host="$(host_path "$candidates_abs")"
results_host="$(host_path "$results_abs")"
allowed_signers_host="$(host_path "$allowed_signers_abs")"
canonical_allowed_signers_host="$(host_path "$canonical_allowed_signers")"
canonical_candidates_host="$(host_path "$(cd "$SCRIPT_DIR/candidates" && pwd -P)")"
canonical_results_host="$(host_path "$(cd "$SCRIPT_DIR/results" && pwd -P)")"
production_trust=false
real_user_home=""
if [ "$allowed_signers_host" = "$canonical_allowed_signers_host" ]; then
  production_trust=true
  need cygpath
  [ -f "$TRUSTED_WINDOWS_ENV" ] && [ -x "$TRUSTED_WINDOWS_ENV" ] && [ ! -L "$TRUSTED_WINDOWS_ENV" ] || die "trusted Git-for-Windows env is missing or unsafe"
  case "$("$TRUSTED_WINDOWS_ENV" --version 2>/dev/null | head -1)" in 'env (GNU coreutils) '*) ;; *) die "trusted env identity is invalid" ;; esac
  real_user_home_win="$(windows_powershell -NoProfile -Command '[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)' | tr -d '\r')"
  [ -n "$real_user_home_win" ] || die "could not resolve the token-backed Windows user profile"
  real_user_home="$(cygpath -u "$real_user_home_win")"
  key_host="$(host_path "$SIGNING_KEY")"
  workspace_host="$(host_path "$(cd "$ROOT/.." && pwd -P)")"
  user_home_host="$(host_path "$real_user_home")"
  case "$key_host" in
    "$workspace_host"/*|"$user_home_host"/*) ;;
    *) die "signing key must be inside a root denied to eval sandbox accounts" ;;
  esac
else
  [ "$candidates_host" != "$canonical_candidates_host" ] \
    && [ "$results_host" != "$canonical_results_host" ] \
    || die "custom trust anchors are test-only and cannot publish to canonical directories"
fi
candidate_lock="$CANDIDATES_DIR/.eval-agent.lock"
if ! mkdir "$candidate_lock" 2>/dev/null; then
  die "Agent evaluation is active or candidate lock is stale: $candidate_lock"
fi
candidate_lock_owned=true
publication_lock="$RESULTS_DIR/.eval-write.lock"
publication_started=false
tmp=""
cleanup() {
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then rm -rf -- "$tmp"; fi
  if [ "$publication_started" = false ] && [ -d "$publication_lock" ]; then rmdir "$publication_lock" 2>/dev/null || true; fi
  if [ "$candidate_lock_owned" = true ] && [ -d "$candidate_lock" ]; then rmdir "$candidate_lock" 2>/dev/null || true; fi
}
trap cleanup EXIT

[ ! -e "$CANDIDATES_DIR/.eval-write.lock" ] && [ ! -L "$CANDIDATES_DIR/.eval-write.lock" ] || die "candidate publication is incomplete"
if ! mkdir "$publication_lock" 2>/dev/null; then die "result publication lock exists: $publication_lock"; fi

[ -f "$CANDIDATE" ] && [ ! -L "$CANDIDATE" ] || die "candidate missing or unsafe"
candidate_abs="$(cd "$(dirname "$CANDIDATE")" && pwd -P)/$(basename "$CANDIDATE")"
candidate_host="$(host_path "$candidate_abs")"
case "$candidate_host" in "$candidates_host"/*.json) ;; *) die "candidate is outside the authoritative candidate directory" ;; esac
case "$(basename "$candidate_abs")" in *.reviewer-output.json|*[!A-Za-z0-9._-]*) die "unsafe candidate name" ;; esac

tmp="$(mktemp -d "$RESULTS_DIR/.attest.XXXXXX")" || die "attestation staging failed"
base="${candidate_abs%.json}"
base_name="$(basename "$base")"
artifact_suffixes=(transcript.jsonl tree.sha256 subject-events.jsonl reviewer-events.jsonl turn-trees.jsonl evaluator-events.jsonl reviewer-output.json objective-checks.jsonl project-brief.json isolation.json)
artifact_keys=(transcript tree subject_events reviewer_events turn_trees evaluator_events reviewer_output objective_checks project_brief isolation)

snapshot_dir="$tmp/inputs"
mkdir "$snapshot_dir" || die "private snapshot directory creation failed"
snapshot_candidate="$snapshot_dir/$base_name.json"
snapshot_manifest="$tmp/input-snapshot.json"
snapshot_args=("$candidate_abs" "$snapshot_candidate")
for suffix in "${artifact_suffixes[@]}"; do
  snapshot_args+=("$base.$suffix" "$snapshot_dir/$base_name.$suffix")
done
snapshot_inputs "$snapshot_manifest" "${snapshot_args[@]}" || die "candidate snapshot failed"
snapshot_base="$snapshot_dir/$base_name"

case_name="$(jq -r '.case // empty' "$snapshot_candidate")"
case_version="$(jq -r '.case_version // empty' "$snapshot_candidate")"
scenario="$(jq -r '.scenario_ref // empty' "$snapshot_candidate")"
case_file=""
while IFS= read -r candidate_case; do
  if [ "$(jq -r '.name // empty' "$candidate_case")" = "$case_name" ]; then
    [ -z "$case_file" ] || die "duplicate case authority for $case_name"
    case_file="$candidate_case"
  fi
done < <(find "$CASES_DIR" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
[ -n "$case_file" ] && [ ! -L "$case_file" ] || die "current case authority not found"
case "$base_name" in "$case_name.$case_version."*) ;; *) die "candidate filename does not match case authority" ;; esac

runtime_file_manifest "$ROOT" "$tmp/runtime.manifest" || die "current runtime authority is unsafe"
jq -cS '.reviewer_rubric' "$case_file" > "$tmp/rubric.json"
input_count="$(jq '.mock_user_inputs | length' "$case_file")"

for ((i=0; i<${#artifact_suffixes[@]}; i++)); do
  path="$snapshot_base.${artifact_suffixes[$i]}"
  key="${artifact_keys[$i]}"
  [ -f "$path" ] && [ ! -L "$path" ] || die "candidate companion missing or unsafe: $path"
  [ "$(jq -r --arg key "$key" '.artifact_hashes[$key] // empty' "$snapshot_candidate")" = "$(sha "$path")" ] \
    || die "candidate companion hash mismatch: $key"
done

jq -e 'type == "object"' "$snapshot_base.project-brief.json" >/dev/null || die "captured PROJECT_BRIEF.json is invalid"
expected_probe="$(expected_probe_command "$snapshot_base.isolation.json")" \
  || die "could not reconstruct the effective isolation probe command"
recorded_probe_b64="$(jq -r '.probe.command_event.command | @base64' "$snapshot_base.isolation.json")" \
  || die "effective isolation probe command event is invalid"
expected_probe_b64="$(printf '%s' "$expected_probe" | base64 | tr -d '\r\n')"
codex_powershell_path="$(jq -r '.probe.executables.codex_powershell.path // empty' "$snapshot_base.isolation.json")"
probe_wrapper_path="$(jq -r '.probe.shell_wrapper_path // empty' "$snapshot_base.isolation.json")"
recorded_probe_variant="$(jq -r '.probe.shell_wrapper_argv_variant // empty' "$snapshot_base.isolation.json")"
powershell_path="$(jq -r '.probe.executables.powershell.path // empty' "$snapshot_base.isolation.json")"
probe_subject_name="$(jq -r '.subject.name // empty' "$snapshot_candidate")"
probe_subject_version="$(jq -r '.subject.cli_version // empty' "$snapshot_candidate")"
probe_subject_sha="$(jq -r '.subject.executable_sha256 // empty' "$snapshot_candidate")"
probe_shell_variants_b64="$(jq -r \
  --arg agent "$probe_subject_name" --arg version "$probe_subject_version" --arg sha "$probe_subject_sha" '
  [.agents[$agent].approved_builds[]? | select(
    .cli_version == $version and (.sha256 | ascii_downcase) == ($sha | ascii_downcase)
  )] as $builds
  | if ($builds | length) == 1
    then ($builds[0].shell_wrapper_argv_variants | tojson | @base64)
    else empty
    end
' "$AGENT_PUBLISHERS")"
[ -n "$probe_shell_variants_b64" ] || die "candidate probe serializer policy is missing or ambiguous"
python "$PROBE_COMMAND_VALIDATOR" --same-windows-path "$probe_wrapper_path" "$powershell_path" >/dev/null 2>&1 \
  || die "recorded Codex shell wrapper does not match the trusted system PowerShell"
identified_probe_variant="$(python "$PROBE_COMMAND_VALIDATOR" --identify \
  "$recorded_probe_b64" "$expected_probe_b64" "$probe_wrapper_path" \
  "$probe_shell_variants_b64" 2>/dev/null)" \
  || die "effective isolation probe command did not match an exact build-approved controller argv"
[ -n "$recorded_probe_variant" ] && [ "$identified_probe_variant" = "$recorded_probe_variant" ] \
  || die "effective isolation probe serializer variant was not evidence-bound"
executable_snapshot_manifests=()
if [ "$production_trust" = true ]; then
  trusted_powershell_path="$(jq -r '.windows_system_tools.powershell.path' "$AGENT_PUBLISHERS")"
  trusted_whoami_path="$(jq -r '.windows_system_tools.whoami.path' "$AGENT_PUBLISHERS")"
  trusted_powershell_posix="$(cygpath -u "$trusted_powershell_path")"
  trusted_whoami_posix="$(cygpath -u "$trusted_whoami_path")"
  [ -f "$trusted_powershell_posix" ] && [ ! -L "$trusted_powershell_posix" ] \
    && [ "$(sha "$trusted_powershell_posix")" = "$(jq -r '.windows_system_tools.powershell.sha256' "$AGENT_PUBLISHERS")" ] \
    || die "live Windows PowerShell does not match the versioned trust policy"
  [ -f "$trusted_whoami_posix" ] && [ ! -L "$trusted_whoami_posix" ] \
    && [ "$(sha "$trusted_whoami_posix")" = "$(jq -r '.windows_system_tools.whoami.sha256' "$AGENT_PUBLISHERS")" ] \
    || die "live Windows whoami does not match the versioned trust policy"
  evidence_user_home="$(jq -r '.denied_roots[1] // empty' "$snapshot_base.isolation.json")"
  [ -n "$evidence_user_home" ] \
    && [ "$(host_path "$evidence_user_home")" = "$(host_path "$real_user_home")" ] \
    || die "isolation evidence is not bound to the token-resolved user profile"
  codex_powershell_suffix="$(jq -r '.windows_runtime_tools.codex_powershell.user_profile_suffix // empty' "$AGENT_PUBLISHERS")"
  expected_codex_powershell="$real_user_home_win\\$codex_powershell_suffix"
  [ "$(host_path "$codex_powershell_path")" = "$(host_path "$expected_codex_powershell")" ] \
    || die "Codex PowerShell wrapper path does not match the versioned trust policy"
  codex_powershell_posix="$(cygpath -u "$codex_powershell_path")"
  evidence_codex_powershell_sha="$(jq -r '.probe.executables.codex_powershell.sha256 // empty | ascii_downcase' "$snapshot_base.isolation.json")"
  codex_powershell_snapshot="$tmp/codex-powershell.exe"
  codex_powershell_manifest="$tmp/codex-powershell.manifest.json"
  snapshot_inputs "$codex_powershell_manifest" "$codex_powershell_posix" "$codex_powershell_snapshot" \
    || die "Codex PowerShell wrapper could not be snapshotted safely"
  executable_snapshot_manifests+=("$codex_powershell_manifest")
  evidence_codex_powershell_identity="$(jq -c '.probe.executables.codex_powershell.authenticode' "$snapshot_base.isolation.json")"
  verify_runtime_tool_evidence codex_powershell "$codex_powershell_snapshot" \
    "$evidence_codex_powershell_sha" "$evidence_codex_powershell_identity" >/dev/null \
    || die "live Codex PowerShell wrapper does not match its approved hash and Authenticode evidence"
fi
jq -e \
  --arg wrapper_suffix "$(jq -r '.windows_runtime_tools.codex_powershell.user_profile_suffix // empty' "$AGENT_PUBLISHERS")" \
  --arg wrapper_subject "$(jq -r '.windows_runtime_tools.codex_powershell.publisher_subject // empty' "$AGENT_PUBLISHERS")" \
  --arg payload_sha "$(jq -cS -j '.probe.payload' "$snapshot_base.isolation.json" | sha256sum | awk '{print $1}')" \
  --arg probe_script_sha "$(sha "$ISOLATION_PROBE")" \
  --argjson wrapper_thumbprints "$(jq -c '.windows_runtime_tools.codex_powershell.publisher_thumbprints // []' "$AGENT_PUBLISHERS")" \
  --argjson wrapper_hashes "$(jq -c '.windows_runtime_tools.codex_powershell.approved_sha256 // [] | map(ascii_downcase)' "$AGENT_PUBLISHERS")" '
  def norm: gsub("\\\\"; "/") | ascii_downcase | sub("/+$"; "");
  . as $e
  | ([$e.denied_roots[] | norm]) as $roots
  | ($e.probe.payload.target_file | norm) as $target
  | ($e.probe.payload.source_file | norm) as $source
  | ($e.probe.payload.controller_file | norm) as $controller_file
  | ($controller_file | sub("/controller/runtime\\.manifest$"; "/agent-bin/isolation-probe.ps1")) as $probe_script
  | ($e.probe.payload.user_home | norm) as $user_home
  | $e.schema_version == 2
  and $e.isolation == "windows-native-elevated-acl"
  and $e.controller_visible_to_agent == false
  and $e.source_workspace_visible_to_agent == false
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
  and ($e.source_file_deny | type == "object" and (keys | sort) == ["checks","path"])
  and (($e.source_file_deny.path | norm) == $source)
  and ($e.source_file_deny.checks | type == "array" and length == 2
    and all(.[];
      type == "object"
      and (keys | sort) == ["read_execute_denied","sandbox_account","sandbox_sid"]
      and .read_execute_denied == true))
  and ([
    $e.sandbox_accounts[] as $account
    | (([$e.source_file_deny.checks[] | select(
      .sandbox_account == $account.Name
      and .sandbox_sid == $account.Sid
      and .read_execute_denied == true
    )] | length) == 1)
  ] | length == 2 and all)
  and $e.probe.command_event.type == "command_execution"
  and $e.probe.command_event.status == "completed"
  and $e.probe.command_event.exit_code == 0
  and ($e.probe.shell_wrapper_argv_variant | type == "string" and length > 0)
  and (($e.probe.command_event.aggregated_output
    | if contains("\u0000") then error("invalid NUL") else . end
    | gsub("\r\n"; "\n")
    | if contains("\r") then error("invalid carriage return") else . end
    | split("\n") | map(select(length > 0)) | last | fromjson) == $e.probe.result)
  and ($e.probe.payload | keys | sort == ["controller_file","nonce","source_file","target_file","user_home","whoami_file"])
  and ($e.probe.script | keys | sort == ["path","sha256"])
  and (($e.probe.script.path | norm) == $probe_script)
  and $e.probe.script.sha256 == $probe_script_sha
  and ($e.probe.executables | keys | sort == ["codex_powershell","powershell","whoami"])
  and (all($e.probe.executables[]; (.path | type == "string" and length > 0) and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
  and (($e.probe.executables.codex_powershell.path | norm) == (($user_home + "/" + $wrapper_suffix) | norm))
  and (($e.probe.executables.codex_powershell.sha256 | ascii_downcase) as $sha | ($wrapper_hashes | index($sha)) != null)
  and $e.probe.executables.codex_powershell.authenticode.status == "Valid"
  and $e.probe.executables.codex_powershell.authenticode.subject == $wrapper_subject
  and ($e.probe.executables.codex_powershell.authenticode.thumbprint as $thumbprint | ($wrapper_thumbprints | index($thumbprint)) != null)
  and ($e.probe.result | keys | sort == ["controller_readable","identity","nonce","payload_sha256","source_workspace_readable","target_file_readable","target_writeable","user_home_readable"])
  and $e.probe.payload.nonce == $e.probe.result.nonce
  and $e.probe.result.payload_sha256 == $payload_sha
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
  ' "$snapshot_base.isolation.json" >/dev/null 2>&1 || die "isolation evidence is incomplete"

if [ "$production_trust" = true ]; then
  for role in subject reviewer; do
    agent_name="$(jq -r --arg role "$role" '.[$role].name // empty' "$snapshot_candidate")"
    agent_executable="$(jq -r --arg role "$role" '.[$role].executable // empty' "$snapshot_candidate")"
    agent_sha="$(jq -r --arg role "$role" '.[$role].executable_sha256 // empty' "$snapshot_candidate")"
    agent_version="$(jq -r --arg role "$role" '.[$role].cli_version // empty' "$snapshot_candidate")"
    official_agent_path "$agent_name" "$agent_executable" "$real_user_home" \
      || die "$role executable is outside the trusted $agent_name install location"
    executable_snapshot="$tmp/$role-$agent_name.exe"
    executable_manifest="$tmp/$role-executable.manifest.json"
    snapshot_inputs "$executable_manifest" "$agent_executable" "$executable_snapshot" \
      || die "$role executable could not be snapshotted safely"
    executable_snapshot_manifests+=("$executable_manifest")
    actual_identity="$(official_agent_identity "$agent_name" "$executable_snapshot")" \
      || die "$role executable is not an authentic signed $agent_name binary"
    [ "$agent_sha" = "$(sha "$executable_snapshot")" ] || die "$role executable hash mismatch"
    version_pattern="$(jq -r --arg agent "$agent_name" '.agents[$agent].version_pattern // empty' "$AGENT_PUBLISHERS")"
    snapshot_version="$("$executable_snapshot" --version 2>&1 | head -1)"
    [ "$agent_version" = "$snapshot_version" ] || die "$role executable version mismatch"
    jq -en --arg version "$snapshot_version" --arg pattern "$version_pattern" '$version | test($pattern)' >/dev/null \
      || die "$role executable version identity is invalid"
    official_agent_build "$agent_name" "$snapshot_version" "$agent_sha" \
      || die "$role executable is not an approved $agent_name build"
    jq -e --arg role "$role" --argjson actual "$actual_identity" '.[$role].authenticode == $actual' "$snapshot_candidate" >/dev/null \
      || die "$role Authenticode identity mismatch"
  done
  runtime_agent="$(jq -r '.subject.name // empty' "$snapshot_candidate")"
  runtime_version="$(jq -r '.subject.cli_version // empty' "$snapshot_candidate")"
  subject_install_dir="$(dirname "$(jq -r '.subject.executable // empty' "$snapshot_candidate")")"
  reviewer_install_dir="$(dirname "$(jq -r '.reviewer.executable // empty' "$snapshot_candidate")")"
  [ "$(host_path "$subject_install_dir")" = "$(host_path "$reviewer_install_dir")" ] \
    || die "subject and Reviewer runtime directories differ"
  approved_component_names="$(jq -c --arg agent "$runtime_agent" --arg version "$runtime_version" '
    [.agents[$agent].approved_builds[]? | select(.cli_version == $version) | .components | keys] | if length == 1 then .[0] | sort else [] end
  ' "$AGENT_PUBLISHERS" | tr -d '\r\n')"
  candidate_component_names="$(jq -c '[.agent_runtime.components | keys] | if length == 1 then .[0] | sort else [] end' "$snapshot_candidate" | tr -d '\r\n')"
  [ "$approved_component_names" != '[]' ] && [ "$candidate_component_names" = "$approved_component_names" ] \
    || die "candidate Codex runtime component set is incomplete"
  while IFS= read -r component_name; do
    component_source="$(jq -r --arg name "$component_name" '.agent_runtime.components[$name].source // empty' "$snapshot_candidate")"
    expected_component_source="$subject_install_dir/$component_name"
    [ "$(host_path "$component_source")" = "$(host_path "$expected_component_source")" ] \
      || die "Codex runtime component path is outside the approved install bundle: $component_name"
    component_sha="$(jq -r --arg name "$component_name" '.agent_runtime.components[$name].sha256 // empty' "$snapshot_candidate")"
    component_identity="$(jq -c --arg name "$component_name" '.agent_runtime.components[$name].authenticode' "$snapshot_candidate")"
    component_snapshot="$tmp/runtime-$component_name"
    component_manifest="$tmp/runtime-$component_name.manifest.json"
    snapshot_inputs "$component_manifest" "$component_source" "$component_snapshot" \
      || die "Codex runtime component could not be snapshotted safely: $component_name"
    executable_snapshot_manifests+=("$component_manifest")
    verify_agent_component_evidence "$runtime_agent" "$runtime_version" "$component_name" \
      "$component_snapshot" "$component_sha" "$component_identity" >/dev/null \
      || die "Codex runtime component does not match its approved build evidence: $component_name"
  done < <(jq -r '.[]' <<< "$approved_component_names" | tr -d '\r')
fi

bash "$AGENT_BUILD_VERIFIER" --verify-bundle-evidence "$AGENT_PUBLISHERS" "$snapshot_candidate" \
  || die "candidate Agent runtime bundle evidence is incomplete or internally inconsistent"

signer_public="$(ssh-keygen -y -f "$SIGNING_KEY" | tr -d '\r')" || die "could not read signing key"
signer_fingerprint="$(printf '%s\n' "$signer_public" | ssh-keygen -lf - -E sha256 | awk '{print $2}' | tr -d '\r')"
authorized_fingerprints="$(awk '$1 == "harness-eval-release" {print $2, $3}' "$ALLOWED_SIGNERS" \
  | ssh-keygen -lf - -E sha256 | awk '{print $2}' | tr -d '\r')"
printf '%s\n' "$authorized_fingerprints" | grep -Fxq -- "$signer_fingerprint" \
  || die "signing key is not authorized by the selected trust anchor"
codex_publisher_subject="$(jq -r '.agents.codex.publisher_subject // empty' "$AGENT_PUBLISHERS")"
codex_publisher_thumbprints="$(jq -c '.agents.codex.publisher_thumbprints // []' "$AGENT_PUBLISHERS")"
[ -n "$codex_publisher_subject" ] && [ "$codex_publisher_thumbprints" != '[]' ] || die "Agent publisher policy is invalid"

jq -e \
  --arg name "$case_name" --arg version "$case_version" --arg scenario "$scenario" \
  --arg case_sha "$(sha "$case_file")" --arg skill_sha "$(sha "$ROOT/SKILL.md")" --arg runtime_sha "$(sha "$tmp/runtime.manifest")" \
  --arg runner_sha "$(sha "$RUNNER")" --arg schema_sha "$(sha "$SCHEMA")" --arg rubric_sha "$(sha "$tmp/rubric.json")" \
  --arg attester_sha "$(sha "$SCRIPT_DIR/attest-result.sh")" --arg isolation_sha "$(sha "$ACL_HELPER")" --arg recovery_sha "$(sha "$ACL_RECOVERY")" --arg probe_sha "$(sha "$ISOLATION_PROBE")" --arg probe_command_validator_sha "$(sha "$PROBE_COMMAND_VALIDATOR")" --arg executable_guard_sha "$(sha "$EXECUTABLE_GUARD")" --arg agent_publishers_sha "$(sha "$AGENT_PUBLISHERS")" --arg agent_build_verifier_sha "$(sha "$AGENT_BUILD_VERIFIER")" --arg publisher_sha "$(sha "$PUBLISHER")" \
  --arg codex_publisher_subject "$codex_publisher_subject" --argjson codex_publisher_thumbprints "$codex_publisher_thumbprints" --argjson approved_builds "$(jq -c '.agents.codex.approved_builds' "$AGENT_PUBLISHERS")" \
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
    and .authority.isolation_recovery_sha256 == $recovery_sha
    and .authority.isolation_probe_sha256 == $probe_sha
    and .authority.probe_command_validator_sha256 == $probe_command_validator_sha
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
    and (.subject.cli_version | type == "string" and length > 0) and (.subject.model | type == "string" and length > 0)
    and (.subject as $agent | any($approved_builds[]; .cli_version == $agent.cli_version and (.sha256 | ascii_downcase) == $agent.executable_sha256))
    and (.subject.session_ids | type == "array" and length == $input_count and (unique|length) == $input_count and all(.[]; type == "string" and length > 0))
    and .reviewer.name == "codex" and .reviewer.tools_disabled == true
    and (.reviewer.executable_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.reviewer.authenticode.status == "Valid")
    and .reviewer.authenticode.subject == $codex_publisher_subject
    and (.reviewer.authenticode.thumbprint as $thumbprint | ($codex_publisher_thumbprints | index($thumbprint)) != null)
    and (.reviewer.cli_version | type == "string" and length > 0) and (.reviewer.model | type == "string" and length > 0)
    and (.reviewer as $agent | any($approved_builds[]; .cli_version == $agent.cli_version and (.sha256 | ascii_downcase) == $agent.executable_sha256))
    and (.reviewer.session_id | type == "string" and length > 0)
    and (.reviewer.session_id as $rid | (.subject.session_ids | index($rid)) == null)
    and (.artifact_hashes | keys | sort == ["evaluator_events","isolation","objective_checks","project_brief","reviewer_events","reviewer_output","subject_events","transcript","tree","turn_trees"])
  ' "$snapshot_candidate" >/dev/null || die "candidate is stale, failed, synthetic, unisolated, or structurally invalid"

candidate_sha="$(sha "$snapshot_candidate")"
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
' "$snapshot_candidate" > "$promoted"

ssh-keygen -Y sign -q -f "$SIGNING_KEY" -n harness-eval "$promoted"
mv "$promoted.sig" "$tmp/$base_name.attestation.sig"
for suffix in "${artifact_suffixes[@]}"; do cp "$snapshot_base.$suffix" "$tmp/$base_name.$suffix"; done

# Test-only hook for proving that an input swap after validation cannot be
# promoted. Production use cannot opt into this hook while publishing to the
# canonical trust directories.
if [ -n "${HARNESS_EVAL_TEST_AFTER_SNAPSHOT_HOOK:-}" ] || [ -n "${HARNESS_EVAL_TEST_DURING_RECHECK_HOOK:-}" ] || [ -n "${HARNESS_EVAL_TEST_AFTER_FIRST_RECHECK_HOOK:-}" ]; then
  [ "$allowed_signers_host" != "$canonical_allowed_signers_host" ] && [ "$candidates_host" != "$canonical_candidates_host" ] && [ "$results_host" != "$canonical_results_host" ] || die "snapshot hook is test-only"
fi
if [ -n "${HARNESS_EVAL_TEST_AFTER_SNAPSHOT_HOOK:-}" ]; then
  [ -f "$HARNESS_EVAL_TEST_AFTER_SNAPSHOT_HOOK" ] && [ ! -L "$HARNESS_EVAL_TEST_AFTER_SNAPSHOT_HOOK" ] || die "snapshot hook missing or unsafe"
  bash "$HARNESS_EVAL_TEST_AFTER_SNAPSHOT_HOOK" "$candidate_abs" || die "snapshot hook failed"
fi
if [ -n "${HARNESS_EVAL_TEST_DURING_RECHECK_HOOK:-}" ]; then
  [ -f "$HARNESS_EVAL_TEST_DURING_RECHECK_HOOK" ] && [ ! -L "$HARNESS_EVAL_TEST_DURING_RECHECK_HOOK" ] || die "recheck hook missing or unsafe"
fi
if [ -n "${HARNESS_EVAL_TEST_AFTER_FIRST_RECHECK_HOOK:-}" ]; then
  [ -f "$HARNESS_EVAL_TEST_AFTER_FIRST_RECHECK_HOOK" ] && [ ! -L "$HARNESS_EVAL_TEST_AFTER_FIRST_RECHECK_HOOK" ] || die "set-recheck hook missing or unsafe"
fi

HARNESS_EVAL_TEST_DURING_RECHECK_TARGET="$candidate_abs" verify_snapshot_sources "$snapshot_manifest" || die "candidate input drifted after validation"
[ "$(sha "$snapshot_candidate")" = "$candidate_sha" ] || die "private candidate snapshot changed"
for executable_manifest in "${executable_snapshot_manifests[@]}"; do
  (unset HARNESS_EVAL_TEST_DURING_RECHECK_HOOK HARNESS_EVAL_TEST_DURING_RECHECK_TARGET HARNESS_EVAL_TEST_AFTER_FIRST_RECHECK_HOOK
   verify_snapshot_sources "$executable_manifest") || die "Agent executable drifted after identity verification"
done

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
publication_started=false
rmdir "$candidate_lock" || die "candidate attestation lock cleanup failed"
candidate_lock_owned=false

echo "eval-attest: result=$RESULTS_DIR/$base_name.json"
echo "eval-attest: candidate_sha256=$candidate_sha signer=$signer_fingerprint"
