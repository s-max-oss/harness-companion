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
        Source     = Join-Path (Join-Path $base "workspace") "SKILL.md"
        State      = Join-Path $base "state.json"
        Evidence   = Join-Path $base "evidence.json"
    }
    [void](New-Item -ItemType Directory -Path $value.Workspace, $value.UserHome, $value.Controller)
    [System.IO.File]::WriteAllText($value.Source, "contract source")
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
        -UserHome $Round.UserHome -SourceFile $Round.Source -StateFile $Round.State `
        -EvidenceFile $Round.Evidence
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
    if ((Test-Path -LiteralPath $Round.Source -PathType Leaf) -and
        (Get-Dacl $Round.Source) -ne $Before.Source) {
        throw "source-file DACL was not restored"
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
            -UserHome $Round.UserHome -SourceFile $Round.Source `
            -StateFile $Round.State -EvidenceFile $Round.Evidence 2>$null
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
        Source = Get-Dacl $normal.Source
    }
    Invoke-Helper "Enter" $normal
    if (-not (Test-Path -LiteralPath $normal.State -PathType Leaf)) {
        throw "Enter did not persist recovery state"
    }
    $normalState = Get-Content -LiteralPath $normal.State -Raw | ConvertFrom-Json
    if ([int]$normalState.schema_version -ne 3) {
        throw "Enter did not persist the file-aware recovery schema"
    }
    $sourceEntries = @($normalState.paths | Where-Object {
        $_.kind -eq 'file' -and $_.path -eq $normal.Source
    })
    if ($sourceEntries.Count -ne 1) {
        throw "Enter did not bind the exact source file in recovery state"
    }
    $sourceAcl = Get-Acl -LiteralPath $normal.Source
    foreach ($sandboxName in @('CodexSandboxOffline', 'CodexSandboxOnline')) {
        $denyRules = @($sourceAcl.Access | Where-Object {
            $_.IdentityReference.Value.EndsWith("\$sandboxName") -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and
            -not $_.IsInherited -and
            $_.InheritanceFlags -eq [System.Security.AccessControl.InheritanceFlags]::None -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne 0
        })
        if ($denyRules.Count -ne 1) {
            throw "Enter did not install one direct source-file deny for $sandboxName"
        }
    }
    $normalEvidence = Get-Content -LiteralPath $normal.Evidence -Raw | ConvertFrom-Json
    if ($normalEvidence.source_file_deny.path -ne $normal.Source -or
        @($normalEvidence.source_file_deny.checks).Count -ne 2 -or
        @($normalEvidence.source_file_deny.checks | Where-Object {
            $_.read_execute_denied -ne $true
        }).Count -ne 0) {
        throw "Enter did not emit exact direct source-file deny evidence"
    }
    Invoke-Helper "Leave" $normal
    Assert-Restored $normal $before

    $legacy = New-Round "legacy-schema-2"
    $before = @{
        Workspace = Get-Dacl $legacy.Workspace
        UserHome = Get-Dacl $legacy.UserHome
        Controller = Get-Dacl $legacy.Controller
        Source = Get-Dacl $legacy.Source
    }
    Invoke-Helper "Enter" $legacy
    $legacyState3 = Get-Content -LiteralPath $legacy.State -Raw | ConvertFrom-Json
    $legacySourceEntry = @($legacyState3.paths | Where-Object { $_.kind -eq 'file' })
    if ($legacySourceEntry.Count -ne 1) {
        throw "schema-3 state did not contain one source file for legacy setup"
    }
    $legacySourceAcl = New-Object System.Security.AccessControl.FileSecurity
    $legacySourceAcl.SetSecurityDescriptorSddlForm(
        [string]$legacySourceEntry[0].sddl,
        [System.Security.AccessControl.AccessControlSections]::Access
    )
    Set-Acl -LiteralPath $legacy.Source -AclObject $legacySourceAcl
    $legacyDirectories = @($legacyState3.paths | Where-Object { $_.kind -eq 'directory' } | ForEach-Object {
        [pscustomobject]@{
            path = $_.path
            identity = $_.identity
            sddl = $_.sddl
        }
    })
    $legacyState2 = [pscustomobject]@{
        schema_version = 2
        created_at_utc = $legacyState3.created_at_utc
        paths = $legacyDirectories
    }
    [System.IO.File]::WriteAllText(
        $legacy.State,
        ($legacyState2 | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false))
    )
    Invoke-Helper "Leave" $legacy
    Assert-Restored $legacy $before

    $missing = New-Round "missing"
    $before = @{
        Workspace = Get-Dacl $missing.Workspace
        UserHome = Get-Dacl $missing.UserHome
        Controller = Get-Dacl $missing.Controller
        Source = Get-Dacl $missing.Source
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
        Source = Get-Dacl $replaced.Source
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
        Source = Get-Dacl $replacementDirectory.Source
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
        Source = Get-Dacl $junction.Source
    }
    Invoke-Helper "Enter" $junction
    Remove-Item -LiteralPath $junction.Controller -Recurse -Force
    $junctionTargetDacl = Get-Dacl $junction.Workspace
    [void](New-Item -ItemType Junction -Path $junction.Controller -Target $junction.Workspace)
    Invoke-ExpectedLeaveFailure $junction "junction replacement was accepted"
    if ((Get-Dacl $junction.Workspace) -ne $junctionTargetDacl) {
        throw "junction target received the saved DACL"
    }
    [System.IO.Directory]::Delete($junction.Controller)
    Invoke-Helper "Leave" $junction
    Assert-Restored $junction $before

    $providerFailure = New-Round "provider-failure"
    $before = @{
        Workspace = Get-Dacl $providerFailure.Workspace
        UserHome = Get-Dacl $providerFailure.UserHome
        Controller = Get-Dacl $providerFailure.Controller
        Source = Get-Dacl $providerFailure.Source
    }
    Invoke-Helper "Enter" $providerFailure
    $originalState = Get-Content -LiteralPath $providerFailure.State -Raw
    $modifiedState = $originalState | ConvertFrom-Json
    $controllerEntry = @($modifiedState.paths | Where-Object {
        $_.kind -eq 'directory' -and $_.path -eq $providerFailure.Controller
    })
    if ($controllerEntry.Count -ne 1) {
        throw "recovery state did not uniquely bind the controller directory"
    }
    $controllerEntry[0].path = "HKLM:\\SOFTWARE"
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
