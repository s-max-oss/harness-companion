# Codex Adapter Status — Phase 5b

> Official hook/plugin protocol is documented; package validation and install contract
> tests pass; real Codex CLI hook firing/trust-flow E2E remains pending.

## What IS verified

| Evidence | Result |
|----------|--------|
| `validate_plugin.py` | Passes (Phase 6 CI) |
| Codex contract (`test-codex-contract.sh`) | 122/122 PASS |
| Codex install modes (`test-codex-install-modes.sh`) | 42/42 PASS |
| Release archive test (Phase A+B) | Passes |
| Install receipt upgrade contract (rc.2) | Passes |
| VERSION file sync (rc.2) | Passes |

## What remains pending

- Real Codex CLI hook firing E2E against the actual Codex runtime
- Trust-flow UX verification in the Codex CLI
- `commandWindows` execution on native Windows without Git Bash

## Notes

- PreToolUse is permissive fail-open (`policy_not_enabled`) by design
- Windows sandbox is degraded (`windows_sandbox_degraded=true`) — Codex adapter
  requires Git Bash on PATH for `commandWindows` wrappers
- This file replaces the former `UNSUPPORTED.md` which implied the adapter was
  not yet functional — it is code-complete and install-contract-verified
