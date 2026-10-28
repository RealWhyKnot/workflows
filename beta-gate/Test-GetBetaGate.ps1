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

function New-Repo {
    [CmdletBinding()]
    [OutputType([void])]
    param()
    Pop-Location -ErrorAction SilentlyContinue
    $script:repoCount++
    $script:repo = Join-Path $script:sandbox "repo$($script:repoCount)"
    $null = New-Item -ItemType Directory -Path $script:repo -Force
    Push-Location $script:repo
    Invoke-Git @('init', '--initial-branch=main', '--quiet')
    Invoke-Git @('config', 'user.name', 'Test')
    Invoke-Git @('config', 'user.email', 'test@example.com')
    Invoke-Git @('config', 'commit.gpgsign', 'false')
    New-Commit -Subject 'feat: seed' -Files @('src/app.txt')
}

function New-Commit {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Subject, [string[]] $Files = @())
    foreach ($f in $Files) {
        $path = Join-Path $script:repo $f
        $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
        [System.IO.File]::AppendAllText($path, [System.Guid]::NewGuid().ToString('N') + [Environment]::NewLine)
    }
    Invoke-Git @('add', '-A')
    Invoke-Git @('commit', '--allow-empty', '-m', $Subject)
}

function Assert-Gate {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Params, [hashtable] $Expected)
    [System.IO.File]::WriteAllText($script:outFile, '')
    $p = @{} + $Params
    $p['OutputPath'] = $script:outFile
    $null = & $script:gate @p *>&1
    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($script:outFile)) {
        if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    foreach ($k in $Expected.Keys) {
        if (-not $map.ContainsKey($k) -or $map[$k] -ne $Expected[$k]) {
            Write-Host "FAIL  $Name -- $k was '$(if ($map.ContainsKey($k)) { $map[$k] })', expected '$($Expected[$k])'"
            $script:failures++
            return
        }
    }
    Write-Host "ok    $Name"
}

$script:gate = Join-Path $PSScriptRoot 'Get-BetaGate.ps1'
$script:failures = 0
$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('beta-gate-' + [System.Guid]::NewGuid().ToString('N'))
$script:outFile = Join-Path $script:sandbox 'out.txt'
$script:repo = ''
$script:repoCount = 0

try {
    $null = New-Item -ItemType Directory -Path $script:sandbox -Force

    New-Repo
    Assert-Gate -Name 'no reachable tag ships' -Params @{} -Expected @{ has_changes = 'true'; base = '' }

    New-Repo
    New-Commit -Subject 'chore: stamp' -Files @('version.txt', 'verify.ps1')
    Invoke-Git @('tag', '-a', 'v2026.9.9.0-beta', '-m', 'beta')
    Assert-Gate -Name 'a tag on HEAD ships nothing, even with root files matching the tag glob' -Params @{} -Expected @{
        has_changes = 'false'; base = 'v2026.9.9.0-beta'
    }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'ci: move the build step' -Files @('src/app.txt')
    Assert-Gate -Name 'a ci commit touching source does not ship' -Params @{} -Expected @{ has_changes = 'false' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'fix: repair the workflow' -Files @('.github/workflows/ci.yml', 'README.md')
    Assert-Gate -Name 'a fix touching only CI and root markdown does not ship' -Params @{} -Expected @{
        has_changes = 'false'
    }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'fix(core): repair the thing (2026.9.2.0-AB12)' -Files @(
        'src/app.txt', '.github/workflows/ci.yml'
    )
    Assert-Gate -Name 'a fix touching source ships' -Params @{} -Expected @{
        has_changes = 'true'; base = 'v2026.9.1.0'
    }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'chore!: drop the old config format' -Files @('src/config.txt')
    Assert-Gate -Name 'a breaking change ships whatever its type' -Params @{} -Expected @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'chore(deps): bump a library' -Files @('package.json')
    New-Commit -Subject 'docs(changelog): auto-append entries [skip changelog]' -Files @('CHANGELOG.md')
    New-Commit -Subject 'feat: empty' -Files @()
    Assert-Gate -Name 'dependency bumps, changelog appends and empty commits do not ship' -Params @{} -Expected @{
        has_changes = 'false'
    }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'fix: document the flag' -Files @('src/help.md')
    Assert-Gate -Name 'markdown below the root still counts' -Params @{} -Expected @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'Update the parser' -Files @('src/parser.txt')
    Assert-Gate -Name 'a non-conventional subject touching source ships' -Params @{} -Expected @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'Revert "feat: a thing"' -Files @('docs/guide.txt', 'tests/a.txt')
    Assert-Gate -Name 'a non-conventional subject touching only docs and tests does not ship' -Params @{} -Expected @{
        has_changes = 'false'
    }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    Invoke-Git @('checkout', '--quiet', '-b', 'topic')
    New-Commit -Subject 'perf: faster loop' -Files @('src/loop.txt')
    Invoke-Git @('checkout', '--quiet', 'main')
    New-Commit -Subject 'ci: unrelated' -Files @('.github/x.yml')
    Invoke-Git @('merge', '--quiet', '--no-ff', '-m', 'Merge branch topic', 'topic')
    Assert-Gate -Name 'commits brought in by a merge are evaluated' -Params @{} -Expected @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'fix: tighten a test' -Files @(
        'App.Tests/ParserTests.cs', 'main_test.go', 'internal/x/y_test.go'
    )
    Assert-Gate -Name 'repo test paths ship without an override' -Params @{} -Expected @{ has_changes = 'true' }
    Assert-Gate -Name 'ignore-paths suppresses repo test paths' -Params @{
        IgnorePaths = "App.Tests/**`n**/*_test.go"
    } -Expected @{ has_changes = 'false' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'chore: tidy' -Files @('src/app.txt')
    Assert-Gate -Name 'release-types can widen what ships' -Params @{ ReleaseTypes = 'feat fix chore' } -Expected @{
        has_changes = 'true'
    }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit -Subject 'feat: new thing' -Files @('src/new.txt')
    Invoke-Git @('tag', 'released')
    New-Commit -Subject 'docs: notes' -Files @('docs/notes.txt')
    Assert-Gate -Name 'an explicit base is honoured' -Params @{ Base = 'released' } -Expected @{
        has_changes = 'false'; base = 'released'
    }
    Assert-Gate -Name 'a missing base ships' -Params @{ Base = 'v9999.1.1.1' } -Expected @{ has_changes = 'true' }
    Assert-Gate -Name 'the default tag-glob finds the v tag' -Params @{} -Expected @{
        has_changes = 'true'; base = 'v2026.9.1.0'
    }
    Assert-Gate -Name 'tag-glob picks which tags count as the base' -Params @{ TagGlob = 'rel*' } -Expected @{
        has_changes = 'false'; base = 'released'
    }
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $script:sandbox) { Remove-Item $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
