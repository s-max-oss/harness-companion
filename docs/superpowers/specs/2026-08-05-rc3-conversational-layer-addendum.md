# rc.3 Conversational Layer Addendum — Guided Conversational Harness Construction

> **Status:** Part of the v2.0.0-rc.3 product contract (2026-08-08, revision 8).
> **Revision 8:** adds §5-b — self-host bootstrap contract & evidence rules implementing frozen §15.3 (immutable-vs-mutable file split, feature revision, NDJSON append-only, progress update, dirty-worktree manifest gate).
> **Target version:** v2.0.0-rc.3
> **Branch:** `rc3-guided-conversational-init` (created from clean `master` after rc.2 ships).
> **Version coverage:**
> - `v2.0.0-rc.2` — distribution hardening (shipped prerequisite; must merge to master, tag `v2.0.0-rc.2`, and create the GitHub pre-release first).
> - `v2.0.0-rc.3` — **this round.** The frozen onboarding executor spec (`2026-08-04-harness-init-guided-onboarding.md`) **and** this conversational layer addendum **jointly constitute rc.3's complete product contract**. This addendum adds the Agent dialog layer (SKILL.md conversational instructions, reference files, forward eval) on top of the rc.3 executor. It does not reimplement or replace the executor; it extends it with a conversational entry point.
> **Base spec:** `docs/superpowers/specs/2026-08-04-harness-init-guided-onboarding.md` — guided onboarding executor contract (frozen). This addendum defines the **Agent dialog layer** that drives it.
> **Future:** v2.1+ — autonomous supervised loop + independent Reviewer Agent (high-level preview only; deferred until v2.0.0 is stable).

---

## 0. Highest product principle

**The user calls harness-companion. The Agent initiates and sustains a guided conversation to understand the project, then a deterministic executor creates the Harness environment.**

"Guided conversation" means:

1. **The Agent drives.** The Agent proactively explains what it is deciding and why. The user is never left wondering "what should I say next?"
2. **Never re-ask.** Information already present in the conversation, the repository, or the current session is used directly.
3. **Natural, not mechanical.** The Agent asks questions that form a coherent dialog — not a checklist. Related information is grouped naturally. The conversation reads like a skilled human asking questions, not a form-filling script.
4. **Confirm the Brief, not the plan.** The user confirms or modifies the synthesized Brief before any file is written. The feature breakdown plan is the Agent's execution strategy — the user does not need to approve it.
5. **Explain after writing.** After init, the Agent walks through: what was generated, what was inferred from the repo, what defaults were applied, and what remains to be decided.
6. **Resume dialog only when needed.** After init, the Agent resumes conversation only for: new authorization, information conflict, scope change, a real blocker, or major phase completion.

The autonomous loop, Reviewer Agent, state machine, and evidence system (v2.1+) are supporting mechanisms — they do not replace the Agent-user dialog and are not the default interface.

---

## 0-b. Scope

### 0-b.1 In scope (rc.3)

- Agent dialog layer in SKILL.md: conversational information collection, conflict resolution, Brief confirmation, post-init explanation.
- Agent synthesis of user answers + conversation history + repository inference into a structured Brief.
- Confirmation gate: user approves or modifies the Brief → executor writes files. User rejects → zero writes.
- Post-init explanation: generated / inferred / defaulted / deferred.
- Executor `--brief` re-entry: Brief can be updated after init; executor applies 3-way SHA compare, only touches changed files.
- Legacy → guided transition: legacy mode fills defaults, then informs the user they can run `/harness:init` (guided) to refine the results conversationally.
- Cross-host compatibility: dialog instructions work for any host.
- Forward eval: 14 conversation-centric scenarios (§7).

### 0-b.2 Out of scope (rc.3)

- Autonomous supervised loop. Deferred (v2.1+, after v2.0.0 is stable).
- Independent Reviewer Agent as a runtime gate. Deferred (v2.1+, after v2.0.0 is stable).
- State machine engine, budget enforcement, resume/recovery from loop interruption. All deferred.
- Any change to `distribution/rc2-hardening`.
- Changes to `~/.claude/`, `~/.codex/`, local installed skill.
- New external runtime dependencies.
- Redesigning `feature_list.json` schema v2.
- Changes to `install.sh`, `uninstall.sh`.
- v2.1 feature scope. Deferred until v2.0.0 is stable; not pre-seeded in the current plan.

### 0-b.3 Hard constraints

