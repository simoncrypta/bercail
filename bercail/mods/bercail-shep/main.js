// bercail Shep: the bercail layout's control room. Two views share one window:
//
// - Shep view: Shep's terminal on the left, the navigator (spaces and agents) on
//   the right. The `work` column is hidden.
// - Space view: the navigator on the left, the shown space's desk, tabs and panels
//   on the right. The `shep` column is hidden.
//
// The view is only which of the layout's `shep` and `work` columns is hidden: hidden
// columns keep their terminals and mods running, so switching never starts or stops
// anything. The app launches into the Shep view. Clicking a space (bercail-spaces)
// shows the space view; the navigator's Shep row (or Ctrl+Shift+H) comes back.
//
// Shep is one hc terminal, `bercail-shep` (label bercail.role=shep), not in any space.
// It is found again by its label, so the same session shows after a restart and no
// second one starts. It starts on its own once per app session; one the person quit
// stays quit until "Start Shep". The terminal runs `bercail shep run`: Shep on Pi.
// With a backend in config.toml ([herdr] backend, the Herdr machine bercail runs on),
// Shep is looked for and started there, and desks' labels name that machine's ids.
//
// props.role:
// - "nav" (default): the navigator's Shep row. Always shown, so it runs the logic: the
//   launch view, Shep's block in `shep-stack`, where the keyboard is, key commands.
// - "header": the bar above Shep's terminal.
// - "empty": the placeholder in `shep-stack` while Shep isn't running.
// - "decisions": the Decisions panel under Shep's terminal (`shep-decisions`, hidden
//   until the header's Decisions toggle shows it): Shep's pending questions in words.
// - "modal": the bar of an agent's terminal opened over either view (bercail-agents
//   opens it); props.terminal is the agent, props.back where the keyboard was.
import { View, div, image, svg } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import {
  agents,
  closeOverlay,
  exec,
  focused,
  home,
  layout,
  nextCommand,
  notify,
  panes,
  props,
  readTextFile,
  run,
  spaces,
  terminals,
  theme,
  watchFolder,
} from "herdr";

const NAME = "bercail-shep";
const ROLE = "shep";
// Asked of and run in herdr-core's environment (hc exec, hc run), which may lack the
// login shell's PATH (mise, ~/.local/bin). `bercail shep run` keeps the message
// of a Pi that fails on screen until Enter; quitting normally closes the terminal.
const BERCAIL_PATH = 'command -v bercail >/dev/null || PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"';
const SHEP_RUN = `${BERCAIL_PATH}; exec bercail shep run`;
const KEY = "Ctrl+Shift+H";
const CONFIG = "/.config/bercail/config.toml";

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
export const machineOf = (address) => (address?.includes("/") ? address.slice(0, address.indexOf("/")) : null);
export const qualify = (raw, machine) => (machine && raw ? `${machine}/${raw}` : raw);
// The Decisions panel reads Shep's question ledger through bercail and never answers:
// a desk can synthesize a click this app cannot tell from the person's (docs/shep.md,
// "The Decisions panel"). Discuss selects the question's topic for Shep's next turn.
const PANEL = `${BERCAIL_PATH}; exec bercail shep question panel`;
const THREAD = `${BERCAIL_PATH}; exec bercail shep question thread "$1"`;
const PANEL_ID = "shep-decisions";

export function find(node, id) {
  if (!node || typeof node !== "object") return null;
  if (node.id === id) return node;
  for (const c of node.children ?? []) {
    const hit = find(c, id);
    if (hit) return hit;
  }
  return null;
}

// "shep", "space", or null in a layout without the two views.
export function viewOf(tree) {
  const shep = find(tree, "shep");
  if (!shep || !find(tree, "work")) return null;
  return shep.hidden ? "space" : "shep";
}

