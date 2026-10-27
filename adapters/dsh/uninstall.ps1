<#
.SYNOPSIS
  Remove the harness-companion DSH skill.

.DESCRIPTION
  Deletes the installed skill directory, but only when it can prove the
  directory is the one this adapter installed: install-receipt.json must exist,
  declare adapter=dsh, and record the same absolute path.

  A directory without that receipt is never deleted. That protects a shared
  skill root such as ~/.agents/skills from being cleaned out by mistake.

.PARAMETER Target
  Install directory to remove. Defaults to <DSH_HOME>/skills/harness-companion.

.PARAMETER Force
  Skip the receipt checks. Use only when you are certain about the target.

.EXAMPLE
  ./uninstall.ps1
#>

[CmdletBinding()]
param(
  [string]$Target,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $Target) {
  $dshHome = $env:DSH_HOME
  if (-not $dshHome) { $dshHome = Join-Path $HOME '.dsh' }
  $Target = Join-Path (Join-Path $dshHome 'skills') 'harness-companion'
}

$Target = [System.IO.Path]::GetFullPath($Target)

if (-not (Test-Path -LiteralPath $Target)) {
  Write-Output "Nothing to uninstall: $Target does not exist."
  exit 0
}

$receiptPath = Join-Path $Target 'install-receipt.json'
if (-not $Force) {
  if (-not (Test-Path -LiteralPath $receiptPath)) {
    Write-Output "[ERROR] refusing to delete a directory with no install receipt: $Target"
    Write-Output '        Re-run with -Force only if you are certain this directory is disposable.'
    exit 1
  }
  $receipt = $null
  try {
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
  } catch {
    Write-Output "[ERROR] install receipt is unreadable: $receiptPath"
    exit 1
  }
  if ($receipt.adapter -ne 'dsh') {
    Write-Output "[ERROR] install receipt does not declare adapter=dsh (found '$($receipt.adapter)')."
    exit 1
  }
  if ($receipt.installed_to) {
    $recorded = [System.IO.Path]::GetFullPath([string]$receipt.installed_to)
    if ($recorded -ne $Target) {
      Write-Output "[ERROR] receipt points at a different location: $recorded"
      Write-Output "        requested target: $Target"
      exit 1
    }
  }
}

Remove-Item -LiteralPath $Target -Recurse -Force
Write-Output "Uninstalled harness-companion from: $Target"
Write-Output ''
Write-Output 'Notes:'
Write-Output '  - A v1 skill under ~/.agents/skills was left untouched; it becomes visible again'
Write-Output '    to DSH once this install is gone (the shadowing entry is removed).'
Write-Output '  - Open a new session to refresh the model-facing skill catalog.'
exit 0
