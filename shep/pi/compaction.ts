// Shep's compaction on Pi. When Pi compacts Shep's session, the summary is
// built from what is true now instead of from the old transcript: a fresh job
// board (`bercail shep board`), the person's standing rules (preferences.md),
// and a model summary of only the decisions and open questions in the part
// being compacted. If any of that fails, the handler returns nothing and Pi
// compacts the default way, so the session is never lost. Failures go to
// compaction.log in Shep's state folder.
//
// Rollover (BERCAIL_SHEP_ROLLOVER=1, off by default): instead of a threshold
// compaction, and on the first turn of a new day, Shep moves to a fresh session
// seeded with the board and the rules. /shep-rollover does it by hand.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const DECISIONS = "## Decisions and open questions";
const MAX_TOKENS = 4096;

export const INSTRUCTIONS = `You are compacting the conversation of Shep, an orchestrator that hands coding jobs to agent desks and reports back to the person.

Write only what the conversation decided and what is still open, as two short bullet lists under "### Decisions" and "### Open questions". A decision is something the person chose or approved, with its reason when one was given. An open question is something Shep or a desk asked that nobody has answered yet.

Leave out job state: which issues exist, desk states, branches, and what desks reported. A fresh job board replaces it. Leave out standing rules too; they are kept separately. Name issues as "<id>: <title>". Keep each bullet to one line. Carry over the decisions and open questions of the previous summary unless the conversation settled or replaced them. Write "- none" under a heading with nothing in it.`;

export function rulesOf(text: string): string[] {
  return text.split("\n").filter((l) => l.startsWith("- "));
}

// The decisions part of an earlier summary: ours from its heading on, or the
// whole of one Pi wrote.
export function decisionsOf(previous?: string): string {
  if (!previous) return "";
  const at = previous.indexOf(DECISIONS);
  return (at >= 0 ? previous.slice(at + DECISIONS.length) : previous).trim();
}

export function request(conversation: string, previous: string): string {
  return [
    INSTRUCTIONS,
    previous ? `<previous-summary>\n${previous}\n</previous-summary>` : "",
    `<conversation>\n${conversation}\n</conversation>`,
  ]
    .filter(Boolean)
    .join("\n\n");
}

export function assemble(o: { board: string; rules: string[]; decisions: string; at: string }): string {
  return [
    `# Shep's state at compaction (${o.at})`,
    "## Job board\nFresh from `bercail shep board` at compaction time. It replaces any older job state; run it again for the current one.\n\n" +
      o.board.trim(),
    "## Standing rules from the person\nFrom preferences.md (`bercail shep list`).\n\n" +
      (o.rules.length ? o.rules.join("\n") : "- none yet"),
    `${DECISIONS}\n\n${o.decisions.trim()}`,
  ].join("\n\n");
}

export function seed(o: { board: string; rules: string[]; previous: string; at: string }): string {
  return [
    `bercail rollover (${o.at}): Shep started this session fresh. The previous one is ${o.previous || "unknown"}; /resume opens it again.`,
    "## Job board\n" + o.board.trim(),
    "## Standing rules from the person\n" + (o.rules.length ? o.rules.join("\n") : "- none yet"),
  ].join("\n\n");
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

export type Deps = {
  board(): Promise<string>;
  rules(): string[];
  serialize(messages: any[]): Promise<string> | string;
  log(line: string): void;
  now?(): Date;
};

// The session_before_compact handler: our compaction, or undefined for Pi's own.
export function compactor(deps: Deps) {
  return async (event: any, ctx: any) => {
    const { preparation, signal } = event;
    try {
      const model = ctx.model;
      if (!model) throw new Error("no model selected");
      const board = await deps.board();
      if (!board.trim()) throw new Error("the board was empty");
      const rules = deps.rules();
      const conversation = await deps.serialize([
        ...preparation.messagesToSummarize,
        ...(preparation.turnPrefixMessages ?? []),
      ]);
      const response = await ctx.modelRegistry.complete(
        model,
        {
          messages: [
            {
              role: "user",
              content: [{ type: "text", text: request(conversation, decisionsOf(preparation.previousSummary)) }],
              timestamp: Date.now(),
            },
          ],
        },
        { maxTokens: Math.min(MAX_TOKENS, model.maxTokens || MAX_TOKENS), signal, cacheRetention: "none" },
      );
      if (response?.stopReason === "error" || response?.stopReason === "aborted")
        throw new Error(response.errorMessage || response.stopReason);
      const decisions = (response?.content ?? [])
        .filter((c: any) => c?.type === "text")
        .map((c: any) => c.text)
        .join("\n")
        .trim();
      if (!decisions) throw new Error("the model wrote no summary");
      return {
        compaction: {
          summary: assemble({ board, rules, decisions, at: (deps.now?.() ?? new Date()).toISOString() }),
          firstKeptEntryId: preparation.firstKeptEntryId,
          tokensBefore: preparation.tokensBefore,
          usage: response.usage,
          details: { by: "bercail-shep", reason: event.reason, rules: rules.length },
        },
      };
    } catch (e) {
      deps.log(`${event.reason ?? "?"} compaction: Pi's default summary instead of Shep's (${message(e)})`);
      return undefined;
    }
  };
}

// Whether the session began on an earlier day than now (local time).
export function newDay(started: string | undefined, now: Date): boolean {
  if (!started) return false;
  const t = new Date(started);
  return !Number.isNaN(t.getTime()) && t.toDateString() !== now.toDateString();
}

function runBoard(bin: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(bin, ["shep", "board"], { timeout: 60000, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
      if (err) reject(new Error(`bercail shep board failed: ${(stderr || err.message).trim().split("\n").pop()}`));
      else resolve(stdout);
    });
  });
}

