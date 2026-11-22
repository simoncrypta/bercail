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
export const openOverlay = (spec) => (h().calls.push(["openOverlay", spec]), "o1");
export const closeOverlay = (id) => h().calls.push(["closeOverlay", id]);
// A call's argv; .on: the machine it ran on (null: here).
export const exec = async (cmd, args, opts) => { h().execs.push(Object.assign([cmd, ...args], { on: opts?.on ?? null })); return h().exec(cmd, args); };
export const hc = async () => ({ code: 0, stdout: "", stderr: "" });
export const watchFolder = (path) => {
  (h().watched ??= []).push(path);
  return Object.assign(new Promise(() => {}), { cancel() {} });
};
export const window = () => ({ platform: "linux", active: true });
export const home = () => "/home/me";
// The files a test puts in h().files, by path; else absent.
export const readTextFile = async (path) => h().files?.[path] ?? null;
export const nextCommand = () => (h().nextCommand ?? (() => new Promise(() => {})))();
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
      if (k === "on_key_down") t.key = a[0];
      if (k === "child" && typeof a[0] === "string") (t.text ??= []).push(a[0]);
      if (k === "on_mouse_down" || k === "on_mouse_up") t[`${k}:${a[0]}`] = a[1];
      if (k === "when" && a[0]) a[1](p);
      return p;
    },
  });
  return p;
};
export class View {}
export const ScrollHandle = { new: () => ({ scroll_to_item() {} }) };
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
import Shep, { find, viewOf, stackPlan, focusPlan, withView, loadDecisions, cardWords, answerable } from "./bercail-shep.mjs";
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
const cx = {
  spawn: (f) => f(cx), notify: () => {}, stop_propagation: () => {},
  timer: { every: (_ms, f) => (globalThis.herdr.timers ??= []).push(f) },
  focus_handle: () => ({ focus: () => (globalThis.herdr.panelFocused = true), is_focused: () => false }),
};
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
// Shep's ledger as `bercail shep question panel` prints it: one card fresh, one stale, one unknown.
const card = (token, extra = {}) => ({
  token, kind: "review", prompt: "LGTM to land it?", options: ["LGTM", "Not yet"],
  brief: "The guard now blocks empty secrets.", recommendation: { choice: "LGTM", why: "tests pass" }, discussed: false,
  createdAt: "2026-11-14T20:58:00.000Z", status: "fresh", reasons: [],
  target: { repo: "/w/bercail/.git", topic: `topic-${token}`, worktree: "/w/bercail.guard", space: "sp1" },
  change: { lines: 347, stakes: "high" }, ...extra,
});
const PANEL_VIEW = { state: "/state/shep", at: "2026-11-14T21:00:00.000Z", cards: [
  card("Q1@1"),
  card("Q2@3", { status: "stale", reasons: ["stagedTree changed", "base changed"],
    warnings: ["desk t9 is gone or not live at its recorded address"] }),
  card("Q3@1", { kind: "planning", prompt: "Which job first?", options: [], change: null,
    target: { repo: "/w/app/.git", topic: "plan", worktree: "/w/app", space: null },
    status: "unavailable", reasons: ["policy unavailable; not checked"] }),
] };
// bash -lc SCRIPT bercail-shep ARGS: the panel answers with the view; anything else succeeds.
const panelExec = (view, answer = { accepted: true }) => (cmd, args) =>
  cmd === "bash" && /question panel/.test(args[1]) ? { code: 0, stdout: JSON.stringify(view), stderr: "" }
  : cmd === "bash" && /question answer/.test(args[1]) ? { code: 0, stdout: JSON.stringify(answer), stderr: "" }
  : cmd === "hc" && args[0] === "run" ? { code: 0, stdout: '{"address":"t30","state":"live"}', stderr: "" }
  : okExec();
// The panel's keyboard: a key pressed while it holds focus.
const press = (d, ...keys) => {
  for (const k of keys) {
    els.length = 0;
    d.render(cx);
    els.find((e) => e.id === "decisions-root").key({ keystroke: k }, cx);
  }
};
const answers = () => globalThis.herdr.execs.filter((e) => /question answer/.test(e[2] ?? "")).map((e) => JSON.parse(e[4]));
const texts = () => els.flatMap((e) => e.text ?? []);
const copy = (role) => {
  globalThis.herdr.props = { role };
  const c = new Shep();
  c.init({}, cx);
  return c;
};
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

