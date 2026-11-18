// A wait/admin worker has no shell or authoring tools. This is a tool surface,
// not an OS sandbox: trusted extensions still run with the user's permissions.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  const issue = process.env.BERCAIL_ISSUE || "";
  const cwd = process.cwd();
  const text = (value: string) => ({ content: [{ type: "text" as const, text: value.slice(-16000) }], details: {} });
  const call = (command: string, args: string[], input?: string, timeout = 30000): Promise<string> =>
    new Promise((resolve, reject) => {
      const child = execFile(
        command,
        args,
        {
          cwd,
          timeout,
          maxBuffer: 1024 * 1024,
          env: Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(BD_|BEADS_|GIT_)/.test(k))),
        },
        (error, stdout, stderr) => {
          if (error)
            reject(new Error(`${command}: ${stderr || error.message}; report the blocker, never ask in this terminal`));
          else resolve(stdout);
        },
      );
      child.stdin?.end(input);
    });
  pi.registerTool({
    name: "shep_issue",
    label: "Read assigned issue",
    description: "Read only this worker's assigned issue and comments.",
    parameters: Type.Object({}),
    async execute() {
      return text((await call("bd", ["show", issue])) + "\n" + (await call("bd", ["comments", issue])));
    },
  });
  pi.registerTool({
    name: "shep_wait",
    label: "Wait",
    description:
      "Wait for a CI run or desk, or a delay (seconds). No shell or follow-through writes. Report a bound timeout as incomplete.",
    parameters: Type.Object({
      kind: Type.Union([Type.Literal("ci"), Type.Literal("desk"), Type.Literal("delay")]),
      target: Type.String(),
    }),
    async execute(_id, args, signal) {
      if (signal?.aborted) throw new Error("wait cancelled; outcome incomplete");
      if (args.kind === "ci" && /^[1-9][0-9]*$/.test(args.target))
        return text(await call("gh", ["run", "watch", args.target, "--exit-status"], undefined, 3600000));
      if (args.kind === "desk" && /^[a-z0-9_-]+$/i.test(args.target))
        return text(await call("hc", ["wait", args.target], undefined, 3600000));
      if (args.kind === "delay" && /^[0-9]+$/.test(args.target) && Number(args.target) <= 3600)
        return text(await call("sleep", [args.target], undefined, 3601000));
      throw new Error("wait needs ci run id, desk address, or delay 0..3600 seconds");
    },
  });
  pi.registerTool({
    name: "shep_report",
    label: "Report assigned job",
    description:
      "Post the observed outcome or a precise blocker/next action on this issue. Not a closure or authorization receipt.",
    parameters: Type.Object({ report: Type.String() }),
    async execute(_id, args) {
      if (!args.report.trim()) throw new Error("report cannot be empty");
      return text(await call("bd", ["comment", issue, "--stdin"], args.report));
    },
  });
  // Defensive admission: a wrapper/config mistake cannot add coding tools.
  pi.on("tool_call", (event) => {
    if (!["read", "grep", "find", "ls", "shep_issue", "shep_wait", "shep_report"].includes(event.toolName))
      return {
        block: true,
        reason:
          "Background worker is wait/admin only. Continue coding/interactive authoring in the original visible owner; no role or approval transfer.",
      };
  });
  pi.on("session_start", () => {
    if (!issue || !["wait", "admin"].includes(process.env.BERCAIL_BG_KIND || ""))
      throw new Error("missing narrow background admission");
    // Pin the actual brief at startup in the worker's session, not today's file.
    pi.appendEntry("bercail-background-profile", {
      kind: process.env.BERCAIL_BG_KIND,
      generation: "wait-admin-1",
      brief: readFileSync(process.env.BERCAIL_BG_BRIEF!, "utf8"),
    });
  });
}
