#!/usr/bin/env bats
# The bercail-agents mod: a desk under a bash Shell gets its own row in the agents list,
# and a click opens the agent's terminal in a dialog.

setup() {
  load test_helper
  isolate
  need node
  cat >"$BATS_TEST_TMPDIR/herdr.mjs" <<'EOF'
const h = () => globalThis.herdr;
export const agents = () => h().agents;
export const terminals = () => h().terminals;
export const spaces = () => h().spaces;
export const panes = () => h().panes ?? [];
export const focused = () => h().focused;
export const run = (name, args) => h().calls.push([name, args]);
export const theme = () => new Proxy({}, { get: (_t, k) => String(k) });
export const shared = () => null;
export const setShared = () => {};
export const setAgentOrder = (order) => { h().order = order; };
export const openOverlay = (spec) => { h().overlays.push(spec); return "o1"; };
export const closeOverlay = () => {};
export const props = () => ({});
export const window = () => ({ platform: "linux" });
export const layout = () => ({ id: "root", children: [{ id: "sidebar", size: { px: 268 } }] });
EOF
  cat >"$BATS_TEST_TMPDIR/gpui.mjs" <<'EOF'
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
    -e 's|from "gpui-base"|from "./gpui.mjs"|' "$ROOT/bercail/mods/bercail-agents/main.js" >"$BATS_TEST_TMPDIR/main.mjs"
  cat >"$BATS_TEST_TMPDIR/prelude.mjs" <<'EOF'
import Agents, { deskRows, withDesks } from "./main.mjs";
import { els } from "./gpui.mjs";

const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exit(1); };
const store = new Map();
globalThis.localStorage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v), removeItem: (k) => store.delete(k) };

const spaces = [{ id: "s1", name: "one", tabs: [] }, { id: "s2", name: "two", tabs: [] }];
const desk = (address, space, parent, status = "working") => ({
  address, parent, state: "live", status, title: "Pi | a job", program: { name: "Pi" },
  labels: { "bercail.role": "agent", "bercail.space": space },
});
const agent = (address, space, status = "idle") => ({
  address, pane: `p-${address}`, space, space_name: space, tab: null, status, title: "", program: {}, seq: 1, focused: false,
});

function render(state) {
  globalThis.herdr = { calls: [], overlays: [], focused: { space: "s1" }, spaces, ...state };
  els.length = 0;
  const v = new Agents();
  v.init({}, { timer: { every: () => {} } });
  v.render({});
  return els;
}
const row = (address) => els.find((e) => e.id === `ag-${address}`);
const sub = (address) => els.find((e) => e.id === `sub-${address}`);

// t2 is a desk under bash Shell t1 (not an agent); t9 is a pane agent.
const renderShellDesk = () => render({
  agents: [agent("t9", "s2")],
  terminals: [
    { address: "t1", state: "live", status: null, labels: {} },
    desk("t2", "s1", "t1"),
    { address: "t9", state: "live", status: "idle", labels: {} },
  ],
});
EOF
}

# One case: the shared prelude, then the case on stdin.
mod_case() {
  cat "$BATS_TEST_TMPDIR/prelude.mjs" - >"$BATS_TEST_TMPDIR/test.mjs"
  node "$BATS_TEST_TMPDIR/test.mjs"
}

