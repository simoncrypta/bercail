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

function setup({ desk, lostAgent }) {
  const tree = structuredClone(shipped);
  const stack = find(tree, "agent-stack");
  if (lostAgent) {
    // What the app leaves after the space showing the desk is closed.
    stack.children = stack.children.filter((c) => c.id !== "agent");
    stack.active = "agent";
  }
  globalThis.herdr = {
    layout: tree,
    calls: [],
    focused: { space: "s1", pane: "p1" },
    spaces: [{ id: "s1", tabs: [], folder: "/w" }],
    terminals: desk ? [{ address: "t7", state: "live", labels: { "bercail.role": "agent", "bercail.space": "s1" } }] : [],
  };
  const d = new Desk();
  Object.assign(d, { cfg: { autoReview: false }, prev: {}, pendingReview: {}, lastAuto: {} });
  return d;
}
// A layout.select the app can't honor: the toast this test guards against.
function badSelects() {
  return globalThis.herdr.calls.filter(([n, a]) => n === "layout.select"
    && !find(globalThis.herdr.layout, a.stack)?.children?.some((c) => c.id === a.child));
}

// Lost agent block, desk running: put back, pointed at the desk, shown, once.
let d = setup({ desk: true, lostAgent: true });
for (let i = 0; i < 3; i++) d.sync();
let block = find(globalThis.herdr.layout, "agent");
if (!block) fail("the agent block was not restored");
if (block.content?.terminal !== "t7") fail(`restored block points at ${JSON.stringify(block.content)}`);
if (JSON.stringify(block.padding) !== "[6,6]") fail(`restored block padding ${JSON.stringify(block.padding)}`);
if (find(globalThis.herdr.layout, "agent-stack").active !== "agent") fail("restored block is not shown");
if (badSelects().length) fail(`selected a missing child: ${JSON.stringify(badSelects())}`);
const sets = globalThis.herdr.calls.filter(([n]) => n === "layout.set").length;
if (sets !== 1) fail(`expected one layout.set, got ${sets}`);
console.log("PASS: a lost agent block is restored for the desk on the next render");

// The app drops it again for the same desk: no layout.set loop, no bad select.
d = setup({ desk: true, lostAgent: true });
d.sync();
const again = find(globalThis.herdr.layout, "agent-stack");
again.children = again.children.filter((c) => c.id !== "agent");
globalThis.herdr.calls = [];
d.sync(); d.sync();
if (globalThis.herdr.calls.some(([n]) => n === "layout.set")) fail("re-set the layout in a loop for the same desk");
if (badSelects().length) fail(`selected a missing child: ${JSON.stringify(badSelects())}`);
console.log("PASS: a block the app keeps dropping is not re-set every render");

// Lost agent block, no desk: show the placeholder, never select "agent".
d = setup({ desk: false, lostAgent: true });
for (let i = 0; i < 3; i++) d.sync();
if (badSelects().length) fail(`selected a missing child: ${JSON.stringify(badSelects())}`);
if (find(globalThis.herdr.layout, "agent-stack").active === "agent"
  && !globalThis.herdr.calls.some(([n, a]) => n === "layout.select" && a.child === "empty")) fail("placeholder not selected");
console.log("PASS: without a desk a lost agent block only selects the placeholder");

// Intact layout: the block is repointed and selected as before.
d = setup({ desk: true, lostAgent: false });
d.sync();
block = find(globalThis.herdr.layout, "agent");
if (block.content?.terminal !== "t7") fail("intact block not repointed");
if (!globalThis.herdr.calls.some(([n, a]) => n === "layout.select" && a.child === "agent")) fail("intact block not selected");
if (badSelects().length) fail(`selected a missing child: ${JSON.stringify(badSelects())}`);
console.log("PASS: an intact agent block is repointed and shown");
EOF

node "$TMP_DIR/test.mjs"
