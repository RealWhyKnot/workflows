#!/usr/bin/env pwsh
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
    [switch] $AssumeExisting
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Title) { $Title = $Tag }
$assetList = @()
foreach ($entry in @($Assets | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })) {
    if ($entry -match '[*?]') {
        # A glob that matches nothing contributes nothing, which is what the hand-rolled
        # Get-ChildItem calls this replaces did.
        $assetList += @(Get-ChildItem -Path $entry -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    } else {
        $assetList += $entry
    }
}

function Invoke-Gh {
    param([string[]] $Arguments)
    if ($DryRun) { Write-Host "gh $($Arguments -join ' ')"; return '' }
    $output = & gh @Arguments
    return $output
}

$lookupArgs = @('release', 'view', $Tag, '--json', 'id')
if ($Repository) { $lookupArgs += @('--repo', $Repository) }
$existing = [bool] $AssumeExisting
if ($DryRun) {
    Write-Host "gh $($lookupArgs -join ' ')"
} else {
    $global:LASTEXITCODE = 0
    $found = & gh @lookupArgs 2>$null
    $existing = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($found)
    $global:LASTEXITCODE = 0
}

if ($DeleteExisting -and $existing) {
    if ($DryRun) {
        Write-Host "gh release delete $Tag --yes"
    } else {
        & gh release delete $Tag --yes
        if ($LASTEXITCODE -ne 0) { throw "Could not delete the existing release $Tag." }
        Write-Host "Deleted the existing release $Tag."
    }
    $existing = $false
}

if ($existing) {
    $editArgs = @('release', 'edit', $Tag)
    if ($Repository) { $editArgs += @('--repo', $Repository) }
    $editArgs += @('--title', $Title)
    if ($NotesFile)  { $editArgs += @('--notes-file', $NotesFile) }
    if ($Prerelease) { $editArgs += @('--prerelease', '--latest=false') }
    Invoke-Gh -Arguments $editArgs | Out-Null
    if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release edit failed ($LASTEXITCODE)" }

    if ($assetList.Count -gt 0) {
        $uploadArgs = @('release', 'upload', $Tag) + $assetList + @('--clobber')
        if ($Repository) { $uploadArgs += @('--repo', $Repository) }
        Invoke-Gh -Arguments $uploadArgs | Out-Null
        if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release upload failed ($LASTEXITCODE)" }
    }
    Write-Host "Updated the existing release $Tag."
}
else {

$createArgs = @('release', 'create', $Tag) + $assetList
if ($Repository) { $createArgs += @('--repo', $Repository) }
if ($Target)     { $createArgs += @('--target', $Target) }
$createArgs += @('--title', $Title)
if ($NotesFile)  { $createArgs += @('--notes-file', $NotesFile) }
if ($DraftFirst) { $createArgs += '--draft' }
if ($Prerelease) { $createArgs += @('--prerelease', '--latest=false') }

Invoke-Gh -Arguments $createArgs | Out-Null
if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release create failed ($LASTEXITCODE)" }

if ($DraftFirst) {
    $viewArgs = @('release', 'view', $Tag, '--json', 'assets,isDraft')
    if ($Repository) { $viewArgs += @('--repo', $Repository) }
    if ($DryRun) {
        Write-Host "gh $($viewArgs -join ' ')"
    } else {
        $json = & gh @viewArgs
        if ($LASTEXITCODE -ne 0) { throw "gh release view failed ($LASTEXITCODE)" }
        $info = $json | ConvertFrom-Json
        foreach ($expected in $assetList) {
            $name = Split-Path -Leaf $expected
            if (-not ($info.assets.name -contains $name)) {
                throw "Asset '$name' did not attach to draft release $Tag; leaving it as a draft for inspection."
            }
        }
        Write-Host "Draft $Tag carries every expected asset, promoting it."
    }
    $editArgs = @('release', 'edit', $Tag, '--draft=false')
    if ($Repository) { $editArgs += @('--repo', $Repository) }
    Invoke-Gh -Arguments $editArgs | Out-Null
    if (-not $DryRun -and $LASTEXITCODE -ne 0) { throw "gh release edit --draft=false failed ($LASTEXITCODE)" }
}

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
