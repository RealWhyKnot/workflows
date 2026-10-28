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
    param([string] $RelativePath, [string] $Content)
    $full = Join-Path $script:sandbox $RelativePath
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Assert-Result {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [bool] $ShouldPass, [string] $ExpectedText = '')
    $out = (& $script:checker -Root $script:sandbox *>&1) -join "`n"
    $passed = $LASTEXITCODE -eq 0
    if ($passed -ne $ShouldPass) {
        Write-Host "FAIL  $Name -- expected $(if ($ShouldPass) { 'pass' } else { 'failure' }), got exit $LASTEXITCODE"
        Write-Host "        $out"
        $script:failures++
        return
    }
    if ($ExpectedText -and $out -notmatch [regex]::Escape($ExpectedText)) {
        Write-Host "FAIL  $Name -- output did not mention '$ExpectedText'"
        Write-Host "        $out"
        $script:failures++
        return
    }
    Write-Host "ok    $Name"
}

$script:checker = Join-Path $PSScriptRoot 'Assert-WorkflowSyntax.ps1'
$script:failures = 0
$sandboxName = 'workflow-syntax-' + [System.Guid]::NewGuid().ToString('N')
$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) $sandboxName
$sandbox = $script:sandbox

try {
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    Push-Location $sandbox
    Invoke-Git -Arguments @('init', '--initial-branch=main', '--quiet')
    Invoke-Git -Arguments @('config', 'user.name', 'Test')
    Invoke-Git -Arguments @('config', 'user.email', 'test@example.com')

    Set-File -RelativePath 'scripts/Good.ps1' -Content "param([string] `$X)`nWrite-Host `$X`n"
    Set-File -RelativePath '.github/workflows/good.yml' -Content @"
name: Good
jobs:
  a:
    steps:
      - name: A pwsh step
        shell: pwsh
        run: |
          `$tag = '`${{ github.ref_name }}'
          Write-Host `$tag
      - name: A bash step
        shell: bash
        run: |
          if [ -n "`$HOME" ]; then echo ok; fi
"@
    Invoke-Git -Arguments @('add', '-A')
    Assert-Result -Name 'a clean repo passes' -ShouldPass $true -ExpectedText 'Parsed'

    Set-File -RelativePath 'scripts/Broken.ps1' -Content "function Oops {`n  Write-Host 'unclosed'`n"
    Invoke-Git -Arguments @('add', '-A')
    Assert-Result -Name 'a broken tracked script fails' -ShouldPass $false -ExpectedText 'scripts/Broken.ps1'
    Invoke-Git -Arguments @('rm', '-q', '-f', 'scripts/Broken.ps1')

    Set-File -RelativePath '.github/workflows/bad.yml' -Content @"
name: Bad
jobs:
  a:
    steps:
      - name: A broken pwsh step
        shell: pwsh
        run: |
          if (`$true) {
            Write-Host 'unclosed'
"@
    Invoke-Git -Arguments @('add', '-A')
    Assert-Result -Name 'a broken inline pwsh block fails' -ShouldPass $false -ExpectedText "step 'A broken pwsh step'"
    Remove-Item (Join-Path $sandbox '.github/workflows/bad.yml') -Force
    Invoke-Git -Arguments @('add', '-A')

    Set-File -RelativePath '.github/workflows/sticky.yml' -Content @"
name: Sticky
jobs:
  a:
    steps:
      - name: A pwsh step
        shell: pwsh
        run: |
          Write-Host 'fine'
      - name: A bash step that is not PowerShell
        shell: bash
        run: |
          for f in *.txt; do
            echo "`$f"
          done
"@
    Invoke-Git -Arguments @('add', '-A')
    Assert-Result -Name 'a bash block after a pwsh step is not parsed as PowerShell' -ShouldPass $true

    Set-File -RelativePath '.github/workflows/stub.yml' -Content @'
name: Caller stub
on:
  push:
    branches: [main]
jobs:
  check:
    uses: RealWhyKnot/workflows/.github/workflows/commit-msg-check.yml@v1
'@
    Invoke-Git -Arguments @('add', '-A')
    Assert-Result -Name 'a reusable-workflow caller stub is accepted' -ShouldPass $true

    Set-File -RelativePath '.github/workflows/push.yml' -Content @'
name: Push
jobs:
  a:
    steps:
      - uses: actions/checkout@v7
      - name: Push it
        shell: bash
        run: |
          git push origin HEAD
'@
    Invoke-Git -Arguments @('add', '-A')
    $name = 'a push without persist-credentials: false fails'
    Assert-Result -Name $name -ShouldPass $false -ExpectedText 'persist-credentials'
    Set-File -RelativePath '.github/workflows/push.yml' -Content @'
name: Push
jobs:
  a:
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - name: Push it
        shell: bash
        run: |
          git push origin HEAD
'@
    Invoke-Git -Arguments @('add', '-A')
    Assert-Result -Name 'a push with persist-credentials: false passes' -ShouldPass $true

    Set-File -RelativePath '.github/workflows/stale.yml' -Content @"
name: Stale
jobs:
  a:
    steps:
      - name: Probe a tag
        shell: pwsh
        run: |
          git rev-parse v1 2>`$null
          if (`$LASTEXITCODE -eq 0) { Write-Host 'exists' }
"@
    Invoke-Git -Arguments @('add', '-A')
    $name = 'a tolerated native failure without a reset fails'
    Assert-Result -Name $name -ShouldPass $false -ExpectedText "step 'Probe a tag'"
    Set-File -RelativePath '.github/workflows/stale.yml' -Content @"
name: Stale
jobs:
  a:
    steps:
      - name: Probe a tag
        shell: pwsh
        run: |
          git rev-parse v1 2>`$null
          if (`$LASTEXITCODE -eq 0) { Write-Host 'exists' }
          `$global:LASTEXITCODE = 0
"@
    Invoke-Git -Arguments @('add', '-A')
    Assert-Result -Name 'a tolerated native failure with a reset passes' -ShouldPass $true
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed."
    exit 1
}
Write-Host "`nAll checks passed."
exit 0
