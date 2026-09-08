#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $Range = '',
    [string] $BeforeSha = '',
    [string] $AfterSha = '',
    [string] $PrBaseSha = '',
    [string] $PrHeadSha = '',
    [bool] $CheckStamp = $true,
    [string] $StampPattern = '\([0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+(-([A-Fa-f0-9]{4}|beta))?\)',
    [bool] $CheckConventional = $false,
    [string] $ConventionalPattern = '^(feat|fix|chore|ci|docs|refactor|test|perf|diag|style)(\([a-z0-9-]+\))?!?: .+',
    [string] $ForbiddenBodyPattern = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-Range {
    if ($Range) { return $Range }
    if ($PrBaseSha -and $PrHeadSha) { return "$PrBaseSha..$PrHeadSha" }
    if (-not $AfterSha) { throw 'Need either -Range, both -PrBaseSha and -PrHeadSha, or -AfterSha.' }
    if (-not $BeforeSha -or $BeforeSha -match '^0+$') { return "$AfterSha~1..$AfterSha" }
    return "$BeforeSha..$AfterSha"
}

$resolved = Resolve-Range
Write-Host "Validating commits in range: $resolved"

$log = @(& git log --format='%H %s' $resolved)
if ($LASTEXITCODE -ne 0) { throw "git log $resolved failed ($LASTEXITCODE)" }

$failures = 0
foreach ($line in $log) {
    if (-not $line) { continue }
    $split = $line.IndexOf(' ')
    if ($split -lt 0) { continue }
    $sha = $line.Substring(0, $split)
    $subject = $line.Substring($split + 1)
    $isMerge = $subject -match '^(Merge|Revert) '

    if ($CheckStamp) {
        $count = [regex]::Matches($subject, $StampPattern).Count
        if ($count -gt 1) {
            Write-Host "::error::Commit $sha carries $count build-version stamps: $subject"
            $failures++
        }
    }

    if ($CheckConventional -and -not $isMerge) {
        if ($subject -notmatch $ConventionalPattern) {
            Write-Host "::error::Commit $sha is not a conventional commit: $subject"
            $failures++
        }
    }

    if ($ForbiddenBodyPattern -and -not $isMerge) {
        $body = (& git log -1 --format='%B' $sha) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "git log -1 $sha failed ($LASTEXITCODE)" }
        if ([regex]::IsMatch($body, $ForbiddenBodyPattern, 'IgnoreCase')) {
            Write-Host "::error::Commit $sha references an issue number or an upstream repository: $subject"
            $failures++
        }
    }
}

if ($failures -gt 0) {
    Write-Host "::error::$failures commit subject(s) failed validation. See .githooks/commit-msg for the local check."
    exit 1
}

Write-Host "All $($log.Count) commit subject(s) in $resolved pass."
