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
#       - flock backend: allocates a distinct FD for $lock_dir/flock.lock and
#         holds an exclusive flock in the *calling* shell. The token is exposed as
#         $LOCK_REGISTRY_TOKEN. Do NOT wrap acquire_lock in $(...) — that
#         runs it in a subshell, the subshell exits, its FD closes, and the
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

# The flock backend must support nested locks in one shell. Verdict writes hold
# a per-(kind,id) transaction lock while runtime_register acquires the distinct
# runtime-manifest lock. A fixed FD would make the inner acquire close and
# replace the outer lock. Keep one dynamically allocated FD and token per
# lock_dir instead. Use parallel indexed arrays rather than associative arrays
# so the mkdir fallback remains sourceable by the system Bash 3.2 shipped on
# older macOS hosts. Declarations without initializers preserve active entries
# if this library is sourced more than once.
declare -a _LR_FLOCK_DIRS 2>/dev/null || true
declare -a _LR_FLOCK_FDS 2>/dev/null || true
declare -a _LR_FLOCK_TOKENS 2>/dev/null || true
: "${_LR_FLOCK_NEXT_INDEX:=0}"
LR_FLOCK_INDEX=-1

_lr_flock_find_index() {
  local needle="$1" i
  LR_FLOCK_INDEX=-1
  for ((i=0; i<_LR_FLOCK_NEXT_INDEX; i++)); do
    if [ "${_LR_FLOCK_DIRS[$i]:-}" = "$needle" ]; then
      LR_FLOCK_INDEX="$i"
      return 0
    fi
  done
  return 1
}

# Allocate/close numeric descriptors without Bash 4's `exec {var}` syntax so
# this file can still be parsed when the mkdir backend is sourced by Bash 3.2.
# The evaluated fragment contains only a range-checked integer and a quoted
# reference to the local path variable; path bytes are never interpolated into
# shell syntax.
_lr_flock_open_fd() {
  local lock_file="$1" fd=10
  while eval ": >&${fd}" 2>/dev/null; do
    fd=$((fd + 1))
    if [ "$fd" -gt 199 ]; then
      return 1
    fi
  done
  if ! eval "exec ${fd}>>\"\$lock_file\""; then
    return 1
  fi
  LR_FLOCK_FD="$fd"
  return 0
}

_lr_flock_close_fd() {
  local fd="$1"
  case "$fd" in
    ''|*[!0-9]*) return 1 ;;
  esac
  eval "exec ${fd}>&-" 2>/dev/null
}

# Map lock_dir to flock's lock file path. For the flock backend, the caller-
# supplied lock_dir is a directory; we create a regular file inside it named
# `flock.lock` and use that as the flock target.
_lr_flock_path() {
  printf '%s/flock.lock' "$1"
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
  printf '%s\n' "$pid" > "$lock_dir/pid" || return 1
  if [ -n "$start_time" ]; then
    printf '%s\n' "$start_time" > "$lock_dir/process_start_time" || return 1
  else
    : > "$lock_dir/process_start_time" || return 1  # empty file = no start_time
  fi
  printf '%s\n' "$host" > "$lock_dir/hostname" || return 1
  printf '%s\n' "$ts" > "$lock_dir/timestamp" || return 1
  printf '%s\n' "$tok" > "$lock_dir/token" || return 1
  printf '%s\n' "$tok" > "$lock_dir/.ready" || return 1
}

