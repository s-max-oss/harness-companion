# Codex 0.153 Windows launch migration

Date: 2026-09-10

Scope: the release-eligible F-CONV-08 evaluation launcher on native Windows.

The user authorized a compatibility fix after the installed Codex CLI was
updated to 0.153.4. A live probe established that this release rejects shell
commands when `--ignore-user-config` also removes the disposable project's
trust entry. An attempted `--approve-for-me` migration was rejected by the
repository's own live boundary probe because the approved command ran with the
host identity and could read protected roots.

The runner now restores `trust_level="trusted"` by command-line override only
for its freshly created disposable subject and Reviewer roots. It continues to
use `--ignore-user-config`, `approval_policy="never"`, the native elevated
workspace-write/read-only sandboxes, disabled non-shell tools, a snapshotted
and signed Codex runtime, and the existing Windows ACL boundary. The live probe
remains mandatory and must prove both the `CodexSandboxOffline` identity and
that the disposable target is writable while the source workspace, context
authority, controller, host profile, and host temp are inaccessible. The
Reviewer remains read-only with shell execution disabled.

This migration does not accept an unisolated run, weaken evidence validation,
rewrite historical candidates/results, or change the frozen DWM baseline.
