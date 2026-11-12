#!/usr/bin/env bats
# The bercail-shep mod (the Shep and space views) and bercail-spaces' click, against
# stubbed herdr and gpui modules and the shipped layout.

setup() {
  load test_helper
  isolate
  need node
  # Each stub reads the state the test sets on globalThis.herdr.
  cat >"$BATS_TEST_TMPDIR/herdr.mjs" <<'EOF'
const h = () => globalThis.herdr;
const find = (n, id) => n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean);
export const layout = () => structuredClone(h().layout);
export const run = (name, args) => {
  h().calls.push([name, args]);
  if (name === "layout.set") h().layout = structuredClone(args.layout);
  if (name === "layout.show" || name === "layout.hide") find(h().layout, args.id).hidden = name === "layout.hide";
  if (name === "layout.select") find(h().layout, args.stack).active = args.child;
};
export const spaces = () => h().spaces ?? [];
export const focused = () => h().focused;
export const terminals = () => h().terminals;
export const panes = () => h().panes ?? [];
export const agents = () => [];
export const machines = () => [];
export const notify = (n) => (h().notes ??= []).push(n);
export const theme = () => new Proxy({}, { get: (_t, k) => String(k) });
export const props = () => h().props ?? {};
export const shared = () => null;
export const setShared = () => {};
export const openOverlay = () => "o1";
export const closeOverlay = (id) => h().calls.push(["closeOverlay", id]);
export const exec = async (cmd, args) => { h().execs.push([cmd, ...args]); return h().exec(cmd, args); };
export const hc = async () => ({ code: 0, stdout: "", stderr: "" });
export const watchFolder = () => new Promise(() => {});
export const window = () => ({ platform: "linux", active: true });
export const home = () => "/home/me";
export const nextCommand = () => new Promise(() => {});
EOF
  cat >"$BATS_TEST_TMPDIR/gpui.mjs" <<'EOF'
// An element records its id and click handler; every other method chains.
export const els = [];
const el = () => {
  const e = {};
  els.push(e);
  const p = new Proxy(e, {
    get: (t, k) => k in t ? t[k] : (...a) => {
      if (k === "id") t.id = a[0];
      if (k === "on_click") t.click = a[0];
      if (k === "child" && typeof a[0] === "string") (t.text ??= []).push(a[0]);
      if (k === "on_mouse_down" || k === "on_mouse_up") t[`${k}:${a[0]}`] = a[1];
      if (k === "when" && a[0]) a[1](p);
      return p;
    },
  });
  return p;
};
export class View {}
export const div = el, image = el, svg = el, h_flex = el, v_flex = el;
EOF
  local mod
  for mod in bercail-shep bercail-spaces; do
    sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui.mjs"|' \
      -e 's|from "gpui-base"|from "./gpui.mjs"|' "$ROOT/bercail/mods/$mod/main.js" >"$BATS_TEST_TMPDIR/$mod.mjs"
  done
  cp "$ROOT/bercail/layouts/bercail.json" "$BATS_TEST_TMPDIR/layout.json"
  cp "$ROOT/bercail/keys.json" "$BATS_TEST_TMPDIR/keys.json"
  cat >"$BATS_TEST_TMPDIR/prelude.mjs" <<'EOF'
import { readFileSync } from "node:fs";
import Shep, { find, viewOf, stackPlan, focusPlan, withView } from "./bercail-shep.mjs";
import Spaces from "./bercail-spaces.mjs";
import { els } from "./gpui.mjs";

