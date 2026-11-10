#!/usr/bin/env bash
# shellcheck shell=bash
# The bercail-shep mod (the Shep and space views) and bercail-spaces' click, against
# stubbed herdr and gpui modules and the shipped layout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found\n'
  exit 0
fi

# Each stub reads the state the test sets on globalThis.herdr.
cat >"$TMP_DIR/herdr.mjs" <<'EOF'
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
export const readTextFile = async (path) => {
  h().reads = [...(h().reads ?? []), path];
  if (h().config === undefined) throw new Error("ENOENT");
  return h().config;
};
export const nextCommand = () => new Promise(() => {});
EOF
cat >"$TMP_DIR/gpui.mjs" <<'EOF'
// An element records its id and click handler; every other method chains.
export const els = [];
const el = () => {
  const e = {};
  els.push(e);
  const p = new Proxy(e, {
    get: (t, k) => k in t ? t[k] : (...a) => {
      if (k === "id") t.id = a[0];
      if (k === "on_click") t.click = a[0];
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
for mod in bercail-shep bercail-spaces; do
  sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui.mjs"|' \
    -e 's|from "gpui-base"|from "./gpui.mjs"|' "$ROOT/bercail/mods/$mod/main.js" >"$TMP_DIR/$mod.mjs"
done
cp "$ROOT/bercail/layouts/bercail.json" "$TMP_DIR/layout.json"

cat >"$TMP_DIR/test.mjs" <<'EOF'
import { readFileSync } from "node:fs";
import Shep, { find, viewOf, stackPlan, focusPlan, withView, configSession } from "./bercail-shep.mjs";
import Spaces from "./bercail-spaces.mjs";
import { els } from "./gpui.mjs";

const shipped = JSON.parse(readFileSync(new URL("./layout.json", import.meta.url)));
const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exit(1); };
const calls = (name) => globalThis.herdr.calls.filter(([n]) => n === name);
const tick = () => new Promise((r) => setImmediate(r));
const SHEP = (address, state = "live") => ({ address, state, labels: { "bercail.role": "shep" } });
const DESK = (address, space) => ({ address, state: "live", labels: { "bercail.role": "agent", "bercail.space": space } });
const SPACES = [{ id: "s1", tabs: [{ id: "tab1", active: true }] }, { id: "s2", tabs: [{ id: "tab2", active: true }] }];
const PANES = [{ pane: "p1", tab: "tab1", terminal: "t1" }, { pane: "p2", tab: "tab2", terminal: "t2" }];
globalThis.localStorage = { getItem: () => null, setItem: () => {} };

// OpenClaw's agents: `sheep` is the default.
const AGENTS = JSON.stringify([{ id: "other", isDefault: false }, { id: "sheep", isDefault: true }]);
const ocExec = (_c, a) => ({ code: 0, stdout: /openclaw agents list --json/.test(a.at(-1)) ? AGENTS : "", stderr: "" });
function setup(state = {}) {
  globalThis.herdr = {
    layout: structuredClone(shipped), calls: [], execs: [], spaces: SPACES, panes: PANES,
    focused: { space: "s1", pane: "p1", terminal: "t1" }, terminals: [],
    exec: ocExec, ...state,
  };
}
const cx = { spawn: (f) => f(cx), notify: () => {}, timer: { every: () => {} } };
function nav() {
  const v = new Shep();
  v.init({}, cx);
  return v;
}

// The shipped layout opens on the Shep view: Shep's column shown, the work column hidden,
// the navigator (with its Shep row and bercail's spaces list) beside them.
setup();
if (viewOf(shipped) !== "shep") fail(`the shipped layout opens on ${viewOf(shipped)}`);
if (find(shipped, "shep-nav")?.content?.props?.role !== "nav") fail("no Shep row in the sidebar");
if (find(shipped, "spaces")?.content?.mod !== "bercail-spaces") fail("the sidebar must use bercail-spaces");
if (shipped.children.map((c) => c.id).join() !== "shep,sidebar,work") fail(`root order: ${shipped.children.map((c) => c.id)}`);
console.log("PASS: the shipped layout opens on the Shep view, navigator on the right");

// Launch: once per app session the space view gives way to the Shep view, and Shep
// starts once the core lists terminals. A second copy (a mod reload) does neither.
delete globalThis.bercailShep;
setup({ terminals: [] });
globalThis.herdr.layout = withView(structuredClone(shipped), "space");
let v = nav();
if (calls("layout.show").length) fail("the view changed before layout() was known");
v.sync();
if (viewOf(globalThis.herdr.layout) !== "shep") fail("launch must show the Shep view");
const runs = () => globalThis.herdr.execs.filter((e) => e[1] === "run");
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
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
globalThis.herdr.execs = [];
v = nav();
v.sync();
v.sync();
await tick();
if (viewOf(globalThis.herdr.layout) !== "space" || runs().length) fail("a second copy must not switch the view or start Shep");
console.log("PASS: launch shows the Shep view and starts Shep once, after the core lists terminals");

// A live Shep is found by its label: no second start. A start that races one the list
// doesn't show yet (hc: name_taken) is no error. Missing OpenClaw starts nothing.
for (const [label, state, wantRun, wantNote] of [
  ["live", { terminals: [SHEP("t9")] }, false, false],
  ["name_taken", { exec: (c, a) => a[0] === "run" ? { code: 1, stdout: "", stderr: '{"error":{"kind":"name_taken"}}' } : ocExec(c, a) }, true, false],
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
console.log("PASS: one Shep: a live one is reused, a racing start is quiet, no OpenClaw starts nothing");

// Shep opens an agent-scoped session, never bare `openclaw tui` (which picks the agent
// from its folder): [shep] session from config.toml, else OpenClaw's default agent's
// main session. The key goes in as an argument, not into the script.
async function started(state) {
  delete globalThis.bercailShep;
  setup({ terminals: [{ address: "t1", state: "live", labels: {} }], ...state });
  v = nav();
  v.sync();
  await tick();
  await tick();
  return runs()[0] ?? null;
}
function routes(argv, key, label) {
  const script = argv?.[argv.indexOf("-lc") + 1] ?? "";
  if (!/openclaw tui --session "\$1"/.test(script) || /openclaw tui(;|\s*$)/m.test(script)) fail(`${label}: script ${script}`);
  if (argv.at(-1) !== key || argv.at(-2) !== "bash" || script.includes(key)) fail(`${label}: argv ${argv}`);
  if (!argv.includes(`bercail.shep_session=${key}`)) fail(`${label}: no session label: ${argv}`);
}
routes(await started({}), "agent:sheep:main", "default agent");
if (!globalThis.herdr.reads?.includes("/home/me/.config/bercail/config.toml")) fail("the config was not read");
const config = '[layout]\nsession = "agent:no:main"\n\n[shep]\n# the orchestrator\nsession = "agent:sheep:main" # Simon\n';
if (configSession(config) !== "agent:sheep:main" || configSession("[layout]\nsession = \"x\"\n") !== "") fail("configSession");
let argv2 = await started({ config: config.replace("agent:sheep:main", "agent:ops:work") });
routes(argv2, "agent:ops:work", "[shep] session");
if (globalThis.herdr.execs.some((e) => /agents list/.test(e.at(-1)))) fail("a set [shep] session must not ask OpenClaw for its default");
for (const [label, state] of [
  ["not agent-scoped", { config: '[shep]\nsession = "main"\n' }],
  ["injection", { config: '[shep]\nsession = "agent:a:b; rm -rf ~"\n' }],
  ["no default agent", { exec: (c, a) => /agents list/.test(a.at(-1)) ? { code: 0, stdout: "[]", stderr: "" } : ocExec(c, a) }],
]) {
  if (await started(state)) fail(`${label}: Shep started`);
  const note = globalThis.herdr.notes?.[0]?.body ?? "";
  if (!/\[shep\] session = "agent:<agent id>:main"/.test(note)) fail(`${label}: note ${note}`);
}
console.log("PASS: Shep opens [shep] session or the default agent's main session, explicitly, else says how to set it");

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
console.log("PASS: Shep's block is added once, selected after, dropped when Shep ends");

// A layout.set while a view switch is on its way carries that view.
setup({ terminals: [SHEP("t9")] });
v = nav();
v.show("space");
globalThis.herdr.layout = withView(globalThis.herdr.layout, "shep"); // the switch hasn't landed
v.sync();
const [[, set]] = calls("layout.set");
if (viewOf(set.layout) !== "space") fail("layout.set undid a view switch on its way");
console.log("PASS: adding Shep's block keeps a view switch on its way");

// The keyboard: into Shep in the Shep view (once its block is there); back where it
// was in the space when the space view comes back, else the shown tab's first pane.
const shep = SHEP("t9");
const f = (o) => ({ space: "s1", pane: null, terminal: null, ...o });
const eq = (a, b, label) => { if (JSON.stringify(a) !== JSON.stringify(b)) fail(`${label}: ${JSON.stringify(a)}`); };
setup();
eq(focusPlan("shep", "space", f({ pane: "p1" }), shep, true, null, PANES, SPACES[0]), { terminal: "t9" }, "into Shep");
eq(focusPlan("shep", "space", f({ pane: "p1" }), shep, false, null, PANES, SPACES[0]), null, "not before its block");
eq(focusPlan("shep", "shep", f({ terminal: "t9" }), shep, true, null, PANES, SPACES[0]), null, "already on Shep");
eq(focusPlan("space", "shep", f({ terminal: "t9" }), shep, true, { terminal: "t5" }, PANES, SPACES[0]), { terminal: "t5" }, "back to the desk");
eq(focusPlan("space", "shep", f({ pane: "p1" }), shep, true, { terminal: "t5" }, PANES, SPACES[0]), { terminal: "t5" }, "over the app's own pick");
eq(focusPlan("space", "shep", f({ terminal: "t9" }), shep, true, { pane: "gone" }, PANES, SPACES[0]), { pane: "p1" }, "a closed pane");
eq(focusPlan("space", "shep", f({ pane: "p1" }), shep, true, { pane: "p1" }, PANES, SPACES[0]), null, "already there");
eq(focusPlan("space", "space", f({ pane: "p1" }), shep, true, { terminal: "t5" }, PANES, SPACES[0]), null, "the person moved it");
console.log("PASS: the keyboard follows the view and comes back where it was");

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
console.log("PASS: a round trip through Shep puts the keyboard back on the desk");

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
console.log("PASS: Ctrl+Shift+H toggles the views; the Shep row comes back to Shep");

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
console.log("PASS: the dialog's bar closes back to where the keyboard was, or shows the space");

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
console.log("PASS: clicking a space shows it in the space view; other layouts only select");
EOF
node "$TMP_DIR/test.mjs"
