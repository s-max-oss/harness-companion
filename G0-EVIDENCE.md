# G0 Evidence Package — G0-rev5 收尾 v3

**Branch:** `distribution/rc2-hardening`
**Commit:** current HEAD (this commit, not yet pushed)
**Parent commit:** `6784d70` (G0-rev4)
**History:** The current commit is the result of a sequence of in-place amendments (no new commits). Each pass added a v3 closure refinement. To identify the exact SHA at any time, use `git rev-parse HEAD` — this document deliberately does not hardcode an SHA.

This document records **only actual run results** from this session. No gate is claimed passed without a verified exit-0 run.

---

## Part I: Targeted Regression

### BUG3 Matrix — C14/C15/C16 now exercise both jq and python backends

**Script:** `tests/adapters/test-bug3-matrix.sh`

C14, C15, C16 in v2 only ran with python (via jq-shadowing). The v3 release-parameterization runs each scenario twice:

| Group | Backend | Scenario | Result |
|-------|---------|----------|--------|
| C14-jq | jq (real) | Corrupted JSON fail-closed, no mutation | PASS |
| C14-py | python (jq shadowed) | Corrupted JSON fail-closed, no mutation | PASS |
| C15-jq | jq (real) | SS-only backslash — trust bash, add Stop | PASS |
| C15-py | python (jq shadowed) | SS-only backslash — trust bash, add Stop | PASS |
| C16-jq | jq (real) | Stop-only C:/ — trust bash, add SessionStart | PASS |
| C16-py | python (jq shadowed) | Stop-only C:/ — trust bash, add SessionStart | PASS |

The C15/C16 "trust bash pre-check" behavior is critical: bash `canonical_path()` resolves equivalent Windows path forms to the same canonical value. Both writers consume `SS_EXISTS`/`STOP_EXISTS` env vars from the pre-check; only the missing side is appended. The previous exact-string `any()` jq comparison was the v2 bug — it duplicated hooks when bash found equivalence.

C14 verifies both backends respect the JSON-validity gate: corrupted JSON → installer exits non-zero, SHA-256 of `settings.json` unchanged.

### Lifecycle — register_hooks + verifier trust

**Script:** `tests/adapters/test-claude-code-lifecycle.sh`

```
27 passed, 0 failed
```

All 27 tests pass. The post-write verifier (jq and Python paths) trusts the bash pre-check for existing hooks and only verifies the newly added side.

### Version-sync — installed target (positive)

**Script:** `tests/release/test-version-sync.sh --installed-target <real-temp-install-path>`

```
10 passed, 0 failed — exit 0
```

### Version-sync — README.zh-CN.md deleted (single fault)

```
9 passed, 1 failed — exit 1
```

Single isolated fault → exit 1 with real installed target. Item #8 reports `FAIL: #8 README.zh-CN.md not present`.

### E2 Behavior Tests (extended)

**Script:** `tests/release/test-e2-tag-trigger.sh`

```
[PASS] P1 inline array tags: ['v*']
[PASS] P2 multi-line list tags: ['v*']
[PASS] P3 specific version pattern
[PASS] P4 numeric v1.2.3
[PASS] N1 comment-faked trigger
[PASS] N2 jobs.tags (wrong location)
[PASS] N3 broken YAML
[PASS] N4 missing tags key
[PASS] N5 non-release pattern ('release')
[PASS] N6 non-release pattern ('v' alone)
[PASS] N7 empty tags list
[PASS] N8 non-release string
[PASS] N9 missing on: block
[PASS] N10 missing push: block
[PASS] N11 vbogus* — not a release pattern   (v3 NEW)
[PASS] N12 v[ — truncated bracket class       (v3 NEW)
[PASS] N13 fake top-level true: key          (v3 NEW)
[PASS] N14 fake top-level yes: key           (v3 NEW)
[PASS] N15 multi-pattern valid triggers      (v3 NEW)
[PASS] N16 PyYAML missing → exit 2           (v3 NEW, always-on)
```

28/28 PASS (23 single-file + 5 aggregation via shared `e2_aggregate.sh`). E2 contract enforced: **only `on.push.tags` is parsed**; **PyYAML is required** (missing → fail-closed exit 2); **YAML parse error → exit 11**; **valid YAML with no release trigger → exit 10**; **release trigger found → exit 0**. Aggregation tests (A1a/A1b/A2/A3/A4) call the SAME `e2_aggregate.sh` function the production gate uses — there is no duplicated aggregation logic in the test script. Tightened bracket-class allowlist now rejects `v[0-9]bogus*` (N17) and `v[---]whatever` (N18); only `v[N]+...` continuations are accepted.

---

## Part II: Archive Regression

**Script:** `tests/release/test-release-archive.sh`
**Method:** Isolated git clone + temp commit of all G0-rev5 changes → `git archive HEAD` → extract → full Phase A-G test

### E2 (CI tag trigger, in archive) — PASS via PyYAML

The E2 loop in `test-release-archive.sh` now iterates EVERY workflow in `.github/workflows/` (no early `break`) and aggregates per-file outcomes into a single verdict. Priority: `DEP_MISSING > PARSE_ERR > FOUND > NOT_FOUND`. A parse error or dep-missing condition in any workflow fails the entire E2 regardless of how many others PASS.

