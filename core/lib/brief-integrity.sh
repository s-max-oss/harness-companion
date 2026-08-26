#!/bin/bash
# brief-integrity.sh — Acyclic Brief/snapshot integrity validator
#
# Validates the PROJECT_BRIEF.json + PROJECT_BRIEF.md + .template-snapshot.json
# triple (used by init.sh check 9). All checks FAIL-CLOSED:
#   - PROJECT_BRIEF.json parses as an object, schema_version == 1
#   - PROJECT_BRIEF.md exists (human rendering, spec §7.4 / AC-11)
#   - MD header parity: schema_version / source_version tokens match the JSON,
#     and the MD's captured git rev token is a prefix of the JSON's
#     captured_from_git_rev (spec §7.4 out-of-sync detection)
#   - .template-snapshot.json parses as an object, schema_version == 1
#   - digest: PROJECT_BRIEF.json.template_manifest_digest ==
#     sha256(.template-snapshot.json)  (digest = hash of snapshot file)
#   - ACYCLIC: the snapshot's template manifest MUST NOT reference
#     PROJECT_BRIEF.json or PROJECT_BRIEF.md. If it did, the Brief digest
#     (derived from the snapshot) would depend on the snapshot's hash of the
#     Brief — a self-referential cycle. The Brief/snapshot pair is verified by
#     presence + digest + parity, never by being a snapshot template.
#
# A bare JSON parse is NOT a schema validation — this is the repo's own
# validator, mirroring config-validate.sh / validate-run-log.sh style.
#
# Usage:
#   source brief-integrity.sh
#   validate_brief_integrity [project_dir]
#
# Returns 0 (valid) or 1 (invalid); diagnostics to stderr.

validate_brief_integrity() {
  local project_dir="${1:-.}"
  local brief_json="$project_dir/.harness/PROJECT_BRIEF.json"
  local brief_md="$project_dir/.harness/PROJECT_BRIEF.md"
  local snapshot="$project_dir/.harness/.template-snapshot.json"

  # ---- PROJECT_BRIEF.json exists, parses, schema_version == 1 ----
  if [ ! -f "$brief_json" ]; then
    echo "brief-integrity: PROJECT_BRIEF.json missing: $brief_json" >&2
    return 1
  fi
  if ! jq -e 'type == "object" and .schema_version == 1' "$brief_json" >/dev/null 2>&1; then
    echo "brief-integrity: PROJECT_BRIEF.json must be an object with schema_version == 1" >&2
    return 1
  fi
  local src_rev src_version src_schema
  src_rev="$(jq -r '.captured_from_git_rev // ""' "$brief_json" 2>/dev/null)"
  src_version="$(jq -r '.source_version // ""' "$brief_json" 2>/dev/null)"
  src_schema="$(jq -r '.schema_version // ""' "$brief_json" 2>/dev/null)"
  if [ -z "$src_rev" ] || [ -z "$src_version" ]; then
    echo "brief-integrity: PROJECT_BRIEF.json requires captured_from_git_rev and source_version" >&2
    return 1
  fi

  # ---- PROJECT_BRIEF.md presence ----
  if [ ! -f "$brief_md" ]; then
    echo "brief-integrity: PROJECT_BRIEF.md missing (human rendering required, spec §7.4/AC-11)" >&2
    return 1
  fi

  # ---- MD header parity (schema_version / source_version / git rev) ----
  local md_ok=true
  if ! grep -qF "schema_version=$src_schema" "$brief_md" >/dev/null 2>&1 \
     || ! grep -qF "source_version=$src_version" "$brief_md" >/dev/null 2>&1; then
    md_ok=false
  fi
  # captured rev: MD must carry a git-rev token that is a PREFIX of the JSON rev
  # (MD may use the full 40-hex or a short prefix; both are "the same rev").
  local md_rev
  md_rev="$(grep -oE 'git rev [0-9a-fA-F]{7,64}' "$brief_md" 2>/dev/null | head -1 | awk '{print $3}')"
  if [ -z "$md_rev" ] || [ "${src_rev#$md_rev}" = "$src_rev" ]; then
    md_ok=false
  fi
  if [ "$md_ok" = false ]; then
    echo "brief-integrity: PROJECT_BRIEF.md out of sync with JSON (schema_version/source_version/rev) — regenerate MD from JSON" >&2
    return 1
  fi

  # ---- snapshot exists, parses, schema_version == 1 ----
  if [ ! -f "$snapshot" ]; then
    echo "brief-integrity: .template-snapshot.json missing: $snapshot" >&2
    return 1
  fi
  if ! jq -e 'type == "object" and .schema_version == 1' "$snapshot" >/dev/null 2>&1; then
    echo "brief-integrity: .template-snapshot.json must be an object with schema_version == 1" >&2
    return 1
  fi

  # ---- digest: template_manifest_digest == sha256(snapshot file) ----
  local digest snap_sha
  digest="$(jq -r '.template_manifest_digest // ""' "$brief_json" 2>/dev/null)"
  snap_sha="$(sha256sum "$snapshot" 2>/dev/null | awk '{print $1}')"
  if [ -z "$digest" ] || [ -z "$snap_sha" ] || [ "$digest" != "$snap_sha" ]; then
    echo "brief-integrity: Brief template_manifest_digest ($digest) != snapshot sha ($snap_sha) — recompute digest after any snapshot change" >&2
    return 1
  fi

  # ---- ACYCLIC: snapshot must not reference the Brief files ----
  local cycle
  cycle="$(jq -r '[.templates | keys[]] | map(select(. == ".harness/PROJECT_BRIEF.json" or . == ".harness/PROJECT_BRIEF.md")) | .[]' "$snapshot" 2>/dev/null | head -1)"
  if [ -n "$cycle" ]; then
    echo "brief-integrity: snapshot references $cycle — cycle (Brief digest depends on snapshot, snapshot must not hash the Brief)" >&2
    return 1
  fi

  return 0
}
