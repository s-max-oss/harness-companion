# rc.2 Distribution-Hardening Specification

> **Status:** Approved / frozen. Sole implementation authority for `distribution/rc2-hardening`.
> **Predecessor:** `v2.0.0-rc.1` (tag `v2.0.0-rc.1` → `bbf283d` → `e13d56d`)
> **Branch:** `distribution/rc2-hardening` (currently at `e13d56d`, zero rc.2 commits)
> **Target release:** `v2.0.0-rc.2` — distribution baseline for guided-onboarding P2

---

## §0 Scope

This specification defines what rc.2 fixes and delivers. It is the sole implementation
authority for the `distribution/rc2-hardening` branch. The now-dismissed
`handoff-rc2/01-design-spec.md` does not exist in the repository and was never authority.

rc.2 is a **distribution-hardening release**. No new features. No behavioral changes to
the core engine, status renderer, audit, or hook semantics. The sole purpose is to make
the distribution installable, upgradeable, uninstallable, and verifiable by a real user.

---

## §1 Current Facts (rc.1 baseline, verified 2026-08-04)

### 1.1 Git identity

| Ref | Value |
|-----|-------|
| `v2.0.0-rc.1` annotated tag | tag object `bbf283d` → commit `e13d56d` |
| Merge commit | `e13d56d49189b0563d4ccd8af638df6e7bc1195b` |
| Branch HEAD at merge | `ef30b31` |
| `distribution/rc2-hardening` HEAD | `e13d56d` — identical to master; zero rc.2 commits |

The user's install receipt records both `source.commit: ef30b31` (branch HEAD when
`install.sh` ran) and `source.tag_commit: e13d56d` (merge commit the tag dereferences
to). Both are correct for their respective contexts.

### 1.2 What rc.1 ships

| Component | Path | Status |
|-----------|------|--------|
| Core engine | `core/` + `core/lib/` | Deployed |
| Claude Code adapter | `adapters/claude-code/install.sh`, `hooks/{session-start,stop-handoff}.sh` | Deployed |
| Codex adapter | `adapters/codex/install.sh`, `uninstall.sh`, `hooks/{session-start,stop-handoff,pre-tool-use}.{sh,cmd}` | Deployed |
| Codex plugin manifest | `.codex-plugin/plugin.json` | Deployed |
| Codex hook registry | `hooks/hooks.json` (root, `${PLUGIN_ROOT}` paths, Codex-owned) | Deployed |
| Top-level dispatcher | `install.sh` (→ adapters) | Deployed |
| Install receipt | `install-receipt.json` (per-adapter) | Deployed |
| v1 compat wrappers | `scripts/` | Deployed |
| Claude contract tests | `tests/adapters/test-claude-code-contract.sh` (G1–G10) | Deployed |
| Codex install-mode tests | `tests/adapters/test-codex-install-modes.sh` (G5.M1–M19) | Deployed |
| Release archive test | `tests/release/test-release-archive.sh` (Phase A: git-ls-files + git archive; Phase B: core smoke + adapter contracts + migration + validate_plugin.py) | Deployed |
| CI workflow | `.github/workflows/ci.yml` (8 phases: core → adapters → migration → validate_plugin.py → release archive gate → negative gate tests) | Deployed |
| Negative gate tests | `tests/release/test-negative-gates.sh` | Deployed |
| CHANGELOG | `CHANGELOG.md` | Deployed (rc.1 section only; contains factual errors — see §1.4) |
| SKILL.md | Root | Deployed (manual install + settings.json hook registration) |

### 1.3 What rc.1 does NOT ship

| Missing item | Evidence |
|-------------|----------|
| Claude Code uninstaller | `adapters/claude-code/uninstall.sh` does not exist |
| Top-level uninstall dispatcher | No `uninstall.sh` at repo root |
| `.claude-plugin/plugin.json` | No `.claude-plugin/` directory exists |
| `.claude-plugin/marketplace.json` | No `.claude-plugin/` directory exists |
| Claude plugin hook config | No `${CLAUDE_PLUGIN_ROOT}`-based hook config; root `hooks/hooks.json` is Codex-owned |
| `VERSION` file at repo root | No `VERSION` exists |
| `VERSION` file written by installer | Neither Claude nor Codex installer writes `$TARGET/VERSION` |
| Upgrade-safe receipt | Installer only updates `installed_at` on re-run; version, source, integrity, upgrade_history frozen |
| Path-normalized hook idempotency | Hook dedup uses raw `grep -qF` on command string |
| Lifecycle tests (upgrade, alternate-path, uninstall) | G9 covers clean install + same-path idempotency; no upgrade / alternate-path / uninstall coverage |
| Release archive installer round-trip | `test-release-archive.sh` has no install.sh → uninstall.sh round-trip |
| GitHub tag tarball verification | `test-release-archive.sh` uses `git archive HEAD`, not real GitHub tag tarball download |

### 1.4 Known errors in rc.1 CHANGELOG

`CHANGELOG.md` lines 71–73 state:

> **No CI workflow** for the harness-companion test suites yet (only
> `deploy-pages.yml` and `release-course-pdfs.yml` exist).

This is **factually incorrect**. `.github/workflows/ci.yml` exists with 8 phases
covering core regression, adapters, migration, validate_plugin.py, release archive
gate, and negative gate tests. The referenced `deploy-pages.yml` and
`release-course-pdfs.yml` workflows do not exist in this repository and may be
a copy-paste artifact from another project.

---

## §2 Bugs (confirmed, reproducible in rc.1)

### BUG-1 — Install receipt frozen on upgrade

**File:** `adapters/claude-code/install.sh:124–151`
**Also affects:** `adapters/codex/install.sh:260–310` (always writes fresh receipt — overwrites any prior upgrade_history)

**Root cause:**

