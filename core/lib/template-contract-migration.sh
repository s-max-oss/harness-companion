#!/bin/bash
# Explicit authorization for deliberate changes to immutable harness templates.
#
# The template snapshot is an immutable provenance baseline and is never
# rewritten merely because a repository deliberately evolves its tracked
# AGENTS.md / CLAUDE.md / init.sh contract. Instead, a committed migration in
# docs/template-contract-migrations/ binds:
#   * the exact unchanged snapshot bytes,
#   * each old snapshot digest,
#   * each current tracked-file digest, and
#   * an ancestor commit at which the authorization mechanism existed.
#
# validate_template_contract_migration <project> <snapshot> <entry>...
# Prints the unique active migration_id and returns 0, or returns 1.

_tcm_sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$path" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$path" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

_tcm_candidate_active() {
  local project="$1" snapshot="$2" record="$3"
  shift 3
  local entries=("$@") rel snap_sha parent n_changed=0 entry rec act count

  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  rel="${record#"$project/"}"
  [ "$rel" != "$record" ] || return 1
  git -C "$project" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || return 1
  git -C "$project" diff --quiet -- "$rel" || return 1
  git -C "$project" diff --cached --quiet -- "$rel" || return 1

  jq -e '
    type == "object"
    and keys == ["authorization_parent","changes","migration_id","reason","schema_version","snapshot_sha256"]
    and .schema_version == 1
    and (.migration_id | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and (.authorization_parent | type == "string" and test("^[0-9a-f]{40}$"))
    and (.snapshot_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.reason | type == "string" and test("[^[:space:]]"))
    and (.changes | type == "array" and length > 0)
    and ([.changes[].path] | length == (unique | length))
    and ([.changes[] | keys == ["authorized_sha256","path","snapshot_sha256"]] | all)
    and ([.changes[] | .path | type == "string" and test("^[A-Za-z0-9._/-]+$")
          and (test("(^/|(^|/)\\.\\.(/|$)|\\\\)") | not)] | all)
    and ([.changes[] | .snapshot_sha256 | type == "string" and test("^[0-9a-f]{64}$")] | all)
    and ([.changes[] | .authorized_sha256 | type == "string" and test("^[0-9a-f]{64}$")] | all)
  ' "$record" >/dev/null 2>&1 || return 1

  snap_sha="$(_tcm_sha256_file "$snapshot")" || return 1
  [ "$(jq -r '.snapshot_sha256' "$record")" = "$snap_sha" ] || return 1
  parent="$(jq -r '.authorization_parent' "$record")"
  git -C "$project" merge-base --is-ancestor "$parent" HEAD >/dev/null 2>&1 || return 1

  for entry in "${entries[@]}"; do
    rec="$(jq -r --arg e "$entry" '.templates[$e].sha256 // ""' "$snapshot" 2>/dev/null)"
    [ -n "$rec" ] || return 1
    [ -f "$project/$entry" ] && [ ! -L "$project/$entry" ] || return 1
    act="$(_tcm_sha256_file "$project/$entry")" || return 1
    if [ "$rec" = "$act" ]; then
      count="$(jq -r --arg e "$entry" '[.changes[] | select(.path == $e)] | length' "$record")"
      [ "$count" = "0" ] || return 1
      continue
    fi
    n_changed=$((n_changed + 1))
    count="$(jq -r --arg e "$entry" --arg old "$rec" --arg new "$act" '
      [.changes[] | select(.path == $e and .snapshot_sha256 == $old and .authorized_sha256 == $new)] | length' "$record")"
    [ "$count" = "1" ] || return 1
    git -C "$project" ls-files --error-unmatch -- "$entry" >/dev/null 2>&1 || return 1
    git -C "$project" diff --quiet -- "$entry" || return 1
    git -C "$project" diff --cached --quiet -- "$entry" || return 1
  done

  [ "$(jq '.changes | length' "$record")" = "$n_changed" ] || return 1
  return 0
}

validate_template_contract_migration() {
  local project="$1" snapshot="$2"
  shift 2
  [ -d "$project/.git" ] || {
    echo "template-contract-migration: project is not a git repository" >&2
    return 1
  }
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || {
    echo "template-contract-migration: snapshot missing or unsafe" >&2
    return 1
  }
  local dir="$project/docs/template-contract-migrations" record active="" count=0 id
  [ -d "$dir" ] || {
    echo "template-contract-migration: no committed migration directory" >&2
    return 1
  }
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    if _tcm_candidate_active "$project" "$snapshot" "$record" "$@"; then
      id="$(jq -r '.migration_id' "$record")"
      active="$id"
      count=$((count + 1))
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort)
  if [ "$count" -ne 1 ]; then
    echo "template-contract-migration: expected exactly one active committed migration, found $count" >&2
    return 1
  fi
  printf '%s' "$active"
}
