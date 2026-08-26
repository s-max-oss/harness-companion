#!/bin/bash
# validate-feature-registry.sh — Feature registry schema/status/revision/WIP validator
#
# Canonical validation for feature_list.json (used by init.sh check 3 and by
# tests). Validates, all FAIL-CLOSED:
#   - file exists and parses as a JSON object
#   - revision: non-negative integer
#   - features: non-empty array
#   - per-feature id: string matching ^[A-Z][A-Z0-9_-]*$ (repo convention:
#     uppercase-leading, e.g. F-CONV-01), unique
#   - per-feature status: one of not_started|in_progress|blocked|passing|
#     unverified|deprecated (frozen design §10)
#   - evidence_associations / legacy_audit_evidence: arrays
#   - passing requires non-empty evidence_associations (passing needs evidence)
#   - WIP: count(in_progress) <= wip_limit (.harness/config.json, default 1)
#
# A bare JSON parse is NOT a schema validation — this is the registry's own
# validator, mirroring config-validate.sh / validate-run-log.sh style.
#
# Usage:
#   source validate-feature-registry.sh
#   validate_feature_registry <feature_list.json> [project_dir]
#
# Returns 0 (valid) or 1 (invalid); diagnostics to stderr.

# P0-M2: registry-journal.sh carries the mutation journal + replay (P0-M2
# replaces the prior transitive-reachability check). The validate-
# feature-registry.sh file is sourced by harness-feature.sh before the journal
# is loaded, so we lazy-source here.
_journal_loaded=0
_ensure_journal_loaded() {
  if [ "$_journal_loaded" = "1" ]; then return 0; fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$here/registry-journal.sh" ]; then
    # shellcheck source=registry-journal.sh
    source "$here/registry-journal.sh"
  fi
  _journal_loaded=1
}

validate_feature_registry() {
  local fl="${1:?validate_feature_registry: feature_list.json path required}"
  local project_dir="${2:-.}"

  if [ ! -f "$fl" ]; then
    echo "validate-feature-registry: feature_list.json missing: $fl" >&2
    return 1
  fi
  local doc
  doc="$(cat "$fl" 2>/dev/null)" || { echo "validate-feature-registry: cannot read $fl" >&2; return 1; }
  validate_feature_registry_json "$doc" "$project_dir"
}

