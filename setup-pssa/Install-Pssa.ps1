#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Version = '1.25.0',
    [version] $Pwsh = $PSVersionTable.PSVersion,
    [string] $Image = ((@($env:ImageOS, $env:ImageVersion) | Where-Object { $_ }) -join '-'),
    [string] $ProfileDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSScriptAnalyzer'),
    [scriptblock] $GetInstalled = $null,
    [scriptblock] $Install = $null,
    [string] $OutputPath = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "version must be major.minor.patch, got '$Version'." }
if (-not $GetInstalled) {
    $GetInstalled = {
        foreach ($module in @(Get-Module -ListAvailable -Name PSScriptAnalyzer)) { $module.Version.ToString() }
    }
}
if (-not $Install) {
    $Install = {
        param([string] $Wanted)
        Install-PSResource -Name PSScriptAnalyzer -Version $Wanted -TrustRepository -Quiet
    }
}

if (@(& $GetInstalled) -contains $Version) {
    Write-Host "PSScriptAnalyzer $Version is already installed."
} else {
    & $Install $Version
}

$parts = @(
    "pwsh$($Pwsh.Major).$($Pwsh.Minor)"
    "pssa$Version"
    if ($Image) { $Image }
)
$key = $parts -join '-'
Write-Host "Compatibility profiles are cached in $ProfileDirectory under $key."
if ($OutputPath) {
    $outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $outputLines = @("profile-dir=$ProfileDirectory", "cache-key=$key")
    [System.IO.File]::AppendAllText($outputFile, ($outputLines -join [Environment]::NewLine) + [Environment]::NewLine)
}
exit 0
