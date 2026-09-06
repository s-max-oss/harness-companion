#!/usr/bin/env python3
"""Validate Codex's structured command display against one exact probe argv."""

from __future__ import annotations

import ntpath
import base64
import binascii
import shlex
import sys


def fail(message: str) -> "NoReturn":
    print(f"probe-command: {message}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 4:
    fail("expected RECORDED_B64 EXPECTED_B64 WRAPPER")

recorded_b64, expected_b64, wrapper = sys.argv[1:]
if not recorded_b64 or not expected_b64 or not wrapper:
    fail("arguments must be non-empty")
try:
    recorded = base64.b64decode(recorded_b64, validate=True).decode("utf-8")
    expected = base64.b64decode(expected_b64, validate=True).decode("utf-8")
except (binascii.Error, UnicodeDecodeError):
    fail("command arguments were not canonical UTF-8 base64")
if any(ch in recorded for ch in "\x00\r\n"):
    fail("recorded command contains a forbidden control character")
if any(ch in expected for ch in "\x00\r\n"):
    fail("expected command contains a forbidden control character")

try:
    argv = shlex.split(recorded, comments=False, posix=True)
except ValueError:
    fail("recorded command is not valid shell-quoted argv")

allowed = (
    [wrapper, "-Command", expected],
    [wrapper, "-NoProfile", "-Command", expected],
)


def canonical_windows_path(path: str) -> str:
    return ntpath.normcase(ntpath.normpath(path))


if len(argv) not in (3, 4):
    fail("recorded command did not contain the exact wrapper argv shape")
if canonical_windows_path(argv[0]) != canonical_windows_path(wrapper):
    fail("recorded command used an unexpected wrapper executable")
argv[0] = wrapper
if argv not in allowed:
    fail("recorded command did not contain the exact probe command")
