#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:gate = Join-Path $PSScriptRoot 'Get-BetaGate.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("beta-gate-" + [System.Guid]::NewGuid().ToString('N'))
$script:outFile = Join-Path $sandbox 'out.txt'
$script:repo = ''
$script:repoCount = 0

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function New-Repo {
    Pop-Location -ErrorAction SilentlyContinue
    $script:repoCount++
    $script:repo = Join-Path $sandbox "repo$($script:repoCount)"
    New-Item -ItemType Directory -Path $script:repo -Force | Out-Null
    Push-Location $script:repo
    Invoke-Git @('init', '--initial-branch=main', '--quiet')
    Invoke-Git @('config', 'user.name', 'Test')
    Invoke-Git @('config', 'user.email', 'test@example.com')
    Invoke-Git @('config', 'commit.gpgsign', 'false')
    New-Commit 'feat: seed' @('src/app.txt')
}

function New-Commit {
    param([string] $Subject, [string[]] $Files = @())
    foreach ($f in $Files) {
        $path = Join-Path $script:repo $f
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Add-Content -LiteralPath $path -Value ([System.Guid]::NewGuid().ToString('N'))
    }
    Invoke-Git @('add', '-A')
    Invoke-Git @('commit', '--allow-empty', '-m', $Subject)
}

function Assert-Gate {
    param([string] $Name, [hashtable] $Params, [hashtable] $Expected)
    Set-Content -LiteralPath $script:outFile -Value '' -NoNewline
    $p = @{} + $Params
    $p['OutputPath'] = $script:outFile
    $null = & $script:gate @p *>&1
    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $script:outFile)) {
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

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

    New-Repo
    Assert-Gate 'no reachable tag ships' @{} @{ has_changes = 'true'; base = '' }

    New-Repo
    New-Commit 'chore: stamp' @('version.txt', 'verify.ps1')
    Invoke-Git @('tag', '-a', 'v2026.9.9.0-beta', '-m', 'beta')
    Assert-Gate 'a tag on HEAD ships nothing, even with root files matching the tag glob' @{} @{ has_changes = 'false'; base = 'v2026.9.9.0-beta' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'ci: move the build step' @('src/app.txt')
    Assert-Gate 'a ci commit touching source does not ship' @{} @{ has_changes = 'false' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'fix: repair the workflow' @('.github/workflows/ci.yml', 'README.md')
    Assert-Gate 'a fix touching only CI and root markdown does not ship' @{} @{ has_changes = 'false' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'fix(core): repair the thing (2026.9.2.0-AB12)' @('src/app.txt', '.github/workflows/ci.yml')
    Assert-Gate 'a fix touching source ships' @{} @{ has_changes = 'true'; base = 'v2026.9.1.0' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'chore!: drop the old config format' @('src/config.txt')
    Assert-Gate 'a breaking change ships whatever its type' @{} @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'chore(deps): bump a library' @('package.json')
    New-Commit 'docs(changelog): auto-append entries [skip changelog]' @('CHANGELOG.md')
    New-Commit 'feat: empty' @()
    Assert-Gate 'dependency bumps, changelog appends and empty commits do not ship' @{} @{ has_changes = 'false' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'fix: document the flag' @('src/help.md')
    Assert-Gate 'markdown below the root still counts' @{} @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'Update the parser' @('src/parser.txt')
    Assert-Gate 'a non-conventional subject touching source ships' @{} @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'Revert "feat: a thing"' @('docs/guide.txt', 'tests/a.txt')
    Assert-Gate 'a non-conventional subject touching only docs and tests does not ship' @{} @{ has_changes = 'false' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    Invoke-Git @('checkout', '--quiet', '-b', 'topic')
    New-Commit 'perf: faster loop' @('src/loop.txt')
    Invoke-Git @('checkout', '--quiet', 'main')
    New-Commit 'ci: unrelated' @('.github/x.yml')
    Invoke-Git @('merge', '--quiet', '--no-ff', '-m', 'Merge branch topic', 'topic')
    Assert-Gate 'commits brought in by a merge are evaluated' @{} @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'fix: tighten a test' @('App.Tests/ParserTests.cs', 'main_test.go', 'internal/x/y_test.go')
    Assert-Gate 'repo test paths ship without an override' @{} @{ has_changes = 'true' }
    Assert-Gate 'ignore-paths suppresses repo test paths' @{ IgnorePaths = "App.Tests/**`n**/*_test.go" } @{ has_changes = 'false' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'chore: tidy' @('src/app.txt')
    Assert-Gate 'release-types can widen what ships' @{ ReleaseTypes = 'feat fix chore' } @{ has_changes = 'true' }

    New-Repo
    Invoke-Git @('tag', 'v2026.9.1.0')
    New-Commit 'feat: new thing' @('src/new.txt')
    Invoke-Git @('tag', 'released')
    New-Commit 'docs: notes' @('docs/notes.txt')
    Assert-Gate 'an explicit base is honoured' @{ Base = 'released' } @{ has_changes = 'false'; base = 'released' }
    Assert-Gate 'a missing base ships' @{ Base = 'v9999.1.1.1' } @{ has_changes = 'true' }
    Assert-Gate 'the default tag-glob finds the v tag' @{} @{ has_changes = 'true'; base = 'v2026.9.1.0' }
    Assert-Gate 'tag-glob picks which tags count as the base' @{ TagGlob = 'rel*' } @{ has_changes = 'false'; base = 'released' }
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
