#!/bin/bash
# Recover ACLs after a crashed real-Agent eval. Refuses to act while the lock
# owner is still alive and preserves restoration state on any restore error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACL_HELPER="$SCRIPT_DIR/windows-isolation-acl.ps1"
ACL_STATE="$ROOT/.harness/eval-acl-state.json"
ACL_LOCK="$ROOT/.harness/eval-acl.lock"
OWNER_FILE="$ACL_LOCK/owner.pid"
WINDOWS_POWERSHELL="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
TRUSTED_WINDOWS_ENV="/c/Program Files/Git/usr/bin/env.exe"

die() { echo "eval-recover: $*" >&2; exit 2; }
[ "$#" -eq 0 ] || die "usage: recover-windows-isolation.sh"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) die "Windows isolation recovery requires Git Bash on Windows" ;; esac
[ -f "$ACL_HELPER" ] && [ ! -L "$ACL_HELPER" ] || die "ACL helper missing or unsafe"
[ -f "$WINDOWS_POWERSHELL" ] && [ ! -L "$WINDOWS_POWERSHELL" ] || die "Windows PowerShell missing or unsafe"
[ -f "$TRUSTED_WINDOWS_ENV" ] && [ -x "$TRUSTED_WINDOWS_ENV" ] && [ ! -L "$TRUSTED_WINDOWS_ENV" ] || die "trusted env missing or unsafe"
[ -f "$ACL_STATE" ] && [ ! -L "$ACL_STATE" ] || die "ACL restoration state missing or unsafe"

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

real_user_home_win="$("$TRUSTED_WINDOWS_ENV" -u PSModulePath "$WINDOWS_POWERSHELL" -NoProfile -Command '[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)' | tr -d '\r')"
[ -n "$real_user_home_win" ] || die "could not resolve the token-backed Windows user profile"
"$TRUSTED_WINDOWS_ENV" -u PSModulePath "$WINDOWS_POWERSHELL" -NoProfile -ExecutionPolicy Bypass \
  -File "$ACL_HELPER" -Mode Leave -WorkspaceRoot "$ROOT/.." -ControllerRoot "$ROOT" \
  -UserHome "$real_user_home_win" -StateFile "$ACL_STATE" \
  || die "ACL restoration failed; state retained"

rm -f -- "$OWNER_FILE"
rmdir "$ACL_LOCK" || die "ACLs restored but recovery lock could not be released"
lock_owned=false
echo "eval-recover: ACL restoration complete"
