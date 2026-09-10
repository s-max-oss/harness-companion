# rc.3 maintenance path exception

Date: 2026-09-10

The user explicitly prioritized a stable, working implementation over rigid
scope limits, authorized the four-hour verification window, and authorized the
agent to make work-related repository and release changes without repeated
approval. This records the resulting narrow exception to the original PR-B
file-path freeze in frozen onboarding specification section 15.2; it does not
rewrite that specification or its historical meaning.

The exception covers only these post-PR-B maintenance changes:

1. `core/harness-verify.sh` and `core/lib/config-validate.sh`: enforce and
   validate the user-approved four-hour canonical verification limit while
   remaining fail-closed when GNU `timeout` is unavailable.
2. `core/lib/lock-registry.sh`: preserve cross-platform lock ownership,
   bounded acquisition, nested locking, and crash-safe runtime evidence
   publication required by the current self-hosting acceptance gates.

The exception does not authorize changes to the other protected paths, force
updates, retagging existing releases, deletion or rewriting of append-only
evidence, weakening the real-eval release gate, or re-recording the frozen
dirty-worktree baseline. The rc.3 cumulative diff and these three files remain
subject to targeted tests, fresh independent review, canonical verification,
and final release acceptance.
