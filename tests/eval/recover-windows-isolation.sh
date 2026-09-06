#!/bin/bash
# Recover a crashed real-Agent eval from its controller-owned lifecycle journal.
# The journal and lock metadata bind every action to canonical paths plus a
# Windows PID, creation time, exact command line, and per-run nonce.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACL_HELPER="$SCRIPT_DIR/windows-isolation-acl.ps1"
EXECUTABLE_GUARD="$SCRIPT_DIR/windows-executable-guard.ps1"
RECOVERY_JOURNAL="$ROOT/.harness/eval-recovery-journal.json"
ACL_STATE="$ROOT/.harness/eval-acl-state.json"
GUARD_STATE="$ROOT/.harness/eval-guard-state.json"
ACL_LOCK="$ROOT/.harness/eval-acl.lock"
OWNER_FILE="$ACL_LOCK/owner.json"
CANONICAL_AGENT_LOCK="$SCRIPT_DIR/candidates/.eval-agent.lock"
CANONICAL_OUTPUT="$SCRIPT_DIR/candidates"
WORK_ROOT="/c/Users/Public/harness-companion-eval"
WINDOWS_POWERSHELL="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
TRUSTED_WINDOWS_ENV="/c/Program Files/Git/usr/bin/env.exe"

die() { echo "eval-recover: $*" >&2; exit 2; }
windows_powershell() { "$TRUSTED_WINDOWS_ENV" -u PSModulePath "$WINDOWS_POWERSHELL" "$@"; }
host_path() {
  local path="$1"
  path="$(cygpath -aw "$path")" || return 1
  python - "$path" <<'PY'
import os, sys
print(os.path.normcase(os.path.realpath(sys.argv[1])).replace(os.sep, "/"))
PY
}
windows_process_status() {
  HARNESS_EVAL_OWNER_PID="$1" HARNESS_EVAL_OWNER_START="$2" HARNESS_EVAL_OWNER_NAME="$3" \
  HARNESS_EVAL_OWNER_COMMAND="$4" windows_powershell -NoProfile -Command '
    $p = Get-Process -Id ([int]$env:HARNESS_EVAL_OWNER_PID) -ErrorAction SilentlyContinue
    if ($null -eq $p) { "absent"; exit 0 }
    $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $p.Id) -ErrorAction SilentlyContinue
    if ($null -eq $cim) { "mismatch"; exit 0 }
    $start = $p.StartTime.ToUniversalTime().ToString("o")
    if ($start -ceq $env:HARNESS_EVAL_OWNER_START -and
        ([string]$cim.Name).Equals($env:HARNESS_EVAL_OWNER_NAME, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$cim.CommandLine) -ceq $env:HARNESS_EVAL_OWNER_COMMAND) { "match" } else { "mismatch" }
  ' 2>/dev/null | tr -d '\r\n'
}
windows_current_identity() {
  local msys_pid="$$" windows_pid
  windows_pid="$(ps -W | while read -r pid _ _ winpid _; do
    if [ "$pid" = "$msys_pid" ]; then printf '%s\n' "$winpid"; break; fi
  done)"
  case "$windows_pid" in ''|*[!0-9]*) return 1 ;; esac
  HARNESS_EVAL_RECOVERY_PID="$windows_pid" windows_powershell -NoProfile -Command '
    $process = Get-Process -Id ([int]$env:HARNESS_EVAL_RECOVERY_PID) -ErrorAction Stop
    $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $process.Id) -ErrorAction Stop
    [ordered]@{
      pid = [int]$process.Id
      start_time_utc = $process.StartTime.ToUniversalTime().ToString("o")
      name = [string]$cim.Name
      command_line = [string]$cim.CommandLine
    } | ConvertTo-Json -Compress
  ' 2>/dev/null | tr -d '\r\n'
}
guard_process_status() {
  HARNESS_EVAL_GUARD_PID="$1" HARNESS_EVAL_GUARD_START="$2" HARNESS_EVAL_GUARD_NONCE="$3" \
  HARNESS_EVAL_GUARD_SCRIPT="$4" HARNESS_EVAL_GUARD_STATE="$5" windows_powershell -NoProfile -Command '
    $p = Get-Process -Id ([int]$env:HARNESS_EVAL_GUARD_PID) -ErrorAction SilentlyContinue
    if ($null -eq $p) { "absent"; exit 0 }
    $start = $p.StartTime.ToUniversalTime().ToString("o")
    $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $p.Id) -ErrorAction SilentlyContinue
    $command = if ($null -ne $cim) { [string]$cim.CommandLine } else { "" }
    $normalizedCommand = $command.Replace("/", "\")
    $normalizedScript = $env:HARNESS_EVAL_GUARD_SCRIPT.Replace("/", "\")
    $normalizedState = $env:HARNESS_EVAL_GUARD_STATE.Replace("/", "\")
    if ($start -ceq $env:HARNESS_EVAL_GUARD_START -and
        $normalizedCommand.IndexOf($normalizedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $normalizedCommand.IndexOf($normalizedState, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $normalizedCommand.Contains($env:HARNESS_EVAL_GUARD_NONCE)) { "match" } else { "mismatch" }
  ' 2>/dev/null | tr -d '\r\n'
}
update_journal_stage() {
  local next_stage="$1" staged="$ROOT/.harness/.eval-recovery-journal.recover.$$.$RANDOM"
  jq --arg stage "$next_stage" '.stage = $stage' "$RECOVERY_JOURNAL" > "$staged" || { rm -f -- "$staged"; return 1; }
  python - "$staged" "$RECOVERY_JOURNAL" <<'PY' || { rm -f -- "$staged"; return 1; }
import os, stat, sys, time
source, destination = sys.argv[1:]
if not stat.S_ISREG(os.lstat(destination).st_mode): raise SystemExit("unsafe journal")
fd = os.open(source, os.O_WRONLY | getattr(os, "O_BINARY", 0))
try: os.fsync(fd)
finally: os.close(fd)
for attempt in range(200):
    try:
        if not stat.S_ISREG(os.lstat(destination).st_mode):
            raise SystemExit("unsafe journal")
        os.replace(source, destination)
        break
    except PermissionError:
        if attempt == 199:
            raise
        time.sleep(0.01)
PY
}
write_owner() {
  local process_json="$1" lock_nonce staged="$ACL_LOCK/.owner.json.$$.$RANDOM"
  lock_nonce="$(python -c 'import secrets; print(secrets.token_hex(32))')" || return 1
  jq -n --arg run_nonce "$journal_nonce" --arg lock_nonce "$lock_nonce" \
    --arg journal "$(cygpath -w "$RECOVERY_JOURNAL")" --argjson process "$process_json" \
    '{schema_version:1,run_nonce:$run_nonce,lock_nonce:$lock_nonce,journal:$journal,process:$process}' > "$staged" || return 1
  mv "$staged" "$OWNER_FILE"
}
remove_verified_tree() {
  local path="$1" allowed_parent="$2" required_prefix="$3"
  HARNESS_EVAL_RECOVERY_PATH="$(cygpath -w "$path")" HARNESS_EVAL_RECOVERY_PARENT="$(cygpath -w "$allowed_parent")" \
  HARNESS_EVAL_RECOVERY_PREFIX="$required_prefix" windows_powershell -NoProfile -Command '
    $path = [IO.Path]::GetFullPath($env:HARNESS_EVAL_RECOVERY_PATH)
    $separator = [IO.Path]::DirectorySeparatorChar
    $parent = [IO.Path]::GetFullPath($env:HARNESS_EVAL_RECOVERY_PARENT).TrimEnd($separator) + $separator
    if (-not $path.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($path)).StartsWith($env:HARNESS_EVAL_RECOVERY_PREFIX, [StringComparison]::Ordinal)) { exit 2 }
    if (-not [IO.Directory]::Exists($path)) { exit 0 }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { exit 2 }
    foreach ($child in Get-ChildItem -LiteralPath $path -Force -Recurse) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { exit 2 }
      if (-not $child.PSIsContainer) { $child.Attributes = [IO.FileAttributes]::Normal }
    }
    [IO.Directory]::Delete($path, $true)
  '
}

[ "$#" -eq 0 ] || die "usage: recover-windows-isolation.sh"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) die "Windows isolation recovery requires Git Bash on Windows" ;; esac
for cmd in jq python cygpath; do command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"; done
for path in "$ACL_HELPER" "$EXECUTABLE_GUARD" "$WINDOWS_POWERSHELL" "$TRUSTED_WINDOWS_ENV"; do
  [ -f "$path" ] && [ ! -L "$path" ] || die "recovery authority missing or unsafe: $path"
done
[ -f "$RECOVERY_JOURNAL" ] && [ ! -L "$RECOVERY_JOURNAL" ] || die "lifecycle recovery journal missing or unsafe"
jq -e '
  .schema_version == 1 and (.nonce | type == "string" and test("^[0-9a-f]{64}$"))
  and (.stage | type == "string" and length > 0)
  and (.controller.pid | type == "number" and . > 0)
  and (.controller.name | ascii_downcase) == "bash.exe"
  and all(.controller.start_time_utc,.controller.name,.controller.command_line; type == "string" and length > 0)
  and all(.paths.journal,.paths.run_root,.paths.work_runs_root,.paths.output_dir,.paths.agent_lock,
          .paths.acl_lock,.paths.acl_owner,.paths.acl_state,.paths.guard_state; type == "string" and length > 0)
  and ((.paths.publication_lock == null) or (.paths.publication_lock | type == "string" and length > 0))
  and ((.paths.publication_stage == null) or (.paths.publication_stage | type == "string" and length > 0))
' "$RECOVERY_JOURNAL" >/dev/null || die "lifecycle recovery journal is invalid"

journal_nonce="$(jq -r '.nonce' "$RECOVERY_JOURNAL")"
journal_stage="$(jq -r '.stage' "$RECOVERY_JOURNAL")"
controller_pid="$(jq -r '.controller.pid' "$RECOVERY_JOURNAL")"
controller_start="$(jq -r '.controller.start_time_utc' "$RECOVERY_JOURNAL")"
controller_name="$(jq -r '.controller.name' "$RECOVERY_JOURNAL")"
controller_command="$(jq -r '.controller.command_line' "$RECOVERY_JOURNAL")"
run_root="$(cygpath -u "$(jq -r '.paths.run_root' "$RECOVERY_JOURNAL")")"
work_runs_root="$(cygpath -u "$(jq -r '.paths.work_runs_root' "$RECOVERY_JOURNAL")")"
output_dir="$(cygpath -u "$(jq -r '.paths.output_dir' "$RECOVERY_JOURNAL")")"
agent_lock="$(cygpath -u "$(jq -r '.paths.agent_lock' "$RECOVERY_JOURNAL")")"
recorded_acl_lock="$(cygpath -u "$(jq -r '.paths.acl_lock' "$RECOVERY_JOURNAL")")"
recorded_acl_owner="$(cygpath -u "$(jq -r '.paths.acl_owner' "$RECOVERY_JOURNAL")")"
recorded_acl_state="$(cygpath -u "$(jq -r '.paths.acl_state' "$RECOVERY_JOURNAL")")"
recorded_guard_state="$(cygpath -u "$(jq -r '.paths.guard_state' "$RECOVERY_JOURNAL")")"
publication_lock_win="$(jq -r '.paths.publication_lock // empty' "$RECOVERY_JOURNAL")"
publication_stage_win="$(jq -r '.paths.publication_stage // empty' "$RECOVERY_JOURNAL")"

[ "$(host_path "$(jq -r '.paths.journal' "$RECOVERY_JOURNAL")")" = "$(host_path "$RECOVERY_JOURNAL")" ] || die "journal path is not authoritative"
[ "$(host_path "$work_runs_root")" = "$(host_path "$WORK_ROOT/runs")" ] || die "work root is not canonical"
[ "$(host_path "$output_dir")" = "$(host_path "$CANONICAL_OUTPUT")" ] || die "output directory is not canonical"
[ "$(host_path "$agent_lock")" = "$(host_path "$CANONICAL_AGENT_LOCK")" ] || die "Agent lock is not canonical"
[ "$(host_path "$recorded_acl_lock")" = "$(host_path "$ACL_LOCK")" ] || die "ACL lock is not authoritative"
[ "$(host_path "$recorded_acl_owner")" = "$(host_path "$OWNER_FILE")" ] || die "ACL owner path is not authoritative"
[ "$(host_path "$recorded_acl_state")" = "$(host_path "$ACL_STATE")" ] || die "ACL state path is not authoritative"
[ "$(host_path "$recorded_guard_state")" = "$(host_path "$GUARD_STATE")" ] || die "guard state path is not authoritative"
run_root_host="$(host_path "$run_root")"
case "$run_root_host" in "$(host_path "$WORK_ROOT/runs")"/run.*) ;; *) die "run root is outside the fixed work root" ;; esac

