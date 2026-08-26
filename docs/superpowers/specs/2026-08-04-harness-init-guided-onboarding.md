# Harness-Init Guided Onboarding (design)

> **Status:** **Approved / frozen.** Revision 2026-08-04 (round 6). No code changes until §10/§11 preconditions are met (rc.2 merge, tag, release, clean master).
> **Target version:** v2.0.0-rc.3 (depends on v2.0.0-rc.2 shipping first).
> **Predecessor spec:** `2026-08-04-rc2-distribution-hardening.md` — **must be merged and rc.2 tag cut before this work starts**.

## 0. Scope

### 0.1 In scope

- Redesign `/harness:init` from a deterministic scaffold runner into an Agent-guided onboarding workflow.
- 5-category information collection (goal, cadence, constraints, current state, operation preferences).
- Project Brief confirmation gate before any file is written.
- Persistence of the confirmed Brief to `<target>/.harness/PROJECT_BRIEF.json` (canonical) + `<target>/.harness/PROJECT_BRIEF.md` (human rendering).
- Mode matrix: **guided** (Agent dialog), **quick** (Agent no-dialog), **legacy** (CLI v1 surface, deterministic placeholder fill), **resume** (sentinel-detected re-run), **update** (template upgrade).
- Type-matching content generation using a typed-template approach with a unified type enum.
- Lightweight check boundary (no test execution, no dependency install).
- Template manifest (`<target>/.harness/.template-snapshot.json`) for 3-way compare on resume/update.

### 0.2 Out of scope

- rc.2 distribution-hardening work (separate PR, `distribution/rc2-hardening` branch, target v2.0.0-rc.2). This spec does not start until rc.2 is merged.
- Any change to other slash commands (`status`, `feature`, `verify`, `handoff`, `audit`).
- New external runtime dependencies (no `claude-mem`, no `node`, no `python` runtime required at test time).
- New declared test dependencies (only `jq`, `bash`, `grep`, `sed`, `awk` may be used by tests; `yq` and any markdown parser are forbidden).
- Re-designing the `feature_list.json` schema (v2 revision 1 is preserved).

### 0.3 Hard constraints (non-negotiable)

| # | Constraint |
|---|---|
| C1 | **Repository isolation.** Dev source-of-truth is `D:\HuaweiMoveData\Users\20805\Desktop\homework\GitHub learning\harness-companion skill\harness-companion`. No re-clone, no `git init`, no copy from local installed skill. |
| C2 | **Local install paths are protected.** `~/.claude/skills/harness-companion/`, `~/.agents/skills/harness-companion/`, `~/.claude/settings.json`, `~/.agents/settings.*` are not written, overwritten, or synced by this work. |
| C3 | **Pre-confirm = 0 writes.** No files in the target directory before the user approves the Project Brief. Not even `.harness/.draft.yml`. Brief state lives only in Agent conversation context. |
| C4 | **No `claude-mem` dependency.** Cross-session continuity is carried by the confirmed `<target>/.harness/PROJECT_BRIEF.json` file, not by memory injection. |
| C5 | **Wire format may vary; mutation semantics must not fork.** The interaction contract (§6) is fixed; the specific on-the-wire shape (`--brief <file>`, stdin, MCP) is chosen at implementation time. **All file mutations go through `scripts/harness-init.sh` or a deterministic core executor called by all entry points.** SKILL.md is dialog-only. |
| C6 | **Existing scaffold is preserved.** A protected-paths list is maintained in §15. PR-B must not touch any path on the list. The list (not counts) is the source of truth. |
| C7 | **Install / upgrade tests use isolated temp dirs.** `mktemp -d` for install target, `HOME=$(mktemp -d)` for hook registration. Never `~/.claude/` or `~/.agents/`. |
| C8 | **Test failure on local-install dependency.** If a test depends on the locally installed skill, treat it as a test failure and fix the isolation. |
| C9 | **PROJECT_BRIEF is advisory only.** `operation_preferences` records user-stated preference but is never a binding authorization. Current session user instructions and host security policies always take precedence. The Agent must obtain explicit in-session confirmation for `merge`, `release`, `install_packages`, `external_mutation`, and `destructive_ops` regardless of what the brief says. |
| C10 | **No `read -p` in `scripts/harness-init.sh`.** Dialog is the Agent's job. Bash is the deterministic executor. |
| C11 | **Pre-release confirmation gates.** No merge, no tag, no GitHub release, no local install update happens without explicit user confirmation (see §14). |

## 1. Goals

- **G1.** Agent-driven 5-category collection, ≤ 3 questions per round, never a fixed questionnaire.
- **G2.** No re-asking: conversation history and repo evidence are the source of truth.
- **G3.** Reject the Brief ⇒ target dir byte-identical to before (verified by full tree SHA).
- **G4.** Approve the Brief ⇒ canonical `<target>/.harness/PROJECT_BRIEF.json` + human-rendered `<target>/.harness/PROJECT_BRIEF.md` + harness files per the output manifest (§6.2a), all using the detected type's templates.
- **G5.** Re-run on an initialized project never overwrites user-modified files; resume/update is 3-way SHA compare.
- **G6.** `docs`, `shell`, `python`, `rust`, `go`, `electron` projects get type-matching content — verified by **white-list per type** (positive match on a fixture), not a black-list.
- **G7.** Quick mode aborts on missing required field; legacy CLI mode fills with placeholders and prints a warning. The two are never conflated.

## 2. Non-goals

- The Brief is **not** a PRD. One paragraph goal, 2–5 success criteria, 5–7 operation preference fields, a few constraints.
- The Brief is **not** a binding authorization. Repo file is advisory.
- The guided flow is **not** a fixed questionnaire. The Agent decides which questions to ask.
- Conflict resolution is **not** a free-form prompt. One precise question per detected conflict.

## 3. Mode matrix

Five distinct modes, each with its own entry point and behaviour. **The three primary modes are non-overlapping**:

| Mode | Entry | Conversation | Behaviour on missing required | Confirm gate | Brief |
|---|---|---|---|---|---|
| **guided** | Agent's `/harness:init` (no flag) in a fresh project | Yes, 5-category | Prompt the user | Required | After approval |
| **quick** | Agent's `/harness:init --quick` | None | **Abort** with `error: --quick mode cannot prompt; field 'X' is required` (AC-13) | None (auto-runs after Brief synthesized) | Without confirmation, with warning |
| **legacy** | Bash `bash scripts/harness-init.sh <dir> [--full] [--host=claude\|codex]` from v1 callers | None | **Fill with placeholder** values; never abort (v1 back-compat). Placeholders are flagged in `defaults_applied` | None | Without confirmation, with warning that brief is placeholder |
| **resume** | Any entry in a project where `<target>/.harness/.template-snapshot.json` exists | None | n/a (uses existing files) | Required before touching template-only files | Not re-written (existing preserved) |
| **update** | Any entry with `--update` | None | n/a | Required before overwriting | Not re-written |

**Crucial distinction:**

- `quick` is for the **Agent's CLI** (`/harness:init --quick`) and aborts on missing required — it knows a dialog is impossible.
- `legacy` is for **v1 Bash callers** (no flag, no Agent in the loop) and never aborts — it must continue to work without modification, filling placeholders.

These two never share an "abort on missing" code path.

### 3.1 Mode priority

When entry conditions overlap, priority is **explicit flag > Agent presence > Bash absence**:

1. **Explicit `--update`** — overrides everything. User signalled intent to upgrade templates.
2. **Agent resume detection** — applies to `guided` and `quick` modes only when `.harness/.template-snapshot.json` exists.
3. **Agent quick/guided** — fresh-project paths (no snapshot).
4. **Plain Bash legacy** — last priority. No dialog.

#### 3.1.1 Combination matrix

Snapshot state is now **none | valid | invalid** (not just present/absent). Invalid snapshots fail closed.

| Entry | Snapshot state | `--update` | Mode actually executed |
|---|---|---|---|
| `bash scripts/harness-init.sh <dir>` | none | No | **legacy-fresh** (§3.4) |
| `bash scripts/harness-init.sh <dir>` | valid | No | **legacy-skip-existing** (§3.4) |
| `bash scripts/harness-init.sh <dir>` | invalid | No | **fail-closed** (print diagnostic; exit non-zero) |
| `bash scripts/harness-init.sh <dir> --update` | any | Yes | **update-plan** (no write without `--apply`; per §3.4.1) |
| `bash scripts/harness-init.sh <dir> --update --apply` | any | Yes | **update-apply** (writes; still no stdin confirm, per C10) |
| `/harness:init` (Agent) | none | No | **guided** |
| `/harness:init` (Agent) | valid | No | **resume** (Agent asks via SKILL.md) |
| `/harness:init` (Agent) | invalid | No | **fail-closed** (Agent reports diagnostic; refuses to proceed) |
| `/harness:init --quick` (Agent) | none | No | **quick** |
| `/harness:init --quick` (Agent) | valid | No | **already-initialized** (refuses to update; tells user to run `/harness:init --update` explicitly) |
| `/harness:init --quick` (Agent) | invalid | No | **fail-closed** |
| `/harness:init --update` (Agent) | valid | Yes | **update** |
| `/harness:init --update` (Agent) | none | Yes | **migration-required** (Agent guides user; cannot proceed without user input on legacy markers) |
| `/harness:init --update` (Agent) | invalid | Yes | **fail-closed** (cannot proceed; user must back up damaged snapshot and enter explicit recovery flow) |

**Binding rules:**

- **Bash executor never asks confirmation.** Per C10: no `read -p`, no `read -r`, no stdin-driven prompt. The only authorization channel is a flag (`--apply` / `--yes`).
- **Bash `--update` without `--apply` is a dry run.** It prints plan/diff and exits 0 without writing. This is the C10-compatible equivalent of v1's confirmation dialog.
- **Agent `--quick` on a managed-valid project refuses to update.** It reports `already-initialized` and exits. The user must re-run with explicit `--update`. `--quick` never implicitly upgrades.
- **`--update` with managed-inconsistent state fails closed.** No automatic repair, no auto-snapshot rebuild, no overwrite. User must back up the damaged snapshot and enter the explicit recovery flow before retrying.

### 3.2 Required fields

Per-field rules. `R` = required, `O` = optional.

