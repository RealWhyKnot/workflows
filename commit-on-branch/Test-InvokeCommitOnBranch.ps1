#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Merge-Parameter {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable] $Base, [hashtable] $Override)
    $m = @{}
    foreach ($k in $Base.Keys) { $m[$k] = $Base[$k] }
    foreach ($k in $Override.Keys) { $m[$k] = $Override[$k] }
    return $m
}

function Get-Payload {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable] $Params)
    $p = @{} + $Params
    $p['DryRun'] = $true
    $p['SkipIfUnchanged'] = $false
    $lines = foreach ($item in & $script:committer @p 2>&1) { "$item" }
    return $lines -join "`n"
}

function Assert-Json {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Params, [scriptblock] $Check)
    $raw = Get-Payload -Params $Params
    try { $obj = $raw | ConvertFrom-Json } catch [System.ArgumentException] {
        Write-Host "FAIL  $Name -- payload is not valid JSON"; Write-Host "        $raw"; $script:failures++; return
    }
    $problem = & $Check $obj
    if ($problem) { Write-Host "FAIL  $Name -- $problem"; $script:failures++; return }
    Write-Host "ok    $Name"
}

$script:committer = Join-Path $PSScriptRoot 'Invoke-CommitOnBranch.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('commit-on-branch-' + [System.Guid]::NewGuid().ToString('N'))

try {
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    Push-Location $sandbox
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'CHANGELOG.md'), "# Changelog`nhello`n")
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'wiki.md'), "wiki body`n")

    $base = @{ Paths = @('CHANGELOG.md'); Headline = 'docs(changelog): promote [skip changelog]'; Repository = 'o/r' }

    Assert-Json -Name 'the mutation and branch are set' -Params $base -Check {
        param([object] $o)
        if ($o.query -notmatch 'createCommitOnBranch') { return 'query does not call the mutation' }
        if ($o.variables.input.branch.repositoryNameWithOwner -ne 'o/r') { return 'wrong repository' }
        if ($o.variables.input.branch.branchName -ne 'main') { return 'branch should default to main' }
        return $null
    }

    Assert-Json -Name 'the headline is carried and no body is sent when empty' -Params $base -Check {
        param([object] $o)
        if ($o.variables.input.message.headline -ne 'docs(changelog): promote [skip changelog]') {
            return 'headline missing'
        }
        if ($o.variables.input.message.PSObject.Properties.Name -contains 'body') { return 'body should be absent' }
        return $null
    }

    $withBody = Merge-Parameter -Base $base -Override @{ Body = 'Maintained by CI.' }
    Assert-Json -Name 'a body is included when given' -Params $withBody -Check {
        param([object] $o)
        if ($o.variables.input.message.body -ne 'Maintained by CI.') { return 'body missing' }
        return $null
    }

    Assert-Json -Name 'the file is base64 encoded under its path' -Params $base -Check {
        param([object] $o)
        $add = @($o.variables.input.fileChanges.additions)
        if ($add.Count -ne 1) { return "expected 1 addition, got $($add.Count)" }
        if ($add[0].path -ne 'CHANGELOG.md') { return "wrong path $($add[0].path)" }
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($add[0].contents))
        if ($decoded -notmatch 'hello') { return 'contents did not round-trip' }
        return $null
    }

    $twoFiles = Merge-Parameter -Base $base -Override @{ Paths = @('CHANGELOG.md', 'wiki.md') }
    Assert-Json -Name 'multiple files become multiple additions' -Params $twoFiles -Check {
        param([object] $o)
        $add = @($o.variables.input.fileChanges.additions)
        if ($add.Count -ne 2) { return "expected 2 additions, got $($add.Count)" }
        if (@($add.path) -notcontains 'wiki.md') { return 'wiki.md missing' }
        return $null
    }

    $release = Merge-Parameter -Base $base -Override @{ Branch = 'release' }
    Assert-Json -Name 'a custom branch is honoured' -Params $release -Check {
        param([object] $o)
        if ($o.variables.input.branch.branchName -ne 'release') { return 'branch not applied' }
        return $null
    }

    Assert-Json -Name 'expectedHeadOid is always present' -Params $base -Check {
        param([object] $o)
        if (-not $o.variables.input.expectedHeadOid) { return 'expectedHeadOid missing' }
        return $null
    }

    try {
        $null = & $script:committer -Paths @('nope.md') -Headline 'x' -Repository 'o/r' -DryRun 2>&1
    } catch [System.Management.Automation.RuntimeException] {
        $global:LASTEXITCODE = 1
    }
    if ($LASTEXITCODE -eq 0) { Write-Host 'FAIL  a missing file is rejected'; $script:failures++ }
    else { Write-Host 'ok    a missing file is rejected' }

    try {
        $null = & $script:committer -Paths @('') -Headline 'x' -Repository 'o/r' -DryRun 2>&1
    } catch [System.Management.Automation.RuntimeException] {
        $global:LASTEXITCODE = 1
    }
    if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL  an empty path list exits cleanly'; $script:failures++ }
    else { Write-Host 'ok    an empty path list exits cleanly' }

    try {
        $null = & $script:committer -Paths @() -Headline 'x' -Repository 'o/r' -DryRun 2>&1
    } catch [System.Management.Automation.RuntimeException] {
        $global:LASTEXITCODE = 1
    }
    if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL  a genuinely empty array exits cleanly'; $script:failures++ }
    else { Write-Host 'ok    a genuinely empty array exits cleanly' }
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
