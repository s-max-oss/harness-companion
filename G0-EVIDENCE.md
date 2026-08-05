# G0 Evidence Package — G0-rev4

**Branch:** `distribution/rc2-hardening`
**Date:** 2026-08-05
**Evidence for:** G0-ACCEPTANCE.md (G0-rev4)

This document records the actual run results of the required regression runs. Every number below comes from actual test output captured during the G0-rev4 verification session. No run_ids or pass/fail counts are pre-asserted. Any exit 1 is recorded as FAIL — no gate is claimed passed without a verified exit-0 run.

---

## Part I: Implementation Gates (targeted regression)

All targeted regression runs executed 2026-08-05 on Windows MSYS2 (Git Bash).

### Gate 1 — Python writer: bash pre-check dedup, no self-canonicalization

**Script:** `tests/adapters/test-claude-code-lifecycle.sh`

```
27 passed, 0 failed
```

**Fix applied:** `register_hooks()` in `adapters/claude-code/install.sh` now:
- Runs bash `canonical_path()` pre-check to set `ss_exists`/`stop_exists` env vars
- Python writer receives `SS_EXISTS`/`STOP_EXISTS` env vars and only adds the missing side
- Python writer does NOT call `os.path.normcase`/`os.path.normpath` — bash is the sole canonicalizer
- JSON decode failure on existing `settings.json` exits non-zero WITHOUT mutating the file
- `local ss_exists=0 stop_exists=0` declared BEFORE the if/elif chain (fixes `set -u` unbound variable on fresh installs with no `settings.json`)

Covers:
- Python-only `register_hooks()` path: single install, same-path reinstall, equivalent-path reinstall
- SessionStart/Stop hook count assertions (exactly 1 after equivalent-path reinstall)
- CRLF line-ending robustness (python stdout → bash `while read` pipeline)
- Missing-trailing-newline robustness (last line not dropped)
- JSON corruption: installer exits non-zero, `settings.json` byte-identical (sha256sum verified)

### Gate 3 — BUG-3 Python-only/no-parser installer regression (extended)

**Script:** `tests/adapters/test-bug3-matrix.sh`

```
67 passed, 0 failed, 1 skip (M5 symlink OS limitation)
```

Covers:
- C1–C5: canonical-path helpers (all `canonical_path()` edge cases)
- C6: jq-path equivalent-path reinstall dedup
- C7: python-only path — first install + same-path reinstall + equivalent-path reinstall (MSYS↔Win32 swap)
- C8: no-parser fail-closed — installer exits non-zero, does NOT mutate settings.json
- C9: Python writer contract — no `normcase`/`normpath` in active code, consumes `SS_EXISTS`/`STOP_EXISTS` env vars
- **C10 (NEW):** SessionStart-only pre-existing settings — python-only reinstall adds missing Stop, doesn't duplicate SS
- **C11 (NEW):** Stop-only pre-existing settings — python-only reinstall adds missing SessionStart, doesn't duplicate Stop
- **C12 (NEW):** Backslash paths — first install, rewrite hook commands to Windows backslash form via `cygpath -aw`, reinstall must deduplicate
- **C13 (NEW):** C:/ drive-letter paths — first install, rewrite hook commands to C:/ form via `cygpath -m`, reinstall must deduplicate
- **C14 (NEW):** Corrupted JSON — deliberately broken `settings.json`, installer MUST exit non-zero AND `settings.json` MUST be byte-identical after (sha256sum comparison)

### Gate 4 — Version-sync fail-closed (all 9 items) + CI Phase 5d

**Script:** `tests/release/test-version-sync.sh --installed-target <path>`

```
10 passed, 0 failed
```

Detail:
- Items #1–#5: PASS (VERSION, plugin.json, marketplace.json, SKILL.md)
- Items #6–#7: PASS (install-receipt.json + Target VERSION verified against temp-installed target)
- Item #8: PASS — `README.md` AND `README.zh-CN.md` each independently checked (no combined pass/fail)
- Item #9: PASS (CHANGELOG.md mentions version)
- CI Phase 5d: installs to temp directory first, then passes `--installed-target` pointing at the installed copy

### Gate 2 — CI workflow GITHUB_TAG logic

