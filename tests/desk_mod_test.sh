#!/usr/bin/env bash
# shellcheck shell=bash
# The bercail-desk mod's sync() against stubbed herdr and gpui modules.
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
export const layout = () => structuredClone(h().layout);
export const run = (name, args) => {
  h().calls.push([name, args]);
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
export const props = () => ({});
export const shared = () => null;
export const setShared = () => {};
export const home = () => "/nonexistent";
export const exec = async (cmd, args, opts) => h().exec?.(cmd, args, opts) ?? { code: 1, stdout: "", stderr: "" };
export const knownAgents = async () => [];
export const nextCommand = () => new Promise(() => {});
export const readTextFile = async () => "";
EOF
printf 'export class View {}\nexport const div = () => ({});\n' >"$TMP_DIR/gpui-kit.mjs"
printf 'export const h_flex = () => ({});\nexport const v_flex = () => ({});\n' >"$TMP_DIR/gpui-base.mjs"
sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui-kit.mjs"|' \
  -e 's|from "gpui-base"|from "./gpui-base.mjs"|' "$ROOT/bercail/mods/bercail-desk/main.js" >"$TMP_DIR/main.mjs"
cp "$ROOT/bercail/layouts/bercail.json" "$TMP_DIR/layout.json"

cat >"$TMP_DIR/test.mjs" <<'EOF'
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

if (find(shipped, "agent")) fail("the shipped layout still has a shared agent block");

// Spaces with live desks: each gets its own block once; switching back only selects.
let d = setup({ terminals: [D("t7", "s1"), D("t8", "s2")] });
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
console.log("PASS: each desk keeps its own block; switching spaces only selects it");

// A layout.set carries the shown child, so the file never says empty beside a live desk.
d = setup({ terminals: [D("t7", "s1")] });
show(d, "s3");
globalThis.herdr.calls = [];
show(d, "s1", 1);
const [[, set]] = calls("layout.set");
if (find(set.layout, "agent-stack").active !== "desk-t7") fail("layout.set sent with a stale active child");
check("first show");
console.log("PASS: a new desk block is set already shown");

// An older layout's shared block goes; the desk gets its own.
d = setup({ terminals: [D("t7", "s1")], legacy: true });
show(d, "s1");
if (ids().includes("agent")) fail("the shared agent block was kept");
if (stack().active !== "desk-t7") fail(`legacy layout shows ${stack().active}`);
check("legacy");
console.log("PASS: an older layout's shared agent block is replaced by per-desk blocks");

// The app drops a live desk's block: not re-added every render, the placeholder shows.
d = setup({ terminals: [D("t7", "s1")] });
show(d, "s1");
stack().children = stack().children.filter((c) => c.id !== "desk-t7");
globalThis.herdr.calls = [];
show(d, "s1");
if (calls("layout.set").length) fail("re-set the layout in a loop for the same desk");
if (stack().active !== "empty") fail("placeholder not shown for a dropped block");
check("dropped");
console.log("PASS: a block the app keeps dropping is not re-set every render");

// A finished desk's block is removed; a desk-less space selects only the placeholder.
d = setup({ terminals: [D("t7", "s1"), D("t8", "s2")] });
show(d, "s1"); show(d, "s2");
globalThis.herdr.terminals = [D("t7", "s1", "finished"), D("t8", "s2")];
show(d, "s1");
if (ids().includes("desk-t7")) fail("a finished desk's block was kept");
if (stack().active !== "empty" || !ids().includes("desk-t8")) fail(`after t7 ended: ${stack().active} ${ids()}`);
check("finished");
console.log("PASS: a finished desk's block goes and its space shows the placeholder");

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
const expect = (got, want, what) => { if (got !== want) fail(`${what}: ${got}, want ${want}`); };
expect(order.map((r) => (r.parent ? `${r.parent}>${r.id}` : r.id)).join(" "),
  "ll ll>ll-wt1 ll>ll-wt2 home b b>b-wt orphan-wt ll-2 far", "sidebar order");
console.log("PASS: spaces are ordered and nested like the sidebar");

const steps = (fn, from, dir) => {
  const seen = [];
  let at = from;
  for (let i = 0; i < 6; i++) { at = fn(order, at, dir); seen.push(at); }
  return seen.join(" ");
};
expect(steps(stepSpace, "ll", 1), "home b orphan-wt ll-2 far ll", "space next");
expect(steps(stepSpace, "ll", -1), "far ll-2 orphan-wt b home ll", "space prev");
expect(stepSpace(order, "ll-wt2", 1), "home", "space next from a worktree goes past its repo");
expect(stepSpace(order, "b-wt", -1), "home", "space prev from a worktree");
expect(stepSpace(order, "gone", 1), "ll", "space next from an unknown space");
console.log("PASS: space next/prev walk top-level spaces only, wrapping");

expect(steps(stepSubspace, "ll", 1), "ll-wt1 ll-wt2 ll-2 ll ll-wt1 ll-wt2", "subspace next");
expect(steps(stepSubspace, "ll-wt1", -1), "ll ll-2 ll-wt2 ll-wt1 ll ll-2", "subspace prev");
expect(stepSubspace(order, "b-wt", 1), "b", "subspace wraps within its repo");
expect(String(stepSubspace(order, "home", 1)), "null", "no subspace outside a repo");
expect(String(stepSubspace(order, "orphan-wt", 1)), "null", "a lone worktree has no subspace");
expect(String(stepSubspace(order, "far", 1)), "null", "another machine's checkout is another repo");
console.log("PASS: subspace next/prev walk the current repo's checkouts, wrapping");

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
expect(agentWalk("d-ll", 1), "a-wt2 d-b a-b a-far d-ll a-wt2", "agent next");
expect(agentWalk("d-ll", -1), "a-far a-b d-b a-wt2 d-ll a-far", "agent prev");
expect(stepAgent(order, ags, "t-shell", "b", 1).address, "d-b", "agent next from a shell: its space's first");
expect(stepAgent(order, ags, "t-shell", "b", -1).address, "a-b", "agent prev from a shell: its space's last");
expect(stepAgent(order, ags, "t-shell", "home", 1).address, "d-b", "agent next from a space without agents");
expect(stepAgent(order, ags, "t-shell", "home", -1).address, "a-wt2", "agent prev from a space without agents");
console.log("PASS: agent next/prev walk agents in sidebar space order, wrapping");

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
  console.log("PASS: the space, subspace and agent commands select and focus as the keys expect");
}

