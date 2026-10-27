<!-- generated from PROJECT_BRIEF.json schema_version=1 source_version=2.0.0-rc.2 -->
<!-- DO NOT EDIT — regenerate from JSON. On mismatch, JSON is authoritative. -->
<!-- git rev 7ba16e74a28e40eeec0aa9a250ac2505dd0b570d -->

# Project Brief — v2.0.0-rc.3 Guided Conversational Harness Construction

> **Advisory only.** Current-session user instructions and host security policies
> always take precedence over this file.

## Goal

Ship v2.0.0-rc.3: guided conversational Harness construction as one closed loop.
On `/harness:init`, the Agent drives a natural conversation, synthesizes a
structured Brief, and only after user confirmation does the deterministic Bash
executor (`scripts/harness-init.sh`) write files per the output manifest.
Executor, dialog layer, shell tests, forward eval, and acceptance ship together.
The conversation is the product; the file writes are the consequence.

## Success Criteria

1. Deterministic executor: `scripts/harness-init.sh` accepts `--brief`
   (guided/quick) and legacy callers, and writes the §6.2a output manifest from
   a validated Brief — atomically, idempotently, re-entrant via 3-way SHA compare.
2. Zero writes before Brief confirmation in guided mode; Brief state lives only
   in conversation context until the user approves.
3. Conversational dialog layer: SKILL.md + reference files drive a natural
   Agent-led dialog — never re-ask known info, explain decisions, confirm the
   Brief not the plan, post-init explanation covers generated/inferred/
   defaulted/deferred.
4. Type-matched templates: `templates/` restructured into `common/` + `by-type/`,
   `core/lib/project-detect.sh` extended, and the template manifest snapshot
   records origin for resume/update.
5. 14 forward-eval conversation scenarios pass with a real Agent (vague goals,
   conflicts, unfamiliar users, rejection/modification, authorization denial,
   clean-archive end-to-end).
6. Shell tests cover executor determinism, type-matching, zero-writes, resume
   safety, and cross-host equality; legacy Bash callers still work with
   placeholder-filled Briefs.
7. All rc.3 work contained within this repository; zero writes to
   `~/.claude/`, `~/.agents/`, or local install paths; acceptance package
   (F-CONV-09) presented and release-ready; release requires separate user
   authorization.

## Details

| Field | Value |
|-------|-------|
| Cadence | `oneoff` (conversational decision — this round is a single closed-loop delivery) |
| Deadline | *Deferred* |
| Stack | `shell` |
| Test Framework | `unspecified` (repo has shell tests under `tests/`, but no single canonical runner declared) |
| Detected Type | `shell` |

## Operation Preferences

| Operation | Preference | Notes |
|-----------|-----------|-------|
| commit | **auto** | Ordinary feature commits only. Amend, rebase, reset, discard, force-push require explicit confirmation. |
| push | ask | User confirms push |
| merge | ask | User authorizes merge to master |
| release | ask | User authorizes tag + GitHub release |
| install_packages | ask | No new deps without confirmation |
| external_mutation | ask | No out-of-repo writes without confirmation |
| destructive_ops | false | Never destructive without explicit override |

## Features (v2.0.0-rc.3 — 9 items, one closed loop)

| Phase | Feature ID | Title |
|-------|-----------|-------|
| 1 | F-CONV-04 | `core/lib/project-detect.sh` — extended type detection |
| 1 | F-CONV-05 | `templates/` — restructure into `common/` + `by-type/` |
| 1 | F-CONV-06 | `scripts/harness-init.sh` — `--brief`, re-entry, etc. |
| 2 | F-CONV-01 | SKILL.md — conversational dialog instructions |
| 2 | F-CONV-02 | `references/conversational-principles.md` |
| 2 | F-CONV-03 | `references/post-init-explanation.md` |
| 3 | F-CONV-07 | Shell tests |
| 4 | F-CONV-08 | Forward eval (14 scenarios) |
| 5 | F-CONV-09 | G0-style acceptance package + live conversation session evidence |

**F-CONV-09 is the sole user phase-stop gate in rc.3.** Phase transitions are
gated by an independent Reviewer (defined in `.harness/PLAN.json`). v2.1+ is
deferred until v2.0.0 is stable and does NOT auto-start.

## Honesty note

`generated_by` / `source_version` report the **actual bootstrap baseline**
(`harness-companion v2.0.0-rc.2 @ c5ca212`) — the target rc.3 version is never
claimed as the generator. Bootstrap **origin: legacy-unmanaged** (manual
self-host init, no prior snapshot); **current state: managed-valid** (valid
snapshot present). It does not masquerade as rc.3 executor output. This Brief
was authored conversationally by the Agent.

## Generated

`harness-companion v2.0.0-rc.2` at `c5ca2127792c`
