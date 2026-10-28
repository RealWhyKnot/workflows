#!/usr/bin/env pwsh
#Requires -Version 7.4
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
Set-StrictMode -Version Latest

function Get-Sha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ContentRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string] $Directory)
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $root = (Resolve-Path -LiteralPath $Directory).Path
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object -Property FullName)) {
        [pscustomobject]@{
            Name = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
            Size = $file.Length
            Hash = Get-Sha256 -Path $file.FullName
        }
    }
}

$resolved = [System.Collections.Generic.List[object]]::new()
foreach ($pattern in $Archives) {
    $pattern = "$pattern".Trim()
    if (-not $pattern) { continue }
    $matched = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    if ($matched.Count -eq 0) { throw "No file matched '$pattern'." }
    $resolved.AddRange($matched)
}
if ($resolved.Count -eq 0) { throw 'No archives to hash.' }

if ($Contents -and -not (Test-Path -LiteralPath $Contents -PathType Container)) {
    throw "Contents directory '$Contents' does not exist."
}
$shared = @(Get-ContentRow -Directory $Contents)

$divisor = if ($Units -eq 'MB') { 1000000 } else { 1048576 }
$rows = [System.Collections.Generic.List[object]]::new()
$manifests = [System.Collections.Generic.List[string]]::new()
foreach ($archive in $resolved) {
    $hash = Get-Sha256 -Path $archive.FullName
    $rows.Add([pscustomobject]@{ Name = $archive.Name; Size = $archive.Length; Hash = $hash })

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
        $contentRows = if ($Contents) { $shared } else { @(Get-ContentRow -Directory $base) }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("$hash`t$($archive.Length)`t$($archive.Name)")
        foreach ($file in $contentRows) { $lines.Add("$($file.Hash)`t$($file.Size)`t$($file.Name)") }
        [System.IO.File]::WriteAllLines($manifest, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
        $manifests.Add($manifest)
    }
}

$table = [System.Collections.Generic.List[string]]::new()
$table.Add("| Asset | Size ($Units) | SHA-256 |")
$table.Add('| --- | --- | --- |')
foreach ($row in $rows) {
    $size = ($row.Size / $divisor).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    $table.Add("| ``$($row.Name)`` | $size | ``$($row.Hash)`` |")
}
$markdown = ($table -join "`n") + "`n"

if ($TableFile) {
    $tablePath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $TableFile))
    [System.IO.File]::WriteAllText($tablePath, $markdown, (New-Object System.Text.UTF8Encoding($false)))
}

if ($env:GITHUB_OUTPUT) {
    $delimiter = "checksums-$([System.Guid]::NewGuid().ToString('N'))"
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("sha256=$($rows[0].Hash)")
    $out.Add("manifests<<$delimiter")
    $out.AddRange($manifests)
    $out.Add($delimiter)
    $out.Add("table<<$delimiter")
    $out.AddRange($table)
    $out.Add($delimiter)
    $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:GITHUB_OUTPUT)
    [System.IO.File]::AppendAllText($outputPath, ($out -join [Environment]::NewLine) + [Environment]::NewLine)
}

Write-Output $markdown
exit 0
