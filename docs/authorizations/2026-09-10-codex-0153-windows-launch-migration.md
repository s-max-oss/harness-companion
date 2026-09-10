# Codex 0.153 Windows launch migration

Date: 2026-09-10

Scope: the release-eligible F-CONV-08 evaluation launcher on native Windows.

The user authorized a compatibility fix after the installed Codex CLI was
updated to 0.153.4. That release reports the historical
`windows.sandbox="elevated"` feature switch as removed. Combining that switch
with `approval_policy="never"` caused the live isolation probe to fail while
launching the sandbox helper, before its command ran.

The subject and live isolation-probe launches now use `--approve-for-me`, the
current CLI entry point for automatically reviewed commands in the
workspace-write sandbox. They continue to use `--ignore-user-config`, disabled
non-shell tools, a snapshotted and signed Codex runtime, the fixed disposable
workspace, and the existing Windows ACL boundary. The live probe remains
mandatory and must prove that the disposable target is writable while the
source workspace, context authority, controller, host profile, and host temp
are inaccessible. The Reviewer remains read-only with shell execution disabled.

This migration does not accept an unisolated run, weaken evidence validation,
rewrite historical candidates/results, or change the frozen DWM baseline.
