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
    Assert-Check -Name 'a missing .gitattributes is reported' -Condition (
        $result.Code -eq 1 -and $result.Text.Contains('.gitattributes is missing.'))
    $common = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'common/merge/.gitattributes'))
    [IO.File]::WriteAllText((Join-Path $sandbox '.gitattributes'), "*.py diff=python`n")
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'a .gitattributes without the line ending default is reported' -Condition (
        $result.Code -eq 1 -and $result.Text -match '\.gitattributes is missing 1 settings')
    [IO.File]::WriteAllText((Join-Path $sandbox '.gitattributes'), $common)
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'auto-detection installs Python' -Condition ($result.Code -eq 0)
    $ruff = Join-Path $sandbox 'ruff.toml'
    Assert-Check -Name 'Python baseline exists' -Condition (Test-Path -LiteralPath $ruff)
    Assert-Check -Name 'shared checker is installed' -Condition (
        Test-Path -LiteralPath (Join-Path $sandbox '.github/lint/style_check.py'))
    Assert-Check -Name 'selftests are not distributed' -Condition (
        -not (Test-Path -LiteralPath (Join-Path $sandbox '.github/lint/selftest')))
    $runner = '.github/lint/repo_checks.sh'
    $mode = @(& git -C $sandbox ls-files --stage -- $runner)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the runner mode.' }
    Assert-Check -Name 'a new shebang file has an executable index entry' -Condition (
        $mode.Count -eq 1 -and $mode[0].StartsWith('100755 '))
    $staged = @(& git -C $sandbox diff --cached --name-only -- $runner)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect staged files.' }
    Assert-Check -Name 'new script contents remain unstaged' -Condition ($staged.Count -eq 0)
    $runnerPath = Join-Path $sandbox $runner
    $baseline = [IO.File]::ReadAllText($runnerPath)
    [IO.File]::WriteAllText($runnerPath, "#!/usr/bin/env bash`necho staged`n")
    $null = & git -C $sandbox add --chmod=-x -- $runner
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the runner fixture.' }
    $before = & git -C $sandbox rev-parse ":$runner"
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the staged runner.' }
    [IO.File]::WriteAllText($runnerPath, $baseline)
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'compare mode reports a wrong executable bit' -Condition (
        $result.Code -eq 1 -and $result.Text.Contains("$runner isn't executable in git"))
    $mode = @(& git -C $sandbox ls-files --stage -- $runner)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the runner mode.' }
    Assert-Check -Name 'compare mode leaves the index unchanged' -Condition ($mode[0].StartsWith('100644 '))
    $result = Invoke-Install -Root $sandbox -Arguments @('-Force')
    Assert-Check -Name 'force repairs the executable bit' -Condition ($result.Code -eq 0)
    $mode = @(& git -C $sandbox ls-files --stage -- $runner)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the repaired runner mode.' }
    Assert-Check -Name 'tracked script is executable without staging its contents' -Condition (
        $mode[0].StartsWith("100755 $before "))
    $null = & git -C $sandbox add -- $runner
    if ($LASTEXITCODE -ne 0) { throw 'Could not index the installed runner.' }
    $mode = @(& git -C $sandbox ls-files --stage -- $runner)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the runner mode after add.' }
    Assert-Check -Name 'git add preserves the installed executable bit' -Condition ($mode[0].StartsWith('100755 '))
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'unchanged install is idempotent' -Condition (
        $result.Code -eq 0 -and $result.Text.Contains('ruff.toml is already current'))
    [IO.File]::AppendAllText($ruff, "`nline-length = 200`n")
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'drift blocks installation' -Condition ($result.Code -eq 1)
    $result = Invoke-Install -Root $sandbox -Arguments @('-Force')
    Assert-Check -Name 'force replaces drift' -Condition ($result.Code -eq 0)
    $local = Join-Path $sandbox '.github/lint/vendored-paths.local.txt'
    [IO.File]::WriteAllText($local, "upstream/`n/external/library/`n/docs/NOTICE.md`n")
    $result = Invoke-Install -Root $sandbox -Arguments @('-Force')
    Assert-Check -Name 'local vendored paths install' -Condition ($result.Code -eq 0)
    $config = [IO.File]::ReadAllText((Join-Path $sandbox 'pyrightconfig.json')) | ConvertFrom-Json
    Assert-Check -Name 'named vendored paths are folded' -Condition ($config.exclude -contains '**/upstream')
    Assert-Check -Name 'rooted vendored paths are folded' -Condition ($config.exclude -contains 'external/library')
    Assert-Check -Name 'vendored files are folded' -Condition ($config.exclude -contains 'docs/NOTICE.md')
    $typos = [IO.File]::ReadAllLines((Join-Path $sandbox '.github/lint/typos.toml'))
    Assert-Check -Name 'typos skips vendored paths' -Condition (
        ($typos -contains '  "upstream/",') -and ($typos -contains '  "/external/library/",') -and
        ($typos -contains '  "/docs/NOTICE.md",'))
    $gitleaks = [IO.File]::ReadAllText((Join-Path $sandbox '.github/lint/gitleaks.toml'))
    Assert-Check -Name 'gitleaks keeps the default rules' -Condition ($gitleaks.Contains('useDefault = true'))
    Assert-Check -Name 'gitleaks skips only vendored paths' -Condition (
        $gitleaks.Contains("'''((^|/)upstream/)'''") -and
        $gitleaks.Contains("'''(^external/library/)'''") -and
        $gitleaks.Contains("'''(^docs/NOTICE\.md$)'''"))
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'folded baselines remain current' -Condition ($result.Code -eq 0)
    [IO.File]::WriteAllText($local, "*.py`n")
    $result = Invoke-Install -Root $sandbox
    Assert-Check -Name 'invalid vendored paths fail' -Condition ($result.Code -ne 0)
    [IO.File]::WriteAllText($local, '')
    $attributes = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shell/merge/.gitattributes'))
    [IO.File]::WriteAllText((Join-Path $sandbox '.gitattributes'), $common + $attributes)
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'csharp,shell', '-Force')
    Assert-Check -Name 'CSharp line endings are reported when missing' -Condition (
        $result.Code -eq 1 -and $result.Text -match 'csharp: \.gitattributes is missing 5 settings')
    $csharpAttributes = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'csharp/merge/.gitattributes'))
    [IO.File]::WriteAllText((Join-Path $sandbox '.gitattributes'), $common + $attributes + $csharpAttributes)
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'csharp,shell', '-Force')
    Assert-Check -Name 'multiple languages merge successfully' -Condition ($result.Code -eq 0)
    $editor = [IO.File]::ReadAllText((Join-Path $sandbox '.editorconfig'))
    Assert-Check -Name 'shell and CSharp editor sections survive' -Condition (
        $editor.Contains('[[shell]]') -and $editor.Contains('[*.{cs,csx}]'))
    [IO.File]::WriteAllText($local, "upstream/`n/docs/NOTICE.md`n")
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'shell', '-Force')
    $editor = [IO.File]::ReadAllText((Join-Path $sandbox '.editorconfig'))
    Assert-Check -Name 'vendored folders and files share the editor sections' -Condition (
        $result.Code -eq 0 -and $editor.Contains("`n[{vendor,third_party,node_modules,.yarn,upstream}/**]`nignore = true`n") -and
        $editor.Contains("`n[**/{vendor,third_party,node_modules,.yarn,upstream}/**]`nignore = true`n") -and
        $editor.Contains("`n[docs/NOTICE.md]`nignore = true`n"))
    [IO.File]::WriteAllText($local, '')
    [IO.File]::WriteAllText($local, "/docs/NOTICE.md`n/docs/LICENSE.txt`n")
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'csharp,shell,typescript', '-Force')
    Assert-Check -Name 'vendored files install with TypeScript' -Condition ($result.Code -eq 0)
    $editor = [IO.File]::ReadAllText((Join-Path $sandbox '.editorconfig'))
    $section = [regex]::Match($editor, '(?m)^\[\{docs/NOTICE\.md,docs/LICENSE\.txt\}\]\n(?<body>(?:[^\[\n][^\n]*\n)*)')
    $body = $section.Groups['body'].Value
    Assert-Check -Name 'vendored files get their own editor section' -Condition (
        $section.Success -and $body.Contains("generated_code = true`n") -and $body.Contains("ignore = true`n"))
    $ignore = [IO.File]::ReadAllLines((Join-Path $sandbox '.prettierignore'))
    Assert-Check -Name 'prettierignore keeps vendored files' -Condition ($ignore -contains '/docs/NOTICE.md')
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'css', '-Force')
    Assert-Check -Name 'CSS baseline installs' -Condition ($result.Code -eq 0)
    $stylelint = [IO.File]::ReadAllText((Join-Path $sandbox 'stylelint.config.mjs'))
    $guards = @(
        'ignoreDisables', 'reportNeedlessDisables', 'reportInvalidScopeDisables', 'reportDescriptionlessDisables'
    )
    foreach ($guard in $guards) {
        Assert-Check -Name "Stylelint keeps $guard enabled" -Condition ($stylelint.Contains("${guard}: true"))
    }
    [IO.File]::WriteAllText($local, '')
    $lints = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'rust/merge/workspace-lints.toml'))
    $member = Join-Path $sandbox 'rs/crates/member'
    $null = [IO.Directory]::CreateDirectory($member)
    [IO.File]::WriteAllText((Join-Path $sandbox 'rs/Cargo.toml'), "[workspace]`n`n$lints")
    [IO.File]::WriteAllText((Join-Path $member 'Cargo.toml'), "[lints]`nworkspace = true`n")
    $null = & git -C $sandbox add -- rs
    if ($LASTEXITCODE -ne 0) { throw 'Could not index the nested workspace.' }
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'rust', '-Force')
    Assert-Check -Name 'nested workspace manifests are checked' -Condition (
        $result.Text.Contains('rs/Cargo.toml has everything') -and -not $result.Text.Contains('is missing.'))
    Assert-Check -Name 'member manifests are not checked' -Condition (-not $result.Text.Contains('rs/crates'))
    [IO.File]::WriteAllText((Join-Path $sandbox 'rs/Cargo.toml'), "[workspace]`n")
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'rust', '-Force')
    Assert-Check -Name 'nested workspace drift is reported' -Condition (
        $result.Text -match 'rs/Cargo\.toml is missing \d+ settings')
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'unknown')
    Assert-Check -Name 'unknown languages fail' -Condition ($result.Code -ne 0)
    $result = Invoke-Install -Root $sandbox -Arguments @('-Lang', 'powershell', '-Force')
    Assert-Check -Name 'PowerShell baseline installs' -Condition ($result.Code -eq 0)
    $mode = @(& git -C $sandbox ls-files --stage -- .github/lint/Invoke-PSLint.ps1)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the PowerShell script mode.' }
    Assert-Check -Name 'non-shell shebang files are executable too' -Condition (
        $mode.Count -eq 1 -and $mode[0].StartsWith('100755 '))
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}
Write-Host 'All installer checks passed.'
exit 0
