#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $Version = '3.12',
    [string] $Exe = 'C:\Program Files (x86)\NSIS\makensis.exe',
    [scriptblock] $GetVersion = $null,
    [scriptblock] $Install = $null,
    [string] $PathFile = $env:GITHUB_PATH
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -notmatch '^\d+\.\d+$') { throw "NSIS version must look like 3.12, got '$Version'." }
$want = "v$Version"

if (-not $GetVersion) {
    $GetVersion = {
        param([string] $Path)
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $out = & $Path /VERSION
        $global:LASTEXITCODE = 0
        return "$out".Trim()
    }
}
if (-not $Install) {
    $Install = {
        param([string] $Package)
        & choco install nsis --version $Package --force -y --no-progress
        if ($LASTEXITCODE -ne 0) { throw "choco install nsis $Package failed ($LASTEXITCODE)" }
    }
}

$have = & $GetVersion $Exe
if ($have -eq $want) {
    Write-Host "NSIS $have is already installed."
}
else {
    $from = if ($have) { $have } else { 'nothing' }
    Write-Host "Found $from, installing NSIS $want."
    & $Install "$Version.0"
    $have = & $GetVersion $Exe
    if ($have -ne $want) { throw "Expected NSIS $want after installing, found '$have'." }
}

if ($PathFile) { Add-Content -LiteralPath $PathFile -Value (Split-Path -Parent $Exe) }
