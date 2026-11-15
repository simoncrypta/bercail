// Workspace spaces: stable colored avatars, worktrees under their checkout,
// grouped by machine when more than one is known. After a space's name, the repo
// its first terminal is in now, only where unusual: branch, ahead/behind. Agent state lives in the agents list, not here. Click to
// switch, right-click for its menu, drag to reorder.
//
// bercail's copy of Herdr's spaces mod 0.1.15 (mod.clone). Rebase it when Herdr ships a
// newer spaces mod: take Herdr's file and put these back. bercail's changes, all of them:
// - shepShown, spaceView, select, newSpace: in the bercail layout a click on a space, or
//   a new space, also leaves the Shep view for the space view.
// - while Shep shows, no space reads as selected (row and the narrow rail's cell).
// - review marks, from `bercail shep queue --json` (see "review marks" below): a mark
//   after a space's name, a count in the header that opens the Review list (this mod
//   with props.role "reviews", as a dialog), and review-next (Ctrl+Shift+J). With a
//   backend in config.toml ([herdr] backend), the queue is read there and names its spaces.
// - adoptedNames: a space bercail made with no window on its machine gets the name
//   on its Shell's bercail.space_name label, and its first tab is called Shell.
// - another machine's git (AT_ONCE, RETRY, limited, tries; check, due, refreshGit, ordered):
//   its core runs 16 execs at once and refuses the rest, so its places are looked at four
//   at a time, a refused look keeps what it showed and is asked again within seconds, and
//   its spaces are not reordered while one of its places has no answer yet.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { spaces, machines, panes, run, openOverlay, closeOverlay, exec, hc, theme, shared, setShared, watchFolder, window, layout, focused, home, nextCommand, notify, props, readTextFile, terminals } from "herdr";

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// The sidebar's rail goes by its width, not a flag: dragging its edge narrows it too.
const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

// The bercail layout's two views: `shep` (Shep's TUI) or `work` (the shown space) is hidden.
const shepShown = () => { const n = find(layout(), "shep"); return Boolean(n && !n.hidden); };
function spaceView() {
  if (!find(layout(), "shep")) return;
  run("layout.hide", { id: "shep" });
  run("layout.show", { id: "work" });
}
const select = (id) => { run("space.select", { id }); spaceView(); };
const newSpace = (args) => { run("space.new", args); spaceView(); };

// Where a space is now: its first terminal's live folder, else where it was made.
// `ps`: panes(), read once by the caller (each read copies every pane).
function place(s, ps) {
  const tabs = new Set((s.tabs ?? []).map((c) => c.id));
  return ps.find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder;
}
const rowHeight = ({ tree }) => (tree ? 28 : 30);
const RAIL_CELL = 32;
const railCell = (el) => h_flex().flex_none().justify_center().child(el);
const where = (s, ps) => JSON.stringify([s.machine ?? null, place(s, ps)]);
const base = (path) => path.replace(/\/+$/, "").split("/").pop();
// Changes made outside Herdr (an editor's save, a commit in another app): looked
// for this often, in repos the list shows, while the window is in front.
const FALLBACK = 60000;
// Another machine's core runs at most 16 execs at once, for every mod, and turns the
// rest away: look at this many of its places at a time (two execs each).
const AT_ONCE = 4;
// A place git couldn't answer for is asked again after this, doubling up to FALLBACK.
const RETRY = 2000;

// Runs f on each item, at most n at a time.
async function limited(items, n, f) {
  const queue = [...items];
  await Promise.all(Array.from({ length: Math.min(n, queue.length) }, async () => {
    while (queue.length) await f(queue.shift());
  }));
}

// What a stored color name looks like on an avatar (the same in every mod
// that draws space avatars): one strong color per hue, light and dark alike.
const MARK = { ansi6: "#22a99a", ansi3: "#e3814f", ansi4: "#5b8def", ansi5: "#8b7cf6", ansi2: "#3fae6a", ansi1: "#d9649a" };

// A space speaks up only when something in it needs you.
export function glyph(status) {
  return status === "blocked" || status === "done" ? "●" : "·";
}

export function tone(t, status) {
  return t[status] ?? t.unknown;
}

// [herdr] backend in this computer's config.toml: the Herdr machine bercail runs on
// (a name from `hc machine ls`), or null for this computer.
export function backendOf(text) {
  let section = "";
  for (const raw of String(text ?? "").split("\n")) {
    const line = raw.replace(/#.*$/, "").trim();
    const sec = line.match(/^\[(.+)\]$/);
    if (sec) section = sec[1].trim();
    const kv = section === "herdr" && line.match(/^backend\s*=\s*"([^"]*)"$/);
    if (kv) return kv[1] || null;
  }
  return null;
}

// Ids across machines: a terminal on box is box/t3 here, and the labels written there
// name ids as box does (sp1 there is box/sp1 here).
export const qualify = (raw, machine) => (machine && raw ? `${machine}/${raw}` : raw);
export const machineOf = (address) => (address?.includes("/") ? address.slice(0, address.indexOf("/")) : null);

// --- review marks ---------------------------------------------------------------
// bercail's queue is the source: this reads `bercail shep queue --json` (about eight
// seconds of bd and gh), on the backend when there is one, every five minutes, and
// after a desk's status changes at most every 30 seconds, and shares it as REVIEW for
// every copy. It never decides what
// waits, and nothing it reads moves the view or the keyboard: only review-next and a
// click do.
const BERCAIL_PATH = 'command -v bercail >/dev/null || PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"';
const QUEUE = `${BERCAIL_PATH}; exec bercail shep queue --json`;
const REVIEW = "bercail.review"; // { q: the last queue read, or null; backend: where q was read; error: the last read's; missing: no bercail }
const REVIEW_EVERY = 300000;
const REVIEW_SOON = 30000;
// A queue older than this reads as stale: three reads missed.
export const STALE = 3 * REVIEW_EVERY;

