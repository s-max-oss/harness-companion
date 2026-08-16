# G0 Evidence Package — Codex r6 Remediation

**Branch:** `distribution/rc2-hardening`
**Commit:** current HEAD (this commit, not yet pushed)
**Parent commit:** `b7ad1bb` (Codex r5 closure)
**History:** The current commit is the result of an in-place amendment following a Codex r6 independent-verification rejection (2026-08-15). To identify the exact SHA at any time, use `git rev-parse HEAD` — this document deliberately does not hardcode an SHA.

This document records **only actual run results** from the r6 remediation pass. No gate is claimed passed without a verified exit-0 run from a single canonical F-MAINT-01 invocation.

---

## Part 0: Canonical Run Identification

The single canonical F-MAINT-01 run for this acceptance pass is the **NEW** NDJSON produced by `bash core/harness-verify.sh F-MAINT-01 . --write` at current HEAD, after all in-place amendments. The timed-out run (`20260816T042120Z-29749-15476`, exit_code=124) is preserved as historical evidence only — it is NOT used as the acceptance result, per the "no delete / no re-shoot / no weaken" constraint inherited from Codex r3.

Identification (placeholders to be filled at canonical run completion):

| Field | Value |
|-------|-------|
| canonical run_id | `(filled at canonical run completion)` |
| vcs_revision (HEAD at run start) | `(filled at canonical run completion)` |
| workspace_fingerprint_initial | `(filled at canonical run completion)` |
| config_sha256 (after r6 7200s bump) | `sha256:8ace63957d822f1a0b530ad3aa83619682cc48155d75c4746286d8f0574a49a6` |
| exit_code | `(filled at canonical run completion)` |
| duration_ms | `(filled at canonical run completion)` |
| overall_result | `(filled at canonical run completion; must be "passed")` |

---

## Part I: Targeted Regression — Per-Test Pass Counts

These counts come from `tests/run-all.sh` running each test script under `bash <test>` with stdin `/dev/null` and timeout `3000s` (raised from `1500s` to accommodate `test-verdict-artifact.sh` on Windows MSYS). The full per-test results appear in the canonical NDJSON's `log_artifact` (full-suite.log).

(per-test results table to be filled at canonical run completion)

| Test | Result |
|------|--------|
| `tests/adapters/test-bug3-matrix.sh` | (filled) |
| `tests/adapters/test-claude-code-contract.sh` | (filled) |
| `tests/adapters/test-claude-code-lifecycle.sh` | (filled) |
| `tests/adapters/test-codex-contract.sh` | (filled) |
| `tests/adapters/test-codex-install-modes.sh` | (filled) |
| `tests/bootstrap/test-bootstrap-gates.sh` | (filled) |
| `tests/core/test-audit-score-axis.sh` | (filled) |
| `tests/core/test-branch-gate.sh` | (filled) |
| `tests/core/test-brief-integrity.sh` | (filled) |
| `tests/core/test-harness-feature.sh` | (filled) |
| `tests/core/test-harness-verify-integration.sh` | (filled) |
| `tests/core/test-init.sh` | (filled) |
| `tests/core/test-journal-recover.sh` | (filled) |
| `tests/core/test-journal-strict-contract.sh` | (filled) |
| `tests/core/test-lock-registry.sh` | (filled) |
| `tests/core/test-passing.sh` | (filled) |
| `tests/core/test-r4-contracts.sh` | (filled) |
| `tests/core/test-r5-glob.sh` | (filled) |
| `tests/core/test-staleness.sh` | (filled) |
| `tests/core/test-templates.sh` | (filled) |
| `tests/core/test-validate-feature-registry.sh` | (filled) |
| `tests/core/test-validate-run-log.sh` | (filled) |
| `tests/core/test-verdict-artifact.sh` | (filled) |
| `tests/core/test-workspace-fingerprint.sh` | (filled) |
| `tests/migration/test-v1-compat.sh` | (filled) |
| `tests/release/test-dirty-worktree-manifest.sh` | (filled) |
| `tests/release/test-e2-tag-trigger.sh` | (filled) |
| `tests/release/test-negative-gates.sh` | (filled) |
| `tests/release/test-release-archive.sh` | (filled) |
| `tests/release/test-version-sync.sh` | (filled) |

Final SUITES: `(filled; must be "X/30 passed")`.

---

## Part II: Four Release Gates (single canonical run)

Per Codex r3 → r6 inheritance, the four release gates must ALL be green on a single canonical run (not side-channel evidence):

