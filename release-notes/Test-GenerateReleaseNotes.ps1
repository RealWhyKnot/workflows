#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:failures = 0

function Assert-Contains {
    param([string] $Text, [string] $Needle, [string] $Because)
    if ($Text -notmatch [regex]::Escape($Needle)) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      expected to find: $Needle"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

function Assert-NotContains {
    param([string] $Text, [string] $Needle, [string] $Because)
    if ($Text -match [regex]::Escape($Needle)) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      did not expect: $Needle"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

$generator = Join-Path $PSScriptRoot 'Generate-ReleaseNotes.ps1'
. (Join-Path $PSScriptRoot 'AuthorCredit.ps1')

function Assert-Equal {
    param([string] $Actual, [string] $Expected, [string] $Because)
    if ($Actual -ne $Expected) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

Assert-Equal (Get-AuthorCredit -Login 'RealWhyKnot' -Name 'WhyKnot') '[RealWhyKnot](https://github.com/RealWhyKnot)' 'a login is credited as a profile link, never a bare @mention'
Assert-Equal (Get-AuthorCredit -Login 'benaclejames' -Name 'Ben Thomas') '[benaclejames](https://github.com/benaclejames)' 'an outside author is credited the same way, with no mention'
Assert-Equal (Get-AuthorCredit -Login '' -Name 'Test Person') 'Test Person' 'a commit with no login is credited by name alone'
Assert-Equal (Get-AuthorCredit -Login 'dependabot[bot]' -Name 'dependabot[bot]') 'dependabot[bot]' 'a bot is named in plain text, because its login is not a profile path'
Assert-Equal (Get-AuthorCredit -Login 'github-actions[bot]' -Name 'github-actions[bot]') 'github-actions[bot]' 'the actions bot is named the same way'

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("relnotes-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $sandbox | Out-Null
Push-Location $sandbox
try {
    git init --quiet --initial-branch=main
    git config user.email 'test@example.invalid'
    git config user.name 'Test Person'
    git config commit.gpgsign false

    function New-Commit {
        param([string] $Subject)
        $name = [System.Guid]::NewGuid().ToString('N')
        Set-Content -LiteralPath (Join-Path $sandbox $name) -Value $name
        git add -A
        git commit --quiet -m $Subject
    }

    New-Commit 'feat: the first thing'
    git tag v2026.1.1.0
    New-Commit 'fix(scope): repair the thing (2026.1.2.0-AB12)'
    New-Commit 'feat!: a breaking change'
    New-Commit 'chore: tidy up'
    New-Commit 'docs(changelog): auto-append entries [skip changelog]'
    New-Commit 'Not a conventional subject'
    git tag v2026.1.2.0

    $body = & $generator -Tag v2026.1.2.0 -Repository '' -Title 'Sample v2026.1.2.0' | Out-String

    Assert-Contains $body '# Sample v2026.1.2.0' 'the title is rendered'
    Assert-Contains $body '### Breaking Changes' 'a type!: subject lands in Breaking Changes'
    Assert-Contains $body '### Bug Fixes' 'fix lands in Bug Fixes'
    Assert-Contains $body '### Chores' 'chore lands in Chores'
    Assert-Contains $body '### Other' 'a non-conventional subject lands in Other'
    Assert-Contains $body 'by Test Person in' 'the author is credited from git when there is no API'
    Assert-NotContains $body '[skip changelog]' 'skip-changelog commits are dropped'
    Assert-NotContains $body '(2026.1.2.0-AB12)' 'the CalVer build stamp is stripped'
    Assert-NotContains $body 'the first thing' 'commits before the previous tag are excluded'

    Set-Content -LiteralPath (Join-Path $sandbox 'release-notes.txt') -Value 'x'
    New-Commit 'fix: between the stable and the beta'
    git tag v2026.1.2.1-beta
    New-Commit 'feat: after the beta'
    git tag v2026.1.3.0
    $stable = & $generator -Tag v2026.1.3.0 -Repository '' | Out-String
    Assert-Contains $stable 'between the stable and the beta' 'stable notes skip past betas even when a checkout file contains a hyphen'

    $crlfMessage = Join-Path $sandbox 'crlf-message.txt'
    [System.IO.File]::WriteAllText($crlfMessage, "fix: a subject written with CRLF (2026.1.4.0-CD34)`r`n`r`nA body line.`r`n")
    git commit --quiet --allow-empty --cleanup=verbatim -F $crlfMessage
    git tag v2026.1.4.0
    $crlfOut = Join-Path $sandbox 'crlf-notes.md'
    & $generator -Tag v2026.1.4.0 -Repository '' -OutFile $crlfOut | Out-Null
    $crlf = [System.IO.File]::ReadAllText($crlfOut)
    Assert-Contains $crlf '- fix: a subject written with CRLF by Test Person in' 'a CRLF subject from git loses its stamp and its carriage return'
    Assert-NotContains $crlf "`r" 'no carriage return reaches the notes from git'

    $global:ghFixture = @{
        commits = @(
            @{ sha = '67f9ddc0000000000000000000000000000000ff'; author = @{ login = 'RealWhyKnot' }; commit = @{ author = @{ name = 'WhyKnot' }; message = "fix(http): cap each request (2026.10.9.0-1528)`r`n`r`nBody.`r`n" }; parents = @(@{}) }
            @{ sha = '38a1e5d0000000000000000000000000000000ff'; author = @{ login = 'RealWhyKnot' }; commit = @{ author = @{ name = 'WhyKnot' }; message = "feat: an LF subject (2026.10.9.0-1528)`n`nBody.`n" }; parents = @(@{}) }
        )
    } | ConvertTo-Json -Depth 6
    $global:ghCalled = $false
    function gh {
        $global:ghCalled = $true
        $query = $args[[array]::IndexOf($args, '--jq') + 1]
        $global:ghFixture | jq -r $query
    }
    $apiOut = Join-Path $sandbox 'api-notes.md'
    & $generator -Tag v2026.1.4.0 -PreviousTag v2026.1.3.0 -Repository 'RealWhyKnot/sample' -OutFile $apiOut | Out-Null
    Remove-Item function:gh
    $apiCalled = $global:ghCalled
    Remove-Variable -Scope Global -Name ghFixture, ghCalled
    $api = [System.IO.File]::ReadAllText($apiOut)
    Assert-Equal "$apiCalled" 'True' 'the API path is taken when a repository is given'
    Assert-Contains $api '- fix(http): cap each request by [RealWhyKnot](https://github.com/RealWhyKnot) in 67f9ddc' 'a CRLF subject from the API loses its stamp'
    Assert-Contains $api '- feat: an LF subject by [RealWhyKnot](https://github.com/RealWhyKnot) in 38a1e5d' 'an LF subject from the API still loses its stamp'
    Assert-NotContains $api '\r' 'no escaped carriage return reaches the notes from the API'
    Assert-NotContains $api '(2026.10.9.0-1528)' 'no build stamp survives in API notes'

    $unicode = "caf$([char]0xE9) menu $([char]0x2014) SteamVR$([char]0x2019)s $([char]0x30C8)$([char]0x30E9)$([char]0x30C3)$([char]0x30AB)$([char]0x30FC)"
    New-Commit "feat: $unicode"
    git tag v2026.1.5.0
    $consoleEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Latin1
    try {
        $unicodeOut = Join-Path $sandbox 'unicode-notes.md'
        & $generator -Tag v2026.1.5.0 -Repository '' -OutFile $unicodeOut | Out-Null
    } finally {
        $latin1Kept = [Console]::OutputEncoding.WebName
        [Console]::OutputEncoding = $consoleEncoding
    }
    Assert-Contains ([System.IO.File]::ReadAllText($unicodeOut)) "- feat: $unicode by Test Person in" 'a non-ASCII subject from git survives a console that is not UTF-8'
    Assert-Equal $latin1Kept 'iso-8859-1' 'the caller''s console encoding is put back afterwards'

    function ConvertTo-PageJson {
        param([object[]] $Commits, [switch] $Compare)
        if ($Compare) { return (@{ commits = $Commits } | ConvertTo-Json -Depth 6 -Compress) }
        return (ConvertTo-Json -InputObject $Commits -Depth 6 -Compress)
    }
    function New-ApiCommit {
        param([string] $Sha, [string] $Message)
        @{ sha = $Sha.PadRight(40, '0'); author = @{ login = 'RealWhyKnot' }; commit = @{ author = @{ name = 'WhyKnot' }; message = $Message }; parents = @(@{}) }
    }
    $pageOne = @(New-ApiCommit 'aaaaaaa1' "fix: page one $unicode")
    $pageTwo = @(New-ApiCommit 'bbbbbbb2' 'feat: page two')
    $global:ghPages = @{
        compare = @((ConvertTo-PageJson $pageOne -Compare), (ConvertTo-PageJson $pageTwo -Compare))
        list    = @((ConvertTo-PageJson $pageOne), (ConvertTo-PageJson $pageTwo))
    }
    $global:ghArgs = @()
    function gh {
        $global:ghArgs += , @($args)
        $query = $args[[array]::IndexOf($args, '--jq') + 1]
        $pages = if ("$($args[1])" -match '/compare/') { $global:ghPages.compare } else { $global:ghPages.list }
        if ($args -notcontains '--paginate') { $pages = @($pages[0]) }
        foreach ($page in $pages) { $page | jq -r $query }
    }
    [Console]::OutputEncoding = [System.Text.Encoding]::Latin1
    try {
        $compareOut = Join-Path $sandbox 'compare-notes.md'
        & $generator -Tag v2026.1.5.0 -PreviousTag v2026.1.4.0 -Repository 'RealWhyKnot/sample' -OutFile $compareOut | Out-Null
        $firstOut = Join-Path $sandbox 'first-notes.md'
        & $generator -Tag v2026.1.1.0 -Repository 'RealWhyKnot/sample' -OutFile $firstOut | Out-Null
    } finally {
        [Console]::OutputEncoding = $consoleEncoding
        Remove-Item function:gh
    }
    $listCalls = @($global:ghArgs | Where-Object { "$($_[1])" -match '/commits\?' })
    Remove-Variable -Scope Global -Name ghPages, ghArgs
    $compareNotes = [System.IO.File]::ReadAllText($compareOut)
    $firstNotes = [System.IO.File]::ReadAllText($firstOut)
    Assert-Contains $compareNotes "- fix: page one $unicode by" 'a non-ASCII subject from the API survives a console that is not UTF-8'
    Assert-Contains $compareNotes '- feat: page two by' 'the compare reads every page'
    Assert-Equal "$($listCalls.Count)" '1' 'a first release lists commits through the API'
    Assert-Contains $firstNotes '- feat: page two by' 'a first release reads every page of the commit list'
    Assert-Contains $firstNotes "- fix: page one $unicode by" 'a first release keeps non-ASCII subjects'

    New-Commit 'diag: log the tracker state on start'
    New-Commit 'style: reformat the settings window'
    git tag v2026.1.6.0
    $kinds = & $generator -Tag v2026.1.6.0 -Repository '' | Out-String
    Assert-Contains $kinds "### Changes`n- diag: log the tracker state on start" 'diag lands in Changes'
    Assert-Contains $kinds "### Chores`n- style: reformat the settings window" 'style lands in Chores'
    Assert-NotContains $kinds '### Other' 'diag and style no longer fall through to Other'

    function Invoke-ReleaseNotesAction {
        param([hashtable] $With, [string] $Temp)
        $yaml = [System.IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'action.yml'))
        $runAt = [array]::IndexOf($yaml, '      run: |')
        $envAt = [array]::IndexOf($yaml, '      env:')
        $expand = {
            param([string] $Text)
            [regex]::Replace($Text, '\$\{\{\s*([^}]+?)\s*\}\}', {
                param($m)
                $key = $m.Groups[1].Value
                if ($key -match '^inputs\.(.+)$') { return "$($With[$Matches[1]])" }
                if ($key -eq 'github.action_path') { return $PSScriptRoot }
                if ($key -eq 'runner.temp') { return $Temp }
                return ''
            })
        }
        $stepEnv = @{ GITHUB_OUTPUT = (Join-Path $Temp 'github-output') }
        for ($i = $envAt + 1; $i -lt $runAt -and $yaml[$i] -match '^        ([A-Z_]+): (.*)$'; $i++) {
            $stepEnv[$Matches[1]] = & $expand $Matches[2]
        }
        $script = New-Object System.Collections.Generic.List[string]
        $script.Add('$ErrorActionPreference = ''stop''')
        for ($i = $runAt + 1; $i -lt $yaml.Count -and ($yaml[$i] -eq '' -or $yaml[$i].StartsWith('        ')); $i++) {
            $script.Add((& $expand ($yaml[$i] -replace '^ {8}', '')))
        }
        $script.Add('if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }')
        $scriptPath = Join-Path $Temp 'step.ps1'
        [System.IO.File]::WriteAllText($scriptPath, ($script -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $saved = @{}
        foreach ($k in $stepEnv.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $stepEnv[$k])
        }
        try {
            & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command ". '$scriptPath'" *> (Join-Path $Temp 'step.log')
            return $LASTEXITCODE
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
    }

    $actionTemp = Join-Path $sandbox 'action-temp'
    New-Item -ItemType Directory -Force $actionTemp | Out-Null
    $marker = Join-Path $sandbox 'injected'
    $actionTitle = "TrackDoctor's $unicode"
    $actionExtra = "## Download`n`nNeeds SteamVR's driver folder. $unicode`n`n`$(New-Item -ItemType File '$marker')"
    $code = Invoke-ReleaseNotesAction -Temp $actionTemp -With @{ tag = 'v2026.1.6.0'; repository = ''; 'previous-tag' = ''; title = $actionTitle; extra = $actionExtra }
    $actionNotesPath = Join-Path $actionTemp 'release-notes.md'
    Assert-Equal "$code" '0' 'the action step runs with apostrophes and non-ASCII text in title and extra'
    $actionNotes = if (Test-Path $actionNotesPath) { [System.IO.File]::ReadAllText($actionNotesPath) } else { '' }
    Assert-Contains $actionNotes "# $actionTitle" 'the title reaches the notes unchanged'
    Assert-Contains $actionNotes "Needs SteamVR's driver folder. $unicode" 'the extra block reaches the notes unchanged'
    Assert-Contains $actionNotes '$(New-Item' 'a subexpression in extra stays literal text'
    $injectedTitle = "x'`$(New-Item -ItemType File '$marker')'"
    Remove-Item -LiteralPath $actionNotesPath -ErrorAction SilentlyContinue
    Invoke-ReleaseNotesAction -Temp $actionTemp -With @{ tag = 'v2026.1.6.0'; repository = ''; 'previous-tag' = ''; title = $injectedTitle; extra = '' } | Out-Null
    Assert-Equal "$(Test-Path $marker)" 'False' 'quotes in an input cannot run code in the step'
    $injectedNotes = if (Test-Path $actionNotesPath) { [System.IO.File]::ReadAllText($actionNotesPath) } else { '' }
    Assert-Contains $injectedNotes "# $injectedTitle" 'a quoted input reaches the notes as plain text'

    $extra =& $generator -Tag v2026.1.2.0 -Repository '' -Extra '## Downloads', '- a file' | Out-String
    Assert-Contains $extra '## Downloads' 'extra markdown is appended'

    $out = Join-Path $sandbox 'notes.md'
    & $generator -Tag v2026.1.2.0 -Repository '' -OutFile $out | Out-Null
    if (-not (Test-Path $out)) {
        Write-Host 'FAIL: -OutFile did not write a file' -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host 'ok: -OutFile writes the markdown'
        $raw = [System.IO.File]::ReadAllBytes($out)
        if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
            Write-Host 'FAIL: the notes file has a UTF-8 BOM' -ForegroundColor Red
            $script:failures++
        } else {
            Write-Host 'ok: the notes file has no BOM'
        }
    }
} finally {
    Pop-Location
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$script:failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
