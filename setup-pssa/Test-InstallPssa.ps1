#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Install {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]] $Present = @(), [hashtable] $Params = @{}, [bool] $InstallFails = $false)
    $state = @{ Installed = [System.Collections.Generic.List[string]]::new(); Present = $Present }
    $get = { $state.Present }.GetNewClosure()
    $install = if ($InstallFails) {
        {
            param([string] $Wanted)
            $state.Installed.Add($Wanted)
            throw 'gallery broke'
        }.GetNewClosure()
    } else {
        {
            param([string] $Wanted)
            $state.Installed.Add($Wanted)
        }.GetNewClosure()
    }
    $out = Join-Path ([System.IO.Path]::GetTempPath()) ('setup-pssa-' + [System.Guid]::NewGuid().ToString('N'))
    $installArgs = @{
        Pwsh             = [version] '7.6.1'
        Image            = 'win25-20261102.1'
        ProfileDirectory = 'C:\cache\PSScriptAnalyzer'
        GetInstalled     = $get
        Install          = $install
        OutputPath       = $out
    }
    foreach ($key in $Params.Keys) { $installArgs[$key] = $Params[$key] }
    $isSuccess = $true
    $text = ''
    $global:LASTEXITCODE = 0
    try {
        $text = (& $script:installer @installArgs *>&1) -join "`n"
        $isSuccess = $LASTEXITCODE -eq 0
    } catch [System.Management.Automation.RuntimeException] {
        $isSuccess = $false
        $text = "$_"
    }
    $outputs = @{}
    if (Test-Path -LiteralPath $out) {
        foreach ($line in [System.IO.File]::ReadAllLines($out)) {
            $name, $value = $line -split '=', 2
            $outputs[$name] = $value
        }
        Remove-Item -LiteralPath $out
    }
    return @{ IsSuccess = $isSuccess; Text = $text; Installed = $state.Installed; Outputs = $outputs }
}

function Assert-Install {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $Name,
        [hashtable] $Result,
        [bool] $IsSuccess,
        [string[]] $Installed,
        [hashtable] $Outputs = @{},
        [string] $Contains = ''
    )
    $problem = $null
    if ($Result.IsSuccess -ne $IsSuccess) {
        $problem = "ok was $($Result.IsSuccess)"
    } elseif (($Result.Installed -join ',') -ne ($Installed -join ',')) {
        $problem = "installed '$($Result.Installed -join ',')'"
    } elseif ($Contains -and $Result.Text -notmatch [regex]::Escape($Contains)) {
        $problem = "missing '$Contains'"
    } else {
        foreach ($key in $Outputs.Keys) {
            $got = if ($Result.Outputs.ContainsKey($key)) { $Result.Outputs[$key] } else { '<none>' }
            if ($got -ne $Outputs[$key]) {
                $problem = "$key was '$got'"
                break
            }
        }
    }
    if ($problem) {
        Write-Host "FAIL  ${Name}: $problem"
        Write-Host "        $($Result.Text)"
        $script:failures++
        return
    }
    Write-Host "ok    $Name"
}

$script:installer = Join-Path $PSScriptRoot 'Install-Pssa.ps1'
$script:failures = 0
$full = @{ 'profile-dir' = 'C:\cache\PSScriptAnalyzer'; 'cache-key' = 'pwsh7.6-pssa1.25.0-win25-20261102.1' }

$result = Invoke-Install
Assert-Install -Name 'a missing module is installed' -Result $result -IsSuccess $true -Installed @('1.25.0') -Outputs (
    $full)
$result = Invoke-Install -Present @('1.24.0', '1.25.0')
Assert-Install -Name 'the right version skips the install' -Result $result -IsSuccess $true -Installed @() -Outputs (
    $full) -Contains 'already installed'
$result = Invoke-Install -Present @('1.24.0')
Assert-Install -Name 'another version still installs' -Result $result -IsSuccess $true -Installed @('1.25.0')
$result = Invoke-Install -Params @{ Version = '1.26.1'; Pwsh = [version] '7.5.4' }
Assert-Install -Name 'the key follows both versions' -Result $result -IsSuccess $true -Installed @('1.26.1') -Outputs @{
    'cache-key' = 'pwsh7.5-pssa1.26.1-win25-20261102.1'
}
$result = Invoke-Install -Params @{ Image = '' }
Assert-Install -Name 'no image info leaves it out of the key' -Result $result -IsSuccess $true -Installed (
    @('1.25.0')) -Outputs @{ 'cache-key' = 'pwsh7.6-pssa1.25.0' }
$result = Invoke-Install -InstallFails $true
Assert-Install -Name 'a failed install fails' -Result $result -IsSuccess $false -Installed @('1.25.0') -Outputs @{
    'cache-key' = '<none>'
} -Contains 'gallery broke'
$result = Invoke-Install -Params @{ Version = '1.25' }
Assert-Install -Name 'a malformed version is rejected' -Result $result -IsSuccess $false -Installed @() -Outputs @{
    'cache-key' = '<none>'
} -Contains 'major.minor.patch'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
