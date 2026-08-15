#!/bin/bash
# registry-journal.sh — Append-only mutation journal (P0-M2)
#
# The feature_list.json "registry gate" proves per-revision legal mutation
# history through an APPEND-ONLY journal (the user's choice — over end-point
# transitive reachability, which the user explicitly rejected as insufficient).
#
# Storage: $project_dir/.harness/registry-journal.ndjson
#   NOT under .harness/.registry.lock/ — that directory is reclaimed on stale
#   lock recovery (lock-registry.sh rm -rf) and cannot carry persistent
#   evidence across that operation.
#
# Schema (one NDJSON line per legal mutation):
#   {ts, by, op, revision, feature_id, from, to,
#    feature_list_sha_before, feature_list_sha_after,
#    evidence_run_ids_after (optional array),
#    run_id (optional, present for evidence-associate / PASS transitions)}
#
# Two-phase commit:
#   1) journal_record_pending   — appends a JSON line with op+intent. The
#      `pending` field is true. The caller MUST follow with atomic_write_json
#      for feature_list.json, then journal_record_committed (which appends a
#      SECOND line with the same op_key and pending=false). On crash, recovery
#      walks the journal, finds a pending line whose paired committed line is
#      missing, and either rolls forward (replay the mutation IF feature_list
#      SHA already matches the pending's `feature_list_sha_after`) or rolls
#      back (truncate the orphan pending line).
#
# Checkpoint migration:
#   First call to journal_init checks for legacy journal data under
#   .harness/.registry.lock/journal.ndjson (rejected location). If present,
#   the legacy file is MIGRATED to the canonical .harness/registry-journal.ndjson
#   with a single "checkpoint_migrated" line, then deleted. This satisfies the
#   "checkpoint 迁移" requirement without losing prior mutation history.
#
# DWM append-only contract:
#   The journal is in DWM_MUTABLE but with a STRICTER per-class rule: existing
#   bytes MUST be a PREFIX of the current file (append-only — no in-place
#   edits, no removals, no reordering). dwm_compare_manifest enforces this.
#
# All writes go through the same acquire-lock (lock-registry.sh) used by
# harness-feature.sh so concurrent CLI calls cannot interleave a pending and
# committed pair.
#
# Functions:
#   journal_init        <project_dir>
#   journal_record_pending  <project_dir> <op> <feature_id> <from> <to> \
#                          [--run-id R] [--evidence-ids ID1,ID2,...] \
#                          [--revision N]
#       → echoes the raw op_key (used to pair with the committed line)
#   journal_record_committed <project_dir> <op_key> <feature_list_sha_after>
#       → appends the second line; copies revision from the pending line
#   journal_recover     <project_dir>  — idempotent crash recovery
#   journal_replay      <project_dir> <recorded_doc>
#       → PROVES the current feature_list.json is the recorded snapshot plus a
#         chain of PER-REVISION LEGAL SINGLE-EDGE mutations, all evidenced by
#         the append-only journal. Returns 0 (proven) or 1 (rejected). On
#         rejection prints a short reason token to STDOUT and a detail line to
#         stderr.
#   journal_migrate_legacy <project_dir>  — one-shot checkpoint migration
set -u

JOURNAL_REL=".harness/registry-journal.ndjson"
LEGACY_JOURNAL_REL=".harness/.registry.lock/journal.ndjson"

# ---- journal_path <project_dir> → absolute path ----------------------------
journal_path() {
  printf '%s/%s' "$1" "$JOURNAL_REL"
}

# ---- ensure_journal_dir <project_dir> ---------------------------------------
ensure_journal_dir() {
  local dir="$1"
  local jd
  jd="$(dirname "$(journal_path "$dir")")"
  [ -d "$jd" ] || mkdir -p "$jd" 2>/dev/null || {
    echo "journal: cannot create $jd" >&2; return 1; }
}

# ---- journal_init <project_dir> --------------------------------------------
# Idempotent: ensures the journal file exists with at least one header line.
# Also runs legacy checkpoint migration (P0-M2).
journal_init() {
  local dir="$1"
  ensure_journal_dir "$dir" || return 1
  local jp; jp="$(journal_path "$dir")"
  if [ ! -f "$jp" ]; then
    local hdr
    hdr="$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{ts:$ts, op:"journal_init", revision:0, feature_id:null,
        from:null, to:null, pending:false, op_key:null,
        feature_list_sha_before:null, feature_list_sha_after:null,
        evidence_run_ids_after:[], run_id:null}')"
    printf '%s\n' "$hdr" > "$jp" 2>/dev/null || {
      echo "journal: cannot initialize $jp" >&2; return 1; }
  fi
  journal_migrate_legacy "$dir"
  # Contract 3 (fail-closed): before any new mutation, resolve orphan pending
  # lines via three-way recovery (roll-forward ONLY on exact expected post-state
  # SHA; anything else blocks). A blocker aborts the init → the mutation fails.
  journal_recover "$dir" || return 1
}

# ---- sha256_file <path> -----------------------------------------------------
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    printf 'null'
  fi
}

# ---- op_key_new <project_dir> ----------------------------------------------
# Fresh per-mutation op_key (16 hex). The pending+committed pair shares this
# so crash recovery can pair them deterministically.
op_key_new() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s%s%s' "$(date +%s%N)" "$$" "$RANDOM" \
      | sha256sum 2>/dev/null | awk '{print substr($1,1,16)}'
  else
    printf '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
  fi
}

