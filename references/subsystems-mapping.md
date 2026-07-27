# Harness Subsystems Mapping

This document maps the 7 Harness Engineering subsystems to their files, course lessons, and automation targets.

---

## The 7 Subsystems

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Knowledge  │  │ Environment │  │  Progress   │  │Scope/Feature│
│  L02-L04    │  │  L05-L06    │  │  L05-L06    │  │  L07-L08    │
├─────────────┤  ├─────────────┤  ├─────────────┤  ├─────────────┤
│ AGENTS.md   │  │ init.sh     │  │ claude-     │  │ feature_    │
│ CLAUDE.md   │  │ package.json│  │ progress.md │  │ list.json   │
│ docs/       │  │             │  │ session-    │  │             │
│             │  │             │  │ handoff.md  │  │             │
└─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘

┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│ Verification│  │Observability│  │  Handoff    │
│  L09-L10    │  │  L11        │  │  L12-L13    │
├─────────────┤  ├─────────────┤  ├─────────────┤
│ checklist.sh│  │ agent.log   │  │ session-    │
│ npm test    │  │ logger.ts   │  │ handoff.md  │
│ npm run     │  │ benchmark.sh│  │ clean-state-│
│   build     │  │ evaluator-  │  │ checklist.md│
│ evidence in │  │ rubric.md   │  │ checklist.sh│
│ feature_list│  │             │  │ loop.sh     │
└─────────────┘  └─────────────┘  └─────────────┘
```

---

## Detailed Subsystem Breakdown

### 1. Knowledge Subsystem

**Course**: Lessons 02-04
**Core principle**: The repository is the single source of truth. Agent instructions are files, not conversation memory.

| File | Role | Lesson |
|------|------|--------|
| `AGENTS.md` | Full operating manual — startup rules, boundaries, conventions, definition of done | L03, L04 |
| `CLAUDE.md` | Claude Code quick reference — entry point that points to AGENTS.md | L04 |
| `docs/ARCHITECTURE.md` | System layer descriptions and data flow | L03 |
| `docs/PRODUCT.md` | Feature requirements and user-facing behavior | L03 |

**Key insight from L04**: AGENTS.md is the "operations manual." CLAUDE.md is the "cheat sheet." The entry file routes to specialized docs — it does NOT contain everything. A giant AGENTS.md is worse than no AGENTS.md because agents skip it.

**Automation targets**:
- Detect when AGENTS.md exceeds 500 lines → suggest splitting
- Verify CLAUDE.md points to AGENTS.md (not duplicates it)
- Check that `docs/` files are referenced from AGENTS.md

---

### 2. Environment Subsystem

**Course**: Lessons 05-06
**Core principle**: Agent must verify the environment builds before writing any code. Environment setup is a separate phase, not a warmup.

| File | Role | Lesson |
|------|------|--------|
| `init.sh` | One-command environment verification | L06 |
| `package.json` scripts | `check`, `build`, `dev`, `test` commands | L06 |

**Key insight from L06**: `bash init.sh` should ALWAYS be the first command in a session. If init.sh fails and the agent still writes code, the code is built on a broken foundation.

**Automation targets**:
- SessionStart hook: remind to run `bash init.sh` if not run yet
- Detect when `init.sh` is missing → suggest creating it
- Verify `init.sh` covers install + check + build as minimum

---

### 3. Progress Subsystem

**Course**: Lessons 05-06
**Core principle**: Treat the agent like an engineer whose short-term memory is wiped between sessions. Persistent state bridges sessions.

| File | Role | Lesson |
|------|------|--------|
| `claude-progress.md` | Current verified state + session log | L05 |
| `session-handoff.md` | Compact session-end summary | L12 |

**Key insight from L05**: An agent in a fresh session knows NOTHING about what happened before. `claude-progress.md` is its memory. Without it, every session starts from scratch.

**Automation targets**:
- SessionStart: check if `claude-progress.md` is stale (last updated > 24h ago)
- Stop: remind to update `claude-progress.md`
- Detect gaps in session log (missing verification, missing next step)

---

### 4. Scope/Feature Subsystem

**Course**: Lessons 07-08
**Core principle**: WIP=1 — work on exactly ONE feature at a time. The feature list is an externalized todo that doesn't vanish when context is cleared.

| File | Role | Lesson |
|------|------|--------|
| `feature_list.json` | Machine-readable feature registry with status and evidence | L08 |

**Key insight from L07 + L08**: "Doing more" means finishing less. WIP=1 enforced by `feature_list.json` with `single_active_feature: true`. The feature list is a harness primitive — it externalizes what the agent should work on, one item at a time.

**Automation targets**:
- PreToolUse: warn if agent edits files outside the current feature's area
- Status check: detect >1 feature `in_progress` (WIP violation)
- Verify evidence is non-empty before allowing status change to `passing`

---

### 5. Verification Subsystem

**Course**: Lessons 09-10
**Core principle**: Agent confidence ≠ completion. Verification = executable evidence (typecheck green + build success + test pass). Unit tests verify parts; end-to-end verifies the whole.

| File | Role | Lesson |
|------|------|--------|
| `checklist.sh` | Executable end-of-session verification | L12 |
| `npm test` | Unit/integration test suite | L09 |
| `npm run build` | Full build verification | L10 |
| `evidence` field in feature_list.json | Recorded proof of verification | L09 |

**Key insight from L09 + L10**: Agent says "done" prematurely because it's confident. Verification replaces confidence with evidence. Unit tests alone are insufficient — integration bugs live in the gaps between modules.

**Automation targets**:
- `/harness:verify`: run full check → build → test chain, auto-fill evidence
- Detect features marked `passing` with empty evidence → flag as unverified
- Remind that `npm test` passing ≠ `npm run build` passing

---

### 6. Observability Subsystem

**Course**: Lesson 11
**Core principle**: The agent's process must be transparent. If you can't see what the agent did, you can't debug it.

| File | Role | Lesson |
|------|------|--------|
| `agent.log` | Structured ndjson log of agent actions | L11 |
| `logger.ts` (or equivalent) | Structured logging library with levels and service tags | L11 |
| `evaluator-rubric.md` | Scoring rubric for agent output quality | — |
| `scripts/benchmark.sh` | Performance benchmark suite | — |

**Key insight from L11**: agent.log is most useful at domain action boundaries — READ, WRITE, TEST, ABORT events. Not every line of code, but every meaningful state transition.

**Automation targets**:
- PostToolUse: auto-append to agent.log for Write/Edit/Bash actions
- Detect agent.log with no CLOSE marker → previous session did not exit cleanly
- Parse agent.log to reconstruct what happened in a session

---

### 7. Handoff + Automation Subsystem

**Course**: Lessons 12-13
**Core principle**: Every session must leave a clean handoff. Loop engineering automates the human out of the driving seat.

| File | Role | Lesson |
|------|------|--------|
| `session-handoff.md` | Compact session-end summary | L12 |
| `clean-state-checklist.md` | Pre-commit verification checklist | L12 |
| `checklist.sh` | Executable handoff verification | L12 |
| `loop.sh` | While-true automation loop | L13 |

**Key insight from L12 + L13**: The most expensive 30 minutes in harness engineering is the NEXT session's first 30 minutes — when the agent has no idea what happened before. Handoff eliminates that cost. Loop eliminates the human from the coordination loop entirely.

**Automation targets**:
- Stop hook: run checklist.sh items, remind about uncommitted changes
- Detect missing handoff from previous session
- `/harness:audit`: score all 7 subsystems, rank improvements by impact

---

## Subsystem Maturity Levels

When auditing a project, score each subsystem 0-3:

| Score | Level | Criteria |
|-------|-------|----------|
| 0 | Absent | Files don't exist, no practice in place |
| 1 | Emerging | Files exist but are incomplete or stale |
| 2 | Established | Files are complete and consistently used |
| 3 | Optimized | Files are integrated, automated, and self-healing |

### Scoring Rubric per Subsystem

**Knowledge (0-3)**:
- 0: No AGENTS.md or CLAUDE.md
- 1: One of the two exists, incomplete
- 2: Both exist, AGENTS.md has startup rules + conventions + DoD
- 3: Full docs/ hierarchy, CLAUDE.md routes to AGENTS.md, no duplication

**Environment (0-3)**:
- 0: No init.sh
- 1: init.sh exists but only installs dependencies
- 2: init.sh covers install + check + build
- 3: init.sh covers install + check + build + harness file audit + sample data

**Progress (0-3)**:
- 0: No progress tracking
- 1: claude-progress.md exists but last updated > 1 week ago
- 2: Updated every session, has current state + session log
- 3: Plus session-handoff.md for fast resumption

**Scope/Feature (0-3)**:
- 0: No feature_list.json
- 1: feature_list.json exists but statuses are stale
- 2: Statuses are current, evidence is filled for passing features
- 3: WIP=1 enforced, verification steps defined per feature

**Verification (0-3)**:
- 0: No automated verification
- 1: Tests exist but aren't run consistently
- 2: `npm test` run every session, evidence recorded
- 3: Full chain (check → build → test) automated, checklist.sh in use

**Observability (0-3)**:
- 0: No logging
- 1: Basic console.log, no structure
- 2: Structured logging (agent.log or logger.ts), levels used correctly
- 3: Plus benchmark scripts, evaluator rubric, cleanup scanner

**Handoff/Automation (0-3)**:
- 0: No handoff practice
- 1: checklist.sh exists
- 2: checklist.sh + clean-state-checklist.md used every session
- 3: Plus loop.sh for automated task cycling

**Maximum total score**: 21 (7 subsystems × 3)
