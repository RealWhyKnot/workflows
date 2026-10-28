#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $RepoRoot = (Get-Location).Path,
    [string[]] $Lang = @(),
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-VendoredEntry {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Path
    )
    $segment = '(?!\.+/)[A-Za-z0-9_.@+-]+/'
    $number = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $number++
        $entry = $line.Trim()
        if (-not $entry) {
            continue
        }
        if ($entry -cnotmatch "^(?:/(?:$segment)+|$segment)$") {
            throw "$(Split-Path -Leaf $Path):${number}: '$entry' isn't a folder name/ or a /path/ from the repo root"
        }
        $entry
    }
}

function Get-VendoredPattern {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]] $Entry = @()
    )
    $parts = @(foreach ($item in $Entry) {
            $name = [regex]::Escape($item.Trim('/'))
            if ($entry.StartsWith('/')) {
                "^$name/"
            } else {
                "(^|/)$name/"
            }
        })
    if ($parts.Count -eq 0) {
        return '(?!)'
    }
    '(' + ($parts -join '|') + ')'
}

function Add-ListItem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Anchor,
        [Parameter(Mandatory)][string[]] $Item,
        [string] $Quote = ''
    )
    $quoted = [regex]::Escape($Quote + $Anchor + $Quote)
    $found = [regex]::Match($Text, "(?m)^(?<indent>[ \t]*)$quoted(?<comma>,?)$")
    if (-not $found.Success) {
        throw "The baseline has no $Anchor entry to add the repo's vendored paths after."
    }
    $comma = if ($Quote) { ',' } else { '' }
    $lines = @(foreach ($value in @($Anchor; $Item)) {
            "$($found.Groups['indent'].Value)$Quote$value$Quote$comma"
        })
    if ($Quote -and -not $found.Groups['comma'].Value) {
        $lines[-1] = $lines[-1].TrimEnd(',')
    }
    $Text.Substring(0, $found.Index) + ($lines -join "`n") + $Text.Substring($found.Index + $found.Length)
}

function Add-SectionItem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Prefix,
        [Parameter(Mandatory)][string[]] $Item
    )
    $found = [regex]::Match($Text, "(?m)^\[$([regex]::Escape($Prefix))\{(?<list>[^}\n]*\.yarn)\}/\*\*\]$")
    if (-not $found.Success) {
        throw "The baseline has no [$Prefix{...,.yarn}/**] section to add the repo's vendored paths to."
    }
    $header = "[$Prefix{$($found.Groups['list'].Value),$($Item -join ',')}/**]"
    $Text.Substring(0, $found.Index) + $header + $Text.Substring($found.Index + $found.Length)
}