# ---- journal_record_pending ------------------------------------------------
# Append a PENDING line. The caller MUST follow up with atomic_write_json on
# feature_list.json and journal_record_committed. On crash between pending
# and committed, journal_recover handles it.
journal_record_pending() {
  local dir="$1" op="$2" feature_id="$3" from="$4" to="$5"
  shift 5
  local run_id="" evidence_ids_csv="" revision="" post_sha=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) run_id="${2:?--run-id requires a value}"; shift 2;;
      --evidence-ids) evidence_ids_csv="${2:?--evidence-ids requires a CSV}"; shift 2;;
      --revision) revision="${2:?--revision requires a value}"; shift 2;;
      --post-sha) post_sha="${2:?--post-sha requires a value}"; shift 2;;
      *) shift ;;
    esac
  done
  # Codex item 2+5: STRICT binding at pending time. Any op that affects the
  # canonical registry (add / status / evidence_associate) MUST bind a
  # deterministic expected_post_sha at pending time. The legacy journal used a
  # recovery_backfill to make up for missing binding; that path is closed for
  # new writes — bind at pending or fail-closed. `journal_init` lines have no
  # post-state, and `checkpoint_migrated` / `recovery_*` records are infra
  # records that also do not affect the registry directly.
  case "$op" in
    add|status|evidence_associate)
      if [ -z "$post_sha" ]; then
        echo "journal: op=$op requires --post-sha at pending time (Codex strict binding)" >&2
        return 1
      fi
      # 64-hex sanity (sha256sum output)
      case "$post_sha" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
          : ;;
        *)
          echo "journal: op=$op --post-sha must be a 64-hex sha256 (got: $post_sha)" >&2
          return 1
          ;;
      esac
      ;;
  esac
  ensure_journal_dir "$dir" || return 1
  local jp; jp="$(journal_path "$dir")"
  [ -f "$jp" ] || journal_init "$dir" || return 1
  local fl="$dir/feature_list.json"
  local sha_before
  sha_before="$(sha256_file "$fl")"

  # Parse evidence IDs (CSV → array)
  local ev_json="[]"
  if [ -n "$evidence_ids_csv" ]; then
    ev_json="$(printf '%s' "$evidence_ids_csv" | jq -R -s 'split(",") | map(select(length>0))')"
  fi

  local op_key; op_key="$(op_key_new)"
  local by; by="${HARNESS_OPERATOR:-$(whoami 2>/dev/null || echo unknown)}"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

  local from_json to_json
  if [ -z "$from" ]; then from_json="null"; else from_json="\"$from\""; fi
  if [ -z "$to" ];   then to_json="null";   else to_json="\"$to\"";   fi
  # revision: the target registry revision this mutation produces (per-revision
  # auditability). null when the caller did not provide one.
  local rev_json
  if [ -z "$revision" ]; then rev_json="null"; else rev_json="$revision"; fi
  # Contract 3: the caller BINDS the deterministic expected post-state SHA at
  # pending time (the sha of the exact content it is about to atomic-write).
  # journal_recover may only roll-forward when current == expected_post_sha.
  local post_json
  if [ -z "$post_sha" ]; then post_json="null"; else post_json="\"$post_sha\""; fi
  local line
  line="$(jq -cn \
    --arg ts "$ts" --arg by "$by" --arg op "$op" --arg f "$feature_id" \
    --arg key "$op_key" \
    --arg sha_b "$sha_before" --arg run_id "$run_id" \
    --argjson ev "$ev_json" \
    --argjson from_j "$from_json" --argjson to_j "$to_json" \
    --argjson rev_j "$rev_json" --argjson post_j "$post_json" \
    '{ts:$ts, by:$by, op:$op, revision:$rev_j, feature_id:$f,
      from:$from_j, to:$to_j, pending:true, op_key:$key,
      feature_list_sha_before:$sha_b, feature_list_sha_after:null,
      evidence_run_ids_after:$ev, run_id:$run_id, expected_post_sha:$post_j}')"

  # Append + flush — atomic via O_APPEND on POSIX (we cannot use atomic_write_json
  # because the file must be append-only; an O_APPEND write is atomic for sizes
  # ≤ PIPE_BUF on Linux and is the conventional append-only idiom).
  printf '%s\n' "$line" >> "$jp" || {
    echo "journal: cannot append pending line" >&2; return 1; }

  printf '%s' "$op_key"
  return 0
}

# ---- journal_record_committed ----------------------------------------------
# Append the COMMITTED line paired with the pending op_key. The caller has
# already mutated feature_list.json — we record its NEW sha.
journal_record_committed() {
  local dir="$1" op_key="$2" sha_after="$3"
  ensure_journal_dir "$dir" || return 1
  local jp; jp="$(journal_path "$dir")"
  [ -f "$jp" ] || { echo "journal: no journal file at $jp" >&2; return 1; }

  # Find the matching pending line by op_key. If missing, this is a bug
  # (committed without pending) — fail-closed.
  local pending_line
  pending_line="$(grep -F "\"op_key\":\"$op_key\"" "$jp" | grep '"pending":true' | tail -1)"
  if [ -z "$pending_line" ]; then
    echo "journal: committed called for op_key=$op_key with no pending line" >&2
    return 1
  fi

  local by; by="${HARNESS_OPERATOR:-$(whoami 2>/dev/null || echo unknown)}"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

  # Contract 3 (fail-closed): the committed sha_after MUST equal the expected
  # post-state SHA bound at pending time. A mismatch means the reported
  # post-state is not the one the mutation promised — refuse to commit it.
  local exp_sha bf_sha
  exp_sha="$(printf '%s' "$pending_line" | jq -r '.expected_post_sha // ""' 2>/dev/null | tr -d '\r')"
  bf_sha="$(jq -r --arg k "$op_key" 'select(.op == "recovery_backfill" and .op_key == $k) | .expected_post_sha // ""' "$jp" 2>/dev/null | tr -d '\r' | head -1)"
  # Codex item 5: ALSO fail-closed when expected_post_sha is missing/null AND
  # no recovery_backfill exists. A legacy pending without backfill cannot be
  # committed to — refuse rather than silently pass.
  if [ -z "$exp_sha" ] || [ "$exp_sha" = "null" ]; then
    if [ -z "$bf_sha" ] || [ "$bf_sha" = "null" ]; then
      echo "journal: committed called for op_key=$op_key with no expected_post_sha and no recovery_backfill — refusing to commit" >&2
      return 1
    fi
    exp_sha="$bf_sha"
  fi
  if [ "$exp_sha" != "$sha_after" ]; then
    echo "journal: committed sha_after ($sha_after) != expected post-state ($exp_sha) for op_key=$op_key" >&2
    return 1
  fi

  # Copy the pending line's revision so the committed line is per-revision
  # auditable too.
  local rev_json
  rev_json="$(printf '%s' "$pending_line" | jq -c '.revision // null' 2>/dev/null | tr -d '\r')"

  local line
  line="$(jq -cn \
    --arg ts "$ts" --arg by "$by" --arg key "$op_key" \
    --arg sha_a "$sha_after" --argjson rev "$rev_json" \
    '{ts:$ts, by:$by, op:"commit", revision:$rev, feature_id:null,
      from:null, to:null, pending:false, op_key:$key,
      feature_list_sha_before:null, feature_list_sha_after:$sha_a,
      evidence_run_ids_after:[], run_id:null}')"
  printf '%s\n' "$line" >> "$jp" || {
    echo "journal: cannot append committed line" >&2; return 1; }
  return 0
}

