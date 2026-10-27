<#
.SYNOPSIS
  DSH acceptance harness for harness-companion.

.DESCRIPTION
  Drives the installed/source skill through its real entry point (run.ps1) and
  records one NDJSON evidence line per scenario. This is the DSH replacement for
  the retired Codex real-Agent evaluation: the evidence is reproducible, bounded
  (well under two minutes), and every assertion names the observable it checked.

  Scenarios:
    A1 status on a managed project
    A2 feature add + in_progress
    A3 verify --write produces canonical NDJSON evidence
    A4 in_progress -> passing with fresh evidence
    A5 WIP=1 rejects a second in_progress
    A6 handoff reports the dangling in_progress feature
    A7 consent boundary cancel writes nothing

  The human-facing acceptance package (docs/acceptance/*.md) cites the evidence
  directory produced by this run.

.PARAMETER EvidenceDir
  Where to write the evidence. Defaults to
  <repo>/tests/acceptance/evidence/<UTC timestamp>.

.PARAMETER KeepFixtures
  Keep the temporary project fixtures instead of deleting them.

.EXAMPLE
  ./dsh/acceptance.ps1
#>

[CmdletBinding()]
param(
  [string]$EvidenceDir,
  [switch]$KeepFixtures
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
  Write-Output 'ACCEPTANCE: FAIL — cannot locate the skill root.'
  exit 1
}

$runPath = Join-Path $skillRoot 'dsh/run.ps1'
if (-not (Test-Path -LiteralPath $runPath)) {
  $runPath = Join-Path $PSScriptRoot 'run.ps1'
}
if (-not (Test-Path -LiteralPath $runPath)) {
  Write-Output 'ACCEPTANCE: FAIL — run.ps1 not found.'
  exit 1
}

if (-not $EvidenceDir) {
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  $EvidenceDir = Join-Path (Join-Path (Join-Path $skillRoot 'tests') 'acceptance') (Join-Path 'evidence' $stamp)
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$evidenceFile = Join-Path $EvidenceDir 'dsh-scenarios.ndjson'
if (Test-Path -LiteralPath $evidenceFile) { Remove-Item -LiteralPath $evidenceFile -Force }

$pwshPath = (Get-Process -Id $PID).Path
$results = New-Object System.Collections.Generic.List[object]
$overall = [System.Diagnostics.Stopwatch]::StartNew()
$baseStamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

function Write-TextFile {
  param([string]$Path, [string]$Text)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Run {
  param([string[]]$Arguments, [int]$TimeoutSec = 90)
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runPath) + $Arguments + @('-TimeoutSec', "$TimeoutSec")
  $lines = & $pwshPath @argList 2>&1
  $code = $LASTEXITCODE
  return [pscustomobject]@{ Code = $code; Text = (@($lines) | Out-String) }
}

function Add-Evidence {
  param(
    [string]$Scenario,
    [bool]$Ok,
    [int]$ExitCode,
    [string]$Assertion,
    [string]$Detail,
    [double]$Seconds
  )
  $record = [ordered]@{
    scenario    = $Scenario
    status      = $(if ($Ok) { 'pass' } else { 'fail' })
    exit_code   = $ExitCode
    assertion   = $Assertion
    detail      = $Detail
    duration_ms = [int]($Seconds * 1000)
    recorded_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    host        = [ordered]@{
      os       = [System.Environment]::OSVersion.VersionString
      pwsh     = $PSVersionTable.PSVersion.ToString()
      skill    = $skillRoot
    }
  }
  Add-Content -LiteralPath $evidenceFile -Value ($record | ConvertTo-Json -Depth 5 -Compress) -Encoding utf8
  $results.Add([pscustomobject]@{ Name = $Scenario; Ok = $Ok; Detail = $Detail; Seconds = $Seconds })
  $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
  $line = '[{0}] {1} ({2:N1}s)' -f $tag, $Scenario, $Seconds
  if (-not $Ok -and $Detail) { $line += " — $Detail" }
  Write-Output $line
}

# ---- fixtures -----------------------------------------------------------------
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hc-accept-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
Write-Output "ACCEPTANCE: skill root = $skillRoot"
Write-Output "ACCEPTANCE: evidence   = $evidenceFile"
Write-Output ''

$config = @'
{
  "project_type": "generic",
  "verification": {
    "commands": [
      {
        "id": "echo-check",
        "command": ["bash", "-c", "echo acceptance-ok"],
        "command_origin": "configured",
        "confirmation": "not_required",
        "required_for_passing": true,
        "timeout_seconds": 60
      }
    ]
  }
}
'@

function New-Project {
  param([string]$Path, [string]$FeaturesJson)
  New-Item -ItemType Directory -Force -Path (Join-Path $Path '.harness') | Out-Null
  Write-TextFile (Join-Path $Path 'AGENTS.md') "# Acceptance Fixture`n`nTemporary harness project.`n"
  Write-TextFile (Join-Path $Path '.harness/config.json') $config
  Write-TextFile (Join-Path $Path 'feature_list.json') $FeaturesJson
}

$project = Join-Path $fixtureRoot 'managed'
New-Project -Path $project -FeaturesJson @'
{
  "version": "2",
  "schema_version": "2.0.0",
  "revision": 1,
  "features": [
    {
      "id": "F-ACC-01",
      "title": "acceptance feature",
      "status": "not_started",
      "evidence_associations": [],
      "legacy_audit_evidence": []
    }
  ]
}
'@

# ---- A1: status ---------------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Run @('status', $project) 40
$step.Stop()
Add-Evidence 'A1 status reads a managed project' ($r.Code -eq 0 -and $r.Text -match 'Harness Health') $r.Code 'exit 0 and "Harness Health" in output' "exit=$($r.Code)" $step.Elapsed.TotalSeconds

# ---- A2: feature add + in_progress -------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$add = Invoke-Run @('feature', 'add', $project, 'F-ACC-02') 40
$prog = Invoke-Run @('feature', 'status', $project, 'F-ACC-02', 'in_progress') 40
$step.Stop()
Add-Evidence 'A2 feature add and in_progress' ($add.Code -eq 0 -and $prog.Code -eq 0) $prog.Code 'add and in_progress both exit 0' "add=$($add.Code) in_progress=$($prog.Code)" $step.Elapsed.TotalSeconds

# ---- A3: verify --write -------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$verify = Invoke-Run @('verify', 'F-ACC-02', $project, '--write') 120
$logs = @(Get-ChildItem -LiteralPath (Join-Path $project '.harness/logs/runs') -Filter '*.ndjson' -File -ErrorAction SilentlyContinue)
$step.Stop()
Add-Evidence 'A3 verify writes canonical NDJSON evidence' ($verify.Code -eq 0 -and $verify.Text -match 'PASSED' -and $logs.Count -ge 1) $verify.Code 'exit 0, "PASSED", one or more run logs' "exit=$($verify.Code) logs=$($logs.Count)" $step.Elapsed.TotalSeconds

# ---- A4: passing with fresh evidence -----------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$passing = Invoke-Run @('feature', 'status', $project, 'F-ACC-02', 'passing') 40
$step.Stop()
Add-Evidence 'A4 in_progress -> passing with fresh evidence' ($passing.Code -eq 0) $passing.Code 'passing accepted after evidence' "exit=$($passing.Code)" $step.Elapsed.TotalSeconds

# ---- A5: WIP=1 ----------------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$null = Invoke-Run @('feature', 'add', $project, 'F-ACC-03') 40
$firstProg = Invoke-Run @('feature', 'status', $project, 'F-ACC-03', 'in_progress') 40
$null = Invoke-Run @('feature', 'add', $project, 'F-ACC-04') 40
$wip = Invoke-Run @('feature', 'status', $project, 'F-ACC-04', 'in_progress') 40
$step.Stop()
Add-Evidence 'A5 WIP=1 rejects a second in_progress' ($firstProg.Code -eq 0 -and $wip.Code -eq 4) $wip.Code 'first in_progress 0, second in_progress 4' "first=$($firstProg.Code) second=$($wip.Code) (expected 0/4)" $step.Elapsed.TotalSeconds

# ---- A6: handoff --------------------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$handoff = Invoke-Run @('handoff', $project) 120
$handoffFile = Join-Path $project 'session-handoff.md'
$step.Stop()
Add-Evidence 'A6 handoff generates session-handoff.md' ($handoff.Code -eq 0 -and (Test-Path -LiteralPath $handoffFile)) $handoff.Code 'exit 0 and session-handoff.md written' "exit=$($handoff.Code) file=$(Test-Path -LiteralPath $handoffFile)" $step.Elapsed.TotalSeconds

# ---- A7: consent boundary -----------------------------------------------------
$step = [System.Diagnostics.Stopwatch]::StartNew()
$boundary = Invoke-Run @('boundary', $project, '--decision', 'cancel') 40
$briefWritten = Test-Path -LiteralPath (Join-Path $project '.harness/PROJECT_BRIEF.json')
$step.Stop()
Add-Evidence 'A7 consent boundary cancel writes nothing' ($boundary.Code -eq 0 -and -not $briefWritten) $boundary.Code 'exit 0 and no PROJECT_BRIEF.json' "exit=$($boundary.Code) brief=$briefWritten" $step.Elapsed.TotalSeconds

# ---- summary ------------------------------------------------------------------
$overall.Stop()
$passed = @($results | Where-Object { $_.Ok }).Count
$total = $results.Count
$summary = [ordered]@{
  suite       = 'dsh-live-acceptance'
  started_at  = $baseStamp
  finished_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  skill_root  = $skillRoot
  evidence    = $evidenceFile
  scenarios   = $total
  passed      = $passed
  failed      = $total - $passed
  duration_s  = [math]::Round($overall.Elapsed.TotalSeconds, 1)
}
Write-Output ''
Write-Output ('ACCEPTANCE: {0}/{1} passed in {2:N1}s' -f $passed, $total, $overall.Elapsed.TotalSeconds)
Write-Output ("ACCEPTANCE: evidence -> $evidenceFile")
Write-TextFile (Join-Path $EvidenceDir 'summary.json') ($summary | ConvertTo-Json -Depth 5)

if (-not $KeepFixtures) {
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Write-Output "ACCEPTANCE: fixtures kept at $fixtureRoot"
}

if ($passed -ne $total) { exit 1 }
exit 0
