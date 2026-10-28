#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) { Write-Host "ok    $Name" }
    else { Write-Host "FAIL  $Name$(if ($Detail) { " -- $Detail" })"; $script:failures++ }
}

function Invoke-Hook {
    [CmdletBinding()]
    [OutputType([int])]
    param([string] $Subject, [string] $Config = '')
    $msg = Join-Path $script:sandbox 'msg.txt'
    [System.IO.File]::WriteAllText($msg, "$Subject`n", (New-Object System.Text.UTF8Encoding($false)))
    $cfg = Join-Path $script:sandbox 'hook-config'
    if ($Config) {
        [System.IO.File]::WriteAllText($cfg, "$Config`n", (New-Object System.Text.UTF8Encoding($false)))
    } elseif (Test-Path $cfg) {
        Remove-Item $cfg -Force
    }
    Copy-Item (Join-Path $script:hooksDir 'commit-msg') (Join-Path $script:sandbox 'commit-msg') -Force
    $null = & bash (Join-Path $script:sandbox 'commit-msg') $msg 2>&1
    return $LASTEXITCODE
}

$script:failures = 0
$script:hooksDir = $PSScriptRoot
$actionYml = Join-Path (Split-Path -Parent $PSScriptRoot) 'commit-subjects/action.yml'
$bash = (Get-Command bash -ErrorAction SilentlyContinue)

foreach ($file in @('commit-msg', 'prepare-commit-msg')) {
    $path = Join-Path $script:hooksDir $file
    Assert -Name "$file exists" -Condition (Test-Path -LiteralPath $path)
    $text = [System.IO.File]::ReadAllText($path)
    Assert -Name "$file has a bash shebang" -Condition ($text.StartsWith('#!/usr/bin/env bash'))
    Assert -Name "$file uses LF endings" -Condition (-not $text.Contains("`r"))
    Assert -Name "$file reads hook-config" -Condition ($text -match 'hook-config')
}

$hookText = [System.IO.File]::ReadAllText((Join-Path $script:hooksDir 'commit-msg'))
$hookPattern = if ($hookText -match "(?m)^STAMP_PATTERN='([^']+)'") { $Matches[1] } else { $null }
Assert -Name 'commit-msg declares a default stamp pattern' -Condition ($null -ne $hookPattern)

$prepText = [System.IO.File]::ReadAllText((Join-Path $script:hooksDir 'prepare-commit-msg'))
$prepPattern = if ($prepText -match "(?m)^STAMP_PATTERN='([^']+)'") { $Matches[1] } else { $null }
Assert -Name 'both hooks default to the same stamp pattern' -Condition ($hookPattern -eq $prepPattern) -Detail (
    "'$hookPattern' vs '$prepPattern'")

$actionText = [System.IO.File]::ReadAllText($actionYml)
$actionPattern = "stamp-pattern:\s*\r?\n\s*description:[^\r\n]*\r?\n\s*required: false\r?\n\s*default: '([^']+)'"
if ($actionText -match $actionPattern) {
    Assert -Name 'the hooks and the commit-subjects action share one stamp pattern' -Condition (
        $Matches[1] -eq $hookPattern) -Detail "action '$($Matches[1])' vs hook '$hookPattern'"
} else {
    Assert -Name 'the commit-subjects action declares a default stamp pattern' -Condition $false
}

