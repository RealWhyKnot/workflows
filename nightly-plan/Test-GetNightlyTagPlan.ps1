#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Git {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function New-Commit {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Text, [string] $Type = 'feat', [string] $File = 'log.txt')
    [System.IO.File]::AppendAllText((Join-Path $script:sandbox $File), $Text + [Environment]::NewLine)
    Invoke-Git @('add', '-A')
    Invoke-Git @('commit', '-m', "${Type}: $Text")
}

function Invoke-Plan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable] $Params)
    [System.IO.File]::WriteAllText($script:outFile, '')
    $p = @{} + $Params
    $p['OutputPath'] = $script:outFile
    $null = & $script:planner @p *>&1
    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($script:outFile)) {
        if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return $map
}

function Assert-Plan {
    [CmdletBinding()]
    [OutputType([void])]
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

$script:planner = Join-Path $PSScriptRoot 'Get-NightlyTagPlan.ps1'
$script:failures = 0
$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('nightly-plan-' + [System.Guid]::NewGuid().ToString('N'))
$script:outFile = Join-Path $script:sandbox 'out.txt'

try {
    $null = New-Item -ItemType Directory -Path $script:sandbox -Force
    Push-Location $script:sandbox
    Invoke-Git @('init', '--initial-branch=main', '--quiet')
    Invoke-Git @('config', 'user.name', 'Test')
    Invoke-Git @('config', 'user.email', 'test@example.com')
    Invoke-Git @('config', 'commit.gpgsign', 'false')
    New-Commit -Text 'seed'

    $noon = [datetime]::SpecifyKind([datetime]::Parse('2026-09-08T18:00:00'), 'Utc')

    Assert-Plan -Name 'an untagged repo tags .0' -Params @{ NowUtc = $noon } -Expected @{
        has_changes = 'true'; next_tag = 'v2026.9.8.0-beta'
    }

    Invoke-Git @('tag', 'v2026.9.8.0-beta')
    Assert-Plan -Name 'no commits since the latest tag means nothing to do' -Params @{ NowUtc = $noon } -Expected @{
        has_changes = 'false'; next_tag = ''
    }

    New-Commit -Text 'more work'
    Assert-Plan -Name 'a new commit bumps to .1' -Params @{ NowUtc = $noon } -Expected @{
        has_changes = 'true'; next_tag = 'v2026.9.8.1-beta'
    }

    Assert-Plan -Name 'a different day restarts at .0' -Params @{ NowUtc = $noon.AddDays(1) } -Expected @{
        next_tag = 'v2026.9.9.0-beta'
    }

    $lateUtc = [datetime]::SpecifyKind([datetime]::Parse('2026-09-09T02:00:00'), 'Utc')
    Assert-Plan -Name 'the timezone decides the date, not UTC' -Params @{ NowUtc = $lateUtc } -Expected @{
        next_tag = 'v2026.9.8.1-beta'
    }
    Assert-Plan -Name 'UTC as the timezone gives the next day' -Params @{
        NowUtc = $lateUtc; Timezone = 'UTC'
    } -Expected @{ next_tag = 'v2026.9.9.0-beta' }

    Invoke-Git @('tag', 'v2026.9.8.1-beta')
    New-Commit -Text 'yet more'
    Assert-Plan -Name 'an existing beta counts toward the next revision' -Params @{ NowUtc = $noon } -Expected @{
        next_tag = 'v2026.9.8.2-beta'
    }

    Assert-Plan -Name 'a different suffix still counts same-day tags carrying the old one' -Params @{
        NowUtc = $noon; Suffix = 'nightly'
    } -Expected @{ next_tag = 'v2026.9.8.2-nightly' }
    Assert-Plan -Name 'an empty suffix counts same-day betas too' -Params @{ NowUtc = $noon; Suffix = '' } -Expected @{
        next_tag = 'v2026.9.8.2'
    }

    Invoke-Git @('tag', 'v2026.9.8.2')
    New-Commit -Text 'plain tag exists now'
    Assert-Plan -Name 'a plain same-day tag counts under an empty suffix' -Params @{
        NowUtc = $noon; Suffix = ''
    } -Expected @{ next_tag = 'v2026.9.8.3' }
    Assert-Plan -Name 'a plain same-day tag also counts under the beta suffix' -Params @{ NowUtc = $noon } -Expected @{
        next_tag = 'v2026.9.8.3-beta'
    }

    Invoke-Git @('tag', 'v2026.9.8.3-a1b2')
    New-Commit -Text 'hex prerelease exists now'
    Assert-Plan -Name 'a hex prerelease counts under the beta suffix' -Params @{ NowUtc = $noon } -Expected @{
        next_tag = 'v2026.9.8.4-beta'
    }

    Invoke-Git @('tag', 'v2026.9.8.4-beta')
    New-Commit -Text 'bump the stamp' -Type 'chore' -File 'version.txt'
    New-Commit -Text 'reword the readme' -Type 'fix' -File 'README.md'
    Assert-Plan -Name 'commits the beta gate rejects mean nothing to do' -Params @{ NowUtc = $noon } -Expected @{
        has_changes = 'false'; next_tag = ''
    }
    Assert-Plan -Name 'release-types passes through to the gate' -Params @{
        NowUtc = $noon; ReleaseTypes = 'chore'
    } -Expected @{ has_changes = 'true'; next_tag = 'v2026.9.8.5-beta' }
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $script:sandbox) { Remove-Item $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
