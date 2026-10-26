#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $WorkingDirectory = '.',
    [string] $Toolchain = '',
    [string[]] $Components = @(),
    [string[]] $Targets = @(),
    [scriptblock] $Rustup = $null,
    [string] $OutputPath = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Rustup) {
    $Rustup = {
        param([string[]] $Arguments)
        & rustup @Arguments
        if ($LASTEXITCODE -ne 0) { throw "rustup $($Arguments -join ' ') failed ($LASTEXITCODE)" }
    }
}

function Get-List {
    param([string[]] $Values)
    return @($Values | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-TomlList {
    param([string] $Text, [string] $Key)
    if ($Text -notmatch "(?m)^\s*$Key\s*=\s*\[([^\]]*)\]") { return @() }
    return @([regex]::Matches($Matches[1], '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
}

$dir = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$fileComponents = @()
$fileTargets = @()
$source = 'input'
if (-not $Toolchain) {
    $file = $null
    $search = $dir
    while ($search -and -not $file) {
        $file = @('rust-toolchain.toml', 'rust-toolchain') | ForEach-Object { Join-Path $search $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($file -or (Test-Path -LiteralPath (Join-Path $search '.git'))) { break }
        $search = Split-Path -Parent $search
    }
    if ($file) {
        $text = Get-Content -LiteralPath $file -Raw
        if ($text -match '(?m)^\s*channel\s*=\s*"([^"]+)"') { $Toolchain = $Matches[1] }
        elseif ($text -notmatch '\[toolchain\]' -and $text.Trim() -match '^[A-Za-z0-9._-]+$') { $Toolchain = $text.Trim() }
        $fileComponents = Get-TomlList $text 'components'
        $fileTargets = Get-TomlList $text 'targets'
        if ($Toolchain) { $source = Split-Path -Leaf $file }
    }
}
if (-not $Toolchain) { $Toolchain = 'stable'; $source = 'default' }

$allComponents = @(@(Get-List $Components) + @($fileComponents) | Select-Object -Unique)
$allTargets = @(@(Get-List $Targets) + @($fileTargets) | Select-Object -Unique)

$arguments = @('toolchain', 'install', $Toolchain, '--profile', 'minimal', '--no-self-update')
if ($allComponents.Count -gt 0) { $arguments += @('--component', ($allComponents -join ',')) }
if ($allTargets.Count -gt 0) { $arguments += @('--target', ($allTargets -join ',')) }
Write-Host "Installing Rust $Toolchain (from $source)."
& $Rustup $arguments
& $Rustup @('default', $Toolchain)

$lock = Join-Path $dir 'Cargo.lock'
$lockHash = if (Test-Path -LiteralPath $lock) { (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant() } else { 'nolock' }
$targetDir = [System.IO.Path]::GetRelativePath((Get-Location).Path, (Join-Path $dir 'target')) -replace '\\', '/'

if ($OutputPath) {
    Add-Content -LiteralPath $OutputPath -Value "toolchain=$Toolchain"
    Add-Content -LiteralPath $OutputPath -Value "lock-hash=$lockHash"
    Add-Content -LiteralPath $OutputPath -Value "target-dir=$targetDir"
}
