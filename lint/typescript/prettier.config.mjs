const installed = (name) => {
  try {
    import.meta.resolve(name);
    return true;
  } catch {
    return false;
  }
};

export default {
  printWidth: 160,
  trailingComma: "es5",
  plugins: ["prettier-plugin-svelte", "prettier-plugin-astro"].filter(installed),
};