const shipped = JSON.parse(readFileSync(new URL("./layout.json", import.meta.url)));
const keys = JSON.parse(readFileSync(new URL("./keys.json", import.meta.url)))["layout:bercail"];
const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exit(1); };
const calls = (name) => globalThis.herdr.calls.filter(([n]) => n === name);
const tick = () => new Promise((r) => setImmediate(r));
const SHEP = (address, state = "live") => ({ address, state, labels: { "bercail.role": "shep" } });
const DESK = (address, space) => ({ address, state: "live", labels: { "bercail.role": "agent", "bercail.space": space } });
const SPACES = [{ id: "s1", tabs: [{ id: "tab1", active: true }] }, { id: "s2", tabs: [{ id: "tab2", active: true }] }];
const PANES = [{ pane: "p1", tab: "tab1", terminal: "t1" }, { pane: "p2", tab: "tab2", terminal: "t2" }];
globalThis.localStorage = { getItem: () => null, setItem: () => {} };

// hc exec finds bercail; hc run starts.
const okExec = () => ({ code: 0, stdout: "", stderr: "" });
function setup(state = {}) {
  globalThis.herdr = {
    layout: structuredClone(shipped), calls: [], execs: [], spaces: SPACES, panes: PANES,
    focused: { space: "s1", pane: "p1", terminal: "t1" }, terminals: [],
    exec: okExec, ...state,
  };
}
const cx = { spawn: (f) => f(cx), notify: () => {}, timer: { every: () => {} } };
function nav() {
  const v = new Shep();
  v.init({}, cx);
  return v;
}
const runs = () => globalThis.herdr.execs.filter((e) => e[1] === "run");
let v;
const shep = SHEP("t9");
const f = (o) => ({ space: "s1", pane: null, terminal: null, ...o });
const eq = (a, b, label) => { if (JSON.stringify(a) !== JSON.stringify(b)) fail(`${label}: ${JSON.stringify(a)}`); };
// Later copies: the first nav() of the app session already launched. A case that
// is that first copy deletes this.
globalThis.bercailShep = { launched: true };
EOF
}

# One case: the shared prelude, then the case on stdin.
mod_case() {
  cat "$BATS_TEST_TMPDIR/prelude.mjs" - >"$BATS_TEST_TMPDIR/test.mjs"
  node "$BATS_TEST_TMPDIR/test.mjs"
}

@test "the shipped layout opens on the Shep view, navigator on the right" {
  mod_case <<'EOF'
// The shipped layout opens on the Shep view: Shep's column shown, the work column hidden,
// the navigator (with its Shep row and bercail's spaces list) beside them.
setup();
if (viewOf(shipped) !== "shep") fail(`the shipped layout opens on ${viewOf(shipped)}`);
if (find(shipped, "shep-nav")?.content?.props?.role !== "nav") fail("no Shep row in the sidebar");
if (find(shipped, "spaces")?.content?.mod !== "bercail-spaces") fail("the sidebar must use bercail-spaces");
if (shipped.children.map((c) => c.id).join() !== "shep,sidebar,work") fail(`root order: ${shipped.children.map((c) => c.id)}`);
EOF
}

@test "launch shows the Shep view and starts Shep once, after the core lists terminals" {
  mod_case <<'EOF'
// Launch: once per app session the space view gives way to the Shep view, and Shep
// starts once the core lists terminals. A second copy (a mod reload) does neither.
delete globalThis.bercailShep;
setup({ terminals: [] });
globalThis.herdr.layout = withView(structuredClone(shipped), "space");
v = nav();
if (calls("layout.show").length) fail("the view changed before layout() was known");
v.sync();
if (viewOf(globalThis.herdr.layout) !== "shep") fail("launch must show the Shep view");
await tick();
if (runs().length) fail("Shep started before the core listed its terminals");
globalThis.herdr.terminals = [{ address: "t1", state: "live", labels: {} }];
v.sync();
await tick();
if (runs().length !== 1) fail(`expected one hc run, got ${JSON.stringify(globalThis.herdr.execs)}`);
const argv = runs()[0];
for (const a of ["--bg", "--no-parent", "--rm", "--name", "bercail-shep", "--label", "bercail.role=shep"]) {
  if (!argv.includes(a)) fail(`hc run lacks ${a}: ${argv}`);
}
if (/--token|--password|--url/.test(argv.join(" "))) fail(`Shep passes credentials: ${argv}`);
const script = argv[argv.indexOf("-lc") + 1];
if (!/exec bercail shep run$/.test(script) || argv.at(-1) !== script) fail(`Shep does not run bercail shep run: ${argv}`);
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
globalThis.herdr.execs = [];
v = nav();
v.sync();
v.sync();
await tick();
if (viewOf(globalThis.herdr.layout) !== "space" || runs().length) fail("a second copy must not switch the view or start Shep");
EOF
}

