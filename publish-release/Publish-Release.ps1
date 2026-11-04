#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Tag,
    [string] $Title = '',
    [string] $NotesFile = '',
    [string[]] $Assets = @(),
    [string] $Repository = '',
    [string] $Target = '',
    [bool] $Prerelease = $false,
    [bool] $DraftFirst = $false,
    [bool] $DeleteExisting = $false,
    [string] $VerifyAsset = '',
    [string] $VerifySha256 = '',
    [int] $VerifyAttempts = 6,
    [int] $VerifyDelaySeconds = 2,
    [switch] $DryRun,
    [switch] $AssumeExisting,
    [switch] $AssumeDraft
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Gh {
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]] $Arguments, [bool] $DryRun)
    if ($DryRun) { Write-Host "gh $($Arguments -join ' ')"; return '' }
    $output = & gh @Arguments
    return $output
}

function Assert-AssetDigest {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $Tag,
        [string[]] $RepoArgs,
        [string] $Asset,
        [string] $Sha256,
        [int] $Attempts,
        [int] $DelaySeconds,
        [bool] $DryRun
    )
    $expected = "sha256:$Sha256"
    $viewArgs = @('release', 'view', $Tag, '--json', 'assets') + $RepoArgs
    if ($DryRun) { Write-Host "gh $($viewArgs -join ' ') (expect $Asset $expected)"; return }
    for ($attemptIndex = 0; $attemptIndex -lt $Attempts; $attemptIndex++) {
        Start-Sleep -Seconds $DelaySeconds
        $global:LASTEXITCODE = 0
        $json = & gh @viewArgs 2>$null
        $hasFetched = $LASTEXITCODE -eq 0
        $global:LASTEXITCODE = 0
        if (-not $hasFetched) { continue }
        $assets = @(($json | ConvertFrom-Json).assets)
        $matching = @($assets | Where-Object { $_.name -eq $Asset -and $_.digest -eq $expected })
        if ($matching.Count -gt 0) { Write-Host "Verified $Asset digest $expected"; return }
    }
    throw "Uploaded $Asset digest does not match $expected."
}

function Publish-Draft {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $Tag,
        [string[]] $RepoArgs,
        [string[]] $AssetList,
        [hashtable] $Verify,
        [int] $Attempts,
        [int] $DelaySeconds,
        [bool] $DryRun
    )
    $viewArgs = @('release', 'view', $Tag, '--json', 'assets,isDraft') + $RepoArgs
    if ($DryRun) {
        Write-Host "gh $($viewArgs -join ' ')"
    } else {
        $expected = @{}
        foreach ($path in $AssetList) {
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $expected[(Split-Path -Leaf $path)] = "sha256:$hash"
        }
        $wrong = @($expected.Keys)
        for ($attemptIndex = 0; $attemptIndex -lt $Attempts -and $wrong.Count -gt 0; $attemptIndex++) {
            if ($attemptIndex -gt 0) { Start-Sleep -Seconds $DelaySeconds }
            $json = & gh @viewArgs
            if ($LASTEXITCODE -ne 0) { throw "gh release view failed ($LASTEXITCODE)" }
            $digests = @{}
            foreach ($asset in @(($json | ConvertFrom-Json).assets)) {
                $digest = $asset.PSObject.Properties['digest']
                if ($digest) { $digests[$asset.name] = [string] $digest.Value }
            }
            $wrong = @(foreach ($name in $expected.Keys) { if ($digests[$name] -ne $expected[$name]) { $name } })
        }
        if ($wrong.Count -gt 0) {
            $names = ($wrong | Sort-Object) -join ', '
            throw "These assets are missing from draft $Tag or don't match the local file: $names. It stays a draft."
        }
        Write-Host "Draft $Tag has all $($AssetList.Count) assets, and their SHA-256 digests match the local files."
    }
    if ($Verify) { Assert-AssetDigest @Verify }
    $editArgs = @('release', 'edit', $Tag, '--draft=false') + $RepoArgs
    $null = Invoke-Gh -Arguments $editArgs -DryRun $DryRun
    if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release edit --draft=false failed ($LASTEXITCODE)" }
}

if (-not $Title) { $Title = $Tag }
$assetList = @(foreach ($asset in $Assets) {
        if (-not ($asset -and $asset.Trim())) { continue }
        $entry = $asset.Trim()
        if ($entry -match '[*?]') {
            foreach ($file in @(Get-ChildItem -Path $entry -File -ErrorAction SilentlyContinue)) { $file.FullName }
        } else {
            $entry
        }
    })
