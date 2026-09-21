#!/usr/bin/env python3
"""Prove that subject commands are read-only or use the exact init boundary."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path, PureWindowsPath


RUN_ROOT = re.compile(
    r"(?i)^c:/users/public/harness-companion-eval/runs/run\.[0-9a-f]{64}$"
)
BOUNDARY_TEXT = re.compile(r"(?i)(?:^|[\\/])harness-init-boundary\.sh\b")
MUTATING_ITEM_TYPES = {"file_change"}
READ_ONLY_POWERSHELL = {
    "compare-object",
    "convertfrom-json",
    "convertto-json",
    "format-list",
    "format-table",
    "get-childitem",
    "get-command",
    "get-content",
    "get-date",
    "get-filehash",
    "get-item",
    "get-location",
    "join-path",
    "out-null",
    "out-string",
    "resolve-path",
    "select-object",
    "select-string",
    "sort-object",
    "test-path",
    "where-object",
    "write-output",
}
READ_ONLY_NATIVE = {
    "cat",
    "grep",
    "head",
    "jq",
    "ls",
    "pwd",
    "rg",
    "sha256sum",
    "wc",
}
READ_ONLY_GIT = {"diff", "log", "ls-files", "ls-tree", "rev-parse", "show", "status"}
GIT_SIDE_EFFECT_FLAGS = {
    "--ext-diff",
    "--textconv",
    "--output",
    "-o",
}
POWERSHELL_PARAMETERS = {
    "compare-object": {"-referenceobject", "-differenceobject", "-syncwindow", "-property", "-excludedifferent", "-includeequal", "-passthru", "-culture", "-casesensitive"},
    "convertfrom-json": {"-inputobject", "-ashashtable", "-depth", "-noenumerate", "-datekind"},
    "convertto-json": {"-inputobject", "-depth", "-compress", "-enumsasstrings", "-escapehandling"},
    "format-list": {"-property", "-view", "-showerror", "-displayerror", "-force", "-groupby"},
    "format-table": {"-property", "-view", "-showerror", "-displayerror", "-force", "-groupby", "-autosize", "-hidetableheaders", "-wrap"},
    "get-childitem": {"-path", "-literalpath", "-filter", "-include", "-exclude", "-recurse", "-depth", "-force", "-name", "-attributes", "-directory", "-file", "-hidden", "-readonly", "-system"},
    "get-command": {"-name", "-verb", "-noun", "-module", "-commandtype", "-all", "-listimported", "-syntax", "-totalcount"},
    "get-content": {"-path", "-literalpath", "-readcount", "-totalcount", "-tail", "-raw", "-encoding", "-delimiter", "-wait", "-force", "-stream"},
    "get-date": {"-date", "-format", "-uformat", "-unixtimeseconds", "-asutc"},
    "get-filehash": {"-path", "-literalpath", "-algorithm", "-inputstream"},
    "get-item": {"-path", "-literalpath", "-force", "-stream"},
    "get-location": {"-psprovider", "-psdrive"},
    "join-path": {"-path", "-childpath", "-resolve", "-additionalchildpath"},
    "out-null": {"-inputobject"},
    "out-string": {"-inputobject", "-width", "-stream"},
    "resolve-path": {"-path", "-literalpath", "-relative", "-relativebasepath"},
    "select-object": {"-inputobject", "-property", "-excludeproperty", "-expandproperty", "-unique", "-last", "-first", "-skip", "-wait", "-skiplast", "-index"},
    "select-string": {"-pattern", "-path", "-literalpath", "-simplematch", "-casesensitive", "-quiet", "-list", "-include", "-exclude", "-notmatch", "-allmatches", "-encoding", "-context", "-raw", "-noemphasis"},
    "sort-object": {"-inputobject", "-property", "-descending", "-unique", "-culture", "-casesensitive", "-stable", "-top", "-bottom"},
    "test-path": {"-path", "-literalpath", "-pathtype", "-isvalid", "-olderthan", "-newerthan"},
    "where-object": {"-inputobject", "-filterScript", "-property", "-value", "-eq", "-ceq", "-ne", "-cne", "-gt", "-cgt", "-lt", "-clt", "-ge", "-cge", "-le", "-cle", "-like", "-clike", "-notlike", "-cnotlike", "-match", "-cmatch", "-notmatch", "-cnotmatch", "-contains", "-ccontains", "-notcontains", "-cnotcontains", "-in", "-cin", "-notin", "-cnotin", "-is", "-isnot"},
    "write-output": {"-inputobject", "-noenumerate"},
}
POWERSHELL_COMMON_PARAMETER_VALUES = {
    "-erroraction": {"continue", "ignore", "silentlycontinue", "stop"},
}


POWERSHELL_ANALYZER = r"""
$ErrorActionPreference = 'Stop'
$sources = [Console]::In.ReadToEnd() | ConvertFrom-Json
$results = @()
foreach ($source in $sources) {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput(
    [string]$source, [ref]$tokens, [ref]$errors
  )
  $commands = @()
  foreach ($command in $ast.FindAll({
      param($node) $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)) {
    $elements = @()
    foreach ($element in $command.CommandElements) {
      if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
          $element -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        $elements += [pscustomobject]@{text=[string]$element.Value; static=$true}
      } elseif ($element -is [System.Management.Automation.Language.ArrayLiteralAst] -and
          @($element.Elements | Where-Object {
            $_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $_ -isnot [System.Management.Automation.Language.ConstantExpressionAst]
          }).Count -eq 0) {
        $elements += [pscustomobject]@{text=[string]$element.Extent.Text; static=$true}
      } elseif ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
        $elements += [pscustomobject]@{text=[string]$element.Extent.Text; static=$true}
      } else {
        $elements += [pscustomobject]@{text=[string]$element.Extent.Text; static=$false}
      }
    }
    $hasPipelineInput = $false
    if ($command.Parent -is [System.Management.Automation.Language.PipelineAst]) {
      $pipeline = $command.Parent
      for ($index = 1; $index -lt $pipeline.PipelineElements.Count; $index++) {
        if ([object]::ReferenceEquals($pipeline.PipelineElements[$index], $command)) {
          $hasPipelineInput = $true
        }
      }
    }
    $commands += [pscustomobject]@{
      name=[string]$command.GetCommandName()
      invocation=[string]$command.InvocationOperator
      elements=$elements
      has_pipeline_input=$hasPipelineInput
    }
  }
  $results += [pscustomobject]@{
    parse_errors=@($errors | ForEach-Object { [string]$_.Message })
    redirections=@($ast.FindAll({
      param($node) $node -is [System.Management.Automation.Language.RedirectionAst]
    }, $true)).Count
    method_invocations=@($ast.FindAll({
      param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true)).Count
    function_definitions=@($ast.FindAll({
      param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)).Count
    assignments=@($ast.FindAll({
      param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true)).Count
    mutating_unary=@($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.UnaryExpressionAst] -and
        $node.TokenKind -in @('PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus')
    }, $true)).Count
    non_pipeline_statements=@($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.StatementAst] -and
        $node -isnot [System.Management.Automation.Language.PipelineAst] -and
        $node -isnot [System.Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetType().Name })
    commands=$commands
  }
}
$results | ConvertTo-Json -Depth 8 -Compress
"""


def fail(message: str) -> None:
    print(f"subject-event-validator: {message}", file=sys.stderr)
    raise SystemExit(1)


def normalize_windows_path(value: str) -> str:
    normalized = value.strip().strip("'\"").replace("\\", "/")
    while "//" in normalized:
        normalized = normalized.replace("//", "/")
    if re.match(r"^/[A-Za-z]/", normalized):
        normalized = normalized[1] + ":" + normalized[2:]
    return normalized.rstrip("/").casefold()


def basename(value: str) -> str:
    return PureWindowsPath(value.replace("/", "\\")).name.casefold()


def trusted_native_name(value: str, name: str) -> bool:
    """Return whether a native command resolves inside the trusted runtime."""

    if "/" not in value and "\\" not in value:
        return True
    normalized = normalize_windows_path(value)
    return name in {"bash", "bash.exe"} and normalized == "c:/program files/git/bin/bash.exe"


def require_trusted_native_name(value: str, name: str) -> None:
    """Reject path-selected binaries; bare names resolve only in the sanitized PATH."""

    if trusted_native_name(value, name):
        return
    fail("absolute native command is outside the trusted runtime")


def validate_git_args(args: list[str]) -> None:
    if not args:
        fail("git command is not in the read-only allowlist")
    lowered_all = [arg.casefold() for arg in args]
    if lowered_all[0] == "--no-optional-locks":
        lowered_all = lowered_all[1:]
        if not lowered_all or lowered_all[0] != "status":
            fail("git --no-optional-locks is permitted only for status")
    elif lowered_all[0] == "status":
        fail("git status must disable optional index locks")
    subcommand = lowered_all[0]
    if subcommand not in READ_ONLY_GIT:
        fail("git command is not in the read-only allowlist")
    lowered = lowered_all[1:]
    if any(
        arg in GIT_SIDE_EFFECT_FLAGS
        or arg.startswith("--output=")
        or arg.startswith("--ext-diff=")
        or arg.startswith("--textconv=")
        for arg in lowered
    ):
        fail("git read command requests output mutation or external execution")
    if subcommand in {"diff", "log", "show"} and not {
        "--no-ext-diff",
        "--no-textconv",
    }.issubset(set(lowered)):
        fail("git content inspection must explicitly disable external helpers")


def validate_native_args(name: str, args: list[str]) -> None:
    """Reject callback/output modes of otherwise read-only native tools."""

    lowered = [arg.casefold() for arg in args]
    if name == "git":
        validate_git_args(args)
        return
    if name == "jq" and any(arg in {"-i", "--in-place"} for arg in lowered):
        fail("jq command has an in-place action")
    if name == "rg" and any(
        arg in {"--pre", "--hostname-bin"}
        or arg.startswith("--pre=")
        or arg.startswith("--hostname-bin=")
        for arg in lowered
    ):
        fail("rg command requests external helper execution")


def validate_powershell_args(name: str, args: list[str]) -> None:
    allowed = {value.casefold() for value in POWERSHELL_PARAMETERS.get(name, set())}
    common = set(POWERSHELL_COMMON_PARAMETER_VALUES)
    index = 0
    while index < len(args):
        arg = args[index]
        if not arg.startswith("-"):
            index += 1
            continue
        parameter, separator, inline_value = arg.partition(":")
        parameter = parameter.casefold()
        if parameter not in allowed and parameter not in common:
            fail(f"PowerShell read command uses an unrecognized parameter: {arg}")
        if parameter in common:
            if separator:
                value = inline_value
            elif index + 1 < len(args) and not args[index + 1].startswith("-"):
                index += 1
                value = args[index]
            else:
                fail(f"PowerShell common parameter requires a value: {arg}")
            if value.casefold() not in POWERSHELL_COMMON_PARAMETER_VALUES[parameter]:
                fail(f"PowerShell common parameter uses an unsafe value: {arg} {value}")
        index += 1


def load_authority(isolation_path: Path) -> dict[str, str]:
    if not isolation_path.is_file() or isolation_path.is_symlink():
        fail("isolation evidence is missing or unsafe")
    try:
        evidence = json.loads(isolation_path.read_text(encoding="utf-8"))
        target_file = evidence["probe"]["payload"]["target_file"]
        wrapper = evidence["probe"]["shell_wrapper_path"]
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        fail(f"isolation evidence cannot bind command authority: {exc}")
    if not isinstance(target_file, str) or not isinstance(wrapper, str):
        fail("isolation command authority fields are invalid")
    target_norm = normalize_windows_path(target_file)
    sentinel = "/project/.harness-eval-isolation-sentinel"
    if not target_norm.endswith(sentinel):
        fail("isolation target sentinel is not authoritative")
    run_root = target_norm[: -len(sentinel)]
    if not RUN_ROOT.fullmatch(run_root):
        fail("isolation run root is not canonical")
    wrapper_norm = normalize_windows_path(wrapper)
    if wrapper_norm != "c:/windows/system32/windowspowershell/v1.0/powershell.exe":
        fail("isolation shell wrapper is not the trusted Windows PowerShell")
    return {
        "run_root": run_root,
        "target": f"{run_root}/project",
        "boundary": f"{run_root}/skill-authority/scripts/harness-init-boundary.sh",
        "brief_validator": f"{run_root}/skill-authority/scripts/harness-init.sh",
        "wrapper": wrapper_norm,
    }


def powershell_executable() -> str:
    root = os.environ.get("SystemRoot", r"C:\Windows")
    return str(Path(root) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")


def analyze_powershell(sources: list[str]) -> list[dict[str, object]]:
    if not sources:
        return []
    try:
        completed = subprocess.run(
            [
                powershell_executable(),
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                POWERSHELL_ANALYZER,
            ],
            input=json.dumps(sources, separators=(",", ":")),
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        fail(f"trusted PowerShell parser unavailable: {exc}")
    if completed.returncode != 0:
        fail("trusted PowerShell parser failed")
    try:
        parsed = json.loads(completed.stdout)
    except json.JSONDecodeError:
        fail("trusted PowerShell parser returned invalid output")
    if isinstance(parsed, dict):
        parsed = [parsed]
    if not isinstance(parsed, list) or len(parsed) != len(sources):
        fail("trusted PowerShell parser returned an incomplete analysis")
    return parsed


def decode_command(command: str, authority: dict[str, str]) -> tuple[str, str]:
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError as exc:
        fail(f"command transport is malformed: {exc}")
    if (
        len(tokens) == 4
        and tokens[1].casefold() == "-noprofile"
        and tokens[2].casefold() == "-command"
    ):
        if normalize_windows_path(tokens[0]) != authority["wrapper"]:
            fail("command used an untrusted PowerShell wrapper")
        return "powershell", tokens[3]
    if tokens and basename(tokens[0]) in READ_ONLY_POWERSHELL:
        return "powershell", command
    return "shell", command


def boundary_details_from_elements(
    elements: list[dict[str, object]], authority: dict[str, str], has_input: bool
) -> dict[str, str] | None:
    if len(elements) not in {8, 9, 11} or not has_input:
        return None
    values = [str(element.get("text", "")) for element in elements]
    if not all(bool(element.get("static")) for element in elements[1:]):
        return False
    prefix_ok = (
        basename(values[0]) in {"bash", "bash.exe"}
        and trusted_native_name(values[0], basename(values[0]))
        and normalize_windows_path(values[1]) == authority["boundary"]
        and normalize_windows_path(values[2]) == authority["target"]
        and values[3:7] == ["--decision", "approve", "--brief-stdin", "--non-interactive"]
        and values[7].casefold() in {"--host=claude", "--host=codex"}
    )
    if not prefix_ok:
        return None
    tail = values[8:]
    if tail == []:
        return {"mode": "fresh", "host": values[7].casefold(), "token": ""}
    if tail == ["--update"]:
        return {"mode": "update-plan", "host": values[7].casefold(), "token": ""}
    if (
        len(tail) == 3
        and tail[:2] == ["--update", "--apply"]
        and (
            re.fullmatch(r"--plan-token=[0-9a-f]{64}", tail[2]) is not None
            # Codex redacts secret-looking argv values in its JSONL event stream.
            # The completed boundary result below is therefore the authoritative
            # proof that the executor accepted the dry-run token in this case.
            or tail[2] == "--plan-token=[REDACTED_SECRET]"
        )
    ):
        return {
            "mode": "update-apply",
            "host": values[7].casefold(),
            "token": tail[2].split("=", 1)[1],
        }
    return None


def is_brief_preflight(
    elements: list[dict[str, object]], authority: dict[str, str], has_input: bool
) -> bool:
    """Admit only the authoritative, non-mutating Brief validation shape."""
    if len(elements) != 7 or not has_input:
        return False
    if not all(bool(element.get("static")) for element in elements):
        return False
    values = [str(element.get("text", "")) for element in elements]
    return (
        basename(values[0]) in {"bash", "bash.exe"}
        and trusted_native_name(values[0], basename(values[0]))
        and normalize_windows_path(values[1]) == authority["brief_validator"]
        and normalize_windows_path(values[2]) == authority["target"]
        and values[3:6]
        == ["--brief-stdin", "--validate-brief-only", "--non-interactive"]
        and values[6].casefold() in {"--host=claude", "--host=codex"}
    )


def validate_shell_script(source: str) -> None:
    if any(marker in source for marker in ("$", "`", ">", "<", "\x00", "\n", "\r")):
        fail("shell inspection uses expansion, substitution, redirection, or multiple lines")
    # shlex removes quotes but does not expand braces/globs. Reject expansions
    # before tokenization, where quote information is still available, so an
    # apparently safe argument cannot become a callback/output option in Bash.
    quote = ""
    escaped = False
    for char in source:
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote:
            if char == quote:
                quote = ""
        elif char in {"'", '"'}:
            quote = char
        elif char in "*?[]{}~":
            fail("shell inspection uses unquoted argument expansion")
        elif char in "|;&":
            fail("shell composition is not statically provable as read-only")
        elif char == "#":
            fail("shell inspection uses unquoted comment syntax")
    lexer = shlex.shlex(source, posix=True, punctuation_chars="|;&")
    lexer.whitespace_split = True
    # Unquoted comment syntax is rejected above. Keep quoted/escaped hashes
    # as literal argument text instead of letting shlex hide later arguments.
    lexer.commenters = ""
    try:
        tokens = list(lexer)
    except ValueError as exc:
        fail(f"shell inspection is malformed: {exc}")
    if not tokens:
        fail("empty shell inspection")
    name = basename(tokens[0])
    args = tokens[1:]
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[0]):
        fail("shell environment assignments are not permitted")
    if name not in READ_ONLY_NATIVE and name != "git":
        fail(f"shell command is not in the read-only allowlist: {name or '<dynamic>'}")
    require_trusted_native_name(tokens[0], name)
    validate_native_args(name, args)


def validate_native(
    command: dict[str, object], authority: dict[str, str]
) -> dict[str, str] | None:
    name_value = str(command.get("name", ""))
    name = basename(name_value)
    elements = command.get("elements")
    if not isinstance(elements, list) or not elements:
        fail("PowerShell command has invalid elements")
    if str(command.get("invocation", "")) not in {"Unknown", ""}:
        fail("PowerShell call or dot invocation is not permitted")
    boundary = boundary_details_from_elements(
        elements, authority, bool(command.get("has_pipeline_input"))
    )
    if boundary is not None:
        return boundary
    if is_brief_preflight(
        elements, authority, bool(command.get("has_pipeline_input"))
    ):
        return None
    if not all(bool(element.get("static")) for element in elements):
        fail("PowerShell command contains a dynamic command or argument")
    if name in {"bash", "bash.exe"}:
        require_trusted_native_name(name_value, name)
        values = [str(element.get("text", "")) for element in elements]
        if len(values) == 2 and values[1] == "--version":
            return None
        if len(values) == 3 and values[1] == "-lc":
            validate_shell_script(values[2])
            return None
        fail("bash command is not an exact read-only inspection or init boundary")
    values = [str(element.get("text", "")) for element in elements]
    args = values[1:]
    if name == "git":
        require_trusted_native_name(name_value, name)
        validate_native_args(name, args)
        return None
    if name in READ_ONLY_NATIVE:
        require_trusted_native_name(name_value, name)
        validate_native_args(name, args)
        return None
    if name in READ_ONLY_POWERSHELL:
        validate_powershell_args(name, args)
        return None
    fail(f"PowerShell command is not in the read-only allowlist: {name or '<dynamic>'}")


def validate_powershell(
    analysis: dict[str, object], source: str, authority: dict[str, str]
) -> dict[str, str] | None:
    if analysis.get("parse_errors"):
        fail("PowerShell inspection does not parse exactly")
    if any(
        int(analysis.get(field, 0))
        for field in (
            "redirections",
            "method_invocations",
            "function_definitions",
            "assignments",
            "mutating_unary",
        )
    ):
        fail("PowerShell inspection contains an unprovable side-effect construct")
    if analysis.get("non_pipeline_statements"):
        fail("PowerShell inspection contains a non-pipeline statement")
    commands = analysis.get("commands")
    if not isinstance(commands, list) or not commands:
        fail("PowerShell inspection contains no statically identifiable command")
    boundaries: list[tuple[int, dict[str, str]]] = []
    for command in commands:
        if not isinstance(command, dict):
            fail("PowerShell command analysis is invalid")
        boundary = validate_native(command, authority)
        if boundary is not None:
            boundaries.append((len(boundaries), boundary))
    if len(boundaries) > 1:
        fail("more than one init boundary invocation appears in one command")
    if not boundaries:
        return None
    if len(commands) != 2:
        fail("init boundary must have exactly one static stdin producer")
    producer = commands[0]
    boundary_command = commands[1]
    if not isinstance(producer, dict) or not isinstance(boundary_command, dict):
        fail("init boundary pipeline analysis is invalid")
    producer_elements = producer.get("elements")
    if (
        basename(str(producer.get("name", ""))) != "write-output"
        or str(producer.get("invocation", "")) not in {"Unknown", ""}
        or bool(producer.get("has_pipeline_input"))
        or not isinstance(producer_elements, list)
        or len(producer_elements) != 2
        or not all(bool(element.get("static")) for element in producer_elements)
        or not bool(boundary_command.get("has_pipeline_input"))
    ):
        fail("init boundary must receive one static Write-Output payload")
    boundary = boundaries[0][1]
    boundary["transport"] = "powershell"
    boundary["payload"] = str(producer_elements[1].get("text", ""))
    return boundary


def direct_boundary_details(command: str, authority: dict[str, str]) -> dict[str, str] | None:
    if command.count("|") != 1 or any(token in command for token in (";", "&&", "||", "\n", "\r", ">", "<")):
        return None
    producer_raw, invocation_raw = (part.strip() for part in command.split("|", 1))
    try:
        producer = shlex.split(producer_raw, posix=True)
        invocation = shlex.split(invocation_raw, posix=True)
    except ValueError:
        return None
    if not (
        producer == ["printf", "%s", "$BRIEF"]
        and len(invocation) in {8, 9, 11}
        and basename(invocation[0]) in {"bash", "bash.exe"}
        and trusted_native_name(invocation[0], basename(invocation[0]))
        and normalize_windows_path(invocation[1]) == authority["boundary"]
        and normalize_windows_path(invocation[2]) == authority["target"]
        and invocation[3:7] == ["--decision", "approve", "--brief-stdin", "--non-interactive"]
        and invocation[7].casefold() in {"--host=claude", "--host=codex"}
    ):
        return None
    tail = invocation[8:]
    details = {
        "transport": "shell",
        "payload": producer[2],
        "host": invocation[7].casefold(),
        "token": "",
    }
    if tail == []:
        details["mode"] = "fresh"
        return details
    # Direct shell uses a runtime variable as its stdin producer, so its actual
    # bytes cannot be proven from the event text. Post-init updates are accepted
    # only through the literal PowerShell Write-Output transport analyzed above.
    return None


def validate_direct_shell(command: str, authority: dict[str, str]) -> dict[str, str] | None:
    boundary = direct_boundary_details(command, authority)
    if boundary is not None:
        return boundary
    if BOUNDARY_TEXT.search(command):
        fail("direct shell command is not the exact authoritative init boundary")
    # Native Codex shell selection emits Bash itself as the outer process,
    # rather than a Bash invocation inside the PowerShell transport. Unwrap
    # only its exact non-login -c shape, then apply the same read-only parser.
    try:
        invocation = shlex.split(command, posix=True)
    except ValueError as exc:
        fail(f"direct shell transport is malformed: {exc}")
    if invocation and basename(invocation[0]) in {"bash", "bash.exe"}:
        require_trusted_native_name(invocation[0], basename(invocation[0]))
        if len(invocation) != 3 or invocation[1] != "-c":
            fail("direct Bash inspection must use exactly one -c script")
        validate_shell_script(invocation[2])
        return None
    validate_shell_script(command)
    return None


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: validate-subject-events.py <subject-events.jsonl> <isolation.json>",
            file=sys.stderr,
        )
        return 2
    path = Path(sys.argv[1])
    if not path.is_file() or path.is_symlink():
        fail("event stream is missing or unsafe")
    pending: dict[str, str] = {}
    completed_commands = 0
    occurrences: list[tuple[str, str, int, dict[str, object]]] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            event = json.loads(raw)
        except json.JSONDecodeError as exc:
            fail(f"line {number} is not JSON: {exc}")
        if not isinstance(event, dict) or event.get("type") not in {"item.started", "item.completed"}:
            continue
        item = event.get("item")
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type in MUTATING_ITEM_TYPES:
            fail(f"line {number} contains prohibited {item_type} mutation evidence")
        if item_type != "command_execution":
            continue
        command = item.get("command")
        item_id = item.get("id")
        if not isinstance(command, str) or not command.strip() or not isinstance(item_id, str) or not item_id:
            fail(f"line {number} has an invalid command event")
        event_type = str(event["type"])
        if event_type == "item.started":
            if item_id in pending:
                fail(f"line {number} reuses an unfinished command id")
            pending[item_id] = command
        else:
            if pending.get(item_id) != command:
                fail(f"line {number} has no identical started command")
            del pending[item_id]
            completed_commands += 1
        occurrences.append((event_type, command, number, item))
    if pending:
        fail("event stream ends with an unfinished command")
    if not occurrences:
        print(json.dumps({"valid": True, "completed_commands": 0}, separators=(",", ":")))
        return 0

    authority = load_authority(Path(sys.argv[2]))
    decoded = [decode_command(command, authority) for _, command, _, _ in occurrences]
    powershell_sources = [source for kind, source in decoded if kind == "powershell"]
    analyses = iter(analyze_powershell(powershell_sources))
    boundary_occurrences: list[
        tuple[str, dict[str, str], dict[str, object], int]
    ] = []
    for (event_type, _command, number, item), (kind, source) in zip(occurrences, decoded):
        try:
            if kind == "powershell":
                boundary = validate_powershell(next(analyses), source, authority)
            else:
                boundary = validate_direct_shell(source, authority)
        except SystemExit:
            print(f"subject-event-validator: rejected {event_type} at line {number}", file=sys.stderr)
            raise
        if boundary is not None:
            boundary_occurrences.append((event_type, boundary, item, number))

    pending_plan: dict[str, str] | None = None
    active_applies: dict[str, bool] = {}
    for event_type, boundary, item, number in boundary_occurrences:
        mode = boundary["mode"]
        if mode == "fresh":
            # Starting a writer invalidates any earlier plan even if that writer
            # later fails; its partial effects cannot be proven absent here.
            if event_type == "item.started":
                pending_plan = None
            elif item.get("status") != "completed" or item.get("exit_code") != 0:
                fail(f"line {number} has a non-successful init boundary")
            continue
        if mode == "update-plan":
            if event_type == "item.started":
                continue
            if item.get("status") != "completed" or item.get("exit_code") != 0:
                fail(f"line {number} has a non-successful update dry-run")
            output = item.get("aggregated_output")
            if not isinstance(output, str):
                fail(f"line {number} update dry-run has no captured output")
            tokens = re.findall(r"(?m)^Plan token: ([0-9a-f]{64})\r?$", output)
            if len(tokens) != 1:
                fail(f"line {number} update dry-run has no unique plan token")
            pending_plan = {
                "transport": boundary["transport"],
                "payload": boundary["payload"],
                "host": boundary["host"],
                "token": tokens[0],
            }
            continue
        item_id = str(item["id"])
        if event_type == "item.started":
            if pending_plan is None:
                fail(f"line {number} update apply starts before a successful dry-run")
            token_redacted = boundary["token"] == "[REDACTED_SECRET]"
            if any(
                boundary[field] != pending_plan[field]
                for field in ("transport", "payload", "host")
            ) or (not token_redacted and boundary["token"] != pending_plan["token"]):
                fail(f"line {number} update apply does not match its dry-run payload and token")
            active_applies[item_id] = token_redacted
            pending_plan = None
            continue
        if item_id not in active_applies:
            fail(f"line {number} update apply has no authorized start")
        token_redacted = active_applies.pop(item_id)
        if item.get("status") != "completed" or item.get("exit_code") != 0:
            fail(f"line {number} has a non-successful update apply")
        if token_redacted and item.get("aggregated_output") != "=== Update applied ===\n":
            fail(f"line {number} redacted update apply has no successful executor receipt")

    print(json.dumps({"valid": True, "completed_commands": completed_commands}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
