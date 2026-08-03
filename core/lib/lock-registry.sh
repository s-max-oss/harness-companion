#!/bin/bash
# lock-registry.sh — Registry mutex for feature_list.json
#
# Design §7: Registry Locking Protocol.
# Cross-platform: Linux (flock preferred), macOS (mkdir), Windows Git Bash (mkdir).
#
# Backends (per platform, design §7.1):
#   - flock  : Linux when `flock(1)` is available (kernel-level fd lock).
#              Faster than mkdir under high contention; identical semantics
#              for the acquire/release API exposed here.
#   - mkdir  : POSIX-atomic, used on macOS and Windows Git Bash, and on
#              Linux if `flock` is missing. No external dependency beyond
#              POSIX mkdir(2).
#
# The chosen backend is fixed at source time and stored in _LR_BACKEND.
# Override with LOCK_REGISTRY_BACKEND=flock|mkdir before sourcing if
# platform detection disagrees with your environment.
#
# Public API (same signature for both backends):
#   source lock-registry.sh
#   acquire_lock <lock_dir> [timeout_s]
#     Returns 0 on success, 5 on timeout.
#     Side effects on success:
#       - mkdir backend: creates $lock_dir with metadata files
#       - flock backend: opens FD 9 on $lock_dir/flock.lock and holds an
#         exclusive flock in the *calling* shell. The token is exposed as
#         $LOCK_REGISTRY_TOKEN. Do NOT wrap acquire_lock in $(...) — that
#         runs it in a subshell, the subshell exits, FD 9 closes, and the
#         kernel releases the flock. acquire_lock sets a global; do not
#         capture via command substitution.
#   release_lock <lock_dir> [token]
#     If [token] is omitted, reads $LOCK_REGISTRY_TOKEN from the environment.
#     exit 0 released; exit 6 token mismatch / cannot_verify_ownership.
#
# Stale recovery matrix (per design §7.5) — applies to mkdir backend only.
# flock backend relies on the kernel for stale detection (dead fd → auto-release
# when the owning process exits; PID-start-time disambiguation is moot).
#
# Defaults:
#   LOCK_TIMEOUT_S       = 10 (per-call override via 2nd arg)
#   CROSS_HOST_TIMEOUT_S = 60
#   POLL_INTERVAL_S      = 0.1

# Defaults — overridable via env before sourcing
: "${LOCK_TIMEOUT_S:=10}"
: "${CROSS_HOST_TIMEOUT_S:=60}"
: "${POLL_INTERVAL_S:=0.1}"

# ---- backend selection -------------------------------------------------------
# Override via LOCK_REGISTRY_BACKEND=flock|mkdir. Otherwise: flock on Linux
# when available, mkdir everywhere else.
if [ -n "${LOCK_REGISTRY_BACKEND:-}" ]; then
  _LR_BACKEND="$LOCK_REGISTRY_BACKEND"
elif [ "$(uname -s 2>/dev/null)" = "Linux" ] && command -v flock >/dev/null 2>&1; then
  _LR_BACKEND="flock"
else
  _LR_BACKEND="mkdir"
fi

# Map lock_dir to flock's lock file path. For the flock backend, the caller-
# supplied lock_dir is a directory; we create a regular file inside it named
# `flock.lock` and use that as the flock target.
_lr_flock_path() {
  printf '%s/flock.lock' "$1"
}

# fd storage for flock backend. We need to remember which fd maps to which
# lock_dir so release_lock can flock -u the right fd. We use a simple file
# under $TMPDIR or /tmp with the lock_dir path encoded.
_lr_fd_dir="${TMPDIR:-/tmp}/.lock-registry-fds.$$"
mkdir -p "$_lr_fd_dir" 2>/dev/null || _lr_fd_dir="/tmp/.lock-registry-fds.$$-$$"
mkdir -p "$_lr_fd_dir" 2>/dev/null || true
_lr_fd_path() {
  # Encode lock_dir to a flat filename so we can mktemp safely.
  printf '%s/%s' "$_lr_fd_dir" "$(printf '%s' "$1" | tr '/' '_')"
}

