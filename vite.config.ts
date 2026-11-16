import { defineConfig } from "vite-plus";

// pstack's statechart skill, vendored byte for byte (skills/statechart/UPSTREAM.md):
// kept diffable against upstream. bercail's own scripts beside it are checked.
const STATECHART_UPSTREAM = [
  "skills/statechart/scripts/backends/**",
  "skills/statechart/scripts/frontends/**",
  "skills/statechart/scripts/passes/**",
  "skills/statechart/scripts/{ir,pipeline,run,statechart,worker}.ts",
];

export default defineConfig({
  fmt: {
    printWidth: 120,
    ignorePatterns: [
      // TS and JS only: prose, data and CI files keep their hand layout.
      "**/*.md",
      "**/*.json",
      "**/*.jsonc",
      "**/*.yaml",
      "**/*.yml",
      "**/*.toml",
      // Copies of Herdr's own mods (mod.json `cloned_from`): kept diffable against upstream.
      "bercail/mods/bercail-agents/**",
      "bercail/mods/bercail-spaces/**",
      // Written by `entire enable --agent pi` and overwritten on each install: not ours to format.
      ".pi/extensions/entire/**",
      ...STATECHART_UPSTREAM,
    ],
  },
  lint: {
    // The Herdr mods get their own pass (tests/lint.sh): the jsconfig.json that
    // `herdr-app check` writes beside a mod would type-check it here and not in CI.
    // Entire's generated Pi extension is overwritten on each install, so it is not ours to lint.
    ignorePatterns: ["bercail/mods/**", ".pi/extensions/entire/**", ...STATECHART_UPSTREAM],
    jsPlugins: [{ name: "vite-plus", specifier: "vite-plus/oxlint-plugin" }],
    rules: { "vite-plus/prefer-vite-plus-imports": "error" },
    options: { typeAware: true, typeCheck: true },
  },
  // The TypeScript unit tests. The shell tests and the live proofs are bats (tests/run.sh).
  test: {
    include: ["tests/**/*.test.ts"],
    setupFiles: ["tests/setup.ts"],
    unstubEnvs: true,
    unstubGlobals: true,
  },
});
