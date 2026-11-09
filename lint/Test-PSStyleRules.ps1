#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RuleHit {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $Code)
    $rules = Join-Path $PSScriptRoot 'powershell/.github/lint/PSStyleRules.psm1'
    $records = @(Invoke-ScriptAnalyzer -ScriptDefinition $Code -CustomRulePath $rules)
    $names = @(foreach ($record in $records) {
            if ($record.RuleName -match '(StyleExitCode|StyleLiteralPath|StyleRelativePath)$') {
                $Matches[1]
            }
        })
    $names
}

$cases = @(
    @{ Name = 'a native command with no exit check'; Code = "git fetch origin`n"; Expect = @('StyleExitCode') }
    @{
        Name   = 'a native command followed by an exit check'
        Code   = "git fetch origin`nif (`$LASTEXITCODE -ne 0) { throw 'fetch failed' }`n"
        Expect = @()
    }
    @{
        Name   = 'a native command checked in the same statement'
        Code   = "`$ok = (git diff --quiet) -or `$LASTEXITCODE -eq 0`n"
        Expect = @()
    }
    @{
        Name   = 'a native command inside a Continue scope checked after it'
        Code   = "`$out = & { `$ErrorActionPreference = 'Continue'; git rev-parse HEAD 2>&1 }`n" +
        "if (`$LASTEXITCODE -ne 0) { throw `$out }`n"
        Expect = @()
    }
    @{
        Name   = 'a check two statements later does not count'
        Code   = "git fetch origin`nWrite-Host 'fetched'`nif (`$LASTEXITCODE -ne 0) { throw 'fetch failed' }`n"
        Expect = @('StyleExitCode')
    }
    @{
        Name   = 'a native command in an array checked after it'
        Code   = "`$files = @(git ls-files)`nif (`$LASTEXITCODE -ne 0) { throw 'x' }`n"
        Expect = @()
    }
    @{
        Name   = 'a native command in a subexpression checked after it'
        Code   = "`$tag = `"`$(git describe)`".Trim()`nif (`$LASTEXITCODE -ne 0) { throw 'x' }`n"
        Expect = @()
    }
    @{
        Name   = 'a native command in an array with no check'
        Code   = "`$files = @(git ls-files)`n`$files.Count`n"
        Expect = @('StyleExitCode')
    }
    @{
        Name   = 'a native command in each branch checked after the if'
        Code   = "if (`$a) { git fetch } else { git pull }`nif (`$LASTEXITCODE -ne 0) { throw 'x' }`n"
        Expect = @()
    }
    @{
        Name   = 'a native command in a loop checked after the loop'
        Code   = "foreach (`$r in `$rs) { git fetch `$r }`nif (`$LASTEXITCODE -ne 0) { throw 'x' }`n"
        Expect = @('StyleExitCode')
    }
    @{ Name = 'an unknown tool counts as native';Code = "notarealtool --flag`n"; Expect = @('StyleExitCode') }
    @{ Name = 'a cmdlet needs no exit check'; Code = "Write-Host 'done'`n"; Expect = @() }
    @{
        Name   = 'a positional path from data'
        Code   = "`$items = @(Get-ChildItem `$dir -Filter *.log)`n"
        Expect = @('StyleLiteralPath')
    }
    @{ Name = 'a named path from data'; Code = "`$found = Test-Path -Path `$file`n"; Expect = @('StyleLiteralPath') }
    @{
        Name   = 'a wildcard pattern from data'
        Code   = "`$found = @(Get-ChildItem -Path `$assetPattern -File)`n"
        Expect = @()
    }
    @{ Name = 'a literal path';Code = "`$found = Test-Path -LiteralPath `$file`n"; Expect = @() }
    @{ Name = 'a constant path'; Code = "`$found = Test-Path 'C:\Windows'`n"; Expect = @() }
    @{ Name = 'a deliberate wildcard'; Code = "`$items = @(Get-ChildItem `"`$dir/*.ps1`")`n"; Expect = @() }
    @{
        Name   = 'a relative path in a .NET call'
        Code   = "`$text = [IO.File]::ReadAllText('config.json')`n"
        Expect = @('StyleRelativePath')
    }
    @{
        Name   = 'a rooted path in a .NET call'
        Code   = "`$text = [IO.File]::ReadAllText((Join-Path `$PSScriptRoot 'config.json'))`n"
        Expect = @()
    }
)

$failed = 0
foreach ($case in $cases) {
    $hits = @(Get-RuleHit -Code $case.Code)
    if (($hits -join ',') -eq ($case.Expect -join ',')) {
        Write-Host "ok    $($case.Name)"
    } else {
        Write-Host "FAIL  $($case.Name): got [$($hits -join ', ')], wanted [$($case.Expect -join ', ')]"
        $failed++
    }
}
if ($failed -gt 0) {
    Write-Host "$failed style rule checks failed."
    exit 1
}
Write-Host 'All style rule checks passed.'
exit 0