```bash
# Line 124–145: Full receipt ONLY on first install
if [ ! -f "$RECEIPT" ]; then
  cat > "$RECEIPT" <<JSON
  { "skill": "harness-companion", "version": "2.0.0", ... }
JSON
fi

# Line 147–149: Only installed_at is touched on every run
jq --arg ts "$INSTALLED_AT" '.installed_at = $ts' "$RECEIPT" > "$RECEIPT.tmp" \
  && mv "$RECEIPT.tmp" "$RECEIPT"
```

**Observed behavior:**
1. First install writes full receipt (version, source, integrity)
2. Re-install / upgrade ONLY updates `installed_at`
3. `version` stays frozen
4. `source.commit` / `source.tag` not updated
5. Integrity hashes not regenerated
6. No `upgrade_history` entry appended

**Fix contract:**

| Scenario | Behavior |
|----------|----------|
| First install (no receipt) | Write fresh receipt with current version, source, integrity |
| Same-version reinstall (receipt.version == current) | Update `installed_at`, regenerate `integrity.files`; do **NOT** append `upgrade_history` |
| Version upgrade (receipt.version != current) | Update `version`, `source`, `installed_at`, regenerate `integrity.files`; **append** `upgrade_history[]` entry: `{from: <old>, to: <new>, at: <ISO8601>}` |
| Tarball install (no `.git`, no trusted build metadata) | `source.repository` preserved if unchanged; `source.commit` → `null`; `source.tag` → `null` unless explicit release metadata is present (e.g., `VERSION` matches a known tag pattern and the tarball was fetched from a trusted release URL); `source.origin` → `"archive"`; never retain stale git metadata from a prior install |

**rc.1→rc.2 upgrade test fixture (fixed, no network/git dependency):**

Tests must use a fixed receipt payload representing a canonical rc.1 install — not
depend on a live git tag or network fetch. The fixture is a checked-in JSON file:

`tests/fixtures/rc1-receipt.json`:
```json
{
  "skill": "harness-companion",
  "version": "2.0.0-rc.1",
  "schema_version": "2.0.0",
  "source": {
    "repository": "s-max-oss/harness-companion",
    "tag": "v2.0.0-rc.1",
    "tag_commit": "e13d56d49189b0563d4ccd8af638df6e7bc1195b",
    "commit": "ef30b31f2e2d309b34b14b30052259ae1c1502b",
    "commit_short": "ef30b31"
  },
  "installed_at": "2026-08-04T00:00:00Z",
  "installed_to": "/tmp/harness-test/.claude/skills/harness-companion",
  "integrity": {
    "algorithm": "sha256",
    "files": {
      "SKILL.md": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }
}
```

The upgrade test copies this fixture into the test target as `install-receipt.json`,
then runs the rc.2 installer and asserts: version → `2.0.0-rc.2`, `upgrade_history`
appended, `installed_at` updated, `integrity.files` regenerated.

**`integrity.files` contract:**

| Rule | Detail |
|------|--------|
| Coverage | All files under `$TARGET/` copied by the installer, excluding: `install-receipt.json` itself, `VERSION`, `settings.json` (not in target tree) |
| Algorithm | `sha256` |
| Key format | Path relative to `$TARGET/`, forward-slash separated (e.g., `"scripts/hooks/session-start.sh"`) |
| Rebuild trigger | Every install run (both same-version reinstall and upgrade) |
| Validation | Test: compare `jq -r '.integrity.files | to_entries[] | "\(.key) \(.value)"'` with `find $TARGET -type f | while read f; do sha256sum "$f"; done` — every covered file must have a matching hash, every hash entry must correspond to an extant file |

### BUG-2 — No VERSION file

**Files:** `adapters/claude-code/install.sh`, `adapters/codex/install.sh`, repo root

**Two-part gap:**

**(a) Repo-root `VERSION` missing.** No single source of truth for the current semver.
Installers hardcode `"2.0.0"` (Claude) or `"2.0.0"` (Codex).

**(b) `$TARGET/VERSION` not written.** Neither installer writes a VERSION file into
the install target, so `cat VERSION` fails and version checks require JSON parsing.

**Fix contract:**
- Create repo-root `VERSION` containing exactly the semver + trailing newline (e.g., `2.0.0-rc.2\n`)
- Both installers read version from `$REPO_ROOT/VERSION` (or a shared constant)
- Both installers write `$TARGET/VERSION` containing the same semver + trailing newline
- `install-receipt.json` `.version` → same value

**Version sync gate:**

Every version-bearing artifact must agree. The following list is normative:

| # | Artifact | Path | Update mechanism |
|---|----------|------|------------------|
| 1 | Repo VERSION | `VERSION` (repo root) | Manual edit before tag |
| 2 | Claude plugin manifest | `.claude-plugin/plugin.json` → `.version` | Manual, sync with #1 |
| 3 | Codex plugin manifest | `.codex-plugin/plugin.json` → `.version` | Manual, sync with #1 |
| 4 | Claude marketplace | `.claude-plugin/marketplace.json` → entries[].version | Manual, sync with #1 |
| 5 | SKILL.md frontmatter | `SKILL.md` → description/header text | Manual, sync with #1 |
| 6 | Install receipt | `$TARGET/install-receipt.json` → `.version` | Installer writes from #1 |
| 7 | Target VERSION | `$TARGET/VERSION` | Installer writes from #1 |
| 8 | README | `README.md` / `README.zh-CN.md` → version badge/text | Manual, sync with #1 |
| 9 | CHANGELOG | `CHANGELOG.md` → section header | Manual, sync with #1 |

Test: `tests/release/test-version-sync.sh` asserts all #1–#9 agree at release time.

### BUG-3 — Hook idempotency uses raw string match

**File:** `adapters/claude-code/install.sh:192–195`

**Root cause:**

```bash
if [ -f "$settings" ] && grep -qF "$hook_ss_cmd" "$settings" 2>/dev/null \
                        && grep -qF "$hook_stop_cmd" "$settings" 2>/dev/null; then
  echo "  hooks already registered in $settings (idempotent)"
  return 0
fi
```

