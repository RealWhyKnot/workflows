#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Substring {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Text, [string] $Needle, [string] $Because)
    if ($Text -notmatch [regex]::Escape($Needle)) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      expected to find: $Needle"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

function Assert-NoSubstring {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Text, [string] $Needle, [string] $Because)
    if ($Text -match [regex]::Escape($Needle)) {
        Write-Host "FAIL: $Because" -ForegroundColor Red
        Write-Host "      did not expect: $Needle"
        $script:failures++
        return
    }
    Write-Host "ok: $Because"
}

function Assert-Equal {
    [CmdletBinding()]
    [OutputType([void])]
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

function New-Commit {
    [CmdletBinding()]
    [OutputType([void])]
    param([string] $Subject)
    $name = [System.Guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText((Join-Path $script:sandbox $name), $name + [Environment]::NewLine)
    git add -A
    git commit --quiet -m $Subject
}

function ConvertTo-PageJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]] $Commits, [switch] $Compare)
    if ($Compare) { return (@{ commits = $Commits } | ConvertTo-Json -Depth 6 -Compress) }
    return (ConvertTo-Json -InputObject $Commits -Depth 6 -Compress)
}

function New-ApiCommit {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $Sha, [string] $Message)
    @{
        sha     = $Sha.PadRight(40, '0')
        author  = @{ login = 'RealWhyKnot' }
        commit  = @{ author = @{ name = 'WhyKnot' }; message = $Message }
        parents = @(@{})
    }
}

function gh {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
    $ghState.Called = $true
    $ghCallLog.Add(@($Rest))
    $query = $Rest[[array]::IndexOf($Rest, '--jq') + 1]
    if ($ghState.Mode -eq 'fixture') {
        $ghState.Fixture | jq -r $query
        return
    }
    $pages = if ("$($Rest[1])" -match '/compare/') { $ghState.Pages.compare } else { $ghState.Pages.list }
    if ($Rest -notcontains '--paginate') { $pages = @($pages[0]) }
    foreach ($page in $pages) { $page | jq -r $query }
}

function Expand-ActionExpression {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Text, [hashtable] $With, [string] $Temp)
    $result = [System.Text.StringBuilder]::new()
    $last = 0
    foreach ($m in [regex]::Matches($Text, '\$\{\{\s*([^}]+?)\s*\}\}')) {
        $null = $result.Append($Text, $last, $m.Index - $last)
        $key = $m.Groups[1].Value
        $value = if ($key -match '^inputs\.(.+)$') {
            "$($With[$Matches[1]])"
        } elseif ($key -eq 'github.action_path') {
            $PSScriptRoot
        } elseif ($key -eq 'runner.temp') {
            $Temp
        } else {
            ''
        }
        $null = $result.Append($value)
        $last = $m.Index + $m.Length
    }
    $null = $result.Append($Text, $last, $Text.Length - $last)
    return $result.ToString()
}

function Invoke-ReleaseNotesAction {
    [CmdletBinding()]
    [OutputType([int])]
    param([hashtable] $With, [string] $Temp)
    $yaml = [System.IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'action.yml'))
    $runAt = [array]::IndexOf($yaml, '      run: |')
    $envAt = [array]::IndexOf($yaml, '      env:')
    $stepEnv = @{ GITHUB_OUTPUT = (Join-Path $Temp 'github-output') }
    for ($i = $envAt + 1; $i -lt $runAt -and $yaml[$i] -match '^        ([A-Z_]+): (.*)$'; $i++) {
        $stepEnv[$Matches[1]] = Expand-ActionExpression -Text $Matches[2] -With $With -Temp $Temp
    }
    $script = New-Object System.Collections.Generic.List[string]
    $script.Add('$ErrorActionPreference = ''stop''')
    for ($i = $runAt + 1; $i -lt $yaml.Count -and ($yaml[$i] -eq '' -or $yaml[$i].StartsWith('        ')); $i++) {
        $script.Add((Expand-ActionExpression -Text ($yaml[$i] -replace '^ {8}', '') -With $With -Temp $Temp))
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
        $stepOutput = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command ". '$scriptPath'" *>&1)
        $stepCode = $LASTEXITCODE
        [System.IO.File]::WriteAllText((Join-Path $Temp 'step.log'), ($stepOutput -join [Environment]::NewLine))
        return $stepCode
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

$script:failures = 0
$generator = Join-Path $PSScriptRoot 'Generate-ReleaseNotes.ps1'
Import-Module (Join-Path $PSScriptRoot 'AuthorCredit.psm1')

