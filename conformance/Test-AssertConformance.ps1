#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Git {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function Set-File {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Root, [string] $RelativePath, [string] $Content)
    $full = Join-Path $Root $RelativePath
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-File {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $RelativePath)
    Remove-Item -LiteralPath (Join-Path $script:sandbox $RelativePath) -Force
}

function Assert-Result {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [bool] $ShouldPass, [string] $ExpectedText = '', [hashtable] $Extra = @{})
    Invoke-Git @('-C', $script:sandbox, 'add', '-A')
    $params = @{
        Root        = $script:sandbox
        SharedRoot  = $script:shared
        Fork        = 'false'
        Repository  = ''
        LatestMajor = $script:latest
    }
    foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
    $out = (& $script:checker @params *>&1) -join "`n"
    $passed = $LASTEXITCODE -eq 0
    if ($passed -ne $ShouldPass) {
        Write-Host "FAIL  ${Name}: expected $(if ($ShouldPass) { 'pass' } else { 'failure' }), got exit $LASTEXITCODE"
        Write-Host "        $out"
        $script:failures++
        return
    }
    if ($ExpectedText -and $out -notmatch [regex]::Escape($ExpectedText)) {
        Write-Host "FAIL  ${Name}: output did not mention '$ExpectedText'"
        Write-Host "        $out"
        $script:failures++
        return
    }
    Write-Host "ok    $Name"
}

$script:checker = Join-Path $PSScriptRoot 'Assert-Conformance.ps1'
$script:failures = 0
$base = Join-Path ([System.IO.Path]::GetTempPath()) ('conformance-' + [System.Guid]::NewGuid().ToString('N'))
$script:sandbox = Join-Path $base 'repo'
$script:shared = Join-Path $base 'shared'
$script:latest = @{ 'actions/checkout' = 7; 'actions/cache' = 6; 'dtolnay/rust-toolchain' = 1 }
$sandbox = $script:sandbox
$shared = $script:shared

$caller = @'
name: Commit message check
on: [push]
jobs:
  check:
    uses: RealWhyKnot/workflows/.github/workflows/commit-msg-check.yml@v1
'@

$ci = @'
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: RealWhyKnot/workflows/workflow-syntax@v1
'@

$dependabot = @'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: chore
      include: scope
'@

$cargoEntry = @'
  - package-ecosystem: cargo
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: chore
'@