@test "with a backend, Shep is looked for and started on it, in its home" {
  mod_case <<'EOF'
// [herdr] backend = "box": hc asks box whether bercail is there and starts Shep there,
// with no --cwd (hc uses box's home; this computer's home means nothing there). A Shep
// on this computer is not that one; a live box/ Shep is reused.
const BOX = { "/home/me/.config/bercail/config.toml": '[herdr]\nbackend = "box" # bercail runs there\n' };
delete globalThis.bercailShep;
setup({ files: BOX, terminals: [SHEP("t9"), { address: "box/t1", state: "live", labels: {} }] });
v = nav();
v.sync();
for (let i = 0; i < 4; i++) await tick();
const probe = globalThis.herdr.execs.find((e) => e[1] === "exec");
eq(probe?.slice(0, 5), ["hc", "exec", "--on", "box", "bash"], "bercail is looked for on box");
const argv = runs()[0] ?? [];
if (argv[argv.indexOf("--on") + 1] !== "box") fail(`Shep must start on box: ${argv}`);
if (argv.includes("--cwd")) fail(`no --cwd from this computer: ${argv}`);
delete globalThis.bercailShep;
setup({ files: BOX, terminals: [SHEP("box/t4")] });
v = nav();
v.sync();
for (let i = 0; i < 4; i++) await tick();
if (runs().length) fail(`box's Shep is live: ${JSON.stringify(runs())}`);
// box answers that it has no bercail: the view says where it looked.
delete globalThis.bercailShep;
setup({ files: BOX, terminals: [], props: { role: "empty" }, exec: () => ({ code: 1, stdout: "", stderr: "" }) });
const empty = new Shep();
empty.init({}, cx);
for (let i = 0; i < 4; i++) await tick();
els.length = 0;
empty.render(cx);
if (!els.some((e) => e.text?.includes("bercail is not installed on box"))) fail("the missing view must name box");
EOF
}

@test "a desk on the backend: the keyboard comes back to it, and Show in space finds its space" {
  mod_case <<'EOF'
// box/t5's bercail.space=sp1 is written on box: here its space is box/sp1.
const DESKBOX = DESK("box/t5", "sp1");
const SP = [{ id: "box/sp1", name: "far", tabs: [{ id: "box/tab1", active: true }] }];
setup({ spaces: SP, panes: [{ pane: "box/p1", tab: "box/tab1", terminal: "box/t1" }],
  terminals: [shep, DESKBOX], focused: f({ space: "box/sp1", terminal: "box/t5" }) });
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
v = nav();
v.sync();
v.sync();
globalThis.herdr.layout = withView(globalThis.herdr.layout, "shep");
globalThis.herdr.focused = f({ space: "box/sp1", pane: "box/p1" });
v.sync();
globalThis.herdr.layout = withView(globalThis.herdr.layout, "space");
globalThis.herdr.calls = [];
v.sync();
eq(calls("pane.focus").at(-1)?.[1], { terminal: "box/t5" }, "back on box's desk");
setup({ spaces: SP, terminals: [DESKBOX], props: { role: "modal", terminal: "box/t5", overlay: "o1" } });
v = nav();
els.length = 0;
v.render(cx);
const show = els.find((e) => e.id === "modal-space");
if (!show) fail("the desk's dialog has no Show in space");
show.click();
eq(calls("space.select")[0]?.[1], { id: "box/sp1" }, "Show in space");
EOF
}

