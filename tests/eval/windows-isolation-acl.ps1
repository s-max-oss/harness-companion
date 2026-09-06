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

    [string]$EvidenceFile,

    [string]$ProcessStateFile,
    [string]$ProcessStateStageFile,
    [string]$ProcessContinueFile,
    [string]$ProcessAbortFile,
    [string]$ProcessRecoveryFile,
    [string]$ProcessNonce,
    [string]$RecoveryJournal,
    [switch]$TestPauseBeforeState,
    [switch]$TestPauseAfterState
)

$ErrorActionPreference = "Stop"

if (-not ("HarnessEval.NativeDirectoryAcl" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using Microsoft.Win32.SafeHandles;

namespace HarnessEval {
    public static class NativeDirectoryAcl {
        private const uint READ_CONTROL = 0x00020000;
        private const uint WRITE_DAC = 0x00040000;
        private const uint FILE_SHARE_READ_WRITE = 0x00000003;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
        private const int DACL_SECURITY_INFORMATION = 0x00000004;
        private const int UNPROTECTED_DACL_SECURITY_INFORMATION = 0x20000000;
        private const int PROTECTED_DACL_SECURITY_INFORMATION = unchecked((int)0x80000000);
        private const int ERROR_INSUFFICIENT_BUFFER = 122;

        public sealed class DirectoryAclSnapshot {
            public string Identity { get; private set; }
            public string Sddl { get; private set; }

            public DirectoryAclSnapshot(string identity, string sddl) {
                Identity = identity;
                Sddl = sddl;
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle handle,
            out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorDacl(
            IntPtr securityDescriptor,
            [MarshalAs(UnmanagedType.Bool)] out bool daclPresent,
            out IntPtr dacl,
            [MarshalAs(UnmanagedType.Bool)] out bool daclDefaulted);

        [DllImport("advapi32.dll")]
        private static extern uint SetSecurityInfo(
            SafeFileHandle handle,
            int objectType,
            int securityInformation,
            IntPtr owner,
            IntPtr group,
            IntPtr dacl,
            IntPtr sacl);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetKernelObjectSecurity(
            SafeFileHandle handle,
            int securityInformation,
            byte[] securityDescriptor,
            uint length,
            out uint lengthNeeded);

        private static SafeFileHandle Open(string path, uint access) {
            SafeFileHandle handle = CreateFile(
                path,
                access,
                FILE_SHARE_READ_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "unable to open protected directory: " + path);
            }
            return handle;
        }

        private static string Describe(SafeFileHandle handle, string path) {
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information)) {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "unable to identify protected directory: " + path);
            }
            if ((information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
                throw new InvalidOperationException("protected path is not a directory: " + path);
            }
            if ((information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                throw new InvalidOperationException("protected directory is a reparse point: " + path);
            }
            return String.Format(
                System.Globalization.CultureInfo.InvariantCulture,
                "{0:X8}:{1:X8}{2:X8}",
                information.VolumeSerialNumber,
                information.FileIndexHigh,
                information.FileIndexLow);
        }

        public static DirectoryAclSnapshot GetSnapshot(string path) {
            using (SafeFileHandle handle = Open(path, READ_CONTROL)) {
                string identity = Describe(handle, path);
                uint lengthNeeded;
                bool initial = GetKernelObjectSecurity(
                    handle,
                    DACL_SECURITY_INFORMATION,
                    null,
                    0,
                    out lengthNeeded);
                int initialError = Marshal.GetLastWin32Error();
                if (initial || lengthNeeded == 0 ||
                        initialError != ERROR_INSUFFICIENT_BUFFER) {
                    throw new Win32Exception(
                        initialError,
                        "unable to size protected directory DACL: " + path);
                }
                byte[] securityDescriptor = new byte[lengthNeeded];
                if (!GetKernelObjectSecurity(
                        handle,
                        DACL_SECURITY_INFORMATION,
                        securityDescriptor,
                        lengthNeeded,
                        out lengthNeeded)) {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "unable to read protected directory DACL: " + path);
                }
                RawSecurityDescriptor descriptor =
                    new RawSecurityDescriptor(securityDescriptor, 0);
                return new DirectoryAclSnapshot(
                    identity,
                    descriptor.GetSddlForm(AccessControlSections.Access));
            }
        }

        public static void ApplyDacl(
            string path,
            string expectedIdentity,
            byte[] securityDescriptor) {
            using (SafeFileHandle handle = Open(path, READ_CONTROL | WRITE_DAC)) {
                string actualIdentity = Describe(handle, path);
                if (!String.Equals(actualIdentity, expectedIdentity, StringComparison.Ordinal)) {
                    throw new InvalidOperationException(
                        "protected directory identity changed: " + path);
                }
                RawSecurityDescriptor descriptor =
                    new RawSecurityDescriptor(securityDescriptor, 0);
                bool accessRulesProtected =
                    (descriptor.ControlFlags &
                        ControlFlags.DiscretionaryAclProtected) != 0;
                int securityInformation = DACL_SECURITY_INFORMATION |
                    (accessRulesProtected
                        ? PROTECTED_DACL_SECURITY_INFORMATION
                        : UNPROTECTED_DACL_SECURITY_INFORMATION);
                GCHandle pinned = GCHandle.Alloc(
                    securityDescriptor,
                    GCHandleType.Pinned);
                try {
                    bool daclPresent;
                    bool daclDefaulted;
                    IntPtr dacl;
                    if (!GetSecurityDescriptorDacl(
                            pinned.AddrOfPinnedObject(),
                            out daclPresent,
                            out dacl,
                            out daclDefaulted)) {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "unable to read protected directory DACL: " + path);
                    }
                    if (!daclPresent) {
                        throw new InvalidOperationException(
                            "protected directory descriptor has no DACL: " + path);
                    }
                    uint result = SetSecurityInfo(
                        handle,
                        1,
                        securityInformation,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        dacl,
                        IntPtr.Zero);
                    if (result != 0) {
                        throw new Win32Exception(
                            (int)result,
                            "unable to apply protected directory DACL: " + path);
                    }
                    // The untrusted sandbox child is not alive while Enter or
                    // Leave executes. Re-resolve the pathname before returning
                    // so accidental or trusted-controller churn is still
                    // detected and leaves the recovery journal intact.
                    using (SafeFileHandle current = Open(path, READ_CONTROL)) {
                        string currentIdentity = Describe(current, path);
                        if (!String.Equals(
                                currentIdentity,
                                expectedIdentity,
                                StringComparison.Ordinal)) {
                            throw new InvalidOperationException(
                                "protected directory changed during DACL application: " + path);
                        }
                    }
                } finally {
                    pinned.Free();
                }
            }
        }
    }
}
"@
}