@test "one Shep: a live one is reused, a racing start is quiet, no bercail starts nothing" {
  mod_case <<'EOF'
// A live Shep is found by its label: no second start. A start that races one the list
// doesn't show yet (hc: name_taken) is no error. Missing bercail starts nothing.
for (const [label, state, wantRun, wantNote] of [
  ["live", { terminals: [SHEP("t9")] }, false, false],
  ["name_taken", { exec: (c, a) => a[0] === "run" ? { code: 1, stdout: "", stderr: '{"error":{"kind":"name_taken"}}' } : okExec(c, a) }, true, false],
  ["missing", { exec: (_c, a) => ({ code: a[0] === "exec" ? 1 : 0, stdout: "", stderr: "" }) }, false, false],
]) {
  delete globalThis.bercailShep;
  setup({ terminals: [{ address: "t1", state: "live", labels: {} }], ...state });
  v = nav();
  v.sync();
  await tick();
  if (Boolean(runs().length) !== wantRun) fail(`${label}: hc run ${JSON.stringify(globalThis.herdr.execs)}`);
  if (Boolean(globalThis.herdr.notes?.length) !== wantNote) fail(`${label}: notes ${JSON.stringify(globalThis.herdr.notes)}`);
}
EOF
}

@test "Start Shep runs bercail shep run (Pi), with no runtime choice" {
  mod_case <<'EOF'
// Stopped, the view offers Start Shep alone and says it runs on Pi; it reads no
// config and passes nothing to bercail shep run. `script` is the launch command,
// captured here because this case does not share the launch case's process.
delete globalThis.bercailShep;
setup({ terminals: [{ address: "t1", state: "live", labels: {} }] });
v = nav();
v.sync();
await tick();
const launched = runs()[0];
const script = launched[launched.indexOf("-lc") + 1];
if (!/exec bercail shep run$/.test(script)) fail(`launch script: ${script}`);
delete globalThis.bercailShep;
setup({ terminals: [{ address: "t1", state: "live", labels: {} }], props: { role: "empty" } });
const empty = new Shep();
empty.init({}, cx);
await tick();
els.length = 0;
empty.render(cx);
if (els.some((e) => e.id === "shep-setup") || !els.some((e) => e.text?.includes("Runs Shep on Pi, in its own session."))) {
  fail(`stopped view: ${JSON.stringify(els.filter((e) => e.id || e.text))}`);
}
els.find((e) => e.id === "shep-start").click(null, cx);
await tick();
if (runs().at(-1)?.at(-1) !== script) fail(`Start Shep ran ${JSON.stringify(runs())}`);
EOF
}

