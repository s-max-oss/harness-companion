# G0 Acceptance Package — Revision 4 (G0-rev4)

**Branch:** `distribution/rc2-hardening`
**Date:** 2026-08-05
**Basis:** User rejection of G0-rev3 with 5 implementation blockers:

1. Python writer still called `os.path.normcase`/`os.path.normpath` — must use bash pre-check exclusively
2. JSON parse/decode failure on existing settings.json did not exit non-zero or left file mutated
3. BUG3 matrix missing Python-only SessionStart-only, Stop-only, backslash, C:/, and corrupted JSON edge cases
4. CI Phase 5d must install to temp dir + pass `--installed-target`; both READMEs independently checked
5. Contract tests called regen that published back to source fixtures; must copy to temp first

This document describes the **fixes** applied for G0-rev4. Full evidence is in **[G0-EVIDENCE.md](G0-EVIDENCE.md)**.

---

## Implementation Blockers (4/4 fixed in code)

### F14.1 / Gate 1: Python writer uses bash pre-check, no self-canonicalization

**Root cause (G0-rev3):** `register_hooks()` Python writer in `adapters/claude-code/install.sh` still called `os.path.normcase(os.path.normpath(...))` in its `exists_in()` function — a second canonicalizer that could disagree with bash `canonical_path()`. Additionally, JSON decode failure on an existing-but-corrupt `settings.json` would silently overwrite it with `{}` plus the new hooks — violating the fail-closed contract.

**Fix applied (G0-rev4):**
- `register_hooks()` bash pre-check now sets `ss_exists`/`stop_exists` env vars via `canonical_path()` comparison
- Python writer receives `SS_EXISTS`/`STOP_EXISTS` env vars; it ONLY adds the missing side
- Python writer NO LONGER calls `os.path.normcase`/`os.path.normpath` — bash `canonical_path()` is the sole normalizer
- JSON decode failure on existing `settings.json` exits non-zero WITHOUT mutating the file (`sys.exit(1)`)
- `local ss_exists=0 stop_exists=0` declared BEFORE the if/elif chain (was inside `elif [ -f "$settings" ]` block — caused `unbound variable` on fresh installs with `set -u`)

### F14.4 / Gate 2: CI GITHUB_TAG only on real tag ref

**Root cause:** `.github/workflows/ci.yml` Phase 7 unconditionally set `GITHUB_TAG` from `$GITHUB_REF_NAME`. On branch pushes this was the branch name, not a tag — silently testing against local `git archive` while pretending to be a tag push.

**Fix applied:** Phase 7 only sets `GITHUB_TAG` when `GITHUB_REF_TYPE == "tag"` AND `GITHUB_REF` starts with `refs/tags/`. Branch pushes correctly leave GITHUB_TAG unset.

### F14.6 / Gate 3: BUG-3 Python-only/no-parser installer regression (extended to 14 tests)

**Root cause (G0-rev3):** C1–C9 covered canonical-path, jq-path, python-only first/same/equivalent-path, and no-parser fail-closed. But 5 Python-only real-installer edge cases were missing: SessionStart-only pre-existing settings, Stop-only pre-existing settings, Windows backslash paths, C:/ drive-letter paths, and corrupted JSON.

**Fix applied (G0-rev4):** Added C10–C14 to `tests/adapters/test-bug3-matrix.sh`:
- **C10** (SessionStart-only): pre-existing settings with only another skill's SessionStart hook → python-only reinstall adds missing Stop, doesn't duplicate SS
- **C11** (Stop-only): pre-existing settings with only a Stop hook → python-only reinstall adds missing SessionStart, doesn't duplicate Stop
- **C12** (Backslash): first install, then rewrite hook commands to Windows backslash form via `cygpath -aw` → reinstall must deduplicate
- **C13** (C:/): first install, then rewrite hook commands to C:/ form via `cygpath -m` → reinstall must deduplicate
- **C14** (Corrupted JSON): write deliberately broken JSON to settings.json → installer MUST exit non-zero AND settings.json MUST be byte-identical after (sha256sum comparison)

### F14.x / Gate 4: Version-sync all items fail-closed + CI Phase 5d temp-install

**Root cause (G0-rev3):** Version-sync items #6/#7 failed-closed when `--installed-target` was not provided (correct). But CI Phase 5d did not perform a real install → it couldn't pass `--installed-target`. Additionally, item #8 combined both READMEs into a single pass/fail — if one matched but the other didn't, it could pass or fail ambiguously.

**Fix applied (G0-rev4):**
- CI Phase 5d: creates temp dir → runs `install.sh --project` inside temp → passes `--installed-target` pointing at installed copy to `test-version-sync.sh` → cleans up temp
- Item #8: `README.md` and `README.zh-CN.md` each get their own independent PASS/FAIL line
- All 10 items pass with `--installed-target` provided

---

## Harness-Loop Blockers (3/3 fixed)

### H1: Fixture regeneration in temp copy + publish feature_list.json

**Root cause (G0-rev3):** `_regen-fixtures.sh` `publish_from_temp()` only copied `*.ndjson` files — it did NOT copy `feature_list.json` or the per-run directories. When `harness-verify` generated a new run_id, the temp work dir's `feature_list.json` was updated with the new run_id, but the source fixture's `feature_list.json` retained the old run_id. After `clear_source_runs` deleted the old NDJSON, the status renderer looked for the old-run-id NDJSON (via `feature_list.json` → `evidence_associations[].run_id`) and reported `run_log_missing` — even though a valid new NDJSON existed under a different name.