// With a backend, only the Shep there; before the config is read, or without one, any.
export function shepTerminal(all = terminals(), backend = S.backend) {
  return (
    all.find(
      (t) =>
        t.state === "live" && t.labels?.["bercail.role"] === ROLE && (!backend || machineOf(t.address) === backend),
    ) ?? null
  );
}

function setView(view) {
  run("layout.hide", { id: view === "shep" ? "work" : "shep" });
  run("layout.show", { id: view === "shep" ? "shep" : "work" });
}

// The view written into a tree, for a layout.set made before a setView has shown.
export function withView(tree, view) {
  const shep = find(tree, "shep"),
    work = find(tree, "work");
  if (shep && work) {
    shep.hidden = view !== "shep";
    work.hidden = view === "shep";
  }
  return tree;
}

// Shep's block in `shep-stack`: `shep-<address>`, added once per terminal and kept,
// like a desk's. Returns the tree to layout.set (with the child to show), a child to
// select, or nothing. `added`: block ids already added, never added twice (the app
// drops a block whose terminal ends; adding it back could loop).
export function stackPlan(tree, shep, added) {
  const stack = find(tree, "shep-stack");
  if (!stack) return {};
  const id = shep ? `shep-${shep.address}` : null;
  const kids = stack.children ?? [];
  const stale = (c) => c.id !== "shep-empty" && c.id !== id;
  const add = Boolean(id) && !kids.some((c) => c.id === id) && !added.has(id);
  const want = id && (add || kids.some((c) => c.id === id)) ? id : "shep-empty";
  if (add || kids.some(stale)) {
    stack.children = kids.filter((c) => !stale(c));
    if (add) stack.children.push({ id, type: "block", content: { terminal: shep.address }, padding: [6, 6] });
    stack.active = want; // with the tree: a separate select can lose to the file
    return { set: tree, added: add ? id : null };
  }
  if (stack.active !== want && kids.some((c) => c.id === want)) return { select: want };
  return {};
}

// Where the keyboard must go so it never types into a hidden terminal: in the Shep
// view, out of a (hidden) pane into Shep; coming back to the space view (`was`: the
// view at the last render), or still on Shep there, to where it was in the space
// (`back`: { pane } or { terminal } of its desk), else the shown tab's first pane.
// `ready`: Shep's block is in the layout (pane.focus fails before). Returns pane.focus
// args, or null.
export function focusPlan(view, was, f, shep, ready, back, ps, space) {
  if (!f) return null;
  if (view === "shep") return f.pane && shep && ready ? { terminal: shep.address } : null;
  const onShep = Boolean(shep) && !f.pane && f.terminal === shep.address;
  if (view !== "space" || (was !== "shep" && !onShep)) return null;
  let to = null;
  if (back?.pane && ps.some((p) => p.pane === back.pane)) to = { pane: back.pane };
  else if (back?.terminal) to = { terminal: back.terminal };
  else if (onShep) {
    const tab = space?.tabs.find((t) => t.active);
    const pane = ps.find((p) => p.tab === tab?.id && p.terminal) ?? ps.find((p) => p.tab === tab?.id);
    if (pane) to = { pane: pane.pane };
  }
  if (!to || (to.pane && to.pane === f.pane) || (to.terminal && !f.pane && to.terminal === f.terminal)) return null;
  return to;
}

// Shared by every copy: whether bercail is installed (and why a check could not tell),
// a start in flight, and the backend (undefined until config.toml is read).
const S = {
  found: null,
  checkError: null,
  check: null,
  starting: false,
  error: null,
  backend: undefined,
  config: null,
};

function readBackend() {
  S.config ??= readTextFile(home() + CONFIG)
    .catch(() => null)
    .then((text) => {
      S.backend = backendOf(text);
    });
  return S.config;
}

// Shared by every copy: the last panel JSON, its error, the load in flight (and whether
// the ledger changed during it), and the copies waiting to redraw.
const D = { view: null, error: null, loading: null, again: false, waiters: [], note: null };

