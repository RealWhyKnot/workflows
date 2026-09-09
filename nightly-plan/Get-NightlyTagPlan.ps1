#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $Timezone = 'America/Chicago',
    [datetime] $NowUtc = ([datetime]::UtcNow),
    [string] $Suffix = 'beta',
    [string] $TagGlob = 'v*',
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

$head = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Could not resolve HEAD.' }

$latest = @(& git tag --list $TagGlob --sort=-creatordate) | Where-Object { $_ } | Select-Object -First 1
$global:LASTEXITCODE = 0

if ($latest) {
    $latestSha = (& git rev-list -n 1 $latest).Trim()
    $global:LASTEXITCODE = 0
    if ($latestSha -eq $head) {
        Write-Host "No commits since $latest; nothing to tag."
        Set-Output @{ has_changes = 'false'; next_tag = '' }
        exit 0
    }
}

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
