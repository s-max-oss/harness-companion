#!/bin/bash
# Batch extension for core/lib/runtime-manifest.sh.
# Source runtime-manifest.sh first so its private validation/anchor helpers are
# available. Keeping this recovery-oriented extension outside core/lib honors
# the frozen core change budget while preserving one-lock atomic publication.

runtime_register_batch() {
  local project_dir="$1" kind="$2" rel seen f mf tmp backup="" rc=0 changed=0 release_rc=0 retain_backup=0
  local -a rels=()
  case "$kind" in
    eval_candidate|eval_result) ;;
    *)
      echo "runtime-manifest: unsupported batch artifact kind: $kind" >&2
      return 1
      ;;
  esac
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    for seen in "${rels[@]}"; do
      if [ "$seen" = "$rel" ]; then
        echo "runtime-manifest: duplicate path in batch: $rel" >&2
        return 1
      fi
    done
    rels+=("$rel")
  done
  [ "${#rels[@]}" -gt 0 ] || return 0

  project_dir="$(cd "$project_dir" 2>/dev/null && pwd)" || return 1
  mf="$(runtime_manifest_path "$project_dir")"
  if [ -L "$mf" ] || [ ! -f "$mf" ]; then
    echo "runtime-manifest: batch registration requires an existing regular registry" >&2
    return 1
  fi

  for rel in "${rels[@]}"; do
    f="$project_dir/$rel"
    if [ -L "$f" ] || [ ! -f "$f" ]; then
      echo "runtime-manifest: refusing to batch-register missing file: $rel" >&2
      return 1
    fi
  done

  _runtime_acquire "$project_dir" || {
    echo "runtime-manifest: failed to acquire registry lock" >&2
    return 1
  }

  tmp="${mf}.batch.$$"
  if ! _runtime_verify_registry_anchor "$project_dir" "$mf" \
     || ! _runtime_validate_registry "$project_dir" "$mf"; then
    echo "runtime-manifest: existing registry or dedicated anchor is invalid" >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    backup="$(_runtime_backup_path "$project_dir")" || rc=1
    [ "$rc" -ne 0 ] || cp "$mf" "$backup" || rc=1
    [ "$rc" -ne 0 ] || cp "$mf" "$tmp" || rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    for rel in "${rels[@]}"; do
      local h sz
      f="$project_dir/$rel"
      if [ -L "$f" ] || [ ! -f "$f" ] || ! h="$(_runtime_file_sha256 "$f")"; then
        echo "runtime-manifest: batch source changed or hash failed: $rel" >&2
        rc=1
        break
      fi
      sz="$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r')"
      if [ -z "$sz" ]; then
        echo "runtime-manifest: failed to measure batch entry for $rel" >&2
        rc=1
        break
      fi
      if jq -e -s --arg p "$rel" 'any(.[]; .path? == $p)' "$tmp" >/dev/null 2>&1; then
        if ! jq -e -s --arg p "$rel" --arg k "$kind" --arg h "$h" --argjson s "$sz" '
          ([.[] | select(.path? == $p)] | length) == 1
          and any(.[]; .path? == $p and .kind == $k and .sha256 == $h and .size == $s)
        ' "$tmp" >/dev/null 2>&1; then
          echo "runtime-manifest: existing batch binding does not match current artifact: $rel" >&2
          rc=1
          break
        fi
        continue
      fi
      if ! jq -cn --arg p "$rel" --arg k "$kind" --arg h "$h" --argjson s "$sz" \
          '{path:$p, kind:$k, sha256:$h, size:$s}' >>"$tmp" 2>/dev/null; then
        echo "runtime-manifest: failed to build batch entry for $rel" >&2
        rc=1
        break
      fi
      changed=1
    done
  fi

  if [ "$rc" -eq 0 ] && [ "$changed" = "1" ]; then
    if ! _runtime_validate_registry "$project_dir" "$tmp" || ! mv "$tmp" "$mf" 2>/dev/null; then
      echo "runtime-manifest: batch registry validation or publication failed" >&2
      rc=1
    elif ! _runtime_anchor_registry "$project_dir" "$mf"; then
      echo "runtime-manifest: batch anchor update failed; rolling back registry" >&2
      if ! _runtime_rollback_registry "$project_dir" "$mf" "$backup" 1 >/dev/null 2>&1; then
        echo "runtime-manifest: batch rollback failed" >&2
        retain_backup=1
      fi
      rc=1
    fi
  fi

  rm -f "$tmp"
  _runtime_release "$project_dir" || release_rc=$?
  if [ "$release_rc" -ne 0 ] && [ "$release_rc" -ne 8 ]; then
    echo "runtime-manifest: failed to release registry lock after batch" >&2
    retain_backup=1
    _runtime_release "$project_dir" >/dev/null 2>&1 || true
    rc=1
  elif [ "$release_rc" -eq 8 ]; then
    echo "runtime-manifest: batch committed; lock cleanup incomplete" >&2
  fi
  if [ "$retain_backup" = "0" ]; then
    [ -z "$backup" ] || rm -f "$backup"
  elif [ -n "$backup" ]; then
    echo "runtime-manifest: retained batch recovery backup at $backup" >&2
  fi
  return "$rc"
}