# ---- journal_recover <project_dir> -----------------------------------------
# Idempotent. Walks the journal. For each pending line whose committed partner
# is missing, decides roll-forward or roll-back based on the actual SHA of
# feature_list.json AND the expected post-state SHA bound at pending time.
# Logs a recovery record. Fail-closed (Contract 3):
#
#   current == pre_sha                  → roll-back (writer crashed before
#                                         atomic_write; truncate orphan pending)
#   current == expected_post_sha        → roll-forward (writer crashed between
#                                         atomic_write and committed; append a
#                                         recovery_forward commit-equivalent)
#   any OTHER sha                       → BLOCKER: leave the pending line in
#                                         place, log recovery_blocked, return 1.
#                                         An arbitrary external SHA must never be
#                                         re-recorded as a commit.
# Called from journal_init before every new mutation, so a blocker aborts the
# next mutation too. Returns 0 on success, 1 on a blocker.
journal_recover() {
  local dir="$1"
  local jp; jp="$(journal_path "$dir")"
  # Nothing to recover if the journal (or registry) does not exist.
  [ -f "$jp" ] || return 0
  local fl="$dir/feature_list.json"
  [ -f "$fl" ] || return 0
  local fl_sha; fl_sha="$(sha256_file "$fl")"

  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

  # P0-1.7 explicit legacy recovery BEFORE any verification: bring pre-Contract-3
  # pending lines (no expected_post_sha) into the strict contract via append-only
  # recovery_backfill records derived from their committed sha_after.
  journal_backfill_legacy_pending "$dir" || return 1

  # P0-1.6 INDEPENDENT strict-pairing verification. A committed partner NEVER
  # lets recovery skip this: a duplicate op_key/pending/commit, commit-without-
  # pending, missing expected_post_sha, or sha-after byte-mismatch must BLOCK
  # here, not pass silently.
  local vreason
  if ! vreason="$(journal_verify_pairs "$dir")"; then
    local rec
    rec="$(jq -cn --arg ts "$ts" --arg reason "$vreason" \
      '{ts:$ts, op:"recovery_blocked", op_key:null,
        reason:"journal_verify_pairs failed", pair_violation:$reason}')"
    printf '%s\n' "$rec" >> "$jp" 2>/dev/null || true
    echo "journal-recover: BLOCKED — strict pairing violation ($vreason)" >&2
    return 1
  fi

  # Read all pending op_keys (in order). CR-strip: jq raw output on MSYS emits
  # CRLF, and a trailing \r would make the op_key lookups below miss their
  # partner lines (see the F11 parallel-mutation regression).
  local pending_keys
  pending_keys="$(jq -r 'select(.pending == true) | .op_key' "$jp" 2>/dev/null | tr -d '\r')"
  local key
  while IFS= read -r key; do
    key="${key%$'\r'}"
    [ -z "$key" ] && continue
    # Has the partner committed line arrived?
    if jq -e --arg k "$key" 'select(.op_key == $k and .pending == false)' "$jp" >/dev/null 2>&1; then
      continue
    fi
    # No committed partner — decide from the current registry SHA.
    local pre_sha
    pre_sha="$(jq -r --arg k "$key" 'select(.op_key == $k and .pending == true) | .feature_list_sha_before' "$jp" 2>/dev/null | tr -d '\r')"
    if [ "$pre_sha" = "$fl_sha" ]; then
      # Roll-back (Codex item 3 — APPEND-ONLY): the orphan pending line is
      # PRESERVED in the audit trail (DWM append-only contract). Backout is
      # marked by APPENDING a recovery_backout record carrying the op_key;
      # journal_replay and journal_verify_pairs filter out op_keys with such a
      # record (they were backed out, not committed). This satisfies the
      # `recorded bytes ⊆ current bytes` invariant at all times.
      local already
      already="$(jq -sr --arg k "$key" '[.[] | select(.op == "recovery_backout" and .op_key == $k)] | length' "$jp" 2>/dev/null | tr -d '\r')"
      if [ "$already" = "0" ]; then
        local rec
        rec="$(jq -cn --arg ts "$ts" --arg k "$key" \
          '{ts:$ts, op:"recovery_backout", op_key:$k, reason:"pending orphan + sha unchanged (append-only backout)"}')"
        printf '%s\n' "$rec" >> "$jp"
      fi
    else
      # Roll-forward ONLY when current SHA exactly equals the expected post-state.
      local exp_sha
      exp_sha="$(jq -r --arg k "$key" 'select(.op_key == $k and .pending == true) | .expected_post_sha // ""' "$jp" 2>/dev/null | tr -d '\r' | tail -1)"
      if [ -n "$exp_sha" ] && [ "$exp_sha" != "null" ] && [ "$exp_sha" = "$fl_sha" ]; then
        # The writer DID succeed in atomic_write but crashed before recording
        # committed. Append a committed-equivalent line.
        local rev_json
        rev_json="$(jq -c --arg k "$key" 'select(.op_key == $k and .pending == true) | .revision // null' "$jp" 2>/dev/null | tr -d '\r' | tail -1)"
        local rec
        rec="$(jq -cn --arg ts "$ts" --arg k "$key" --arg sha "$fl_sha" --argjson rev "$rev_json" \
          '{ts:$ts, by:"journal_recover", op:"commit",
            revision:$rev, feature_id:null, from:null, to:null,
            pending:false, op_key:$k,
            feature_list_sha_before:null, feature_list_sha_after:$sha,
            evidence_run_ids_after:[], run_id:null,
            recovery_note:"forward-roll-forward on crash recovery (sha == expected post-state)"}')"
        printf '%s\n' "$rec" >> "$jp"
      else
        # BLOCKER: current SHA is neither the pre-SHA nor the expected post-SHA.
        # Leave the pending line in place (a later retry re-runs this decision);
        # log and fail-closed so no external edit is ever minted into a commit.
        local rec
        rec="$(jq -cn --arg ts "$ts" --arg k "$key" --arg cur "$fl_sha" --arg exp "${exp_sha:-null}" \
          '{ts:$ts, op:"recovery_blocked", op_key:$k,
            reason:"current sha matches neither pre-sha nor expected post-state",
            current_sha:$cur, expected_post_sha:($exp | if . == "null" then null else . end)}')"
        printf '%s\n' "$rec" >> "$jp" 2>/dev/null || true
        echo "journal-recover: BLOCKED orphan op_key=$key (feature_list sha $fl_sha matches neither pre-sha $pre_sha nor expected post-state ${exp_sha:-null})" >&2
        return 1
      fi
    fi
  done <<<"$pending_keys"
  return 0
}

