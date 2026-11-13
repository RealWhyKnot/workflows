#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Version = '3.12',
    [string] $Exe = 'C:\Program Files (x86)\NSIS\makensis.exe',
    [scriptblock] $GetVersion = $null,
    [scriptblock] $Install = $null,
    [string] $PathFile = $env:GITHUB_PATH,
    [int] $Attempts = 3,
    [int] $RetryDelaySeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -notmatch '^\d+\.\d+$') { throw "NSIS version must look like 3.12, got '$Version'." }
if ($Attempts -lt 1) { throw 'Attempts must be at least 1.' }
if ($RetryDelaySeconds -lt 0) { throw 'RetryDelaySeconds must be at least 0.' }
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
} else {
    $from = if ($have) { $have } else { 'nothing' }
    Write-Host "Found $from, installing NSIS $want."
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            & $Install "$Version.0"
            break
        } catch [System.Management.Automation.RuntimeException] {
            if ($attempt -eq $Attempts) { throw }
            Write-Host "Install attempt $attempt of $Attempts failed: $_. Retrying in $RetryDelaySeconds seconds."
            if ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
    }
    $have = & $GetVersion $Exe
    if ($have -ne $want) { throw "Expected NSIS $want after installing, found '$have'." }
}

if ($PathFile) {
    $pathFileFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PathFile)
    $exeDir = $Exe.Substring(0, $Exe.LastIndexOfAny([char[]]'\/'))
    [System.IO.File]::AppendAllText($pathFileFull, $exeDir + [Environment]::NewLine)
}
exit 0
