#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checker = Join-Path $PSScriptRoot 'Assert-CommitSubjects.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("commit-subjects-" + [System.Guid]::NewGuid().ToString('N'))

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function New-Commit {
    param([Parameter(Mandatory = $true)][string] $Subject, [string] $Body = '')
    Add-Content -LiteralPath (Join-Path $sandbox 'log.txt') -Value $Subject
    Invoke-Git @('add', '-A')
    $args = @('commit', '-m', $Subject)
    if ($Body) { $args += @('-m', $Body) }
    Invoke-Git $args
    return (& git rev-parse HEAD).Trim()
}

function Assert-Pass {
    param([string] $Name, [hashtable] $Params)
    $out = & $checker @Params *>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL  $Name -- expected pass, got exit $LASTEXITCODE"
        $out | ForEach-Object { Write-Host "        $_" }
        $script:failures++
    } else {
        Write-Host "ok    $Name"
    }
}

function Assert-Fail {
    param([string] $Name, [hashtable] $Params, [string] $ExpectedText)
    $out = (& $checker @Params *>&1) -join "`n"
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

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Push-Location $sandbox
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

    Assert-Pass 'single stamp passes' @{ Range = "$base..$clean" }
    Assert-Fail 'double stamp fails' @{ Range = "$clean..$double" } 'carries 2 build-version stamps'
    Assert-Pass 'double stamp ignored when stamp check is off' @{ Range = "$clean..$double"; CheckStamp = $false }
    Assert-Pass 'non-conventional passes when not checked' @{ Range = "$double..$nonConv" }
    Assert-Fail 'non-conventional fails when checked' @{ Range = "$double..$nonConv"; CheckConventional = $true } 'is not a conventional commit'
    Assert-Pass 'conventional subject passes the conventional check' @{ Range = "$base..$clean"; CheckConventional = $true }
    Assert-Fail 'forbidden body pattern fails' @{ Range = "$nonConv..$withIssue"; ForbiddenBodyPattern = '(^|[^A-Za-z0-9_])#[0-9]+' } 'references an issue number'
    Assert-Pass 'forbidden body pattern skipped when empty' @{ Range = "$nonConv..$withIssue" }
    Assert-Pass 'merge subject skips the conventional check' @{ Range = "$withIssue..$merge"; CheckConventional = $true }

    Assert-Pass 'push-range shas resolve' @{ BeforeSha = $base; AfterSha = $clean }
    Assert-Pass 'first-push zero sha falls back to one commit' @{ BeforeSha = '0000000000000000000000000000000000000000'; AfterSha = $clean }
    Assert-Fail 'pr shas resolve and still catch a bad subject' @{ PrBaseSha = $clean; PrHeadSha = $double } 'build-version stamps'

    $strict = '\([0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+(-beta)?\)'
    Assert-Pass 'a hex suffix is not a stamp under the -beta-only pattern' @{ Range = "$clean..$double"; StampPattern = $strict }
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed."
    exit 1
}
Write-Host "`nAll checks passed."
exit 0