`grep -qF` matches the literal command string. On Windows/MSYS/Git Bash, the same
absolute path can be represented in multiple forms:

| Form | Example |
|------|---------|
| MSYS `/c/` form | `/c/Users/20805/.claude/skills/harness-companion/scripts/hooks/session-start.sh` |
| Windows backslash form | `C:\Users\20805\.claude\skills\harness-companion\scripts\hooks\session-start.sh` |
| MSYS `/` form (same path, different drive notation) | `C:/Users/20805/.claude/skills/harness-companion/scripts/hooks/session-start.sh` |

If a re-install resolves the path through a different form, `grep -qF` won't match,
and hooks are duplicated.

Note: MSYS2 `/home/` is NOT a valid equivalence. On MSYS2, `/home/` maps to the
MSYS2 home directory (e.g., `/home/20805/`), which is a **different** filesystem
location from `/c/Users/20805/`. The two are not interchangeable. The test must
use genuinely equivalent path forms for the SAME directory.

**Fix contract:**

Architecture: jq/Python is responsible ONLY for extracting hook command strings from
`settings.json`. A separate **path normalizer** resolves each extracted path to a
canonical form before comparison. The normalizer is the single source of truth for
path equivalence; jq/Python never decides equivalence.

**Path normalizer contract:**

The normalizer:
1. Receives a hook command string (e.g., `bash "/c/Users/.../session-start.sh"`)
2. Extracts the script path (the argument to `bash`)
3. Resolves it to a canonical absolute path using the host's native resolver
4. Returns the canonical form for comparison

| Platform | Resolver |
|----------|----------|
| MSYS/Git Bash | `cygpath -aw "$path"` then back to POSIX via `cygpath -u` (round-trip forces canonical MSYS form) |
| Linux/macOS | `readlink -f "$path"` (or `realpath` if available) |
| Windows (no MSYS) | `cygpath -aw` equivalent via `python3 -c "import os; print(os.path.normpath(os.path.abspath(...)))"` |

**Fail-closed rule for no JSON parser:**

If neither jq nor python3 is available to extract existing hook entries from
`settings.json`, the installer must **fail closed**: exit with a clear error message
and do NOT mutate `settings.json`. The old "readlink then raw grep" fallback is
deleted — it cannot distinguish a bash script path from arbitrary JSON content,
and a false match on hook command strings is a silent hook-silencing bug.

Error message:
```
ERROR: Cannot safely check for existing hooks — neither jq nor python3 is available.
       Install jq (recommended) or python3 to proceed, or manually verify that
       SessionStart and Stop hooks in <settings.json> do not already reference
       <target-path>/scripts/hooks/ before re-running with HARNESS_SKIP_HOOK_CHECK=1.
```

**BUG-3 test contract:**

1. Clean install → verify 1 SessionStart entry, 1 Stop entry
2. Pre-seed `settings.json` with a SessionStart hook whose `command` uses a **different but equivalent** path form for the same target (e.g., `C:\Users\...` backslash form vs `/c/Users/...` POSIX form)
3. Run install again → verify SessionStart count is still 1 (not 2)
4. Same for Stop hook
5. Repeat with MSYS `C:/...` slash form vs `/c/...` form
6. **Path-with-spaces test:** install to a target path containing spaces (e.g., `/c/Users/Test User/.claude/skills/harness companion/`) → verify hooks registered with correctly quoted paths → re-install with alternate path form → count unchanged
7. **Fail-closed test:** remove jq and python3 from PATH → run install → assert exit ≠ 0, assert settings.json NOT mutated (hash unchanged)
8. **Windows/MSYS gate:** alternate-path acceptance tests must pass on a real Windows Git Bash runner. If CI only runs on `ubuntu-latest`, these tests are executed manually before release as a blocking pre-release gate

---

## §3 Gaps (missing capabilities, not bugs)

### GAP-1 — No Claude Code uninstaller

Codex has `adapters/codex/uninstall.sh` with `--repo`, `--user`, and plugin modes.
Claude Code has no uninstaller. No top-level `uninstall.sh` dispatcher.

**Required:**
- `adapters/claude-code/uninstall.sh` with `--user` and `--project` modes
- Removes: `$TARGET/` tree, hooks from `settings.json` (via jq, preserving other entries), timestamped backup before mutation
- Prints manual removal instructions for any items it cannot safely auto-remove
- Top-level `uninstall.sh` dispatcher (mirrors `install.sh`: `--codex`, `--all`)

### GAP-2 — No Claude Code plugin/marketplace packaging

#### GAP-2a: Current state

rc.1 ships Claude Code support via `adapters/claude-code/install.sh` which copies files
and registers hooks in `settings.json`. This is a **manual/adapter install path** — not
a Claude Code plugin.