try {
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    Set-File -Root $shared -RelativePath 'hooks/commit-msg' -Content "#!/usr/bin/env bash`necho shared`n"
    Set-File -Root $shared -RelativePath 'hooks/prepare-commit-msg' -Content "#!/usr/bin/env bash`necho stamp`n"
    Invoke-Git @('-C', $sandbox, 'init', '--initial-branch=main', '--quiet')

    Set-File -Root $sandbox -RelativePath '.github/workflows/commit-msg-check.yml' -Content $caller
    Set-File -Root $sandbox -RelativePath '.github/workflows/ci.yml' -Content $ci
    Set-File -Root $sandbox -RelativePath '.github/dependabot.yml' -Content $dependabot
    Assert-Result -Name 'a conforming repo passes' -ShouldPass $true -ExpectedText 'match the shared setup'

    Set-File -Root $sandbox -RelativePath '.github/workflows/ci.yml' -Content (
        $ci -replace 'workflow-syntax@v1', 'workflow-syntax@main')
    Assert-Result -Name 'a shared action off v1 fails' -ShouldPass $false -ExpectedText 'pinned to @main'
    Set-File -Root $sandbox -RelativePath '.github/workflows/ci.yml' -Content $ci

    Remove-File -RelativePath '.github/workflows/commit-msg-check.yml'
    Assert-Result -Name 'a repo without the commit message check fails' -ShouldPass $false -ExpectedText (
        'No workflow calls commit-msg-check.yml')
    Set-File -Root $sandbox -RelativePath '.github/workflows/commits.yml' -Content (
        $caller -replace 'RealWhyKnot/workflows/(\.github/workflows/commit-msg-check\.yml)@v1', './$1')
    Assert-Result -Name 'a local call of the commit message check counts' -ShouldPass $true
    Remove-File -RelativePath '.github/workflows/commits.yml'
    Set-File -Root $sandbox -RelativePath '.github/workflows/commit-msg-check.yml' -Content $caller

    Assert-Result -Name 'a fork without a forbidden body pattern fails' -ShouldPass $false -Extra @{
        Fork = 'true'
    } -ExpectedText 'needs forbidden-body-pattern'
    Set-File -Root $sandbox -RelativePath '.github/workflows/commit-msg-check.yml' -Content (
        $caller + "`n    with:`n      forbidden-body-pattern: '#[0-9]+'`n")
    Assert-Result -Name 'a fork with a forbidden body pattern passes' -ShouldPass $true -ExpectedText '' -Extra @{
        Fork = 'true'
    }

    Set-File -Root $sandbox -RelativePath '.githooks/commit-msg' -Content "#!/usr/bin/env bash`r`necho shared`r`n"
    Assert-Result -Name 'a hook that only differs in line endings passes' -ShouldPass $true
    Set-File -Root $sandbox -RelativePath '.githooks/prepare-commit-msg' -Content (
        "#!/usr/bin/env bash`necho old stamp`n")
    Assert-Result -Name 'a stale hook fails' -ShouldPass $false -ExpectedText '.githooks/prepare-commit-msg: differs'
    Remove-File -RelativePath '.githooks/prepare-commit-msg'

    Set-File -Root $sandbox -RelativePath 'Cargo.toml' -Content "[package]`nname = `"x`"`n"
    Assert-Result -Name 'a Cargo.toml without a cargo entry fails' -ShouldPass $false -ExpectedText 'no cargo entry'
    Assert-Result -Name 'an ignored ecosystem is not required' -ShouldPass $true -ExpectedText '' -Extra @{
        IgnoreEcosystems = @('cargo')
    }
    Set-File -Root $sandbox -RelativePath '.github/dependabot.yml' -Content ($dependabot + "`n" + $cargoEntry)
    Assert-Result -Name 'a cargo entry covers Cargo.toml' -ShouldPass $true

    Set-File -Root $sandbox -RelativePath '.github/dependabot.yml' -Content (
        $dependabot + "`n" + ($cargoEntry -replace '(?s)    commit-message:.*$', ''))
    Assert-Result -Name 'an entry without a commit prefix fails' -ShouldPass $false -ExpectedText (
        'cargo entry has no commit-message prefix')
    Set-File -Root $sandbox -RelativePath '.github/dependabot.yml' -Content ($dependabot + "`n" + $cargoEntry)

    Set-File -Root $sandbox -RelativePath 'Packages/dev.x/package.json' -Content (
        '{ "name": "dev.x", "unity": "2022.3", "dependencies": {} }')
    Assert-Result -Name 'a Unity package.json does not need npm' -ShouldPass $true
    Set-File -Root $sandbox -RelativePath 'web/package.json' -Content (
        '{ "name": "web", "dependencies": { "vite": "^7" } }')
    Assert-Result -Name 'an npm package.json needs an npm entry' -ShouldPass $false -ExpectedText 'no npm entry'
    Remove-File -RelativePath 'web/package.json'

    Remove-File -RelativePath '.github/dependabot.yml'
    Assert-Result -Name 'a missing dependabot.yml fails' -ShouldPass $false -ExpectedText 'dependabot.yml is missing'
    Set-File -Root $sandbox -RelativePath '.github/dependabot.yml' -Content ($dependabot + "`n" + $cargoEntry)

    Set-File -Root $sandbox -RelativePath '.github/workflows/ci.yml' -Content (
        $ci + "`n      - uses: actions/cache@v4`n")
    Assert-Result -Name 'an old major only warns by default' -ShouldPass $true -ExpectedText (
        'actions/cache@v4 is behind v6')
    Assert-Result -Name 'an old major fails when pins is fail' -ShouldPass $false -Extra @{
        Pins = 'fail'
    } -ExpectedText 'actions/cache@v4 is behind v6'
    Assert-Result -Name 'pins off ignores it' -ShouldPass $true -ExpectedText '0 warning(s)' -Extra @{ Pins = 'off' }
    Set-File -Root $sandbox -RelativePath '.github/workflows/ci.yml' -Content (
        $ci + "`n      - uses: dtolnay/rust-toolchain@master`n")
    Assert-Result -Name 'a branch pin warns' -ShouldPass $true -ExpectedText 'follows a branch'
    Set-File -Root $sandbox -RelativePath '.github/workflows/ci.yml' -Content (
        $ci + "`n      - uses: actions/cache@0123456789abcdef0123456789abcdef01234567`n      - uses: ./local-action`n")
    Assert-Result -Name 'SHA pins and local actions are left alone' -ShouldPass $true -ExpectedText '0 warning(s)'
} finally {
    if (Test-Path $base) { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed."
    exit 1
}
Write-Host "`nAll checks passed."
exit 0
