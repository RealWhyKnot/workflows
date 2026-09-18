#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]] $Archives,
    [string] $Contents = '',
    [string] $ManifestSuffix = '.integrity.tsv',
    [ValidateSet('MiB', 'MB')][string] $Units = 'MiB',
    [string] $TableFile = '',
    [switch] $NoManifest
)

$ErrorActionPreference = 'Stop'

function Get-Sha256 {
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$resolved = @()
foreach ($pattern in $Archives) {
    $pattern = "$pattern".Trim()
    if (-not $pattern) { continue }
    $matched = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($matched.Count -eq 0) { throw "No file matched '$pattern'." }
    $resolved += $matched
}
if ($resolved.Count -eq 0) { throw 'No archives to hash.' }

function Get-ContentRows {
    param([string] $Directory)
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    $root = (Resolve-Path -LiteralPath $Directory).Path
    return @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            Name = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
            Size = $_.Length
            Hash = Get-Sha256 -Path $_.FullName
        }
    })
}

if ($Contents -and -not (Test-Path -LiteralPath $Contents -PathType Container)) {
    throw "Contents directory '$Contents' does not exist."
}
$shared = Get-ContentRows -Directory $Contents

$divisor = if ($Units -eq 'MB') { 1000000 } else { 1048576 }
$rows = @()
$manifests = @()
foreach ($archive in $resolved) {
    $hash = Get-Sha256 -Path $archive.FullName
    $rows += [pscustomobject]@{ Name = $archive.Name; Size = $archive.Length; Hash = $hash }

    if (-not $NoManifest) {
        $base = $archive.FullName
        foreach ($double in @('.tar.gz', '.tar.bz2', '.tar.xz')) {
            if ($base.EndsWith($double, [System.StringComparison]::OrdinalIgnoreCase)) {
                $base = $base.Substring(0, $base.Length - $double.Length)
                break
            }
        }
        if ($base -eq $archive.FullName) { $base = [System.IO.Path]::ChangeExtension($base, $null).TrimEnd('.') }
        $manifest = $base + $ManifestSuffix
        $contentRows = if ($Contents) { $shared } else { Get-ContentRows -Directory $base }
        $lines = @("$hash`t$($archive.Length)`t$($archive.Name)")
        foreach ($file in $contentRows) { $lines += "$($file.Hash)`t$($file.Size)`t$($file.Name)" }
        [System.IO.File]::WriteAllLines($manifest, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        $manifests += $manifest
    }
}

$table = @("| Asset | Size ($Units) | SHA-256 |", '| --- | --- | --- |')
foreach ($row in $rows) {
    $size = ($row.Size / $divisor).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    $table += "| ``$($row.Name)`` | $size | ``$($row.Hash)`` |"
}
$markdown = ($table -join "`n") + "`n"

if ($TableFile) {
    $tablePath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $TableFile))
    [System.IO.File]::WriteAllText($tablePath, $markdown, (New-Object System.Text.UTF8Encoding($false)))
}

if ($env:GITHUB_OUTPUT) {
    $delimiter = "checksums-$([System.Guid]::NewGuid().ToString('N'))"
    $out = @("sha256=$($rows[0].Hash)")
    $out += "manifests<<$delimiter"
    $out += $manifests
    $out += $delimiter
    $out += "table<<$delimiter"
    $out += $table
    $out += $delimiter
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value $out
}

Write-Output $markdown