**Fix applied (G0-rev4):** `publish_from_temp()` now publishes:
1. `*.ndjson` files (as before)
2. Run directories (`<run_id>/` containing `typecheck.log`)
3. `feature_list.json` from the temp work dir (so run_ids stay in sync with NDJSONs)

This ensures `evidence_associations[].run_id` always matches an NDJSON filename on disk.

### H2: Protected files removed from rc.2 submission

**Root cause:** The previous `bd64b1e` commit had committed Tier-1/2 protected files.

**Fix applied (G0-rev3, preserved):** `git reset --hard e354706` reverted that commit. Current working tree contains only:
```
 M .github/workflows/ci.yml
 M G0-ACCEPTANCE.md
 M adapters/claude-code/install.sh
 M tests/adapters/_regen-fixtures.sh
 M tests/adapters/test-bug3-matrix.sh
 M tests/adapters/test-claude-code-contract.sh
 M tests/core/test-audit-score-axis.sh
 M tests/release/test-version-sync.sh
?? G0-EVIDENCE.md
?? run-all-features.sh
```
No protected files are tracked, modified, or staged.

### H3: Contract test fixture isolation (temp copy, no source mutation)

**Root cause (G0-rev3):** `test-claude-code-contract.sh` and `test-audit-score-axis.sh` called `_regen-fixtures.sh` directly, which published regenerated NDJSONs and `feature_list.json` back into the source `tests/adapters/fixtures/` tree. This violated the principle that contract tests must not mutate source fixtures.

**Fix applied (G0-rev4):**
- Both contract tests now copy the entire fixture root to a temp directory first
- Set `FIXTURES_DIR` env var to point at the temp copy
- Run `_regen-fixtures.sh` inside the temp copy only
- Combined EXIT trap cleans up both TMPROOT and temp fixtures
- Source fixture tree is NEVER mutated by contract test regeneration

---

## Regression Evidence — COMPLETED 2026-08-05

Both required regression runs have been executed. Full results are in **[G0-EVIDENCE.md](G0-EVIDENCE.md)**.

### Targeted regression (2026-08-05)
| Test | Result |
|------|--------|
| `test-bug3-matrix.sh` (Gate 3) | 67 passed, 0 failed, 1 skip |
| `test-claude-code-lifecycle.sh` (Gate 1) | 27 passed, 0 failed |
| `test-version-sync.sh --installed-target` (Gate 4) | 10 passed, 0 failed |
| `test-claude-code-contract.sh` (H-G3) | 148 passed, 0 failed |
| `test-audit-score-axis.sh` (H-G3) | 15 passed, 0 failed |
| CI workflow GITHUB_TAG + Phase 5d (Gate 2) | Static review passed |

### Full release regression (2026-08-05, isolated clone)
| Phase | Result |
|-------|--------|
| A (archive extraction) | 4/4 PASS |
| B1 (core smoke) | 3/3 PASS |
| B2 (adapter contracts) | Claude 148/0, Codex 122/0, Install modes 51/0 |
| B3 (migration compat) | 106/0 (2 archive-mode skips) |
| B4 (validate_plugin.py) | PASS |
| C (installer round-trip) | 6/6 PASS |
| D (integrity) | 4/4 PASS |
| D' (tag archive) | 4/4 PASS |
| E (marketplace) | 1 PASS, 1 SKIP |
| F (claude validate) | PASS |
| G (plugin-dir smoke) | 4/4 PASS |
| **Total** | **32 passed, 0 failed, 1 skipped** |

### Overall
All 4 implementation gates and all 3 harness gates verified. Full release archive gate: 32/0/1. **No exit 1 recorded as gate passed.** See [G0-EVIDENCE.md](G0-EVIDENCE.md) for complete per-gate detail and Stop hook error report.

---

## Changes from G0-rev3

| Area | G0-rev3 | G0-rev4 |
|------|---------|---------|
| Python writer canonicalization | Self-canonicalized via `normcase`/`normpath` | Uses bash pre-check `ss_exists`/`stop_exists` exclusively |
| JSON fail-closed | Not enforced | Exits non-zero, byte-identical `settings.json` verified |
| BUG3 matrix tests | C1–C9 (9 tests) | C1–C14 (14 tests) — +5 Python-only edge cases |
| Version-sync | 7 pass + 2 expected fail | 10/10 pass with `--installed-target` |
| README check | Combined pass/fail | Each README independently checked |
| CI Phase 5d | None (no `--installed-target`) | Temp install + `--installed-target` |
| Regen publish | Only `*.ndjson` files | NDJSONs + run dirs + `feature_list.json` |
| Contract test regen | Mutated source fixtures | Temp copy, no source mutation |
| `ss_exists` unbound | Bug: `local` inside `elif` block | Fixed: `local` before if/elif chain |
| Release archive | Run in main working tree | Isolated clone + temp commit → `git archive HEAD` |
| Evidence | Combined document | Separated G0-EVIDENCE.md with strict pass/fail |

---

## Constraints Preserved

- No push, no merge, no tag, no release, no install.
- No update of locally installed skill.
- No new commits yet (all changes are uncommitted working-tree modifications).
- Single commit for all G0-rev4 changes (per user directive: "完成后一次性提交复验").
- Protected baseline files never modified.
- Isolated clone used for release archive verification (temp commit, not in main working tree).

---

End of G0-rev4 acceptance package. Evidence in G0-EVIDENCE.md.
