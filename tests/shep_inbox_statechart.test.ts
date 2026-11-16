// Shep's inbox against its TLA+ model (tests/statechart/shep-inbox): every step
// in TLC's own state graph is replayed on the real inbox.ts, with a fake
// follower (files written the way notify_shep_enqueue writes them) and a fake Pi
// (a follow-up queue, and session JSONL written the way Pi writes it). After
// each step the files, queue, screen and sessions must match the model's state.
// A mismatch is drift: the code or the model changed without the other.
//
// Every step, not every state: two orders of the same steps can reach one model
// state, and the shortest path to it takes only one of them. A step that leaves
// a drain half done is followed to the drain's end, where the state is compared.
//
// A model drain is three steps (Claim, Reconcile, Send); the real one is one
// call. A follower write the model puts between Claim and Reconcile runs inside
// the drain's first status update (after claim() and verify(), before
// reconcile()); one after Reconcile runs when the drain returns. A crash after
// Claim throws from that update, so the drain stops before reconcile(); a crash
// after Reconcile runs the drain with no session file, so it stops before it
// stamps an attempt. Both hang on the drain's first ctx.ui.setStatus call, at
// the end of checkReceipts(): if inbox.ts stops making it, the replay fails.
//
// What inbox.ts decides is compared: where each event is, its delivery attempt
// and receipt, what it queues in Pi, and whether it runs or pauses. The screen
// and the session files are the fake Pi's, written as the model says. Only
// replay.cfg's graph is replayed (one Shep): two Sheps and the lock are checked
// in the model only.
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
import register, { TYPE } from "../shep/pi/inbox.ts";

const SPEC = join(import.meta.dirname, "statechart", "shep-inbox");
type Vars = Record<string, any>;
type Graph = { states: { start: boolean; vars: Vars }[]; steps: [number, string, number][] };
const graph: Graph = JSON.parse(readFileSync(join(SPEC, "graph.json"), "utf8"));

const sorted = (xs: Iterable<string>) => [...xs].sort((a, b) => a.localeCompare(b));
const EID = "t9:finished:1763078400:4242";
const NAME = "t9_finished_1763078400.json"; // notify_shep_enqueue drops the pid
const desk = {
  agent: { address: "t9", status: "idle", previous_status: "working", role: "desk" },
  space: { id: "space-1", name: "inbox", repo: "bercail", checkout_path: "/w/bercail" },
  desk: { issue: "bercail-1" },
};

const outOf = new Map<number, number[]>();
graph.steps.forEach(([from], k) => outOf.set(from, [...(outOf.get(from) ?? []), k]));

// The shortest path, as step indices, from the states in FROM to each state
// it reaches, going no further than a state DONE accepts.
function shortest(from: number[], done: (state: number) => boolean = () => false): Map<number, number[]> {
  const paths = new Map(from.map((s) => [s, [] as number[]]));
  const queue = [...from];
  while (queue.length) {
    const at = queue.shift()!;
    if (done(at) && !from.includes(at)) continue;
    for (const k of outOf.get(at) ?? []) {
      const to = graph.steps[k][2];
      if (paths.has(to)) continue;
      paths.set(to, [...paths.get(at)!, k]);
      queue.push(to);
    }
  }
  return paths;
}
const drainDone = (s: number) =>
  Object.values(graph.states[s].vars.pc).every((pc) => pc !== "claimed" && pc !== "reconciled");

// For each step: the way to it, the step, and the way out of a drain it leaves half done.
function stepPaths(): number[][] {
  const to = shortest(graph.states.flatMap((s, i) => (s.start ? [i] : [])));
  return graph.steps.map(([from, , next], k) => {
    if (!to.has(from)) throw new Error(`TLC lists state ${from}, but no path reaches it`);
    const out = drainDone(next) ? [] : [...shortest([next], drainDone)].find(([s]) => drainDone(s))?.[1];
    if (!out) throw new Error(`a drain never ends after step ${k}`);
    return [...to.get(from)!, k, ...out];
  });
}

type Rt = {
  s: number;
  file: string;
  flushed: boolean;
  handlers: Record<string, (...a: any[]) => any>;
  ctx: any;
  queue: string[];
  unsaved: string[];
  status: string[];
  hook?: () => void;
  noFile: boolean;
  down: boolean;
  phase?: "claimed" | "reconciled";
  inject: (() => void)[];
  after: (() => void)[];
};