$repoArgs = @(if ($Repository) { '--repo'; $Repository })
$titleArgs = @('--title', $Title) + @(if ($NotesFile) { '--notes-file'; $NotesFile })
$prereleaseArgs = @(if ($Prerelease) { '--prerelease'; '--latest=false' })
$verifyArgs = $null
if ($VerifySha256 -and $VerifyAsset) {
    $verifyArgs = @{
        Tag = $Tag; RepoArgs = $repoArgs; Asset = $VerifyAsset; Sha256 = $VerifySha256
        Attempts = $VerifyAttempts; DelaySeconds = $VerifyDelaySeconds; DryRun = $DryRun.IsPresent
    }
}
$draftArgs = @{
    Tag = $Tag; RepoArgs = $repoArgs; AssetList = $assetList; Verify = $verifyArgs
    Attempts = $VerifyAttempts; DelaySeconds = $VerifyDelaySeconds; DryRun = $DryRun.IsPresent
}

$lookupArgs = @('release', 'view', $Tag, '--json', 'id,isDraft,assets') + $repoArgs
$hasExistingRelease = [bool] $AssumeExisting
$isExistingDraft = [bool] $AssumeDraft
$attachedNames = @()
$isDraftChecked = $false
if ($DryRun) {
    Write-Host "gh $($lookupArgs -join ' ')"
} else {
    $global:LASTEXITCODE = 0
    $found = & gh @lookupArgs 2>$null
    $hasExistingRelease = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($found)
    if ($hasExistingRelease) {
        $existing = $found | ConvertFrom-Json
        $isExistingDraft = [bool] $existing.isDraft
        $attachedNames = @(foreach ($attached in @($existing.assets)) { $attached.name })
    }
    $global:LASTEXITCODE = 0
}

if ($DeleteExisting -and $hasExistingRelease) {
    if (-not $isExistingDraft) {
        throw "Release $Tag is already published. delete-existing only deletes drafts."
    }
    $deleteArgs = @('release', 'delete', $Tag, '--yes') + $repoArgs
    if ($DryRun) {
        Write-Host "gh $($deleteArgs -join ' ')"
    } else {
        & gh @deleteArgs
        if ($LASTEXITCODE -ne 0) { throw "Could not delete the existing release $Tag." }
        Write-Host "Deleted the existing draft $Tag."
    }
    $hasExistingRelease = $false
}

if ($hasExistingRelease) {
    $editArgs = @('release', 'edit', $Tag) + $repoArgs + $titleArgs + $prereleaseArgs
    $null = Invoke-Gh -Arguments $editArgs -DryRun $DryRun.IsPresent
    if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release edit failed ($LASTEXITCODE)" }

    $uploadList = $assetList
    $clobberArgs = @('--clobber')
    if (-not $isExistingDraft) {
        $clobberArgs = @()
        $uploadList = @(foreach ($asset in $assetList) {
                $name = Split-Path -Leaf $asset
                if ($attachedNames -notcontains $name) { $asset; continue }
                Write-Host "Skipped ${name}: $Tag already has it."
            })
    }
    if ($uploadList.Count -gt 0) {
        $uploadArgs = @('release', 'upload', $Tag) + $uploadList + $clobberArgs + $repoArgs
        $null = Invoke-Gh -Arguments $uploadArgs -DryRun $DryRun.IsPresent
        if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release upload failed ($LASTEXITCODE)" }
    }
    if ($isExistingDraft) { Publish-Draft @draftArgs; $isDraftChecked = $true }
    Write-Host "Updated the existing release $Tag."
} else {
    $targetArgs = @(if ($Target) { '--target'; $Target })
    $draftFlag = @(if ($DraftFirst) { '--draft' })
    $createArgs = @('release', 'create', $Tag) + $assetList + $repoArgs + $targetArgs + $titleArgs + $draftFlag +
    $prereleaseArgs

    $null = Invoke-Gh -Arguments $createArgs -DryRun $DryRun.IsPresent
    if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release create failed ($LASTEXITCODE)" }

    if ($DraftFirst) { Publish-Draft @draftArgs; $isDraftChecked = $true }
}

if ($verifyArgs -and -not $isDraftChecked) { Assert-AssetDigest @verifyArgs }

Write-Host "Published $Tag."
exit 0
