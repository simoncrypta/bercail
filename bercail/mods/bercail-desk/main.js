// bercail desk: one sticky agent per space, shown in the layout's agent column.
//
// The desk agent is an hc terminal started as a sub-agent of the space's Shell
// terminal, so it belongs to the space without a pane in any tab. It carries
// labels bercail.role=agent and bercail.space=<space id>. Each desk shows in a
// terminal block of its own in the layout's `agent-stack`, `desk-<address>` (an agent
// block can't take the keyboard from a command, and agent.focus moves it to the parent pane).
//
// props.role: "header" (default) runs the logic and takes key commands;
// "empty" is the placeholder shown in the agent column when the space has no desk.
//
// Space keys go by the sidebar's order (Herdr's spaces mod): spaces in order, this
// computer's first and then each machine's, a linked worktree's space nested under the
// first space of its repo's main checkout. space-next/prev walk the spaces that aren't
// nested; subspace-next/prev walk the current repo's (main checkout and worktrees).
import { View, div } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import {
  agents, exec, focused, home, knownAgents, layout, nextCommand, notify, panes, props,
  readTextFile, run, setShared, shared, spaces, terminals, theme,
} from "herdr";

const CONFIG = "/.config/bercail/config.toml";
// The desk agents to choose from, by Herdr program key; argv is used when Herdr doesn't know one.
// own: keep this name over Herdr's (bstack is bercail's opencode setup).
const CHOICES = [
  { key: "opencode", name: "bstack", argv: ["opencode"], own: true },
  { key: "claude", name: "Claude Code", argv: ["claude"] },
  { key: "codex", name: "Codex", argv: ["codex"] },
  { key: "grok", name: "Grok", argv: ["grok"] },
];
const PICKED = "bercail.agent"; // shared: argv of the last agent picked, for Ctrl+Shift+A

// hc runs codex without its app-server daemon.
function deskArgv(argv) {
  const codex = argv[0]?.split("/").pop() === "codex";
  return codex && !argv.includes("--no-daemon") ? [...argv, "--no-daemon"] : argv;
}

function findNode(node, id) {
  if (!node || typeof node !== "object") return null;
  if (node.id === id) return node;
  for (const c of node.children ?? []) {
    const hit = findNode(c, id);
    if (hit) return hit;
  }
  return null;
}

