#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-SandboxGit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $output = & { $ErrorActionPreference = 'Continue'; & git -C $sandbox @Arguments 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    $lines = @($output)
    if ($lines.Count -eq 0) {
        return ''
    }
    "$($lines[-1])".Trim()
}

function New-SandboxCommit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Subject,
        [Parameter(Mandatory)][string] $Path
    )
    $file = Join-Path $sandbox $Path
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force
    [IO.File]::AppendAllText($file, "$Subject`n")
    $null = Invoke-SandboxGit -Arguments @('add', '-A')
    $null = Invoke-SandboxGit -Arguments @('commit', '--quiet', '-m', $Subject)
    Invoke-SandboxGit -Arguments @('rev-parse', 'HEAD')
}

function Assert-Equal {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()][AllowEmptyString()][object] $Actual,
        [AllowNull()][AllowEmptyString()][object] $Expected
    )
    if ("$Actual" -ceq "$Expected") {
        Write-Host "ok    $Name"
        return
    }
    Write-Host "FAIL  $Name -- got '$Actual', expected '$Expected'"
    $script:failures++
}

function Get-NextTag {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Day = '2026.10.28'
    )
    $next = Get-NextRelease -Root $sandbox -Day $Day
    if ($null -eq $next) {
        return ''
    }
    "$($next.Previous) $($next.Tag)"
}

Import-Module (Join-Path $PSScriptRoot 'ReleasePlan.psm1') -Force

$script:failures = 0
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('release-plan-' + [guid]::NewGuid().ToString('N'))

$workflow = @(
    'uses: RealWhyKnot/workflows/beta-gate@v1',
    'uses: RealWhyKnot/workflows/.github/workflows/commit-msg-check.yml@v1',
    'uses: RealWhyKnot/workflows/wait-for-ci@v1.6.2',
    'uses: actions/checkout@v7'
) -join "`n"
$pinned = @(
    'uses: RealWhyKnot/workflows/beta-gate@v2026.10.28.0',
    'uses: RealWhyKnot/workflows/.github/workflows/commit-msg-check.yml@v2026.10.28.0',
    'uses: RealWhyKnot/workflows/wait-for-ci@v1.6.2',
    'uses: actions/checkout@v7'
) -join "`n"
$converted = ConvertTo-PinnedReference -Content $workflow -Tag 'v2026.10.28.0'
Assert-Equal -Name 'only shared references move to the release tag' -Actual $converted -Expected $pinned

$paths = [ordered]@{
    'README.md'                                         = $false
    'beta-gate/Test-GetBetaGate.ps1'                    = $false
    '.github/workflows/ci.yml'                          = $false
    '.github/workflows/release.yml'                     = $false
    '.github/scripts/ReleasePlan.psm1'                  = $false
    '.github/dependabot.yml'                            = $false
    'lint/common/tests/test_style_check.py'             = $false
    'lint/python/.github/lint/selftest/test_pystyle.py' = $false
    '.github/workflows/nightly-beta.yml'                = $true
    'beta-gate/Get-BetaGate.ps1'                        = $true
    'beta-gate/action.yml'                              = $true
    'lint/powershell/.github/lint/PSStyleRules.psm1'    = $true
}
foreach ($path in $paths.Keys) {
    $shipped = Test-ShippedPath -Path $path
    Assert-Equal -Name "$path ships: $($paths[$path])" -Actual $shipped -Expected $paths[$path]
}