class World {
  rts = new Map<number, Rt>();
  starts = 0;
  entries = 0;
  shown: Record<string, number> = { E: 0, N: 0 };
  dir: string;
  inbox: string;
  delivered: string;
  constructor(dir: string) {
    this.dir = dir;
    this.inbox = join(dir, "inbox");
    this.delivered = join(dir, "delivered");
  }

  midDrain() {
    return [...this.rts.values()].some((r) => !r.down && r.phase);
  }
  // A follower write lands where the model puts it, relative to a drain.
  private follower(write: () => void) {
    const mid = [...this.rts.values()].find((r) => !r.down && r.phase);
    if (mid?.phase === "claimed") mid.inject.push(write);
    else if (mid?.phase === "reconciled") mid.after.push(write);
    else write();
  }
  private put(path: string, value: unknown) {
    writeFileSync(`${path}.tmp-follower`, JSON.stringify(value));
    renameSync(`${path}.tmp-follower`, path);
  }
  private drain(rt: Rt, mode: "send" | "stop-after-claim" | "stop-before-stamp") {
    rt.handlers.message_end({ message: { role: "user" } }, rt.ctx);
    rt.hook = () => {
      for (const write of rt.inject.splice(0)) write();
      if (mode === "stop-after-claim") throw new Error("crash after claim");
    };
    rt.noFile = mode === "stop-before-stamp";
    vi.advanceTimersByTime(200);
    rt.noFile = false;
    for (const write of rt.inject.splice(0)) write();
    rt.hook = undefined;
    rt.phase = undefined;
    for (const write of rt.after.splice(0)) write();
  }
  private header(s: number) {
    return { type: "session", version: 3, id: `ses-${s}`, cwd: this.dir };
  }
  private noticeId() {
    const f = readdirSync(this.delivered).find((n) => n.startsWith("notice-") && n.endsWith(".json"));
    return f ? JSON.parse(readFileSync(join(this.delivered, f), "utf8")).notice_id : undefined;
  }
  private entry(item: string) {
    return {
      type: "custom_message",
      customType: TYPE,
      id: `entry-${++this.entries}`,
      content: "bercail desk event",
      display: true,
      details: item === "E" ? { events: [EID], notices: [] } : { events: [], notices: [this.noticeId()] },
    };
  }

  async step(action: string, from: Vars, to: Vars) {
    const changed = (k: string) =>
      Object.keys(to[k]).find((x) => JSON.stringify(from[k][x]) !== JSON.stringify(to[k][x]));
    const p = Number(changed("pc") ?? changed("busy") ?? changed("queue"));
    const rt = this.rts.get(p)!;
    switch (action) {
      case "FollowerWritesEvent":
        return this.follower(() =>
          this.put(join(this.inbox, NAME), {
            source: "bercail",
            schema: "bercail.notify/v1",
            kind: "finished",
            sink: "shep",
            event_id: EID,
            text: "bercail-1. Desk t9 (inbox) finished.",
            ...desk,
          }),
        );
      case "FollowerMissesEvent":
        return;
      case "FollowerWritesSource":
        return this.follower(() =>
          this.put(join(this.dir, "source-state.json"), {
            source: "bercail",
            schema: "bercail.source_state/v1",
            kind: "reconciliation",
            observed_at: "2026-11-14T00:00:00Z",
            history_gap: true,
            possibly_stale: true,
            desks: [{ observed_at: "2026-11-14T00:00:00Z", ...desk }],
          }),
        );
      case "ShepStarts":
        return this.start(p, !to.flushed[to.starts]);
      case "ShepCrashes":
        if (rt.phase === "claimed") this.drain(rt, "stop-after-claim");
        if (rt.phase === "reconciled") this.drain(rt, "stop-before-stamp");
        rt.queue = [];
        rt.unsaved = [];
        await rt.handlers.session_shutdown({ type: "session_shutdown", reason: "quit" }, rt.ctx);
        rt.down = true;
        return;
      case "Claim":
        rt.phase = "claimed";
        return;
      case "Reconcile":
        rt.phase = "reconciled";
        return;
      case "Send":
        return this.drain(rt, "send");
      case "PiShows": {
        const item = changed("shown")!;
        if (!rt.queue.includes(item)) throw new Error(`the model shows ${item}, which inbox.ts never queued`);
        rt.queue.splice(rt.queue.indexOf(item), 1);
        this.shown[item]++;
        if (rt.flushed) appendFileSync(rt.file, `${JSON.stringify(this.entry(item))}\n`);
        else rt.unsaved.push(item);
        return;
      }
      case "PiEndsTurn": {
        const reply = { type: "message", id: `a-${++this.entries}`, message: { role: "assistant", content: [] } };
        if (!rt.flushed) {
          const lines = [this.header(rt.s), ...rt.unsaved.map((i) => this.entry(i)), reply];
          writeFileSync(rt.file, lines.map((x) => `${JSON.stringify(x)}\n`).join(""));
        } else appendFileSync(rt.file, `${JSON.stringify(reply)}\n`);
        rt.flushed = true;
        rt.unsaved = [];
        await rt.handlers.turn_end({ type: "turn_end" }, rt.ctx);
        return;
      }
    }
    throw new Error(`no adapter for the model's action ${action}`);
  }

