<#
.SYNOPSIS
  DSH adapter launcher for harness-companion.

.DESCRIPTION
  DSH sessions on Windows often have no `bash` on PATH, while the skill core is
  POSIX bash. This launcher resolves a real bash (Git Bash included), runs one
  canonical script from the installed skill root, forwards argv without shell
  interpolation, and enforces a timeout.

  It maps an action name to the canonical script so callers never have to know
  the core/scripts layout:

    status    -> core/harness-status.sh
    audit     -> core/harness-audit.sh
    feature   -> core/harness-feature.sh
    verify    -> core/harness-verify.sh
    handoff   -> scripts/harness-handoff.sh
    init      -> scripts/harness-init.sh
    boundary  -> scripts/harness-init-boundary.sh
    bash      -> diagnostics only (prints the resolved bash and its version)
    run       -> run an explicit skill-relative script path

.EXAMPLE
  ./run.ps1 status D:\work\my-app

.EXAMPLE
  ./run.ps1 feature D:\work\my-app status D:\work\my-app feat-001 passing

.EXAMPLE
  ./run.ps1 verify feat-001 D:\work\my-app --write -TimeoutSec 900

.EXAMPLE
  ./run.ps1 boundary D:\work\my-app --decision approve --brief-stdin --non-interactive --host=codex -StdinText '{"goal":"..."}'

.NOTES
  Exit codes: the wrapped script's own code, 2 for launcher usage errors,
  124 for timeout, 127 when no usable bash can be found.
#>

$ErrorActionPreference = 'Stop'

$script:SkillRoot = $null
foreach ($candidateRoot in @(
    $PSScriptRoot,
    (Split-Path -Parent $PSScriptRoot),
    (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
  )) {
  if ($candidateRoot -and (Test-Path -LiteralPath (Join-Path $candidateRoot 'core/harness-status.sh') -PathType Leaf)) {
    $script:SkillRoot = $candidateRoot
    break
  }
}
if (-not $script:SkillRoot) {
  Write-Error "cannot locate the harness-companion skill root from $PSScriptRoot"
  exit 2
}

function Show-Usage {
  @"
harness-companion DSH launcher

  run.ps1 <action> [script args...] [-StdinText <text>] [-StdinFile <path>] [-TimeoutSec <n>]

Actions:
  status     health dashboard                      (core/harness-status.sh)
  audit      5-axis / 7-subsystem audit            (core/harness-audit.sh)
  feature    feature_list.json state machine       (core/harness-feature.sh)
  verify     verification chain + NDJSON evidence  (core/harness-verify.sh)
  handoff    session handoff generator             (scripts/harness-handoff.sh)
  init       deterministic init executor           (scripts/harness-init.sh)
  boundary   consent boundary for guided init      (scripts/harness-init-boundary.sh)
  bash       print the resolved bash + version     (diagnostics)
  run        <skill-relative script path> [args]   (escape hatch)

Options:
  -StdinText <text>  pipe this text to the script's stdin (for --brief-stdin)
  -StdinFile <path>  pipe this file's content to stdin
  -TimeoutSec <n>    kill the child after n seconds (default 300)

Project directories are ordinary script arguments and are forwarded as-is.
The launcher runs the script in the current directory, so a relative target
such as '.' resolves there.

The script args are forwarded verbatim and are not re-quoted by a shell.
"@ | Write-Output
}

function Find-Bash {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($env:DSH_BASH) { $candidates.Add($env:DSH_BASH) }

  $onPath = Get-Command bash -ErrorAction SilentlyContinue
  if ($onPath -and $onPath.Source) { $candidates.Add($onPath.Source) }

  $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)
  foreach ($root in $roots) {
    if (-not $root) { continue }
    $candidates.Add((Join-Path $root 'Git\bin\bash.exe'))
    $candidates.Add((Join-Path $root 'Programs\Git\bin\bash.exe'))
  }
  $candidates.Add('C:\Program Files\Git\usr\bin\bash.exe')
  $candidates.Add('/usr/bin/bash')
  $candidates.Add('/bin/bash')

  foreach ($candidate in $candidates) {
    if (-not $candidate) { continue }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
      $probeOutput = & $candidate --version 2>&1
      $probe = @($probeOutput) | Select-Object -First 1
      if ($probe) {
        return [pscustomobject]@{ Path = $candidate; Version = [string]$probe }
      }
    } catch {
      continue
    }
  }
  return $null
}

function Resolve-ActionScript([string]$Action) {
  $map = @{
    'status'   = 'core/harness-status.sh'
    'audit'    = 'core/harness-audit.sh'
    'feature'  = 'core/harness-feature.sh'
    'verify'   = 'core/harness-verify.sh'
    'handoff'  = 'scripts/harness-handoff.sh'
    'init'     = 'scripts/harness-init.sh'
    'boundary' = 'scripts/harness-init-boundary.sh'
  }
  if ($map.ContainsKey($Action)) { return $map[$Action] }
  return $null
}

