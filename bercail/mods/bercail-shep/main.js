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
// stays quit until "Start Shep". The terminal runs `bercail shep run`, which picks
// the runtime ([shep] backend: Pi, or an OpenClaw agent), asks on the first start,
// and labels the terminal with what it runs (bercail.shep_backend, .shep_session).
//
// props.role:
// - "nav" (default): the navigator's Shep row. Always shown, so it runs the logic: the
//   launch view, Shep's block in `shep-stack`, where the keyboard is, key commands.
// - "header": the bar above Shep's terminal.
// - "empty": the placeholder in `shep-stack` while Shep isn't running.
// - "modal": the bar of an agent's terminal opened over either view (bercail-agents
//   opens it); props.terminal is the agent, props.back where the keyboard was.
import { View, div, image, svg } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import {
  agents, closeOverlay, exec, focused, home, layout, nextCommand, notify, panes, props,
  readTextFile, run, spaces, terminals, theme,
} from "herdr";

const NAME = "bercail-shep";
const ROLE = "shep";
// Asked of and run in herdr-core's environment (hc exec, hc run), which may lack the
// login shell's PATH (mise, ~/.local/bin). `bercail shep run` keeps a failed
// runtime's message on screen until Enter; quitting normally closes the terminal.
const BERCAIL_PATH = 'command -v bercail >/dev/null || PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"';
// "--setup" comes in as $1, never spliced into the script.
const SHEP_RUN = `${BERCAIL_PATH}; exec bercail shep run "$@"`;
const KEY = "Ctrl+Shift+H";
const CONFIG = "/.config/bercail/config.toml";

