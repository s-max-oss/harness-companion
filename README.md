# Harness Companion

> 🇨🇳 [简体中文](./README.zh-CN.md)

**v2.0.0-rc.3 (DSH)** — a DeepSeek Harness skill that bootstraps and maintains a
Harness Engineering environment for any project: knowledge, environment,
progress, scope, verification, observability, and handoff.

> **Host scope.** As of October 2026 this repository targets **DeepSeek Harness
> (DSH) only**. The Claude Code and Codex adapters were retired; their code and
> design record remain in git history.

## What it does

Harness Engineering gives an AI agent a project-level operating system. Harness
Companion initializes it, reports on its health, enforces its evidence rules,
and hands it off cleanly:

| Subsystem | Files | Provided by |
|---|---|---|
| Knowledge | `AGENTS.md`, `CLAUDE.md`, `docs/` | init templates + audit |
| Environment | `init.sh` | init templates |
| Progress | `claude-progress.md` | templates + handoff |
| Scope | `feature_list.json` | state machine with WIP=1 |
| Verification | `.harness/config.json`, run logs | `verify` + evidence gate |
| Observability | `.harness/logs/`, `agent.log` | NDJSON run logs |
| Handoff | `session-handoff.md`, checklist | `handoff` |

## Install

```powershell
# copies the skill into %DSH_HOME%\skills\harness-companion
./dsh/install.ps1

# nine bounded checks, ~50 s
& "$env:DSH_HOME\skills\harness-companion\dsh\smoke.ps1"
```

Open a new DSH session afterwards; the catalog is read at session start.

## Use

Load the skill (`/harness-companion`, or just ask about harness status). The
model drives the same entry point for every action:

```powershell
& "<skill-root>\dsh\run.ps1" status <project-dir>
& "<skill-root>\dsh\run.ps1" feature list <project-dir>
& "<skill-root>\dsh\run.ps1" feature status <project-dir> <id> in_progress
& "<skill-root>\dsh\run.ps1" verify <id> <project-dir> --write
& "<skill-root>\dsh\run.ps1" feature status <project-dir> <id> passing
& "<skill-root>\dsh\run.ps1" handoff <project-dir>
& "<skill-root>\dsh\run.ps1" audit <project-dir> -TimeoutSec 900
```

DSH exposes no skill lifecycle hooks, so there is no automatic status injection
or stop reminder. The skill's `SKILL.md` states the explicit contract: run
`status` when entering a harness project, run `handoff` when wrapping up. The
init flow keeps its consent boundary — no target file is written before the
complete Brief is approved.

## Design principles

- **WIP=1** — at most one `in_progress` feature; the state machine refuses more.
- **Evidence before passing** — `passing` requires a canonical NDJSON run log
  associated through `evidence_associations`; the workspace fingerprint must
  still match.
- **Fail-closed init** — a damaged template snapshot stops the flow instead of
  being silently repaired.
- **Advisory Brief** — current-session instructions and host security policy
  always win over `PROJECT_BRIEF.json`.

## Requirements

- PowerShell 7 (installer, launcher, smoke)
- Git for Windows — its `bash` runs the semantic core
- `jq` recommended (the core falls back to python where possible)

## Layout

```
harness-companion/
├── SKILL.md              # DSH entry: routing, hard rules, resource map
├── dsh/                  # host runtime: launcher, installer, smoke, refs
├── core/                 # bash semantics (status, feature, verify, audit)
├── scripts/              # init executor, handoff, boundary
├── templates/            # project scaffolding
├── references/           # harness file formats, subsystem mapping, dialogue
└── tests/                # core / init / release suites + fixtures
```

## Development

The full repository suite is `bash tests/run-all.sh` (four-hour timeout in
`.harness/config.json`). For day-to-day work prefer the targeted suites:

```bash
bash tests/core/test-status-renderer.sh   # renderer + evidence blocks
bash tests/core/test-harness-feature.sh   # state machine
bash tests/core/test-passing.sh           # evidence eligibility
```

## License

MIT — see [LICENSE](./LICENSE).
