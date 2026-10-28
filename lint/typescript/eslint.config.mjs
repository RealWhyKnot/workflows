import js from "@eslint/js";
import prettier from "eslint-config-prettier";
import { defineConfig, globalIgnores } from "eslint/config";
import globals from "globals";
import { globSync, readFileSync } from "node:fs";
import path from "node:path";
import tseslint from "typescript-eslint";

const root = import.meta.dirname;

const load = async (name) => {
  try {
    import.meta.resolve(name);
  } catch {
    return null;
  }
  return (await import(name)).default;
};

const vue = await load("eslint-plugin-vue");
const svelte = await load("eslint-plugin-svelte");
const astro = await load("eslint-plugin-astro");

const off = (level) => level === "off" || level === 0;
const asErrors = (configs) =>
  [configs].flat().map((config) =>
    config.rules
      ? {
          ...config,
          rules: Object.fromEntries(
            Object.entries(config.rules).map(([rule, value]) => {
              if (Array.isArray(value)) return [rule, off(value[0]) ? value : ["error", ...value.slice(1)]];
              return [rule, off(value) ? value : "error"];
            })
          ),
        }
      : config
  );

const workerEntries = globSync("**/wrangler.{toml,json,jsonc}", { cwd: root, exclude: (file) => file.includes("node_modules") }).flatMap((file) => {
  const text = readFileSync(path.join(root, file), "utf8");
  const main = /^\s*main\s*=\s*"([^"]+)"/m.exec(text) ?? /"main"\s*:\s*"([^"]+)"/.exec(text);
  return main?.[1] ? [path.posix.join(path.dirname(file).replaceAll("\\", "/"), main[1])] : [];
});

const toolEntries = ["**/*.config.{js,mjs,cjs,ts,mts,cts}", "**/*.d.ts", ...workerEntries];

const syntax = [
  { selector: "TSAsExpression[expression.type='ObjectExpression']", message: "Annotate or use satisfies instead of asserting an object literal (TS-4)." },
  {
    selector: "VariableDeclarator[id.typeAnnotation.typeAnnotation.typeName.name='Record'][init.type='ObjectExpression']",
    message: "A fixed table is `{ ... } as const satisfies Record<K, V>` (TS-4); runtime keys go in a Map.",
  },
  { selector: "Property[key.name='nodeIntegration'][value.value=true]", message: "nodeIntegration stays off (TS-7)." },
  { selector: "Property[key.name='contextIsolation'][value.value=false]", message: "contextIsolation stays on (TS-7)." },
  { selector: "CallExpression[callee.name='fetch'][arguments.length=1]", message: "Pass a signal to fetch, such as AbortSignal.timeout(ms) (TS-8)." },
  {
    selector: "CallExpression[callee.name='fetch'] > ObjectExpression:not(:has(> Property[key.name='signal'])):not(:has(> SpreadElement))",
    message: "Pass a signal to fetch, such as AbortSignal.timeout(ms) (TS-8).",
  },
  {
    selector: ":matches(ClassDeclaration, ClassExpression)[superClass.name=/Error$/]:not(:has(PropertyDefinition[key.name='name']))",
    message: "An Error subclass sets its name.",
  },
  {
    selector: "CallExpression[callee.object.property.name='message'][callee.property.name=/^(includes|startsWith|endsWith|match|indexOf)$/]",
    message: "Test errors with instanceof, not by their message.",
  },
  {
    selector: "BinaryExpression[operator=/^[!=]==?$/] > MemberExpression[property.name='message']",
    message: "Test errors with instanceof, not by their message.",
  },
  {
    selector: "UnaryExpression[operator='void'] > CallExpression:not([callee.property.name='catch'])",
    message: "Fire-and-forget is `void task().catch(log)`.",
  },
  { selector: "ExportAllDeclaration, ExportNamedDeclaration[source]", message: "No re-exports or barrel files; import the module itself." },
  {
    selector:
      "CallExpression[callee.property.name='catch'] > ArrowFunctionExpression:matches([body.type='Identifier'][body.name='undefined'], [body.type='Literal'][body.raw='null'], [body.type='UnaryExpression'][body.operator='void'])",
    message: "No empty catch (GEN-17): handle, log or rethrow the error.",
  },
  {
    selector: "ExportNamedDeclaration > VariableDeclaration[kind='let']",
    message: "No export let: modules export const, and Svelte props come from $props() (TS-3, TS-5).",
  },
  {
    selector:
      ":matches(CallExpression[callee.name=/^parse(Int|Float)$/], CallExpression[callee.object.name='Number'][callee.property.name=/^parse(Int|Float)$/]):not([arguments.1.type='Literal']:not([arguments.1.value=10]))",
    message: "Parse decimal numbers with Number() and check Number.isFinite; parseInt only for another radix.",
  },
];
const defaultExports = [
  { selector: "ExportDefaultDeclaration, TSExportAssignment, ExportSpecifier[exported.name='default']", message: "Named exports only (TS-3)." },
];
const testChecks = [
  {
    selector: "CallExpression[callee.name=/^(setTimeout|setInterval|sleep|delay|wait)$/], CallExpression[callee.property.name=/^(setTimeout|setInterval)$/]",
    message: "No real sleeps in tests; use fake timers or await the event (GEN-26).",
  },
  {
    selector:
      "CallExpression[callee.name='fetch']:matches([arguments.0.value=/^https?:..(?!localhost|127\\.0\\.0\\.1)/], [arguments.0.quasis.0.value.raw=/^https?:..(?!localhost|127\\.0\\.0\\.1)/])",
    message: "No network in tests: inject fetch or listen on port 0.",
  },
];
const svelteLegacy = [{ selector: "SvelteReactiveStatement", message: "Svelte 5 runes only: $derived or $effect, not $: (TS-5)." }];

