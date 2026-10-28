#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Install {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable] $Params, [hashtable] $Files = @{})
    if (Test-Path $script:sandbox) { Remove-Item $script:sandbox -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $script:sandbox -Force
    foreach ($k in $Files.Keys) {
        $full = Join-Path $script:sandbox $k
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
        [System.IO.File]::WriteAllText($full, $Files[$k])
    }
    $state = @{ Calls = New-Object System.Collections.Generic.List[string] }
    $rustup = { param([string[]] $Arguments) $state.Calls.Add($Arguments -join ' ') }.GetNewClosure()
    $out = Join-Path $script:sandbox 'out.txt'
    $p = @{ Rustup = $rustup; OutputPath = $out; WorkingDirectory = $script:sandbox }
    foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] }
    if ($Params.ContainsKey('WorkingDirectory')) {
        $p.WorkingDirectory = Join-Path $script:sandbox $Params.WorkingDirectory
    }
    Push-Location $script:sandbox
    try { $null = & $script:installer @p *>&1 } finally { Pop-Location }
    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($out)) {
        if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return @{ Calls = @($state.Calls); Out = $map }
}

function Assert-Install {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Result, [string] $Install, [hashtable] $Outputs = @{})
    $problem = $null
    if ($Result.Calls[0] -ne $Install) { $problem = "ran 'rustup $($Result.Calls[0])'" }
    foreach ($k in $Outputs.Keys) {
        if (-not $problem -and $Result.Out[$k] -ne $Outputs[$k]) { $problem = "$k was '$($Result.Out[$k])'" }
    }
    if (-not $problem -and $Result.Calls[1] -notmatch '^default ') { $problem = 'never set the default toolchain' }
    if ($problem) { Write-Host "FAIL  ${Name}: $problem"; $script:failures++; return }
    Write-Host "ok    $Name"
}

$script:installer = Join-Path $PSScriptRoot 'Install-RustToolchain.ps1'
$script:failures = 0
$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('setup-rust-' + [System.Guid]::NewGuid().ToString('N'))

$base = 'toolchain install {0} --profile minimal --no-self-update'
$file = "[toolchain]`nchannel = `"1.99.1`"`ncomponents = [`"rustfmt`", `"clippy`"]`n"
$pinned = ($base -f '1.99.1') + ' --component rustfmt,clippy'

try {
    $r = Invoke-Install -Params @{}
    Assert-Install -Name 'no input and no file installs stable' -Result $r -Install ($base -f 'stable') -Outputs @{
        toolchain = 'stable'; 'lock-hash' = 'nolock'; 'target-dir' = 'target'
    }

    $r = Invoke-Install -Params @{
        Components = @('rustfmt, clippy'); Targets = @("x86_64-pc-windows-msvc`naarch64-apple-darwin")
    }
    $expected = ($base -f 'stable') + ' --component rustfmt,clippy --target x86_64-pc-windows-msvc,aarch64-apple-darwin'
    Assert-Install -Name 'components and targets are passed on' -Result $r -Install $expected

    $r = Invoke-Install -Params @{ Components = @(''); Targets = @('') }
    Assert-Install -Name 'empty inputs add nothing' -Result $r -Install ($base -f 'stable')

    $r = Invoke-Install -Params @{} -Files @{ 'rust-toolchain.toml' = $file }
    $name = 'rust-toolchain.toml decides the channel and components'
    Assert-Install -Name $name -Result $r -Install $pinned -Outputs @{ toolchain = '1.99.1' }

    $r = Invoke-Install -Params @{ Toolchain = 'nightly' } -Files @{ 'rust-toolchain.toml' = $file }
    Assert-Install -Name 'an input toolchain wins over the file' -Result $r -Install ($base -f 'nightly')

    $r = Invoke-Install -Params @{} -Files @{ 'rust-toolchain' = "1.90.0`n" }
    Assert-Install -Name 'a legacy rust-toolchain file works' -Result $r -Install ($base -f '1.90.0') -Outputs @{
        toolchain = '1.90.0'
    }

    $locked = Invoke-Install -Params @{ WorkingDirectory = 'bridge' } -Files @{
        'bridge/Cargo.lock' = 'lock'; 'bridge/rust-toolchain.toml' = $file
    }
    $name = 'a working directory finds its own file, lock and target'
    Assert-Install -Name $name -Result $locked -Install $pinned -Outputs @{ 'target-dir' = 'bridge/target' }

    $r = Invoke-Install -Params @{ WorkingDirectory = 'bridge' } -Files @{
        '.git/HEAD' = 'ref'; 'rust-toolchain.toml' = $file; 'bridge/Cargo.toml' = ''
    }
    Assert-Install -Name 'a working directory falls back to the repo root file' -Result $r -Install $pinned -Outputs @{
        toolchain = '1.99.1'; 'target-dir' = 'bridge/target'
    }

    $r = Invoke-Install -Params @{ WorkingDirectory = 'repo/bridge' } -Files @{
        'rust-toolchain.toml' = $file; 'repo/.git/HEAD' = 'ref'; 'repo/bridge/Cargo.toml' = ''
    }
    Assert-Install -Name 'the search stops at the repo root' -Result $r -Install ($base -f 'stable') -Outputs @{
        toolchain = 'stable'
    }

    if ($locked.Out['lock-hash'] -notmatch '^[0-9a-f]{16}$') {
        Write-Host "FAIL  the lock file is hashed: got '$($locked.Out['lock-hash'])'"; $script:failures++
    } else { Write-Host 'ok    the lock file is hashed' }
} finally {
    if (Test-Path $script:sandbox) { Remove-Item $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
