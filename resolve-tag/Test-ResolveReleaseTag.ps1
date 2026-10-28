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

function Invoke-Resolve {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable] $Params)
    [System.IO.File]::WriteAllText($script:outFile, '')
    $p = @{} + $Params
    $p['OutputPath'] = $script:outFile
    $null = & $script:checker @p *>&1
    $code = $LASTEXITCODE
    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($script:outFile)) {
        if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return @{ Code = $code; Out = $map }
}

function Assert-Output {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Params, [hashtable] $Expected)
    $r = Invoke-Resolve -Params $Params
    if ($r.Code -ne 0) { Write-Host "FAIL  $Name -- exit $($r.Code)"; $script:failures++; return }
    foreach ($k in $Expected.Keys) {
        if (-not $r.Out.ContainsKey($k)) { Write-Host "FAIL  $Name -- no output '$k'"; $script:failures++; return }
        if ($r.Out[$k] -ne $Expected[$k]) {
            Write-Host "FAIL  $Name -- $k was '$($r.Out[$k])', expected '$($Expected[$k])'"; $script:failures++; return
        }
    }
    Write-Host "ok    $Name"
}

function Assert-Failure {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Params)
    $r = Invoke-Resolve -Params $Params
    if ($r.Code -eq 0) { Write-Host "FAIL  $Name -- expected failure, got exit 0"; $script:failures++; return }
    Write-Host "ok    $Name"
}

$script:checker = Join-Path $PSScriptRoot 'Resolve-ReleaseTag.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('resolve-tag-' + [System.Guid]::NewGuid().ToString('N'))
$script:outFile = Join-Path $sandbox 'out.txt'

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
    $head = (& git rev-parse HEAD).Trim()
    Invoke-Git @('tag', 'v2026.9.8.0')
    Invoke-Git @('tag', 'v2026.9.8.1-beta')
    Invoke-Git @('tag', 'v2026.9.8.2-A1B2')

    Assert-Output -Name 'a stable tag resolves' -Params @{ Tag = 'v2026.9.8.0' } -Expected @{
        tag = 'v2026.9.8.0'; version = '2026.9.8.0'; prerelease = 'false'; channel = 'release'; sha = $head
    }
    Assert-Output -Name 'a beta tag is a prerelease' -Params @{ Tag = 'v2026.9.8.1-beta' } -Expected @{
        prerelease = 'true'; channel = 'beta'; version = '2026.9.8.1-beta'
    }
    Assert-Output -Name 'a hex tag is valid but not a beta by default' -Params @{
        Tag = 'v2026.9.8.2-A1B2'
    } -Expected @{ prerelease = 'false'; channel = 'release' }
    Assert-Output -Name 'any-suffix pattern makes the hex tag a prerelease' -Params @{
        Tag = 'v2026.9.8.2-A1B2'; PrereleasePattern = '^v\d{4}\.\d+\.\d+\.\d+-.+$'
    } -Expected @{ prerelease = 'true'; channel = 'beta' }
    Assert-Output -Name 'the fallback is used when no tag is given' -Params @{
        FallbackTag = 'v2026.9.8.0'
    } -Expected @{ tag = 'v2026.9.8.0' }
    Assert-Output -Name 'an explicit tag wins over the fallback' -Params @{
        Tag = 'v2026.9.8.1-beta'; FallbackTag = 'v2026.9.8.0'
    } -Expected @{ tag = 'v2026.9.8.1-beta' }

    Assert-Failure -Name 'a malformed tag is rejected' -Params @{ Tag = 'v2026.9.8' }
    Assert-Failure -Name 'a branch name is rejected' -Params @{ Tag = 'main' }
    Assert-Failure -Name 'no tag and no fallback fails' -Params @{}
    Assert-Failure -Name 'a well-formed tag that does not exist is rejected' -Params @{ Tag = 'v2026.9.9.0' }
    Assert-Output -Name 'the missing tag is allowed when existence is not required' -Params @{
        Tag = 'v2026.9.9.0'; RequireTagExists = $false
    } -Expected @{ tag = 'v2026.9.9.0'; sha = '' }
    Assert-Failure -Name 'a suffix outside the tag pattern is rejected' -Params @{ Tag = 'v2026.9.8.3-rc.1' }
    $fresh = & pwsh -NoProfile -Command "& '$script:checker' -Tag 'v2026.9.8.0' -OutputPath '$script:outFile'" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL  a fresh session with no prior native command resolves -- exit $LASTEXITCODE : $fresh"
        $script:failures++
    } else {
        Write-Host 'ok    a fresh session with no prior native command resolves'
    }

    Assert-Output -Name 'a widened tag pattern accepts it' -Params @{
        Tag              = 'v2026.9.8.3-rc.1'
        TagPattern       = '^v\d{4}\.\d+\.\d+\.\d+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$'
        RequireTagExists = $false
    } -Expected @{ tag = 'v2026.9.8.3-rc.1' }
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