if [ "$journal_stage" = recovery_complete ]; then
  completed_paths=("$GUARD_STATE" "$ACL_STATE" "$ACL_LOCK" "$CANONICAL_AGENT_LOCK" "$run_root")
  [ -z "$publication_stage_win" ] || completed_paths+=("$(cygpath -u "$publication_stage_win")")
  [ -z "$publication_lock_win" ] || completed_paths+=("$(cygpath -u "$publication_lock_win")")
  for path in "${completed_paths[@]}"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || die "completed recovery still has live state: $path"
  done
  rm -f -- "$RECOVERY_JOURNAL" || die "could not retire completed recovery journal"
  echo "eval-recover: lifecycle recovery complete"
  exit 0
fi

controller_status="$(windows_process_status "$controller_pid" "$controller_start" "$controller_name" "$controller_command")"
[ "$controller_status" != match ] || die "recorded eval controller is still active (Windows pid $controller_pid)"

if [ -e "$ACL_LOCK" ] || [ -L "$ACL_LOCK" ]; then
  [ -d "$ACL_LOCK" ] && [ ! -L "$ACL_LOCK" ] || die "ACL lock is unsafe"
  if [ -e "$OWNER_FILE" ] || [ -L "$OWNER_FILE" ]; then
    [ -f "$OWNER_FILE" ] && [ ! -L "$OWNER_FILE" ] || die "ACL lock owner metadata is unsafe"
    jq -e --arg nonce "$journal_nonce" --arg journal "$(cygpath -w "$RECOVERY_JOURNAL")" '
      .schema_version == 1 and .run_nonce == $nonce and .journal == $journal
      and (.process.pid | type == "number" and . > 0)
      and all(.process.start_time_utc,.process.name,.process.command_line; type == "string" and length > 0)
    ' "$OWNER_FILE" >/dev/null || die "ACL lock owner metadata is invalid"
    owner_pid="$(jq -r '.process.pid' "$OWNER_FILE")"
    owner_start="$(jq -r '.process.start_time_utc' "$OWNER_FILE")"
    owner_name="$(jq -r '.process.name' "$OWNER_FILE")"
    owner_command="$(jq -r '.process.command_line' "$OWNER_FILE")"
    owner_status="$(windows_process_status "$owner_pid" "$owner_start" "$owner_name" "$owner_command")"
    [ "$owner_status" != match ] || die "ACL transition lock owner is still active (Windows pid $owner_pid)"
    rm -f -- "$OWNER_FILE"
  fi
  rmdir "$ACL_LOCK" || die "could not retire stale ACL lock"
