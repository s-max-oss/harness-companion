#!/usr/bin/env python3
"""Validate Codex's structured command display against approved exact argv forms."""

from __future__ import annotations

import base64
import binascii
import json
import re
import sys


VARIANT_ARGUMENTS = {
    "powershell-command-v1": ("-Command",),
    "powershell-no-profile-command-v1": ("-NoProfile", "-Command"),
}


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


def decode_variants(value: str) -> list[str]:
    raw = decode_canonical(value, "allowed variants")
    try:
        variants = json.loads(raw)
    except json.JSONDecodeError:
        fail("allowed variants were not valid JSON")
    if not isinstance(variants, list) or not variants:
        fail("allowed variants must be a non-empty JSON array")
    if any(not isinstance(variant, str) for variant in variants):
        fail("allowed variants must contain only strings")
    if len(set(variants)) != len(variants):
        fail("allowed variants must not contain duplicates")
    if any(variant not in VARIANT_ARGUMENTS for variant in variants):
        fail("allowed variants contain an unknown serializer")
    return variants


def canonical_display(wrapper: str, expected: str, variant: str) -> str:
    # Codex 0.152.1 has emitted two exact Windows structured-event forms for
    # the same non-login shell request.  The caller supplies a versioned,
    # build-bound closed set and this function still performs byte-for-byte
    # matching; it never accepts a shell-equivalent free-form serialization.
    if variant not in VARIANT_ARGUMENTS:
        fail("unknown command serializer variant")
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
    wrapper_args = " ".join(VARIANT_ARGUMENTS[variant])
    return f"{wrapper_display} {wrapper_args} {command_display}"


def canonical_windows_path(value: str, label: str) -> str:
    if any(ch in value for ch in "\x00\r\n\""):
        fail(f"{label} contains a forbidden byte")
    if not value.isascii():
        fail(f"{label} must be ASCII")
    if len(value) < 3 or value[1:3] != ":\\":
        fail(f"{label} is not an absolute Windows drive path")
    ascii_lower = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
    return value.replace("\\", "/").rstrip("/").translate(ascii_lower)


def validate_probe_script_path(controller_file: str, script_path: str) -> None:
    """Accept only the controller-created canonical run root and exact sibling probe."""
    for value, label in ((controller_file, "controller path"), (script_path, "probe script path")):
        if not value.isascii():
            fail(f"{label} must be ASCII")
        if any(ch in value for ch in "\x00\r\n'\"`$"):
            fail(f"{label} contains a forbidden byte")

    controller_match = re.fullmatch(
        r"C:\\Users\\Public\\harness-companion-eval\\runs\\run\.([0-9a-f]{64})"
        r"\\controller\\runtime\.manifest",
        controller_file,
    )
    if controller_match is None:
        fail("controller path is outside the canonical isolated-run grammar")

    expected_script = (
        "C:\\Users\\Public\\harness-companion-eval\\runs\\run."
        f"{controller_match.group(1)}\\agent-bin\\isolation-probe.ps1"
    )
    if script_path != expected_script:
        fail("probe script is not the exact canonical sibling of the controller")


if len(sys.argv) == 4 and sys.argv[1] == "--same-windows-path":
    left = canonical_windows_path(sys.argv[2], "left path")
    right = canonical_windows_path(sys.argv[3], "right path")
    if left != right:
        fail("Windows paths do not identify the same canonical path")
    raise SystemExit(0)


if len(sys.argv) == 4 and sys.argv[1] == "--probe-script-path":
    validate_probe_script_path(sys.argv[2], sys.argv[3])
    raise SystemExit(0)


if len(sys.argv) == 5 and sys.argv[1] == "--canonical":
    variant = sys.argv[2]
    expected = decode_canonical(sys.argv[3], "expected command")
    wrapper = sys.argv[4]
    print(canonical_display(wrapper, expected, variant), end="")
    raise SystemExit(0)

if len(sys.argv) != 6 or sys.argv[1] != "--identify":
    fail("expected a supported probe-command validation mode")

recorded_b64, expected_b64, wrapper, variants_b64 = sys.argv[2:]
if not recorded_b64 or not expected_b64 or not wrapper or not variants_b64:
    fail("arguments must be non-empty")
recorded = decode_canonical(recorded_b64, "recorded command")
expected = decode_canonical(expected_b64, "expected command")
matches = [
    variant
    for variant in decode_variants(variants_b64)
    if recorded == canonical_display(wrapper, expected, variant)
]
if len(matches) != 1:
    fail("recorded command was not one exact approved non-login probe argv")
print(matches[0], end="")