if ($bash) {
    $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('hooks-' + [System.Guid]::NewGuid().ToString('N'))
    $sandbox = $script:sandbox
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    try {
        $twoStamps = 'fix: it (2026.9.8.1-A1B2) (2026.9.8.2-C3D4)'
        $conventional = 'CHECK_CONVENTIONAL=1'
        Assert -Name 'one stamp passes' -Condition ((Invoke-Hook -Subject 'feat: a thing (2026.9.8.1-A1B2)') -eq 0)
        Assert -Name 'two stamps fail' -Condition ((Invoke-Hook -Subject $twoStamps) -ne 0)
        Assert -Name 'a plain subject passes by default' -Condition ((Invoke-Hook -Subject 'made changes') -eq 0)
        Assert -Name 'CHECK_CONVENTIONAL rejects a plain subject' -Condition (
            (Invoke-Hook -Subject 'made changes' -Config $conventional) -ne 0)
        Assert -Name 'CHECK_CONVENTIONAL accepts a conventional subject' -Condition (
            (Invoke-Hook -Subject 'feat: a thing' -Config $conventional) -eq 0)
        Assert -Name 'CHECK_CONVENTIONAL accepts a revert subject' -Condition (
            (Invoke-Hook -Subject 'revert: a thing' -Config $conventional) -eq 0)
        Assert -Name 'CHECK_CONVENTIONAL skips a merge subject' -Condition (
            (Invoke-Hook -Subject 'Merge branch x' -Config $conventional) -eq 0)
        Assert -Name 'CHECK_CONVENTIONAL skips a fixup subject' -Condition (
            (Invoke-Hook -Subject 'fixup! feat: a thing' -Config $conventional) -eq 0)
        Assert -Name 'CHECK_CONVENTIONAL skips a squash subject' -Condition (
            (Invoke-Hook -Subject 'squash! feat: a thing' -Config $conventional) -eq 0)
        Assert -Name 'CHECK_STAMP=0 ignores two stamps' -Condition (
            (Invoke-Hook -Subject $twoStamps -Config 'CHECK_STAMP=0') -eq 0)
        Assert -Name 'FORBIDDEN_BODY_PATTERN rejects an issue reference' -Condition (
            (Invoke-Hook -Subject 'docs: tidy #412' -Config "FORBIDDEN_BODY_PATTERN='#[0-9]+'") -ne 0)
        $narrowed = "STAMP_PATTERN='\(2026\.[0-9]+\.[0-9]+\.[0-9]+-[A-F0-9]{4}\)'"
        Assert -Name 'a narrowed STAMP_PATTERN ignores a beta stamp' -Condition (
            (Invoke-Hook -Subject 'fix: it (2026.9.8.1-beta) (2026.9.8.2-beta)' -Config $narrowed) -eq 0)
        $repo = Join-Path $sandbox 'repo'
        $null = New-Item -ItemType Directory -Path $repo -Force
        Push-Location $repo
        try {
            $null = & git init --initial-branch=main --quiet 2>&1
            $null = & git config user.name 'Test'
            $null = & git config user.email 'test@example.com'
            $null = New-Item -ItemType Directory -Path (Join-Path $repo '.githooks') -Force
            $prepareSource = Join-Path $script:hooksDir 'prepare-commit-msg'
            Copy-Item $prepareSource (Join-Path $repo '.githooks/prepare-commit-msg') -Force

            $today = Get-Date -Format 'yyyy.M.d'
            $stamp = "$today.42-ABCD"

            $gitPath = (& git rev-parse --git-path 'app-version.txt').Trim()
            $private = if ([System.IO.Path]::IsPathRooted($gitPath)) { $gitPath } else { Join-Path $repo $gitPath }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $private) -Force
            [System.IO.File]::WriteAllText($private, $stamp)
            [System.IO.File]::WriteAllText(
                (Join-Path $repo '.githooks/hook-config'), "VERSION_FILE='app-version.txt'`nVERSION_IN_GITDIR=1`n")

            $msg = Join-Path $repo 'msg.txt'
            [System.IO.File]::WriteAllText($msg, "docs: sample`n")
            $null = & bash '.githooks/prepare-commit-msg' $msg 2>&1
            $subject = ([System.IO.File]::ReadAllText($msg) -split "`n")[0].Trim()

            Assert -Name 'the git-dir version file supplies the stamp' -Condition (
                $subject -eq "docs: sample ($stamp)") -Detail "got '$subject'"
            Assert -Name 'no root version.txt is created' -Condition (-not (Test-Path (Join-Path $repo 'version.txt')))
            Assert -Name 'the private version file survives' -Condition (Test-Path $private)

            $null = & git commit --allow-empty --quiet -m 'base' 2>&1
            $prefix = (& git rev-parse HEAD).Trim().Substring(0, 4)
            $sha1 = [System.Security.Cryptography.SHA1]::Create()
            $n = 0
            do {
                $n++
                $body = [System.Text.Encoding]::ASCII.GetBytes("$n")
                $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($body.Length)`0")
                $digest = $sha1.ComputeHash([byte[]]($header + $body))
                $hash = [System.BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
            } until ($hash.StartsWith($prefix))
            $twin = Join-Path $sandbox 'twin.txt'
            [System.IO.File]::WriteAllText($twin, "$n")
            $null = & git hash-object -w $twin
            Remove-Item -LiteralPath $private -Force
            [System.IO.File]::WriteAllText($msg, "docs: fresh day`n")
            $null = & bash '.githooks/prepare-commit-msg' $msg 2>&1
            $subject = ([System.IO.File]::ReadAllText($msg) -split "`n")[0].Trim()
            $head = (& git rev-parse HEAD).Trim().Substring(0, 4).ToUpperInvariant()
            Assert -Name 'a new day stamps exactly four hex digits of HEAD' -Condition (
                $subject -eq "docs: fresh day ($today.0-$head)") -Detail "got '$subject'"
            Assert -Name 'the new stamp matches the default pattern' -Condition (
                $subject -match $prepPattern) -Detail "got '$subject'"
        } finally { Pop-Location }
    } finally { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
} else {
    Write-Host 'skip  bash not available, hook behaviour not exercised'
}

Assert -Name 'the installer exists' -Condition (Test-Path -LiteralPath (Join-Path $script:hooksDir 'Install-Hooks.ps1'))

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
