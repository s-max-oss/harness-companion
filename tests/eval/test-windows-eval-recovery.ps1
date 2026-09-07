param(
    [Parameter(Mandatory = $true)][string]$Runner,
    [Parameter(Mandatory = $true)][string]$Recovery,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Bash,
    [string[]]$Stages = @(
        'journal_update_staged', 'run_root_created', 'acl_owner_staged',
        'agent_lock_acquired', 'guard_active', 'isolation_entering_before_state', 'isolation_entering',
        'isolation_entering_after_state', 'isolation_active',
        'publication_paths_reserved', 'publication_staged', 'run_tree_removed'
    )
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$Runner = [IO.Path]::GetFullPath($Runner)
$Recovery = [IO.Path]::GetFullPath($Recovery)
$expectedRunner = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'tests\eval\run-eval.sh'))
if (-not $Runner.Equals($expectedRunner, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Runner must be the repository production eval runner'
}
$journal = Join-Path $RepoRoot '.harness\eval-recovery-journal.json'
$aclState = Join-Path $RepoRoot '.harness\eval-acl-state.json'
$guardState = Join-Path $RepoRoot '.harness\eval-guard-state.json'
$aclLock = Join-Path $RepoRoot '.harness\eval-acl.lock'
$owner = Join-Path $aclLock 'owner.json'
$agentLock = Join-Path $RepoRoot 'tests\eval\candidates\.eval-agent.lock'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('harness-production-recovery-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Assert-Idle {
    foreach ($path in @($journal, $aclState, $guardState, $aclLock, $agentLock)) {
        if (Test-Path -LiteralPath $path) { throw "recovery test requires idle state: $path" }
    }
}

function Stop-OrphanGuard {
    if (-not (Test-Path -LiteralPath $guardState -PathType Leaf)) { return }
    $state = Get-Content -LiteralPath $guardState -Raw | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath ([string]$state.stop_file))) {
        [IO.File]::WriteAllText([string]$state.stop_file, '')
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Get-Process -Id ([int]$state.guard_pid) -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (Get-Process -Id ([int]$state.guard_pid) -ErrorAction SilentlyContinue) {
        throw 'orphan guard did not stop during partial-cleanup setup'
    }
}

