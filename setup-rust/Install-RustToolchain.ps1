#!/usr/bin/env pwsh
#Requires -Version 7.4
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

function Get-List {
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]] $Values)
    foreach ($value in $Values) {
        foreach ($part in $value -split '[,\s]+') {
            $trimmed = $part.Trim()
            if ($trimmed) { $trimmed }
        }
    }
}

function Get-TomlList {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Text, [string] $Key)
    if ($Text -notmatch "(?m)^\s*$Key\s*=\s*\[([^\]]*)\]") { return }
    foreach ($m in [regex]::Matches($Matches[1], '"([^"]+)"')) { $m.Groups[1].Value }
}

if (-not $Rustup) {
    $Rustup = {
        param([string[]] $Arguments)
        & rustup @Arguments
        if ($LASTEXITCODE -ne 0) { throw "rustup $($Arguments -join ' ') failed ($LASTEXITCODE)" }
    }
}

$dir = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$fileComponents = @()
$fileTargets = @()
$source = 'input'
if (-not $Toolchain) {
    $file = $null
    $search = $dir
    while ($search -and -not $file) {
        foreach ($name in @('rust-toolchain.toml', 'rust-toolchain')) {
            $candidate = Join-Path $search $name
            if (Test-Path -LiteralPath $candidate) { $file = $candidate; break }
        }
        if ($file -or (Test-Path -LiteralPath (Join-Path $search '.git'))) { break }
        $search = Split-Path -Parent $search
    }
    if ($file) {
        $text = [System.IO.File]::ReadAllText($file)
        if ($text -match '(?m)^\s*channel\s*=\s*"([^"]+)"') {
            $Toolchain = $Matches[1]
        } elseif ($text -notmatch '\[toolchain\]' -and $text.Trim() -match '^[A-Za-z0-9._-]+$') {
            $Toolchain = $text.Trim()
        }
        $fileComponents = Get-TomlList -Text $text -Key 'components'
        $fileTargets = Get-TomlList -Text $text -Key 'targets'
        if ($Toolchain) { $source = Split-Path -Leaf $file }
    }
}
if (-not $Toolchain) { $Toolchain = 'stable'; $source = 'default' }

$allComponents = @(@(Get-List -Values $Components) + @($fileComponents) | Select-Object -Unique)
$allTargets = @(@(Get-List -Values $Targets) + @($fileTargets) | Select-Object -Unique)

$arguments = @(
    'toolchain', 'install', $Toolchain, '--profile', 'minimal', '--no-self-update'
    if ($allComponents.Count -gt 0) { '--component'; $allComponents -join ',' }
    if ($allTargets.Count -gt 0) { '--target'; $allTargets -join ',' }
)
Write-Host "Installing Rust $Toolchain (from $source)."
& $Rustup $arguments
& $Rustup @('default', $Toolchain)

$lock = Join-Path $dir 'Cargo.lock'
$lockHash = if (Test-Path -LiteralPath $lock) {
    (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant()
} else {
    'nolock'
}
$targetDir = [System.IO.Path]::GetRelativePath((Get-Location).Path, (Join-Path $dir 'target')) -replace '\\', '/'

if ($OutputPath) {
    $outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $outputLines = @("toolchain=$Toolchain", "lock-hash=$lockHash", "target-dir=$targetDir")
    [System.IO.File]::AppendAllText($outputFile, ($outputLines -join [Environment]::NewLine) + [Environment]::NewLine)
}
exit 0