# ---- journal_migrate_legacy <project_dir> ----------------------------------
# P0-5 FAIL-CLOSED one-shot migration: if .harness/.registry.lock/journal.ndjson
# exists, its lines are merged into the canonical journal (every original field
# preserved — NO history may be lost), then the legacy file is processed
# (removed). The legacy data is first assembled into a temp PROBE (current
# journal + checkpoint marker + legacy lines + deterministic recovery_backfill)
# which must pass the strict pairing contract; only then is the probe atomically
# installed as the canonical journal and the legacy file removed. ANY step
# failure returns nonzero with the canonical journal and the legacy file left
# EXACTLY as they were — migration is never claimed complete (no checkpoint
# marker is minted) and no `|| true` swallows a critical failure.
journal_migrate_legacy() {
  local dir="$1"
  local legacy="$dir/$LEGACY_JOURNAL_REL"
  local jp; jp="$(journal_path "$dir")"
  [ -f "$legacy" ] || return 0
  [ -f "$jp" ] || return 0  # nothing to migrate into

  # Idempotent: a checkpoint_migrated marker for this source already present →
  # the data is already safely in the canonical journal. Re-attempt the leftover
  # cleanup so an interrupted prior run converges; a cleanup failure here is
  # non-critical (no history can be lost — it is already migrated).
  if jq -e --arg src "$LEGACY_JOURNAL_REL" \
      '[.[] | select(.op == "checkpoint_migrated" and .from == $src)] | length > 0' \
      "$jp" >/dev/null 2>&1; then
    [ -f "$legacy" ] && rm -f "$legacy"
    return 0
  fi

  # 1) Every legacy line must be a parseable JSON object BEFORE anything is
  #    written — a corrupt legacy file fails closed with nothing appended.
  local nline=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! printf '%s\n' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
      echo "journal-migrate: legacy journal line $nline is not a JSON object — refusing to migrate" >&2
      return 1
    fi
    nline=$((nline + 1))
  done < "$legacy"

  # 2) Assemble the probe: canonical journal bytes + checkpoint marker + legacy
  #    lines (as-is). Content = old journal bytes as a strict prefix, so the
  #    append-only contract (recorded ⊆ current) is preserved by the swap.
  local probe; probe="$(mktemp "$dir/.harness/.migrate-probe.XXXXXX")" || return 1
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
  local mark
  mark="$(jq -cn --arg ts "$ts" --arg src "$LEGACY_JOURNAL_REL" \
    '{ts:$ts, op:"checkpoint_migrated", from:$src, to:"'"$JOURNAL_REL"'"}')" || {
    rm -f "$probe"; echo "journal-migrate: cannot build checkpoint marker" >&2; return 1; }
  if ! { cat "$jp"; printf '%s\n' "$mark"; cat "$legacy"; } > "$probe"; then
    rm -f "$probe"
    echo "journal-migrate: cannot assemble migration probe" >&2
    return 1
  fi

  # 3) The probe must satisfy the strict contract EXACTLY as the real journal
  #    will: recovery_backfill the legacy pendings deterministically, then
  #    journal_verify_pairs must pass. Any violation → fail-closed.
  if ! journal_backfill_legacy_pending "$dir" "$probe"; then
    rm -f "$probe"
    echo "journal-migrate: legacy backfill failed during probe" >&2
    return 1
  fi
  local vreason
  if ! vreason="$(journal_verify_pairs "$dir" "$probe")"; then
    rm -f "$probe"
    echo "journal-migrate: post-migration journal violates strict pairing ($vreason) — refusing to migrate" >&2
    return 1
  fi

  # 4) Migration fully written and validated — commit. Atomic replace keeps the
  #    journal consistent (no partial append observable); the legacy file is
  #    only processed AFTER the canonical journal is installed.
  #
  #    Snapshot the canonical journal bytes BEFORE the mv. If the subsequent
  #    rm of the legacy file fails, restore the snapshot so the caller's view
  #    of "both files exactly as they were" is preserved even when the rm
  #    step itself fails — otherwise a successful mv with a failed rm would
  #    leave the legacy file behind and the caller would see rc=1, hiding the
  #    fact that migration actually succeeded (Codex r5 defect, Critical #3).
  local jp_snapshot; jp_snapshot="$(mktemp "$dir/.harness/.migrate-rollback.XXXXXX")" || {
    rm -f "$probe"; echo "journal-migrate: cannot create rollback snapshot" >&2; return 1; }
  if ! cp -f "$jp" "$jp_snapshot" 2>/dev/null; then
    rm -f "$probe" "$jp_snapshot"
    echo "journal-migrate: cannot snapshot pre-migration journal" >&2
    return 1
  fi
  if ! mv -f "$probe" "$jp"; then
    rm -f "$probe" "$jp_snapshot"
    echo "journal-migrate: cannot install migrated journal" >&2
    return 1
  fi
  if ! rm -f "$legacy"; then
    # Legacy file could not be removed — roll back the canonical journal to
    # its pre-migration bytes so the caller's view of "both files untouched
    # on failure" holds. If the rollback mv itself fails (which would be a
    # filesystem-level disaster), we have nothing else to do — fail closed
    # with both states now inconsistent. The journal IS migrated at that
    # point; subsequent callers see checkpoint_migrated on the journal side
    # and re-attempt the legacy cleanup via the idempotent path above.
    if ! mv -f "$jp_snapshot" "$jp" 2>/dev/null; then
      echo "journal-migrate: FATAL — journal migrated AND rollback failed ($legacy still present)" >&2
      rm -f "$jp_snapshot"
      return 1
    fi
    rm -f "$jp_snapshot"
    echo "journal-migrate: cannot remove legacy file ($legacy); rolled back journal" >&2
    return 1
  fi
  rm -f "$jp_snapshot"

  # 5) Durability flush (best-effort platform guard: MSYS provides sync as a
  #    no-op that still returns 0; if a real sync exists and fails, fail closed).
  if command -v sync >/dev/null 2>&1; then
    if ! sync 2>/dev/null; then
      echo "journal-migrate: sync failed after migration" >&2
      return 1
    fi
  fi
  return 0
}