# ---- token generation -------------------------------------------------------

# ---- token generation -------------------------------------------------------
# 32-char random token. Falls back to $RANDOM concatenation if /dev/urandom is
# absent (Windows Git Bash usually has it via MSYS2).
_lr_random_token() {
  if [ -r /dev/urandom ]; then
    tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 32
    return 0
  fi
  # Fallback: $RANDOM (16-bit) + pid + nanos — not cryptographically strong
  # but adequate for ownership distinction within a single host.
  printf '%.32s' "${RANDOM}${RANDOM}${RANDOM}$$$(date +%N)"
}

# ---- metadata helpers --------------------------------------------------------
_lr_my_hostname() {
  hostname 2>/dev/null || printf 'unknown-host'
}

_lr_now() {
  date +%s
}

# Get process start time as seconds since epoch. Empty on platforms that
# don't expose it (Windows Git Bash / macOS without ps).
# Args: pid
_lr_process_start_time() {
  local pid="$1"
  # Linux: stat /proc/$pid; GNU ps; BSD ps (macOS)
  if [ -r "/proc/$pid/stat" ]; then
    # /proc/$pid/stat: field 22 is starttime in clock ticks since boot
    # Convert using sysconf(_SC_CLK_TCK) — usually 100 on Linux.
    local starttime clk_tck
    starttime="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)"
    clk_tck="$(getconf CLK_TCK 2>/dev/null || printf '100')"
    if [ -n "$starttime" ] && [ -n "$clk_tck" ]; then
      local btime
      btime="$(awk '{print $22}' /proc/stat 2>/dev/null)"
      # btime is wall-clock at boot (sec). Add (starttime/clk_tck) = process age.
      if [ -n "$btime" ]; then
        awk -v b="$btime" -v s="$starttime" -v c="$clk_tck" \
          'BEGIN { printf "%d\n", b + (s / c) }'
        return 0
      fi
    fi
  fi
  # Fallback: ps (Linux/macOS). -o lstart= gives human time; -o etime= gives elapsed.
  if command -v ps >/dev/null 2>&1; then
    # etime is [[DD-]hh:]mm:ss — parse to seconds.
    local etime
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$etime" ]; then
      _lr_etime_to_start "$etime" || true
      return 0
    fi
  fi
  # Cannot determine start_time
  return 1
}

# Convert ps etime ([[DD-]hh:]mm:ss) to seconds-since-epoch process start.
# Echoes the start time.
_lr_etime_to_start() {
  local etime="$1"
  local d=0 h=0 m=0 s=0
  case "$etime" in
    *-*)
      d="${etime%%-*}"
      etime="${etime#*-}"
      ;;
  esac
  # Now etime is hh:mm:ss or mm:ss
  local parts
  IFS=':' read -ra parts <<<"$etime"
  case "${#parts[@]}" in
    3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
    2) m="${parts[0]}"; s="${parts[1]}" ;;
    *) s="${parts[0]}" ;;
  esac
  local total
  total=$(( d*86400 + h*3600 + m*60 + s ))
  _lr_now
  awk -v n "$(_lr_now)" -v t "$total" 'BEGIN { printf "%d\n", n - t }'
}

# Is PID alive? Uses kill -0 (POSIX) which works on Linux/macOS/Windows MSYS2.
_lr_pid_alive() {
  local pid="$1"
  # POSIX special case: pid=0 means "current process group" not a real pid
  [ -z "$pid" ] && return 1
  [ "$pid" -le 0 ] 2>/dev/null && return 1
  kill -0 "$pid" 2>/dev/null
}

