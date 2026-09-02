#!/usr/bin/env python3
"""Atomically publish files without ever replacing an existing destination.

Every source must be on the same filesystem as its destination.  The caller
publishes the authoritative result last, so a partial companion publication is
never accepted as a complete result.
"""

from __future__ import annotations

import os
import sys


def main() -> int:
    if len(sys.argv) < 3 or len(sys.argv[1:]) % 2:
        print("usage: publish-no-replace.py SRC DST [SRC DST ...]", file=sys.stderr)
        return 2

    pairs = list(zip(sys.argv[1::2], sys.argv[2::2]))
    for source, destination in pairs:
        if not os.path.isfile(source) or os.path.islink(source):
            print(f"unsafe publication source: {source}", file=sys.stderr)
            return 2
        try:
            os.link(source, destination)
        except FileExistsError:
            print(f"publication destination already exists: {destination}", file=sys.stderr)
            return 73
        except OSError as exc:
            print(f"publication failed for {destination}: {exc}", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
