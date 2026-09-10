#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workflowDir = Join-Path $PSScriptRoot 'workflows'
$failures = @()
$checked = 0

function Get-PwshRunBlocks {
    param([string[]] $Lines)

    $blocks = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^(\s*)run:\s*\|\s*$') { continue }
        $indent = $Matches[1].Length
        $body = @()
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            $line = $Lines[$j]
            if ($line.Trim() -eq '') { $body += [pscustomobject]@{ Number = $j + 1; Text = '' }; continue }
            $lead = $line.Length - $line.TrimStart().Length
            if ($lead -le $indent) { break }
            $body += [pscustomobject]@{ Number = $j + 1; Text = $line }
        }
        $blocks += , $body
    }
    return $blocks
}

foreach ($workflow in @(Get-ChildItem -Path $workflowDir -Filter '*.yml' | Sort-Object Name)) {
    $lines = [System.IO.File]::ReadAllLines($workflow.FullName)
    foreach ($block in Get-PwshRunBlocks -Lines $lines) {
        for ($k = 0; $k -lt $block.Count; $k++) {
            if ($block[$k].Text -notmatch '^\s*&\s*\$') { continue }
            $checked++
            $previous = if ($k -gt 0) { $block[$k - 1].Text.Trim() } else { '' }
            if ($previous -ne '$global:LASTEXITCODE = 0') {
                $failures += "$($workflow.Name):$($block[$k].Number) invokes a script without resetting `$global:LASTEXITCODE first."
            }
        }
    }
}

$probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("exitcode-guard-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
try {
    $quiet = Join-Path $probeDir 'quiet.ps1'
    [System.IO.File]::WriteAllText($quiet, "Write-Host 'no native command ran'`n")

    $unguarded = pwsh -NoProfile -Command "& '$quiet'; if (`$LASTEXITCODE -ne 0) { 'throws' } else { 'passes' }"
    if ($unguarded -notcontains 'throws') {
        $failures += "Probe: expected an unguarded invocation to see a null `$LASTEXITCODE, got '$unguarded'."
    }

    $guarded = pwsh -NoProfile -Command "`$global:LASTEXITCODE = 0; & '$quiet'; if (`$LASTEXITCODE -ne 0) { 'throws' } else { 'passes' }"
    if ($guarded -notcontains 'passes') {
        $failures += "Probe: expected a guarded invocation to pass, got '$guarded'."
    }
} finally {
    Remove-Item -Path $probeDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($checked -eq 0) {
    throw 'No script invocations found in the workflow pwsh blocks. The check would pass by finding nothing.'
}

if ($failures) {
    foreach ($failure in $failures) { Write-Host "  $failure" }
    throw "$($failures.Count) exit-code guard failure(s)."
}

Write-Host "Checked $checked script invocation(s) across the workflow pwsh blocks."
exit 0
