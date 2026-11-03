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

const cases = [
  { name: "as const", expression: "{ value: 1 } as const", expected: 0 },
  { name: "as const satisfies", expression: "{ value: 1 } as const satisfies Record<string, number>", expected: 0 },
  { name: "satisfies", expression: "{ value: 1 } satisfies Record<string, number>", expected: 0 },
  { name: "nested as const", expression: "{ nested: { value: 1 } as const }", expected: 0 },
  { name: "nested and outer as const", expression: "{ nested: { value: 1 } as const } as const", expected: 0 },
  { name: "nested as const satisfies", expression: "{ nested: { value: 1 } as const satisfies Foo }", expected: 0 },
  { name: "as Foo", expression: "{ value: 1 } as Foo", expected: 1 },
  { name: "as unknown as Foo", expression: "{ value: 1 } as unknown as Foo", expected: 1 },
  { name: "angle assertion", expression: "<Foo>{ value: 1 }", expected: 1 },
  { name: "as unknown", expression: "{ value: 1 } as unknown", expected: 1 },
  { name: "as any", expression: "{ value: 1 } as any", expected: 1 },
  { name: "as inline type", expression: "{ value: 1 } as { value: number }", expected: 1 },
  {
    name: "nested const in asserted object",
    expression: "{ nested: { value: 1 } as const } as { nested: Foo }",
    expected: 1,
  },
  { name: "nested assertion in const object", expression: "{ nested: { value: 1 } as Foo } as const", expected: 1 },
  { name: "assertion before satisfies", expression: "{ value: 1 } as Foo satisfies Foo", expected: 1 },
];
const files = ["lint-snippet.ts", "lint-snippet.config.ts", "tests/lint-snippet.test.ts"];
const configs = ["lint/typescript/eslint.config.mjs", "eslint.config.mjs"];
const failures = [];
for (const config of configs) {
  const eslint = new ESLint({
    overrideConfigFile: config,
    overrideConfig: {
      files: ["**/*.ts"],
      languageOptions: {
        parserOptions: {
          tsconfigRootDir: process.cwd(),
          projectService: { allowDefaultProject: files },
        },
      },
    },
  });
  for (const filePath of files) {
    for (const test of cases) {
      const name = `${config}: ${filePath}: ${test.name}`;
      const code = `export type Foo = { value: number }; export const table = ${test.expression};`;
      const [result] = await eslint.lintText(code, { filePath });
      try {
        assert.equal(result.fatalErrorCount, 0, JSON.stringify(result.messages));
        assert.equal(result.warningCount, 0, JSON.stringify(result.messages));
        const reports = result.messages.filter((message) => message.ruleId === "no-restricted-syntax");
        assert.equal(reports.length, test.expected, JSON.stringify(result.messages));
        if (test.expected === 0) assert.deepEqual(result.messages, []);
        process.stdout.write(`ok ${name}\n`);
      } catch (error) {
        failures.push(name);
        process.stderr.write(`FAIL ${name}: ${error.message}\n`);
      }
    }
  }
}
assert.equal(failures.length, 0, `${failures.length} TypeScript syntax checks failed.`);
process.stdout.write(`All ${configs.length * files.length * cases.length} TypeScript syntax checks passed.\n`);
'@

Push-Location -LiteralPath $root
try {
    $node = (Get-Command -Name node -CommandType Application).Source
    $script | & $node --input-type=module -
    if ($LASTEXITCODE -ne 0) { throw "TypeScript syntax checks failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
exit 0
