# Harness Companion

> 🇨🇳 [简体中文](./README.zh-CN.md)

**v2.0.0-rc.1** — A multi-agent skill that automates Harness Engineering — the practice of building reliable coding environments for AI agents. It combines **automatic lifecycle hooks** with **interactive slash commands**, and ships native adapters for both **Claude Code** and **Codex**.

## Architecture (v2 — Core/Adapter split)

```
┌─────────────────────────────────────────────────────┐
│             Host agent (Claude Code / Codex)         │
└─────────────────┬───────────────────────┬───────────┘
                  │                       │
       adapters/claude-code/      adapters/codex/
                  │                       │
                  └─────────┬─────────────┘
                            │
                            ▼
                  ┌───────────────────┐
                  │   core/  (engine) │   ← pure bash, no host awareness
                  │  + libs (15 files)│
                  └───────────────────┘
                            ▲
                            │
              scripts/  (v1 compat wrappers — 4 lines each)
                            │
                  ┌───────────────────┐
                  │  SKILL.md (entry) │
                  └───────────────────┘
```

- **Core** owns all business semantics: feature tracking, evidence, audit, status rendering, run-log validation, workspace fingerprint, lock registry.
- **Adapters** do **only** host-protocol mapping: stdin JSON, fail-open trap, host envelope wrapping (Claude `hookSpecificOutput.additionalContext` / `systemMessage`; Codex `SessionStart` / `Stop` / `PreToolUse`).
- **scripts/** is a thin v1-compat layer (`exec bash ../core/<name>`) so old `/harness:*` callers keep working.

## What It Does

| Layer | How | What |
|-------|-----|------|
| **Hooks** (automatic) | SessionStart + Stop events | Inject harness health on session start, warn about handoff on session end |
| **Commands** (interactive) | 6 slash commands | Init scaffold, view health dashboard, manage features, run verification, generate handoff, audit all 7 subsystems |
| **Adapters** | Claude Code + Codex | Native protocol mapping for both agents; install picks one or both |

## Quick Start

### Install

```bash
# Clone
git clone https://github.com/s-max-oss/harness-companion.git

# Install (default: Claude Code adapter)
bash harness-companion/install.sh                          # global
bash harness-companion/install.sh --project                # project-local
bash harness-companion/install.sh --codex                  # Codex adapter
bash harness-companion/install.sh --all                    # both adapters

# Or invoke the adapter installer directly
bash harness-companion/adapters/claude-code/install.sh
bash harness-companion/adapters/codex/install.sh --repo ~/my-project
bash harness-companion/adapters/codex/install.sh --user
```

The install script:
- Copies `core/`, `adapters/<x>/`, `templates/`, `references/`, `scripts/` (v1 wrappers) to the target
- Registers SessionStart + Stop hooks in `~/.claude/settings.json` (auto-merging with any existing entries; idempotent; backup before modification)
- For Codex: writes `.codex/hooks.json` (repo-local) or `~/.codex/harness-hooks.toml` (user)
- Stamps `install-receipt.json` with version, source commit, and SHA-256 integrity manifest

### Commands

| Command | What It Does |
|---------|--------------|
| `/harness:init` | Generate harness scaffold from templates (AGENTS.md, CLAUDE.md, feature_list.json, init.sh, +4 optional) |
| `/harness:status` | Dashboard of file existence, feature progress, WIP=1 state, stale docs |
| `/harness:feature` | List / add / update features in `feature_list.json` |
| `/harness:verify` | Run `check → build → test` chain, auto-fill evidence |
| `/harness:handoff` | Generate `session-handoff.md`, run checklist verification |
| `/harness:audit` | Score all 7 harness subsystems (0-21), rank improvements by impact |

## Adapters

| Adapter | Hook Events | Output Path | Notes |
|---------|-------------|-------------|-------|
| **Claude Code** | SessionStart, Stop | `~/.claude/skills/harness-companion/` | Default. `hookSpecificOutput.additionalContext` for status; `systemMessage` for handoff warnings. |
| **Codex** | SessionStart, Stop, PreToolUse | `<project>/.codex/` or `~/.codex/` | Phase 5b. PreToolUse is permissive (policy not enabled). Plugin marketplace also supported via `.codex-plugin/plugin.json`. |

## The 7 Subsystems

Harness Companion is built around the 7 subsystems from the [Learn Harness Engineering](https://github.com/walkinglabs/learn-harness-engineering) course:

| # | Subsystem | Files |
|---|-----------|-------|
| 1 | **Knowledge** | `AGENTS.md`, `CLAUDE.md`, `docs/` |
| 2 | **Environment** | `init.sh` |
| 3 | **Progress** | `claude-progress.md` |
| 4 | **Scope/Feature** | `feature_list.json` |
| 5 | **Verification** | `checklist.sh`, test suite |
| 6 | **Observability** | `agent.log`, `evaluator-rubric.md` |
| 7 | **Handoff/Automation** | `session-handoff.md`, `clean-state-checklist.md`, `loop.sh` |

## Requirements

- **Claude Code** (for Claude Code adapter) — https://claude.ai/code
- **Codex CLI** (for Codex adapter) — see Codex marketplace
- Git Bash (Windows) / bash (macOS/Linux)
- `jq` (recommended) — for `/harness:feature` and run-log validation
- `python3` (optional) — fallback for Codex `hooks.json` construction on systems without `jq`

JSON runtime fallback: `python3 → python → py -3 → jq → powershell`, with a real execution probe (no `command -v` stubs).

## File Structure

```
harness-companion/
├── SKILL.md                       # Skill entry document (6 workflows)
├── README.md                      # English readme (this file)
├── README.zh-CN.md                # 简体中文说明
├── CHANGELOG.md                   # Version history
├── LICENSE                        # MIT
├── install.sh                     # Top-level dispatcher (Claude Code by default, --codex/--all supported)
├── core/                          # Pure bash semantic core (no host awareness)
│   ├── harness-audit.sh
│   ├── harness-feature.sh
│   ├── harness-status.sh
│   ├── harness-verify.sh
│   └── lib/                       # 15 library files (atomic_write, baseline, evidence, etc.)
├── adapters/
│   ├── claude-code/               # Claude Code protocol mapping
│   │   ├── hooks/                 # session-start.sh, stop-handoff.sh
│   │   └── install.sh
│   └── codex/                     # Codex protocol mapping (Phase 5b)
│       ├── hooks/                 # session-start, stop-handoff, pre-tool-use
│       ├── adapter.conf           # protocol_version=1, install_receipt schema_version=2.0.0
│       ├── UNSUPPORTED.md
│       ├── install.sh             # 3 modes: plugin/--repo/--user
│       └── uninstall.sh
├── .codex-plugin/
│   ├── plugin.json                # Codex plugin manifest (v 2.0.0-rc.1)
│   └── skills/                    # Codex-discoverable skill bundle
├── hooks/
│   ├── hooks.json                 # Codex event-keyed hook registry
│   └── README.md
├── scripts/                       # v1 compat wrappers (each ≤5 lines)
│   ├── harness-init.sh            # ← canonical impl (creates AGENTS.md, CLAUDE.md, feature_list.json, init.sh)
│   ├── harness-handoff.sh         # ← canonical impl (generates session-handoff.md, runs checklist.sh)
│   ├── harness-audit.sh           # → ../core/harness-audit.sh
│   ├── harness-feature.sh         # → ../core/harness-feature.sh
│   ├── harness-status.sh          # → ../core/harness-status.sh
│   ├── harness-verify.sh          # → ../core/harness-verify.sh
│   └── hooks/
│       ├── session-start.sh       # → ../../adapters/claude-code/hooks/session-start.sh
│       └── stop-handoff.sh        # → ../../adapters/claude-code/hooks/stop-handoff.sh
├── references/
│   ├── harness-files.md           # Full format reference
│   └── subsystems-mapping.md      # Subsystems ↔ files ↔ lessons
├── templates/                     # Copy-paste harness file templates (8 files)
└── tests/                         # 277+ tests across core/, golden/, adapters/
    ├── core/                      # Pure-bash unit + integration tests
    ├── golden/                    # Snapshot fixtures
    └── adapters/                  # Claude Code + Codex contract tests
```

## How Hooks Work

Two Claude Code hooks run automatically — no slash command needed:

- **SessionStart**: Detects harness files → reports health status → injects context into Claude's system prompt (`hookSpecificOutput.additionalContext`)
- **Stop**: Checks for uncommitted changes → detects dangling `in_progress` features → reminds to run checklist.sh (`systemMessage`)

Three Codex hooks:

- **SessionStart**: Same status injection logic, mapped to Codex's `hookSpecificOutput`
- **Stop**: Same handoff warnings, mapped to Codex `systemMessage`
- **PreToolUse**: Permissive fail-open (policy not enabled in Phase 5b)

All hooks are **non-blocking** (always return `{"continue":true}` on error) and **gracefully skip** non-harness projects (no `feature_list.json` → silent exit). 5-second timeout.

## License

MIT — see [LICENSE](./LICENSE)

---

Project repo: https://github.com/s-max-oss/harness-companion