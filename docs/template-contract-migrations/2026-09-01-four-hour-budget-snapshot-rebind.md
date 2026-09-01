# Template-contract authorization after the four-hour budget migration

The four-hour canonical budget migration changes the byte digest of
`.harness/.template-snapshot.json` because the snapshot now records the
approved `.harness/config.json` digest.

Template-contract authorizations bind the complete snapshot digest and
therefore fail closed after any snapshot change. This record carries forward
the exact, previously reviewed rc.3 authorizations for `AGENTS.md`,
`CLAUDE.md`, and `init.sh` against the new snapshot bytes.

It does not authorize new content in those files, modify their frozen snapshot
entries, or recapture the snapshot. The prior 2026-08-27 authorization remains
unchanged as historical evidence and is no longer active because its
`snapshot_sha256` binds the earlier snapshot.