_lr_read_meta() {
  local lock_dir="$1"
  if [ ! -d "$lock_dir" ]; then
    return 1
  fi
  # Current protocol: metadata is prepared in a token-private sibling before
  # one atomic hard-link publishes <lock_dir>/.claim. Thus no contender ever
  # observes a public lock whose metadata is only half written. Legacy root-
  # metadata is still readable for stale-lock recovery during upgrades/tests.
  local meta_dir="$lock_dir" claim="" protocol="legacy"
  if [ -f "$lock_dir/.claim" ] && [ ! -L "$lock_dir/.claim" ]; then
    IFS= read -r claim 2>/dev/null < "$lock_dir/.claim" || true
    case "$claim" in ''|*[!a-zA-Z0-9]*) return 1 ;; esac
    meta_dir="${lock_dir}.claim.${claim}"
    protocol="claim"
    [ -d "$meta_dir" ] && [ ! -L "$meta_dir" ] || return 1
  fi
  # Required fields: pid, hostname, timestamp, token
  # Read via the `read` builtin (no `cat` subprocess forks): this runs on every
  # contention poll, and on MSYS2 each fork costs ~30 ms, so 5×cat per iteration
  # starves concurrent lock acquirers. Each metadata file is a single line
  # (written by printf '%s\n'), so `read` captures the same value `cat` did.
  #
  # TOCTOU safety: a concurrent release_lock may `rm -rf` the lock_dir between
  # the `[ -d ]` guard above and these reads, so any file may vanish. Two rules
  # make this tolerant: (1) initialize every var to "" so `set -u` never sees an
  # unbound name, and (2) put `2>/dev/null` BEFORE the input redirect so the
  # "No such file or directory" redirection error is suppressed (bash opens
  # redirections left-to-right; a later `2>/dev/null` does not catch the input-
  # redirect failure). A vanished file then yields "" → the `-z` guard below
  # returns 1 (damaged → wait), exactly as the old `cat` path did.
  local pid="" host="" ts="" tok="" start_time="" ready=""
  IFS= read -r pid  2>/dev/null < "$meta_dir/pid"  || true
  IFS= read -r host 2>/dev/null < "$meta_dir/hostname" || true
  IFS= read -r ts   2>/dev/null < "$meta_dir/timestamp" || true
  IFS= read -r tok  2>/dev/null < "$meta_dir/token" || true
  IFS= read -r ready 2>/dev/null < "$meta_dir/.ready" || true
  # Optional: process_start_time (may be empty)
  if [ -f "$meta_dir/process_start_time" ]; then
    IFS= read -r start_time 2>/dev/null < "$meta_dir/process_start_time" || true
  fi
  if [ -z "$pid" ] || [ -z "$host" ] || [ -z "$ts" ] || [ -z "$tok" ] \
     || [ "$ready" != "$tok" ]; then
    return 1
  fi
  LR_META_PID="$pid"
  LR_META_START="$start_time"
  LR_META_HOST="$host"
  LR_META_TS="$ts"
  LR_META_TOKEN="$tok"
  LR_META_DIR="$meta_dir"
  LR_META_PROTOCOL="$protocol"
  return 0
}

_lr_path_identity() {
  local path="$1"
  stat -c '%d:%i:%Y:%s' "$path" 2>/dev/null \
    || stat -f '%d:%i:%m:%z' "$path" 2>/dev/null
}

_lr_path_mtime() {
  local path="$1"
  stat -c '%Y' "$path" 2>/dev/null || stat -f '%m' "$path" 2>/dev/null
}

