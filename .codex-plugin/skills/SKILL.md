---
name: harness-companion
description: Use when working on projects with harness engineering files (feature_list.json, AGENTS.md, init.sh) — set up or audit Harness Engineering practices, drive an evidence-backed feature pipeline, surface stale evidence or WIP violations at session start, hand off cleanly between sessions, or run the 7-subsystem health / 5-axis audit dashboard.
---

# Harness Companion

See the main [SKILL.md](../../SKILL.md) at the harness-companion root for full documentation.

## Quick reference

| Command | Purpose |
|---------|---------|
| `/harness:init` | Bootstrap harness files |
| `/harness:status` | 7-subsystem health dashboard |
| `/harness:feature <id> <status> [evidence...]` | Update a feature |
| `/harness:verify` | Run verification chain |
| `/harness:handoff` | Handoff warnings |
| `/harness:audit` | 5-axis audit scoring |