| Gate | Expected | Actual (canonical run) |
|------|----------|------------------------|
| `tools/snapshot-dirty-worktree.sh check` (against original official baseline) | rc=0 | (filled) |
| Passing eligibility for F-MAINT-01 (`core/lib/passing.sh is_eligible_for_passing`) | rc=0 | (filled) |
| Three-axis freshness (Axis1 fingerprint, Axis2 config, Axis3 vcs) | all three fresh | (filled) |
| `init.sh` exit code | 2 (checks pass, Phase 1 fail-closed) | (filled) |

`init.sh` exit-code semantics (per CLAUDE.md):
- 0 = checks pass AND all Phase 1 start conditions met ("Ready to start work.")
- 1 = init/validator failure (config, run log, registry, status, WIP, staleness, snapshot/digest/immutable integrity)
- 2 = checks pass but Phase 1 start conditions NOT met (fail-closed)

rc.2 has not been merged to master and no `v2.0.0-rc.2` tag exists locally, so the Phase 1 conditions will (correctly) NOT be met → init.sh exits 2. This is the expected fail-closed behavior, not a defect.

---

## Part III: Reviewer Verdict (Independent Subagent)

Per constraint "Reviewer verdict 经独立 subagent 写出，不由 Claude 自写", the verdict JSONL appended to `.harness/reviews/maintenance/F-MAINT-01.jsonl` is produced by an independent subagent dispatched specifically for this purpose.

Schema (per existing precedent line in `.harness/reviews/maintenance/F-MAINT-01.jsonl`):

```json
{
  "schema_version": 1,
  "kind": "maintenance",
  "feature_id": "F-MAINT-01",
  "verdict": "PASS",
  "base_sha": "<40-hex>",
  "head_sha": "<40-hex>",
  "run_id": "<canonical-run-id>",
  "reviewer_host": "subagent",
  "checked": ["<gate-list>"],
  "reason": "<one-line summary>",
  "recorded_at": "<iso8601>",
  "attempt": <N>
}
```

Subagent dispatch will follow once the canonical run completes.

---

## Part IV: Path (b) Decision Record

Per Codex r3 directive "Optimize first to fit under cap (prior baseline ~53 min fits with margin); only if optimization is provably insufficient, then take path (b): raise schema `timeout_seconds.maximum` to 7200 + sync spec/validator/compatibility/tests."

**Path (a) measurement (Windows MSYS, single-run):**

| Test | Wall-clock |
|------|------------|
| `tests/core/test-verdict-artifact.sh` | **1777s (29.6 min)** |
| `tests/core/test-workspace-fingerprint.sh` | ~208s (3.5 min) |
| `tests/release/test-release-archive.sh` | ~360s (6 min) |
| `tests/release/test-dirty-worktree-manifest.sh` | ~180s (3 min) |

`tests/core/test-verdict-artifact.sh` alone exceeds the prior 1500s per-test cap by 277s (4.6 min) — it would be KILLED before completing under the prior `tests/run-all.sh` per-test timeout.

**Path (a) proved insufficient.** Path (b) enabled: raised `timeout_seconds` 3600 → 7200 in `.harness/config.json`; raised per-test 1500 → 3000 in `tests/run-all.sh`; updated `tests/bootstrap/test-bootstrap-gates.sh` sandbox fixture for consistency.

Validator (`core/lib/config-validate.sh`) accepts the new value: only requires positive integer; 7200 passes.

---

## Part V: Timed-Out Run Preserved as Historical Evidence

The prior run `20260816T042120Z-29749-15476` (Aug 16, exit_code=124, duration_ms=3600000) is preserved at `.harness/logs/runs/20260816T042120Z-29749-15476.ndjson` with its accompanying `full-suite.log`. It is NOT deleted per the "no delete" constraint. It is also NOT used as the acceptance result per the same constraint.

| Run | status | role |
|-----|--------|------|
| `20260816T042120Z-29749-15476` | timed-out (124) | historical evidence only |
| `20260815T152707Z-23238-9058` | passed (0) | prior-passed reference |
| `<NEW canonical>` | (filled) | THIS acceptance result |

---

## Part VI: Acceptance Claim Summary

- Single canonical run generated via `core/harness-verify.sh F-MAINT-01 . --write`
- Canonical command `bash tests/run-all.sh` (unchanged, NOT weakened)
- Per-test count: 30/30 expected (or report which test failed if any)
- Four release gates green on the canonical run
- Reviewer verdict written by independent subagent
- timed-out run preserved as historical evidence
- DWM baseline unchanged
- No push / merge / tag / release / install

---

End of r6 evidence package (header). Per-test counts and gate statuses filled at canonical run completion.