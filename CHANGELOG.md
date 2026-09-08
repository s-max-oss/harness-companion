# Changelog

All notable changes to harness-companion are recorded here. Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
