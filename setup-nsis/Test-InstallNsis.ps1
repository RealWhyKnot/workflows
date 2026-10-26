#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installer = Join-Path $PSScriptRoot 'Install-Nsis.ps1'
$script:failures = 0

function Invoke-Install {
    param([string[]] $Versions, [string] $Version = '3.12', [bool] $InstallFails = $false)
    $state = @{ Seen = [System.Collections.Generic.Queue[string]]::new([string[]] $Versions); Installed = @() }
    $get = { param([string] $Path) return $state.Seen.Dequeue() }.GetNewClosure()
    $install = {
        param([string] $Package)
        $state.Installed += $Package
        if ($InstallFails) { throw 'choco broke' }
    }.GetNewClosure()
    $pathFile = Join-Path ([System.IO.Path]::GetTempPath()) ("setup-nsis-" + [System.Guid]::NewGuid().ToString('N'))
    $ok = $true
    $text = ''
    try { $text = (& $installer -Version $Version -Exe 'C:\NSIS\makensis.exe' -GetVersion $get -Install $install -PathFile $pathFile *>&1) -join "`n" }
    catch { $ok = $false; $text = "$_" }
    $path = if (Test-Path $pathFile) { (Get-Content $pathFile -Raw).Trim() } else { '' }
    Remove-Item $pathFile -ErrorAction SilentlyContinue
    return @{ Ok = $ok; Text = $text; Installed = $state.Installed; Path = $path }
}

function Assert-Install {
    param([string] $Name, [hashtable] $Result, [bool] $Ok, [string[]] $Installed, [string] $Contains = '')
    $problem = $null
    if ($Result.Ok -ne $Ok) { $problem = "ok was $($Result.Ok)" }
    elseif (($Result.Installed -join ',') -ne ($Installed -join ',')) { $problem = "installed '$($Result.Installed -join ',')'" }
    elseif ($Contains -and $Result.Text -notmatch [regex]::Escape($Contains)) { $problem = "missing '$Contains'" }
    elseif ($Ok -and $Result.Path -ne 'C:\NSIS') { $problem = "PATH got '$($Result.Path)'" }
    if ($problem) { Write-Host "FAIL  ${Name}: $problem"; Write-Host "        $($Result.Text)"; $script:failures++; return }
    Write-Host "ok    $Name"
}

Assert-Install 'the right version skips the install' (Invoke-Install @('v3.12')) $true @() 'already installed'
Assert-Install 'an older version is replaced' (Invoke-Install @('v3.10', 'v3.12')) $true @('3.12.0') 'Found v3.10'
Assert-Install 'a missing install is installed' (Invoke-Install @('', 'v3.12')) $true @('3.12.0') 'Found nothing'
Assert-Install 'a failed install fails' (Invoke-Install @('', '') -InstallFails $true) $false @('3.12.0') 'choco broke'
Assert-Install 'the wrong version after installing fails' (Invoke-Install @('', 'v3.11')) $false @('3.12.0') "found 'v3.11'"
Assert-Install 'a malformed version is rejected' (Invoke-Install @() -Version '3.12.0') $false @() 'must look like 3.12'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
