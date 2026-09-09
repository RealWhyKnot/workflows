#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:planner = Join-Path $PSScriptRoot 'Get-NightlyTagPlan.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("nightly-plan-" + [System.Guid]::NewGuid().ToString('N'))
$script:outFile = Join-Path $sandbox 'out.txt'

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function New-Commit {
    param([string] $Text)
    Add-Content -LiteralPath (Join-Path $sandbox 'log.txt') -Value $Text
    Invoke-Git @('add', '-A')
    Invoke-Git @('commit', '-m', "chore: $Text")
}

function Invoke-Plan {
    param([hashtable] $Params)
    Set-Content -LiteralPath $script:outFile -Value '' -NoNewline
    $p = @{} + $Params
    $p['OutputPath'] = $script:outFile
    $null = & $script:planner @p *>&1
    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $script:outFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return $map
}

function Assert-Plan {
    param([string] $Name, [hashtable] $Params, [hashtable] $Expected)
    $r = Invoke-Plan -Params $Params
    foreach ($k in $Expected.Keys) {
        if ($r[$k] -ne $Expected[$k]) {
            Write-Host "FAIL  $Name -- $k was '$($r[$k])', expected '$($Expected[$k])'"
            $script:failures++
            return
        }
    }
    Write-Host "ok    $Name"
}

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Push-Location $sandbox
    Invoke-Git @('init', '--initial-branch=main', '--quiet')
    Invoke-Git @('config', 'user.name', 'Test')
    Invoke-Git @('config', 'user.email', 'test@example.com')
    Invoke-Git @('config', 'commit.gpgsign', 'false')
    New-Commit 'seed'

    # 2026-09-08 18:00 UTC is still 2026-09-08 in Chicago (UTC-5).
    $noon = [datetime]::SpecifyKind([datetime]::Parse('2026-09-08T18:00:00'), 'Utc')

    Assert-Plan 'an untagged repo tags .0' @{ NowUtc = $noon } @{ has_changes = 'true'; next_tag = 'v2026.9.8.0-beta' }

    Invoke-Git @('tag', 'v2026.9.8.0-beta')
    Assert-Plan 'no commits since the latest tag means nothing to do' @{ NowUtc = $noon } @{ has_changes = 'false'; next_tag = '' }

    New-Commit 'more work'
    Assert-Plan 'a new commit bumps to .1' @{ NowUtc = $noon } @{ has_changes = 'true'; next_tag = 'v2026.9.8.1-beta' }

    Assert-Plan 'a different day restarts at .0' @{ NowUtc = $noon.AddDays(1) } @{ next_tag = 'v2026.9.9.0-beta' }

    # 2026-09-09 02:00 UTC is still 2026-09-08 in Chicago, which is the point of the timezone.
    $lateUtc = [datetime]::SpecifyKind([datetime]::Parse('2026-09-09T02:00:00'), 'Utc')
    Assert-Plan 'the timezone decides the date, not UTC' @{ NowUtc = $lateUtc } @{ next_tag = 'v2026.9.8.1-beta' }
    Assert-Plan 'UTC as the timezone gives the next day' @{ NowUtc = $lateUtc; Timezone = 'UTC' } @{ next_tag = 'v2026.9.9.0-beta' }

    Invoke-Git @('tag', 'v2026.9.8.1-beta')
    New-Commit 'yet more'
    Assert-Plan 'an existing beta counts toward the next revision' @{ NowUtc = $noon } @{ next_tag = 'v2026.9.8.2-beta' }

    Assert-Plan 'a different suffix ignores same-day tags carrying the old one' @{ NowUtc = $noon; Suffix = 'nightly' } @{ next_tag = 'v2026.9.8.0-nightly' }
    Assert-Plan 'an empty suffix only counts plain same-day tags' @{ NowUtc = $noon; Suffix = '' } @{ next_tag = 'v2026.9.8.0' }

    Invoke-Git @('tag', 'v2026.9.8.0')
    New-Commit 'plain tag exists now'
    Assert-Plan 'a plain same-day tag counts under an empty suffix' @{ NowUtc = $noon; Suffix = '' } @{ next_tag = 'v2026.9.8.1' }
    Assert-Plan 'a plain same-day tag also counts under the beta suffix' @{ NowUtc = $noon } @{ next_tag = 'v2026.9.8.2-beta' }
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
