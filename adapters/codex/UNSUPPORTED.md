# Codex Adapter — Status: Supported (Phase 5b)

The Codex adapter now implements real SessionStart status injection and Stop
handoff warnings using the official Codex CLI plugin/hooks protocol.

## Protocol verified

| Capability | Status |
|---|---|
| `validate_plugin.py` acceptance | ✅ Passes (Phase 5b) |
| `plugin.json` schema | ✅ Matching validate_plugin.py contract |
| `hooks/hooks.json` | ✅ Real hook definitions with SessionStart/Stop/PreToolUse |
| SessionStart status injection | ✅ `hookSpecificOutput.additionalContext` |
| Stop handoff warnings | ✅ `systemMessage` |
| PreToolUse tool gating | ⚠️ Permissive — policy not enabled |
| `commandWindows` support | ✅ `.cmd` wrappers for each hook |
| Repo-local install | ✅ Copies core/ + adapters/codex/ into target |
| No-jq install fallback | ✅ python3 JSON construction when jq unavailable |
| Contract tests | ✅ Self-contained (python3 for JSON, no hard jq dep) |

## Hook behavior

### SessionStart

Reads stdin for `cwd`, calls `core/lib/status-renderer.sh` to compose
plain-text status, JSON-encodes via python3, wraps in:

```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<status text>"}}
```

Fail-open: any error → `{"continue":true}` exit 0.

### Stop

Reads stdin for `cwd`, calls `sr_handoff_warnings`, JSON-encodes, wraps in:

```json
{"systemMessage":"<handoff warnings>"}
```

No warnings → `{"continue":true}` exit 0 (clean stop).

### PreToolUse

Exits 0 permissively (allows all tools). Emits "policy not enabled" to stderr.
This is intentional — PreToolUse policies are a future feature. The Codex hook
protocol IS functional for SessionStart and Stop.

## Previous status

Prior to Phase 5b, this adapter was marked UNSUPPORTED because an initial
investigation incorrectly concluded that the Codex CLI plugin/hooks protocol
did not exist. The investigation was wrong:

- `validate_plugin.py` DOES exist at `~/.codex/skills/.system/plugin-creator/scripts/`
- `plugin-creator` scaffold DOES exist at the same path
- `codex.exe` IS installed on this machine
- The hook protocol IS documented in the plugin-creator's reference materials