const lines = (item) => item.lines ?? item.change?.lines ?? 0;
// Waits on your LGTM: its policy says so, whatever bd could tell of its state.
const lgtm = (item) => Boolean(item.counts && item.change?.review === "required");
const size = (n) => (n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : String(n));

// How long since an ISO time, shortly: 5m, 3h, 2d.
export function ago(iso, now) {
  const ms = now - Date.parse(iso ?? "");
  if (!(ms >= 0)) return "";
  const m = Math.floor(ms / 60000);
  return m < 1 ? "now" : m < 60 ? `${m}m` : m < 1440 ? `${Math.floor(m / 60)}h` : `${Math.floor(m / 1440)}d`;
}

// The queue's items in its order, each with its space: the desk's or the handoff's
// space id, else the space whose folder is the item's worktree. `ps`: panes().
// `backend`: the machine the queue was read on (null: this computer). Its ids and
// folders are that machine's, so a space elsewhere is never matched by folder.
export function reviewRows(q, sp, ps, backend = null) {
  const there = (s) => (s.machine ?? null) === backend;
  return (q?.items ?? []).map((item) => ({
    item,
    space:
      (item.space && sp.find((s) => s.id === qualify(item.space, backend))) ||
      (item.path && sp.find((s) => there(s) && (place(s, ps) === item.path || s.folder === item.path))) ||
      null,
  }));
}

// space id -> what waits there: counted lines and changes, whether one needs an LGTM
// or has an unknown state; else `quiet`, the state of what does not count.
export function marks(rows) {
  const out = {};
  for (const { item, space } of rows) {
    if (!space) continue;
    const m = (out[space.id] ??= { lines: 0, waits: 0, lgtm: false, unknown: false, quiet: null, items: [] });
    m.items.push(item);
    if (item.counts) {
      m.waits++;
      m.lines += lines(item);
      m.lgtm ||= lgtm(item);
      m.unknown ||= item.state === "unknown";
    } else m.quiet ??= item.state;
  }
  return out;
}

// The space after `current` among the spaces with work that waits, in queue order;
// the first when `current` has none. null when nothing waits in a space.
export function nextReview(rows, current) {
  const ids = [...new Set(rows.filter((r) => r.item.counts && r.space).map((r) => r.space.id))];
  return ids.length ? ids[(ids.indexOf(current) + 1) % ids.length] : null;
}

// The color of what waits: red when one item needs your LGTM, else the accent.
// Not by color alone: the tooltip and the list say "needs your LGTM".
const waitColor = (t, needsLgtm) => (needsLgtm ? t.ansi1 : t.accent);

// One line on an item, for tooltips and the list.
export function itemLabel(item) {
  const head = item.kind === "pr" ? `PR #${item.number}` : item.issue ?? item.path;
  const title = item.title ? `: ${item.title}` : "";
  const state = [lgtm(item) && "needs your LGTM", item.state === "unknown" ? `state unknown: ${item.why}` : item.why]
    .filter(Boolean)
    .join(" · ");
  return `${head}${title} · ${size(lines(item))} lines${state ? ` · ${state}` : ""}`;
}

// Where the queue stands, for the header and the list: "as of 14:02", stale, or the error.
export function reviewStatus(r, now) {
  if (!r?.q) return { text: r?.error ? `queue unread: ${r.error}` : "queue not read yet", bad: Boolean(r?.error) };
  const at = Date.parse(r.q.at);
  const d = new Date(at);
  const time = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  const old = !(now - at <= STALE);
  const text = `as of ${time}` + (old ? `, stale (${ago(r.q.at, now)} old)` : "") + (r.error ? `; last read failed: ${r.error}` : "");
  return { text, bad: old || Boolean(r.error) };
}

// Spaces bercail made with no window on their machine (config/worktrunk/herdr-layout.sh):
// a kept Shell labelled herdr.space=<id there> and bercail.space_name=<name>, which Herdr
// adopts and calls after its folder. The ones nobody has named yet, with that name.
export function adoptedNames(sp, ts) {
  const out = [];
  for (const s of sp) {
    if (s.named) continue;
    const shell = ts.find((t) => t.state === "live" && t.labels?.["bercail.space_name"]
      && qualify(t.labels["herdr.space"], machineOf(t.address)) === s.id);
    if (shell) out.push({ space: s, name: shell.labels["bercail.space_name"] });
  }
  return out;
}

