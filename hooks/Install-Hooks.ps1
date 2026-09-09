#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $RepoRoot = (Get-Location).Path,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$target = Join-Path $root '.githooks'
New-Item -ItemType Directory -Path $target -Force | Out-Null

$installed = @()
foreach ($hook in @('commit-msg', 'prepare-commit-msg')) {
    $source = Join-Path $PSScriptRoot $hook
    $dest = Join-Path $target $hook
    if ((Test-Path -LiteralPath $dest) -and -not $Force) {
        $same = (Get-FileHash $source -Algorithm SHA256).Hash -eq (Get-FileHash $dest -Algorithm SHA256).Hash
        if (-not $same) {
            Write-Host "$hook differs from the shared copy. Re-run with -Force to overwrite it."
            continue
        }
    }
    Copy-Item -LiteralPath $source -Destination $dest -Force
    $installed += $hook
}

& git -C $root config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw "Could not set core.hooksPath in $root" }

if ($installed) { Write-Host "Installed: $($installed -join ', ')" }
Write-Host "core.hooksPath is now .githooks"