function Add-VendoredEntry {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [string[]] $Entry = @()
    )
    if ($Entry.Count -eq 0) {
        return $Text
    }
    $names = @(foreach ($item in $Entry) { if (-not $item.StartsWith('/')) { $item.TrimEnd('/') } })
    $paths = @(foreach ($item in $Entry) { if ($item.StartsWith('/')) { $item.Trim('/') } })
    switch -CaseSensitive ($Key) {
        'vendored-paths.txt' {
            return $Text.TrimEnd("`n") + "`n" + ($Entry -join "`n") + "`n"
        }
        'ruff.toml' {
            $item = @($names; foreach ($path in $paths) { "./$path" })
            return Add-ListItem -Text $Text -Anchor '.yarn' -Quote '"' -Item $item
        }
        'pyrightconfig.json' {
            $item = @(foreach ($name in $names) { "**/$name" }; $paths)
            return Add-ListItem -Text $Text -Anchor '**/.yarn' -Quote '"' -Item $item
        }
        '.prettierignore' {
            $item = @(foreach ($name in $names) { "**/$name/" }; foreach ($path in $paths) { "/$path/" })
            return Add-ListItem -Text $Text -Anchor '**/.yarn/' -Item $item
        }
        'eslint.config.mjs' {
            $item = @(foreach ($name in $names) { "**/$name/" }; foreach ($path in $paths) { "$path/" })
            return Add-ListItem -Text $Text -Anchor '**/.yarn/' -Quote '"' -Item $item
        }
        '.editorconfig' {
            $Text = Add-SectionItem -Text $Text -Prefix '' -Item @($names; $paths)
            if ($names.Count -gt 0) {
                $Text = Add-SectionItem -Text $Text -Prefix '**/' -Item $names
            }
            return $Text
        }
    }
    $Text
}

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
    if ($first -match ($interpreter + '(ba|da|k|z)?sh\b')) {
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

function Test-MergeItem {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Root,
        [AllowNull()][hashtable] $Entry
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
    $path = Join-Path $Root $target
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($Entry) {
            Write-Host "${Name}: $target is missing. Create it with the lines in merge/$leaf."
            return $true
        }
        Write-Host "${Name}: no $target here to check merge/$leaf against. The $Name guide says where it goes."
        return $false
    }
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

$extensions = @{
    rust       = @('.rs')
    typescript = @('.ts', '.tsx', '.mts', '.cts', '.js', '.mjs', '.cjs', '.jsx', '.svelte', '.vue', '.astro')
    csharp     = @('.cs')
    python     = @('.py')
    powershell = @('.ps1', '.psm1', '.psd1')
    shell      = @('.sh', '.bash')
}
$languageOf = @{}
foreach ($name in $extensions.Keys) {
    foreach ($extension in $extensions[$name]) {
        $languageOf[$extension] = $name
    }
}

$vendoredList = Join-Path (Join-Path $PSScriptRoot 'common') 'vendored-paths.txt'
if (-not (Test-Path -LiteralPath $vendoredList -PathType Leaf)) {
    throw "No vendored-path list at $vendoredList"
}
$shared = @(Read-VendoredEntry -Path $vendoredList)

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$localList = Join-Path $root 'vendored-paths.local.txt'
$local = @()
if (Test-Path -LiteralPath $localList -PathType Leaf) {
    $local = @(Read-VendoredEntry -Path $localList | Where-Object { $_ -cnotin $shared } | Select-Object -Unique)
}
$vendored = Get-VendoredPattern -Entry @($shared; $local)
$available = @(Get-ChildItem -LiteralPath $PSScriptRoot -Directory |
        Where-Object Name -NE 'common' |
        Sort-Object Name |
        Select-Object -ExpandProperty Name)
if ($available.Count -eq 0) {
    throw "No language folders in $PSScriptRoot"
}

$tracked = @(& { $ErrorActionPreference = 'Continue'; git -c core.quotepath=off -C $root ls-files 2>$null })
$isRepo = $LASTEXITCODE -eq 0
if (-not $isRepo) {
    $tracked = @()
}
$own = @($tracked | Where-Object { $_ -notmatch $vendored })

if ($Lang) {
    $selected = @(foreach ($item in $Lang -split ',') {
            if ($item.Trim()) {
                $item.Trim()
            }
        }) | Sort-Object -Unique
    $selected = @($selected)
    $unknown = @($selected | Where-Object { $_ -notin $available })
    if ($unknown.Count -gt 0) {
        throw "No baseline for $($unknown -join ', '). Available: $($available -join ', ')"
    }
} else {
    if (-not $isRepo) {
        throw "$root isn't a git repo. Pass -Lang with one or more of: $($available -join ', ')"
    }
    $shipped = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($name in @('common'; $available)) {
        $folder = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot $name)).Path
        foreach ($item in Get-ChildItem -LiteralPath $folder -File -Recurse -Force) {
            $null = $shipped.Add(($item.FullName.Substring($folder.Length).TrimStart('\', '/') -replace '\\', '/'))
        }
    }
    $present = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($file in $own) {
        if ($shipped.Contains($file)) {
            continue
        }
        $language = Get-FileLanguage -Root $root -File $file -LanguageOf $languageOf
        if ($language) {
            $null = $present.Add($language)
        }
    }
    $selected = @($available | Where-Object { $present.Contains($_) })
    if ($selected.Count -eq 0) {
        Write-Host "No tracked files match any of: $($available -join ', '). Pass -Lang to pick one."
        exit 0
    }
}

$pending = $false
$plan = [ordered]@{}
foreach ($name in @('common'; $selected)) {
    $source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot $name)).Path
    $rules = @()
    $merges = @()
    $rulesPath = Join-Path $source 'install.psd1'
    if (Test-Path -LiteralPath $rulesPath -PathType Leaf) {
        $data = Import-PowerShellDataFile -LiteralPath $rulesPath
        if ($data.ContainsKey('Rules')) {
            $rules = @($data.Rules)
        }
        if ($data.ContainsKey('Merge')) {
            $merges = @($data.Merge)
        }
    }
    $active = @($rules | Where-Object { Test-Rule -Rule $_ -Root $root -Tracked $own })
    $used = @(foreach ($rule in $active) {
            if ($rule.ContainsKey('Use')) {
                $rule.Use -replace '\\', '/'
            }
        })

    foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
        $key = $file.FullName.Substring($source.Length).TrimStart('\', '/') -replace '\\', '/'
        $parts = @($key -split '/')
        if ($parts[0] -eq 'tests' -or $parts -contains '__pycache__' -or $parts -contains '.ruff_cache') {
            continue
        }
        if ($parts.Count -eq 1 -and ($file.Extension -eq '.md' -or $file.Name -eq 'install.psd1')) {
            continue
        }
        if ($parts[0] -eq 'merge') {
            if ($parts.Count -eq 2 -and $key -notin $used) {
                $entry = @($merges | Where-Object { $_.File -eq $parts[1] } | Select-Object -First 1)
                $check = @{ Name = $name; Source = $file.FullName; Root = $root; Entry = $null }
                if ($entry.Count -gt 0) {
                    $check.Entry = $entry[0]
                }
                if (Test-MergeItem @check) {
                    $pending = $true
                }
            }
            continue
        }

        $from = $file.FullName
        $matched = @($active | Where-Object { $_.File -eq $key } | Select-Object -First 1)
        if ($matched.Count -gt 0) {
            $rule = $matched[0]
            $reason = Get-RuleReason -Rule $rule
            if ($rule.ContainsKey('Skip') -and $rule.Skip) {
                Write-Host "${name}: $key doesn't apply here because $reason"
                continue
            }
            if ($rule.ContainsKey('Use')) {
                $from = Join-Path $source $rule.Use
                Write-Host "${name}: using $($rule.Use) for $key because $reason"
            } else {
                $where = 'vendored paths go in vendored-paths.local.txt'
                Write-Host "${name}: $reason. Remove it: $key replaces it, and $where."
                $pending = $true
            }
        }
        if (-not $plan.Contains($key)) {
            $plan[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $plan[$key].Add(@{ Language = $name; Source = $from })
    }
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($key in $plan.Keys) {
    $items = $plan[$key]
    $names = @(foreach ($item in $items) { $item.Language }) -join ' and '
    $texts = @(foreach ($item in $items) { [IO.File]::ReadAllText($item.Source) -replace "`r`n", "`n" })
    if ($texts.Count -eq 1) {
        $text = $texts[0]
    } elseif ((Split-Path -Leaf $key) -eq '.editorconfig') {
        $joined = Join-Section -Text $texts
        $text = $joined.Text
        foreach ($conflict in $joined.Conflicts) {
            Write-Host "${names}: the baselines set $conflict in $key differently. Make them agree first."
            $pending = $true
        }
    } else {
        Write-Host "${names}: each baseline has its own $key. Merge them by hand."
        $pending = $true
        continue
    }
    $text = Add-VendoredEntry -Key $key -Text $text -Entry $local
    $dest = Join-Path $root $key
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        $current = [IO.File]::ReadAllText($dest) -replace "`r`n", "`n"
        if ($current -ceq $text) {
            Write-Host "${names}: $key is already current"
            continue
        }
        if (-not $Force) {
            Write-Host "${names}: $key differs from the baseline. Fix it by hand, or run again with -Force."
            $pending = $true
            continue
        }
    }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
    [IO.File]::WriteAllText($dest, $text, $utf8)
    Write-Host "${names}: installed $key"
}

if ($pending) {
    Write-Host 'The repo isn''t on the baseline yet. Do the steps above, then run this again.'
    exit 1
}
exit 0