// The panel: Herdr's tab bar finds a "panel" node holding the "panel-body" stack.
{
  const panel = find(shipped, "panel");
  if (panel?.type !== "column") fail("the shipped layout has no panel column");
  if (find(panel, "panel-body")?.type !== "stack") fail("panel-body is not inside the panel column");
  if (JSON.stringify(find(panel, "panel-body").children.map((c) => c.id)) !== '["files","changes"]') fail("panel-body must hold files and changes");
  if (find(shipped, "work-body").children.at(-1).id !== "panel") fail("the panel must be work-body's last child");
  if (!(panel.size?.px >= panel.min)) fail(`panel width ${panel.size?.px} is under its min ${panel.min}`);
  console.log("PASS: the shipped layout has a panel column holding panel-body");
}

// Ctrl+Shift+F/G and the tab bar's Files/Changes buttons share one panel state.
{
  globalThis.herdr = {
    layout: structuredClone(shipped), calls: [], toasts: [],
    focused: { space: "s1", pane: "p1" }, spaces: [{ id: "s1", tabs: [], folder: "/w" }], terminals: [],
  };
  const d = new Desk();
  Object.assign(d, { cfg: { autoReview: false }, prev: {}, pendingReview: {}, lastAuto: {}, hadDesk: new Set() });
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
  if (globalThis.herdr.toasts.length) fail(`toasts: ${globalThis.herdr.toasts}`);
  check("panel");
  if (calls("layout.show").concat(calls("layout.hide")).some(([, a]) => a.id !== "panel")) fail("keys must show and hide the panel column");
  console.log("PASS: the panel keys and the tab bar's buttons open, switch and close one panel");
}

// bstack on: a space shown without a desk starts one, under its Shell, once.
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
  const d = new Desk();
  Object.assign(d, { cfg: { ...readConfig('[bstack]\nenabled = true # on\n'), autoReview: false },
    prev: {}, pendingReview: {}, lastAuto: {}, starting: {}, hadDesk: new Set() });
  if (!d.cfg.bstack || readConfig("[bstack]\nenabled = false\n").bstack) fail("readConfig reads [bstack] enabled");
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
  // A space whose core terminals aren't known (s2, no live Shell): nothing yet. bstack off: never.
  show(d, "s2");
  await settle();
  if (starts().length !== 2) fail("s2 has no live Shell yet");
  d.cfg.bstack = false;
  d.hadDesk.clear();
  show(d, "s1");
  await settle();
  if (starts().length !== 2) fail("bstack off must not auto-start");
  // Ctrl+Shift+A in a space with no Shell: a warning, no desk.
  globalThis.herdr.spaces.push({ id: "s3", tabs: [], folder: "/w3" });
  globalThis.herdr.focused = { space: "s3", pane: null };
  globalThis.herdr.notes = [];
  await d.command("agent");
  if (starts().length !== 2) fail("a space with no Shell must not start a desk");
  if (globalThis.herdr.notes[0]?.level !== "warning") fail("no Shell: the person is told why");
  console.log("PASS: with bstack on, a shown space gets its desk once, under its Shell (no tab of its own); a quit desk stays quit");
}
EOF

node "$TMP_DIR/test.mjs"
