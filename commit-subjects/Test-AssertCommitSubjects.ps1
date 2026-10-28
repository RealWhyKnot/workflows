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
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $Subject, [string] $Body = '')
    [System.IO.File]::AppendAllText((Join-Path $script:sandbox 'log.txt'), $Subject + [Environment]::NewLine)
    Invoke-Git @('add', '-A')
    $gitArgs = if ($Body) { @('commit', '-m', $Subject, '-m', $Body) } else { @('commit', '-m', $Subject) }
    Invoke-Git $gitArgs
    return (& git rev-parse HEAD).Trim()
}

function Assert-Pass {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Params)
    $out = & $script:checker @Params *>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL  $Name -- expected pass, got exit $LASTEXITCODE"
        foreach ($line in $out) { Write-Host "        $line" }
        $script:failures++
    } else {
        Write-Host "ok    $Name"
    }
}

function Assert-Fail {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Params, [string] $ExpectedText)
    $out = (& $script:checker @Params *>&1) -join "`n"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "FAIL  $Name -- expected failure, got exit 0"
        $script:failures++
    } elseif ($ExpectedText -and $out -notmatch [regex]::Escape($ExpectedText)) {
        Write-Host "FAIL  $Name -- output did not mention '$ExpectedText'"
        Write-Host "        $out"
        $script:failures++
    } else {
        Write-Host "ok    $Name"
    }
}

$script:checker = Join-Path $PSScriptRoot 'Assert-CommitSubjects.ps1'
$script:failures = 0
$sandboxName = 'commit-subjects-' + [System.Guid]::NewGuid().ToString('N')
$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) $sandboxName

try {
    $null = New-Item -ItemType Directory -Path $script:sandbox -Force
    Push-Location $script:sandbox
    Invoke-Git @('init', '--initial-branch=main', '--quiet')
    Invoke-Git @('config', 'user.name', 'Test')
    Invoke-Git @('config', 'user.email', 'test@example.com')
    Invoke-Git @('config', 'commit.gpgsign', 'false')

    $base = New-Commit -Subject 'chore: seed the sandbox'
    $clean = New-Commit -Subject 'feat(core): add a thing (2026.9.8.1-A1B2)'
    $double = New-Commit -Subject 'fix: repair it (2026.9.8.1-A1B2) (2026.9.8.2-C3D4)'
    $nonConv = New-Commit -Subject 'made some changes'
    $withIssue = New-Commit -Subject 'docs: tidy the readme' -Body 'Refs #412 upstream.'
    $merge = New-Commit -Subject 'Merge branch feature/x into main'
    $revert = New-Commit -Subject 'revert: drop the thing (2026.9.8.3-E5F6)'

    Assert-Pass -Name 'single stamp passes' -Params @{ Range = "$base..$clean" }
    Assert-Fail -Name 'double stamp fails' -Params @{
        Range = "$clean..$double"
    } -ExpectedText 'carries 2 build-version stamps'
    Assert-Pass -Name 'double stamp ignored when stamp check is off' -Params @{
        Range = "$clean..$double"; CheckStamp = $false
    }
    Assert-Pass -Name 'non-conventional passes when not checked' -Params @{ Range = "$double..$nonConv" }
    Assert-Fail -Name 'non-conventional fails when checked' -Params @{
        Range = "$double..$nonConv"; CheckConventional = $true
    } -ExpectedText 'is not a conventional commit'
    Assert-Pass -Name 'conventional subject passes the conventional check' -Params @{
        Range = "$base..$clean"; CheckConventional = $true
    }
    Assert-Fail -Name 'forbidden body pattern fails' -Params @{
        Range = "$nonConv..$withIssue"; ForbiddenBodyPattern = '(^|[^A-Za-z0-9_])#[0-9]+'
    } -ExpectedText 'references an issue number'
    Assert-Pass -Name 'forbidden body pattern skipped when empty' -Params @{ Range = "$nonConv..$withIssue" }
    Assert-Pass -Name 'merge subject skips the conventional check' -Params @{
        Range = "$withIssue..$merge"; CheckConventional = $true
    }
    Assert-Pass -Name 'revert is a conventional type' -Params @{ Range = "$merge..$revert"; CheckConventional = $true }

    Assert-Pass -Name 'push-range shas resolve' -Params @{ BeforeSha = $base; AfterSha = $clean }
    Assert-Pass -Name 'no shas at all falls back to the tip commit, as on workflow_dispatch' -Params @{}
    Assert-Pass -Name 'first-push zero sha falls back to one commit' -Params @{
        BeforeSha = '0000000000000000000000000000000000000000'; AfterSha = $clean
    }
    Assert-Fail -Name 'pr shas resolve and still catch a bad subject' -Params @{
        PrBaseSha = $clean; PrHeadSha = $double
    } -ExpectedText 'build-version stamps'

    $strict = '\([0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+(-beta)?\)'
    Assert-Pass -Name 'a hex suffix is not a stamp under the -beta-only pattern' -Params @{
        Range = "$clean..$double"; StampPattern = $strict
    }

    Invoke-Git @('checkout', '--quiet', '-b', 'foreign', $base)
    $null = New-Commit -Subject 'upstream work that was never conventional'
    Invoke-Git @('checkout', '--quiet', 'main')
    Invoke-Git @('merge', '--quiet', '-s', 'ours', 'foreign', '-m', 'chore: absorb foreign history')
    $mergeOurs = (& git rev-parse HEAD).Trim()
    Assert-Pass -Name 'foreign commits behind a merge are not validated' -Params @{
        Range = "$revert..$mergeOurs"; CheckConventional = $true
    }
    Assert-Fail -Name 'first-parent commits are still validated across a merge' -Params @{
        Range = "$double..$mergeOurs"; CheckConventional = $true
    } -ExpectedText 'is not a conventional commit'
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $script:sandbox) { Remove-Item $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed."
    exit 1
}
Write-Host "`nAll checks passed."
exit 0
