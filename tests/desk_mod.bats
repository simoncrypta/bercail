#!/usr/bin/env bats
# The bercail-desk mod's sync() against stubbed herdr and gpui modules.

setup() {
  load test_helper
  isolate
  need node
  # Each stub reads the state the test sets on globalThis.herdr.
  cat >"$BATS_TEST_TMPDIR/herdr.mjs" <<'EOF'
const h = () => globalThis.herdr;
export const layout = () => structuredClone(h().layout);
export const run = (name, args) => {
  h().calls.push([name, args]);
  // h().lose: how many layout.sets the app takes and never applies.
  if (name === "layout.set" && h().lose > 0) return void h().lose--;
  if (name === "layout.set") h().layout = structuredClone(args.layout);
  if (name === "layout.show" || name === "layout.hide") {
    const find = (n) => n?.id === args.id ? n : (n?.children ?? []).map(find).find(Boolean);
    const node = find(h().layout);
    if (!node) (h().toasts ??= []).push(`${name} failed: no node "${args.id}"`);
    else node.hidden = name === "layout.hide";
  }
  if (name === "layout.select") {
    const find = (n) => n?.id === args.stack ? n : (n?.children ?? []).map(find).find(Boolean);
    const stack = find(h().layout);
    if (stack?.children?.some((c) => c.id === args.child)) stack.active = args.child;
  }
};
export const spaces = () => h().spaces;
export const focused = () => h().focused;
export const terminals = () => h().terminals;
export const panes = () => h().panes ?? [];
export const agents = () => h().agents ?? [];
export const notify = (n) => (h().notes ??= []).push(n);
export const theme = () => ({});
export const props = () => h().props ?? {};
export const shared = () => null;
export const setShared = () => {};
export const home = () => "/nonexistent";
export const exec = async (cmd, args, opts) => h().exec?.(cmd, args, opts) ?? { code: 1, stdout: "", stderr: "" };
export const knownAgents = async () => [];
// The keys the test queues in h().keys, then none.
export const nextCommand = () => h().keys?.length ? Promise.resolve(h().keys.shift()) : new Promise(() => {});
// The files a test puts in h().files, by path; else an empty file.
export const readTextFile = async (path) => h().files?.[path] ?? "";
EOF
  # Elements take any chain of calls, so render() runs.
  cat >"$BATS_TEST_TMPDIR/gpui-kit.mjs" <<'EOF'
export const el = new Proxy(() => el, { get: (_t, k) => (k === "then" ? undefined : el), apply: () => el });
export class View {}
export const div = () => el;
EOF
  printf 'import { el } from "./gpui-kit.mjs";\nexport const h_flex = () => el;\nexport const v_flex = () => el;\n' >"$BATS_TEST_TMPDIR/gpui-base.mjs"
  sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui-kit.mjs"|' \
    -e 's|from "gpui-base"|from "./gpui-base.mjs"|' "$ROOT/bercail/mods/bercail-desk/main.js" >"$BATS_TEST_TMPDIR/main.mjs"
  cp "$ROOT/bercail/layouts/bercail.json" "$BATS_TEST_TMPDIR/layout.json"
  cat >"$BATS_TEST_TMPDIR/prelude.mjs" <<'EOF'
import { readFileSync } from "node:fs";
import Desk, { readConfig, sidebarOrder, stepSpace, stepSubspace, stepAgent } from "./main.mjs";
import { run } from "./herdr.mjs";

const shipped = JSON.parse(readFileSync(new URL("./layout.json", import.meta.url)));
const find = (n, id) => n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean) ?? null;
const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exit(1); };

const D = (address, space, state = "live") => ({ address, state, labels: { "bercail.role": "agent", "bercail.space": space } });
const stack = () => find(globalThis.herdr.layout, "agent-stack");
const ids = () => stack().children.map((c) => c.id);
const calls = (name) => globalThis.herdr.calls.filter(([n]) => n === name);

function setup({ terminals, legacy = false }) {
  const tree = structuredClone(shipped);
  // Layouts from before per-desk blocks: one shared block, repointed per space.
  if (legacy) find(tree, "agent-stack").children.unshift({ id: "agent", type: "block", content: { terminal: "t1" } });
  globalThis.herdr = {
    layout: tree,
    calls: [],
    focused: { space: "s1", pane: "p1" },
    spaces: ["s1", "s2", "s3"].map((id) => ({ id, tabs: [], folder: "/w" })),
    terminals,
  };
  const d = new Desk();
  Object.assign(d, { cfg: { autoReview: false }, prev: {}, pendingReview: {}, lastAuto: {}, hadDesk: new Set() });
  return d;
}
function show(d, space, renders = 3) {
  globalThis.herdr.focused = { space, pane: "p1" };
  for (let i = 0; i < renders; i++) d.sync();
}
// A layout.select the app can't honor: the toast this test guards against.
function badSelects() {
  return calls("layout.select").filter(([, a]) => !find(globalThis.herdr.layout, a.stack)?.children?.some((c) => c.id === a.child));
}
function check(label) {
  if (badSelects().length) fail(`${label}: selected a missing child: ${JSON.stringify(badSelects())}`);
}
let d;
const expect = (got, want, what) => { if (got !== want) fail(`${what}: ${got}, want ${want}`); };
// The layout as Herdr saved it on 2026-11-02: the panel column gone, panel-body in its place.
function collapsePanel(tree, body) {
  const work = find(tree, "work-body"), i = work.children.findIndex((c) => c.id === "panel");
  work.children[i] = { ...find(work.children[i], "panel-body"), ...body };
}
// Ctrl+Shift+F/G and the tab bar's Files/Changes buttons, in turn: one panel state.
async function panelSteps(d) {
  const state = () => {
    const panel = find(globalThis.herdr.layout, "panel");
    return panel.hidden ? "hidden" : find(panel, "panel-body").active;
  };
  // What a click on Files/Changes runs (Herdr's tabs mod).
  const click = (id) => {
    const root = globalThis.herdr.layout;
    const panel = find(root, "panel"), body = find(root, "panel-body");
    const on = panel && !panel.hidden && body?.active === id;
    if (on) run("layout.hide", { id: "panel" });
    else { run("layout.select", { stack: "panel-body", child: id }); run("layout.show", { id: "panel" }); }
  };
  const steps = [
    ["key", "files", "files"], ["key", "files", "hidden"], ["key", "changes", "changes"],
    ["key", "files", "files"], ["click", "files", "hidden"], ["click", "changes", "changes"],
    ["key", "changes", "hidden"], ["click", "files", "files"], ["key", "changes", "changes"],
    ["click", "changes", "hidden"], ["key", "changes", "changes"], ["click", "files", "files"],
  ];
  for (const [how, id, want] of steps) {
    if (how === "key") await d.command(id); else click(id);
    if (state() !== want) fail(`${how} ${id}: panel is ${state()}, want ${want}`);
  }
  if (globalThis.herdr.toasts?.length) fail(`toasts: ${globalThis.herdr.toasts}`);
  check("panel");
  if (calls("layout.show").concat(calls("layout.hide")).some(([, a]) => a.id !== "panel")) fail("keys must show and hide the panel");
}
EOF
  cat >"$BATS_TEST_TMPDIR/sidebar.mjs" <<'EOF'