Claude Code official plugin structure (per `@anthropics/claude-code` documentation):

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json          # Required: Plugin manifest
├── commands/                 # Slash commands (.md files)
├── agents/                   # Subagent definitions (.md files)
├── skills/                   # Agent skills (subdirectories)
│   └── skill-name/
│       └── SKILL.md
├── hooks/
│   └── hooks.json           # Plugin-scoped hook config
└── .mcp.json                # MCP server definitions
```

Current repo:
- `.codex-plugin/plugin.json` exists (Codex manifest)
- `hooks/hooks.json` exists (Codex registry, `${PLUGIN_ROOT}` paths)
- `SKILL.md` at root (manual install discovery)
- **No** `.claude-plugin/` directory
- **No** Claude-specific hook config

#### GAP-2b: Required additions

**1. `.claude-plugin/plugin.json`** — plugin manifest.

All component paths MUST start with `./`:

```json
{
  "name": "harness-companion",
  "version": "2.0.0-rc.2",
  "description": "Harness Engineering skill — evidence-backed feature pipeline for reliable AI coding environments",
  "author": {
    "name": "harness-engineering"
  },
  "homepage": "https://github.com/s-max-oss/harness-companion",
  "repository": "https://github.com/s-max-oss/harness-companion",
  "license": "MIT",
  "keywords": ["harness", "engineering", "feature-tracking", "evidence", "audit"],
  "skills": ["./"],
  "hooks": "./adapters/claude-code/hooks/hooks.json"
}
```

Path semantics:
- `"skills": ["./"]` — discover `SKILL.md` at the plugin root
- `"hooks": "./adapters/claude-code/hooks/hooks.json"` — Claude-scoped hook config inside the plugin tree

**2. `.claude-plugin/marketplace.json`** — marketplace entry.

Same-repo plugins use `"source": "./"`, not a bare GitHub URL string:

```json
{
  "name": "harness-engineering",
  "owner": {
    "name": "harness-engineering"
  },
  "description": "Harness Engineering tools for reliable AI coding workflows",
  "plugins": [
    {
      "name": "harness-companion",
      "version": "2.0.0-rc.2",
      "description": "Evidence-backed feature pipeline with status, audit, and handoff",
      "source": "./",
      "author": {
        "name": "harness-engineering"
      }
    }
  ]
}
```

`"owner"` is a required top-level field.

**3. Commands (exact, copy-paste runnable):**

```bash
# Add marketplace (from local checkout or GitHub shorthand)
claude plugin marketplace add .                         # local repo root
claude plugin marketplace add s-max-oss/harness-companion  # GitHub shorthand

# Install / verify / uninstall (use @owner, not bare name)
claude plugin install harness-companion@harness-engineering
claude plugin details harness-companion@harness-engineering
claude plugin uninstall harness-companion@harness-engineering

# Validate (strict mode)
claude plugin validate . --strict
```

**4. Claude plugin hook config** — `adapters/claude-code/hooks/hooks.json` (NEW file, NOT root `hooks/hooks.json`):

This is a Claude-scoped hook registry using `${CLAUDE_PLUGIN_ROOT}`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/adapters/claude-code/hooks/session-start.sh\"",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/adapters/claude-code/hooks/stop-handoff.sh\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**Design rule:** root `hooks/hooks.json` uses `${PLUGIN_ROOT}` → Codex.
`adapters/claude-code/hooks/hooks.json` uses `${CLAUDE_PLUGIN_ROOT}` → Claude.
Never reuse one host's hook config for the other.

**5. Acceptance:**
- `claude plugin validate . --strict` must pass
- `claude --plugin-dir .` smoke: plugin loads without error; must have an explicit timeout (30 s) and deterministic exit (not hang). If `claude` is not available, the gate is NOT skipped — it is deferred to the pre-release manual gate
- Isolated test: `claude plugin marketplace add .` → `claude plugin install harness-companion@harness-engineering` → `claude plugin details harness-companion@harness-engineering` → verify hooks fire → `claude plugin uninstall harness-companion@harness-engineering`
- CI: add a phase running `claude plugin validate . --strict`. CI may report `skipped` if the `claude` CLI is absent from the runner, but **skipped is NOT an AC pass**. Before release, a real Claude CLI run producing `passed` is blocking evidence (manual gate on a machine with `claude` installed)

### GAP-3 — Incomplete lifecycle test coverage

#### GAP-3a: What already exists

**G9 in `test-claude-code-contract.sh`** (lines 379–461) already covers:
- Clean `--project` install from empty directory → SKILL.md copied, core CLIs present + executable
- `settings.json` hook paths point inside installed target
- Installed hooks can be invoked (exit 0)
- Same-path re-install is idempotent (SessionStart count = 1, Stop count = 1 after re-install)

**G5 in `test-codex-install-modes.sh`** (M1–M19) already covers:
- Plugin mode (no-flag) prints instructions
- `--repo` creates hooks.json, copies core + adapter
- hooks.json paths reference installed copy (not source tree)
- Source-tree-move safety (G5.M11)
- No-jq fallback (G5.M12)
- Uninstall `--repo` removes created files (G5.M13)
- `--user` writes snippet, uninstall removes it (G5.M14–M19)

#### GAP-3b: What's missing

| Scenario | Claude | Codex |
|----------|--------|-------|
| Clean install → VERSION written | Missing | Missing |
| Clean install → receipt version matches VERSION | Missing | Missing |
| Same-version reinstall → no upgrade_history append | Missing | Missing |
| Cross-version upgrade → receipt updated (BUG-1) | Missing | Missing |
| Cross-version upgrade → upgrade_history appended | Missing | Missing |
| Alternate-path re-install idempotency (BUG-3) | Missing | N/A (Codex uses different dedup) |
| Uninstall → hooks deregistered from settings.json | Missing | N/A |
| Uninstall → target tree removed | Missing | ✅ G5.M13/M19 |
| Install from tarball (no .git) → source shows archive origin | Missing | Missing |

**Required:**
- New file: `tests/adapters/test-claude-code-lifecycle.sh` covering all Claude-missing rows
- Extend `tests/adapters/test-codex-install-modes.sh` with: VERSION, receipt upgrade (BUG-1), tarball source
- Extend `tests/adapters/test-claude-code-contract.sh` G9 with: alternate-path re-install, uninstall

### GAP-4 — No installer round-trip in release archive test

#### GAP-4a: What already exists

`tests/release/test-release-archive.sh` already covers:
- **Phase A (outer):** git-ls-files count, git archive extraction, plugin.json in archive
- **Phase B (inner, no .git):** core smoke tests, adapter contracts (Claude + Codex + install modes), migration compat, validate_plugin.py

CI Phase 7 gates on Phase 6 (validate_plugin.py passed) and runs the release archive test.
CI Phase 8 runs negative gate tests proving gates fail-closed.

#### GAP-4b: What's missing

- **installer round-trip:** `git archive HEAD` → `bash install.sh` → verify VERSION, receipt, hooks → invoke hooks → `bash uninstall.sh` → verify cleanup
- **Real GitHub tag tarball:** download `https://github.com/s-max-oss/harness-companion/archive/refs/tags/v2.0.0-rc.2.tar.gz` → same round-trip

