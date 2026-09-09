#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:publisher = Join-Path $PSScriptRoot 'Publish-Release.ps1'
$script:failures = 0

function Get-Plan {
    param([hashtable] $Params)
    $p = @{} + $Params
    $p['DryRun'] = $true
    return ((& $script:publisher @p *>&1) | ForEach-Object { "$_" }) -join "`n"
}

function Assert-Plan {
    param([string] $Name, [hashtable] $Params, [string[]] $Contains = @(), [string[]] $NotContains = @())
    $plan = Get-Plan -Params $Params
    foreach ($c in $Contains) {
        if ($plan -notmatch [regex]::Escape($c)) {
            Write-Host "FAIL  $Name -- missing '$c'"; Write-Host "        $plan"; $script:failures++; return
        }
    }
    foreach ($n in $NotContains) {
        if ($plan -match [regex]::Escape($n)) {
            Write-Host "FAIL  $Name -- should not contain '$n'"; Write-Host "        $plan"; $script:failures++; return
        }
    }
    Write-Host "ok    $Name"
}

$base = @{ Tag = 'v2026.9.8.0'; NotesFile = 'notes.md' }

$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("publish-release-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $script:sandbox 'dist') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $script:sandbox 'dist/one.whl') -Value 'x'
Set-Content -LiteralPath (Join-Path $script:sandbox 'dist/two.tar.gz') -Value 'y'
Push-Location $script:sandbox

Assert-Plan 'a plain release names the tag and notes file' $base `
    @('gh release create v2026.9.8.0', '--title v2026.9.8.0', '--notes-file notes.md') `
    @('--draft', '--prerelease', '--repo', '--target')

Assert-Plan 'a prerelease adds both prerelease flags' ($base + @{ Prerelease = $true }) `
    @('--prerelease', '--latest=false')

Assert-Plan 'assets are appended before the flags' ($base + @{ Assets = @('a.zip', 'a.zip.sha256') }) `
    @('gh release create v2026.9.8.0 a.zip a.zip.sha256 --title')

Assert-Plan 'blank asset entries are dropped' ($base + @{ Assets = @('a.zip', '', '  ', 'b.tsv') }) `
    @('create v2026.9.8.0 a.zip b.tsv --title')

Assert-Plan 'an explicit title is kept' ($base + @{ Title = 'My App v2026.9.8.0' }) `
    @('--title My App v2026.9.8.0')

Assert-Plan 'repository and target are passed through' ($base + @{ Repository = 'o/r'; Target = 'abc123' }) `
    @('--repo o/r', '--target abc123')

Assert-Plan 'draft-first creates a draft then promotes it' ($base + @{ DraftFirst = $true }) `
    @('--draft', 'gh release view v2026.9.8.0 --json assets,isDraft', 'gh release edit v2026.9.8.0 --draft=false')

Assert-Plan 'draft-first and prerelease combine' ($base + @{ DraftFirst = $true; Prerelease = $true }) `
    @('--draft', '--prerelease', '--latest=false')

Assert-Plan 'a plain release looks the tag up before creating it' $base `
    @('gh release view v2026.9.8.0 --json id', 'gh release create v2026.9.8.0') `
    @('gh release edit', 'gh release upload')

Assert-Plan 'an existing release is edited, not created' ($base + @{ AssumeExisting = $true }) `
    @('gh release edit v2026.9.8.0 --title v2026.9.8.0 --notes-file notes.md') `
    @('gh release create', '--draft')

Assert-Plan 'an existing release re-uploads assets over the old ones' `
    ($base + @{ AssumeExisting = $true; Assets = @('a.zip', 'b.tsv') }) `
    @('gh release upload v2026.9.8.0 a.zip b.tsv --clobber')

Assert-Plan 'an existing release with no assets skips the upload' ($base + @{ AssumeExisting = $true }) `
    @() @('gh release upload')

Assert-Plan 'an existing prerelease keeps both prerelease flags on edit' `
    ($base + @{ AssumeExisting = $true; Prerelease = $true }) `
    @('gh release edit v2026.9.8.0', '--prerelease', '--latest=false')

Assert-Plan 'an existing release passes the repository to edit and upload' `
    ($base + @{ AssumeExisting = $true; Repository = 'o/r'; Assets = @('a.zip') }) `
    @('gh release edit v2026.9.8.0 --repo o/r', 'gh release upload v2026.9.8.0 a.zip --clobber --repo o/r')

Assert-Plan 'delete-existing still creates rather than edits' `
    ($base + @{ AssumeExisting = $true; DeleteExisting = $true }) `
    @('gh release delete v2026.9.8.0 --yes', 'gh release create v2026.9.8.0') `
    @('gh release edit')

Assert-Plan 'delete-existing checks for a release first' ($base + @{ DeleteExisting = $true }) `
    @('gh release view v2026.9.8.0 --json id')

Assert-Plan 'digest verification is planned when both inputs are given' `
    ($base + @{ VerifyAsset = 'a.zip'; VerifySha256 = 'deadbeef'; Repository = 'o/r' }) `
    @('gh api repos/o/r/releases/tags/v2026.9.8.0', 'expect a.zip sha256:deadbeef')

Assert-Plan 'digest verification is skipped without a hash' ($base + @{ VerifyAsset = 'a.zip' }) `
    @() @('gh api')

Assert-Plan 'the draft view passes the repository through' ($base + @{ DraftFirst = $true; Repository = 'o/r' }) `
    @('gh release view v2026.9.8.0 --json assets,isDraft --repo o/r')

Assert-Plan 'a glob expands to the matching files' @{ Tag = 'v2026.9.8.0'; Assets = @('dist/*') } `
    @('one.whl', 'two.tar.gz')

Assert-Plan 'a glob matching nothing contributes no assets' @{ Tag = 'v2026.9.8.0'; Assets = @('dist/nope/*') } `
    @('gh release create v2026.9.8.0 --title')

Assert-Plan 'literal paths are not globbed' @{ Tag = 'v2026.9.8.0'; Assets = @('dist/one.whl') } `
    @('create v2026.9.8.0 dist/one.whl --title')

Pop-Location
Remove-Item $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
