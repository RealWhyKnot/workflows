#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checker = Join-Path $PSScriptRoot 'Assert-Conformance.ps1'
$script:failures = 0
$base = Join-Path ([System.IO.Path]::GetTempPath()) ("conformance-" + [System.Guid]::NewGuid().ToString('N'))
$sandbox = Join-Path $base 'repo'
$shared = Join-Path $base 'shared'
$latest = @{ 'actions/checkout' = 7; 'actions/cache' = 6; 'dtolnay/rust-toolchain' = 1 }

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function Set-File {
    param([string] $Root, [string] $RelativePath, [string] $Content)
    $full = Join-Path $Root $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-File {
    param([string] $RelativePath)
    Remove-Item -LiteralPath (Join-Path $sandbox $RelativePath) -Force
}

function Assert-Result {
    param([string] $Name, [bool] $ShouldPass, [string] $ExpectedText = '', [hashtable] $Extra = @{})
    Invoke-Git @('-C', $sandbox, 'add', '-A')
    $params = @{ Root = $sandbox; SharedRoot = $shared; Fork = 'false'; Repository = ''; LatestMajor = $latest }
    foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
    $out = (& $checker @params *>&1) -join "`n"
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

$caller = @"
name: Commit message check
on: [push]
jobs:
  check:
    uses: RealWhyKnot/workflows/.github/workflows/commit-msg-check.yml@v1
"@

$ci = @"
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: RealWhyKnot/workflows/workflow-syntax@v1
"@

$dependabot = @"
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: chore
      include: scope
"@

$cargoEntry = @"
  - package-ecosystem: cargo
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: chore
"@

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Set-File $shared 'hooks/commit-msg' "#!/usr/bin/env bash`necho shared`n"
    Set-File $shared 'hooks/prepare-commit-msg' "#!/usr/bin/env bash`necho stamp`n"
    Invoke-Git @('-C', $sandbox, 'init', '--initial-branch=main', '--quiet')

    Set-File $sandbox '.github/workflows/commit-msg-check.yml' $caller
    Set-File $sandbox '.github/workflows/ci.yml' $ci
    Set-File $sandbox '.github/dependabot.yml' $dependabot
    Assert-Result 'a conforming repo passes' $true 'match the shared setup'

    Set-File $sandbox '.github/workflows/ci.yml' ($ci -replace 'workflow-syntax@v1', 'workflow-syntax@main')
    Assert-Result 'a shared action off v1 fails' $false 'pinned to @main'
    Set-File $sandbox '.github/workflows/ci.yml' $ci

    Remove-File '.github/workflows/commit-msg-check.yml'
    Assert-Result 'a repo without the commit message check fails' $false 'No workflow calls commit-msg-check.yml'
    Set-File $sandbox '.github/workflows/commits.yml' ($caller -replace 'RealWhyKnot/workflows/(\.github/workflows/commit-msg-check\.yml)@v1', './$1')
    Assert-Result 'a local call of the commit message check counts' $true
    Remove-File '.github/workflows/commits.yml'
    Set-File $sandbox '.github/workflows/commit-msg-check.yml' $caller

    Assert-Result 'a fork without a forbidden body pattern fails' $false 'needs forbidden-body-pattern' @{ Fork = 'true' }
    Set-File $sandbox '.github/workflows/commit-msg-check.yml' ($caller + "`n    with:`n      forbidden-body-pattern: '#[0-9]+'`n")
    Assert-Result 'a fork with a forbidden body pattern passes' $true '' @{ Fork = 'true' }

    Set-File $sandbox '.githooks/commit-msg' "#!/usr/bin/env bash`r`necho shared`r`n"
    Assert-Result 'a hook that only differs in line endings passes' $true
    Set-File $sandbox '.githooks/prepare-commit-msg' "#!/usr/bin/env bash`necho old stamp`n"
    Assert-Result 'a stale hook fails' $false '.githooks/prepare-commit-msg: differs'
    Remove-File '.githooks/prepare-commit-msg'

    Set-File $sandbox 'Cargo.toml' "[package]`nname = `"x`"`n"
    Assert-Result 'a Cargo.toml without a cargo entry fails' $false 'no cargo entry'
    Assert-Result 'an ignored ecosystem is not required' $true '' @{ IgnoreEcosystems = @('cargo') }
    Set-File $sandbox '.github/dependabot.yml' ($dependabot + "`n" + $cargoEntry)
    Assert-Result 'a cargo entry covers Cargo.toml' $true

    Set-File $sandbox '.github/dependabot.yml' ($dependabot + "`n" + ($cargoEntry -replace '(?s)    commit-message:.*$', ''))
    Assert-Result 'an entry without a commit prefix fails' $false 'cargo entry has no commit-message prefix'
    Set-File $sandbox '.github/dependabot.yml' ($dependabot + "`n" + $cargoEntry)

    Set-File $sandbox 'Packages/dev.x/package.json' '{ "name": "dev.x", "unity": "2022.3", "dependencies": {} }'
    Assert-Result 'a Unity package.json does not need npm' $true
    Set-File $sandbox 'web/package.json' '{ "name": "web", "dependencies": { "vite": "^7" } }'
    Assert-Result 'an npm package.json needs an npm entry' $false 'no npm entry'
    Remove-File 'web/package.json'

    Remove-File '.github/dependabot.yml'
    Assert-Result 'a missing dependabot.yml fails' $false 'dependabot.yml is missing'
    Set-File $sandbox '.github/dependabot.yml' ($dependabot + "`n" + $cargoEntry)

    Set-File $sandbox '.github/workflows/ci.yml' ($ci + "`n      - uses: actions/cache@v4`n")
    Assert-Result 'an old major only warns by default' $true 'actions/cache@v4 is behind v6'
    Assert-Result 'an old major fails when pins is fail' $false 'actions/cache@v4 is behind v6' @{ Pins = 'fail' }
    Assert-Result 'pins off ignores it' $true '0 warning(s)' @{ Pins = 'off' }
    Set-File $sandbox '.github/workflows/ci.yml' ($ci + "`n      - uses: dtolnay/rust-toolchain@master`n")
    Assert-Result 'a branch pin warns' $true 'follows a branch'
    Set-File $sandbox '.github/workflows/ci.yml' ($ci + "`n      - uses: actions/cache@0123456789abcdef0123456789abcdef01234567`n      - uses: ./local-action`n")
    Assert-Result 'SHA pins and local actions are left alone' $true '0 warning(s)'
}
finally {
    if (Test-Path $base) { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed."
    exit 1
}
Write-Host "`nAll checks passed."
exit 0
