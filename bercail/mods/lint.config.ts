// The Herdr mods' lint (tests/lint.sh): the root config's rules without type
// information. Herdr loads plain JS, and the jsconfig.json `herdr-app check`
// writes beside a mod would make a type-aware pass differ between here and CI.
import { defineConfig } from "vite-plus";

export default defineConfig({
  lint: {
    jsPlugins: [{ name: "vite-plus", specifier: "vite-plus/oxlint-plugin" }],
    rules: { "vite-plus/prefer-vite-plus-imports": "error" },
  },
});
