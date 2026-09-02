$ErrorActionPreference = "Stop"

$payloadEncoded = [System.Environment]::GetEnvironmentVariable("HARNESS_EVAL_PROBE_PAYLOAD")
if ([string]::IsNullOrWhiteSpace($payloadEncoded)) {
    throw "HARNESS_EVAL_PROBE_PAYLOAD is required"
}
$payloadJson = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($payloadEncoded)
)
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

$targetDir = [System.IO.Path]::GetDirectoryName($payload.target_file)
$marker = Join-Path $targetDir (".harness-eval-write-" + $payload.nonce + ".tmp")
$targetWrite = $false
try {
    [System.IO.File]::WriteAllText($marker, $payload.nonce)
    $targetWrite = ([System.IO.File]::ReadAllText($marker) -eq $payload.nonce)
} finally {
    if ([System.IO.File]::Exists($marker)) {
        [System.IO.File]::Delete($marker)
    }
}

[ordered]@{
    nonce = $payload.nonce
    identity = (& whoami.exe).Trim()
    target_file_readable = Test-FileRead $payload.target_file
    target_writeable = $targetWrite
    source_workspace_readable = Test-FileRead $payload.source_file
    controller_readable = Test-FileRead $payload.controller_file
    user_home_readable = Test-DirectoryList $payload.user_home
} | ConvertTo-Json -Compress
