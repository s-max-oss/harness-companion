---
name: harness-companion
description: Use when working on projects that have harness engineering files (feature_list.json, AGENTS.md, init.sh), or when the user wants a guided conversational /harness:init, a Harness audit, evidence-backed feature tracking, verification, or session handoff. v2 splits the runtime into core/ (business semantics) and adapters/ (host protocol mapping for Claude Code and Codex), with v1 compatibility preserved.
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

- Projects without harness files when the user has not asked to initialize or assess a Harness
- Pure refactor / business-logic tasks (the skill is a meta-tool about the workflow, not the work)

## Commands

| Command | Purpose |
|---------|---------|
| `/harness:init [--quick\|--update]` | Build or refine a project Harness through the guided workflow below. `scripts/harness-init.sh` is the only file-writing executor. |
| `/harness:status` | Compact 7-subsystem health dashboard. Cheap to run, run often. |
| `/harness:feature <id> <status> [evidence...]` | Update a feature in `feature_list.json` with a structured evidence record |
| `/harness:verify` | Run the verification chain (config-driven or `checklist.sh`) and capture evidence |
| `/harness:handoff` | Render handoff warnings (uncommitted files, dangling `in_progress`, passing-without-evidence, stale evidence, checklist reminder). **Canonical impl** in `scripts/harness-handoff.sh`. |
| `/harness:audit` | Detailed 5-axis scoring per subsystem. Total out of 21. Verbose mode via `HARNESS_VERBOSE=1`. |

## Onboarding workflow

`/harness:init` is an Agent-guided conversation backed by a deterministic Bash executor. The Agent owns understanding and decisions; `scripts/harness-init.sh` owns every target-project mutation. Never ask the user to fill in JSON or write scaffold files directly.

Load `references/conversational-principles.md` and `references/post-init-explanation.md` when `/harness:init` is invoked, not at session start. Resolve the executor from this skill's own root; do not assume it exists in the target project.

### Route the mode first

- In every Agent mode, a structurally invalid `.harness/.template-snapshot.json` fails closed before dialog or execution. Make zero writes, explain the damage, and direct the user to back up the snapshot and use the explicit recovery flow; never auto-repair it.
- `/harness:init` on a fresh project is **guided**. No target-project file may be created or changed until the user confirms the synthesized Project Brief.
- `/harness:init` on a legacy-unmanaged project is **guided migration**. Explain the legacy markers, confirm the Brief, preserve every pre-existing file, and let the executor snapshot only files created by this run.
- `/harness:init` on a project with a valid `.harness/.template-snapshot.json` is **resume**. Load the existing Brief, discuss only requested or unresolved changes, and confirm the revised Brief before execution.
- `/harness:init --quick` is **quick**. Ask no questions and request no confirmation. Infer what is safe from the current message, conversation, environment, and repository; apply documented defaults. If `goal` or `success_criteria` is still missing, stop without writes and explain what is missing. Never retry as legacy mode. On an initialized or legacy-unmanaged project, refuse implicit changes and direct the user to guided init or explicit `/harness:init --update` as appropriate. For a complete fresh-project Brief, immediately use the `--brief-stdin --non-interactive --host=<claude|codex>` executor path shown below, then warn that quick mode ran without confirmation and the generated Brief should be reviewed.
- `/harness:init --update` is an explicit template update. A fresh project fails because there is nothing to update. A legacy-unmanaged project enters the migration plan described below. A structurally damaged snapshot fails closed; do not repair, replace, or recreate it automatically.
- Plain `bash scripts/harness-init.sh <target> ...` is the compatibility-only **legacy** entry point. It is not the Agent workflow.

### Guided conversation