# ---- metadata read/write -----------------------------------------------------
_lr_write_meta() {
  local lock_dir="$1" pid="$2" start_time="$3" host="$4" ts="$5" tok="$6"
  printf '%s\n' "$pid" > "$lock_dir/pid"
  if [ -n "$start_time" ]; then
    printf '%s\n' "$start_time" > "$lock_dir/process_start_time"
  else
    : > "$lock_dir/process_start_time"  # empty file = no start_time
  fi
  printf '%s\n' "$host" > "$lock_dir/hostname"
  printf '%s\n' "$ts" > "$lock_dir/timestamp"
  printf '%s\n' "$tok" > "$lock_dir/token"
}

_lr_read_meta() {
  local lock_dir="$1"
  if [ ! -d "$lock_dir" ]; then
    return 1
  fi
  # Required fields: pid, hostname, timestamp, token
  local pid host ts tok
  pid="$(cat "$lock_dir/pid" 2>/dev/null)"
  host="$(cat "$lock_dir/hostname" 2>/dev/null)"
  ts="$(cat "$lock_dir/timestamp" 2>/dev/null)"
  tok="$(cat "$lock_dir/token" 2>/dev/null)"
  # Optional: process_start_time (may be empty)
  local start_time=""
  if [ -f "$lock_dir/process_start_time" ]; then
    start_time="$(cat "$lock_dir/process_start_time" 2>/dev/null)"
  fi
  if [ -z "$pid" ] || [ -z "$host" ] || [ -z "$ts" ] || [ -z "$tok" ]; then
    return 1
  fi
  LR_META_PID="$pid"
  LR_META_START="$start_time"
  LR_META_HOST="$host"
  LR_META_TS="$ts"
  LR_META_TOKEN="$tok"
  return 0
}

# ---- stale-lock recovery decision -------------------------------------------
# Returns 0 if the lock_dir should be removed (stale), 1 if it should be kept.
# Decision matrix per design §7.5.
_lr_is_stale() {
  local lock_dir="$1"
  if ! _lr_read_meta "$lock_dir"; then
    # Damaged metadata — wait (don't fast-recover)
    return 1
  fi
  local my_host
  my_host="$(_lr_my_hostname)"
  local now
  now="$(_lr_now)"

  # --- Cross-host: NEVER judge stale by local PID ---
  if [ "$LR_META_HOST" != "$my_host" ]; then
    if [ $(( now - LR_META_TS )) -gt "$CROSS_HOST_TIMEOUT_S" ]; then
      return 0  # cross-host grace expired → recover
    fi
    return 1  # within grace → wait
  fi

  # --- Same host: can use PID ---
  if _lr_pid_alive "$LR_META_PID"; then
    # PID alive — check start_time to rule out reuse
    if [ -n "$LR_META_START" ]; then
      local actual_start
      if actual_start="$(_lr_process_start_time "$LR_META_PID" 2>/dev/null)"; then
        if [ "$actual_start" != "$LR_META_START" ]; then
          # PID reused by different process — DO NOT steal
          return 1
        fi
      fi
    fi
    # PID alive and start_time either matches or unavailable → not stale
    return 1
  fi

  # --- PID dead on same host ---
  if [ -n "$LR_META_START" ]; then
    # Have start_time: PID is dead AND start_time matches "nothing now"
    # (since the PID is dead, no current process matches). Safe to recover.
    return 0
  fi

  # No start_time (legacy/Windows): cannot disambiguate. Only recover past timeout.
  if [ $(( now - LR_META_TS )) -gt "$LOCK_TIMEOUT_S" ]; then
    return 0
  fi
  return 1
}

# _lr_snapshot_stale <lock_dir>
# Returns 0 if lock_dir is stale, AND captures identity snapshot into
# LR_STALE_{PID,START,TS,TOKEN} for TOCTOU-safe deletion. Caller MUST
# re-read metadata before deleting and verify the snapshot still matches.
# Returns 1 if lock_dir is not stale (or metadata damaged).
_lr_snapshot_stale() {
  local lock_dir="$1"
  if _lr_is_stale "$lock_dir"; then
    LR_STALE_PID="$LR_META_PID"
    LR_STALE_START="$LR_META_START"
    LR_STALE_TS="$LR_META_TS"
    LR_STALE_TOKEN="$LR_META_TOKEN"
    LR_STALE_HOST="$LR_META_HOST"
    return 0
  fi
  return 1
}

