#!/usr/bin/env python3
"""Validate Codex's structured command display against one exact probe argv."""

from __future__ import annotations

import base64
import binascii
import sys


def fail(message: str) -> "NoReturn":
    print(f"probe-command: {message}", file=sys.stderr)
    raise SystemExit(1)


def decode_canonical(value: str, label: str) -> str:
    try:
        raw = base64.b64decode(value, validate=True)
    except binascii.Error:
        fail(f"{label} was not valid base64")
    if base64.b64encode(raw).decode("ascii") != value:
        fail(f"{label} was not canonical base64")
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail(f"{label} was not canonical UTF-8")
    if any(ch in decoded for ch in "\x00\r\n"):
        fail(f"{label} contains a forbidden control character")
    return decoded


def canonical_display(wrapper: str, expected: str) -> str:
    # Codex 0.152.1 emits Windows command events using this exact display form:
    # a double-quoted, backslash-escaped executable followed by the mandatory
    # profile-free PowerShell argv.  The controller-generated probe has one or
    # more single quotes, no double quote/backtick, and no expansion-capable
    # token after its first single quote.  Constrain that grammar instead of
    # accepting a shell-equivalent alternate serialization.
    if any(ch in wrapper for ch in "\x00\r\n\""):
        fail("wrapper path cannot be represented canonically")
    if len(wrapper) < 3 or wrapper[1:3] != ":\\":
        fail("wrapper must be an absolute Windows drive path")
    if any(ch in expected for ch in "\x00\r\n\"`"):
        fail("expected command cannot be represented canonically")
    first_quote = expected.find("'")
    if first_quote < 0:
        fail("expected command is outside the controller probe grammar")
    prefix = expected[:first_quote]
    suffix = expected[first_quote:]
    if "$" in suffix:
        fail("expected command has expansion-capable text after quote switch")

    escape_path = lambda value: value.replace("\\", "\\\\")
    wrapper_display = f'"{escape_path(wrapper)}"'
    command_display = f"'{escape_path(prefix)}'\"{escape_path(suffix)}\""
    return f"{wrapper_display} -NoProfile -Command {command_display}"


def canonical_windows_path(value: str, label: str) -> str:
    if any(ch in value for ch in "\x00\r\n\""):
        fail(f"{label} contains a forbidden byte")
    if len(value) < 3 or value[1:3] != ":\\":
        fail(f"{label} is not an absolute Windows drive path")
    return value.replace("\\", "/").rstrip("/").casefold()


if len(sys.argv) == 4 and sys.argv[1] == "--same-windows-path":
    left = canonical_windows_path(sys.argv[2], "left path")
    right = canonical_windows_path(sys.argv[3], "right path")
    if left != right:
        fail("Windows paths do not identify the same canonical path")
    raise SystemExit(0)


if len(sys.argv) == 4 and sys.argv[1] == "--canonical":
    expected = decode_canonical(sys.argv[2], "expected command")
    wrapper = sys.argv[3]
    print(canonical_display(wrapper, expected), end="")
    raise SystemExit(0)

if len(sys.argv) != 4:
    fail("expected RECORDED_B64 EXPECTED_B64 WRAPPER")

recorded_b64, expected_b64, wrapper = sys.argv[1:]
if not recorded_b64 or not expected_b64 or not wrapper:
    fail("arguments must be non-empty")
recorded = decode_canonical(recorded_b64, "recorded command")
expected = decode_canonical(expected_b64, "expected command")
if recorded != canonical_display(wrapper, expected):
    fail("recorded command was not the exact canonical profile-free probe argv")
