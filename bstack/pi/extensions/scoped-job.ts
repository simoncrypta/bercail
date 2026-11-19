import { readFileSync, readlinkSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { QuestionStore } from "../../../shep/pi/questions.ts";
import type { ScopedCandidate } from "../../../shep/pi/scoped-types.ts";

const text = Type.String({ minLength: 1 });
const oid = Type.String({ pattern: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$" });
const fingerprint = Type.String({ pattern: "^[a-f0-9]{64}$" });
const candidateSchema = Type.Object(
  { head: oid, tree: oid, base: oid, description: fingerprint, evidence: fingerprint },
  { additionalProperties: false },
);
export const scopedJobSchema = Type.Object(
  {
    op: StringEnum(["preflight", "execute", "inspect", "revoke"]),
    issue: Type.Optional(text),
    topic: Type.Optional(text),
    base: Type.Optional(text),
    pr: Type.Optional(text),
    remote: Type.Optional(text),
    requestId: Type.Optional(text),
    grantId: Type.Optional(text),
    action: Type.Optional(StringEnum(["commit", "publish-fast-forward"])),
    candidate: Type.Optional(candidateSchema),
    reason: Type.Optional(text),
  },
  { additionalProperties: false },
);

type Caller = { cwd: string; desk: string; session: string; role: string };
type ScopedInput =
  | { op: "preflight"; issue: string; topic: string; base?: string; pr?: string; remote?: string }
  | {
      op: "execute";
      requestId: string;
      grantId: string;
      action: "commit" | "publish-fast-forward";
      candidate: ScopedCandidate;
    }
  | { op: "inspect"; requestId: string }
  | { op: "revoke"; grantId: string; reason: string };

export function scopedStateDir(): string {
  const xdg = process.env.XDG_STATE_HOME;
  const home = process.env.HOME;
  if (xdg ? !isAbsolute(xdg) : !home || !isAbsolute(home))
    throw new Error("scoped_job: XDG_STATE_HOME, or its fallback HOME, must be an absolute authority root");
  return join(xdg || join(home!, ".local/state"), "bercail/shep");
}

// Resolve only beside this extension's trusted distribution, never from ctx.cwd.
export function scopedModuleRoot(url = import.meta.url): string {
  const extensions = dirname(fileURLToPath(url));
  const parent = resolve(extensions, "../..");
  return join(basename(parent) === "bstack" ? dirname(parent) : parent, "shep/pi");
}
const load = (name: string) => import(pathToFileURL(join(scopedModuleRoot(), `${name}.ts`)).href);

function callerOf(ctx: ExtensionContext): Caller {
  return {
    cwd: ctx.cwd,
    desk: process.env.HC_TERMINAL_ID ?? "",
    session: ctx.sessionManager?.getSessionId?.() ?? "",
    role: process.env.BERCAIL_ROLE ?? "",
  };
}
function readOnly(role: string): boolean {
  return ["judge", "council", "discuss"].includes(role);
}
function object(value: unknown, required: string[], optional: string[] = []): asserts value is Record<string, unknown> {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    required.some((key) => !Object.hasOwn(value, key)) ||
    Object.keys(value).some((key) => !required.includes(key) && !optional.includes(key))
  )
    throw new Error("scoped_job: invalid fields; caller identity, paths, commands and flags are not tool arguments");
}
function nonempty(value: unknown): asserts value is string {
  if (typeof value !== "string" || !value.trim() || value.includes("\0"))
    throw new Error("scoped_job: expected nonempty text");
}
function parse(value: unknown): ScopedInput {
  object(
    value,
    ["op"],
    ["issue", "topic", "base", "pr", "remote", "requestId", "grantId", "action", "candidate", "reason"],
  );
  if (value.op === "preflight") object(value, ["op", "issue", "topic"], ["base", "pr", "remote"]);
  else if (value.op === "execute") {
    object(value, ["op", "requestId", "grantId", "action", "candidate"]);
    if (value.action !== "commit" && value.action !== "publish-fast-forward")
      throw new Error("scoped_job: unsupported action");
    object(value.candidate, ["head", "tree", "base", "description", "evidence"]);
    for (const item of Object.values(value.candidate)) nonempty(item);
    for (const key of ["head", "tree", "base"]) {
      if (!/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value.candidate[key] as string))
        throw new Error("scoped_job: candidate needs full immutable OIDs");
    }
    for (const key of ["description", "evidence"]) {
      if (!/^[a-f0-9]{64}$/.test(value.candidate[key] as string))
        throw new Error("scoped_job: candidate needs exact description and evidence fingerprints");
    }
  } else if (value.op === "inspect") object(value, ["op", "requestId"]);
  else if (value.op === "revoke") object(value, ["op", "grantId", "reason"]);
  else throw new Error("scoped_job: unsupported operation");
  for (const [key, item] of Object.entries(value)) if (key !== "candidate") nonempty(item);
  // A later handler may mutate event.input: retain no caller-owned objects.
  return structuredClone(value) as ScopedInput;
}

function canonical(path: string, links = 0): string {
  if (links > 40) throw new Error("scoped_job: cannot resolve authority path");
  try {
    return realpathSync.native(path);
  } catch {
    let link: string | undefined;
    try {
      link = readlinkSync(path);
    } catch {
      /* A missing leaf may still have a symlink parent. */
    }
    if (link) return canonical(link.startsWith("/") ? link : `${dirname(path)}/${link}`, links + 1);
    const parent = dirname(path);
    return parent === path ? resolve(path) : join(canonical(parent, links), basename(path));
  }
}

// The execution locks of a scoped grant, for an absolute path. Shep's state
// folder is the guard's own rule.
export function scopedProtectedPath(path: string): boolean {
  try {
    const full = canonical(path);
    const locks = canonical(join(dirname(scopedStateDir()), "scoped-locks"));
    if (full === locks || full.startsWith(`${locks}/`) || locks.startsWith(`${full}/`)) return true;
    const runtime = process.env.XDG_RUNTIME_DIR;
    if (runtime && !isAbsolute(runtime)) return true;
    return runtime !== undefined && full.startsWith(`${canonical(runtime)}/scoped-index-`);
  } catch {
    return true;
  }
}
function within(cwd: string, worktree: string): boolean {
  const path = relative(canonical(worktree), canonical(cwd));
  return path === "" || (path !== ".." && !path.startsWith("../") && !path.startsWith("/"));
}

// No mkdir, locks, receipts, target probes or execution in sibling preflights.
export async function hasScopedJob(ctx: ExtensionContext): Promise<boolean> {
  let dir: string;
  try {
    dir = scopedStateDir();
    readFileSync(join(dir, "questions.json"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    return true;
  }
  try {
    const { readQuestionState } = await load("questions");
    const state = readQuestionState(dir);
    const caller = callerOf(ctx);
    return state.questions.some(
      (question: { kind: string; authorization?: { scope: { worktree: string; desk: string } } }) => {
        const scope = question.authorization?.scope;
        return (
          question.kind === "scoped-authorization" &&
          scope &&
          (within(caller.cwd, scope.worktree) || (caller.desk !== "" && caller.desk === scope.desk))
        );
      },
    );
  } catch {
    // Corrupt/unknown authority cannot fall through to policy or role approval.
    return true;
  }
}

export function scopedToolDenial(input: unknown, ctx: ExtensionContext): string | undefined {
  try {
    const request = parse(input);
    if (readOnly(callerOf(ctx).role) && request.op !== "preflight" && request.op !== "inspect")
      return "This role is read-only. scoped_job cannot execute or revoke a grant.";
  } catch (error) {
    return (error as Error).message;
  }
  return undefined;
}

export function registerScopedJob(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "scoped_job",
    label: "Scoped job",
    description:
      "Read-only preflight before work; execute an exact granted commit or fast-forward publication; inspect without retrying; or revoke. This tool never creates or approves a grant. Use the person's Decisions picker for authority. " +
      "Required fields: preflight (issue, topic), execute (requestId, grantId, action, candidate), inspect (requestId), revoke (grantId, reason).",
    parameters: scopedJobSchema,
    async execute(_id, input, signal, _update, ctx) {
      const request = parse(input);
      const stateDir = scopedStateDir();
      const caller = callerOf(ctx);
      const denial = scopedToolDenial(request, ctx);
      if (denial) throw new Error(denial);
      if (!caller.cwd || !caller.desk || !caller.session)
        throw new Error("scoped_job: actual cwd, desk and Pi session are required; a parent desk grants nothing");
      let result: unknown;
      if (request.op === "preflight") {
        const { feasibility } = await load("scoped-target");
        const { op: _op, ...target } = request;
        result = await feasibility({ ...target, repo: caller.cwd, desk: caller.desk });
        const scope = (result as { scope?: { worktree: string; desk: string; session: string } }).scope;
        if (
          scope &&
          (canonical(scope.worktree) !== canonical(caller.cwd) ||
            scope.desk !== caller.desk ||
            scope.session !== caller.session)
        )
          throw new Error("scoped_job: preflight owner does not match this actual session");
      } else {
        const { QuestionStore: Store } = await load("questions");
        const state: QuestionStore = new Store(stateDir);
        if (request.op === "execute") {
          const { op: _op, ...action } = request;
          const { executeScoped } = await load("scoped-execution");
          result = await executeScoped(state, action, caller, signal);
        } else if (request.op === "inspect") {
          const { inspectScoped } = await load("scoped-execution");
          result = await inspectScoped(state, request.requestId, caller);
        } else {
          const grant = state.scopedSnapshot().grants.find((grant) => grant.id === request.grantId);
          if (
            !grant ||
            canonical(grant.scope.worktree) !== canonical(caller.cwd) ||
            grant.scope.desk !== caller.desk ||
            grant.scope.session !== caller.session
          )
            throw new Error("scoped_job: grant does not belong to this actual session");
          result = state.revokeGrant(request.grantId, request.reason);
        }
      }
      return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
    },
  });
}
