# Codex hooks registry (Phase 5a)

This is the Codex event-keyed hook registry, committed at plugin root.

**Phase 5a**: Codex CLI not available to confirm hook command schema. Path
tokens `${PLUGIN_ROOT}` (bash) and `%PLUGIN_ROOT%` (cmd) are
environment-variable references expanded by bash / cmd.exe at hook runtime
— NOT installer substitutions.

**Schema** (per design §5.3):
- Top-level key: `hooks`
- Subkeys: event names (`SessionStart`, `Stop`, `PreToolUse`)
- Each event value: array of hook groups
- Each hook group: `{ "hooks": [ { "type": "command", "command": "...", "commandWindows": "...", "timeout": N } ] }`

**`timeout` unit**: seconds (Codex hook timeout unit), not milliseconds.
5 seconds is deliberately chosen — hooks are lightweight core→adapter
mappings; they should complete quickly or fail-open.

**Phase 5b**: when confirmed Codex schemas are available, this file remains
unchanged (path structure is stable). What changes is the `.sh` hook
implementations: fail-open default is replaced with confirmed-schema
output paths.
