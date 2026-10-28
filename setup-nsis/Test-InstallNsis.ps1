#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Install {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]] $Versions, [string] $Version = '3.12', [bool] $InstallFails = $false)
    $state = @{
        Seen      = [System.Collections.Generic.Queue[string]]::new([string[]] $Versions)
        Installed = [System.Collections.Generic.List[string]]::new()
    }
    $get = { $state.Seen.Dequeue() }.GetNewClosure()
    $install = if ($InstallFails) {
        {
            param([string] $Package)
            $state.Installed.Add($Package)
            throw 'choco broke'
        }.GetNewClosure()
    } else {
        {
            param([string] $Package)
            $state.Installed.Add($Package)
        }.GetNewClosure()
    }
    $pathFile = Join-Path ([System.IO.Path]::GetTempPath()) ('setup-nsis-' + [System.Guid]::NewGuid().ToString('N'))
    $installArgs = @{
        Version    = $Version
        Exe        = 'C:\NSIS\makensis.exe'
        GetVersion = $get
        Install    = $install
        PathFile   = $pathFile
    }
    $ok = $true
    $text = ''
    try { $text = (& $script:installer @installArgs *>&1) -join "`n" }
    catch [System.Management.Automation.RuntimeException] { $ok = $false; $text = "$_" }
    $path = if (Test-Path $pathFile) { [System.IO.File]::ReadAllText($pathFile).Trim() } else { '' }
    Remove-Item $pathFile -ErrorAction SilentlyContinue
    return @{ Ok = $ok; Text = $text; Installed = $state.Installed; Path = $path }
}

function Assert-Install {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Result, [bool] $Ok, [string[]] $Installed, [string] $Contains = '')
    $problem = $null
    if ($Result.Ok -ne $Ok) {
        $problem = "ok was $($Result.Ok)"
    } elseif (($Result.Installed -join ',') -ne ($Installed -join ',')) {
        $problem = "installed '$($Result.Installed -join ',')'"
    } elseif ($Contains -and $Result.Text -notmatch [regex]::Escape($Contains)) {
        $problem = "missing '$Contains'"
    } elseif ($Ok -and $Result.Path -ne 'C:\NSIS') {
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

$r = Invoke-Install -Versions @('v3.12')
Assert-Install -Name 'the right version skips the install' -Result $r -Ok $true -Installed @() -Contains (
    'already installed')
$r = Invoke-Install -Versions @('v3.10', 'v3.12')
Assert-Install -Name 'an older version is replaced' -Result $r -Ok $true -Installed @('3.12.0') -Contains 'Found v3.10'
$r = Invoke-Install -Versions @('', 'v3.12')
Assert-Install -Name 'a missing install is installed' -Result $r -Ok $true -Installed @('3.12.0') -Contains (
    'Found nothing')
$r = Invoke-Install -Versions @('', '') -InstallFails $true
Assert-Install -Name 'a failed install fails' -Result $r -Ok $false -Installed @('3.12.0') -Contains 'choco broke'
$r = Invoke-Install -Versions @('', 'v3.11')
Assert-Install -Name 'the wrong version after installing fails' -Result $r -Ok $false -Installed @('3.12.0') -Contains (
    "found 'v3.11'")
$r = Invoke-Install -Versions @() -Version '3.12.0'
Assert-Install -Name 'a malformed version is rejected' -Result $r -Ok $false -Installed @() -Contains (
    'must look like 3.12')

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
