param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedPayloadSha256
)

$ErrorActionPreference = "Stop"

$payloadEncoded = [System.Environment]::GetEnvironmentVariable("HARNESS_EVAL_PROBE_PAYLOAD")
if ([string]::IsNullOrWhiteSpace($payloadEncoded)) {
    throw "HARNESS_EVAL_PROBE_PAYLOAD is required"
}
$payloadBytes = [System.Convert]::FromBase64String($payloadEncoded)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $payloadSha256 = ([System.BitConverter]::ToString($sha256.ComputeHash($payloadBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha256.Dispose()
}
if ($payloadSha256 -cne $ExpectedPayloadSha256) {
    throw "HARNESS_EVAL_PROBE_PAYLOAD hash mismatch"
}
$payloadJson = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
$payload = $payloadJson | ConvertFrom-Json

function Test-FileRead([string]$Path) {
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        try { [void]$stream.ReadByte() } finally { $stream.Dispose() }
        return $true
    } catch [System.UnauthorizedAccessException] {
        return $false
    } catch [System.Security.SecurityException] {
        return $false
    }
}

function Test-DirectoryList([string]$Path) {
    try {
        [void][System.IO.Directory]::GetFileSystemEntries($Path)
        return $true
    } catch [System.UnauthorizedAccessException] {
        return $false
    } catch [System.Security.SecurityException] {
        return $false
    }
}

function Test-FileWrite([string]$Path, [string]$Value) {
    try {
        [System.IO.File]::WriteAllText($Path, $Value)
        return ([System.IO.File]::ReadAllText($Path) -eq $Value)
    } catch [System.UnauthorizedAccessException] {
        return $false
    } catch [System.Security.SecurityException] {
        return $false
    } finally {
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Delete($Path)
        }
    }
}

$targetDir = [System.IO.Path]::GetDirectoryName($payload.target_file)
$marker = Join-Path $targetDir (".harness-eval-write-" + $payload.nonce + ".tmp")
$targetWrite = Test-FileWrite $marker $payload.nonce
$hostTempWrite = Test-FileWrite ([string]$payload.host_temp_marker) $payload.nonce

[ordered]@{
    nonce = $payload.nonce
    payload_sha256 = $payloadSha256
    identity = (& ([string]$payload.whoami_file)).Trim()
    target_file_readable = Test-FileRead $payload.target_file
    target_writeable = $targetWrite
    source_workspace_readable = Test-FileRead $payload.source_file
    controller_readable = Test-FileRead $payload.controller_file
    user_home_root_listable = Test-DirectoryList $payload.user_home
    context_authority_readable = Test-FileRead $payload.context_file
    user_executable_readable = Test-FileRead $payload.user_executable_file
    host_temp_writeable = $hostTempWrite
    shell_home = [System.Environment]::GetEnvironmentVariable("HOME")
    shell_userprofile = [System.Environment]::GetEnvironmentVariable("USERPROFILE")
    shell_temp = [System.Environment]::GetEnvironmentVariable("TEMP")
    shell_tmp = [System.Environment]::GetEnvironmentVariable("TMP")
} | ConvertTo-Json -Compress
