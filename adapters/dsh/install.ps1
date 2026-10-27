<#
.SYNOPSIS
  Install harness-companion as a DSH skill.

.DESCRIPTION
  Copies the DSH-facing layer (SKILL.md + references) together with the shared
  bash core (core/, scripts/, templates/) into a DSH skill root:

      <DSH_HOME>/skills/harness-companion

  DSH discovers skills one level deep as <root>/<name>/SKILL.md, so after a new
  session the skill appears in the model catalog and can be loaded with the
  `skill` tool (or invoked by a human as /harness-companion).

  The installer refuses to overwrite a directory it does not own, normalizes
  shell scripts to LF (the source tree is CRLF under core.autocrlf=true), and
  writes a minimal install receipt that uninstall.ps1 uses for identity checks.

.PARAMETER Target
  Explicit install directory. Defaults to <DSH_HOME>/skills/harness-companion.

.PARAMETER Force
  Allow replacing an existing directory that has no DSH receipt. The previous
  contents are moved to <Target>.bak.<timestamp>, never deleted.

.EXAMPLE
  ./install.ps1

.EXAMPLE
  ./install.ps1 -Target 'D:\tmp\skills\harness-companion'
#>

[CmdletBinding()]
param(
  [string]$Target,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$AdapterDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent (Split-Path -Parent $AdapterDir)

function Fail([string]$Message) {
  Write-Output "[ERROR] $Message"
  exit 1
}

function Write-Step([string]$Message) {
  Write-Output $Message
}

# ---- source validation --------------------------------------------------------
$required = @(
  (Join-Path $AdapterDir 'SKILL.md'),
  (Join-Path $AdapterDir 'run.ps1'),
  (Join-Path $RepoRoot 'core/harness-status.sh'),
  (Join-Path $RepoRoot 'scripts/harness-init.sh'),
  (Join-Path $RepoRoot 'templates'),
  (Join-Path $RepoRoot 'references'),
  (Join-Path $RepoRoot 'VERSION')
)
foreach ($path in $required) {
  if (-not (Test-Path -LiteralPath $path)) {
    Fail "source tree is incomplete, missing: $path"
  }
}

$version = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
if (-not $version) { Fail "VERSION is empty" }

# ---- target resolution --------------------------------------------------------
if (-not $Target) {
  $dshHome = $env:DSH_HOME
  if (-not $dshHome) { $dshHome = Join-Path $HOME '.dsh' }
  $Target = Join-Path (Join-Path $dshHome 'skills') 'harness-companion'
}

$Target = [System.IO.Path]::GetFullPath($Target)
$targetParent = Split-Path -Parent $Target
if (-not (Test-Path -LiteralPath $targetParent)) {
  New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
}

Write-Output '=== harness-companion DSH adapter installer ==='
Write-Output "source:  $RepoRoot"
Write-Output "target:  $Target"
Write-Output "version: $version"
Write-Output ''

# ---- identity / overwrite policy ---------------------------------------------
$receiptPath = Join-Path $Target 'install-receipt.json'
if (Test-Path -LiteralPath $Target) {
  $owned = $false
  if (Test-Path -LiteralPath $receiptPath) {
    try {
      $existing = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
      if ($existing.adapter -eq 'dsh') { $owned = $true }
    } catch {
      $owned = $false
    }
  }
  if ($owned) {
    # Our own previous install: replace it. The source tree is the authority and
    # a .bak directory inside a DSH skill root would only add discovery noise.
    Write-Output '[1/5] Existing DSH install detected — replacing it'
    Remove-Item -LiteralPath $Target -Recurse -Force
  } else {
    if (-not $Force) {
      Fail "target exists and is not a DSH install: $Target`n        Re-run with -Force to move it aside to $Target.bak.<timestamp>"
    }
    $stamp = Get-Date -Format 'yyyyMMddTHHmmssZ'
    $backup = "$Target.bak.$stamp"
    Write-Output "[1/5] Existing directory moved aside: $backup"
    Move-Item -LiteralPath $Target -Destination $backup
  }
} else {
  Write-Output '[1/5] Fresh install'
}

New-Item -ItemType Directory -Force -Path $Target | Out-Null

# ---- copy ---------------------------------------------------------------------
function Copy-Tree([string]$Source, [string]$Destination) {
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
    $outFile = Join-Path $Destination $relative
    $outDir = Split-Path -Parent $outFile
    if (-not (Test-Path -LiteralPath $outDir)) {
      New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $outFile -Force
  }
}

Write-Output '[2/5] Copying skill entry + references'
Copy-Item -LiteralPath (Join-Path $AdapterDir 'SKILL.md') -Destination (Join-Path $Target 'SKILL.md') -Force
$referencesTarget = Join-Path $Target 'references'
New-Item -ItemType Directory -Force -Path $referencesTarget | Out-Null
Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'references') -File -Filter '*.md' | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $referencesTarget $_.Name) -Force
}
Get-ChildItem -LiteralPath (Join-Path $AdapterDir 'references') -File -Filter '*.md' | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $referencesTarget $_.Name) -Force
}