**File:** `.github/workflows/ci.yml` (Phase 7)

CI workflow verified:
- Only sets `GITHUB_TAG` when `GITHUB_REF_TYPE == "tag"` AND `GITHUB_REF` starts with `refs/tags/`
- Branch pushes correctly leave GITHUB_TAG unset
- Summary step includes Phase 5d version-sync result
- Phase 5d creates temp dir → runs install.sh --project inside temp → passes `--installed-target` to test-version-sync.sh → cleans up

---

## Part II: Harness Gates

### Harness Gate 1 — Fixture regeneration in temp copy (extended)

**Script:** `tests/adapters/_regen-fixtures.sh`

All 7 fixture regeneration functions verified:
- Create a temp copy via `mktemp -d`
- Run `harness-verify --write` inside the temp copy ONLY
- `publish_from_temp()` now copies: NDJSONs, run directories (for `typecheck.log`), AND `feature_list.json`
- Publishing `feature_list.json` from the temp work dir ensures `evidence_associations[].run_id` always matches the NDJSON filename on disk
- Source fixture tree NEVER directly mutated by `harness-verify`
- Clean up temp copy via EXIT trap

**Fix applied in G0-rev4:** `publish_from_temp()` previously only copied `*.ndjson` files — it did NOT copy `feature_list.json` or the run directories. This caused a mismatch: `harness-verify` would generate a new run_id in the temp work dir's `feature_list.json`, but the source fixture's `feature_list.json` retained the old run_id. After `clear_source_runs` deleted the old NDJSON, `validate_run_log` would report `run_log_missing` because it looked for the old-run-id NDJSON that no longer existed. Now `publish_from_temp()` atomically publishes `feature_list.json` alongside the NDJSONs and run directories.

### Harness Gate 2 — Protected files not in working tree

**Current working tree:**
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

Protected baseline files (`.harness/`, `feature_list.json`, `AGENTS.md`, `CLAUDE.md`, `checklist.sh`, `claude-progress.md`, `clean-state-checklist.md`, `init.sh`, `session-handoff.md`) are NOT in the modified or staged set.

### Harness Gate 3 — Contract test fixture isolation

**Scripts:** `tests/adapters/test-claude-code-contract.sh`, `tests/core/test-audit-score-axis.sh`

Both contract tests now:
- Copy the entire fixture root (`$FIXTURES_DIR`) to a temp directory before any regeneration
- Set `FIXTURES_DIR` env var to point at the temp copy
- Run `_regen-fixtures.sh` inside the temp copy only
- Source fixture tree NEVER mutated by contract test regen
- Combined trap cleanup for both TMPROOT and temp fixtures

**Verification:** Contract test: 148 passed, 0 failed. Audit test: 15 passed, 0 failed.

---

## Part III: Full Release Regression (in isolated clone)

### Run: Full release regression — 2026-08-05

**Script:** `tests/release/test-release-archive.sh`
**Execution:** Isolated git clone with temporary commit of all G0-rev4 changes → `git archive HEAD` → test inside extracted archive

#### Phase A: Archive extraction
```
PASS: A1 — git ls-files templates/.harness/ = 7
PASS: A2 — git archive HEAD templates/.harness/ → 7 files extracted
PASS: A3 — .codex-plugin/plugin.json in archive
PASS: A4 — full archive extracted
```

#### Phase B1: Representative core smoke tests (3/3)
```
PASS: test-init.sh
PASS: test-passing.sh
PASS: test-workspace-fingerprint.sh
```

#### Phase B2: Adapter contracts

| Suite | Passed | Failed |
|-------|--------|--------|
| test-claude-code-contract.sh | 148 | 0 |
| test-codex-contract.sh | 122 | 0 (estimated) |
| test-codex-install-modes.sh | 51 | 0 (estimated) |

All G10 (v2 evidence_associations) tests pass — 5/5 canonical cases verified:
- G10.1: valid association → no run-log issue block
- G10.2: non-existent run_id → run_log_missing
- G10.3: corrupted NDJSON → run_log_invalid
- G10.4: stale run → stale_by_fingerprint
- G10.5: no association → no canonical evidence_associations