try {
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    $null = Invoke-SandboxGit -Arguments @('init', '--quiet', '--initial-branch=main')
    $null = Invoke-SandboxGit -Arguments @('config', 'user.name', 'Test')
    $null = Invoke-SandboxGit -Arguments @('config', 'user.email', 'test@example.com')
    $null = Invoke-SandboxGit -Arguments @('config', 'commit.gpgsign', 'false')
    $null = Invoke-SandboxGit -Arguments @('config', 'core.hooksPath', '.no-hooks')

    $null = New-SandboxCommit -Subject 'feat: seed' -Path 'beta-gate/action.yml'
    $threw = $false
    try {
        $null = Get-NextRelease -Root $sandbox -Day '2026.10.28'
    } catch [System.Management.Automation.RuntimeException] {
        $threw = $true
    }
    Assert-Equal -Name 'a repo with no release tag refuses to guess' -Actual $threw -Expected $true

    $null = Invoke-SandboxGit -Arguments @('tag', 'v1.6.2')
    Assert-Equal -Name 'nothing since the last release means no release' -Actual (Get-NextTag) -Expected ''

    $null = New-SandboxCommit -Subject 'docs: reword the readme' -Path 'README.md'
    $null = New-SandboxCommit -Subject 'test: cover the gate' -Path 'beta-gate/Test-GetBetaGate.ps1'
    Assert-Equal -Name 'docs and tests alone mean no release' -Actual (Get-NextTag) -Expected ''

    $null = New-SandboxCommit -Subject 'chore(deps): bump actions/cache' -Path 'setup-rust/action.yml'
    $expected = 'v1.6.2 v2026.10.28.0'
    Assert-Equal -Name 'the first dated release follows the old numbers' -Actual (Get-NextTag) -Expected $expected

    $main = Invoke-SandboxGit -Arguments @('rev-parse', 'HEAD')
    $null = Invoke-SandboxGit -Arguments @('checkout', '--quiet', '--detach')
    $release = @{
        Subject = 'chore(release): pin shared references to v2026.10.28.0 [skip changelog]'
        Path    = '.github/workflows/nightly-beta.yml'
    }
    $null = New-SandboxCommit @release
    $null = Invoke-SandboxGit -Arguments @('tag', '-a', 'v2026.10.28.0', '-m', 'v2026.10.28.0')
    $null = Invoke-SandboxGit -Arguments @('tag', 'v1')
    $null = Invoke-SandboxGit -Arguments @('checkout', '--quiet', 'main')
    $head = Invoke-SandboxGit -Arguments @('rev-parse', 'HEAD')
    Assert-Equal -Name 'main is untouched by the release commit' -Actual $head -Expected $main
    Assert-Equal -Name 'a release tag off main still counts as released' -Actual (Get-NextTag) -Expected ''

    $null = New-SandboxCommit -Subject 'fix(beta-gate): handle a shallow clone' -Path 'beta-gate/Get-BetaGate.ps1'
    $expected = 'v2026.10.28.0 v2026.10.28.1'
    Assert-Equal -Name 'a second release that day takes the next revision' -Actual (Get-NextTag) -Expected $expected

    $null = Invoke-SandboxGit -Arguments @('tag', 'v2026.10.29.0-beta')
    $expected = 'v2026.10.28.0 v2026.10.29.1'
    $actual = Get-NextTag -Day '2026.10.29'
    Assert-Equal -Name 'a tag with a suffix uses up its revision' -Actual $actual -Expected $expected

    $previous = Get-PreviousRelease -Root $sandbox -Tag 'v2026.10.28.1'
    Assert-Equal -Name 'the release before .1 is .0' -Actual $previous -Expected 'v2026.10.28.0'
    $previous = Get-PreviousRelease -Root $sandbox -Tag 'v2026.10.28.0'
    Assert-Equal -Name 'the first dated release follows v1.6.2' -Actual $previous -Expected 'v1.6.2'
    $previous = Get-PreviousRelease -Root $sandbox -Tag 'v1.6.2'
    Assert-Equal -Name 'the first release has no previous one' -Actual $previous -Expected ''

    $null = New-SandboxCommit -Subject 'feat!: drop the old input' -Path 'beta-gate/action.yml'
    $threw = $false
    try {
        $null = Get-NextRelease -Root $sandbox -Day '2026.10.28'
    } catch [System.Management.Automation.RuntimeException] {
        $threw = $_.Exception.Message -like '*breaking change*'
    }
    Assert-Equal -Name 'a breaking change stops the release' -Actual $threw -Expected $true
} finally {
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) failed."
    exit 1
}
Write-Host "`nAll checks passed."
exit 0
