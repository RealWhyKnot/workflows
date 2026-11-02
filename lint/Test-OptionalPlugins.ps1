#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param([string] $BaselineRoot = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Config {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Text,
        [string] $PackageName,
        [string] $PackageJson,
        [string] $Module = 'export default {};'
    )
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('optional-plugin-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($folder)
    try {
        $config = Join-Path $folder 'plugin.config.mjs'
        [IO.File]::WriteAllText($config, $Text)
        if ($PackageJson) {
            $package = Join-Path $folder "node_modules/$PackageName"
            $null = [IO.Directory]::CreateDirectory($package)
            [IO.File]::WriteAllText((Join-Path $package 'package.json'), $PackageJson)
            [IO.File]::WriteAllText((Join-Path $package 'index.mjs'), $Module)
        }
        $runner = Join-Path $folder 'runner.mjs'
        $script = @'
import { pathToFileURL } from "node:url";
try {
  const loaded = await import(pathToFileURL(process.argv[2]).href);
  process.stdout.write(JSON.stringify(loaded.default));
} catch (error) {
  if (!(error instanceof Error) || !("code" in error)) throw error;
  process.stdout.write(error.code);
}
'@
        [IO.File]::WriteAllText($runner, $script)
        $node = (Get-Command -Name node -CommandType Application).Source
        $output = & $node $runner $config
        if ($LASTEXITCODE -ne 0) { throw "Config test failed with exit code $LASTEXITCODE" }
        return "$output"
    } finally {
        Remove-Item -LiteralPath $folder -Recurse -Force
    }
}

$eslint = [IO.File]::ReadAllText((Join-Path $BaselineRoot 'typescript/eslint.config.mjs'))
$match = [regex]::Match($eslint, '(?s)const load =.*?\r?\n};')
if (-not $match.Success) { throw 'Could not find the optional ESLint plugin loader.' }
$configs = @(
    @{
        Name    = 'eslint'
        Text    = $match.Value + "`n" + 'export default await load("eslint-plugin-vue");'
        Package = 'eslint-plugin-vue'
        Missing = 'null'
        Present = '{}'
    }
    foreach ($language in @('typescript', 'css')) {
        @{
            Name    = "$language prettier"
            Text    = [IO.File]::ReadAllText((Join-Path $BaselineRoot "$language/prettier.config.mjs"))
            Package = 'prettier-plugin-svelte'
            Missing = '{"printWidth":160,"trailingComma":"es5","plugins":[]}'
            Present = '{"printWidth":160,"trailingComma":"es5","plugins":["prettier-plugin-svelte"]}'
        }
    }
)
$failures = 0
foreach ($config in $configs) {
    $cases = @(
        @{ Name = 'missing'; Json = ''; Expected = $config.Missing }
        @{ Name = 'installed'; Json = '{"type":"module","exports":"./index.mjs"}'; Expected = $config.Present }
        @{ Name = 'malformed'; Json = '{broken'; Expected = 'ERR_INVALID_PACKAGE_CONFIG' }
        @{ Name = 'invalid export'; Json = '{"exports":"outside"}'; Expected = 'ERR_INVALID_PACKAGE_TARGET' }
    )
    foreach ($case in $cases) {
        $parameters = @{ Text = $config.Text; PackageName = $config.Package; PackageJson = $case.Json }
        $actual = Invoke-Config @parameters
        if ($actual -ne $case.Expected) {
            Write-Host "FAIL $($config.Name): $($case.Name): expected $($case.Expected), got $actual"
            $failures++
        } else {
            Write-Host "ok $($config.Name): $($case.Name)"
        }
    }
}
if ($failures -gt 0) { exit 1 }
Write-Host 'All optional plugin checks passed.'
exit 0
