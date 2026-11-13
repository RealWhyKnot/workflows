#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Install {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Shellcheck = '0.11.0',
        [string] $Shfmt = '3.14.1',
        [string] $Actionlint = '1.7.12',
        [string] $RunnerOS = $script:runnerOS,
        [string] $RunnerArch = 'X64',
        [int] $DownloadFailures = 0,
        [bool] $WrongHash = $false,
        [int] $Attempts = 3,
        [int] $RetryDelaySeconds = 0
    )
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('test-shell-tools-' + [Guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($temp)
    $pathFile = Join-Path $temp 'path'
    $state = @{
        Downloads        = [Collections.Generic.List[string]]::new()
        Hashes           = [Collections.Generic.List[string]]::new()
        Extracted        = [Collections.Generic.List[string]]::new()
        Versions         = [Collections.Generic.List[string]]::new()
        Paths            = [Collections.Generic.List[string]]::new()
        Files            = @()
        RunnerOS         = $RunnerOS
        DownloadFailures = $DownloadFailures
        WrongHash        = $WrongHash
        PathFile         = $pathFile
        HashTable        = $script:hashes
    }
    $download = {
        param([string] $Uri, [string] $File)
        $name = [IO.Path]::GetFileName($File)
        $state.Downloads.Add($name)
        if ($state.Downloads.Count -le $state.DownloadFailures) {
            throw "download failed $($state.Downloads.Count)"
        }
        $repo = if ($name.StartsWith('shellcheck')) { 'koalaman/shellcheck' }
        elseif ($name.StartsWith('shfmt')) { 'mvdan/sh' } else { 'rhysd/actionlint' }
        $version = if ($name.StartsWith('shellcheck')) { '0.11.0' }
        elseif ($name.StartsWith('shfmt')) { '3.14.1' } else { '1.7.12' }
        if ($Uri -ne "https://github.com/$repo/releases/download/v$version/$name") { throw "Wrong URL: $Uri" }
        [IO.File]::WriteAllText($File, $name)
    }.GetNewClosure()
    $getHash = {
        param([string] $File)
        $name = [IO.Path]::GetFileName($File)
        $state.Hashes.Add($name)
        if ([IO.File]::ReadAllText($File) -ne $name) { throw 'Download content is missing.' }
        if ($state.WrongHash) { return 'wrong hash' }
        return $state.HashTable[$name]
    }.GetNewClosure()
    $expand = {
        param([string] $File, [string] $Destination)
        $name = [IO.Path]::GetFileName($File)
        $state.Extracted.Add($name)
        $binary = if ($name -eq 'shellcheck-v0.11.0.zip') { 'shellcheck.exe' }
        elseif ($name.StartsWith('shellcheck')) { 'shellcheck-v0.11.0/shellcheck' }
        elseif ($name.EndsWith('.zip')) { 'actionlint.exe' } else { 'actionlint' }
        $target = Join-Path $Destination $binary
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllText($target, $name)
    }.GetNewClosure()
    $getVersion = {
        param([string] $File, [string] $Flag)
        $name = [IO.Path]::GetFileNameWithoutExtension($File)
        if (-not [IO.File]::ReadAllText($File).StartsWith($name)) { throw "Wrong binary: $File" }
        $wantFlag = if ($name -eq 'actionlint') { '-version' } else { '--version' }
        if ($Flag -ne $wantFlag) { throw "Wrong version flag: $Flag" }
        $state.Versions.Add($name)
        return "$name version"
    }.GetNewClosure()
    $addPath = {
        param([string] $Directory, [string] $File)
        if ($File -ne $state.PathFile) { throw "Wrong PATH file: $File" }
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw 'Missing tool directory.' }
        $state.Files = @(Get-ChildItem -LiteralPath $Directory -File | Select-Object -ExpandProperty Name | Sort-Object)
        $state.Paths.Add($Directory)
        [IO.File]::AppendAllText($File, $Directory + [Environment]::NewLine)
    }.GetNewClosure()
    $installArgs = @{
        Shellcheck        = $Shellcheck
        Shfmt             = $Shfmt
        Actionlint        = $Actionlint
        RunnerOS          = $RunnerOS
        RunnerArch        = $RunnerArch
        RunnerTemp        = $temp
        PathFile          = $pathFile
        Attempts          = $Attempts
        RetryDelaySeconds = $RetryDelaySeconds
        Download          = $download
        GetHash           = $getHash
        ExpandArchive     = $expand
        GetVersion        = $getVersion
        AddPath           = $addPath
    }
    $isSuccess = $true
    $text = ''
    try {
        try { $text = (& $script:installer @installArgs *>&1) -join "`n" }
        catch [System.Management.Automation.RuntimeException] { $isSuccess = $false; $text = "$_" }
        $path = if (Test-Path -LiteralPath $pathFile) { [IO.File]::ReadAllText($pathFile).Trim() } else { '' }
        return @{ IsSuccess = $isSuccess; Text = $text; State = $state; Path = $path; Temp = $temp }
    } finally {
        $full = [IO.Path]::GetFullPath($temp)
        if (-not $full.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove '$full' outside the temp directory."
        }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

function Assert-Install {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $Name,
        [hashtable] $Result,
        [bool] $IsSuccess,
        [int] $Downloads,
        [int] $Hashes = 0,
        [int] $Extracted = 0,
        [string[]] $Installed = @(),
        [string] $Contains = ''
    )
    $state = $Result.State
    $expectedFiles = @(foreach ($tool in $Installed) {
            if ($state.RunnerOS -eq 'Windows') { "$tool.exe" } else { $tool }
        })
    $problem = $null
    if ($Result.IsSuccess -ne $IsSuccess) { $problem = "ok was $($Result.IsSuccess)" }
    elseif ($state.Downloads.Count -ne $Downloads) { $problem = "downloads: $($state.Downloads.Count)" }
    elseif ($state.Hashes.Count -ne $Hashes) { $problem = "hash checks: $($state.Hashes.Count)" }
    elseif ($state.Extracted.Count -ne $Extracted) { $problem = "extractions: $($state.Extracted.Count)" }
    elseif (($state.Versions -join ',') -ne ($Installed -join ',')) { $problem = 'installed tools differ' }
    elseif ($IsSuccess -and ($state.Files -join ',') -cne (($expectedFiles | Sort-Object) -join ',')) {
        $problem = "bin files: $($state.Files -join ',')"
    } elseif ($Contains -and -not $Result.Text.Contains($Contains)) { $problem = "missing '$Contains'" }
    elseif ($IsSuccess -and ($state.Paths.Count -ne 1 -or $Result.Path -ne $state.Paths[0])) {
        $problem = 'tool directory was not added to PATH once'
    } elseif ($IsSuccess -and -not $Result.Path.StartsWith($Result.Temp + [IO.Path]::DirectorySeparatorChar)) {
        $problem = 'tool directory is outside RUNNER_TEMP'
    } elseif (-not $IsSuccess -and ($state.Paths.Count -ne 0 -or $Result.Path)) {
        $problem = 'a failed install changed PATH'
    }
    foreach ($tool in $Installed) {
        if (-not $Result.Text.Contains("$tool version")) { $problem = "missing $tool version output" }
    }
    if ($problem) {
        Write-Host "FAIL  ${Name}: $problem"
        Write-Host "        $($Result.Text)"
        $script:failures++
        return
    }
    Write-Host "ok    $Name"
}

$script:installer = Join-Path $PSScriptRoot 'Install-ShellTools.ps1'
$script:failures = 0
$script:runnerOS = if ($env:OS -eq 'Windows_NT') { 'Windows' } else { 'Linux' }
$script:hashes = @{
    'shellcheck-v0.11.0.linux.x86_64.tar.xz' = '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198'
    'shellcheck-v0.11.0.zip'                 = '8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e'
    'shfmt_v3.14.1_linux_amd64'              = '76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf'
    'shfmt_v3.14.1_windows_amd64.exe'        = '13629ce28442ca80b6b5a819f7574ab39e1c28c6e26734ca816c9714e04851df'
    'actionlint_1.7.12_linux_amd64.tar.gz'   = '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8'
    'actionlint_1.7.12_windows_amd64.zip'    = '6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9'
}
$allTools = @('shellcheck', 'shfmt', 'actionlint')
$success = @{ IsSuccess = $true; Downloads = 3; Hashes = 3; Extracted = 2; Installed = $allTools }

$result = Invoke-Install
Assert-Install -Name 'verified tools install and add PATH' -Result $result @success
$result = Invoke-Install -WrongHash $true
$archive = if ($script:runnerOS -eq 'Windows') { 'shellcheck-v0.11.0.zip' }
else { 'shellcheck-v0.11.0.linux.x86_64.tar.xz' }
Assert-Install -Name ('a wrong hash fails before extraction and names the file') -Result $result -IsSuccess (
    $false) -Downloads 1 -Hashes 1 -Contains "SHA-256 mismatch for '$archive'"
foreach ($tool in $allTools) {
    $versions = @{ $tool = '9.9.9' }
    $result = Invoke-Install @versions
    Assert-Install -Name "an unknown $tool version fails before downloading" -Result $result -IsSuccess (
        $false) -Downloads 0 -Contains "Unsupported $tool version '9.9.9'"
}
$result = Invoke-Install -DownloadFailures 1
$success.Downloads = 4
Assert-Install -Name 'a failed download retries and succeeds' -Result $result @success -Contains (
    'attempt 1 of 3 failed: download failed 1. Retry in 0 s.')
$result = Invoke-Install -DownloadFailures 2
$success.Downloads = 5
Assert-Install -Name 'a failed download succeeds on the last attempt' -Result $result @success -Contains (
    'attempt 2 of 3 failed: download failed 2. Retry in 0 s.')
$result = Invoke-Install -DownloadFailures 3
Assert-Install -Name ('a failed download stops after three attempts with the last error') -Result $result -IsSuccess (
    $false) -Downloads 3 -Contains 'download failed 3'
$result = Invoke-Install -DownloadFailures 3 -Attempts 1
Assert-Install -Name 'one attempt fails without retrying' -Result $result -IsSuccess $false -Downloads 1 -Contains (
    'download failed 1')
$result = Invoke-Install -Actionlint ''
$skipped = @{ IsSuccess = $true; Downloads = 2; Hashes = 2; Extracted = 1; Installed = @('shellcheck', 'shfmt') }
Assert-Install -Name 'empty actionlint skips its download and install' -Result $result @skipped
$result = Invoke-Install -RunnerOS 'macOS'
Assert-Install -Name 'an unsupported OS fails' -Result $result -IsSuccess $false -Downloads 0 -Contains 'macOS X64'
$result = Invoke-Install -RunnerArch 'ARM64'
Assert-Install -Name 'an unsupported architecture fails' -Result $result -IsSuccess $false -Downloads 0 -Contains (
    'ARM64')
$result = Invoke-Install -Attempts 0
Assert-Install -Name 'zero attempts is rejected' -Result $result -IsSuccess $false -Downloads 0 -Contains (
    'Attempts must be at least 1')
$result = Invoke-Install -RetryDelaySeconds -1
Assert-Install -Name 'a negative retry delay is rejected' -Result $result -IsSuccess $false -Downloads 0 -Contains (
    'RetryDelaySeconds must be at least 0')

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
