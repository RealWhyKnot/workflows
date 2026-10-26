#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Sha,
    [Parameter(Mandatory = $true)]
    [string] $Repository,
    [string] $Workflow = 'ci.yml',
    [int] $TimeoutMinutes = 20,
    [int] $GraceMinutes = 3,
    [int] $MaxDepth = 30,
    [int] $PollSeconds = 30,
    [scriptblock] $Api = $null,
    [scriptblock] $Clock = $null,
    [string] $OutputPath = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Api) {
    $Api = {
        param([string] $Path)
        $json = & gh api $Path 2>$null
        $ok = $LASTEXITCODE -eq 0
        $global:LASTEXITCODE = 0
        if (-not $ok) { return $null }
        return ($json | Out-String | ConvertFrom-Json)
    }
}
if (-not $Clock) {
    $script:started = [datetime]::UtcNow
    $Clock = {
        param([int] $Sleep)
        if ($Sleep -gt 0) { Start-Sleep -Seconds $Sleep }
        return ([datetime]::UtcNow - $script:started).TotalMinutes
    }
}

function Set-Output {
    param([hashtable] $Values)
    foreach ($k in $Values.Keys) {
        if ($OutputPath) { Add-Content -LiteralPath $OutputPath -Value "$k=$($Values[$k])" }
    }
}

function Get-Runs {
    param([string] $Commit)
    $page = & $Api "repos/$Repository/actions/workflows/$Workflow/runs?head_sha=$Commit&per_page=100"
    if ($null -eq $page) { return $null }
    return , @($page.workflow_runs | Where-Object { $_.event -ne 'pull_request' })
}

function Get-Commit {
    param([string] $Commit)
    return (& $Api "repos/$Repository/commits/$Commit")
}

function Test-BotCommit {
    param($Info)
    foreach ($who in @($Info.author, $Info.committer)) {
        if ($who -and ($who.PSObject.Properties.Name -contains 'login') -and "$($who.login)" -match '\[bot\]$') { return $true }
    }
    return $false
}

function Get-Verdict {
    param([double] $Elapsed)
    $commit = $Sha
    $skipped = @()
    for ($depth = 0; $depth -le $MaxDepth; $depth++) {
        $runs = Get-Runs -Commit $commit
        if ($null -eq $runs) { return @{ State = 'wait'; Reason = "Could not list $Workflow runs for $commit." } }
        if ($runs.Count -gt 0) {
            $passed = @($runs | Where-Object { $_.status -eq 'completed' -and $_.conclusion -eq 'success' })
            if ($passed.Count -gt 0) {
                return @{ State = 'pass'; Commit = $commit; Run = $passed[0]; Skipped = $skipped }
            }
            $running = @($runs | Where-Object { $_.status -ne 'completed' })
            if ($running.Count -gt 0) {
                return @{ State = 'wait'; Reason = "$Workflow is still running on $commit ($($running.Count) run(s))." }
            }
            $summary = ($runs | ForEach-Object { "run $($_.id) $($_.conclusion)" }) -join ', '
            return @{ State = 'fail'; Reason = "$Workflow did not pass on $commit ($summary)." }
        }
        $info = Get-Commit -Commit $commit
        if ($null -eq $info) { return @{ State = 'wait'; Reason = "Could not read commit $commit." } }
        if ($depth -eq 0 -and $Elapsed -lt $GraceMinutes -and -not (Test-BotCommit $info)) {
            return @{ State = 'wait'; Reason = "No $Workflow run on $commit yet." }
        }
        $parents = @($info.parents)
        if ($parents.Count -eq 0) { break }
        $skipped += $commit
        $commit = $parents[0].sha
    }
    return @{ State = 'fail'; Reason = "No $Workflow run on $Sha or its last $MaxDepth first-parent ancestors." }
}

$elapsed = & $Clock 0
while ($true) {
    $verdict = Get-Verdict -Elapsed $elapsed
    if ($verdict.State -eq 'pass') {
        $run = $verdict.Run
        if ($verdict.Skipped.Count -gt 0) {
            Write-Host "No $Workflow run on $($verdict.Skipped -join ', '). Those pushes didn't start one, so the nearest run counts."
        }
        Write-Host "$Workflow passed on $($verdict.Commit): $($run.html_url)"
        Set-Output @{ sha = $verdict.Commit; 'run-url' = $run.html_url }
        exit 0
    }
    if ($verdict.State -eq 'fail') {
        Write-Host "::error::$($verdict.Reason) Fix it or re-run $Workflow on that commit, then run this again."
        exit 1
    }
    if ($elapsed -ge $TimeoutMinutes) {
        Write-Host "::error::Gave up after $TimeoutMinutes minutes. $($verdict.Reason)"
        exit 1
    }
    Write-Host $verdict.Reason
    $elapsed = & $Clock $PollSeconds
}
