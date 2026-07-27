# Harness Companion

> 🇨🇳 [简体中文](./README.zh-CN.md)

A [Claude Code](https://claude.ai/code) skill that automates Harness Engineering — the practice of building reliable coding environments for AI agents. It combines **automatic lifecycle hooks** with **interactive slash commands** to keep your project's harness files healthy.

## What It Does

| Layer | How | What |
|-------|-----|------|
| **Hooks** (automatic) | SessionStart + Stop events | Checks harness readiness on session start, reminds about handoff on session end |
| **Commands** (interactive) | 6 slash commands | Init harness scaffold, view health dashboard, manage features, run verification, generate handoff, audit all 7 subsystems |

## Quick Start

### Install

```bash
# 1. Clone this repo into your Claude Code skills directory
git clone https://github.com/s-max-oss/harness-companion.git ~/.claude/skills/harness-companion

# 2. Run the install script to register hooks
bash ~/.claude/skills/harness-companion/install.sh
```

### Commands

| Command | What It Does |
|---------|--------------|
| `/harness:init` | Generate harness scaffold from templates (AGENTS.md, CLAUDE.md, feature_list.json, init.sh, +4 optional) |
| `/harness:status` | Dashboard of file existence, feature progress, WIP=1 state, stale docs |
| `/harness:feature` | List / add / update features in `feature_list.json` |
| `/harness:verify` | Run `check → build → test` chain, auto-fill evidence |
| `/harness:handoff` | Generate `session-handoff.md`, run checklist verification |
| `/harness:audit` | Score all 7 harness subsystems (0-21), rank improvements by impact |

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

- [Claude Code](https://claude.ai/code) CLI
- Git Bash (Windows) / bash (macOS/Linux)
- `jq` (recommended, for feature management features)

## File Structure

```
harness-companion/
├── SKILL.md                  # Main skill document (6 workflows)
├── README.md                 # This file
├── LICENSE                   # MIT
├── install.sh                # One-command install + hook registration
├── scripts/
│   ├── harness-init.sh       # Scaffold generator
│   ├── harness-status.sh     # Health dashboard
│   ├── harness-feature.sh    # Feature list CRUD
│   ├── harness-verify.sh     # Verification chain runner
│   ├── harness-handoff.sh    # Session handoff generator
│   ├── harness-audit.sh      # 7-subsystem auditor
│   └── hooks/
│       ├── session-start.sh  # SessionStart hook
│       └── stop-handoff.sh   # Stop hook
├── references/
│   ├── harness-files.md      # Full format reference
│   └── subsystems-mapping.md # Subsystems ↔ files ↔ lessons
└── assets/templates/         # Copy-paste harness file templates
    ├── AGENTS.md
    ├── CLAUDE.md
    ├── feature_list.json
    ├── init.sh
    ├── claude-progress.md
    ├── session-handoff.md
    ├── clean-state-checklist.md
    └── checklist.sh
```

## How Hooks Work

Two hooks run automatically — no slash command needed:

- **SessionStart**: Detects harness files → reports health status → injects context into Claude's system prompt
- **Stop**: Checks for uncommitted changes → detects dangling in_progress features → reminds to run checklist.sh

Hooks are **non-blocking** (always return `{"continue":true}`) and **gracefully skip** non-harness projects (no `feature_list.json` → silent exit).

## License

MIT — see [LICENSE](./LICENSE)
