#!/bin/bash
# Recover executable guards and ACLs after a crashed real-Agent eval. Refuses
# to act while the recorded controller is alive, and never kills a process
# unless PID, creation time, guard path, state path, and nonce all match.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACL_HELPER="$SCRIPT_DIR/windows-isolation-acl.ps1"
EXECUTABLE_GUARD="$SCRIPT_DIR/windows-executable-guard.ps1"
ACL_STATE="$ROOT/.harness/eval-acl-state.json"
GUARD_STATE="$ROOT/.harness/eval-guard-state.json"
ACL_LOCK="$ROOT/.harness/eval-acl.lock"
OWNER_FILE="$ACL_LOCK/owner.pid"
CANONICAL_AGENT_LOCK="$SCRIPT_DIR/candidates/.eval-agent.lock"
WORK_ROOT="/c/Users/Public/harness-companion-eval"
WINDOWS_POWERSHELL="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
TRUSTED_WINDOWS_ENV="/c/Program Files/Git/usr/bin/env.exe"

die() { echo "eval-recover: $*" >&2; exit 2; }
windows_powershell() {
  "$TRUSTED_WINDOWS_ENV" -u PSModulePath "$WINDOWS_POWERSHELL" "$@"
}
host_path() {
  local path="$1"
  path="$(cygpath -aw "$path")" || return 1
  python - "$path" <<'PY'
import os, sys
print(os.path.normcase(os.path.realpath(sys.argv[1])).replace(os.sep, "/"))
PY
}

[ "$#" -eq 0 ] || die "usage: recover-windows-isolation.sh"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) die "Windows isolation recovery requires Git Bash on Windows" ;; esac
for cmd in jq python cygpath; do command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"; done
[ -f "$ACL_HELPER" ] && [ ! -L "$ACL_HELPER" ] || die "ACL helper missing or unsafe"
[ -f "$EXECUTABLE_GUARD" ] && [ ! -L "$EXECUTABLE_GUARD" ] || die "executable guard missing or unsafe"
[ -f "$WINDOWS_POWERSHELL" ] && [ ! -L "$WINDOWS_POWERSHELL" ] || die "Windows PowerShell missing or unsafe"
[ -f "$TRUSTED_WINDOWS_ENV" ] && [ -x "$TRUSTED_WINDOWS_ENV" ] && [ ! -L "$TRUSTED_WINDOWS_ENV" ] || die "trusted env missing or unsafe"
acl_pending=false; guard_pending=false
if [ -e "$ACL_STATE" ] || [ -L "$ACL_STATE" ]; then
  [ -f "$ACL_STATE" ] && [ ! -L "$ACL_STATE" ] || die "ACL restoration state is unsafe"
  acl_pending=true
fi
if [ -e "$GUARD_STATE" ] || [ -L "$GUARD_STATE" ]; then
  [ -f "$GUARD_STATE" ] && [ ! -L "$GUARD_STATE" ] || die "executable guard recovery state is unsafe"
  guard_pending=true
fi
[ "$acl_pending" = true ] || [ "$guard_pending" = true ] || die "no ACL or executable-guard recovery state exists"

if [ -e "$ACL_LOCK" ] || [ -L "$ACL_LOCK" ]; then
  [ -d "$ACL_LOCK" ] && [ ! -L "$ACL_LOCK" ] || die "ACL lock is unsafe"
  [ -f "$OWNER_FILE" ] && [ ! -L "$OWNER_FILE" ] || die "ACL lock owner metadata missing or unsafe"
  owner_pid="$(tr -d '\r\n' < "$OWNER_FILE")"
  case "$owner_pid" in ''|*[!0-9]*) die "ACL lock owner PID is invalid" ;; esac
  if kill -0 "$owner_pid" 2>/dev/null; then
    die "real eval lock owner is still active (pid $owner_pid)"
  fi
  rm -f -- "$OWNER_FILE"
  rmdir "$ACL_LOCK" || die "could not retire stale ACL lock"
fi

