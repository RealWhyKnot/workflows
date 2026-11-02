const isInstalled = (name) => {
  try {
    import.meta.resolve(name);
    return true;
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ERR_MODULE_NOT_FOUND") return false;
    throw error;
  }
};

export default {
  printWidth: 160,
  trailingComma: "es5",
  plugins: ["prettier-plugin-svelte", "prettier-plugin-astro"].filter(isInstalled),
};
