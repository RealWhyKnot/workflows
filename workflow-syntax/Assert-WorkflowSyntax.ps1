#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Root = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Add-ParseError {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [System.Collections.Generic.List[string]] $Problems,
        [string] $Source,
        [System.Management.Automation.Language.ParseError[]] $ParseErrors
    )
    if (-not $ParseErrors) { return }
    foreach ($err in $ParseErrors) {
        $where = "$($err.Extent.StartLineNumber):$($err.Extent.StartColumnNumber)"
        $Problems.Add("$Source (line $where): $($err.Message)")
    }
}

function Add-RunBlockProblem {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [System.Collections.Generic.List[string]] $Problems,
        [System.Collections.Generic.List[string]] $BlockLines,
        [string] $Label,
        [regex] $GhaPattern
    )
    if ($BlockLines.Count -eq 0) { return }
    $baseline = -1
    foreach ($line in $BlockLines) {
        if ($line.Trim().Length -eq 0) { continue }
        $baseline = $line.Length - $line.TrimStart(' ').Length
        break
    }
    if ($baseline -lt 0) { return }
    $body = @(foreach ($line in $BlockLines) {
            if ($line.Length -gt $baseline) { $line.Substring($baseline) } else { '' }
        }) -join "`n"
    $stubbed = $GhaPattern.Replace($body, '__GHA_EXPR__')
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($stubbed, [ref]$null, [ref]$parseErrors)
    Add-ParseError -Problems $Problems -Source $Label -ParseErrors $parseErrors

    $suppresses = $body -match '2>\$null'
    $tolerates = $body -match '\$LASTEXITCODE\s+-eq\s+0'
    $resets = $body -match '\$global:LASTEXITCODE\s*=\s*0'
    if ($suppresses -and $tolerates -and -not $resets) {
        $Problems.Add("${Label}: lets a native command fail without setting `$global:LASTEXITCODE = 0, " +
            'so the step exits with the stale code.')
    }
}

$Root = (Resolve-Path -LiteralPath $Root).Path
$errors = New-Object System.Collections.Generic.List[string]

$tracked = @(& git -C $Root ls-files '*.ps1' '*.psm1' '*.psd1')
if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $Root ($LASTEXITCODE)" }

foreach ($relative in $tracked) {
    if (-not $relative) { continue }
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
    Add-ParseError -Problems $errors -Source $relative -ParseErrors $parseErrors
}

$workflowDir = Join-Path (Join-Path $Root '.github') 'workflows'
$ghaPattern = [regex]'\$\{\{[^}]*\}\}'

if (Test-Path -LiteralPath $workflowDir) {
    $workflowFiles = @(Get-ChildItem -LiteralPath $workflowDir -File | Where-Object {
            $_.Extension -in '.yml', '.yaml'
        })
    foreach ($file in $workflowFiles) {
        $relativeWorkflow = [System.IO.Path]::GetRelativePath($Root, $file.FullName)
        $workflowText = [System.IO.File]::ReadAllText($file.FullName)
        if ($workflowText -match 'git push' -and $workflowText -notmatch 'persist-credentials:\s*false') {
            $errors.Add("${relativeWorkflow}: pushes with git but never checks out with persist-credentials: false. " +
                'Turn that off and push with an explicit token.')
        }
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        $stepName = '<unnamed>'
        $isPwsh = $false
        $inRun = $false
        $runIndent = -1
        $runStart = 0
        $blockLines = New-Object System.Collections.Generic.List[string]

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $indent = $line.Length - $line.TrimStart(' ').Length
            $trimmed = $line.Trim()

            if ($inRun) {
                if ($trimmed.Length -gt 0 -and $indent -le $runIndent) {
                    $blockArgs = @{
                        Problems   = $errors
                        BlockLines = $blockLines
                        Label      = "$relativeWorkflow step '$stepName' run block starting line $runStart"
                        GhaPattern = $ghaPattern
                    }
                    Add-RunBlockProblem @blockArgs
                    $blockLines.Clear()
                    $inRun = $false
                } else {
                    $blockLines.Add($line)
                    continue
                }
            }

            if ($trimmed -match '^- name:\s*(.+?)\s*$') {
                $stepName = $Matches[1]
                $isPwsh = $false
                continue
            }
            if ($trimmed -match '^shell:\s*(.+?)\s*$') {
                $isPwsh = ($Matches[1] -eq 'pwsh')
                continue
            }
            if ($isPwsh -and $trimmed -match '^run:\s*\|\s*$') {
                $inRun = $true
                $runIndent = $indent
                $runStart = $i + 1
                $blockLines.Clear()
            }
        }
        if ($inRun) {
            $blockArgs = @{
                Problems   = $errors
                BlockLines = $blockLines
                Label      = "$relativeWorkflow step '$stepName' run block starting line $runStart"
                GhaPattern = $ghaPattern
            }
            Add-RunBlockProblem @blockArgs
        }
    }
}

if ($errors.Count -gt 0) {
    Write-Host '::error::Workflow and PowerShell problems:'
    foreach ($err in $errors) { Write-Host "  $err" }
    Write-Host "::error::Found $($errors.Count) problem(s)."
    exit 1
}

Write-Host "Parsed $($tracked.Count) tracked script(s) and the inline pwsh blocks under .github/workflows cleanly."
exit 0
