---
name: harness-companion
description: Use when working on projects that have harness engineering files (feature_list.json, AGENTS.md, init.sh) — when the user wants to set up or audit Harness Engineering practices, drive an evidence-backed feature pipeline, surface stale evidence or WIP violations at session start, hand off cleanly between sessions, or run the 7-subsystem health / 5-axis audit dashboard. v2 splits the runtime into core/ (business semantics) and adapters/ (host protocol mapping for Claude Code and Codex), with v1 compat wrappers preserved.
---

# Harness Companion

A Core/Adapter refactor of the v1.1.2 Harness Engineering skill. The runtime now lives in two layers:

- **`core/`** — business semantics only. Plain-text status composition, WIP=1 detection, passing-without-evidence detection, stale-evidence comparison against SessionStart baseline, handoff warnings, and the 7-subsystem × 5-axis audit dashboard. No protocol awareness.
- **`adapters/`** — host protocol mapping. Reads stdin, parses cwd, calls core, JSON-encodes, wraps in the host envelope, fail-open on error. Two adapters ship today: Claude Code (default) and Codex.

## When to use

- The user is in a project that has harness files (`feature_list.json`, `AGENTS.md`, `init.sh`)
- They want to bootstrap / audit / drive / verify / hand off a Harness Engineering workflow
- They need to interpret the 7-subsystem health dashboard or the 5-axis audit
- They want to surface stale evidence or WIP violations at session boundaries
- They want Codex to follow the same workflow as Claude Code

## When NOT to use

- Projects without any harness files (the skill will see no `feature_list.json` and emit `suppressOutput`)
- Pure refactor / business-logic tasks (the skill is a meta-tool about the workflow, not the work)

## Commands

| Command | Purpose |
|---------|---------|
| `/harness:init` | Bootstrap harness files in a project (AGENTS.md, CLAUDE.md, init.sh, feature_list.json). **Canonical impl** in `scripts/harness-init.sh`. |
| `/harness:status` | Compact 7-subsystem health dashboard. Cheap to run, run often. |
| `/harness:feature <id> <status> [evidence...]` | Update a feature in `feature_list.json` with a structured evidence record |
| `/harness:verify` | Run the verification chain (config-driven or `checklist.sh`) and capture evidence |
| `/harness:handoff` | Render handoff warnings (uncommitted files, dangling `in_progress`, passing-without-evidence, stale evidence, checklist reminder). **Canonical impl** in `scripts/harness-handoff.sh`. |
| `/harness:audit` | Detailed 5-axis scoring per subsystem. Total out of 21. Verbose mode via `HARNESS_VERBOSE=1`. |

## Architecture (v2)

```
harness-companion/
├── core/                              # Business semantics — no protocol awareness
│   ├── harness-{verify,feature,status,audit}.sh   # CLI entrypoints
│   └── lib/                           # Shared helpers (json-helpers, baseline, evidence, status-renderer, ...)
├── adapters/
│   ├── claude-code/                   # Claude Code protocol mapping (Phase 4)
│   │   ├── install.sh
│   │   └── hooks/
│   │       ├── session-start.sh       # SessionStart → status text via core
│   │       └── stop-handoff.sh        # Stop → handoff warnings via core
│   └── codex/                         # Codex protocol mapping (Phase 5b)
│       ├── adapter.conf               # protocol_version=1
│       ├── install.sh                 # 3 modes: plugin / --repo / --user
│       ├── uninstall.sh
│       ├── PHASE5B_STATUS.md          # Codex status qualification (canonical wording)
│       ├── hooks/                     # session-start, stop-handoff, pre-tool-use
│       └── templates/
├── .codex-plugin/
│   ├── plugin.json                    # Codex plugin manifest (v 2.0.0-rc.2)
│   ├── README.md
│   └── skills/                        # Codex-discoverable skill bundle
├── hooks/
│   ├── hooks.json                     # Codex event-keyed hook registry
│   └── README.md
├── scripts/                           # v1 compat wrappers (≤5 lines each)
│   ├── harness-init.sh                # ← canonical impl (4-file scaffold)
│   ├── harness-handoff.sh             # ← canonical impl (generate handoff + checklist)
│   ├── harness-{verify,feature,status,audit}.sh   # → ../core/<name>.sh
│   └── hooks/{session-start,stop-handoff}.sh      # → ../../adapters/claude-code/hooks/<name>.sh
├── templates/                         # 8 file templates (AGENTS, CLAUDE, feature_list, init, ...)
├── references/                        # harness-files.md, subsystems-mapping.md
├── tests/                             # Per-file runnable tests
│   ├── core/                          # Pure-bash unit + integration
│   ├── golden/                        # Snapshot fixtures
│   └── adapters/                      # Claude Code + Codex contract tests
└── SKILL.md                           # This file
```