| # | Constraint |
|---|-----------|
| C1 | **Repository isolation.** Only the current repo. |
| C2 | **Local install paths are protected.** Zero writes to `~/.claude/skills/harness-companion/`, `~/.agents/`, `~/.claude/settings.json`, `~/.agents/settings.*`. |
| C3 | **Pre-confirm = 0 writes — scoped to guided mode.** In guided mode, no file in the target project is written before the user confirms the Brief; Brief state lives only in conversation context. **Quick mode** has no confirmation gate — the Brief is auto-synthesized and executor runs immediately with a post-hoc warning. **Legacy mode** writes with placeholder-filled Brief, never aborting on missing fields. **Resume/update** require confirmation before touching template files but operate on already-initialized projects. The zero-write-before-confirmation rule applies ONLY to guided mode on a fresh project. |
| C4 | **On the resolved `--brief` path, Bash is a deterministic executor.** When Bash receives a complete, validated Brief via `--brief <json-path>` or `--brief-stdin`, it writes files deterministically — no inference, no questions, no `read -p`. SKILL.md contains dialog instructions only. The user is never asked to manually fill a JSON schema or edit a config file. **Legacy mode** (no `--brief` flag, Bash v1 caller) may fill placeholders for missing fields as a backward-compatibility measure — but this is the only inference Bash performs, and it is scoped to the legacy entry point. |
| C5 | **Agent drives; user confirms the Brief.** The Agent proactively explains decisions and asks questions conversationally. The user confirms or modifies the Brief. The feature plan is the Agent's execution strategy — not a user confirmation gate. |
| C6 | **Fail-closed.** Unresolvable conflicts, missing required fields in quick mode, corrupted state → abort with diagnostic, zero writes. |
| C7 | **Pre-release gates are independent authorization.** No `push`, `merge`, `tag`, `release`, `install` without explicit in-session user confirmation. |
| C8 | **Core is host-agnostic.** `core/` has no adapter-specific code. |
| C9 | **One evidence architecture.** rc.2 NDJSON run log (`core/lib/evidence.sh`) is the single evidence sink. |
| C10 | **SKILL.md is lean.** It describes the workflow and the Agent's role — not a checklist of questioning rules. Reference files provide detail; SKILL.md points to them. **Reference files (`conversational-principles.md`, `post-init-explanation.md`) are loaded by the Agent on `/harness:init` trigger — not pre-loaded at session start.** This keeps session-start lightweight and scopes reference context exclusively to init sessions. |

---

## 1. Conversational principles

### 1.1 The Agent's role

When the user invokes `/harness:init` (guided mode), the Agent:

1. **Acknowledges what it already knows.** Before asking anything, the Agent states what it has inferred from the repo and conversation history.
2. **Explains decisions, not just questions.** "I'm going to set up the Harness environment for this project. First, I need to understand what we're building — what's the goal?"
3. **Groups related topics naturally.** If the user gives a vague goal, the Agent follows up on that topic until it's clear — rather than switching to an unrelated question.
4. **Presents the Brief with source annotations.** Each value tagged `[from you]`, `[inferred from <file>]`, `[default]`, or `[to decide]`.

### 1.2 Information sources (priority order)

| Priority | Source | Example |
|----------|--------|---------|
| 1 | **Current user message** | "I want to add authentication to my Flask app" → goal, stack |
| 2 | **Conversation history** | Earlier in session: "we use pytest" → test_framework |
| 3 | **Repository inference** | `package.json` → Node; `pyproject.toml` → Python |

Only when a required field has `source = missing` across all three sources does the Agent ask.

### 1.3 Conversation style

The Agent conducts a natural dialog — not a questionnaire. This means:

- **Related questions together.** "I need to understand your workflow preferences — how should I handle commits, pushes, and merges?" is better than three separate rounds.
- **Follow the user's lead.** If the user volunteers information about one category, explore it fully before moving on.
- **Adapt to the user.** A user who gives detailed answers gets fewer, more targeted questions. A user who says "I don't know, just set it up" gets an explanation of sensible defaults and one confirmation.
- **Explicitly replaces frozen AC-1.** The frozen onboarding spec (`2026-08-04-harness-init-guided-onboarding.md`) AC-1 states "≤ 3 questions per round." This rc.3 addendum **supersedes** that numeric cap. The Agent uses conversational judgment, not a question counter. Related questions are grouped naturally. The acceptance criterion for dialog behavior is now: the Agent conducts focused, relevant rounds of conversation without a rigid numeric limit — verified by forward eval scenarios FE-01 through FE-14.

### 1.4 Conflict resolution

When repo evidence and user input contradict, the Agent asks exactly one precise question:

```
[Field] conflict:
  - The repo has: package.json (Node project)
  - You said: "Python backend"
Which is correct?
  1. This is a Node project — I misspoke
  2. It has both — the backend is Python
  3. Tell me more about the project structure
  4. Skip this for now
```

The Agent does not silently pick a side.

### 1.5 Users unfamiliar with Harness

When the user does not understand Harness concepts, the Agent explains them in plain language. Jargon is translated; concepts are introduced before questions about them. The Agent never assumes prior knowledge of `cadence`, `operation_preferences`, or `secrets_handling`.

---

## 2. Dialog workflow

### 2.1 guided mode

```
1. Trigger     /harness:init  (no flags)
2. Recon       Agent reads cwd: git status, file listing, presence of
                 .harness/config.json, package.json/pyproject.toml/Cargo.toml/
                 go.mod/Makefile, git log -10. Reads conversation history.
3. Acknowledge Agent states what it already knows.
4. Collect     Agent conducts a natural conversation to fill required fields
                 and resolve conflicts. Related questions grouped; flow adapts
                 to user's responses. Explains concepts when needed.
5. Compose     Agent renders the Brief with source annotations.
6. Confirm     User chooses: approve / edit / cancel.
                 - approve → step 7
                 - edit    → Agent revises; confirmed fields preserved; back to step 5
                 - cancel  → abort, no files written
7. Execute     Agent calls: bash scripts/harness-init.sh --brief <tmp.json>
                 Executor writes files atomically. Agent does NOT write files directly.
8. Explain     Agent walks through: generated, inferred, defaulted, deferred.
```