1. Inspect the target read-only: repository status and recent history, existing Harness files and snapshot state, top-level files, and project markers such as `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, and `Makefile`. Reuse facts already present in the current message or conversation.
2. Start by telling the user what is already known or inferred. Build the five Brief categories—goal and success criteria, cadence, constraints, initial project state, and operation preferences—while asking only about missing required information, genuine conflicts, and choices that materially affect the Harness. Explain unfamiliar concepts in plain language. Do not use a fixed questionnaire or a question-count rule.
3. Never re-ask known information. Prefer the current user message, then conversation history, then repository evidence. If user input conflicts with the repository, show both grounded positions and offer: use the repo value, use the user's value, tell me more, or defer. Ask each conflict-resolution question exactly once in one user-visible response. A progress/commentary update may say that evidence is being checked, but must not preview the question or its choices and then repeat them in the final response. When several fields conflict, the current question and every choice in its menu must affect only one named field; do not bundle another unresolved field into a composite choice or mention it as part of the current resolution. Save that conflict for the next user turn. Never silently choose. Execution-critical conflicts cannot be deferred.
4. Compose a complete Brief in conversation context. Preserve machine-readable `provenance`, `defaults_applied`, and `conflicts_resolved`; include `type_evidence` for `mixed` or `unknown` projects. Annotate the human presentation as `[from you]`, `[inferred from <file>]`, `[default]`, or `[to decide]`. Every decision presented for approval must be represented losslessly in the exact machine-readable Brief passed to the executor. Before presenting it, use the schema's canonical spelling for known identifier values in both forms—for example `stack: node` and `test_framework: jest`, not display-only variants such as `Node.js` or `Jest` that would serialize differently. Human prose around those identifiers may remain natural. When the user asks for "sensible defaults," apply only the documented Brief defaults: `cadence: stable`, `deadline: null`, `secrets_handling: unspecified`, `external_network: ask`, `prohibitions: []`, and the ask/false `operation_preferences` defaults. Record each field that actually used a default exactly once in `defaults_applied`, with the same value and a non-empty rationale. Do not invent product or implementation defaults such as a framework, database, UI architecture, authentication, or deployment choice. Leave such optional choices explicitly deferred unless the user supplies them and the Brief can represent them. Present the Brief—not the Agent's implementation plan—for approve, edit, or cancel. Edits preserve all previously confirmed fields; cancel leaves a fresh target byte-identical.
5. Record the user's decision through the consent boundary. Reject/cancel takes no executor arguments and returns without invoking the executor:

   ```sh
   bash <skill-root>/scripts/harness-init-boundary.sh <target> --decision cancel
   ```

   After approval, pass the resolved Brief through the same boundary without writing it into the target yourself:

   ```sh
   printf '%s' "$RESOLVED_BRIEF_JSON" \
     | bash <skill-root>/scripts/harness-init-boundary.sh <target> --decision approve \
         --brief-stdin --non-interactive --host=<claude|codex>
   ```

   Treat the command as illustrative argument binding, not permission to interpolate untrusted shell text. Use the host's structured process API or safely quoted arguments in a real invocation.

   Approval freezes the exact human Brief that was just presented. Build the
   executor JSON by copying its goal, success-criterion strings, and other
   decisions exactly; never regenerate, paraphrase, personalize (for example,
   by inserting “the user's”), or reinterpret them from earlier messages. If
   the exact approved Brief cannot be recovered from conversation context, do
   not write—present it again and ask for confirmation.

### Resume and update safety

For resume on a managed-valid project, first perform a no-write 3-way comparison and explain which files are identical, template-only changes, user-modified, or missing. Offer **apply the template-only changes**, **keep all existing files**, or **cancel**. Only an approved exact plan may execute; user-modified files must be preserved. Use the same stable-Brief dry-run and plan-token apply sequence as explicit update below. If the user keeps all or cancels, do not apply the plan.

For explicit `/harness:init --update`, store the confirmed Brief in a stable temporary file outside the target. On a legacy-unmanaged project, first explain which files predate Harness management, collect and confirm any missing Brief fields, and make clear that the new snapshot will claim only files this migration creates. Then:

1. Run `bash <skill-root>/scripts/harness-init.sh <target> --brief <temp-json> --non-interactive --host=<claude|codex> --update` as a no-write dry run.
2. Explain the proposed creates, updates, and preserved user modifications. Ask whether to apply that exact plan.
3. Only after approval, run `bash <skill-root>/scripts/harness-init.sh <target> --brief <temp-json> --non-interactive --host=<claude|codex> --update --apply --plan-token <token>`. A stale or missing token means stop and regenerate the plan; never bypass the check.

### Completion and errors

After a successful run, explain the outcome conversationally using the four categories in `references/post-init-explanation.md`: **generated**, **inferred**, **defaulted**, and **deferred**. Before replying, reconcile the approved human Brief, the exact executor input, and the resulting `PROJECT_BRIEF.json`; do not omit an approved default, report an unrecorded choice as applied, or claim that nothing is deferred when optional choices remain open. Highlight decisions the user may want to revisit and invite them to rerun guided init; do not dump JSON.

Translate executor diagnostics into plain language while preserving the failed field or condition and the non-zero result. Do not hide partial state, silently retry, weaken a fail-closed check, or fall back to another mode.

The Brief is advisory. Current-session instructions and host security policy always win. Obtain explicit in-session authorization for push, merge, tag, release, handling credentials, secrets, API keys, or tokens, local skill installation or update, package installation, external network access or mutation, and destructive actions regardless of Brief preferences. An in-session stop or denial wins immediately; do not perform the action, and record the denial in evidence when the active workflow has an evidence sink.

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
│   ├── harness-init.sh                # ← canonical guided-init executor
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

`scripts/harness-init.sh` and `scripts/harness-handoff.sh` are NOT wrappers — they are the **canonical implementations** (the rc.3 deterministic onboarding executor and the handoff generator respectively). v2 core does not re-implement them.

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
