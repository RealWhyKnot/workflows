#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Shellcheck = '0.11.0',
    [string] $Shfmt = '3.14.1',
    [string] $Actionlint = '',
    [string] $RunnerOS = $env:RUNNER_OS,
    [string] $RunnerArch = $env:RUNNER_ARCH,
    [string] $RunnerTemp = $env:RUNNER_TEMP,
    [string] $PathFile = $env:GITHUB_PATH,
    [int] $Attempts = 3,
    [int] $RetryDelaySeconds = 30,
    [scriptblock] $Download = $null,
    [scriptblock] $GetHash = $null,
    [scriptblock] $ExpandArchive = $null,
    [scriptblock] $GetVersion = $null,
    [scriptblock] $AddPath = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($RunnerOS -notin @('Linux', 'Windows') -or $RunnerArch -ne 'X64') {
    throw "setup-shell-tools supports Linux x64 and Windows x64, got '$RunnerOS $RunnerArch'."
}
if (-not $RunnerTemp) { throw 'RUNNER_TEMP must be set.' }
if (-not $PathFile) { throw 'GITHUB_PATH must be set.' }
if ($Attempts -lt 1) { throw 'Attempts must be at least 1.' }
if ($RetryDelaySeconds -lt 0) { throw 'RetryDelaySeconds must be at least 0.' }

$releases = @{
    shellcheck = @{
        '0.11.0' = @{
            Linux   = @{
                File   = 'shellcheck-v0.11.0.linux.x86_64.tar.xz'
                Hash   = '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198'
                Binary = 'shellcheck-v0.11.0/shellcheck'
            }
            Windows = @{
                File   = 'shellcheck-v0.11.0.zip'
                Hash   = '8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e'
                Binary = 'shellcheck.exe'
            }
        }
    }
    shfmt      = @{
        '3.14.1' = @{
            Linux   = @{
                File   = 'shfmt_v3.14.1_linux_amd64'
                Hash   = '76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf'
                Binary = ''
            }
            Windows = @{
                File   = 'shfmt_v3.14.1_windows_amd64.exe'
                Hash   = '13629ce28442ca80b6b5a819f7574ab39e1c28c6e26734ca816c9714e04851df'
                Binary = ''
            }
        }
    }
    actionlint = @{
        '1.7.12' = @{
            Linux   = @{
                File   = 'actionlint_1.7.12_linux_amd64.tar.gz'
                Hash   = '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8'
                Binary = 'actionlint'
            }
            Windows = @{
                File   = 'actionlint_1.7.12_windows_amd64.zip'
                Hash   = '6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9'
                Binary = 'actionlint.exe'
            }
        }
    }
}
$tools = @(
    @{ Name = 'shellcheck'; Version = $Shellcheck; Repo = 'koalaman/shellcheck'; Flag = '--version' }
    @{ Name = 'shfmt'; Version = $Shfmt; Repo = 'mvdan/sh'; Flag = '--version' }
    if ($Actionlint) {
        @{ Name = 'actionlint'; Version = $Actionlint; Repo = 'rhysd/actionlint'; Flag = '-version' }
    }
)
foreach ($tool in $tools) {
    if (-not $releases[$tool.Name].ContainsKey($tool.Version)) {
        throw "Unsupported $($tool.Name) version '$($tool.Version)'."
    }
    $tool.Asset = $releases[$tool.Name][$tool.Version][$RunnerOS]
}

if (-not $Download) {
    $Download = {
        param([string] $Uri, [string] $File)
        Invoke-WebRequest -Uri $Uri -OutFile $File -TimeoutSec 60
    }
}
if (-not $GetHash) {
    $GetHash = {
        param([string] $File)
        (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    }
}
if (-not $ExpandArchive) {
    $ExpandArchive = {
        param([string] $File, [string] $Destination)
        if ($File.EndsWith('.zip')) {
            Expand-Archive -LiteralPath $File -DestinationPath $Destination
        } else {
            & tar -xf $File -C $Destination
            if ($LASTEXITCODE -ne 0) { throw "Could not extract '$File' ($LASTEXITCODE)." }
        }
    }
}
if (-not $GetVersion) {
    $GetVersion = {
        param([string] $File, [string] $Flag)
        & $File $Flag
        if ($LASTEXITCODE -ne 0) { throw "Could not read the version of '$File' ($LASTEXITCODE)." }
    }
}
if (-not $AddPath) {
    $AddPath = {
        param([string] $Directory, [string] $File)
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($File)
        [IO.File]::AppendAllText($full, $Directory + [Environment]::NewLine)
    }
}

$root = Join-Path $RunnerTemp ('shell-tools-' + [Guid]::NewGuid().ToString('N'))
$bin = Join-Path $root 'bin'
$null = [IO.Directory]::CreateDirectory($bin)
foreach ($tool in $tools) {
    $asset = $tool.Asset
    $file = Join-Path $root $asset.File
    $uri = "https://github.com/$($tool.Repo)/releases/download/v$($tool.Version)/$($asset.File)"
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            & $Download $uri $file
            break
        } catch [System.Management.Automation.RuntimeException] {
            if ($attempt -eq $Attempts) { throw }
            Write-Host (
                "Download $($asset.File) attempt $attempt of $Attempts failed: $_. Retry in $RetryDelaySeconds s.")
            if ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
    }
    $hash = & $GetHash $file
    if ($hash -ne $asset.Hash) { throw "SHA-256 mismatch for '$($asset.File)': expected $($asset.Hash), got '$hash'." }
    $source = $file
    if ($asset.Binary) {
        $expanded = Join-Path $root $tool.Name
        $null = [IO.Directory]::CreateDirectory($expanded)
        & $ExpandArchive $file $expanded
        $source = Join-Path $expanded $asset.Binary
    }
    $name = if ($RunnerOS -eq 'Windows') { "$($tool.Name).exe" } else { $tool.Name }
    $tool.Exe = Join-Path $bin $name
    Copy-Item -LiteralPath $source -Destination $tool.Exe
    if ($RunnerOS -eq 'Linux') {
        & chmod 755 $tool.Exe
        if ($LASTEXITCODE -ne 0) { throw "Could not make '$($tool.Exe)' executable ($LASTEXITCODE)." }
    }
}
foreach ($tool in $tools) {
    Write-Host ((& $GetVersion $tool.Exe $tool.Flag) -join [Environment]::NewLine)
}
& $AddPath $bin $PathFile
exit 0