export default class Spaces extends View {
  init(_props, cx) {
    this.role = props()?.role ?? "list";
    if (this.role === "reviews") return;
    this.git = {}; // where() -> { name, branch, ahead, behind, repo, linked }, null: not a repo
    this.checked = {}; // where() -> when it was last looked at
    this.unsure = new Set(); // where()s git couldn't answer for (a machine away or busy)
    this.tries = {}; // where() -> unanswered looks in a row
    this.pending = new Set(); // where()s to look at next
    this.busy = {}; // pane -> an agent working or a program in front of its shell
    this.ready = {}; // machine -> its layout was readable at the last look
    this.at = {}; // space -> its where() at the last look
    this.watching = new Set(); // local repos' git folders
    // Spaces made while this runs wait (at most a moment) for their git, so a
    // worktree appears under its repo instead of jumping there.
    this.shown = new Set(spaces().map((s) => s.id));
    this.born = {};
    this.pressed = null;
    this.over = null;
    this.machines = [];
    this.reconnecting = JSON.parse(localStorage.getItem("machines.reconnecting") ?? "{}");
    for (const state of Object.values(this.reconnecting)) state.busy = false;
    this.folded = new Set(JSON.parse(localStorage.getItem("machines.folded") ?? "[]"));
    this.refreshMachines(cx);
    cx.timer.every(15000, cx => this.refreshMachines(cx));
    // Refresh only when the refs could have changed (see `due`).
    cx.timer.every(250, (cx) => this.checkNew(cx));
    this.desks = null; // the desks' statuses at the last look: a change reads the queue again
    this.naming = {}; // space -> when it was last renamed from its label, so a slow echo is not renamed again
    this.reviewAt = 0; // when the queue was last read
    this.config = readTextFile(home() + "/.config/bercail/config.toml")
      .catch(() => null)
      .then((text) => backendOf(text));
    cx.timer.every(REVIEW_EVERY, (cx) => this.readQueue(cx));
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        if (c === "review-next") this.reviewNext();
        cx.notify();
      }
    });
  }

  // One read at a time; a change meanwhile reads again after it.
  readQueue(cx) {
    this.reviewAt = Date.now();
    if (this.reading) {
      this.readAgain = true;
      return;
    }
    this.reading = true;
    cx.spawn(async (cx) => {
      do {
        this.readAgain = false;
        const was = shared(REVIEW) ?? {};
        const backend = await this.config;
        let next;
        try {
          const r = await exec("bash", ["-lc", QUEUE], { timeout: 90000, on: backend });
          if (r.code === 127) next = { q: null, error: null, missing: true, backend };
          else {
            if (r.code !== 0) throw new Error(r.stderr.trim().split("\n").at(-1) || `bercail shep queue exited ${r.code}`);
            const q = JSON.parse(r.stdout);
            if (q?.schema !== "bercail.queue/v1") throw new Error("this bercail has no review queue JSON: run bercail update");
            next = { q, error: null, backend };
          }
        } catch (e) {
          next = { q: was.q ?? null, backend: was.backend ?? null, error: String(e?.message ?? e) };
        }
        setShared(REVIEW, next);
      } while (this.readAgain);
      this.reading = false;
      cx.notify();
    });
  }

  // Ctrl+Shift+J: the next space whose work waits on review, as a click on it would.
  reviewNext() {
    const r = shared(REVIEW);
    const id = nextReview(reviewRows(r?.q, spaces(), panes(), r?.backend), focused()?.space);
    if (id) select(id);
    else if (!r?.q) notify({ title: "bercail", body: `The review queue is not read: ${reviewStatus(r, Date.now()).text}`, level: "warning" });
    else notify({ title: "bercail", body: "Nothing in a space waits on your review.", level: "info" });
  }

  checkNew(cx) {
    const now = Date.now();
    const sp = spaces();
    for (const { space, name } of adoptedNames(sp, terminals())) {
      if (now - (this.naming[space.id] ?? 0) < 5000) continue;
      this.naming[space.id] = now;
      run("space.rename", { id: space.id, name });
      const first = space.tabs[0];
      if (first && !first.named) run("tab.rename", { id: first.id, name: "Shell" });
    }
    for (const s of sp) if (!this.shown.has(s.id)) this.born[s.id] ??= now;
    const due = this.due(now, sp, panes());
    if (due.size) this.refreshGit(due, cx);
    const desks = terminals().filter((t) => t.labels?.["bercail.role"] === "agent").map((t) => `${t.address}:${t.status}`).join(" ");
    if (desks !== this.desks) {
      this.desks = desks;
      this.reviewDue = true;
    }
    if (this.reviewDue && now - this.reviewAt >= REVIEW_SOON) {
      this.reviewDue = false;
      this.readQueue(cx);
    }
    if (sp.some((s) => !this.shown.has(s.id)) || this.orderingDue(now)) cx.notify();
  }

  // Places whose git could have changed: new ones (a new space, a cd), where a
  // command or an agent's turn just ended (a checkout, a commit, edits), those on
  // a machine that is back, and repos in view whose fallback is due.
  due(now, sp, ps) {
    // Moved there: what it knew of that place may be old.
    const at = {};
    for (const s of sp) at[s.id] = where(s, ps);
    const keys = new Set(Object.values(at).filter((k) => JSON.parse(k)[1]));
    const due = new Set([...keys].filter((k) => !(k in this.git)));
    for (const [id, k] of Object.entries(at)) if (this.at[id] && this.at[id] !== k && keys.has(k)) due.add(k);
    this.at = at;
    const spaceOf = {};
    for (const s of sp) for (const t of s.tabs ?? []) spaceOf[t.id] = s;
    const busy = {};
    for (const p of ps) {
      if (!p.terminal || !spaceOf[p.tab]) continue;
      busy[p.pane] = p.status === "working" || !(p.program?.shell || p.program?.agent);
      if (this.busy[p.pane] && !busy[p.pane]) this.sameRepo(at[spaceOf[p.tab].id], keys).forEach((k) => due.add(k));
    }
    this.busy = busy;
    for (const m of machines()) {
      const ready = m.layout === "ready";
      if (ready && this.ready[m.name] === false) for (const k of keys) if (JSON.parse(k)[0] === m.name) due.add(k);
      this.ready[m.name] = ready;
    }
    if (window().active) {
      for (const k of keys) {
        const asks = this.git[k] || this.unsure.has(k);
        const wait = this.unsure.has(k) ? Math.min(FALLBACK, RETRY * 2 ** (this.tries[k] - 1)) : FALLBACK;
        if (asks && !this.folded.has(JSON.parse(k)[0]) && now - (this.checked[k] ?? 0) > wait) due.add(k);
      }
    }
    return due;
  }

  // `key` and the other places in its repo (a commit there moves their ahead/behind).
  sameRepo(key, keys) {
    const repo = this.git[key]?.repo;
    return [key, ...(repo ? [...keys].filter((k) => this.git[k]?.repo === repo) : [])];
  }

  refreshMachines(cx) {
    cx.spawn(async cx => {
      try { const r = await hc(["machine", "ls", "--json"]); if (r.code === 0) this.machines = (JSON.parse(r.stdout).machines ?? []).filter((m) => !m.temporary); } catch {}
      cx.notify();
    });
  }

  rebuilt(machine) {
    return machine?.state === "unreachable" && /^a different core answers there \("[^"]+"\)$/.test(machine.why ?? "");
  }

  reconnect(machine, cx) {
    const name = machine.name;
    if (this.reconnecting[name]?.busy) return;
    const state = this.reconnecting[name] ??= { machine, removed: false };
    state.busy = true;
    state.error = null;
    localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
    cx.notify();
    cx.spawn(async cx => {
      try {
        const ask = async args => {
          const r = await hc([...args, "--json"]);
          if (r.code !== 0) {
            let error;
            try { error = JSON.parse(r.stdout || r.stderr).error?.message; } catch {}
            throw new Error(error || r.stderr || r.stdout || "Couldn't connect.");
          }
        };
        if (!state.removed) {
          await ask(["machine", "rm", name]);
          state.removed = true;
          localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
        }
        const args = ["machine", "add"];
        if (machine.via) args.push("--via", machine.target);
        else args.push(machine.target);
        args.push("--name", name);
        if (machine.session) args.push("--session", machine.session);
        if (machine.temporary) args.push("--temp");
        await ask(args);
        this.folded.delete(name);
        localStorage.setItem("machines.folded", JSON.stringify([...this.folded]));
        delete this.reconnecting[name];
      } catch (e) {
        state.error = String(e.message ?? e);
        state.busy = false;
      }
      localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
      this.refreshMachines(cx);
      cx.notify();
    });
  }

  // One look at a time, each place once however often it was asked for meanwhile.
  refreshGit(keys, cx) {
    for (const k of keys) this.pending.add(k);
    if (this.refreshing) return;
    this.refreshing = true;
    cx.spawn(async (cx) => {
      while (this.pending.size) {
        const keys = [...this.pending];
        this.pending.clear();
        const by = {};
        for (const key of keys) (by[JSON.parse(key)[0] ?? ""] ??= []).push(key);
        await Promise.all(Object.entries(by).map(([on, ks]) => limited(ks, on ? AT_ONCE : ks.length, (key) => this.check(key, cx))));
      }
      const used = new Set(Object.values(this.git).filter(Boolean).map((g) => JSON.parse(g.repo)).filter(([on]) => !on).map(([, repo]) => repo));
      for (const repo of this.watching) if (!used.has(repo)) this.watching.delete(repo);
      this.refreshing = false;
      cx.notify();
    });
  }

  // One place's git: branch, ahead/behind, its repo.
  async check(key, cx) {
    const [on, cwd] = JSON.parse(key);
    this.checked[key] = Date.now();
    this.unsure.delete(key);
    try {
      // Ref-only reads avoid scanning the worktree or waking its index watch.
      // Two reads: a folder name may itself contain a newline.
      const [r, common] = await Promise.all([
        exec("git", ["rev-parse", "--path-format=absolute", "--show-toplevel"], { cwd, on }),
        exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, on }),
      ]);
      if (r.code !== 0 || common.code !== 0) {
        // Only git's own "no" is remembered as no repo; anything else (a busy core) keeps
        // what it showed and is asked again.
        if (/not a git repository/i.test(r.code !== 0 ? r.stderr : common.stderr)) {
          this.git[key] = null;
        } else {
          this.git[key] ??= null;
          this.unsure.add(key);
        }
        return;
      }
      // The repo's own .git folder names it; a worktree's top differs from it.
      const top = r.stdout.replace(/\n$/, ""), repo = common.stdout.replace(/\n$/, "");
      const [branch, counts] = await Promise.all([
        exec("git", ["symbolic-ref", "-q", "HEAD"], { cwd, on }),
        exec("git", ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], { cwd, on }),
      ]);
      const name = repo.endsWith("/.git") ? base(repo.slice(0, -5)) : base(repo).replace(/\.git$/, "");
      const [ahead, behind] = counts.code === 0 ? counts.stdout.trim().split(/\s+/).map(Number) : [0, 0];
      const info = { name, branch: branch.code === 0 ? branch.stdout.trim().replace(/^refs\/heads\//, "") : "(detached)", ahead, behind, repo: JSON.stringify([on, repo]), linked: repo !== `${top}/.git` };
      this.git[key] = info;
      if (!on) this.watch(repo, cx);
    } catch {
      // Couldn't ask (the machine is away): keep what it showed, look again later.
      this.git[key] ??= null;
      this.unsure.add(key);
    } finally {
      if (this.unsure.has(key)) this.tries[key] = (this.tries[key] ?? 0) + 1;
      else delete this.tries[key];
    }
  }

  watch(repo, cx) {
    if (this.watching.has(repo)) return;
    this.watching.add(repo);
    cx.spawn(async (cx) => {
      try {
        while (this.watching.has(repo)) {
          await watchFolder(repo);
          const mine = JSON.stringify([null, repo]);
          if (this.watching.has(repo)) this.refreshGit(Object.keys(this.git).filter((k) => this.git[k]?.repo === mine), cx);
        }
      } catch { this.watching.delete(repo); }
    });
  }

  menu(w) {
    // A popup is as tall as its items; height is only the most.
    openOverlay({ mod: "menu", kind: "popup", width: 200, height: 260, props: { tab: "space", target: { id: w.id } } });
  }

  orderingDue(now) {
    return this.ordering && now - this.ordering.at >= 1000
      && this.ordering.machines.every(name => machines().some(m => m.name === name && m.layout === "ready"));
  }

  // Spaces in order, each worktree space moved under its main checkout's.
  ordered() {
    const sp = spaces(), ps = panes();
    const ready = (w) => this.shown.has(w.id) || where(w, ps) in this.git || Date.now() - (this.born[w.id] ??= Date.now()) > 1500;
    for (const w of sp) if (!this.shown.has(w.id) && ready(w)) this.shown.add(w.id);
    const list = sp.map((w, i) => ({ w, i, g: this.git[where(w, ps)] ?? null }));
    const mains = new Set(list.filter((r) => r.g && !r.g.linked).map((r) => r.g.repo));
    const nested = (r) => r.g?.linked && mains.has(r.g.repo);
    const out = [];
    const placed = new Set(); // repos whose worktrees are listed (under the first of its spaces)
    for (const r of list) {
      if (nested(r)) continue;
      out.push({ ...r, tree: null });
      if (!r.g || r.g.linked || placed.has(r.g.repo)) continue;
      placed.add(r.g.repo);
      const kids = list.filter((k) => nested(k) && k.g.repo === r.g.repo);
      kids.forEach((k, n) => out.push({ ...k, tree: n === kids.length - 1 ? "└─" : "├─" }));
    }
    // Another machine with a place this window has no answer for yet (not looked at, or
    // refused and still retried sooner than FALLBACK) keeps its spaces' order in their
    // slots: windows share that order, and a partial view would undo another's.
    const waiting = (k) => {
      const [on, cwd] = JSON.parse(k);
      return on && cwd && (!(k in this.git) || (!this.git[k] && this.unsure.has(k) && RETRY * 2 ** this.tries[k] < FALLBACK));
    };
    const unknown = new Set(list.filter((r) => waiting(where(r.w, ps))).map((r) => r.w.machine));
    const kept = sp.filter((w) => unknown.has(w.machine ?? null)).map((w) => w.id);
    // Simulate the batch so later indexes include earlier moves. An attempted
    // write can lose a sync conflict: allow the echo to settle before retrying.
    const order = sp.map(w => w.id);
    const target = out.map(r => (unknown.has(r.w.machine ?? null) ? kept.shift() : r.w.id));
    const key = JSON.stringify([order, target, machines()]);
    if (order.every((id, i) => id === target[i])) {
      this.ordering = null;
    } else if (this.ordering?.key !== key || this.orderingDue(Date.now())) {
      const moved = new Set();
      this.ordering = { key, at: Date.now(), machines: [] };
      for (let i = 0; i < target.length; i++) {
        const from = order.indexOf(target[i]);
        if (from === i) continue;
        run("space.move", { id: target[i], index: i + 1 });
        moved.add(sp.find((w) => w.id === target[i]).machine ?? null);
        order.splice(i, 0, order.splice(from, 1)[0]);
      }
      this.ordering.machines = [...moved];
    }
    return out.filter(r => this.shown.has(r.w.id));
  }

  // The rows, under a header per machine once one isn't this computer.
  grouped(t, collapsed) {
    const rows = this.ordered();
    const draw = (r) => (collapsed ? this.compact(r, t) : this.row(r, t));
    const remote = [...new Set([...rows.map(r => r.w.machine).filter(Boolean), ...this.machines.map(m => m.name), ...Object.keys(this.reconnecting)])].sort();
    const loading = m => {
      const layout = machines().find(k => k.name === m)?.layout;
      return layout === "loading" || (!layout && this.machines.some(k => k.name === m && k.state === "connected"))
        || spaces().some(s => (s.machine ?? null) === m && !this.shown.has(s.id));
    };
    const loadingRow = m => h_flex().id(`machine-loading-${m ?? "local"}`).h(28).flex_none().px(collapsed ? 0 : 8).items_center().when(collapsed, el => el.justify_center()).text_size(12).text_color(t.dim).child(collapsed ? "…" : "Loading…");
    if (!remote.length) return loading(null) && !rows.length ? [loadingRow(null)] : rows.map(draw);
    const machineNames = [null, ...remote];
    return machineNames.flatMap((m) => {
      const mine = rows.filter((r) => (r.w.machine ?? null) === m);
      const repair = this.reconnecting[m];
      const machine = this.machines.find(k => k.name === m) ?? repair?.machine;
      const connected = !m || machine?.state === "connected";
      const rebuilt = this.rebuilt(machine) || !!repair;
      const login = machine?.state === "needs_login" ? `hc machine login ${m}` : null;
      const folded = this.folded.has(m);
      const icon = svg(`mods/workspace-chrome/${m ? "server" : "monitor"}.svg`).size(13).flex_none();
      const badge = div().absolute().right(-3).bottom(-2).size(6).rounded(3).border_1().border_color(t.chrome).bg(connected ? t.ansi2 : t.dim);
      const head = h_flex().id(`machine-${m ?? "local"}`).h(26).flex_none().px(collapsed ? 0 : 8).gap(7).items_center().text_size(11).text_color(t.dim)
        .when(collapsed, el => el.mt(4).w(RAIL_CELL).justify_center().rounded(6).tooltip(login ? `${m} needs a login: run ${login}. Click for Copy.` : m ? `${m} · ${connected ? "connected" : (machine?.state ?? "asleep").replace(/_/g, " ")}` : "This computer"))
        .cursor_pointer().hover(s => s.bg(t.hover))
        .on_click((_e, cx) => {
          if (collapsed && login) { run("app.settings", { section: "machines" }); return; }
          folded ? this.folded.delete(m) : this.folded.add(m);
          localStorage.setItem("machines.folded", JSON.stringify([...this.folded]));
          cx.notify();
        })
        .when(!collapsed, el => el.child(icon))
        .when(collapsed, el => el.child(div().relative().flex_none().child(icon).when(Boolean(m), el => el.child(badge))))
        .when(!collapsed, el => el.child(div().flex_1().truncate().child(m ?? "This computer"))
          .when(!connected && !rebuilt && !login, el => el.child(div().flex_none().child((machine?.state ?? "asleep").replace(/_/g, " "))))
          .when(rebuilt, el => el.child(h_flex().flex_none().gap(3).items_center()
            .child(div().max_w(140).truncate().child(repair?.error || "rebuilt ·"))
            .child(div().id(`machine-connect-${m}`).text_color(repair?.error ? t.blocked : t.muted)
              .hover(s => s.text_color(t.foreground))
              .tooltip(repair?.error || "This machine was rebuilt or replaced. Click to connect to the new one.")
              .on_click((_e, cx) => { cx.stop_propagation(); this.reconnect(machine, cx); })
              .child(repair?.busy ? "Connecting…" : "Connect"))))
          .when(connected, el => el.child(div().id(`machine-add-${m ?? "local"}`).flex_none().px(4).rounded(4).hover(s => s.bg(t.hover).text_color(t.foreground))
            .on_click((_e, cx) => { cx.stop_propagation(); newSpace({ machine: m ?? "" }); }).child("+")))
          .child(div().size(6).rounded(3).flex_none().bg(connected ? t.ansi2 : t.dim))
          .child(svg(`mods/workspace-chrome/chevron-${folded ? "right" : "down"}.svg`).size(11).flex_none()));
      const empty = h_flex().id(`machine-new-${m ?? "local"}`).h(28).flex_none().px(collapsed ? 0 : 8).gap(7).items_center().rounded(7)
        .text_size(12).text_color(t.dim).hover(s => s.bg(t.hover).text_color(t.foreground))
        .on_click(() => newSpace({ machine: m ?? "" }))
        .when(collapsed, el => el.w(RAIL_CELL).rounded(6).justify_center().tooltip(`New space on ${m ?? "this computer"}`)
          .child(h_flex().size(18).rounded(5).border_1().border_color(t.dim).items_center().justify_center()
            .child(svg("mods/workspace-chrome/plus.svg").size(10))))
        .when(!collapsed, el => el.child(svg("mods/workspace-chrome/plus.svg").size(12)).child("New space there"));
      if (!collapsed && rebuilt) return [head];
      const cell = collapsed ? railCell : (el) => el;
      const guidance = !collapsed && login ? [v_flex().px(8).pb(6).gap(3).flex_none()
        .child(div().text_size(11).text_color(t.blocked).child("needs a login: run"))
        .child(h_flex().gap(5).items_center()
          .child(div().flex_1().min_w(0).truncate().tooltip(login).text_size(11).text_color(t.muted).child(login))
          .child(div().id(`machine-login-copy-${m}`).flex_none().px(5).py(2).rounded(4)
            .text_size(11).text_color(t.foreground).bg(t.raised).cursor_pointer().hover(s => s.bg(t.hover))
            .on_click((_e, cx) => { cx.stop_propagation(); cx.write_to_clipboard(login); this.copiedLogin = login; cx.notify(); })
            .child(this.copiedLogin === login ? "Copied" : "Copy")))] : [];
      return [cell(head), ...guidance, ...(folded ? [] : mine.length ? mine.map(draw) : [loading(m) ? loadingRow(m) : cell(empty)])];
    });
  }

  // Only what's unusual, after the name: "herdr \u00b7 spike \u21912 \u21931". The repo or
  // branch goes when the name already says it (a worktree is named after its branch),
  // and master/main go: nearly every space is on one.
  gitTail(g, tree, name, t) {
    const raw = g.branch ?? "detached";
    const same = (a) => a.toLowerCase() === name.toLowerCase();
    const branch = same(raw) || raw === "master" || raw === "main" ? "" : raw;
    const repo = tree || same(g.name) ? "" : g.name;
    const where = [repo, branch].filter(Boolean).join(" \u00b7 ");
    return h_flex()
      .flex_1()
      .min_w(0)
      .gap(5)
      .justify_end()
      .items_center()
      .text_size(11.5)
      .text_color(t.dim)
      .when(Boolean(where), (el) => el.child(div().min_w(0).truncate().child(where)))
      .when(g.ahead > 0, (el) => el.child(div().flex_none().text_color(t.ansi2).child(`\u2191${g.ahead}`)))
      .when(g.behind > 0, (el) => el.child(div().flex_none().text_color(t.ansi1).child(`\u2193${g.behind}`)));
  }

  row({ w, i, g, tree }, t) {
    const on = w.active && !shepShown();
    const fromIndex = this.pressed === null ? -1 : spaces().findIndex(s => s.id === this.pressed);
    const colors = shared("space.colors") ?? {};
    const color = colors[w.id] ?? "ansi6";
    const fill = color.startsWith("#") ? color : (MARK[color] ?? t[color]);
    return v_flex()
      .relative()
      .id(`space-${w.id}`)
      .px(8)
      .h(rowHeight({ tree }))
      .flex_none()
      .justify_center()
      .rounded(8)
      .when(on, (el) => el.bg(t.selected))
      .when(!on, (el) => el.hover((s) => s.bg(t.hover)))
      .when(this.pressed === w.id && this.over !== w.id, (el) => el.opacity(0.5))
      .when(this.pressed !== null && this.over === w.id && this.pressed !== w.id, (el) => el.child(
        div().absolute().left(0).right(0).h(2).bg(t.accent)
          .when(fromIndex < i, line => line.bottom(0))
          .when(fromIndex > i, line => line.top(0)),
      ))
      .on_mouse_down("left", () => {
        this.pressed = w.id;
        this.over = w.id;
      })
      .on_mouse_move((_e, cx) => {
        const source = spaces().find(s => s.id === this.pressed);
        const over = source && (source.machine ?? null) === (w.machine ?? null) ? w.id : null;
        if (this.pressed !== null && this.over !== over) {
          this.over = over;
          cx.notify();
        }
      })
      .on_mouse_up("left", (_e, cx) => {
        const from = this.pressed;
        const over = this.over;
        this.pressed = null;
        this.over = null;
        if (from !== null && over === w.id && from !== w.id) {
          const index = spaces().findIndex(s => s.id === w.id);
          if (index !== -1) run("space.move", { id: from, index: index + 1 });
        } else if (from === w.id) select(w.id);
        cx.notify();
      })
      .on_mouse_down("right", () => this.menu(w))
      .child(
        h_flex()
          .gap(9)
          .items_center()
          .when(Boolean(tree), el => el.pl(22).child(svg("mods/workspace-chrome/branch.svg").size(13).text_color(t.dim)))
          .when(!tree, el => el.child(h_flex().size(18).flex_none().rounded(5).bg(fill).items_center().justify_center().text_size(10.5).font_bold().text_color("#ffffff").child([...w.name][0]?.toUpperCase() ?? "?")))
          .child(div().flex_shrink(0).max_w(150).truncate().text_color(t.foreground).child(w.name))
          .child(g ? this.gitTail(g, tree, w.name, t) : div().flex_1())
          .when(Boolean(this.marks?.[w.id]), (el) => el.child(this.reviewMark(w.id, this.marks[w.id], t))),
      );
  }

  // After the name: what waits on review here and its size, red when it needs your
  // LGTM (waitColor); a cleanup candidate or superseded work, quietly.
  reviewMark(id, m, t) {
    const mark = div().id(`review-${id}`).flex_none().text_size(11).tooltip(m.items.map(itemLabel).join("\n"));
    if (!m.waits) return mark.text_color(t.dim).child(m.quiet);
    return mark.font_medium().text_color(waitColor(t, m.lgtm)).child(`◆ ${size(m.lines)}${m.unknown ? "?" : ""}`);
  }

  compact({ w, i }, t) {
    return railCell(h_flex()
      .id(`space-${w.id}`)
      .relative()
      .w(RAIL_CELL)
      .h(26)
      .rounded(6)
      .justify_center()
      .items_center()
      .when(w.active && !shepShown(), (el) => el.bg(t.selected))
      .when(!w.active || shepShown(), (el) => el.hover((s) => s.bg(t.hover)))
      .on_click(() => select(w.id))
      .when(Boolean(this.marks?.[w.id]?.waits), (el) => el.tooltip(this.marks[w.id].items.map(itemLabel).join("\n")))
      .child(div().text_color(this.marks?.[w.id]?.waits ? waitColor(t, this.marks[w.id].lgtm) : w.active && !shepShown() ? t.foreground : t.muted).child(String(i + 1)))
      .child(div().absolute().right(5).text_color(tone(t, w.status)).child(glyph(w.status))));
  }

  // The header's count of what waits on review; a click opens the Review list.
  reviewBadge(r, rows, t) {
    const box = h_flex().flex_1().min_w(0).justify_end().pr(4);
    if (!r || r.missing) return box;
    const waits = rows.filter((x) => x.item.counts);
    const quiet = rows.length - waits.length;
    const st = reviewStatus(r, Date.now());
    const text = waits.length ? `◆ ${waits.length} to review` : quiet ? `${quiet} to clean up` : r.q ? "" : "review ?";
    if (!text) return box;
    const total = waits.reduce((n, x) => n + lines(x.item), 0);
    return box.child(
      div()
        .id("review-list")
        .px(6)
        .py(2)
        .rounded(5)
        .truncate()
        .cursor_pointer()
        .text_color(waits.length ? waitColor(t, waits.some((x) => lgtm(x.item))) : t.dim)
        .hover((s) => s.bg(t.hover))
        .tooltip(`${size(total)} lines wait on your review, ${st.text}. Click for the list; Ctrl+Shift+J goes to the next.`)
        .on_click(() => openOverlay({ mod: "bercail-spaces", kind: "dialog", width: 780, height: 480, props: { role: "reviews" } }))
        .child(text + (st.bad ? " (stale)" : "")),
    );
  }

  // The Review list (props.role "reviews", a dialog): the queue across repos, read-only.
  // Its targets show the space or open its review; nothing here merges, commits,
  // gives an LGTM or answers a desk.
  reviewList(t) {
    const r = shared(REVIEW) ?? {};
    const rows = reviewRows(r.q, spaces(), panes(), r.backend);
    const now = Date.now();
    const st = reviewStatus(r, now);
    const waits = rows.filter((x) => x.item.counts);
    const quiet = rows.filter((x) => !x.item.counts);
    const total = waits.reduce((n, x) => n + lines(x.item), 0);
    const overlay = props()?.overlay;
    const tilde = (p) => (p && p.startsWith(`${home()}/`) ? `~${p.slice(home().length)}` : (p ?? ""));
    const target = (id, label, f) =>
      div()
        .id(id)
        .flex_none()
        .px(8)
        .py(2)
        .rounded(5)
        .text_color(t.muted)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click(f)
        .child(label);
    const row = ({ item, space }, n) => {
      const heading =
        item.kind === "pr"
          ? `PR #${item.number}: ${item.title ?? ""}`
          : item.issue
            ? `${item.issue}${item.title ? `: ${item.title}` : ""}`
            : (item.title ?? "no issue");
      const by = item.by?.startsWith("/") ? ` (${tilde(item.by)})` : "";
      const state = { unknown: `unknown: ${item.why}`, cleanup: `${item.why}: clean up`, superseded: `${item.why}${by}` }[item.state];
      const facts = [item.kind === "pr" ? "PR" : `stakes ${item.change?.stakes ?? "?"}`, lgtm(item) && "needs your LGTM", state]
        .filter(Boolean)
        .join(" · ");
      const targets = [];
      if (space) targets.push(target(`review-space-${n}`, "Open space", () => { closeOverlay(overlay); select(space.id); }));
      if (space && item.kind === "staged") {
        targets.push(target(`review-open-${n}`, "Open review", () => {
          closeOverlay(overlay);
          run("space.select", { id: space.id });
          // bercail-shep shows the space view first when Shep shows, then bercail-desk opens Review.
          run("bercail-shep.desk:review");
        }));
      }
      if (item.kind === "pr" && item.url) targets.push(target(`review-pr-${n}`, "Open PR", (_e, cx) => cx.open_url(item.url)));
      if (!targets.length) targets.push(div().flex_none().px(8).text_color(t.dim).child("no space"));
      return h_flex()
        .id(`review-row-${n}`)
        .px(12)
        .py(6)
        .gap(10)
        .items_center()
        .rounded(6)
        .hover((s) => s.bg(t.hover))
        .child(
          v_flex()
            .flex_1()
            .min_w(0)
            .child(div().truncate().text_color(t.foreground).child(space?.name ?? tilde(item.kind === "pr" ? item.repo : item.path)))
            .child(div().truncate().text_size(11.5).text_color(t.dim).child(heading)),
        )
        .child(div().flex_none().w(72).text_color(t.muted).child(`${size(lines(item))} lines`))
        .child(div().flex_none().w(190).truncate().text_color(lgtm(item) ? t.ansi1 : item.counts ? t.muted : t.dim).child(facts))
        .child(div().flex_none().w(40).text_color(t.dim).child(ago(item.since, now) || "–"))
        .child(h_flex().flex_none().gap(2).children(targets));
    };
    const section = (text) => div().px(12).pt(10).pb(2).text_size(11).text_color(t.dim).child(text);
    return v_flex()
      .size_full()
      .bg(t.background)
      .text_size(12.5)
      .child(
        h_flex()
          .h(36)
          .flex_none()
          .px(12)
          .gap(10)
          .items_center()
          .border_b(1)
          .border_color(t.border)
          .child(div().flex_none().font_semibold().text_color(t.foreground).child("Review"))
          .child(div().flex_none().text_color(t.muted).child(`${waits.length} waiting · ${size(total)} lines`))
          .child(div().flex_1().truncate().text_color(st.bad ? t.blocked : t.dim).child(st.text))
          .child(target("review-close", "✕", () => closeOverlay(overlay))),
      )
      .child(
        v_flex()
          .flex_1()
          .min_h(0)
          .py(4)
          .overflow_y_scrollbar()
          .when(!rows.length, (el) => el.child(div().px(12).py(10).text_color(t.dim).child(r.q ? "Nothing waits on your review." : st.text)))
          .children(waits.map(row))
          .when(quiet.length > 0, (el) => el.child(section("Not counted against the review budget")).children(quiet.map((x, i) => row(x, waits.length + i)))),
      );
  }

  render() {
    const t = theme();
    if (this.role === "reviews") return this.reviewList(t);
    const collapsed = narrow();
    const review = shared(REVIEW);
    const rows = reviewRows(review?.q, spaces(), panes(), review?.backend);
    this.marks = marks(rows);
    const palette = ["ansi6", "ansi3", "ansi4", "ansi5", "ansi2", "ansi1"];
    const sp = spaces();
    const ids = new Set(sp.map(p => p.id));
    const kept = Object.fromEntries(Object.entries(shared("space.colors") ?? {}).filter(([id]) => ids.has(id)));
    let changed = Object.keys(kept).length !== Object.keys(shared("space.colors") ?? {}).length;
    for (const p of sp) {
      if (kept[p.id] || p.name === "~") continue;
      const uses = c => Object.values(kept).filter(v => v === c).length;
      kept[p.id] = palette.reduce((best, c) => uses(c) < uses(best) ? c : best);
      changed = true;
    }
    if (changed) setShared("space.colors", kept);
    return v_flex().size_full().min_h(0).bg(t.chrome).text_size(13)
      .child(h_flex().h(31).pl(16).pr(10).items_center().justify_between().text_size(11.5).text_color(t.dim)
        .when(collapsed, el => el.pl(0).pr(0).justify_center())
        .when(!collapsed, el => el.child("Spaces"))
        .when(!collapsed, el => el.child(this.reviewBadge(review, rows, t)))
        .child(div().id("space-new").size(26).flex_none().flex().items_center().justify_center().rounded(6).hover(s => s.bg(t.hover).text_color(t.foreground))
          .on_click(() => newSpace()).child(svg("mods/workspace-chrome/plus.svg").size(14))))
      .child(v_flex().flex_1().min_h(0).px(collapsed ? 0 : 8).pb(14).overflow_y_scrollbar().mode("always")
        .on_mouse_up("left", (_e, cx) => { this.pressed = null; cx.notify(); })
        .children(this.grouped(t, collapsed)));
  }
}
