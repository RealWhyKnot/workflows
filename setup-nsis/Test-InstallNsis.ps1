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
        [string[]] $Versions,
        [string] $Version = '3.12',
        [bool] $InstallFails = $false,
        [int] $InstallFailures = 0,
        [int] $Attempts = 3,
        [int] $RetryDelaySeconds = 0
    )
    $state = @{
        Seen            = [System.Collections.Generic.Queue[string]]::new([string[]] $Versions)
        Installed       = [System.Collections.Generic.List[string]]::new()
        InstallFails    = $InstallFails
        InstallFailures = $InstallFailures
    }
    $get = { $state.Seen.Dequeue() }.GetNewClosure()
    $install = {
        param([string] $Package)
        $state.Installed.Add($Package)
        if ($state.InstallFails -or $state.Installed.Count -le $state.InstallFailures) { throw 'choco broke' }
    }.GetNewClosure()
    $pathFile = Join-Path ([System.IO.Path]::GetTempPath()) ('setup-nsis-' + [System.Guid]::NewGuid().ToString('N'))
    $installArgs = @{
        Version           = $Version
        Exe               = 'C:\NSIS\makensis.exe'
        GetVersion        = $get
        Install           = $install
        PathFile          = $pathFile
        Attempts          = $Attempts
        RetryDelaySeconds = $RetryDelaySeconds
    }
    $isSuccess = $true
    $text = ''
    try { $text = (& $script:installer @installArgs *>&1) -join "`n" }
    catch [System.Management.Automation.RuntimeException] { $isSuccess = $false; $text = "$_" }
    $path = if (Test-Path -LiteralPath $pathFile) { [System.IO.File]::ReadAllText($pathFile).Trim() } else { '' }
    Remove-Item -LiteralPath $pathFile -ErrorAction SilentlyContinue
    return @{ IsSuccess = $isSuccess; Text = $text; Installed = $state.Installed; Path = $path }
}

function Assert-Install {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Result, [bool] $IsSuccess, [string[]] $Installed, [string] $Contains = '')
    $problem = $null
    if ($Result.IsSuccess -ne $isSuccess) {
        $problem = "ok was $($Result.IsSuccess)"
    } elseif (($Result.Installed -join ',') -ne ($Installed -join ',')) {
        $problem = "installed '$($Result.Installed -join ',')'"
    } elseif ($Contains -and $Result.Text -notmatch [regex]::Escape($Contains)) {
        $problem = "missing '$Contains'"
    } elseif ($isSuccess -and $Result.Path -ne 'C:\NSIS') {
        $problem = "PATH got '$($Result.Path)'"
    }
    if ($problem) {
        Write-Host "FAIL  ${Name}: $problem"
        Write-Host "        $($Result.Text)"
        $script:failures++
        return
    }
    Write-Host "ok    $Name"
}

$script:installer = Join-Path $PSScriptRoot 'Install-Nsis.ps1'
$script:failures = 0

$result = Invoke-Install -Versions @('v3.12')
Assert-Install -Name 'the right version skips the install' -Result $result -IsSuccess $true -Installed @() -Contains (
    'already installed')
$result = Invoke-Install -Versions @('v3.10', 'v3.12')
Assert-Install -Name 'an older version is replaced' -Result $result -IsSuccess $true -Installed @('3.12.0') -Contains (
    'Found v3.10')
$result = Invoke-Install -Versions @('', 'v3.12')
Assert-Install -Name 'a missing install is installed' -Result $result -IsSuccess $true -Installed (
    @('3.12.0')) -Contains (
    'Found nothing')
$result = Invoke-Install -Versions @('', '') -InstallFails $true
Assert-Install -Name 'a failed install fails' -Result $result -IsSuccess $false -Installed (
    @('3.12.0', '3.12.0', '3.12.0')) -Contains (
    'choco broke')
$result = Invoke-Install -Versions @('', 'v3.12') -InstallFailures 1
Assert-Install -Name 'a failed install retries and succeeds' -Result $result -IsSuccess $true -Installed (
    @('3.12.0', '3.12.0')) -Contains (
    'Install attempt 1 of 3 failed: choco broke. Retrying in 0 seconds.')
$result = Invoke-Install -Versions @('', 'v3.12') -InstallFailures 2
Assert-Install -Name 'a failed install succeeds on the last attempt' -Result $result -IsSuccess $true -Installed (
    @('3.12.0', '3.12.0', '3.12.0')) -Contains (
    'Install attempt 2 of 3 failed: choco broke. Retrying in 0 seconds.')
$result = Invoke-Install -Versions @('') -InstallFails $true -Attempts 1
Assert-Install -Name 'one attempt fails without retrying' -Result $result -IsSuccess $false -Installed (
    @('3.12.0')) -Contains (
    'choco broke')
$result = Invoke-Install -Versions @('', 'v3.11')
Assert-Install -Name ('the wrong version after installing fails') -Result $result -IsSuccess $false -Installed (
    @('3.12.0')) -Contains (
    "found 'v3.11'")
$result = Invoke-Install -Versions @() -Version '3.12.0'
Assert-Install -Name 'a malformed version is rejected' -Result $result -IsSuccess $false -Installed @() -Contains (
    'must look like 3.12')
$result = Invoke-Install -Versions @() -Attempts 0
Assert-Install -Name 'zero attempts is rejected' -Result $result -IsSuccess $false -Installed @() -Contains (
    'Attempts must be at least 1')
$result = Invoke-Install -Versions @() -RetryDelaySeconds -1
Assert-Install -Name 'a negative retry delay is rejected' -Result $result -IsSuccess $false -Installed @() -Contains (
    'RetryDelaySeconds must be at least 0')

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
