# rc.2 → rc.3 self-host contract migration

This migration preserves `.harness/.template-snapshot.json` byte-for-byte. It
authorizes the exact tracked `AGENTS.md`, `CLAUDE.md`, and `init.sh` content that
was deliberately evolved during rc.2 hardening and the rc.3 bootstrap.

The authorization is fail-closed:

- the migration JSON must be committed and clean;
- its `authorization_parent` must be an ancestor of the current HEAD;
- its snapshot digest must equal the unchanged frozen snapshot;
- every recorded old digest must equal the corresponding snapshot entry;
- every authorized digest must equal the clean tracked file at HEAD; and
- exactly one migration may satisfy the complete immutable-entry set.

This is not a snapshot recapture and does not change the frozen dirty-worktree
baseline. Any later edit to an authorized file requires another explicit,
reviewable migration.
