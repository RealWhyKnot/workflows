#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function New-Run {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string] $Status = 'completed', [string] $Conclusion = 'success', [string] $RunEvent = 'push', [int] $Id = 1)
    [pscustomobject]@{
        id         = $Id
        status     = $Status
        conclusion = $Conclusion
        event      = $RunEvent
        html_url   = "https://example.test/runs/$Id"
    }
}

function New-Commit {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string] $Parent = '', [string] $Author = 'someone')
    $parents = @()
    if ($Parent) { $parents = @([pscustomobject]@{ sha = $Parent }) }
    [pscustomobject]@{
        parents   = $parents
        author    = [pscustomobject]@{ login = $Author }
        committer = [pscustomobject]@{ login = 'web-flow' }
    }
}

function Invoke-Wait {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable] $Runs,
        [hashtable] $Commits,
        [string] $Sha = 'c0',
        [int] $Timeout = 1,
        [int] $Grace = 0,
        [scriptblock] $Change = $null
    )
    $state = @{ Minutes = 0.0; Runs = $Runs; Commits = $Commits; Change = $Change }
    $api = {
        param([string] $Path)
        if ($Path -match 'head_sha=([^&]+)') {
            $list = $state.Runs[$Matches[1]]
            if ($null -eq $list) { $list = @() }
            return [pscustomobject]@{ workflow_runs = @($list) }
        }
        if ($Path -match '/commits/(.+)$') { return $state.Commits[$Matches[1]] }
        return $null
    }.GetNewClosure()
    $clock = {
        param([int] $Sleep)
        if ($Sleep -gt 0) {
            $state.Minutes += 0.5
            if ($state.Change) { & $state.Change $state }
        }
        return $state.Minutes
    }.GetNewClosure()
    $out = Join-Path ([System.IO.Path]::GetTempPath()) ('wait-for-ci-' + [System.Guid]::NewGuid().ToString('N'))
    $waitArgs = @{
        Sha            = $Sha
        Repository     = $script:repo
        TimeoutMinutes = $Timeout
        GraceMinutes   = $Grace
        PollSeconds    = 1
        Api            = $api
        Clock          = $clock
        OutputPath     = $out
    }
    $text = @(foreach ($line in (& $script:waiter @waitArgs *>&1)) { "$line" }) -join "`n"
    $code = $LASTEXITCODE
    $outputs = if (Test-Path $out) { [System.IO.File]::ReadAllText($out) } else { '' }
    Remove-Item $out -ErrorAction SilentlyContinue
    return @{ Code = $code; Text = $text; Outputs = $outputs }
}

function Assert-Wait {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Name, [hashtable] $Result, [int] $Code, [string] $Contains = '')
    if ($Result.Code -ne $Code) {
        Write-Host "FAIL  ${Name}: exit $($Result.Code), expected $Code"
        Write-Host "        $($Result.Text)"
        $script:failures++
        return
    }
    if ($Contains -and ($Result.Text + $Result.Outputs) -notmatch [regex]::Escape($Contains)) {
        Write-Host "FAIL  ${Name}: missing '$Contains'"
        Write-Host "        $($Result.Text)"
        $script:failures++
        return
    }
    Write-Host "ok    $Name"
}

$script:waiter = Join-Path $PSScriptRoot 'Wait-ForCi.ps1'
$script:failures = 0
$script:repo = 'o/r'

$r = Invoke-Wait -Runs @{ c0 = @(New-Run) } -Commits @{ c0 = New-Commit -Parent 'c1' }
Assert-Wait -Name 'a passing run on the commit passes' -Result $r -Code 0 -Contains 'sha=c0'

$r = Invoke-Wait -Runs @{ c0 = @(New-Run -Conclusion 'failure') } -Commits @{ c0 = New-Commit -Parent 'c1' }
Assert-Wait -Name 'a failed run fails' -Result $r -Code 1 -Contains 'did not pass on c0'

$r = Invoke-Wait -Runs @{ c0 = @(New-Run -Conclusion 'failure'); c1 = @(New-Run) } -Commits @{
    c0 = New-Commit -Parent 'c1'; c1 = New-Commit -Parent 'c2'
}
Assert-Wait -Name 'a failed run is not rescued by a passing ancestor' -Result $r -Code 1

$r = Invoke-Wait -Runs @{ c0 = @((New-Run -Conclusion 'failure' -Id 1), (New-Run -Id 2)) } -Commits @{
    c0 = New-Commit -Parent 'c1'
}
Assert-Wait -Name 'a re-run that passed counts even after a failed attempt' -Result $r -Code 0 -Contains 'runs/2'

$r = Invoke-Wait -Runs @{ c0 = @(New-Run -RunEvent 'pull_request') } -Commits @{ c0 = New-Commit } -Timeout 0
Assert-Wait -Name 'pull request runs are ignored' -Result $r -Code 1

$r = Invoke-Wait -Runs @{ c1 = @(New-Run) } -Commits @{
    c0 = (New-Commit -Parent 'c1' -Author 'github-actions[bot]'); c1 = New-Commit -Parent 'c2'
} -Grace 5 -Timeout 0
Assert-Wait -Name 'a bot commit with no run falls back to its parent at once' -Result $r -Code 0 -Contains 'sha=c1'

$r = Invoke-Wait -Runs @{ c1 = @(New-Run) } -Commits @{
    c0 = New-Commit -Parent 'c1'; c1 = New-Commit -Parent 'c2'
} -Grace 5 -Timeout 1
Assert-Wait -Name 'a human commit with no run waits out the grace period first' -Result $r -Code 1 -Contains (
    'No ci.yml run on c0 yet')

$r = Invoke-Wait -Runs @{ c2 = @(New-Run) } -Commits @{
    c0 = New-Commit -Parent 'c1'; c1 = New-Commit -Parent 'c2'; c2 = New-Commit -Parent 'c3'
} -Grace 0
Assert-Wait -Name 'after the grace period the nearest ancestor with a run decides' -Result $r -Code 0 -Contains 'sha=c2'

$r = Invoke-Wait -Runs @{ c1 = @(New-Run -Conclusion 'failure') } -Commits @{
    c0 = New-Commit -Parent 'c1'; c1 = New-Commit -Parent 'c2'
}
Assert-Wait -Name 'a failing ancestor fails the check' -Result $r -Code 1 -Contains 'did not pass on c1'

$r = Invoke-Wait -Runs @{} -Commits @{ c0 = New-Commit -Parent 'c1'; c1 = New-Commit }
Assert-Wait -Name 'running out of history fails' -Result $r -Code 1 -Contains 'No ci.yml run'

$r = Invoke-Wait -Runs @{ c0 = @(New-Run -Status 'in_progress' -Conclusion '') } -Commits @{
    c0 = New-Commit -Parent 'c1'
} -Timeout 5 -Change {
    param([hashtable] $s)
    if ($s.Minutes -ge 1) { $s.Runs['c0'] = @(New-Run) }
}
Assert-Wait -Name 'a run still going is waited on until it passes' -Result $r -Code 0 -Contains 'sha=c0'

$r = Invoke-Wait -Runs @{ c0 = @(New-Run -Status 'in_progress' -Conclusion '') } -Commits @{
    c0 = New-Commit -Parent 'c1'
} -Timeout 1
Assert-Wait -Name 'a run still going past the timeout fails' -Result $r -Code 1 -Contains 'Gave up after 1 minutes'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed."; exit 1 }
Write-Host "`nAll checks passed."
exit 0
