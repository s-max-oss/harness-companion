param(
    [Parameter(Mandatory = $true)][string]$Guard,
    [Parameter(Mandatory = $true)][string]$TempRoot,
    [string]$LaunchSource = ''
)

$ErrorActionPreference = 'Stop'
[System.IO.Directory]::CreateDirectory($TempRoot) | Out-Null
$executable = Join-Path $TempRoot 'agent.exe'
$manifest = Join-Path $TempRoot 'manifest.json'
$ready = Join-Path $TempRoot 'ready.json'
$stop = Join-Path $TempRoot 'stop'
$stdout = Join-Path $TempRoot 'guard.stdout'
$stderr = Join-Path $TempRoot 'guard.stderr'

if ([string]::IsNullOrWhiteSpace($LaunchSource)) {
    [System.IO.File]::WriteAllBytes($executable, [byte[]](1, 2, 3, 4))
} else {
    [System.IO.File]::Copy($LaunchSource, $executable, $false)
}
$manifestJson = @{schema_version = 1; paths = @($executable)} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($manifest, $manifestJson + "`n", [System.Text.UTF8Encoding]::new($false))

$quote = { param([string]$Value) '"' + $Value.Replace('"', '\"') + '"' }
$arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (& $quote $Guard) +
    ' -ManifestFile ' + (& $quote $manifest) +
    ' -ReadyFile ' + (& $quote $ready) +
    ' -StopFile ' + (& $quote $stop)
$process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
    -ArgumentList $arguments

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not [System.IO.File]::Exists($ready) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not [System.IO.File]::Exists($ready) -or $process.HasExited) {
        throw 'guard did not become ready'
    }

    if (-not [string]::IsNullOrWhiteSpace($LaunchSource)) {
        $launchOutput = & $executable
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($launchOutput | Out-String))) {
            throw 'locked executable could not be launched'
        }
    }

    $overwriteBlocked = $false
    try {
        [System.IO.File]::WriteAllBytes($executable, [byte[]](9, 9, 9, 9))
    } catch [System.IO.IOException] {
        $overwriteBlocked = $true
    } catch [System.UnauthorizedAccessException] {
        $overwriteBlocked = $true
    }
    if (-not $overwriteBlocked) {
        throw 'guard allowed executable overwrite'
    }

    $replacement = Join-Path $TempRoot 'replacement.exe'
    [System.IO.File]::WriteAllBytes($replacement, [byte[]](8, 8, 8, 8))
    $replaceBlocked = $false
    try {
        Move-Item -LiteralPath $replacement -Destination $executable -Force -ErrorAction Stop
    } catch [System.IO.IOException] {
        $replaceBlocked = $true
    } catch [System.UnauthorizedAccessException] {
        $replaceBlocked = $true
    }
    if (-not $replaceBlocked) {
        throw 'guard allowed executable replacement'
    }

    [System.IO.File]::WriteAllText($stop, '')
    if (-not $process.WaitForExit(10000)) {
        throw 'guard did not stop'
    }
    [System.IO.File]::WriteAllBytes($executable, [byte[]](7, 7, 7, 7))
    if (([System.IO.File]::ReadAllBytes($executable))[0] -ne 7) {
        throw 'executable remained locked after guard exit'
    }
}
finally {
    if (-not $process.HasExited) {
        [System.IO.File]::WriteAllText($stop, '')
        if (-not $process.WaitForExit(2000)) {
            $process.Kill()
        }
    }
    $process.Dispose()
}

Write-Output 'windows executable guard: PASS'
