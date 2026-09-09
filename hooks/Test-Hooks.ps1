#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:failures = 0
$hooksDir = $PSScriptRoot
$actionYml = Join-Path (Split-Path -Parent $PSScriptRoot) 'commit-subjects/action.yml'

function Assert {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) { Write-Host "ok    $Name" }
    else { Write-Host "FAIL  $Name$(if ($Detail) { " -- $Detail" })"; $script:failures++ }
}

# The local hooks and the CI check must agree on what a build stamp looks like, or a commit
# passes locally and fails in CI. This is the whole reason the hooks live beside the action.
$hookPattern = $null
foreach ($file in @('commit-msg', 'prepare-commit-msg')) {
    $path = Join-Path $hooksDir $file
    Assert "$file exists" (Test-Path -LiteralPath $path)
    $text = Get-Content -LiteralPath $path -Raw
    if ($text -match "(?m)^pattern='([^']+)'") {
        $found = $Matches[1]
        if ($null -eq $hookPattern) { $hookPattern = $found }
        else { Assert "$file uses the same stamp pattern as its sibling" ($found -eq $hookPattern) "'$found' vs '$hookPattern'" }
    } else {
        Assert "$file declares a stamp pattern" $false
    }
    Assert "$file has a bash shebang" ($text -match '^#!/usr/bin/env bash')
    Assert "$file uses LF endings" (-not $text.Contains("`r"))
}

$actionText = Get-Content -LiteralPath $actionYml -Raw
if ($actionText -match "stamp-pattern:\s*\r?\n\s*description:[^\n]*\r?\n\s*required: false\r?\n\s*default: '([^']+)'") {
    $actionPattern = $Matches[1]
    Assert 'the hooks and the commit-subjects action share one stamp pattern' ($actionPattern -eq $hookPattern) "action '$actionPattern' vs hook '$hookPattern'"
} else {
    Assert 'the commit-subjects action declares a default stamp pattern' $false
}

Assert 'the installer exists' (Test-Path -LiteralPath (Join-Path $hooksDir 'Install-Hooks.ps1'))

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