# ---- stale-lock recovery decision -------------------------------------------
# Returns 0 if the lock_dir should be removed (stale), 1 if it should be kept.
# Decision matrix per design §7.5.
_lr_is_stale() {
  local lock_dir="$1"
  # my_host is precomputed once by the acquire loop and passed in — calling
  # `hostname` on every contention poll is another ~100 ms fork on MSYS2.
  local my_host="${2:-}"
  if [ -z "$my_host" ]; then
    my_host="$(_lr_my_hostname)"
  fi
  if ! _lr_read_meta "$lock_dir"; then
    # Damaged metadata — wait (don't fast-recover)
    return 1
  fi

  # `now` is computed lazily — only the cross-host and no-start_time past-timeout
  # branches actually need wall-clock time. The common contention case (same
  # host, live PID) skips the `date` fork entirely.
  local now=""

  # --- Cross-host: NEVER judge stale by local PID ---
  if [ "$LR_META_HOST" != "$my_host" ]; then
    now="$(_lr_now)"
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
  now="${now:-$(_lr_now)}"
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
  local my_host="${2:-}"
  if _lr_is_stale "$lock_dir" "$my_host"; then
    LR_STALE_PID="$LR_META_PID"
    LR_STALE_START="$LR_META_START"
    LR_STALE_TS="$LR_META_TS"
    LR_STALE_TOKEN="$LR_META_TOKEN"
    LR_STALE_HOST="$LR_META_HOST"
    LR_STALE_DIR="$LR_META_DIR"
    LR_STALE_PROTOCOL="$LR_META_PROTOCOL"
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

  # Deadline via the $SECONDS builtin (integer seconds since shell start),
  # not `date +%s` — the latter is a ~77 ms fork on MSYS2 and this runs on
  # every contention poll. $SECONDS is monotonic within this shell (and its
  # background subshells), so a relative deadline is strictly more correct
  # than wall-clock time (immune to NTP/clock steps).
  local deadline
  deadline=$(( SECONDS + timeout_s ))
  local my_token
  my_token="$(_lr_random_token)"
  if [ -z "$my_token" ]; then
    echo "acquire_lock: failed to generate token" >&2
    return 3
  fi
  # BASHPID identifies the actual background subshell. `$$` remains the parent
  # shell's PID inside `( ... ) &`, so using it makes independent contenders
  # claim the same owner identity and defeats stale-owner diagnostics.
  local my_pid="${BASHPID:-$$}"
  local my_host
  my_host="$(_lr_my_hostname)"
  local my_start_time=""
  # Compute potentially slow platform metadata before publishing the atomic
  # mkdir claim, minimizing the incomplete-metadata crash window.
  my_start_time="$(_lr_process_start_time "$my_pid" 2>/dev/null || true)"

  # Prepare a complete, private claim before publishing anything at the shared
  # lock path. The hard link below is the only atomic ownership primitive.
  local candidate="${lock_dir}.claim.${my_token}"
  if [ -e "$candidate" ] || [ -L "$candidate" ] || ! mkdir "$candidate" 2>/dev/null; then
    echo "acquire_lock: cannot create private claim metadata" >&2
    return 3
  fi
  if ! _lr_write_meta "$candidate" "$my_pid" "$my_start_time" "$my_host" \
      "$(_lr_now)" "$my_token"; then
    rm -rf "$candidate" 2>/dev/null || true
    echo "acquire_lock: failed to commit private lock metadata" >&2
    return 3
  fi
  # This claim protocol requires a same-filesystem atomic hard link. Detect an
  # unsupported FAT/exFAT/network filesystem up front instead of reporting a
  # misleading contention timeout.
  if ! ln "$candidate/.ready" "$candidate/.hardlink-probe" 2>/dev/null; then
    rm -rf "$candidate" 2>/dev/null || true
    echo "acquire_lock: mkdir claim backend unsupported (atomic hard links unavailable)" >&2
    return 4
  fi
  rm -f "$candidate/.hardlink-probe" 2>/dev/null || {
    rm -rf "$candidate" 2>/dev/null || true
    echo "acquire_lock: failed to clean hard-link capability probe" >&2
    return 3
  }

  # A fresh lock still receives one atomic publish attempt if metadata setup
  # consumes the timeout; later retries remain bounded by the deadline.
  local first_attempt=1
  while [ "$first_attempt" -eq 1 ] || [ "$SECONDS" -lt "$deadline" ]; do
    first_attempt=0
    # Never follow a caller-controlled symlink at the shared lock path.
    if [ -L "$lock_dir" ] || { [ -e "$lock_dir" ] && [ ! -d "$lock_dir" ]; }; then
      rm -rf "$candidate" 2>/dev/null || true
      echo "acquire_lock: shared lock path is not a real directory" >&2
      return 3
    fi
    # On Windows, a predecessor may rmdir the now-empty shared container in
    # the same instant this contender runs mkdir -p. That transient race can
    # make mkdir report failure even though there is no obstacle; retry until
    # the normal deadline instead of abandoning a fully prepared candidate.
    if ! mkdir -p "$lock_dir" 2>/dev/null; then
      sleep "$POLL_INTERVAL_S"
      continue
    fi
    # Upgrade compatibility: a root-metadata lock from the legacy protocol is
    # authoritative until it releases or is proven stale. Never publish a new
    # claim beside it.
    local legacy_present=0
    if [ ! -e "$lock_dir/.claim" ] && { [ -e "$lock_dir/.ready" ] || [ -e "$lock_dir/pid" ]; }; then
      legacy_present=1
    fi
    # `ln` is atomic and non-clobbering. Since candidate/.ready is committed
    # last and already contains the token, a visible .claim is always complete.
    if [ "$legacy_present" = "0" ] && ln "$candidate/.ready" "$lock_dir/.claim" 2>/dev/null; then
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
    if _lr_snapshot_stale "$lock_dir" "$my_host"; then
      # _lr_snapshot_stale sets LR_STALE_PID / LR_STALE_START / LR_STALE_TS / LR_STALE_TOKEN
      if _lr_read_meta "$lock_dir" \
          && [ "$LR_META_PID" = "$LR_STALE_PID" ] \
          && [ "$LR_META_START" = "$LR_STALE_START" ] \
          && [ "$LR_META_TOKEN" = "$LR_STALE_TOKEN" ] \
          && [ "$LR_META_TS" = "$LR_STALE_TS" ] \
          && [ "$LR_META_PROTOCOL" = "$LR_STALE_PROTOCOL" ] \
          && [ "$LR_META_DIR" = "$LR_STALE_DIR" ]; then
        if [ "$LR_STALE_PROTOCOL" = "claim" ]; then
          local published=""
          IFS= read -r published 2>/dev/null < "$lock_dir/.claim" || true
          if [ "$published" = "$LR_STALE_TOKEN" ] && rm -f "$lock_dir/.claim" 2>/dev/null; then
            rm -rf "$LR_STALE_DIR" 2>/dev/null || true
            continue
          fi
        else
          # Legacy owner metadata has no atomic claim. Retain the historical
          # stale-recovery behavior only for a fully committed legacy record.
          if rm -rf "$lock_dir" 2>/dev/null; then
            continue
          fi
        fi
      fi
      # Identity changed: another process replaced the lock. Wait.
    fi

    sleep "$POLL_INTERVAL_S"
  done

  rm -rf "$candidate" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
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
  if [ "${LR_META_PROTOCOL:-legacy}" = "claim" ]; then
    local claim_token=""
    IFS= read -r claim_token 2>/dev/null < "$lock_dir/.claim" || true
    if [ "$claim_token" != "$token" ]; then
      echo "release_lock: claim token changed; refusing to release" >&2
      return 6
    fi
    # Unlink only our atomic claim. A successor may publish immediately after
    # this point; all remaining cleanup is confined to our private metadata.
    if ! rm -f "$lock_dir/.claim" 2>/dev/null; then
      echo "release_lock: failed to unlink owned claim" >&2
      return 7
    fi
    local own_meta="${lock_dir}.claim.${token}" removed=0 i
    for i in 1 2 3 4 5; do
      rm -rf "$own_meta" 2>/dev/null || true
      if [ ! -e "$own_meta" ] && [ ! -L "$own_meta" ]; then
        removed=1
        break
      fi
      sleep 0.1
    done
    rmdir "$lock_dir" 2>/dev/null || true
    if [ "$removed" -ne 1 ]; then
      echo "release_lock: claim released; private metadata cleanup failed" >&2
      return 8
    fi
    return 0
  fi
  # Detach our verified directory from the acquisition name first. A new owner
  # can then acquire lock_dir while all cleanup retries remain confined to our
  # token-named tombstone; this releaser can never delete the new holder.
  local tomb="${lock_dir}.release.${token}"
  if [ -e "$tomb" ] || [ -L "$tomb" ]; then
    echo "release_lock: tombstone already exists; refusing ambiguous cleanup" >&2
    return 7
  fi
  if ! mv "$lock_dir" "$tomb" 2>/dev/null; then
    if _lr_read_meta "$lock_dir" && [ "$LR_META_TOKEN" != "$token" ]; then
      return 0
    fi
    echo "release_lock: failed to detach verified lock directory" >&2
    return 7
  fi
  local removed=0
  local i
  for i in 1 2 3 4 5; do
    rm -rf "$tomb" 2>/dev/null || true
    if [ ! -e "$tomb" ] && [ ! -L "$tomb" ]; then
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
    echo "release_lock: failed to remove $tomb after 5 attempts (filesystem leak)" >&2
    return 8
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

# _lr_flock_acquire <lock_dir> [timeout_s]
# IMPORTANT: opens a dynamic FD in the CALLING shell. The caller must
# NOT capture acquire_lock's stdout via $(...) — that would run in a subshell,
# the subshell would exit, its FD would close, and the kernel would release the
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
  if _lr_flock_find_index "$lock_dir"; then
    echo "acquire_lock: lock already held by this shell: $lock_dir" >&2
    return 4
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

  # Allocate a distinct FD in the calling shell. After this line returns, the
  # FD stays open in the shell that called acquire_lock — not in a subshell.
  # A distinct FD is essential for nested, different lock_dir acquisitions.
  local fd
  if ! _lr_flock_open_fd "$lock_file"; then
    echo "acquire_lock: failed to open lock file '$lock_file'" >&2
    return 2
  fi
  fd="$LR_FLOCK_FD"

  # Try to acquire exclusive flock with the deadline. flock -w 1 waits at
  # most 1s; we loop until the deadline so we surface a clear timeout error.
  local rc=1
  local deadline
  deadline=$(( $(_lr_now) + timeout_s ))
  while [ "$(_lr_now)" -lt "$deadline" ] && [ "$rc" -ne 0 ]; do
    flock -w 1 -x "$fd" && rc=0 || rc=$?
  done

  if [ "$rc" -ne 0 ]; then
    # Timed out — close the FD in the calling shell and surface failure.
    _lr_flock_close_fd "$fd" || true
    return 5
  fi

  # Got the flock — record token sidecar so release_lock can verify ownership.
  if ! printf '%s' "$my_token" > "$lock_dir/.lr_owner" 2>/dev/null; then
    flock -u "$fd" 2>/dev/null || true
    _lr_flock_close_fd "$fd" || true
    echo "acquire_lock: failed to write owner token sidecar" >&2
    return 3
  fi
  local map_index="$_LR_FLOCK_NEXT_INDEX"
  _LR_FLOCK_DIRS[$map_index]="$lock_dir"
  _LR_FLOCK_FDS[$map_index]="$fd"
  _LR_FLOCK_TOKENS[$map_index]="$my_token"
  _LR_FLOCK_NEXT_INDEX=$((_LR_FLOCK_NEXT_INDEX + 1))
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
# Must be called in the same shell that called acquire_lock so the mapped FD is
# the same kernel fd that holds the flock.
_lr_flock_release() {
  local lock_dir="${1:-}"
  local token="${2:-${LOCK_REGISTRY_TOKEN:-}}"
  if [ -z "$lock_dir" ] || [ -z "$token" ]; then
    echo "release_lock: usage: release_lock <lock_dir> [token] (token required; set LOCK_REGISTRY_TOKEN or pass as 2nd arg)" >&2
    return 2
  fi
  local lock_file
  lock_file="$(_lr_flock_path "$lock_dir")"

  _lr_flock_find_index "$lock_dir" || true
  local map_index="$LR_FLOCK_INDEX"
  local fd="" mapped_token=""
  if [ "$map_index" -ge 0 ]; then
    fd="${_LR_FLOCK_FDS[$map_index]:-}"
    mapped_token="${_LR_FLOCK_TOKENS[$map_index]:-}"
  fi
  if [ -z "$fd" ] || [ -z "$mapped_token" ]; then
    if [ ! -e "$lock_file" ]; then
      return 0
    fi
    echo "release_lock: cannot_verify_ownership — no FD mapping for $lock_dir" >&2
    return 6
  fi
  if [ "$mapped_token" != "$token" ]; then
    echo "release_lock: token_mismatch — refusing to release lock held by another owner" >&2
    return 6
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

  # Remove our sidecar while the kernel lock is still held. After unlock, a new
  # holder may write its token and must never be raced by this releaser.
  if ! rm -f "$lock_dir/.lr_owner" 2>/dev/null; then
    echo "release_lock: failed to remove owner sidecar while locked" >&2
    return 7
  fi
  # Even if the explicit unlock reports an error, closing the owned descriptor
  # is the kernel-level fallback that releases any lock still attached to it.
  # Do not return before closing: the sidecar is already gone and a retry could
  # no longer prove ownership.
  local unlock_rc=0 close_rc=0
  flock -u "$fd" 2>/dev/null || unlock_rc=1
  _lr_flock_close_fd "$fd" || close_rc=1
  if [ "$unlock_rc" -ne 0 ] && [ "$close_rc" -ne 0 ]; then
    # No kernel-release route succeeded. Keep the descriptor mapping and
    # restore the owner sidecar so a later retry can still prove ownership.
    printf '%s\n' "$token" > "$lock_dir/.lr_owner" 2>/dev/null || true
    echo "release_lock: kernel unlock and descriptor close both failed; ownership retained/unknown" >&2
    return 7
  fi
  unset "_LR_FLOCK_DIRS[$map_index]"
  unset "_LR_FLOCK_FDS[$map_index]"
  unset "_LR_FLOCK_TOKENS[$map_index]"
  LOCK_REGISTRY_TOKEN=""
  if [ "$unlock_rc" -ne 0 ]; then
    echo "release_lock: kernel unlock failed; descriptor close fallback attempted" >&2
    return 8
  fi
  if [ "$close_rc" -ne 0 ]; then
    echo "release_lock: file descriptor close failed after unlock" >&2
    return 8
  fi
  return 0
}