**Required:**
- Add Phase C to `test-release-archive.sh`: `bash install.sh --project` inside extracted archive → verify VERSION/receipt/hooks → invoke hooks → `bash uninstall.sh --project` → verify cleanup
- Add Phase D: download real GitHub tag tarball → same round-trip (runs only when `GITHUB_TAG` env var is set, so it works both locally and in CI after tag push)

### GAP-5 — CHANGELOG errors and missing rc.2 section

#### GAP-5a: Errors to fix (see §1.4)

Lines 71–73 must be rewritten. The claim "No CI workflow … only deploy-pages.yml and release-course-pdfs.yml exist" is false. CI exists with 8 phases.

#### GAP-5b: Missing rc.2 section

No `## [2.0.0-rc.2]` entry. Add one covering all rc.2 changes.

#### GAP-5c: README install/uninstall matrix

README documents install but not uninstall. Two distinct lifecycles must be documented:

**Lifecycle A — Claude marketplace (plugin-managed):**
```bash
claude plugin marketplace add .                         # local repo
claude plugin marketplace add s-max-oss/harness-companion  # GitHub shorthand
claude plugin install harness-companion@harness-engineering
claude plugin details harness-companion@harness-engineering
claude plugin uninstall harness-companion@harness-engineering
```

**Lifecycle B — Manual adapter install (install.sh + uninstall.sh):**
```bash
bash install.sh [--user|--project] [--codex|--all]
bash uninstall.sh [--user|--project] [--codex|--all]
```

These two paths must NOT be mixed. A marketplace-installed plugin is managed by
`claude plugin`; a manually-installed adapter is managed by `install.sh`/`uninstall.sh`.

---

## §4 Codex Distribution Status — Required Wording

### 4.1 Canonical wording

Every public-facing document must use this exact qualification (or its Chinese equivalent
in `README.zh-CN.md`):

> Official hook/plugin protocol is documented; package validation and install contract
> tests pass; real Codex CLI hook firing/trust-flow E2E remains pending.

### 4.2 Prohibited phrasing

| Do NOT write | Because |
|-------------|---------|
| "unsupported" | Adapter is supported — code is complete, tests pass, validator passes |
| "native integration verified" | E2E has not been run against real Codex CLI |
| "fully validated" | Implies runtime E2E which hasn't happened |
| "production-ready" | Overstates the evidence |

### 4.3 Files to update

| File | Change |
|------|--------|
| `adapters/codex/adapter.conf` | `status=code-complete-runtime-e2e-pending` |
| `adapters/codex/UNSUPPORTED.md` | Delete file. Replace with `PHASE5B_STATUS.md` containing the canonical wording (§4.1) + summary of what IS verified |
| `README.md` | Apply canonical wording wherever Codex is described |
| `README.zh-CN.md` | Chinese equivalent of canonical wording |
| `SKILL.md` | Apply canonical wording |
| `CHANGELOG.md` | Apply canonical wording in rc.2 section |

---

## §5 Acceptance Criteria (AC)

### AC-1: BUG-1 fixed — receipt upgrade contract
- [ ] Same-version reinstall: updates `installed_at`, regenerates `integrity.files`; does NOT append `upgrade_history`
- [ ] Cross-version upgrade: updates `version`, `source.commit`, `source.tag`, `installed_at`; regenerates `integrity.files`; appends `upgrade_history[]` entry `{from, to, at}`
- [ ] Tarball install (no trusted build metadata): `source.commit` → `null`; `source.tag` → `null` (unless explicit release metadata present); `source.origin` → `"archive"`
- [ ] `integrity.files` covers all installed files (excl. receipt + VERSION + settings.json)
- [ ] `integrity.files` keys are forward-slash paths relative to `$TARGET/`
- [ ] `integrity.files` rebuilt on every install run
- [ ] First install (no receipt) writes fresh receipt with all fields
- [ ] Test: copy `tests/fixtures/rc1-receipt.json` as receipt → run rc.2 installer → verify version, upgrade_history appended, integrity regenerated
- [ ] Test: install rc.2 → reinstall rc.2 → verify `installed_at` updated, no duplicate upgrade_history
- [ ] Test: install from tarball (no .git) → verify `source.origin: "archive"`, `source.commit: null`, `source.tag: null`
- [ ] Both Claude and Codex installers

### AC-2: BUG-2 fixed — VERSION file + sync gate
- [ ] Repo-root `VERSION` exists, contains semver + trailing newline
- [ ] Both installers read from `$REPO_ROOT/VERSION` (or shared constant derived from it)
- [ ] `$TARGET/VERSION` written by both installers
- [ ] `tests/release/test-version-sync.sh` asserts all 9 artifacts in §2 BUG-2 table agree
- [ ] Test: `cat $TARGET/VERSION` equals `jq -r '.version' $TARGET/install-receipt.json`

### AC-3: BUG-3 fixed — hook path normalization
- [ ] Installer resolves `$TARGET` to canonical absolute path before constructing hook commands
- [ ] Idempotency check uses path-resolved comparison (not raw `grep -qF`)
- [ ] **All 8 tests in §2 BUG-3 test contract pass:**
  1. Clean install → 1 SessionStart, 1 Stop
  2. Pre-seed Windows backslash → re-install MSYS POSIX → count = 1
  3. Pre-seed MSYS `C:/...` slash → re-install `/c/...` → count = 1
  4. Pre-seed both hooks → re-install → both counts = 1
  5. G9 existing same-path idempotency still passes
  6. Path-with-spaces: install to `/c/Users/Test User/...` → re-install alternate form → count unchanged
  7. Fail-closed: no jq, no python3 → exit ≠ 0, settings.json hash unchanged
  8. Windows/MSYS gate: tests 2–6 pass on real Windows Git Bash (blocking pre-release if CI is Linux-only)