$ghState = @{ Mode = ''; Called = $false; Fixture = ''; Pages = $null }
$ghCallLog = [System.Collections.Generic.List[object]]::new()

Assert-Equal -Actual (Get-AuthorCredit -Login 'RealWhyKnot' -Name 'WhyKnot') -Expected (
    '[RealWhyKnot](https://github.com/RealWhyKnot)'
) -Because 'a login is credited as a profile link, never a bare @mention'
Assert-Equal -Actual (Get-AuthorCredit -Login 'benaclejames' -Name 'Ben Thomas') -Expected (
    '[benaclejames](https://github.com/benaclejames)'
) -Because 'an outside author is credited the same way, with no mention'
Assert-Equal -Actual (Get-AuthorCredit -Login '' -Name 'Test Person') -Expected 'Test Person' -Because (
    'a commit with no login is credited by name alone')
Assert-Equal -Actual (Get-AuthorCredit -Login 'dependabot[bot]' -Name 'dependabot[bot]') -Expected (
    'dependabot[bot]'
) -Because 'a bot is named in plain text, because its login is not a profile path'
Assert-Equal -Actual (Get-AuthorCredit -Login 'github-actions[bot]' -Name 'github-actions[bot]') -Expected (
    'github-actions[bot]'
) -Because 'the actions bot is named the same way'