export default function (pi: ExtensionAPI) {
  const state = process.env.BERCAIL_SHEP_STATE;
  if (!state) return;
  const bin = process.env.BERCAIL_SHEP_BIN || "bercail";
  const rollover = process.env.BERCAIL_SHEP_ROLLOVER === "1";
  const log = (line: string) => {
    try {
      appendFileSync(join(state, "compaction.log"), `${new Date().toISOString()} ${line}\n`);
    } catch {}
  };
  const deps: Deps = {
    board: () => runBoard(bin),
    rules: () => {
      try {
        return rulesOf(readFileSync(join(state, "preferences.md"), "utf8"));
      } catch {
        return [];
      }
    },
    serialize: async (messages) => {
      const { convertToLlm, serializeConversation } = await import("@earendil-works/pi-coding-agent");
      return serializeConversation(convertToLlm(messages));
    },
    log,
  };
  const compact = compactor(deps);
  // One rollover try per session: Pi makes a new instance of this extension
  // for the new session, so a try that did nothing is never repeated each turn.
  // A rollover that failed turns rollovers off for this process.
  let asked = false;
  let broken = false;
  let skipped = false;

  // Starts /shep-rollover once Pi is idle (a threshold check can come mid-run).
  const rollSoon = (ctx: any) => {
    asked = true;
    const started = Date.now();
    const tick = () => {
      if (!ctx.isIdle() && Date.now() - started < 600000) return void setTimeout(tick, 250);
      try {
        pi.sendUserMessage("/shep-rollover", { expandPromptTemplates: true });
      } catch (e) {
        broken = true;
        log(`rollover failed, compaction resumes: ${message(e)}`);
      }
    };
    setTimeout(tick, 0);
  };

  pi.on("session_before_compact", async (event, ctx) => {
    // After a try in this session, compact: that rollover did not happen.
    if (rollover && !broken && !asked && event.reason === "threshold") {
      skipped = true;
      log("threshold compaction skipped: a rollover instead");
      rollSoon(ctx);
      return { cancel: true };
    }
    return compact(event, ctx);
  });
  pi.on("session_compact", (event) => {
    log(
      `${event.reason} compaction: ${event.fromExtension ? "Shep's summary (board, rules, decisions)" : "Pi's default summary"}`,
    );
  });
  pi.on("session_compact_failed", (event) => {
    if (skipped && event.aborted) return void (skipped = false);
    log(
      `${event.reason} compaction failed${event.aborted ? " (aborted)" : ""}${event.fromExtension ? " with Shep's summary" : ""}: ${event.errorMessage ?? "no message"}`,
    );
  });

  pi.registerCommand("shep-rollover", {
    description: "Start a fresh Shep session seeded with the job board and the standing rules",
    handler: async (_args, ctx) => {
      await ctx.waitForIdle();
      const previous = ctx.sessionManager.getSessionFile() ?? "";
      let board: string;
      try {
        board = await deps.board();
      } catch (e) {
        broken = true;
        log(`rollover failed, compaction resumes: ${message(e)}`);
        ctx.ui.notify(`Shep rollover failed: ${message(e)}`, "error");
        return;
      }
      const text = seed({ board, rules: deps.rules(), previous, at: new Date().toISOString() });
      const result = await ctx.newSession({
        parentSession: previous || undefined,
        setup: async (sm) => {
          sm.appendMessage({ role: "user", content: [{ type: "text", text }], timestamp: Date.now() });
        },
      });
      if (result.cancelled) {
        broken = true;
        log("rollover cancelled, compaction resumes");
      } else {
        log(`rolled over from ${previous}`);
      }
    },
  });

  if (!rollover) return;
  // The first turn of a new day ends in a rollover.
  pi.on("agent_end", (_event, ctx) => {
    if (broken || asked || !newDay(ctx.sessionManager.getHeader()?.timestamp, new Date())) return;
    rollSoon(ctx);
  });
}