function decisionsChanged() {
  const waiting = D.waiters;
  D.waiters = [];
  for (const wake of waiting) wake();
}
const nextDecisions = () => new Promise((wake) => D.waiters.push(wake));

function decisionsShown(tree = layout()) {
  const node = find(tree, PANEL_ID);
  return viewOf(tree) === "shep" && Boolean(node) && !node.hidden;
}

export function loadDecisions() {
  // A change during a load may not be in what it read: load once more after it.
  if (D.loading) {
    D.again = true;
    return D.loading;
  }
  // Shep's ledger is where bercail runs: on the backend when there is one.
  D.loading = readBackend()
    .then(() => exec("bash", ["-lc", PANEL], { timeout: 60000, on: S.backend }))
    .then((r) => {
      if (r.code !== 0) throw new Error(r.stderr.trim() || `bercail shep question panel exited ${r.code}`);
      D.view = JSON.parse(r.stdout);
      D.error = null;
    })
    .catch((e) => {
      D.error = String(e?.message ?? e);
    })
    .finally(() => {
      D.loading = null;
      decisionsChanged();
      if (D.again) {
        D.again = false;
        loadDecisions();
      }
    });
  return D.loading;
}

// Each header and Decisions copy watches on its own cx, so one closing stops no other;
// loads in flight are shared. A new question rewrites questions.json; a staged tree or
// a desk changes elsewhere, so the open panel also looks again every 30 seconds. A
// ledger on the backend can't be watched from here: the count looks every 30 seconds.
// Data never moves the view or the keyboard: only the count and the cards change.
function watchDecisions(cx) {
  cx.spawn(async (cx) => {
    for (;;) {
      await nextDecisions();
      cx.notify();
    }
  });
  cx.timer.every(30000, () => {
    if (S.backend || decisionsShown()) loadDecisions();
  });
  cx.spawn(async (cx) => {
    await (D.loading ?? loadDecisions()); // the other copy's first load will do
    for (;;) {
      const dir = S.backend ? null : D.view?.state; // a backend's path is not this computer's
      let paths = null;
      try {
        if (dir) paths = await watchFolder(dir);
      } catch {}
      // Shep's session files change all the time: only the ledger reloads (and redraws).
      if (paths?.some((p) => p === dir || p.endsWith("/questions.json"))) {
        await loadDecisions();
        cx.notify(); // also ends this loop once a newer mod version runs
      } else if (!paths) await nextDecisions();
    }
  });
}

const REASONS = {
  "repo changed": "the repo",
  "head changed": "new commits",
  "stagedTree changed": "the staged change",
  "base changed": "the base",
  "space changed": "the desk's space",
  "session changed": "the desk's session",
  "worktree changed": "the worktree",
};

function clock(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "at an unknown time";
  const pad = (n) => String(n).padStart(2, "0");
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const today = new Date();
  return d.toDateString() === today.toDateString()
    ? time
    : `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${time}`;
}

// A card in words: where (the space as Herdr names it), what (size and stakes), its state.
// Question tokens are the ledger's keys, never shown.
export function cardWords(card, all = spaces(), backend = S.backend) {
  const t = card.target ?? {};
  const space = all.find((x) => x.id === qualify(t.space, backend)); // the backend's sp1 is box/sp1 here
  const folder = (t.worktree || t.repo || "")
    .replace(/\/\.git$/, "")
    .split("/")
    .filter(Boolean)
    .pop();
  const where = space?.name || (t.space ? `${folder || "a desk"} (its space is closed)` : folder || t.topic);
  const change = card.change;
  const what = [
    where,
    change ? `${change.lines} ${change.lines === 1 ? "line" : "lines"}` : null,
    change?.stakes === "high" ? "high-stakes" : null,
  ].filter(Boolean);
  const reasons = (card.reasons ?? []).map((r) =>
    r.startsWith("target unavailable: ")
      ? r.slice(20).replace(/^Question target: /, "")
      : r === "policy unavailable; not checked"
        ? "the repo's policy could not be read"
        : (REASONS[r] ?? r),
  );
  const state =
    card.status === "fresh"
      ? { word: "open", why: null }
      : card.status === "stale"
        ? { word: "stale", why: `Changed since Shep asked: ${reasons.join(", ")}. Shep must ask again.` }
        : { word: "unknown", why: `Can't check it now: ${reasons.join("; ") || "no answer from bercail"}.` };
  return { title: what.join(", "), ...state, asked: `asked ${clock(card.createdAt)}` };
}