  private async start(p: number, fresh: boolean) {
    const s = ++this.starts;
    const file = join(this.dir, `ses-${s}.jsonl`);
    // An empty session has no file until Pi writes the first reply.
    if (!fresh) {
      const lines = [this.header(s), { type: "message", id: `u-${s}`, message: { role: "user", content: "hi" } }];
      writeFileSync(file, lines.map((x) => `${JSON.stringify(x)}\n`).join(""));
    }
    const rt: Rt = {
      s,
      file,
      flushed: !fresh,
      handlers: {},
      ctx: null,
      queue: [],
      unsaved: [],
      status: [],
      noFile: false,
      down: false,
      inject: [],
      after: [],
    };
    rt.ctx = {
      hasUI: true,
      ui: {
        setStatus: (_key: string, text?: string) => {
          if (text) rt.status.push(text);
          const hook = rt.hook;
          rt.hook = undefined;
          hook?.();
        },
        notify() {},
      },
      sessionManager: {
        getSessionId: () => `ses-${s}`,
        getSessionFile: () => (rt.noFile ? undefined : file),
        getSessionDir: () => this.dir,
        getEntries: () => [],
      },
    };
    register({
      on: (name: string, fn: any) => (rt.handlers[name] = fn),
      sendMessage: (m: any) => {
        for (const _ of m.details.events ?? []) rt.queue.push("E");
        for (const _ of m.details.notices ?? []) rt.queue.push("N");
      },
    } as any);
    this.rts.set(p, rt);
    await rt.handlers.session_start({ type: "session_start", reason: "startup" }, rt.ctx);
  }

  // The real state in the model's terms.
  observe(items: string[], procs: string[], sessions: string[]) {
    const read = (name?: string) =>
      name && existsSync(join(this.delivered, name))
        ? JSON.parse(readFileSync(join(this.delivered, name), "utf8"))
        : undefined;
    const files: Record<string, string | undefined> = {
      E: existsSync(join(this.delivered, NAME)) ? NAME : undefined,
      N: readdirSync(this.delivered).find((n) => n.startsWith("notice-") && n.endsWith(".json")),
    };
    const nid = this.noticeId();
    const o: Vars = { loc: {}, attempt: {}, receipt: {}, shown: {}, saved: {}, queue: {}, shep: {} };
    for (const i of items) {
      const r = read(files[i]);
      o.loc[i] = r ? "delivered" : i === "E" && existsSync(join(this.inbox, NAME)) ? "inbox" : "none";
      o.attempt[i] = r?.delivery_attempt ? Number(String(r.delivery_attempt.session_id).replace("ses-", "")) : 0;
      o.receipt[i] = typeof r?.persisted_entry_id === "string";
      o.shown[i] = this.shown[i];
    }
    for (const s of sessions) {
      const f = join(this.dir, `ses-${s}.jsonl`);
      const lines = existsSync(f)
        ? readFileSync(f, "utf8")
            .split("\n")
            .filter(Boolean)
            .map((l) => JSON.parse(l))
        : [];
      const ids = lines
        .filter((x) => x.type === "custom_message")
        .flatMap((x) => [
          ...(x.details.events.includes(EID) ? ["E"] : []),
          ...(nid && x.details.notices.includes(nid) ? ["N"] : []),
        ]);
      o.saved[s] = sorted(new Set(ids));
    }
    for (const p of procs) {
      const rt = this.rts.get(Number(p));
      o.queue[p] = rt && !rt.down ? sorted(rt.queue) : [];
      o.shep[p] = !rt || rt.down ? "down" : rt.status.some((t) => /another consumer/.test(t)) ? "paused" : "live";
    }
    return o;
  }
}

