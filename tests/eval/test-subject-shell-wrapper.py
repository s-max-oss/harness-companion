#!/usr/bin/env python3
"""Focused, non-executing regressions for subject shell command validation."""

import contextlib
import io
from pathlib import Path
import runpy
import shlex
import unittest


VALIDATOR = runpy.run_path(str(Path(__file__).with_name("validate-subject-events.py")))
RUN_ROOT = "c:/users/public/harness-companion-eval/runs/run." + "a" * 64
AUTHORITY = {
    "wrapper": "c:/windows/system32/windowspowershell/v1.0/powershell.exe",
    "boundary": RUN_ROOT + "/skill-authority/scripts/harness-init-boundary.sh",
    "target": RUN_ROOT + "/project",
}
BASH = "C:/Program Files/Git/bin/bash.exe"


def wrapped(source, executable=BASH, option="-c"):
    return f'"{executable}" {option} {shlex.quote(source)}'


class SubjectShellWrapperTests(unittest.TestCase):
    def validate(self, command):
        kind, source = VALIDATOR["decode_command"](command, AUTHORITY)
        self.assertEqual(kind, "shell")
        return VALIDATOR["validate_direct_shell"](source, AUTHORITY)

    def assert_rejected(self, command):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            self.validate(command)
        self.assertEqual(raised.exception.code, 1)

    def test_observed_native_windows_wrapper(self):
        # Codex's direct shell transport doubles Windows path separators.
        command = (
            r'"C:\\Program Files\\Git\\bin\\bash.exe" -c '
            '"cat \'/c/Users/Public/harness-companion-eval/runs/run.'
            + "a" * 64 + "/skill-authority/SKILL.md'\""
        )
        self.assertIsNone(self.validate(command))

    def test_static_read_commands(self):
        for source in ("cat 'README with spaces.md'", "pwd", "ls -a", "rg pattern README.md",
                       "git --no-optional-locks status --short"):
            with self.subTest(source=source):
                self.assertIsNone(self.validate(wrapped(source)))

    def test_bare_bash_resolves_only_through_existing_sanitized_path_policy(self):
        self.assertIsNone(self.validate(wrapped("cat README.md", "bash")))

    def test_quoted_expansion_characters_are_literal(self):
        for source in ("jq '{name: .name}' package.json", "rg '[a-z]*' README.md",
                       'cat "README{1,2}.md"', r"cat README\{1,2\}.md"):
            with self.subTest(source=source):
                self.assertIsNone(self.validate(wrapped(source)))

    def test_quoted_composition_characters_are_literal(self):
        for source in ("rg '|&' README.md", r"rg \|\& README.md", "rg 'a;b' README.md"):
            with self.subTest(source=source):
                self.assertIsNone(self.validate(wrapped(source)))

    def test_quoted_comment_characters_are_literal(self):
        for source in ("rg '# heading' README.md", r"cat README\#.md"):
            with self.subTest(source=source):
                self.assertIsNone(self.validate(wrapped(source)))

    def test_arbitrary_wrapper_path_is_rejected(self):
        for executable in ("C:/tmp/bash.exe", "./bash", "C:/Program Files/Git/bin/../bin/bash.exe"):
            with self.subTest(executable=executable):
                self.assert_rejected(wrapped("cat README.md", executable))

    def test_unrecognized_shell_modes_and_extra_arguments_are_rejected(self):
        for command in (wrapped("cat README.md", option="-lc"),
                        wrapped("cat README.md") + " ignored",
                        f'"{BASH}" script.sh', f'"{BASH}" --rcfile evil -c "cat README.md"'):
            with self.subTest(command=command):
                self.assert_rejected(command)

    def test_writes_and_shell_composition_are_rejected(self):
        for source in ("touch marker", "cat README.md > marker", "cat < README.md",
                       "cat README.md; touch marker", "cat README.md && touch marker",
                       "cat README.md | tee marker", "cat README.md &",
                       "cat README.md |& tee marker",
                       "cat README#; touch marker", "rg pattern# --pre=evil README.md",
                       "git diff # --no-ext-diff --no-textconv",
                       "git show HEAD # --no-ext-diff --no-textconv",
                       "cat README.md\ntouch marker", "cat README.md\rtouch marker",
                       "cat $(touch marker)", "cat `touch marker`", "cat $INPUT",
                       "BASH_ENV=evil cat README.md", "bash -c 'cat README.md'",
                       "rg --pre=evil pattern README.md", "git diff --output=marker",
                       "rg --p{r,r}e=./evil pattern README.md",
                       "rg --pr?=evil pattern README.md", "rg --p[r]e=evil pattern README.md",
                       "git diff --no-ext-diff --no-textconv --out*", "cat ~/README.md",
                       "git status --short"):
            with self.subTest(source=source):
                self.assert_rejected(wrapped(source))

    def test_environment_injection_before_wrapper_is_rejected(self):
        self.assert_rejected("BASH_ENV=evil " + wrapped("cat README.md"))

    def test_path_selected_inner_program_is_rejected(self):
        for source in ("./cat README.md", "C:/tmp/rg README.md", "./git --no-optional-locks status"):
            with self.subTest(source=source):
                self.assert_rejected(wrapped(source))
                self.assert_rejected(source)

    def test_wrapper_cannot_hide_executor_mutations(self):
        self.assert_rejected(wrapped(f"bash {AUTHORITY['boundary']} {AUTHORITY['target']} --decision approve"))
        self.assert_rejected(wrapped(f"bash {RUN_ROOT}/skill-authority/scripts/harness-init.sh --apply"))

    def test_existing_exact_approved_boundary_is_unchanged(self):
        command = f"printf %s $BRIEF | bash {AUTHORITY['boundary']} {AUTHORITY['target']} --decision approve --brief-stdin --non-interactive --host=codex"
        self.assertEqual(self.validate(command)["mode"], "fresh")
        self.assert_rejected(command + " --force-config")


if __name__ == "__main__":
    unittest.main()