# ---- public API --------------------------------------------------------------

# acquire_lock <lock_dir> [timeout_s]
# Dispatches to flock or mkdir backend per _LR_BACKEND (fixed at source time).
acquire_lock() {
  if [ "$_LR_BACKEND" = "flock" ]; then
    _lr_flock_acquire "$@"
    return $?
  fi
  _lr_mkdir_acquire "$@"
}

# release_lock <lock_dir> <token>
# Dispatches to flock or mkdir backend per _LR_BACKEND.
release_lock() {
  if [ "$_LR_BACKEND" = "flock" ]; then
    _lr_flock_release "$@"
    return $?
  fi
  _lr_mkdir_release "$@"
}

# ---- mkdir backend (POSIX-atomic; macOS, Git Bash, Linux-fallback) -----------

# _lr_mkdir_acquire <lock_dir> [timeout_s]
_lr_mkdir_acquire() {
  local lock_dir="${1:-}"
  local timeout_s="${2:-$LOCK_TIMEOUT_S}"
  if [ -z "$lock_dir" ]; then
    echo "acquire_lock: usage: acquire_lock <lock_dir> [timeout_s]" >&2
    return 2
  fi

  local deadline
  deadline=$(( $(_lr_now) + timeout_s ))
  local my_token
  my_token="$(_lr_random_token)"
  if [ -z "$my_token" ]; then
    echo "acquire_lock: failed to generate token" >&2
    return 3
  fi
  local my_pid="$$"
  local my_host
  my_host="$(_lr_my_hostname)"
  local my_start_time=""

  while [ "$(_lr_now)" -lt "$deadline" ]; do
    # mkdir is POSIX-atomic; EEXIST means someone else holds it
    if mkdir "$lock_dir" 2>/dev/null; then
      # We hold the lock — compute start_time NOW (it can be slow on
      # Windows Git Bash / macOS where /proc is absent). Deferring this
      # keeps the deadline check accurate relative to wall-clock wait time.
      my_start_time="$(_lr_process_start_time "$my_pid" 2>/dev/null || true)"
      _lr_write_meta "$lock_dir" "$my_pid" "$my_start_time" "$my_host" \
        "$(_lr_now)" "$my_token"
      # Expose token via the global so release_lock can read it from env
      # (mirrors the flock backend). Callers must NOT wrap acquire_lock in
      # $(...); see the public-API doc-comment at the top of this file.
      LOCK_REGISTRY_TOKEN="$my_token"
      export LOCK_REGISTRY_TOKEN
      printf '%s' "$my_token"
      return 0
    fi

    # Lock exists — check if it's stale, with TOCTOU-safe recovery.
    # Capture identity (pid + start_time + token + timestamp) at the stale
    # decision time, then re-read metadata immediately before rm -rf. Only
    # delete if the identity still matches — otherwise another process may
    # have released and re-acquired the lock, and we'd be stealing the new
    # owner's lock. Use rm -rf because metadata files live inside lock_dir.
    if _lr_snapshot_stale "$lock_dir"; then
      # _lr_snapshot_stale sets LR_STALE_PID / LR_STALE_START / LR_STALE_TS / LR_STALE_TOKEN
      if _lr_read_meta "$lock_dir" \
          && [ "$LR_META_PID" = "$LR_STALE_PID" ] \
          && [ "$LR_META_START" = "$LR_STALE_START" ] \
          && [ "$LR_META_TOKEN" = "$LR_STALE_TOKEN" ] \
          && [ "$LR_META_TS" = "$LR_STALE_TS" ]; then
        # Identity confirmed unchanged — safe to delete the stale lock.
        if rm -rf "$lock_dir" 2>/dev/null; then
          continue
        fi
      fi
      # Identity changed: another process replaced the lock. Wait.
    fi

    sleep "$POLL_INTERVAL_S"
  done

  return 5  # timeout
}

