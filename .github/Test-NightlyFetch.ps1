#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workflow = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'workflows/nightly-beta-scripted.yml'))
$match = [regex]::Match($workflow, '(?s)- name: Plan the nightly beta\r?\n(?<step>.*?)(?=\r?\n      - name:)')
if (-not $match.Success) { throw 'The nightly planner step is missing.' }
$step = $match.Groups['step'].Value
$run = [regex]::Match($step, '(?s)run: \|\r?\n(?<body>.*)')
if (-not $run.Success) { throw 'The nightly planner script is missing.' }
$body = $run.Groups['body'].Value
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('nightly-fetch-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($sandbox)
try {
    $planner = Join-Path $sandbox 'planner.ps1'
    [IO.File]::WriteAllText($planner, '$global:ranPlanner = $true')
    $probe = @'
param([string] $Body, [string] $Planner, [int] $FetchExit)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:GH_TOKEN = 'test-token'
$env:REPO = 'owner/private-repo'
$env:PLANNER = $Planner
$global:ranPlanner = $false
$script:fetchExit = $FetchExit
function git {
    $expected = 'fetch --tags --force https://x-access-token:test-token@github.com/owner/private-repo.git'
    if (($args -join ' ') -ne $expected) {
        throw 'The fetch did not use the authenticated repository URL.'
    }
    $global:LASTEXITCODE = $script:fetchExit
}
$failed = $false
try { & ([scriptblock]::Create($Body)) } catch { $failed = $true }
if ($FetchExit -eq 0 -and ($failed -or -not $global:ranPlanner)) { throw 'The authenticated fetch failed.' }
if ($FetchExit -ne 0 -and (-not $failed -or $global:ranPlanner)) { throw 'The planner ran after a failed fetch.' }
'@
    $probePath = Join-Path $sandbox 'probe.ps1'
    [IO.File]::WriteAllText($probePath, $probe)
    foreach ($fetchExit in @(0, 1)) {
        & pwsh -NoProfile -File $probePath -Body $body -Planner $planner -FetchExit $fetchExit
        if ($LASTEXITCODE -ne 0) { throw "Nightly fetch test failed with exit code $fetchExit." }
    }
    if ($step -notmatch 'REPO: \$\{\{ github.repository \}\}') { throw 'The planner repository is missing.' }
    Write-Host 'Nightly fetch checks passed.'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}
exit 0