@test "agent titles keep opening brackets, quotes and a leading emoji while dropping spinner and Codex status marks" {
  mod_case <<'EOF'
for (const [raw, want] of [["✦  Working", "Working"], ["⠋ - Thinking", "Thinking"],
  ["[ ! ] Fix login", "Fix login"], ["[ . ] Fix login", "Fix login"],
  ["[web] login", "[web] login"], ["“Quoted task”", "“Quoted task”"],
  ["🔴 login", "🔴 login"], ["✋ Waiting", "Waiting"]]) {
  const got = deskRows([], [{ ...desk("t2", "s1", "t1"), title: raw }], spaces, null)[0].title;
  if (got !== want) fail(`title ${JSON.stringify(raw)} became ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}
EOF
}

@test "a live title equal to the terminal or fallback agent address keeps its tab name" {
  mod_case <<'EOF'
const tab = { id: "tab1", name: "Pi", named: false };
const a = { ...agent("t9", "s1"), tab: tab.id, title: "t9", program: { name: "Pi", agent: true } };
const texts = () => els.flatMap((e) => e.kids.filter((k) => typeof k === "string"));
render({ agents: [a], terminals: [], spaces: [{ ...spaces[0], tabs: [tab] }],
  panes: [{ tab: tab.id, terminal: "t9", title: "t9", program: a.program }] });
if (texts().includes("· t9") || !texts().includes("· Pi")) fail(`terminal id used as title: ${JSON.stringify(texts())}`);
render({ agents: [a, { ...a, address: "t10", title: "t10" }], terminals: [], spaces: [{ ...spaces[0], tabs: [tab] }] });
if (texts().some((s) => /^· t(?:9|10)$/.test(s)) || texts().filter((s) => s === "· Pi").length !== 2) {
  fail(`fallback agent address used as title: ${JSON.stringify(texts())}`);
}
EOF
}

@test "agents recover malformed or wrongly shaped persisted status and pin data" {
  mod_case <<'EOF'
for (const [key, raw] of [["changed", "{"], ["changed", "null"], ["changed", "[]"],
  ["pins", "{"], ["pins", "null"], ["pins", "{}"]]) {
  store.clear();
  store.set(key, raw);
  try { renderShellDesk(); } catch (e) { fail(`${key}=${raw} prevents rendering: ${e.message}`); }
  if (!row("t2") || !row("t9")) fail(`${key}=${raw} lost agent rows`);
  if (herdr.calls.some(([name]) => name === "terminal.pin")) fail(`${key}=${raw} invented a pin`);
}
EOF
}

@test "a Shell sub-agent desk gets a row" {
  mod_case <<'EOF'
renderShellDesk();
if (!row("t2")) fail("a Shell sub-agent desk has no row");
if (!row("t9")) fail("a pane agent lost its row");
const order = globalThis.herdr.order;
if (order.indexOf("t2") < 0) fail(`the desk is not in the list order: ${order}`);
EOF
}

@test "a desk on another machine gets its row under its space there" {
  mod_case <<'EOF'
// box/t2's bercail.space=s1 is written on box: its space is box/s1 ("far"), not s1 here.
const sps = [...spaces, { id: "box/s1", name: "far", tabs: [] }];
const rows = deskRows([], [desk("box/t2", "s1", "box/t1")], sps, null);
if (rows.length !== 1 || rows[0].space !== "box/s1" || rows[0].space_name !== "far") fail(`box's desk: ${JSON.stringify(rows)}`);
const order = withDesks([agent("t9", "s1")], rows, sps).map((a) => a.address).join();
if (order !== "t9,box/t2") fail(`box's desk sorts with box/s1, after s1's agents: ${order}`);
EOF
}

@test "clicking a desk or an agent opens its terminal in a dialog and switches nothing" {
  mod_case <<'EOF'
renderShellDesk();
// A click opens the agent's own terminal in a dialog, with bercail-shep's bar, and
// switches nothing: no space, pane or desk command runs.
globalThis.herdr.focused = { space: "s1", pane: "p7", terminal: "t7" };
row("t2").click();
row("t9").click();
const terms = globalThis.herdr.overlays.map((o) => o.layout.children[1].content.terminal);
if (terms.join() !== "t2,t9") fail(`clicks opened ${JSON.stringify(globalThis.herdr.overlays)}`);
const [o] = globalThis.herdr.overlays;
const bar = o.layout.children[0].content;
if (o.kind !== "dialog" || bar.mod !== "bercail-shep" || bar.props.role !== "modal" || bar.props.terminal !== "t2"
  || bar.props.back.pane !== "p7" || bar.props.back.terminal !== "t7") fail(`dialog: ${JSON.stringify(o)}`);
if (globalThis.herdr.calls.length) fail(`a click ran ${JSON.stringify(globalThis.herdr.calls)}`);
EOF
}

@test "a desk row's status comes from terminals()" {
  mod_case <<'EOF'
// Its status follows terminals(): working, then idle (done reads idle, error blocked).
const st = (s) => deskRows([], [desk("t2", "s1", "t1", s)], spaces, null)[0].status;
if (st("working") !== "working" || st("idle") !== "idle" || st("done") !== "idle" || st("error") !== "blocked") {
  fail(`desk status: ${["working", "idle", "done", "error"].map(st)}`);
}
EOF
}

@test "pane agents, agents' sub-agents and old desks keep their rows, once" {
  mod_case <<'EOF'
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
sub("t7").click();
if (globalThis.herdr.overlays.at(-1)?.layout.children[1].content.terminal !== "t7") fail("a sub-agent row must open its dialog");
EOF
}

@test "a desk row sits first among its space's agents" {
  mod_case <<'EOF'
// In spaces() order (what grouped-by-space draws): the desk sits with its space's agents, before them.
const d = deskRows([], [desk("t2", "s1", "t1")], spaces, { agent: "t2" })[0];
if (d.space_name !== "one" || !d.focused || d.pane !== null) fail(`desk row shape: ${JSON.stringify(d)}`);
const merged = withDesks([agent("t4", "s1"), agent("t9", "s2"), agent("t10", "s2")], [{ ...d, address: "t2", space: "s2" }], spaces);
if (merged.map((a) => a.address).join() !== "t4,t2,t9,t10") fail(`space order: ${merged.map((a) => a.address)}`);
EOF
}

@test "a pin the older mod kept in localStorage moves to the terminal's label, and a pinned desk leads the list" {
  mod_case <<'EOF'
// Herdr's agents mod up to 0.1.14, and bercail's copy of it, kept pins in localStorage.
store.set("pins", JSON.stringify(["t2"]));
renderShellDesk();
const pin = globalThis.herdr.calls.find(([name]) => name === "terminal.pin");
if (!pin || pin[1].terminal !== "t2" || pin[1].pinned !== true) fail(`the stored pin was not handed to core: ${JSON.stringify(globalThis.herdr.calls)}`);
if (!store.has("pins")) fail("the stored pin was dropped before core confirmed it");

// Core echoes the label: the stored copy goes, and the desk (space s1) leads t9 either way,
// so pin the later one to see the order move.
const pinned = { ...desk("t2", "s2", "t1"), labels: { "bercail.role": "agent", "bercail.space": "s2", "herdr.pinned": "1" } };
render({
  agents: [agent("t4", "s1")],
  terminals: [{ address: "t1", state: "live", status: null, labels: {} }, pinned, { address: "t4", state: "live", status: "idle", labels: {} }],
});
if (store.has("pins")) fail("a pin core holds is still in localStorage");
if (globalThis.herdr.order.join() !== "t2,t4") fail(`a pinned desk must lead: ${globalThis.herdr.order}`);
EOF
}
