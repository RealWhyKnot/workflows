#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:waiter = Join-Path $PSScriptRoot 'Wait-ForCi.ps1'
$script:failures = 0
$repo = 'o/r'

function New-Run {
    param([string] $Status = 'completed', [string] $Conclusion = 'success', [string] $Event = 'push', [int] $Id = 1)
    [pscustomobject]@{ id = $Id; status = $Status; conclusion = $Conclusion; event = $Event; html_url = "https://example.test/runs/$Id" }
}

function New-Commit {
    param([string] $Parent = '', [string] $Author = 'someone')
    $parents = @()
    if ($Parent) { $parents = @([pscustomobject]@{ sha = $Parent }) }
    [pscustomobject]@{ parents = $parents; author = [pscustomobject]@{ login = $Author }; committer = [pscustomobject]@{ login = 'web-flow' } }
}

function Invoke-Wait {
    param([hashtable] $Runs, [hashtable] $Commits, [string] $Sha = 'c0', [int] $Timeout = 1, [int] $Grace = 0, [scriptblock] $Change = $null)
    $state = @{ Minutes = 0.0; Runs = $Runs }
    $api = {
        param([string] $Path)
        if ($Path -match 'head_sha=([^&]+)') {
            $list = $state.Runs[$Matches[1]]
            if ($null -eq $list) { $list = @() }
            return [pscustomobject]@{ workflow_runs = @($list) }
        }
        if ($Path -match '/commits/(.+)$') { return $Commits[$Matches[1]] }
        return $null
    }.GetNewClosure()
    $clock = {
        param([int] $Sleep)
        if ($Sleep -gt 0) {
            $state.Minutes += 0.5
            if ($Change) { & $Change $state }
        }
        return $state.Minutes
    }.GetNewClosure()
    $out = Join-Path ([System.IO.Path]::GetTempPath()) ("wait-for-ci-" + [System.Guid]::NewGuid().ToString('N'))
    $text = ((& $script:waiter -Sha $Sha -Repository $repo -TimeoutMinutes $Timeout -GraceMinutes $Grace -PollSeconds 1 -Api $api -Clock $clock -OutputPath $out *>&1) | ForEach-Object { "$_" }) -join "`n"
    $code = $LASTEXITCODE
    $outputs = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    Remove-Item $out -ErrorAction SilentlyContinue
    return @{ Code = $code; Text = $text; Outputs = $outputs }
}

function Assert-Wait {
    param([string] $Name, [hashtable] $Result, [int] $Code, [string] $Contains = '')
    if ($Result.Code -ne $Code) {
        Write-Host "FAIL  ${Name}: exit $($Result.Code), expected $Code"; Write-Host "        $($Result.Text)"; $script:failures++; return
    }
    if ($Contains -and ($Result.Text + $Result.Outputs) -notmatch [regex]::Escape($Contains)) {
        Write-Host "FAIL  ${Name}: missing '$Contains'"; Write-Host "        $($Result.Text)"; $script:failures++; return
    }
    Write-Host "ok    $Name"
}

Assert-Wait 'a passing run on the commit passes' `
    (Invoke-Wait -Runs @{ c0 = @(New-Run) } -Commits @{ c0 = New-Commit 'c1' }) 0 'sha=c0'

Assert-Wait 'a failed run fails' `
    (Invoke-Wait -Runs @{ c0 = @(New-Run -Conclusion 'failure') } -Commits @{ c0 = New-Commit 'c1' }) 1 'did not pass on c0'

Assert-Wait 'a failed run is not rescued by a passing ancestor' `
    (Invoke-Wait -Runs @{ c0 = @(New-Run -Conclusion 'failure'); c1 = @(New-Run) } -Commits @{ c0 = New-Commit 'c1'; c1 = New-Commit 'c2' }) 1

Assert-Wait 'a re-run that passed counts even after a failed attempt' `
    (Invoke-Wait -Runs @{ c0 = @((New-Run -Conclusion 'failure' -Id 1), (New-Run -Id 2)) } -Commits @{ c0 = New-Commit 'c1' }) 0 'runs/2'

Assert-Wait 'pull request runs are ignored' `
    (Invoke-Wait -Runs @{ c0 = @(New-Run -Event 'pull_request') } -Commits @{ c0 = New-Commit } -Timeout 0) 1

Assert-Wait 'a bot commit with no run falls back to its parent at once' `
    (Invoke-Wait -Runs @{ c1 = @(New-Run) } -Commits @{ c0 = (New-Commit 'c1' 'github-actions[bot]'); c1 = New-Commit 'c2' } -Grace 5 -Timeout 0) 0 'sha=c1'

Assert-Wait 'a human commit with no run waits out the grace period first' `
    (Invoke-Wait -Runs @{ c1 = @(New-Run) } -Commits @{ c0 = New-Commit 'c1'; c1 = New-Commit 'c2' } -Grace 5 -Timeout 1) 1 'No ci.yml run on c0 yet'

Assert-Wait 'after the grace period the nearest ancestor with a run decides' `
    (Invoke-Wait -Runs @{ c2 = @(New-Run) } -Commits @{ c0 = New-Commit 'c1'; c1 = New-Commit 'c2'; c2 = New-Commit 'c3' } -Grace 0) 0 'sha=c2'

Assert-Wait 'a failing ancestor fails the check' `
    (Invoke-Wait -Runs @{ c1 = @(New-Run -Conclusion 'failure') } -Commits @{ c0 = New-Commit 'c1'; c1 = New-Commit 'c2' }) 1 'did not pass on c1'

Assert-Wait 'running out of history fails' `
    (Invoke-Wait -Runs @{} -Commits @{ c0 = New-Commit 'c1'; c1 = New-Commit }) 1 'No ci.yml run'

Assert-Wait 'a run still going is waited on until it passes' `
    (Invoke-Wait -Runs @{ c0 = @(New-Run -Status 'in_progress' -Conclusion '') } -Commits @{ c0 = New-Commit 'c1' } -Timeout 5 -Change {
        param($s)
        if ($s.Minutes -ge 1) { $s.Runs['c0'] = @(New-Run) }
    }) 0 'sha=c0'

Assert-Wait 'a run still going past the timeout fails' `
    (Invoke-Wait -Runs @{ c0 = @(New-Run -Status 'in_progress' -Conclusion '') } -Commits @{ c0 = New-Commit 'c1' } -Timeout 1) 1 'Gave up after 1 minutes'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