@test "Shep's block is added once, selected after, dropped when Shep ends" {
  mod_case <<'EOF'
// Shep's block: added once (already shown), selected after, dropped when Shep ends,
// never added again for the same terminal.
setup({ terminals: [SHEP("t9")] });
let added = new Set();
let tree = structuredClone(shipped);
let plan = stackPlan(tree, SHEP("t9"), added);
const stack = (t) => find(t, "shep-stack");
if (!plan.set || stack(plan.set).active !== "shep-t9" || find(plan.set, "shep-t9")?.content?.terminal !== "t9") fail(`add: ${JSON.stringify(plan)}`);
added.add(plan.added);
tree = plan.set;
if (Object.keys(stackPlan(structuredClone(tree), SHEP("t9"), added)).length) fail("a shown block must not change again");
stack(tree).active = "shep-empty";
if (stackPlan(structuredClone(tree), SHEP("t9"), added).select !== "shep-t9") fail("a hidden block must be selected");
plan = stackPlan(structuredClone(tree), null, added);
if (!plan.set || stack(plan.set).children.map((c) => c.id).join() !== "shep-empty" || stack(plan.set).active !== "shep-empty") fail(`drop: ${JSON.stringify(plan)}`);
const dropped = structuredClone(shipped);
if (Object.keys(stackPlan(dropped, SHEP("t9"), added)).length) fail("a block the app dropped must not be added again");
plan = stackPlan(structuredClone(shipped), SHEP("t10"), added);
if (find(plan.set, "shep-t10")?.content?.terminal !== "t10") fail("a new Shep gets its block");
EOF
}

@test "adding Shep's block keeps a view switch on its way" {
  mod_case <<'EOF'
// A layout.set while a view switch is on its way carries that view.
setup({ terminals: [SHEP("t9")] });
v = nav();
v.show("space");
globalThis.herdr.layout = withView(globalThis.herdr.layout, "shep"); // the switch hasn't landed
v.sync();
const [[, set]] = calls("layout.set");
if (viewOf(set.layout) !== "space") fail("layout.set undid a view switch on its way");
EOF
}

@test "the keyboard follows the view and comes back where it was" {
  mod_case <<'EOF'
// The keyboard: into Shep in the Shep view (once its block is there); back where it
// was in the space when the space view comes back, else the shown tab's first pane.
setup();
eq(focusPlan("shep", "space", f({ pane: "p1" }), shep, true, null, PANES, SPACES[0]), { terminal: "t9" }, "into Shep");
eq(focusPlan("shep", "space", f({ pane: "p1" }), shep, false, null, PANES, SPACES[0]), null, "not before its block");
eq(focusPlan("shep", "shep", f({ terminal: "t9" }), shep, true, null, PANES, SPACES[0]), null, "already on Shep");
eq(focusPlan("space", "shep", f({ terminal: "t9" }), shep, true, { terminal: "t5" }, PANES, SPACES[0]), { terminal: "t5" }, "back to the desk");
eq(focusPlan("space", "shep", f({ pane: "p1" }), shep, true, { terminal: "t5" }, PANES, SPACES[0]), { terminal: "t5" }, "over the app's own pick");
eq(focusPlan("space", "shep", f({ terminal: "t9" }), shep, true, { pane: "gone" }, PANES, SPACES[0]), { pane: "p1" }, "a closed pane");
eq(focusPlan("space", "shep", f({ pane: "p1" }), shep, true, { pane: "p1" }, PANES, SPACES[0]), null, "already there");
eq(focusPlan("space", "space", f({ pane: "p1" }), shep, true, { terminal: "t5" }, PANES, SPACES[0]), null, "the person moved it");
EOF
}

@test "a round trip through Shep puts the keyboard back on the desk" {
  mod_case <<'EOF'
// The nav copy remembers where the keyboard was in each space, desks too, while the
// space view stays.
setup({ terminals: [shep, DESK("t5", "s1")], focused: f({ terminal: "t5" }) });
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
v = nav();
v.sync();
v.sync();
globalThis.herdr.layout = withView(globalThis.herdr.layout, "shep");
globalThis.herdr.focused = f({ pane: "p1" }); // the app moved it
v.sync();
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
globalThis.herdr.calls = [];
v.sync();
eq(calls("pane.focus").at(-1)?.[1], { terminal: "t5" }, "desk restored after a round trip");
EOF
}

