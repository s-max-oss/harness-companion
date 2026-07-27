# Harness Files Reference

This document describes every file in the Harness Engineering system — its purpose, format, and when to create or update it.

---

## File Index

| File | Subsystem | Purpose | When Created | When Updated |
|------|-----------|---------|--------------|--------------|
| `AGENTS.md` | Knowledge | Agent operating manual — startup rules, boundaries, conventions, definition of done | Project init | When conventions or architecture change |
| `CLAUDE.md` | Knowledge | Claude Code quick reference — commands, key files, "how to add a feature" | Project init | When build commands or key files change |
| `init.sh` | Environment | One-command environment verification — install, check, build, harness file audit | Project init | When build steps or harness file list changes |
| `feature_list.json` | Scope/Feature | Machine-readable feature registry with status and evidence | Project init | Every session — status changes, evidence added |
| `claude-progress.md` | Progress | Cross-session state — current verified state + session log | Project init | Every session end |
| `session-handoff.md` | Handoff | Compact session-end summary — what was verified, changed, broken, next step | Project init | Every session end |
| `clean-state-checklist.md` | Handoff | Pre-commit verification checklist — build, feature state, repo state | Project init | When verification steps change |
| `checklist.sh` | Handoff | Executable end-of-session checklist — build, status sync, progress, commits, agent.log | Project init | When verification commands change |
| `agent.log` | Observability | Structured ndjson log of agent actions — WRITE, READ, TEST, ABORT, CLOSE | Auto-created | Every action |
| `evaluator-rubric.md` | Observability | Agent output scoring rubric — correctness, verification, scope, reliability, maintainability, handoff | Project init | When quality criteria evolve |
| `loop.sh` | Automation | While-true loop that drives harness components automatically | After harness is stable | When task flow changes |

---

## File Format Specifications

### AGENTS.md

**Purpose**: The full operating manual for AI agents. Read on every session start.

**Structure**:
```markdown
# AGENTS.md — Agent Operating Manual

## Startup Rules (numbered list: what to read, in what order)
## Project Context (one paragraph)
## Docs Hierarchy (if docs/ exists)
## Layer Boundaries (main / preload / renderer / services)
## Conventions (TypeScript strict, named exports, etc.)
## Definition of Done (numbered checklist)
## WIP=1 Rule
## Session Handoff (what to update when ending)
```

**Key principle**: AGENTS.md is the "operations manual" — it tells the agent HOW to work. It is NOT a README for humans.

---

### CLAUDE.md

**Purpose**: Quick reference for Claude Code specifically. Should be short — point to AGENTS.md for details.

**Structure**:
```markdown
# CLAUDE.md — Quick Reference for Claude Code

## Project Overview (one sentence)
## Build & Run (commands)
## Quick Start (bash init.sh)
## Key Files (table: file → purpose)
## Architecture Rules (bullet list)
## IPC Channels (if Electron: table of channel → direction → purpose)
## How to Add a Feature (numbered steps)
## Testing (commands)
```

**Key principle**: CLAUDE.md is a "cheat sheet" — AGENTS.md is the full manual. Do not duplicate content between them.

---

### feature_list.json

**Purpose**: The single source of truth for what features exist and their current state.

**Template format** (with rules and verification steps):
```json
{
  "project": "project-name",
  "last_updated": "YYYY-MM-DD",
  "rules": {
    "single_active_feature": true,
    "passing_requires_evidence": true,
    "do_not_skip_verification": true
  },
  "features": [
    {
      "id": "unique-id",
      "priority": 1,
      "area": "category",
      "title": "Human-readable name",
      "user_visible_behavior": "What the user sees",
      "status": "not_started | in_progress | blocked | passing",
      "verification": ["Step 1", "Step 2", "Step 3"],
      "evidence": [],
      "notes": ""
    }
  ]
}
```

**Status values**:
- `not_started` — Work has not begun
- `in_progress` — Currently being worked on (WIP=1: only ONE at a time)
- `blocked` — Cannot continue until a documented blocker is resolved
- `passing` — Required verification has passed and evidence is recorded

