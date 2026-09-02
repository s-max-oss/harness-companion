param(
    [Parameter(Mandatory = $true)][string]$ManifestFile,
    [Parameter(Mandatory = $true)][string]$ReadyFile,
    [Parameter(Mandatory = $true)][string]$StopFile
)

$ErrorActionPreference = 'Stop'
$handles = [System.Collections.Generic.List[System.IO.FileStream]]::new()

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

    $ready = [ordered]@{
        schema_version = 1
        paths = @($manifest.paths)
        handle_count = $handles.Count
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($ReadyFile, $ready + "`n", [System.Text.UTF8Encoding]::new($false))

    while (-not [System.IO.File]::Exists($StopFile)) {
        Start-Sleep -Milliseconds 100
    }
}
finally {
    foreach ($handle in $handles) {
        $handle.Dispose()
    }
}
