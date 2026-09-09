#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:committer = Join-Path $PSScriptRoot 'Invoke-CommitOnBranch.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("commit-on-branch-" + [System.Guid]::NewGuid().ToString('N'))

function Merge-Params {
    param([hashtable] $Base, [hashtable] $Override)
    $m = @{}
    foreach ($k in $Base.Keys) { $m[$k] = $Base[$k] }
    foreach ($k in $Override.Keys) { $m[$k] = $Override[$k] }
    return $m
}

function Get-Payload {
    param([hashtable] $Params)
    $p = @{} + $Params
    $p['DryRun'] = $true
    $p['SkipIfUnchanged'] = $false
    $raw = (& $script:committer @p 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return $raw
}

function Assert-Json {
    param([string] $Name, [hashtable] $Params, [scriptblock] $Check)
    $raw = Get-Payload -Params $Params
    try { $obj = $raw | ConvertFrom-Json } catch {
        Write-Host "FAIL  $Name -- payload is not valid JSON"; Write-Host "        $raw"; $script:failures++; return
    }
    $problem = & $Check $obj
    if ($problem) { Write-Host "FAIL  $Name -- $problem"; $script:failures++; return }
    Write-Host "ok    $Name"
}

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Push-Location $sandbox
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'CHANGELOG.md'), "# Changelog`nhello`n")
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'wiki.md'), "wiki body`n")

    $base = @{ Paths = @('CHANGELOG.md'); Headline = 'docs(changelog): promote [skip changelog]'; Repository = 'o/r' }

    Assert-Json 'the mutation and branch are set' $base {
        param($o)
        if ($o.query -notmatch 'createCommitOnBranch') { return 'query does not call the mutation' }
        if ($o.variables.input.branch.repositoryNameWithOwner -ne 'o/r') { return 'wrong repository' }
        if ($o.variables.input.branch.branchName -ne 'main') { return 'branch should default to main' }
        return $null
    }

    Assert-Json 'the headline is carried and no body is sent when empty' $base {
        param($o)
        if ($o.variables.input.message.headline -ne 'docs(changelog): promote [skip changelog]') { return 'headline missing' }
        if ($o.variables.input.message.PSObject.Properties.Name -contains 'body') { return 'body should be absent' }
        return $null
    }

    Assert-Json 'a body is included when given' (Merge-Params $base @{ Body = 'Maintained by CI.' }) {
        param($o)
        if ($o.variables.input.message.body -ne 'Maintained by CI.') { return 'body missing' }
        return $null
    }

    Assert-Json 'the file is base64 encoded under its path' $base {
        param($o)
        $add = @($o.variables.input.fileChanges.additions)
        if ($add.Count -ne 1) { return "expected 1 addition, got $($add.Count)" }
        if ($add[0].path -ne 'CHANGELOG.md') { return "wrong path $($add[0].path)" }
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($add[0].contents))
        if ($decoded -notmatch 'hello') { return 'contents did not round-trip' }
        return $null
    }

    Assert-Json 'multiple files become multiple additions' (Merge-Params $base @{ Paths = @('CHANGELOG.md', 'wiki.md') }) {
        param($o)
        $add = @($o.variables.input.fileChanges.additions)
        if ($add.Count -ne 2) { return "expected 2 additions, got $($add.Count)" }
        if (@($add.path) -notcontains 'wiki.md') { return 'wiki.md missing' }
        return $null
    }

    Assert-Json 'a custom branch is honoured' (Merge-Params $base @{ Branch = 'release' }) {
        param($o)
        if ($o.variables.input.branch.branchName -ne 'release') { return 'branch not applied' }
        return $null
    }

    Assert-Json 'expectedHeadOid is always present' $base {
        param($o)
        if (-not $o.variables.input.expectedHeadOid) { return 'expectedHeadOid missing' }
        return $null
    }

    $missing = $null
    try { $missing = & $script:committer -Paths @('nope.md') -Headline 'x' -Repository 'o/r' -DryRun 2>&1 } catch { $global:LASTEXITCODE = 1 }
    if ($LASTEXITCODE -eq 0) { Write-Host 'FAIL  a missing file is rejected'; $script:failures++ }
    else { Write-Host 'ok    a missing file is rejected' }

    $none = $null
    try { $none = & $script:committer -Paths @('') -Headline 'x' -Repository 'o/r' -DryRun 2>&1 } catch { $global:LASTEXITCODE = 1 }
    if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL  an empty path list exits cleanly'; $script:failures++ }
    else { Write-Host 'ok    an empty path list exits cleanly' }

    $empty = $null
    try { $empty = & $script:committer -Paths @() -Headline 'x' -Repository 'o/r' -DryRun 2>&1 } catch { $global:LASTEXITCODE = 1 }
    if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL  a genuinely empty array exits cleanly'; $script:failures++ }
    else { Write-Host 'ok    a genuinely empty array exits cleanly' }
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
