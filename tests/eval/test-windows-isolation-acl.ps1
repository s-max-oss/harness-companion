param(
    [Parameter(Mandatory = $true)]
    [string]$Helper
)

$ErrorActionPreference = "Stop"
$Helper = (Get-Item -LiteralPath $Helper -Force -ErrorAction Stop).FullName
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$root = Join-Path $tempBase ("harness-acl-contract-" + [Guid]::NewGuid().ToString("N"))
if (-not $root.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw "unsafe ACL contract test root: $root"
}
[void](New-Item -ItemType Directory -Path $root)
$rounds = @()

function New-Round([string]$Name) {
    $base = Join-Path $root $Name
    $value = [pscustomobject]@{
        Workspace  = Join-Path $base "workspace"
        UserHome   = Join-Path $base "home"
        Controller = Join-Path $base "controller"
        State      = Join-Path $base "state.json"
    }
    [void](New-Item -ItemType Directory -Path $value.Workspace, $value.UserHome, $value.Controller)
    $script:rounds += $value
    return $value
}

function Get-Dacl([string]$Path) {
    return (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm(
        [System.Security.AccessControl.AccessControlSections]::Access
    )
}

function Invoke-Helper([string]$Mode, [object]$Round) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Helper -Mode $Mode `
        -WorkspaceRoot $Round.Workspace -ControllerRoot $Round.Controller `
        -UserHome $Round.UserHome -StateFile $Round.State
    if ($LASTEXITCODE -ne 0) {
        throw "ACL helper $Mode failed with exit $LASTEXITCODE"
    }
}

function Assert-Restored([object]$Round, [hashtable]$Before) {
    if ((Get-Dacl $Round.Workspace) -ne $Before.Workspace) {
        throw "workspace DACL was not restored"
    }
    if ((Get-Dacl $Round.UserHome) -ne $Before.UserHome) {
        throw "user-home DACL was not restored"
    }
    if ((Test-Path -LiteralPath $Round.Controller -PathType Container) -and
        (Get-Dacl $Round.Controller) -ne $Before.Controller) {
        throw "controller DACL was not restored"
    }
    if (Test-Path -LiteralPath $Round.State) {
        throw "restoration state was not removed after success"
    }
}

function Invoke-ExpectedLeaveFailure([object]$Round, [string]$Message) {
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 can promote native stderr to a terminating
        # NativeCommandError when ErrorActionPreference is Stop. This child is
        # expected to fail, so capture its process status explicitly.
        $ErrorActionPreference = "Continue"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Helper -Mode Leave `
            -WorkspaceRoot $Round.Workspace -ControllerRoot $Round.Controller `
            -UserHome $Round.UserHome -StateFile $Round.State 2>$null
        $failureExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($failureExit -eq 0) {
        throw $Message
    }
    if (-not (Test-Path -LiteralPath $Round.State -PathType Leaf)) {
        throw "failed restoration removed its recovery state"
    }
}