mkdir "$ACL_LOCK" || die "could not acquire ACL recovery lock"
printf '%s\n' "$$" > "$OWNER_FILE"
lock_owned=true
cleanup() {
  if [ "${lock_owned:-false}" = true ]; then
    rm -f -- "$OWNER_FILE" 2>/dev/null || true
    rmdir "$ACL_LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

run_root_posix=""
if [ "$guard_pending" = true ]; then
  jq -e '
    .schema_version == 1
    and (.guard_pid | type == "number" and . > 0)
    and (.guard_start_time_utc | type == "string" and length > 0)
    and (.nonce | type == "string" and test("^[0-9a-f]{64}$"))
    and (.guard_script | type == "string" and length > 0)
    and (.state_file | type == "string" and length > 0)
    and (.stop_file | type == "string" and length > 0)
    and (.run_root | type == "string" and length > 0)
    and (.agent_lock | type == "string" and length > 0)
  ' "$GUARD_STATE" >/dev/null || die "executable guard recovery state is invalid"

  guard_pid="$(jq -r '.guard_pid' "$GUARD_STATE")"
  guard_start="$(jq -r '.guard_start_time_utc' "$GUARD_STATE")"
  guard_nonce="$(jq -r '.nonce' "$GUARD_STATE")"
  guard_script_win="$(jq -r '.guard_script' "$GUARD_STATE")"
  state_file_win="$(jq -r '.state_file' "$GUARD_STATE")"
  stop_file_win="$(jq -r '.stop_file' "$GUARD_STATE")"
  run_root_win="$(jq -r '.run_root' "$GUARD_STATE")"
  agent_lock_win="$(jq -r '.agent_lock' "$GUARD_STATE")"
  [ "$(host_path "$guard_script_win")" = "$(host_path "$EXECUTABLE_GUARD")" ] || die "recorded guard script is not authoritative"
  [ "$(host_path "$state_file_win")" = "$(host_path "$GUARD_STATE")" ] || die "recorded guard state path is not authoritative"
  [ "$(host_path "$agent_lock_win")" = "$(host_path "$CANONICAL_AGENT_LOCK")" ] || die "recorded Agent lock is outside the canonical candidate directory"
  run_root_posix="$(cygpath -u "$run_root_win")"
  stop_file_posix="$(cygpath -u "$stop_file_win")"
  work_runs_host="$(host_path "$WORK_ROOT/runs")"
  run_root_host="$(host_path "$run_root_posix")"
  case "$run_root_host" in "$work_runs_host"/run.*) ;; *) die "recorded run root is outside the isolated work root" ;; esac
  [ -d "$run_root_posix" ] && [ ! -L "$run_root_posix" ] || die "recorded run root is missing or unsafe"
  stop_parent="$(dirname "$stop_file_posix")"
  case "$(host_path "$stop_parent")/" in "$run_root_host"/*) ;; *) die "recorded stop file escapes the run root" ;; esac

  guard_status="$({
    HARNESS_EVAL_GUARD_PID="$guard_pid" HARNESS_EVAL_GUARD_START="$guard_start" \
    HARNESS_EVAL_GUARD_NONCE="$guard_nonce" HARNESS_EVAL_GUARD_SCRIPT="$guard_script_win" \
    HARNESS_EVAL_GUARD_STATE="$state_file_win" windows_powershell -NoProfile -Command '
      $p = Get-Process -Id ([int]$env:HARNESS_EVAL_GUARD_PID) -ErrorAction SilentlyContinue
      if ($null -eq $p) { "absent"; exit 0 }
      $start = $p.StartTime.ToUniversalTime().ToString("o")
      $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $p.Id) -ErrorAction SilentlyContinue
      $command = if ($null -ne $cim) { [string]$cim.CommandLine } else { "" }
      if ($start -eq $env:HARNESS_EVAL_GUARD_START -and
          $command.IndexOf($env:HARNESS_EVAL_GUARD_SCRIPT, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
          $command.IndexOf($env:HARNESS_EVAL_GUARD_STATE, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
          $command.Contains($env:HARNESS_EVAL_GUARD_NONCE)) { "match" } else { "mismatch" }
    '
  } 2>/dev/null | tr -d '\r\n')"
  [ "$guard_status" != mismatch ] || die "recorded guard PID belongs to a different process; refusing to signal it"
  if [ "$guard_status" = match ]; then
    mkdir -p "$(dirname "$stop_file_posix")"
    [ ! -L "$stop_file_posix" ] || die "recorded guard stop path is unsafe"
    : > "$stop_file_posix"
    for _ in $(seq 1 100); do
      if ! windows_powershell -NoProfile -Command \
        "if (Get-Process -Id $guard_pid -ErrorAction SilentlyContinue) { exit 1 }" >/dev/null 2>&1; then
        sleep 0.1
      else
        guard_status=absent
        break
      fi
    done
    [ "$guard_status" = absent ] || die "verified executable guard did not stop; recovery state retained"
  fi
fi

if [ "$acl_pending" = true ]; then
  real_user_home_win="$(windows_powershell -NoProfile -Command '[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)' | tr -d '\r')"
  [ -n "$real_user_home_win" ] || die "could not resolve the token-backed Windows user profile"
  windows_powershell -NoProfile -ExecutionPolicy Bypass \
    -File "$ACL_HELPER" -Mode Leave -WorkspaceRoot "$ROOT/.." -ControllerRoot "$ROOT" \
    -UserHome "$real_user_home_win" -StateFile "$ACL_STATE" \
    || die "ACL restoration failed; state retained"
fi

if [ "$guard_pending" = true ]; then
  if [ -e "$CANONICAL_AGENT_LOCK" ] || [ -L "$CANONICAL_AGENT_LOCK" ]; then
    [ -d "$CANONICAL_AGENT_LOCK" ] && [ ! -L "$CANONICAL_AGENT_LOCK" ] || die "recorded Agent lock is unsafe"
    rmdir "$CANONICAL_AGENT_LOCK" || die "could not retire stale Agent lock"
  fi
  HARNESS_EVAL_RECOVERY_RUN_ROOT="$(cygpath -w "$run_root_posix")" HARNESS_EVAL_RECOVERY_WORK_ROOT="$(cygpath -w "$WORK_ROOT/runs")" \
    windows_powershell -NoProfile -Command '
      $run = [IO.Path]::GetFullPath($env:HARNESS_EVAL_RECOVERY_RUN_ROOT)
      $separator = [IO.Path]::DirectorySeparatorChar
      $root = [IO.Path]::GetFullPath($env:HARNESS_EVAL_RECOVERY_WORK_ROOT).TrimEnd($separator) + $separator
      if (-not $run.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
          -not ([IO.Path]::GetFileName($run)).StartsWith("run.", [StringComparison]::Ordinal)) { exit 2 }
      $item = Get-Item -LiteralPath $run -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { exit 2 }
      [IO.Directory]::Delete($run, $true)
    ' || die "could not remove the verified isolated run tree"
  rm -f -- "$GUARD_STATE" || die "could not retire executable guard recovery state"
fi

rm -f -- "$OWNER_FILE"
rmdir "$ACL_LOCK" || die "recovery completed but the ACL lock could not be released"
lock_owned=false
echo "eval-recover: executable guard and ACL restoration complete"
