// bstack: TLC's whole state graph for a config, as JSON, so a test can replay
// every shortest path on the real code (the paths come from TLC, not from a
// second model). Usage: graph.ts SPEC.tla CONFIG.cfg OUT.json. Needs TLA2TOOLS
// and JAVA; statechart-bstack sets them and bounds the run.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { configText } from "./backends/cfg.ts";
import { readConfig } from "./frontends/config.ts";
import { parseDot } from "./frontends/dot.ts";
import { json } from "./frontends/view.ts";

const [specFile, configFile, outFile] = process.argv.slice(2);
if (!specFile || !configFile || !outFile) {
  console.error("Usage: statechart-bstack graph SPEC.tla CONFIG.cfg OUT.json");
  process.exit(2);
}
const sha256 = (file: string) => createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "statechart-graph-"));
try {
  // Without its rules: the dump is every reachable state, not the way to the first break.
  const cfg = readConfig({ file: configFile, text: fs.readFileSync(configFile, "utf8") });
  const kept = cfg.sections.filter((s) => !/^(INVARIANTS?|PROPERTY|PROPERTIES)$/.test(s.key));
  fs.writeFileSync(path.join(dir, "graph.cfg"), configText(kept, []));
  // As upstream runs it: from the temp folder, the spec found on TLA-Library.
  const folder = path.dirname(path.resolve(specFile));
  const r = spawnSync(
    process.env.JAVA!,
    ["-cp", process.env.TLA2TOOLS!, `-DTLA-Library=${folder}`, "tlc2.TLC", "-workers", "1", "-fp", "0", "-deadlock"]
      .concat(["-metadir", path.join(dir, "meta"), "-config", path.join(dir, "graph.cfg")])
      .concat(["-dump", "dot,actionlabels", path.join(dir, "graph"), path.basename(specFile, ".tla")]),
    { cwd: dir, encoding: "utf8", maxBuffer: 1 << 28 },
  );
  if (r.status !== 0) {
    console.error(`TLC exited ${r.status}:\n${`${r.stdout}${r.stderr}`.trim().split("\n").slice(-20).join("\n")}`);
    process.exit(2);
  }
  const graph = parseDot(fs.readFileSync(path.join(dir, "graph.dot"), "utf8"));
  const index = new Map([...graph.states.keys()].map((id, i) => [id, i]));
  const states = [...graph.states.values()].map((s) => ({
    start: s.start,
    vars: Object.fromEntries(Object.entries(s.vars).map(([k, v]) => [k, json(v)])),
  }));
  const steps = graph.steps.map((s) => [index.get(s.from), s.action, index.get(s.to)]);
  // One state or step a line: a diff of the file reads as a diff of the graph.
  const lines = [
    `{"spec": ${JSON.stringify(path.basename(specFile))}, "spec_sha256": "${sha256(specFile)}",`,
    ` "config": ${JSON.stringify(path.basename(configFile))}, "config_sha256": "${sha256(configFile)}",`,
    ` "states": [`,
    states.map((s) => `  ${JSON.stringify(s)}`).join(",\n"),
    ` ],`,
    ` "steps": [`,
    steps.map((s) => `  ${JSON.stringify(s)}`).join(",\n"),
    ` ]}`,
  ];
  fs.writeFileSync(outFile, `${lines.join("\n")}\n`);
  console.log(`${outFile}: ${states.length} states, ${steps.length} steps`);
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
