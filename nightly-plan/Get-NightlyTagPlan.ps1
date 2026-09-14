#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $Timezone = 'America/Chicago',
    [datetime] $NowUtc = ([datetime]::UtcNow),
    [string] $Suffix = 'beta',
    [string] $TagGlob = 'v*',
    [string[]] $IgnorePaths = @(),
    [string[]] $ReleaseTypes = @(),
    [string] $OutputPath = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Set-Output {
    param([hashtable] $Values)
    foreach ($k in $Values.Keys) {
        Write-Host "$k=$($Values[$k])"
        if ($OutputPath) { Add-Content -LiteralPath $OutputPath -Value "$k=$($Values[$k])" }
    }
}

$gate = & (Join-Path $PSScriptRoot '../beta-gate/Get-BetaGate.ps1') -TagGlob $TagGlob -IgnorePaths $IgnorePaths -ReleaseTypes $ReleaseTypes -OutputPath '' | Select-Object -Last 1
if (-not $gate.HasChanges) {
    Set-Output @{ has_changes = 'false'; next_tag = '' }
    exit 0
}

$head = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Could not resolve HEAD.' }

$zone = [TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
$today = [TimeZoneInfo]::ConvertTimeFromUtc($NowUtc, $zone).ToString('yyyy.M.d')

$escaped = [regex]::Escape($today)
$pattern = if ($Suffix) { "^v$escaped\.(\d+)(-(?:$Suffix))?$" } else { "^v$escaped\.(\d+)$" }
$highest = -1
foreach ($existing in @(& git tag --list "v$today.*")) {
    if ($existing -match $pattern -and [int] $Matches[1] -gt $highest) { $highest = [int] $Matches[1] }
}
$global:LASTEXITCODE = 0

$next = $highest + 1
$tag = if ($Suffix) { "v$today.$next-$Suffix" } else { "v$today.$next" }

Write-Host "Tagging $tag at $head"
Set-Output @{ has_changes = 'true'; next_tag = $tag }
