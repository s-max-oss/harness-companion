# Changelog

All notable changes to harness-companion are recorded here. Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] — 2026-10-27 — DSH-only stable

First stable release of the DSH-only skill, promoting 2.0.0-rc.4 after a green
full suite and a reproducible acceptance run.

### Added

- `dsh/acceptance.ps1` — seven-scenario acceptance harness that drives the
  real `dsh/run.ps1` entry and writes one NDJSON evidence line per scenario
  (status, feature state machine, canonical evidence, WIP=1, handoff, consent
  boundary).
- `docs/acceptance/2026-10-27-dsh-2.0.0.md` — acceptance package with scope,
  environment, scenario table, evidence paths, and explicit non-coverage.

### Changed

- `F-CONV-08` (Codex forward evaluation) and `F-CONV-09` (its acceptance
  package) are deprecated: their subject pipeline was retired with the host
  adapters. Registry feature `F-DSH-02` covers the DSH acceptance harness and
  package instead.

### Validation

- DSH acceptance: **7 / 7 PASS** in 56 s; evidence under
  `tests/acceptance/evidence/20261027T133032Z/`.
- Full suite: **33 / 33 suites PASS** (86 min) through `core/harness-verify.sh`,
  run `20261027T133213Z-1125-3502`, associated with `F-DSH-02` (passing, registry
  revision 70).

## [2.0.0-rc.4] — 2026-10-27 — DSH-only release

The skill now targets DeepSeek Harness exclusively. Claude Code and Codex keep
working as tools; they simply no longer integrate this skill.

### Changed

- The DSH runtime moved from `adapters/dsh/` to `dsh/`. The root `SKILL.md` is
  the DSH entry; `dsh/install.ps1` copies it and the shared `core/`, `scripts/`,
  `templates/`, and `references/` into `<DSH_HOME>/skills/harness-companion`.
- `CLAUDE.md` was removed; `AGENTS.md` is the single operating manual.

### Removed

- `adapters/claude-code/`, `adapters/codex/`, their hook scripts and installers,
  `.claude-plugin/`, `.codex-plugin/`, the top-level `hooks/` registry,
  `scripts/hooks/`, `install.sh`, and `uninstall.sh`.
- Contract, lifecycle, install-mode, migration, and release-packaging suites
  that existed only to validate those hosts, plus the adapter-specific CI
  workflow.

### Added

- `tests/core/test-status-renderer.sh` keeps the evidence-rendering coverage
  that lived in the retired adapter suite (17 assertions): verified evidence,
  missing/corrupted run logs, stale fingerprint, missing associations, dangling
  `in_progress`, newline-joined blocks, and CR-free output. Fixtures are built
  at runtime so the test does not depend on committed absolute paths.

### Validation

- `bash tests/run-all.sh`: **33 / 33 suites PASS** (66 min wall clock through
  `core/harness-verify.sh`, run `20261027T110215Z-1172-24193`). The run is
  associated with `F-DSH-01`, which is marked `passing` at registry revision 64.
- `tests/core/test-status-renderer.sh`: 17 / 17 PASS.
- `dsh/smoke.ps1`: 9 / 9 PASS from the source tree and from an installed copy;
  install → smoke → uninstall round-trip verified.
- Release-gate adjustments for this DSH-only window, all reported in the suite
  output rather than hidden: the AC-16 `core/lib` budget is 200 lines for rc.4
  (actual 169, driven by the renderer hardening); negative-gate cases whose
  gates were retired now report `SKIP`; and the Codex real-Agent eval contract
  is parked as `tests/eval/contract-offline.sh` because its subject pipeline was
  removed with the host adapters (F-CONV-08 is blocked). A template-copy
  `CLAUDE.md` and a minimal `tests/run-all.sh` CI workflow were restored so the
  bootstrap and isolation gates keep testing something real.

### Host adapter and hook repair

#### Added

- `adapters/dsh/` — DeepSeek Harness adapter, the third host next to Claude
  Code and Codex: a DSH entry `SKILL.md`, `run.ps1` (Git Bash resolution, argv
  passthrough, Windows→POSIX path normalization, timeout), `install.ps1` /
  `uninstall.ps1` with receipt-based identity checks, `smoke.ps1` (nine bounded
  checks, ~50 s), and two references (execution recipes, host mapping).
- Installs to `%DSH_HOME%\skills\harness-companion` (DSH root rank 400), which
  shadows a v1 copy under `~/.agents/skills` (rank 500) without deleting it.

#### Changed

