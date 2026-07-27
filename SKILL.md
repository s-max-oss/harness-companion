---
name: harness-companion
description: Use when working on projects that have harness engineering files (feature_list.json, AGENTS.md, init.sh), when the user wants to set up or audit harness practices, when the user asks about harness status, feature tracking, verification, session handoff, or harness initialization, or when the user wants to check if their project follows harness engineering discipline. Also use when the user says "harness" in any context related to agent engineering workflows.
---

# Harness Companion

## Overview

Harness Companion is the operational assistant for Harness Engineering's 7 subsystems. It helps agents and developers initialize, inspect, manage, verify, hand off, and audit harness files — turning the 13-lesson course knowledge into executable workflows.

**Core principle**: Harness files are the project's "agent OS." Harness Companion keeps that OS healthy.

## When to Use

Trigger this skill when:
- The user asks about harness status, health, or audit
- The user wants to initialize harness files in a new project
- The user needs to manage `feature_list.json` (add, list, update features)
- The user wants to verify a feature is truly complete (not just claimed)
- The user is about to end a session and needs handoff
- The user wants a comprehensive diagnosis of harness maturity
- The project has `feature_list.json` and the user mentions any harness concept

**Do NOT use when**:
- The project has no harness files and the user doesn't want to set them up
- The user is asking about non-harness topics (general git, npm, etc.)

## Quick Reference

| Command | Trigger | What It Does |
|---------|---------|--------------|
| `/harness:init` | "initialize harness", "set up harness files" | Generate harness scaffold from templates |
| `/harness:status` | "harness status", "how is harness health" | Dashboard of file existence, feature progress, WIP state |
| `/harness:feature` | "feature list", "add feature", "update status" | Read/write feature_list.json |
| `/harness:verify` | "verify feature", "is it really done" | Run check→build→test chain, fill evidence |
| `/harness:handoff` | "handoff", "end session", "wrap up" | Generate handoff doc, run checklist verification |
| `/harness:audit` | "audit harness", "diagnose harness" | Score all 7 subsystems, rank improvements |

## Workflows

### /harness:init — Initialize Harness Scaffold

**When**: New project needs harness files, or existing project is missing core harness files.

**Process**:
1. Detect project type (Node/TS, Python, generic) by reading `package.json` or similar
2. Ask which harness files to generate (minimum: AGENTS.md + CLAUDE.md + feature_list.json + init.sh)
3. Copy templates from `templates/` to project root, filling in project-specific placeholders
4. Make scripts executable (`chmod +x init.sh`)
5. Run `bash init.sh` to verify the scaffold works
6. Report what was created and what the user should customize

**Template mapping**:
- `AGENTS.md` → project root
- `CLAUDE.md` → project root
- `feature_list.json` → project root (user fills in features)
- `init.sh` → project root (adapt commands to project)
- `claude-progress.md` → project root (optional, for multi-session projects)
- `session-handoff.md` → project root (optional)
- `clean-state-checklist.md` → project root (optional)
- `checklist.sh` → project root (optional)

**Minimum viable harness** (4 files): AGENTS.md, CLAUDE.md, feature_list.json, init.sh

### /harness:status — Harness Health Dashboard

**When**: User wants to see current harness state at a glance.

**Process**:
1. Scan for harness files in project root — report Present/Missing/Stale for each
2. If `feature_list.json` exists:
   - Count features by status (not_started, in_progress, blocked, passing)
   - Detect WIP=1 violations (>1 feature in_progress)
   - Detect unverified passing features (status=passing but evidence is empty)
3. If `claude-progress.md` exists: report last session date, current blocker, next step
4. If `agent.log` exists: report last action timestamp, check for CLOSE marker
5. Output a compact dashboard (not raw JSON — a formatted summary)

**Output format**:
```
Harness Health: project-name
─────────────────────────────
Knowledge:   AGENTS.md ✓  CLAUDE.md ✓
Environment: init.sh ✓ (last run: 2026-07-27)
Progress:    claude-progress.md ✓ (2 sessions logged)
Scope:       feature_list.json ✓ (3/8 passing, WIP=1 ✓)
Verification: checklist.sh ✓
Observability: agent.log ✓ (last: 2026-07-27T10:00:00Z, CLOSE ✓)
Handoff:     session-handoff.md ✓  clean-state-checklist.md ✓

⚠ Warnings:
  - feature "chat-login" is in_progress since 2026-07-25 (2 days stale)
```

### /harness:feature — Manage Feature List

**When**: User wants to list, add, or update features in `feature_list.json`.

