#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checker = Join-Path $PSScriptRoot 'Assert-VersionSequence.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("version-sequence-" + [System.Guid]::NewGuid().ToString('N'))

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function Assert-Result {
    param([string] $Name, [hashtable] $Params, [bool] $ShouldPass, [string] $ExpectedText = '')
    $out = (& $checker @Params *>&1) -join "`n"
    $passed = $LASTEXITCODE -eq 0
    if ($passed -ne $ShouldPass) {
        Write-Host "FAIL  $Name -- expected $(if ($ShouldPass) { 'pass' } else { 'failure' }), got exit $LASTEXITCODE"
        Write-Host "        $out"
        $script:failures++
        return
    }
    if ($ExpectedText -and $out -notmatch [regex]::Escape($ExpectedText)) {
        Write-Host "FAIL  $Name -- output did not mention '$ExpectedText'"
        Write-Host "        $out"
        $script:failures++
        return
    }
    Write-Host "ok    $Name"
}

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Push-Location $sandbox
    Invoke-Git @('init', '--initial-branch=main', '--quiet')
    Invoke-Git @('config', 'user.name', 'Test')
    Invoke-Git @('config', 'user.email', 'test@example.com')
    Invoke-Git @('config', 'commit.gpgsign', 'false')
    Set-Content -LiteralPath (Join-Path $sandbox 'a.txt') -Value 'seed'
    Invoke-Git @('add', '-A')
    Invoke-Git @('commit', '-m', 'chore: seed')

    Assert-Result 'first tag of the day expects .0' @{ Tag = 'v2026.9.8.0' } $true
    Assert-Result 'first tag of the day rejects .1' @{ Tag = 'v2026.9.8.1' } $false 'expected 0'
    Assert-Result 'a malformed tag is rejected' @{ Tag = 'v2026.9.8' } $false 'must be vYYYY.M.D.N'
    Assert-Result 'a non-v tag is rejected' @{ Tag = '2026.9.8.0' } $false 'must be vYYYY.M.D.N'

    Invoke-Git @('tag', 'v2026.9.8.0')
    Assert-Result 'second tag of the day expects .1' @{ Tag = 'v2026.9.8.1' } $true
    Assert-Result 'the tag under test is excluded, so re-checking it still passes' @{ Tag = 'v2026.9.8.0' } $true
    Assert-Result 'a different day is unaffected' @{ Tag = 'v2026.9.9.0' } $true

    Invoke-Git @('tag', 'v2026.9.8.1-A1B2')
    Assert-Result 'a hex prerelease counts toward the next revision' @{ Tag = 'v2026.9.8.2' } $true
    Assert-Result 'the hex prerelease is skipped under a beta-only suffix' @{ Tag = 'v2026.9.8.1'; PrereleaseSuffix = 'beta' } $true

    Invoke-Git @('tag', 'v2026.9.8.2-beta')
    Assert-Result 'a beta counts under the default suffix' @{ Tag = 'v2026.9.8.3' } $true
    Assert-Result 'a beta counts under a beta-only suffix' @{ Tag = 'v2026.9.8.3'; PrereleaseSuffix = 'beta' } $true
    Assert-Result 'the permissive suffix accepts a dotted prerelease' @{ Tag = 'v2026.9.8.3-rc.1'; PrereleaseSuffix = '[A-Za-z0-9][A-Za-z0-9.-]*' } $true
    Assert-Result 'the default suffix rejects a dotted prerelease' @{ Tag = 'v2026.9.8.3-rc.1' } $false 'must be vYYYY.M.D.N'

    $other = Join-Path $sandbox 'sub'
    New-Item -ItemType Directory -Path $other -Force | Out-Null
    Push-Location $other
    Assert-Result 'RepoRoot is honoured from another directory' @{ Tag = 'v2026.9.9.0'; RepoRoot = $sandbox } $true
    Pop-Location
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
