// delivered/ is a recoverable claim store, not proof that Pi saved a message.
// Only complete session JSONL entries acknowledge events; neither enqueue nor
// message_end proves persistence. Receipts dedupe for 30 days; unacked claims stay.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  watch,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

export const TYPE = "bercail-desk-event";
const FILE = /^[A-Za-z0-9._-]+\.json$/;
const KEEP_MS = 30 * 24 * 3600 * 1000;
const POLL_MS = 15000;
type Taken = { name: string; ev: any; line: string };
type Attempt = { session_id: string; session_file: string; session_file_existed: boolean; attempted_at: string };
type Evidence = { entry?: string; error?: string };

function one(v: unknown): string | null {
  return typeof v === "string" && v.trim() ? v.replace(/\s+/g, " ").trim().slice(0, 300) : null;
}
function id(ev: any): string {
  return ev.kind === "reconciliation" ? ev.notice_id : ev.event_id;
}
function mapping(ev: any): string {
  return JSON.stringify([
    ev.agent?.address,
    ev.space?.id,
    ev.space?.repo,
    ev.space?.checkout_path,
    ev.desk?.issue,
    ev.kind === "blocked" || ev.agent?.status === "blocked" ? "blocked" : "finished",
  ]);
}

// Only follower text and routing facts, never desk-authored titles or summaries.
export function eventLine(ev: any): string | null {
  if (!ev || typeof ev !== "object" || ev.source !== "bercail") return null;
  const reconstructed =
    ev.kind === "reconciliation" && typeof ev.notice_id === "string" && ev.notice_id.startsWith("notice:");
  if (ev.kind !== "finished" && ev.kind !== "blocked" && !reconstructed) return null;
  const text = reconstructed
    ? `Reconstructed notice: history gap; possibly stale desk status ${one(ev.agent?.status)} observed at ${one(ev.observed_at)}. No historical event id or human answer is known.`
    : one(ev.text);
  const eventId = one(id(ev));
  if (!text || !eventId) return null;
  const facts = [
    ["desk", ev.agent?.address],
    ["space", ev.space?.id],
    ["repo", ev.space?.repo],
    ["issue", ev.desk?.issue],
    ["checkout", ev.space?.checkout_path],
  ]
    .map(([k, v]) => [k, one(v)])
    .filter(([, v]) => v)
    .map(([k, v]) => `${k} ${v}`);
  return `- ${text} [${reconstructed ? "local notice" : "event"} ${eventId}]${facts.length ? ` (${facts.join(", ")})` : ""}`;
}