# validate_feature_registry_json <doc> [project_dir] — the JSON-document core of
# validate_feature_registry. Applies the identical canonical checks to an
# in-memory registry document, so the dirty-worktree manifest gate (P0-10) can
# validate recorded registry snapshots embedded in a manifest record without
# materializing them to disk.
validate_feature_registry_json() {
  local doc="${1:?validate_feature_registry_json: registry JSON document required}"
  local project_dir="${2:-.}"

  if ! printf '%s' "$doc" | jq -e '.' >/dev/null 2>&1; then
    echo "validate-feature-registry: feature_list.json is not valid JSON" >&2
    return 1
  fi
  if ! printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "validate-feature-registry: top level must be a JSON object" >&2
    return 1
  fi

  # ---- revision: non-negative integer ----
  if ! printf '%s' "$doc" | jq -e '(.revision | type) == "number" and .revision >= 0 and ((.revision | floor) == .revision)' >/dev/null 2>&1; then
    echo "validate-feature-registry: revision must be a non-negative integer" >&2
    return 1
  fi

  # ---- features: non-empty array ----
  if ! printf '%s' "$doc" | jq -e '(.features | type) == "array" and (.features | length) >= 1' >/dev/null 2>&1; then
    echo "validate-feature-registry: features must be a non-empty array" >&2
    return 1
  fi

  # ---- id format ----
  if ! printf '%s' "$doc" | jq -e '[.features[].id] | all(.[]; (type == "string") and test("^[A-Z][A-Z0-9_-]*$"))' >/dev/null 2>&1; then
    echo "validate-feature-registry: feature id must match ^[A-Z][A-Z0-9_-]*$ (e.g. F-CONV-01)" >&2
    return 1
  fi

  # ---- id uniqueness ----
  local dup
  dup="$(printf '%s' "$doc" | jq -r '[.features[].id] | group_by(.)[] | select(length > 1) | .[0]' 2>/dev/null | head -1)"
  if [ -n "$dup" ]; then
    echo "validate-feature-registry: duplicate feature id: $dup" >&2
    return 1
  fi

  # ---- status enum ----
  if ! printf '%s' "$doc" | jq -e '[.features[].status] | all(.[]; . == "not_started" or . == "in_progress" or . == "blocked" or . == "passing" or . == "unverified" or . == "deprecated")' >/dev/null 2>&1; then
    echo "validate-feature-registry: feature status must be one of not_started|in_progress|blocked|passing|unverified|deprecated" >&2
    return 1
  fi

  # ---- evidence arrays ----
  if ! printf '%s' "$doc" | jq -e '[.features[] | (.evidence_associations | type) == "array"] | all(.[]; .)' >/dev/null 2>&1; then
    echo "validate-feature-registry: each feature requires evidence_associations (array)" >&2
    return 1
  fi
  if ! printf '%s' "$doc" | jq -e '[.features[] | (.legacy_audit_evidence | type) == "array"] | all(.[]; .)' >/dev/null 2>&1; then
    echo "validate-feature-registry: each feature requires legacy_audit_evidence (array)" >&2
    return 1
  fi

  # ---- Contract 2: per-item evidence_associations structure (fail-closed) ----
  # Every association item must be either a legacy string OR an OBJECT whose
  # run_id is a NON-EMPTY STRING. Rejects [{}], empty run_id, and wrong-type
  # (number/object/null) run_id. An empty [] is allowed (no evidence).
  # legacy_audit_evidence is left permissive (its items may be plain strings).
  if ! printf '%s' "$doc" | jq -e '[.features[].evidence_associations[]? |
      ((type == "string")
       or ((type == "object") and ((.run_id | type) == "string") and (.run_id | length > 0)))] | all(.[]; .)' >/dev/null 2>&1; then
    echo "validate-feature-registry: every evidence_associations item must be a legacy string or an object with a non-empty string run_id" >&2
    return 1
  fi

  # ---- passing requires evidence ----
  local pass_no_ev
  pass_no_ev="$(printf '%s' "$doc" | jq -r '[.features[] | select(.status == "passing" and ((.evidence_associations // []) | length) == 0)] | length' 2>/dev/null)"
  if [ "$pass_no_ev" != "0" ]; then
    echo "validate-feature-registry: $pass_no_ev feature(s) marked passing without evidence_associations — passing requires evidence" >&2
    return 1
  fi

  # ---- WIP limit ----
  local wip_limit=1
  if [ -f "$project_dir/.harness/config.json" ]; then
    local cfg_wip
    cfg_wip="$(jq -r '.wip_limit // empty' "$project_dir/.harness/config.json" 2>/dev/null)"
    if [ -n "$cfg_wip" ] && [ "$cfg_wip" -gt 0 ] 2>/dev/null; then
      wip_limit="$cfg_wip"
    fi
  fi
  local in_prog
  in_prog="$(printf '%s' "$doc" | jq '[.features[] | select(.status == "in_progress")] | length' 2>/dev/null)"
  if [ "$in_prog" -gt "$wip_limit" ]; then
    echo "validate-feature-registry: WIP limit exceeded: $in_prog in_progress (limit $wip_limit)" >&2
    return 1
  fi

  return 0
}

# ---- status reachability (P0-10) ------------------------------------------
# True when <to> is REACHABLE from <from> through the TRANSITIVE CLOSURE of the
# feature state machine's single-step legal edges (core/harness-feature.sh
# `_is_allowed_transition`):
#   not_started → in_progress | blocked | deprecated
#   in_progress → passing | blocked | unverified | deprecated
#   blocked     → in_progress | unverified | deprecated
#   passing     → in_progress | deprecated
#   unverified  → in_progress | deprecated
#   deprecated  → (terminal — no outgoing edges)
# A status is trivially reachable from itself (zero-length path). A Phase may
# apply MULTIPLE legal mutations between two manifest snapshots, so the
# manifest contract (validate_registry_transition) accepts any reachable target
# — not just a single edge.
is_reachable_status_transition() {
  local from="$1" to="$2"
  case "$from:$to" in
    not_started:not_started|not_started:in_progress|not_started:blocked|not_started:deprecated|not_started:passing|not_started:unverified|\
    in_progress:in_progress|in_progress:passing|in_progress:blocked|in_progress:unverified|in_progress:deprecated|\
    blocked:blocked|blocked:in_progress|blocked:unverified|blocked:deprecated|blocked:passing|\
    passing:passing|passing:in_progress|passing:deprecated|passing:blocked|passing:unverified|\
    unverified:unverified|unverified:in_progress|unverified:deprecated|unverified:passing|unverified:blocked|\
    deprecated:deprecated) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- validate_registry_transition (P0-M2: journal-driven) ------------------