@test "a failed start keeps its error under Start Shep when another copy checks for bercail" {
  mod_case <<'EOF'
// hc run refuses; the stopped view says why. A copy that opens later checks for bercail
// again, which must not wipe that error.
delete globalThis.bercailShep;
setup({ terminals: [{ address: "t1", state: "live", labels: {} }], props: { role: "empty" },
  exec: (_c, a) => (a[0] === "run" ? { code: 1, stdout: "", stderr: "no room for Shep" } : okExec()) });
const empty = new Shep();
empty.init({}, cx);
await tick();
els.length = 0;
empty.render(cx);
els.find((e) => e.id === "shep-start").click(null, cx);
for (let i = 0; i < 4; i++) await tick();
new Shep().init({}, cx);
for (let i = 0; i < 4; i++) await tick();
els.length = 0;
empty.render(cx);
if (!els.some((e) => e.text?.includes("no room for Shep"))) fail("the start's error is gone after another copy checked");
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

@test "the Decisions panel shows each decision's brief, Shep's pick, its state and times, with a picker only when fresh" {
  mod_case <<'EOF'
// Cards from a fixed ledger: the space as Herdr names it, size and stakes, the ask, Shep's
// brief and recommendation, the choices, stale and unknown said plainly, and the times.
setup({ exec: panelExec(PANEL_VIEW), spaces: [{ id: "sp1", name: "Guard-empty-secret_Bercail", tabs: [] }] });
const d = copy("decisions");
await tick();
els.length = 0;
d.render(cx);
const all = texts();
for (const want of [
  "Guard-empty-secret_Bercail, 347 lines, high-stakes", "LGTM to land it?", "The guard now blocks empty secrets.",
  "Shep recommends LGTM: tests pass", "1 LGTM ★", "2 Not yet", "Answer LGTM",
  "open", "stale", "Changed since Shep asked: the staged change, the base. Shep must ask again.",
  "Warning: desk t9 is gone or not live at its recorded address.",
  "app", "unknown", "Can't check it now: the repo's policy could not be read.", "No choices: answer Shep in chat.",
]) if (!all.includes(want)) fail(`missing "${want}" in ${JSON.stringify(all)}`);
if (!all.some((x) => x.startsWith("3 waiting on you"))) fail(`no count in ${JSON.stringify(all)}`);
if (!all.some((x) => /^asked (2026-11-14 )?\d\d:\d\d$/.test(x)) || !all.some((x) => /^checked (2026-11-14 )?\d\d:\d\d$/.test(x)))
  fail(`no asked/checked times in ${JSON.stringify(all)}`);
// Tokens are the ledger's keys, never something to read.
if (all.some((x) => /Q\d+@\d+/.test(x))) fail(`a token is shown: ${all.filter((x) => /Q\d+@/.test(x))}`);
// Only the fresh card's choices and answer click; a stale or unknown card discusses only.
const buttons = els.filter((e) => e.click).map((e) => e.id);
eq(buttons, ["decision-choice-Q1@1-0", "decision-choice-Q1@1-1", "decision-discuss-Q1@1", "decision-accept-Q1@1",
  "decision-discuss-Q2@3", "decision-discuss-Q3@1"], "card buttons");
// A space Herdr no longer shows is said so.
eq(cardWords(card("Q4@1"), []).title, "bercail.guard (its space is closed), 347 lines, high-stakes", "closed space");
// A desk problem is a warning on a card that can still be answered.
const warned = card("Q5@1", { warnings: ["no desk: bound to the repo and issue only"] });
eq([cardWords(warned).word, cardWords(warned).warnings, answerable(warned)],
  ["open", ["Warning: no desk: bound to the repo and issue only."], true], "a warned card");
EOF
}

@test "a card bound to a trail links the trail's page; a card bound to a beads issue has no link" {
  mod_case <<'EOF'
const url = "https://entire.com/et/lab/-/trails/7";
const view = { ...PANEL_VIEW, cards: [card("Q1@1", { target: { ...card("Q1@1").target, url } }), card("Q2@1")] };
setup({ terminals: [shep], exec: panelExec(view) });
const d = copy("decisions");
await tick();
els.length = 0;
d.render(cx);
eq(els.filter((e) => e.id?.startsWith("decision-trail-")).map((e) => e.id), ["decision-trail-Q1@1"], "trail links");
const opened = [];
els.find((e) => e.id === "decision-trail-Q1@1").click(null, { ...cx, open_url: (u) => opened.push(u) });
eq(opened, [url], "Open trail");
eq(answers(), [], "opening the trail answers nothing");
EOF
}

@test "a land card the person shipped shows how far its chain got, offers no choice, and counts as waiting on no one" {
  mod_case <<'EOF'
const land = (token, landing) => card(token, { kind: "land", options: ["Ship it", "Not yet"], status: "landing", landing });
const view = { ...PANEL_VIEW, cards: [land("Q1@1", { step: null, detail: null, at: null }),
  land("Q2@1", { step: "ci", detail: "waiting for CI (1 of 2 runs passed)", at: "2026-11-14T12:00:00Z" }), card("Q3@1")] };
setup({ terminals: [shep], exec: panelExec(view) });
const d = copy("decisions");
await tick();
els.length = 0;
d.render(cx);
const all = texts();
for (const want of ["You shipped it. Picked; waiting for its worker to start.",
  "You shipped it. Landing, at its ci step: waiting for CI (1 of 2 runs passed). Shep tells you how it ends."])
  if (!all.includes(want)) fail(`missing "${want}" in ${JSON.stringify(all)}`);
eq(cardWords(view.cards[1]).word, "landing", "its state");
eq(answerable(view.cards[1]), false, "no pick on a landing card");
eq(els.filter((e) => e.click).map((e) => e.id).filter((id) => /Q[12]@1/.test(id) && !id.includes("discuss")), [],
  "no choice or answer button on a landing card");
if (!all.some((x) => x.startsWith("1 waiting on you"))) fail(`a landing card counts as waiting: ${JSON.stringify(all)}`);
EOF
}

@test "a push question's card names the choice that approves the push, its remote and its refs" {
  mod_case <<'EOF'
const push = { approves: "Push it", remote: "origin", refs: ["refs/heads/master"], url: "git@example.invalid:team/app.git" };
const view = { ...PANEL_VIEW, cards: [card("Q1@1", { push }), card("Q2@1")] };
setup({ terminals: [shep], exec: panelExec(view) });
const d = copy("decisions");
await tick();
els.length = 0;
d.render(cx);
const line = 'Picking "Push it" lets Shep push the answered commit to origin (git@example.invalid:team/app.git): refs/heads/master, once.';
eq(texts().filter((x) => x.startsWith("Picking ")), [line], "only the push card says what it approves");
eq(cardWords(card("Q2@1")).push, null, "no push line without a push");
EOF
}

@test "Enter answers with Shep's pick, keys move between cards and choices, and a stale card answers nothing" {
  mod_case <<'EOF'
setup({ terminals: [shep], exec: panelExec(PANEL_VIEW) });
const d = copy("decisions");
await tick();
// A click on a choice selects it and puts the keyboard in the panel; it records nothing.
els.length = 0;
d.render(cx);
els.find((e) => e.id === "decision-choice-Q1@1-1").click(null, cx);
if (!globalThis.herdr.panelFocused) fail("a click in the panel must give it the keyboard");
eq(answers(), [], "a choice click alone");
press(d, "1", "enter");
await tick();
press(d, "right", "enter");
await tick();
press(d, "left", "2", "enter");
await tick();
eq(answers().map((a) => [a.token, a.choice, a.source]), [
  ["Q1@1", "LGTM", "panel picker"], ["Q1@1", "Not yet", "panel picker"], ["Q1@1", "Not yet", "panel picker"],
], "answers");
if (new Set(answers().map((a) => a.requestId)).size !== 3) fail("each pick needs its own request id");
// The stale card and the card with no choices: Enter and number keys record nothing.
globalThis.herdr.execs = [];
press(d, "down", "1", "enter", "down", "enter");
await tick();
eq(answers(), [], "answers from a stale or choiceless card");
// d discusses the card the keys are on.
press(d, "d");
await tick();
const run = globalThis.herdr.execs.find((e) => e[0] === "hc" && e[1] === "run");
if (!run?.includes("bercail.question=Q3@1")) fail(`d did not discuss the selected card: ${JSON.stringify(run)}`);
// A refused pick says why on the panel.
setup({ terminals: [shep], exec: panelExec(PANEL_VIEW, { accepted: false, reason: "question is answered" }) });
const d2 = copy("decisions");
await tick();
press(d2, "enter");
for (let i = 0; i < 5; i++) await tick();
els.length = 0;
d2.render(cx);
if (!texts().includes("Not recorded: question is answered.")) fail(`no refusal shown: ${JSON.stringify(texts())}`);
EOF
}

@test "a card with no recommendation waits for a pick before Enter answers" {
  mod_case <<'EOF'
const view = { ...PANEL_VIEW, cards: [card("Q1@1", { recommendation: null })] };
setup({ terminals: [shep], exec: panelExec(view) });
const d = copy("decisions");
await tick();
press(d, "enter");
await tick();
eq(answers(), [], "Enter with nothing picked");
els.length = 0;
d.render(cx);
if (!texts().includes("Pick a choice") || els.some((e) => e.id === "decision-accept-Q1@1" && e.click))
  fail("the answer button must wait for a pick");
press(d, "2", "enter");
await tick();
eq(answers().map((a) => a.choice), ["Not yet"], "the picked choice");
EOF
}

@test "a two-way door counts down on its card and ticks; a defaulted one says so, offers OK, and is counted apart" {
  mod_case <<'EOF'
const at = (min) => new Date(Date.now() + min * 60000).toISOString();
const plan = { kind: "planning", prompt: "Which desk first?", options: ["auth", "search"], change: null,
  recommendation: { choice: "auth", why: "it unblocks search" } };
const view = { ...PANEL_VIEW, cards: [
  card("Q1@1", { ...plan, deadline: at(29.5), defaulted: null }),
  card("Q2@1", { deadline: null, defaulted: null }),
  card("Q3@1", { ...plan, deadline: at(-1), defaulted: null }),
  card("Q4@1", { ...plan, deadline: at(-1), defaulted: null, status: "stale", reasons: ["worktree changed"] }),
  card("Q5@1", { ...plan, deadline: at(-5), defaulted: { choice: "auth", at: at(-4) } }),
  card("Q6@1", { ...plan, deadline: at(65.5), defaulted: null }),
  card("Q7@1", { ...plan, deadline: at(0.5), defaulted: null }),
] };
setup({ terminals: [shep], exec: panelExec(view) });
const d = copy("decisions");
const h = copy("header");
await tick();
const render = () => { els.length = 0; d.render(cx); return texts(); };
const timers = (all) => all.filter((x) => x.startsWith("two-way door: ") && !x.includes("nobody picked"));
eq(timers(render()), [
  "two-way door: defaults to auth in 29 min",
  "two-way door: defaults to auth at Shep's next check",
  "two-way door: past its deadline; it waits for you while it is stale",
  "two-way door: defaults to auth in 1 h 5 min",
  "two-way door: defaults to auth in under a minute",
], "timers (none on the card with no deadline)");
const all = texts();
if (!all.includes("defaulted")) fail(`no defaulted word in ${JSON.stringify(all)}`);
if (!all.some((x) => /^two-way door: nobody picked by (\d{4}-\d\d-\d\d )?\d\d:\d\d, so it took Shep's recommendation, auth\. OK keeps it as your pick; Reverse tells Shep to undo it\.$/.test(x)))
  fail(`no defaulted line in ${JSON.stringify(all)}`);
// Past its deadline a fresh card takes no pick: only Discuss is clickable.
eq(els.filter((e) => e.click && e.id?.includes("Q3@1")).map((e) => e.id), ["decision-discuss-Q3@1"], "overdue card controls");
// The defaulted card: its choices (to reverse to), Discuss, Reverse and OK, no answer button; counted apart from the 6 waiting on you.
eq(els.filter((e) => e.id?.includes("Q5@1") && e.id !== "decision-Q5@1").map((e) => e.id),
  ["decision-choice-Q5@1-0", "decision-choice-Q5@1-1", "decision-discuss-Q5@1", "decision-reverse-Q5@1", "decision-ok-Q5@1"], "defaulted card controls");
if (!all.includes("OK auth")) fail(`no OK button: ${JSON.stringify(all)}`);
if (!all.some((x) => x.startsWith("6 waiting on you · 1 defaulted · "))) fail(`panel count: ${JSON.stringify(all)}`);
els.length = 0;
h.render(cx);
if (!texts().includes("Decisions 6 · 1 defaulted")) fail(`header: ${JSON.stringify(texts())}`);
// Ten minutes on, the next draw counts down.
const now = Date.now;
Date.now = () => now() + 10 * 60000;
if (!timers(render()).includes("two-way door: defaults to auth in 19 min")) fail(`no tick: ${JSON.stringify(timers(texts()))}`);
Date.now = now;
// Its Discuss bar says it defaulted, not that /pick answers.
globalThis.herdr.props = { role: "discuss", token: "Q5@1" };
const bar = new Shep();
bar.init({}, cx);
els.length = 0;
bar.render(cx);
if (!texts().includes("read-only branch · it defaulted; /pick OKs or reverses it, closing tells Shep")) fail(`discuss bar: ${JSON.stringify(texts())}`);
EOF
}

@test "o or OK records the person's OK on a fresh default only, and a default alone counts in the header" {
  mod_case <<'EOF'
const plan = { kind: "planning", prompt: "Which desk first?", options: ["auth", "search"], change: null,
  recommendation: { choice: "auth", why: "it unblocks search" }, deadline: "2026-11-14T20:30:00.000Z" };
const view = { ...PANEL_VIEW, cards: [
  card("Q1@1", { ...plan, defaulted: { choice: "auth", at: "2026-11-14T20:31:00.000Z" } }),
  card("Q2@1", { ...plan, defaulted: { choice: "auth", at: "2026-11-14T20:31:00.000Z" }, status: "stale", reasons: ["head changed"] }),
  card("Q3@1", { deadline: null, defaulted: null }),
] };
setup({ terminals: [shep], exec: panelExec(view) });
const d = copy("decisions");
await tick();
// o on the fresh default records an OK, with no choice; Enter and the number keys pick nothing on it.
press(d, "2", "enter", "o");
await tick();
eq(answers().map(({ requestId, ...a }) => a), [{ token: "Q1@1", outcome: "ok", source: "panel picker" }], "the OK");
// A stale default says why and takes no OK; o on a card that did not default records nothing.
globalThis.herdr.execs = [];
press(d, "down", "o", "down", "o");
await tick();
eq(answers(), [], "an OK on a stale default or a pending card");
els.length = 0;
d.render(cx);
if (!texts().some((x) => x.endsWith("Changed since: new commits. OK and Reverse need it unchanged; Shep must ask again.")))
  fail(`stale default: ${JSON.stringify(texts())}`);
if (els.find((e) => e.id === "decision-ok-Q2@1")?.click) fail("a stale default's OK must not click");
// The OK button records the same as o.
els.find((e) => e.id === "decision-ok-Q1@1").click(null, cx);
await tick();
eq(answers().map((a) => [a.token, a.outcome]), [["Q1@1", "ok"]], "the button's OK");
// With only defaults left, the header still counts them.
setup({ terminals: [shep], exec: panelExec({ ...view, cards: view.cards.slice(0, 2) }) });
const h = copy("header");
await tick();
els.length = 0;
h.render(cx);
if (!texts().includes("Decisions 2 defaulted")) fail(`header: ${JSON.stringify(texts())}`);
EOF
}

@test "r reverses a fresh default, to the picked choice or none; a reversed card waits on Shep and is not counted" {
  mod_case <<'EOF'
const plan = { kind: "planning", prompt: "Which desk first?", options: ["auth", "search"], change: null,
  recommendation: { choice: "auth", why: "it unblocks search" }, deadline: "2026-11-14T20:30:00.000Z" };
const defaulted = { choice: "auth", at: "2026-11-14T20:31:00.000Z" };
const view = { ...PANEL_VIEW, cards: [
  card("Q1@1", { ...plan, defaulted }),
  card("Q2@1", { ...plan, defaulted, status: "stale", reasons: ["head changed"] }),
  card("Q3@1", { ...plan, defaulted, reversed: { choice: "search", at: "2026-11-14T20:40:00.000Z" } }),
] };
setup({ terminals: [shep], exec: panelExec(view) });
const d = copy("decisions");
const h = copy("header");
await tick();
// On the default's own choice, r reverses with no other choice; on another, to it.
press(d, "r");
await tick();
press(d, "2");
els.length = 0;
d.render(cx);
if (!texts().includes("Reverse to search")) fail(`reverse button: ${JSON.stringify(texts())}`);
press(d, "r");
await tick();
eq(answers().map(({ requestId, ...a }) => a), [
  { token: "Q1@1", outcome: "reversed", source: "panel picker" },
  { token: "Q1@1", outcome: "reversed", choice: "search", source: "panel picker" },
], "the reverses");
// A stale default and a reversed one take no Reverse or OK.
globalThis.herdr.execs = [];
press(d, "down", "r", "o", "down", "1", "r", "o");
await tick();
eq(answers(), [], "a Reverse on a stale or reversed card");
els.length = 0;
d.render(cx);
const all = texts();
if (!all.includes("reversed")) fail(`no reversed word: ${JSON.stringify(all)}`);
if (!all.includes("You reversed its default, auth, to search. Shep undoes what it did on it; the card leaves once Shep has."))
  fail(`reversed line: ${JSON.stringify(all)}`);
eq(els.filter((e) => e.id?.includes("Q3@1") && e.id !== "decision-Q3@1").map((e) => e.id), ["decision-discuss-Q3@1"], "reversed card controls");
// The header counts the two defaults still waiting on you, not the reversed one.
els.length = 0;
h.render(cx);
if (!texts().includes("Decisions 2 defaulted")) fail(`header: ${JSON.stringify(texts())}`);
EOF
}

@test "a new decision changes the header's count and nothing else" {
  mod_case <<'EOF'
// Data never moves the view, the panel, or the keyboard: only the count changes.
setup({ terminals: [shep], exec: panelExec({ ...PANEL_VIEW, cards: PANEL_VIEW.cards.slice(0, 1) }) });
const h = copy("header");
await tick();
els.length = 0;
h.render(cx);
if (!texts().includes("Decisions 1")) fail(`header: ${JSON.stringify(texts())}`);
globalThis.herdr.exec = panelExec(PANEL_VIEW);
await loadDecisions();
els.length = 0;
h.render(cx);
if (!texts().includes("Decisions 3")) fail(`header after a new decision: ${JSON.stringify(texts())}`);
eq(globalThis.herdr.calls, [], "commands run by a data change");
if (!find(globalThis.herdr.layout, "shep-decisions")?.hidden) fail("the panel must start hidden");
EOF
}

@test "the header's Decisions toggle shows and hides the panel on a click" {
  mod_case <<'EOF'
setup({ terminals: [shep], exec: panelExec(PANEL_VIEW) });
const h = copy("header");
await tick();
const toggle = () => {
  els.length = 0;
  h.render(cx);
  return els.find((e) => e.id === "shep-decisions-toggle");
};
let stopped = false;
toggle()["on_mouse_down:left"](null, { stop_propagation: () => (stopped = true) });
if (!stopped) fail("a press on the toggle must not drag the window");
toggle().click();
if (find(globalThis.herdr.layout, "shep-decisions").hidden) fail("a click must show the panel");
toggle().click();
if (!find(globalThis.herdr.layout, "shep-decisions").hidden) fail("a second click must hide it");
eq(globalThis.herdr.calls.map(([n, a]) => `${n} ${a.id}`), ["layout.show shep-decisions", "layout.hide shep-decisions"], "toggle commands");
EOF
}

@test "Discuss opens the question's branch in a dialog; closing it ends the branch and tells Shep" {
  mod_case <<'EOF'
setup({ terminals: [shep], exec: panelExec(PANEL_VIEW) });
const d = copy("decisions");
await tick();
globalThis.herdr.execs = [];
els.length = 0;
d.render(cx);
els.find((e) => e.id === "decision-discuss-Q2@3").click(null, cx);
for (let i = 0; i < 5; i++) await tick();
const run = globalThis.herdr.execs.find((e) => e[0] === "hc");
eq(run.slice(1, 16), ["run", "--bg", "--json", "--no-parent", "--no-notify", "--rm", "--name", "shep-discuss-q2-3",
  "--cwd", "/home/me", "--label", "bercail.role=shep-discuss", "--label", "bercail.question=Q2@3", "bash"], "the branch's terminal");
if (!/exec bercail shep discuss "\$1"$/.test(run[17]) || run[19] !== "Q2@3") fail(`Discuss ran ${run.slice(16)}`);
const [, dialog] = calls("openOverlay")[0];
eq([dialog.kind, dialog.modal], ["dialog", true], "a dialog a click beside it does not close");
const [bar, term] = dialog.layout.children;
eq(term.content, { terminal: "t30" }, "the dialog shows the branch's terminal");
eq([bar.content.props.role, bar.content.props.token, bar.content.props.terminal], ["discuss", "Q2@3", "t30"], "bar");
// A branch still running is reopened, not started twice.
globalThis.herdr.terminals = [shep, { address: "t31", state: "live", labels: { "bercail.role": "shep-discuss", "bercail.question": "Q2@3" } }];
globalThis.herdr.execs = [];
els.length = 0;
d.render(cx);
els.find((e) => e.id === "decision-discuss-Q2@3").click(null, cx);
for (let i = 0; i < 5; i++) await tick();
if (globalThis.herdr.execs.some((e) => e[1] === "run")) fail("a second branch started");
eq(calls("openOverlay")[1][1].layout.children[1].content, { terminal: "t31" }, "reopened on the running branch");
// The bar: ✕ closes the dialog; the close ends the branch's Pi, tells Shep, and the keyboard goes back.
globalThis.herdr.props = { ...bar.content.props, overlay: "o9" };
const b = new Shep();
b.init({}, cx);
els.length = 0;
b.render(cx);
if (!texts().includes("Discuss") || !texts().includes("LGTM to land it?")) fail(`bar: ${JSON.stringify(texts())}`);
els.find((e) => e.id === "discuss-close").click();
eq(calls("closeOverlay").at(-1), ["closeOverlay", "o9"], "✕ closes the dialog");
globalThis.herdr.execs = [];
globalThis.herdr.calls = [];
await b.close();
eq(globalThis.herdr.execs[0].slice(0, 3), ["hc", "kill", "t30"], "the branch's Pi ends");
const told = globalThis.herdr.execs.find((e) => /question closed/.test(e[2] ?? ""));
eq(told?.slice(3), ["bercail-shep", "Q2@3", bar.content.props.opening], "Shep is told of this close");
if (!/^[A-Za-z0-9_-]+$/.test(bar.content.props.opening)) fail(`opening ${bar.content.props.opening}`);
eq(calls("pane.focus"), [["pane.focus", { pane: "p1" }]], "the keyboard goes back");
EOF
}

@test "no scripted command (keys.json, the palette, herdr-app do) answers or opens the Decisions panel" {
  mod_case <<'EOF'
// keys.json, the palette, herdr-app do and toasts all arrive through nextCommand. The nav
// copy takes them; none, made up or real, runs a question command or opens the panel.
setup({ terminals: [shep], exec: panelExec(PANEL_VIEW) });
let waits = 0;
globalThis.herdr.nextCommand = () => (waits++, new Promise(() => {}));
copy("decisions");
copy("header");
if (waits) fail("a Decisions or header copy waits for commands");
globalThis.herdr.props = {};
v = nav();
if (waits !== 1) fail(`the nav copy must wait for commands (${waits})`);
for (let i = 0; i < 5; i++) await tick(); // the copies' first loads
globalThis.herdr.execs = [];
globalThis.herdr.calls = [];
const made = ["answer:Q1@1:LGTM", "decisions", "discuss:Q1@1", "reply:Q1@1 yes", "thread:topic-Q1@1", "desk:discuss"];
for (const c of [...Object.values(keys).filter((a) => a.startsWith("bercail-shep.")).map((a) => a.slice(13)), ...made])
  await v.command(c);
if (globalThis.herdr.execs.some((e) => e.join(" ").includes("question"))) fail(`a command ran ${JSON.stringify(globalThis.herdr.execs)}`);
if (globalThis.herdr.calls.some(([, a]) => a?.id === "shep-decisions")) fail("a command opened the panel");
EOF
}

@test "a ledger change during a load is read by one more load" {
  mod_case <<'EOF'
// A question written while a load runs may not be in what it read: the count must not
// stay behind until some later write.
setup({ terminals: [shep] });
let release;
globalThis.herdr.exec = () => new Promise((r) => (release = () => r({ code: 0, stdout: JSON.stringify({ ...PANEL_VIEW, cards: [] }), stderr: "" })));
const h = copy("header");
for (let i = 0; i < 5; i++) await tick(); // its first load reaches exec
loadDecisions(); // the watch saw questions.json change mid-load
globalThis.herdr.exec = panelExec(PANEL_VIEW);
release();
for (let i = 0; i < 5; i++) await tick();
const loads = globalThis.herdr.execs.filter((e) => /question panel/.test(e[2] ?? "")).length;
if (loads !== 2) fail(`expected two loads, got ${loads}`);
els.length = 0;
h.render(cx);
if (!texts().includes("Decisions 3")) fail(`the count stayed behind: ${JSON.stringify(texts())}`);
EOF
}

@test "with a backend, the Decisions panel reads, answers and discusses on it" {
  mod_case <<'EOF'
// [herdr] backend = "box": Shep's ledger is on box, so the panel and Discuss run there,
// a card finds box's space as box/sp1, and box's state path is never watched here.
setup({
  files: { "/home/me/.config/bercail/config.toml": '[herdr]\nbackend = "box"\n' },
  terminals: [SHEP("box/t9")], exec: panelExec(PANEL_VIEW),
  spaces: [{ id: "sp1", name: "a local space", tabs: [] }, { id: "box/sp1", name: "Guard-empty-secret_Bercail", tabs: [] }],
});
const d = copy("decisions");
for (let i = 0; i < 5; i++) await tick();
const panels = () => globalThis.herdr.execs.filter((e) => /question panel/.test(e[2] ?? ""));
if (!panels().length || panels().some((e) => e.on !== "box")) fail(`panel ran on ${panels().map((e) => e.on)}`);
if ((globalThis.herdr.watched ?? []).length) fail(`watched ${globalThis.herdr.watched} here`);
els.length = 0;
d.render(cx);
if (!texts().includes("Guard-empty-secret_Bercail, 347 lines, high-stakes")) fail(`no box space name: ${JSON.stringify(texts())}`);
// Hidden, the count still follows box's ledger on the timer.
const before = panels().length;
for (const f of globalThis.herdr.timers) f(cx);
for (let i = 0; i < 5; i++) await tick();
if (panels().length !== before + 1) fail("the timer did not look at box's ledger with the panel hidden");
// A pick is recorded where the ledger is.
press(d, "enter");
for (let i = 0; i < 5; i++) await tick();
const answer = globalThis.herdr.execs.find((e) => /question answer/.test(e[2] ?? ""));
if (answer?.on !== "box") fail(`the answer ran on ${answer?.on}`);
// The branch runs on box, in its home; its box address shows here as box/t30.
globalThis.herdr.execs = [];
els.length = 0;
d.render(cx);
els.find((e) => e.id === "decision-discuss-Q1@1").click(null, cx);
for (let i = 0; i < 5; i++) await tick();
const run = globalThis.herdr.execs.find((e) => e[0] === "hc" && e[1] === "run");
if (!run || run.on !== null || run[run.indexOf("--on") + 1] !== "box" || run.includes("--cwd")) fail(`hc run: ${JSON.stringify(run)}`);
const props = calls("openOverlay").at(-1)[1].layout.children[0].content.props;
eq(props.terminal, "box/t30", "the branch's address here");
globalThis.herdr.props = props;
const b = new Shep();
b.init({}, cx);
globalThis.herdr.execs = [];
await b.close();
const closed = globalThis.herdr.execs.find((e) => /question closed/.test(e[2] ?? ""));
if (closed?.on !== "box") fail(`the close was told on ${closed?.on}`);
eq(globalThis.herdr.execs[0].slice(0, 3), ["hc", "kill", "box/t30"], "the branch ends on box");
EOF
}