// Space grouping, as the sidebar nests it.
const main = (repo) => ({ repo, linked: false });
const linked = (repo) => ({ repo, linked: true });
const rows = [
  { id: "ll-wt1", machine: null, git: linked("/w/ll/.git") }, // before its main: still nested under it
  { id: "ll", machine: null, git: main("/w/ll/.git") },
  { id: "home", machine: null, git: null },
  { id: "b", machine: null, git: main("/w/b/.git") },
  { id: "far", machine: "box", git: main("/w/ll/.git") }, // same path on another machine: its own repo
  { id: "ll-wt2", machine: null, git: linked("/w/ll/.git") },
  { id: "b-wt", machine: null, git: linked("/w/b/.git") },
  { id: "orphan-wt", machine: null, git: linked("/w/o/.git") }, // no main checkout space: top level
  { id: "ll-2", machine: null, git: main("/w/ll/.git") }, // a second space on the main checkout
];
const order = sidebarOrder(rows);

const steps = (fn, from, dir) => {
  const seen = [];
  let at = from;
  for (let i = 0; i < 6; i++) { at = fn(order, at, dir); seen.push(at); }
  return seen.join(" ");
};

const ags = [
  { address: "a-far", space: "far" },
  { address: "d-b", space: "b" }, { address: "a-b", space: "b" },
  { address: "d-ll", space: "ll" },
  { address: "a-wt2", space: "ll-wt2" },
];
const agentWalk = (from, dir) => {
  const seen = [];
  let at = from;
  for (let i = 0; i < 6; i++) { at = stepAgent(order, ags, at, null, dir).address; seen.push(at); }
  return seen.join(" ");
};
EOF
}

# One case: the shared prelude, the sidebar fixture when asked for, then the case on stdin.
mod_case() {
  local parts=("$BATS_TEST_TMPDIR/prelude.mjs")
  [[ "${1:-}" != --sidebar ]] || parts+=("$BATS_TEST_TMPDIR/sidebar.mjs")
  cat "${parts[@]}" - >"$BATS_TEST_TMPDIR/test.mjs"
  node "$BATS_TEST_TMPDIR/test.mjs"
}

@test "each desk keeps its own block; switching spaces only selects it" {
  mod_case <<'EOF'
if (find(shipped, "agent")) fail("the shipped layout still has a shared agent block");

// Spaces with live desks: each gets its own block once; switching back only selects.
d = setup({ terminals: [D("t7", "s1"), D("t8", "s2")] });
show(d, "s1");
if (stack().active !== "desk-t7") fail(`s1 shows ${stack().active}`);
if (find(globalThis.herdr.layout, "desk-t7")?.content?.terminal !== "t7") fail("desk-t7 block missing");
if (calls("layout.set").length !== 1) fail(`first visit: expected one layout.set, got ${calls("layout.set").length}`);
show(d, "s2");
if (stack().active !== "desk-t8") fail(`s2 shows ${stack().active}`);
show(d, "s3"); // no desk
if (stack().active !== "empty") fail(`s3 shows ${stack().active}`);
globalThis.herdr.calls = [];
const before = JSON.stringify(stack().children);
show(d, "s1");
if (stack().active !== "desk-t7") fail(`back on s1 shows ${stack().active}`);
show(d, "s2");
if (stack().active !== "desk-t8") fail(`back on s2 shows ${stack().active}`);
if (calls("layout.set").length) fail("switching to a space whose desk has a block must not set the layout");
if (JSON.stringify(stack().children) !== before) fail("a desk block was repointed or replaced");
check("switching");
EOF
}

