#!/usr/bin/env bash
# shellcheck shell=bash
# The bercail-agents mod: a desk under a bash Shell gets its own row in the agents list.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found\n'
  exit 0
fi

# render() builds its rows through these stubs; every element method chains.
cat >"$TMP_DIR/herdr.mjs" <<'EOF'
const h = () => globalThis.herdr;
export const agents = () => h().agents;
export const terminals = () => h().terminals;
export const spaces = () => h().spaces;
export const panes = () => [];
export const focused = () => h().focused;
export const run = (name, args) => h().calls.push([name, args]);
export const theme = () => new Proxy({}, { get: (_t, k) => String(k) });
export const shared = () => null;
export const setShared = () => {};
export const setAgentOrder = (order) => { h().order = order; };
export const openOverlay = () => {};
export const closeOverlay = () => {};
export const props = () => ({});
export const window = () => ({ platform: "linux" });
export const layout = () => ({ id: "root", children: [{ id: "sidebar", size: { px: 268 } }] });
EOF
cat >"$TMP_DIR/gpui.mjs" <<'EOF'
// An element records its id, text children and click handler; nested elements too.
export const els = [];
const el = () => {
  const e = { kids: [] };
  els.push(e);
  const p = new Proxy(e, {
    get: (t, k) => k in t ? t[k] : (...a) => {
      if (k === "id") t.id = a[0];
      if (k === "child") t.kids.push(a[0]);
      if (k === "children") t.kids.push(...(a[0] ?? []));
      if (k === "on_click") t.click = a[0];
      if (k === "when" && a[0]) a[1](p);
      return p;
    },
  });
  return p;
};
export class View {}
export const div = el, image = el, svg = el, h_flex = el, v_flex = el;
EOF
sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui.mjs"|' \
  -e 's|from "gpui-base"|from "./gpui.mjs"|' "$ROOT/bercail/mods/bercail-agents/main.js" >"$TMP_DIR/main.mjs"

cat >"$TMP_DIR/test.mjs" <<'EOF'
import Agents, { deskRows, withDesks } from "./main.mjs";
import { els } from "./gpui.mjs";

const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exit(1); };
globalThis.localStorage = { getItem: () => null, setItem: () => {} };

const spaces = [{ id: "s1", name: "one", tabs: [] }, { id: "s2", name: "two", tabs: [] }];
const desk = (address, space, parent, status = "working") => ({
  address, parent, state: "live", status, title: "OC | a job", program: { name: "OpenCode" },
  labels: { "bercail.role": "agent", "bercail.space": space },
});
const agent = (address, space, status = "idle") => ({
  address, pane: `p-${address}`, space, space_name: space, tab: null, status, title: "", program: {}, seq: 1, focused: false,
});

function render(state) {
  globalThis.herdr = { calls: [], focused: { space: "s1" }, spaces, ...state };
  els.length = 0;
  const v = new Agents();
  v.init({}, { timer: { every: () => {} } });
  v.render({});
  return els;
}
const row = (address) => els.find((e) => e.id === `ag-${address}`);
const sub = (address) => els.find((e) => e.id === `sub-${address}`);

// t2 is a desk under bash Shell t1 (not an agent): it gets its own row.
render({
  agents: [agent("t9", "s2")],
  terminals: [
    { address: "t1", state: "live", status: null, labels: {} },
    desk("t2", "s1", "t1"),
    { address: "t9", state: "live", status: "idle", labels: {} },
  ],
});
if (!row("t2")) fail("a Shell sub-agent desk has no row");
if (!row("t9")) fail("a pane agent lost its row");
const order = globalThis.herdr.order;
if (order.indexOf("t2") < 0) fail(`the desk is not in the list order: ${order}`);
row("t2").click();
const [name, args] = globalThis.herdr.calls.at(-1);
if (name !== "bercail-desk.agent:t2") fail(`clicking a desk row runs ${name} ${JSON.stringify(args)}`);
row("t9").click();
if (globalThis.herdr.calls.at(-1)[0] !== "pane.focus") fail("clicking a pane agent must still focus its pane");
console.log("PASS: a Shell sub-agent desk gets a row; clicking it shows the desk");

// Its status follows terminals(): working, then idle (done reads idle, error blocked).
const st = (s) => deskRows([], [desk("t2", "s1", "t1", s)], spaces, null)[0].status;
if (st("working") !== "working" || st("idle") !== "idle" || st("done") !== "idle" || st("error") !== "blocked") {
  fail(`desk status: ${["working", "idle", "done", "error"].map(st)}`);
}
console.log("PASS: a desk row's status comes from terminals()");

// Old desks: a desk with its own pane is an agent already; a desk under an agent is its
// sub-agent row. Neither gets a second row. Finished desks and other terminals get none.
render({
  agents: [agent("t5", "s1"), agent("t6", "s2")],
  terminals: [
    { ...desk("t5", "s1", null), status: "idle" },
    { address: "t6", state: "live", status: "idle", labels: {} },
    desk("t7", "s2", "t6"),
    { ...desk("t8", "s2", "t1"), state: "exited" },
    { address: "t3", state: "live", status: "working", parent: "t1", labels: {} },
  ],
});
if (!row("t5") || !row("t6")) fail("pane agents must keep their rows");
if (row("t7") || !sub("t7")) fail("a desk under an agent stays that agent's sub-agent row");
if (row("t8") || row("t3")) fail("only live bercail desks get rows");
if (els.filter((e) => e.id === "ag-t5").length !== 1) fail("a desk with a pane got two rows");
console.log("PASS: pane agents, agents' sub-agents and old desks keep their rows, once");

// In spaces() order (what grouped-by-space draws): the desk sits with its space's agents, before them.
const d = deskRows([], [desk("t2", "s1", "t1")], spaces, { agent: "t2" })[0];
if (d.space_name !== "one" || !d.focused || d.pane !== null) fail(`desk row shape: ${JSON.stringify(d)}`);
const merged = withDesks([agent("t4", "s1"), agent("t9", "s2"), agent("t10", "s2")], [{ ...d, address: "t2", space: "s2" }], spaces);
if (merged.map((a) => a.address).join() !== "t4,t2,t9,t10") fail(`space order: ${merged.map((a) => a.address)}`);
console.log("PASS: a desk row sits first among its space's agents");
EOF
node "$TMP_DIR/test.mjs"
