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
    $parameters = @{} + $Params
    $parameters['DryRun'] = $true
    $lines = foreach ($item in & $script:publisher @parameters *>&1) { "$item" }
    return $lines -join "`n"
}

function Assert-Plan {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Params, [string[]] $Contains = @(), [string[]] $NotContains = @())
    $plan = Get-Plan -Params $Params
    foreach ($expected in $Contains) {
        if ($plan -notmatch [regex]::Escape($expected)) {
            Write-Host "FAIL  ${Name}: missing '$expected'"; Write-Host "        $plan"; $script:failures++; return
        }
    }
    foreach ($forbidden in $NotContains) {
        if ($plan -match [regex]::Escape($forbidden)) {
            Write-Host "FAIL  ${Name}: should not contain '$forbidden'"
            Write-Host "        $plan"
            $script:failures++
            return
        }
    }
    Write-Host "ok    $Name"
}

function Assert-Check {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [bool] $Condition, [string] $Detail)
    if ($Condition) { Write-Host "ok    $Name"; return }
    Write-Host "FAIL  $Name"
    Write-Host "        $Detail"
    $script:failures++
}

function Invoke-Publisher {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable] $Params)
    $ghCallLog.Clear()
    $parameters = @{} + $Params
    try {
        & $script:publisher @parameters *> $null
    } catch [System.Management.Automation.RuntimeException] {
        return $_.Exception.Message
    }
    return ''
}

function gh {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
    $ghCallLog.Add($Rest -join ' ')
    $global:LASTEXITCODE = 0
    if ($Rest -contains 'id,isDraft,assets') {
        if ($isReleaseDraft) { return '{"id":"RE_1","isDraft":true,"assets":[{"name":"a.zip"}]}' }
        return '{"id":"RE_1","isDraft":false,"assets":[{"name":"a.zip"}]}'
    }
    if ($Rest -contains 'assets,isDraft' -or $Rest -contains 'assets') { return $draftView }
    return ''
}

$script:publisher = Join-Path $PSScriptRoot 'Publish-Release.ps1'
$script:failures = 0
$ghCallLog = [System.Collections.Generic.List[string]]::new()
$isReleaseDraft = $false

$base = @{ Tag = 'v2026.9.8.0'; NotesFile = 'notes.md' }

