#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Base = '',
    [string] $TagGlob = 'v*',
    [string[]] $IgnorePaths = @(),
    [string[]] $ReleaseTypes = @(),
    [string] $OutputPath = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Set-Output {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [System.Collections.Specialized.OrderedDictionary] $Values,
        [string] $OutputPath
    )
    foreach ($k in $Values.Keys) {
        Write-Host "$k=$($Values[$k])"
        if ($OutputPath) {
            $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
            [System.IO.File]::AppendAllText($path, "$k=$($Values[$k])" + [Environment]::NewLine)
        }
    }
}

function Split-List {
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]] $Items)
    foreach ($item in $Items) {
        foreach ($part in "$item" -split '[\r\n]+') {
            $trimmed = $part.Trim()
            if ($trimmed) { $trimmed }
        }
    }
}

function ConvertTo-PathRegex {
    [CmdletBinding()]
    [OutputType([regex])]
    param([string] $Glob)
    $sb = [System.Text.StringBuilder]::new('^')
    $i = 0
    while ($i -lt $Glob.Length) {
        $rest = $Glob.Substring($i)
        if ($rest.StartsWith('**/')) { $null = $sb.Append('(?:.*/)?'); $i += 3 }
        elseif ($rest.StartsWith('**')) { $null = $sb.Append('.*'); $i += 2 }
        elseif ($rest[0] -eq '*') { $null = $sb.Append('[^/]*'); $i++ }
        elseif ($rest[0] -eq '?') { $null = $sb.Append('[^/]'); $i++ }
        else { $null = $sb.Append([regex]::Escape([string] $rest[0])); $i++ }
    }
    return [regex]::new($sb.Append('$').ToString())
}

function Complete-Gate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([bool] $HasChanges, [string] $BaseRef, [string] $OutputPath)
    $values = [ordered]@{ has_changes = $HasChanges.ToString().ToLowerInvariant(); base = $BaseRef }
    Set-Output -Values $values -OutputPath $OutputPath
    [pscustomobject]@{ HasChanges = $HasChanges; Base = $BaseRef }
}

$DefaultIgnorePaths = @(
    '.github/**', '.githooks/**', 'docs/**', 'wiki/**', 'tests/**', 'test/**',
    '*.md', 'LICENSE*', 'NOTICE', '.gitignore', '.gitattributes', '.editorconfig', '.vscode/**'
)
$DefaultReleaseTypes = @('feat', 'fix', 'perf', 'refactor', 'revert')

$ignore = @(foreach ($glob in Split-List -Items ($DefaultIgnorePaths + $IgnorePaths)) {
        ConvertTo-PathRegex -Glob $glob
    })
$types = @(foreach ($entry in Split-List -Items $ReleaseTypes) {
        foreach ($type in $entry -split '[\s,]+') { if ($type) { $type } }
    })
if ($types.Count -eq 0) { $types = $DefaultReleaseTypes }

if ($Base) {
    $null = & git rev-parse --verify --quiet "$Base^{commit}"
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        Write-Host "Base $Base does not exist; treating everything as new."
        Complete-Gate -HasChanges $true -BaseRef '' -OutputPath $OutputPath
        exit 0
    }
} else {
    $Base = "$(& git describe --tags --abbrev=0 --match "$TagGlob" HEAD 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $Base) {
        $global:LASTEXITCODE = 0
        Write-Host "No tag matching $TagGlob is reachable from HEAD; shipping."
        Complete-Gate -HasChanges $true -BaseRef '' -OutputPath $OutputPath
        exit 0
    }
}

$log = @(& git log --no-merges --format=%H%x09%s "$Base..HEAD")
if ($LASTEXITCODE -ne 0) { throw "git log $Base..HEAD failed ($LASTEXITCODE)" }

$typeRegex = '^([A-Za-z]+)(\([^)]*\))?(!)?: '
$ships = $false
Write-Host "Commits since ${Base}:"
foreach ($line in $log | Where-Object { $_ }) {
    $sha, $subject = $line -split "`t", 2
    $short = $sha.Substring(0, 7)

    $files = @(& git diff-tree --root --no-commit-id --name-only -r "$sha")
    if ($LASTEXITCODE -ne 0) { throw "git diff-tree $sha failed ($LASTEXITCODE)" }
    $functional = @($files | Where-Object { $f = $_; -not ($ignore | Where-Object { $_.IsMatch($f) }) })

    $reason = $null
    if ($subject -match $typeRegex) {
        if (-not ($types -contains $Matches[1].ToLowerInvariant() -or $Matches[3])) { $reason = "type $($Matches[1])" }
    }
    if (-not $reason -and $functional.Count -eq 0) { $reason = 'only non-functional paths' }

    if ($reason) {
        Write-Host "  skip   $short $subject ($reason)"
    } else {
        Write-Host "  ships  $short $subject ($($functional.Count) functional file(s), e.g. $($functional[0]))"
        $ships = $true
    }
}

if (-not $ships) { Write-Host "No functional changes since $Base." }
Complete-Gate -HasChanges $ships -BaseRef $Base -OutputPath $OutputPath
exit 0