**Sub-commands** (inferred from user's language):

**List features**:
- Read `feature_list.json` and display a table: id, title, status, priority
- Highlight current in_progress feature
- Show completion percentage

**Add feature**:
- Ask for: id, title, area, user_visible_behavior, priority
- Auto-fill: status="not_started", evidence=[], verification=[]
- Validate JSON after writing

**Update status**:
- Show current features, ask which one
- Validate: cannot mark as `passing` without evidence (warn if evidence is empty)
- Validate: cannot have >1 `in_progress` (warn if WIP=1 rule would be violated)
- Update `last_updated` timestamp

**Key rules enforced**:
- WIP=1: at most one feature `in_progress`
- Evidence required: `passing` must have non-empty evidence
- Timestamp updated on every change

### /harness:verify — Run Verification Chain

**When**: User wants to verify a feature is truly complete, not just claimed.

**Process**:
1. Identify which feature to verify (ask if not specified)
2. Run the verification chain:
   a. `npm run check` (or `npx tsc --noEmit`) — typecheck
   b. `npm run build` — build
   c. `npm test` — test suite
3. Capture output and exit codes from each step
4. If all pass: auto-fill the feature's `evidence` field with command outputs and timestamps
5. If any fail: report exactly what failed, do NOT update feature status
6. Update `feature_list.json` status to `passing` only if all steps pass

**Evidence format** written to feature_list.json:
```
"evidence": [
  "2026-07-27: typecheck passed (0 errors)",
  "2026-07-27: build succeeded (exit 0)",
  "2026-07-27: tests passed (42/42)"
]
```

### /harness:handoff — Session Handoff

**When**: User is ending a session and wants clean handoff.

**Process**:
1. Run `checklist.sh` if it exists; otherwise run equivalent checks manually:
   - Build verification (typecheck + build)
   - Feature status sync (detect dangling in_progress)
   - Progress documentation (claude-progress.md exists and updated)
   - Change record (uncommitted changes?)
   - Agent log close marker
2. Generate/update `session-handoff.md`:
   - Fill "Verified Now" with command results
   - Fill "Changed This Session" from git diff
   - Fill "Next Best Step" from feature_list.json pending items
3. If `claude-progress.md` exists: append a new session log entry
4. Report any items that need human attention before closing

**Output**: A clear summary of what's clean and what needs attention before the session ends.

### /harness:audit — Comprehensive Harness Diagnosis

**When**: User wants a deep assessment of harness maturity across all 7 subsystems.

**Process**:
1. For each of the 7 subsystems, check file existence, content completeness, and freshness
2. Score each subsystem 0-3 (see `references/subsystems-mapping.md` for rubric)
3. Compute total score (max 21)
4. Rank improvements by impact (what would raise the score most with least effort)

**Output format**:
```
Harness Audit: project-name
─────────────────────────────
Knowledge:    2/3  (AGENTS.md ✓, CLAUDE.md ✓, docs/ ✗)
Environment:  3/3  (init.sh covers install+check+build+audit)
Progress:     1/3  (claude-progress.md exists, last updated 5 days ago)
Scope:        2/3  (feature_list.json ✓, WIP=1 enforced, evidence incomplete)
Verification: 2/3  (tests exist, checklist.sh ✓, no full chain automation)
Observability:1/3  (agent.log ✓, no structured logging in services)
Handoff:      1/3  (session-handoff.md ✓, no clean-state-checklist.md)
─────────────────────────────
Total: 12/21 (57%)

Top improvements (by impact):
  1. [Progress] Update claude-progress.md — 5 min, +1 point
  2. [Observability] Add service-level structured logging — 30 min, +1 point
  3. [Handoff] Create clean-state-checklist.md from template — 5 min, +1 point
```

## Common Mistakes

| Mistake | Why It Happens | Fix |
|---------|---------------|-----|
| Skipping init.sh at session start | Agent is eager to start coding | SessionStart hook auto-reminds; run `bash init.sh` first |
| Multiple features in_progress | "This one is almost done, I'll start the next" | feature_list.json WIP=1 rule; `/harness:status` detects violations |
| Marking passing without evidence | Agent is confident it works | `/harness:verify` enforces evidence-before-status |
| Not updating claude-progress.md | "I'll do it next session" | Stop hook auto-reminds; `/harness:handoff` generates it |
| Giant AGENTS.md | Everything seems important | `/harness:audit` flags files > 500 lines; split into docs/ |
| Agent.log without CLOSE marker | Session ended abruptly | Stop hook writes CLOSE; `/harness:status` detects missing CLOSE |

## Hook Integration

This skill works alongside two automatic hooks (configured in `~/.claude/settings.json`):

| Hook | When | What |
|------|------|------|
| SessionStart | Every new/resumed session | Checks harness file health, injects status into context |
| Stop | Every session end | Reminds about uncommitted changes, feature sync, checklist |

If hooks are not yet configured, run the install script or ask the user to set them up.