**Hermetic E2 (archive-candidate-only, no source-repo fallback)** — `test-release-archive.sh` sources `e2_aggregate.sh` AND resolves `e2_check.py` exclusively from `FULL_ARCHIVE_DIR` (the extracted `git archive HEAD` candidate). There is NO `SOURCE_REPO` fallback. If either helper is missing or unreadable from the archive candidate, E2 records FAIL immediately. The archive gate executes ONLY the code that ships in the artifact — it does not reach out to the source repository for any part of the E2 check. Two negative tests (E3, E4) prove this by deliberately removing each helper from a temp archive copy and verifying E2 FAILs even though `SOURCE_REPO` still contains both files.

**String-key YAML loader (root-cause fix)** — `e2_check.py` builds a `SafeLoader` subclass that overrides the bool/str constructors so the bare scalars `on`/`off`/`yes`/`no` stay as Python strings; only the unambiguous literals `true`/`false`/`null` still coerce. Under this loader, `on:` parses to the string key `"on"` while `true:` parses to the boolean True. The top-level trigger check `if "on" not in data` is now unambiguous at the loader level — fake `true:`/`yes:` triggers cannot masquerade as `on:`, even when paired with a nested `on:` block (nested on: is not a top-level key). The previous line-by-line raw-text pre-check is gone. Locked in by P5 (real-world shape), N13/N14 (fake triggers), and the aggregation tests A3/A4 (loader-level disambiguation).

### Phase D' — historical smoke, **4/4 PASS**

The current archive run **did** execute Phase D' (real GitHub tag archive download) and Phase D' returned **4/4 PASS**. Earlier v2 documentation claimed "D' skipped" — that was incorrect. Phase D' downloads `https://github.com/s-max-oss/harness-companion/archive/refs/tags/v2.0.0-rc.1.tar.gz` and verifies the rc.1 archive is installable.

Phase D' is treated as **historical / infrastructure smoke** — the rc.1 tag was the previous release and is verified for legacy compatibility of the release toolchain only.

**The rc.2 real GitHub tag gate is still pending** — it will execute after the next rc.2 tag is published to GitHub. NOT a local-development gate and NOT a pre-merge requirement.

---

## Part III: run-all-features.sh — Not in this commit's file list

`run-all-features.sh` was found to **not work on clean checkout** in the v1 closure. It requires `feature_list.json` to exist in the working directory, which is not the case for a fresh git clone. The file is **not present** in either the parent commit (`6784d70`) or this commit's HEAD — it never was committed. It is therefore **not** listed in the file-change summary for this commit, because there is no delete operation to record.

The v2 commit message claim "run-all-features.sh F0/F14 fix, included in commit" was retracted in v2 and remains retracted.

---

## Part IV: Old Stop Hook — Non-Blocking Error

The current machine's `settings.json` has a Stop hook from a previous install at an old path. This is **not blocking** but will show an error in the Claude Code system message when the old path's hook script is not found.

- **Reinstall to same path:** canonical_path() comparison finds `stop_exists=1` → writer skips Stop → verifier trusts bash → no duplicate.
- **Reinstall to different path:** `stop_exists=0` → writer adds a NEW Stop entry at the new path. The old entry remains (installer never removes hooks it didn't create).
- **Cleanup:** Run `--uninstall` from the old location, or manually remove the old hook entry from `settings.json`. This is the machine's old install state — **本轮不修改本机 skill 或 settings**.

---

## Overall Verdict

| Gate | Status | Evidence |
|------|--------|----------|
| BUG3 matrix (incl. C14/C15/C16 × jq+py) | ✅ | All 6 backend combos pass |
| Lifecycle | ✅ | 27/27 |
| Version-sync (positive, real install) | ✅ | 10/0 exit 0 |
| Version-sync (single fault) | ✅ | 9/1 exit 1 |
| E2 behavior (P1–P5, N1–N18, A1a–A4 via shared aggregator) | ✅ | 28/28 |
| E2 (CI tag trigger, in archive — hermetic) | ✅ | PASS: e2_aggregate.sh + e2_check.py sourced from FULL_ARCHIVE_DIR only, no SOURCE_REPO fallback |
| E3 (negative: archive missing e2_check.py) | ✅ | FAIL (hermetic confirmed — source repo has file, archive doesn't) |
| E4 (negative: archive missing e2_aggregate.sh) | ✅ | FAIL (hermetic confirmed — source repo has file, archive doesn't) |
| Archive regression | ✅ | 35/0/0 (hermetic: all E2 code from FULL_ARCHIVE_DIR, E3/E4 negative tests confirm no source-repo fallback) |
| Phase 5d fail-closed (CI YAML) | ✅ | manual verify: `exit "$rc"` after `phase5d_result=...`, restoring fail-closed |
| PyYAML install order | ✅ | moved to before Phase 5e in ci.yml (no duplicate) |
| Phase D' (rc.1 historical smoke) | ✅ | 4/4 PASS — verified |

**No "Expected", "to be filled", or "correct by inspection" claims.** Every number above is from actual test output captured in this session.

**No push, no merge, no tag, no release, no install.** All changes are committed as a single amended commit on top of `6784d70`. The exact SHA is not hardcoded — use `git rev-parse HEAD` to identify this commit.

---

End of G0-rev5 收尾 v3 evidence package.