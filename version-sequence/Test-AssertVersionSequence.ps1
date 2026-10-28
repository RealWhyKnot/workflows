#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Git {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function Assert-Result {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Params, [bool] $ShouldPass, [string] $ExpectedText = '')
    $out = (& $script:checker @Params *>&1) -join "`n"
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

$script:checker = Join-Path $PSScriptRoot 'Assert-VersionSequence.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('version-sequence-' + [System.Guid]::NewGuid().ToString('N'))

try {
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    Push-Location $sandbox
    Invoke-Git @('init', '--initial-branch=main', '--quiet')
    Invoke-Git @('config', 'user.name', 'Test')
    Invoke-Git @('config', 'user.email', 'test@example.com')
    Invoke-Git @('config', 'commit.gpgsign', 'false')
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'a.txt'), 'seed' + [Environment]::NewLine)
    Invoke-Git @('add', '-A')
    Invoke-Git @('commit', '-m', 'chore: seed')

    Assert-Result -Name 'first tag of the day expects .0' -Params @{ Tag = 'v2026.9.8.0' } -ShouldPass $true
    Assert-Result -Name 'first tag of the day rejects .1' -Params @{
        Tag = 'v2026.9.8.1'
    } -ShouldPass $false -ExpectedText 'expected 0'
    Assert-Result -Name 'a malformed tag is rejected' -Params @{
        Tag = 'v2026.9.8'
    } -ShouldPass $false -ExpectedText 'must be vYYYY.M.D.N'
    Assert-Result -Name 'a non-v tag is rejected' -Params @{
        Tag = '2026.9.8.0'
    } -ShouldPass $false -ExpectedText 'must be vYYYY.M.D.N'

    Invoke-Git @('tag', 'v2026.9.8.0')
    Assert-Result -Name 'second tag of the day expects .1' -Params @{ Tag = 'v2026.9.8.1' } -ShouldPass $true
    Assert-Result -Name 'the tag under test is excluded, so re-checking it still passes' -Params @{
        Tag = 'v2026.9.8.0'
    } -ShouldPass $true
    Assert-Result -Name 'a different day is unaffected' -Params @{ Tag = 'v2026.9.9.0' } -ShouldPass $true

    Invoke-Git @('tag', 'v2026.9.8.1-A1B2')
    Assert-Result -Name 'a hex prerelease counts toward the next revision' -Params @{
        Tag = 'v2026.9.8.2'
    } -ShouldPass $true
    Assert-Result -Name 'the hex prerelease still counts under a beta-only suffix' -Params @{
        Tag = 'v2026.9.8.2'; PrereleaseSuffix = 'beta'
    } -ShouldPass $true
    Assert-Result -Name 'a beta-only suffix cannot reuse the hex prerelease revision' -Params @{
        Tag = 'v2026.9.8.1'; PrereleaseSuffix = 'beta'
    } -ShouldPass $false -ExpectedText 'expected 2'

    Invoke-Git @('tag', 'v2026.9.8.2-beta')
    Assert-Result -Name 'a beta counts under the default suffix' -Params @{ Tag = 'v2026.9.8.3' } -ShouldPass $true
    Assert-Result -Name 'a beta counts under a beta-only suffix' -Params @{
        Tag = 'v2026.9.8.3'; PrereleaseSuffix = 'beta'
    } -ShouldPass $true
    Assert-Result -Name 'the permissive suffix accepts a dotted prerelease' -Params @{
        Tag = 'v2026.9.8.3-rc.1'; PrereleaseSuffix = '[A-Za-z0-9][A-Za-z0-9.-]*'
    } -ShouldPass $true
    Assert-Result -Name 'the default suffix rejects a dotted prerelease' -Params @{
        Tag = 'v2026.9.8.3-rc.1'
    } -ShouldPass $false -ExpectedText 'must be vYYYY.M.D.N'

    $other = Join-Path $sandbox 'sub'
    $null = New-Item -ItemType Directory -Path $other -Force
    Push-Location $other
    Assert-Result -Name 'RepoRoot is honoured from another directory' -Params @{
        Tag = 'v2026.9.9.0'; RepoRoot = $sandbox
    } -ShouldPass $true
    Pop-Location
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed."
    exit 1
}
Write-Host "`nAll checks passed."
exit 0