# validate_registry_transition <recorded_doc> <current_fl> [project_dir]
#
# P0-M2: the registry gate now proves per-revision legal mutation history via
# the APPEND-ONLY journal (.harness/registry-journal.ndjson) instead of end-
# point transitive reachability. The output shape is preserved so existing
# callers/tests can consume the same fields. A recorded snapshot + current
# registry is accepted only when:
#   (1) canonical schema of BOTH documents
#   (2) the journal exists, replays cleanly, and every status-changing
#       journal entry is a SINGLE legal edge (not_started→passing in one
#       step is REJECTED — was previously accepted by transitive closure)
#   (3) feature-set consistency: a recorded feature must still exist; a new
#       feature must start at not_started
#   (4) evidence APPEND-ONLY per feature
#   (5) revision CONSISTENCY: content-unchanged ⇒ revision-unchanged;
#       content-changed ⇒ revision ADVANCED. A revision jump with identical
#       content (fabrication) is rejected because the journal has no entry
#       for it (replay sha-mismatch).
#
# On success prints nothing and returns 0. On failure prints a one-line reason
# to stderr and returns 1.
validate_registry_transition() {
  local recorded_doc="${1:?validate_registry_transition: recorded registry doc required}"
  local current_fl="${2:?validate_registry_transition: current feature_list.json required}"
  local project_dir="${3:-.}"

  _ensure_journal_loaded

  # (1) canonical schema of both documents
  if ! validate_feature_registry_json "$recorded_doc" "$project_dir" >/dev/null 2>&1; then
    echo "validate-registry-transition: recorded registry failed canonical schema validation" >&2
    return 1
  fi
  if ! validate_feature_registry "$current_fl" "$project_dir" >/dev/null 2>&1; then
    echo "validate-registry-transition: current registry failed canonical schema validation" >&2
    return 1
  fi

  # Normalize both registries to {revision, features:[{id, status,
  # evidence_run_ids, legacy_evidence_run_ids}]} for shape compatibility with
  # existing tests and DWM callers.
  local rec_norm cur_norm
  rec_norm="$(printf '%s' "$recorded_doc" | jq -c '{revision:.revision, features:[.features[] | {id, status, evidence_run_ids:(.evidence_run_ids // [.evidence_associations[]?.run_id // empty]), legacy_evidence_run_ids:(.legacy_evidence_run_ids // [.legacy_audit_evidence[]?.run_id // empty])}]}')"
  cur_norm="$(jq -c '{revision:.revision, features:[.features[] | {id, status, evidence_run_ids:[.evidence_associations[]?.run_id // empty], legacy_evidence_run_ids:[.legacy_audit_evidence[]?.run_id // empty]}]}' "$current_fl")"

  # Feature-set consistency + evidence append-only + content-same signal
  # (independent of journal, kept so DWM callers still see the same shape).
  local shape_prog='
    def ev($f): [ ($f.evidence_run_ids // [])[]? | if type == "string" then . else (.run_id // empty) end ];
    def lev($f): [ ($f.legacy_evidence_run_ids // [])[]? | if type == "string" then . else (.run_id // empty) end ];
    def prefix($a; $b): $a == ($b[0:($a|length)]);
    ($rec.features | map({key:.id, value:.}) | from_entries) as $rb
    | ($cur.features | map({key:.id, value:.}) | from_entries) as $cb
    | [ $rb | to_entries[] | .key as $id | select($cb[$id] == null) | {feature:$id, violation:"feature_removed", detail:"feature_removed"} ] as $removed
    # NOTE: there is NO static "new feature must be not_started" rule here —
    # Contract 5: a feature absent from the recorded (early) snapshot may
    # legitimately end at ANY final status, PROVEN by the journal replay (add at
    # not_started → legal single edges). The replay rejects a feature added at a
    # non-not_started status (add_not_not_started) and a feature with no add
    # mutation at all (final_state_mismatch), so the static rule would only
    # FALSELY reject a legal early-snapshot → add → transition chain.
    | [ $rb | to_entries[] | .key as $id | select($cb[$id] != null)
        | ($rb[$id] as $r | $cb[$id] as $c
          | (select(((prefix(ev($r); ev($c))) | not) or ((prefix(lev($r); lev($c))) | not)) | {feature:$id, violation:"evidence_not_append_only", detail:"evidence_not_append_only"})) ] as $perfeat
    | ( (($rb | keys | sort) == ($cb | keys | sort))
        and ([ $rb | to_entries[] | .key as $id | ($rb[$id].status == $cb[$id].status) and (ev($rb[$id]) == ev($cb[$id])) and (lev($rb[$id]) == lev($cb[$id])) ] | all(.[]; .)) ) as $content_same
    | {
        shape_violations: ($removed + $perfeat),
        content_same: $content_same,
        recorded_revision: $rec.revision,
        current_revision: $cur.revision
      }
  '
  local shape
  shape="$(printf '%s' "$cur_norm" | jq -c --argjson rec "$rec_norm" --argjson cur "$cur_norm" "$shape_prog" 2>/dev/null)"
  if [ -z "$shape" ]; then
    echo "validate-registry-transition: shape check failed to run" >&2
    return 1
  fi

  # Journal-driven legal-mutation check (replaces transitive reachability).
  # If no journal exists, REJECT — recorded snapshots without a journal cannot
  # prove per-revision legal mutation history. journal_replay returns a short
  # reason token on STDOUT on failure (illegal_status_transition, sha_chain_gap,
  # recorded_sha_unanchored, ...) which we propagate into the violation detail.
  local journal_path="$project_dir/.harness/registry-journal.ndjson"
  local journal_reason="" jr_out=""
  if [ ! -f "$journal_path" ]; then
    journal_reason="missing"
  elif ! jr_out="$(journal_replay "$project_dir" "$recorded_doc" 2>/dev/null)"; then
    # journal_replay echoes a short reason token on STDOUT (illegal_status_
    # transition, sha_chain_gap, ...). Propagate the bare token; the violation
    # detail prefixes it with `journal_` exactly once.
    journal_reason="$(printf '%s' "$jr_out" | tail -1)"
    [ -z "$journal_reason" ] && journal_reason="replay_failed"
  fi

  # Revision consistency
  local content_same rec_rev cur_rev rev_ok
  content_same="$(printf '%s' "$shape" | jq -r '.content_same')"
  rec_rev="$(printf '%s' "$shape" | jq -r '.recorded_revision')"
  cur_rev="$(printf '%s' "$shape" | jq -r '.current_revision')"
  rev_ok="false"
  if [ "$content_same" = "true" ]; then
    [ "$cur_rev" = "$rec_rev" ] && rev_ok="true"
  else
    if [ "$cur_rev" -gt "$rec_rev" ] 2>/dev/null; then rev_ok="true"; fi
  fi

  # Aggregate: shape violations first, then revision_consistency (when the
  # revision did not advance correctly), then the journal verdict. Every
  # violation carries a `detail` so callers/tests can assert the specific cause.
  local violations
  violations="$(printf '%s' "$shape" | jq -c '.shape_violations')"

  local valid_json
  valid_json="$(jq -cn \
    --argjson rev_ok "$( [ "$rev_ok" = 'true' ] && echo true || echo false )" \
    --arg jr "$journal_reason" \
    --argjson violations "$violations" \
    --arg rs "$rec_rev" --arg cs "$cur_rev" --argjson csame "$content_same" \
    '{
       valid: (($rev_ok == true) and ($jr == "") and (($violations | length) == 0)),
       violations: ($violations
         + (if ($rev_ok == true) then [] else [{violation:"revision_consistency", detail:"revision_consistency"}] end)
         + (if ($jr != "") then [{violation:"illegal_registry_transition", detail:("journal_\($jr)")}] else [] end)),
       content_same: $csame,
       recorded_revision: ($rs|tonumber),
       current_revision: ($cs|tonumber)
     }')"

  if [ "$(printf '%s' "$valid_json" | jq -r '.valid')" = "true" ]; then
    return 0
  fi

  local first
  first="$(printf '%s' "$valid_json" | jq -c '.violations[0] // {violation:"revision_consistency", detail:"revision_consistency"}')"
  local detail
  detail="$(printf '%s' "$first" | jq -r '.detail // empty')"
  local head
  head="$(printf '%s' "$first" | jq -rc 'if .feature then "\(.violation) feature=\(.feature)" else .violation end')"
  echo "validate-registry-transition: $head$([ -n "$detail" ] && echo " detail=$detail") (recorded_revision=$rec_rev, current_revision=$cur_rev, content_same=$content_same)" >&2
  return 1
}