$sandboxName = 'publish-release-' + [System.Guid]::NewGuid().ToString('N')
$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) $sandboxName
$null = New-Item -ItemType Directory -Path (Join-Path $script:sandbox 'dist') -Force
[System.IO.File]::WriteAllText((Join-Path $script:sandbox 'dist/one.whl'), 'x' + [Environment]::NewLine)
[System.IO.File]::WriteAllText((Join-Path $script:sandbox 'dist/two.tar.gz'), 'y' + [Environment]::NewLine)
[System.IO.File]::WriteAllText((Join-Path $script:sandbox 'a.zip'), 'z' + [Environment]::NewLine)
$zipHash = (Get-FileHash -LiteralPath (Join-Path $script:sandbox 'a.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
$matchingView = '{"assets":[{"name":"a.zip","digest":"sha256:' + $zipHash + '"}],"isDraft":true}'
$draftView = $matchingView
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

Assert-Plan -Name 'an existing release gets an edit call' -Params ($base + @{
        AssumeExisting = $true
    }) -Contains @(
    'gh release edit v2026.9.8.0 --title v2026.9.8.0 --notes-file notes.md'
) -NotContains @('gh release create', '--draft')

Assert-Plan -Name 'an existing published release uploads without --clobber' -Params ($base + @{
        AssumeExisting = $true; Assets = @('a.zip', 'b.tsv')
    }) -Contains @('gh release upload v2026.9.8.0 a.zip b.tsv') -NotContains @('--clobber')

$isReleaseDraft = $false
$null = Invoke-Publisher -Params @{ Tag = 'v2026.9.8.0'; NotesFile = 'notes.md'; Assets = @('a.zip', 'b.tsv') }
$uploads = @(foreach ($call in $ghCallLog) { if ($call -match '^release upload') { $call } })
Assert-Check -Name 'a published release only gets the assets it lacks' -Condition (
    $uploads.Count -eq 1 -and $uploads[0] -eq 'release upload v2026.9.8.0 b.tsv'
) -Detail ($uploads -join ' | ')

Assert-Plan -Name 'an existing release with no assets skips the upload' -Params ($base + @{
        AssumeExisting = $true
    }) -NotContains @('gh release upload')

Assert-Plan -Name 'an existing prerelease keeps both prerelease flags on edit' -Params ($base + @{
        AssumeExisting = $true; Prerelease = $true
    }) -Contains @('gh release edit v2026.9.8.0', '--prerelease', '--latest=false')

Assert-Plan -Name 'an existing release passes the repository to edit and upload' -Params ($base + @{
        AssumeExisting = $true; Repository = 'o/r'; Assets = @('a.zip')
    }) -Contains @(
    'gh release edit v2026.9.8.0 --repo o/r', 'gh release upload v2026.9.8.0 a.zip --repo o/r'
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
$isReleaseDraft = $true
& $script:publisher -Tag 'v2026.9.8.0' -NotesFile 'notes.md' -Assets @('a.zip') -DraftFirst $true *> $null
$rerun = $ghCallLog -join "`n"
if ($rerun -match [regex]::Escape('release edit v2026.9.8.0 --draft=false') -and $rerun -notmatch 'release create') {
    Write-Host 'ok    a re-run finds the draft left by the last run and promotes it'
} else {
    Write-Host 'FAIL  a re-run finds the draft left by the last run and promotes it'
    Write-Host "        $rerun"
    $script:failures++
}

Assert-Plan -Name 'delete-existing replaces a draft' -Params ($base + @{
        AssumeExisting = $true; AssumeDraft = $true; DeleteExisting = $true
    }) -Contains @('gh release delete v2026.9.8.0 --yes', 'gh release create v2026.9.8.0') -NotContains @(
    'gh release edit'
)

Assert-Plan -Name 'delete-existing deletes in the target repository' -Params ($base + @{
        AssumeExisting = $true; AssumeDraft = $true; DeleteExisting = $true; Repository = 'o/r'
    }) -Contains @('gh release delete v2026.9.8.0 --yes --repo o/r', 'gh release create v2026.9.8.0 --repo o/r')

$isReleaseDraft = $false
$failure = Invoke-Publisher -Params @{ Tag = 'v2026.9.8.0'; NotesFile = 'notes.md'; DeleteExisting = $true }
$deletes = @(foreach ($call in $ghCallLog) { if ($call -match '^release (delete|create|upload)') { $call } })
Assert-Check -Name 'delete-existing refuses a published release' -Condition (
    $failure -match 'already published' -and $deletes.Count -eq 0
) -Detail "$failure | $($deletes -join ' | ')"

$ghCallLog.Clear()
$isReleaseDraft = $true
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
    }) -Contains @('gh release view v2026.9.8.0 --json assets --repo o/r', 'expect a.zip sha256:deadbeef')

Assert-Plan -Name 'digest verification is skipped without a hash' -Params ($base + @{
        VerifyAsset = 'a.zip'
    }) -NotContains @('expect a.zip')

$plan = Get-Plan -Params ($base + @{ DraftFirst = $true; VerifyAsset = 'a.zip'; VerifySha256 = 'deadbeef' })
$checkAt = $plan.IndexOf('expect a.zip')
Assert-Check -Name 'draft-first checks the digest before publishing' -Condition (
    $checkAt -ge 0 -and $checkAt -lt $plan.IndexOf('--draft=false')
) -Detail $plan

$isReleaseDraft = $true
$verify = @{
    Tag = 'v2026.9.8.0'; NotesFile = 'notes.md'; Assets = @('a.zip'); DraftFirst = $true; VerifyAsset = 'a.zip'
    VerifyAttempts = 1; VerifyDelaySeconds = 0
}
$failure = Invoke-Publisher -Params ($verify + @{ VerifySha256 = 'feedface' })
$calls = $ghCallLog -join "`n"
Assert-Check -Name 'a draft with the wrong digest stays a draft' -Condition (
    $failure -match 'does not match' -and $calls -notmatch '--draft=false'
) -Detail "$failure | $calls"

$failure = Invoke-Publisher -Params ($verify + @{ VerifySha256 = $zipHash })
$calls = $ghCallLog -join "`n"
Assert-Check -Name 'a draft with the right digest is published' -Condition (
    -not $failure -and $calls -match [regex]::Escape('release edit v2026.9.8.0 --draft=false')
) -Detail "$failure | $calls"

$draftView = '{"assets":[{"name":"a.zip","digest":"sha256:' + ('0' * 64) + '"}],"isDraft":true}'
$failure = Invoke-Publisher -Params @{
    Tag = 'v2026.9.8.0'; Assets = @('a.zip'); DraftFirst = $true; VerifyAttempts = 1; VerifyDelaySeconds = 0
}
$calls = $ghCallLog -join "`n"
Assert-Check -Name 'a draft asset that differs from the local file stays a draft' -Condition (
    $failure -match "don't match the local file: a\.zip" -and $calls -notmatch '--draft=false'
) -Detail "$failure | $calls"

$draftView = '{"assets":[],"isDraft":true}'
$failure = Invoke-Publisher -Params @{
    Tag = 'v2026.9.8.0'; Assets = @('a.zip'); DraftFirst = $true; VerifyAttempts = 1; VerifyDelaySeconds = 0
}
Assert-Check -Name 'a draft missing an asset stays a draft' -Condition (
    $failure -match 'missing from draft' -and ($ghCallLog -join "`n") -notmatch '--draft=false'
) -Detail $failure
$draftView = $matchingView

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