@test "Ctrl+Shift+H toggles the views; the Shep row comes back to Shep" {
  mod_case <<'EOF'
// Keys: toggle flips the views; the Shep row's click shows Shep.
setup({ terminals: [shep] });
v = nav();
await v.command("toggle");
if (viewOf(globalThis.herdr.layout) !== "space") fail("toggle from Shep");
await v.command("toggle");
if (viewOf(globalThis.herdr.layout) !== "shep") fail("toggle back");
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
els.length = 0;
v.render(cx);
els.find((e) => e.id === "shep-row").click();
if (viewOf(globalThis.herdr.layout) !== "shep") fail("the Shep row must show Shep");
if (!els.some((e) => e.text?.includes("Ctrl+Shift+H"))) fail("the Back to Shep row must hint Ctrl+Shift+H");
if (keys["ctrl-shift-h"] !== "bercail-shep.toggle") fail("Ctrl+Shift+H must toggle the views");
EOF
}

@test "every bercail key reaches one shown mod copy in the Shep view and in the space view" {
  mod_case <<'EOF'
// Every mod key reaches exactly one shown copy that takes commands, in both views: a
// hidden copy gets no keys (the desk's header is in the hidden work column in the Shep
// view; its `keys` copy in the Shep column takes them there).
const shown = (n, out = []) => {
  if (!n || n.hidden) return out;
  if (n.content?.mod) out.push(n.content);
  for (const c of n.children ?? []) if (n.type !== "stack" || c.id === n.active) shown(c, out);
  return out;
};
const TAKES = { "bercail-desk": ["header", "keys"], "bercail-shep": ["nav"], "bercail-review": [] };
for (const view of ["shep", "space"]) {
  const copies = shown(withView(structuredClone(shipped), view));
  for (const [key, action] of Object.entries(keys)) {
    const mod = action.split(".")[0];
    if (!(mod in TAKES)) continue;
    const n = copies.filter((c) => c.mod === mod && TAKES[mod].includes(c.props?.role ?? (mod === "bercail-shep" ? "nav" : "header"))).length;
    if (n !== 1) fail(`${view} view: ${key} (${action}) reaches ${n} copies of ${mod}`);
  }
}
// Ctrl(+Shift)+Up/Down stay the program's: Pi jumps between prompts with them.
for (const k of ["ctrl-up", "ctrl-down", "ctrl-shift-up", "ctrl-shift-down"]) if (keys[k]) fail(`${k} is bound: ${keys[k]}`);
EOF
}

@test "a desk key in the Shep view shows the space view, then reaches the desk after the keyboard" {
  mod_case <<'EOF'
// A desk key from the Shep view shows the space view, then replays to the desk once the
// keyboard is back in the space, so a key that moves it (an agent) has the last word.
setup({ terminals: [shep], focused: f({ terminal: "t9" }) });
globalThis.herdr.layout = withView(globalThis.herdr.layout, "shep");
v = nav();
v.sync();
v.view = "shep";
v.back.s1 = { pane: "p1" };
globalThis.herdr.calls = [];
await v.command("desk:agent-next");
if (viewOf(globalThis.herdr.layout) !== "space") fail("a desk key must show the space view");
if (calls("bercail-desk.agent-next").length) fail("the desk key went out before the space view showed");
v.sync();
const order = globalThis.herdr.calls.map(([n]) => n).filter((n) => n === "pane.focus" || n.startsWith("bercail-desk."));
eq(order, ["pane.focus", "bercail-desk.agent-next"], "keyboard back, then the key");
v.sync();
if (calls("bercail-desk.agent-next").length !== 1) fail("the key was replayed twice");
// In the space view the key goes straight on; a switch that never showed drops it.
globalThis.herdr.calls = [];
await v.command("desk:space-prev");
eq(globalThis.herdr.calls.map(([n]) => n), ["bercail-desk.space-prev"], "space view: straight to the desk");
globalThis.herdr.layout = withView(globalThis.herdr.layout, "shep");
v.sync();
await v.command("desk:review");
globalThis.herdr.layout = withView(globalThis.herdr.layout, "shep"); // the switch never landed
v.pending.at -= 3000;
v.sync();
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
v.sync();
if (calls("bercail-desk.review").length) fail("a key whose view switch never showed must not replay later");
EOF
}

