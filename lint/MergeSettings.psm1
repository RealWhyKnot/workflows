$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Split-Section {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )
    $sections = [ordered]@{ '' = [System.Collections.Generic.List[string]]::new() }
    $current = $sections['']
    foreach ($raw in $Text -split "`r?`n") {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) {
            continue
        }
        if ($line -match '^\[.*\]$') {
            if (-not $sections.Contains($line)) {
                $sections[$line] = [System.Collections.Generic.List[string]]::new()
            }
            $current = $sections[$line]
            continue
        }
        $current.Add($line)
    }
    $sections
}

function ConvertTo-Setting {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Line
    )
    ($Line -replace '\s*=\s*', '=') -replace '\s+', ' '
}

function Get-MissingLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Expected,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Actual
    )
    $have = Split-Section -Text $Actual
    $want = Split-Section -Text $Expected
    foreach ($name in $want.Keys) {
        $present = @()
        if ($have.Contains($name)) {
            $present = @(foreach ($line in $have[$name]) { ConvertTo-Setting -Line $line })
        }
        foreach ($line in $want[$name]) {
            if ((ConvertTo-Setting -Line $line) -notin $present) {
                ($name + ' ' + $line).Trim()
            }
        }
    }
}

function Get-MissingJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object] $Expected,
        [AllowNull()][object] $Actual,
        [string] $Prefix = ''
    )
    $record = [System.Management.Automation.PSCustomObject]
    if ($Expected -isnot $record) {
        if ("$Expected" -cne "$Actual") {
            $Prefix
        }
        return
    }
    foreach ($property in $Expected.PSObject.Properties) {
        $value = $null
        if ($Actual -is $record -and $Actual.PSObject.Properties[$property.Name]) {
            $value = $Actual.PSObject.Properties[$property.Name].Value
        }
        $path = $property.Name
        if ($Prefix) {
            $path = "$Prefix.$path"
        }
        Get-MissingJson -Expected $property.Value -Actual $value -Prefix $path
    }
}

function Join-Section {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]] $Text
    )
    $combined = [ordered]@{}
    $conflicts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $Text) {
        $sections = Split-Section -Text $part
        foreach ($name in $sections.Keys) {
            if (-not $combined.Contains($name)) {
                $combined[$name] = [System.Collections.Generic.List[string]]::new()
            }
            $lines = $combined[$name]
            foreach ($line in $sections[$name]) {
                $key = ($line -split '=', 2)[0].Trim()
                $same = @($lines | Where-Object { ($_ -split '=', 2)[0].Trim() -eq $key })
                if ($same.Count -eq 0) {
                    $lines.Add($line)
                } elseif ((ConvertTo-Setting -Line $same[0]) -ne (ConvertTo-Setting -Line $line)) {
                    $conflicts.Add(("$name $key").Trim())
                }
            }
        }
    }
    $builder = [System.Text.StringBuilder]::new()
    foreach ($name in $combined.Keys) {
        if ($combined[$name].Count -eq 0) {
            continue
        }
        if ($builder.Length -gt 0) {
            $null = $builder.Append("`n")
        }
        if ($name) {
            $null = $builder.Append("$name`n")
        }
        foreach ($line in $combined[$name]) {
            $null = $builder.Append("$line`n")
        }
    }
    @{ Text = $builder.ToString(); Conflicts = $conflicts.ToArray() }
}

function Get-MergeTarget {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Target,
        [bool] $Nested,
        [AllowEmptyCollection()][string[]] $Tracked
    )
    if (Test-Path -LiteralPath (Join-Path $Root $Target) -PathType Leaf) {
        return $Target
    }
    if (-not $Nested) {
        return
    }
    $suffix = "/$Target"
    $found = @($Tracked | Where-Object {
            $_.EndsWith($suffix, [StringComparison]::Ordinal) -and
            (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)
        })
    foreach ($path in $found) {
        $folder = $path.Substring(0, $path.Length - $Target.Length)
        $outer = @($found | Where-Object {
                $prefix = $_.Substring(0, $_.Length - $Target.Length)
                $_ -ne $path -and $folder.StartsWith($prefix, [StringComparison]::Ordinal)
            })
        if ($outer.Count -eq 0) {
            $path
        }
    }
}

function Test-MergeItem {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Root,
        [AllowNull()][hashtable] $Entry,
        [AllowEmptyCollection()][string[]] $Tracked = @()
    )
    $leaf = Split-Path -Leaf $Source
    if ($Entry -and $Entry.ContainsKey('Skip') -and $Entry.Skip) {
        Write-Host "${Name}: merge/$leaf isn't merged into a file here: $(Get-RuleReason -Rule $Entry)"
        return $false
    }
    $target = $leaf
    if ($Entry -and $Entry.ContainsKey('Into')) {
        $target = $Entry.Into
    }
    $nested = [bool]($Entry -and $Entry.ContainsKey('Nested') -and $Entry.Nested)
    $targets = @(Get-MergeTarget -Root $Root -Target $target -Nested $nested -Tracked $Tracked)
    if ($targets.Count -eq 0) {
        if ($Entry) {
            Write-Host "${Name}: $target is missing. Create it with the lines in merge/$leaf."
            return $true
        }
        Write-Host "${Name}: no $target here to check merge/$leaf against. The $Name guide says where it goes."
        return $false
    }
    $pending = $false
    foreach ($relative in $targets) {
        if (Test-MergeFile -Name $Name -Source $Source -Path (Join-Path $Root $relative) -Target $relative) {
            $pending = $true
        }
    }
    $pending
}

function Test-MergeFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Target
    )
    $leaf = Split-Path -Leaf $Source
    $expected = [IO.File]::ReadAllText($Source)
    $actual = [IO.File]::ReadAllText($path)
    if ($leaf.EndsWith('.json')) {
        $wanted = ConvertFrom-Json -InputObject $expected
        $found = ConvertFrom-Json -InputObject $actual
        $missing = @(Get-MissingJson -Expected $wanted -Actual $found)
    } else {
        $missing = @(Get-MissingLine -Expected $expected -Actual $actual)
    }
    if ($missing.Count -eq 0) {
        Write-Host "${Name}: $target has everything in merge/$leaf"
        return $false
    }
    Write-Host "${Name}: $target is missing $($missing.Count) settings from merge/${leaf}: $($missing -join '; ')"
    return $true
}

Import-Module -Name (Join-Path $PSScriptRoot 'InstallRules.psm1')
Export-ModuleMember -Function Test-MergeItem, Join-Section