@test "readConfig reads [layout] focus_follows_mouse and auto_review as bercail's TOML reader does" {
  local f cli="" js follow auto
  # shellcheck source=/dev/null
  source "$ROOT/lib/toml.sh"
  # Each fixture as written (LF) and with CRLF line ends: lib/toml.sh reads both alike.
  export FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIXTURES"
  for f in "$ROOT"/tests/fixtures/focus-follows-mouse/*.toml; do
    cp "$f" "$FIXTURES/"
    sed 's/$/\r/' "$f" >"$FIXTURES/crlf-$(basename "$f")"
  done
  for f in "$FIXTURES"/*.toml; do
    follow=false
    [[ "$(toml_get "$f" layout focus_follows_mouse 2>/dev/null)" != true ]] || follow=true
    auto="$(toml_value "$f" layout auto_review true)"
    cli+="$(basename "$f") $follow $auto"$'\n'
  done
  js="$(mod_case <<'EOF'
import { readdirSync } from "node:fs";
const dir = process.env.FIXTURES;
for (const f of readdirSync(dir).filter((n) => n.endsWith(".toml")).sort()) {
  const cfg = readConfig(readFileSync(`${dir}/${f}`, "utf8"));
  console.log(`${f} ${cfg.follow} ${cfg.autoReview}`);
}
EOF
)"
  [[ "$js"$'\n' == "$cli" ]] || fail "the desk and lib/toml.sh disagree:"$'\n'"$(diff <(printf '%s' "$cli") <(printf '%s\n' "$js"))"
}

@test "focus follows the mouse into the desk's block: on entering it, or on a move there while a pane has the keyboard" {
  mod_case <<'EOF'
let active = true;
globalThis.window = { is_window_active: () => active };
const on = "[layout]\nfocus_follows_mouse = true\n";

const desk = D("t7", "s1");
d = setup({ terminals: [desk] });
show(d, "s1");
d.cfg = readConfig(on);
// The header block's bounds, as Herdr reports them with every pointer move in the window.
const head = { x: 280, y: 50, width: 340, height: 32 };
const move = (x, y, extra = {}) => {
  globalThis.herdr.calls = [];
  d.followDesk({ position: { x, y }, bounds: head, ...extra }, desk);
  return calls("pane.focus").map(([, a]) => a.terminal).join(" ") || "none";
};
globalThis.herdr.focused = { space: "s1", pane: "p1", terminal: "t1" };
expect(move(400, 400), "t7", "entering the desk's block");
globalThis.herdr.focused = { space: "s1", pane: null, terminal: "t7" };
expect(move(410, 410), "none", "a move within it, the desk focused");
globalThis.herdr.focused = { space: "s1", pane: "p1", terminal: "t1" };
expect(move(420, 420), "t7", "a move within it while a pane has the keyboard");
expect(move(420, 420), "none", "a still pointer");
// A mod that takes the keyboard leaves Herdr reporting the desk focused: entering takes it back.
expect(move(900, 420), "none", "out of the column");
globalThis.herdr.focused = { space: "s1", pane: null, terminal: "t7" };
expect(move(430, 430), "t7", "entering while Herdr reports the desk focused");
globalThis.herdr.focused = { space: "s1", pane: "p1", terminal: "t1" };
expect(move(400, 60), "none", "the header itself");
expect(move(900, 400), "none", "beside the column");
expect(move(400, 450, { pressed_button: "left" }), "none", "a drag");
active = false;
expect(move(400, 500), "none", "another app active");
active = true;
expect(move(900, 410), "none", "out");
d.cfg = readConfig("");
expect(move(400, 410), "none", "switched off");
d.cfg = readConfig(on);
stack().active = "empty";
expect(move(900, 420), "none", "out again");
expect(move(400, 420), "none", "the stack not showing the desk");
EOF
}

@test "a new desk block is set already shown" {
  mod_case <<'EOF'
// A layout.set carries the shown child, so the file never says empty beside a live desk.
d = setup({ terminals: [D("t7", "s1")] });
show(d, "s3");
globalThis.herdr.calls = [];
show(d, "s1", 1);
const [[, set]] = calls("layout.set");
if (find(set.layout, "agent-stack").active !== "desk-t7") fail("layout.set sent with a stale active child");
check("first show");
EOF
}

@test "an older layout's shared agent block is replaced by per-desk blocks" {
  mod_case <<'EOF'
// An older layout's shared block goes; the desk gets its own.
d = setup({ terminals: [D("t7", "s1")], legacy: true });
show(d, "s1");
if (ids().includes("agent")) fail("the shared agent block was kept");
if (stack().active !== "desk-t7") fail(`legacy layout shows ${stack().active}`);
check("legacy");
EOF
}

@test "a block the app keeps dropping is not re-set every render" {
  mod_case <<'EOF'
// The app drops a live desk's block: not re-added every render, the placeholder shows.
d = setup({ terminals: [D("t7", "s1")] });
show(d, "s1");
stack().children = stack().children.filter((c) => c.id !== "desk-t7");
globalThis.herdr.calls = [];
show(d, "s1");
if (calls("layout.set").length) fail("re-set the layout in a loop for the same desk");
if (stack().active !== "empty") fail("placeholder not shown for a dropped block");
check("dropped");
EOF
}

@test "a desk block whose layout.set did not land is sent again by the header's own wake-up" {
  mod_case <<'EOF'
// One render, its add lost, and nothing else happens: the timer it armed brings it back.
let now = 1_000_000;
Date.now = () => now;
const timers = [];
const cx = { timer: { after: (ms, fn) => timers.push({ ms, fn }) }, notify: () => d.render(cx) };
d = setup({ terminals: [D("t7", "s1")] });
globalThis.herdr.lose = 1;
d.render(cx);
expect(calls("layout.set").length, 1, "layout.sets on the first render");
expect(stack().active, "empty", "shown while the add is lost");
expect(timers.length, 1, "wake-ups armed");
now += timers[0].ms;
timers.shift().fn(cx);
expect(calls("layout.set").length, 2, "layout.sets after the wake-up");
expect(stack().active, "desk-t7", "shown after the wake-up");
// The render that sent it again checks once more, then stops.
now += timers[0].ms;
timers.shift().fn(cx);
expect(calls("layout.set").length, 2, "layout.sets once it landed");
expect(timers.length, 0, "wake-ups armed once it landed");
check("lost add");
EOF
}

@test "a column change the app keeps losing is sent once per pause, then lands" {
  mod_case <<'EOF'
// A gone block and a new desk, every layout.set lost: renders don't each rewrite the layout.
let now = 1_000_000;
Date.now = () => now;
d = setup({ terminals: [D("t7", "s1")] });
stack().children.push({ id: "desk-t40p", type: "block", content: { terminal: "t40p" } });
globalThis.herdr.lose = 100;
show(d, "s1", 20);
expect(calls("layout.set").length, 1, "layout.sets in 20 renders at one time");
now += 5000;
show(d, "s1", 20);
expect(calls("layout.set").length, 2, "layout.sets after the pause");
globalThis.herdr.lose = 0;
now += 5000;
show(d, "s1", 20);
expect(calls("layout.set").length, 3, "layout.sets once they land");
expect(ids().join(" "), "empty desk-t7", "blocks once they land");
expect(stack().active, "desk-t7", "shown");
check("kept losing");
EOF
}

@test "blocks of desks gone from the core are pruned, but not before the core lists terminals" {
  mod_case <<'EOF'
const gone = (t) => ({ id: `desk-${t}`, type: "block", content: { terminal: t }, padding: [6, 6] });
d = setup({ terminals: [] });
stack().children.push(gone("t40p"), gone("t3yz"));
show(d, "s1");
expect(ids().join(" "), "empty desk-t40p desk-t3yz", "blocks while the core has listed nothing");
globalThis.herdr.terminals = [D("t7", "s1")];
show(d, "s1");
expect(ids().join(" "), "empty desk-t7", "blocks once the core lists terminals");
expect(stack().active, "desk-t7", "shown");
check("gone");
EOF
}

@test "Start the agent in a space whose desk is running starts no second desk" {
  mod_case <<'EOF'
const ran = [];
d = setup({ terminals: [{ address: "t-sh", state: "live", labels: {} }, D("t7", "s1")] });
Object.assign(globalThis.herdr, {
  spaces: [{ id: "s1", tabs: [{ id: "tab1", named: true }], folder: "/w" }],
  panes: [{ pane: "p1", tab: "tab1", terminal: "t-sh", cwd: "/w" }],
  exec: (cmd, args) => { ran.push([cmd, ...args]); return { code: 0, stdout: "{}", stderr: "" }; },
  notes: [],
});
d.starting = {};
await d.start(globalThis.herdr.spaces[0]);
if (ran.some(([c]) => c === "hc")) fail(`started a second desk: ${JSON.stringify(ran)}`);
if (!globalThis.herdr.notes[0]?.body.includes("t7")) fail(`the person is not told which desk runs: ${JSON.stringify(globalThis.herdr.notes)}`);
EOF
}

@test "a finished desk's block goes and its space shows the placeholder" {
  mod_case <<'EOF'
// A finished desk's block is removed; a desk-less space selects only the placeholder.
d = setup({ terminals: [D("t7", "s1"), D("t8", "s2")] });
show(d, "s1"); show(d, "s2");
globalThis.herdr.terminals = [D("t7", "s1", "finished"), D("t8", "s2")];
show(d, "s1");
if (ids().includes("desk-t7")) fail("a finished desk's block was kept");
if (stack().active !== "empty" || !ids().includes("desk-t8")) fail(`after t7 ended: ${stack().active} ${ids()}`);
check("finished");
EOF
}

@test "spaces are ordered and nested like the sidebar" {
  mod_case --sidebar <<'EOF'
expect(order.map((r) => (r.parent ? `${r.parent}>${r.id}` : r.id)).join(" "),
  "ll ll>ll-wt1 ll>ll-wt2 home b b>b-wt orphan-wt ll-2 far", "sidebar order");
EOF
}

@test "space next/prev walk top-level spaces only, wrapping" {
  mod_case --sidebar <<'EOF'
expect(steps(stepSpace, "ll", 1), "home b orphan-wt ll-2 far ll", "space next");
expect(steps(stepSpace, "ll", -1), "far ll-2 orphan-wt b home ll", "space prev");
expect(stepSpace(order, "ll-wt2", 1), "home", "space next from a worktree goes past its repo");
expect(stepSpace(order, "b-wt", -1), "home", "space prev from a worktree");
expect(stepSpace(order, "gone", 1), "ll", "space next from an unknown space");
EOF
}

@test "subspace next/prev walk the current repo's checkouts, wrapping" {
  mod_case --sidebar <<'EOF'
expect(steps(stepSubspace, "ll", 1), "ll-wt1 ll-wt2 ll-2 ll ll-wt1 ll-wt2", "subspace next");
expect(steps(stepSubspace, "ll-wt1", -1), "ll ll-2 ll-wt2 ll-wt1 ll ll-2", "subspace prev");
expect(stepSubspace(order, "b-wt", 1), "b", "subspace wraps within its repo");
expect(String(stepSubspace(order, "home", 1)), "null", "no subspace outside a repo");
expect(String(stepSubspace(order, "orphan-wt", 1)), "null", "a lone worktree has no subspace");
expect(String(stepSubspace(order, "far", 1)), "null", "another machine's checkout is another repo");
EOF
}

@test "agent next/prev walk agents in sidebar space order, wrapping" {
  mod_case --sidebar <<'EOF'
expect(agentWalk("d-ll", 1), "a-wt2 d-b a-b a-far d-ll a-wt2", "agent next");
expect(agentWalk("d-ll", -1), "a-far a-b d-b a-wt2 d-ll a-far", "agent prev");
expect(stepAgent(order, ags, "t-shell", "b", 1).address, "d-b", "agent next from a shell: its space's first");
expect(stepAgent(order, ags, "t-shell", "b", -1).address, "a-b", "agent prev from a shell: its space's last");
expect(stepAgent(order, ags, "t-shell", "home", 1).address, "d-b", "agent next from a space without agents");
expect(stepAgent(order, ags, "t-shell", "home", -1).address, "a-wt2", "agent prev from a space without agents");
EOF
}

@test "the space, subspace and agent commands select and focus as the keys expect" {
  mod_case <<'EOF'
// The commands: git decides the grouping; a desk is focused in its space's agent block.
{
  const repoOf = { "/w/ll": ["/w/ll", "/w/ll/.git"], "/w/ll.wt": ["/w/ll.wt", "/w/ll/.git"], "/w/b": ["/w/b", "/w/b/.git"] };
  let gitCalls = 0;
  globalThis.herdr = {
    layout: structuredClone(shipped),
    calls: [],
    focused: { space: "s-ll", pane: "p1", terminal: "t-shell" },
    spaces: [
      { id: "s-ll", tabs: [{ id: "tab1" }], folder: "/w/ll" },
      { id: "s-b", tabs: [], folder: "/w/b" },
      { id: "s-wt", tabs: [], folder: "/w/ll.wt" },
    ],
    panes: [{ pane: "p1", tab: "tab1", terminal: "t-shell", cwd: "/w/ll" }],
    terminals: [{ address: "t-desk-b", state: "live", labels: { "bercail.role": "agent", "bercail.space": "s-b" } }],
    agents: [{ address: "t-agent-wt", space: "s-wt" }],
    exec: (cmd, _args, { cwd }) => {
      if (cmd !== "git") return { code: 1, stdout: "", stderr: "" };
      gitCalls++;
      const r = repoOf[cwd];
      return r ? { code: 0, stdout: `${r.join("\n")}\n`, stderr: "" } : { code: 128, stdout: "", stderr: "not a git repository" };
    },
  };
  const d = new Desk();
  Object.assign(d, { cfg: { autoReview: false }, prev: {}, pendingReview: {}, lastAuto: {}, starting: {}, git: {}, hadDesk: new Set() });
  const ran = async (cmd) => {
    globalThis.herdr.calls = [];
    await d.command(cmd);
    // Selecting a space shows it: what space.select would do in the app.
    for (const [n, a] of globalThis.herdr.calls) if (n === "space.select") globalThis.herdr.focused = { space: a.id };
    return JSON.stringify(globalThis.herdr.calls.filter(([n]) => !n.startsWith("layout.")));
  };
  expect(await ran("space-next"), '[["space.select",{"id":"s-b"}]]', "space-next command (the worktree is nested)");
  globalThis.herdr.focused = { space: "s-ll", pane: "p1", terminal: "t-shell" };
  expect(await ran("subspace-next"), '[["space.select",{"id":"s-wt"}]]', "subspace-next command");
  expect(await ran("subspace-next"), '[["space.select",{"id":"s-ll"}]]', "subspace-next command wraps");
  if (gitCalls !== 3) fail(`git asked ${gitCalls} times, want once per folder within 10s`);
  // From the shell in s-ll (no agents): the sidebar puts s-wt next, then s-b's desk.
  globalThis.herdr.focused = { space: "s-ll", pane: "p1", terminal: "t-shell" };
  expect(await ran("agent-next"), '[["agent.focus",{"terminal":"t-agent-wt"}]]', "agent-next to a pane agent");
  globalThis.herdr.focused = { space: "s-wt", pane: "p9", terminal: "t-agent-wt" };
  expect(await ran("agent-next"), '[["space.select",{"id":"s-b"}],["pane.focus",{"terminal":"t-desk-b"}]]', "agent-next to a desk");
  if (find(globalThis.herdr.layout, "agent-stack").active !== "desk-t-desk-b") fail("the agent column must show the desk it focuses");
}
EOF
}

@test "the shipped layout has a panel stack holding panel-body" {
  mod_case <<'EOF'
// The panel: Herdr's tab bar finds a "panel" node holding the "panel-body" stack.
// A stack: Herdr has saved the layout without the one-child panel column it had.
{
  const panel = find(shipped, "panel");
  if (panel?.type !== "stack") fail("the shipped layout has no panel stack");
  if (JSON.stringify(panel.children.map((c) => c.id)) !== '["panel-body"]' || panel.active !== "panel-body") fail("the panel stack must show panel-body");
  if (find(panel, "panel-body")?.type !== "stack") fail("panel-body is not inside the panel stack");
  if (JSON.stringify(find(panel, "panel-body").children.map((c) => c.id)) !== '["files","changes"]') fail("panel-body must hold files and changes");
  if (find(shipped, "work-body").children.at(-1).id !== "panel") fail("the panel must be work-body's last child");
  if (panel.min !== 280 || panel.max !== 900) fail(`panel min/max ${panel.min}/${panel.max}, want 280/900`);
  if (!(panel.size?.px >= panel.min)) fail(`panel width ${panel.size?.px} is under its min ${panel.min}`);
}
EOF
}

@test "the panel keys and the tab bar's buttons open, switch and close one panel" {
  mod_case <<'EOF'
{
  const d = setup({ terminals: [] });
  const before = JSON.stringify(globalThis.herdr.layout);
  show(d, "s1");
  if (calls("layout.set").length || JSON.stringify(globalThis.herdr.layout) !== before) fail("an intact layout must be left as it is");
  await panelSteps(d);
}
EOF
}

@test "a saved layout that lost its panel gets it back, and Files/Changes work on it" {
  mod_case <<'EOF'
for (const [body, want] of [
  [{ size: { px: 24 } }, { px: 280, hidden: undefined }], // as after the 2026-11-02 reboot: under the min
  [{ size: { px: 420 }, hidden: true }, { px: 420, hidden: true }],
]) {
  const d = setup({ terminals: [] });
  collapsePanel(globalThis.herdr.layout, body);
  show(d, "s1");
  const panel = find(globalThis.herdr.layout, "panel");
  if (panel?.type !== "stack" || panel.active !== "panel-body") fail(`no panel stack after the repair: ${JSON.stringify(panel)}`);
  const inner = find(panel, "panel-body");
  if (inner.size || inner.hidden) fail("the panel, not panel-body, must hold the width and visibility");
  if (panel.size.px !== want.px || panel.min !== 280 || panel.max !== 900) fail(`panel ${JSON.stringify(panel)}, want ${want.px}px, min 280, max 900`);
  if (panel.hidden !== want.hidden) fail(`panel hidden ${panel.hidden}, want ${want.hidden}`);
  if (calls("layout.set").length !== 1) fail(`the repair must be saved once, not ${calls("layout.set").length} times`);
  // The app reloads the saved file: nothing is left to repair.
  globalThis.herdr.layout = JSON.parse(JSON.stringify(globalThis.herdr.layout));
  show(d, "s1");
  if (calls("layout.set").length !== 1) fail("a repaired layout must not be repaired again");
  await panelSteps(d);
}
EOF
}

@test "repairing the panel keeps the desk shown" {
  mod_case <<'EOF'
// The repair lands on the same render as a new desk block, or before selecting a
// desk already in the layout: either way the desk shows.
{
  d = setup({ terminals: [D("t7", "s1"), D("t8", "s2")] });
  collapsePanel(globalThis.herdr.layout, { size: { px: 24 } });
  show(d, "s1");
  const shown = () => `panel ${Boolean(find(globalThis.herdr.layout, "panel"))}, shown ${stack().active}`;
  if (!find(globalThis.herdr.layout, "panel") || stack().active !== "desk-t7") fail(`new desk: ${shown()}`);
  show(d, "s2");
  collapsePanel(globalThis.herdr.layout, { size: { px: 24 } });
  show(d, "s1", 1); // on the render that repairs, not a later one
  if (!find(globalThis.herdr.layout, "panel") || stack().active !== "desk-t7") fail(`known desk: ${shown()}`);
  check("desk");
}
EOF
}

@test "a shown space gets its desk once, under its Shell (no tab of its own); a quit desk stays quit; enabled is not a gate" {
  mod_case <<'EOF'
// A space shown without a desk starts one, under its Shell, once. readConfig
// does not return bstack, and enabled = false does not stop the start.
{
  const ran = [];
  globalThis.herdr = {
    layout: structuredClone(shipped), calls: [],
    focused: { space: "s1", pane: "p1" },
    spaces: [{ id: "s1", tabs: [{ id: "tab1", named: true }], folder: "/w" }, { id: "s2", tabs: [{ id: "tab2" }], folder: "/w2" }],
    panes: [{ pane: "p1", tab: "tab1", terminal: "t-sh", cwd: "/w/sub" }],
    terminals: [],
    exec: (cmd, args) => { ran.push([cmd, ...args]); return { code: 0, stdout: "{}", stderr: "" }; },
  };
  // The file the bash reader's tests read: same answers from the mod's reader.
  const hard = readConfig(readFileSync(process.env.ROOT + "/tests/fixtures/config-hard.toml", "utf8"));
  if (hard.review !== "hunk diff" || hard.autoReview !== false) fail(`the shared fixture: ${JSON.stringify(hard)}`);
  const parsed = readConfig("[bstack]\nenabled = true # on\n");
  if ("bstack" in parsed || "bstack" in readConfig("[bstack]\nenabled = false\n") || "bstack" in readConfig("")) {
    fail("readConfig does not return bstack");
  }
  const d = new Desk();
  Object.assign(d, { cfg: { ...parsed, autoReview: false },
    prev: {}, pendingReview: {}, lastAuto: {}, starting: {}, hadDesk: new Set() });
  const starts = () => ran.filter(([c]) => c === "hc");
  const settle = () => new Promise((r) => setImmediate(r));
  show(d, "s1");
  await settle();
  if (starts().length) fail("started a desk before the core listed the space's Shell");
  globalThis.herdr.terminals = [{ address: "t-sh", state: "live", labels: {} }];
  show(d, "s1");
  await settle();
  expect(JSON.stringify(starts()), JSON.stringify([["hc", "run", "--bg", "--json", "--keep", "--outlive-parent", "--no-notify",
    "--parent", "t-sh", "--cwd", "/w/sub", "--label", "bercail.role=agent", "--label", "bercail.space=s1",
    "/nonexistent/.local/bin/bercail-desk-agent"]]), "auto-start in the shown space");
  show(d, "s1");
  await settle();
  if (starts().length !== 1) fail("auto-start ran again before the desk showed up");
  // The desk comes up as the Shell's sub-agent, with no pane or tab; then the person quits it.
  globalThis.herdr.terminals.push({ ...D("t-desk", "s1"), parent: "t-sh" });
  globalThis.herdr.calls = [];
  show(d, "s1", 1);
  if (calls("tab.rename").length) fail(`no tab is renamed for the desk: ${JSON.stringify(calls("tab.rename"))}`);
  expect(stack().active, "desk-t-desk", "the desk shows in its block");
  globalThis.herdr.terminals = [{ address: "t-sh", state: "live", labels: {} }, D("t-desk", "s1", "finished")];
  show(d, "s1");
  await settle();
  if (starts().length !== 1) fail("a desk the person quit must not come back on its own");
  await d.command("agent");
  if (starts().length !== 2) fail("Ctrl+Shift+A starts the desk again");
  // A space whose core terminals aren't known (s2, no live Shell): nothing yet.
  show(d, "s2");
  await settle();
  if (starts().length !== 2) fail("s2 has no live Shell yet");
  // enabled = false is not a gate: clearing hadDesk starts again.
  d.cfg = { ...readConfig("[bstack]\nenabled = false\n"), autoReview: false, bstack: false };
  d.hadDesk.clear();
  show(d, "s1");
  await settle();
  if (starts().length !== 3) fail("enabled = false must not stop auto-start");
  // Ctrl+Shift+A in a space with no Shell: a warning, no desk.
  globalThis.herdr.spaces.push({ id: "s3", tabs: [], folder: "/w3" });
  globalThis.herdr.focused = { space: "s3", pane: null };
  globalThis.herdr.notes = [];
  await d.command("agent");
  if (starts().length !== 3) fail("a space with no Shell must not start a desk");
  if (globalThis.herdr.notes[0]?.level !== "warning") fail("no Shell: the person is told why");
}
EOF
}

@test "every mod reads [herdr] backend and names ids across machines the same way" {
  # The mods can't share a file: each has its own copy of these. They must not drift.
  local name mod src
  for name in backendOf machineOf qualify strip; do
    src=""
    for mod in "$ROOT"/bercail/mods/bercail-*/main.js; do
      local def
      # A function ends at its closing brace, a const at its first line's semicolon.
      def="$(awk -v n="$name" '$0 ~ "^export (function|const) " n "[ (=]" { on = /^export function/ ? "fn" : "const" }
        on { print } on == "fn" && /^}/ { exit } on == "const" && /;$/ { exit }' "$mod")"
      [[ -n "$def" ]] || continue
      [[ -z "$src" || "$def" == "$src" ]] || fail "$name in $mod differs from the other mods' copy"
      src="$def"
    done
    [[ -n "$src" ]] || fail "no mod defines $name"
  done
  mod_case <<'EOF'
import { backendOf, machineOf, qualify, strip } from "./main.mjs";
const cases = [
  ["", null], ['[herdr]\nbackend = "box"\n', "box"], ['[herdr]\nbackend = ""\n', null],
  ['[layout]\nbackend = "box"\n', null], ['[herdr]\n# backend = "box"\n', null],
  ['[herdr] # where bercail runs\nbackend = "box" # a Herdr machine\n', "box"],
  [readFileSync(process.env.ROOT + "/docs/config.md", "utf8").match(/```toml\n([\s\S]*?)```/)[1], null],
];
for (const [text, want] of cases) expect(backendOf(text), want, `backendOf ${JSON.stringify(text.slice(0, 40))}`);
expect(backendOf(null), null, "no config file");
expect(machineOf("box/t3"), "box", "a terminal on box");
expect(machineOf("t3"), null, "a terminal here");
expect(qualify("sp1", "box"), "box/sp1", "box's label, here");
expect(qualify("sp1", null), "sp1", "a label here stays");
expect(strip("box/sp1", "box"), "sp1", "written back on box");
expect(strip("vps/sp1", "box"), "vps/sp1", "only box's prefix goes");
expect(strip("sp1", null), "sp1", "here, nothing to strip");
EOF
}