@test "Ctrl+Space opens Herdr's Go to… search; from Shep, over the space view" {
  mod_case <<'EOF'
// Ctrl+Space opens Herdr's own Go to… search (the picker mod), never Shep. In the space
// view at once; from the Shep view over the space view, after the keyboard is back,
// so the space picked there is the one that shows.
if (keys["ctrl-space"] !== "bercail-shep.goto") fail(`Ctrl+Space is ${keys["ctrl-space"]}`);
setup({ terminals: [shep], focused: f({ pane: "p1" }) });
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
v = nav();
v.sync();
globalThis.herdr.calls = [];
await v.command("goto");
eq(globalThis.herdr.calls, [["mod.open", { name: "picker" }]], "space view: the picker at once");
globalThis.herdr.layout = withView(globalThis.herdr.layout, "shep");
globalThis.herdr.focused = f({ terminal: "t9" });
v.sync();
globalThis.herdr.calls = [];
await v.command("goto");
if (viewOf(globalThis.herdr.layout) !== "space") fail("Ctrl+Space from Shep must leave the Shep view");
if (calls("mod.open").length) fail("the picker opened before the space view showed");
v.sync();
eq(globalThis.herdr.calls.map(([n]) => n).filter((n) => n === "pane.focus" || n === "mod.open"), ["pane.focus", "mod.open"], "keyboard back, then the picker");
eq(calls("mod.open")[0][1], { name: "picker" }, "the native picker");
EOF
}

@test "the dialog's bar closes back to where the keyboard was, or shows the space" {
  mod_case <<'EOF'
// The agent dialog's bar: close puts the keyboard back; "Show in space" goes there.
setup({ terminals: [{ address: "t6", state: "live", labels: {} }], spaces: [{ id: "s2", name: "two", tabs: [] }],
  props: { role: "modal", terminal: "t6", overlay: "o1", back: { pane: "p1", terminal: "t1" } } });
v = nav();
await v.close();
eq(calls("pane.focus").at(-1)?.[1], { pane: "p1" }, "close restores");
globalThis.herdr.calls = [];
globalThis.herdr.terminals[0].labels = { "bercail.space": "s2" };
els.length = 0;
v.render(cx);
els.find((e) => e.id === "modal-space").click();
await v.close();
const names = globalThis.herdr.calls.map(([n]) => n).join();
if (names !== "closeOverlay,space.select,layout.hide,layout.show,agent.focus") fail(`Show in space ran ${names}`);
if (viewOf(globalThis.herdr.layout) !== "space") fail("Show in space must show the space view");
EOF
}

@test "clicking a space shows it in the space view; other layouts only select" {
  mod_case <<'EOF'
// bercail-spaces: a click on a space selects it and shows the space view; while Shep
// shows, no space reads as selected.
setup({ spaces: [{ id: "s1", name: "one", tabs: [], active: true, machine: null }] });
const sp = new Spaces();
sp.init({}, cx);
els.length = 0;
sp.render(cx);
const rowEl = els.find((e) => e.id === "space-s1");
rowEl["on_mouse_down:left"]();
rowEl["on_mouse_up:left"](null, cx);
if (calls("space.select")[0]?.[1]?.id !== "s1" || viewOf(globalThis.herdr.layout) !== "space") fail(`space click: ${JSON.stringify(globalThis.herdr.calls)}`);
// Herdr's own layouts have no Shep view: the click only selects.
setup({ layout: { id: "root", children: [{ id: "sidebar", size: { px: 268 } }] } });
rowEl["on_mouse_down:left"]();
rowEl["on_mouse_up:left"](null, cx);
if (calls("layout.hide").length || calls("layout.show").length) fail("a layout without the views got layout commands");
EOF
}