# _lr_mkdir_release <lock_dir> [token]
# If [token] is omitted, reads $LOCK_REGISTRY_TOKEN from the environment.
_lr_mkdir_release() {
  local lock_dir="${1:-}"
  local token="${2:-${LOCK_REGISTRY_TOKEN:-}}"
  if [ -z "$lock_dir" ] || [ -z "$token" ]; then
    echo "release_lock: usage: release_lock <lock_dir> [token] (token required; set LOCK_REGISTRY_TOKEN or pass as 2nd arg)" >&2
    return 2
  fi
  if [ ! -d "$lock_dir" ]; then
    # Lock already gone — nothing to do (idempotent)
    return 0
  fi
  # Fail-closed: if metadata cannot be read, ownership cannot be verified.
  # Refuse to delete — any token would otherwise be able to remove a lock
  # whose owner is unknown.
  if ! _lr_read_meta "$lock_dir"; then
    echo "release_lock: cannot_verify_ownership — metadata unreadable; refusing to delete" >&2
    return 6
  fi
  if [ "$LR_META_TOKEN" != "$token" ]; then
    echo "release_lock: token_mismatch — refusing to release lock held by another owner" >&2
    return 6
  fi
  # rm -rf + verify: on slower Windows filesystems the directory entry can
  # linger for a few hundred ms after rm -rf reports success. Retry up to
  # 5 times with short sleeps to ensure the lock_dir is actually gone before
  # the caller assumes release succeeded — otherwise the next acquire_lock
  # will see a stale-but-matching lock_dir and time out (Windows flake).
  local removed=0
  local i
  for i in 1 2 3 4 5; do
    rm -rf "$lock_dir" 2>/dev/null || true
    if [ ! -d "$lock_dir" ]; then
      removed=1
      break
    fi
    sleep 0.1
  done
  if [ "$removed" -ne 1 ]; then
    # Lock_dir is still present after retries. The token matched and the
    # owner is verified, so the release "logically" succeeded — but the
    # filesystem didn't honor rm. Surface a warning so callers and tests
    # can detect the leak; the next acquire_lock will stale-recover.
    echo "release_lock: warning — failed to remove $lock_dir after 5 attempts (filesystem leak)" >&2
  fi
  return 0
}

# ---- flock backend (Linux preferred) -----------------------------------------
# flock(1) provides fd-level exclusive locks handled by the kernel. The lock
# is auto-released when the owning process exits — no stale-recovery matrix
# needed for crash safety. Token-based ownership is preserved via a sidecar
# file so release_lock can refuse mismatched tokens (defense in depth: even
# though fd ownership is enforced by the kernel, refusing wrong tokens gives
# us a clear error path and matches the mkdir API contract).
#
# File layout:
#   <lock_dir>/                       — caller-supplied directory
#   <lock_dir>/flock.lock             — regular file flock(1) operates on
#   <lock_dir>/.lr_owner              — file containing our 32-char token
#   $_lr_fd_dir/<encoded_lock_dir>    — file with the fd number for release

