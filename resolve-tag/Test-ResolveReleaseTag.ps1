#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:checker = Join-Path $PSScriptRoot 'Resolve-ReleaseTag.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("resolve-tag-" + [System.Guid]::NewGuid().ToString('N'))
$script:outFile = Join-Path $sandbox 'out.txt'

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function Invoke-Resolve {
    param([hashtable] $Params)
    Set-Content -LiteralPath $script:outFile -Value '' -NoNewline
    $p = @{} + $Params
    $p['OutputPath'] = $script:outFile
    $null = & $script:checker @p *>&1
    $code = $LASTEXITCODE
    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $script:outFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return @{ Code = $code; Out = $map }
}

function Assert-Outputs {
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

function Assert-Fails {
    param([string] $Name, [hashtable] $Params)
    $r = Invoke-Resolve -Params $Params
    if ($r.Code -eq 0) { Write-Host "FAIL  $Name -- expected failure, got exit 0"; $script:failures++; return }
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
    $head = (& git rev-parse HEAD).Trim()
    Invoke-Git @('tag', 'v2026.9.8.0')
    Invoke-Git @('tag', 'v2026.9.8.1-beta')
    Invoke-Git @('tag', 'v2026.9.8.2-A1B2')

    Assert-Outputs 'a stable tag resolves' @{ Tag = 'v2026.9.8.0' } @{ tag='v2026.9.8.0'; version='2026.9.8.0'; prerelease='false'; channel='release'; sha=$head }
    Assert-Outputs 'a beta tag is a prerelease' @{ Tag = 'v2026.9.8.1-beta' } @{ prerelease='true'; channel='beta'; version='2026.9.8.1-beta' }
    Assert-Outputs 'a hex tag is valid but not a beta by default' @{ Tag = 'v2026.9.8.2-A1B2' } @{ prerelease='false'; channel='release' }
    Assert-Outputs 'any-suffix pattern makes the hex tag a prerelease' @{ Tag = 'v2026.9.8.2-A1B2'; PrereleasePattern = '^v\d{4}\.\d+\.\d+\.\d+-.+$' } @{ prerelease='true'; channel='beta' }
    Assert-Outputs 'the fallback is used when no tag is given' @{ FallbackTag = 'v2026.9.8.0' } @{ tag='v2026.9.8.0' }
    Assert-Outputs 'an explicit tag wins over the fallback' @{ Tag = 'v2026.9.8.1-beta'; FallbackTag = 'v2026.9.8.0' } @{ tag='v2026.9.8.1-beta' }

    Assert-Fails 'a malformed tag is rejected' @{ Tag = 'v2026.9.8' }
    Assert-Fails 'a branch name is rejected' @{ Tag = 'main' }
    Assert-Fails 'no tag and no fallback fails' @{}
    Assert-Fails 'a well-formed tag that does not exist is rejected' @{ Tag = 'v2026.9.9.0' }
    Assert-Outputs 'the missing tag is allowed when existence is not required' @{ Tag = 'v2026.9.9.0'; RequireTagExists = $false } @{ tag='v2026.9.9.0'; sha='' }
    Assert-Fails 'a suffix outside the tag pattern is rejected' @{ Tag = 'v2026.9.8.3-rc.1' }
    $fresh = & pwsh -NoProfile -Command "& '$script:checker' -Tag 'v2026.9.8.0' -OutputPath '$script:outFile'" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL  a fresh session with no prior native command resolves -- exit $LASTEXITCODE : $fresh"
        $script:failures++
    }
    else {
        Write-Host 'ok    a fresh session with no prior native command resolves'
    }

    Assert-Outputs 'a widened tag pattern accepts it' @{ Tag = 'v2026.9.8.3-rc.1'; TagPattern = '^v\d{4}\.\d+\.\d+\.\d+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$'; RequireTagExists = $false } @{ tag='v2026.9.8.3-rc.1' }
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