$script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('relnotes-' + [System.Guid]::NewGuid().ToString('N'))
$sandbox = $script:sandbox
$null = New-Item -ItemType Directory -Force -Path $sandbox
Push-Location $sandbox
try {
    git init --quiet --initial-branch=main
    git config user.email 'test@example.invalid'
    git config user.name 'Test Person'
    git config commit.gpgsign false

    New-Commit -Subject 'feat: the first thing'
    git tag v2026.1.1.0
    New-Commit -Subject 'fix(scope): repair the thing (2026.1.2.0-AB12)'
    New-Commit -Subject 'feat!: a breaking change'
    New-Commit -Subject 'chore: tidy up'
    New-Commit -Subject 'docs(changelog): auto-append entries [skip changelog]'
    New-Commit -Subject 'Not a conventional subject'
    git tag v2026.1.2.0

    $body = & $generator -Tag v2026.1.2.0 -Repository '' -Title 'Sample v2026.1.2.0' | Out-String

    Assert-Substring -Text $body -Needle '# Sample v2026.1.2.0' -Because 'the title is rendered'
    Assert-Substring -Text $body -Needle '### Breaking Changes' -Because 'a type!: subject lands in Breaking Changes'
    Assert-Substring -Text $body -Needle '### Bug Fixes' -Because 'fix lands in Bug Fixes'
    Assert-Substring -Text $body -Needle '### Chores' -Because 'chore lands in Chores'
    Assert-Substring -Text $body -Needle '### Other' -Because 'a non-conventional subject lands in Other'
    Assert-Substring -Text $body -Needle 'by Test Person in' -Because (
        'the author is credited from git when there is no API')
    Assert-NoSubstring -Text $body -Needle '[skip changelog]' -Because 'skip-changelog commits are dropped'
    Assert-NoSubstring -Text $body -Needle '(2026.1.2.0-AB12)' -Because 'the CalVer build stamp is stripped'
    Assert-NoSubstring -Text $body -Needle 'the first thing' -Because 'commits before the previous tag are excluded'

    [System.IO.File]::WriteAllText((Join-Path $sandbox 'release-notes.txt'), 'x' + [Environment]::NewLine)
    New-Commit -Subject 'fix: between the stable and the beta'
    git tag v2026.1.2.1-beta
    New-Commit -Subject 'feat: after the beta'
    git tag v2026.1.3.0
    $stable = & $generator -Tag v2026.1.3.0 -Repository '' | Out-String
    Assert-Substring -Text $stable -Needle 'between the stable and the beta' -Because (
        'stable notes skip past betas even when a checkout file contains a hyphen')

    $crlfMessage = Join-Path $sandbox 'crlf-message.txt'
    [System.IO.File]::WriteAllText(
        $crlfMessage, "fix: a subject written with CRLF (2026.1.4.0-CD34)`r`n`r`nA body line.`r`n")
    git commit --quiet --allow-empty --cleanup=verbatim -F $crlfMessage
    git tag v2026.1.4.0
    $crlfOut = Join-Path $sandbox 'crlf-notes.md'
    $null = & $generator -Tag v2026.1.4.0 -Repository '' -OutFile $crlfOut
    $crlf = [System.IO.File]::ReadAllText($crlfOut)
    Assert-Substring -Text $crlf -Needle '- fix: a subject written with CRLF by Test Person in' -Because (
        'a CRLF subject from git loses its stamp and its carriage return')
    Assert-NoSubstring -Text $crlf -Needle "`r" -Because 'no carriage return reaches the notes from git'

    $ghState.Fixture = @{
        commits = @(
            @{
                sha     = '67f9ddc0000000000000000000000000000000ff'
                author  = @{ login = 'RealWhyKnot' }
                commit  = @{
                    author  = @{ name = 'WhyKnot' }
                    message = "fix(http): cap each request (2026.10.9.0-1528)`r`n`r`nBody.`r`n"
                }
                parents = @(@{})
            }
            @{
                sha     = '38a1e5d0000000000000000000000000000000ff'
                author  = @{ login = 'RealWhyKnot' }
                commit  = @{
                    author  = @{ name = 'WhyKnot' }
                    message = "feat: an LF subject (2026.10.9.0-1528)`n`nBody.`n"
                }
                parents = @(@{})
            }
        )
    } | ConvertTo-Json -Depth 6
    $ghState.Mode = 'fixture'
    $ghState.Called = $false
    $apiOut = Join-Path $sandbox 'api-notes.md'
    $null = & $generator -Tag v2026.1.4.0 -PreviousTag v2026.1.3.0 -Repository 'RealWhyKnot/sample' -OutFile $apiOut
    $apiCalled = $ghState.Called
    $api = [System.IO.File]::ReadAllText($apiOut)
    Assert-Equal -Actual "$apiCalled" -Expected 'True' -Because 'the API path is taken when a repository is given'
    Assert-Substring -Text $api -Needle (
        '- fix(http): cap each request by [RealWhyKnot](https://github.com/RealWhyKnot) in 67f9ddc'
    ) -Because 'a CRLF subject from the API loses its stamp'
    Assert-Substring -Text $api -Needle (
        '- feat: an LF subject by [RealWhyKnot](https://github.com/RealWhyKnot) in 38a1e5d'
    ) -Because 'an LF subject from the API still loses its stamp'
    Assert-NoSubstring -Text $api -Needle '\r' -Because 'no escaped carriage return reaches the notes from the API'
    Assert-NoSubstring -Text $api -Needle '(2026.10.9.0-1528)' -Because 'no build stamp survives in API notes'

    $unicode = "caf$([char]0xE9) menu $([char]0x2014) SteamVR$([char]0x2019)s " +
    "$([char]0x30C8)$([char]0x30E9)$([char]0x30C3)$([char]0x30AB)$([char]0x30FC)"
    New-Commit -Subject "feat: $unicode"
    git tag v2026.1.5.0
    $consoleEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Latin1
    try {
        $unicodeOut = Join-Path $sandbox 'unicode-notes.md'
        $null = & $generator -Tag v2026.1.5.0 -Repository '' -OutFile $unicodeOut
    } finally {
        $latin1Kept = [Console]::OutputEncoding.WebName
        [Console]::OutputEncoding = $consoleEncoding
    }
    $unicodeNotes = [System.IO.File]::ReadAllText($unicodeOut)
    Assert-Substring -Text $unicodeNotes -Needle "- feat: $unicode by Test Person in" -Because (
        'a non-ASCII subject from git survives a console that is not UTF-8')
    Assert-Equal -Actual $latin1Kept -Expected 'iso-8859-1' -Because (
        'the caller''s console encoding is put back afterwards')

    $pageOne = @(New-ApiCommit -Sha 'aaaaaaa1' -Message "fix: page one $unicode")
    $pageTwo = @(New-ApiCommit -Sha 'bbbbbbb2' -Message 'feat: page two')
    $ghState.Pages = @{
        compare = @((ConvertTo-PageJson -Commits $pageOne -Compare), (ConvertTo-PageJson -Commits $pageTwo -Compare))
        list    = @((ConvertTo-PageJson -Commits $pageOne), (ConvertTo-PageJson -Commits $pageTwo))
    }
    $ghState.Mode = 'pages'
    $ghCallLog.Clear()
    [Console]::OutputEncoding = [System.Text.Encoding]::Latin1
    try {
        $compareOut = Join-Path $sandbox 'compare-notes.md'
        $compareArgs = @{
            Tag         = 'v2026.1.5.0'
            PreviousTag = 'v2026.1.4.0'
            Repository  = 'RealWhyKnot/sample'
            OutFile     = $compareOut
        }
        $null = & $generator @compareArgs
        $firstOut = Join-Path $sandbox 'first-notes.md'
        $null = & $generator -Tag v2026.1.1.0 -Repository 'RealWhyKnot/sample' -OutFile $firstOut
    } finally {
        [Console]::OutputEncoding = $consoleEncoding
        $ghState.Mode = ''
    }
    $listCalls = @($ghCallLog | Where-Object { "$($_[1])" -match '/commits\?' })
    $compareNotes = [System.IO.File]::ReadAllText($compareOut)
    $firstNotes = [System.IO.File]::ReadAllText($firstOut)
    Assert-Substring -Text $compareNotes -Needle "- fix: page one $unicode by" -Because (
        'a non-ASCII subject from the API survives a console that is not UTF-8')
    Assert-Substring -Text $compareNotes -Needle '- feat: page two by' -Because 'the compare reads every page'
    Assert-Equal -Actual "$($listCalls.Count)" -Expected '1' -Because 'a first release lists commits through the API'
    Assert-Substring -Text $firstNotes -Needle '- feat: page two by' -Because (
        'a first release reads every page of the commit list')
    Assert-Substring -Text $firstNotes -Needle "- fix: page one $unicode by" -Because (
        'a first release keeps non-ASCII subjects')

    New-Commit -Subject 'diag: log the tracker state on start'
    New-Commit -Subject 'style: reformat the settings window'
    git tag v2026.1.6.0
    $kinds = & $generator -Tag v2026.1.6.0 -Repository '' | Out-String
    Assert-Substring -Text $kinds -Needle "### Changes`n- diag: log the tracker state on start" -Because (
        'diag lands in Changes')
    Assert-Substring -Text $kinds -Needle "### Chores`n- style: reformat the settings window" -Because (
        'style lands in Chores')
    Assert-NoSubstring -Text $kinds -Needle '### Other' -Because 'diag and style no longer fall through to Other'

    $actionTemp = Join-Path $sandbox 'action-temp'
    $null = New-Item -ItemType Directory -Force -Path $actionTemp
    $marker = Join-Path $sandbox 'injected'
    $actionTitle = "TrackDoctor's $unicode"
    $actionExtra = "## Download`n`nNeeds SteamVR's driver folder. $unicode`n`n`$(New-Item -ItemType File '$marker')"
    $code = Invoke-ReleaseNotesAction -Temp $actionTemp -With @{
        tag = 'v2026.1.6.0'; repository = ''; 'previous-tag' = ''; title = $actionTitle; extra = $actionExtra
    }
    $actionNotesPath = Join-Path $actionTemp 'release-notes.md'
    Assert-Equal -Actual "$code" -Expected '0' -Because (
        'the action step runs with apostrophes and non-ASCII text in title and extra')
    $actionNotes = if (Test-Path $actionNotesPath) { [System.IO.File]::ReadAllText($actionNotesPath) } else { '' }
    Assert-Substring -Text $actionNotes -Needle "# $actionTitle" -Because 'the title reaches the notes unchanged'
    Assert-Substring -Text $actionNotes -Needle "Needs SteamVR's driver folder. $unicode" -Because (
        'the extra block reaches the notes unchanged')
    Assert-Substring -Text $actionNotes -Needle '$(New-Item' -Because 'a subexpression in extra stays literal text'
    $injectedTitle = "x'`$(New-Item -ItemType File '$marker')'"
    Remove-Item -LiteralPath $actionNotesPath -ErrorAction SilentlyContinue
    $null = Invoke-ReleaseNotesAction -Temp $actionTemp -With @{
        tag = 'v2026.1.6.0'; repository = ''; 'previous-tag' = ''; title = $injectedTitle; extra = ''
    }
    Assert-Equal -Actual "$(Test-Path $marker)" -Expected 'False' -Because (
        'quotes in an input cannot run code in the step')
    $injectedNotes = if (Test-Path $actionNotesPath) { [System.IO.File]::ReadAllText($actionNotesPath) } else { '' }
    Assert-Substring -Text $injectedNotes -Needle "# $injectedTitle" -Because (
        'a quoted input reaches the notes as plain text')

    $extra = & $generator -Tag v2026.1.2.0 -Repository '' -Extra '## Downloads', '- a file' | Out-String
    Assert-Substring -Text $extra -Needle '## Downloads' -Because 'extra markdown is appended'

    $out = Join-Path $sandbox 'notes.md'
    $null = & $generator -Tag v2026.1.2.0 -Repository '' -OutFile $out
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
