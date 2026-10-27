<#
.SYNOPSIS
  Bounded self-check for the installed harness-companion DSH skill.

.DESCRIPTION
  The repository's own verification chain is `bash tests/run-all.sh` with a
  four-hour timeout. That is the wrong gate for a host adapter: it is slow,
  and a single hang stops the release. This smoke test covers the adapter
  contract instead and finishes in well under two minutes:

    1. the launcher finds a real bash
    2. SKILL.md has valid DSH frontmatter
    3. status reads a harness project
    4. the feature list is readable
    5. the state machine accepts in_progress
    6. verify writes canonical NDJSON evidence
    7. passing is accepted only with fresh evidence
    8. WIP=1 is enforced (second in_progress is refused)
    9. the consent boundary cancels without touching the target

  Every step is time-boxed. The fixture is a throwaway directory under TEMP.

.PARAMETER KeepFixture
  Do not delete the temporary fixture project (useful when a step fails).

.EXAMPLE
  ./smoke.ps1
#>

[CmdletBinding()]
param(
  [switch]$KeepFixture
)

$ErrorActionPreference = 'Stop'

# ---- locate skill root --------------------------------------------------------
$skillRoot = $null
foreach ($candidate in @(
    $PSScriptRoot,
    (Split-Path -Parent $PSScriptRoot),
    (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
  )) {
  if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'core/harness-status.sh'))) {
    $skillRoot = $candidate
    break
  }
}
if (-not $skillRoot) {
  Write-Output 'SMOKE: FAIL — cannot locate the skill root (core/harness-status.sh).'
  exit 1
}

$runPath = Join-Path $skillRoot 'dsh/run.ps1'
if (-not (Test-Path -LiteralPath $runPath)) {
  $runPath = Join-Path $PSScriptRoot 'run.ps1'
}
if (-not (Test-Path -LiteralPath $runPath)) {
  Write-Output 'SMOKE: FAIL — run.ps1 not found next to smoke.ps1.'
  exit 1
}

$pwshPath = (Get-Process -Id $PID).Path
$results = New-Object System.Collections.Generic.List[object]
$overall = [System.Diagnostics.Stopwatch]::StartNew()

function Invoke-Run {
  param([string[]]$Arguments, [int]$TimeoutSec = 90)
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runPath) + $Arguments + @('-TimeoutSec', "$TimeoutSec")
  $lines = & $pwshPath @argList 2>&1
  $code = $LASTEXITCODE
  return [pscustomobject]@{
    Code = $code
    Text = (@($lines) | Out-String)
  }
}

function Add-Result {
  param([string]$Name, [bool]$Ok, [string]$Detail, [double]$Seconds)
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Seconds = $Seconds })
  $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
  $line = '[{0}] {1} ({2:N1}s)' -f $tag, $Name, $Seconds
  if (-not $Ok -and $Detail) { $line += " — $Detail" }
  Write-Output $line
}

function Write-TextFile {
  param([string]$Path, [string]$Text)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- fixture ------------------------------------------------------------------
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("hc-smoke-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
Write-Output "SMOKE: skill root = $skillRoot"
Write-Output "SMOKE: fixture    = $fixture"
Write-Output ''

Write-TextFile (Join-Path $fixture 'AGENTS.md') "# Smoke Project`n`nTemporary harness fixture.`n"
Write-TextFile (Join-Path $fixture '.harness/config.json') @'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {
        "id": "echo-check",
        "command": ["bash", "-c", "echo smoke-ok"],
        "command_origin": "configured",
        "confirmation": "not_required",
        "required_for_passing": true,
        "timeout_seconds": 60
      }
    ]
  }
}
'@
Write-TextFile (Join-Path $fixture 'feature_list.json') @'
{
  "version": "2",
  "schema_version": "2.0.0",
  "revision": 1,
  "features": [
    {
      "id": "F-SMOKE-01",
      "title": "smoke feature",
      "status": "not_started",
      "evidence_associations": [],
      "legacy_audit_evidence": []
    }
  ]
}
'@

# ---- 1. bash resolution -------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Run @('bash') 20
$step.Stop()
Add-Result 'launcher finds a real bash' ($r.Code -eq 0 -and $r.Text -match 'bash:\s*.+bash(\.exe)?') "exit=$($r.Code)" $step.Elapsed.TotalSeconds

