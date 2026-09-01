# Four-hour canonical verification budget

This one-time migration raises the self-host canonical command budget from
7,200 seconds to 14,400 seconds. The user explicitly approved the change after
a current-HEAD run used the full two-hour budget while completing 34 of 40
suites, all at `rc=0` with no assertion failures.

The six suites that had not started were then exercised through the same
runner-compatible entry points. All passed. Two are intrinsically expensive on
this Windows/MSYS host: the dirty-worktree manifest suite took 2,087 seconds and
the release-archive suite took 1,181 seconds. A four-hour cap therefore supplies
bounded scheduling margin without creating an unbounded hang allowance.

## Contract preserved

- Canonical command remains exactly `bash tests/run-all.sh`.
- All discovered suites and assertions remain required.
- Passing still requires one terminal, valid, current-HEAD canonical run.
- Targeted runs remain diagnostic and cannot be stitched into passing evidence.
- Runner parallelism, fail-closed behavior, evidence binding, DWM rules, and
  historical artifacts are unchanged.

## Immutable runtime migration

Only the following three immutable self-host paths are re-bound:

| Path | Change |
|---|---|
| `.harness/config.json` | `timeout_seconds: 7200` → `14400` |
| `.harness/.template-snapshot.json` | update only the recorded config digest |
| `.harness/PROJECT_BRIEF.json` | update only `template_manifest_digest` |

The corresponding three lines in
`tests/fixtures/dirty-worktree-manifest.jsonl` are updated explicitly. The
fixture is not regenerated, and all other lines remain unchanged.
