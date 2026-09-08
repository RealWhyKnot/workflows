#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Tag,
    [string] $RepoRoot = (Get-Location).Path,
    [string] $PrereleaseSuffix = '[A-Za-z0-9]{4}'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
    return @($output)
}

$suffix = if ($PrereleaseSuffix) { "(-(?:$PrereleaseSuffix))?" } else { '' }

function Get-ExpectedRevision {
    param([string] $DateStamp, [string] $ExcludeTag, [string] $Suffix)

    $pattern = "^v$([regex]::Escape($DateStamp))\.(\d+)$Suffix$"
    $highest = -1
    foreach ($existing in @(Invoke-Git -Arguments @('tag', '--list', "v$DateStamp.*"))) {
        if ($existing -eq $ExcludeTag) { continue }
        if ($existing -match $pattern) {
            $value = [int] $Matches[1]
            if ($value -gt $highest) { $highest = $value }
        }
    }
    return $highest + 1
}

$resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Push-Location $resolvedRoot
try {
    if ($Tag -notmatch "^v(\d{4})\.(\d+)\.(\d+)\.(\d+)$suffix$") {
        Write-Host "::error::Release tag must be vYYYY.M.D.N with an optional -suffix, got '$Tag'."
        exit 1
    }

    $dateStamp = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
    $actual = [int] $Matches[4]
    $expected = Get-ExpectedRevision -DateStamp $dateStamp -ExcludeTag $Tag -Suffix $suffix

    if ($actual -ne $expected) {
        Write-Host "::error::Release tag $Tag uses revision $actual, expected $expected for $dateStamp. Use .0 when no same-day tag exists; otherwise increment the highest same-day release or prerelease revision by one."
        exit 1
    }

    Write-Host "Release tag $Tag uses the expected same-day revision $expected."
}
finally {
    Pop-Location
}
