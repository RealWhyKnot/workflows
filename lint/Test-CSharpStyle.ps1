#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param([string] $Checker = (Join-Path $PSScriptRoot 'csharp/.github/lint/CSharpStyle.cs'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Join-Path $temporaryRoot ('csharp-style-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($sandbox)
try {
    $source = Join-Path $sandbox 'CSharpStyle.cs'
    Copy-Item -LiteralPath $Checker -Destination $source
    $binary = Join-Path $sandbox 'bin'
    $build = & dotnet build $source --output $binary 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not build the checker: $($build -join "`n")" }
    $assembly = Join-Path $binary 'CSharpStyle.dll'
    $cases = @(
        foreach ($package in @('Microsoft.NET.ILLink.Tasks', 'Microsoft.DotNet.ILCompiler', 'Example.Library')) {
            foreach ($roll in @('disable', 'latestFeature')) {
                @{
                    Package = $package; Roll = $roll; Version = '10.0.203'; Path = 'src/App/packages.lock.json'
                    Tracked = $true; Implicit = $package -ne 'Example.Library'
                }
            }
        }
        foreach ($version in @('10.0', '10.0.203.1', '10.0.203-preview.1', '10.0.x', '10..203', '10.0.', '9.0.203')) {
            @{
                Package = 'Microsoft.NET.ILLink.Tasks'; Roll = 'disable'; Version = $version
                Path = 'packages.lock.json'; Tracked = $true; Implicit = $true
            }
        }
        $excludedPaths = @('vendor/packages.lock.json', 'external/packages.lock.json', 'untracked/packages.lock.json')
        foreach ($path in $excludedPaths) {
            @{
                Package = 'Microsoft.NET.ILLink.Tasks'; Roll = 'latestFeature'; Version = '10.0.203'
                Path = $path; Tracked = $path -ne 'untracked/packages.lock.json'; Implicit = $false
            }
        }
    )
    $index = 0
    foreach ($case in $cases) {
        $index++
        $root = Join-Path $sandbox "case-$index"
        $null = [IO.Directory]::CreateDirectory((Join-Path $root '.github/lint'))
        foreach ($file in @('App.slnx', 'Directory.Build.props', '.editorconfig', '.gitattributes')) {
            [IO.File]::WriteAllText((Join-Path $root $file), '')
        }
        [IO.File]::WriteAllText((Join-Path $root '.github/lint/vendored-paths.txt'), "vendor/`n/external/`n")
        $globalJson = @{ sdk = @{ version = $case.Version; rollForward = $case.Roll } } | ConvertTo-Json -Depth 2
        [IO.File]::WriteAllText((Join-Path $root 'global.json'), $globalJson)
        $null = & git -C $root init -q
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the test repository.' }
        $null = & git -C $root add -- .
        if ($LASTEXITCODE -ne 0) { throw 'Could not index the test configuration.' }
        $lockPath = Join-Path $root $case.Path
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $lockPath))
        $dependency = @{ $case.Package = @{ type = 'Direct'; resolved = '10.0.3' } }
        $packages = @{ version = 1; dependencies = @{ 'net10.0' = $dependency } }
        [IO.File]::WriteAllText($lockPath, ($packages | ConvertTo-Json -Depth 5))
        if ($case.Tracked) {
            $null = & git -C $root add -- $case.Path
            if ($LASTEXITCODE -ne 0) { throw 'Could not index the test lock file.' }
        }
        $expected = ''
        if ($case.Implicit -and ($case.Roll -ne 'disable' -or $case.Version -ne '10.0.203')) {
            $expected = "global.json(1,1): CS-24 packages.lock.json has $($case.Package); " +
            'pin the exact SDK with rollForward disable'
        } elseif (-not $case.Implicit -and $case.Roll -ne 'latestFeature') {
            $expected = 'global.json(1,1): CS-24 pin sdk.version 10.x with rollForward latestFeature'
        }
        $output = & dotnet $assembly $root 2>&1
        $code = $LASTEXITCODE
        $actual = ($output -join "`n").Trim()
        $expectedCode = if ($expected) { 1 } else { 0 }
        $name = "$($case.Package), $($case.Roll), $($case.Version), $($case.Path)"
        if ($code -ne $expectedCode -or $actual -cne $expected) {
            throw "$name expected exit $expectedCode and '$expected'; got exit $code and '$actual'"
        }
        Write-Host "ok $name"
    }
    $unityCases = @(
        @{
            Name = 'catch variable'; Finding = $true
            Code = 'void Run() { try { Work(); } catch (Exception ex) { Debug.LogError(ex.Message); } }'
        }
        @{
            Name = 'catch inner exception'; Finding = $true
            Code = 'void Run() { try { Work(); } catch (Exception ex) { Debug.LogError(ex.InnerException.Message); } }'
        }
        @{
            Name = 'typed parameter'; Finding = $true
            Code = 'void Run(System.Exception ex) { Debug.LogError(ex.Message); }'
        }
        @{
            Name = 'pattern variable'; Finding = $true
            Code = 'void Run(object value) { if (value is IOException io) { Debug.LogError(io.Message); } }'
        }
        @{
            Name = 'record message'; Finding = $false
            Code = 'void Run(SquishProblem problem) { Debug.LogError(LogPrefix + problem.Message, problem.Context); }'
        }
        @{
            Name = 'log exception'; Finding = $false
            Code = 'void Run(Exception ex, object context) { Debug.LogException(ex, context); }'
        }
        @{
            Name = 'typed local'; Finding = $true
            Code = 'void Run() { IOException io = GetError(); Debug.LogWarning(io.Message); }'
        }
        @{
            Name = 'parameter inner exception'; Finding = $true
            Code = 'void Run(Exception ex) { Debug.LogError(ex.InnerException.Message); }'
        }
        @{
            Name = 'local inner exception'; Finding = $true
            Code = 'void Run() { Exception ex = GetError(); Debug.LogError(ex.InnerException.Message); }'
        }
        @{
            Name = 'pattern inner exception'; Finding = $true
            Code = 'void Run(object value) { if (value is IOException io) Debug.LogError(io.InnerException.Message); }'
        }
        @{
            Name = 'record inner exception'; Finding = $false
            Code = 'void Run(SquishProblem problem) { Debug.LogError(problem.InnerException.Message); }'
        }
        @{
            Name = 'other method parameter'; Finding = $false
            Code = 'void Other(Exception ex) { Work(); } void Run(SquishProblem ex) { Debug.LogError(ex.Message); }'
        }
        @{
            Name = 'other catch scope'; Finding = $false
            Code = 'void Run() { try { Work(); } catch (Exception ex) { Work(); } ' +
            '{ SquishProblem ex = GetProblem(); Debug.LogError(ex.Message); } }'
        }
        @{
            Name = 'inferred local'; Finding = $false
            Code = 'void Run() { var ex = GetProblem(); Debug.LogError(ex.Message); }'
        }
        @{
            Name = 'exception field'; Finding = $false
            Code = 'Exception ex; void Run() { Debug.LogError(ex.Message); }'
        }
        @{
            Name = 'nullable parameter'; Finding = $true
            Code = 'void Run(System.Exception? ex) { if (ex != null) Debug.LogError(ex.Message); }'
        }
        @{
            Name = 'parenthesized exception'; Finding = $true
            Code = 'void Run(Exception ex) { Debug.LogError((ex).Message); }'
        }
        @{
            Name = 'captured exception'; Finding = $true
            Code = 'void Run(Exception ex) { Action log = () => Debug.LogError(ex.Message); }'
        }
    )
    foreach ($case in $unityCases) {
        $index++
        $root = Join-Path $sandbox "case-$index"
        $null = [IO.Directory]::CreateDirectory((Join-Path $root '.github/lint'))
        $null = [IO.Directory]::CreateDirectory((Join-Path $root 'ProjectSettings'))
        [IO.File]::WriteAllText((Join-Path $root '.github/lint/vendored-paths.txt'), '')
        [IO.File]::WriteAllText((Join-Path $root 'ProjectSettings/ProjectVersion.txt'), '2022.3.22f1')
        $code = 'record SquishProblem(string Message, object Context); class Sample { ' + $case.Code + ' }'
        [IO.File]::WriteAllText((Join-Path $root 'Sample.cs'), $code)
        $null = & git -C $root init -q
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the Unity test repository.' }
        $null = & git -C $root add -- .
        if ($LASTEXITCODE -ne 0) { throw 'Could not index the Unity test source.' }
        $output = & dotnet $assembly $root 2>&1
        $exitCode = $LASTEXITCODE
        $actual = ($output -join "`n").Trim()
        $expectedCode = if ($case.Finding) { 1 } else { 0 }
        $diagnostic = '^Sample.cs\(1,\d+\): CS-14 log exceptions with Debug\.LogException\(ex, context\)$'
        $isMatch = if ($case.Finding) { $actual -cmatch $diagnostic } else { $actual -ceq '' }
        if ($exitCode -ne $expectedCode -or -not $isMatch) {
            throw "$($case.Name) expected exit $expectedCode; got exit $exitCode and '$actual'"
        }
        Write-Host "ok $($case.Name)"
    }
    Write-Host "All $index CSharpStyle cases passed."
} finally {
    $resolvedSandbox = [IO.Path]::GetFullPath($sandbox)
    $isTemporary = $resolvedSandbox.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)
    if (-not $isTemporary -or $resolvedSandbox -eq $temporaryRoot) {
        throw "Refusing to remove a directory outside the temporary root: $resolvedSandbox"
    }
    Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force
}
exit 0