**Rules** (enforced by convention, not mechanically):
- `single_active_feature`: At most one feature `in_progress` at a time
- `passing_requires_evidence`: Cannot mark `passing` without evidence
- `do_not_skip_verification`: Must run verification steps, not just assume

---

### init.sh

**Purpose**: One command that verifies the project is ready to work on.

**Standard structure**:
```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Install dependencies (npm install)
# 2. Type-check (npm run check or npx tsc --noEmit)
# 3. Build (npm run build)
# 4. Verify harness files exist
# 5. Verify sample data (optional)
```

**Exit codes**: 0 = ready, non-0 = something is broken

**Key principle**: `bash init.sh` should be the FIRST command in any session. If it fails, don't write code — fix the environment first.

---

### claude-progress.md

**Purpose**: Cross-session persistent state. The next session reads this to know where to continue.

**Structure**:
```markdown
# claude-progress.md — Session Log

## Current Verified State
- Repository root: ...
- Standard startup path: bash init.sh
- Standard verification path: npm test && npm run build
- Current highest-priority unfinished feature: [feature id]
- Current blocker: [none, or describe]

## Session Log
### Session 001
- Date: YYYY-MM-DD
- Goal: ...
- Completed: ...
- Verification run: npm test — N/N passing
- Evidence captured: ...
- Commits: ...
- Files or artifacts updated: ...
- Known risk or unresolved issue: ...
- Next best step: ...
```

---

### session-handoff.md

**Purpose**: Compact session-end document. Faster to read than the full progress log.

**Structure**:
```markdown
# Session Handoff — [Date]

## Verified Now
- [ ] npm test — N/N passing
- [ ] npm run build — success
- [ ] npm run check — clean

## Changed This Session
| File | Change | Reason |

## Broken Or Unverified
(List or "None — all verified green")

## Next Best Step
(One sentence)

## Commands to Resume
```

---

### clean-state-checklist.md

**Purpose**: Pre-commit verification. Run before declaring anything "done."

**Categories**:
1. Build & Environment (init.sh, typecheck, build, test)
2. Feature State (JSON valid, evidence filled, WIP=1)
3. Progress Tracking (claude-progress.md updated)
4. Repository State (no unexpected uncommitted changes)
5. Clean Exit (no stale artifacts, agent.log CLOSE marker)

---

### checklist.sh

**Purpose**: Executable version of the handoff checklist. Run at end of every session.

**5 standard checks**:
1. Build verification — `npm run check && npm run build`
2. Feature status sync — detect dangling `in_progress` features
3. Progress documentation — verify `claude-progress.md` exists
4. Change record — detect uncommitted changes
5. Agent log close — write CLOSE marker to `agent.log`

---

### agent.log

**Purpose**: Structured ndjson log of every agent action for observability.

**Format** (one JSON object per line):
```json
{"ts":"2026-03-30T11:30:00Z","step":1,"action":"WRITE","file":"src/services/qa-service.ts"}
{"ts":"2026-03-30T11:45:00Z","step":-1,"action":"CLOSE"}
```

**Action types**: `WRITE`, `READ`, `TEST`, `ABORT`, `CLOSE`
**step: -1**: Session close marker

---

## Minimum Viable Harness

For a new project, the absolute minimum harness files are:

1. **AGENTS.md** — tells the agent how to work
2. **CLAUDE.md** — quick reference for Claude Code
3. **feature_list.json** — what to build, what's done
4. **init.sh** — one-command environment verification

These 4 files give you the Knowledge + Environment + Scope subsystems. Add Progress (claude-progress.md) and Handoff (session-handoff.md, clean-state-checklist.md, checklist.sh) as the project grows. Add Observability (agent.log, evaluator-rubric.md) when you need to debug agent behavior. Add Automation (loop.sh) when the harness is stable and you want to remove the human from the loop.
