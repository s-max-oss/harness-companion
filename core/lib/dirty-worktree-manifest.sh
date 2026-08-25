#!/bin/bash
# dirty-worktree-manifest.sh — Local dirty-worktree manifest gate (§15.3/§15.5)
#
# The dev repo working tree holds tracked-but-modified and untracked paths that
# `git diff <base>..<head>` cannot see. A before/after manifest records the
# protected dirty path set at snapshot time; the gate re-enumerates later and
# asserts IMMUTABLE and non-Harness USER dirty paths stayed byte-equal, while
# ALLOWING controlled changes AND new paths inside the mutable runtime
# namespace — but NEVER arbitrary rewrites (P0-5):
#
# Mutable namespace: NEW paths are allowed; EXISTING files follow per-class
# content rules (the whole namespace is NOT arbitrarily modifiable):
#   .harness/logs/runs/*.ndjson — existing run logs must stay BYTE-EQUAL
#                                 (a run is one file, never re-written)
#   .harness/reviews/**/*.jsonl — reviewer verdict artifacts may only APPEND:
#                                 the recorded bytes must be a PREFIX of the
#                                 current file (re-review appends one record)
#   feature_list.json           — registry manifest contract (P0-M2): BOTH the
#                                 recorded snapshot and the current file must be
#                                 canonical-schema-valid; feature set consistent
#                                 (no removals; new features start not_started);
#                                 per-revision legal mutation history proven by
#                                 the append-only journal (validate_registry_
#                                 transition → journal_replay, single-edge only —
#                                 NOT transitive closure); evidence append-only;
#                                 revision consistent (content-same ⇒
#                                 rev-unchanged, content-changed ⇒ rev-advanced)
#   .harness/registry-journal.ndjson
#                             — append-only mutation journal (P0-M2): existing
#                                 bytes must be a PREFIX of the current file
#                                 (append-only — no in-place edits, no
#                                 removals, no reordering)
#   .harness/.registry.lock/
#   .harness/branch-gate.json   — stateful Phase 1 branch-baseline gate state,
#                                 recorded ONCE by a successful init (P0-2);
#                                 first appearance allowed, then byte-equal
#                                 (P0-M3: rewriting the baseline must fail)
#   claude-progress.md, session-handoff.md, clean-state-checklist.md, checklist.sh
#     — progress/state files may change content (content_changed_mutable)
# Everything else recorded in the manifest must be byte-equal, and no NEW dirty
# path may appear outside the mutable namespace.
#
# Functions:
#   dwm_is_mutable <path>                    → exit 0 (mutable) / 1 (not)
#   dwm_emit_manifest <project_dir> <out> [exclude...]
#       → canonical JSONL (one object/line, sorted by parsed .path, deduped)
#   dwm_compare_manifest <project_dir> <recorded> → JSON result, exit 0/1
#
# Manifest record: {path, type, sha256, size, mode, symlink_target, git_status}
# (spec §15.5). mtime is NOT recorded — only SHA-256 proves content equality.
# size/mode are diagnostics only and never compared by the gate.
#
# Requires: bash, jq, git, sha256sum (or shasum -a 256), readlink.

# P0-10: the feature_list.json gate re-validates the registry manifest contract
# via the repo's own canonical validator (never a bare JSON parse).
if ! type validate_feature_registry_json >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  source "${BASH_SOURCE[0]%/*}/validate-feature-registry.sh" 2>/dev/null \
    || { echo "dirty-worktree-manifest: cannot source validate-feature-registry.sh" >&2; }
fi

DWM_MUTABLE=(
  ".harness/logs/runs/"
  ".harness/reviews/"
  ".harness/acceptance/"
  ".harness/registry-journal.ndjson"
  ".harness/runtime-manifest.jsonl"
  ".harness/.registry.lock/"
  ".harness/branch-gate.json"
  "feature_list.json"
  "claude-progress.md"
  "session-handoff.md"
  "clean-state-checklist.md"
  "checklist.sh"
)

# ---- dwm_is_mutable --------------------------------------------------------
# 0 if path is in the mutable runtime namespace (dir namespaces match by
# prefix; file namespaces match exactly).
dwm_is_mutable() {
  local p="$1" m
  for m in "${DWM_MUTABLE[@]}"; do
    case "$m" in
      */)
        [ "$p" = "${m%/}" ] && return 0
        case "$p" in "$m"*) return 0 ;; esac ;;
      *)
        [ "$p" = "$m" ] && return 0 ;;
    esac
  done
  return 1
}

