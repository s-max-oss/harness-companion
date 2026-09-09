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
BOUNDARY_INVOKE = re.compile(
    r"(?i)\bbash(?:\.exe)?\s+['\"]?\S*(?:^|[\\/])harness-init-boundary\.sh\b"
)
APPROVE = re.compile(r"(?i)--decision(?:=|\s+)approve\b")
DIRECT_EXECUTOR = re.compile(r"(?i)(?:^|[\\/])harness-init\.sh\b")
POWERSHELL_LAUNCH = re.compile(
    r"(?is)^\s*\"?[^\"\r\n]*powershell(?:\.exe)?\"?\s+-NoProfile\s+-Command\s+['\"]*"
)
SAFE_VARIABLE = re.compile(r"^\$[A-Za-z_][A-Za-z0-9_]*$")
SAFE_PRINTF = re.compile(
    r"(?is)^printf\s+%s\s+\$[A-Za-z_][A-Za-z0-9_]*$"
)
MUTATING_ITEM_TYPES = {"file_change"}
# File redirection is a write even when the resulting file is removed before
# the next tree snapshot.  Exclude descriptor-to-descriptor forms such as
# ``2>&1``, which do not create or replace a filesystem object.
FILE_REDIRECT = re.compile(r">{1,2}(?!&)\s*")


def fail(message: str) -> None:
    print(f"subject-event-validator: {message}", file=sys.stderr)
    raise SystemExit(1)


def _clean_shell_quotes(value: str) -> str:
    """Remove quote-only transport noise from a simple command fragment."""

    return value.replace("'", "").replace('"', "").strip()


def _boundary_pipeline_is_exact(fragment: str, variable: str | None = None) -> bool:
    """Accept one data-only producer piped to one approved init boundary."""

    if fragment.count("|") != 1 or any(token in fragment for token in (";", "&&", "||", "\n", "\r")):
        return False
    producer_raw, invocation_raw = (part.strip() for part in fragment.split("|", 1))
    producer = _clean_shell_quotes(producer_raw)
    invocation = _clean_shell_quotes(invocation_raw)
    if variable is not None:
        if producer != f"${variable}":
            return False
    elif not (SAFE_VARIABLE.fullmatch(producer) or SAFE_PRINTF.fullmatch(producer)):
        json_start = producer_raw.find("{")
        json_end = producer_raw.rfind("}")
        if json_start < 0 or json_end <= json_start:
            return False
        if _clean_shell_quotes(producer_raw[:json_start]) != "printf %s":
            return False
        if _clean_shell_quotes(producer_raw[json_end + 1 :]):
            return False
        try:
            brief = json.loads(producer_raw[json_start : json_end + 1].replace(r'\"', '"'))
        except json.JSONDecodeError:
            return False
        if not isinstance(brief, dict):
            return False

    tokens = invocation.split()
    if len(tokens) < 7 or tokens[0].lower() not in {"bash", "bash.exe"}:
        return False
    if not re.search(r"(?i)(?:^|[\\/])harness-init-boundary\.sh$", tokens[1]):
        return False
    if tokens[2].startswith("-"):
        return False
    try:
        decision_index = tokens.index("--decision")
    except ValueError:
        decision_index = -1
    decision_ok = (
        decision_index >= 0
        and decision_index + 1 < len(tokens)
        and tokens[decision_index + 1].lower() == "approve"
    ) or any(token.lower() == "--decision=approve" for token in tokens)
    return (
        decision_ok
        and "--brief-stdin" in tokens
        and "--non-interactive" in tokens
        and any(token.lower() in {"--host=claude", "--host=codex"} for token in tokens)
        and not FILE_REDIRECT.search(invocation)
        and not DIRECT_EXECUTOR.search(invocation)
        and len(BOUNDARY.findall(invocation)) == 1
    )


def approved_boundary_command(command: str) -> bool:
    """Recognize only the documented stdin-to-boundary command shapes."""

    if len(BOUNDARY.findall(command)) != 1 or len(APPROVE.findall(command)) != 1:
        return False
    if FILE_REDIRECT.search(command) or DIRECT_EXECUTOR.search(command):
        return False

    # Direct POSIX form from SKILL.md: printf %s "$BRIEF" | bash ...
    if _boundary_pipeline_is_exact(command):
        return True

    # A Windows Codex command may wrap that same exact pipeline in PowerShell.
    powershell = POWERSHELL_LAUNCH.match(command)
    if powershell and _boundary_pipeline_is_exact(command[powershell.end() :]):
        return True

    # Codex on Windows wraps the same pipeline in PowerShell and assigns the
    # complete Brief JSON to one local scalar first.  Parse that scalar as JSON
    # so the assignment cannot hide command substitution or another statement.
    assignment = re.search(r"\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*", command)
    boundary_match = BOUNDARY.search(command)
    if not assignment or not boundary_match or assignment.start() >= boundary_match.start():
        return False
    if not POWERSHELL_LAUNCH.fullmatch(command[: assignment.start()]):
        return False
    separator = command.rfind(";", assignment.end(), boundary_match.start())
    if separator < 0:
        return False
    assigned = command[assignment.end() : separator]
    json_start = assigned.find("{")
    json_end = assigned.rfind("}")
    if json_start < 0 or json_end <= json_start:
        return False
    if _clean_shell_quotes(assigned[:json_start]) or _clean_shell_quotes(assigned[json_end + 1 :]):
        return False
    try:
        brief = json.loads(assigned[json_start : json_end + 1].replace(r'\"', '"'))
    except json.JSONDecodeError:
        return False
    if not isinstance(brief, dict):
        return False
    without_brief = command[assignment.end() : json_start] + command[json_end + 1 : separator]
    if ";" in without_brief or "$(" in without_brief or "`" in without_brief:
        return False
    return _boundary_pipeline_is_exact(command[separator + 1 :], assignment.group(1))


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
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type in MUTATING_ITEM_TYPES:
            fail(f"line {number} contains prohibited {item_type} mutation evidence")
        if item_type != "command_execution":
            continue
        if event.get("type") != "item.completed":
            continue
        command = item.get("command")
        if not isinstance(command, str) or not command.strip():
            fail(f"line {number} has an invalid command")
        commands += 1
        has_boundary = bool(BOUNDARY_INVOKE.search(command))
        if has_boundary:
            if not approved_boundary_command(command):
                fail(f"line {number} is not an exact approved init boundary invocation")
            continue
        forbidden = bool(
            MUTATORS.search(command)
            or FILE_REDIRECT.search(command)
            or DIRECT_EXECUTOR.search(command)
        )
        if forbidden:
            fail(f"line {number} contains a mutator outside the approved init boundary")

    print(json.dumps({"valid": True, "completed_commands": commands}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
