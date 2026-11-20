// A background Shep waits and reports. Its bash runs under the guard as shep-bg,
// which refuses commits, pushes, tags and file edits, so a follow-up such as a
// trail merge goes back to Shep with its finish. This is a tool surface, not an
// OS sandbox: trusted extensions still run with the user's permissions.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { Type } from "typebox";

// Between two reads of a trail's gates.
const TRAIL_POLL_MS = 30000;

type Gate = { gate_key?: string; blocking?: boolean; status?: string; outcome?: string | null };
type Change = {
  repository?: string;
  number?: number;
  status?: string;
  current?: boolean;
  mergeability?: { head_sha?: string; mergeable?: boolean; gates?: Gate[] } | null;
};
type TrailGate = { state: "ready" | "pending" | "failed" | "moved"; text: string };

// Where one `entire trail show <n> --json` leaves a wait for the gates to pass
// on HEAD: the change the trail was reached through, or its one open change.
function trailGate(show: { changes?: Change[] }, head: string): TrailGate {
  const changes = show.changes ?? [];
  const open = changes.filter((c) => c.status !== "merged" && c.status !== "closed");
  const change = changes.find((c) => c.current) ?? (open.length === 1 ? open[0] : undefined);
  if (!change) return { state: "failed", text: `the trail has ${open.length} open changes; wait on one as <repo>/<n>` };
  const name = `${change.repository}/${change.number}`;
  if (change.status === "merged" || change.status === "closed")
    return { state: "failed", text: `${name} is already ${change.status}` };
  const m = change.mergeability;
  // Null is unknown, never mergeable (entire agent-help trail show).
  if (!m?.head_sha) return { state: "pending", text: `${name} has no gate state yet` };
  if (!m.head_sha.startsWith(head)) return { state: "moved", text: `${name} is at ${m.head_sha}, not ${head}` };
  const gates = (m.gates ?? []).filter((g) => g.blocking);
  const failed = gates.filter((g) => g.status === "failed" || g.outcome === "failed").map((g) => g.gate_key);
  if (failed.length) return { state: "failed", text: `${name} at ${m.head_sha}: ${failed.join(", ")} failed` };
  if (m.mergeable === true) return { state: "ready", text: `${name} at ${m.head_sha}: every blocking gate passed` };
  const waiting = gates.filter((g) => g.status !== "passed" && g.status !== "skipped").map((g) => g.gate_key);
  return { state: "pending", text: `${name} at ${m.head_sha}: waiting on ${waiting.join(", ") || "mergeability"}` };
}

export default function (pi: ExtensionAPI) {
  const issue = process.env.BERCAIL_ISSUE || "";
  const cwd = process.cwd();
  const text = (value: string) => ({ content: [{ type: "text" as const, text: value.slice(-16000) }], details: {} });
  const call = (command: string, args: string[], timeout = 30000, signal?: AbortSignal): Promise<string> =>
    new Promise((resolve, reject) => {
      const child = execFile(
        command,
        args,
        {
          cwd,
          timeout,
          signal,
          maxBuffer: 1024 * 1024,
          env: Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(BD_|BEADS_|GIT_)/.test(k))),
        },
        (error, stdout, stderr) => {
          if (signal?.aborted) reject(new Error("wait cancelled; outcome incomplete"));
          else if (error)
            reject(new Error(`${command}: ${stderr || error.message}; report the blocker, never ask in this terminal`));
          else resolve(stdout);
        },
      );
      child.stdin?.end();
    });
  const pause = (ms: number, signal: AbortSignal | undefined) =>
    new Promise<void>((resolve, reject) => {
      const timer = setTimeout(resolve, ms);
      signal?.addEventListener(
        "abort",
        () => {
          clearTimeout(timer);
          reject(new Error("wait cancelled; outcome incomplete"));
        },
        { once: true },
      );
    });
  pi.registerTool({
    name: "shep_wait",
    label: "Wait",
    description:
      "Wait for a CI run, a desk, an Entire trail's gates to pass on an expected head (target <n> or <repo>/<n>, head: the commit), or a delay (seconds). Report a bound timeout as incomplete.",
    parameters: Type.Object({
      kind: Type.Union([Type.Literal("ci"), Type.Literal("desk"), Type.Literal("trail"), Type.Literal("delay")]),
      target: Type.String(),
      head: Type.Optional(Type.String()),
    }),
    async execute(_id, args, signal) {
      if (signal?.aborted) throw new Error("wait cancelled; outcome incomplete");
      if (args.kind === "ci" && /^[1-9][0-9]*$/.test(args.target))
        return text(await call("gh", ["run", "watch", args.target, "--exit-status"], 3600000, signal));
      if (args.kind === "desk" && /^[a-z0-9_-]+$/i.test(args.target))
        return text(await call("hc", ["wait", args.target], 3600000, signal));
      if (args.kind === "trail") {
        const head = (args.head ?? "").toLowerCase();
        if (!/^([a-z0-9._-]+\/)?[1-9][0-9]*$/i.test(args.target) || !/^[0-9a-f]{7,64}$/.test(head))
          throw new Error("a trail wait needs target <n> or <repo>/<n>, and head: the commit its gates must pass on");
        const end = Date.now() + 3600000;
        for (;;) {
          const gate = trailGate(
            JSON.parse(await call("entire", ["trail", "show", args.target, "--json"], 30000, signal)),
            head,
          );
          if (gate.state === "ready")
            return text(
              `ready: ${gate.text}. Report it on the issue and stop; Shep runs the follow-up, such as the merge.`,
            );
          if (gate.state !== "pending")
            throw new Error(`${gate.state}: ${gate.text}. Report it on the issue and stop.`);
          if (Date.now() + TRAIL_POLL_MS > end)
            throw new Error(`timed out after an hour: ${gate.text}. Report the wait as incomplete.`);
          await pause(TRAIL_POLL_MS, signal);
        }
      }
      if (args.kind === "delay" && /^[0-9]+$/.test(args.target) && Number(args.target) <= 3600)
        return text(await call("sleep", [args.target], 3601000, signal));
      throw new Error("wait needs a ci run id, a desk address, a trail and head, or a delay of 0..3600 seconds");
    },
  });
  // Defensive admission: a wrapper/config mistake cannot add edit or agent tools.
  pi.on("tool_call", (event) => {
    if (!["read", "grep", "find", "ls", "bash", "shep_wait"].includes(event.toolName))
      return {
        block: true,
        reason:
          "A background Shep waits and reports; it has no edit, write or agent tools. Put the next step in your report on the issue: Shep or the original desk does it.",
      };
  });
  pi.on("session_start", () => {
    if (!issue) throw new Error("BERCAIL_ISSUE is unset; start the background Shep with bercail shep bg --issue ID");
    const brief = process.env.BERCAIL_BG_BRIEF;
    if (!brief)
      throw new Error("BERCAIL_BG_BRIEF is unset; start the background Shep with bercail shep bg, which passes it");
    // Pin the actual brief at startup in the worker's session, not today's file.
    pi.appendEntry("bercail-background-profile", { generation: "shep-bg-2", brief: readFileSync(brief, "utf8") });
  });
}
