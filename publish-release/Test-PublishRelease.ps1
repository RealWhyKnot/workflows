#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Plan {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable] $Params)
    $p = @{} + $Params
    $p['DryRun'] = $true
    $lines = foreach ($item in & $script:publisher @p *>&1) { "$item" }
    return $lines -join "`n"
}

function Assert-Plan {
    [CmdletBinding()]
    [OutputType([void])]
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

function gh {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
    $ghCallLog.Add($Rest -join ' ')
    $global:LASTEXITCODE = 0
    if ($Rest -contains 'id,isDraft') {
        if ($ghReleaseIsDraft) { return '{"id":"RE_1","isDraft":true}' }
        return '{"id":"RE_1","isDraft":false}'
    }
    if ($Rest -contains 'assets,isDraft') { return '{"assets":[{"name":"a.zip"}],"isDraft":true}' }
    return ''
}

$script:publisher = Join-Path $PSScriptRoot 'Publish-Release.ps1'
$script:failures = 0
$ghCallLog = [System.Collections.Generic.List[string]]::new()
$ghReleaseIsDraft = $false

$base = @{ Tag = 'v2026.9.8.0'; NotesFile = 'notes.md' }

$sandboxName = 'publish-release-' + [System.Guid]::NewGuid().ToString('N')
$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) $sandboxName
$null = New-Item -ItemType Directory -Path (Join-Path $script:sandbox 'dist') -Force
[System.IO.File]::WriteAllText((Join-Path $script:sandbox 'dist/one.whl'), 'x' + [Environment]::NewLine)
[System.IO.File]::WriteAllText((Join-Path $script:sandbox 'dist/two.tar.gz'), 'y' + [Environment]::NewLine)
Push-Location $script:sandbox

Assert-Plan -Name 'a plain release names the tag and notes file' -Params $base -Contains @(
    'gh release create v2026.9.8.0', '--title v2026.9.8.0', '--notes-file notes.md'
) -NotContains @('--draft', '--prerelease', '--repo', '--target')

Assert-Plan -Name 'a prerelease adds both prerelease flags' -Params ($base + @{ Prerelease = $true }) -Contains @(
    '--prerelease', '--latest=false'
)

Assert-Plan -Name 'assets are appended before the flags' -Params ($base + @{
        Assets = @('a.zip', 'a.zip.sha256')
    }) -Contains @('gh release create v2026.9.8.0 a.zip a.zip.sha256 --title')

Assert-Plan -Name 'blank asset entries are dropped' -Params ($base + @{
        Assets = @('a.zip', '', '  ', 'b.tsv')
    }) -Contains @('create v2026.9.8.0 a.zip b.tsv --title')

Assert-Plan -Name 'an explicit title is kept' -Params ($base + @{ Title = 'My App v2026.9.8.0' }) -Contains @(
    '--title My App v2026.9.8.0'
)

Assert-Plan -Name 'repository and target are passed through' -Params ($base + @{
        Repository = 'o/r'; Target = 'abc123'
    }) -Contains @('--repo o/r', '--target abc123')

Assert-Plan -Name 'draft-first creates a draft then promotes it' -Params ($base + @{ DraftFirst = $true }) -Contains @(
    '--draft', 'gh release view v2026.9.8.0 --json assets,isDraft', 'gh release edit v2026.9.8.0 --draft=false'
)

Assert-Plan -Name 'draft-first and prerelease combine' -Params ($base + @{
        DraftFirst = $true; Prerelease = $true
    }) -Contains @('--draft', '--prerelease', '--latest=false')

Assert-Plan -Name 'a plain release looks the tag up before creating it' -Params $base -Contains @(
    'gh release view v2026.9.8.0 --json id', 'gh release create v2026.9.8.0'
) -NotContains @('gh release edit', 'gh release upload')

Assert-Plan -Name 'an existing release is edited, not created' -Params ($base + @{
        AssumeExisting = $true
    }) -Contains @(
    'gh release edit v2026.9.8.0 --title v2026.9.8.0 --notes-file notes.md'
) -NotContains @('gh release create', '--draft')

Assert-Plan -Name 'an existing release re-uploads assets over the old ones' -Params ($base + @{
        AssumeExisting = $true; Assets = @('a.zip', 'b.tsv')
    }) -Contains @('gh release upload v2026.9.8.0 a.zip b.tsv --clobber')

Assert-Plan -Name 'an existing release with no assets skips the upload' -Params ($base + @{
        AssumeExisting = $true
    }) -NotContains @('gh release upload')

Assert-Plan -Name 'an existing prerelease keeps both prerelease flags on edit' -Params ($base + @{
        AssumeExisting = $true; Prerelease = $true
    }) -Contains @('gh release edit v2026.9.8.0', '--prerelease', '--latest=false')

