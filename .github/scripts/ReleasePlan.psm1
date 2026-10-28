Set-StrictMode -Version Latest

function Invoke-Git {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $output = & { $ErrorActionPreference = 'Continue'; & git -C $Root @Arguments 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        throw "git -C $Root $($Arguments -join ' ') failed with exit code ${LASTEXITCODE}: $($output -join ' ')"
    }
    @(foreach ($line in @($output)) { "$line" })
}

function ConvertTo-ReleaseVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)][hashtable] $Match
    )
    $revision = 0
    if ($Match.ContainsKey(4)) {
        $revision = [int]$Match[4]
    }
    [version]::new([int]$Match[1], [int]$Match[2], [int]$Match[3], $revision)
}

function Get-ReleaseTag {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)][string] $Root
    )
    $releases = foreach ($name in @(Invoke-Git -Root $Root -Arguments @('tag', '--list', 'v*'))) {
        if ($name -match $script:releasePattern) {
            [pscustomobject]@{
                Name    = $name
                Version = ConvertTo-ReleaseVersion -Match $Matches
            }
        }
    }
    @($releases | Sort-Object -Property Version)
}

function Get-PreviousRelease {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Tag
    )
    if ($Tag -notmatch $script:releasePattern) {
        throw "$Tag is not a release tag."
    }
    $current = ConvertTo-ReleaseVersion -Match $Matches
    $earlier = @(foreach ($release in @(Get-ReleaseTag -Root $Root)) {
            if ($release.Version -lt $current) {
                $release.Name
            }
        })
    if ($earlier.Count -eq 0) {
        return ''
    }
    $earlier[-1]
}

function Test-ShippedPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Path
    )
    $Path -notmatch $script:unshippedPattern
}

function Get-ReleaseCommit {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Range
    )
    $separator = [char]0x1e
    $arguments = @('log', '--no-merges', '--format=%x1e%H%x1f%s', '--name-only', $Range)
    $text = (Invoke-Git -Root $Root -Arguments $arguments) -join "`n"
    $commits = foreach ($record in $text.Split($separator)) {
        $lines = @(foreach ($line in $record.Split("`n")) { if ($line.Trim()) { $line } })
        if ($lines.Count -eq 0) {
            continue
        }
        $header = $lines[0].Split([char]0x1f)
        $paths = [System.Collections.Generic.List[string]]::new()
        for ($index = 1; $index -lt $lines.Count; $index++) {
            $paths.Add($lines[$index])
        }
        [pscustomobject]@{
            Sha     = $header[0]
            Subject = $header[1]
            Paths   = $paths.ToArray()
        }
    }
    @($commits)
}

function Get-DayRevision {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Day
    )
    $pattern = '^v' + [regex]::Escape($Day) + '\.(\d+)(-.+)?$'
    $next = 0
    foreach ($name in @(Invoke-Git -Root $Root -Arguments @('tag', '--list', "v$Day.*"))) {
        if ($name -match $pattern -and [int]$Matches[1] -ge $next) {
            $next = [int]$Matches[1] + 1
        }
    }
    $next
}

function Get-NextRelease {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][ValidatePattern('^\d{4}\.\d{1,2}\.\d{1,2}$')][string] $Day,
        [string] $Ref = 'HEAD'
    )
    $releases = @(Get-ReleaseTag -Root $Root)
    if ($releases.Count -eq 0) {
        throw 'No release tag found. Tag the first release by hand.'
    }
    $latest = $releases[-1]
    $base = @(Invoke-Git -Root $Root -Arguments @('merge-base', $latest.Name, $Ref))[0]
    $shipped = $false
    foreach ($commit in @(Get-ReleaseCommit -Root $Root -Range "$base..$Ref")) {
        if ($commit.Subject -match $script:breakingPattern) {
            throw ("$($commit.Sha.Substring(0, 7)) '$($commit.Subject)' is a breaking change. " +
                'It needs a new moving tag, which is set up by hand.')
        }
        foreach ($path in $commit.Paths) {
            if (Test-ShippedPath -Path $path) {
                $shipped = $true
            }
        }
    }
    if (-not $shipped) {
        return $null
    }
    [pscustomobject]@{
        Previous = $latest.Name
        Tag      = "v$Day.$(Get-DayRevision -Root $Root -Day $Day)"
    }
}

function ConvertTo-PinnedReference {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content,
        [Parameter(Mandatory)][string] $Tag
    )
    [regex]::Replace($Content, $script:sharedReferencePattern, "`$1@$Tag")
}

$script:releasePattern = '^v(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$'
$script:breakingPattern = '^[A-Za-z]+(\([^)]*\))?!:'
$script:sharedReferencePattern = '(RealWhyKnot/workflows/[A-Za-z0-9._/-]+)@v\d+(?![\d.])'
$script:unshippedPattern = '(' + (@(
        '\.md$'
        '(^|/)Test-[^/]*\.ps1$'
        '(^|/)(tests|selftest)/'
        '^\.github/(workflows/(ci|commits|release)\.yml$|dependabot\.yml$|scripts/)'
        '^\.githooks/'
        '^\.git(ignore|attributes)$'
    ) -join '|') + ')'

$exported = @(
    'Get-ReleaseTag'
    'Get-PreviousRelease'
    'Test-ShippedPath'
    'Get-NextRelease'
    'ConvertTo-PinnedReference'
)
Export-ModuleMember -Function $exported