@test "a desk on another machine shows in its space's column there" {
  mod_case <<'EOF'
// box/t5's bercail.space=sp1 is written on box: its space here is box/sp1.
d = setup({ terminals: [D("box/t5", "sp1")] });
globalThis.herdr.spaces.push({ id: "box/sp1", machine: "box", tabs: [], folder: "/w" });
show(d, "box/sp1");
expect(stack().active, "desk-box/t5", "box's desk in its space");
show(d, "s1");
expect(stack().active, "empty", "no desk in s1");
check("remote desk");
EOF
}

@test "Start the agent in a space on another machine starts it there, with that machine's ids" {
  mod_case <<'EOF'
// hc run --on box: its parent and bercail.space are box's own ids (t1, sp1), and the
// wrapper is looked for in box's home, never this computer's.
const ran = [];
globalThis.herdr = {
  layout: structuredClone(shipped), calls: [],
  focused: { space: "box/sp1", pane: "box/p1" },
  spaces: [{ id: "box/sp1", machine: "box", tabs: [{ id: "box/tab1", named: true }], folder: "/w" }],
  panes: [{ pane: "box/p1", tab: "box/tab1", terminal: "box/t1", cwd: "/w/sub" }],
  terminals: [{ address: "box/t1", state: "live", labels: {} }],
  exec: (cmd, args, opts) => { ran.push([cmd, ...args, opts?.on ?? null]); return { code: 0, stdout: "{}", stderr: "" }; },
};
d = new Desk();
Object.assign(d, { cfg: { autoReview: false }, prev: {}, pendingReview: {}, lastAuto: {}, starting: {}, hadDesk: new Set() });
show(d, "box/sp1");
await new Promise((r) => setImmediate(r));
if (ran.some(([c]) => c === "hc")) fail("a space on another machine does not start its desk on its own");
await d.command("agent");
expect(JSON.stringify(ran.find(([c]) => c === "bash")), JSON.stringify(["bash", "-lc", 'test -x "$HOME/.local/bin/bercail-desk-agent"', "box"]), "the wrapper, on box");
expect(JSON.stringify(ran.filter(([c]) => c === "hc")), JSON.stringify([["hc", "run", "--bg", "--json", "--keep", "--outlive-parent", "--no-notify",
  "--on", "box", "--parent", "t1", "--cwd", "/w/sub", "--label", "bercail.role=agent", "--label", "bercail.space=sp1",
  "bash", "-lc", 'exec "$HOME/.local/bin/bercail-desk-agent"', null]]), "Ctrl+Shift+A on box");
if (ran.some((r) => r.join(" ").includes("/nonexistent"))) fail(`this computer's home went to box: ${JSON.stringify(ran)}`);
EOF
}

