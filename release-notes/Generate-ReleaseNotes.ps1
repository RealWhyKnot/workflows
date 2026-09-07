#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Tag,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $PreviousTag = '',
    [string] $Title = '',
    [string] $OutFile = '',
    [string[]] $Extra = @()
)

$ErrorActionPreference = 'Stop'

$Categories = @(
    @{ Prefix = 'feat';     Name = 'Features' }
    @{ Prefix = 'fix';      Name = 'Bug Fixes' }
    @{ Prefix = 'perf';     Name = 'Performance' }
    @{ Prefix = 'refactor'; Name = 'Changes' }
    @{ Prefix = 'revert';   Name = 'Changes' }
    @{ Prefix = 'docs';     Name = 'Documentation' }
    @{ Prefix = 'build';    Name = 'Build' }
    @{ Prefix = 'ci';       Name = 'CI' }
    @{ Prefix = 'test';     Name = 'Tests' }
    @{ Prefix = 'chore';    Name = 'Chores' }
)
$Order = @('Breaking Changes', 'Features', 'Bug Fixes', 'Performance', 'Changes', 'Documentation', 'Build', 'CI', 'Tests', 'Chores', 'Other')
$StampPattern = '\s*\(\d{4}\.\d+\.\d+\.\d+(-([A-Fa-f0-9]{4}|beta))?\)\s*$'

function Invoke-Git {
    param([string[]] $Arguments)
    $out = & git @Arguments 2>$null
    return @($out)
}

function Resolve-PreviousTag {
    param([string] $Tag)
    $isPre = $Tag -match '-'
    $args = @('describe', '--tags', '--abbrev=0')
    if (-not $isPre) { $args += @('--exclude', '*-*') }
    $args += "$Tag^"
    $prev = (Invoke-Git -Arguments $args | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { return '' }
    return "$prev".Trim()
}

function Get-CommitsFromApi {
    param([string] $Repository, [string] $Base, [string] $Head)
    if ($Base) {
        $json = & gh api "repos/$Repository/compare/$Base...$Head" --paginate 2>$null
    } else {
        $json = & gh api "repos/$Repository/commits?sha=$Head&per_page=100" 2>$null
    }
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    try { $data = $json | ConvertFrom-Json } catch { return $null }
    if (-not $Base) {
        $flat = @($data)
        $wrapped = [pscustomobject]@{ commits = $flat }
        [array]::Reverse($wrapped.commits)
        $data = @($wrapped)
    }
    $commits = @()
    foreach ($page in @($data)) {
        foreach ($c in @($page.commits)) {
            if (@($c.parents).Count -gt 1) { continue }
            $login = ''
            if ($c.author -and $c.author.login) { $login = $c.author.login }
            $commits += [pscustomobject]@{
                Sha     = $c.sha.Substring(0, 7)
                Subject = ($c.commit.message -split "`n")[0]
                Login   = $login
                Name    = $c.commit.author.name
            }
        }
    }
    [array]::Reverse($commits)
    return $commits
}

function Get-CommitsFromGit {
    param([string] $Base, [string] $Head)
    $range = $Head
    if ($Base) { $range = "$Base..$Head" }
    $lines = Invoke-Git -Arguments @('log', '--no-merges', "--pretty=format:%h`t%an`t%s", $range)
    $commits = @()
    foreach ($line in $lines) {
        if (-not $line) { continue }
        $parts = $line -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $commits += [pscustomobject]@{
            Sha     = $parts[0]
            Subject = $parts[2]
            Login   = ''
            Name    = $parts[1]
        }
    }
    return $commits
}

function Get-Category {
    param([string] $Subject)
    if ($Subject -match '^([a-z]+)(\([^)]+\))?!:') { return 'Breaking Changes' }
    if ($Subject -match '^([a-z]+)(\([^)]+\))?:') {
        $prefix = $Matches[1]
        foreach ($c in $Categories) {
            if ($c.Prefix -eq $prefix) { return $c.Name }
        }
    }
    return 'Other'
}

$previous = $PreviousTag
if (-not $previous) { $previous = Resolve-PreviousTag -Tag $Tag }

$commits = $null
if ($Repository) { $commits = Get-CommitsFromApi -Repository $Repository -Base $previous -Head $Tag }
if ($null -eq $commits) { $commits = Get-CommitsFromGit -Base $previous -Head $Tag }

$buckets = [ordered]@{}
foreach ($name in $Order) { $buckets[$name] = New-Object System.Collections.Generic.List[string] }

foreach ($commit in $commits) {
    $subject = $commit.Subject
    if ($subject -match '\[skip changelog\]') { continue }
    if ($subject -match '^Merge ') { continue }
    $subject = ($subject -replace $StampPattern, '').Trim()
    if (-not $subject) { continue }

    $who = $commit.Login
    if ($who) { $who = "@$who" } else { $who = $commit.Name }
    $buckets[(Get-Category -Subject $subject)].Add("- $subject by $who in $($commit.Sha)")
}

$lines = New-Object System.Collections.Generic.List[string]
if ($Title) {
    $lines.Add("# $Title")
    $lines.Add('')
}
$lines.Add('## What''s Changed')
$lines.Add('')

$any = $false
foreach ($name in $Order) {
    if ($buckets[$name].Count -eq 0) { continue }
    $any = $true
    $lines.Add("### $name")
    foreach ($entry in $buckets[$name]) { $lines.Add($entry) }
    $lines.Add('')
}
if (-not $any) {
    $lines.Add('- Maintenance release')
    $lines.Add('')
}

if ($previous -and $Repository) {
    $lines.Add("**Full Changelog**: https://github.com/$Repository/compare/$previous...$Tag")
    $lines.Add('')
}

foreach ($block in $Extra) {
    if (-not $block) { continue }
    $lines.Add($block)
    $lines.Add('')
}

$body = ($lines -join "`n").TrimEnd() + "`n"
if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [System.IO.File]::WriteAllText($OutFile, $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $OutFile"
} else {
    Write-Output $body
}
