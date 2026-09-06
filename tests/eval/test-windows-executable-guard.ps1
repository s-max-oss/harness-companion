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
$state = Join-Path $TempRoot 'guard-state.json'
$journal = Join-Path $TempRoot 'recovery-journal.json'
$agentLock = Join-Path $TempRoot 'agent.lock'
$stdout = Join-Path $TempRoot 'guard.stdout'
$stderr = Join-Path $TempRoot 'guard.stderr'
$nonce = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
[System.IO.Directory]::CreateDirectory($agentLock) | Out-Null
[System.IO.File]::WriteAllText($journal, "{}`n", [System.Text.UTF8Encoding]::new($false))

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
    ' -StopFile ' + (& $quote $stop) +
    ' -StateFile ' + (& $quote $state) +
    ' -RunRoot ' + (& $quote $TempRoot) +
    ' -AgentLock ' + (& $quote $agentLock) +
    ' -RecoveryJournal ' + (& $quote $journal) +
    ' -Nonce ' + $nonce
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
    if (-not [System.IO.File]::Exists($state)) {
        throw 'guard did not persist recovery state'
    }
    $readyObject = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
    $stateObject = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
    if ($readyObject.nonce -ne $nonce -or $stateObject.nonce -ne $nonce -or
        $readyObject.guard_pid -ne $stateObject.guard_pid -or
        $readyObject.guard_start_time_utc -ne $stateObject.guard_start_time_utc -or
        $readyObject.stop_file -ne $stateObject.stop_file) {
        throw 'guard ready signal and persisted recovery state differ'
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
    [System.IO.File]::Delete($state)
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

$forgedRoot = Join-Path $TempRoot 'forged-ready'
[System.IO.Directory]::CreateDirectory($forgedRoot) | Out-Null
$forgedExecutable = Join-Path $forgedRoot 'agent.exe'
$forgedManifest = Join-Path $forgedRoot 'manifest.json'
$forgedReady = Join-Path $forgedRoot 'ready.json'
$forgedStop = Join-Path $forgedRoot 'stop'
$forgedState = Join-Path $forgedRoot 'state.json'
$forgedJournal = Join-Path $forgedRoot 'recovery-journal.json'
$forgedLock = Join-Path $forgedRoot 'agent.lock'
[System.IO.Directory]::CreateDirectory($forgedLock) | Out-Null
[System.IO.File]::WriteAllText($forgedJournal, "{}`n", [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllBytes($forgedExecutable, [byte[]](1, 2, 3, 4))
[System.IO.File]::WriteAllText($forgedManifest, (@{schema_version=1;paths=@($forgedExecutable)} | ConvertTo-Json -Compress) + "`n", [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($forgedReady, '{"forged":true}', [System.Text.UTF8Encoding]::new($false))
$forgedArguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (& $quote $Guard) +
    ' -ManifestFile ' + (& $quote $forgedManifest) + ' -ReadyFile ' + (& $quote $forgedReady) +
    ' -StopFile ' + (& $quote $forgedStop) + ' -StateFile ' + (& $quote $forgedState) +
    ' -RunRoot ' + (& $quote $forgedRoot) + ' -AgentLock ' + (& $quote $forgedLock) +
    ' -RecoveryJournal ' + (& $quote $forgedJournal) +
    ' -Nonce ' + $nonce
$forgedProcess = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList $forgedArguments
try {
    if (-not $forgedProcess.WaitForExit(10000) -or $forgedProcess.ExitCode -eq 0) {
        throw 'guard accepted a pre-existing forged ready file'
    }
    if (-not (Test-Path -LiteralPath $forgedState -PathType Leaf)) {
        throw 'guard failure did not retain recovery state'
    }
    [System.IO.File]::Delete($forgedState)
}
finally {
    if (-not $forgedProcess.HasExited) { $forgedProcess.Kill() }
    $forgedProcess.Dispose()
}

Write-Output 'windows executable guard: PASS'