### 2.2 quick mode

```
1. Trigger     /harness:init --quick
2. Recon       Same as 2.1.2
3. Brief       Compose Brief from env vars + repo detection + defaults.
               If required field missing → abort with diagnostic, exit 2.
4. Execute     bash scripts/harness-init.sh --brief <tmp.json> --non-interactive
5. Warning     "warning: --quick mode ran without confirmation;
                review PROJECT_BRIEF.json for accuracy"
```

### 2.3 legacy mode (Bash v1 caller)

```
1. Trigger     bash scripts/harness-init.sh <dir> [--full] [--host=claude|codex]
2. Recon       Same as 2.1.2
3. Brief       Compose Brief from args + env + repo detection + placeholder fill.
               NEVER abort on missing fields.
4. Execute     Write files.
5. Warning     "warning: legacy mode ran; PROJECT_BRIEF.json contains placeholder
                fields. Run /harness:init (without --quick) to refine these
                interactively."
```

After legacy mode completes, the user can invoke `/harness:init` (guided mode). The executor detects the existing `.template-snapshot.json` and enters the resume path — the Agent reloads the existing Brief and offers to refine it conversationally. The user's manually edited files are protected by 3-way SHA compare.

### 2.4 resume / update

Per onboarding spec §4.4/§4.5. Non-interactive 3-way SHA compare.

### 2.5 Executor `--brief` re-entry

The executor's `--brief` flag is idempotent for re-entry. On an already-initialized project:

1. Executor detects `.template-snapshot.json` exists → enters resume path.
2. New Brief fields are merged with existing Brief (user-confirmed values preserved unless explicitly changed).
3. Template files are updated via 3-way SHA compare — user-modified files are never overwritten.
4. `PROJECT_BRIEF.json` is rewritten; `PROJECT_BRIEF.md` is regenerated.

This enables: legacy mode fill → user runs guided mode to refine → executor re-enters with updated Brief → only changed values touch the filesystem.

---

## 3. Confirmation and explanation

### 3.1 Brief confirmation gate

Before ANY file is written:

1. Agent presents the synthesized Brief with source annotations.
2. User chooses: approve / edit / cancel.
3. If the user edits, only changed fields are re-discussed. Confirmed fields are preserved.
4. The feature breakdown plan is NOT presented for confirmation — it is the Agent's execution strategy.

### 3.2 Post-init explanation

After files are written, the Agent explains in four categories:

| Category | Example |
|----------|---------|
| **Generated** | "Created 9 files: PROJECT_BRIEF.json, feature_list.json, AGENTS.md, ..." |
| **Inferred** | "Detected Python stack from pyproject.toml; pytest from pytest.ini" |
| **Defaulted** | "Used defaults: cadence=stable, secrets_handling=unspecified" |
| **Deferred** | "Not yet decided: deadline. You can edit PROJECT_BRIEF.json or re-run /harness:init to refine" |

The explanation is conversational — not a JSON dump. The Agent highlights anything the user might want to change.

### 3.3 User modifies the Brief after init

"Actually, change the test framework to vitest."

1. Agent updates the Brief in conversation context.
2. Agent re-runs executor with updated Brief (resume path).
3. Executor applies 3-way SHA compare — only changed template files touched.
4. Agent confirms what changed.

---

## 4. Executor contract

### 4.1 What Bash does

- Receives a resolved Brief as `--brief <json-path>` or `--brief-stdin`.
- Validates schema.
- Writes files per output manifest.
- Writes `.template-snapshot.json`.
- Returns exit code 0 on success, non-zero with structured error on failure.
- Supports re-entry on already-initialized projects (resume path, 3-way SHA compare).

### 4.2 What Bash does NOT do

