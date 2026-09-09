#!/usr/bin/env python3
"""Create, verify, complete, and retire crash-recoverable eval publications."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import sys
from pathlib import Path


SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
SAFE_SUFFIX = re.compile(r"^[A-Za-z0-9.-]+$")
KINDS = {"eval_candidate", "eval_result"}


def die(message: str) -> None:
    print(f"publication-bundle: {message}", file=sys.stderr)
    raise SystemExit(2)


def regular_digest(path: Path) -> tuple[str, int]:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        die(f"unsafe non-regular artifact: {path}")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
        before.st_dev,
        before.st_ino,
    ):
        os.close(fd)
        die(f"artifact changed while opening: {path}")
    digest = hashlib.sha256()
    try:
        while chunk := os.read(fd, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    current = path.lstat()
    signature = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)
    if signature(before) != signature(opened) or signature(before) != signature(after) or signature(before) != signature(current):
        die(f"artifact changed while hashing: {path}")
    return digest.hexdigest(), before.st_size


def normalize_directory(path: str, *, required: bool = True) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute():
        die("publication directories must be absolute")
    if candidate.is_symlink() or (required and not candidate.is_dir()):
        die(f"publication directory is missing or unsafe: {candidate}")
    if not required and candidate.exists() and not candidate.is_dir():
        die(f"publication directory is missing or unsafe: {candidate}")
    return Path(os.path.realpath(candidate))


def create(argv: list[str]) -> None:
    if len(argv) < 6:
        die("create requires MANIFEST KIND BASE STAGE OUTPUT SUFFIX...")
    manifest, kind, base, stage_raw, output_raw, *suffixes = argv
    manifest_path = Path(manifest)
    if manifest_path.exists() or manifest_path.is_symlink():
        die("publication manifest destination already exists")
    if kind not in KINDS or not SAFE_NAME.fullmatch(base):
        die("publication identity is invalid")
    if not suffixes or suffixes[-1] != "json" or len(suffixes) != len(set(suffixes)):
        die("publication suffix set must be unique and end in json")
    if any(not SAFE_SUFFIX.fullmatch(suffix) for suffix in suffixes):
        die("publication suffix is unsafe")
    stage = normalize_directory(stage_raw)
    output = normalize_directory(output_raw)
    files = []
    for suffix in suffixes:
        source = stage / f"{base}.{suffix}"
        digest, size = regular_digest(source)
        files.append({"suffix": suffix, "sha256": digest, "size": size})
    record = {
        "schema_version": 1,
        "kind": kind,
        "base": base,
        "stage": str(stage).replace(os.sep, "/"),
        "output": str(output).replace(os.sep, "/"),
        "files": files,
    }
    payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode()
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
    fd = os.open(manifest_path, flags, 0o600)
    try:
        os.write(fd, payload)
        os.fsync(fd)
    finally:
        os.close(fd)


def load(manifest_raw: str) -> tuple[dict[str, object], Path, Path]:
    manifest = Path(manifest_raw)
    if manifest.is_symlink() or not manifest.is_file():
        die("publication manifest is missing or unsafe")
    raw = manifest.read_bytes()
    if not raw.endswith(b"\n") or b"\r" in raw or b"\x00" in raw:
        die("publication manifest transport is invalid")
    try:
        record = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"publication manifest is invalid JSON: {exc}")
    if not isinstance(record, dict) or set(record) != {
        "schema_version",
        "kind",
        "base",
        "stage",
        "output",
        "files",
    }:
        die("publication manifest shape is invalid")
    kind = record.get("kind")
    base = record.get("base")
    files = record.get("files")
    if record.get("schema_version") != 1 or kind not in KINDS or not isinstance(base, str) or not SAFE_NAME.fullmatch(base):
        die("publication manifest identity is invalid")
    if not isinstance(files, list) or not files:
        die("publication manifest file set is empty")
    suffixes: list[str] = []
    for item in files:
        if not isinstance(item, dict) or set(item) != {"suffix", "sha256", "size"}:
            die("publication manifest file record is invalid")
        suffix, digest, size = item["suffix"], item["sha256"], item["size"]
        if (
            not isinstance(suffix, str)
            or not SAFE_SUFFIX.fullmatch(suffix)
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or not isinstance(size, int)
            or size < 0
        ):
            die("publication manifest file metadata is invalid")
        suffixes.append(suffix)
    if len(suffixes) != len(set(suffixes)) or suffixes[-1] != "json":
        die("publication manifest suffix order is invalid")
    # A successful publisher retires staging before retiring this manifest.
    # Recovery must therefore accept an absent stage only when every bound
    # destination member is already complete; verify() enforces that below.
    stage = normalize_directory(str(record.get("stage", "")), required=False)
    output = normalize_directory(str(record.get("output", "")))
    return record, stage, output


def verify_member(path: Path, digest: str, size: int) -> None:
    actual_digest, actual_size = regular_digest(path)
    if actual_digest != digest or actual_size != size:
        die(f"published artifact does not match its manifest: {path}")


def verify(manifest: str, complete: bool) -> dict[str, object]:
    record, stage, output = load(manifest)
    base = str(record["base"])
    for item in record["files"]:  # type: ignore[index]
        suffix = str(item["suffix"])
        source = stage / f"{base}.{suffix}"
        destination = output / f"{base}.{suffix}"
        source_exists = source.exists() or source.is_symlink()
        destination_exists = destination.exists() or destination.is_symlink()
        if source_exists:
            verify_member(source, str(item["sha256"]), int(item["size"]))
        if destination_exists:
            verify_member(destination, str(item["sha256"]), int(item["size"]))
        if not source_exists and not destination_exists:
            die(f"publication artifact is absent from stage and output: {suffix}")
    if complete:
        ordered = [item for item in record["files"] if item["suffix"] != "json"]  # type: ignore[index]
        ordered += [item for item in record["files"] if item["suffix"] == "json"]  # type: ignore[index]
        for item in ordered:
            suffix = str(item["suffix"])
            source = stage / f"{base}.{suffix}"
            destination = output / f"{base}.{suffix}"
            if not (destination.exists() or destination.is_symlink()):
                verify_member(source, str(item["sha256"]), int(item["size"]))
                try:
                    os.link(source, destination)
                except FileExistsError:
                    pass
            verify_member(destination, str(item["sha256"]), int(item["size"]))
    print(json.dumps(record, sort_keys=True, separators=(",", ":")))
    return record


def remove_tree(argv: list[str]) -> None:
    if len(argv) != 3:
        die("remove-tree requires PATH PARENT PREFIX")
    path_raw, parent_raw, prefix = argv
    parent = normalize_directory(parent_raw)
    path = Path(path_raw)
    if path.is_symlink() or not path.is_dir():
        die("retired staging tree is missing or unsafe")
    resolved = Path(os.path.realpath(path))
    if resolved.parent != parent or not resolved.name.startswith(prefix):
        die("retired staging tree is outside the exact publication parent")
    for root, directories, files in os.walk(resolved, followlinks=False):
        for name in directories + files:
            if (Path(root) / name).is_symlink():
                die("retired staging tree contains a symlink")
    shutil.rmtree(resolved)


def main() -> None:
    if len(sys.argv) < 3:
        die("usage: publication-bundle.py create|verify|recover|remove-tree ...")
    command, args = sys.argv[1], sys.argv[2:]
    if command == "create":
        create(args)
    elif command == "verify" and len(args) == 1:
        verify(args[0], False)
    elif command == "recover" and len(args) == 1:
        verify(args[0], True)
    elif command == "remove-tree":
        remove_tree(args)
    else:
        die("invalid publication-bundle command")


if __name__ == "__main__":
    main()
