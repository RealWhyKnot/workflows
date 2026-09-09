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

Assert-Plan 'a plain release never views or edits' $base `
    @() @('gh release view', 'gh release edit')

Assert-Plan 'delete-existing checks for a release first' ($base + @{ DeleteExisting = $true }) `
    @('gh release view v2026.9.8.0 --json id')

Assert-Plan 'digest verification is planned when both inputs are given' `
    ($base + @{ VerifyAsset = 'a.zip'; VerifySha256 = 'deadbeef'; Repository = 'o/r' }) `
    @('gh api repos/o/r/releases/tags/v2026.9.8.0', 'expect a.zip sha256:deadbeef')

Assert-Plan 'digest verification is skipped without a hash' ($base + @{ VerifyAsset = 'a.zip' }) `
    @() @('gh api')

Assert-Plan 'the draft view passes the repository through' ($base + @{ DraftFirst = $true; Repository = 'o/r' }) `
    @('gh release view v2026.9.8.0 --json assets,isDraft --repo o/r')

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
