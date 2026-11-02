#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PwshRunBlock {
    [CmdletBinding()]
    [OutputType([array])]
    param([string[]] $Lines = @())

    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        if ($Lines[$lineIndex] -notmatch '^(\s*)run:\s*\|\s*$') { continue }
        $indent = $Matches[1].Length
        $body = [System.Collections.Generic.List[object]]::new()
        for ($bodyIndex = $lineIndex + 1; $bodyIndex -lt $Lines.Count; $bodyIndex++) {
            $line = $Lines[$bodyIndex]
            if ($line.Trim() -eq '') {
                $body.Add([pscustomobject]@{ Number = $bodyIndex + 1; Text = '' })
                continue
            }
            $lead = $line.Length - $line.TrimStart().Length
            if ($lead -le $indent) { break }
            $body.Add([pscustomobject]@{ Number = $bodyIndex + 1; Text = $line })
        }
        , $body.ToArray()
    }
}

$workflowDir = Join-Path $PSScriptRoot 'workflows'
$failures = [System.Collections.Generic.List[string]]::new()
$checked = 0

foreach ($workflow in @(Get-ChildItem -LiteralPath $workflowDir -Filter '*.yml' | Sort-Object -Property Name)) {
    $lines = [System.IO.File]::ReadAllLines($workflow.FullName)
    foreach ($block in Get-PwshRunBlock -Lines $lines) {
        for ($statementIndex = 0; $statementIndex -lt $block.Count; $statementIndex++) {
            if ($block[$statementIndex].Text -notmatch '^\s*&\s*\$') { continue }
            $checked++
            $previous = if ($statementIndex -gt 0) { $block[$statementIndex - 1].Text.Trim() } else { '' }
            if ($previous -ne '$global:LASTEXITCODE = 0') {
                $where = "$($workflow.Name):$($block[$statementIndex].Number)"
                $failures.Add("$where invokes a script without resetting `$global:LASTEXITCODE first.")
            }
        }
    }
}

$probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('exitcode-guard-' + [System.Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $probeDir -Force
try {
    $quiet = Join-Path $probeDir 'quiet.ps1'
    [System.IO.File]::WriteAllText($quiet, "Write-Host 'no native command ran'`n")
    $verdict = "if (`$LASTEXITCODE -ne 0) { 'throws' } else { 'passes' }"

    $unguarded = pwsh -NoProfile -Command "& '$quiet'; $verdict"
    if ($LASTEXITCODE -ne 0) { throw "The unguarded probe failed with exit code $LASTEXITCODE" }
    if ($unguarded -notcontains 'throws') {
        $failures.Add("Probe: expected an unguarded invocation to see a null `$LASTEXITCODE, got '$unguarded'.")
    }

    $guarded = pwsh -NoProfile -Command "`$global:LASTEXITCODE = 0; & '$quiet'; $verdict"
    if ($LASTEXITCODE -ne 0) { throw "The guarded probe failed with exit code $LASTEXITCODE" }
    if ($guarded -notcontains 'passes') {
        $failures.Add("Probe: expected a guarded invocation to pass, got '$guarded'.")
    }
} finally {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($checked -eq 0) {
    throw 'No script invocations found in the workflow pwsh blocks. The check would pass by finding nothing.'
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "  $failure" }
    throw "$($failures.Count) exit-code guard failure(s)."
}

Write-Host "Checked $checked script invocation(s) across the workflow pwsh blocks."
exit 0