@test "Review in a space on another machine: git and gh ask that machine, and a desk finishing there opens it" {
  mod_case <<'EOF'
// The desk box/t5 (bercail.space=sp1) finishes with changes: Review opens in box/sp1,
// after git status and gh run on box, in the desk's folder there.
const ran = [];
globalThis.herdr = {
  layout: structuredClone(shipped), calls: [],
  focused: { space: "box/sp1", pane: "box/p1" },
  spaces: [{ id: "box/sp1", machine: "box", tabs: [{ id: "box/tab1", named: true }], folder: "/w" }],
  panes: [{ pane: "box/p1", tab: "box/tab1", terminal: "box/t1", cwd: "/w" }],
  terminals: [{ ...D("box/t5", "sp1"), status: "working", cwd: "/w/job" }],
  exec: (cmd, args, opts) => {
    ran.push([cmd, args[0], opts?.cwd, opts?.on ?? null]);
    return cmd === "git" ? { code: 0, stdout: " M a.txt\n", stderr: "" } : { code: 1, stdout: "", stderr: "" };
  },
};
d = new Desk();
Object.assign(d, { cfg: { review: "tuicr", autoReview: true }, prev: {}, pendingReview: {}, lastAuto: {}, starting: {}, hadDesk: new Set(["box/sp1"]) });
show(d, "box/sp1", 1);
globalThis.herdr.terminals[0].status = "done";
show(d, "box/sp1", 1);
for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
expect(JSON.stringify(ran), JSON.stringify([["git", "status", "/w/job", "box"], ["gh", "pr", "/w/job", "box"]]), "asked on box");
expect(JSON.stringify(calls("tab.new")), JSON.stringify([["tab.new", { space: "box/sp1", name: "Review", folder: "/w/job",
  argv: ["tuicr", "-w", "--no-update-check"] }]]), "Review opened in box/sp1");
EOF
}

