#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $RepoRoot = (Get-Location).Path,
    [string] $StampPattern = '',
    [switch] $NoStamp,
    [switch] $CheckConventional,
    [string] $ConventionalPattern = '',
    [string] $ForbiddenBodyPattern = '',
    [string] $VersionFile = '',
    [switch] $VersionInGitDir,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$target = Join-Path $root '.githooks'
$null = New-Item -ItemType Directory -Path $target -Force

$hooks = @(
    'commit-msg'
    if (-not $NoStamp) { 'prepare-commit-msg' }
)

foreach ($hook in $hooks) {
    $source = Join-Path $PSScriptRoot $hook
    $dest = Join-Path $target $hook
    if ((Test-Path -LiteralPath $dest) -and -not $Force) {
        $same = (Get-FileHash $source -Algorithm SHA256).Hash -eq (Get-FileHash $dest -Algorithm SHA256).Hash
        if (-not $same) {
            Write-Host "$hook already exists and differs. Re-run with -Force to replace it."
            continue
        }
    }
    $text = [System.IO.File]::ReadAllText($source) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Installed $hook"
}

$lines = @(
    if ($NoStamp) { 'CHECK_STAMP=0' }
    if ($StampPattern) { "STAMP_PATTERN='$StampPattern'" }
    if ($CheckConventional) { 'CHECK_CONVENTIONAL=1' }
    if ($ConventionalPattern) { "CONVENTIONAL_PATTERN='$ConventionalPattern'" }
    if ($ForbiddenBodyPattern) { "FORBIDDEN_BODY_PATTERN='$ForbiddenBodyPattern'" }
    if ($VersionFile) { "VERSION_FILE='$VersionFile'" }
    if ($VersionInGitDir) { 'VERSION_IN_GITDIR=1' }
)

$configPath = Join-Path $target 'hook-config'
if ($lines) {
    $body = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($configPath, $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote hook-config with $($lines.Count) setting(s)"
} elseif (Test-Path -LiteralPath $configPath) {
    Remove-Item -LiteralPath $configPath -Force
    Write-Host 'Removed hook-config; the defaults apply'
}

& git -C $root config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw "Could not set core.hooksPath in $root" }
Write-Host 'core.hooksPath is now .githooks'
exit 0
