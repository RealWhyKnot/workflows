#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checker = Join-Path $PSScriptRoot 'Assert-WorkflowSyntax.ps1'
$script:failures = 0
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("workflow-syntax-" + [System.Guid]::NewGuid().ToString('N'))

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
}

function Set-File {
    param([string] $RelativePath, [string] $Content)
    $full = Join-Path $sandbox $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Assert-Result {
    param([string] $Name, [bool] $ShouldPass, [string] $ExpectedText = '')
    $out = (& $checker -Root $sandbox *>&1) -join "`n"
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

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Push-Location $sandbox
    Invoke-Git @('init', '--initial-branch=main', '--quiet')
    Invoke-Git @('config', 'user.name', 'Test')
    Invoke-Git @('config', 'user.email', 'test@example.com')

    Set-File 'scripts/Good.ps1' "param([string] `$X)`nWrite-Host `$X`n"
    Set-File '.github/workflows/good.yml' @"
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
    Invoke-Git @('add', '-A')
    Assert-Result 'a clean repo passes' $true 'Parsed'

    Set-File 'scripts/Broken.ps1' "function Oops {`n  Write-Host 'unclosed'`n"
    Invoke-Git @('add', '-A')
    Assert-Result 'a broken tracked script fails' $false 'scripts/Broken.ps1'
    Invoke-Git @('rm', '-q', '-f', 'scripts/Broken.ps1')

    Set-File '.github/workflows/bad.yml' @"
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
    Invoke-Git @('add', '-A')
    Assert-Result 'a broken inline pwsh block fails' $false "step 'A broken pwsh step'"
    Remove-Item (Join-Path $sandbox '.github/workflows/bad.yml') -Force
    Invoke-Git @('add', '-A')

    Set-File '.github/workflows/sticky.yml' @"
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
    Invoke-Git @('add', '-A')
    Assert-Result 'a bash block after a pwsh step is not parsed as PowerShell' $true

    Set-File '.github/workflows/stub.yml' @"
name: Caller stub
on:
  push:
    branches: [main]
jobs:
  check:
    uses: RealWhyKnot/workflows/.github/workflows/commit-msg-check.yml@v1
"@
    Invoke-Git @('add', '-A')
    Assert-Result 'a reusable-workflow caller stub is accepted' $true
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed."
    exit 1
}
Write-Host "`nAll checks passed."
exit 0