# _dwm_validate_branch_gate_first_add <project_dir> — Contract 4 (P0-3).
# Validate a FIRST-APPEARING .harness/branch-gate.json (a new mutable path).
# A new branch-gate MUST NOT slip through the mutable-namespace hole unchecked.
# Fail-closed (P0-3): the file must be a REAL regular file (symlinks/directories
# rejected), the PLAN.json that defines branch policy must EXIST and carry a
# target branch (missing/malformed/untargeted PLAN → reject, never allow), the
# recorded branch_name must equal the PLAN target AND the CURRENT git branch,
# and the base must be a real git OID that is an ANCESTOR of HEAD, satisfying
# the expected FIRST baseline (branch-gate.sh records its first entry at
# head==master tip, so while the repo is still at that state base must equal
# HEAD — an arbitrary ancestor at first-add is rejected). Returns a short reason
# string on violation (empty = valid). Never a bare JSON parse.
_dwm_validate_branch_gate_first_add() {
  local project_dir="$1"
  local f="$project_dir/.harness/branch-gate.json"
  # Nothing at all present → no first-add to validate.
  [ -e "$f" ] || [ -L "$f" ] || return 0
  # A SYMLINK at the branch-gate path is tampering, not a state file: it must
  # NOT bypass validation by resolving to a regular file (or a dangling target)
  # elsewhere. Reject before any follow-the-link test.
  if [ -L "$f" ]; then echo "symlink_rejected"; return 0; fi
  # A directory (or other non-regular-file) at the branch-gate path is
  # tampering too: only a regular file is candidate JSON.
  if [ ! -f "$f" ]; then echo "not_json"; return 0; fi
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then echo "not_json"; return 0; fi
  if ! jq -e '.schema_version == 1' "$f" >/dev/null 2>&1; then echo "schema_version"; return 0; fi
  local bn bs
  bn="$(jq -r '.branch_name // ""' "$f" 2>/dev/null)"
  bs="$(jq -r '.branch_base_sha // ""' "$f" 2>/dev/null)"
  if [ -z "$bn" ] || [ "$bn" = "null" ]; then echo "missing_branch_name"; return 0; fi
  if [ -z "$bs" ] || [ "$bs" = "null" ]; then echo "missing_branch_base_sha"; return 0; fi
  # PLAN.json is the AUTHORITATIVE branch policy — a first-appearing baseline
  # cannot be validated without it, so missing/malformed/untargeted PLAN is
  # REJECTED (fail-closed), never silently allowed.
  local plan="$project_dir/.harness/PLAN.json"
  # Codex r4: a SYMLINK at the PLAN path is tampering, not a state file. It
  # must NOT bypass validation by resolving to a regular file (or a dangling
  # target) elsewhere — `[ -f ]` follows symlinks, so without this explicit
  # guard a symlink → valid-plan would be accepted, allowing the baseline
  # gate's branch policy to be redirected to an attacker-controlled file.
  # Reject before any follow-the-link test (matches the branch-gate
  # symlink_rejected treatment immediately above).
  if [ -L "$plan" ]; then echo "plan_symlink"; return 0; fi
  if [ ! -f "$plan" ]; then echo "plan_missing"; return 0; fi
  if ! jq -e 'type == "object"' "$plan" >/dev/null 2>&1; then echo "plan_bad_json"; return 0; fi
  local target
  target="$(jq -r '.branch_gate.target_branch // ""' "$plan" 2>/dev/null)"
  if [ -z "$target" ] || [ "$target" = "null" ]; then echo "plan_no_target"; return 0; fi
  # The recorded baseline branch must equal the PLAN target branch (P0-3).
  if [ "$bn" != "$target" ]; then echo "branch_mismatch"; return 0; fi
  # The CURRENT branch must equal the recorded branch_name (P0-3: current branch
  # == PLAN target AND == recorded branch_name — a baseline recorded on a
  # different branch than the one the gate is running on is not this repo's
  # baseline).
  local cur_branch
  cur_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  # FAIL-CLOSED on an unresolvable current branch (unborn HEAD / broken git):
  # an empty branch can never equal the recorded branch_name, so it must be
  # rejected here rather than silently skipped (consistent with branch-gate.sh).
  if [ -z "$cur_branch" ] || [ "$cur_branch" != "$bn" ]; then echo "current_branch_mismatch"; return 0; fi
  # Real git OID, and an ancestor of HEAD (forward advancement from the baseline).
  if ! git -C "$project_dir" rev-parse --verify --quiet "$bs^{commit}" >/dev/null 2>&1; then
    echo "not_real_oid"; return 0
  fi
  local head
  head="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$head" ] || ! git -C "$project_dir" merge-base --is-ancestor "$bs" "$head" 2>/dev/null; then
    echo "not_ancestor"; return 0
  fi
  # Expected first baseline (P0-3, Codex item 8): the recorded base MUST equal
  # the REAL master tip at the time. branch-gate.sh records branch_base_sha =
  # master tip on its FIRST entry (head == master tip), and master does not
  # advance during Phase 1 (work happens on the target branch). So a
  # first-appearing baseline whose base != master tip is tampering — an
  # arbitrary ancestor of HEAD is NOT "the master tip when the baseline was
  # recorded". This must hold UNCONDITIONALLY: when the target branch has
  # advanced AHEAD of master (head != master tip), the old master-tip == HEAD
  # special-case never fired and any real ancestor slipped through the
  # ancestor-of-HEAD check above. Unconditional base == master tip equality
  # proves the invariant in both the at-tip and ahead-of-tip cases. (The
  # "current branch at-or-ahead of master tip" requirement is implied here:
  # base == master tip AND base ancestor-of-HEAD ⇒ master tip ancestor-of-HEAD.)
  local master_tip
  master_tip="$(git -C "$project_dir" rev-parse --verify --quiet refs/heads/master 2>/dev/null || true)"
  # FAIL-CLOSED when there is no local master ref: the first baseline must prove
  # the REAL master tip at the time, and with no master ref that proof is
  # impossible — reject rather than accept an arbitrary ancestor.
  if [ -z "$master_tip" ]; then echo "not_first_baseline"; return 0; fi
  if [ "$bs" != "$master_tip" ]; then
    echo "not_first_baseline"; return 0
  fi
  return 0
}

# _v_registry_revision <file> — feature_list.json .revision as a JSON number
# (0 if absent/unparseable — fail-closed when a content change is later judged).
_v_registry_revision() {
  jq -r '.revision // 0' "$1" 2>/dev/null || printf '0'
}

