#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$files = @(git -C $root ls-files -- '*Test-*.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Could not list the PowerShell tests.' }
if ($files.Count -eq 0) { throw 'No PowerShell tests were found.' }
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $path = Join-Path $root $file
    & pwsh -NoProfile -File $path
    if ($LASTEXITCODE -ne 0) { $failures.Add($file) }
}
if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("Failed: $($failures -join ', ')")
    exit 1
}
Write-Host "All $($files.Count) PowerShell test scripts passed."
exit 0
