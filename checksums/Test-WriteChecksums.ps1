#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:failures = 0

function Assert-Equal {
    param([string] $Actual, [string] $Expected, [string] $Because)
    if ($Actual -ne $Expected) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

function Assert-Contains {
    param([string] $Text, [string] $Needle, [string] $Because)
    if ($Text -notmatch [regex]::Escape($Needle)) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      expected to find: $Needle"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

$writer = Join-Path $PSScriptRoot 'Write-Checksums.ps1'
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("checksums-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $sandbox | Out-Null
$previousDirectory = [System.IO.Directory]::GetCurrentDirectory()
Push-Location $sandbox
[System.IO.Directory]::SetCurrentDirectory($sandbox)
try {
    [System.IO.File]::WriteAllBytes('app-1.0.0-win-x64.zip', [byte[]]((1..1024) | ForEach-Object { $_ % 256 }))
    [System.IO.File]::WriteAllBytes('app-1.0.0-linux-x64.tar.gz', [byte[]]((1..2048) | ForEach-Object { $_ % 256 }))
    New-Item -ItemType Directory -Force 'payload/nested' | Out-Null
    [System.IO.File]::WriteAllText('payload/app.exe', 'binary')
    [System.IO.File]::WriteAllText('payload/nested/data.bin', 'more')

    $zipHash = (Get-FileHash -LiteralPath 'app-1.0.0-win-x64.zip' -Algorithm SHA256).Hash.ToLowerInvariant()
    $table = (& $writer -Archives @('*.zip', '*.tar.gz') -Contents 'payload') -join "`n"

    Assert-Contains $table '| Asset | Size (MiB) | SHA-256 |' 'the table header names the unit'
    Assert-Contains $table "| ``app-1.0.0-win-x64.zip`` | 0.00 | ``$zipHash`` |" 'the archive row carries the real hash'

    Assert-Equal (Test-Path 'app-1.0.0-win-x64.integrity.tsv') 'True' 'a zip gets a manifest beside it'
    Assert-Equal (Test-Path 'app-1.0.0-linux-x64.integrity.tsv') 'True' 'a .tar.gz loses both extensions, not just .gz'

    $manifest = @(Get-Content 'app-1.0.0-win-x64.integrity.tsv')
    $first = $manifest[0].Split("`t")
    Assert-Equal $first[0] $zipHash 'the manifest opens with the archive hash'
    Assert-Equal $first[1] '1024' 'then its byte count'
    Assert-Equal $first[2] 'app-1.0.0-win-x64.zip' 'then its name'
    Assert-Equal "$($manifest.Count)" '3' 'every file under -Contents adds a row'
    Assert-Contains ($manifest -join "`n") 'nested/data.bin' 'nested paths are recorded with forward slashes'

    $raw = [System.IO.File]::ReadAllBytes((Join-Path $sandbox 'app-1.0.0-win-x64.integrity.tsv'))
    if ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
        Write-Host 'FAIL: the manifest has a UTF-8 BOM' -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host 'ok: the manifest has no BOM'
    }

    $mb = (& $writer -Archives @('app-1.0.0-linux-x64.tar.gz') -Units MB -NoManifest) -join "`n"
    Assert-Contains $mb '| Asset | Size (MB) | SHA-256 |' 'MB is decimal, and the header says so'
    Assert-Contains $mb '| 0.00 |' 'the size renders to two places'

    & $writer -Archives @('app-1.0.0-win-x64.zip') -TableFile 'table.md' | Out-Null
    Assert-Equal (Test-Path 'table.md') 'True' '-TableFile writes the markdown out'

    $threw = $false
    try { & $writer -Archives @('nothing-here-*.zip') | Out-Null } catch { $threw = $true }
    Assert-Equal "$threw" 'True' 'a pattern matching nothing is an error, not an empty table'
}
finally {
    [System.IO.Directory]::SetCurrentDirectory($previousDirectory)
    Pop-Location
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$script:failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
