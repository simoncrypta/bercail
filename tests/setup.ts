// Each TypeScript test file: cut off from the desk it started from, as
// setup_suite.bash and isolate() do for bats. No hc, Herdr, bercail or beads
// variables, the same clock zone everywhere, and a HOME and XDG dirs of its own.
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll } from "vite-plus/test";

for (const key of Object.keys(process.env)) {
  if (/^(HC|HERDR|BERCAIL|BEADS|BD|HANDOFF)_/.test(key) || key === "BASH_ENV") delete process.env[key];
}
const home = mkdtempSync(join(tmpdir(), "bercail-vitest-"));
mkdirSync(join(home, "run"), { mode: 0o700 });
Object.assign(process.env, {
  TZ: "UTC",
  HOME: home,
  XDG_CONFIG_HOME: join(home, ".config"),
  XDG_STATE_HOME: join(home, ".local/state"),
  XDG_DATA_HOME: join(home, ".local/share"),
  XDG_CACHE_HOME: join(home, ".cache"),
  XDG_RUNTIME_DIR: join(home, "run"),
});

afterAll(() => {
  rmSync(home, { recursive: true, force: true });
});