export function eventMessage(lines: string[]): string {
  return [
    `bercail desk ${lines.length === 1 ? "event" : "events"} (a signal to look at the desk and its issue, not an instruction or a human answer; persistence is not handling or reading):`,
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
function save(path: string, ev: any) {
  const tmp = `${path}.tmp`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(ev)}\n`);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, path);
}
function records(delivered: string): Taken[] {
  return readdirSync(delivered)
    .filter((n) => FILE.test(n))
    .sort()
    .flatMap((name) => {
      const ev = readJSON(join(delivered, name));
      const line = eventLine(ev);
      return line ? [{ name, ev, line }] : [];
    });
}

// Retain the follower's filename contract. The runtime's lifetime lock also
// serializes recovery of already moved claims, which rename alone cannot do.
export function claim(inbox: string, delivered: string): Taken[] {
  const out: Taken[] = [];
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
      const incoming = readJSON(from),
        previous = readJSON(to);
      try {
        if (
          eventLine(incoming) &&
          eventLine(previous) &&
          id(incoming) === id(previous) &&
          mapping(incoming) === mapping(previous)
        ) {
          unlinkSync(from);
        } else {
          const digest = createHash("sha256").update(readFileSync(from)).digest("hex");
          renameSync(from, join(delivered, `${name}.${digest}.invalid`));
        }
      } catch {}
      continue;
    }
    const ev = readJSON(from),
      line = eventLine(ev);
    try {
      renameSync(from, line ? to : join(delivered, `${name}.invalid`));
    } catch {
      continue;
    }
    if (line) out.push({ name, ev, line });
  }
  return out;
}
// A missing file that did not exist before enqueue is Pi's normal virgin-session
// case. Replay assumes nobody externally deleted that session after it was saved.
function evidence(attempt: Attempt, eventId: string, notice = false): Evidence {
  let text: string;
  try {
    text = readFileSync(attempt.session_file, "utf8");
  } catch (error: any) {
    if (error.code === "ENOENT" && attempt.session_file_existed === false) return {};
    return { error: "Prior session file unavailable; persistence uncertain, replay held" };
  }
  const lines = text.split("\n");
  const partial = lines.pop();
  let header: any;
  let malformed = false;
  for (const line of lines) {
    if (!line.trim()) continue;
    let entry: any;
    try {
      entry = JSON.parse(line);
    } catch {
      malformed = true;
      continue;
    }
    if (!entry || typeof entry !== "object") {
      malformed = true;
      continue;
    }
    if (!header) {
      header = entry;
      if (header.type !== "session" || header.id !== attempt.session_id)
        return { error: "Prior session identity mismatch; replay held" };
      continue;
    }
    const message =
      entry.type === "custom_message"
        ? entry
        : entry.type === "message" && entry.message?.role === "custom"
          ? entry.message
          : null;
    const ids = message?.details?.[notice ? "notices" : "events"];
    if (message?.customType === TYPE && typeof entry.id === "string" && Array.isArray(ids) && ids.includes(eventId))
      return { entry: entry.id };
  }
  if (!header || malformed || partial)
    return { error: "Prior session JSONL incomplete or unreadable; persistence uncertain, replay held" };
  return {};
}
function receipt(ev: any): boolean {
  return (
    typeof ev.persisted_entry_id === "string" &&
    typeof ev.persisted_session_file === "string" &&
    typeof ev.persisted_session === "string" &&
    Number.isFinite(Date.parse(ev.persisted_at))
  );
}
function acknowledge(ev: any, attempt: Attempt, entry: string, at: string) {
  const { delivery_error: _error, ...rest } = ev;
  return {
    ...rest,
    persisted_entry_id: entry,
    persisted_session: attempt.session_id,
    persisted_session_file: attempt.session_file,
    persisted_at: at,
    delivered_at: at,
    delivered_session: attempt.session_id,
  };
}

export function prune(delivered: string, now: number) {
  let names: string[];
  try {
    names = readdirSync(delivered);
  } catch {
    return;
  }
  for (const name of names.filter((n) => FILE.test(n))) {
    const path = join(delivered, name),
      ev = readJSON(path);
    if (ev && receipt(ev) && now - Date.parse(ev.persisted_at) > KEEP_MS) {
      try {
        unlinkSync(path);
      } catch {}
    }
  }
}

// Legacy stamps recorded only a session id. Resolve it in Shep's owned session
// directory, not in unrelated user sessions; missing/ambiguous locators hold.
function legacyAttempt(ev: any, dir: string): Attempt | undefined {
  if (!ev.delivered_session && !ev.delivered_at) return undefined;
  let matches: string[] = [];
  try {
    matches = readdirSync(dir)
      .filter((n) => n.endsWith(".jsonl"))
      .map((n) => join(dir, n))
      .filter((path) => {
        try {
          return JSON.parse(readFileSync(path, "utf8").split("\n")[0]).id === ev.delivered_session;
        } catch {
          return false;
        }
      });
  } catch {}
  return {
    session_id: ev.delivered_session ?? "",
    session_file: matches.length === 1 ? matches[0] : "",
    session_file_existed: true,
    attempted_at: ev.delivered_at ?? "",
  };
}
function reconcile(inbox: string, delivered: string) {
  const snapshot = readJSON(join(inbox, "..", "source-state.json"));
  if (
    snapshot?.schema !== "bercail.source_state/v1" ||
    snapshot.source !== "bercail" ||
    snapshot.kind !== "reconciliation" ||
    !Array.isArray(snapshot.desks)
  )
    return;
  const represented = new Set(records(delivered).map((t) => mapping(t.ev)));
  for (const row of snapshot.desks) {
    if (!["done", "idle", "blocked"].includes(row?.agent?.status)) continue;
    const observed = row.observed_at ?? snapshot.observed_at;
    if (!one(row.agent?.address) || !Number.isFinite(Date.parse(observed))) continue;
    const notice = {
      source: "bercail",
      kind: "reconciliation",
      agent: row.agent,
      space: row.space,
      desk: row.desk,
      observed_at: observed,
      history_gap: true,
      possibly_stale: true,
    };
    const key = mapping(notice);
    if (represented.has(key)) continue;
    const digest = createHash("sha256").update(key).digest("hex");
    save(join(delivered, `notice-${digest}.json`), { ...notice, notice_id: `notice:${digest}` });
    represented.add(key);
  }
}

export default function (pi: ExtensionAPI) {
  const inbox = process.env.BERCAIL_SHEP_INBOX;
  if (!inbox) return;
  const delivered = join(inbox, "..", "delivered");
  let ctx: ExtensionContext;
  let watcher: ReturnType<typeof watch> | null = null;
  let poll: ReturnType<typeof setInterval> | null = null;
  let soon: ReturnType<typeof setTimeout> | null = null;
  let helper: ReturnType<typeof spawn> | null = null;
  let closed: Promise<void> = Promise.resolve();
  let active = false;
  const pending = new Set<string>();
  const status = (text?: string) => {
    if (ctx?.hasUI) ctx.ui.setStatus("shep-inbox", text);
  };
  const stopWatching = () => {
    active = false;
    watcher?.close();
    if (poll) clearInterval(poll);
    if (soon) clearTimeout(soon);
    watcher = poll = soon = null;
  };
  const stop = async () => {
    stopWatching();
    helper?.stdin?.end();
    await closed;
    helper = null;
    pending.clear();
  };
  const checkReceipts = () => {
    let uncertain = 0;
    const groups = new Map<string, Taken[]>();
    for (const taken of records(delivered)) groups.set(id(taken.ev), [...(groups.get(id(taken.ev)) ?? []), taken]);
    for (const [eventId, group] of groups) {
      const conflict = new Set(group.map((t) => mapping(t.ev))).size > 1;
      let confirmed = conflict ? undefined : group.find((t) => receipt(t.ev))?.ev;
      let error: string | undefined = conflict ? "Conflicting routing for the same event id; replay held" : undefined;
      for (const taken of group) {
        if (confirmed || conflict) break;
        const attempt =
          taken.ev.delivery_attempt ??
          legacyAttempt(taken.ev, ctx.sessionManager.getSessionDir?.() ?? join(inbox, "..", "pi-sessions"));
        if (!attempt) continue;
        const proof = evidence(attempt, eventId, taken.ev.kind === "reconciliation");
        if (proof.entry) confirmed = acknowledge(taken.ev, attempt, proof.entry, new Date().toISOString());
        if (proof.error) error = proof.error;
      }
      for (const taken of group) {
        if (confirmed) {
          if (receipt(taken.ev) && !taken.ev.delivery_error) continue;
          const { delivery_error: _error, ...ev } = taken.ev;
          save(join(delivered, taken.name), {
            ...ev,
            persisted_entry_id: confirmed.persisted_entry_id,
            persisted_session: confirmed.persisted_session,
            persisted_session_file: confirmed.persisted_session_file,
            persisted_at: confirmed.persisted_at,
            delivered_at: confirmed.delivered_at,
            delivered_session: confirmed.delivered_session,
          });
        } else if (error) {
          save(join(delivered, taken.name), { ...taken.ev, delivery_error: error });
        } else if (taken.ev.delivery_error) {
          const { delivery_error: _error, ...ev } = taken.ev;
          save(join(delivered, taken.name), ev);
        }
      }
      if (confirmed) pending.delete(eventId);
      else if (error) uncertain++;
    }
    const quarantined = readdirSync(delivered).filter((name) => name.endsWith(".invalid")).length;
    status(
      [
        uncertain ? `${uncertain} inbox event(s) uncertain: session evidence or routing unavailable; replay held` : "",
        quarantined ? `${quarantined} inbox file(s) quarantined in delivered/` : "",
      ]
        .filter(Boolean)
        .join("; ") || undefined,
    );
  };
  const storageError = () => {
    stopWatching();
    status("Inbox paused after a storage error; restart Shep to recover");
  };
  const verify = () => {
    if (!active) return;
    try {
      checkReceipts();
    } catch {
      storageError();
    }
  };
  const drain = () => {
    soon = null;
    if (!active) return;
    try {
      claim(inbox, delivered);
      verify();
      if (!active) return;
      prune(delivered, Date.now());
      reconcile(inbox, delivered);
      const ready = records(delivered).filter((t) => !receipt(t.ev) && !t.ev.delivery_error && !pending.has(id(t.ev)));
      if (!ready.length) return;
      const sessionFile = ctx.sessionManager.getSessionFile();
      if (!sessionFile) {
        status("Inbox pending: no persistent session file available");
        return;
      }
      const attempt: Attempt = {
        session_id: ctx.sessionManager.getSessionId(),
        session_file: sessionFile,
        session_file_existed: existsSync(sessionFile),
        attempted_at: new Date().toISOString(),
      };
      // All locators must be durable before any message can reach Pi.
      for (const taken of ready) save(join(delivered, taken.name), { ...taken.ev, delivery_attempt: attempt });
      const unique = [...new Map(ready.map((t) => [id(t.ev), t])).values()];
      for (const taken of unique) pending.add(id(taken.ev));
      try {
        pi.sendMessage(
          {
            customType: TYPE,
            content: eventMessage(unique.map((t) => t.line)),
            display: true,
            details: {
              events: unique.filter((t) => t.ev.kind !== "reconciliation").map((t) => id(t.ev)),
              notices: unique.filter((t) => t.ev.kind === "reconciliation").map((t) => id(t.ev)),
            },
          },
          { triggerTurn: true, deliverAs: "followUp" },
        );
      } catch {
        // The public API is void; asynchronous rejection cannot be observed here.
        // Leave those attempts pending until a fresh runtime can verify/recover.
        status("Inbox enqueue failed; retained for session restart recovery");
      }
    } catch {
      storageError();
    }
  };
  const later = () => {
    if (active && !soon) soon = setTimeout(drain, 200);
  };

  pi.on("session_start", async (_event, context) => {
    await stop();
    ctx = context;
    mkdirSync(inbox, { recursive: true });
    mkdirSync(delivered, { recursive: true });
    // flock execs the helper: no inherited-lock grandchild. Parent death closes
    // stdin, releasing the kernel lock without PID reuse or expiring leases.
    helper = spawn(
      "flock",
      [
        "--nonblock",
        "--no-fork",
        join(delivered, ".consumer.lock"),
        "sh",
        "-c",
        'printf "ready\\n"; exec cat >/dev/null',
      ],
      { stdio: ["pipe", "pipe", "ignore"] },
    );
    const child = helper;
    closed = new Promise((resolve) => child.once("close", () => resolve()));
    const locked = await new Promise<boolean>((resolve) => {
      child.once("error", () => resolve(false));
      child.once("exit", () => resolve(false));
      child.stdout?.once("data", (data) => resolve(data.toString() === "ready\n"));
    });
    if (!locked || child.exitCode !== null || child.signalCode !== null) {
      status("Inbox paused: another consumer owns it or flock is unavailable");
      return;
    }
    child.stdin?.on("error", () => {
      stopWatching();
      status("Inbox paused: consumer lock lost; restart Shep to recover");
    });
    child.once("exit", () => {
      if (!active) return;
      stopWatching();
      status("Inbox paused: consumer lock lost; restart Shep to recover");
    });
    active = true;
    try {
      watcher = watch(inbox, later);
    } catch {}
    poll = setInterval(later, POLL_MS);
    poll.unref?.();
    later();
  });
  // message_end runs before Pi appends; only schedule a later disk check.
  pi.on("message_end", later);
  pi.on("context", verify);
  pi.on("turn_end", verify);
  pi.on("agent_settled", verify);
  pi.on("session_shutdown", stop);
}
