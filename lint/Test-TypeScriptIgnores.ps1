#!/usr/bin/env pwsh
#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$script = @'
import assert from "node:assert/strict";
import { ESLint } from "eslint";
import { readFileSync } from "node:fs";

assert.equal(
  readFileSync("eslint.config.mjs", "utf8"),
  readFileSync("lint/typescript/eslint.config.mjs", "utf8"),
  "eslint.config.mjs differs from lint/typescript/eslint.config.mjs."
);
const configs = ["eslint.config.mjs"];
const cases = [
  { path: "eslint-ignore-[x]/sample.ts", ignored: true },
  { path: "eslint-ignore-x/sample.ts", ignored: false },
  { path: "lint-snippet.ts", ignored: false },
  { path: "tests/lint-snippet.test.ts", ignored: false },
];
const failures = [];
for (const config of configs) {
  const eslint = new ESLint({ overrideConfigFile: config });
  for (const test of cases) {
    const name = `${config}: ${test.path}`;
    try {
      assert.equal(await eslint.isPathIgnored(test.path), test.ignored);
      process.stdout.write(`ok ${name}\n`);
    } catch (error) {
      failures.push(name);
      process.stderr.write(`FAIL ${name}: ${error.message}\n`);
    }
  }
}
assert.equal(failures.length, 0, `${failures.length} ESLint ignore checks failed.`);
process.stdout.write(`All ${configs.length * cases.length} ESLint ignore checks passed.\n`);
'@

$checkDir = Join-Path $root 'eslint-ignore-[x]'
$null = New-Item -ItemType Directory -Path $checkDir -Force
Push-Location -LiteralPath $root
try {
    [System.IO.File]::WriteAllText((Join-Path $checkDir '.gitignore'), "*`n")
    [System.IO.File]::WriteAllText((Join-Path $checkDir 'sample.ts'), "export const sample = 1;`n")
    $node = @(Get-Command -Name node -CommandType Application)[0].Source
    $script | & $node --input-type=module -
    if ($LASTEXITCODE -ne 0) { throw "ESLint ignore checks failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $checkDir -Recurse -Force
}
exit 0
