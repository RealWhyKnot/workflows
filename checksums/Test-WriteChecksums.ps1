#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Equal {
    [CmdletBinding()]
    [OutputType([void])]
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

function Assert-Substring {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Text, [string] $Needle, [string] $Because)
    if ($Text -notmatch [regex]::Escape($Needle)) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      expected to find: $Needle"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

$script:failures = 0
$writer = Join-Path $PSScriptRoot 'Write-Checksums.ps1'
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('checksums-' + [System.Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $sandbox
$previousDirectory = [System.IO.Directory]::GetCurrentDirectory()
Push-Location $sandbox
[System.IO.Directory]::SetCurrentDirectory($sandbox)
try {
    [System.IO.File]::WriteAllBytes('app-1.0.0-win-x64.zip', [byte[]]@(foreach ($i in 1..1024) { $i % 256 }))
    [System.IO.File]::WriteAllBytes('app-1.0.0-linux-x64.tar.gz', [byte[]]@(foreach ($i in 1..2048) { $i % 256 }))
    $null = New-Item -ItemType Directory -Force -Path 'payload/nested'
    [System.IO.File]::WriteAllText('payload/app.exe', 'binary')
    [System.IO.File]::WriteAllText('payload/nested/data.bin', 'more')

    $zipHash = (Get-FileHash -LiteralPath 'app-1.0.0-win-x64.zip' -Algorithm SHA256).Hash.ToLowerInvariant()
    $table = (& $writer -Archives @('*.zip', '*.tar.gz') -Contents 'payload') -join "`n"

    Assert-Substring -Text $table -Needle '| Asset | Size (MiB) | SHA-256 |' -Because 'the table header names the unit'
    Assert-Substring -Text $table -Needle "| ``app-1.0.0-win-x64.zip`` | 0.00 | ``$zipHash`` |" -Because (
        'the archive row carries the real hash')

    Assert-Equal -Actual (Test-Path 'app-1.0.0-win-x64.integrity.tsv') -Expected 'True' -Because (
        'a zip gets a manifest beside it')
    Assert-Equal -Actual (Test-Path 'app-1.0.0-linux-x64.integrity.tsv') -Expected 'True' -Because (
        'a .tar.gz loses both extensions, not just .gz')

    $manifest = @([System.IO.File]::ReadAllLines((Join-Path $sandbox 'app-1.0.0-win-x64.integrity.tsv')))
    $first = $manifest[0].Split("`t")
    Assert-Equal -Actual $first[0] -Expected $zipHash -Because 'the manifest opens with the archive hash'
    Assert-Equal -Actual $first[1] -Expected '1024' -Because 'then its byte count'
    Assert-Equal -Actual $first[2] -Expected 'app-1.0.0-win-x64.zip' -Because 'then its name'
    Assert-Equal -Actual "$($manifest.Count)" -Expected '3' -Because 'every file under -Contents adds a row'
    Assert-Substring -Text ($manifest -join "`n") -Needle 'nested/data.bin' -Because (
        'nested paths are recorded with forward slashes')

    $raw = [System.IO.File]::ReadAllBytes((Join-Path $sandbox 'app-1.0.0-win-x64.integrity.tsv'))
    if ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
        Write-Host 'FAIL: the manifest has a UTF-8 BOM' -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host 'ok: the manifest has no BOM'
    }

    $mb = (& $writer -Archives @('app-1.0.0-linux-x64.tar.gz') -Units MB -NoManifest) -join "`n"
    Assert-Substring -Text $mb -Needle '| Asset | Size (MB) | SHA-256 |' -Because (
        'MB is decimal, and the header says so')
    Assert-Substring -Text $mb -Needle '| 0.00 |' -Because 'the size renders to two places'

    $null = & $writer -Archives @('app-1.0.0-win-x64.zip') -TableFile 'table.md'
    Assert-Equal -Actual (Test-Path 'table.md') -Expected 'True' -Because '-TableFile writes the markdown out'

    $threw = $false
    try {
        $null = & $writer -Archives @('nothing-here-*.zip')
    } catch [System.Management.Automation.RuntimeException] {
        $threw = $true
    }
    Assert-Equal -Actual "$threw" -Expected 'True' -Because 'a pattern matching nothing is an error, not an empty table'

    $null = New-Item -ItemType Directory -Force -Path 'sib/app-2.0.0-win-x64'
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'sib/app-2.0.0-win-x64/only.txt'), 'inside')
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'sib/app-2.0.0-win-x64.zip'), [byte[]](1..16))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'sib/app-2.0.0-osx-x64.zip'), [byte[]](1..32))
    $null = & $writer -Archives @('sib/*.zip')
    $sibling = @([System.IO.File]::ReadAllLines((Join-Path $sandbox 'sib/app-2.0.0-win-x64.integrity.tsv')))
    Assert-Equal -Actual "$($sibling.Count)" -Expected '2' -Because (
        'with no -Contents, an archive picks up its own sibling directory')
    Assert-Substring -Text ($sibling -join "`n") -Needle 'only.txt' -Because (
        'and lists that directory only, not another archive''s')
    $lonely = @([System.IO.File]::ReadAllLines((Join-Path $sandbox 'sib/app-2.0.0-osx-x64.integrity.tsv')))
    Assert-Equal -Actual "$($lonely.Count)" -Expected '1' -Because (
        'an archive with no sibling directory gets just its own row')
} finally {
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