@test "the notifier and the routine loop are each kept running once, here or on the backend" {
  mod_case <<'EOF'
// Without a backend, one of each starts here, as bercail.role=notify and =routines,
// and none while one is live here. With [herdr] backend = "box", bercail is looked for on
// box, a terminal on this computer does not count, and the ones started are box's.
const ran = [];
const start = async (terminals, config = '[layout]\nreview = "tuicr"\n') => {
  ran.length = 0;
  globalThis.herdr = {
    layout: structuredClone(shipped), calls: [], spaces: [], focused: null, terminals,
    props: { role: "header" },
    files: { "/nonexistent/.config/bercail/config.toml": config },
    exec: (cmd, args, opts) => { ran.push([cmd, ...args, opts?.on ?? null]); return { code: 0, stdout: "", stderr: "" }; },
  };
  const d = new Desk();
  const cx = { spawn: (f) => f(cx), notify: () => {}, timer: { every: () => {} } };
  d.init({}, cx);
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
};
const started = () => ran.filter(([c]) => c === "hc").map((a) => ({
  name: a[a.indexOf("--name") + 1], label: a[a.indexOf("--label") + 1],
  on: a.includes("--on") ? a[a.indexOf("--on") + 1] : null, run: a.at(-2) }));
const live = (machine) => ["bercail-notify", "bercail-routines"].map((name, i) =>
  ({ address: `${machine ? machine + "/" : ""}t${8 + i}`, name, state: "live" }));
const box = '[layout]\nreview = "tuicr"\n\n[herdr]\nbackend = "box"\n';

await start([]);
expect(JSON.stringify(started().map(({ name, label, on }) => [name, label, on])),
  JSON.stringify([["bercail-notify", "bercail.role=notify", null], ["bercail-routines", "bercail.role=routines", null]]), "one of each, here");
if (!started()[1].run.endsWith("; exec bercail routine loop")) fail(`the loop's command: ${started()[1].run}`);
await start(live(null));
if (started().length) fail(`both are live: ${JSON.stringify(ran)}`);
// Without a backend, another machine's do not count.
await start(live("box"));
expect(JSON.stringify(started().map(({ name, on }) => [name, on])),
  JSON.stringify([["bercail-notify", null], ["bercail-routines", null]]), "box's do not count here");

await start(live(null), box);
expect(ran[0]?.at(-1), "box", "bercail is looked for on box");
expect(JSON.stringify(started().map(({ name, on }) => [name, on])),
  JSON.stringify([["bercail-notify", "box"], ["bercail-routines", "box"]]), "both start on box");
await start(live("box"), box);
if (started().length) fail(`box's are live: ${JSON.stringify(ran)}`);
EOF
}

