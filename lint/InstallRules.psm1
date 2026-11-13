$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-FileLanguage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $File,
        [Parameter(Mandatory)][hashtable] $LanguageOf
    )
    if ($File -match '\.(sh|bash)\.tpl$') {
        return 'shell'
    }
    $extension = [IO.Path]::GetExtension($File)
    if ($extension) {
        if ($LanguageOf.ContainsKey($extension)) {
            return $LanguageOf[$extension]
        }
        return ''
    }
    $path = Join-Path $Root $File
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    $buffer = New-Object byte[] 128
    $stream = [IO.File]::OpenRead($path)
    try {
        $count = $stream.Read($buffer, 0, $buffer.Length)
    } finally {
        $stream.Dispose()
    }
    $first = ([Text.Encoding]::ASCII.GetString($buffer, 0, $count) -split "`n")[0]
    $interpreter = '^#![ \t]*\S*/(env[ \t]+(-\S+[ \t]+)*)?'
    if ($first -match ($interpreter + '(bash|dash|ksh|zsh|sh)\b')) {
        return 'shell'
    }
    if ($first -match ($interpreter + 'python[0-9.]*\b')) {
        return 'python'
    }
    return ''
}

function Test-Rule {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable] $Rule,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Tracked
    )
    if ($Rule.ContainsKey('Tracked')) {
        $hits = @($Tracked | Where-Object { $_ -ne $Rule.File -and $_ -match $Rule.Tracked })
        if (-not $Rule.ContainsKey('Matches')) {
            return $hits.Count -gt 0
        }
        foreach ($hit in $hits) {
            $file = Join-Path $Root $hit
            if ((Test-Path -LiteralPath $file -PathType Leaf) -and [IO.File]::ReadAllText($file) -match $Rule.Matches) {
                return $true
            }
        }
        return $false
    }
    $path = Join-Path $Root $Rule.When
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }
    if (-not $Rule.ContainsKey('Matches')) {
        return $true
    }
    return [IO.File]::ReadAllText($path) -match $Rule.Matches
}

function Get-RuleReason {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable] $Rule
    )
    if ($Rule.ContainsKey('Reason')) {
        return $Rule.Reason
    }
    if ($Rule.ContainsKey('Tracked')) {
        return "a tracked file matches $($Rule.Tracked)"
    }
    if ($Rule.ContainsKey('Matches')) {
        return "$($Rule.When) matches $($Rule.Matches)"
    }
    return "$($Rule.When) exists"
}

function Set-ExecutableMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $File,
        [bool] $Apply
    )

    $entries = @(& git -C $Root ls-files --stage -- $File)
    if ($LASTEXITCODE -ne 0) { throw "Could not read the git mode for $File." }
    if ($entries.Count -gt 1) { throw "Resolve the merge conflict in $File before installing lint." }
    $hasMode = $entries.Count -eq 1 -and $entries[0].StartsWith('100755 ')
    if (-not $hasMode -and -not $Apply) {
        Write-Host "$File isn't executable in git. Run Install-Lint with -Force."
        return $true
    }
    if (-not $hasMode) {
        $null = & git -C $Root add --intent-to-add --chmod=+x -- $File
        if ($LASTEXITCODE -ne 0) { throw "Could not make $File executable in git." }
    }
    if ($Apply -and [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        & chmod +x -- (Join-Path $Root $File)
        if ($LASTEXITCODE -ne 0) { throw "Could not make $File executable on disk." }
    }
    return $false
}

Export-ModuleMember -Function Get-FileLanguage, Test-Rule, Get-RuleReason, Set-ExecutableMode
