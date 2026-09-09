#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:failures = 0
$hooksDir = $PSScriptRoot
$actionYml = Join-Path (Split-Path -Parent $PSScriptRoot) 'commit-subjects/action.yml'
$bash = (Get-Command bash -ErrorAction SilentlyContinue)

function Assert {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) { Write-Host "ok    $Name" }
    else { Write-Host "FAIL  $Name$(if ($Detail) { " -- $Detail" })"; $script:failures++ }
}

foreach ($file in @('commit-msg', 'prepare-commit-msg')) {
    $path = Join-Path $hooksDir $file
    Assert "$file exists" (Test-Path -LiteralPath $path)
    $text = [System.IO.File]::ReadAllText($path)
    Assert "$file has a bash shebang" ($text.StartsWith('#!/usr/bin/env bash'))
    Assert "$file uses LF endings" (-not $text.Contains("`r"))
    Assert "$file reads hook-config" ($text -match 'hook-config')
}

$hookText = [System.IO.File]::ReadAllText((Join-Path $hooksDir 'commit-msg'))
$hookPattern = if ($hookText -match "(?m)^STAMP_PATTERN='([^']+)'") { $Matches[1] } else { $null }
Assert 'commit-msg declares a default stamp pattern' ($null -ne $hookPattern)

$prepText = [System.IO.File]::ReadAllText((Join-Path $hooksDir 'prepare-commit-msg'))
$prepPattern = if ($prepText -match "(?m)^STAMP_PATTERN='([^']+)'") { $Matches[1] } else { $null }
Assert 'both hooks default to the same stamp pattern' ($hookPattern -eq $prepPattern) "'$hookPattern' vs '$prepPattern'"

$actionText = [System.IO.File]::ReadAllText($actionYml)
if ($actionText -match "stamp-pattern:\s*\r?\n\s*description:[^\r\n]*\r?\n\s*required: false\r?\n\s*default: '([^']+)'") {
    Assert 'the hooks and the commit-subjects action share one stamp pattern' ($Matches[1] -eq $hookPattern) "action '$($Matches[1])' vs hook '$hookPattern'"
} else {
    Assert 'the commit-subjects action declares a default stamp pattern' $false
}

if ($bash) {
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("hooks-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    try {
        function Invoke-Hook {
            param([string] $Subject, [string] $Config = '')
            $msg = Join-Path $sandbox 'msg.txt'
            [System.IO.File]::WriteAllText($msg, "$Subject`n", (New-Object System.Text.UTF8Encoding($false)))
            $cfg = Join-Path $sandbox 'hook-config'
            if ($Config) { [System.IO.File]::WriteAllText($cfg, "$Config`n", (New-Object System.Text.UTF8Encoding($false))) }
            elseif (Test-Path $cfg) { Remove-Item $cfg -Force }
            Copy-Item (Join-Path $hooksDir 'commit-msg') (Join-Path $sandbox 'commit-msg') -Force
            & bash (Join-Path $sandbox 'commit-msg') $msg 2>&1 | Out-Null
            return $LASTEXITCODE
        }

        Assert 'one stamp passes' ((Invoke-Hook 'feat: a thing (2026.9.8.1-A1B2)') -eq 0)
        Assert 'two stamps fail' ((Invoke-Hook 'fix: it (2026.9.8.1-A1B2) (2026.9.8.2-C3D4)') -ne 0)
        Assert 'a plain subject passes by default' ((Invoke-Hook 'made changes') -eq 0)
        Assert 'CHECK_CONVENTIONAL rejects a plain subject' ((Invoke-Hook 'made changes' 'CHECK_CONVENTIONAL=1') -ne 0)
        Assert 'CHECK_CONVENTIONAL accepts a conventional subject' ((Invoke-Hook 'feat: a thing' 'CHECK_CONVENTIONAL=1') -eq 0)
        Assert 'CHECK_CONVENTIONAL skips a merge subject' ((Invoke-Hook 'Merge branch x' 'CHECK_CONVENTIONAL=1') -eq 0)
        Assert 'CHECK_CONVENTIONAL skips a fixup subject' ((Invoke-Hook 'fixup! feat: a thing' 'CHECK_CONVENTIONAL=1') -eq 0)
        Assert 'CHECK_CONVENTIONAL skips a squash subject' ((Invoke-Hook 'squash! feat: a thing' 'CHECK_CONVENTIONAL=1') -eq 0)
        Assert 'CHECK_STAMP=0 ignores two stamps' ((Invoke-Hook 'fix: it (2026.9.8.1-A1B2) (2026.9.8.2-C3D4)' 'CHECK_STAMP=0') -eq 0)
        Assert 'FORBIDDEN_BODY_PATTERN rejects an issue reference' ((Invoke-Hook 'docs: tidy #412' "FORBIDDEN_BODY_PATTERN='#[0-9]+'") -ne 0)
        Assert 'a narrowed STAMP_PATTERN ignores a beta stamp' ((Invoke-Hook 'fix: it (2026.9.8.1-beta) (2026.9.8.2-beta)' "STAMP_PATTERN='\(2026\.[0-9]+\.[0-9]+\.[0-9]+-[A-F0-9]{4}\)'") -eq 0)
    }
    finally { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
} else {
    Write-Host 'skip  bash not available, hook behaviour not exercised'
}

Assert 'the installer exists' (Test-Path -LiteralPath (Join-Path $hooksDir 'Install-Hooks.ps1'))

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
