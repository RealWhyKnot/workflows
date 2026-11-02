#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Check {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [bool] $Condition)
    if ($Condition) { Write-Host "ok $Name" } else { throw "Failed: $Name" }
}

function Invoke-Install {
    [CmdletBinding()]
    [OutputType([object])]
    param([string] $Root, [string[]] $Arguments = @())
    $installer = Join-Path $PSScriptRoot 'Install-Lint.ps1'
    $output = & pwsh -NoProfile -File $installer -RepoRoot $Root @Arguments 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $output -join "`n" }
}

Import-Module (Join-Path $PSScriptRoot 'VendoredPaths.psm1') -Force
$mixedPattern = Get-VendoredPattern -Entry @('vendor/', '/rooted/')
Assert-Check -Name 'unrooted entries in a mixed list match nested vendor paths' -Condition (
    'a/b/vendor/x' -match $mixedPattern)
Assert-Check -Name 'rooted entries in a mixed list match root paths' -Condition (
    'rooted/x' -match $mixedPattern)
Assert-Check -Name 'rooted entries in a mixed list reject nested paths' -Condition (
    'a/rooted/x' -notmatch $mixedPattern)

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('lint-install-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($sandbox)
try {
    $null = & git -C $sandbox init -q
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the test repository.' }
    [IO.File]::WriteAllText((Join-Path $sandbox 'tool.py'), "value = 1`n")
    $null = & git -C $sandbox add -- tool.py
    if ($LASTEXITCODE -ne 0) { throw 'Could not index the test source.' }
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'auto-detection installs Python' -Condition ($result.Code -eq 0)
    $ruff = Join-Path $sandbox 'ruff.toml'
    Assert-Check -Name 'Python baseline exists' -Condition (Test-Path -LiteralPath $ruff)
    Assert-Check -Name 'shared checker is installed' -Condition (
        Test-Path -LiteralPath (Join-Path $sandbox '.github/lint/style_check.py'))
    Assert-Check -Name 'selftests are not distributed' -Condition (
        -not (Test-Path -LiteralPath (Join-Path $sandbox '.github/lint/selftest')))
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'unchanged install is idempotent' -Condition (
        $result.Code -eq 0 -and $result.Text.Contains('ruff.toml is already current'))
    [IO.File]::AppendAllText($ruff, "`nline-length = 200`n")
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'drift blocks installation' -Condition ($result.Code -eq 1)
    $result = Invoke-Install -Root $sandbox -Arguments @('-Force')
    Assert-Check -Name 'force replaces drift' -Condition ($result.Code -eq 0)
    $local = Join-Path $sandbox '.github/lint/vendored-paths.local.txt'
    [IO.File]::WriteAllText($local, "upstream/`n/external/library/`n")
    $result = Invoke-Install -Root $sandbox -Arguments @('-Force')
    Assert-Check -Name 'local vendored paths install' -Condition ($result.Code -eq 0)
    $config = [IO.File]::ReadAllText((Join-Path $sandbox 'pyrightconfig.json')) | ConvertFrom-Json
    Assert-Check -Name 'named vendored paths are folded' -Condition ($config.exclude -contains '**/upstream')
    Assert-Check -Name 'rooted vendored paths are folded' -Condition ($config.exclude -contains 'external/library')
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'folded baselines remain current' -Condition ($result.Code -eq 0)
    [IO.File]::WriteAllText($local, "*.py`n")
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'invalid vendored paths fail' -Condition ($result.Code -ne 0)
    [IO.File]::WriteAllText($local, '')
    $attributes = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shell/merge/.gitattributes'))
    [IO.File]::WriteAllText((Join-Path $sandbox '.gitattributes'), $attributes)
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'csharp,shell', '-Force')
    Assert-Check -Name 'multiple languages merge successfully' -Condition ($result.Code -eq 0)
    $editor = [IO.File]::ReadAllText((Join-Path $sandbox '.editorconfig'))
    Assert-Check -Name 'shell and CSharp editor sections survive' -Condition (
        $editor.Contains('[[shell]]') -and $editor.Contains('[*.{cs,csx}]'))
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'unknown')
    Assert-Check -Name 'unknown languages fail' -Condition ($result.Code -ne 0)
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}
Write-Host 'All installer checks passed.'
exit 0