function Get-DirectoryDaclSnapshot([string]$Path) {
    return [HarnessEval.NativeDirectoryAcl]::GetSnapshot($Path)
}

function Set-DirectoryDacl(
    [string]$Path,
    [string]$ExpectedIdentity,
    [System.Security.AccessControl.DirectorySecurity]$Security
) {
    [HarnessEval.NativeDirectoryAcl]::ApplyDacl(
        $Path,
        $ExpectedIdentity,
        $Security.GetSecurityDescriptorBinaryForm()
    )
}

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

function Write-JsonCreateNew([object]$Value, [string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "process-state parent is missing: $parent"
    }
    $json = ($Value | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8WithoutBom.GetBytes($json)
    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Assert-HandshakePath([string]$Path, [string]$Root, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the controller root: $Path"
    }
    return $full
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
    if ([int]$state.schema_version -ne 2) {
        throw "unsupported ACL restoration state schema: $($state.schema_version)"
    }
    $restoreEntries = @($state.paths)
    [Array]::Reverse($restoreEntries)
    foreach ($entry in $restoreEntries) {
        # A failed run may remove its private controller tree before a later
        # recovery attempt. An absent directory has no ACL left to restore,
        # but a replacement non-directory remains unsafe and must fail closed.
        try {
            $directory = Get-Item -LiteralPath ([string]$entry.path) -Force -ErrorAction Stop
        } catch [System.Management.Automation.ItemNotFoundException] {
            continue
        }
        if (-not $directory.PSIsContainer) {
            throw "ACL restoration path is no longer a directory: $($entry.path)"
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.identity)) {
            throw "ACL restoration entry is missing its directory identity: $($entry.path)"
        }
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetSecurityDescriptorSddlForm(
            [string]$entry.sddl,
            [System.Security.AccessControl.AccessControlSections]::Access
        )
        Set-DirectoryDacl ([string]$entry.path) ([string]$entry.identity) $security
    }
    Remove-Item -LiteralPath $StateFile -Force
    exit 0
}