// Tiny TOML reader for the keys bercail needs: [agent] command, [layout] review and auto_review.
function readConfig(text) {
  const cfg = { agent: ["cursor-agent"], review: "tuicr", autoReview: true };
  let section = "";
  for (const raw of text.split("\n")) {
    const line = raw.replace(/#.*$/, "").trim();
    const sec = line.match(/^\[(.+)\]$/);
    if (sec) { section = sec[1]; continue; }
    const kv = line.match(/^(\w+)\s*=\s*(.+)$/);
    if (!kv) continue;
    const value = kv[2].trim().replace(/^"(.*)"$/, "$1");
    if (section === "agent" && kv[1] === "command" && value) cfg.agent = value.split(/\s+/);
    if (section === "layout" && kv[1] === "review" && value) cfg.review = value === "hunk" ? "hunk diff" : value;
    if (section === "layout" && kv[1] === "auto_review") cfg.autoReview = value !== "false";
  }
  return cfg;
}

function deskFor(spaceId) {
  return terminals().find((t) => t.state === "live"
    && t.labels?.["bercail.role"] === "agent"
    && t.labels?.["bercail.space"] === spaceId) ?? null;
}

// The space a terminal belongs to: a desk by its label, else the tab of its pane,
// else its parent's (sub-agents have no pane).
function spaceOfTerminal(address) {
  const seen = new Set();
  let t = terminals().find((x) => x.address === address);
  while (t && !seen.has(t.address)) {
    seen.add(t.address);
    const label = t.labels?.["bercail.space"];
    if (label) return spaces().find((s) => s.id === label) ?? null;
    const tab = panes().find((p) => p.terminal === t.address)?.tab;
    if (tab) return spaces().find((s) => s.tabs.some((x) => x.id === tab)) ?? null;
    t = terminals().find((x) => x.address === t.parent);
  }
  return null;
}

// Someone else's PR on this checkout: its number, for `tuicr pr`.
async function foreignPr(folder) {
  try {
    const pr = await exec("gh", ["pr", "view", "--json", "number,author"], { cwd: folder });
    if (pr.code !== 0) return null;
    const { number, author } = JSON.parse(pr.stdout);
    const me = await exec("gh", ["api", "user", "--jq", ".login"], { cwd: folder });
    if (me.code !== 0 || !me.stdout.trim() || author?.login === me.stdout.trim()) return null;
    return number ?? null;
  } catch { return null; }
}

// What Review runs. `review = "tuicr"`: own work is the uncommitted tree, watched
// (agents stage and never commit unreviewed work); someone else's PR is `tuicr pr N`.
// Any other `review` is run as written.
async function reviewArgv(review, folder) {
  const argv = review.split(/\s+/).filter(Boolean);
  if (argv[0] !== "tuicr") return argv;
  if (argv.length === 1) {
    const pr = await foreignPr(folder);
    argv.push(...(pr ? ["pr", String(pr)] : ["-w"]));
  }
  if (!argv.includes("--no-update-check")) argv.push("--no-update-check");
  return argv;
}

// Where a space is now: its first terminal's live folder, else where it was made.
function placeOf(space, ps) {
  const tabs = new Set((space.tabs ?? []).map((t) => t.id));
  return ps.find((p) => tabs.has(p.tab) && p.cwd)?.cwd || space.folder;
}

// rows: { id, machine, git: { repo, linked } | null } in spaces() order. Returns them in
// the sidebar's order, each with `parent`: the space it is nested under, or null.
export function sidebarOrder(rows) {
  const machines = [...new Set(rows.map((r) => r.machine ?? null))]
    .sort((a, b) => (a === null ? -1 : b === null ? 1 : a.localeCompare(b)));
  const out = [];
  for (const m of machines) {
    const list = rows.filter((r) => (r.machine ?? null) === m);
    const main = new Map(); // repo -> the first space of its main checkout
    for (const r of list) if (r.git && !r.git.linked && !main.has(r.git.repo)) main.set(r.git.repo, r.id);
    for (const r of list) {
      if (r.git?.linked && main.has(r.git.repo)) continue;
      out.push({ ...r, parent: null });
      if (!r.git || main.get(r.git.repo) !== r.id) continue;
      for (const k of list) if (k.git?.linked && k.git.repo === r.git.repo) out.push({ ...k, parent: r.id });
    }
  }
  return out;
}

const wrap = (list, i) => list[(i + list.length) % list.length];

// The top-level space dir (1 or -1) away from current's (its parent's, when nested).
export function stepSpace(order, current, dir) {
  const tops = order.filter((r) => !r.parent);
  if (!tops.length) return null;
  const at = order.find((r) => r.id === current);
  const i = tops.findIndex((r) => r.id === (at?.parent ?? current));
  return (i < 0 ? tops[dir > 0 ? 0 : tops.length - 1] : wrap(tops, i + dir)).id;
}

// The space dir away from current among its repo's spaces, in sidebar order; null outside a repo.
export function stepSubspace(order, current, dir) {
  const at = order.find((r) => r.id === current);
  if (!at?.git) return null;
  const same = order.filter((r) => (r.machine ?? null) === (at.machine ?? null) && r.git?.repo === at.git.repo);
  return same.length > 1 ? wrap(same, same.indexOf(at) + dir).id : null;
}

// list: { address, space } in each space's own order. The agent dir away from current,
// spaces in sidebar order; from a terminal that isn't one, the first (dir 1) or last
// (dir -1) agent of the shown space or, if it has none, the next one that way.
export function stepAgent(order, list, current, space, dir) {
  const rank = new Map(order.map((r, i) => [r.id, i]));
  const all = list.filter((a) => rank.has(a.space)).sort((a, b) => rank.get(a.space) - rank.get(b.space));
  if (!all.length) return null;
  const i = all.findIndex((a) => a.address === current);
  if (i >= 0) return wrap(all, i + dir);
  const here = rank.get(space) ?? -1;
  return dir > 0
    ? all.find((a) => rank.get(a.space) >= here) ?? all[0]
    : [...all].reverse().find((a) => rank.get(a.space) <= here) ?? all[all.length - 1];
}

// The webhook follower (`bercail notify run`): one hidden hc terminal, kept
// running here so it lives as long as herdr-core, window open or not.
const NOTIFIER = "bercail-notify";
const NOTIFIER_PATH = 'command -v bercail >/dev/null || PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"';
const NOTIFIER_RUN = `${NOTIFIER_PATH}; exec bercail notify run`;

function shellOf(space) {
  const first = space?.tabs?.[0];
  if (!first) return null;
  return panes().find((p) => p.tab === first.id && p.terminal)?.terminal ?? null;
}

export default class BercailDesk extends View {
  init(_props, cx) {
    this.role = props()?.role ?? "header";
    this.cfg = readConfig("");
    this.prev = {};          // desk address -> last status
    this.pendingReview = {}; // space id -> folder, opened when the space is shown
    this.starting = {};      // space id -> true while hc run is in flight
    this.lastAuto = {};      // space id -> when Review last opened on its own (ms)
    this.lastPane = null;    // the pane the keyboard was last in, to come back from the desk
    this.git = {};           // [machine, folder] -> { at, git: { repo, linked } | null }
    this.choices = CHOICES.map((c) => ({ ...c, installed: true }));
    cx.spawn(async (cx) => {
      try {
        const known = await knownAgents();
        this.choices = CHOICES.map((c) => {
          const k = known.find((a) => a.key === c.key);
          return k ? { ...c, name: c.own ? c.name : k.name, argv: k.run, installed: k.installed } : c;
        });
      } catch { /* keep the defaults */ }
      cx.notify();
    });
    if (this.role !== "header") return;
    // On a timer, not on render: an idle window doesn't render, and the follower
    // must come back after it exits.
    // Only with bercail installed: the layout also works on its own.
    cx.spawn(async () => {
      try {
        const r = await exec("bash", ["-lc", `${NOTIFIER_PATH}; command -v bercail`]);
        this.hasBercail = r.code === 0;
      } catch { this.hasBercail = false; }
      this.ensureNotifier();
    });
    cx.timer.every(60000, () => this.ensureNotifier());
    cx.spawn(async (cx) => {
      try { this.cfg = readConfig(await readTextFile(home() + CONFIG)); } catch { /* defaults */ }
      cx.notify();
    });
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        await this.command(c);
        cx.notify();
      }
    });
  }

  space() {
    const id = focused()?.space;
    return spaces().find((s) => s.id === id) ?? null;
  }

  // "<command>" acts on the shown space; "<command>:<terminal>" (from an agent,
  // `herdr-app do bercail-desk.review:$HC_TERMINAL_ID`) on that terminal's space.
  async command(raw) {
    const [c, address] = raw.split(":");
    const space = address ? spaceOfTerminal(address) : this.space();
    if (!space) {
      if (address) notify({ title: "bercail", body: `No space has terminal ${address}.`, level: "warning" });
      return;
    }
    const desk = deskFor(space.id);
    switch (c) {
      case "agent":
        if (desk) run("pane.focus", { terminal: desk.address });
        else await this.start(space);
        break;
      case "review": await this.review(space, desk?.cwd ?? space.folder, true); break;
      case "close-review": {
        const tab = space.tabs.find((t) => t.name === "Review");
        if (tab) run("tab.close", { id: tab.id });
        break;
      }
      case "shell": run("tab.select", { index: 1 }); break;
      case "go-left":
      case "go-right":
      case "go-up":
      case "go-down":
        this.go(c.slice(3), desk);
        break;
      case "space-next":
      case "space-prev":
      case "subspace-next":
      case "subspace-prev": {
        const step = c.startsWith("sub") ? stepSubspace : stepSpace;
        const id = step(await this.spaceOrder(), space.id, c.endsWith("next") ? 1 : -1);
        if (id && id !== space.id) run("space.select", { id });
        break;
      }
      case "agent-next":
      case "agent-prev": {
        const a = stepAgent(await this.spaceOrder(), this.agentList(), focused()?.terminal, space.id,
          c.endsWith("next") ? 1 : -1);
        if (a) this.focusAgent(a);
        break;
      }
      case "files":
      case "changes": {
        // Toggle: the same key again hides the panel.
        const panel = findNode(layout(), "panel-body");
        if (panel && !panel.hidden && panel.active === c) { run("layout.hide", { id: "panel-body" }); break; }
        run("layout.select", { stack: "panel-body", child: c });
        run("layout.show", { id: "panel-body" });
        break;
      }
    }
  }

  // The desk is a layout block, not a pane of the tab: pane.go neither reaches it nor
  // leaves it. Left from the leftmost pane goes to the desk, right from the desk back.
  // Up/down on the desk do nothing (they'd reach the agent as arrow keys otherwise).
  go(direction, desk) {
    const f = focused();
    const onDesk = desk && !f?.pane && f?.terminal === desk.address;
    if (onDesk) {
      if (direction !== "right") return;
      const tabPanes = panes().filter((p) => p.tab === f.tab && p.terminal);
      const back = tabPanes.find((p) => p.pane === this.lastPane) ?? tabPanes[0];
      if (back) run("pane.focus", { pane: back.pane });
      return;
    }
    const before = f?.pane;
    run("pane.go", { direction });
    if (direction === "left" && desk && focused()?.pane === before) run("pane.focus", { terminal: desk.address });
  }

  // The spaces in sidebar order (see sidebarOrder), git asked again after 10s.
  async spaceOrder() {
    const ps = panes();
    const now = Date.now();
    const rows = await Promise.all(spaces().map(async (s) => {
      const on = s.machine ?? null;
      const cwd = placeOf(s, ps);
      const key = JSON.stringify([on, cwd]);
      if (!(now - (this.git[key]?.at ?? 0) < 10000)) {
        let git = null;
        try {
          const r = await exec("git", ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"], { cwd, on });
          const [top, repo] = r.stdout.trim().split("\n");
          if (r.code === 0 && top && repo) git = { repo, linked: repo !== `${top}/.git` };
        } catch { /* no folder, or its machine is away: not a repo for now */ }
        this.git[key] = { at: now, git };
      }
      return { id: s.id, machine: on, git: this.git[key].git };
    }));
    return sidebarOrder(rows);
  }

  // Every space's desk first, then the agents list's agents (Herdr's order: tab, pane).
  agentList() {
    const out = [];
    for (const s of spaces()) {
      const desk = deskFor(s.id);
      if (desk) out.push({ address: desk.address, space: s.id, desk: true });
    }
    for (const a of agents()) if (!out.some((o) => o.address === a.address)) out.push({ address: a.address, space: a.space });
    return out;
  }

  // agent.focus would put the keyboard on a desk's parent pane (the Shell): a desk is
  // shown in its space's agent block and focused there.
  focusAgent(a) {
    if (!a.desk) { run("agent.focus", { terminal: a.address }); return; }
    if (focused()?.space !== a.space) {
      run("space.select", { id: a.space });
      // Add or select the desk's block in the agent column before focusing it.
      this.sync(spaces().find((s) => s.id === a.space));
    }
    run("pane.focus", { terminal: a.address });
  }

  // argv: the agent to start; default the last one picked, else bercail's [agent] command.
  async start(space, argv = shared(PICKED) ?? this.cfg.agent) {
    if (this.starting[space.id]) return;
    const shell = shellOf(space);
    if (!shell) {
      notify({ title: "bercail", body: "This space has no Shell terminal to start the agent from.", level: "warning" });
      return;
    }
    this.starting[space.id] = true;
    try {
      const cwd = panes().find((p) => p.terminal === shell)?.cwd || space.folder;
      const r = await exec("hc", ["run", "--bg", "--json", "--keep", "--outlive-parent", "--no-notify",
        "--parent", shell, "--cwd", cwd,
        "--label", "bercail.role=agent", "--label", `bercail.space=${space.id}`,
        ...deskArgv(argv)]);
      if (r.code !== 0) throw new Error(r.stderr || r.stdout);
      const first = space.tabs[0];
      if (first && !first.named) run("tab.rename", { id: first.id, name: "Shell" });
    } catch (e) {
      notify({ title: "bercail: agent did not start", body: String(e?.message ?? e), level: "error" });
    } finally {
      this.starting[space.id] = false;
    }
  }

  // Select the space's Review tab, or open the review tool in a new one. A live Review
  // is never restarted (tuicr's watch keeps it current). Quitting the tool leaves a
  // shell in the tab: that tab is replaced.
  // always: open even on a clean tree (asked for, not on agent done).
  async review(space, folder, always) {
    const shown = focused()?.space === space.id;
    const tab = space.tabs.find((t) => t.name === "Review");
    if (tab) {
      const live = panes().some((p) => p.tab === tab.id && p.terminal && p.program?.key !== "shell");
      if (live) { if (shown) run("tab.select", { id: tab.id }); return; }
      run("tab.close", { id: tab.id, confirmed: true });
    }
    try {
      if (!always) {
        const st = await exec("git", ["status", "--porcelain"], { cwd: folder });
        if (st.code !== 0 || !st.stdout.trim()) return;
      }
      run("tab.new", { space: space.id, name: "Review", folder, argv: await reviewArgv(this.cfg.review, folder) });
    } catch (e) {
      notify({ title: "bercail: Review did not open", body: String(e?.message ?? e), level: "error" });
    }
  }

  ensureNotifier() {
    if (!this.hasBercail) return;
    if (terminals().some((t) => t.name === NOTIFIER && t.state === "live")) return;
    exec("hc", ["run", "--bg", "--no-parent", "--no-notify", "--rm", "--name", NOTIFIER,
      "--label", "bercail.role=notify", "bash", "-lc", NOTIFIER_RUN]).catch(() => {});
  }

  // Runs on every render: Herdr re-renders on any live change.
  sync(space = this.space()) {
    if (!space) return null;
    const desk = deskFor(space.id);
    const f = focused();
    if (f?.pane) this.lastPane = f.pane;
    this.deskFocused = Boolean(desk && !f?.pane && f?.terminal === desk.address);

    // Each desk has its own block in the agent column, `desk-<address>`, added the
    // first time its space is shown and kept: switching spaces only selects it, like
    // a tab. (One shared block repointed per space could show a desk blank until its
    // agent redrew.) The app drops a block when its terminal ends. A block it drops
    // for a live desk is not added again, so this can't loop: the placeholder shows.
    // Only children that exist are selected, since a failed layout.select is a toast,
    // not a throw, and this runs on every render.
    try {
      const tree = layout();
      const stack = findNode(tree, "agent-stack");
      if (stack) {
        this.added ??= new Set(); // desk block ids this copy added
        const id = desk ? `desk-${desk.address}` : null;
        const kids = stack.children ?? [];
        // The shared block of older layouts, and blocks whose desk has finished.
        const ended = (c) => c.id === "agent" || (c.id.startsWith("desk-")
          && terminals().some((t) => t.address === c.content?.terminal && t.state !== "live"));
        const add = Boolean(id) && !kids.some((c) => c.id === id) && !this.added.has(id);
        const want = id && (add || kids.some((c) => c.id === id)) ? id : "empty";
        if (add || kids.some(ended)) {
          if (add) this.added.add(id);
          stack.children = kids.filter((c) => !ended(c));
          if (add) stack.children.push({ id, type: "block", content: { terminal: desk.address }, padding: [6, 6] });
          stack.active = want; // set with the tree: a separate select can lose to the file
          run("layout.set", { layout: tree });
        } else if (stack.active !== want && kids.some((c) => c.id === want)) {
          run("layout.select", { stack: "agent-stack", child: want });
        }
      }
    } catch { /* a layout without the agent column: show nothing extra */ }

    // Review when a desk finishes with uncommitted changes. A short turn can
    // finish between renders, so any arrival at done counts (first sight too).
    for (const t of terminals()) {
      if (t.labels?.["bercail.role"] !== "agent") continue;
      const before = this.prev[t.address];
      this.prev[t.address] = t.status;
      const finished = (t.status === "done" && before !== "done") || (before === "working" && t.status === "idle");
      if (finished && this.cfg.autoReview) {
        this.pendingReview[t.labels["bercail.space"]] = t.cwd;
      }
    }
    const folder = this.pendingReview[space.id];
    if (folder) {
      delete this.pendingReview[space.id];
      const now = Date.now();
      if (now - (this.lastAuto[space.id] ?? 0) > 15000) {
        this.lastAuto[space.id] = now;
        this.review(space, folder, false);
      }
    }
    return desk;
  }

  render(cx) {
    const t = theme();
    if (this.role === "empty") {
      const picked = JSON.stringify(shared(PICKED) ?? null);
      const buttons = h_flex().gap(8);
      for (const c of this.choices) {
        const argv = deskArgv(c.argv);
        const last = JSON.stringify(argv) === picked;
        buttons.child(div().id(`start-${c.key}`).px(14).py(6).rounded(6)
          .bg(last ? t.solid : t.chrome).text_color(last ? t.solid_foreground : t.foreground)
          .border_1().border_color(t.border)
          .when(!c.installed, (el) => el.opacity(0.45))
          .hover((s) => s.opacity(0.85))
          .on_click((_e, cx) => cx.spawn(async (cx) => {
            const sp = this.space();
            if (!sp) return;
            setShared(PICKED, argv);
            await this.start(sp, argv);
            cx.notify();
          }))
          .child(c.installed ? c.name : `${c.name} (not installed)`));
      }
      return v_flex().size_full().items_center().justify_center().gap(12).bg(t.background).text_color(t.muted).text_size(13)
        .child("No agent on this desk")
        .child(buttons)
        .child(div().text_color(t.dim).text_size(12)
          .child(picked !== "null" ? "Ctrl+Shift+A starts the highlighted one" : "Pick the agent for this desk"));
    }
    const desk = this.sync();
    const info = desk ? agents().find((a) => a.address === desk.address) : null;
    const status = info?.status ?? desk?.status ?? null;
    const color = { working: t.working, blocked: t.blocked, done: t.done, idle: t.idle }[status] ?? t.dim;
    return h_flex().size_full().px(12).gap(8).items_center().bg(t.chrome).text_size(12.5).text_color(t.muted)
      .border_b_2().border_color(this.deskFocused ? t.accent : t.chrome)
      .child(div().size(7).rounded(4).bg(color))
      .child(div().text_color(t.foreground).font_semibold().child(info?.program?.name ?? desk?.program?.name ?? (desk ? "agent" : "desk")))
      .child(div().flex_1().truncate().text_color(t.dim).child(desk ? (info?.title ?? "") : "Ctrl+Shift+A starts the agent"))
      .when(Boolean(status), (el) => el.child(div().text_color(color).child(status)));
  }
}
