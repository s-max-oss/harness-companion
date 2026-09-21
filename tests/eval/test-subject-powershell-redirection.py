#!/usr/bin/env python3
"""Parse-only regressions: null stderr sinks must not admit filesystem writes."""

import contextlib
import io
from pathlib import Path
import runpy
import unittest


VALIDATOR = runpy.run_path(str(Path(__file__).with_name("validate-subject-events.py")))
RUN_ROOT = "c:/users/public/harness-companion-eval/runs/run." + "a" * 64
AUTHORITY = {
    "wrapper": "c:/windows/system32/windowspowershell/v1.0/powershell.exe",
    "boundary": RUN_ROOT + "/skill-authority/scripts/harness-init-boundary.sh",
    "brief_validator": RUN_ROOT + "/skill-authority/scripts/harness-init.sh",
    "target": RUN_ROOT + "/project",
}


@unittest.skipUnless(Path(VALIDATOR["powershell_executable"]()).is_file(),
                     "requires the trusted Windows PowerShell AST parser")
class SubjectPowerShellRedirectionTests(unittest.TestCase):
    def check_sources(self, sources, accepted):
        # ParseInput only: none of these commands, even negative cases, execute.
        analyses = VALIDATOR["analyze_powershell"](sources)
        for source, analysis in zip(sources, analyses):
            with self.subTest(source=source):
                if accepted:
                    self.assertIsNone(VALIDATOR["validate_powershell"](
                        analysis, source, AUTHORITY))
                else:
                    with contextlib.redirect_stderr(io.StringIO()), \
                            self.assertRaises(SystemExit) as raised:
                        VALIDATOR["validate_powershell"](analysis, source, AUTHORITY)
                    self.assertEqual(raised.exception.code, 1)

    def test_observed_readonly_error_suppression(self):
        self.check_sources([
            "Get-ChildItem -Force -Name AGENTS.md,CLAUDE.md,feature_list.json,init.sh,.harness 2>$null",
            "Get-Content -LiteralPath 'missing.md' 2> $NULL",
            "Get-ChildItem 2>${null} | Select-Object Name",
            "Get-Content missing.md 2>$null; Get-ChildItem 2>$null",
            "Get-Content missing.md -ErrorAction SilentlyContinue",
        ], True)

    def test_file_dynamic_scoped_and_other_stream_redirects_stay_denied(self):
        self.check_sources([
            "Get-Content README.md 2> marker",
            "Get-Content README.md 2>> marker",
            "Get-Content README.md > marker 2>$null",
            "Get-Content README.md 2>'$null'",
            'Get-Content README.md 2>"$null"',
            "Get-Content README.md 2>nul",
            "Get-Content README.md 2>$sink",
            "Get-Content README.md 2>$env:NULL",
            "Get-Content README.md 2>$global:null",
            "Get-Content README.md 2>($null)",
            "Get-Content README.md 2>>$null",
            "Get-Content README.md >$null",
            "Get-Content README.md *>$null",
            "Get-Content README.md 2>&1",
            "Get-Content README.md 2>$(Set-Content marker data)",
        ], False)

    def test_null_sink_cannot_hide_other_side_effects(self):
        self.check_sources([
            "Set-Content marker data 2>$null",
            "Get-ChildItem 2>$null; Set-Content marker data",
            "Get-ChildItem 2>$null; $env:FLAG='changed'",
            "Get-ChildItem 2>$null; [IO.File]::WriteAllText('marker','data')",
            "Get-ChildItem $(Set-Content marker data) 2>$null",
            "Get-ChildItem -ErrorVariable errors 2>$null",
            "Get-ChildItem 2>$null | Tee-Object marker",
            "rg --pre=evil pattern README.md 2>$null",
            "& './Get-ChildItem.ps1' 2>$null",
            "Get-Content README.md > marker # 2>$null",
        ], False)


if __name__ == "__main__":
    unittest.main()
