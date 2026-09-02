param(
    [Parameter(Mandatory = $true)][string]$Helper,
    [Parameter(Mandatory = $true)][string]$Guard,
    [Parameter(Mandatory = $true)][string]$Recovery,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Bash
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$state = Join-Path $RepoRoot '.harness\eval-acl-state.json'
$guardState = Join-Path $RepoRoot '.harness\eval-guard-state.json'
$aclLock = Join-Path $RepoRoot '.harness\eval-acl.lock'
$agentLock = Join-Path $RepoRoot 'tests\eval\candidates\.eval-agent.lock'
$publicRuns = 'C:\Users\Public\harness-companion-eval\runs'
$runRoot = Join-Path $publicRuns ('run.recovery-test-' + [Guid]::NewGuid().ToString('N'))
$aclRoot = Join-Path ([IO.Path]::GetTempPath()) ('harness-recovery-acl-' + [Guid]::NewGuid().ToString('N'))
$workspace = Join-Path $aclRoot 'workspace'
$testUserHome = Join-Path $aclRoot 'home'
$aclController = Join-Path $aclRoot 'controller'
$controller = Join-Path $runRoot 'controller'
$executable = Join-Path $runRoot 'agent.exe'
$manifest = Join-Path $controller 'manifest.json'
$ready = Join-Path $controller 'ready.json'
$stop = Join-Path $controller 'stop'
$stdout = Join-Path $controller 'stdout.log'
$stderr = Join-Path $controller 'stderr.log'
$nonce = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).ToLowerInvariant()
$guardProcess = $null
$entered = $false

function Get-Dacl([string]$Path) {
    (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::Access
    )
}

foreach ($path in @($state, $guardState, $aclLock, $agentLock)) {
    if (Test-Path -LiteralPath $path) {
        throw "recovery contract requires an idle eval state: $path"
    }
}

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.Directory]::CreateDirectory($testUserHome) | Out-Null
    [IO.Directory]::CreateDirectory($aclController) | Out-Null
    [IO.Directory]::CreateDirectory($controller) | Out-Null
    [IO.Directory]::CreateDirectory((Split-Path -Parent $state)) | Out-Null
    [IO.File]::Copy('C:\Windows\System32\whoami.exe', $executable, $false)
    [IO.File]::WriteAllText($manifest, (@{schema_version=1;paths=@($executable)} | ConvertTo-Json -Compress) + "`n", [Text.UTF8Encoding]::new($false))
    $before = @{Workspace=Get-Dacl $workspace; UserHome=Get-Dacl $testUserHome; Controller=Get-Dacl $aclController}

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Helper -Mode Enter `
        -WorkspaceRoot $workspace -ControllerRoot $aclController -UserHome $testUserHome -StateFile $state
    if ($LASTEXITCODE -ne 0) { throw "ACL Enter failed with exit $LASTEXITCODE" }
    $entered = $true

    [IO.Directory]::CreateDirectory($agentLock) | Out-Null
    [IO.Directory]::CreateDirectory($aclLock) | Out-Null
    [IO.File]::WriteAllText((Join-Path $aclLock 'owner.pid'), "2147483647`n", [Text.UTF8Encoding]::new($false))
    $quote = { param([string]$Value) '"' + $Value.Replace('"', '\"') + '"' }
    $args = '-NoProfile -ExecutionPolicy Bypass -File ' + (& $quote $Guard) +
        ' -ManifestFile ' + (& $quote $manifest) + ' -ReadyFile ' + (& $quote $ready) +
        ' -StopFile ' + (& $quote $stop) + ' -StateFile ' + (& $quote $guardState) +
        ' -RunRoot ' + (& $quote $runRoot) + ' -AgentLock ' + (& $quote $agentLock) +
        ' -Nonce ' + $nonce
    $guardProcess = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ArgumentList $args
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ready -PathType Leaf) -and -not $guardProcess.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $ready -PathType Leaf) -or $guardProcess.HasExited) {
        throw 'orphan guard did not become ready'
    }

    & $Bash $Recovery
    if ($LASTEXITCODE -ne 0) { throw "recovery command failed with exit $LASTEXITCODE" }
    if (-not $guardProcess.WaitForExit(5000)) { throw 'recovery left the executable guard running' }
    $entered = $false
    if ((Get-Dacl $workspace) -ne $before.Workspace -or (Get-Dacl $testUserHome) -ne $before.UserHome -or
        (Get-Dacl $aclController) -ne $before.Controller) { throw 'recovery did not restore all recorded DACLs' }
    foreach ($path in @($state, $guardState, $aclLock, $agentLock, $runRoot)) {
        if (Test-Path -LiteralPath $path) { throw "recovery left stale state: $path" }
    }
}
finally {
    if ($null -ne $guardProcess -and -not $guardProcess.HasExited) {
        [IO.File]::WriteAllText($stop, '')
        if (-not $guardProcess.WaitForExit(2000)) { $guardProcess.Kill() }
    }
    if ($null -ne $guardProcess) { $guardProcess.Dispose() }
    if ($entered -and (Test-Path -LiteralPath $state -PathType Leaf)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Helper -Mode Leave `
            -WorkspaceRoot $workspace -ControllerRoot $aclController -UserHome $testUserHome -StateFile $state 2>$null
    }
    foreach ($path in @($agentLock, $aclLock)) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            try { [IO.Directory]::Delete($path, $true) } catch {}
        }
    }
    foreach ($path in @($guardState, $state)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { try { [IO.File]::Delete($path) } catch {} }
    }
    if (Test-Path -LiteralPath $runRoot -PathType Container) {
        try { [IO.Directory]::Delete($runRoot, $true) } catch {}
    }
    if (Test-Path -LiteralPath $aclRoot -PathType Container) {
        try { [IO.Directory]::Delete($aclRoot, $true) } catch {}
    }
}

Write-Output 'windows eval crash recovery: PASS'
