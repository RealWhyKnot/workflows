#!/usr/bin/env pwsh
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

$DefaultIgnorePaths = @(
    '.github/**', '.githooks/**', 'docs/**', 'wiki/**', 'tests/**', 'test/**',
    '*.md', 'LICENSE*', 'NOTICE', '.gitignore', '.gitattributes', '.editorconfig', '.vscode/**'
)
$DefaultReleaseTypes = @('feat', 'fix', 'perf', 'refactor', 'revert')

function Set-Output {
    param([System.Collections.Specialized.OrderedDictionary] $Values)
    foreach ($k in $Values.Keys) {
        Write-Host "$k=$($Values[$k])"
        if ($OutputPath) { Add-Content -LiteralPath $OutputPath -Value "$k=$($Values[$k])" }
    }
}

function Split-List {
    param([string[]] $Items)
    return @($Items | ForEach-Object { "$_" -split '[\r\n]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function ConvertTo-PathRegex {
    param([string] $Glob)
    $sb = [System.Text.StringBuilder]::new('^')
    $i = 0
    while ($i -lt $Glob.Length) {
        $rest = $Glob.Substring($i)
        if ($rest.StartsWith('**/')) { [void] $sb.Append('(?:.*/)?'); $i += 3 }
        elseif ($rest.StartsWith('**')) { [void] $sb.Append('.*'); $i += 2 }
        elseif ($rest[0] -eq '*') { [void] $sb.Append('[^/]*'); $i++ }
        elseif ($rest[0] -eq '?') { [void] $sb.Append('[^/]'); $i++ }
        else { [void] $sb.Append([regex]::Escape([string] $rest[0])); $i++ }
    }
    return [regex]::new($sb.Append('$').ToString())
}

function Complete {
    param([bool] $HasChanges, [string] $BaseRef)
    Set-Output ([ordered]@{ has_changes = $HasChanges.ToString().ToLowerInvariant(); base = $BaseRef })
    [pscustomobject]@{ HasChanges = $HasChanges; Base = $BaseRef }
    exit 0
}

$ignore = @(Split-List ($DefaultIgnorePaths + $IgnorePaths) | ForEach-Object { ConvertTo-PathRegex $_ })
$types = @(Split-List $ReleaseTypes | ForEach-Object { $_ -split '[\s,]+' } | Where-Object { $_ })
if ($types.Count -eq 0) { $types = $DefaultReleaseTypes }

if ($Base) {
    $null = & git rev-parse --verify --quiet "$Base^{commit}"
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        Write-Host "Base $Base does not exist; treating everything as new."
        Complete $true ''
    }
} else {
    $Base = "$(& git describe --tags --abbrev=0 --match "$TagGlob" HEAD 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $Base) {
        $global:LASTEXITCODE = 0
        Write-Host "No tag matching $TagGlob is reachable from HEAD; shipping."
        Complete $true ''
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
Complete $ships $Base