# ---- argument parsing (manual: keep every token verbatim) ---------------------
$raw = @($args)
if ($raw.Count -eq 0) { Show-Usage; exit 2 }

$action = [string]$raw[0]
if ($action -in @('-h', '--help', 'help')) { Show-Usage; exit 0 }

$rest = New-Object System.Collections.Generic.List[string]
$timeoutSec = 300
$stdinText = $null

# MSYS tools misbehave on backslash paths: sha256sum switches to binary mode and
# prefixes its digest with "\", and the workspace fingerprint fails to strip the
# project prefix so exclusions stop matching. Both surface later as bogus
# "config_changed_since_run" / "workspace_changed_since_verification" refusals.
# Git Bash accepts forward slashes, so normalize path-shaped tokens here.
function ConvertTo-BashPath([string]$Value) {
  if ($Value -match '^[A-Za-z]:[\\/]') { return ($Value -replace '\\', '/') }
  if ($Value -match '^\\\\') { return ('//' + $Value.Substring(2) -replace '\\', '/') }
  return $Value
}

for ($i = 1; $i -lt $raw.Count; $i++) {
  $token = [string]$raw[$i]
  switch -Regex ($token) {
    '^-TimeoutSec$' {
      if ($i + 1 -ge $raw.Count) { Write-Error '-TimeoutSec requires a number'; exit 2 }
      $timeoutSec = [int]$raw[++$i]
      continue
    }
    '^-StdinText$' {
      if ($i + 1 -ge $raw.Count) { Write-Error '-StdinText requires text'; exit 2 }
      $stdinText = [string]$raw[++$i]
      continue
    }
    '^-StdinFile$' {
      if ($i + 1 -ge $raw.Count) { Write-Error '-StdinFile requires a path'; exit 2 }
      $path = [string]$raw[++$i]
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "stdin file not found: $path"
        exit 2
      }
      $stdinText = Get-Content -LiteralPath $path -Raw
      continue
    }
    default { $rest.Add($token) }
  }
}

# ---- diagnostics action -------------------------------------------------------
if ($action -eq 'bash') {
  $found = Find-Bash
  if (-not $found) {
    Write-Output 'bash: NOT FOUND (install Git for Windows, or set DSH_BASH)'
    exit 127
  }
  Write-Output "bash: $($found.Path)"
  Write-Output "version: $($found.Version)"
  exit 0
}

# ---- resolve the script under the skill root ----------------------------------
if ($action -eq 'run') {
  if ($rest.Count -eq 0) { Write-Error 'run requires a skill-relative script path'; exit 2 }
  $relative = $rest[0]
  $rest.RemoveAt(0)
  $scriptPath = Join-Path $script:SkillRoot $relative
} else {
  $relative = Resolve-ActionScript $action
  if (-not $relative) {
    Write-Error "unknown action: $action"
    Show-Usage
    exit 2
  }
  $scriptPath = Join-Path $script:SkillRoot $relative
}

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  Write-Error "script not found under skill root: $scriptPath"
  exit 2
}

# ---- resolve working directory ------------------------------------------------
$workDir = (Get-Location).Path
if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
  Write-Error "working directory not found: $workDir"
  exit 2
}
$workDir = (Resolve-Path -LiteralPath $workDir).Path

# ---- resolve bash -------------------------------------------------------------
$bash = Find-Bash
if (-not $bash) {
  Write-Error 'No usable bash found. Install Git for Windows (Git Bash) or set DSH_BASH to bash.exe.'
  exit 127
}

# ---- run with timeout ---------------------------------------------------------
$bashArgs = @($scriptPath) + ($rest.ToArray() | ForEach-Object { ConvertTo-BashPath ([string]$_) })

$worker = {
  param($BashPath, $Arguments, $WorkDir, $Stdin)
  # Git Bash emits UTF-8; decode it as UTF-8 instead of the ANSI code page.
  try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
  try { $OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
  Set-Location -LiteralPath $WorkDir
  try {
    if ($Stdin) {
      $output = $Stdin | & $BashPath @Arguments 2>&1 | Out-String
    } else {
      $output = & $BashPath @Arguments 2>&1 | Out-String
    }
    [pscustomobject]@{ Output = $output; Code = $LASTEXITCODE }
  } catch {
    [pscustomobject]@{ Output = "launcher error: $($_.Exception.Message)"; Code = 127 }
  }
}

$job = Start-Job -ScriptBlock $worker -ArgumentList $bash.Path, $bashArgs, $workDir, $stdinText
$finished = Wait-Job -Job $job -Timeout $timeoutSec

if (-not $finished) {
  Stop-Job -Job $job -ErrorAction SilentlyContinue
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  Write-Output "harness-companion: '$action' exceeded ${timeoutSec}s and was stopped (exit 124)."
  exit 124
}

$result = Receive-Job -Job $job
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

if (-not $result) {
  Write-Output 'harness-companion: the wrapped script produced no result object (exit 127).'
  exit 127
}

$record = @($result)[-1]
if ($record.Output) { Write-Output $record.Output.TrimEnd("`r", "`n") }
exit ([int]$record.Code)