- README documents the third host. DSH exposes no skill lifecycle hooks, so
  SessionStart status injection and Stop handoff reminders become an explicit
  contract in the DSH `SKILL.md`; `/harness:*` commands become `run.ps1` actions.
- Stop hooks bound run-log validation by wall clock instead of skipping it:
  `HC_HANDOFF_BUDGET_SEC` (default 3 s) is checked before each passing feature,
  so a normal project still gets full validation (a fixture costs ~0.2 s) while
  a project with large run logs reports checked/truncated counts instead of
  timing out. The Claude Code Stop hook timeout rises from 5 s to 15 s on fresh
  and upgraded installs; Codex Stop hooks use 15 s as well.

#### Fixed

- `adapters/claude-code/install.sh` refuses to register hooks when the copied
  tree is incomplete — missing `SKILL.md`, `core/lib/status-renderer.sh`,
  `core/lib/validate-run-log.sh`, or either hook script exits 1 before
  `settings.json` is touched. A truncated archive previously produced a
  "successful" install whose hooks pointed at nonexistent files, failing on
  every session.
- Installing over an older layout now prunes leftover `scripts/hooks/*` entries
  from `settings.json`, so Claude runs exactly one SessionStart and one Stop
  hook. Matching uses fixed path suffixes because MSYS rewrites POSIX-looking
  argv and environment values into Windows form before native `jq` / `python`
  see them, so passing the install path as an argument never matched.