Write-Output '[3/5] Copying bash core (core/, scripts/, templates/)'
Copy-Tree (Join-Path $RepoRoot 'core') (Join-Path $Target 'core')
Copy-Tree (Join-Path $RepoRoot 'templates') (Join-Path $Target 'templates')

$scriptsTarget = Join-Path $Target 'scripts'
New-Item -ItemType Directory -Force -Path $scriptsTarget | Out-Null
Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -File -Filter '*.sh' | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $scriptsTarget $_.Name) -Force
}
# scripts/hooks (v1 Claude/Codex compatibility) and scripts/acceptance (release
# tooling) are intentionally not installed: DSH does not consume either.

$dshTarget = Join-Path $Target 'dsh'
New-Item -ItemType Directory -Force -Path $dshTarget | Out-Null
foreach ($file in @('run.ps1', 'smoke.ps1')) {
  $source = Join-Path $AdapterDir $file
  if (Test-Path -LiteralPath $source) {
    Copy-Item -LiteralPath $source -Destination (Join-Path $dshTarget $file) -Force
  }
}
Copy-Item -LiteralPath (Join-Path $RepoRoot 'VERSION') -Destination (Join-Path $Target 'VERSION') -Force

# ---- LF normalization ---------------------------------------------------------
Write-Output '[4/5] Normalizing shell scripts to LF'
$converted = 0
Get-ChildItem -LiteralPath $Target -Recurse -File -Filter '*.sh' | ForEach-Object {
  $text = Get-Content -LiteralPath $_.FullName -Raw
  if ($null -eq $text) { return }
  if ($text.Contains("`r")) {
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    Set-Content -LiteralPath $_.FullName -Value $text -NoNewline -Encoding utf8
    $converted++
  }
}
Write-Output "      converted $converted file(s)"

# ---- receipt ------------------------------------------------------------------
$commit = $null
try {
  $commit = (& git -C $RepoRoot rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0) { $commit = $null }
} catch {
  $commit = $null
}
if ($commit) { $commit = ([string]$commit).Trim() }

$receipt = [ordered]@{
  adapter      = 'dsh'
  version      = $version
  mode         = 'user'
  installed_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  installed_to = $Target
  source       = [ordered]@{
    repository = 'harness-companion'
    commit     = $commit
    origin     = $(if ($commit) { 'git' } else { 'archive' })
  }
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding utf8

# ---- verify -------------------------------------------------------------------
Write-Output '[5/5] Verifying installed layout'
$installedEntry = Join-Path $Target 'SKILL.md'
if (-not (Test-Path -LiteralPath $installedEntry)) { Fail 'installed SKILL.md missing' }
$entryText = Get-Content -LiteralPath $installedEntry -Raw
if ($entryText -notmatch '(?m)^name:\s*harness-companion\s*$') {
  Fail 'installed SKILL.md does not declare name: harness-companion'
}
if (-not (Test-Path -LiteralPath (Join-Path $Target 'core/harness-status.sh'))) {
  Fail 'installed core/harness-status.sh missing'
}

$fileCount = (Get-ChildItem -LiteralPath $Target -Recurse -File).Count
Write-Output ''
Write-Output '=== Installed ==='
Write-Output "  skill root: $Target"
Write-Output "  files:      $fileCount"
Write-Output "  manifest:   $(Join-Path $Target 'SKILL.md')"
Write-Output ''
Write-Output 'Next steps:'
Write-Output '  1. Open a NEW DSH session so the catalog picks up the skill.'
Write-Output '  2. Verify the runtime:'
Write-Output "       & '$Target\dsh\smoke.ps1'"
Write-Output '  3. In a harness project, load this skill and ask for 状态 / 初始化.'
Write-Output ''
Write-Output 'Notes:'
Write-Output '  - A pre-existing v1 skill under ~/.agents/skills is shadowed by this'
Write-Output '    install (user-dsh rank 400 beats user-agents rank 500). Nothing is deleted.'
Write-Output '  - The bash core is copied, not linked; re-run this installer after upgrades.'
exit 0
