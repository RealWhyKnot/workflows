#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Root = (Get-Location).Path,
    [string] $SharedRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $SharedRef = 'v1',
    [string] $Fork = '',
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [ValidateSet('warn', 'fail', 'off')]
    [string] $Pins = 'warn',
    [string[]] $IgnoreEcosystems = @(),
    [hashtable] $LatestMajor = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Text {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Path)
    return ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

$Root = (Resolve-Path -LiteralPath $Root).Path
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

$tracked = @(& git -C $Root ls-files)
if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $Root ($LASTEXITCODE)" }

$workflowDir = Join-Path (Join-Path $Root '.github') 'workflows'
$workflowFiles = @()
if (Test-Path -LiteralPath $workflowDir) {
    $workflowFiles = @(Get-ChildItem -LiteralPath $workflowDir -File |
            Where-Object { $_.Extension -in '.yml', '.yaml' })
}
$actionFiles = @(foreach ($trackedPath in $tracked) {
        if ($trackedPath -match '(^|/)action\.ya?ml$') { Get-Item -LiteralPath (Join-Path $Root $trackedPath) }
    })
$yamlFiles = @($workflowFiles) + @($actionFiles)

$usesPattern = [regex]'(?m)^\s*(?:-\s*)?uses:\s*[''"]?([^@\s''"#]+)@([^\s''"#]+)'
$sharedPattern = '^RealWhyKnot/workflows(/|$)'
$sharedCalls = New-Object System.Collections.Generic.List[object]
$thirdParty = New-Object System.Collections.Generic.List[object]

foreach ($file in $yamlFiles) {
    $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName) -replace '\\', '/'
    $text = Get-Text -Path $file.FullName
    foreach ($m in $usesPattern.Matches($text)) {
        $target = $m.Groups[1].Value
        $ref = $m.Groups[2].Value
        if ($target -match $sharedPattern) {
            $sharedCalls.Add([pscustomobject]@{ File = $relative; Target = $target; Ref = $ref; Text = $text })
            if ($ref -ne $SharedRef) {
                $errors.Add("${relative}: $target is pinned to @$ref. " +
                    "Every shared workflow and action should use @$SharedRef.")
            }
        } elseif ($target -notmatch '^(\./|docker://)') {
            $thirdParty.Add([pscustomobject]@{ File = $relative; Target = $target; Ref = $ref })
        }
    }
}

foreach ($hook in @('commit-msg', 'prepare-commit-msg')) {
    $local = Join-Path (Join-Path $Root '.githooks') $hook
    $shared = Join-Path (Join-Path $SharedRoot 'hooks') $hook
    if (-not (Test-Path -LiteralPath $local) -or -not (Test-Path -LiteralPath $shared)) { continue }
    if ((Get-Text -Path $local) -ne (Get-Text -Path $shared)) {
        $errors.Add(".githooks/${hook}: differs from the shared copy. " +
            'Run hooks/Install-Hooks.ps1 -Force from the workflows repo to refresh it.')
    }
}

$detected = [ordered]@{}
if ($workflowFiles.Count -gt 0 -or $actionFiles.Count -gt 0) { $detected['github-actions'] = '.github/workflows' }
foreach ($path in $tracked) {
    $name = ($path -split '/')[-1]
    $ecosystem = $null
    if ($name -eq 'Cargo.toml') { $ecosystem = 'cargo' }
    elseif ($name -match '\.(cs|fs|vb)proj$' -or $name -in 'Directory.Packages.props', 'packages.config') {
        $ecosystem = 'nuget'
    } elseif ($name -eq 'go.mod') { $ecosystem = 'gomod' }
    elseif ($name -match '^requirements.*\.txt$' -or $name -in 'pyproject.toml', 'Pipfile') { $ecosystem = 'pip' }
    elseif ($name -eq 'package.json') {
        $json = $null
        try {
            $json = [System.IO.File]::ReadAllText((Join-Path $Root $path)) | ConvertFrom-Json
        } catch [System.Exception] {
            $json = $null
        }
        $names = if ($json) { @($json.PSObject.Properties.Name) } else { @() }
        $isUnity = ($names -contains 'unity') -or ($names -contains 'vpmDependencies')
        if (-not $isUnity) { $ecosystem = 'npm' }
    }
    if ($ecosystem -and -not $detected.Contains($ecosystem)) { $detected[$ecosystem] = $path }
}
foreach ($skip in $IgnoreEcosystems) {
    if ($skip -and $detected.Contains($skip.Trim())) { $detected.Remove($skip.Trim()) }
}

$dependabotPath = @('.github/dependabot.yml', '.github/dependabot.yaml') |
    Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) } |
    Select-Object -First 1