function Invoke-ProductionCrash {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [switch]$SimulatePidReuse,
        [switch]$StopGuardBeforeRecovery,
        [switch]$SimulateGuardPidReuse,
        [switch]$TestRecoveryFinalWindow
    )
    Assert-Idle
    $stdout = Join-Path $testRoot ($Stage + '.stdout.log')
    $stderr = Join-Path $testRoot ($Stage + '.stderr.log')
    $oldContract = $env:HARNESS_EVAL_CONTRACT_TEST
    $oldStage = $env:HARNESS_EVAL_TEST_HOLD_STAGE
    $process = $null
    try {
        $env:HARNESS_EVAL_CONTRACT_TEST = '1'
        $env:HARNESS_EVAL_TEST_HOLD_STAGE = $Stage
        $arguments = @(
            'tests/eval/run-eval.sh',
            'tests/eval/cases/vague-goal.json',
            '--model=gpt-5.4-mini',
            '--reviewer-model=gpt-5.4-mini'
        )
        $process = Start-Process -FilePath $Bash -WindowStyle Hidden -PassThru `
            -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
            -ArgumentList $arguments
        $holdTimeoutSeconds = if ($Stage -like 'isolation_*') { 240 } else { 60 }
        $deadline = [DateTime]::UtcNow.AddSeconds($holdTimeoutSeconds)
        $observed = $false
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $journal -PathType Leaf) {
                try {
                    $current = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
                    $expectedStage = switch ($Stage) {
                        'journal_update_staged' { 'planned' }
                        'acl_owner_staged' { 'run_root_created' }
                        'isolation_entering_before_state' { 'isolation_entering' }
                        'isolation_entering_after_state' { 'isolation_entering' }
                        default { $Stage }
                    }
                    $helperReady = $true
                    if ($Stage -eq 'journal_update_staged') {
                        $helperReady = Test-Path -LiteralPath ([string]$current.paths.journal_stage) -PathType Leaf
                    }
                    if ($Stage -eq 'acl_owner_staged') {
                        $helperReady = Test-Path -LiteralPath ([string]$current.paths.acl_owner_stage) -PathType Leaf
                    }
                    if ($Stage -like 'isolation_entering*') {
                        if ($Stage -eq 'isolation_entering_before_state') {
                            $helperReady = @(
                                Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                                    ([string]$_.Name).Equals('powershell.exe', [StringComparison]::OrdinalIgnoreCase) -and
                                    ([string]$_.CommandLine).Contains('windows-isolation-acl.ps1') -and
                                    ([string]$_.CommandLine).Contains('TestPauseBeforeState') -and
                                    ([string]$_.CommandLine).Contains([string]$current.nonce)
                                }
                            ).Count -eq 1
                        } else {
                            $helperReady = Test-Path -LiteralPath ([string]$current.paths.acl_helper_state) -PathType Leaf
                        }
                    }
                    if ($Stage -eq 'isolation_entering_after_state') {
                        $helperReady = $helperReady -and (Test-Path -LiteralPath $aclState -PathType Leaf)
                    }
                    if ([string]$current.stage -eq $expectedStage -and $helperReady) { $observed = $true; break }
                } catch {}
            }
            Start-Sleep -Milliseconds 25
        }
        if (-not $observed) {
            $details = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
            throw "production runner did not hold at $Stage (exit=$($process.ExitCode)): $details"
        }

        $record = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
        if ($record.schema_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$record.nonce) -or
            $record.controller.pid -le 0 -or -not ([string]$record.controller.name).Equals('bash.exe', [StringComparison]::OrdinalIgnoreCase) -or
            [string]::IsNullOrWhiteSpace([string]$record.controller.start_time_utc) -or
            [string]::IsNullOrWhiteSpace([string]$record.controller.command_line)) {
            throw "production lifecycle journal is incomplete at $Stage"
        }
        $controllerPid = [int]$record.controller.pid
        Write-Output "recovery-stage: $Stage launcher=$($process.Id) controller=$controllerPid"
        $runRoot = [string]$record.paths.run_root
        if ($Stage -ne 'run_tree_removed' -and -not (Test-Path -LiteralPath $runRoot -PathType Container)) {
            throw "journaled run root is missing at $Stage"
        }
        if ($Stage -eq 'run_tree_removed' -and (Test-Path -LiteralPath $runRoot)) {
            throw 'run-tree-removed stage still has a run root'
        }

        Stop-Process -Id $controllerPid -Force
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((Get-Process -Id $controllerPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
        }
        if (Get-Process -Id $controllerPid -ErrorAction SilentlyContinue) {
            throw "production controller did not terminate at $Stage"
        }
        if (-not $process.WaitForExit(10000)) {
            throw "Git Bash launcher did not retire after controller termination at $Stage"
        }

        if ($SimulatePidReuse) {
            if (-not (Test-Path -LiteralPath $owner -PathType Leaf)) { throw 'PID-reuse test has no owner metadata' }
            $ownerRecord = Get-Content -LiteralPath $owner -Raw | ConvertFrom-Json
            $ownerRecord.process.pid = $PID
            [IO.File]::WriteAllText($owner, ($ownerRecord | ConvertTo-Json -Compress -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
        }
        if ($StopGuardBeforeRecovery) { Stop-OrphanGuard }
        if ($SimulateGuardPidReuse) {
            if (-not (Test-Path -LiteralPath $guardState -PathType Leaf)) { throw 'guard PID-reuse test has no guard metadata' }
            $guardRecord = Get-Content -LiteralPath $guardState -Raw | ConvertFrom-Json
            $guardRecord.guard_pid = $PID
            [IO.File]::WriteAllText($guardState, ($guardRecord | ConvertTo-Json -Compress -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
        }

        if ($TestRecoveryFinalWindow) {
            $oldRecoveryExit = $env:HARNESS_EVAL_RECOVERY_TEST_EXIT_STAGE
            try {
                foreach ($recoveryStage in @('recovery_owner_staged', 'recovery_journal_staged', 'recovery_lock_released', 'recovery_complete_committed')) {
                    $env:HARNESS_EVAL_RECOVERY_TEST_EXIT_STAGE = $recoveryStage
                    & $Bash $Recovery
                    if ($LASTEXITCODE -ne 99) { throw "recovery final-window seam $recoveryStage returned $LASTEXITCODE instead of 99" }
                    if (-not (Test-Path -LiteralPath $journal -PathType Leaf)) { throw "$recoveryStage did not retain journal" }
                }
            } finally {
                $env:HARNESS_EVAL_RECOVERY_TEST_EXIT_STAGE = $oldRecoveryExit
            }
            if (Test-Path -LiteralPath $aclLock) { throw 'final-window recovery retained released ACL lock' }
        }
        & $Bash $Recovery
        if ($LASTEXITCODE -ne 0) { throw "production recovery failed at $Stage with exit $LASTEXITCODE" }
        $helperPaths = @(
            [string]$record.paths.acl_helper_state,
            [string]$record.paths.acl_helper_state_stage,
            [string]$record.paths.acl_helper_continue,
            [string]$record.paths.acl_helper_abort,
            [string]$record.paths.acl_helper_recovery
        )
        foreach ($path in @($journal, $aclState, $guardState, $aclLock, $agentLock, $runRoot) + $helperPaths) {
            if (Test-Path -LiteralPath $path) { throw "recovery left stale state after ${Stage}: $path" }
        }
    }
    finally {
        if (Test-Path -LiteralPath $journal -PathType Leaf) {
            try {
                $stale = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
                $stalePid = [int]$stale.controller.pid
                if (Get-Process -Id $stalePid -ErrorAction SilentlyContinue) {
                    Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        if ($null -ne $process -and -not $process.HasExited) {
            try { $process.Kill(); $process.WaitForExit(5000) | Out-Null } catch {}
        }
        if ($null -ne $process) { $process.Dispose() }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $env:HARNESS_EVAL_CONTRACT_TEST = $oldContract
        $env:HARNESS_EVAL_TEST_HOLD_STAGE = $oldStage
        if (Test-Path -LiteralPath $journal -PathType Leaf) {
            try { & $Bash $Recovery 2>$null | Out-Null } catch {}
        }
    }
}

try {
    foreach ($stage in $Stages) {
        switch ($stage) {
            'journal_update_staged' { Invoke-ProductionCrash -Stage $stage }
            'run_root_created' { Invoke-ProductionCrash -Stage $stage }
            'acl_owner_staged' { Invoke-ProductionCrash -Stage $stage }
            'agent_lock_acquired' { Invoke-ProductionCrash -Stage $stage -SimulatePidReuse }
            'guard_active' { Invoke-ProductionCrash -Stage $stage -StopGuardBeforeRecovery -SimulateGuardPidReuse }
            'isolation_entering_before_state' { Invoke-ProductionCrash -Stage $stage }
            'isolation_entering' { Invoke-ProductionCrash -Stage $stage }
            'isolation_entering_after_state' { Invoke-ProductionCrash -Stage $stage }
            'isolation_active' { Invoke-ProductionCrash -Stage $stage }
            'publication_paths_reserved' { Invoke-ProductionCrash -Stage $stage }
            'publication_staged' { Invoke-ProductionCrash -Stage $stage }
            'run_tree_removed' { Invoke-ProductionCrash -Stage $stage -TestRecoveryFinalWindow }
            default { throw "unsupported recovery test stage: $stage" }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $removed = $false
        # A crashed Windows process can keep its redirected log handles alive
        # briefly after every recovery assertion has completed.  The full
        # contract suite creates substantially more handle pressure than this
        # test in isolation, so allow those already-terminated handles to drain
        # while keeping cleanup bounded and fail-closed.
        $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(120)
        while (-not $removed -and [DateTime]::UtcNow -lt $cleanupDeadline) {
            try {
                [IO.Directory]::Delete($testRoot, $true)
                $removed = $true
            }
            catch [IO.IOException], [UnauthorizedAccessException] {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                Start-Sleep -Milliseconds 50
                $removed = -not (Test-Path -LiteralPath $testRoot)
            }
        }
        if (-not $removed) { throw "could not retire recovery test logs: $testRoot" }
    }
}

Write-Output 'windows production runner crash recovery: PASS'
