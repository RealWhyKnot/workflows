#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]] $Paths,
    [Parameter(Mandatory = $true)]
    [string] $Headline,
    [string] $Body = '',
    [string] $Branch = 'main',
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [bool] $SkipIfUnchanged = $true,
    [bool] $VerifySignature = $true,
    [bool] $WarnOnFailure = $false,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$files = @($Paths | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
if (-not $files) { Write-Host 'No paths given; nothing to commit.'; exit 0 }

foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "::error::File not found: $f"
        exit 1
    }
}

function Get-Base64 {
    param([string] $Path)
    return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path))
}

function Fail {
    param([string] $Message)
    if ($WarnOnFailure) { Write-Host "::warning::$Message"; exit 0 }
    Write-Host "::error::$Message"
    exit 1
}

if ($SkipIfUnchanged -and -not $DryRun) {
    $changed = $false
    foreach ($f in $files) {
        $remote = & git show "origin/$Branch`:$f" 2>$null
        if ($LASTEXITCODE -ne 0) { $changed = $true; $global:LASTEXITCODE = 0; break }
        $global:LASTEXITCODE = 0
        $remoteBytes = [System.Text.Encoding]::UTF8.GetBytes(($remote -join "`n"))
        $localBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $f).Path)
        $normalisedLocal = ([System.Text.Encoding]::UTF8.GetString($localBytes) -replace "`r`n", "`n").TrimEnd("`n")
        $normalisedRemote = ([System.Text.Encoding]::UTF8.GetString($remoteBytes) -replace "`r`n", "`n").TrimEnd("`n")
        if ($normalisedLocal -ne $normalisedRemote) { $changed = $true; break }
    }
    if (-not $changed) { Write-Host "No change against origin/$Branch; nothing to commit."; exit 0 }
}

$expectedOid = ''
if ($DryRun) {
    $expectedOid = '0000000000000000000000000000000000000000'
} else {
    $expectedOid = (& gh api "repos/$Repository/branches/$Branch" --jq '.commit.sha')
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($expectedOid)) {
        Fail "Could not read the head of $Branch on $Repository."
    }
    $expectedOid = $expectedOid.Trim()
}

$additions = @($files | ForEach-Object { @{ path = $_.Replace([char]92, [char]47); contents = (Get-Base64 -Path $_) } })

$message = @{ headline = $Headline }
if ($Body) { $message['body'] = $Body }

$payload = @{
    query     = 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }'
    variables = @{
        input = @{
            branch          = @{ repositoryNameWithOwner = $Repository; branchName = $Branch }
            message         = $message
            fileChanges     = @{ additions = $additions }
            expectedHeadOid = $expectedOid
        }
    }
} | ConvertTo-Json -Depth 12

if ($DryRun) {
    Write-Output $payload
    exit 0
}

$payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("commit-on-branch-" + [System.Guid]::NewGuid().ToString('N') + '.json')
[System.IO.File]::WriteAllText($payloadPath, $payload, (New-Object System.Text.UTF8Encoding($false)))

try {
    $response = & gh api graphql --input $payloadPath
    if ($LASTEXITCODE -ne 0) { Fail 'createCommitOnBranch failed.' }
    $result = $response | ConvertFrom-Json
    if ($result.PSObject.Properties.Name -contains 'errors' -and $result.errors) {
        Fail "createCommitOnBranch returned GraphQL errors: $($result.errors | ConvertTo-Json -Compress)"
    }
    $oid = [string] $result.data.createCommitOnBranch.commit.oid
    if ([string]::IsNullOrWhiteSpace($oid)) { Fail 'createCommitOnBranch returned no commit oid.' }
    Write-Host "Committed $($files -join ', ') to $Branch as $oid"

    if ($VerifySignature) {
        $verified = & gh api "repos/$Repository/commits/$oid" --jq '.commit.verification.verified'
        if ($LASTEXITCODE -ne 0) { Fail "Could not read verification state for $oid." }
        if ("$verified".Trim() -ne 'true') { Fail "Commit $oid is not verified (got: $verified)." }
        Write-Host 'Verification: ok'
    }
}
finally {
    Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
}