function checkBercail() {
  S.check ??= readBackend()
    .then(() =>
      exec("hc", [
        "exec",
        ...(S.backend ? ["--on", S.backend] : []),
        "bash",
        "-lc",
        `${BERCAIL_PATH}; command -v bercail`,
      ]),
    )
    .then((r) => {
      S.found = r.code === 0;
      // hc's own error (an unknown machine, one that is away), not bercail missing.
      const hcError = !S.found && r.stderr.trim().startsWith('{"error"') && JSON.parse(r.stderr).error?.message;
      S.checkError = hcError || null;
    })
    .catch((e) => {
      S.found = false;
      S.checkError = String(e?.message ?? e);
    })
    .finally(() => {
      S.check = null;
    });
  return S.check;
}

// One Shep: none while one is live or starting. hc names are unique among live
// terminals, so a start that races one the list doesn't show yet is refused: fine.
async function startShep() {
  await readBackend(); // which Shep counts depends on it
  if (S.starting || shepTerminal()) return;
  S.starting = true;
  S.error = null;
  try {
    await checkBercail();
    if (!S.found) return;
    const r = await exec("hc", [
      "run",
      "--bg",
      "--json",
      "--no-parent",
      "--no-notify",
      "--rm",
      "--name",
      NAME,
      // On the backend, hc starts it in that machine's home.
      ...(S.backend ? ["--on", S.backend] : ["--cwd", home()]),
      "--label",
      `bercail.role=${ROLE}`,
      "bash",
      "-lc",
      SHEP_RUN,
    ]);
    if (r.code !== 0 && !/"name_taken"/.test(r.stderr + r.stdout)) throw new Error((r.stderr || r.stdout).trim());
  } catch (e) {
    S.error = String(e?.message ?? e);
    notify({ title: "bercail: Shep did not start", body: S.error, level: "error" });
  } finally {
    S.starting = false;
  }
}

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