- Ask questions (`read -p`, `read -r`, stdin prompt).
- Make decisions about what to ask.
- Guess or infer missing fields (Agent's job).
- Produce human-readable explanations (Agent's job).

### 4.3 Error routing

Executor errors are structured: `error: <field>: <reason>`. The Agent translates them into conversational language — never passes raw errors unfiltered.

---

## 5. Evidence architecture (inherited from rc.2)

NDJSON run log at `.harness/logs/runs/<run_id>.ndjson`. Init writes `run_started`, `run_completed`, `run_failed` events. `PROJECT_BRIEF.json` is canonical for project configuration. `core/harness-status.sh` cross-validates. Run logs are generated by `core/harness-verify.sh` / the executor — never hand-crafted.

---

## 5-b. Self-host bootstrap contract & evidence rules (frozen §15.3)

This addendum's own development is carried out **on** the self-host bootstrap
(`.harness/`, `feature_list.json`, knowledge entries, init environment — written
by hand at the rc.2 baseline, honest about `generated_by`/`source_version`). The
rules below govern those files and the evidence they produce. They implement
frozen §15.3 of the onboarding executor spec and the rc.2 evidence invariants.

### 5-b.1 Immutable contract vs mutable runtime files

| Class | Files | Rule |
|-------|-------|------|
| **Immutable contract** | `.harness/PROJECT_BRIEF.json`, `.harness/PROJECT_BRIEF.md`, `.harness/.template-snapshot.json`, `.harness/config.json`, `AGENTS.md`, `CLAUDE.md`, `init.sh` | Fixed by the bootstrap. Changed only via a deliberate contract update (executor `--update` 3-way SHA compare, or explicit user approval). Not changed mid-phase. These files are the contract the harness operates under. |
| **Mutable runtime** | `feature_list.json`, `.harness/logs/runs/*.ndjson`, verification run artifacts, `.harness/.registry.lock/`, `.harness/reviews/` (reviewer verdict artifacts), `claude-progress.md`, `session-handoff.md`, `clean-state-checklist.md`, `checklist.sh` | Normal state changes during development. Each class has a dedicated mutation rule below. |

### 5-b.2 Feature revision rules

- Every mutation to `feature_list.json` serializes through `core/lib/lock-registry.sh` and bumps `revision` by **exactly +1**. A failed mutation leaves `revision` unchanged.
- **WIP = 1:** exactly one feature may be `in_progress` at a time. A second `in_progress` transition is rejected (exit 4), revision unchanged.
- Status transitions run through `core/harness-feature.sh`'s explicit state machine. A transition to `passing` requires non-empty `evidence_associations` (the associated run's NDJSON), else it is rejected (exit 5), revision unchanged.

### 5-b.3 NDJSON append-only

- The NDJSON run log is the single evidence sink. **Each verification run produces a NEW run** under `.harness/logs/runs/<new_run_id>.ndjson`. Never rewrite, truncate, or append to an existing run log.
- NDJSON is generated exclusively by `core/harness-verify.sh` (or the executor). Hand-crafting NDJSON is prohibited.
- When the self-host contract files change, the existing run log's workspace fingerprint goes stale (Axis 1); the run log must be regenerated with a new run via `harness-verify.sh` so init evidence matches the final tree.

### 5-b.4 Progress update rules

- `claude-progress.md` is updated only at **session handoff** and at **feature close** (a feature transitions to `passing`, or a phase completes) — not mid-phase.
- One session block per session; the "Current Verified State" header reflects the highest-priority unfinished feature. Progress file updates never happen between two verification runs of the same feature.

### 5-b.5 §15.3 dirty-worktree manifest gate (local-only, before/after, immutable/mutable-classified)

The dev repo's working tree is **dirty** (tracked-but-modified `.gitignore`; untracked `.harness/`, `AGENTS.md`, `CLAUDE.md`, `checklist.sh`, `claude-progress.md`, `clean-state-checklist.md`, `feature_list.json`, `init.sh`, `session-handoff.md`). None of these appear in `git diff <base>..<head>`, so a before/after manifest of the local dirty working tree is enforced:

1. **Before** PR-B work: write `tests/fixtures/dirty-worktree-manifest.jsonl` listing **every dirty path** as canonical JSONL (§15.5): `path` (relative), `type` (`file | directory | symlink`), `sha256` (hex or null), `size` (int or null), `mode` (octal string or null), `symlink_target` (string or null), `git_status` (`git status --porcelain` code or `"-"`).
2. **For directories, the manifest is recursive.** Each child file / directory / symlink is enumerated in sorted order. `.harness/` in particular **must** be enumerated recursively — recording only the directory name is insufficient.
3. **Classify** every dirty path by the §5-b.1 split: **immutable contract** (`.harness/PROJECT_BRIEF.json`, `.harness/PROJECT_BRIEF.md`, `.harness/.template-snapshot.json`, `.harness/config.json`, `AGENTS.md`, `CLAUDE.md`, `init.sh`) vs **mutable runtime** (everything else on the dirty list). A non-Harness user dirty file (a dirty path that is neither immutable contract nor mutable runtime) is treated like the immutable class for equality purposes — it is not a harness file the gate may rewrite, so it must also stay byte-equal.
4. **Path-set stability (with a controlled mutable-namespace new-path allowance):** deletions and type-changes always fail — every recorded `(path, type)` entry must still exist with the same `type` (append-only, no shape drift). **New** dirty paths are allowed ONLY inside the mutable runtime namespace — a NEW verification run log (`§5-b.3`), a NEW reviewer verdict artifact (`§5-b.6`, both feature and phase files), a feature-registry mutation (`§5-b.2`), or a progress-file update (`§5-b.4`) never fails the gate. A new dirty path OUTSIDE the mutable runtime namespace (e.g., a new untracked user file, or a new file directly under `.harness/`) **fails** the gate (`new_non_mutable`).
5. **Immutable contract paths must be byte-equal** (sha256 identical before/after). Any immutable change fails the gate. An immutable change is permitted ONLY as a deliberate contract update (§5-b.1): re-capture the snapshot, update the affected snapshot SHA entries, recompute the Brief manifest digest, and regenerate the run log — all BEFORE the change is treated as legitimate. Non-Harness user dirty files are byte-equal the same way: any content change to them fails the gate.
6. **Mutable runtime paths are NOT required to be byte-equal.** Content changes are expected and allowed, and must be attributable to a documented mutation class: feature revision bump (§5-b.2), a NEW append-only run log (`§5-b.3`), progress append at session handoff / feature close (§5-b.4), or a new verdict record (§5-b.6). Byte-equal is asserted ONLY on the immutable class and non-Harness user dirty files.
7. **`mtime` is NOT used** as a signal (mtime changes under copy/extract/antivirus/filesystem events even when content is unchanged). SHA-256 proves immutable equality; size is diagnostic only.

Tests: `tests/release/test-dirty-worktree-manifest.sh` (canonical §15.3 manifest mechanics, byte-equal on immutable + user files, and the mutable-namespace new-run / new-verdict / illegal-mutable allowance) and `tests/bootstrap/test-bootstrap-gates.sh` (behavior: mutable normal change passes, immutable change fails, forged master-clean env var cannot bypass the readiness gate). This gate is **local-only** — a developer-machine pre-PR check, **not** CI. CI runs against a clean clone and sees none of these paths; CI verifies the PR diff (file-path gate §15.2) while §15.3 verifies the local dirty working tree.

### 5-b.6 Reviewer verdict artifacts (append-only)

Independent Reviewer verdicts are persisted as append-only evidence. The full contract (paths, JSON schema, base/head SHA, run_id, attempt, append-only rule) is defined in `.harness/PLAN.json` → `reviewer_contract.verdict_artifact`; this section records the file-level invariants:

- **Feature verdicts** and **phase verdicts are saved separately**:
  - feature: `.harness/reviews/feature/<feature_id>.jsonl`
  - phase: `.harness/reviews/phase/<phase>.jsonl`
- **Append-only:** each review appends one new record with `attempt = previous attempt + 1` for the same feature/phase. Existing records are never rewritten, truncated, or deleted.
- **Preservation:** a phase cumulative review never overwrites the per-feature verdict records — both are kept side by side (per-feature records are the ORIGINAL verdict evidence).
- Verdict artifacts are **mutable runtime** files (§5-b.1): the gate allows new/updated verdict records without failing (they are the documented §5-b.6 mutation class).
- Verdict artifacts are **excluded from the workspace fingerprint** (`core/lib/workspace-fingerprint.sh` `BUILTIN_EXCLUDES` → `.harness/reviews/`): a new verdict record must not invalidate Axis1 staleness of any verification run. Verdicts are reviewer runtime state written outside the verification lifecycle, not verification scope.

---

## 6. Mode matrix

| Mode | Entry | Dialog | Confirm gate | Re-entry |
|------|-------|--------|-------------|----------|
| **guided** | `/harness:init` | Yes — Agent drives conversation | Brief only | `--brief` on initialized project → resume path |
| **quick** | `/harness:init --quick` | None | None (warns) | Refuses on initialized project; tells user to use `--update` |
| **legacy** | `bash scripts/harness-init.sh <dir>` | None | None (warns) | User can then run guided mode to refine conversationally |
| **resume** | Detected via `.template-snapshot.json` | None | Required before touching files | — |
| **update** | `--update` | None | Required before overwriting | — |

Legacy → guided transition: legacy fills defaults and writes files. The user is told they can run `/harness:init` (guided) to refine. The Agent loads the existing Brief, presents it with annotations showing what was defaulted vs. inferred, and offers to improve it conversationally.

---

## 7. Forward eval matrix (14 conversation-centric scenarios)

### 7.1 Vague and partial information (4 scenarios)

| # | Scenario | Success criterion |
|---|---------|-------------------|
| FE-01 | **Vague goal.** User says "I need to build something" with no details. | Agent asks focused follow-ups to clarify the goal. Does not ask about stack (inferrable) or cadence (premature). Conversation stays on topic until goal is clear. |
| FE-02 | **Partial information.** User says "Python project, add auth, due Friday." | Agent acknowledges known info. Only asks about what's still needed. Does not re-ask stack or goal. |
| FE-03 | **Everything inferrable.** Repo has `package.json` + `jest.config.js` + `AGENTS.md`. User says "keep going." | Agent infers Node, Jest, existing harness. Asks only: goal, success_criteria (both required, both missing). Applies defaults for remaining fields. |
| FE-04 | **Only defaults needed.** User gives goal + success criteria. Everything else missing. | Agent applies all defaults, presents complete annotated Brief, confirms. Does not optimize optional fields the user didn't ask about. |

### 7.2 Information conflict (2 scenarios)

| # | Scenario | Success criterion |
|---|---------|-------------------|
| FE-05 | **Repo contradicts user.** User says "Python project" but repo has `Cargo.toml` and `src/main.rs`. | Agent presents the conflict with both options. Does not silently pick either. Resolution recorded in `conflicts_resolved`. |
| FE-06 | **Multiple conflicts.** User says "Node" but repo is Python; user says "no tests" but `pytest.ini` exists. | Agent addresses conflicts one at a time. Each gets one precise question. Conflicts not batched with missing-field questions. |

### 7.3 Users unfamiliar with Harness (1 scenario)

| # | Scenario | Success criterion |
|---|---------|-------------------|
| FE-07 | **User doesn't understand Harness.** User says "I don't know what any of this means, just set it up" and later asks "wait, what's a cadence?" | Agent explains concepts in plain language as they come up. Adapts explanations to the user's level of understanding. Offers sensible defaults and confirms them. User feels guided, not interrogated or overwhelmed. |

### 7.4 Confirmation and modification (3 scenarios)

| # | Scenario | Success criterion |
|---|---------|-------------------|
| FE-08 | **User rejects Brief.** User says "no, that's wrong — the goal is different." | Agent revises only changed field. Confirmed fields preserved. No files written. |
| FE-09 | **User modifies after init.** "Change test framework to vitest." | Agent re-runs executor. 3-way compare protects user files. Agent confirms what changed. |
| FE-10 | **Post-init explanation.** Init completes. | Agent explains generated/inferred/defaulted/deferred conversationally. User understands without reading JSON. |

### 7.5 Authorization and boundaries (2 scenarios)

| # | Scenario | Success criterion |
|---|---------|-------------------|
| FE-11 | **User denies external_network.** Brief sets `external_network: "ask"`. User later says "call the production API." | Agent stops and asks. Denial recorded in evidence. |
| FE-12 | **Brief says push=auto but user says stop.** Brief has `push: "auto"`. In session, user says "don't push yet." | Session instruction wins (Brief is advisory per C9 of onboarding spec). Agent does not push. Does not argue. |

### 7.6 No context leakage (2 scenarios)

| # | Scenario | Success criterion |
|---|---------|-------------------|
| FE-13 | **Forward test Agent sees only SKILL.md + task prompt.** No spec internals, no expected outcomes. | Agent's conversation follows the principles naturally. Questions are relevant, non-redundant. Agent explains decisions. |
| FE-14 | **Clean archive → Agent guides a mock user through init.** Mock user gives vague answers, conflicts, "I don't know" responses, then changes mind after init. | Agent handles all gracefully. Brief confirmed. Post-init modification works. No re-asking. No silent picks. |

---

## 7-b. Forward eval infrastructure

### 7-b.1 Eval case format

Each scenario in §7 has a corresponding versioned eval case at `tests/eval/cases/<name>.json`:

```json
{
  "name": "vague-goal",
  "version": "1",
  "scenario_ref": "FE-01",
  "fixture": "fixtures/empty-repo",
  "mock_user_inputs": [
    "I need to build something",
    "A web app for managing my team's tasks",
    "Python backend, React frontend",
    "Yeah that sounds good, go ahead"
  ],
  "expected_dialog_signals": {
    "did_not_ask": ["stack"],
    "asked_at_most_per_round": null,
    "covered_categories": ["goal", "stack", "success_criteria"],
    "conflict_resolution_format": "two options + tell me more + skip",
    "never_re_asked": ["stack"],
    "explanation_complete": true
  },
  "expected_post_init_files": [
    ".harness/PROJECT_BRIEF.json",
    ".harness/PROJECT_BRIEF.md",
    ".harness/.template-snapshot.json",
    "AGENTS.md",
    "feature_list.json"
  ],
  "expected_brief_fields": {
    "advisory": true
  },
  "reviewer_rubric": {
    "checks": [
      "Agent did not ask about stack (inferrable from repo)",
      "Agent followed up on vague goal until clear",
      "Agent did not switch topics prematurely",
      "Agent explained decisions before asking for confirmation",
      "Post-init explanation covered generated/inferred/defaulted/deferred"
    ],
    "pass_criteria": "all checks pass; zero re-asks; explanation covers all four categories",
    "fail_criteria": "any re-ask; topic switch before goal clear; silent pick of field; explanation missing a category",
    "minimum_bar": "5/5 checks pass"
  }
}
```

### 7-b.2 Eval runner

`tests/eval/run-eval.sh <case.json>`:

1. Sets up `fixture` in a `mktemp -d`.
2. Invokes a **real Agent** (Claude Code / Codex) with the case as input. The Agent receives only SKILL.md + the case prompt — no spec internals, no expected outcomes.
3. Captures:
   - **Full conversation transcript** (Agent-user dialog, all turns).
   - **Post-init file tree** (SHA-256 manifest of target directory).
   - **PROJECT_BRIEF.json** (for field assertions).
4. Asserts each invariant in `expected_dialog_signals` and `expected_brief_fields`.
5. Scores against `reviewer_rubric`.
6. Writes result to `tests/eval/results/<case-name>.<version>.<timestamp>.json`.

### 7-b.3 Results format

```json
{
  "case": "vague-goal",
  "case_version": "1",
  "spec_version": "2.0.0-rc.3",
  "timestamp": "2026-08-08T15:30:00Z",
  "passed": true,
  "rubric_score": "5/5",
  "rubric_details": {
    "checks": [
      {"check": "Agent did not ask about stack", "pass": true},
      {"check": "Agent followed up on vague goal until clear", "pass": true}
    ]
  },
  "transcript_sha256": "abc123...",
  "post_init_tree_sha256": "def456...",
  "reviewer_verdict": "CONFIRMED",
  "notes": ""
}
```

### 7-b.4 Release-blocking rule

A **failed or unrun eval case blocks the release gate.** Before `v2.0.0-rc.3` can be tagged, every case in `tests/eval/cases/` must have a corresponding result file in `tests/eval/results/` with `passed: true` and `reviewer_verdict: "CONFIRMED"`. CI verifies case files parse; the actual Agent run may be manual / host-level if no CI-integrated eval harness is wired. A green CI without eval results is acceptable ONLY if the release gate (§14 of the frozen onboarding spec) requires the result JSON to be present.

### 7-b.5 Reviewer rubric per scenario category

Each scenario category has a Reviewer rubric defining what an independent Reviewer checks. (Dev-phase review mechanics are defined in `.harness/PLAN.json`; a runtime Reviewer Agent is a future concern — see §8.2.)

| Category | Reviewer checks | Minimum bar |
|----------|----------------|-------------|
| **Vague/partial (FE-01–04)** | Did Agent re-ask known info? Did Agent stay on topic until clear? Were defaults applied correctly? Was explanation complete? | 5/5 checks; zero re-asks |
| **Conflict (FE-05–06)** | Did Agent silently pick a side? Was each conflict one precise question? Were conflicts not batched with missing-field questions? Was resolution recorded? | 4/4 checks; zero silent picks |
| **Unfamiliar user (FE-07)** | Did Agent use jargon without explanation? Were concepts introduced before questions? Did user feel guided? | 3/3 checks; zero unexplained jargon |
| **Confirmation (FE-08–10)** | Were confirmed fields preserved on edit? Did 3-way compare protect user files? Did explanation cover all four categories? | 3/3 checks; zero lost field edits |
| **Authorization (FE-11–12)** | Did Agent stop on denial? Was denial recorded? Did session instruction win over Brief advisory? | 3/3 checks; zero unauthorized actions |
| **Context leakage (FE-13–14)** | Did Agent follow principles from SKILL.md alone? Were questions relevant and non-redundant? Did Agent handle mock user gracefully? | 3/3 checks; zero spec-internals leakage |

---

## 8. Feature assignment

### 8.1 rc.3 — Guided conversational init (one closed loop)

| ID | Feature | Phase |
|----|---------|-------|
| F-CONV-01 | SKILL.md — conversational `/harness:init` dialog instructions | 2 |
| F-CONV-02 | `references/conversational-principles.md` — dialog reference | 2 |
| F-CONV-03 | `references/post-init-explanation.md` — explanation template | 2 |
| F-CONV-04 | `core/lib/project-detect.sh` — extended type detection | 1 |
| F-CONV-05 | `templates/` — restructure `common/` + `by-type/` | 1 |
| F-CONV-06 | `scripts/harness-init.sh` — `--brief`, `--non-interactive`, `--update`, `--apply`, `--render-brief`, re-entry support | 1 |
| F-CONV-07 | Shell tests: executor determinism, type-matching, zero writes, resume safety, cross-host | 3 |
| F-CONV-08 | Forward eval — 14 conversation scenarios via real Agent, versioned cases, runner, transcript capture, Reviewer rubric, release-blocking results | 4 |
| F-CONV-09 | G0-style acceptance package + live conversation session evidence | 5 |

All nine features are rc.3 deliverables and ship as one closed loop: executor, dialog layer, shell tests, forward eval, acceptance.

### 8.2 Future — deferred until v2.0.0 is stable (high-level only)

After v2.0.0 is stable, a future version will add the **autonomous supervised loop** on top of rc.3's validated conversational foundation. High-level goals:

- **State machine engine** with deterministic core validation, budget enforcement, and fail-closed resume/recovery.
- **Two-tier authorization model**: Tier 1 (core-enforced — state legality, WIP=1, evidence completeness, fingerprint match) with deterministic rejection; Tier 2 (agent-contractual — push, merge, tag, release, install, package installation, external network, destructive, credentials, external) requiring `auth_granted` NDJSON events.
- **Independent Reviewer Agent gate**: fresh read-only sub-agent per feature, receiving only spec + diff + SHA + test logs + raw artifacts — not the main Agent's conclusions.
- **Self-host development environment**: `.harness/dev/` isolated from release artifact, zero writes to install paths.

Full design, feature breakdown, and file locations deferred until v2.0.0 is stable. **No future-version features appear in the current plan.**

### 8.3 Phase order (rc.3)

```
Phase 1 (Foundation):   F-CONV-04 → F-CONV-05 → F-CONV-06
Phase 2 (Dialog):       F-CONV-01 → F-CONV-02 → F-CONV-03  (sequential; WIP=1)
Phase 3 (Shell tests):  Phase 1 → F-CONV-07
Phase 4 (Forward eval): Phase 1 + Phase 2 → F-CONV-08
Phase 5 (Acceptance):   Phase 1–4 → F-CONV-09
```

**Phase review rules** are defined in `.harness/PLAN.json` — not in this spec. The PLAN is the sole authority for dev-phase review mechanics (Reviewer contract, pass/fail/blocker rules, retry limits, force-stop conditions). This spec defines only the feature scope and dialog principles; the development execution protocol is a separate concern. **F-CONV-09 is the sole user phase-stop gate in rc.3**; Reviewer gates are internal progress gates.

---

## 9. Future: autonomous supervised loop (preview)

### 9.1 What a future version builds on

| rc.3 foundation | Future use |
|----------------|---------|
| `PROJECT_BRIEF.json` (confirmed conversationally) | Loop reads goal, constraints, authorization preferences |
| `feature_list.json` (v2 schema) | Loop reads/writes feature status; WIP=1 enforcement |
| NDJSON run log | Loop writes state transitions, verification results, auth grants |
| `core/lib/workspace-fingerprint.sh` | Loop captures/compares fingerprint |
| `core/lib/staleness.sh` | Loop checks 3-axis staleness |
| `core/harness-feature.sh` | Loop calls for WIP=1 |
| `core/harness-verify.sh` | Loop calls for verification |

### 9.2 Future scope (deferred)

- Autonomous supervised loop: implement → verify → (independent review) → close → next feature.
- Explicit state machine with deterministic core validation.
- Independent Reviewer Agent gate: fresh read-only sub-agent, no access to main Agent's conclusions.
- Two host-capability paths: with sub-agent (full review) and without (verified → closed, unavailability recorded honestly).
- Budget enforcement: retry caps, time budgets, transition limits.
- Resume/recovery from interruption, fail-closed.
- Self-host development environment: `.harness/dev/` isolated, zero writes to install paths.

### 9.3 Why it is separate

The autonomous loop requires a solid Brief. If the conversation that produced the Brief is weak, the loop builds on garbage. rc.3 validates the conversation experience first — 14 forward eval scenarios with a real Agent — before the loop is added. Merging them would dilute the conversation evidence and delay the init experience.

---

## 10. File locations

| File | Version | Purpose |
|------|---------|---------|
| `SKILL.md` | rc.3 | Agent dialog instructions for `/harness:init` |
| `references/conversational-principles.md` | rc.3 | Dialog reference (loaded on `/harness:init` trigger, not at session start) |
| `references/post-init-explanation.md` | rc.3 | Explanation template (loaded on `/harness:init` trigger, not at session start) |
| `core/lib/project-detect.sh` | rc.3 | Extended type detection |
| `templates/common/` | rc.3 | Shared templates |
| `templates/by-type/<type>/` | rc.3 | Per-type overrides |
| `scripts/harness-init.sh` | rc.3 | Executor with `--brief`, `--non-interactive`, `--update`, `--apply`, `--render-brief`, re-entry |
| `tests/init/` | rc.3 | Shell tests |
| `tests/eval/cases/` | rc.3 | Forward eval cases (14 scenarios) |
| `tests/eval/run-eval.sh` | rc.3 | Eval runner (invokes real Agent) |
| `tests/eval/results/` | rc.3 | Eval results (<case>.<version>.<timestamp>.json) |

Future-version file locations (loop engine, reviewer, state machine, self-host, loop references) are deferred to that future design — not listed here.

### 10.1 Files NOT modified

`core/lib/evidence.sh`, `core/lib/workspace-fingerprint.sh`, `core/lib/staleness.sh`, `core/lib/atomic_write.sh`, `core/harness-feature.sh`, `core/harness-verify.sh`, `core/harness-status.sh`, `core/harness-audit.sh`, `feature_list.json`, `install.sh`, `adapters/`.

---

## 11. Design invariants

1. **The Agent drives a natural conversation; the user confirms or modifies the Brief.** The user is never asked to fill a JSON schema.
2. **Pre-confirm = 0 writes is scoped to guided mode.** Quick mode auto-runs without confirmation. Legacy mode writes placeholders. Resume/update have independent confirmation rules.
3. **On the resolved `--brief` path, Bash is a deterministic executor.** Receives complete, validated Brief — never infers, never asks questions. Legacy mode placeholder fill is the only exception, scoped to the legacy entry point.
4. **Information known from conversation or repo is never re-asked.**
5. **Post-init, the user understands what happened without reading JSON.** Explanation covers generated/inferred/defaulted/deferred.
6. **The Brief is advisory — current-session user instructions always take precedence.**
7. **rc.2 evidence architecture is the single sink.** No second evidence system.
8. **SKILL.md is lean.** Describes workflow and role, not a checklist. Reference files load on `/harness:init` trigger, not at session start.
9. **This addendum explicitly replaces frozen AC-1's "≤3" numeric cap.** The Agent uses conversational judgment, not a question counter.
10. **Dev-phase execution rules (Reviewer contract, phase gates, force-stop, retry limits) are defined in `.harness/PLAN.json`** — not in this spec. This spec defines product behavior; PLAN.json defines development protocol. F-CONV-09 is the sole user phase-stop gate.
11. **rc.3 depends on the rc.2 → rc.3 ship order.** rc.2 (distribution hardening) must merge/tag/pre-release → rc.3 (this round: frozen executor + this addendum) can begin. v2.1+ is deferred until v2.0.0 is stable. Version coverage is declared in the header above.
12. **Authorization in rc.3 is advisory-Brief + session-confirmation.** The two-tier loop authorization model (Tier-1 core-enforced + Tier-2 agent-contractual with `auth_granted` NDJSON) is deferred to a future version.

---

End of rc.3 conversational layer addendum. Status: part of the v2.0.0-rc.3 product contract (2026-08-08, revision 8). Revision 8 adds §5-b (self-host bootstrap contract & evidence rules implementing frozen §15.3).