# ---- dwm_record ------------------------------------------------------------
# Emit ONE canonical JSON record for a path. Runs with cwd == project_dir.
# <rel> = path relative to project root; <gs> = git status porcelain code.
# feature_list.json records additionally carry the registry `revision` (P0-5),
# so the gate can validate the revision transition when that file changes.
dwm_record() {
  local rel="$1" gs="$2"
  local typ="file" sha="" size="" mode="" target=""
  if [ -L "$rel" ]; then
    typ="symlink"
    target="$(readlink "$rel" 2>/dev/null || true)"
  elif [ -d "$rel" ]; then
    typ="directory"
  elif [ -f "$rel" ]; then
    sha="$( { sha256sum "$rel" 2>/dev/null || shasum -a 256 "$rel" 2>/dev/null; } | awk '{print $1}' )"
    size="$(wc -c < "$rel" 2>/dev/null | tr -d ' \t\r')"
    mode="$(stat -c %a "$rel" 2>/dev/null || stat -f %Lp "$rel" 2>/dev/null || true)"
  elif [ -p "$rel" ]; then
    typ="fifo"
  elif [ -S "$rel" ]; then
    typ="socket"
  elif [ -b "$rel" ]; then
    typ="block_device"
  elif [ -c "$rel" ]; then
    typ="char_device"
  else
    typ="other"
  fi
  local revarg regarg
  if [ "$rel" = "feature_list.json" ]; then
    revarg="$(_v_registry_revision "$rel")"
    # P0-10: embed the full canonical features array so the gate can re-validate
    # the recorded snapshot's schema and run the registry transition contract.
    regarg="$(jq -c '.features // []' "$rel" 2>/dev/null || printf '[]')"
  else
    revarg="null"
    regarg="null"
  fi
  jq -cn \
    --arg path "$rel" --arg type "$typ" \
    --arg sha "$sha" --arg size "$size" --arg mode "$mode" --arg target "$target" --arg gs "$gs" \
    --argjson rev "$revarg" --argjson reg "$regarg" \
    '{path:$path, type:$type,
      sha256:($sha | if .=="" then null else . end),
      size:($size | if .=="" then null else (.|tonumber) end),
      mode:($mode | if .=="" then null else . end),
      symlink_target:($target | if .=="" then null else . end),
      git_status:$gs}
      + (if $path == "feature_list.json" then {revision:$rev, registry:$reg} else {} end)'
}