$handshakeValues = @(
    $ProcessStateFile, $ProcessStateStageFile, $ProcessContinueFile, $ProcessAbortFile,
    $ProcessRecoveryFile, $ProcessNonce, $RecoveryJournal
)
$hasHandshake = @($handshakeValues | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0
if ($hasHandshake -and @($handshakeValues | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
    throw 'ACL Enter process handshake must provide every handshake field'
}
if (($TestPauseBeforeState -or $TestPauseAfterState) -and -not $hasHandshake) {
    throw 'ACL Enter test pauses require the process handshake'
}

if ($hasHandshake) {
    if ($ProcessNonce -notmatch '^[0-9a-f]{64}$') { throw 'invalid ACL Enter process nonce' }
    $handshakeRoot = Split-Path -Parent ([IO.Path]::GetFullPath($RecoveryJournal))
    $ProcessStateFile = Assert-HandshakePath $ProcessStateFile $handshakeRoot 'process state path'
    $ProcessStateStageFile = Assert-HandshakePath $ProcessStateStageFile $handshakeRoot 'process state stage path'
    $ProcessContinueFile = Assert-HandshakePath $ProcessContinueFile $handshakeRoot 'process continue path'
    $ProcessAbortFile = Assert-HandshakePath $ProcessAbortFile $handshakeRoot 'process abort path'
    $ProcessRecoveryFile = Assert-HandshakePath $ProcessRecoveryFile $handshakeRoot 'process recovery path'
    foreach ($path in @($ProcessStateFile, $ProcessStateStageFile, $ProcessContinueFile, $ProcessAbortFile, $ProcessRecoveryFile)) {
        if (Test-Path -LiteralPath $path) { throw "stale ACL Enter handshake path exists: $path" }
    }
    if (-not (Test-Path -LiteralPath $RecoveryJournal -PathType Leaf)) {
        throw "ACL Enter recovery journal is missing: $RecoveryJournal"
    }
    if ($TestPauseBeforeState) {
        while (-not (Test-Path -LiteralPath $ProcessAbortFile -PathType Leaf)) {
            if (-not (Test-Path -LiteralPath $RecoveryJournal -PathType Leaf)) { exit 3 }
            Start-Sleep -Milliseconds 25
        }
        exit 3
    }
    $self = Get-Process -Id $PID -ErrorAction Stop
    $selfCim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $PID) -ErrorAction Stop
    Write-JsonCreateNew ([ordered]@{
        schema_version = 1
        nonce = $ProcessNonce
        recovery_journal = [IO.Path]::GetFullPath($RecoveryJournal)
        helper_script = [IO.Path]::GetFullPath($PSCommandPath)
        state_file = $ProcessStateFile
        state_stage_file = $ProcessStateStageFile
        continue_file = $ProcessContinueFile
        abort_file = $ProcessAbortFile
        recovery_file = $ProcessRecoveryFile
        process = [ordered]@{
            pid = [int]$PID
            start_time_utc = $self.StartTime.ToUniversalTime().ToString('o')
            name = [string]$selfCim.Name
            command_line = [string]$selfCim.CommandLine
        }
    }) $ProcessStateStageFile
    [IO.File]::Move($ProcessStateStageFile, $ProcessStateFile)

    while (-not (Test-Path -LiteralPath $ProcessContinueFile -PathType Leaf)) {
        if ((Test-Path -LiteralPath $ProcessAbortFile -PathType Leaf) -or
            -not (Test-Path -LiteralPath $RecoveryJournal -PathType Leaf)) {
            Remove-Item -LiteralPath $ProcessStateFile -Force -ErrorAction SilentlyContinue
            exit 3
        }
        Start-Sleep -Milliseconds 25
    }
    if ((Test-Path -LiteralPath $ProcessAbortFile -PathType Leaf) -or
        -not (Test-Path -LiteralPath $RecoveryJournal -PathType Leaf)) {
        Remove-Item -LiteralPath $ProcessStateFile -Force -ErrorAction SilentlyContinue
        exit 3
    }
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
    $snapshot = Get-DirectoryDaclSnapshot $path
    [pscustomobject]@{
        path     = $path
        identity = $snapshot.Identity
        sddl     = $snapshot.Sddl
    }
}

Write-JsonAtomic ([pscustomobject]@{
    schema_version = 2
    created_at_utc = [DateTime]::UtcNow.ToString("o")
    paths = @($saved)
}) $StateFile

if ($TestPauseAfterState) {
    while (-not (Test-Path -LiteralPath $ProcessRecoveryFile -PathType Leaf)) {
        if (Test-Path -LiteralPath $ProcessAbortFile -PathType Leaf) {
            & $PSCommandPath -Mode Leave -WorkspaceRoot $WorkspaceRoot -ControllerRoot $ControllerRoot `
                -UserHome $UserHome -StateFile $StateFile
            exit 3
        }
        Start-Sleep -Milliseconds 25
    }
    if (Test-Path -LiteralPath $ProcessAbortFile -PathType Leaf) {
        & $PSCommandPath -Mode Leave -WorkspaceRoot $WorkspaceRoot -ControllerRoot $ControllerRoot `
            -UserHome $UserHome -StateFile $StateFile
        exit 3
    }
}

try {
    foreach ($path in $paths) {
        $savedEntry = @($saved | Where-Object { $_.path -eq $path })
        if ($savedEntry.Count -ne 1) {
            throw "ACL state does not uniquely identify protected directory: $path"
        }
        $expectedIdentity = [string]$savedEntry[0].identity
        $snapshot = Get-DirectoryDaclSnapshot $path
        if ($snapshot.Identity -ne $expectedIdentity) {
            throw "protected directory changed before deny installation: $path"
        }
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorSddlForm(
            $snapshot.Sddl,
            [System.Security.AccessControl.AccessControlSections]::Access
        )
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
        Set-DirectoryDacl $path $expectedIdentity $acl
    }

    $checks = foreach ($path in $paths) {
        $savedEntry = @($saved | Where-Object { $_.path -eq $path })
        $snapshot = Get-DirectoryDaclSnapshot $path
        if ($savedEntry.Count -ne 1 -or
            $snapshot.Identity -ne [string]$savedEntry[0].identity) {
            throw "protected directory changed before isolation verification: $path"
        }
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorSddlForm(
            $snapshot.Sddl,
            [System.Security.AccessControl.AccessControlSections]::Access
        )
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