### AC-4: Claude Code uninstaller
- [ ] `adapters/claude-code/uninstall.sh --user` removes target tree + deregisters hooks from `~/.claude/settings.json`
- [ ] `adapters/claude-code/uninstall.sh --project` removes target tree + deregisters hooks from `<project>/.claude/settings.json`
- [ ] Writes timestamped backup before mutating settings.json
- [ ] Prints manual steps for anything not auto-removable
- [ ] Top-level `uninstall.sh` dispatcher (mirrors `install.sh`)
- [ ] Test: install → uninstall → target dir removed, hooks deregistered, backup present, other settings.json entries preserved

**Safety delete protection — uninstaller must refuse to delete unsafe targets:**

- [ ] **Receipt gate:** Before any deletion, verify `$TARGET/install-receipt.json` exists and its `.skill` field equals `"harness-companion"`. Refuse if missing or mismatched
- [ ] **Target gate:** Canonical target must match expected install paths:
  - `--user` → `$HOME/.claude/skills/harness-companion`
  - `--project` → `$(pwd)/.claude/skills/harness-companion`
  Refuse to delete if `$TARGET` is: empty string, `"/"`, `"$HOME"`, `"$HOME/"`, or any path that does not end with `harness-companion`
- [ ] **Settings fail-closed:** If `settings.json` exists but cannot be safely parsed as JSON (jq fails, python3 fails), keep the original file untouched and exit non-zero. Never mutate unparseable settings
- [ ] **Negative tests:**
  - Receipt missing → uninstaller refuses, exit ≠ 0, target untouched
  - Receipt `.skill` ≠ `"harness-companion"` → uninstaller refuses, exit ≠ 0, target untouched
  - `$TARGET` = `"/"` or `"$HOME"` → uninstaller refuses BEFORE any deletion, exit ≠ 0
  - `$TARGET` does not end with `harness-companion` → refuses
  - Corrupt `settings.json` (invalid JSON) → uninstaller exits ≠ 0, settings.json hash unchanged

### AC-5: Claude Code plugin/marketplace packaging
- [ ] `.claude-plugin/plugin.json` exists with valid JSON; all paths start with `./`; `"skills": ["./"]`, `"hooks": "./adapters/claude-code/hooks/hooks.json"`
- [ ] `.claude-plugin/marketplace.json` exists with valid JSON; `"owner": {"name": "harness-engineering"}` required; `"source": "./"`
- [ ] `adapters/claude-code/hooks/hooks.json` exists using `${CLAUDE_PLUGIN_ROOT}` paths
- [ ] Root `hooks/hooks.json` still uses `${PLUGIN_ROOT}` (Codex) — NOT repurposed for Claude
- [ ] `claude plugin validate . --strict` passes on a machine with real `claude` CLI (blocking pre-release gate)
- [ ] `claude --plugin-dir .` smoke: 30 s timeout, deterministic exit 0
- [ ] Isolated test: `claude plugin marketplace add .` → `claude plugin install harness-companion@harness-engineering` → `claude plugin details harness-companion@harness-engineering` → verify hooks → `claude plugin uninstall harness-companion@harness-engineering`
- [ ] CI phase for `claude plugin validate . --strict`: **skipped in CI is NOT an AC pass.** The phase may report `skipped` when CLI is absent, but the blocking evidence must come from a pre-release manual run with a real `claude` CLI producing `passed`

### AC-6: Lifecycle test coverage
- [ ] `tests/adapters/test-claude-code-lifecycle.sh` passes all scenarios in §3 GAP-3b Claude column
- [ ] `tests/adapters/test-codex-install-modes.sh` extended with: VERSION written, receipt upgrade, tarball source
- [ ] `tests/adapters/test-claude-code-contract.sh` G9 extended with: alternate-path re-install, uninstall
- [ ] All tests pass in isolated HOME/TMPDIR (no pollution of real user state)

### AC-7a: Release archive installer round-trip (pre-tag, LOCAL only)
- [ ] `tests/release/test-release-archive.sh` Phase C: `git archive HEAD` → `bash install.sh --project` → verify VERSION/receipt/hooks → invoke hooks → `bash uninstall.sh --project` → verify cleanup
- [ ] Runs locally and in CI (`git archive` is always available)
- [ ] NOT dependent on a pushed tag or GitHub availability — must pass before G0

### AC-7b: GitHub tag tarball round-trip (post-tag, requires pushed tag)
- [ ] `tests/release/test-release-archive.sh` Phase D: download real GitHub tag tarball (`$GITHUB_TAG` env) → install in temp HOME → invoke hooks → uninstall → verify cleanup
- [ ] Requires CI trigger on tag push (add `tags: ['v*']` to workflow or create separate release workflow)
- [ ] BLOCKING on failure
- [ ] **Not a G0/G2 prerequisite** — runs after tag push, gates G3 only
- [ ] Existing Phase A and Phase B unchanged (except adding `.claude-plugin/` to A3)

### AC-8: CHANGELOG + README
- [ ] `CHANGELOG.md` lines 71–73 corrected (CI workflow claim)
- [ ] `CHANGELOG.md` rc.2 section added listing all changes
- [ ] `README.md` (both languages): two lifecycles documented per §3 GAP-5c
- [ ] `README.md` (both languages): Codex canonical wording per §4
- [ ] All install/uninstall commands copy-paste runnable
- [ ] Version badges/numbers in README match `VERSION`

### AC-9: Codex status qualification
- [ ] `adapters/codex/adapter.conf`: `status=code-complete-runtime-e2e-pending`
- [ ] `adapters/codex/UNSUPPORTED.md` → deleted; replaced by `PHASE5B_STATUS.md` with canonical wording
- [ ] README (both languages): canonical wording applied
- [ ] SKILL.md: canonical wording applied
- [ ] CHANGELOG rc.2 section: canonical wording applied

---

## §6 Implementation Phases