# ---- dwm_expand ------------------------------------------------------------
# Emit a record for a dirty path and (for directories) all descendants, in
# sorted order. Runs with cwd == project_dir.
dwm_expand() {
  local rel="$1" gs="$2"
  shift 2
  local ex
  for ex in "$@"; do
    [ "$rel" = "$ex" ] && return 0
  done
  if [ -L "$rel" ]; then
    dwm_record "$rel" "$gs"
    return 0
  fi
  if [ -d "$rel" ]; then
    dwm_record "$rel" "$gs"
    local child
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      dwm_expand "$rel/$child" "$gs" "$@"
    done < <(find "$rel" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
    return 0
  fi
  dwm_record "$rel" "$gs"
}

# ---- dwm_emit_manifest -----------------------------------------------------
# Enumerate the protected dirty path set (tracked-but-modified + untracked,
# per §15.3), recursively including ancestor directory records, excluding the
# passed self-reference paths, and write canonical sorted JSONL to <out>.
dwm_emit_manifest() {
  local project_dir="$1" out_file="$2"
  shift 2
  local excludes=("$@")
  local tmp
  tmp="$(mktemp)"
  (
    cd "$project_dir" 2>/dev/null || { echo "dirty-worktree: cannot cd $project_dir" >&2; exit 2; }
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo "dirty-worktree: not a git repository: $project_dir" >&2
      exit 3
    fi
    local line code path ex
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      code="${line:0:2}"
      path="${line:3}"
      case "$path" in *" -> "*) path="${path##* -> }" ;; esac
      for ex in "${excludes[@]}"; do
        [ "$path" = "$ex" ] && continue 2
      done
      if [ -d "$path" ]; then
        dwm_expand "$path" "$code" "${excludes[@]}"
      else
        dwm_record "$path" "$code"
        # ancestor directory records
        local anc="$path" ex2 skip_anc
        while :; do
          anc="$(dirname "$anc")"
          { [ "$anc" = "." ] || [ -z "$anc" ]; } && break
          if [ -d "$anc" ]; then
            skip_anc=0
            for ex2 in "${excludes[@]}"; do
              [ "$anc" = "$ex2" ] && skip_anc=1
            done
            [ "$skip_anc" = 0 ] && dwm_record "$anc" "$code"
          fi
        done
      fi
    done < <(git status --porcelain=v1 --untracked-files=all 2>/dev/null)

    # Codex r4 fix: enumerate .harness/logs/runs/*.ndjson even when gitignored.
    # The directory is in .gitignore (`# Harness runtime artifacts`), so
    # `git status --porcelain --untracked-files=all` never reports individual
    # run-log files; without this enumeration, deletions and rewrites of run
    # logs are INVISIBLE to the manifest gate. The per-class rule
    # `.harness/logs/runs/*.ndjson — existing run NDJSON must stay BYTE-EQUAL`
    # already covers the byte-equality contract — the missing piece is the
    # enumeration itself, so the gate can compare current vs recorded and
    # detect removals/rewrites. Marker `!!` distinguishes "gitignored,
    # manifest-enumerated" from the `??` untracked git-status entries (the
    # field is diagnostic only — the compare logic does not act on it).
    #
    # Codex r5 defect 1 follow-up: also enumerate the per-command `.log`
    # artifacts under `.harness/logs/runs/<run_id>/<command_id>.log`. These
    # are the file-on-disk anchors that validate-run-log step 5b/5c binds to
    # the recorded log_artifact + log_sha256. Without enumeration, an attacker
    # could swap or delete the command log AFTER the NDJSON was captured and
    # the manifest gate would never notice — defeating step 5b/5c. The same
    # byte-equality contract applies: existing log files must stay byte-equal.
    # Ancestor directory records for the run path are already emitted by the
    # `git status` loop above when any peer sibling file is reported; here we
    # only need the file records.
    if [ -d ".harness/logs/runs" ]; then
      while IFS= read -r rpath; do
        [ -n "$rpath" ] || continue
        case "$rpath" in
          *.ndjson|*.log) dwm_record ".harness/logs/runs/$rpath" "!!" ;;
        esac
      done < <(cd ".harness/logs/runs" && find . \( -name '*.ndjson' -o -name '*.log' \) -printf '%P\n' 2>/dev/null \
        | sed 's|^\./||' | LC_ALL=C sort)
    fi

    # The review and acceptance namespaces are gitignored runtime state too.
    # Enumerate every matching filesystem node, not only regular files: a FIFO,
    # socket, device, or symlink at a protected artifact path must reach the
    # fail-closed type checks instead of disappearing from the current manifest.
    local runtime_root runtime_rel
    for runtime_root in ".harness/reviews" ".harness/acceptance"; do
      [ -d "$runtime_root" ] || continue
      while IFS= read -r runtime_rel; do
        [ -n "$runtime_rel" ] || continue
        case "$runtime_root/$runtime_rel" in
          .harness/reviews/*.jsonl|.harness/reviews/*/*.jsonl|.harness/acceptance/*/acceptance.json|.harness/acceptance/*/A-G.log)
            dwm_record "$runtime_root/$runtime_rel" "!!"
            ;;
        esac
      done < <(cd "$runtime_root" && find . -mindepth 1 -printf '%P\n' 2>/dev/null \
        | sed 's|^\./||' | LC_ALL=C sort)
    done
  ) > "$tmp"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  # canonical: sort by parsed .path, dedupe, one compact object per line
  jq -s 'sort_by(.path) | unique_by(.path) | .[]' "$tmp" 2>/dev/null \
    | jq -c . 2>/dev/null | tr -d '\r' > "$out_file" 2>/dev/null
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# ---- dwm_compare_manifest --------------------------------------------------
# Compare the CURRENT dirty-worktree manifest (re-emitted) against a recorded
# manifest. NEW paths are allowed only inside the mutable namespace
# (allowed_new). EXISTING files must stay byte-equal UNLESS mutable AND the
# change follows the P0-5 per-class rules:
#   .harness/logs/runs/*.ndjson   — existing run NDJSON must be byte-equal
#   .harness/reviews/**/*.jsonl   — verdicts may only APPEND: the recorded
#                                   bytes must be a PREFIX of the current file
#   .harness/registry-journal.ndjson — append-only mutation journal (P0-M2):
#                                   recorded bytes must be a PREFIX of the
#                                   current file (same append-only contract)
#   .harness/branch-gate.json     — first add allowed, then byte-equal (P0-M3:
#                                   rewriting the recorded baseline must fail)
#   feature_list.json             — legal ONLY when validate_registry_transition
#                                   passes (journal-driven single-edge replay,
#                                   P0-M2 — replaces the old reachability check)
#   other mutable state/progress  — content may differ (content_changed_mutable)
# Removals always violate (append-only). Any extra args are self-reference
# exclude paths forwarded to the internal emit (the recorded manifest and the
# snapshot tool must never enumerate themselves).
#
# Codex r6 fix — runtime-artifact PAIRED-REWRITE detection: an attacker could
# pair a brand-new run NDJSON with a brand-new full-suite.log AND a brand-new
# reviewer verdict — every entry shows up as `allowed_new` (legitimate) when
# considered alone, but together they constitute a co-ordinated rewrite of
# the recorded evidence. The recorded fixture pre-dates the latest canonical
# run, so a TRULY new run-id legitimately enters as `allowed_new`; the
# distinguishing signal is whether ANY recorded file in the runtime-artifact
# namespace has been modified (`changed_mutable` is non-empty). If both a
# modification and a new-file appearance happen at the same time, the new
# file is rejected with reason "runtime_paired_rewrite" — there is no
# legitimate way to add a new run log AND modify an existing one between two
# DWM snapshots (a re-run always adds the NEW file but never rewrites the
# previous one, since runs are append-only one-shot files). This is the
# code-only fix the user-required "no baseline re-shoot" constraint demands:
# the gate becomes sensitive to paired-rewrites without enumerating them in
# the recorded fixture.
# Output: JSON {valid, violations, allowed_new, new_non_mutable,
#               appended_mutable, feature_revision_advanced,
#               content_changed_mutable, runtime_paired_rewrite}.
# Exit 0 if valid, 1 otherwise.
dwm_compare_manifest() {
  local project_dir="$1" recorded="$2"
  shift 2
  local excludes=("$@")
  local cur_file
  cur_file="$(mktemp)"
  local mutable_json prog
  mutable_json="$(printf '%s\n' "${DWM_MUTABLE[@]}" | jq -R -s 'split("\n") | map(select(length>0))')"
  prog='def in_mutable($m):
    # NOTE: the element must be captured into a variable ($e) before use —
    # `$p | startswith(.)` would rebind `.` to $p and always match.
    . as $p | any($m[]; . as $e | if ($e | endswith("/")) then (($p == ($e | rtrimstr("/"))) or ($p | startswith($e))) else ($p == $e) end);
  # runtime-artifact namespace: a NEW file here paired with ANY recorded-file
  # modification in the same namespace is a paired rewrite (see header).
  def is_runtime_artifact: startswith(".harness/logs/runs/") or startswith(".harness/reviews/") or startswith(".harness/acceptance/");

  ($r | map({key:.path, value:.}) | from_entries) as $rm |
  ($c | map({key:.path, value:.}) | from_entries) as $cm |
  ({
    violations: (
      [ $r[] | .path ] as $rp
      | [ $rp[]
          | . as $p
          | ($rm[$p]) as $rv
          | if (($cm[$p] | not)) then {path:$p, reason:"removed"}
            elif ($cm[$p].type != $rv.type) then {path:$p, reason:"type_changed"}
            elif ($cm[$p].type == "symlink" and $cm[$p].symlink_target != $rv.symlink_target) then {path:$p, reason:"symlink_changed"}
            elif ($cm[$p].type == "file" and $cm[$p].sha256 != $rv.sha256
                  and (($p | in_mutable($mutable)) | not)) then {path:$p, reason:"not_byte_equal"}
            else empty end
        ]
    ),
    allowed_new: [ $c[] | select((.path | in_mutable($mutable)) and ($rm[.path] | not)) | .path ],
    new_non_mutable: [ $c[] | select((( .path | in_mutable($mutable)) | not) and ($rm[.path] | not)) | .path ],
    changed_mutable: [ $r[] | select((.path | in_mutable($mutable)) and (.type == "file") and ($cm[.path] and $cm[.path].sha256 != .sha256)) | .path ]
  }) as $res
  # Codex r6 paired-rewrite guard: if ANY recorded runtime-artifact file was
  # modified AND any new file appeared in the same namespace in the same gate
  # pass, the new file is rejected as `runtime_paired_rewrite` — a single
  # legitimate canonical re-run adds ONE new file and modifies ZERO recorded
  # files. The recorded fixture pre-dates the canonical run; the canonical
  # run NDJSON is the ONLY legitimate `allowed_new` in the runtime-artifact
  # namespace, and it never co-occurs with a recorded-file modification.
  | (if ([$res.changed_mutable[] | select(is_runtime_artifact)] | length) > 0
     then [$res.allowed_new[] | select(is_runtime_artifact)] | map({path:., reason:"runtime_paired_rewrite"})
     else []
     end) as $paired_violations
  | $res + {runtime_paired_rewrite: ($paired_violations | map(.path)),
            paired_rewrite_violations: $paired_violations}'
  if ! dwm_emit_manifest "$project_dir" "$cur_file" "${excludes[@]}"; then
    rm -f "$cur_file"
    jq -n --arg d "$project_dir" '{valid:false, reason:"emit_failed", project_dir:$d}'
    return 1
  fi
  local result
  result="$(jq -c -n --slurpfile r "$recorded" --slurpfile c "$cur_file" --argjson mutable "$mutable_json" "$prog" 2>/dev/null)"
  if [ -z "$result" ]; then
    rm -f "$cur_file"
    jq -n '{valid:false, reason:"compare_failed"}'
    return 1
  fi

  # ---- Codex r6: paired-rewrite violation promotion ----
  # The jq prog computes `paired_rewrite_violations`; promote them into the
  # main violations array (so .valid==false when any paired rewrite occurs).
  local paired_count
  paired_count="$(printf '%s' "$result" | jq '.paired_rewrite_violations | length')"
  if [ "$paired_count" != "0" ]; then
    result="$(printf '%s' "$result" | jq -c '.violations += .paired_rewrite_violations')"
  fi

  # ---- P0-5: classify each content-changed mutable path (needs disk reads) ----

  # ---- Contract 4: branch-gate.json FIRST-ADD is validated, not just allowed --
  # A brand-new branch-gate.json may NOT enter through the mutable-namespace
  # allowed_new hole without validation. Validate the canonical schema, PLAN
  # target branch, real git OID/ancestry, and expected first baseline; on any
  # violation remove it from allowed_new and raise a violation (fail-closed).
  local bg_is_new bg_violation=""
  bg_is_new="$(printf '%s' "$result" | jq -r '[.allowed_new[] | select(. == ".harness/branch-gate.json")] | length')"
  if [ "$bg_is_new" = "1" ]; then
    bg_violation="$(_dwm_validate_branch_gate_first_add "$project_dir")"
    if [ -n "$bg_violation" ]; then
      result="$(printf '%s' "$result" | jq -c '.allowed_new = [.allowed_new[] | select(. != ".harness/branch-gate.json")]')"
      mutable_violations+=("$(jq -nc --arg p ".harness/branch-gate.json" --arg d "$bg_violation" \
        '{path:$p, reason:"invalid_branch_gate", detail:$d}')")
    fi
  fi

  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      ".harness/logs/runs/"*)
        # existing run NDJSON must stay byte-equal (P0-5)
        mutable_violations+=("$(jq -nc --arg p "$p" '{path:$p, reason:"not_byte_equal"}')")
        ;;
      ".harness/reviews/"*)
        # verdicts may only append: the recorded bytes must be a PREFIX of the
        # current file. Verify via `head -c recorded_size | sha256sum == recorded_sha`.
        local rec_sha rec_size actual=""
        rec_sha="$(jq -r --arg p "$p" 'select(.path == $p) | .sha256 // ""' "$recorded" | head -1)"
        rec_size="$(jq -r --arg p "$p" 'select(.path == $p) | .size // 0' "$recorded" | head -1)"
        if [ -n "$rec_sha" ] && [ -n "$rec_size" ]; then
          actual="$(head -c "$rec_size" "$project_dir/$p" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')"
        fi
        if [ -n "$actual" ] && [ "$actual" = "$rec_sha" ]; then
          appended_mutable+=("$p")
        else
          mutable_violations+=("$(jq -nc --arg p "$p" '{path:$p, reason:"not_append_only"}')")
        fi
        ;;
      ".harness/registry-journal.ndjson")
        # P0-M2 append-only journal: existing bytes must be a PREFIX of the
        # current file (append-only — no in-place edits, no removals, no
        # reordering). Same recorded-PREFIX-vs-current verification as reviews.
        local rec_sha rec_size actual=""
        rec_sha="$(jq -r --arg p "$p" 'select(.path == $p) | .sha256 // ""' "$recorded" | head -1)"
        rec_size="$(jq -r --arg p "$p" 'select(.path == $p) | .size // 0' "$recorded" | head -1)"
        if [ -n "$rec_sha" ] && [ -n "$rec_size" ]; then
          actual="$(head -c "$rec_size" "$project_dir/$p" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')"
        fi
        if [ -n "$actual" ] && [ "$actual" = "$rec_sha" ]; then
          appended_mutable+=("$p")
        else
          mutable_violations+=("$(jq -nc --arg p "$p" '{path:$p, reason:"not_append_only"}')")
        fi
        ;;
      ".harness/runtime-manifest.jsonl")
        # Codex r7: the byte-binding registry is itself append-only — new
        # registrations append NEW lines, existing lines are never rewritten.
        # Same recorded-PREFIX-vs-current verification as reviews/journal.
        local rec_sha rec_size actual=""
        rec_sha="$(jq -r --arg p "$p" 'select(.path == $p) | .sha256 // ""' "$recorded" | head -1)"
        rec_size="$(jq -r --arg p "$p" 'select(.path == $p) | .size // 0' "$recorded" | head -1)"
        if [ -n "$rec_sha" ] && [ -n "$rec_size" ]; then
          actual="$(head -c "$rec_size" "$project_dir/$p" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')"
        fi
        if [ -n "$actual" ] && [ "$actual" = "$rec_sha" ]; then
          appended_mutable+=("$p")
        else
          mutable_violations+=("$(jq -nc --arg p "$p" '{path:$p, reason:"not_append_only"}')")
        fi
        ;;
      ".harness/branch-gate.json")
        # P0-M3: the Phase 1 branch-baseline gate state is written ONCE by a
        # successful init and is fully DETERMINISTIC (no timestamps — subsequent
        # entries never rewrite it). First appearance is allowed (it is in
        # DWM_MUTABLE → allowed_new); once recorded, its bytes must stay
        # byte-equal — rewriting the baseline must FAIL.
        mutable_violations+=("$(jq -nc --arg p "$p" '{path:$p, reason:"not_byte_equal"}')")
        ;;
      "feature_list.json")
        # P0-10 registry manifest contract — NOT a revision +1/+N check. See
        # validate_registry_transition (core/lib/validate-feature-registry.sh):
        # canonical schema of BOTH snapshots, feature-set consistency (no
        # removals; new features start not_started), per-feature status
        # transitions reachable through the legal state machine (transitive
        # closure — a Phase may apply several legal mutations), evidence
        # append-only, revision consistency (content-same ⇒ rev-unchanged,
        # content-changed ⇒ rev-advanced). FAIL-CLOSED via the repo's own
        # validator — never a bare JSON parse.
        local rec_rev rec_reg rec_sha rec_doc vrt_out vrt_err
        rec_rev="$(jq -r --arg p "$p" 'select(.path == $p) | .revision // -1' "$recorded" | head -1)"
        rec_reg="$(jq -c --arg p "$p" 'select(.path == $p) | .registry // null' "$recorded" | head -1)"
        # P0-M2: the recorded feature_list.json sha256 anchors the journal replay
        # (recorded snapshot must appear in the journal's sha chain).
        rec_sha="$(jq -r --arg p "$p" 'select(.path == $p) | .sha256 // ""' "$recorded" | head -1)"
        if [ "$rec_rev" != "-1" ] && [ -n "$rec_reg" ] && [ "$rec_reg" != "null" ]; then
          rec_doc="$(printf '{"revision":%s,"features":%s,"_recorded_sha":%s}' \
            "$rec_rev" "$rec_reg" "$( [ -n "$rec_sha" ] && printf '"%s"' "$rec_sha" || printf 'null' )")"
          if vrt_out="$(validate_registry_transition "$rec_doc" "$project_dir/feature_list.json" "$project_dir" 2>&1)"; then
            feature_advanced+=("$p")
          else
            vrt_err="$(printf '%s' "$vrt_out" | tail -1)"
            mutable_violations+=("$(jq -nc --arg p "$p" --arg d "$vrt_err" \
              '{path:$p, reason:"illegal_registry_transition", detail:$d}')")
          fi
        else
          mutable_violations+=("$(jq -nc --arg p "$p" --argjson rr "$rec_rev" \
            '{path:$p, reason:"illegal_registry_transition", detail:"recorded snapshot missing registry/revision", recorded_revision:$rr}')")
        fi
        ;;
      *)
        content_changed_mutable+=("$p")
        ;;
    esac
  # MSYS jq emits CRLF from every output mode; command substitution strips the
  # trailing \r only from the LAST line, and `read` (IFS=) keeps \r on every
  # intermediate line. Without stripping CR, the exact-match case arms below
  # (registry-journal.ndjson, feature_list.json) silently never fire whenever
  # another mutable path sorts after them — the journal append-only and registry
  # gates would be skipped on the target platform. Strip CR from the stream.
  done <<<"$(printf '%s\n' "$result" | jq -r '.changed_mutable[]' | tr -d '\r')"

  # ---- Codex r7 + rc6 final remediation: runtime-artifact byte-binding ----
  # The frozen recorded fixture pre-dates the latest canonical run, so the
  # canonical NDJSON + command logs + reviewer verdict would otherwise enter as
  # `allowed_new` indefinitely and their bytes would never be bound. The
  # persistent runtime-manifest registry binds the FIRST-SEEN bytes of each
  # runtime artifact; once the registry exists it is the authoritative binding,
  # independent of the recorded fixture.
  #
  # Protection layers (rc6 final):
  #   1. Genesis + append-only transitions identify the current authorized
  #      HEAD. A dedicated Git index in .git binds the exact registry bytes;
  #      DWM requires byte equality with its stage-0 blob and also compares the
  #      effective anchor with current HEAD (or RUNTIME_MANIFEST_GENESIS).
  #      Any drift = fail-closed.
  #   2. A REGISTERED artifact that changed is a violation:
  #        ndjson/log → runtime_artifact_not_byte_equal
  #        verdict    → runtime_artifact_not_append_only
  #   3. An UNREGISTERED runtime artifact (NDJSON/log/verdict path appearing in
  #      the current tree but missing from the registry) is a HARD violation
  #      (rc6 final: previously skipped via `continue`, which let an attacker
  #      silently introduce a new forged artifact). The writer path must
  #      register before the gate runs.
  #   4. Malformed registry / duplicate path lines / missing genesis line all
  #      fail-closed (no silent `reg_json="[]"` fallback).
  local runtime_registry_path="$project_dir/.harness/runtime-manifest.jsonl"
  local runtime_anchor_present=0 runtime_namespace_present=0 runtime_idx="" runtime_receipt="" runtime_ref="refs/harness/runtime-manifest"
  if ! type _runtime_validate_registry >/dev/null 2>&1 && [ -f "$project_dir/core/lib/runtime-manifest.sh" ]; then
    # shellcheck source=runtime-manifest.sh
    . "$project_dir/core/lib/runtime-manifest.sh"
  fi
  if type _runtime_anchor_index >/dev/null 2>&1; then
    runtime_idx="$(_runtime_anchor_index "$project_dir" 2>/dev/null || true)"
    runtime_receipt="$(_runtime_anchor_receipt "$project_dir" 2>/dev/null || true)"
    if { [ -n "$runtime_idx" ] && { [ -e "$runtime_idx" ] || [ -L "$runtime_idx" ]; }; } \
       || { [ -n "$runtime_receipt" ] && { [ -e "$runtime_receipt" ] || [ -L "$runtime_receipt" ]; }; } \
       || git -C "$project_dir" show-ref --verify --quiet "$runtime_ref" 2>/dev/null; then
      runtime_anchor_present=1
    fi
  fi
  runtime_namespace_present="$(jq -sr '
    [.[] | select(.path | test("^\\.harness/logs/runs/.*\\.(ndjson|log)$|^\\.harness/reviews/.*\\.jsonl$|^\\.harness/acceptance/[0-9a-f]+/(acceptance\\.json|A-G\\.log)$"))] | length
  ' "$cur_file" 2>/dev/null)"
  if [ -L "$runtime_registry_path" ] || { [ -e "$runtime_registry_path" ] && [ ! -f "$runtime_registry_path" ]; }; then
    mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" '{path:$p, reason:"runtime_manifest_not_regular"}')")
  elif [ -f "$runtime_registry_path" ]; then
    local reg_json reg_dup reg_genesis reg_genesis_expected reg_entry_count
    # Validate the append-only anchor-transition hash chain with the same
    # structural validator used by writers.  Merely selecting the last `to`
    # value would let a fabricated transition replace the trust root.
    if type _runtime_validate_registry >/dev/null 2>&1; then
      if ! _runtime_validate_registry "$project_dir" "$runtime_registry_path" >/dev/null 2>&1; then
        mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" '{path:$p, reason:"runtime_manifest_anchor_chain_invalid"}')")
      fi
      if ! type _runtime_verify_registry_anchor >/dev/null 2>&1 \
         || ! _runtime_verify_registry_anchor "$project_dir" "$runtime_registry_path" >/dev/null 2>&1; then
        mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" '{path:$p, reason:"runtime_manifest_index_anchor_mismatch"}')")
      fi
    else
      mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" '{path:$p, reason:"runtime_manifest_validator_missing"}')")
    fi
    if ! reg_json="$(jq -s '.' "$runtime_registry_path" 2>/dev/null)"; then
      # Malformed registry → fail-closed (never silently drop the binding).
      mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" '{path:$p, reason:"runtime_manifest_invalid"}')")
      reg_json="[]"
    fi
    # A duplicate path line would let a later (tampered) line rebind an earlier
    # registration; reject the registry wholesale.
    reg_dup="$(printf '%s' "$reg_json" | jq -r '[map(select(.path? != null)) | group_by(.path)[] | select(length > 1) | .[0].path] | length' 2>/dev/null)"
    if [ "$reg_dup" != "0" ] && [ -n "$reg_dup" ]; then
      mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" '{path:$p, reason:"runtime_manifest_duplicate_path"}')")
    fi

    # ---- Genesis anchor validation -------------------------------------------
    # Expected anchor (in priority order):
    #   (a) explicit RUNTIME_MANIFEST_GENESIS env var (set by DWM callers and
    #       canonical Reviewer), else
    #   (b) `git rev-parse HEAD` (the current working-tree HEAD).
    # The committed tree's genesis is the first line of the registry itself
    # (`{genesis: "<OID>"}`); if the in-tree line does not equal the expected
    # anchor, the registry has been tampered with.
    reg_genesis_expected="${RUNTIME_MANIFEST_GENESIS:-}"
    if [ -z "$reg_genesis_expected" ] && command -v git >/dev/null 2>&1 \
       && git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
      reg_genesis_expected="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)"
    fi
    reg_genesis="$(printf '%s' "$reg_json" | jq -r 'reduce .[] as $o (""; if ($o.genesis? | type) == "string" then $o.genesis elif ($o.anchor_transition? | type) == "object" then $o.anchor_transition.to else . end)' 2>/dev/null)"
    reg_entry_count="$(printf '%s' "$reg_json" | jq -r 'length' 2>/dev/null)"
    if [ -z "$reg_genesis" ]; then
      mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" '{path:$p, reason:"runtime_manifest_genesis_missing"}')")
    elif [ -n "$reg_genesis_expected" ] && [ "$reg_genesis" != "$reg_genesis_expected" ]; then
      mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" --arg e "$reg_genesis_expected" --arg a "$reg_genesis" \
        '{path:$p, reason:"runtime_manifest_genesis_mismatch", expected:$e, actual:$a}')")
    fi

    # First walk the trusted registry so a deleted or type-replaced artifact
    # cannot disappear from a current-manifest-driven loop.
    local cpath centry ckind rsha rsize actual
    while IFS= read -r centry; do
      [ -n "$centry" ] || continue
      cpath="$(printf '%s' "$centry" | jq -r '.path // empty')"
      ckind="$(printf '%s' "$centry" | jq -r '.kind // empty')"
      rsha="$(printf '%s' "$centry" | jq -r '.sha256 // empty')"
      rsize="$(printf '%s' "$centry" | jq -r '.size // -1')"
      [ -n "$cpath" ] || continue
      case "$cpath" in
        ".harness/logs/runs/"*.ndjson|".harness/logs/runs/"*.log|".harness/reviews/"*.jsonl|".harness/acceptance/"*/acceptance.json|".harness/acceptance/"*/A-G.log) ;;
        *) continue ;;
      esac
      if [ -L "$project_dir/$cpath" ] || [ ! -f "$project_dir/$cpath" ]; then
        mutable_violations+=("$(jq -nc --arg p "$cpath" '{path:$p, reason:"runtime_artifact_missing_or_not_regular"}')")
        continue
      fi
      if [ "$ckind" = "verdict" ]; then
        actual="$(head -c "$rsize" "$project_dir/$cpath" 2>/dev/null | {
          if type _runtime_stdin_sha256 >/dev/null 2>&1; then
            _runtime_stdin_sha256
          elif command -v sha256sum >/dev/null 2>&1; then
            sha256sum | awk '{print $1}'
          else
            shasum -a 256 | awk '{print $1}'
          fi
        } 2>/dev/null)"
        if [ -z "$actual" ] || [ "$actual" != "$rsha" ]; then
          mutable_violations+=("$(jq -nc --arg p "$cpath" '{path:$p, reason:"runtime_artifact_not_append_only"}')")
        fi
      else
        actual="$(_runtime_file_sha256 "$project_dir/$cpath" 2>/dev/null || true)"
        if [ -z "$actual" ] || [ "$actual" != "$rsha" ]; then
          mutable_violations+=("$(jq -nc --arg p "$cpath" '{path:$p, reason:"runtime_artifact_not_byte_equal"}')")
        fi
      fi
    done <<<"$(printf '%s' "$reg_json" | jq -c '.[] | select(.path? != null)' 2>/dev/null)"

    # Then walk the current runtime namespace solely to reject unregistered
    # additions (including symlink replacements).
    while IFS= read -r cpath; do
      [ -n "$cpath" ] || continue
      case "$cpath" in
        ".harness/logs/runs/"*.ndjson) ckind="ndjson" ;;
        ".harness/logs/runs/"*.log)    ckind="log" ;;
        ".harness/reviews/"*.jsonl)    ckind="verdict" ;;
        ".harness/acceptance/"*/acceptance.json) ckind="acceptance" ;;
        ".harness/acceptance/"*/A-G.log)          ckind="log" ;;
        *) continue ;;
      esac
      centry="$(printf '%s' "$reg_json" | jq -c --arg p "$cpath" 'map(select(.path == $p)) | .[0] // null' 2>/dev/null)"
      if [ "$centry" = "null" ] || [ -z "$centry" ]; then
        # rc6 final: unregistered runtime artifact = hard violation (previously
        # silently skipped, which let attackers introduce forged artifacts).
        # The genesis anchor + hard-failing register ensure this never fires
        # in a healthy run.
        mutable_violations+=("$(jq -nc --arg p "$cpath" --arg k "$ckind" \
          '{path:$p, reason:"runtime_artifact_unregistered", kind:$k}')")
        continue
      fi
    done <<<"$(jq -r '.path' "$cur_file" | tr -d '\r')"
  elif [ "$runtime_anchor_present" = "1" ] \
       || { [ -n "${RUNTIME_MANIFEST_GENESIS:-}" ] && [ "${runtime_namespace_present:-0}" -gt 0 ]; } \
       || { [ -f "$project_dir/core/lib/runtime-manifest.sh" ] && [ "${runtime_namespace_present:-0}" -gt 0 ]; }; then
    # A repository that ships the runtime-manifest contract cannot become a
    # pre-registry repository merely by deleting all three Git anchor parts
    # together with the registry. Runtime artifacts plus the in-repo contract
    # make the registry mandatory; this closes the "delete every trust-root
    # component" downgrade while leaving older projects that do not implement
    # this contract unaffected.
    mutable_violations+=("$(jq -nc --arg p ".harness/runtime-manifest.jsonl" '{path:$p, reason:"runtime_manifest_missing"}')")
  fi

  rm -f "$cur_file"

  local final
  final="$(printf '%s\n' "$result" | jq -c \
    --argjson mv "$(printf '%s\n' "${mutable_violations[@]}" | jq -R -s 'split("\n") | map(select(length>0) | fromjson)' 2>/dev/null || printf '[]')" \
    --argjson am "$(printf '%s\n' "${appended_mutable[@]}" | jq -R -s 'split("\n") | map(select(length>0))')" \
    --argjson fa "$(printf '%s\n' "${feature_advanced[@]}" | jq -R -s 'split("\n") | map(select(length>0))')" \
    --argjson ccm "$(printf '%s\n' "${content_changed_mutable[@]}" | jq -R -s 'split("\n") | map(select(length>0))')" \
    '.violations = (.violations + $mv) | .appended_mutable = $am | .feature_revision_advanced = $fa | .content_changed_mutable = $ccm | .valid = ((.violations | length) == 0 and (.new_non_mutable | length) == 0)')"
  printf '%s\n' "$final"
  if [ "$(printf '%s' "$final" | jq -r '.valid')" = "true" ]; then
    return 0
  fi
  return 1
}