// The model's state, in the same shape.
function expected(v: Vars) {
  const o: Vars = { loc: {}, attempt: {}, receipt: {}, shown: {}, saved: {}, queue: {}, shep: {} };
  for (const i of Object.keys(v.loc)) {
    o.loc[i] = v.loc[i];
    o.attempt[i] = v.attempt[i];
    o.receipt[i] = v.receipt[i];
    o.shown[i] = v.shown[i];
  }
  for (const s of Object.keys(v.saved)) o.saved[s] = sorted(v.saved[s]);
  for (const p of Object.keys(v.pc)) {
    o.queue[p] = sorted(v.queue[p]);
    o.shep[p] = v.pc[p] === "down" ? "down" : v.pc[p] === "paused" ? "paused" : "live";
  }
  return o;
}

describe("Shep's inbox follows its TLA+ model", () => {
  let dir: string;
  let world: World;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shep-inbox-model-"));
    mkdirSync(join(dir, "inbox"));
    mkdirSync(join(dir, "delivered"));
    vi.stubEnv("BERCAIL_SHEP_INBOX", join(dir, "inbox"));
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-11-14T00:00:00.000Z"));
  });
  afterEach(async () => {
    for (const rt of world?.rts.values() ?? [])
      if (!rt.down) await rt.handlers.session_shutdown({ type: "session_shutdown" }, rt.ctx);
    vi.useRealTimers();
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
  });

  test("the chart and graph.json come from the spec, configs and view as they are now", () => {
    const sum = (name: string) =>
      createHash("sha256")
        .update(readFileSync(join(SPEC, name)))
        .digest("hex");
    const lines = readFileSync(join(SPEC, "sha256sums"), "utf8").trim().split("\n");
    const stale = lines.map((l) => l.split(/\s+/)).filter(([hash, name]) => sum(name) !== hash);
    expect(stale, "run tests/statechart/shep-inbox/check.sh").toEqual([]);
    expect(sorted(lines.map((l) => l.split(/\s+/)[1]))).toEqual(
      sorted(
        readdirSync(SPEC)
          .filter((n) => /\.(tla|cfg)$|^view\.mjs$/.test(n))
          .map((n) => (n.endsWith(".cfg") ? `./${n}` : n)),
      ),
    );
  });

  test("every step in TLC's graph replays on the real inbox.ts", async () => {
    const paths = stepPaths();
    const start = graph.states.find((s) => s.start)!.vars;
    const items = Object.keys(start.loc);
    const procs = Object.keys(start.pc);
    const sessions = Object.keys(start.saved);
    const mismatches: string[] = [];
    for (const path of paths) {
      rmSync(join(dir, "inbox"), { recursive: true, force: true });
      rmSync(join(dir, "delivered"), { recursive: true, force: true });
      for (const f of readdirSync(dir)) rmSync(join(dir, f), { force: true });
      mkdirSync(join(dir, "inbox"));
      mkdirSync(join(dir, "delivered"));
      world = new World(dir);
      for (const [n, k] of path.entries()) {
        const [from, action, to] = graph.steps[k];
        await world.step(action, graph.states[from].vars, graph.states[to].vars);
        if (world.midDrain()) continue;
        const want = expected(graph.states[to].vars);
        const got = world.observe(items, procs, sessions);
        if (JSON.stringify(want) !== JSON.stringify(got)) {
          const actions = path.slice(0, n + 1).map((j) => graph.steps[j][1]);
          mismatches.push(`${actions.join(" → ")}\n  model ${JSON.stringify(want)}\n  code  ${JSON.stringify(got)}`);
          break;
        }
      }
      for (const rt of world.rts.values())
        if (!rt.down) await rt.handlers.session_shutdown({ type: "session_shutdown" }, rt.ctx);
      world.rts.clear();
    }
    expect(mismatches).toEqual([]);
  }, 120_000);
});
