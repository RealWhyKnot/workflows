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
            if ($Entry.StartsWith('/')) {
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
        '.github/lint/vendored-paths.txt' {
            return $Text.TrimEnd("`n") + "`n" + ($Entry -join "`n") + "`n"
        }
        'ruff.toml' {
            $item = @($names; foreach ($path in $paths) { "./$path" })
            return Add-ListItem -Text $Text -Anchor '.yarn' -Quote '"' -Item $item
        }
        'pyrightconfig.json' {
            $item = @(foreach ($name in $names) { "**/$name" }; $paths)
            $config = ConvertFrom-Json -InputObject $Text
            $quoted = @(foreach ($value in @($config.exclude; $item)) {
                    ConvertTo-Json -InputObject $value -Depth 2 -Compress
                })
            $found = [regex]::Match($Text, '(?ms)^(?<indent>[ \t]*)"exclude"\s*:\s*\[[^\]]*\]')
            if (-not $found.Success) { throw 'The Python baseline has no exclude array.' }
            $indent = $found.Groups['indent'].Value
            $replacement = $indent + '"exclude": [' + ($quoted -join ', ') + ']'
            if ($replacement.Length -gt 160) {
                $rows = @(foreach ($value in $quoted) { "$indent  $value" })
                $replacement = $indent + '"exclude": [' + "`n" + ($rows -join ",`n") + "`n$indent]"
            }
            return $Text.Substring(0, $found.Index) + $replacement + $Text.Substring($found.Index + $found.Length)
        }
        '.prettierignore' {
            $item = @(foreach ($name in $names) { "**/$name/" }; foreach ($path in $paths) { "/$path/" })
            return Add-ListItem -Text $Text -Anchor '**/.yarn/' -Item $item
        }
        'eslint.config.mjs' {
            $item = @(foreach ($name in $names) { "**/$name/" }; foreach ($path in $paths) { "$path/" })
            return Add-ListItem -Text $Text -Anchor '**/.yarn/' -Quote '"' -Item $item
        }
        'stylelint.config.mjs' {
            $item = @(foreach ($name in $names) { "**/$name/**" }; foreach ($path in $paths) { "$path/**" })
            return Add-ListItem -Text $Text -Anchor '**/.yarn/**' -Quote '"' -Item $item
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

Export-ModuleMember -Function Read-VendoredEntry, Get-VendoredPattern, Add-VendoredEntry