| Field | Type | guided | quick | legacy placeholder | Repo-inferable | Validation rule |
|---|---|---|---|---|---|---|
| `goal` | string | **R** | **R** | `"<unset: goal>"` | No | Non-empty after trim; 1 ≤ length ≤ 500 |
| `success_criteria` | array of strings | **R** | **R** | `["<unset: success criteria>"]` | No | 1 ≤ length ≤ 7; each entry non-empty after trim |
| `cadence` | enum | O | O | `"stable"` | No | one of `stable`, `weekly`, `daily`, `oneoff` |
| `deadline` | string \| null | O | O | `null` | No | `null` or ISO-8601 date `YYYY-MM-DD`. **Past dates trigger a warning, not rejection** (a project may already be overdue). |
| `stack` | enum | O | O | `"unknown"` | **Yes** (from §8.1 detector) | one of 9 enum values §8.1 |
| `test_framework` | enum \| string | O | O | `"unspecified"` | **Yes** (from §8.1 detector) | `none \| unspecified` enum values, OR known framework enum, OR free string ≤ 50 chars. **Not nullable.** |
| `secrets_handling` | enum | O | O | `"unspecified"` | No | one of `env-file`, `vault`, `keyring`, `unspecified` |
| `external_network` | enum | O | O | `"ask"` | No | one of `ask`, `allowed`, `denied` |
| `prohibitions` | array of strings | O | O | `[]` | No | each entry non-empty; ≤ 20 entries; each ≤ 200 chars |
| `initial_project_state` | object | O | O | inferred object | **Yes** (from recon) | per §7.2.3 |
| `operation_preferences` | object | O | O | advisory defaults | No | per §7.2.4 |
| `defaults_applied` | array of objects | n/a (recorded) | n/a (recorded) | always recorded | n/a | structured per §7.2.5 |
| `conflicts_resolved` | array of objects | n/a (recorded) | n/a (recorded) | always `[]` in legacy | n/a | structured per §7.2.6 |

**Test derivation for AC-13:** "Quick aborts on missing required" is concretely: `quick` mode aborts when `goal` or `success_criteria` cannot be filled from env vars, repo detection, or defaults (source=missing after the recon pass).

### 3.3 Required-field combination matrix

| Mode | Missing `goal` or `success_criteria`? | Result |
|---|---|---|
| guided | Yes | Ask user |
| quick | Yes | **Abort** with `error: --quick mode cannot prompt; field 'X' is required` (AC-13) |
| legacy | Yes | Fill placeholder; **warn**; never abort |

### 3.4 Project state model

The executor determines the project's state by inspecting the target. **State, not the mode flag, decides what happens.**

Four states:

| State | Definition |
|---|---|
| **fresh** | No `.harness/.template-snapshot.json` AND no legacy marker combo AND no recognizable legacy schema. |
| **legacy-unmanaged** | No snapshot BUT legacy markers present: `.harness/config.json` exists, OR `feature_list.json + AGENTS.md + init.sh` co-exist (combo), OR `feature_list.json` / `.harness/config.json` has a recognizable `schema_version` field. |
| **managed-valid** | `.harness/.template-snapshot.json` exists, parses, `schema_version` is in the supported set, and the snapshot's internal structure is self-consistent: all required manifest fields present, every recorded SHA is 64 hex characters, the file-count matches the record count. **Whether a source template path still exists in the current harness-companion version is NOT a validity check** — missing old paths enter 3-way compare, not fail-closed. **Whether the on-disk file content differs from the snapshot is NOT a validity check** — that is the normal condition detected by 3-way compare. |
| **managed-inconsistent** | `.harness/.template-snapshot.json` exists but is structurally unusable: parse error / `schema_version` not in the supported set / required manifest field missing / SHA format invalid (not 64 hex chars) / file-count vs record-count mismatch. **Template source paths missing from the current harness-companion version, or target files whose content differs from the snapshot, are NOT inconsistent — they are normal input to 3-way compare.** |

**Detection logic** (executed by `scripts/harness-init.sh` recon step):

```
if [ -f "$target/.harness/.template-snapshot.json" ]; then
  if validate_snapshot "$target/.harness/.template-snapshot.json"; then
    state=managed-valid
  else
    state=managed-inconsistent
  fi
elif has_legacy_markers "$target"; then
  state=legacy-unmanaged
else
  state=fresh
fi
```

`has_legacy_markers` returns true when **any** of:

- `.harness/config.json` exists, **OR**
- `feature_list.json` AND `AGENTS.md` AND `init.sh` all exist (combo), **OR**
- `feature_list.json` has a `schema_version` field, **OR**
- `.harness/config.json` exists with a recognizable harness schema (e.g., `schema_version` field).

A single common project file (e.g., `AGENTS.md` alone) is **not** evidence. The harness v1 shipped `feature_list.json + AGENTS.md + init.sh` together, and a v0 user could have written any of them manually.

#### 3.4.1 Behaviour per state × mode

| State | guided (Agent) | quick (Agent) | legacy (Bash) | --update (Agent) | --update (Bash, no --apply) | --update --apply (Bash) |
|---|---|---|---|---|---|---|
| fresh | full dialog | fill or abort | fill placeholders, run | **error: not initialized** (exit non-zero, zero writes) | **error: not initialized** | **error: not initialized** |
| legacy-unmanaged | full dialog with migration notice | **migration-required** (refuse to write; quick cannot confirm old file ownership) | fill placeholders; write only new artefacts; **snapshot tracks only new files, never claims old files as template origin** | enter migration flow (Agent guides); snapshot tracks only new files | print plan; refuse write without `--apply`; snapshot listed as "would-create" | write migration scaffolding; never overwrite user files; snapshot tracks only new files |
| managed-valid | resume via 3-way SHA compare | report **already-initialized**, refuse to update | legacy-skip-existing (no overwrite) | update via 3-way SHA compare | print plan; refuse write without `--apply` | write per plan; preserve user-modified files |
| managed-inconsistent | refuse to proceed; report diagnostic; user must back up damaged snapshot and enter explicit recovery flow | refuse; report diagnostic | refuse; print diagnostic, exit non-zero | refuse; cannot proceed | refuse; cannot proceed | refuse; cannot proceed |

**Critical rules (binding):**

- **Bash never asks confirmation.** Per C10, including not via `read -p`, not via `read -r`, not via stdin. `--apply` / `--yes` is a flag-based authorization, not an interactive prompt.
- **Bash `--update` without `--apply` prints a plan only.** It does not write. This is the C10-compatible equivalent of v1's confirmation dialog.
- **Agent `--quick` on managed-valid projects refuses to update.** It reports `already-initialized` and tells the user to run `/harness:init --update` explicitly. `--quick` never auto-updates.
- **`--update` with managed-inconsistent state fails closed.** No automatic repair, no auto-snapshot rebuild, no overwrite. The user must back up the damaged snapshot and enter the explicit recovery flow first.
- **All `--apply` paths must re-check file SHAs before writing.** Between dry-run (`--update` without `--apply`) and write (`--update --apply`), any target file that will be overwritten must have its current SHA verified against the dry-run baseline. If any SHA changed, the write is refused and the user must re-run the dry-run. This prevents race conditions where a file is modified between plan and write.
- **Snapshot for legacy-unmanaged never backfills provenance.** When a legacy-unmanaged project is initialized or migrated, the written `.template-snapshot.json` records only the files created by this run. It does NOT record sha256 entries for pre-existing files that were left untouched — those files have no known template origin.

## 4. User flow

### 4.1 guided (default)

```
1. Trigger     /harness:init
2. Recon       Agent reads cwd: git status, file listing, presence of
                 .harness/config.json / .harness/.template-snapshot.json,
                 package.json/pyproject.toml/Cargo.toml/go.mod/Makefile
                 headers, git log -10. Reads conversation history (NOT
                 claude-mem).
3. Annotate    Each 5-category field tagged {source, value, confidence}:
                 source ∈ {conversation, repo, default, missing}
4. Conflicts   Detect repo evidence vs user input contradictions (see §5).
5. Probe       Per round: ≤ 3 questions, prioritised:
                 (a) required fields with source=missing
                 (b) conflicts (one precise question each)
                 (c) optional fields where default would be used
6. Compose     Render Project Brief in human-readable form.
7. Confirm     User chooses: approve / edit / cancel
                 approve → step 8
                 edit   → back to step 5
                 cancel → abort, no files written
8. Execute     Run scripts/harness-init.sh --brief <json-path>.
               Writes files per the output manifest (§6.2a):
               minimal (default): files #1–#8
               full (--full):     files #1–#10
9. Report      List written files + "edit PROJECT_BRIEF.json to override"
```

### 4.2 quick (Agent --quick only)

```
1. Trigger     /harness:init --quick (from Agent)
2. Recon       Same as 4.1.2
3. Brief       Compose Brief from env vars + repo detection + defaults.
               If any required field has source=missing → abort with
                 stderr: "error: --quick mode cannot prompt; field 'X' is required"
               exit 2.
4. Execute     scripts/harness-init.sh --brief <path> --non-interactive
5. Warning     stderr: "warning: --quick mode ran without confirmation;
                        review PROJECT_BRIEF.json"
```

### 4.3 legacy (Bash v1 caller)

```
1. Trigger     bash scripts/harness-init.sh <dir> [--full] [--host=claude|codex]
                 (v1 surface; no Agent)
2. Recon       Same as 4.1.2
3. Brief       Compose Brief:
               - args / env vars fill any field they cover
               - repo detection fills stack, test_framework
               - any field still missing is filled with a placeholder,
                 recorded in defaults_applied
               - NEVER abort
4. Execute     Same as 4.1.8
5. Warning     stderr: "warning: legacy mode ran; PROJECT_BRIEF.json
                        contains placeholder fields — review and edit"
```

### 4.4 resume (sentinel-detected re-run)

```
1. Detect      is_initialized = true iff
                 <target>/.harness/config.json  OR
                 <target>/.harness/.template-snapshot.json
                 exists.
               (NOT scripts/, NOT references/, NOT CLAUDE.md / AGENTS.md
                — these are common project paths.)
2. 3-way compare   For each tracked template file:
                 - sha_now   = sha256(<current file in target>)
                 - sha_tmpl  = sha256(<template in repo's templates/ dir
                                     or by-type/<type>/ override>)
                 - sha_snap  = sha256(<file in .template-snapshot.json>)
                 Classify:
                 - sha_now == sha_tmpl                 → identical, skip
                 - sha_now == sha_snap  && sha_tmpl!=  → template changed,
                                                          user did not;
                                                          candidate for update
                 - sha_now != sha_tmpl && sha_now!=snap → user modified;
                                                          default keep, warn
3. Confirm     User picks: update template-only / keep all / cancel
4. Execute     Only template-only files in the chosen set are touched.
               No deletions. No overwrites of user-modified.
```

### 4.5 update (`--update`)

Same as 4.4 but skips the `is_initialized` detection. Use case: upgrading from v2 templates to v3 templates, with explicit `--update`.

