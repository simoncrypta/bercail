// bercail review-pr's reviewer. It runs in a review stack dir and reads only
// what is in it: the PR is untrusted input. In the review desk (a Pi with a UI)
// it also takes the CLI's turns: bercail drops a request in desk/inbox/, this
// sends its prompt when Pi is idle, and appends the turn to the request's out
// file in Pi's json-mode shape (a session line, each assistant message_end, then
// agent_settled), so one parser reads a desk turn and a headless `pi -p`.
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
const FILE = /^[A-Za-z0-9._-]+\.json$/;
const POLL_MS = 500;

// The real path of PATH, or of its nearest existing parent with the rest
// appended: a file that does not exist yet still resolves through symlinks.
function real(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    const parent = dirname(path);
    return parent === path ? path : join(real(parent), path.slice(parent.length + 1));
  }
}

export function inside(root: string, path: string): boolean {
  const base = real(root);
  const p = real(path);
  return p === base || p.startsWith(base.endsWith(sep) ? base : base + sep);
}

// Where a tool call would read, resolved against the stack dir. Pi strips a
// leading @ and expands ~.
export function toolPath(cwd: string, input: unknown): string {
  let p = typeof (input as { path?: unknown })?.path === "string" ? (input as { path: string }).path : ".";
  if (p.startsWith("@")) p = p.slice(1);
  if (p === "~" || p.startsWith("~/")) p = join(homedir(), p.slice(1));
  return isAbsolute(p) ? p : resolve(cwd, p || ".");
}

export function decide(cwd: string, toolName: string, input: unknown): string | null {
  if (!READ_TOOLS.has(toolName)) return `The reviewer is read-only: ${toolName} is not allowed.`;
  if (!inside(cwd, toolPath(cwd, input))) return "The reviewer reads only the review stack dir it runs in.";
  return null;
}

export type Request = { name: string; prompt: string; out: string; pid: number };

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

// The oldest request whose CLI still waits, moved out of the inbox so it runs
// once. A request whose caller died, or that is malformed, is dropped.
export function take(root: string): Request | null {
  const inbox = join(root, "desk", "inbox");
  let names: string[] = [];
  try {
    names = readdirSync(inbox)
      .filter((n) => FILE.test(n))
      .sort();
  } catch {
    return null;
  }
  for (const name of names) {
    const from = join(inbox, name);
    const taken = `${from}.taken`;
    try {
      renameSync(from, taken);
    } catch {
      continue;
    }
    let req: Partial<Request> | null = null;
    try {
      req = JSON.parse(readFileSync(taken, "utf8"));
    } catch {}
    try {
      unlinkSync(taken);
    } catch {}
    if (!req || typeof req.prompt !== "string" || !req.prompt || typeof req.out !== "string") continue;
    if (!Number.isInteger(req.pid) || !alive(req.pid as number)) continue;
    if (!isAbsolute(req.out) || !inside(root, dirname(req.out))) continue;
    return { name, prompt: req.prompt, out: req.out, pid: req.pid as number };
  }
  return null;
}

function line(out: string, value: unknown) {
  appendFileSync(out, `${JSON.stringify(value)}\n`, { mode: 0o600 });
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    const reason = decide(ctx.cwd, event.toolName, event.input);
    if (reason) return { block: true, reason };
  });

  let poll: ReturnType<typeof setInterval> | null = null;
  let current: Request | null = null;
  let ctxNow: any = null;

  const stop = () => {
    if (poll) clearInterval(poll);
    poll = null;
  };
  const tick = () => {
    const ctx = ctxNow;
    if (!ctx) return;
    if (current) {
      if (existsSync(`${current.out}.cancel`)) ctx.abort();
      return;
    }
    if (!ctx.isIdle() || ctx.hasPendingMessages()) return;
    const req = take(ctx.cwd);
    if (!req) return;
    current = req;
    try {
      line(req.out, { type: "session", id: ctx.sessionManager.getSessionId?.() ?? "" });
      pi.sendUserMessage(req.prompt);
    } catch (e) {
      try {
        line(req.out, {
          type: "message_end",
          message: {
            role: "assistant",
            content: [],
            stopReason: "error",
            errorMessage: String((e as Error)?.message ?? e),
          },
        });
        line(req.out, { type: "agent_settled", aborted: false });
      } catch {}
      current = null;
    }
  };

  pi.on("session_start", (_event, ctx) => {
    stop();
    if (!ctx.hasUI) return;
    ctxNow = ctx;
    const desk = join(ctx.cwd, "desk");
    mkdirSync(join(desk, "inbox"), { recursive: true });
    writeFileSync(
      join(desk, "pi.json"),
      `${JSON.stringify({ pid: process.pid, session: ctx.sessionManager.getSessionId?.() ?? "" })}\n`,
      { mode: 0o600 },
    );
    poll = setInterval(tick, POLL_MS);
    poll.unref?.();
  });
  pi.on("session_shutdown", () => {
    stop();
    ctxNow = null;
  });
  pi.on("agent_end", (event) => {
    if (!current) return;
    for (const message of (event as { messages?: any[] }).messages ?? []) {
      if (message?.role === "assistant") line(current.out, { type: "message_end", message });
    }
  });
  pi.on("agent_settled", (event) => {
    if (!current) return;
    const out = current.out;
    current = null;
    line(out, { type: "agent_settled", aborted: (event as { aborted?: boolean }).aborted === true });
    try {
      unlinkSync(`${out}.cancel`);
    } catch {}
  });
}