### Phase 0 — Spec approval + spec-only commit
1. User/Codex reviews this spec
2. Approve or request changes
3. **Commit only the two spec files** to `distribution/rc2-hardening`:
   - `docs/superpowers/specs/2026-08-04-rc2-distribution-hardening.md` (this file)
   - `docs/superpowers/specs/2026-08-04-harness-init-guided-onboarding.md`
4. Both spec files are currently untracked (under `docs/` in the working tree).
   After commit, the new protection baseline is: 1 modified (`.gitignore`) + remaining untracked
5. `feature_list.json` is **never committed** to the product repo. It is a local
   harness operational-state file (per §9.3 two-tier classification). It may be updated
   locally as harness runtime state but must not enter product history. F0 completion is
   recorded by this spec being committed and approved.

### Phase 1 — Bug fixes (BUG-1, BUG-2, BUG-3)
1. Create repo-root `VERSION` containing `2.0.0-rc.2`
2. Fix BUG-1 in `adapters/claude-code/install.sh` (receipt upgrade contract)
3. Fix BUG-1 in `adapters/codex/install.sh` (receipt always overwrites — add conditional logic)
4. Fix BUG-2 in both installers (read from `VERSION`, write `$TARGET/VERSION`)
5. Fix BUG-3 in `adapters/claude-code/install.sh` (canonical path resolution)
6. Write `tests/release/test-version-sync.sh`
7. Commit: `fix: receipt upgrade contract, VERSION file, hook path normalization (BUG-1/2/3)`

### Phase 2 — Claude uninstaller + plugin/marketplace packaging
1. Write `adapters/claude-code/uninstall.sh` (`--user` / `--project`)
2. Write top-level `uninstall.sh` dispatcher (`--codex` / `--all`)
3. Create `.claude-plugin/plugin.json` with `"skills": ["./"]` and `"hooks": "./adapters/claude-code/hooks/hooks.json"`
4. Create `.claude-plugin/marketplace.json`
5. Create `adapters/claude-code/hooks/hooks.json` using `${CLAUDE_PLUGIN_ROOT}`
6. Apply Codex canonical wording to all public docs (§4.3)
7. Fix CHANGELOG errors (§1.4)
8. Commit: `feat: Claude uninstaller, .claude-plugin manifest + marketplace, Codex status qualification`

### Phase 3 — Test matrix
1. Write `tests/adapters/test-claude-code-lifecycle.sh`
2. Extend `tests/adapters/test-codex-install-modes.sh` with upgrade + VERSION + tarball tests
3. Extend `tests/adapters/test-claude-code-contract.sh` G9 with alternate-path + uninstall
4. Add Phase C (installer round-trip) to `tests/release/test-release-archive.sh`
5. Add Phase D (GitHub tag tarball) to `tests/release/test-release-archive.sh`
6. Add Claude plugin validate CI phase
7. Commit: `test: Claude lifecycle matrix, extended G9, release archive installer round-trip`

### Phase 4 — Documentation
1. Write rc.2 section in `CHANGELOG.md`
2. Update `README.md` and `README.zh-CN.md` with two-lifecycle install/uninstall matrix
3. Update version references in README badges/text
4. Commit: `docs: CHANGELOG rc.2, README install/uninstall matrix, version sync`

### Phase 5 — Release (phased gates)

#### 5.0 Local Readiness — LR (G0 prerequisite)

Must be 100% green before requesting G0. Any `skipped` or `failed` blocks G0.

| # | Evidence | Source | Gate |
|---|----------|--------|------|
| LR1 | AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-8, AC-9 all passed | Local test output | G0 |
| LR2 | AC-7a Phase C passed (`git archive HEAD` → install → uninstall) | Local `tests/release/test-release-archive.sh` | G0 |
| LR3 | Windows Git Bash BUG-3 gate (tests 2–6, 8) passed | Real Windows Git Bash | G0 |
| LR4 | `claude plugin validate . --strict` passed | Real Claude CLI | G0 |
| LR5 | `claude plugin marketplace add .` → `install@harness-engineering` → `details` → `uninstall` full round-trip passed | Real Claude CLI | G0 |

AC-7b (Phase D, GitHub tarball) is explicitly NOT in LR — it requires a pushed tag.

After LR all-green: request G0.

#### 5.1 PR Gate (G1 prerequisite)

Must be 100% green before requesting G1.

| # | Evidence | Source | Gate |
|---|----------|--------|------|
| PR1 | PR CI all 8 phases green (on `ubuntu-latest`) | `.github/workflows/ci.yml` | G1 |
| PR2 | Protected-path gate (§8) — no commit touches protected paths | `git diff --stat master...HEAD` | G1 |
| PR3 | Worktree gate (§9.2) — no commit touches protected working-tree files | `git diff --stat master...HEAD` | G1 |
| PR4 | Review complete, no blocking findings | User/Codex review | G1 |

After PR Gate all-green: request G1 merge.

#### 5.2 Tag Gate (G2 prerequisite)

Must be 100% green before requesting G2.

| # | Evidence | Source | Gate |
|---|----------|--------|------|
| TG1 | Post-merge master CI all 8 phases green | `.github/workflows/ci.yml` (push to master) | G2 |
| TG2 | Tag target commit == CI-verified master HEAD | `git rev-parse master` | G2 |
| TG3 | Pre-tag archive verification: `git archive HEAD` → Phase C round-trip passed | Local run | G2 |

After Tag Gate all-green: request G2.

#### 5.3 Post-tag Gate (G3 prerequisite)

Must be 100% green before requesting G3.

| # | Evidence | Source | Gate |
|---|----------|--------|------|
| PT1 | Tag-triggered CI Phase D: download real GitHub tarball for `v2.0.0-rc.2` → install → invoke → uninstall round-trip passed | CI (tag push trigger, `tags: ['v*']`) | G3 |

After Post-tag Gate all-green: request G3 prerelease.

#### 5.4 Post-release
- **User authorization G4:** update real local install from published release
- **User authorization G5:** `gh repo edit` — release checklist only, not code scope
- Confirm `master` clean

