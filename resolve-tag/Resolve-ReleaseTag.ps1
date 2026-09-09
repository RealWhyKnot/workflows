#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $Tag = '',
    [string] $FallbackTag = '',
    [string] $TagPattern = '^v\d{4}\.\d+\.\d+\.\d+(-([A-Fa-f0-9]{4}|beta))?$',
    [string] $PrereleasePattern = '^v\d{4}\.\d+\.\d+\.\d+-beta$',
    [bool] $RequireTagExists = $true,
    [string] $OutputPath = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resolved = if ([string]::IsNullOrWhiteSpace($Tag)) { $FallbackTag } else { $Tag }
$resolved = "$resolved".Trim()

if ([string]::IsNullOrWhiteSpace($resolved)) {
    Write-Host '::error::No tag supplied and no fallback available.'
    exit 1
}

if ($resolved -notmatch $TagPattern) {
    Write-Host "::error::Tag '$resolved' does not match $TagPattern."
    exit 1
}

$sha = ''
if ($RequireTagExists) {
    $sha = (& git rev-list -n 1 $resolved 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
        Write-Host "::error::Tag '$resolved' does not exist in the checked-out repository."
        exit 1
    }
    $sha = $sha.Trim()
}
$global:LASTEXITCODE = 0

$isPrerelease = $resolved -match $PrereleasePattern
$version = $resolved -replace '^v', ''
$channel = if ($isPrerelease) { 'beta' } else { 'release' }

$out = [ordered]@{
    tag        = $resolved
    version    = $version
    prerelease = $isPrerelease.ToString().ToLowerInvariant()
    channel    = $channel
    sha        = $sha
}

if ($OutputPath) {
    foreach ($k in $out.Keys) { Add-Content -LiteralPath $OutputPath -Value "$k=$($out[$k])" }
}
foreach ($k in $out.Keys) { Write-Host "$k=$($out[$k])" }
