// Read-only source/install/loaded diagnostics. A current file hash never proves
// what an already-running process evaluated; only its own startup record can.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const resources: [string, string][] = [
  ["lib/shep.sh", "lib/shep.sh"],
  ["lib/shep-task.ts", "lib/shep-task.ts"],
  ["shep/SHEP.md", "shep/SHEP.md"],
  ["shep/BACKGROUND.md", "shep/BACKGROUND.md"],
  ["shep/pi/background.ts", "shep/pi/background.ts"],
  ["config/pi/extensions/bercail-desk.ts", "pi-extensions/bercail-desk.ts"],
  ["bstack/pi/extensions/guard.ts", "pi/extensions/guard.ts"],
  ["bstack/pi/instructions.md", "pi/instructions.md"],
  ["config/worktrunk/herdr-layout.sh", "../config/worktrunk/herdr-layout.sh"],
  ...["handoff", "desk-restore", "how", "why", "unslop", "describe"].map((name): [string, string] => [
    `skills/${name}/SKILL.md`,
    `skills/${name}/SKILL.md`,
  ]),
];
const hash = (path: string): string => {
  try {
    return createHash("sha256").update(readFileSync(path)).digest("hex");
  } catch {
    return "UNKNOWN";
  }
};
function ticks(pid: number): string {
  const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
  return stat.slice(stat.lastIndexOf(")") + 2).split(/\s+/)[19]!;
}
export function runtimeIdentity(source: string, share: string, state: string, config: string): any {
  let revision = "UNKNOWN";
  try {
    revision = execFileSync("git", ["-C", source, "rev-parse", "HEAD"], {
      encoding: "utf8",
      env: Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_"))),
      timeout: 1000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {}
  const files = resources.map(([src, dest]) => ({
    resource: src,
    source: hash(join(source, src)),
    installed: hash(
      src.startsWith("config/worktrunk/")
        ? join(config, "worktrunk/herdr-layout.sh")
        : src.startsWith("skills/")
          ? join(process.env.HOME!, ".agents", dest)
          : join(share, dest),
    ),
  }));
  const loaded: any[] = [];
  const runtime = join(state, "runtime");
  if (existsSync(runtime))
    for (const file of readdirSync(runtime)) {
      try {
        const record = JSON.parse(readFileSync(join(runtime, file), "utf8"));
        if (record.start_ticks && ticks(record.pid) === record.start_ticks) loaded.push(record);
      } catch {}
    }
  // Legacy desk records are shown explicitly, not retroactively fingerprinted.
  const desks = join(state, "desk-sessions");
  if (existsSync(desks))
    for (const file of readdirSync(desks)) {
      try {
        const r = JSON.parse(readFileSync(join(desks, file), "utf8"));
        if (ticks(r.pid) && !loaded.some((l) => l.pid === r.pid && l.desk === r.address && l.session === r.session))
          loaded.push({
            desk: r.address,
            session: r.session,
            generation: "UNKNOWN",
            guard_generation: "UNKNOWN",
            reason: "legacy or uninstrumented process; today's filesystem is not loaded evidence",
          });
      } catch {}
    }
  return {
    source_revision: revision,
    installed_revision: "UNKNOWN (resource fingerprints below)",
    files,
    drift: files.filter((f) => f.source !== f.installed).map((f) => f.resource),
    loaded: loaded.length ? loaded : "UNKNOWN (no live startup evidence)",
    coverage:
      "Surviving startup/desk records only. Unrecorded processes and uninstrumented guards are UNKNOWN, not a claim of global runtime parity.",
    authority: false,
  };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const home = process.env.HOME!;
  const share = process.env.BERCAIL_SHARE_DIR || join(home, ".local/share/bercail");
  console.log(
    JSON.stringify(
      runtimeIdentity(
        existsSync(join(dirname(dirname(fileURLToPath(import.meta.url))), ".git"))
          ? dirname(dirname(fileURLToPath(import.meta.url)))
          : existsSync(join(share, "source-path"))
            ? readFileSync(join(share, "source-path"), "utf8").trim()
            : dirname(dirname(fileURLToPath(import.meta.url))),
        share,
        join(process.env.XDG_STATE_HOME || join(home, ".local/state"), "bercail"),
        process.env.XDG_CONFIG_HOME || join(home, ".config"),
      ),
    ),
  );
}