- Windows path arguments are normalized to forward slashes before the DSH
  launcher invokes bash. MSYS `sha256sum` switches to binary mode for backslash
  paths and prefixes the digest with `\`, and the workspace fingerprint cannot
  strip the project prefix — both surfaced as false `config_changed_since_run` /
  `workspace_changed_since_verification` refusals.
- `core/lib/status-renderer.sh` joins non-empty blocks with newlines. Command
  substitution strips trailing newlines, so the injected status and the Stop
  message previously arrived as one run-on line
  (`...leave them for the user.[!!] Features still in_progress...`).
- `core/lib/status-renderer.sh` strips CR from jq output. `jq.exe` under MSYS
  writes CRLF, so a run id read through `read` carried a trailing `\r`; the
  resulting NDJSON path never existed and every passing feature was reported as
  `run_log_missing`.

#### Validation

- `tests/adapters/test-claude-code-contract.sh`: **149 / 149 PASS** (~135 s),
  including the G10 stale/missing/corrupt run-log assertions and the G9
  `--project` install round-trip.
- `adapters/dsh/smoke.ps1`: 9 / 9 PASS in ~50 s, in both the source tree and
  the installed layout. Covers bash resolution, DSH frontmatter, status,
  feature listing, state machine, NDJSON evidence, the passing evidence gate,
  WIP=1, and the consent boundary.
- Claude Code hooks, invoked the way the host does (event JSON on stdin):
  SessionStart returns valid JSON with a populated `additionalContext`; Stop
  returns valid JSON with `systemMessage` in ~8.5 s on this repository
  (8 passing features, one stale fingerprint check, then a 3 s budget
  truncation note) and ~0.4 s on the contract fixtures. settings.json holds
  exactly one hook per event with a 15 s Stop timeout, and a second install
  reports idempotent.
- Installer integrity gate, negative test: a source tree without `SKILL.md`
  exits 1 with `install is incomplete — refusing to register hooks` and writes
  no `settings.json`.
- The repository's full suite (`bash tests/run-all.sh`, 4 h timeout) was
  deliberately not used as the gate for these adapter changes.

## [2.0.0-rc.3] — 2026-09-09 — Guided Conversational Initialization

Third release candidate. Adds a user-visible conversational `/harness:init`
workflow backed by a deterministic, fail-atomic executor and release-blocking
real-Agent evaluation.

### Added

- Guided project discovery, conflict resolution, complete Brief presentation,
  explicit approval/cancel handling, and a concise post-init explanation.
- Canonical `PROJECT_BRIEF.json` validation, provenance/default tracking, and
  type-matched templates for Node, Python, Rust, Go, shell, Electron, docs,
  mixed, and unknown projects.
- Fourteen versioned forward-evaluation scenarios with transcript, tree,
  objective-check, Reviewer, runtime-identity, and signed-result evidence.

### Hardened

- Fail-atomic init/update/resume behavior preserves user modifications and
  accepts mutations only through the approved initialization boundary.
- Real-Agent evaluation uses a zero-inheritance shell environment, immutable
  executable snapshots, exact ACL evidence for context and user tools, and a
  separately validated host-temp boundary.
- Eval candidate/result artifacts are canonical-name and byte-bound in the
  Git-anchored runtime registry; historical artifacts remain append-only.
- The forward-eval release signer was rotated for rc.3; only its public trust
  anchor is versioned, while the private key remains outside the repository.

### Validation

- Guided-init executor contract: 107 / 107 PASS.
- Forward-eval contract and Windows ACL recovery suites: PASS.
- Full repository suite and all 14 fresh real-Agent cases are release gates;
  their final run identifiers and hashes are captured in the rc.3 acceptance
  package.

## [2.0.0-rc.2] — 2026-08-04 — Distribution Hardening

Second release candidate. Focuses on distribution hardening — safe install/uninstall
lifecycle, plugin/marketplace packaging, version synchronization, and completing the
Claude Code distribution story.

### Added — Distribution & lifecycle

- **Claude Code plugin packaging** (AC-5):
  - `.claude-plugin/plugin.json` — Claude marketplace manifest with skills + hooks
  - `.claude-plugin/marketplace.json` — marketplace entry (owner=harness-engineering)
  - `adapters/claude-code/hooks/hooks.json` — `${CLAUDE_PLUGIN_ROOT}` hook paths
- **Claude Code uninstaller** (AC-4):
  - `adapters/claude-code/uninstall.sh` — safe uninstall with two safety gates:
    - Target gate: refuses to delete empty/root/home/non-harness-companion paths
    - Receipt gate: verifies install-receipt.json .skill == "harness-companion"
  - Settings fail-closed: timestamped backup, refuses mutation on corrupt JSON
  - `uninstall.sh` — top-level dispatcher (--claude/--codex/--all modes)
- **Codex status qualification** (AC-9):
  - Canonical wording: "code-complete-runtime-e2e-pending" replaces "unsupported"
  - `adapters/codex/PHASE5B_STATUS.md` — detailed evidence table
  - `adapters/codex/adapter.conf` — status field updated

### Fixed — Bug fixes (BUG-1, BUG-2, BUG-3)

- **BUG-1: Receipt upgrade contract** — same-version reinstall preserves upgrade_history;
  cross-version upgrade appends {from, to, at}; tarball installs set source.origin="archive"
- **BUG-2: VERSION file** — `VERSION` at repo root is single source of truth for all 9
  version-bearing artifacts; `test-version-sync.sh` gates consistency
- **BUG-3: Hook path normalization** — canonical path comparison via `cygpath -aw`/`-u`
  round-trip on MSYS, `readlink -f` on Linux; fail-closed without jq/python3
- **HAS_OUR_HOOKS detection** — replaced `grep -c` (broken on Windows Git Bash) with
  invariant-substring jq detection that works across all path formats
- **CHANGELOG.md §1.4** — corrected false CI workflow claim; CI has 8 phases

### Added — Test coverage (AC-6, AC-7a)

- `tests/adapters/test-claude-code-lifecycle.sh` — 27 lifecycle scenarios covering
  VERSION, receipt, upgrade, alternate-path, uninstall, tarball, safety gates
- Extended `test-claude-code-contract.sh` G9.6–G9.7 — alternate-path + uninstall (+7 tests)
- Extended `test-codex-install-modes.sh` G5.M20–M22 — VERSION, receipt, tarball (+9 tests)
- `tests/release/test-release-archive.sh` Phase C — installer round-trip inside archive

### Validation

| Suite | Result |
|-------|--------|
| Claude Code contract (`test-claude-code-contract.sh`) | 148 / 148 PASS |
| Claude Code lifecycle (`test-claude-code-lifecycle.sh`) | 27 / 27 PASS |
| Codex contract (`test-codex-contract.sh`) | 122 / 122 PASS |
| Codex install modes (`test-codex-install-modes.sh`) | 51 / 51 PASS |
| Core regression (init + passing) | 36 / 36 PASS |
| Release archive (Phase A+B+C, no validator) | 17 / 18 PASS |
| Version sync | 7 / 8 PASS (Codex plugin.json → F4) |

## [2.0.0-rc.1] — 2026-08-03 — Release Candidate

First release candidate after the Phase 4 (Claude Code adapter) and Phase 5b
(Codex adapter) acceptance rounds.

### Added — Phase 4: Core/Adapter split (v2 architecture)

- `core/` — business semantics, plain-text output, no protocol awareness
  - `core/harness-{audit,feature,status,verify}.sh` — top-level entry points
  - `core/lib/atomic_write.sh` — crash-safe writes via `mktemp` + `fsync`
  - `core/lib/baseline.sh` — SessionStart SHA baseline persistence
  - `core/lib/config-validate.sh` — JSON-schema-driven config checks
  - `core/lib/evidence.sh` — canonical vs legacy_audit_evidence disambiguation
  - `core/lib/harness-config.sh` — `.harness/config.json` loading
  - `core/lib/json-helpers.sh` — JSON input parsing (cwd, field extraction)
  - `core/lib/passing.sh` — passing eligibility + WIP=1 enforcement
  - `core/lib/project-detect.sh` — auto-detect project type
  - `core/lib/staleness.sh` — stale-evidence detection vs baseline
  - `core/lib/status-renderer.sh` — plain-text status + handoff rendering
  - `core/lib/validate-run-log.sh` — NDJSON run-log validation
  - `core/lib/workspace-fingerprint.sh` — content-hash workspace ID
- `adapters/claude-code/` — host protocol mapping (Claude Code)
  - `session-start.sh`, `stop-handoff.sh`
  - `install.sh` (`--user` / `--project` / `--symlink-core`)
- `scripts/` — v1.1.2 compatibility wrappers (zero business logic)
  - `harness-{audit,feature,status,verify}.sh` → `core/`
  - `hooks/{session-start,stop-handoff}.sh` → `adapters/claude-code/hooks/`
- `templates/` — canonical config templates
  - `feature_list.json`, `init.sh`, `.harness/config.schema.json`

### Added — Phase 5b: Codex CLI adapter

- `.codex-plugin/plugin.json` — Codex marketplace manifest (version 2.0.0-rc.1; semver prerelease)
- `.codex-plugin/skills/SKILL.md` — Codex skill definition
- `hooks/hooks.json` — Codex event-keyed hook registry
- `adapters/codex/` — host protocol mapping (Codex)
  - `session-start.sh`, `stop-handoff.sh`, `pre-tool-use.sh`
  - `_launcher.cmd` — shared Windows launcher establishing Git Bash runtime
  - `session-start.cmd`, `stop-handoff.cmd`, `pre-tool-use.cmd` — Windows wrappers
  - `install.sh` (`--repo` / `--user`; plugin mode prints Codex marketplace instructions)
  - `uninstall.sh`
  - `adapter.conf` — adapter metadata (`status=supported`)
  - `templates/AGENTS.md`, `templates/codex-progress.md`
- `core/lib/json-encode.sh` — cross-platform JSON encoder (shared with parser)

### Cross-platform runtime support

JSON encoding/parsing uses the first available runtime that passes a
**real execution probe** (not just `command -v`):

1. `python3` (cross-platform, pre-installed on most dev systems)
2. `python` (Windows Python launcher alias)
3. `py -3` (Windows Python launcher explicit version)
4. `jq` (often bundled with Git for Windows)
5. `powershell` (Windows-native `ConvertTo-Json` / `ConvertFrom-Json`)

This prevents the "py.exe exists but no Python installed" false positive
on Windows machines.

### Known limitations

- **PreToolUse is permissive fail-open** (`pretooluse_behavior=permissive_allow_all`,
  `pretooluse_status=policy_not_enabled`). Enforcement is a Phase 6 item.
- **Windows sandbox is degraded** (`windows_sandbox_degraded=true`). The
  Codex adapter requires Git Bash on PATH for `commandWindows` wrappers.
- **CI workflow** (`.github/workflows/ci.yml`) has 8 phases covering core
  regression, adapters, migration, validate_plugin.py, release archive gate,
  and negative gate tests. Still requires local regression before tagging
  for Windows-specific tests not covered by `ubuntu-latest` CI.

### Validation

Tested on Windows (real `cmd.exe` invocation across three runtime scenarios:

| Scenario | Result |
|---|---|
| Normal Python available | python3 selected, all hooks produce correct envelopes |
| No Python at all (`--no-python3`) | jq/powershell fallback, all hooks produce correct envelopes |
| Broken py.exe stub (`--fake-python3`) | Probe rejects py, jq/powershell fallback, all hooks produce correct envelopes |

| Suite | Result |
|---|---|
| Codex contract (`test-codex-contract.sh`) | 122 / 122 PASS |
| Codex install modes (`test-codex-install-modes.sh`) | 42 / 42 PASS |
| Claude Code adapter (`test-claude-code-contract.sh`) | 141 / 141 PASS |
| Core regression (11 suites) | 277 / 277 PASS |
| Official `validate_plugin.py` | exit 0 |

## [1.1.2] — Earlier release line

The pre-Phase-4 single-file layout (`scripts/harness-*.sh`) shipped
under 1.1.x. v1.1.2 callers can keep using the old `scripts/` paths via
the v1 compat wrappers in 2.0.0-rc.1.

## Repository

https://github.com/s-max-oss/harness-companion