@test "in the Shep view the desk keys go to bercail-shep; a command for a named terminal acts in place" {
  mod_case <<'EOF'
// The `keys` copy (in the Shep column, shown only in the Shep view) sends each key to
// bercail-shep to replay in the space view; a command for a named terminal's space acts
// at once, without a view change.
d = setup({ terminals: [D("t5", "s2")] });
globalThis.herdr.spaces[1].tabs = [{ id: "tab-r", name: "Review" }];
globalThis.herdr.props = { role: "keys" };
globalThis.herdr.keys = ["space-next", "agent-prev", "close-review:t5"];
globalThis.herdr.exec = (cmd, args) => { (globalThis.herdr.execs ??= []).push([cmd, ...args]); return { code: 0, stdout: "", stderr: "" }; };
const cx = { spawn: (f) => f(cx), notify: () => {}, timer: { every: () => {} } };
d.init({}, cx);
for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
const sent = globalThis.herdr.calls.map(([n, a]) => (a ? `${n} ${JSON.stringify(a)}` : n));
const want = ["bercail-shep.desk:space-next", "bercail-shep.desk:agent-prev", 'tab.close {"id":"tab-r"}'];
if (JSON.stringify(sent) !== JSON.stringify(want)) fail(`keys copy ran ${JSON.stringify(sent)}`);
if (globalThis.herdr.execs?.length) fail("the keys copy must not start the desk follower");
EOF
}
