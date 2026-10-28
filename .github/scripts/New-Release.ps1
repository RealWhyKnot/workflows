#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Remote = 'origin',
    [string] $Branch = 'main',
    [string] $Repository = 'RealWhyKnot/workflows',
    [string] $MovingTag = 'v1',
    [string] $Timezone = 'America/Chicago',
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RepoGit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $output = & { $ErrorActionPreference = 'Continue'; & git -C $Path @Arguments 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        throw "git -C $Path $($Arguments -join ' ') failed with exit code ${LASTEXITCODE}: $($output -join ' ')"
    }
    $lines = @($output)
    if ($lines.Count -eq 0) {
        return ''
    }
    "$($lines[-1])".Trim()
}

function Update-SharedReference {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Tag
    )
    $changed = 0
    $folder = Join-Path $Path '.github/workflows'
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.yml' -File)) {
        $content = [IO.File]::ReadAllText($file.FullName)
        $pinned = ConvertTo-PinnedReference -Content $content -Tag $Tag
        if ($pinned -cne $content) {
            [IO.File]::WriteAllText($file.FullName, $pinned)
            $changed++
        }
    }
    $changed
}

Import-Module (Join-Path $PSScriptRoot 'ReleasePlan.psm1') -Force

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$null = Invoke-RepoGit -Path $root -Arguments @('fetch', '--quiet', '--force', '--tags', $Remote, $Branch)
$ref = "$Remote/$Branch"
$sha = Invoke-RepoGit -Path $root -Arguments @('rev-parse', $ref)
$zone = [TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
$day = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $zone).ToString('yyyy.M.d')
$next = Get-NextRelease -Root $root -Day $day -Ref $ref
if ($null -eq $next) {
    Write-Host "Nothing to release on $ref since the last release."
    exit 0
}
Write-Host "Next release: $($next.Tag) after $($next.Previous), at $($sha.Substring(0, 7)), moving $MovingTag."
if ($PlanOnly) {
    exit 0
}

$wait = @{
    Sha        = $sha
    Repository = $Repository
    Workflow   = 'ci.yml'
    OutputPath = ''
}
& (Join-Path $root 'wait-for-ci/Wait-ForCi.ps1') @wait
if ($LASTEXITCODE -ne 0) {
    throw "CI hasn't passed on $($sha.Substring(0, 7)), so $($next.Tag) was not tagged."
}

$tree = Join-Path ([IO.Path]::GetTempPath()) ('workflows-release-' + [guid]::NewGuid().ToString('N'))
$null = Invoke-RepoGit -Path $root -Arguments @('worktree', 'add', '--quiet', '--detach', $tree, $sha)
try {
    $changed = Update-SharedReference -Path $tree -Tag $next.Tag
    if ($changed -gt 0) {
        $null = Invoke-RepoGit -Path $tree -Arguments @('add', '--', '.github/workflows')
        $subject = "chore(release): pin shared references to $($next.Tag) [skip changelog]"
        $null = Invoke-RepoGit -Path $tree -Arguments @('commit', '--quiet', '-m', $subject)
    }
    $null = Invoke-RepoGit -Path $tree -Arguments @('tag', '--annotate', $next.Tag, '--message', $next.Tag)
    $commit = Invoke-RepoGit -Path $tree -Arguments @('rev-parse', 'HEAD')
} finally {
    $null = Invoke-RepoGit -Path $root -Arguments @('worktree', 'remove', '--force', $tree)
}

$null = Invoke-RepoGit -Path $root -Arguments @('push', '--quiet', $Remote, "refs/tags/$($next.Tag)")
$null = Invoke-RepoGit -Path $root -Arguments @('tag', '--force', $MovingTag, $commit)
$null = Invoke-RepoGit -Path $root -Arguments @('push', '--quiet', '--force', $Remote, "refs/tags/$MovingTag")
Write-Host "Pushed $($next.Tag) and moved $MovingTag to $($commit.Substring(0, 7))."
exit 0
