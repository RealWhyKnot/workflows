#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string] $RepoRoot = (Get-Location).Path,
    [string[]] $Lang = @(),
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module -Name (Join-Path $PSScriptRoot 'VendoredPaths.psm1')
Import-Module -Name (Join-Path $PSScriptRoot 'InstallRules.psm1')
Import-Module -Name (Join-Path $PSScriptRoot 'MergeSettings.psm1')

$extensions = @{
    rust       = @('.rs')
    typescript = @('.ts', '.tsx', '.mts', '.cts', '.js', '.mjs', '.cjs', '.jsx', '.svelte', '.vue', '.astro')
    csharp     = @('.cs')
    python     = @('.py')
    powershell = @('.ps1', '.psm1', '.psd1')
    shell      = @('.sh', '.bash')
    css        = @('.css', '.html')
}
$styled = @('.svelte', '.vue', '.astro')
$languageOf = @{}
foreach ($name in $extensions.Keys) {
    foreach ($extension in $extensions[$name]) {
        $languageOf[$extension] = $name
    }
}

$vendoredList = Join-Path $PSScriptRoot 'common/.github/lint/vendored-paths.txt'
if (-not (Test-Path -LiteralPath $vendoredList -PathType Leaf)) {
    throw "No vendored-path list at $vendoredList"
}
$shared = @(Read-VendoredEntry -Path $vendoredList)

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$localList = Join-Path $root '.github/lint/vendored-paths.local.txt'
$oldList = Join-Path $root 'vendored-paths.local.txt'
if (Test-Path -LiteralPath $oldList -PathType Leaf) {
    if (Test-Path -LiteralPath $localList -PathType Leaf) {
        throw 'There''s a vendored-paths.local.txt at the root and in .github/lint/. Merge them in .github/lint/.'
    }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $localList))
    [IO.File]::Move($oldList, $localList)
    Write-Host 'common: moved vendored-paths.local.txt into .github/lint/'
}
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
            $key = $item.FullName.Substring($folder.Length).TrimStart('\', '/') -replace '\\', '/'
            $null = $shipped.Add($key)
            if ($key -match '^\.github/lint/[^/]+$') {
                $null = $shipped.Add($item.Name)
            }
        }
    }
    $present = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($file in $own) {
        if ($shipped.Contains($file) -or $file.StartsWith('.lint/')) {
            continue
        }
        $language = Get-FileLanguage -Root $root -File $file -LanguageOf $languageOf
        if ($language) {
            $null = $present.Add($language)
        }
        if ([IO.Path]::GetExtension($file) -in $styled) {
            $null = $present.Add('css')
        }
    }
    $selected = @($available | Where-Object { $present.Contains($_) })
    if ($selected.Count -eq 0) {
        Write-Host "No tracked files match any of: $($available -join ', '). Pass -Lang to pick one."
        exit 0
    }
}

$hasPendingChanges = $false
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
                $check = @{ Name = $name; Source = $file.FullName; Root = $root; Entry = $null; Tracked = $own }
                if ($entry.Count -gt 0) {
                    $check.Entry = $entry[0]
                }
                if (Test-MergeItem @check) {
                    $hasPendingChanges = $true
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
                $where = 'vendored paths go in .github/lint/vendored-paths.local.txt'
                Write-Host "${name}: $reason. Remove it: $key replaces it, and $where."
                $hasPendingChanges = $true
            }
        }
        if (-not $plan.Contains($key)) {
            $plan[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $plan[$key].Add(@{ Language = $name; Source = $from })
    }
}

foreach ($key in $plan.Keys) {
    if ($key -notmatch '^\.github/lint/(?<rest>.+)$') {
        continue
    }
    $rest = $Matches['rest']
    $old = @(".lint/$rest"; if (-not $rest.Contains('/')) { $rest })
    foreach ($copy in $old) {
        if (Test-Path -LiteralPath (Join-Path $root $copy) -PathType Leaf) {
            $owner = $plan[$key][0].Language
            Write-Host "${owner}: $copy moved to $key. Delete $copy and point hooks and CI at $key."
            $hasPendingChanges = $true
        }
    }
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($key in $plan.Keys) {
    $items = $plan[$key]
    $names = @(foreach ($item in $items) { $item.Language }) -join ' and '
    $texts = @(foreach ($item in $items) { [IO.File]::ReadAllText($item.Source) -replace "`r`n", "`n" })
    if (@($texts | Where-Object { $_ -cne $texts[0] }).Count -eq 0) {
        $text = $texts[0]
    } elseif ((Split-Path -Leaf $key) -eq '.editorconfig') {
        $joined = Join-Section -Text $texts
        $text = $joined.Text
        foreach ($conflict in $joined.Conflicts) {
            Write-Host "${names}: the baselines set $conflict in $key differently. Make them agree first."
            $hasPendingChanges = $true
        }
    } else {
        Write-Host "${names}: each baseline has its own $key. Merge them by hand."
        $hasPendingChanges = $true
        continue
    }
    $text = Add-VendoredEntry -Key $key -Text $text -Entry $local
    $destination = Join-Path $root $key
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $current = [IO.File]::ReadAllText($destination) -replace "`r`n", "`n"
        if ($current -ceq $text) {
            Write-Host "${names}: $key is already current"
            continue
        }
        if (-not $Force) {
            Write-Host "${names}: $key differs from the baseline. Fix it by hand, or run again with -Force."
            $hasPendingChanges = $true
            continue
        }
    }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    [IO.File]::WriteAllText($destination, $text, $utf8)
    Write-Host "${names}: installed $key"
}

if ($hasPendingChanges) {
    Write-Host 'The repo isn''t on the baseline yet. Do the steps above, then run this again.'
    exit 1
}
exit 0