export default class BercailShep extends View {
  init(_props, cx) {
    this.role = props()?.role ?? "nav";
    if (this.role === "modal") return;
    cx.spawn(async (cx) => {
      await checkBercail();
      cx.notify();
    });
    if (this.role === "header" || this.role === "decisions") watchDecisions(cx);
    if (this.role !== "nav") return;
    this.added = new Set(); // Shep block ids this copy added
    this.back = {}; // space id -> { pane } or { terminal }: where the keyboard was
    this.pending = null; // { view, at }: a view this copy set that layout() doesn't show yet
    // Once per app session (a mod reload keeps globalThis): the Shep view, and Shep.
    // Done in sync(): layout() and terminals() are empty this early.
    const app = (globalThis.bercailShep ??= {});
    this.launch = !app.launched;
    this.autostart = !app.launched;
    app.launched = true;
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        await this.command(c);
        cx.notify();
      }
    });
  }

  async command(raw) {
    const view = viewOf(layout());
    const [c, arg] = raw.split(/:(.*)/s);
    switch (c) {
      case "toggle":
        if (view) this.show(view === "shep" ? "space" : "shep");
        break;
      case "show":
        if (view) this.show("shep");
        break;
      case "space":
        if (view) this.show("space");
        break;
      case "start":
        await startShep();
        break;
      // Ctrl+Space: Herdr's own Go to… search, over the space view so a pick shows.
      case "goto":
        this.inSpace(view, ["mod.open", { name: "picker" }]);
        break;
      // A bercail-desk key pressed in the Shep view (its `keys` copy sends it here).
      case "desk":
        if (arg) this.inSpace(view, [`bercail-desk.${arg}`]);
        break;
    }
  }

  // Runs a command in the space view: from the Shep view, once that shows and the
  // keyboard is back in the space, so a command that moves it (an agent, a pick) wins.
  inSpace(view, cmd) {
    if (view === "shep") this.show("space", cmd);
    else run(...cmd);
  }

  // then: [name, args] to run once the view shows.
  show(view, then = null) {
    this.pending = { view, at: Date.now(), then };
    setView(view);
  }

  // Runs on every render: Herdr re-renders on any live change.
  sync() {
    const tree = layout();
    const view = viewOf(tree);
    if (!view) return view;
    if (this.launch) {
      this.launch = false;
      if (view === "space") this.show("shep");
    }
    const then = this.pending?.view === view ? this.pending.then : null;
    if (this.pending?.view === view || Date.now() - (this.pending?.at ?? 0) > 2000) this.pending = null;
    // Start Shep once the core has listed its terminals (it lists them after the
    // layout): before that, terminals() can't tell whether Shep runs already.
    if (this.autostart && terminals().length > 0) {
      this.autostart = false;
      startShep();
    }
    const shep = shepTerminal();
    const plan = stackPlan(tree, shep, this.added);
    if (plan.set) {
      if (plan.added) this.added.add(plan.added);
      // layout.set writes the whole tree: a view switch still on its way would be undone.
      run("layout.set", { layout: this.pending ? withView(plan.set, this.pending.view) : plan.set });
    } else if (plan.select) {
      run("layout.select", { stack: "shep-stack", child: plan.select });
    }
    const f = focused();
    const ps = panes();
    const was = this.view;
    this.view = view;
    // Where the keyboard is in the space, kept while the space view stays: hiding the
    // Shep view moves it on its own first.
    if (view === "space" && was === "space" && f?.space) {
      const desk =
        f.terminal &&
        terminals().find(
          (t) =>
            t.address === f.terminal &&
            t.labels?.["bercail.role"] === "agent" &&
            qualify(t.labels?.["bercail.space"], machineOf(t.address)) === f.space,
        );
      if (f.pane) this.back[f.space] = { pane: f.pane };
      else if (desk) this.back[f.space] = { terminal: f.terminal };
    }
    const ready =
      Boolean(shep) &&
      !plan.set &&
      Boolean(find(tree, "shep-stack")?.children?.some((c) => c.id === `shep-${shep.address}`));
    const space = spaces().find((s) => s.id === f?.space);
    const to = focusPlan(view, was, f, shep, ready, this.back[f?.space], ps, space);
    if (to) run("pane.focus", to);
    if (then) run(...then);
    return view;
  }

  render(cx) {
    const t = theme();
    switch (this.role) {
      case "header":
        return this.header(t);
      case "empty":
        return this.empty(t);
      case "decisions":
        return this.decisions(t);
      case "modal":
        return this.modal(t);
    }
    const view = this.sync();
    const shep = shepTerminal();
    const on = view === "shep";
    const dot = shep ? t.ansi2 : S.found === false ? t.blocked : t.dim;
    // The sidebar's rail (narrower than 160px): the mark alone.
    const rail = (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;
    return h_flex()
      .size_full()
      .px(rail ? 0 : 8)
      .items_center()
      .justify_center()
      .bg(t.chrome)
      .text_size(13)
      .child(
        h_flex()
          .id("shep-row")
          .h(34)
          .px(8)
          .gap(9)
          .items_center()
          .rounded(8)
          .when(!rail, (el) => el.flex_1())
          .when(on, (el) => el.bg(t.selected))
          .when(!on, (el) => el.hover((s) => s.bg(t.hover)))
          .cursor_pointer()
          .tooltip(on ? "Shep, the orchestrator" : `Back to Shep (${KEY})`)
          .on_click(() => {
            if (view) this.show("shep");
          })
          .child(
            on || rail
              ? h_flex()
                  .size(18)
                  .flex_none()
                  .rounded(5)
                  .bg(on ? t.solid : t.raised)
                  .items_center()
                  .justify_center()
                  .text_size(10.5)
                  .font_bold()
                  .text_color(on ? t.solid_foreground : t.foreground)
                  .child("S")
              : svg("mods/workspace-chrome/chevron-left.svg").size(14).mx(2).flex_none().text_color(t.muted),
          )
          .when(!rail, (el) =>
            el
              .child(
                div()
                  .flex_1()
                  .truncate()
                  .text_color(t.foreground)
                  .font_medium()
                  .child(on ? "Shep" : "Back to Shep"),
              )
              .when(!on, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(KEY)))
              .child(div().size(7).mx(3).flex_none().rounded(4).bg(dot)),
          ),
      );
  }

  header(t) {
    const shep = shepTerminal();
    const word = shep ? "running" : S.found === false ? "bercail missing" : S.starting ? "starting" : "stopped";
    const color = shep ? t.ansi2 : S.found === false ? t.blocked : t.dim;
    return h_flex()
      .size_full()
      .px(12)
      .gap(8)
      .items_center()
      .bg(t.chrome)
      .text_size(12.5)
      .text_color(t.muted)
      .child(div().size(7).rounded(4).bg(color))
      .child(div().text_color(t.foreground).font_semibold().child("Shep"))
      .child(
        div()
          .flex_1()
          .truncate()
          .text_color(t.dim)
          .child(shep?.title || "the orchestrator for every desk"),
      )
      .child(div().text_color(color).child(word))
      .child(this.decisionsToggle(t))
      .child(div().text_size(11).text_color(t.dim).child(`${KEY} spaces`));
  }

  // In the header: the count of open decisions, and the person's click shows or hides
  // the panel. A new decision changes the count only.
  decisionsToggle(t) {
    const n = D.view?.cards?.length ?? 0;
    const open = decisionsShown();
    return (
      div()
        .id("shep-decisions-toggle")
        .flex_none()
        .px(8)
        .py(2)
        .rounded(5)
        .cursor_pointer()
        .text_color(n ? t.foreground : t.dim)
        .when(open, (el) => el.bg(t.selected))
        .when(!open, (el) => el.hover((s) => s.bg(t.hover)))
        .tooltip(open ? "Hide decisions" : "Show what Shep asks you")
        // The header drags the window; a press on the toggle doesn't.
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
        .on_click(() => {
          if (!find(layout(), PANEL_ID)) return;
          run(open ? "layout.hide" : "layout.show", { id: PANEL_ID });
          if (!open) loadDecisions();
        })
        .child(n ? `Decisions ${n}` : "Decisions")
    );
  }

  // The Decisions panel. Read-only: the person answers in Shep; Discuss takes them there.
  decisions(t) {
    const cards = D.view?.cards ?? [];
    const checked = D.view?.at ? `checked ${clock(D.view.at)}` : D.loading ? "checking…" : "";
    const list = v_flex().id("decision-list").flex_1().min_h(0).px(10).pb(10).gap(8).overflow_y_scrollbar();
    const say = (text, color = t.dim) => div().px(12).py(6).text_color(color).child(text);
    return v_flex()
      .size_full()
      .bg(t.background)
      .border_t(1)
      .border_color(t.border)
      .text_size(12.5)
      .text_color(t.muted)
      .child(
        h_flex()
          .h(32)
          .flex_none()
          .px(12)
          .gap(8)
          .items_center()
          .child(div().text_color(t.foreground).font_semibold().child("Decisions"))
          .child(
            div()
              .flex_1()
              .truncate()
              .text_color(t.dim)
              .child(cards.length ? `${cards.length} waiting on you` : ""),
          )
          .child(div().text_size(11).text_color(t.dim).child(checked)),
      )
      .when(Boolean(D.error), (el) => el.child(say(`Can't read Shep's questions: ${D.error}`, t.blocked)))
      .when(Boolean(D.note), (el) => el.child(say(D.note, t.blocked)))
      .when(!cards.length && !D.error, (el) => el.child(say(D.view ? "Nothing waits on you." : "Loading…")))
      .child(list.children(cards.map((c) => this.card(t, c))));
  }

  card(t, c) {
    const w = cardWords(c);
    const color = w.word === "open" ? t.dim : w.word === "stale" ? t.blocked : t.unknown;
    return v_flex()
      .id(`decision-${c.token}`)
      .flex_none()
      .p(10)
      .gap(6)
      .rounded(8)
      .border(1)
      .border_color(t.border)
      .bg(t.chrome)
      .child(
        h_flex()
          .gap(8)
          .child(div().flex_1().truncate().font_semibold().text_color(t.foreground).child(w.title))
          .child(div().flex_none().text_size(11).text_color(color).child(w.word)),
      )
      .child(div().text_color(t.foreground).child(c.prompt))
      .when(c.options?.length > 0, (el) =>
        el.child(
          div()
            .text_color(t.dim)
            .child(`Choices: ${c.options.join(" · ")}. Answer in Shep.`),
        ),
      )
      .when(Boolean(w.why), (el) => el.child(div().text_color(color).child(w.why)))
      .child(
        h_flex()
          .gap(8)
          .items_center()
          .child(div().flex_1().text_size(11).text_color(t.dim).child(w.asked))
          .child(
            div()
              .id(`decision-discuss-${c.token}`)
              .px(10)
              .py(3)
              .rounded(5)
              .bg(t.raised)
              .text_color(t.foreground)
              .cursor_pointer()
              .hover((s) => s.bg(t.hover))
              .tooltip("Talk it over with Shep: its next turn is about this")
              .on_click((_e, cx) => this.discuss(c, cx))
              .child("Discuss"),
          ),
      );
  }

  // The person's click: select the question's topic, then put the keyboard in Shep's
  // terminal (the panel is in the Shep view, so the view stays).
  discuss(c, cx) {
    cx.spawn(async (cx) => {
      let r;
      try {
        r = await exec("bash", ["-lc", THREAD, "bercail-shep", c.target.topic], { on: S.backend });
      } catch (e) {
        r = { code: 1, stderr: String(e?.message ?? e) };
      }
      D.note = r.code === 0 ? null : `Shep could not open that question: ${r.stderr.trim() || `exit ${r.code}`}`;
      const shep = shepTerminal();
      if (shep) run("pane.focus", { terminal: shep.address });
      cx.notify();
    });
  }

  empty(t) {
    const missing = S.found === false;
    const busy = S.starting || S.found === null;
    const act = (cx, f) =>
      cx.spawn(async (cx) => {
        await f();
        cx.notify();
      });
    const button = (id, label, f) =>
      div()
        .id(id)
        .px(14)
        .py(6)
        .rounded(6)
        .bg(t.solid)
        .text_color(t.solid_foreground)
        .hover((s) => s.opacity(0.85))
        .on_click((_e, cx) => act(cx, f))
        .child(label);
    const body = v_flex()
      .size_full()
      .items_center()
      .justify_center()
      .gap(10)
      .px(24)
      .bg(t.background)
      .text_color(t.muted)
      .text_size(13);
    if (missing) {
      return body
        .child(
          div()
            .text_color(t.foreground)
            .font_semibold()
            .child(S.backend ? `bercail is not installed on ${S.backend}` : "bercail is not installed"),
        )
        .child(
          div()
            .max_w(460)
            .text_center()
            .child("Shep starts with bercail shep run. Install bercail (bercail.dev), then check again."),
        )
        .child(button("shep-check", "Check again", checkBercail))
        .child(div().text_color(t.dim).text_size(12).child("Your spaces work without it: pick one on the right."))
        .when(Boolean(S.checkError), (el) =>
          el.child(div().max_w(460).text_center().text_color(t.blocked).text_size(12).child(S.checkError)),
        );
    }
    if (busy) return body.child("Starting Shep…");
    return body
      .child(div().text_color(t.foreground).font_semibold().child("Shep is not running"))
      .child(button("shep-start", "Start Shep", startShep))
      .child(div().text_color(t.dim).text_size(12).child("Runs Shep on Pi, in its own session."))
      .when(Boolean(S.error), (el) =>
        el.child(div().max_w(460).text_center().text_color(t.blocked).text_size(12).child(S.error)),
      );
  }

  // The bar of an agent opened in a dialog. Its terminal is the one in its pane or
  // desk: typing here types there. Closing puts the keyboard back where it was.
  modal(t) {
    const { terminal, overlay } = props() ?? {};
    const k = terminals().find((x) => x.address === terminal);
    const a = agents().find((x) => x.address === terminal);
    const status = a?.status ?? (k?.status === "error" ? "blocked" : k?.status) ?? null;
    const color = t[status] ?? t.dim;
    const spaceId = a?.space ?? qualify(k?.labels?.["bercail.space"], machineOf(k?.address)) ?? null;
    const space = spaces().find((s) => s.id === spaceId);
    const desk = k?.labels?.["bercail.role"] === "agent";
    const pic = icon(k?.program ?? a?.program, 14, t.foreground);
    const button = (id, label, onClick) =>
      div()
        .id(id)
        .px(8)
        .py(2)
        .rounded(5)
        .text_color(t.muted)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click(onClick)
        .child(label);
    return h_flex()
      .size_full()
      .px(12)
      .gap(8)
      .items_center()
      .bg(t.chrome)
      .border_b(1)
      .border_color(t.border)
      .text_size(12.5)
      .text_color(t.muted)
      .child(div().size(7).flex_none().rounded(4).bg(color))
      .when(Boolean(pic), (el) => el.child(pic))
      .child(
        div()
          .flex_none()
          .font_semibold()
          .text_color(t.foreground)
          .child(desk ? "Desk" : k?.name || a?.program?.name || k?.program?.name || terminal || ""),
      )
      .when(Boolean(space), (el) =>
        el.child(div().flex_none().max_w(220).truncate().text_color(t.dim).child(space.name)),
      )
      .child(
        div()
          .flex_1()
          .truncate()
          .text_color(t.dim)
          .child(a?.title ?? k?.title ?? ""),
      )
      .when(Boolean(status), (el) => el.child(div().flex_none().text_color(color).child(status)))
      .when(Boolean(space), (el) =>
        el.child(
          button("modal-space", "Show in space", () => {
            this.left = true;
            closeOverlay(overlay);
            run("space.select", { id: space.id });
            if (viewOf(layout())) setView("space");
            if (!desk) run("agent.focus", { terminal });
          }),
        ),
      )
      .child(button("modal-close", "✕", () => closeOverlay(overlay)));
  }

  // The dialog closed (✕, a click beside it, its terminal ended): the keyboard goes
  // back where it was, unless "Show in space" took it elsewhere.
  async close() {
    if (this.role !== "modal" || this.left) return;
    const back = props()?.back;
    if (back?.pane && panes().some((p) => p.pane === back.pane)) run("pane.focus", { pane: back.pane });
    else if (back?.terminal && terminals().some((x) => x.address === back.terminal && x.state === "live")) {
      run("pane.focus", { terminal: back.terminal });
    }
  }
}
