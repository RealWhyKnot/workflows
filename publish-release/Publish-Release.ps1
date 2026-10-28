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

function Publish-Draft {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Tag, [string[]] $RepoArgs, [string[]] $AssetList, [bool] $DryRun)
    $viewArgs = @('release', 'view', $Tag, '--json', 'assets,isDraft') + $RepoArgs
    if ($DryRun) {
        Write-Host "gh $($viewArgs -join ' ')"
    } else {
        $json = & gh @viewArgs
        if ($LASTEXITCODE -ne 0) { throw "gh release view failed ($LASTEXITCODE)" }
        $info = $json | ConvertFrom-Json
        foreach ($expected in $AssetList) {
            $name = Split-Path -Leaf $expected
            if (-not ($info.assets.name -contains $name)) {
                throw "Asset '$name' did not attach to draft release $Tag; leaving it as a draft for inspection."
            }
        }
        Write-Host "Draft $Tag carries every expected asset, promoting it."
    }
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
$draftArgs = @{ Tag = $Tag; RepoArgs = $repoArgs; AssetList = $assetList; DryRun = $DryRun.IsPresent }

$lookupArgs = @('release', 'view', $Tag, '--json', 'id,isDraft') + $repoArgs
$existing = [bool] $AssumeExisting
$existingDraft = [bool] $AssumeDraft
if ($DryRun) {
    Write-Host "gh $($lookupArgs -join ' ')"
} else {
    $global:LASTEXITCODE = 0
    $found = & gh @lookupArgs 2>$null
    $existing = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($found)
    if ($existing) { $existingDraft = [bool] ($found | ConvertFrom-Json).isDraft }
    $global:LASTEXITCODE = 0
}

if ($DeleteExisting -and $existing) {
    $deleteArgs = @('release', 'delete', $Tag, '--yes') + $repoArgs
    if ($DryRun) {
        Write-Host "gh $($deleteArgs -join ' ')"
    } else {
        & gh @deleteArgs
        if ($LASTEXITCODE -ne 0) { throw "Could not delete the existing release $Tag." }
        Write-Host "Deleted the existing release $Tag."
    }
    $existing = $false
}

if ($existing) {
    $editArgs = @('release', 'edit', $Tag) + $repoArgs + $titleArgs + $prereleaseArgs
    $null = Invoke-Gh -Arguments $editArgs -DryRun $DryRun.IsPresent
    if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release edit failed ($LASTEXITCODE)" }

    if ($assetList.Count -gt 0) {
        $uploadArgs = @('release', 'upload', $Tag) + $assetList + @('--clobber') + $repoArgs
        $null = Invoke-Gh -Arguments $uploadArgs -DryRun $DryRun.IsPresent
        if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release upload failed ($LASTEXITCODE)" }
    }
    if ($existingDraft) { Publish-Draft @draftArgs }
    Write-Host "Updated the existing release $Tag."
} else {
    $targetArgs = @(if ($Target) { '--target'; $Target })
    $draftFlag = @(if ($DraftFirst) { '--draft' })
    $createArgs = @('release', 'create', $Tag) + $assetList + $repoArgs + $targetArgs + $titleArgs + $draftFlag +
    $prereleaseArgs

    $null = Invoke-Gh -Arguments $createArgs -DryRun $DryRun.IsPresent
    if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release create failed ($LASTEXITCODE)" }

    if ($DraftFirst) { Publish-Draft @draftArgs }
}

if ($VerifySha256 -and $VerifyAsset) {
    $repo = if ($Repository) { $Repository } else { $env:GITHUB_REPOSITORY }
    $expected = "sha256:$VerifySha256"
    if ($DryRun) {
        Write-Host "gh api repos/$repo/releases/tags/$Tag (expect $VerifyAsset $expected)"
    } else {
        $ok = $false
        for ($i = 0; $i -lt $VerifyAttempts -and -not $ok; $i++) {
            Start-Sleep -Seconds $VerifyDelaySeconds
            $json = & gh api "repos/$repo/releases/tags/$Tag" 2>$null
            $fetched = $LASTEXITCODE -eq 0
            $global:LASTEXITCODE = 0
            if (-not $fetched) { continue }
            $release = $json | ConvertFrom-Json
            $asset = $release.assets | Where-Object { $_.name -eq $VerifyAsset }
            if ($asset -and $asset.digest -eq $expected) { $ok = $true }
        }
        if (-not $ok) { throw "Uploaded $VerifyAsset digest does not match $expected." }
        Write-Host "Verified $VerifyAsset digest $expected"
    }
}

Write-Host "Published $Tag."
exit 0