# _lr_flock_acquire <lock_dir> [timeout_s]
# IMPORTANT: opens FD 9 in the CALLING shell via `exec 9>>`. The caller must
# NOT capture acquire_lock's stdout via $(...) — that would run in a subshell,
# the subshell would exit, FD 9 would close, and the kernel would release the
# flock immediately. We echo the token for visibility but expose it primarily
# via the global LOCK_REGISTRY_TOKEN. After a successful acquire_lock, the
# caller should run mutations, then call release_lock (NOT in a subshell).
_lr_flock_acquire() {
  local lock_dir="${1:-}"
  local timeout_s="${2:-$LOCK_TIMEOUT_S}"
  if [ -z "$lock_dir" ]; then
    echo "acquire_lock: usage: acquire_lock <lock_dir> [timeout_s]" >&2
    return 2
  fi
  local lock_file
  lock_file="$(_lr_flock_path "$lock_dir")"

  # Ensure parent dir exists (mkdir -p is safe because lock_file inside it
  # is the atomic primitive, not the directory).
  mkdir -p "$lock_dir" 2>/dev/null || {
    echo "acquire_lock: failed to create lock_dir '$lock_dir'" >&2
    return 2
  }
  # Touch the lock file so flock has something to open.
  : >> "$lock_file" 2>/dev/null || {
    echo "acquire_lock: failed to create lock file '$lock_file'" >&2
    return 2
  }

  local my_token
  my_token="$(_lr_random_token)"
  if [ -z "$my_token" ]; then
    echo "acquire_lock: failed to generate token" >&2
    return 3
  fi

  # Open FD 9 in the calling shell. After this line returns, FD 9 stays
  # open in the shell that called acquire_lock — not in a subshell.
  exec 9>>"$lock_file"

  # Try to acquire exclusive flock with the deadline. flock -w 1 waits at
  # most 1s; we loop until the deadline so we surface a clear timeout error.
  local rc=1
  local deadline
  deadline=$(( $(_lr_now) + timeout_s ))
  while [ "$(_lr_now)" -lt "$deadline" ] && [ "$rc" -ne 0 ]; do
    flock -w 1 -x 9 && rc=0 || rc=$?
  done

  if [ "$rc" -ne 0 ]; then
    # Timed out — close the FD in the calling shell and surface failure.
    exec 9>&- 2>/dev/null || true
    return 5
  fi

  # Got the flock — record token sidecar so release_lock can verify ownership.
  printf '%s' "$my_token" > "$lock_dir/.lr_owner" 2>/dev/null || true
  # Expose token via the global LOCK_REGISTRY_TOKEN so callers don't need to
  # capture stdout (which would put acquire_lock in a subshell).
  LOCK_REGISTRY_TOKEN="$my_token"
  export LOCK_REGISTRY_TOKEN
  # Echo for callers that still want stdout (use process substitution carefully).
  printf '%s' "$my_token"
  return 0
}

# _lr_flock_release <lock_dir> [token]
# If [token] is omitted, reads $LOCK_REGISTRY_TOKEN from the environment.
# Must be called in the same shell that called acquire_lock (so FD 9 is the
# same kernel fd that holds the flock).
_lr_flock_release() {
  local lock_dir="${1:-}"
  local token="${2:-${LOCK_REGISTRY_TOKEN:-}}"
  if [ -z "$lock_dir" ] || [ -z "$token" ]; then
    echo "release_lock: usage: release_lock <lock_dir> [token] (token required; set LOCK_REGISTRY_TOKEN or pass as 2nd arg)" >&2
    return 2
  fi
  local lock_file
  lock_file="$(_lr_flock_path "$lock_dir")"

  # Idempotent: if lock_file gone, nothing to do.
  if [ ! -e "$lock_file" ]; then
    return 0
  fi

  # Token check (fail-closed).
  local owner_tok=""
  if [ -f "$lock_dir/.lr_owner" ]; then
    owner_tok="$(cat "$lock_dir/.lr_owner" 2>/dev/null)"
  fi
  if [ -z "$owner_tok" ]; then
    echo "release_lock: cannot_verify_ownership — owner token sidecar missing; refusing to unlock" >&2
    return 6
  fi
  if [ "$owner_tok" != "$token" ]; then
    echo "release_lock: token_mismatch — refusing to unlock lock held by another owner" >&2
    return 6
  fi

  # Release the flock in the calling shell and close FD 9. Because the flock
  # was acquired by the same shell via `exec 9>>`, this is the only fd that
  # actually holds the kernel lock — closing it releases the lock for any
  # waiters (proven by test-lock-registry T13).
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
  rm -f "$(_lr_fd_path "$lock_dir")" 2>/dev/null || true
  rm -f "$lock_dir/.lr_owner" 2>/dev/null || true
  LOCK_REGISTRY_TOKEN=""
  return 0
}