## 5. Conflict resolution

### 5.1 Definition

A **conflict** is a 5-category field where **repo evidence** (current state) and **user input** (target state) produce contradictory conclusions.

### 5.2 Handling rule

**Do not silently pick a side.** For each detected conflict, ask exactly one precise question naming both positions as options. Format:

```
[Field] conflict:
  - repo says: <A>
  - you said:  <B>
Which is true?
  1. <A> (inherit from repo)
  2. <B> (use your input)
  3. Tell me more
  4. Skip for now
```

### 5.3 Examples

| Field | Repo says | User said | Question |
|---|---|---|---|
| `stack` | `node` (has `package.json`) | "Python project" | "Repository has package.json. Initialize as Node (inherit), or as Python (overwrite .harness/config.json)?" |
| `test_framework` | `pytest` (pytest.ini) | "no tests yet" | "Repository has pytest config. Include pytest in verify chain, or leave empty?" |
| `cadence` | (not detectable) | (not stated; default would be `stable`) | Not a conflict. Use default. |
| `operation_preferences.push` | (not detectable) | "yes" | Not a conflict. Use user input. |

### 5.4 Implementation location

Conflict detection lives in SKILL.md (Agent dialog). Not in `scripts/harness-init.sh`. The bash executor receives a resolved Brief, never a "we picked A" guess.

## 6. Interaction contract

### 6.1 Inputs

- `cwd` (target project directory)
- Optional mode flag (`--quick` for Agent, `--update` for resume-with-update, `--host=claude|codex` for legacy)
- Optional environment variables (`HARNESS_INIT_QUIET=1`, `HARNESS_INIT_GOAL`, `HARNESS_INIT_CADENCE`, etc.)
- Agent conversation context (ephemeral, not stored)

### 6.2 Decision output

Either:

- a set of files to write with their content (per the output manifest in §6.2a), **or**
- an `abort` decision with a reason.

### 6.2a Output manifest (normative file list)

This manifest is the **implementation contract** for what `scripts/harness-init.sh` writes. It is derived from the rc.1 executor (§6.2b) with rc.3 additions and modifications annotated. AC assertions reference these paths by number, not by count. "8 standard files" and "8–10 files" are informal descriptions only; this table is authoritative.

**Legend for Kind column:** `file` = regular file created (SKIP if exists). `dir` = directory created (`mkdir -p`; no-op if exists). `append` = executor appends to existing file; does not replace user content.

**Legend for rc.3 change column:** 🆕 = new in rc.3 (did not exist in rc.1/rc.2 output). ♻️ = may be modified from rc.1 template (type-matching, §8.3). `—` = unchanged from rc.1.

**Legend for Host column:** ⬜ = byte-equal across `--host=claude` and `--host=codex`. 🔵 = written only for `--host=claude`. 🟠 = written only for `--host=codex`.

**Legend for Full column:** `minimal` = always written. `--full` = only with `--full` flag.

| # | Path | Kind | Mode | Host | Full | rc.3 | Resume/update | Notes |
|---|---|---|---|---|---|---|---|---|
| 1 | `.harness/PROJECT_BRIEF.json` | file | guided, quick, legacy | ⬜ | minimal | 🆕 | **preserve** (rewrite only if Brief fields explicitly changed) | Canonical brief. Deterministic from Brief input. |
| 2 | `.harness/PROJECT_BRIEF.md` | file | guided, quick, legacy | ⬜ | minimal | 🆕 | **render-on-change** (regenerate if JSON changed or `--render-brief`; otherwise preserve) | Rendered from #1. **Deterministic:** same JSON + same `source_version` → byte-equal output. |
| 3 | `.harness/.template-snapshot.json` | file | guided, quick, legacy, resume, update | ⬜ | minimal | 🆕 | **write** (always updated when templates written; records what was actually placed) | 3-way compare base. §8.5. |
| 4 | `.harness/config.json` | file | guided, quick, legacy | ⬜ | minimal | ♻️ | **preserve** (rewrite only if type changed or `--force-config`) | Type-matched. |
| 5 | `.harness/logs/runs/` | dir | guided, quick, legacy, resume, update | ⬜ | minimal | — | **create-if-missing** | Run-log directory. |
| 6 | `.gitignore` | append | guided, quick, legacy, resume, update | ⬜ | minimal | — | **append-if-missing** | Adds `.harness/logs/` + `.harness/.registry.lock/` entries. Never overwrites user entries. |
| 7 | `feature_list.json` | file | guided, quick, legacy | ⬜ | minimal | — | **preserve** (skip if exists) | v2 schema, revision: 1. Type-agnostic. |
| 8 | `init.sh` | file | guided, quick, legacy | ⬜ | minimal | ♻️ | **preserve** (skip if exists; update only via 3-way compare in resume/update) | Executable. Type-matched from `by-type/<type>/init.sh` or `common/init.sh`. Template source: `templates/env-init.sh`. |
| 9 | `AGENTS.md` | file | guided, quick, legacy | ⬜ | minimal | ♻️ | **preserve** (skip if exists) | Type-matched. Written for both hosts. |
| 10 | `CLAUDE.md` | file | guided, quick, legacy | ⬜ | minimal | ♻️ | **preserve** (skip if exists) | Type-matched. Written for both hosts. |
| 11 | `<progress>` | file | guided, quick, legacy | 🔵 / 🟠 | minimal | **changed** | **preserve** (skip if exists) | `claude-progress.md` for `--host=claude`; `codex-progress.md` for `--host=codex`. **Behaviour change from rc.1:** rc.1 wrote `claude-progress.md` only in `--full` (Codex had `codex-progress.md` in minimal). rc.3 moves both to minimal — always written regardless of `--full`. |
| 12 | `session-handoff.md` | file | guided, quick, legacy | ⬜ | --full | — | **preserve** (skip if exists) | Session handoff doc. |
| 13 | `clean-state-checklist.md` | file | guided, quick, legacy | ⬜ | --full | — | **preserve** (skip if exists) | Pre-commit verification. |
| 14 | `checklist.sh` | file | guided, quick, legacy | ⬜ | --full | ♻️ | **preserve** (skip if exists) | Executable. Type-matched. |

**Minimal vs full count (single host):**

- **minimal** (default): files #1–#11. That is 8 common files (#1–#10) + 1 host-specific progress file (#11). Total: 9 files + 1 directory (#5) + 1 append-only (#6) = 11 operations.
- **full** (`--full`): minimal + #12, #13, #14. Total: 12 files + 1 directory + 1 append = 14 operations.

**Host-specific rules (binding design choice):**