### Boundaries (Design v5 §6.2)

| Concern | Owner |
|---------|-------|
| Status text rendering (file checks, feature stats, WIP=1, passing-without-evidence) | `core/lib/status-renderer.sh` |
| Handoff warnings (uncommitted files, dangling `in_progress`, stale evidence, checklist reminder) | `core/lib/status-renderer.sh` |
| SessionStart baseline persistence | `core/lib/baseline.sh` |
| Stale-evidence comparison vs baseline | `core/lib/status-renderer.sh` |
| Claude Code JSON envelope wrapping (`hookSpecificOutput.additionalContext`, `systemMessage`) | `adapters/claude-code/hooks/*.sh` |
| Codex hook command construction (`hooks.json`, `${PLUGIN_ROOT}` paths) | `adapters/codex/` |
| Fail-open trap (`{"continue":true,"suppressOutput":true}`) | each adapter's hook script |

**Hard constraint:** adapters do host protocol mapping only. Business semantics stay in `core/`. Adapters MUST NOT contain `.status=="passing"` filters, WIP detection, evidence comparison, or `fingerprint` logic — those are checked by the contract tests.

## v1 compatibility

v1.1.2 callers keep working unchanged. The `scripts/harness-{verify,feature,status,audit}.sh` and `scripts/hooks/{session-start,stop-handoff}.sh` wrappers are 4-line forwarders:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/../core/$(basename "$0")" "$@"
```

`scripts/harness-init.sh` and `scripts/harness-handoff.sh` are NOT wrappers — they are the **canonical implementations** (4-file scaffold generator and handoff doc generator respectively). v2 core does not re-implement them.

Identity is guaranteed by the contract test (`tests/adapters/test-claude-code-contract.sh` G3) — byte-for-byte equal output between direct core invocation and wrapper invocation.

## Hook envelopes

### Claude Code

**SessionStart:**
```json
{"continue":true,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<status text as JSON string>"}}
```

**Stop (with warnings):**
```json
{"continue":true,"systemMessage":"<handoff warnings as JSON string>"}
```

**Stop (no warnings) — fail-open:**
```json
{"continue":true,"suppressOutput":true}
```

### Codex

Codex hooks are registered via `.codex/hooks.json` (or `~/.codex/config.toml` in `--user` mode). Three events:

| Event | Adapter action |
|-------|----------------|
| `SessionStart` | Same status injection as Claude Code, mapped to Codex `hookSpecificOutput.additionalContext` |
| `Stop` | Same handoff warnings, mapped to Codex `systemMessage` |
| `PreToolUse` | Permissive fail-open — `policy not enabled` (Phase 5b) |

## Installation

```sh
# Top-level dispatcher (default = Claude Code adapter)
bash install.sh                                       # global, Claude Code
bash install.sh --project                             # project-local, Claude Code
bash install.sh --codex                               # Codex adapter (--repo $(pwd))
bash install.sh --all                                 # both adapters
bash install.sh --symlink-core                        # symlink core/ (no-op on Windows)

# Direct adapter invocation
bash adapters/claude-code/install.sh --user
bash adapters/claude-code/install.sh --project --symlink-core
bash adapters/codex/install.sh --repo ~/my-project
bash adapters/codex/install.sh --user
```

The install script:
1. Copies `core/`, `templates/`, `references/`, `adapters/<x>/`, `.codex-plugin/` (Codex only), `scripts/` v1 compat wrappers
2. Stamps `install-receipt.json` with `installed_at`, source commit, and SHA-256 integrity hashes
3. Registers `SessionStart` and `Stop` hooks in the appropriate settings file:
   - Claude Code `--user` → `~/.claude/settings.json`
   - Claude Code `--project` → `<project>/.claude/settings.json`
   - Existing `hooks` block is **merged** (existing entries preserved)
   - A unique timestamped backup of `settings.json` is written before any modification
   - Repeated installs are idempotent (no duplicate hook entries)

After install, restart Claude Code (or Codex) to load hooks.

## See also

- `core/lib/status-renderer.sh` — reusable plain-text rendering
- `core/lib/baseline.sh` — SessionStart baseline persistence
- `core/lib/evidence.sh` — evidence record validation
- `core/lib/json-helpers.sh` — stdin JSON parsing helpers
- `tests/adapters/test-claude-code-contract.sh` — Claude Code adapter contract tests (G1–G7)
- `tests/adapters/test-codex-contract.sh` — Codex adapter contract tests
- `tests/adapters/test-codex-install-modes.sh` — Codex install mode tests
- `tests/migration/test-v1-compat.sh` — v1-compat migration tests (Phase 2)
- `tests/core/` — core unit + integration tests

## Repository

https://github.com/s-max-oss/harness-companion