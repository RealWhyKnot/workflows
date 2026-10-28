#!/usr/bin/env pwsh
#Requires -Version 7.4
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

function Set-Output {
    [CmdletBinding()]
    [OutputType([void])]
    param([hashtable] $Values, [string] $OutputPath)
    foreach ($k in $Values.Keys) {
        if ($OutputPath) {
            $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
            [System.IO.File]::AppendAllText($path, "$k=$($Values[$k])" + [Environment]::NewLine)
        }
    }
}

function Get-Run {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([scriptblock] $Api, [string] $Repository, [string] $Workflow, [string] $Commit)
    $page = & $Api "repos/$Repository/actions/workflows/$Workflow/runs?head_sha=$Commit&per_page=100"
    if ($null -eq $page) { return $null }
    return , @($page.workflow_runs | Where-Object { $_.event -ne 'pull_request' })
}

function Get-Commit {
    [CmdletBinding()]
    [OutputType([object])]
    param([scriptblock] $Api, [string] $Repository, [string] $Commit)
    return (& $Api "repos/$Repository/commits/$Commit")
}

function Test-BotCommit {
    [CmdletBinding()]
    [OutputType([bool])]
    param([object] $Info)
    foreach ($who in @($Info.author, $Info.committer)) {
        if ($who -and ($who.PSObject.Properties.Name -contains 'login') -and "$($who.login)" -match '\[bot\]$') {
            return $true
        }
    }
    return $false
}

function Get-Verdict {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [double] $Elapsed,
        [string] $Sha,
        [string] $Repository,
        [string] $Workflow,
        [int] $GraceMinutes,
        [int] $MaxDepth,
        [scriptblock] $Api
    )
    $commit = $Sha
    $skipped = [System.Collections.Generic.List[string]]::new()
    for ($depth = 0; $depth -le $MaxDepth; $depth++) {
        $runs = Get-Run -Api $Api -Repository $Repository -Workflow $Workflow -Commit $commit
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
            $summary = @(foreach ($run in $runs) { "run $($run.id) $($run.conclusion)" }) -join ', '
            return @{ State = 'fail'; Reason = "$Workflow did not pass on $commit ($summary)." }
        }
        $info = Get-Commit -Api $Api -Repository $Repository -Commit $commit
        if ($null -eq $info) { return @{ State = 'wait'; Reason = "Could not read commit $commit." } }
        if ($depth -eq 0 -and $Elapsed -lt $GraceMinutes -and -not (Test-BotCommit -Info $info)) {
            return @{ State = 'wait'; Reason = "No $Workflow run on $commit yet." }
        }
        $parents = @($info.parents)
        if ($parents.Count -eq 0) { break }
        $skipped.Add($commit)
        $commit = $parents[0].sha
    }
    return @{ State = 'fail'; Reason = "No $Workflow run on $Sha or its last $MaxDepth first-parent ancestors." }
}

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

$verdictArgs = @{
    Sha          = $Sha
    Repository   = $Repository
    Workflow     = $Workflow
    GraceMinutes = $GraceMinutes
    MaxDepth     = $MaxDepth
    Api          = $Api
}
$elapsed = & $Clock 0
while ($true) {
    $verdict = Get-Verdict -Elapsed $elapsed @verdictArgs
    if ($verdict.State -eq 'pass') {
        $run = $verdict.Run
        if ($verdict.Skipped.Count -gt 0) {
            Write-Host ("No $Workflow run on $($verdict.Skipped -join ', '). " +
                "Those pushes didn't start one, so the nearest run counts.")
        }
        Write-Host "$Workflow passed on $($verdict.Commit): $($run.html_url)"
        Set-Output -Values @{ sha = $verdict.Commit; 'run-url' = $run.html_url } -OutputPath $OutputPath
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
exit 0
