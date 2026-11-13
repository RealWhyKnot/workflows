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
          projectService: { allowDefaultProject: [...files, "lint-guards.*"] },
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
  for (const extension of ["js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx"]) {
    const filePath = `lint-guards.${extension}`;
    const guards = new ESLint({
      overrideConfigFile: config,
      overrideConfig: {
        languageOptions: {
          parserOptions: {
            tsconfigRootDir: process.cwd(),
            projectService: extension.includes("t") ? { allowDefaultProject: [...files, "lint-guards.*"] } : false,
          },
        },
      },
    });
    const resolved = await guards.calculateConfigForFile(filePath);
    assert.equal(resolved.linterOptions.noInlineConfig, true, filePath);
    assert.equal(resolved.linterOptions.reportUnusedDisableDirectives, 2, filePath);
    const checks = [
      { name: "600 lines", code: "void 0;\n".repeat(600), rule: "max-lines", expected: 0 },
      { name: "601 lines", code: "void 0;\n".repeat(601), rule: "max-lines", expected: 1 },
      { name: "blank lines count", code: "\n".repeat(600) + "void 0;", rule: "max-lines", expected: 1 },
      { name: "comment lines count", code: "// text\n".repeat(600) + "void 0;", rule: "max-lines", expected: 1 },
      { name: "final newline is not a line", code: "\n".repeat(599) + "void 0;\n", rule: "max-lines", expected: 0 },
      {
        name: "dynamic delete",
        code: 'const values = { a: 1 }; const key = "a"; delete values[key];',
        rule: "@typescript-eslint/no-dynamic-delete",
        expected: 1,
      },
      {
        name: "static delete",
        code: 'const values = { a: 1 }; delete values["a"];',
        rule: "@typescript-eslint/no-dynamic-delete",
        expected: 0,
      },
      {
        name: "inline config cannot disable rules",
        code: [
          '/* eslint @typescript-eslint/no-dynamic-delete: off */',
          'const values = { a: 1 }; const key = "a"; delete values[key];',
        ].join("\n"),
        rule: "@typescript-eslint/no-dynamic-delete",
        expected: 1,
      },
    ];
    for (const check of checks) {
      const name = `${config}: ${filePath}: ${check.name}`;
      const [result] = await guards.lintText(check.code, { filePath });
      assert.equal(result.fatalErrorCount, 0, `${name}: ${JSON.stringify(result.messages)}`);
      const reports = result.messages.filter((message) => message.ruleId === check.rule);
      assert.equal(reports.length, check.expected, name);
    }
    process.stdout.write(`ok ${config}: ${filePath}: lint guards\n`);
  }
}
assert.equal(failures.length, 0, `${failures.length} TypeScript syntax checks failed.`);
process.stdout.write(`All ${configs.length * files.length * cases.length} TypeScript syntax checks passed.\n`);
process.stdout.write("All 128 lint guard checks passed.\n");
'@

Push-Location -LiteralPath $root
try {
    $node = @(Get-Command -Name node -CommandType Application)[0].Source
    $script | & $node --input-type=module -
    if ($LASTEXITCODE -ne 0) { throw "TypeScript syntax checks failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
exit 0
