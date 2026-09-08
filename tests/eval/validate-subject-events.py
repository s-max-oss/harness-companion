#!/usr/bin/env python3
"""Reject Agent shell commands that mutate outside the trusted init boundary."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


MUTATORS = re.compile(
    r"(?ix)(?:"
    r"\b(?:set-content|add-content|out-file|new-item|remove-item|move-item|copy-item|"
    r"rename-item|clear-content|new-temporaryfile|set-acl|touch|mkdir|mktemp|rmdir|del|erase)\b|"
    r"\[\s*(?:system\.)?io\.(?:file|directory)\s*\]\s*::\s*(?!readalltext\b|readalllines\b|exists\b)|"
    r"\b(?:rm|mv|cp|install|tee|python|python3|node|perl|ruby|curl|wget)\b|"
    r"\bgit\s+(?:add|commit|push|merge|checkout|switch|reset|clean|restore|tag)\b"
    r")"
)
BOUNDARY = re.compile(r"(?i)(?:^|[\\/])harness-init-boundary\.sh\b")
APPROVE = re.compile(r"(?i)--decision(?:=|\s+)approve\b")
DIRECT_EXECUTOR = re.compile(r"(?i)(?:^|[\\/])harness-init\.sh\b")
# File redirection is a write even when the resulting file is removed before
# the next tree snapshot.  Exclude descriptor-to-descriptor forms such as
# ``2>&1``, which do not create or replace a filesystem object.
FILE_REDIRECT = re.compile(r">{1,2}(?!&)\s*")


def fail(message: str) -> None:
    print(f"subject-event-validator: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-subject-events.py <subject-events.jsonl>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file() or path.is_symlink():
        fail("event stream is missing or unsafe")

    commands = 0
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            event = json.loads(raw)
        except json.JSONDecodeError as exc:
            fail(f"line {number} is not JSON: {exc}")
        if not isinstance(event, dict):
            fail(f"line {number} is not an object")
        if event.get("type") not in {"item.started", "item.completed"}:
            continue
        item = event.get("item")
        if not isinstance(item, dict) or item.get("type") != "command_execution":
            continue
        if event.get("type") != "item.completed":
            continue
        command = item.get("command")
        if not isinstance(command, str) or not command.strip():
            fail(f"line {number} has an invalid command")
        commands += 1
        approved_boundary = bool(BOUNDARY.search(command) and APPROVE.search(command))
        forbidden = bool(
            MUTATORS.search(command)
            or FILE_REDIRECT.search(command)
            or (DIRECT_EXECUTOR.search(command) and not BOUNDARY.search(command))
        )
        if forbidden and not approved_boundary:
            fail(f"line {number} contains a mutator outside the approved init boundary")

    print(json.dumps({"valid": True, "completed_commands": commands}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