const yesNo = ["is", "has", "can", "should", "will", "was", "did", "needs", "wants"];
const yesNoUpper = [...yesNo, ...yesNo.map((word) => `${word.toUpperCase()}_`)];

const hint = /^(@vitest-environment |@jsxImportSource |@vite-ignore$|webpackChunkName:|[#@]__PURE__$|\/ <reference )/;
const suppression = /^(eslint\b|eslint-|global |globals |exported |@ts-|svelte-ignore|prettier-ignore|c8 ignore|istanbul ignore)/;
const licence = /licen[cs]e|copyright|SPDX-License-Identifier/i;

const local = {
  rules: {
    comments: {
      meta: { type: "suggestion", schema: [] },
      create(context) {
        const markup = (node) => {
          const message = suppression.test(node.value.trim())
            ? "No inline lint config or suppressions (GEN-4). Change the code, or turn the check off for everyone."
            : "No comments (GEN-29).";
          context.report({ node, message });
        };
        return {
          Program() {
            const source = context.sourceCode;
            const comments = [...source.getAllComments(), ...(source.ast.templateBody?.comments ?? [])];
            comments.forEach((comment, index) => {
              const text = comment.value.trim();
              if (comment.type === "Shebang" || hint.test(text)) return;
              if (suppression.test(text)) {
                context.report({
                  loc: comment.loc,
                  message: "No inline lint config or suppressions (GEN-4). Change the code, or turn the check off for everyone.",
                });
                return;
              }
              if (index === 0 && licence.test(text)) return;
              context.report({ loc: comment.loc, message: "No comments (GEN-29)." });
            });
          },
          SvelteHTMLComment: markup,
          AstroHTMLComment: markup,
        };
      },
    },
    "file-name": {
      meta: { type: "suggestion", schema: [] },
      create(context) {
        return {
          Program(node) {
            const base = path.basename(context.filename);
            const relative = path.relative(root, context.filename).replaceAll("\\", "/");
            if (/\.(test|spec)\./.test(base) && !relative.split("/").includes("tests")) context.report({ node, message: "Tests live in tests/." });
            const name = base.split(".")[0] ?? "";
            if (name.startsWith("+") || /^\[.+\]$/.test(name)) return;
            const component = /\.(svelte|vue)$/.test(base) || (base.endsWith(".astro") && !relative.split("/").includes("pages"));
            const ok = component ? /^[A-Z][A-Za-z0-9]*$/.test(name) : /^[a-z0-9]+(-[a-z0-9]+)*$/.test(name);
            if (!ok) context.report({ node, message: component ? "Component files are PascalCase." : "Module files are kebab-case." });
          },
        };
      },
    },
    "fetch-ok": {
      meta: { type: "problem", schema: [] },
      create(context) {
        return {
          "VariableDeclarator[id.type='Identifier'][init.type='AwaitExpression'][init.argument.type='CallExpression'][init.argument.callee.name='fetch']"(
            node
          ) {
            const [variable] = context.sourceCode.getDeclaredVariables(node);
            const isChecked = variable?.references.some(({ identifier, init }) => {
              if (init) return false;
              const parent = identifier.parent;
              if (parent.type !== "MemberExpression" || parent.object !== identifier) return true;
              return parent.property.type === "Identifier" && (parent.property.name === "ok" || parent.property.name === "status");
            });
            if (!isChecked) context.report({ node, message: "Check res.ok before using a fetch response (TS-8)." });
          },
        };
      },
    },
  },
};

export default defineConfig(
  globalIgnores([
    "**/dist/",
    "**/build/",
    "**/out/",
    "**/coverage/",
    "**/.vite/",
    "**/.svelte-kit/",
    "**/.astro/",
    "**/.yarn/",
    "**/vendor/",
    "**/third_party/",
  ]),
  { linterOptions: { noInlineConfig: true } },
  js.configs.recommended,
  tseslint.configs.strictTypeChecked,
  tseslint.configs.stylisticTypeChecked,
  {
    languageOptions: {
      globals: { ...globals.node, ...globals.browser },
      parserOptions: {
        projectService: true,
        tsconfigRootDir: root,
        extraFileExtensions: [".vue", ".svelte", ".astro"],
      },
    },
    plugins: { local },
    rules: {
      eqeqeq: ["error", "smart"],
      "guard-for-in": "error",
      "no-restricted-syntax": ["error", ...syntax, ...defaultExports],
      "no-var": "error",
      "preserve-caught-error": ["error", { requireCatchParameter: true }],
      "prefer-const": "error",
      "local/comments": "error",
      "local/file-name": "error",
      "local/fetch-ok": "error",
      "@typescript-eslint/consistent-type-assertions": ["error", { assertionStyle: "as", objectLiteralTypeAssertions: "never" }],
      "@typescript-eslint/ban-ts-comment": ["error", { "ts-check": true, "ts-expect-error": true, "ts-ignore": true, "ts-nocheck": true }],
      "@typescript-eslint/consistent-type-definitions": ["error", "type"],
      "@typescript-eslint/naming-convention": [
        "error",
        { selector: "default", format: ["camelCase"], leadingUnderscore: "allow" },
        { selector: "variable", format: ["camelCase", "PascalCase"], leadingUnderscore: "allow" },
        { selector: "variable", modifiers: ["const", "global"], format: ["camelCase", "UPPER_CASE", "PascalCase"], leadingUnderscore: "allow" },
        { selector: "variable", types: ["boolean"], format: ["PascalCase"], prefix: yesNo, leadingUnderscore: "allow" },
        { selector: "variable", modifiers: ["const", "global"], types: ["boolean"], format: ["PascalCase", "UPPER_CASE"], prefix: yesNoUpper },
        { selector: "variable", modifiers: ["destructured"], types: ["boolean"], format: null },
        { selector: "parameter", types: ["boolean"], format: ["PascalCase"], prefix: yesNo, leadingUnderscore: "allow" },
        { selector: "parameter", modifiers: ["destructured"], types: ["boolean"], format: null },
        { selector: "classProperty", types: ["boolean"], format: ["PascalCase"], prefix: yesNo },
        { selector: "accessor", types: ["boolean"], format: ["PascalCase"], prefix: yesNo },
        { selector: "function", format: ["camelCase", "PascalCase"] },
        { selector: "import", format: ["camelCase", "PascalCase"] },
        { selector: "typeLike", format: ["PascalCase"] },
        { selector: "classProperty", modifiers: ["static", "readonly"], format: ["camelCase", "UPPER_CASE"] },
        { selector: ["objectLiteralProperty", "objectLiteralMethod", "typeProperty", "typeMethod"], format: null },
      ],
      "@typescript-eslint/no-confusing-void-expression": ["error", { ignoreArrowShorthand: true }],
      "@typescript-eslint/no-floating-promises": [
        "error",
        {
          allowForKnownSafeCalls: [
            { from: "package", package: "node:test", name: ["test", "it", "describe", "suite", "before", "after", "beforeEach", "afterEach"] },
          ],
        },
      ],
      "@typescript-eslint/non-nullable-type-assertion-style": "off",
      "@typescript-eslint/no-unsafe-type-assertion": "error",
      "@typescript-eslint/restrict-template-expressions": ["error", { allowNumber: true }],
      "@typescript-eslint/switch-exhaustiveness-check": "error",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_", caughtErrorsIgnorePattern: "^_" }],
    },
  },
  {
    files: toolEntries,
    rules: { "no-restricted-syntax": ["error", ...syntax] },
  },
  {
    files: ["**/tests/**", "**/*.test.*", "**/*.spec.*"],
    rules: { "no-restricted-syntax": ["error", ...syntax, ...defaultExports, ...testChecks] },
  },
  {
    files: ["**/Scripting/lmh.d.ts"],
    rules: { "local/comments": "off" },
  },
  vue
    ? [
        asErrors(vue.configs["flat/recommended"]),
        {
          files: ["**/*.vue"],
          languageOptions: { parserOptions: { parser: tseslint.parser } },
          rules: {
            "vue/block-lang": ["error", { script: { lang: "ts" } }],
            "vue/component-api-style": ["error", ["script-setup"]],
            "vue/define-emits-declaration": ["error", "type-based"],
            "vue/define-props-declaration": ["error", "type-based"],
          },
        },
      ]
    : [],
  svelte
    ? [
        asErrors(svelte.configs.recommended),
        {
          files: ["**/*.svelte", "**/*.svelte.ts", "**/*.svelte.js"],
          languageOptions: { parserOptions: { parser: tseslint.parser } },
          rules: {
            "no-restricted-syntax": ["error", ...syntax, ...defaultExports, ...svelteLegacy],
            "prefer-const": "off",
            "svelte/prefer-const": "error",
            "svelte/prefer-writable-derived": "error",
          },
        },
        svelte.configs.prettier,
      ]
    : [],
  astro
    ? [
        asErrors(astro.configs.recommended),
        {
          files: ["**/*.astro"],
          languageOptions: { parserOptions: { parser: tseslint.parser, projectService: false, project: true } },
          rules: { "max-lines": ["error", { max: 600 }], "no-restricted-syntax": ["error", ...syntax] },
        },
      ]
    : [],
  {
    files: ["**/*.{js,mjs,cjs,jsx}"],
    extends: [tseslint.configs.disableTypeChecked],
  },
  prettier
);
