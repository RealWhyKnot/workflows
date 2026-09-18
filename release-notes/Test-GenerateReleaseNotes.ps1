#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:failures = 0

function Assert-Contains {
    param([string] $Text, [string] $Needle, [string] $Because)
    if ($Text -notmatch [regex]::Escape($Needle)) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      expected to find: $Needle"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

function Assert-NotContains {
    param([string] $Text, [string] $Needle, [string] $Because)
    if ($Text -match [regex]::Escape($Needle)) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      did not expect: $Needle"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

$generator = Join-Path $PSScriptRoot 'Generate-ReleaseNotes.ps1'
. (Join-Path $PSScriptRoot 'AuthorCredit.ps1')

function Assert-Equal {
    param([string] $Actual, [string] $Expected, [string] $Because)
    if ($Actual -ne $Expected) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

Assert-Equal (Get-AuthorCredit -Login 'RealWhyKnot' -Name 'WhyKnot') '[RealWhyKnot](https://github.com/RealWhyKnot)' 'a login is credited as a profile link, never a bare @mention'
Assert-Equal (Get-AuthorCredit -Login 'benaclejames' -Name 'Ben Thomas') '[benaclejames](https://github.com/benaclejames)' 'an outside author is credited the same way, with no mention'
Assert-Equal (Get-AuthorCredit -Login '' -Name 'Test Person') 'Test Person' 'a commit with no login is credited by name alone'

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("relnotes-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $sandbox | Out-Null
Push-Location $sandbox
try {
    git init --quiet --initial-branch=main
    git config user.email 'test@example.invalid'
    git config user.name 'Test Person'
    git config commit.gpgsign false

    function New-Commit {
        param([string] $Subject)
        $name = [System.Guid]::NewGuid().ToString('N')
        Set-Content -LiteralPath (Join-Path $sandbox $name) -Value $name
        git add -A
        git commit --quiet -m $Subject
    }

    New-Commit 'feat: the first thing'
    git tag v2026.1.1.0
    New-Commit 'fix(scope): repair the thing (2026.1.2.0-AB12)'
    New-Commit 'feat!: a breaking change'
    New-Commit 'chore: tidy up'
    New-Commit 'docs(changelog): auto-append entries [skip changelog]'
    New-Commit 'Not a conventional subject'
    git tag v2026.1.2.0

    $body = & $generator -Tag v2026.1.2.0 -Repository '' -Title 'Sample v2026.1.2.0' | Out-String

    Assert-Contains $body '# Sample v2026.1.2.0' 'the title is rendered'
    Assert-Contains $body '### Breaking Changes' 'a type!: subject lands in Breaking Changes'
    Assert-Contains $body '### Bug Fixes' 'fix lands in Bug Fixes'
    Assert-Contains $body '### Chores' 'chore lands in Chores'
    Assert-Contains $body '### Other' 'a non-conventional subject lands in Other'
    Assert-Contains $body 'by Test Person in' 'the author is credited from git when there is no API'
    Assert-NotContains $body '[skip changelog]' 'skip-changelog commits are dropped'
    Assert-NotContains $body '(2026.1.2.0-AB12)' 'the CalVer build stamp is stripped'
    Assert-NotContains $body 'the first thing' 'commits before the previous tag are excluded'

    Set-Content -LiteralPath (Join-Path $sandbox 'release-notes.txt') -Value 'x'
    New-Commit 'fix: between the stable and the beta'
    git tag v2026.1.2.1-beta
    New-Commit 'feat: after the beta'
    git tag v2026.1.3.0
    $stable = & $generator -Tag v2026.1.3.0 -Repository '' | Out-String
    Assert-Contains $stable 'between the stable and the beta' 'stable notes skip past betas even when a checkout file contains a hyphen'

    $extra = & $generator -Tag v2026.1.2.0 -Repository '' -Extra '## Downloads', '- a file' | Out-String
    Assert-Contains $extra '## Downloads' 'extra markdown is appended'

    $out = Join-Path $sandbox 'notes.md'
    & $generator -Tag v2026.1.2.0 -Repository '' -OutFile $out | Out-Null
    if (-not (Test-Path $out)) {
        Write-Host 'FAIL: -OutFile did not write a file' -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host 'ok: -OutFile writes the markdown'
        $raw = [System.IO.File]::ReadAllBytes($out)
        if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
            Write-Host 'FAIL: the notes file has a UTF-8 BOM' -ForegroundColor Red
            $script:failures++
        } else {
            Write-Host 'ok: the notes file has no BOM'
        }
    }
} finally {
    Pop-Location
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$script:failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
