#!/usr/bin/env python3
"""Exercise the production recovery suffix loop with LF and native jq CRLF."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest


RECOVERY = Path(__file__).with_name("recover-windows-isolation.sh")
BASE = "brief-rejection.1.20260921T072113Z-477-27153"
SUFFIXES = (
    "transcript.jsonl", "tree.sha256", "subject-events.jsonl",
    "reviewer-events.jsonl", "turn-trees.jsonl", "evaluator-events.jsonl",
    "reviewer-output.json", "objective-checks.jsonl", "project-brief.json",
    "isolation.json", "json",
)
BASH = (r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt"
        else shutil.which("bash"))


class RecoveryPublicationPathsTests(unittest.TestCase):
    def production_paths(self, line_ending):
        # Execute the real loop, not a duplicate implementation. Only jq's
        # transport is stubbed; the verified publication suffix set is fixed.
        source = RECOVERY.read_text(encoding="utf-8")
        loops = re.findall(
            r"publication_rels=\(\)\n.*?done < <\(jq [^\n]+\)\n",
            source, re.DOTALL,
        )
        self.assertEqual(len(loops), 1, "identify exactly one production suffix loop")
        script = (
            "set -euo pipefail\n"
            + "publication_base=" + BASE + "\npublication_record=verified\n"
            + "jq() { printf '%s" + line_ending + "' "
            + " ".join("'" + suffix + "'" for suffix in SUFFIXES) + "; }\n"
            + loops[0]
            + "printf '%s\\0' \"${publication_rels[@]}\"\n"
        )
        completed = subprocess.run([BASH, "--noprofile", "--norc", "-c", script],
                                   capture_output=True, timeout=30, check=True)
        self.assertTrue(completed.stdout.endswith(b"\0"))
        return completed.stdout[:-1].decode("utf-8").split("\0")

    def test_lf_suffixes(self):
        self.assertEqual(self.production_paths(r"\n"),
                         [f"tests/eval/candidates/{BASE}.{s}" for s in SUFFIXES])

    def test_native_jq_crlf_suffixes(self):
        self.assertEqual(self.production_paths(r"\r\n"),
                         [f"tests/eval/candidates/{BASE}.{s}" for s in SUFFIXES])


if __name__ == "__main__":
    unittest.main()
