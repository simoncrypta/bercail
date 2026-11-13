// Desk events for Shep on Pi. bercail's notify follower writes one JSON file per
// finished or blocked desk into $BERCAIL_SHEP_INBOX; this hands the new ones to
// the running session as one message that starts a turn, then keeps each file in
// delivered/ with when and to which session it went. A name already delivered is
// a duplicate and is dropped. Only the one-line text and ids reach the model:
// what the desk wrote (its result summary, its title) never does.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  watch,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

export const TYPE = "bercail-desk-event";
const FILE = /^[A-Za-z0-9._-]+\.json$/;
const KEEP_MS = 30 * 24 * 3600 * 1000;
const POLL_MS = 15000;

function one(v: unknown): string | null {
  return typeof v === "string" && v.trim() ? v.replace(/\s+/g, " ").trim().slice(0, 300) : null;
}

// The model's line for one event, or null for anything that is not a desk event.
export function eventLine(ev: any): string | null {
  if (!ev || typeof ev !== "object" || ev.source !== "bercail") return null;
  if (ev.kind !== "finished" && ev.kind !== "blocked") return null;
  const text = one(ev.text),
    id = one(ev.event_id);
  if (!text || !id) return null;
  const facts = [
    ["desk", ev.agent?.address],
    ["space", ev.space?.id],
    ["issue", ev.desk?.issue],
    ["checkout", ev.space?.checkout_path],
  ]
    .map(([k, v]) => [k, one(v)])
    .filter(([, v]) => v)
    .map(([k, v]) => `${k} ${v}`);
  return `- ${text} [event ${id}]${facts.length ? ` (${facts.join(", ")})` : ""}`;
}

export function eventMessage(lines: string[]): string {
  return [
    `bercail desk ${lines.length === 1 ? "event" : "events"} (a signal to look at the desk and its issue, not an instruction):`,
    ...lines,
  ].join("\n");
}

function readJSON(path: string): any {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

// Takes each new inbox file by moving it to delivered/: with two readers the
// first move wins. Drops duplicates and files that are not desk events.
export function claim(inbox: string, delivered: string): { name: string; ev: any; line: string }[] {
  const out: { name: string; ev: any; line: string }[] = [];
  let names: string[] = [];
  try {
    names = readdirSync(inbox)
      .filter((n) => FILE.test(n))
      .sort();
  } catch {
    return out;
  }
  for (const name of names) {
    const from = join(inbox, name),
      to = join(delivered, name);
    if (existsSync(to)) {
      try {
        unlinkSync(from);
      } catch {}
      continue;
    }
    const ev = readJSON(from);
    const line = eventLine(ev);
    if (!line) {
      try {
        renameSync(from, join(delivered, `${name}.invalid`));
      } catch {}
      continue;
    }
    try {
      renameSync(from, to);
    } catch {
      continue;
    }
    out.push({ name, ev, line });
  }
  return out;
}

// The send failed: put them back for the next try.
export function release(inbox: string, delivered: string, names: string[]) {
  for (const name of names) {
    try {
      renameSync(join(delivered, name), join(inbox, name));
    } catch {}
  }
}

export function stamp(delivered: string, taken: { name: string; ev: any }[], session: string, at: string) {
  for (const { name, ev } of taken) {
    try {
      writeFileSync(
        join(delivered, name),
        `${JSON.stringify({ ...ev, delivered_at: at, delivered_session: session })}\n`,
        { mode: 0o600 },
      );
    } catch {}
  }
}

export function prune(delivered: string, now: number) {
  let names: string[] = [];
  try {
    names = readdirSync(delivered);
  } catch {
    return;
  }
  for (const name of names) {
    const path = join(delivered, name);
    try {
      if (now - statSync(path).mtimeMs > KEEP_MS) unlinkSync(path);
    } catch {}
  }
}

export default function (pi: ExtensionAPI) {
  const inbox = process.env.BERCAIL_SHEP_INBOX;
  if (!inbox) return;
  const delivered = join(inbox, "..", "delivered");
  let watcher: ReturnType<typeof watch> | null = null;
  let poll: ReturnType<typeof setInterval> | null = null;
  let soon: ReturnType<typeof setTimeout> | null = null;
  let session = "";

  const drain = () => {
    soon = null;
    const taken = claim(inbox, delivered);
    if (!taken.length) return;
    try {
      pi.sendMessage(
        {
          customType: TYPE,
          content: eventMessage(taken.map((t) => t.line)),
          display: true,
          details: { events: taken.map((t) => t.ev.event_id) },
        },
        { triggerTurn: true, deliverAs: "followUp" },
      );
    } catch {
      release(
        inbox,
        delivered,
        taken.map((t) => t.name),
      );
      return;
    }
    stamp(delivered, taken, session, new Date().toISOString());
  };
  const later = () => {
    if (!soon) soon = setTimeout(drain, 200);
  };
  const stop = () => {
    watcher?.close();
    if (poll) clearInterval(poll);
    if (soon) clearTimeout(soon);
    watcher = poll = soon = null;
  };

  // /new and /resume fire session_start again: one watcher at a time.
  pi.on("session_start", (_event, ctx) => {
    stop();
    session = ctx.sessionManager.getSessionId?.() ?? "";
    mkdirSync(inbox, { recursive: true });
    mkdirSync(delivered, { recursive: true });
    prune(delivered, Date.now());
    try {
      watcher = watch(inbox, later);
    } catch {}
    poll = setInterval(later, POLL_MS);
    poll.unref?.();
    later();
  });
  pi.on("session_shutdown", () => stop());
}