try {
    $normal = New-Round "normal"
    $before = @{
        Workspace = Get-Dacl $normal.Workspace
        UserHome = Get-Dacl $normal.UserHome
        Controller = Get-Dacl $normal.Controller
    }
    Invoke-Helper "Enter" $normal
    if (-not (Test-Path -LiteralPath $normal.State -PathType Leaf)) {
        throw "Enter did not persist recovery state"
    }
    Invoke-Helper "Leave" $normal
    Assert-Restored $normal $before

    $missing = New-Round "missing"
    $before = @{
        Workspace = Get-Dacl $missing.Workspace
        UserHome = Get-Dacl $missing.UserHome
        Controller = Get-Dacl $missing.Controller
    }
    Invoke-Helper "Enter" $missing
    Remove-Item -LiteralPath $missing.Controller -Recurse -Force
    Invoke-Helper "Leave" $missing
    Assert-Restored $missing $before

    $replaced = New-Round "replaced"
    $before = @{
        Workspace = Get-Dacl $replaced.Workspace
        UserHome = Get-Dacl $replaced.UserHome
        Controller = Get-Dacl $replaced.Controller
    }
    Invoke-Helper "Enter" $replaced
    Remove-Item -LiteralPath $replaced.Controller -Recurse -Force
    [System.IO.File]::WriteAllText($replaced.Controller, "replacement")
    Invoke-ExpectedLeaveFailure $replaced "non-directory replacement did not fail closed"
    Remove-Item -LiteralPath $replaced.Controller -Force
    Invoke-Helper "Leave" $replaced
    Assert-Restored $replaced $before

    $replacementDirectory = New-Round "replacement-directory"
    $before = @{
        Workspace = Get-Dacl $replacementDirectory.Workspace
        UserHome = Get-Dacl $replacementDirectory.UserHome
        Controller = Get-Dacl $replacementDirectory.Controller
    }
    Invoke-Helper "Enter" $replacementDirectory
    Remove-Item -LiteralPath $replacementDirectory.Controller -Recurse -Force
    [void](New-Item -ItemType Directory -Path $replacementDirectory.Controller)
    $replacementDacl = Get-Dacl $replacementDirectory.Controller
    Invoke-ExpectedLeaveFailure $replacementDirectory `
        "replacement directory identity was accepted"
    if ((Get-Dacl $replacementDirectory.Controller) -ne $replacementDacl) {
        throw "replacement directory received the saved DACL"
    }
    Remove-Item -LiteralPath $replacementDirectory.Controller -Recurse -Force
    Invoke-Helper "Leave" $replacementDirectory
    Assert-Restored $replacementDirectory $before

    $junction = New-Round "junction"
    $before = @{
        Workspace = Get-Dacl $junction.Workspace
        UserHome = Get-Dacl $junction.UserHome
        Controller = Get-Dacl $junction.Controller
    }
    Invoke-Helper "Enter" $junction
    Remove-Item -LiteralPath $junction.Controller -Recurse -Force
    $junctionTargetDacl = Get-Dacl $junction.Workspace
    [void](New-Item -ItemType Junction -Path $junction.Controller -Target $junction.Workspace)
    Invoke-ExpectedLeaveFailure $junction "junction replacement was accepted"
    if ((Get-Dacl $junction.Workspace) -ne $junctionTargetDacl) {
        throw "junction target received the saved DACL"
    }
    Remove-Item -LiteralPath $junction.Controller -Force
    Invoke-Helper "Leave" $junction
    Assert-Restored $junction $before

    $providerFailure = New-Round "provider-failure"
    $before = @{
        Workspace = Get-Dacl $providerFailure.Workspace
        UserHome = Get-Dacl $providerFailure.UserHome
        Controller = Get-Dacl $providerFailure.Controller
    }
    Invoke-Helper "Enter" $providerFailure
    $originalState = Get-Content -LiteralPath $providerFailure.State -Raw
    $modifiedState = $originalState | ConvertFrom-Json
    $modifiedState.paths[-1].path = "HKLM:\\SOFTWARE"
    $modifiedState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $providerFailure.State -Encoding UTF8
    Invoke-ExpectedLeaveFailure $providerFailure `
        "non-filesystem provider failure was treated as a missing directory"
    [System.IO.File]::WriteAllText(
        $providerFailure.State,
        $originalState,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Invoke-Helper "Leave" $providerFailure
    Assert-Restored $providerFailure $before
} finally {
    foreach ($round in $rounds) {
        if (Test-Path -LiteralPath $round.Controller -PathType Leaf) {
            Remove-Item -LiteralPath $round.Controller -Force
        }
        if (Test-Path -LiteralPath $round.State -PathType Leaf) {
            try {
                Invoke-Helper "Leave" $round
            } catch {
                Write-Warning "emergency ACL cleanup failed for $($round.State): $_"
            }
        }
    }
    if (Test-Path -LiteralPath $root -PathType Container) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
