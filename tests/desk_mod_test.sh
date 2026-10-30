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
  if (name === "layout.select") {
    const find = (n) => n?.id === args.stack ? n : (n?.children ?? []).map(find).find(Boolean);
    const stack = find(h().layout);
    if (stack?.children?.some((c) => c.id === args.child)) stack.active = args.child;
  }
};
export const spaces = () => h().spaces;
export const focused = () => h().focused;
export const terminals = () => h().terminals;
export const panes = () => [];
export const agents = () => [];
export const notify = () => {};
export const theme = () => ({});
export const props = () => ({});
export const shared = () => null;
export const setShared = () => {};
export const home = () => "/nonexistent";
export const exec = async () => ({ code: 1, stdout: "", stderr: "" });
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
import Desk from "./main.mjs";

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
  Object.assign(d, { cfg: { autoReview: false }, prev: {}, pendingReview: {}, lastAuto: {} });
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
EOF

node "$TMP_DIR/test.mjs"
