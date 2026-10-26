#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installer = Join-Path $PSScriptRoot 'Install-RustToolchain.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("setup-rust-" + [System.Guid]::NewGuid().ToString('N'))

function Invoke-Install {
    param([hashtable] $Params, [hashtable] $Files = @{})
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    foreach ($k in $Files.Keys) {
        $full = Join-Path $sandbox $k
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $Files[$k] -NoNewline
    }
    $state = @{ Calls = New-Object System.Collections.Generic.List[string] }
    $rustup = { param([string[]] $Arguments) $state.Calls.Add($Arguments -join ' ') }.GetNewClosure()
    $out = Join-Path $sandbox 'out.txt'
    $p = @{ Rustup = $rustup; OutputPath = $out; WorkingDirectory = $sandbox }
    foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] }
    if ($Params.ContainsKey('WorkingDirectory')) { $p.WorkingDirectory = Join-Path $sandbox $Params.WorkingDirectory }
    Push-Location $sandbox
    try { $null = & $installer @p *>&1 } finally { Pop-Location }
    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $out)) { if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] } }
    return @{ Calls = @($state.Calls); Out = $map }
}

function Assert-Install {
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

$base = 'toolchain install {0} --profile minimal --no-self-update'
$file = "[toolchain]`nchannel = `"1.99.1`"`ncomponents = [`"rustfmt`", `"clippy`"]`n"

try {
    Assert-Install 'no input and no file installs stable' (Invoke-Install @{}) ($base -f 'stable') @{ toolchain = 'stable'; 'lock-hash' = 'nolock'; 'target-dir' = 'target' }
    Assert-Install 'components and targets are passed on' (Invoke-Install @{ Components = @('rustfmt, clippy'); Targets = @("x86_64-pc-windows-msvc`naarch64-apple-darwin") }) (($base -f 'stable') + ' --component rustfmt,clippy --target x86_64-pc-windows-msvc,aarch64-apple-darwin')
    Assert-Install 'empty inputs add nothing' (Invoke-Install @{ Components = @(''); Targets = @('') }) ($base -f 'stable')
    Assert-Install 'rust-toolchain.toml decides the channel and components' (Invoke-Install @{} @{ 'rust-toolchain.toml' = $file }) (($base -f '1.99.1') + ' --component rustfmt,clippy') @{ toolchain = '1.99.1' }
    Assert-Install 'an input toolchain wins over the file' (Invoke-Install @{ Toolchain = 'nightly' } @{ 'rust-toolchain.toml' = $file }) ($base -f 'nightly')
    Assert-Install 'a legacy rust-toolchain file works' (Invoke-Install @{} @{ 'rust-toolchain' = "1.90.0`n" }) ($base -f '1.90.0') @{ toolchain = '1.90.0' }
    $locked = Invoke-Install @{ WorkingDirectory = 'bridge' } @{ 'bridge/Cargo.lock' = 'lock'; 'bridge/rust-toolchain.toml' = $file }
    Assert-Install 'a working directory finds its own file, lock and target' $locked (($base -f '1.99.1') + ' --component rustfmt,clippy') @{ 'target-dir' = 'bridge/target' }
    Assert-Install 'a working directory falls back to the repo root file' (Invoke-Install @{ WorkingDirectory = 'bridge' } @{ '.git/HEAD' = 'ref'; 'rust-toolchain.toml' = $file; 'bridge/Cargo.toml' = '' }) (($base -f '1.99.1') + ' --component rustfmt,clippy') @{ toolchain = '1.99.1'; 'target-dir' = 'bridge/target' }
    Assert-Install 'the search stops at the repo root' (Invoke-Install @{ WorkingDirectory = 'repo/bridge' } @{ 'rust-toolchain.toml' = $file; 'repo/.git/HEAD' = 'ref'; 'repo/bridge/Cargo.toml' = '' }) ($base -f 'stable') @{ toolchain = 'stable' }
    if ($locked.Out['lock-hash'] -notmatch '^[0-9a-f]{16}$') {
        Write-Host "FAIL  the lock file is hashed: got '$($locked.Out['lock-hash'])'"; $script:failures++
    }
    else { Write-Host 'ok    the lock file is hashed' }
}
finally {
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
