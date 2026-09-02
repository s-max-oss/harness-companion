param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Enter", "Leave")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ControllerRoot,

    [Parameter(Mandatory = $true)]
    [string]$UserHome,

    [Parameter(Mandatory = $true)]
    [string]$StateFile,

    [string]$EvidenceFile
)

$ErrorActionPreference = "Stop"

function Resolve-ExistingDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        throw "isolation path is not a directory: $Path"
    }
    return $item.FullName
}

function Write-JsonAtomic([object]$Value, [string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.tmp-$PID"
    $json = ($Value | ConvertTo-Json -Depth 8) + [Environment]::NewLine
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporary, $json, $utf8WithoutBom)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "$Path.backup-$PID"
        [System.IO.File]::Replace($temporary, $Path, $backup)
        Remove-Item -LiteralPath $backup -Force
    } else {
        [System.IO.File]::Move($temporary, $Path)
    }
}

$sandboxNames = @("CodexSandboxOffline", "CodexSandboxOnline")
$sandboxAccounts = foreach ($name in $sandboxNames) {
    $user = Get-LocalUser -Name $name -ErrorAction Stop
    if (-not $user.Enabled) {
        throw "required Codex sandbox account is disabled: $name"
    }
    [pscustomobject]@{
        Name = $name
        Sid  = $user.SID.Value
    }
}

if ($Mode -eq "Leave") {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        throw "ACL restoration state is missing: $StateFile"
    }
    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    $restoreEntries = @($state.paths)
    [Array]::Reverse($restoreEntries)
    foreach ($entry in $restoreEntries) {
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetSecurityDescriptorSddlForm(
            [string]$entry.sddl,
            [System.Security.AccessControl.AccessControlSections]::All
        )
        Set-Acl -LiteralPath ([string]$entry.path) -AclObject $security
    }
    Remove-Item -LiteralPath $StateFile -Force
    exit 0
}

if (Test-Path -LiteralPath $StateFile) {
    throw "stale ACL restoration state exists; restore it before entering: $StateFile"
}

$paths = @(
    Resolve-ExistingDirectory $WorkspaceRoot
    Resolve-ExistingDirectory $UserHome
    Resolve-ExistingDirectory $ControllerRoot
) | Select-Object -Unique

$saved = foreach ($path in $paths) {
    $acl = Get-Acl -LiteralPath $path
    [pscustomobject]@{
        path = $path
        sddl = $acl.GetSecurityDescriptorSddlForm(
            [System.Security.AccessControl.AccessControlSections]::All
        )
    }
}

Write-JsonAtomic ([pscustomobject]@{
    schema_version = 1
    created_at_utc = [DateTime]::UtcNow.ToString("o")
    paths = @($saved)
}) $StateFile

try {
    foreach ($path in $paths) {
        $acl = Get-Acl -LiteralPath $path
        foreach ($account in $sandboxAccounts) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                (New-Object System.Security.Principal.SecurityIdentifier($account.Sid)),
                [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
                ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                 [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Deny
            )
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $path -AclObject $acl
    }

    $checks = foreach ($path in $paths) {
        $acl = Get-Acl -LiteralPath $path
        foreach ($account in $sandboxAccounts) {
            $matching = @($acl.Access | Where-Object {
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and
                ($_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $account.Sid) -and
                (($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne 0)
            })
            if ($matching.Count -eq 0) {
                throw "failed to install read deny for $($account.Name) on $path"
            }
            [pscustomobject]@{
                path = $path
                sandbox_account = $account.Name
                sandbox_sid = $account.Sid
                read_execute_denied = $true
            }
        }
    }

    if ($EvidenceFile) {
        Write-JsonAtomic ([pscustomobject]@{
            schema_version = 1
            isolation = "windows-native-elevated-acl"
            sandbox_accounts = @($sandboxAccounts)
            denied_roots = @($paths)
            checks = @($checks)
            network = "codex-workspace-write-offline"
            controller_visible_to_agent = $false
            source_workspace_visible_to_agent = $false
            user_home_visible_to_agent = $false
        }) $EvidenceFile
    }
} catch {
    try {
        & $PSCommandPath -Mode Leave -WorkspaceRoot $WorkspaceRoot -ControllerRoot $ControllerRoot `
            -UserHome $UserHome -StateFile $StateFile
    } catch {
        Write-Error "ACL isolation failed and restoration also failed: $($_.Exception.Message)"
    }
    throw
}
