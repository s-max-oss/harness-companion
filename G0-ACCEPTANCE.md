# G0 Acceptance Package — Revision 5 收尾 v3 (G0-rev5-v3-final)

**Branch:** `distribution/rc2-hardening`
**Commit:** current HEAD (this commit, not yet pushed)
**Parent commit:** `6784d70` (G0-rev4)
**History:** The current commit is the result of a sequence of in-place amendments (no new commits). To identify the exact SHA at any time, use `git rev-parse HEAD` — this document deliberately does not hardcode an SHA.

G0-rev5 core implementation was accepted at the v2 closure pass on top of `6784d70`. The current commit (`current HEAD`) is a v3 closure pass that fixes jq writer defects discovered during rc.2 review and tightens the E2 contract.

---

## 收尾 v3 变更（与 v2 的差异）

### V1: Unified writer contract — jq and Python both consume pre-check

**文件:** `adapters/claude-code/install.sh`

The v2 commit tightened the Python writer and the verifier, but the **jq writer path** was not exercised by C15/C16 (which shadowed jq) and contained two real defects:

1. **Bug 1 (line 767 in v2):** jq writer used `any(.[]?.hooks[]?; .command == $ss_cmd)` — exact-string comparison that did NOT consume the bash pre-check `ss_exists`/`stop_exists` result. When bash canonicalized equivalent paths (backslash form, C:/ form), the writer still added a duplicate hook because the raw command strings differed.

2. **Bug 2 (line 769 in v2):** jq writer checked `if [ -f "$settings" ] && jq -e . "$settings" ...` and on failure fell through to `printf '{}\n' > "$tmp"` — **overwriting the corrupted file** with `{}` and proceeding to write. This violated fail-closed / no-mutation.

**Fix:**

- **Unified JSON-validity gate BEFORE writer selection** (single place, both backends share it). If `settings.json` exists but is not valid JSON, the installer exits non-zero and leaves the file byte-identical.
- **Both writers consume `SS_EXISTS`/`STOP_EXISTS` env vars** exported from the bash pre-check. Only the missing side is added. The brittle exact-string `any()` comparison is gone.
- The Python writer was already correct (env-var-driven, JSON fail-closed); it is unchanged.

### V2: C14/C15/C16 parameterized for both jq and Python backends

**文件:** `tests/adapters/test-bug3-matrix.sh`

C14, C15, C16 in v2 only exercised the python backend (via jq-shadowing). After the jq writer fix, the matrix now runs each scenario **twice**: once with REAL jq in PATH, once with jq shadowed (python-only). Both backends must satisfy the same contract:

- **C14-jq and C14-py:** corrupted JSON → exit non-zero, SHA-256 of settings.json unchanged.
- **C15-jq and C15-py:** SS-only backslash form → bash pre-check trusts equivalence, Stop added → rc=0, SS=1 (trusted), Stop=1 (added).
- **C16-jq and C16-py:** Stop-only C:/ form → bash pre-check trusts equivalence, SessionStart added → rc=0, SS=1 (added), Stop=1 (trusted).

### V3: E2 tightened — strict release-tag allowlist + string-key YAML loader + repo-level aggregation

**文件:** `tests/release/test-release-archive.sh`, `tests/release/test-e2-tag-trigger.sh`, `tests/release/e2_check.py`

The v2 E2 had three gaps:

1. `vbogus*` and `v[` were accepted because the v2 `is_release_tag` was too permissive (any v-prefixed pattern with `*` or `[` and length ≤64).
2. A fake top-level `true:` (or `yes:`) coerced by PyYAML 1.1 to boolean True was indistinguishable from a legitimate `on:` trigger (also True under YAML 1.1). The v2 line-by-line raw-text pre-check could be defeated by clever formatting.
3. A workflow file with broken YAML was silently masked by a later valid workflow in the same directory (early `break` on first PASS).

**Fix:**

- **Strict allowlist:** `v*`, `v<X>.<Y>.<Z>`, `v<X>.<Y>.<Z>.<W>`, `v<X>.<Y>.*`, `v[N](...)?` only. `vbogus*` and `v[` are rejected.
- **String-key YAML loader (root-cause fix):** `e2_check.py` builds a `SafeLoader` subclass that overrides the bool/str constructors to keep the bare scalars `on`/`off`/`yes`/`no` as Python strings — only the unambiguous literals `true`/`false`/`null` still coerce. Under this loader, `on:` parses to the string key `"on"` while `true:` parses to the boolean True, so the top-level trigger check `if "on" not in data` is unambiguous at the loader level. The previous line-by-line raw-text pre-check is gone — the loader itself removes the entire class of ambiguity. Nested `on:` under another key is still ignored because E2 only inspects the top-level mapping.
- **Hermetic E2 (archive-candidate-only, no source-repo fallback):** `test-release-archive.sh` sources `e2_aggregate.sh` AND resolves `e2_check.py` exclusively from `FULL_ARCHIVE_DIR` (the extracted `git archive HEAD` candidate). There is NO `SOURCE_REPO` fallback. The archive gate executes ONLY the code that ships in the artifact. Two negative tests (E3/E4) prove hermetic isolation by deliberately removing each helper from a temp archive copy — both correctly fail even though SOURCE_REPO still contains the files.
- **Repo-level aggregation with structured exit codes:** the E2 loop iterates EVERY workflow in `.github/workflows/` (no early `break`). Per-file outcomes are reported as structured exits:
  - `0` = FOUND (release tag trigger detected)
  - `10` = NOT_FOUND (valid YAML, no release trigger)
  - `11` = PARSE_ERR (YAML parse error)
  - `2` = DEP_MISSING (PyYAML missing — fail-closed)
  Aggregation priority: `DEP_MISSING > PARSE_ERR > FOUND > NOT_FOUND`. A parse error in any workflow, or a dep-missing condition in any workflow, fails the entire E2 regardless of how many other workflows PASS. E2 PASSES only if at least one workflow has FOUND and no workflow has PARSE_ERR/DEP_MISSING.