fi

mkdir "$ACL_LOCK" || die "could not acquire ACL recovery lock"
lock_owned=true
cleanup() {
  if [ "${lock_owned:-false}" = true ]; then
    rm -f -- "$OWNER_FILE" 2>/dev/null || true
    rmdir "$ACL_LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
recovery_identity="$(windows_current_identity)" || die "could not capture recovery process identity"
jq -e '(.pid | type == "number" and . > 0) and (.name | ascii_downcase) == "bash.exe"
  and all(.start_time_utc,.command_line; type == "string" and length > 0)' <<< "$recovery_identity" >/dev/null \
  || die "recovery process identity is invalid"
write_owner "$recovery_identity" || die "could not record ACL recovery lock owner"

if [ -e "$GUARD_STATE" ] || [ -L "$GUARD_STATE" ]; then
  [ -f "$GUARD_STATE" ] && [ ! -L "$GUARD_STATE" ] || die "executable guard recovery state is unsafe"
  jq -e --arg nonce "$journal_nonce" --arg journal "$(cygpath -w "$RECOVERY_JOURNAL")" '
    .schema_version == 1 and .nonce == $nonce and .recovery_journal == $journal
    and (.guard_pid | type == "number" and . > 0)
    and all(.guard_start_time_utc,.guard_script,.state_file,.stop_file,.run_root,.agent_lock; type == "string" and length > 0)
  ' "$GUARD_STATE" >/dev/null || die "executable guard recovery state is invalid"
  guard_pid="$(jq -r '.guard_pid' "$GUARD_STATE")"
  guard_start="$(jq -r '.guard_start_time_utc' "$GUARD_STATE")"
  guard_script_win="$(jq -r '.guard_script' "$GUARD_STATE")"
  guard_state_win="$(jq -r '.state_file' "$GUARD_STATE")"
  guard_stop="$(cygpath -u "$(jq -r '.stop_file' "$GUARD_STATE")")"
  [ "$(host_path "$guard_script_win")" = "$(host_path "$EXECUTABLE_GUARD")" ] || die "guard script is not authoritative"
  [ "$(host_path "$guard_state_win")" = "$(host_path "$GUARD_STATE")" ] || die "guard state path is not authoritative"
  [ "$(host_path "$(jq -r '.run_root' "$GUARD_STATE")")" = "$run_root_host" ] || die "guard run root does not match journal"
  [ "$(host_path "$(jq -r '.agent_lock' "$GUARD_STATE")")" = "$(host_path "$CANONICAL_AGENT_LOCK")" ] || die "guard Agent lock does not match journal"
  case "$(host_path "$(dirname "$guard_stop")")/" in "$run_root_host"/*) ;; *) die "guard stop path escapes run root" ;; esac
  guard_status="$(guard_process_status "$guard_pid" "$guard_start" "$journal_nonce" "$guard_script_win" "$guard_state_win")"
  [ "$guard_status" != mismatch ] || die "recorded guard PID belongs to a different process; refusing to signal it"
  if [ "$guard_status" = match ]; then
    [ ! -L "$guard_stop" ] || die "guard stop path is unsafe"
    : > "$guard_stop"
    for _ in $(seq 1 100); do
      guard_status="$(guard_process_status "$guard_pid" "$guard_start" "$journal_nonce" "$guard_script_win" "$guard_state_win")"
      [ "$guard_status" = absent ] && break
      [ "$guard_status" != mismatch ] || die "guard identity changed during shutdown"
      sleep 0.1
    done
    [ "$guard_status" = absent ] || die "verified executable guard did not stop; state retained"
  fi
  rm -f -- "$GUARD_STATE" || die "could not retire executable guard state"
fi

if [ -e "$ACL_STATE" ] || [ -L "$ACL_STATE" ]; then
  [ -f "$ACL_STATE" ] && [ ! -L "$ACL_STATE" ] || die "ACL restoration state is unsafe"
  real_user_home_win="$(windows_powershell -NoProfile -Command '[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)' | tr -d '\r')"
  [ -n "$real_user_home_win" ] || die "could not resolve the token-backed Windows user profile"
  windows_powershell -NoProfile -ExecutionPolicy Bypass -File "$ACL_HELPER" -Mode Leave \
    -WorkspaceRoot "$ROOT/.." -ControllerRoot "$run_root/controller" \
    -UserHome "$real_user_home_win" -StateFile "$ACL_STATE" || die "ACL restoration failed; state retained"
fi

if [ -e "$CANONICAL_AGENT_LOCK" ] || [ -L "$CANONICAL_AGENT_LOCK" ]; then
  [ -d "$CANONICAL_AGENT_LOCK" ] && [ ! -L "$CANONICAL_AGENT_LOCK" ] || die "Agent lock is unsafe"
  rmdir "$CANONICAL_AGENT_LOCK" || die "could not retire stale Agent lock"
fi
if [ -n "$publication_stage_win" ]; then
  publication_stage="$(cygpath -u "$publication_stage_win")"
  remove_verified_tree "$publication_stage" "$CANONICAL_OUTPUT" '.staging-' || die "could not remove verified publication stage"
fi
if [ -n "$publication_lock_win" ]; then
  publication_lock="$(cygpath -u "$publication_lock_win")"
  [ "$(host_path "$publication_lock")" = "$(host_path "$CANONICAL_OUTPUT/.eval-write.lock")" ] || die "publication lock is not canonical"
  if [ -e "$publication_lock" ] || [ -L "$publication_lock" ]; then
    [ -d "$publication_lock" ] && [ ! -L "$publication_lock" ] || die "publication lock is unsafe"
    rmdir "$publication_lock" || die "could not retire publication lock"
  fi
fi
remove_verified_tree "$run_root" "$WORK_ROOT/runs" 'run.' || die "could not remove verified isolated run tree"

update_journal_stage recovery_complete || die "could not mark lifecycle recovery complete"
rm -f -- "$OWNER_FILE" || die "could not retire recovery lock owner"
rmdir "$ACL_LOCK" || die "recovery completed but ACL lock could not be released"
lock_owned=false
rm -f -- "$RECOVERY_JOURNAL" || die "could not retire lifecycle recovery journal"
echo "eval-recover: lifecycle recovery complete"
