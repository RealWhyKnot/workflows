import { globSync, readFileSync } from "node:fs";
import path from "node:path";
import stylelint from "stylelint";

const root = import.meta.dirname;
const references = globSync("**/*.css", { cwd: root, exclude: (file) => file.includes("node_modules") });
const isCalm = references.some((file) => /prefers-reduced-motion\s*:\s*reduce/.test(readFileSync(path.join(root, file), "utf8")));

const {
  createPlugin,
  utils: { report, ruleMessages },
} = stylelint;

const licence = /licen[cs]e|copyright|SPDX-License-Identifier/i;
const keyword = /^(inherit|initial|unset|revert|revert-layer)$/;
const rawColor = /#[\da-f]{3,8}\b|\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\)/i;
const quotedOrUrl = /url\([^)]*\)|"[^"]*"|'[^']*'/g;
const tokenHome = /^(:root|html|:host)?(\[[^\]]+\])*$/;
const motionProperty = /^(transition|animation)(-name|-property|-duration)?$/;
const states = [
  "active",
  "checked",
  "collapsed",
  "current",
  "disabled",
  "expanded",
  "focused",
  "hidden",
  "invalid",
  "loading",
  "off",
  "on",
  "open",
  "opened",
  "paused",
  "playing",
  "pressed",
  "selected",
  "show",
  "shown",
  "visible",
];
const className = new RegExp(`^(?!(is|has)-)(?!(${states.join("|")})$)[a-z][a-z0-9]*(-[a-z0-9]+)*$`);

const ignored = [
  "**/node_modules/**",
  "**/dist/**",
  "**/build/**",
  "**/out/**",
  "**/coverage/**",
  "**/.vite/**",
  "**/.svelte-kit/**",
  "**/.astro/**",
  "**/vendor/**",
  "**/third_party/**",
  "**/.yarn/**",
];

const within = (node, name, params) => {
  for (let parent = node.parent; parent; parent = parent.parent) {
    if (parent.type === "atrule" && parent.name === name && (!params || params.test(parent.params))) return true;
  }
  return false;
};

const rule = (name, check) => {
  const messages = ruleMessages(name, { rejected: (text) => text });
  const ruleFunction = (primary) => (styles, result) => {
    if (!primary) return;
    check(styles, (node, text) => {
      report({ ruleName: name, result, node, message: messages.rejected, messageArgs: [text] });
    });
  };
  ruleFunction.ruleName = name;
  ruleFunction.messages = messages;
  return createPlugin(name, ruleFunction);
};

const comments = rule("local/comments", (styles, flag) => {
  let isFirst = true;
  styles.walkComments((comment) => {
    const text = comment.text.trim();
    if (/^stylelint-/.test(text)) {
      flag(comment, "No inline lint config or suppressions (GEN-4). Change the code, or turn the check off for everyone.");
    } else if (!(isFirst && licence.test(text))) {
      flag(comment, "No comments (GEN-29).");
    }
    isFirst = false;
  });
});

const important = rule("local/important", (styles, flag) => {
  styles.walkDecls((decl) => {
    if (!decl.important) return;
    if (within(decl, "media", /prefers-reduced-motion\s*:\s*reduce/)) return;
    if (decl.parent?.type === "rule" && decl.parent.selector === "[hidden]") return;
    flag(decl, "!important only in a prefers-reduced-motion reset or the [hidden] rule (CSS-4).");
  });
});

const inlineStyle = rule("local/inline-style", (styles, flag) => {
  if (!styles.source?.inline) return;
  styles.walkDecls((decl) => {
    if (!decl.prop.startsWith("--")) flag(decl, "A style attribute may only set custom properties; put the rest in a class (CSS-5).");
  });
});

const fileName = rule("local/file-name", (styles, flag) => {
  const file = styles.source?.input.file;
  if (styles.source?.inline || !file?.endsWith(".css")) return;
  if (!/^[a-z0-9]+(-[a-z0-9]+)*(\.user)?\.css$/.test(path.basename(file))) flag(styles, "CSS files are kebab-case.");
});

const isTokenHome = (decl) => {
  const parent = decl.parent;
  if (parent?.type === "atrule") return parent.name === "theme";
  return parent?.type === "rule" && parent.selectors.every((selector) => selector !== "" && tokenHome.test(selector));
};