// `[shep]` from config.toml text: { backend, session }, "" when unset. bercail
// reads the same keys; this only words the Shep view.
export function configShep(text) {
  const out = { backend: "", session: "" };
  let section = "";
  for (const raw of text.split("\n")) {
    const line = raw.replace(/#.*$/, "").trim();
    const sec = line.match(/^\[(.+)\]$/);
    if (sec) { section = sec[1].trim(); continue; }
    const kv = line.match(/^(backend|session)\s*=\s*(.+)$/);
    if (section === "shep" && kv && !out[kv[1]]) out[kv[1]] = kv[2].trim().replace(/^"(.*)"$/, "$1");
  }
  if (!out.backend && out.session) out.backend = "openclaw";
  return out;
}

// What the Shep view says a start will run.
export function plannedRun({ backend, session }) {
  if (backend === "pi") return "Runs Shep on Pi, in its own session.";
  if (backend === "openclaw") return `Runs openclaw tui --session ${session || "<your default agent>:main"}.`;
  return "The first start asks where Shep runs: Pi (recommended) or OpenClaw.";
}

async function readShep() {
  try { return configShep(await readTextFile(home() + CONFIG)); } catch { return configShep(""); }
}

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

export function shepTerminal(all = terminals()) {
  return all.find((t) => t.state === "live" && t.labels?.["bercail.role"] === ROLE) ?? null;
}

function setView(view) {
  run("layout.hide", { id: view === "shep" ? "work" : "shep" });
  run("layout.show", { id: view === "shep" ? "shep" : "work" });
}

// The view written into a tree, for a layout.set made before a setView has shown.
export function withView(tree, view) {
  const shep = find(tree, "shep"), work = find(tree, "work");
  if (shep && work) { shep.hidden = view !== "shep"; work.hidden = view === "shep"; }
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

// Shared by every copy: whether bercail is installed, the [shep] config, and a
// start in flight.
const S = { found: null, check: null, starting: false, error: null, shep: configShep("") };

function checkBercail() {
  S.check ??= Promise.all([exec("hc", ["exec", "bash", "-lc", `${BERCAIL_PATH}; command -v bercail`]), readShep()])
    .then(([r, shep]) => { S.found = r.code === 0; S.shep = shep; })
    .catch(() => { S.found = false; })
    .finally(() => { S.check = null; });
  return S.check;
}

// One Shep: none while one is live or starting. hc names are unique among live
// terminals, so a start that races one the list doesn't show yet is refused: fine.
// `setup`: ask where Shep runs before starting it.
async function startShep(setup = false) {
  if (S.starting || shepTerminal()) return;
  S.starting = true;
  S.error = null;
  try {
    await checkBercail();
    if (!S.found) return;
    const r = await exec("hc", ["run", "--bg", "--json", "--no-parent", "--no-notify", "--rm", "--name", NAME,
      "--cwd", home(), "--label", `bercail.role=${ROLE}`,
      "bash", "-lc", SHEP_RUN, "bash", ...(setup ? ["--setup"] : [])]);
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
    cx.spawn(async (cx) => { await checkBercail(); cx.notify(); });
    if (this.role !== "nav") return;
    this.added = new Set(); // Shep block ids this copy added
    this.back = {};         // space id -> { pane } or { terminal }: where the keyboard was
    this.pending = null;    // { view, at }: a view this copy set that layout() doesn't show yet
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
      case "toggle": if (view) this.show(view === "shep" ? "space" : "shep"); break;
      case "show": if (view) this.show("shep"); break;
      case "space": if (view) this.show("space"); break;
      case "start": await startShep(); break;
      case "setup": await startShep(true); break;
      // Ctrl+Space: Herdr's own Go to… search, over the space view so a pick shows.
      case "goto": this.inSpace(view, ["mod.open", { name: "picker" }]); break;
      // A bercail-desk key pressed in the Shep view (its `keys` copy sends it here).
      case "desk": if (arg) this.inSpace(view, [`bercail-desk.${arg}`]); break;
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
      const desk = f.terminal && terminals().find((t) => t.address === f.terminal
        && t.labels?.["bercail.role"] === "agent" && t.labels?.["bercail.space"] === f.space);
      if (f.pane) this.back[f.space] = { pane: f.pane };
      else if (desk) this.back[f.space] = { terminal: f.terminal };
    }
    const ready = Boolean(shep) && !plan.set
      && Boolean(find(tree, "shep-stack")?.children?.some((c) => c.id === `shep-${shep.address}`));
    const space = spaces().find((s) => s.id === f?.space);
    const to = focusPlan(view, was, f, shep, ready, this.back[f?.space], ps, space);
    if (to) run("pane.focus", to);
    if (then) run(...then);
    return view;
  }

  render(cx) {
    const t = theme();
    switch (this.role) {
      case "header": return this.header(t);
      case "empty": return this.empty(t);
      case "modal": return this.modal(t);
    }
    const view = this.sync();
    const shep = shepTerminal();
    const on = view === "shep";
    const dot = shep ? t.ansi2 : S.found === false ? t.blocked : t.dim;
    // The sidebar's rail (narrower than 160px): the mark alone.
    const rail = (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;
    return h_flex().size_full().px(rail ? 0 : 8).items_center().justify_center().bg(t.chrome).text_size(13)
      .child(h_flex().id("shep-row").h(34).px(8).gap(9).items_center().rounded(8)
        .when(!rail, (el) => el.flex_1())
        .when(on, (el) => el.bg(t.selected))
        .when(!on, (el) => el.hover((s) => s.bg(t.hover)))
        .cursor_pointer()
        .tooltip(on ? "Shep, the orchestrator" : `Back to Shep (${KEY})`)
        .on_click(() => { if (view) this.show("shep"); })
        .child(on || rail
          ? h_flex().size(18).flex_none().rounded(5).bg(on ? t.solid : t.raised).items_center().justify_center()
            .text_size(10.5).font_bold().text_color(on ? t.solid_foreground : t.foreground).child("S")
          : svg("mods/workspace-chrome/chevron-left.svg").size(14).mx(2).flex_none().text_color(t.muted))
        .when(!rail, (el) => el
          .child(div().flex_1().truncate().text_color(t.foreground).font_medium().child(on ? "Shep" : "Back to Shep"))
          .when(!on, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(KEY)))
          .child(div().size(7).mx(3).flex_none().rounded(4).bg(dot))));
  }

  header(t) {
    const shep = shepTerminal();
    const word = shep ? "running" : S.found === false ? "bercail missing" : S.starting ? "starting" : "stopped";
    const color = shep ? t.ansi2 : S.found === false ? t.blocked : t.dim;
    const backend = shep?.labels?.["bercail.shep_backend"];
    const on = shep?.labels?.["bercail.shep_session"] || (backend === "pi" ? "Pi" : backend === "openclaw" ? "OpenClaw" : "");
    return h_flex().size_full().px(12).gap(8).items_center().bg(t.chrome).text_size(12.5).text_color(t.muted)
      .child(div().size(7).rounded(4).bg(color))
      .child(div().text_color(t.foreground).font_semibold().child("Shep"))
      .child(div().flex_1().truncate().text_color(t.dim).child(shep?.title || "the orchestrator for every desk"))
      .when(Boolean(on), (el) => el.child(div().flex_none().text_color(t.dim).child(on)))
      .child(div().text_color(color).child(word))
      .child(div().text_size(11).text_color(t.dim).child(`${KEY} spaces`));
  }

  empty(t) {
    const missing = S.found === false;
    const busy = S.starting || S.found === null;
    const act = (cx, f) => cx.spawn(async (cx) => { await f(); cx.notify(); });
    const button = (id, label, f, solid = true) => div().id(id).px(14).py(6).rounded(6)
      .when(solid, (el) => el.bg(t.solid).text_color(t.solid_foreground))
      .when(!solid, (el) => el.border(1).border_color(t.border).text_color(t.foreground))
      .hover((s) => s.opacity(0.85)).on_click((_e, cx) => act(cx, f)).child(label);
    const body = v_flex().size_full().items_center().justify_center().gap(10).px(24).bg(t.background)
      .text_color(t.muted).text_size(13);
    if (missing) {
      return body
        .child(div().text_color(t.foreground).font_semibold().child("bercail is not installed"))
        .child(div().max_w(460).text_center().child("Shep starts with bercail shep run. Install bercail (bercail.dev), then check again."))
        .child(button("shep-check", "Check again", checkBercail))
        .child(div().text_color(t.dim).text_size(12).child("Your spaces work without it: pick one on the right."));
    }
    if (busy) return body.child("Starting Shep…");
    return body
      .child(div().text_color(t.foreground).font_semibold().child("Shep is not running"))
      .child(h_flex().gap(8)
        .child(button("shep-start", "Start Shep", () => startShep()))
        .child(button("shep-setup", "Change runtime", () => startShep(true), false)))
      .child(div().text_color(t.dim).text_size(12).child(plannedRun(S.shep)))
      .when(Boolean(S.error), (el) => el.child(div().max_w(460).text_center().text_color(t.blocked).text_size(12).child(S.error)));
  }

  // The bar of an agent opened in a dialog. Its terminal is the one in its pane or
  // desk: typing here types there. Closing puts the keyboard back where it was.
  modal(t) {
    const { terminal, overlay } = props() ?? {};
    const k = terminals().find((x) => x.address === terminal);
    const a = agents().find((x) => x.address === terminal);
    const status = a?.status ?? (k?.status === "error" ? "blocked" : k?.status) ?? null;
    const color = t[status] ?? t.dim;
    const spaceId = a?.space ?? k?.labels?.["bercail.space"] ?? null;
    const space = spaces().find((s) => s.id === spaceId);
    const desk = k?.labels?.["bercail.role"] === "agent";
    const pic = icon(k?.program ?? a?.program, 14, t.foreground);
    const button = (id, label, onClick) => div().id(id).px(8).py(2).rounded(5).text_color(t.muted)
      .cursor_pointer().hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click(onClick).child(label);
    return h_flex().size_full().px(12).gap(8).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .text_size(12.5).text_color(t.muted)
      .child(div().size(7).flex_none().rounded(4).bg(color))
      .when(Boolean(pic), (el) => el.child(pic))
      .child(div().flex_none().font_semibold().text_color(t.foreground)
        .child(desk ? "Desk" : (k?.name || a?.program?.name || k?.program?.name || terminal || "")))
      .when(Boolean(space), (el) => el.child(div().flex_none().max_w(220).truncate().text_color(t.dim).child(space.name)))
      .child(div().flex_1().truncate().text_color(t.dim).child(a?.title ?? k?.title ?? ""))
      .when(Boolean(status), (el) => el.child(div().flex_none().text_color(color).child(status)))
      .when(Boolean(space), (el) => el.child(button("modal-space", "Show in space", () => {
        this.left = true;
        closeOverlay(overlay);
        run("space.select", { id: space.id });
        if (viewOf(layout())) setView("space");
        if (!desk) run("agent.focus", { terminal });
      })))
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
