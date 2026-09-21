#!/usr/bin/env python3
"""Exercise the runner's actual Codex text extractor without an Agent or files."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest


RUNNER = Path(__file__).with_name("run-eval.sh")
BASH = (r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt"
        else shutil.which("bash"))


def message(text):
    return {"type": "item.completed",
            "item": {"type": "agent_message", "text": text}}


class CodexTextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = RUNNER.read_text(encoding="utf-8")
        matches = re.findall(r"^codex_text\(\) \{(?:[^\n]*\}$|.*?^\})", source,
                             re.MULTILINE | re.DOTALL)
        if len(matches) != 1:
            raise AssertionError("identify exactly one production extractor")
        cls.function = matches[0]
        guards = re.findall(
            r'^  \[ "\$rc" -eq 0 \].*?\|\| return 1$', source, re.MULTILINE)
        if len(guards) != 1:
            raise AssertionError("identify the actual subject success guard")
        cls.guard = guards[0]

    def extract(self, events, *, cli_rc=None, session="test-session"):
        script = "set -euo pipefail\n" + self.function + "\n"
        if cli_rc is None:
            script += "codex_text -\n"
        else:
            script += (
                "accept_turn() {\n"
                "output=$(codex_text -) || return 1\n"
                'rc="$1"; session="$2"\n' + self.guard + "\n}\n"
                'accept_turn "$1" "$2"\n'
            )
        payload = (events if isinstance(events, str) else
                   "\n".join(json.dumps(event) for event in events) + "\n")
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c", script, "extractor-test",
             str(cli_rc), session], input=payload.encode("utf-8"),
            capture_output=True, timeout=30,
        )

    def assert_text(self, events, expected):
        result = self.extract(events)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8"))
        self.assertEqual(result.stdout.decode("utf-8").replace("\r\n", "\n"),
                         expected + "\n")

    def test_trailing_empty_messages_do_not_erase_answer(self):
        events = [message("Progress"), message("Initialization is complete."),
                  message(""), message(" \t\r\n"), {"type": "turn.completed"}]
        self.assert_text(events, "Initialization is complete.")
        self.assertEqual(self.extract(events, cli_rc=0).returncode, 0)

    def test_only_last_nonblank_completed_answer_is_used(self):
        self.assert_text([message("old"), message("  final answer  "),
                          {"type": "item.started", "item": {
                              "type": "agent_message", "text": "unfinished"}}],
                         "  final answer  ")

    def test_tool_output_is_not_an_answer(self):
        events = [{"type": "item.completed", "item": {
            "type": "command_execution", "text": "not an answer",
            "aggregated_output": "tool output", "exit_code": 0}}]
        self.assert_text(events, "")
        self.assertNotEqual(self.extract(events, cli_rc=0).returncode, 0)

    def test_empty_or_blank_only_output_still_fails(self):
        for events in ([], [message("")], [message(" \t\r\n")]):
            with self.subTest(events=events):
                self.assert_text(events, "")
                self.assertNotEqual(self.extract(events, cli_rc=0).returncode, 0)

    def test_nonzero_cli_exit_or_missing_session_still_fails(self):
        events = [message("real answer"), message("")]
        for cli_rc, session in ((1, "test"), (124, "test"), (0, "")):
            with self.subTest(cli_rc=cli_rc, session=session):
                self.assertNotEqual(self.extract(
                    events, cli_rc=cli_rc, session=session).returncode, 0)

    def test_malformed_message_does_not_fall_back_to_earlier_answer(self):
        for value in (None, False, 1, [], {}):
            with self.subTest(value=value):
                self.assertNotEqual(self.extract(
                    [message("old"), message(value)]).returncode, 0)
        self.assertNotEqual(self.extract([message("old"), {
            "type": "item.completed", "item": {"type": "agent_message"}
        }]).returncode, 0)

    def test_invalid_json_fails(self):
        self.assertNotEqual(self.extract('{"type":').returncode, 0)

    def test_reviewer_json_is_preserved_without_merging_messages(self):
        verdict = '{"overall_pass":false,"reason":"failed assertion"}'
        self.assert_text([message('{"overall_pass":true}'),
                          message(verdict), message("")], verdict)


if __name__ == "__main__":
    unittest.main()