const tokens = rule("local/tokens", (styles, flag) => {
  styles.walkDecls((decl) => {
    const prop = decl.prop.toLowerCase();
    const value = decl.value.trim();
    const hasRawColor = rawColor.test(value.replace(quotedOrUrl, ""));
    if (prop.startsWith("--")) {
      if (hasRawColor && !isTokenHome(decl)) flag(decl, "Declare colour tokens in :root, a theme attribute selector or @theme (CSS-2).");
      return;
    }
    if (within(decl, "font-face")) return;
    const isToken = value.includes("var(") || keyword.test(value);
    if (hasRawColor) {
      flag(decl, "Use a colour token, such as var(--color-accent) (CSS-2).");
    } else if (prop === "z-index" && !isToken && !/^(auto|-?[01])$/.test(value)) {
      flag(decl, "Use a layer token for a z-index above 1, such as var(--layer-dialog) (CSS-2).");
    } else if ((prop === "font-family" || prop === "font") && !isToken) {
      flag(decl, "Use a font token, such as var(--font-body) (CSS-2).");
    }
  });
});

const motion = rule("local/motion", (styles, flag) => {
  if (isCalm) return;
  styles.walkDecls((decl) => {
    if (!motionProperty.test(decl.prop.toLowerCase()) || /^(none|0m?s)$/i.test(decl.value.trim())) return undefined;
    flag(decl, "Add a prefers-reduced-motion: reduce reset to a global stylesheet (CSS-7).");
    return false;
  });
});

export default {
  extends: ["stylelint-config-standard"],
  plugins: ["stylelint-high-performance-animation", comments, fileName, important, inlineStyle, motion, tokens],
  ignoreDisables: true,
  ignoreFiles: ignored,
  referenceFiles: references,
  overrides: [
    {
      files: ["**/*.svelte", "**/*.vue", "**/*.astro", "**/*.html"],
      customSyntax: "postcss-html",
      rules: { "custom-property-empty-line-before": null },
    },
    {
      files: ["**/*.user.css"],
      rules: {
        "local/important": null,
        "no-unknown-custom-properties": null,
        "selector-class-pattern": null,
        "selector-id-pattern": null,
        "selector-max-id": null,
        "selector-max-compound-selectors": null,
        "selector-max-specificity": null,
        "selector-no-qualifying-type": null,
        "no-descending-specificity": null,
      },
    },
  ],
  rules: {
    "local/comments": true,
    "local/file-name": true,
    "local/important": true,
    "local/inline-style": true,
    "local/motion": true,
    "local/tokens": true,
    "plugin/no-low-performance-animation-properties": [true, { ignore: "paint-properties" }],
    "import-notation": "string",
    "selector-max-id": 0,
    "selector-class-pattern": [
      className,
      {
        message: (selector) =>
          `Class "${selector}" must be kebab-case and can't be a state like is-open or active; put state in an aria- or data- attribute (CSS-3).`,
      },
    ],
    "selector-max-compound-selectors": 3,
    "selector-max-specificity": ["0,4,0", { ignoreSelectors: [":not", ":is", ":has", ":where"] }],
    "selector-no-qualifying-type": [true, { ignore: ["attribute"] }],
    "max-nesting-depth": [1, { ignoreAtRules: ["media", "supports", "container", "layer"] }],
    "selector-disallowed-list": ["/^:global/"],
    "selector-pseudo-class-disallowed-list": ["focus"],
    "selector-pseudo-class-no-unknown": [true, { ignorePseudoClasses: ["global", "deep", "slotted"] }],
    "color-named": "never",
    "no-unknown-custom-properties": true,
    "declaration-property-unit-allowed-list": {
      "/^font(-size)?$/": ["rem", "em", "%", "vw", "vi", "cqi", "cqw"],
      "line-height": [],
    },
    "declaration-property-value-disallowed-list": {
      "/^(transition|transition-property)$/": ["/\\ball\\b/"],
      "/^outline(-style)?$/": ["none", "0"],
      "/^font(-size)?$/": ["/^(?!.*\\d(rem|em|%)).*\\d(vw|vi|cqi|cqw)\\b/"],
      "/^(height|min-height|max-height|block-size|min-block-size|max-block-size)$/": ["/^100vh$/"],
      "/^(width|min-width|max-width|inline-size|min-inline-size|max-inline-size)$/": ["/^100vw$/"],
    },
    "at-rule-disallowed-list": ["apply"],
    "at-rule-no-unknown": [true, { ignoreAtRules: ["theme", "source", "utility", "variant", "custom-variant", "plugin", "config", "reference"] }],
  },
};