# ---- journal_verify_pairs <project_dir> -------------------------------------
# P0-1 STRICT PAIRING contract, validated INDEPENDENTLY by both journal_recover
# and journal_replay — a committed partner NEVER causes the check to be skipped:
#   duplicate op_key    — an op_key appearing on >1 pending or >1 commit line
#   duplicate_pending   — the same op_key on >1 pending line
#   duplicate_commit    — the same op_key on >1 commit line
#   commit_without_pending — a commit whose op_key has no pending partner
#   pending_no_revision — a mutation pending whose revision is not a non-null
#                         integer
#   pending_no_expected_sha — a complete pair whose effective expected_post_sha
#                         is missing/invalid. Effective = pending.expected_post_sha
#                         if a valid 64-hex string, else the recovery_backfill
#                         record appended by journal_backfill_legacy_pending
#                         (the ONLY legitimate way a legacy pair satisfies the
#                         contract — P0-1.7).
#   sha_after_mismatch  — commit.feature_list_sha_after is not a valid 64-hex
#                         sha or is not BYTE-EQUAL to the pair's effective
#                         expected_post_sha.
# ORPHAN pendings (pending with no commit partner) are NOT violations here —
# journal_recover resolves them via three-way recovery and journal_replay
# rejects them with its own orphan_pending check.
# Returns 0 (valid) or 1 (violation). On 1 echoes a short reason token on STDOUT
# (consumed by replay/recover) and a detail line on stderr.
journal_verify_pairs() {
  local dir="$1"
  # Optional explicit journal path — journal_migrate_legacy validates a PROBE
  # file before committing; callers without a probe default to the canonical
  # journal.
  local jp; jp="${2:-$(journal_path "$dir")}"
  [ -f "$jp" ] || return 0
  local reason jq_rc jq_out
  # -s (slurp): the journal is NDJSON; the pairing contract is CROSS-LINE, so the
  # whole file must be evaluated as one array (without -s jq would evaluate the
  # program per line and never see duplicates/withouts).
  # Codex r4: a corrupt NDJSON line would cause jq to fail (exit != 0) and
  # print nothing on stdout; the previous `2>/dev/null` swallowed the error
  # message and the function silently returned valid. Fail-CLOSED: capture
  # jq's exit code and any stdout, and treat any non-zero exit OR empty output
  # against a non-empty file as a `journal_corrupt` violation. A journal that
  # we cannot parse cannot be trusted to be a valid pairing record.
  jq_out="$(jq -rs '
    [ .[] | select(.pending == true) ] as $pend
    | [ .[] | select(.op == "commit" and .pending == false) ] as $comm
    | [ $pend[].op_key ] as $pk
    | [ $comm[].op_key ] as $ck
    | (([$pk | group_by(.)[] | select(length > 1) | .[0]] | length) > 0) as $dupP
    | (([$ck | group_by(.)[] | select(length > 1) | .[0]] | length) > 0) as $dupC
    | (([$ck[] | select(($pk | index(.)) == null)] | length) > 0) as $noP
    | ([ .[] | select(.op == "recovery_backfill") ]) as $bfAll
    | (([$bfAll | group_by(.op_key)[] | select(length > 1) | .[0].op_key] | length) > 0) as $dupBf
    | ([ $bfAll | map({key:.op_key, value:.expected_post_sha}) | from_entries] | add // {}) as $bf
    | ([ $pk[] as $k
         | select(($ck | index($k)) != null)
         | ([ $pend[] | select(.op_key == $k) ][0]) as $p
         | ([ $comm[] | select(.op_key == $k) ][0]) as $c
         | (($p.expected_post_sha // $bf[$k] // null) as $eff
            | ($eff == null or (($eff | type) != "string") or (($eff | length) != 64)
               or (($eff | test("^[0-9a-fA-F]{64}$")) | not))) as $badEff
         | (($p.revision | type) != "number") as $badRev
         | (((($c.feature_list_sha_after | type) != "string")
             or (($c.feature_list_sha_after | length) != 64)
             or (($c.feature_list_sha_after | test("^[0-9a-fA-F]{64}$")) | not))
            or ($c.feature_list_sha_after != ($p.expected_post_sha // $bf[$k]))) as $badPair
         | select($badEff or $badRev or $badPair)
         | {badEff:$badEff, badRev:$badRev, badPair:$badPair} ]) as $bad
    | ([ $bad[] | select(.badRev) ] | length) as $nRev
    | ([ $bad[] | select(.badEff) ] | length) as $nEff
    | ([ $bad[] | select(.badPair and (.badEff | not)) ] | length) as $nPair
    | if $dupP then "duplicate_pending"
      elif $dupC then "duplicate_commit"
      elif $dupBf then "duplicate_backfill"
      elif $noP then "commit_without_pending"
      elif ($nRev > 0) then "pending_no_revision"
      elif ($nEff > 0) then "pending_no_expected_sha"
      elif ($nPair > 0) then "sha_after_mismatch"
      else "" end' "$jp" 2>/dev/null)"
  jq_rc=$?
  reason="$(printf '%s' "$jq_out" | tr -d '\r')"
  # Codex r4: fail-closed on jq parse error. A journal we cannot parse cannot
  # be trusted as a valid pairing record. The same fail-closed rule covers
  # an empty journal (zero non-blank lines) — `jq -rs` over an empty input
  # succeeds with stdout `[]`-empty and reason "", which the old code treated
  # as valid. An empty journal is a meaningless audit trail: reject so a
  # tampered or zero-content journal cannot pass.
  if [ "$jq_rc" -ne 0 ]; then
    echo "journal-verify-pairs: journal_corrupt (jq parse error, rc=$jq_rc)" >&2
    printf '%s' "journal_corrupt"
    return 1
  fi
  if [ -z "$reason" ]; then
    # Cross-check: a journal whose every line parsed but that contained zero
    # non-blank lines is corrupt by design (NDJSON that is fully empty passes
    # `jq -rs` as `[]`, no violation, and silently accepts what is in fact no
    # audit trail at all). Distinguish "valid empty array" from "missing or
    # blank-only file" by counting non-blank lines; both must agree — `0` ⇒
    # journal_corrupt (the gate must never trust a zero-line audit trail).
    local nonempty
    nonempty="$(grep -c '[^[:space:]]' "$jp" 2>/dev/null | tr -d '\r' || true)"
    if [ "${nonempty:-0}" = "0" ]; then
      echo "journal-verify-pairs: journal_corrupt (zero non-blank lines)" >&2
      printf '%s' "journal_corrupt"
      return 1
    fi
  fi
  if [ -n "$reason" ]; then
    echo "journal-verify-pairs: $reason" >&2
    printf '%s' "$reason"
    return 1
  fi
  return 0
}

# ---- journal_backfill_legacy_pending <project_dir> ---------------------------
# P0-1.7 EXPLICIT legacy recovery (append-only, deterministic, never fabricated):
# a pending line written by pre-Contract-3 code carries no expected_post_sha.
# For every such mutation pending that HAS a committed partner, derive the
# effective expected post-state SHA from the partner commit's
# feature_list_sha_after (the ACTUAL sha of the post-state that was written and
# is already bound in the append-only chain) and append a recovery_backfill
# record documenting the derivation. This is the ONLY way a legacy pair may
# satisfy the strict contract; a pending with no commit is left for three-way
# recover; a pair that still cannot be made compliant is left for
# journal_verify_pairs to block. Idempotent: skips op_keys that already carry
# expected_post_sha or an existing recovery_backfill record.
journal_backfill_legacy_pending() {
  local dir="$1"
  # Optional explicit journal path — journal_migrate_legacy backfills a PROBE
  # file before committing; callers without a probe default to the canonical
  # journal.
  local jp; jp="${2:-$(journal_path "$dir")}"
  [ -f "$jp" ] || return 0
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
  local keys
  # -s (slurp): the journal is NDJSON; the backfill decision needs the WHOLE file
  # (which op_keys already carry expected_post_sha or a backfill record).
  keys="$(jq -rs '
    [ .[] | select(.op == "recovery_backfill") | .op_key ] as $bfk
    | [ .[] | select(.pending == true) ] as $pend
    | [ .[] | select(.op == "commit" and .pending == false) ] as $comm
    | [ $pend[].op_key ] as $pk | [ $comm[].op_key ] as $ck
    | [ $pk[] as $k
        | select(($ck | index($k)) != null)
        | ([ $pend[] | select(.op_key == $k) ][0]) as $p
        | select(($p.expected_post_sha == null) or ($p.expected_post_sha == ""))
        | select(($bfk | index($k)) == null)
        | $k ] | .[]' "$jp" 2>/dev/null | tr -d '\r')"
  local key
  while IFS= read -r key; do
    key="${key%$'\r'}"
    [ -z "$key" ] && continue
    local sha
    sha="$(jq -r --arg k "$key" 'select(.op_key == $k and .op == "commit" and .pending == false) | .feature_list_sha_after' "$jp" 2>/dev/null | tr -d '\r' | tail -1)"
    [ -z "$sha" ] && continue
    local rec
    rec="$(jq -cn --arg ts "$ts" --arg k "$key" --arg sha "$sha" \
      '{ts:$ts, op:"recovery_backfill", op_key:$k, expected_post_sha:$sha,
        reason:"legacy pending lacked expected_post_sha — derived from committed feature_list_sha_after (deterministic, not fabricated)"}')"
    printf '%s\n' "$rec" >> "$jp" 2>/dev/null || {
      echo "journal-backfill: cannot append recovery_backfill for $key" >&2
      return 1
    }
  done <<<"$keys"
  return 0
}

# ---- journal_replay <project_dir> <recorded_doc> ----------------------------
# PROVES that the current feature_list.json is the recorded snapshot plus a
# chain of PER-REVISION LEGAL SINGLE-EDGE mutations, all evidenced by the
# append-only journal. This REPLACES the transitive-reachability check of the
# prior validate_registry_transition: a `not_started rev1 → passing rev2` jump
# is REJECTED because there is no single legal edge for it.
#
# Returns 0 (proven) or 1 (rejected). On rejection prints a short reason token
# to STDOUT (consumed by validate_registry_transition) and a detail line to
# stderr. Reason tokens: no_journal, recorded_schema, missing_current,
# current_schema, recorded_sha_missing, orphan_pending, no_mutations,
# sha_chain_gap, tail_sha_mismatch, recorded_sha_unanchored, add_existing,
# add_not_not_started, status_unknown_feature, state_mismatch,
# illegal_status_transition, evidence_unknown_feature, evidence_run_id_missing,
# unknown_op, revision_mismatch, final_state_mismatch, evidence_run_id_mismatch.
#
# Proof outline (all fail-closed):
#   (1) canonical schema of BOTH documents
#   (2) the recorded snapshot's feature_list.json SHA must ANCHOR into the
#       journal's sha chain — a snapshot whose file state appears nowhere in
#       the chain cannot be the product of the journaled mutations (a direct
#       edit / fabrication cannot anchor)
#   (3) the sha chain is CONTIGUOUS: mutations[i].sha_before ==
#       mutations[i-1].sha_after, and the tail equals the CURRENT file sha
#   (4) replaying the mutations AFTER the recorded anchor through the feature
#       state machine (starting from the recorded features) must yield the
#       CURRENT registry: each status op's `from` must equal the accumulated
#       state, each from→to must be a SINGLE legal edge (deprecated has NO
#       outgoing edges), adds create features at not_started,
#       evidence_associate cannot touch an unknown feature.
_journal_legal_edge() {
  local from="$1" to="$2"
  case "$from:$to" in
    not_started:in_progress|not_started:blocked|not_started:deprecated|\
    in_progress:passing|in_progress:blocked|in_progress:unverified|in_progress:deprecated|\
    blocked:in_progress|blocked:unverified|blocked:deprecated|\
    passing:in_progress|passing:deprecated|\
    unverified:in_progress|unverified:deprecated) return 0 ;;
    *) return 1 ;;
  esac
}

journal_replay() {
  local dir="$1"
  local recorded_doc="$2"
  local jp; jp="$(journal_path "$dir")"
  [ -f "$jp" ] || { echo "journal-replay: no journal file" >&2; echo "no_journal"; return 1; }

  # (1) schema both documents
  validate_feature_registry_json "$recorded_doc" "$dir" >/dev/null 2>&1 \
    || { echo "journal-replay: recorded_doc failed canonical schema" >&2; echo "recorded_schema"; return 1; }
  local cur_fl="$dir/feature_list.json"
  [ -f "$cur_fl" ] || { echo "journal-replay: feature_list.json missing" >&2; echo "missing_current"; return 1; }
  validate_feature_registry "$cur_fl" "$dir" >/dev/null 2>&1 \
    || { echo "journal-replay: current registry failed canonical schema" >&2; echo "current_schema"; return 1; }

  local cur_sha rec_sha
  cur_sha="$(sha256_file "$cur_fl")"
  rec_sha="$(printf '%s' "$recorded_doc" | jq -r '."_recorded_sha" // ""')"

  if [ -z "$rec_sha" ]; then
    echo "journal-replay: recorded_doc carries no _recorded_sha (cannot anchor)" >&2
    echo "recorded_sha_missing"
    return 1
  fi

  # Fail-closed on orphaned pending lines (no committed partner). These should
  # only exist transiently and be cleaned by journal_recover; if one survived,
  # the chain is ambiguous. Codex item 3 — APPEND-ONLY: an op_key that carries
  # a recovery_backout record is NOT an orphan; the backout marker means
  # journal_recover already concluded the mutation never happened and the line was
  # intentionally retained in the audit trail. Only op_keys with NO commit
  # partner AND NO recovery_backout record are orphans.
  local orphan
  orphan="$(jq -rn --slurpfile j "$jp" '
    ( $j | [.[] | select(.op == "commit")] | map(.op_key) ) as $cks
    | ( $j | [.[] | select(.op == "recovery_backout")] | map(.op_key) ) as $bks
    | [ $j[] | select(.pending == true and (.op == "add" or .op == "status" or .op == "evidence_associate"))
        | .op_key as $k
        | select(($cks | index($k)) == null)
        | select(($bks | index($k)) == null) | $k ] | .[0]' 2>/dev/null)"
  if [ -n "$orphan" ] && [ "$orphan" != "null" ]; then
    echo "journal-replay: orphaned pending mutation op_key=$orphan (run journal_recover)" >&2
    echo "orphan_pending"
    return 1
  fi

  # P0-1 STRICT PAIRING (runs BEFORE mutation extraction): every complete
  # pending+commit pair must satisfy the contract — no duplicate op_key/pending/
  # commit, no commit-without-pending, a non-null valid expected_post_sha per
  # pair (own binding OR recovery_backfill record), and commit.sha_after
  # BYTE-EQUAL to it. This must run before from_entries so duplicate commits can
  # never be silently deduped.
  local vreason
  if ! vreason="$(journal_verify_pairs "$dir")"; then
    echo "journal-replay: strict pairing violation ($vreason)" >&2
    echo "$vreason"
    return 1
  fi

  # Codex item 1 — CONDITIONAL early-return AFTER strict checks: if the recorded
  # snapshot equals the current file AND the strict orphan + pairing checks
  # pass, there are zero mutations to walk. Returning rc 0 here is safe (the
  # strict checks already proved the journal is well-formed), and it prevents a
  # spurious "no_mutations" error on legitimately-unchanged registries (e.g.
  # after a recovery_backout that left the file at the recorded state).
  if [ "$rec_sha" = "$cur_sha" ]; then
    return 0
  fi

  # (2)+(3) extract ordered mutations (pending+committed pairs by op_key) in
  # journal (append) order, then verify the sha chain. Codex item 3 — skip
  # op_keys with a recovery_backout record (they were intentionally preserved
  # but were never committed).
  local mutations
  mutations="$(jq -cn --slurpfile j "$jp" '
    ( $j | [.[] | select(.op == "commit")] | map({key:.op_key, value:.feature_list_sha_after}) | from_entries ) as $after
    | ( $j | [.[] | select(.op == "recovery_backout")] | map(.op_key) ) as $bks
    | [ $j[] | select(.pending == true and (.op == "add" or .op == "status" or .op == "evidence_associate"))
        | .op_key as $k
        | select($after[$k] != null)
        | select(($bks | index($k)) == null)
        | {op, feature_id, from, to, revision, run_id,
           sha_before:.feature_list_sha_before,
           sha_after:$after[$k]} ]' 2>/dev/null)"
  if [ -z "$mutations" ]; then
    echo "journal-replay: failed to extract mutations from journal" >&2
    echo "no_mutations"
    return 1
  fi

  local n
  n="$(printf '%s' "$mutations" | jq 'length')"
  if [ "$n" = "0" ]; then
    echo "journal-replay: feature_list.json changed with zero journaled mutations" >&2
    echo "no_mutations"
    return 1
  fi

  # Chain contiguity: mutations[i].sha_before == mutations[i-1].sha_after.
  local prev="" idx=0 sb sa m
  while IFS= read -r m; do
    sb="$(printf '%s' "$m" | jq -r '.sha_before // ""')"
    sa="$(printf '%s' "$m" | jq -r '.sha_after // ""')"
    [ -z "$sb" ] && sb="null"
    [ -z "$sa" ] && sa="null"
    if [ -n "$prev" ] && [ "$sb" != "$prev" ]; then
      echo "journal-replay: sha chain gap at mutation $idx ($sb != $prev)" >&2
      echo "sha_chain_gap"
      return 1
    fi
    prev="$sa"
    idx=$((idx + 1))
  done < <(printf '%s' "$mutations" | jq -c '.[]')

  # Tail: the last mutation's sha_after must equal the current file sha.
  if [ "$prev" != "$cur_sha" ]; then
    echo "journal-replay: journal tail sha does not match current feature_list.json" >&2
    echo "tail_sha_mismatch"
    return 1
  fi

  # Anchor the recorded snapshot into the chain. start = index of the first
  # mutation AFTER the recorded snapshot (genesis when rec_sha == chain[0].sha_before).
  local start=0 k
  if [ "$rec_sha" != "$(printf '%s' "$mutations" | jq -r '.[0].sha_before // ""')" ]; then
    k="$(printf '%s' "$mutations" | jq -r --arg s "$rec_sha" \
      '. as $arr | [ range(0; $arr|length) | select($arr[.].sha_after == $s) ] | (.[0] // -1)')"
    if [ "$k" = "-1" ]; then
      echo "journal-replay: recorded snapshot sha not anchored in journal chain" >&2
      echo "recorded_sha_unanchored"
      return 1
    fi
    start=$((k + 1))
  fi
  # NOTE: start >= n is unreachable here — the tail check above requires the
  # last sha_after == cur_sha, so rec_sha == mutations[n-1].sha_after would imply
  # rec_sha == cur_sha and the equality early-return already fired.

  # (4) per-revision state-machine replay from the recorded features.
  local -A st=()
  local fid fst
  # MSYS jq emits CRLF from @tsv; `read` keeps the \r in the last field and
  # would corrupt every stored status (breaking the from/final comparisons).
  # Strip CR from the stream.
  while IFS=$'\t' read -r fid fst; do
    [ -n "$fid" ] && st["$fid"]="$fst"
  done < <(printf '%s' "$recorded_doc" | jq -r '.features[] | [.id,.status] | @tsv' | tr -d '\r')

  # Contract 2 (STRONG binding, P0-2): accumulate, per feature, the ORDERED
  # evidence run_ids the journal PROVES were appended — seeded from the recorded
  # snapshot, extended only by evidence_associate mutations — as a STRUCTURED
  # JSON ARRAY (never a whitespace-joined string). The final accumulated array
  # must EXACTLY equal (order + content) the CURRENT registry's evidence run_id
  # array. This rejects forged/replaced/whitespace-mangled run_ids: "r-1" can
  # never match "r-1 forged" because arrays are compared element-for-element
  # with no tokenization, word-splitting, or prefix semantics.
  local -A acc_ev=()
  while IFS=$'\t' read -r fid evarr; do
    [ -n "$fid" ] && acc_ev["$fid"]="$evarr"
  done < <(printf '%s' "$recorded_doc" | jq -r '.features[] |
      .id + "\t" + (([.evidence_associations[]?.run_id // empty]
        + [.evidence_run_ids[]? | if type == "string" then . else (.run_id // empty) end]) | tostring)' | tr -d '\r')

  # P0-M2 per-revision auditability: every CLI mutation advances the registry
  # revision by exactly +1 and journals that target revision. During replay,
  # each post-anchor mutation must carry the exact revision it produced
  # (recorded_revision + ordinal) — a journal line claiming a different revision
  # cannot have produced the recorded→current transition (fabrication), even if
  # the content-addressed sha chain happens to be contiguous.
  local idx2=0 op from to m_rev expected_rev rec_rev
  rec_rev="$(printf '%s' "$recorded_doc" | jq -r '.revision // 0')"
  while IFS= read -r m; do
    if [ "$idx2" -lt "$start" ]; then idx2=$((idx2 + 1)); continue; fi
    # Contract 1 (fail-closed): revision must be a REAL integer (null / string /
    # float are rejected) and must strictly equal anchor revision + ordinal.
    m_rev_type="$(printf '%s' "$m" | jq -r '.revision | if . == null then "null" else type end')"
    m_rev="$(printf '%s' "$m" | jq -r '.revision // null')"
    expected_rev=$((rec_rev + idx2 - start + 1))
    if [ "$m_rev_type" != "number" ] || [ "$m_rev" != "$expected_rev" ]; then
      echo "journal-replay: revision mismatch at mutation $idx2 (journal=$m_rev type=$m_rev_type, expected=$expected_rev)" >&2
      echo "revision_mismatch"
      return 1
    fi
    op="$(printf '%s' "$m" | jq -r '.op // ""')"
    fid="$(printf '%s' "$m" | jq -r '.feature_id // ""')"
    from="$(printf '%s' "$m" | jq -r '.from // ""')"
    to="$(printf '%s' "$m" | jq -r '.to // ""')"
    case "$op" in
      add)
        [ -n "$fid" ] || { echo "journal-replay: add op missing feature_id" >&2; echo "unknown_op"; return 1; }
        if [ -n "${st[$fid]+set}" ]; then
          echo "journal-replay: add for existing feature $fid" >&2; echo "add_existing"; return 1
        fi
        if [ "$to" != "not_started" ]; then
          echo "journal-replay: add for $fid must create at not_started (got $to)" >&2
          echo "add_not_not_started"; return 1
        fi
        st["$fid"]="not_started"
        ;;
      status)
        local cur="${st[$fid]-}"
        if [ -z "$cur" ]; then
          echo "journal-replay: status for unknown feature $fid" >&2; echo "status_unknown_feature"; return 1
        fi
        if [ "$cur" != "$from" ]; then
          echo "journal-replay: state mismatch for $fid (state=$cur, journal from=$from)" >&2
          echo "state_mismatch"; return 1
        fi
        if ! _journal_legal_edge "$from" "$to"; then
          echo "journal-replay: illegal single-edge $from → $to for $fid" >&2
          echo "illegal_status_transition"; return 1
        fi
        st["$fid"]="$to"
        ;;
      evidence_associate)
        [ -n "$fid" ] || { echo "journal-replay: evidence_associate missing feature_id" >&2; echo "unknown_op"; return 1; }
        if [ -z "${st[$fid]+set}" ]; then
          echo "journal-replay: evidence_associate for unknown feature $fid" >&2
          echo "evidence_unknown_feature"; return 1
        fi
        # The journal's run_id must be a non-empty string (null → contract 1/2 reject).
        # CR-strip: jq raw output on MSYS emits CRLF; a trailing \r would corrupt
        # the array element and false-mismatch every exact comparison.
        local m_run
        m_run="$(printf '%s' "$m" | jq -r '.run_id // ""' | tr -d '\r')"
        if [ -z "$m_run" ] || [ "$m_run" = "null" ]; then
          echo "journal-replay: evidence_associate for $fid missing run_id" >&2
          echo "evidence_run_id_missing"; return 1
        fi
        # Append to the structured array (order-preserving) — never string-join.
        acc_ev["$fid"]="$(printf '%s' "${acc_ev[$fid]:-[]}" | jq -c --arg r "$m_run" '. + [$r]')"
        ;;
      *)
        echo "journal-replay: unknown journal op '$op'" >&2; echo "unknown_op"; return 1
        ;;
    esac
    idx2=$((idx2 + 1))
  done < <(printf '%s' "$mutations" | jq -c '.[]')

  # Final state must equal the CURRENT registry's features (id → status).
  # Both sides are canonicalized (compact + sorted keys) because the replayed
  # map iterates in assoc-array order while the current file keeps its own
  # feature order — a raw string compare would false-negative on key order.
  local rep_json cur_json
  rep_json="$(for fid in "${!st[@]}"; do printf '%s\t%s\n' "$fid" "${st[$fid]}"; done \
    | jq -R -s -c 'split("\n") | map(select(length > 0)) | map(split("\t") | {key:.[0], value:.[1]}) | from_entries')"
  cur_json="$(jq -c '[(.features[] | {id, status})] | map({key:.id, value:.status}) | from_entries' "$cur_fl" 2>/dev/null)"
  if [ "$(printf '%s' "$rep_json" | jq -S -c .)" != "$(printf '%s' "$cur_json" | jq -S -c .)" ]; then
    echo "journal-replay: replayed state does not equal current registry" >&2
    echo "final_state_mismatch"
    return 1
  fi

  # Contract 2 tail check (EXACT binding, P0-2): the journal-proven evidence
  # run_id accumulation (recorded snapshot + each evidence_associate run_id, in
  # order) is a STRUCTURED JSON ARRAY; the CURRENT registry's per-feature
  # evidence run_ids must be BYTE-EQUAL (order + content, compact JSON string
  # equality) to it. No whitespace joining, no shell word-splitting, no token
  # prefix: "r-1" can never match "r-1 forged". The exact match is mandatory —
  # a forged/replaced/extra/whitespace-mangled run_id → evidence_run_id_mismatch.
  local -A cur_ev=()
  while IFS=$'\t' read -r fid evarr; do
    [ -n "$fid" ] && cur_ev["$fid"]="$evarr"
  done < <(jq -r '.features[] |
      .id + "\t" + (([.evidence_associations[]?.run_id // empty]
        + [.evidence_run_ids[]? | if type == "string" then . else (.run_id // empty) end]) | tostring)' "$cur_fl" 2>/dev/null | tr -d '\r')

  local fid_ev
  for fid_ev in "${!acc_ev[@]}" "${!cur_ev[@]}"; do
    if [ "${acc_ev[$fid_ev]:-[]}" != "${cur_ev[$fid_ev]:-[]}" ]; then
      echo "journal-replay: journal-proven evidence run_ids do not EXACTLY equal current registry for $fid_ev" >&2
      echo "evidence_run_id_mismatch"
      return 1
    fi
  done

  return 0
}