# ---- 2. DSH frontmatter -------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$entry = Join-Path $skillRoot 'SKILL.md'
$frontmatterOk = $false
$detail = 'SKILL.md missing'
if (Test-Path -LiteralPath $entry) {
  $text = Get-Content -LiteralPath $entry -Raw
  $nameOk = $text -match '(?m)^name:\s*harness-companion\s*$'
  $descMatch = [regex]::Match($text, '(?ms)^description:\s*(.+?)^---')
  $descLen = if ($descMatch.Success) { $descMatch.Groups[1].Value.Trim().Length } else { 0 }
  $frontmatterOk = $text.StartsWith('---') -and $nameOk -and $descLen -gt 0 -and $descLen -le 500
  $detail = "name=$nameOk description_chars=$descLen"
}
$step.Stop()
Add-Result 'SKILL.md frontmatter is DSH-valid' $frontmatterOk $detail $step.Elapsed.TotalSeconds

# ---- 3. status ----------------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Run @('status', $fixture) 30
$step.Stop()
Add-Result 'status renders a harness dashboard' ($r.Code -eq 0 -and $r.Text -match 'Harness Health') "exit=$($r.Code)" $step.Elapsed.TotalSeconds

# ---- 4. feature list ----------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Run @('feature', 'list', $fixture) 30
$step.Stop()
Add-Result 'feature list reads feature_list.json' ($r.Code -eq 0 -and $r.Text -match 'F-SMOKE-01') "exit=$($r.Code)" $step.Elapsed.TotalSeconds

# ---- 5. state machine accepts in_progress -------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Run @('feature', 'status', $fixture, 'F-SMOKE-01', 'in_progress') 30
$step.Stop()
Add-Result 'state machine accepts not_started -> in_progress' ($r.Code -eq 0) "exit=$($r.Code)" $step.Elapsed.TotalSeconds

# ---- 6. verify writes evidence ------------------------------------------------
# Must run AFTER in_progress: the state change rewrites feature_list.json, and
# evidence is bound to the workspace fingerprint captured at verification time.
$step = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Run @('verify', 'F-SMOKE-01', $fixture, '--write') 90
$logs = @(Get-ChildItem -LiteralPath (Join-Path $fixture '.harness/logs/runs') -Filter '*.ndjson' -File -ErrorAction SilentlyContinue)
$step.Stop()
Add-Result 'verify writes canonical NDJSON evidence' ($r.Code -eq 0 -and $r.Text -match 'PASSED' -and $logs.Count -ge 1) "exit=$($r.Code) logs=$($logs.Count)" $step.Elapsed.TotalSeconds

# ---- 7. passing with fresh evidence -------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Run @('feature', 'status', $fixture, 'F-SMOKE-01', 'passing') 30
$step.Stop()
Add-Result 'in_progress -> passing accepted with fresh evidence' ($r.Code -eq 0) "exit=$($r.Code)" $step.Elapsed.TotalSeconds

# ---- 8. WIP=1 -----------------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$null = Invoke-Run @('feature', 'add', $fixture, 'F-SMOKE-02') 30
$first = Invoke-Run @('feature', 'status', $fixture, 'F-SMOKE-02', 'in_progress') 30
$null = Invoke-Run @('feature', 'add', $fixture, 'F-SMOKE-03') 30
$second = Invoke-Run @('feature', 'status', $fixture, 'F-SMOKE-03', 'in_progress') 30
$step.Stop()
Add-Result 'WIP=1 refuses a second in_progress' ($first.Code -eq 0 -and $second.Code -eq 4) "first=$($first.Code) second=$($second.Code) (expected 0/4)" $step.Elapsed.TotalSeconds

# ---- 8. consent boundary ------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Run @('boundary', $fixture, '--decision', 'cancel') 30
$briefWritten = Test-Path -LiteralPath (Join-Path $fixture '.harness/PROJECT_BRIEF.json')
$step.Stop()
Add-Result 'consent boundary cancels without writes' ($r.Code -eq 0 -and -not $briefWritten) "exit=$($r.Code) brief_written=$briefWritten" $step.Elapsed.TotalSeconds

# ---- summary ------------------------------------------------------------------
$overall.Stop()
$passed = @($results | Where-Object { $_.Ok }).Count
$total = $results.Count
Write-Output ''
Write-Output ('SMOKE: {0}/{1} passed in {2:N1}s' -f $passed, $total, $overall.Elapsed.TotalSeconds)

if (-not $KeepFixture) {
  Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Write-Output "SMOKE: fixture kept at $fixture"
}

if ($passed -ne $total) { exit 1 }
exit 0