---

## §7 Release Gates

Per guided-onboarding spec §14, each gate requires explicit user authorization in the
same session. No automation, no pre-approval.

| Gate | Action | Authorization | Scope |
|------|--------|---------------|-------|
| G0 | Push branch + open PR to master | User must say "push" or "open PR" | External change |
| G1 | Merge PR → master | User must say "merge" | Repository mutation |
| G2 | Create + push annotated tag `v2.0.0-rc.2` | User must say "tag" | Immutable release |
| G3 | GitHub pre-release publish | User must say "release" | Public distribution |
| G4 | Update real local install from release | User must say "install" | Local machine mutation |
| G5 | `gh repo edit` (topics, description) | User must say "edit repo" | External metadata |

G0 is new in r2 — rc.1 was already on master; rc.2 is on a branch and requires PR
authorization before any external change.

G4 applies ONLY to updating the real `~/.claude/skills/harness-companion/` (or Codex
equivalent) after the release is published — not to isolated test installs in temp
directories, which are automated and non-destructive.

G5 is NOT in rc.2 code scope (release checklist item only).

---

## §8 Protected Paths

These paths must not be modified by any rc.2 commit:

| Path | Reason |
|------|--------|
| `scripts/harness-init.sh` | rc.1 executor — immutable per guided-onboarding §15 |
| `core/` (all files) | No behavioral changes |
| `core/lib/` (all files) | No behavioral changes |
| `templates/` (all files) | Scaffold templates — frozen until P2 |
| `adapters/*/hooks/*.sh` | Hook semantics — no behavioral changes |
| `tests/adapters/test-claude-code-contract.sh` (G1–G8, G10) | Contract gold standard |
| `tests/adapters/test-codex-contract.sh` | Contract gold standard |
| `hooks/hooks.json` (root) | Codex hook registry — immutable |
| `docs/superpowers/specs/2026-08-04-harness-init-guided-onboarding.md` | Frozen spec |

**Permitted modifications to protected paths:**

| Path | Permitted change | Reason |
|------|-----------------|--------|
| `tests/adapters/test-claude-code-contract.sh` G9 | Extend with alternate-path + uninstall | G9 is the install round-trip test — extending it is the point of rc.2 |
| `SKILL.md` | Codex canonical wording + two-lifecycle install docs | Documentation only; no architectural changes |
| `README.md` / `README.zh-CN.md` | Codex wording + install matrix + version | Documentation only |

---

## §9 Working Tree Protection

### 9.1 Phase 0: baseline

Before any rc.2 code commits, only the two spec files are committed:

```
docs/superpowers/specs/2026-08-04-harness-init-guided-onboarding.md  (already exists)
docs/superpowers/specs/2026-08-04-rc2-distribution-hardening.md      (this file)
```

### 9.2 Post-Phase-0 protection baseline

After the spec-only commit, the remaining working tree is classified into two tiers:

**Tier 1 — Byte-equal protected baseline.** rc.2 commits must NOT touch, stash, commit,
or clean any of these files. They are the rc.1 work area and will be resolved after
rc.2 ships.

| Status | Path |
|--------|------|
| Modified (tracked) | `.gitignore` |
| Untracked | `.harness/`, `AGENTS.md`, `CLAUDE.md`, `checklist.sh`, `claude-progress.md`, `clean-state-checklist.md`, `init.sh`, `session-handoff.md` |

**Tier 2 — Operational state.** Excluded from byte-equal protection. May be updated
locally as harness runtime state. Must never enter a product commit.

| Status | Path | Policy |
|--------|------|--------|
| Untracked | `feature_list.json` | Local harness operational state; may be updated (F0 status, evidence); never committed |

### 9.3 feature_list.json policy

**Recommendation:** Keep `feature_list.json` **untracked permanently** — never commit
it to the product repository. It is a local harness operational-state file (like
`.harness/logs/` or `.harness/.registry.lock/`). It lives in the working tree so the
harness tooling can read and update it, but it is never part of a product commit.

**Two-tier protection classification:**

| Tier | Paths | Rule |
|------|-------|------|
| Byte-equal baseline | `.gitignore`, `.harness/`, `AGENTS.md`, `CLAUDE.md`, `checklist.sh`, `claude-progress.md`, `clean-state-checklist.md`, `init.sh`, `session-handoff.md` | Must NOT be touched, stashed, committed, or cleaned |
| Operational state | `feature_list.json` | May be updated as local harness runtime state (e.g., status changes, evidence associations). Must NOT be committed to the product repo |

**F0 completion:** Recorded by this spec being committed and approved — not by
mutating `feature_list.json`. The F0 status change in `feature_list.json` is a
local operational update only and is excluded from product commit scope.

**Prior r1/r2 contradiction resolved.** The earlier requirement "never modify
feature_list.json" conflicted with "F0 must be marked completed." The two-tier
classification resolves this: byte-equal protection applies to product artifacts;
operational state files may be updated locally without entering product history.

---

## §10 References

- Guided-onboarding spec: `docs/superpowers/specs/2026-08-04-harness-init-guided-onboarding.md` (frozen)
- Claude Code plugin docs: `@anthropics/claude-code` (`.claude-plugin/plugin.json`, marketplace, `claude plugin` CLI)
- rc.1 tag: `v2.0.0-rc.1` → `bbf283d` → `e13d56d`
- Install receipt: `~/.claude/skills/harness-companion/install-receipt.json` (SHA `b7483fe...`)
- CI: `.github/workflows/ci.yml` (8 phases)
- Release archive test: `tests/release/test-release-archive.sh` (Phase A + B)
- Negative gate tests: `tests/release/test-negative-gates.sh`
- Codex install-mode tests: `tests/adapters/test-codex-install-modes.sh` (G5.M1–M19)
- Claude contract test G9: `tests/adapters/test-claude-code-contract.sh:379–461`
- CHANGELOG: `CHANGELOG.md` (rc.1 section has factual errors per §1.4)