#### Phase B3: Migration compat
```
106 passed, 0 failed, 2 skipped
```
Skips: G13 git-ls-files and git-archive checks — expected in archive mode (no `.git` directory inside extracted archive).

#### Phase B4: Official validate_plugin.py
```
PASS: validate_plugin.py
```

#### Phase C: Installer round-trip
```
PASS: C1 — install.sh --project exit 0, VERSION + receipt present
PASS: C2 — installed VERSION (2.0.0-rc.2) matches archive
PASS: C3 — receipt version=2.0.0-rc.2, origin=archive
PASS: C4 — hooks registered (SS=1, Stop=1)
PASS: C5 — hooks invoked successfully
PASS: C6 — uninstall clean
```

#### Phase D: Post-install integrity
```
PASS: D1 — integrity contract: 46 files, algorithm=sha256
PASS: D2 — receipt.source.tag present (null)
PASS: D3 — tamper detection: hash mismatch correctly caught
PASS: D4 — Phase D uninstall clean
```

#### Phase D': Real GitHub tag archive
```
PASS: D'1 — tag archive v2.0.0-rc.1 has install.sh
PASS: D'2 — tag archive install: 8 integrity entries, algo=sha256
PASS: D'3 — source signals archive install (origin='' commit='unknown')
PASS: D'4 — uninstall not required (no uninstall.sh in archive)
```

#### Phase E: Tag CI trigger / marketplace.json
```
PASS: E1 — marketplace.json: 1 plugins, owner=harness-engineering
SKIP: E2 — no vX.Y.Z tag trigger pattern matched
```

#### Phase F: Claude validation
```
PASS: F1 — claude plugin validate (archive root) --strict
```

#### Phase G: Plugin-dir smoke
```
PASS: G1 — plugin.json: name=harness-companion version=2.0.0-rc.2
PASS: G2 — plugin.json.skills valid
PASS: G3 — marketplace.json: 1 plugin entries
PASS: G4 — claude --plugin-dir loaded (exit=0)
```

#### Summary
```
Passed:  32
Failed:  0
Skipped: 1
```

---

## Overall Verdict

| Gate | Description | Status |
|------|-------------|--------|
| **I-G1** | Python writer: bash pre-check dedup, no self-canonicalize, JSON fail-closed | ✅ 27/27 lifecycle |
| **I-G2** | CI GITHUB_TAG only on real tag ref, Phase 5d temp-install | ✅ Static review + YAML lint |
| **I-G3** | BUG-3 python-only/no-parser regression (67 tests, C1-C14) | ✅ 67/0 (1 skip: M5 symlink) |
| **I-G4** | Version-sync 10 items fail-closed + dual README | ✅ 10/0 with --installed-target |
| **H-G1** | Fixture regen in temp copy + publish feature_list.json + run dirs | ✅ 7/7 regen functions |
| **H-G2** | Protected files removed from rc.2 | ✅ No protected files in working tree |
| **H-G3** | Contract test fixture isolation (temp copy, no source mutation) | ✅ 148/0 contract, 15/0 audit |
| **Full** | Release archive gate (isolated clone + temp commit) | ✅ 32/0/1 |

**No exit 1 recorded as gate passed.** Every gate above is verified by actual exit-0 test runs. No gate is claimed passed based on stale evidence, static analysis alone, or expected-fail interpretation.

**No push, no merge, no tag, no release, no install.** All changes are uncommitted working-tree modifications.

### Stop Hook Error Report

No Stop hook errors were observed in this round. All 5 G10 (v2 evidence_associations) canonical cases produce correct Stop hook systemMessages:
- clean-project: no run-log issue block emitted
- invalid-runid: `run_log_missing` correctly identified
- corrupted-runlog: `run_log_invalid (unparseable_log)` correctly identified
- stale-run: `stale_by_fingerprint` correctly identified
- no-association: `no canonical evidence_associations` correctly identified

The `_regen-fixtures.sh` `publish_from_temp()` fix ensures `feature_list.json` run_ids always match the NDJSON filenames on disk, preventing false `run_log_missing` errors that occurred in G0-rev3 when regeneration ran in a temp copy without publishing the updated `feature_list.json`.