if (-not $dependabotPath) {
    if ($detected.Count -gt 0) {
        $errors.Add('.github/dependabot.yml is missing. ' +
            "This repo has $($detected.Keys -join ', ') dependencies for it to watch.")
    }
} else {
    $entries = New-Object System.Collections.Generic.List[object]
    $current = $null
    $entryIndent = -1
    $inCommitMessage = $false
    foreach ($line in ((Get-Text -Path (Join-Path $Root $dependabotPath)) -split "`n")) {
        $indent = $line.Length - $line.TrimStart(' ').Length
        $trimmed = $line.Trim()
        if ($trimmed -match '^-\s*package-ecosystem:\s*[''"]?([A-Za-z0-9_-]+)') {
            $current = [pscustomobject]@{ Ecosystem = $Matches[1]; Prefix = $false }
            $entries.Add($current)
            $entryIndent = $indent
            $inCommitMessage = $false
            continue
        }
        if (-not $current -or $trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if ($indent -le $entryIndent) { $current = $null; continue }
        if ($trimmed -match '^commit-message:\s*$') { $inCommitMessage = $true; continue }
        if ($inCommitMessage -and $trimmed -match '^prefix:\s*\S') { $current.Prefix = $true; continue }
        if ($trimmed -match '^[A-Za-z0-9_-]+:' -and $trimmed -notmatch '^(prefix|prefix-development|include):') {
            $inCommitMessage = $false
        }
    }
    $covered = @(@(foreach ($entry in $entries) { $entry.Ecosystem }) | Select-Object -Unique)
    foreach ($ecosystem in $detected.Keys) {
        if ($covered -notcontains $ecosystem) {
            $errors.Add("${dependabotPath}: no $ecosystem entry, but $($detected[$ecosystem]) is tracked.")
        }
    }
    foreach ($entry in $entries) {
        if (-not $entry.Prefix) {
            $errors.Add("${dependabotPath}: the $($entry.Ecosystem) entry has no commit-message prefix, " +
                "so its pull requests won't pass the commit message check.")
        }
    }
}

if ($Fork -eq '' -and $Repository) {
    $answer = & gh api "repos/$Repository" --jq '.fork' 2>$null
    $Fork = if ($LASTEXITCODE -eq 0) { "$answer".Trim() } else { '' }
    $global:LASTEXITCODE = 0
}
$msgCalls = New-Object System.Collections.Generic.List[object]
foreach ($call in $sharedCalls) {
    if ($call.Target -match '/commit-msg-check\.yml$') { $msgCalls.Add($call) }
}
foreach ($file in $workflowFiles) {
    $text = Get-Text -Path $file.FullName
    if ($text -match '(?m)^\s*uses:\s*[''"]?\./\.github/workflows/commit-msg-check\.yml') {
        $msgCalls.Add([pscustomobject]@{
                File   = ".github/workflows/$($file.Name)"
                Target = './.github/workflows/commit-msg-check.yml'
                Ref    = ''
                Text   = $text
            })
    }
}
if ($msgCalls.Count -eq 0) {
    $errors.Add('No workflow calls commit-msg-check.yml, so pushed commit subjects go unchecked.')
} elseif ($Fork -eq 'true') {
    if (-not ($msgCalls | Where-Object { $_.Text -match '(?m)^\s*forbidden-body-pattern:\s*\S' })) {
        $errors.Add("$($msgCalls[0].File): this repo is a fork, so commit-msg-check.yml needs " +
            'forbidden-body-pattern to keep upstream issue numbers out of its history.')
    }
}

if ($Pins -ne 'off') {
    $cache = @{}
    $pinProblems = New-Object System.Collections.Generic.List[string]
    foreach ($call in $thirdParty) {
        $parts = $call.Target -split '/'
        if ($parts.Count -lt 2) { continue }
        $repoName = "$($parts[0])/$($parts[1])"
        if ($call.Ref -match '^[0-9a-f]{40}$') { continue }
        if ($call.Ref -notmatch '^v(\d+)(\.\d+)*$') {
            $pinProblems.Add("$($call.File): $($call.Target)@$($call.Ref) follows a branch. " +
                'Pin a release major instead.')
            continue
        }
        $have = [int] $Matches[1]
        if (-not $cache.ContainsKey($repoName)) {
            $latest = $null
            if ($null -ne $LatestMajor) {
                if ($LatestMajor.ContainsKey($repoName)) { $latest = [int] $LatestMajor[$repoName] }
            } else {
                $tag = & gh api "repos/$repoName/releases/latest" --jq '.tag_name' 2>$null
                if ($LASTEXITCODE -eq 0 -and "$tag" -match '^v?(\d+)') { $latest = [int] $Matches[1] }
                $global:LASTEXITCODE = 0
            }
            $cache[$repoName] = $latest
        }
        $latest = $cache[$repoName]
        if ($null -ne $latest -and $have -lt $latest) {
            $pinProblems.Add("$($call.File): $($call.Target)@$($call.Ref) is behind v$latest.")
        }
    }
    foreach ($problem in ($pinProblems | Select-Object -Unique)) {
        if ($Pins -eq 'fail') { $errors.Add($problem) } else { $warnings.Add($problem) }
    }
}

foreach ($w in $warnings) { Write-Host "::warning::$w" }
if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Host "::error::$e" }
    Write-Host "Found $($errors.Count) problem(s) that make this repo drift from the shared setup."
    exit 1
}
Write-Host "Shared refs, hooks and Dependabot all match the shared setup. $($warnings.Count) warning(s)."
exit 0
