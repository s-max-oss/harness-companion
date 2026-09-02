param(
    [Parameter(Mandatory = $true)][string]$ManifestFile,
    [Parameter(Mandatory = $true)][string]$ReadyFile,
    [Parameter(Mandatory = $true)][string]$StopFile,
    [Parameter(Mandatory = $true)][string]$StateFile,
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$AgentLock,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$Nonce
)

$ErrorActionPreference = 'Stop'
$handles = [System.Collections.Generic.List[System.IO.FileStream]]::new()

function Write-Utf8CreateNew {
    param([string]$Path, [string]$Content)
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

try {
    $manifest = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
    if ($null -eq $manifest -or @($manifest.paths).Count -lt 1) {
        throw 'executable guard manifest has no paths'
    }

    foreach ($path in @($manifest.paths)) {
        $full = [System.IO.Path]::GetFullPath([string]$path)
        $handle = [System.IO.File]::Open(
            $full,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $handles.Add($handle)
    }

    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    $startTime = $process.StartTime.ToUniversalTime().ToString('o')
    $state = [ordered]@{
        schema_version = 1
        guard_pid = $PID
        guard_start_time_utc = $startTime
        nonce = $Nonce
        guard_script = [System.IO.Path]::GetFullPath($PSCommandPath)
        state_file = [System.IO.Path]::GetFullPath($StateFile)
        stop_file = [System.IO.Path]::GetFullPath($StopFile)
        run_root = [System.IO.Path]::GetFullPath($RunRoot)
        agent_lock = [System.IO.Path]::GetFullPath($AgentLock)
        paths = @($manifest.paths)
        handle_count = $handles.Count
    }
    $ready = $state | ConvertTo-Json -Compress
    Write-Utf8CreateNew -Path $StateFile -Content $ready
    Write-Utf8CreateNew -Path $ReadyFile -Content $ready
    [Console]::Out.WriteLine($ready)
    [Console]::Out.Flush()

    while (-not [System.IO.File]::Exists($StopFile)) {
        Start-Sleep -Milliseconds 100
    }
}
finally {
    foreach ($handle in $handles) {
        $handle.Dispose()
    }
}