- `AGENTS.md` (#9) and `CLAUDE.md` (#10) are **both written for both hosts**. Their content is type-matched (§8.4), not host-matched. They are **byte-equal across `--host=claude` and `--host=codex`** runs with the same Brief input.
- The progress file (#11) is the **only** host-specific path: `claude-progress.md` for `--host=claude`, `codex-progress.md` for `--host=codex`.
- All other files (#1–#8, #12–#14) are host-independent and byte-equal across hosts.

**resume/update behaviour (binding):**

- **PROJECT_BRIEF.json (#1): preserved by default.** Resume/update does not rewrite the Brief unless the user explicitly provides new Brief content (e.g., `--brief <new.json>` with `--update --apply`).
- **PROJECT_BRIEF.md (#2): rendered on change.** If #1 changed (new Brief fields), #2 is regenerated. If #1 is preserved, #2 is preserved. The standalone `--render-brief` flag (P5) regenerates #2 from existing #1 on demand.
- **.template-snapshot.json (#3): always updated** when any template-origin file is written, reflecting the actual post-write state.
- **All other files (#4–#14): skip-if-exists** (rc.1 behaviour preserved). resume/update via 3-way SHA compare (§4.4) may update template-origin files whose template changed but user didn't modify.
- **update dry-run** (`--update` without `--apply`): prints the plan; **zero writes** (per §3.4.1).

**Acceptance criteria linkage:**

- AC-4 asserts all minimal files (#1–#11) exist after init.
- AC-5 asserts **full tree byte-equal** across two runs with same Brief + same host (all fields identical, no filtering).
- AC-14 asserts common files (#1–#10, #12–#14) are byte-equal across `--host=claude` and `--host=codex`; only #11 differs per host.
- AC-7 asserts type-matched content in ♻️ files (#4, #8, #9, #10, #14).

### 6.2b rc.1 baseline (reference)

For traceability, the rc.1 executor (`scripts/harness-init.sh`, commit `e13d56d`) writes:

| Phase | Files |
|---|---|
| C (v2 scaffold, via `templates/init.sh`) | `.harness/config.json`, `.harness/logs/runs/` (dir), `feature_list.json`, `.gitignore` (append) |
| A (v1 scaffold) | `AGENTS.md`; host=claude→`CLAUDE.md` / host=codex→`codex-progress.md`; `init.sh` (from `templates/env-init.sh`, executable) |
| B (--full only) | host=claude→`claude-progress.md`; `session-handoff.md`; `clean-state-checklist.md`; `checklist.sh` (executable) |

rc.3 changes from this baseline:
- **Add** #1, #2, #3 (Brief JSON, Brief MD, template snapshot).
- **Modify** #4, #8, #9, #10, #14 for type-matching (§8.3, §8.4).
- **Expand** #9 and #10 to both hosts (rc.1 wrote `CLAUDE.md` only for claude; rc.3 writes both `AGENTS.md` and `CLAUDE.md` for both hosts).
- **Move** claude progress file (#11, host=claude) from `--full` to `minimal` (rc.1 wrote `claude-progress.md` only with `--full`; Codex `codex-progress.md` was already minimal in rc.1 and remains so). Both hosts now get their progress file in minimal mode.
- **Remove** `env-init.sh` as an output file (it is a template source only; its content is rendered into `init.sh` #8).

### 6.3 Trigger boundary

**All file mutations go through `scripts/harness-init.sh` (or a deterministic core executor).** SKILL.md never writes project files.

| Wire option | Description |
|---|---|
| **α** | `bash scripts/harness-init.sh --brief <json-path>` — Agent writes Brief to a temp file, passes path |
| **β** | `bash scripts/harness-init.sh --brief-stdin < brief.json` — pipe via stdin |
| **δ** | MCP tool `harness_init(brief: {...})` — future, if MCP is registered |
| ~~γ~~ | ~~Agent uses Write tool directly~~ — **REJECTED** (§0.3 C5; SKILL.md is dialog-only) |

The choice between α/β/δ is deferred to P3 (implementation). All three must produce byte-identical output for the same input Brief.

### 6.4 Defaults

Defaults used **only when source=default and no better evidence exists**. The brief records them in `defaults_applied`.

| Field | Default |
|---|---|
| `cadence` | `stable` |
| `deadline` | `null` (none) |
| `secrets_handling` | `unspecified` (was `env-file`; do not assume all projects use env files) |
| `external_network` | `ask` (was `allowed`; now `ask` per C9) |
| `prohibitions` | `[]` |
| `operation_preferences.commit` | `ask` (was `true`; now `ask` per C9) |
| `operation_preferences.push` | `ask` |
| `operation_preferences.merge` | `ask` |
| `operation_preferences.release` | `ask` |
| `operation_preferences.install_packages` | `ask` |
| `operation_preferences.external_mutation` | `ask` |
| `operation_preferences.destructive_ops` | `false` |

### 6.5 Backward compatibility (legacy mode)

This is an **honest compatibility contract**, **not** a byte-equivalent promise. v1 callers continue to run, but the output tree and template content intentionally differ.

| Property | Promise |
|---|---|
| **Command surface preserved** | All v1 commands and arguments still parse and run: `bash scripts/harness-init.sh <dir> [--full] [--host=claude\|codex]`. |
| **No new failures from missing fields** | Legacy mode never aborts because a field is missing; placeholders fill any gap (see §3.4 for snapshot/config edge cases). |
| **No overwrite of user files** | Existing user files are not overwritten (legacy-skip-existing and legacy-migration rules, §3.4). |
| **Exit-code categories preserved** | success (0), pre-flight check failed (2), user-rejected (3), partial write (1). v1 callers that see exit 0 today keep seeing exit 0 unless something new fails. |
| **New files & template changes = explicit RC behaviour change** | `<target>/.harness/PROJECT_BRIEF.json`, `<target>/.harness/PROJECT_BRIEF.md`, `<target>/.harness/.template-snapshot.json` are written. Template content is typed (per-type overrides, §8.4). Existing `templates/AGENTS.md`, `CLAUDE.md`, `env-init.sh` are modified to remove Node/Electron assumptions (§8.3). **These are documented RC behaviour changes, not byte-equivalent.** |

**Implications for downstream:**

- A v1 caller that diffs the output tree byte-for-byte will see differences. It must update.
- A v1 caller that checks for exit code or sentinel file presence continues to work.
- CI / downstream test consumers should be updated to ignore the new artefacts or compare against typed-template fixtures.

### 6.6 Error response

```
error: <field|condition>: <reason>
```

exit code non-zero. Partial writes are not silently rolled back; the user is told the partial state.

## 7. State and persistence

### 7.1 State ownership

| Stage | State location | Persistent? |
|---|---|---|
| Pre-confirm (steps 1–7 of 4.1) | Agent conversation context | No — not in target dir, not in tmpfs, not in `.harness/.draft.yml` |
| Post-confirm (step 8 of 4.1) | `<target>/.harness/PROJECT_BRIEF.json` (canonical) | Yes, git-tracked |
| | `<target>/.harness/PROJECT_BRIEF.md` (human rendering) | Yes, git-tracked |
| | `<target>/.harness/.template-snapshot.json` (3-way base) | Yes, git-tracked |
| Cross-session | Same three files | Yes |

### 7.2 Canonical artifact: `PROJECT_BRIEF.json`

JSON (parseable with `jq`, no new dependencies). Markdown body is auto-rendered from this file.

**Canonical JSON serialization rules** (binding; required for AC-5 byte-determinism):

- **Encoding:** UTF-8, no BOM.
- **Newlines:** LF (`\n`); never CRLF.
- **Key ordering:** stable, sorted alphabetically at every depth (lexicographic byte order). `jq -S` enforces this at write time.
- **Indentation:** 2 spaces.
- **Trailing:** exactly one newline at EOF. No trailing whitespace on any line.
- **No comments.** No JSON-with-comments. Pure JSON.

#### 7.2.1 Required-field table

The `Required input` column says whether the value must come from the user (or repo/env) before the brief can be valid. The `Required in canonical artifact` column says whether the JSON key must be present in the canonical file. **These are distinct concepts**; they were conflated in earlier revisions.

| Field | Type | Required input | Required in canonical artifact | Nullable | Notes |
|---|---|---|---|---|---|
| `schema_version` | integer | — | **Yes** | No | Must equal `1`. |
| `advisory` | boolean | — | **Yes** | No | Must be `true`. |
| `generated_by` | string | — | **Yes** | No | `"harness-companion v<X.Y.Z-rc.N>"`. |
| `source_version` | string | — | **Yes** | No | Same as `generated_by` version segment, e.g., `"2.0.0-rc.3"`. |
| `captured_from_git_rev` | string \| null | — | **Yes** | **Yes** | 40-char hex SHA, or `null` for tarball / release-asset / `--copy` installs that lack `.git`. |
| `template_manifest_digest` | string | — | **Yes** | No | SHA-256 of template manifest snapshot. Stable across reinstalls at same version. |
| `detected_type` | enum | — | **Yes** | No | Enum per §7.2.2. |
| `goal` | string | **Yes** | **Yes** | No | Non-empty after trim; 1 ≤ length ≤ 500. Required input: `quick` aborts if missing; `legacy` fills placeholder. |
| `success_criteria` | array of strings | **Yes** | **Yes** | No | 1 ≤ length ≤ 7; each entry non-empty after trim. Required input: `quick` aborts if missing. |
| `cadence` | enum | — | **Yes** | No | Default `"stable"`. |
| `deadline` | string \| null | — | **Yes** | **Yes** | `null` or ISO-8601 date `YYYY-MM-DD`. **Past dates trigger a warning, not rejection** (a project may already be overdue). |
| `stack` | enum | — | **Yes** | No | Default = value of `detected_type`. |
| `test_framework` | enum \| string | — | **Yes** | **No** (use enum values) | `none \| unspecified` enum values, OR known framework enum, OR free string ≤ 50 chars. **`null` is NOT allowed.** `none` = confirmed no framework; `unspecified` = not provided or not detected. |
| `secrets_handling` | enum | — | **Yes** | No | Default `"unspecified"`. |
| `external_network` | enum | — | **Yes** | No | Default `"ask"`. |
| `prohibitions` | array of strings | — | **Yes** | No | Default `[]`; ≤ 20 entries; each ≤ 200 chars. |
| `initial_project_state` | object | — | **Yes** | No | Object per §7.2.3. **Required in canonical artifact; not nullable.** |
| `operation_preferences` | object | — | **Yes** | No | Object per §7.2.4. **Required in canonical artifact; not nullable.** |
| `defaults_applied` | array of objects | — | **Yes** | No | Default `[]`; structured per §7.2.5. **Required in canonical artifact; not nullable.** |
| `conflicts_resolved` | array of objects | — | **Yes** | No | Default `[]`; structured per §7.2.6. **Required in canonical artifact; not nullable.** |
| `type_evidence` | object \| null | — | **Yes** | **Yes** | **Key always present in canonical.** `null` for ordinary types. Non-null object required when `detected_type ∈ {mixed, unknown}` (per §7.2.7). |
| `provenance` | object | — | **Yes** | No | **Always present.** `{}` when no provenance has been recorded yet (fresh init). Per §7.2.5a. |

**`Required input` rationale:** only `goal` and `success_criteria` must come from the user (or be inferable from context). Everything else can default. `quick` mode aborts when these two are missing; `legacy` fills placeholders.

**`Required in canonical artifact` rationale:** a fixed schema is easier to test and grep than a sparse one. Keys that are not applicable are represented as their natural empty value (`null` where permitted, `[]`, the default value, or `unspecified` enum). This rule means `jq -e '.field' < brief.json` succeeds for every documented field.

#### 7.2.2 Enum allowed values

- `detected_type`: `node | python | rust | go | shell | electron | mixed | docs | unknown`.
- `cadence`: `stable | weekly | daily | oneoff`.
- `stack`: any of `detected_type` values.
- `secrets_handling`: `env-file | vault | keyring | unspecified`.
- `external_network`: `ask | allowed | denied`.
- `test_framework`: `pytest | vitest | jest | mocha | cargo-test | go-test | shellcheck | bats | none | unspecified`, or free string (≤ 50 chars) for custom runners. **Not nullable.** `none` = confirmed no test framework; `unspecified` = not provided or not detected.
- `operation_preferences.{commit,push,merge,release,install_packages,external_mutation}`: `ask | auto | denied`.
- `operation_preferences.destructive_ops`: `true | false`.

#### 7.2.3 `initial_project_state` (renamed from `project_state`)

Renamed because the value reflects **observation before init**, not the post-write state. After init writes `PROJECT_BRIEF.json`, any field like `is_initialized` would otherwise flip to `true` immediately, making the recorded value stale.

```json
{
  "is_git_repo": true,
  "has_existing_tests": true,
  "existing_harness_files": ["AGENTS.md"],
  "detection_summary": "git repo; pytest detected; existing AGENTS.md"
}
```

| Field | Type | Notes |
|---|---|---|
| `is_git_repo` | boolean | `git rev-parse --is-inside-work-tree` exit 0. |
| `has_existing_tests` | boolean | any of: `pytest.ini`, `pyproject.toml [tool.pytest]`, `Cargo.toml`, `go.mod` with test files, `package.json scripts.test`, `Makefile`, `*.bats`. |
| `existing_harness_files` | array of strings | Paths relative to target root. |
| `detection_summary` | string | ≤ 200 chars human-readable. |

#### 7.2.4 `operation_preferences`

```json
{
  "commit": "ask",
  "push": "ask",
  "merge": "ask",
  "release": "ask",
  "install_packages": "ask",
  "external_mutation": "ask",
  "destructive_ops": false
}
```

All values per §7.2.2 enum rules. **Advisory only** — see §0.3 C9; current session user instructions and host security policies always take precedence.

#### 7.2.5 `defaults_applied` (structured object)

Each entry is an **object**, **not** a display string:

```json
{
  "field": "/cadence",
  "value": "stable",
  "rationale": "user did not specify; default per spec §6.4",
  "source": "spec_default"
}
```

| Field | Type | Notes |
|---|---|---|
| `field` | string | Standard JSON Pointer (RFC 6901), e.g., `"/cadence"`, `"/operation_preferences/commit"`. **Not** a dotted path. |
| `value` | any | The JSON value applied. |
| `rationale` | string | ≤ 200 chars. Why this default was used. |
| `source` | enum | `spec_default | legacy_placeholder`. |

**`defaults_applied` does NOT carry provenance.** Only two `source` values:

- `spec_default` — value came from the §6.4 defaults table.
- `legacy_placeholder` — value was filled by legacy-mode placeholder fill.

**Repo-inferred values are NOT recorded here.** They are either accepted silently (when they fill a field) or, if explicit provenance is needed, recorded in the `provenance` map (§7.2.5a, which is always present in the canonical artifact).

#### 7.2.5a `provenance` (required per-field provenance map)

A top-level `provenance` object records where **available** Brief field values came from. **The top-level key is always present in the canonical artifact** (not optional; not omitted). When no provenance has been recorded yet (fresh init, no inferences made), the value is `{}`. Only fields whose source is known at write time are recorded — provenance does **not** claim to cover every field in the Brief. Missing keys mean "provenance not recorded for this field."

Keys use **standard JSON Pointer** syntax (RFC 6901): `/goal`, `/success_criteria`, `/stack`, `/cadence`, `/operation_preferences/commit`, etc. **Not** dotted field paths like `"operation_preferences.commit"`.

```json
{
  "provenance": {
    "/goal":                         { "source": "conversation" },
    "/stack":                        { "source": "repo",         "marker": "package.json" },
    "/test_framework":               { "source": "spec_default" },
    "/cadence":                      { "source": "spec_default" },
    "/operation_preferences/commit": { "source": "spec_default" }
  }
}
```

| `source` value | Notes |
|---|---|
| `conversation` | Value came from user dialog (or mock user input in eval). |
| `repo` | Value inferred from repo markers. |
| `environment` | Value came from env var (e.g., `HARNESS_TEST_FRAMEWORK`). |
| `cli` | Value came from CLI argument. |
| `spec_default` | Value came from §6.4 defaults. Also recorded in `defaults_applied`. |
| `legacy_placeholder` | Value filled by legacy-mode placeholder. Also recorded in `defaults_applied`. |
| `existing_brief` | Value inherited from an existing `PROJECT_BRIEF.json` during resume/update. Used when the Brief field is carried forward without change. |

**`defaults_applied` and `provenance` are separate concerns.** `defaults_applied` records **which spec defaults were used and why** (source subset: `spec_default | legacy_placeholder`). `provenance` records **where available field values came from** (full 7-way source; only fields whose source is known at write time are recorded — missing keys mean "provenance not recorded for this field").

**No host-dependent metadata in provenance.** Fields like `"turn": 2` (conversation round number) are host-dependent, non-deterministic, and excluded. The provenance entry contains only `source` and an optional `marker` (for `repo` source).

#### 7.2.6 `conflicts_resolved` (array of conflict outcomes)

This array records the outcome of every conflict detected during onboarding. **Entries may be resolved (`resolution ∈ {user, repo, custom}`) or deferred (`resolution = deferred`).** Despite the field name `conflicts_resolved`, both resolved and deferred conflicts appear here. (Renaming to `conflict_outcomes` is deferred for now; the spec explicitly permits deferred entries.)

```json
{
  "field": "/stack",
  "repo_evidence": "node (package.json present)",
  "user_input": "Python project",
  "resolution": "user",
  "resolved_value": "python"
}
```

| Field | Type | Notes |
|---|---|---|
| `field` | string | Standard JSON Pointer (RFC 6901) to the conflicting field, e.g., `"/stack"`, `"/goal"`. **Not** a dotted path. |
| `repo_evidence` | string | What the repo said. |
| `user_input` | string | What the user said. |
| `resolution` | enum | `user | repo | custom | deferred`. |
| `resolved_value` | any | The final resolved value. **Always present in the canonical record** (never omitted). Must be non-null when `resolution ∈ {user, repo, custom}`. Must be `null` (explicitly, not omitted) when `resolution = deferred`. |

**Resolution semantics:**

| `resolution` | Meaning | `resolved_value` |
|---|---|---|
| `user` | User's input wins (after Agent's two-option prompt, §5.2). | The user-stated value. |
| `repo` | Repo evidence wins. | The repo-derived value. |
| `custom` | User provided a value different from both options ("Tell me more" resolved into a third option). | The custom value. |
| `deferred` | Resolution postponed to a later session or skipped. | `null` (explicitly, never omitted) |

**Rules (binding):**

- `goal`, `success_criteria`, `detected_type` (when it is the primary project type in `stack`), and `initial_project_state.is_git_repo` are **execution-critical** conflicts. They **must not** be `deferred`; if unresolved, `quick` aborts and `legacy` falls back to repo evidence with a warning.
- **"Tell me more" is NOT a `resolution`.** It is a request for clarification. The follow-up turn produces a real `resolution ∈ {user, custom, deferred, repo}`. Anything recorded as `resolution = deferred` after a "Tell me more" round is treated as still-unresolved.
- `repo`, `user`, and `custom` resolutions **must** include `resolved_value` as a non-null value. `deferred` resolutions **must** include `resolved_value` as an explicit `null`. The key `resolved_value` is **never omitted** — omitting it is a schema violation, equivalent to the field being missing from the record. This gives a single canonical representation.

#### 7.2.7 `type_evidence` (required when `detected_type = unknown | mixed`)

```json
{
  "markers_seen": ["package.json", "pyproject.toml"],
  "notes": "Both Node and Python markers present; user was asked to pick."
}
```

| Field | Type | Notes |
|---|---|---|
| `markers_seen` | array of strings | Each detected marker (file path or pattern). `[]` is valid only when `detected_type = unknown` with no markers at all. |
| `notes` | string | ≤ 500 chars human explanation. |

#### 7.2.8 Full example

```json
{
  "advisory": true,
  "captured_from_git_rev": "e13d56d49189b0563d4ccd8af638df6e7bc1195b",
  "cadence": "stable",
  "conflicts_resolved": [],
  "deadline": null,
  "defaults_applied": [
    {
      "field": "/cadence",
      "rationale": "user did not specify; default per spec §6.4",
      "source": "spec_default",
      "value": "stable"
    }
  ],
  "detected_type": "python",
  "external_network": "ask",
  "generated_by": "harness-companion v2.0.0-rc.3",
  "goal": "Refactor the auth module",
  "initial_project_state": {
    "detection_summary": "git repo; pytest detected",
    "existing_harness_files": ["AGENTS.md"],
    "has_existing_tests": true,
    "is_git_repo": true
  },
  "operation_preferences": {
    "commit": "ask",
    "destructive_ops": false,
    "external_mutation": "ask",
    "install_packages": "ask",
    "merge": "ask",
    "push": "ask",
    "release": "ask"
  },
  "prohibitions": [],
  "provenance": {
    "/goal":           { "source": "conversation" },
    "/success_criteria": { "source": "conversation" },
    "/stack":          { "source": "spec_default" },
    "/cadence":        { "source": "spec_default" },
    "/test_framework": { "source": "repo", "marker": "pyproject.toml" },
    "/operation_preferences/commit": { "source": "spec_default" }
  },
  "schema_version": 1,
  "secrets_handling": "unspecified",
  "source_version": "2.0.0-rc.3",
  "stack": "python",
  "success_criteria": [
    "all tests pass",
    "pypi release cut"
  ],
  "template_manifest_digest": "abc123...",
  "test_framework": "pytest",
  "type_evidence": null
}
```

### 7.3 What is NOT in the brief

- **No `user_session`.** Session IDs are ephemeral and not committed.
- **No absolute `project_root`.** Repo-relative paths are recorded only when the target is itself a git repo; otherwise, project root is omitted.
- **No wall-clock time.** Reproducibility is achieved by `captured_from_git_rev` (when available; may be `null` for tarball installs) + `source_version` + `template_manifest_digest` (always present).
- **No display strings in structured fields.** `defaults_applied` and `conflicts_resolved` are objects, not prose. The writer rejects strings like `"was true in v1; tell me to change"`.

### 7.4 Markdown rendering: `PROJECT_BRIEF.md`

Auto-generated from `PROJECT_BRIEF.json`. Header:

```
<!-- generated from PROJECT_BRIEF.json schema_version=1 source_version=2.0.0-rc.3 -->
<!-- DO NOT EDIT — regenerate from JSON. On mismatch, JSON is authoritative. -->
```

**Regeneration rules:**

- **`/harness:status` detects but does NOT rewrite.** If `PROJECT_BRIEF.json` and `PROJECT_BRIEF.md` disagree on `captured_from_git_rev`, `schema_version`, or `source_version`, status emits `warning: PROJECT_BRIEF.md is out of sync with JSON; using JSON` — but does **not** touch the Markdown file. Status is read-only.
- **Markdown can only be regenerated by `scripts/harness-init.sh`**, specifically its resume execution path (detected when `.harness/.template-snapshot.json` exists) and the post-confirm step in guided/quick/legacy. No other tool or slash command writes `PROJECT_BRIEF.md`.
- **If an independent entry point is needed**, P5 will add a `--render-brief` flag to `scripts/harness-init.sh`. This still routes through the same deterministic executor; it does not create a second writer.
- **MD renderer is deterministic.** A fresh render from the same `PROJECT_BRIEF.json` + same `source_version` produces **byte-equal** `PROJECT_BRIEF.md` output. Tests assert byte-equality of fresh-rendered MD across two runs with the same Brief input (AC-5 covers this via full-tree diff).
- **User-edited MD is not byte-compared.** When a user has manually edited `PROJECT_BRIEF.md` and the resume/update path preserves it (no JSON change, no `--render-brief`), no byte-equality assertion is made against the fresh-render output. Only the JSON-vs-MD key-field consistency check applies (§7.4 warning).
- **`--render-brief` restores determinism.** After `--render-brief` regenerates the MD from JSON, the output is once again deterministic and must match a fresh render byte-for-byte.

### 7.5 Why JSON, not YAML front matter

`jq` is already a hard dependency of harness-companion. `yq` is not. Tests must not introduce undeclared dependencies (§0.2). The Markdown file is auto-rendered, so tests do not need a markdown parser; they assert file existence + key fields via `jq` on the JSON.

### 7.6 Why alphabetical key ordering

`jq -S` sorts object keys alphabetically at write time. Stable ordering is required for AC-5 byte-determinism and meaningful git diffs of `PROJECT_BRIEF.json`. This is enforced in the writer, not by convention.

## 8. Project type detection and templates

### 8.1 Unified type enum

| Value | Detection signal |
|---|---|
| `node` | `package.json` exists |
| `python` | `pyproject.toml` / `setup.py` / `requirements.txt` / `Pipfile` exists |
| `rust` | `Cargo.toml` exists |
| `go` | `go.mod` exists |
| `shell` | no source markers above; `Makefile` / `*.mk` / `*.sh` at root |
| `electron` | `package.json` with `electron` / `tauri` / `nw` in dependencies |
| `mixed` | multiple distinct source markers (e.g., Node + Python) |
| `docs` | no source markers; markdown files at root or `docs/` directory |
| `unknown` | none of the above |

`mixed` is the only type that does not have a single clean answer. When detected, the brief must record which markers triggered it; the user is asked to confirm or pick a primary type.

### 8.2 `core/lib/project-detect.sh` modifications (allowed, scoped)

| Allowed change | Limit |
|---|---|
| Add `detect_shell`, `detect_electron`, `detect_mixed` | ≤ 20 lines net |
| Update `detect_project_type` to consider `shell` / `electron` / `mixed` and return `unknown` (replacing `generic`) | ≤ 10 lines net |
| Total `core/lib/*` delta | < 50 lines (§9.3 AC-16) |

### 8.3 Templates allowed to change

Existing templates in `templates/` may be **modified** to remove Node/Electron-specific assumptions and to support the typed-template approach (§8.4). Specifically:

- `templates/AGENTS.md` — remove Electron `src/main/`, `src/preload/`, etc. references; add generic placeholders.
- `templates/CLAUDE.md` — remove `npm install` / `npm run check` / `npm test`; add generic commands.
- `templates/env-init.sh` — remove `npm install` / `npx tsc` / `npm run build`; add generic verifications.

These modifications must:

- not change the file's purpose or section structure
- preserve the placeholder substitution mechanism (e.g., `replace-with-project-name`)
- be tracked as a single commit with rationale
- ship with a unit test proving the white-list check (§9.1 AC-7) passes for `node` and `electron` types

### 8.4 Typed-template approach

```
templates/
  common/                       # shared across all types
    AGENTS.md                   # generic, with type-conditional sections
    CLAUDE.md                   # generic
    feature_list.json           # type-agnostic
    init.sh                     # generic
    checklist.sh                # generic
  by-type/
    node/                       # type-specific overrides
      init.sh                   # adds npm install / build
      AGENTS.md                 # adds TypeScript / Node conventions
      CLAUDE.md                 # adds npm commands
    python/
      init.sh                   # adds pip install / pytest
      AGENTS.md                 # adds PEP 8 / type hints
      CLAUDE.md                 # adds pytest / pip commands
    rust/                       # ...
    go/                         # ...
    shell/                      # ...
    electron/                   # ...
    mixed/                      # defaults to common; user can override
    docs/                       # ...
    unknown/                    # common only
  by-type/.gitkeep
```

**Selection rule:** for each file F, the renderer uses `<root>/templates/by-type/<type>/F` if it exists, else falls back to `<root>/templates/common/F`.

Renderer lives in `scripts/harness-init.sh` (not in SKILL.md; per C5).

### 8.5 Template manifest: `<target>/.harness/.template-snapshot.json`

Written on every successful init. Used by 4.4 resume / 4.5 update for 3-way compare.

```json
{
  "schema_version": 1,
  "captured_from_git_rev": "<SHA of harness-companion repo that wrote this, or null>",
  "source_version": "2.0.0-rc.3",
  "templates": {
    "AGENTS.md":        { "source": "by-type/python/AGENTS.md", "sha256": "..." },
    "CLAUDE.md":        { "source": "common/CLAUDE.md",        "sha256": "..." },
    "init.sh":          { "source": "by-type/python/init.sh",   "sha256": "..." },
    "feature_list.json":{ "source": "common/feature_list.json", "sha256": "..." },
    ".harness/config.json": { "source": "by-type/python/.harness/config.json", "sha256": "..." }
  }
}
```

**Field semantics:**

| Field | Type | Nullable | Notes |
|---|---|---|---|
| `schema_version` | integer | No | Must equal `1`. |
| `captured_from_git_rev` | string \| null | **Yes** | 40-char hex SHA of the harness-companion repo HEAD that wrote this snapshot, or `null` for tarball / release-asset / `--copy` installs that lack `.git`. Same semantics as `PROJECT_BRIEF.json` `captured_from_git_rev` (§7.2.1). |
| `source_version` | string | No | Harness-companion version that wrote this snapshot, e.g., `"2.0.0-rc.3"`. Same semantics as `PROJECT_BRIEF.json` `source_version` (§7.2.1). Matches the version segment of `generated_by`. |
| `templates` | object | No | Map of relative target path → `{source, sha256}` for each template-origin file written. |

**Crucially:** `core/lib/baseline.sh` (which is the SessionStart Git baseline, see `references/subsystems-mapping.md`) is **not** modified for this purpose. Template tracking is a separate concern and gets its own file.

## 9. Acceptance criteria

### 9.1 Functional (8)

| AC | Description | Test mechanism |
|---|---|---|
| **AC-1 Default mode collects** | Default `/harness:init` runs the 5-category collection; ≤ 3 questions per round; covers ≥ 4 of 5 categories. | **Skill eval** (§9.5) |
| **AC-2 No re-asking** | Info already in conversation or detectable from repo is not re-asked. | **Skill eval** |
| **AC-3 Pre-confirm = 0 writes** | User rejecting the Brief leaves the target dir byte-identical. | **Shell**: full tree manifest before + after, `diff` empty |
| **AC-4 Post-confirm persistence** | After approval: (a) `<target>/.harness/PROJECT_BRIEF.json` exists with all 5 categories + `operation_preferences` + `defaults_applied` + `conflicts_resolved` + `advisory: true`; (b) all minimal-manifest files for the target host (§6.2a #1–#11) exist; (c) `.harness/logs/runs/` (#5) is a directory; (d) `.gitignore` (#6) contains the required append entries (`.harness/logs/` and `.harness/.registry.lock/`). | **Shell**: `jq` parses Brief; assert field presence + `advisory==true`; `test -f` / `test -d` for #1–#11; `grep` for `.gitignore` entries. |
| **AC-5 Executor deterministic (brief-driven)** | Two `bash scripts/harness-init.sh <dir> --brief <path> --non-interactive --host=<h>` runs with byte-identical `<path>` input (Brief JSON) produce **byte-equal output trees**. The three repo-derived fields (`captured_from_git_rev`, `template_manifest_digest`, `generated_by`) **must be identical** across runs — same harness repo HEAD, same values. Do not filter them out; assert the full tree is byte-equal. v1 legacy caller (no `--brief`, no `--non-interactive`) still works per §6.5 compatibility contract. | **Shell**: write a Brief JSON to two `mktemp -d` targets, run `bash scripts/harness-init.sh <dir> --brief <brief.json> --non-interactive --host=claude` for each, then `diff -r` the two output trees. Assert `diff` is empty (no filtering). **Does not mix `quick` (Agent) and `legacy` (Bash).** |
| **AC-6 Resume safety** | Re-running in an initialized project does not overwrite user-modified files. | **Shell**: 3-way SHA compare; user-modified files unchanged |
| **AC-7 Type-matching content** | For each `detected_type`, the **generated** content matches a per-type **white-list** of acceptable commands/files. **White-list is the positive assertion; black-list is secondary.** White-list per type is a fixture shipped with the test. | **Shell**: for each of `node`, `python`, `shell`, `docs`, `go`, `rust`, `electron`: run `bash scripts/harness-init.sh <dir> --brief <brief.json> --non-interactive --host=claude` with a Brief whose `detected_type` matches the type under test; assert each generated file (NOT just `.harness/config.json`) contains only commands from the type's white-list. Black-list as fallback. **Tests the executor, not the Agent.** |
| **AC-8 Lightweight check boundary** | Init does not run `npm install`, `cargo build`, `pytest`, `go test`. | **Shell**: `strace -e trace=execve` (or equivalent) on a fixture init run; assert none of the prohibited commands appear |

### 9.2 New requirements (4)

| AC | Description | Test mechanism |
|---|---|---|
| **AC-9 Conflict handling** | Repo says X, user says ¬X → Agent asks one precise question with both as options; does not silently pick. | **Skill eval** |
| **AC-10 No `claude-mem`** | Code never references `claude-mem` or `claude_mem`. | **Shell**: `grep -rE "claude[-_]mem" core/ scripts/ templates/ adapters/ tests/` returns 0 matches outside comments. |
| **AC-11 Persistence format** | `PROJECT_BRIEF.json` has all 5 categories + `operation_preferences` + `advisory: true`; `PROJECT_BRIEF.md` exists and references the same `captured_from_git_rev`. | **Shell**: `jq` + `grep` |
| **AC-12 Isolation discipline** | See §9.4 ISO-1..5. | **Shell** |

### 9.3 Derived (5)

| AC | Description | Test mechanism |
|---|---|---|
| **AC-13a Executor rejects Brief missing required fields** | `bash scripts/harness-init.sh <dir> --brief <brief.json> --non-interactive` where the Brief JSON is missing `goal` or `success_criteria` (or either is empty after trim) exits non-zero with stderr `error: required field '<field>' is missing or empty`. **Does NOT apply to legacy CLI mode** (which fills placeholders). | **Shell**: write a Brief JSON with `goal` set to `""` or missing; assert exit ≠ 0 and stderr contains the error message. |
| **AC-13b Agent quick-mode error routing** | Agent's `/harness:init --quick` correctly routes the executor error to the user: when the executor rejects a Brief missing required fields, the Agent reports the error and does not retry or silently fall back to legacy. | **Skill eval** (§9.5.2): mock a repo where required fields cannot be filled; assert Agent reports error and exits without writing. |
| **AC-14 Cross-host common-artifact equality** | After running init in two `mktemp -d` targets with `--host=claude` and `--host=codex`, the **common artifacts** (files #1–#10 + #12–#14 per §6.2a: everything except the host-specific progress file #11) are **byte-equal** across the two trees. The only host-specific path is #11 (`claude-progress.md` for claude, `codex-progress.md` for codex). `AGENTS.md` (#9) and `CLAUDE.md` (#10) are written for both hosts and must be byte-equal. | **Shell**: run init with `--host=claude` and `--host=codex` into two `mktemp -d` targets with the same Brief. Extract the common subset (all files minus #11) from each tree; `diff -r` must be empty. Then separately verify the Claude tree has `claude-progress.md` (#11, host=claude) and the Codex tree has `codex-progress.md` (#11, host=codex). **Do not rename-and-diff the whole tree.** |
| **AC-15 SKILL.md is the dialog authority** | `scripts/harness-init.sh` does not use `read -p` or `read -r` for prompting. | **Shell**: `grep -nE "read -[pr] " scripts/harness-init.sh` returns 0 |
| **AC-16 core/lib minimal** | Sum of `+/-` line counts across `core/lib/*` in the PR is < 50. | **Shell**: `git diff --stat` on `core/lib/*` summed; assert < 50 |

### 9.4 Isolation sub-criteria (AC-12 / ISO-1..5)

| AC | Description | Test mechanism |
|---|---|---|
| **ISO-1** | Tests do not reference `~/.claude/` or `~/.agents/` except in comments. | `grep -rE "\\.claude/\|\\.agents/" tests/` returns 0 non-comment lines. |
| **ISO-2** | All install/upgrade tests set `HOME=$(mktemp -d)` or `INSTALL_TARGET=$tmpdir`. | All `tests/**/test-*.sh` that touch `install.sh` set the env var. |
| **ISO-3** | GitHub Actions workflow sets `HOME` explicitly to a runner temp. | `grep "HOME:" .github/workflows/ci.yml` (or equivalent) sets it to a runner temp path. |
| **ISO-4** | Tests use a `mktemp -d` simulating `~/.claude/skills/harness-companion/`, not the real path. Verify the simulated sentinel is unchanged after `bash tests/run-all.sh`. | `bash tests/run-all.sh` then `sha256sum $TMPDIR/simulated-claude/skills/harness-companion/.sentinel` unchanged. |
| **ISO-5** | Real local install check is **manual, post-release, optional** — not part of CI. | Spec-only; no automated test. |

### 9.5 Test mechanisms

Two test mechanisms, used for different ACs.

#### 9.5.1 Shell tests (most ACs)

Plain bash + `jq` + `grep` + `find` + `sha256sum` + `diff`. Located under `tests/`. Self-contained, no Claude API calls.

Examples:

- `tests/init/test-pre-confirm-zero-writes.sh` — AC-3
- `tests/init/test-executor-reject-missing-required.sh` — AC-13a
- `tests/eval/cases/quick-mode-abort-routing.json` — AC-13b
- `tests/init/test-resume-safety.sh` — AC-6
- `tests/init/test-type-matching-content.sh` — AC-7
- `tests/init/test-isolation.sh` — ISO-1..4

#### 9.5.2 Skill eval / scripted session tests (AC-1, AC-2, AC-9)

**Design constraint (binding):** `scripts/harness-init.sh --eval` is **not** an acceptable substitute for real Agent dialog. If the bash tool decides "what to ask, what not to ask, how to resolve conflicts", it embodies a **second dialog logic** that conflicts with "SKILL.md is the dialog authority" (§0.3 C5). If it merely replays a fixed transcript, it cannot verify that a real Agent obeys SKILL.md.

**Adopted split:**

| Test concern | Mechanism |
|---|---|
| Bash executor correctness (file writes, schema, file safety, byte-equivalence, AC-3/4/5/6/7/8/10/11/12/13/14/15/16) | **Shell tests** under §9.5.1 |
| Agent dialog behaviour (AC-1, AC-2, AC-9) | **Real skill evaluation harness** if available, else **versioned eval cases + pre-release manual / host-level acceptance** (NOT bash pseudo-dialog) |

**Bash tests are explicit about what they do NOT cover:**

- AC-1, AC-2, AC-9 are **not** tested by bash pseudo-dialog.
- They are tested by either:
  - **(a)** a host-integrated eval harness (e.g., Claude Code `claude eval`, Codex equivalent) registered in CI; **or**
  - **(b)** a **versioned eval case suite** under `tests/eval/cases/` that a human (or a CI job with a real Agent API key) runs before each release, recording the result in `tests/eval/results/<case-name>.<version>.<timestamp>.json`.

**Eval case format** (`tests/eval/cases/<name>.json`):

```json
{
  "name": "guided-default-python-repo",
  "version": "1",
  "fixture": "fixtures/python-pytest",
  "mock_user_inputs": [
    "I want to refactor the auth module",
    "Success: all tests pass; pypi release cut",
    "Python with pytest, no new tools",
    "commit yes, push yes when tests pass, merge no, release no"
  ],
  "expected_dialog_signals": {
    "did_not_ask": ["stack", "test_framework"],
    "asked_at_most_per_round": 3,
    "covered_categories": ["goal", "success_criteria", "operation_preferences"],
    "conflict_resolution_format": "two options + tell me more + skip"
  },
  "expected_post_init_files": [
    ".harness/PROJECT_BRIEF.json",
    ".harness/PROJECT_BRIEF.md",
    ".harness/.template-snapshot.json",
    "AGENTS.md",
    "feature_list.json"
  ],
  "expected_brief_fields": {
    "operation_preferences.commit": "ask",
    "operation_preferences.push": "ask"
  }
}
```

`expected_dialog_signals` lists **observable invariants** the Agent must exhibit (e.g., `"did_not_ask: stack"`), not exact wording.

**Eval runner** (`tests/eval/run-eval.sh <case.json>`):

- Sets up `fixture` in a `mktemp -d`.
- Invokes a real Agent with the case as prompt (CLI flag `--eval-case <case.json>` on the Agent CLI, or a registered MCP harness).
- Captures the transcript and post-init tree.
- Asserts each invariant in `expected_dialog_signals` and `expected_brief_fields`.
- Writes result to `tests/eval/results/<case-name>.<version>.<timestamp>.json`.

**If no eval harness is wired:** the case suite is still checked in. CI verifies the case files parse. The actual Agent run is a **manual / host-level** step before release (§14 gates). A failed or unrun eval case blocks the release gate.

**Tooling constraint:** case files use only `bash`, `jq`, `grep`. The runner may require an Agent CLI / API key, but those are CI- or host-runtime concerns, not repo deps.

**Tests in this mechanism:**

- `tests/eval/cases/guided-default-python-repo.json` — AC-1
- `tests/eval/cases/no-re-asking.json` — AC-2
- `tests/eval/cases/conflict-handling.json` — AC-9

**What this spec does NOT claim:**

- This spec does NOT claim that AC-1/2/9 are auto-passed by CI today. They are gated by either an eval harness wiring or a pre-release manual step. A green CI without eval wiring is acceptable **only** if the §14 release gate requires the eval-result JSON to be present.

## 10. Release order

| # | Step | Tag / status | Pre-condition |
|---|---|---|---|
| R1 | Implement rc.2 (`distribution/rc2-hardening` branch): B1–B3 fixes + A–E hardening areas. PR-B for rc.2 is reviewed and merged to master. | tag `v2.0.0-rc.2` (distribution baseline) | spec calibration F0 passes |
| R2 | GitHub pre-release of `v2.0.0-rc.2` with tarball asset. | public pre-release | R1 merge + tag |
| R3 | (Optional) Local install update via official `install.sh`. | not part of this PR | user authorization |
| R4 | `git checkout master && git pull` (master now contains rc.2). Verify no local divergences. | master clean | R1 + R2 + R3 (or skip R3) |
| R5 | `git checkout -b spec/harness-init-guided-onboarding` from master HEAD. | feature branch | R4 |
| R6 | Implement this spec (P2–P11). PR-B for guided. | draft PR | R5 |
| R7 | PR-B reviewed and merged to master. | tag `v2.0.0-rc.3` | user authorization |
| R8 | GitHub pre-release of `v2.0.0-rc.3`. | internal / early adopters | R7 merge + tag |
| R9 | After rc.3 completes **pre-release verification with no blocking issues** (manual eval pass + CI green + user-approved pre-release), and rc.2 is similarly verified, cut stable `v2.0.0`. RC itself is not called "stable". | public stable | user authorization |
| R10 | Future, after `v2.0.0` is widely used: any further change goes to `v2.1.0-rc.1` per SemVer. | post-stable | n/a |

`v2.0.0-rc.3` (not `v2.1.0-rc.1`) is chosen because `v2.0.0` is not yet stable. Bumping to `v2.1.0-rc.1` would be misleading until `v2.0.0` is GA.

## 11. Implementation phases

| Phase | Deliverable | Time | Pre-condition |
|---|---|---|---|
| P0 | This spec. | done | — |
| P1 | `git checkout master && git pull && git checkout -b spec/harness-init-guided-onboarding` from rc.2-merged master. | 5 min | **R1–R4 complete; rc.2 tag cut; master clean** |
| P2 | Update `core/lib/project-detect.sh` to add `shell` / `electron` / `mixed` / `unknown` (§8.2). | 1 h | P1 |
| P3 | Restructure `templates/` into `common/` + `by-type/<type>/` (§8.4). Modify existing `AGENTS.md` / `CLAUDE.md` / `env-init.sh` to remove Node/Electron assumptions (§8.3). | 2 h | P2 |
| P4 | Add `templates/PROJECT_BRIEF.json.schema` (informal) and the renderer logic. | 1 h | P3 |
| P5 | Update `scripts/harness-init.sh` to support `--brief <path>`, `--brief-stdin`, `--non-interactive`, `--update`, `--apply`, `--host`, `--render-brief`. **Bash `--update` without `--apply` prints plan/diff only; no write (per §3.4.1).** `--render-brief` regenerates `PROJECT_BRIEF.md` from `PROJECT_BRIEF.json` on demand (the only code path that writes the Markdown file, per §7.4). Legacy compatibility contract per §6.5 (honest contract, **not** byte-equivalent). **No `--eval` flag** — the bash executor is not the dialog authority (per §9.5.2 binding constraint). | 2 h | P3 |
| P6 | Update `SKILL.md`: rewrite the `/harness:init` section; add `## Onboarding workflow` section. | 2 h | P5 |
| P7 | Write shell tests under `tests/init/` and `tests/release/`. | 3 h | P5 |
| P8 | Write **versioned eval cases** under `tests/eval/cases/` (§9.5.2). **Do NOT implement `scripts/harness-init.sh --eval`** — the bash executor is not the dialog authority. The eval runner invokes a **real Agent** (Claude Code / Codex) with the case as input and writes results to `tests/eval/results/`. If no Agent CLI is wired, cases are still checked in; CI only verifies the case files parse. The actual Agent run is a manual / host-level step gated by §14. | 3 h | P5 |
| P9 | Add `.github/workflows/ci.yml` Phase 10: shell tests + eval tests + isolation. | 1 h | P7, P8 |
| P10 | Local dry-run: `bash tests/run-all.sh` + `bash tests/eval/run-all.sh`; verify AC-12 ISO-1..4; verify AC-15, AC-16. | 1 h | P9 |
| P11 | Open PR. CI green. **User reviews and merges** (§14 gate). | — | P10 |
| P12 | **User authorizes tag** (§14). Tag `v2.0.0-rc.3`. | 5 min | P11 merge |
| P13 | **User authorizes GitHub release** (§14). Pre-release with tarball. | 15 min | P12 |
| P14 | (Optional) **User authorizes local install** (§14). Run official `install.sh`. | 15 min | P13 |

Total estimated: ~16 hours after spec approval and rc.2 shipped.

## 12. Open questions

None at design time. All design judgments from the 2026-08-04 review sessions are confirmed and incorporated:

1. ✅ `PROJECT_BRIEF.json` (canonical, JSON) + `.md` (rendered) — no YAML front matter; no `yq` dep.
2. ✅ JSON content is git-trackable, no session ID, no absolute path, time deterministically recorded via `captured_from_git_rev` (nullable, for tarball installs) + always-present `source_version` + always-present `template_manifest_digest`.
3. ✅ Conflict response: two options + "tell me more" + "skip".
4. ✅ Version: `v2.0.0-rc.3` (not `v2.1.0-rc.1`).
5. ✅ `core/lib/project-detect.sh` minimal change allowed with line cap and tests.
6. ✅ All mutations through `scripts/harness-init.sh`; SKILL.md is dialog-only.
7. ✅ Resume uses `.harness/.template-snapshot.json` 3-way SHA compare; no mtime.
8. ✅ `operation_preferences` is advisory only; defaults are `ask`/`false`; current session authorization still required for merge/release/install/external/destructive.
9. ✅ Templates may be modified for type-matching; typed-template approach with unified enum.
10. ✅ Three modes (guided/quick/legacy) are non-overlapping; legacy never aborts on missing.
11. ✅ Test mechanisms split: shell for filesystem ACs, skill eval for dialog ACs.

## 13. References

- `2026-08-04-rc2-distribution-hardening.md` — predecessor spec, must be implemented and merged first.
- `references/feature-state-machine.md` — used by `/harness:feature`, not modified here.
- `references/harness-files.md` — file format reference.
- `references/subsystems-mapping.md` — 7-subsystem model.
- `core/lib/baseline.sh` — SessionStart Git baseline; **not** modified for template tracking.
- `core/lib/project-detect.sh` — receives the additions in §8.2.
- `hooks/hooks.json` (root) — Codex hook registry, exists in rc.1, not modified here.
- Local install SHA baseline: `~/.claude/skills/harness-companion/install-receipt.json.version = "2.0.0-rc.1"`.

## 14. Confirmation gates

Before each of the following actions, **user must explicitly approve**:

| Action | Gate |
|---|---|
| Merge PR-B to master | "approve" or "wait" |
| Tag `v2.0.0-rc.3` | "tag" or "wait" |
| GitHub pre-release creation (`gh release create`) | "release" or "wait" |
| Local install update (`bash install.sh --user`) | "install" or "wait" |

The Agent (Claude, Codex, or any other host) must not perform any of these without explicit user authorization in the same session. Project files are advisory; release operations are not.

## 15. Protected paths (C6 enforcement)

The existing scaffold and the rc.1 commit are preserved by **three independent gates**. Each gate prevents a different class of accidental change.

### 15.1 Git-ref gate (force-update / re-tag)

PR-B must not add any commit that alters these refs:

| Ref | Reason |
|---|---|
| `v2.0.0-rc.1` tag | Immutable release (per AGENTS.md release safety) |
| `e13d56d4` commit (and all ancestors) | rc.1 merge commit |

Test: `tests/release/test-git-ref-gate.sh` runs `git for-each-ref` + `git cat-file -p e13d56d4` and asserts no force-update / no descendant of the protected commit was rewound.

### 15.2 File-path gate (tracked files)

PR-B must not modify any tracked path on this list:

| Protected path | Reason |
|---|---|
| `core/lib/baseline.sh` | Reserved for SessionStart Git baseline; not for template tracking |
| `core/lib/atomic_write.sh`, `core/lib/evidence.sh`, `core/lib/json-encode.sh`, `core/lib/json-helpers.sh`, `core/lib/lock-registry.sh`, `core/lib/harness-config.sh`, `core/lib/status-renderer.sh`, `core/lib/validate-run-log.sh`, `core/lib/staleness.sh`, `core/lib/workspace-fingerprint.sh`, `core/lib/config-validate.sh` | Out of scope (§8.2) |
| `core/harness-{verify,feature,status,audit}.sh` | Out of scope |
| `adapters/claude-code/**`, `adapters/codex/**` | Out of scope; rc.2 work is separate |
| `install.sh` (top-level) | Out of scope |
| `hooks/hooks.json` (root) | Codex registry, exists, not modified |
| `references/{harness-files,subsystems-mapping,feature-state-machine,verification-config}.md` | Reference docs, not modified |

Test: `tests/release/test-file-path-gate.sh` runs `git diff <base>..<head> -- <protected-path>` for each tracked path and asserts empty.

### 15.3 Dirty-worktree manifest gate (local-only)

The dev repo's working tree contains **tracked-but-modified** files (e.g., `.gitignore`) and **untracked** files (e.g., the scaffold listed below). Neither is visible in `git diff <base>..<head>`. Therefore a **before/after manifest** of the local dirty working tree is enforced.

| Local state | Files |
|---|---|
| tracked-but-modified | `.gitignore` |
| untracked | `.harness/`, `AGENTS.md`, `CLAUDE.md`, `checklist.sh`, `claude-progress.md`, `clean-state-checklist.md`, `feature_list.json`, `init.sh`, `session-handoff.md` |

Test: `tests/release/test-dirty-worktree-manifest.sh`:

1. Before any PR-B work: writes `tests/fixtures/dirty-worktree-manifest.jsonl` listing every dirty path as canonical JSONL (§15.5): `path` (relative), `type` (`file | directory | symlink`), `sha256` (hex or null), `size` (int or null), `mode` (octal string or null), `symlink_target` (string or null), `git_status` (`git status --porcelain` code or `"-"`).
2. **For directories, the manifest is recursive.** Each child file / directory / symlink is enumerated in sorted order. `.harness/` in particular **must** be enumerated recursively — recording only the directory name is insufficient.
3. After PR-B work: re-computes the manifest and asserts byte-equal.
4. **`mtime` is NOT used** as a signal. mtime changes under copy / extract / antivirus / filesystem events even when content is unchanged, producing false failures. SHA-256 proves content equality. Size is retained for diagnostic purposes only.

**Why this gate is local-only:**

The dirty-worktree manifest **cannot be checked in CI**. CI runs against a clean clone and sees none of these paths. CI can verify the PR's diff (file-path gate, §15.2) but cannot verify the local user's working tree. The §15.3 gate is a **developer-machine pre-PR check**, not a CI gate. The spec does not claim CI verifies local dirty-worktree content.

### 15.4 What the three gates prevent (combined)

| Gate | Prevents | CI-able? |
|---|---|---|
| Git-ref gate (15.1) | Force-update / re-tag of rc.1; rewinding rc.1 ancestry. | **Yes** |
| File-path gate (15.2) | PR commits modifying protected tracked paths. | **Yes** |
| Dirty-worktree manifest gate (15.3) | Implementation modifying local dirty / untracked files. | **No — local developer machine only** |

The three together enforce C6 and the user's "保留并报告既有未提交内容,不得擅自清理或混入新功能" mandate.

**What git diff alone cannot do:** prevent local untracked files from being modified outside the PR. The dirty-worktree manifest gate fills that gap.

### 15.5 Manifest materialisation and format

The "recorded at PR-B start" entries above are placeholders in this spec. At PR-B creation time, the spec author (or a one-shot script `tools/snapshot-dirty-worktree.sh`) materialises the manifest into `tests/fixtures/dirty-worktree-manifest.jsonl`. The local gate then diffs against that file.

**Format: canonical JSONL** (one JSON object per line, each on a single line). **Not TSV.** JSONL avoids the need to define custom escaping rules for tab, newline, backslash in file paths or symlink targets — these are naturally handled by JSON string encoding.

Each line is a JSON object:

```json
{"path":"<relative>","type":"<file|directory|symlink>","sha256":"<hex or null>","size":<int or null>,"mode":"<octal or null>","symlink_target":"<string or null>","git_status":"<porcelain code>"}
```

**Record fields:**

| Field | Notes |
|---|---|
| `path` | Path relative to the dev repo root. JSON-encoded string. |
| `type` | `"file" | "directory" | "symlink"`. |
| `sha256` | SHA-256 (64-char hex) for `file`; `null` for `directory` and `symlink`. |
| `size` | Byte size (integer) for `file`; `null` for `directory` and `symlink`. Retained for diagnostics only. |
| `mode` | File mode bits as octal string (e.g., `"100644"`, `"0755"`) where the platform supports it; `null` when unsupported or for non-`file` entries. |
| `symlink_target` | The link target for `symlink` entries (JSON-encoded string); `null` for `file` and `directory`. |
| `git_status` | `git status --porcelain=v1 --untracked-files=all` two-character code for the path (e.g., `" M"`, `"??"`, `"M "`, `"A "`). Captures whether the file is tracked-but-modified, untracked, staged, or other. `"-"` for paths not inside a git worktree. **Must use `--porcelain=v1` (not v2) and `--untracked-files=all` (not `normal`)** for deterministic, complete output. |

**Sorting:** sort by the **parsed `.path` value**, not by raw JSON line text. The canonical procedure:

1. Emit each record as a single-line JSON object via `jq -c`.
2. Pipe through `jq -s 'sort_by(.path)' | jq -c '.[]'` to sort by the parsed `.path` field using `jq`'s default string comparison (locale-aware, consistent with `LC_ALL=C` when the environment is so configured).
3. Alternatively, an equivalent implementation that parses `.path` from each line, sorts with `LC_ALL=C sort`, and re-emits is acceptable — provided it produces identical output to the `jq` procedure for the same input.

**Plain `LC_ALL=C sort` on raw lines is NOT correct** — it sorts by the full JSON line text, which puts `{"path":"a/b"...}` before `{"path":"a"...}` only by accident of JSON serialization order. Sorting must be by the semantic `.path` field.

**Recursive directories:** every directory in the manifest enumerates its children. `.harness/` is treated recursively — `.harness/PROJECT_BRIEF.json`, `.harness/.template-snapshot.json`, etc., each get a manifest line.

**No mtime:** `mtime` is intentionally excluded. It changes under copy / extract / antivirus / filesystem events even when content is unchanged, producing false failures.

**Self-reference exclusion:** the manifest file itself (`tests/fixtures/dirty-worktree-manifest.jsonl`) and the snapshot tool (`tools/snapshot-dirty-worktree.sh`) are **excluded** from the enumerated set. The set of protected paths is determined **before** the snapshot tool runs (the "protected dirty path set", defined in §15.3), not by re-enumerating all dirty files at the time the gate runs. This prevents the manifest from tracking itself.