- **Aggregation tests:** A1a/A1b (legal+corrupted in both orders → FAIL with PARSE_ERR), A2 (legal release + ordinary non-release → PASS), A3 (top-level `true:` + nested `on:` → FAIL — only the top-level `on` key counts), A4 (top-level `true:` + a real quoted `"on":` → PASS — only `"on"` counts, the boolean True block is ignored).
- **Behavior tests:** P5 (real-world workflow shape: `name:` first, `on:` later) + N11 vbogus*, N12 v[, N13 fake `true:`, N14 fake `yes:`, N15 multi-pattern positive, N16 PyYAML-missing (always-on fail-closed exit 2).

### V4: E2 behavior tests wired into CI

**文件:** `.github/workflows/ci.yml`

New Phase 5e runs `tests/release/test-e2-tag-trigger.sh` independently of `test-release-archive.sh`. Failure is a release blocker. The single-file tests (P1–P5, N1–N16) AND the aggregation tests (A1a, A1b, A2, A3, A4) both run.

---

## 变更文件清单（本次 v3-final 收尾，amend 到 current HEAD）

| 文件 | 状态 | 变更 |
|------|------|------|
| `adapters/claude-code/install.sh` | M | (frozen at v2 acceptance) JSON gate + jq writer uses SS_EXISTS/STOP_EXISTS env vars |
| `tests/adapters/test-bug3-matrix.sh` | M | (frozen at v2 acceptance) C14/C15/C16 parameterized for jq + python backends |
| `tests/release/test-release-archive.sh` | M | Phase E2 hermetic: all E2 code sourced from `FULL_ARCHIVE_DIR` only; no SOURCE_REPO fallback; E3/E4 negative tests prove hermetic isolation |
| `tests/release/e2_aggregate.sh` | M (new) | Single shared aggregation function — production gate and behavior tests call the SAME function. No duplicated logic in tests. |
| `tests/release/test-e2-tag-trigger.sh` | M | Sources shared `e2_aggregate.sh`; A1a–A4 call the production aggregator. Adds N17 (`v[0-9]bogus*`) and N18 (`v[---]whatever`) for tightened bracket-class validation. |
| `tests/release/e2_check.py` | M | String-key SafeLoader subclass (on/off/yes/no stay strings); structured exits 0/10/11/2; tightened bracket-class regex requiring `\+` continuation (`v[N]+...`) |
| `.github/workflows/ci.yml` | M | Phase 5d now `exit "$rc"` (fail-closed); PyYAML install moved to before Phase 5e |
| `G0-EVIDENCE.md` | M | v3-final rewrite, SHA references removed |
| `G0-ACCEPTANCE.md` | M | This file |

G0-rev5 prior amendments all preserved on the same commit via `git commit --amend`; each pass adds v3 closure refinements.

---

## 回归证据（v3 收尾后的实际运行结果）

Recorded in `G0-EVIDENCE.md`. Headline:

| 测试 | 结果 |
|------|------|
| BUG3 matrix（含 C14-jq/py、C15-jq/py、C16-jq/py） | **PASS** |
| Lifecycle | **PASS** |
| Version-sync (positive, real install target) | **PASS** |
| Version-sync (single fault README.zh-CN) | **9/1 exit 1** |
| E2 behavior tests (P1–P5, N1–N18, A1a–A4 via shared aggregator) | **28/0 PASS** |
| Archive regression (hermetic E2 + E3/E4 negative tests, FULL_ARCHIVE_DIR only) | **35/0/0 PASS** |
| Phase 5d fail-closed path (CI YAML) | **manually verified** — version-sync non-zero rc exits the CI step |
| E2 single + real aggregation tests | **28/0 PASS** |

---

## 约束保持

- 不 push、不 merge、不 tag、不 release、不更新本机安装
- 原始 v2 commit 已通过 amend 修改（不产生新 commit）
- 受保护基线文件未修改
- 文档不硬编码 commit SHA（commit 内容不能可靠硬编码自身 SHA）；使用 "current HEAD / this commit" 语言
- run-all-features.sh 不在文件清单中（parent 和 HEAD 都不存在，未列入删除项）

---

End of G0-rev5 收尾 v3 acceptance package. Evidence in G0-EVIDENCE.md.