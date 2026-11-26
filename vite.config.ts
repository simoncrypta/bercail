import { defineConfig } from "vite-plus";

// Vendored byte for byte, kept diffable against upstream: pstack's statechart skill
// (skills/statechart/UPSTREAM.md) and pi-emphasis (bstack/pi/extensions/pi-emphasis/UPSTREAM.md).
// bercail's own scripts beside them are checked.
const UPSTREAM_COPIES = [
  "skills/statechart/scripts/backends/**",
  "skills/statechart/scripts/frontends/**",
  "skills/statechart/scripts/passes/**",
  "skills/statechart/scripts/{ir,janitor,kill,pipeline,run,statechart,worker}.ts",
  "bstack/pi/extensions/pi-emphasis/**",
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
      "bercail/mods/bercail-pane/**",
      // Written by `entire enable --agent pi` and overwritten on each install: not ours to format.
      ".pi/extensions/entire/**",
      ...UPSTREAM_COPIES,
    ],
  },
  lint: {
    // The Herdr mods get their own pass (tests/lint.sh): the jsconfig.json that
    // `herdr-app check` writes beside a mod would type-check it here and not in CI.
    // Entire's generated Pi extension is overwritten on each install, so it is not ours to lint.
    ignorePatterns: ["bercail/mods/**", ".pi/extensions/entire/**", ...UPSTREAM_COPIES],
    jsPlugins: [{ name: "vite-plus", specifier: "vite-plus/oxlint-plugin" }],
    rules: { "vite-plus/prefer-vite-plus-imports": "error" },
    options: { typeAware: true, typeCheck: true },
  },
  // The TypeScript unit tests. The shell tests and the live proofs are bats (tests/run.sh).
  test: {
    include: ["tests/**/*.test.ts"],
    setupFiles: ["tests/setup.ts"],
    // A guard against a hung test, not a speed check: tests that start the
    // question CLI a dozen times take over 5 seconds on a busy 4-core runner.
    testTimeout: 30_000,
    unstubEnvs: true,
    unstubGlobals: true,
  },
});