Assert-Plan -Name 'an existing release passes the repository to edit and upload' -Params ($base + @{
        AssumeExisting = $true; Repository = 'o/r'; Assets = @('a.zip')
    }) -Contains @(
    'gh release edit v2026.9.8.0 --repo o/r', 'gh release upload v2026.9.8.0 a.zip --clobber --repo o/r'
)

Assert-Plan -Name 'the lookup asks whether the release is still a draft' -Params $base -Contains @(
    'gh release view v2026.9.8.0 --json id,isDraft'
)

Assert-Plan -Name 'an existing draft is checked and promoted on a re-run' -Params ($base + @{
        AssumeExisting = $true; AssumeDraft = $true; Assets = @('a.zip'); Repository = 'o/r'
    }) -Contains @(
    'gh release upload v2026.9.8.0 a.zip --clobber --repo o/r'
    'gh release view v2026.9.8.0 --json assets,isDraft --repo o/r'
    'gh release edit v2026.9.8.0 --draft=false --repo o/r'
) -NotContains @('gh release create')

Assert-Plan -Name 'an existing published release is not promoted again' -Params ($base + @{
        AssumeExisting = $true; DraftFirst = $true
    }) -Contains @('gh release edit v2026.9.8.0 --title') -NotContains @('--draft=false', 'gh release create')

$ghCallLog.Clear()
$ghReleaseIsDraft = $true
& $script:publisher -Tag 'v2026.9.8.0' -NotesFile 'notes.md' -Assets @('a.zip') -DraftFirst $true *> $null
$rerun = $ghCallLog -join "`n"
if ($rerun -match [regex]::Escape('release edit v2026.9.8.0 --draft=false') -and $rerun -notmatch 'release create') {
    Write-Host 'ok    a re-run finds the draft left by the last run and promotes it'
} else {
    Write-Host 'FAIL  a re-run finds the draft left by the last run and promotes it'
    Write-Host "        $rerun"
    $script:failures++
}

Assert-Plan -Name 'delete-existing still creates rather than edits' -Params ($base + @{
        AssumeExisting = $true; DeleteExisting = $true
    }) -Contains @('gh release delete v2026.9.8.0 --yes', 'gh release create v2026.9.8.0') -NotContains @(
    'gh release edit'
)

Assert-Plan -Name 'delete-existing deletes in the target repository' -Params ($base + @{
        AssumeExisting = $true; DeleteExisting = $true; Repository = 'o/r'
    }) -Contains @('gh release delete v2026.9.8.0 --yes --repo o/r', 'gh release create v2026.9.8.0 --repo o/r')

$ghCallLog.Clear()
$ghReleaseIsDraft = $false
& $script:publisher -Tag 'v2026.9.8.0' -NotesFile 'notes.md' -Repository 'o/r' -DeleteExisting $true *> $null
$deleteCall = @(foreach ($call in $ghCallLog) { if ($call -match '^release delete') { $call } })
if ($deleteCall.Count -eq 1 -and $deleteCall[0] -eq 'release delete v2026.9.8.0 --yes --repo o/r') {
    Write-Host 'ok    a real delete names the target repository'
} else {
    Write-Host 'FAIL  a real delete names the target repository'
    Write-Host "        $($deleteCall -join ' | ')"
    $script:failures++
}

Assert-Plan -Name 'delete-existing checks for a release first' -Params ($base + @{
        DeleteExisting = $true
    }) -Contains @(
    'gh release view v2026.9.8.0 --json id'
)

Assert-Plan -Name 'digest verification is planned when both inputs are given' -Params ($base + @{
        VerifyAsset = 'a.zip'; VerifySha256 = 'deadbeef'; Repository = 'o/r'
    }) -Contains @('gh api repos/o/r/releases/tags/v2026.9.8.0', 'expect a.zip sha256:deadbeef')

Assert-Plan -Name 'digest verification is skipped without a hash' -Params ($base + @{
        VerifyAsset = 'a.zip'
    }) -NotContains @('gh api')

Assert-Plan -Name 'the draft view passes the repository through' -Params ($base + @{
        DraftFirst = $true; Repository = 'o/r'
    }) -Contains @('gh release view v2026.9.8.0 --json assets,isDraft --repo o/r')

Assert-Plan -Name 'a glob expands to the matching files' -Params @{
    Tag = 'v2026.9.8.0'; Assets = @('dist/*')
} -Contains @('one.whl', 'two.tar.gz')

Assert-Plan -Name 'a glob matching nothing contributes no assets' -Params @{
    Tag = 'v2026.9.8.0'; Assets = @('dist/nope/*')
} -Contains @('gh release create v2026.9.8.0 --title')

Assert-Plan -Name 'literal paths are not globbed' -Params @{
    Tag = 'v2026.9.8.0'; Assets = @('dist/one.whl')
} -Contains @('create v2026.9.8.0 dist/one.whl --title')

Pop-Location
Remove-Item $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
