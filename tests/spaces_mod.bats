#!/usr/bin/env bats
# bercail-spaces' review marks, against stubbed herdr and gpui modules and a fixed
# `bercail shep queue --json`: the marks and header count, review-next's order, the
# Review list, and that reading the queue never moves the view or the keyboard.

setup() {
  load test_helper
  isolate
  need node jq
  export TZ=UTC
  cat >"$BATS_TEST_TMPDIR/herdr.mjs" <<'EOF'
const h = () => globalThis.herdr;
const find = (n, id) => n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean);
export const layout = () => structuredClone(h().layout);
export const run = (name, args) => {
  h().calls.push([name, args]);
  if (name === "layout.show" || name === "layout.hide") find(h().layout, args.id).hidden = name === "layout.hide";
};
export const spaces = () => h().spaces;
export const focused = () => h().focused;
export const terminals = () => h().terminals;
export const panes = () => h().panes ?? [];
export const machines = () => h().machines ?? [];
export const notify = (n) => h().notes.push(n);
export const theme = () => new Proxy({}, { get: (_t, k) => String(k) });
export const props = () => h().props ?? {};
export const shared = (k) => h().shared[k] ?? null;
export const setShared = (k, v) => { h().shared[k] = v; };
export const openOverlay = (spec) => { h().calls.push(["openOverlay", spec]); return "o1"; };
export const closeOverlay = (id) => h().calls.push(["closeOverlay", id]);
export const exec = async (cmd, args, opts) => { h().execs.push([cmd, ...args]); return h().exec(cmd, args, opts); };
export const hc = async () => ({ code: 0, stdout: JSON.stringify({ machines: h().machineList ?? [] }), stderr: "" });
export const watchFolder = (path) => {
  let resolve;
  const pending = new Promise((r) => { resolve = r; });
  pending.cancel = () => { pending.canceled = true; resolve(); };
  pending.fire = resolve;
  (h().watches ??= []).push({ path, pending });
  return pending;
};
export const window = () => ({ active: true });
export const home = () => "/home/me";
// The files a test puts in h().files, by path; else absent.
export const readTextFile = async (path) => h().files?.[path] ?? null;
// The commands the test sends with h().send(c).
export const nextCommand = () => new Promise((resolve) => { h().send = resolve; });
EOF
  cat >"$BATS_TEST_TMPDIR/gpui.mjs" <<'EOF'
// An element records its id, text, children, tooltip and click handler.
const el = () => {
  const e = { kids: [] };
  const p = new Proxy(e, {
    get: (t, k) => k === "__el" ? t : (...a) => {
      if (k === "id") t.id = a[0];
      if (k === "on_click") t.click = a[0];
      if (k === "tooltip") t.tip = a[0];
      if (k === "text_color") t.color = a[0];
      if (k === "track_scroll") t.scroll = a[0];
      if (k === "on_size_change") t.resize = a[0];
      if (k === "child") t.kids.push(a[0]);
      if (k === "children") t.kids.push(...a[0]);
      if (k === "when" && a[0]) a[1](p);
      return p;
    },
  });
  return p;
};
export class View {}
export const ScrollHandle = { new: () => ({ revealed: [], scroll_to_item(i) { this.revealed.push(i); } }) };
export const div = el, svg = el, h_flex = el, v_flex = el;
export const E = (n) => n?.__el ?? n;
// The text under a node, depth first, one string per element with text.
export function text(n, out = []) {
  const e = E(n);
  if (e == null || typeof e !== "object") { if (e != null) out.push(String(e)); return out; }
  const own = e.kids.filter((k) => typeof k !== "object").join("");
  if (own) out.push(own);
  for (const k of e.kids) if (k && typeof k === "object") text(k, out);
  return out;
}
export function all(n, out = []) {
  const e = E(n);
  if (!e || typeof e !== "object") return out;
  out.push(e);
  for (const k of e.kids) all(k, out);
  return out;
}
EOF
  sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui.mjs"|' \
    -e 's|from "gpui-base"|from "./gpui.mjs"|' "$ROOT/bercail/mods/bercail-spaces/main.js" >"$BATS_TEST_TMPDIR/main.mjs"
  cp "$ROOT/bercail/layouts/bercail.json" "$BATS_TEST_TMPDIR/layout.json"
  # The queue, oldest first: s1's high-stakes job, a PR, s2's big job, s3's unknown
  # (found by its folder; high-stakes), and work in no space (a space on another
# machine has its folder); then s4's cleanup (high-stakes too) and s5's superseded.
  jq -n '{schema: "bercail.queue/v1", at: "2026-11-14T12:00:00Z", items: [
    {kind: "staged", path: "/w/app.one", issue: "app-1", title: "Export", space: "s1", since: "2026-11-14T09:00:00Z",
     state: "lgtm", counts: true, change: {lines: 6, stakes: "high", review: "required"}},
    {kind: "pr", repo: "/w/app", number: 12, title: "Teammate fix", url: "https://github.com/o/app/pull/12", lines: 4,
     since: "2026-11-13T12:00:00Z", state: "review", counts: true},
    {kind: "staged", path: "/w/app.two", issue: "app-2", title: "Sessions", space: "s2", since: "2026-11-14T11:30:00Z",
     state: "review", counts: true, change: {lines: 1234, stakes: "low"}},
    {kind: "staged", path: "/w/web.x", issue: "web-7", space: "gone-id", since: "2026-11-14T11:58:00Z",
     state: "unknown", why: "bd does not answer for web-7", counts: true, change: {lines: 7, stakes: "high", review: "required"}},
    {kind: "staged", path: "/w/far", issue: null, since: null, state: "review", counts: true, change: {lines: 2, stakes: "low"}},
    {kind: "staged", path: "/w/app.three", issue: "app-3", title: "Old", space: "s4", since: "2026-11-10T12:00:00Z",
     state: "cleanup", why: "issue closed", counts: false, change: {lines: 40, stakes: "high", review: "required"}},
    {kind: "staged", path: "/w/app.four", issue: "app-4", space: "s5", since: "2026-11-11T12:00:00Z",
     state: "superseded", why: "its job moved to another worktree", by: "/home/me/w/app.five", counts: false, change: {lines: 9, stakes: "low"}}],
    repos: []}' >"$BATS_TEST_TMPDIR/queue.json"
  cat >"$BATS_TEST_TMPDIR/prelude.mjs" <<'EOF'
import { readFileSync } from "node:fs";
import Spaces, { reviewRows, nextReview, marks, reviewStatus, ago, STALE, adoptedNames } from "./main.mjs";
import { E, text, all } from "./gpui.mjs";

const shipped = JSON.parse(readFileSync(new URL("./layout.json", import.meta.url)));
const queue = readFileSync(new URL("./queue.json", import.meta.url), "utf8");
const Q = JSON.parse(queue);
const NOW = Date.parse(Q.at) + 60000;
const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exit(1); };
const expect = (got, want, what) => { if (JSON.stringify(got) !== JSON.stringify(want)) fail(`${what}: ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
const tick = () => new Promise((r) => setImmediate(r));
const DESK = (address, space, status) => ({ address, state: "live", status, labels: { "bercail.role": "agent", "bercail.space": space } });
const S = (id, name, folder = `/w/${id}`) => ({ id, name, folder, tabs: [{ id: `tab-${id}` }] });
Date.now = () => NOW;
const store = {};
globalThis.localStorage = { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = v; } };

globalThis.herdr = {
  layout: structuredClone(shipped), calls: [], execs: [], notes: [], shared: {},
  spaces: [S("s0", "home"), S("s1", "export"), S("s2", "sessions"), S("s3", "web-x", "/w/web.x"), S("s4", "old"), S("s5", "four"),
    { ...S("s6", "far-box", "/w/far"), machine: "box" }],
  focused: { space: "s0", pane: "p0" },
  terminals: [DESK("t1", "s1", "done"), DESK("t2", "s2", "idle")],
  exec: (cmd, args) => cmd === "bash" && /bercail shep queue --json$/.test(args.at(-1))
    ? { code: 0, stdout: queue, stderr: "" } : { code: 1, stdout: "", stderr: "" },
};
// As in gpui: a timer callback and a task each get a cx.
const timers = [];
const cx = () => ({ timer: { every: (ms, f) => timers.push({ ms, f }) }, spawn: (f) => f(cx()), notify() {}, open_url: (u) => herdr.calls.push(["open_url", u]) });
const views = (id) => (n) => all(n).find((e) => e.id === id);
const viewCalls = () => herdr.calls.filter(([n]) => n !== "openOverlay");
EOF
}

mod_case() {
  cat "$BATS_TEST_TMPDIR/prelude.mjs" - >"$BATS_TEST_TMPDIR/test.mjs"
  node "$BATS_TEST_TMPDIR/test.mjs"
}

@test "review-next order: spaces whose work waits, in queue order, wrapping; cleanup, superseded and spaceless work are skipped" {
  mod_case <<'EOF'
const rows = reviewRows(Q, herdr.spaces, []);
expect(rows.map((r) => r.space?.id ?? null), ["s1", null, "s2", "s3", null, "s4", "s5"], "spaces: by id, else by folder, this machine's only");
const walk = [];
let at = "s0";
for (let i = 0; i < 4; i++) walk.push((at = nextReview(rows, at)));
expect(walk, ["s1", "s2", "s3", "s1"], "next review from a space with nothing waiting");
expect(nextReview(rows, "s4"), "s1", "from a cleanup candidate's space: the first");
expect(nextReview(reviewRows({ items: Q.items.filter((i) => !i.counts) }, herdr.spaces, []), "s0"), null, "nothing waits");
const m = marks(rows);
expect([m.s1.lines, m.s1.lgtm, m.s2.lines, m.s2.lgtm, m.s3.unknown, m.s3.lgtm, m.s4.waits, m.s4.lgtm, m.s4.quiet, m.s5.quiet, "s0" in m],
  [6, true, 1234, false, true, true, 0, false, "cleanup", "superseded", false], "marks");
expect(ago("2026-11-14T09:00:00Z", NOW), "3h", "waited");
EOF
}

@test "reading the queue marks spaces and the header, and never moves the view or the keyboard" {
  mod_case <<'EOF'
const v = new Spaces();
v.init({}, cx());
const tick250 = timers.find((t) => t.ms === 250).f;
tick250(cx());
await tick();
const reads = () => herdr.execs.filter(([c, , s]) => c === "bash" && /shep queue --json/.test(s)).length;
expect(reads(), 1, "the first look reads the queue");
expect(herdr.shared["bercail.review"].q.at, Q.at, "the queue is shared");
tick250(cx());
await tick();
expect(reads(), 1, "no desk changed: no read");
herdr.terminals = [DESK("t1", "s1", "idle"), DESK("t2", "s2", "working")];
tick250(cx());
await tick();
expect(reads(), 1, "a desk changed within 30s of a read: not yet");
Date.now = () => NOW + 30000;
tick250(cx());
await tick();
expect(reads(), 2, "a desk's status changed: read again, 30s after the last");
tick250(cx());
await tick();
expect(reads(), 2, "one read per change");
timers.find((t) => t.ms === 300000).f(cx());
await tick();
expect(reads(), 3, "the five-minute timer reads it");
Date.now = () => NOW;
expect(viewCalls(), [], "reading the queue ran commands");

const tree = v.render();
const mark = (id) => views(`review-${id}`)(tree);
const look = (id) => [text(mark(id)), E(mark(id)).color];
expect(look("s1"), [["◆ 6"], "ansi1"], "s1: needs your LGTM, red");
expect(look("s2"), [["◆ 1.2k"], "accent"], "s2: optional review, the accent");
expect(look("s3"), [["◆ 7?"], "ansi1"], "s3: unknown state, still high-stakes");
if (text(tree).some((s) => /LGTM/.test(s))) fail(`the sidebar says LGTM: ${text(tree).filter((s) => /LGTM/.test(s))}`);
expect([text(mark("s4")), E(mark("s4")).color], [["cleanup"], "dim"], "s4: quiet cleanup mark");
expect(text(mark("s5")), ["superseded"], "s5: quiet superseded mark");
expect(mark("s0"), undefined, "s0: nothing waits, no mark");
if (!E(mark("s1")).tip.includes("app-1: Export · 6 lines · needs your LGTM")) fail(`s1 tooltip: ${E(mark("s1")).tip}`);
const badge = views("review-list")(tree);
expect([text(badge), E(badge).color], [["◆ 5 to review"], "ansi1"], "header count, red while one needs your LGTM");
E(badge).click();
expect(herdr.calls.at(-1)[1].props, { role: "reviews" }, "the badge opens the Review list");

// Shown three missed reads later, the queue reads as stale.
Date.now = () => NOW + STALE + 60000;
expect(text(views("review-list")(v.render())), ["◆ 5 to review (stale)"], "stale header");
expect(viewCalls(), [], "rendering ran commands");
EOF
}

@test "with a backend, the queue is read there, and its space ids and folders are that machine's" {
  mod_case <<'EOF'
// [herdr] backend = "box": bercail shep queue runs on box. Its item in space sp1 is in
// box/sp1 here, not in a space here that happens to be sp1; its worktree /w/far is box's
// folder, so box/sp2 matches and a space here with that folder does not.
herdr.files = { "/home/me/.config/bercail/config.toml": '[herdr]\nbackend = "box"\n' };
const boxQ = { ...Q, items: [
  { kind: "staged", path: "/w/a", issue: "a-1", space: "sp1", since: Q.at, state: "review", counts: true, change: { lines: 3, stakes: "low" } },
  { kind: "staged", path: "/w/far", issue: "a-2", since: Q.at, state: "review", counts: true, change: { lines: 5, stakes: "low" } }] };
const on = [];
herdr.exec = (cmd, args, opts) => {
  on.push([cmd, opts?.on ?? null]);
  return { code: 0, stdout: JSON.stringify(boxQ), stderr: "" };
};
herdr.spaces = [S("sp1", "here-sp1"), { ...S("box/sp1", "far-one"), machine: "box" }, S("near", "near", "/w/far"),
  { ...S("box/sp2", "far-two", "/w/far"), machine: "box" }];
const v = new Spaces();
v.init({}, cx());
timers.find((t) => t.ms === 250).f(cx());
for (let i = 0; i < 4; i++) await tick();
expect(on.filter(([c]) => c === "bash"), [["bash", "box"]], "the queue is read on box");
const r = herdr.shared["bercail.review"];
expect(r.backend, "box", "the read says where it was made");
expect(reviewRows(r.q, herdr.spaces, [], r.backend).map((x) => x.space?.id ?? null), ["box/sp1", "box/sp2"], "box's spaces");
herdr.calls = [];
herdr.send("review-next");
await tick();
expect(herdr.calls.find(([n]) => n === "space.select"), ["space.select", { id: "box/sp1" }], "review-next goes to box/sp1");
// A failed read keeps the last queue with the machine it came from.
herdr.exec = () => ({ code: 1, stdout: "", stderr: "box is away" });
v.readQueue(cx());
await tick();
expect([herdr.shared["bercail.review"].backend, herdr.shared["bercail.review"].error], ["box", "box is away"], "a failed read");
EOF
}

@test "review-next goes to the next space that waits, from either view; with nothing waiting it says so" {
  mod_case <<'EOF'
const v = new Spaces();
v.init({}, cx());
herdr.shared["bercail.review"] = { q: Q, error: null };
const press = async () => { herdr.calls = []; herdr.send("review-next"); await tick(); return herdr.calls; };
// From the Shep view: the space is selected and the space view shows, as a click on it does.
let c = await press();
expect(c, [["space.select", { id: "s1" }], ["layout.hide", { id: "shep" }], ["layout.show", { id: "work" }]], "from Shep");
herdr.focused = { space: "s1", pane: "p1" };
c = await press();
expect(c.filter(([n]) => n === "space.select"), [["space.select", { id: "s2" }]], "s1 to s2");
herdr.shared["bercail.review"] = { q: { ...Q, items: Q.items.filter((i) => !i.counts) } };
c = await press();
expect([c, herdr.notes.at(-1)?.body], [[], "Nothing in a space waits on your review."], "nothing waits");
herdr.shared["bercail.review"] = { q: null, error: "bercail shep queue exited 1" };
c = await press();
expect([c, herdr.notes.at(-1)?.body, herdr.notes.at(-1)?.level],
  [[], "The review queue is not read: queue unread: bercail shep queue exited 1", "warning"], "an unread queue is not \"nothing waits\"");
EOF
}

@test "the Review list: every item with space, title, size, stakes, LGTM and wait; open targets only; stale and failed reads show" {
  mod_case <<'EOF'
herdr.props = { role: "reviews", overlay: "o7" };
herdr.shared["bercail.review"] = { q: Q, error: null };
const v = new Spaces();
v.init({}, cx());
if (timers.length) fail("the list copy reads the queue itself");
const tree = v.render();
const row = (n) => text(views(`review-row-${n}`)(tree));
expect(text(tree).slice(0, 3), ["Review", "5 waiting · 1.3k lines", "as of 12:00"], "header");
expect(row(0), ["export", "app-1: Export", "6 lines", "stakes high · needs your LGTM", "3h", "Open space", "Open review"], "lgtm row");
expect(row(1), ["/w/app", "PR #12: Teammate fix", "4 lines", "PR", "1d", "Open PR"], "PR row");
expect(row(3), ["web-x", "web-7", "7 lines", "stakes high · needs your LGTM · unknown: bd does not answer for web-7", "3m", "Open space", "Open review"], "unknown row, found by folder, keeps its LGTM");
const facts = (n) => all(views(`review-row-${n}`)(tree)).find((e) => typeof e.kids[0] === "string" && e.kids[0].startsWith("stakes"));
expect([facts(0).color, facts(2).color, facts(5).color], ["ansi1", "muted", "dim"], "the list: needs your LGTM in red, optional muted, not counted dim");
expect(row(4), ["/w/far", "no issue", "2 lines", "stakes low", "–", "no space"], "no space");
if (!text(tree).includes("Not counted against the review budget")) fail("no section for what does not count");
expect(row(5).slice(0, 4), ["old", "app-3: Old", "40 lines", "stakes high · issue closed: clean up"], "cleanup row: no LGTM for what does not count");
expect(row(6)[3], "stakes low · its job moved to another worktree (~/w/app.five)", "superseded row");
const clickable = all(tree).filter((e) => e.click).map((e) => e.id.replace(/-[0-9]+$/, ""));
expect([...new Set(clickable)].sort(), ["review-close", "review-open", "review-pr", "review-space"], "only open targets and close");
E(views("review-open-0")(tree)).click();
expect(herdr.calls, [["closeOverlay", "o7"], ["space.select", { id: "s1" }], ["bercail-shep.desk:review", undefined]], "open review");
herdr.calls = [];
E(views("review-pr-1")(tree)).click({}, cx());
expect(herdr.calls, [["open_url", "https://github.com/o/app/pull/12"]], "open PR");

herdr.shared["bercail.review"] = { q: Q, error: "bd: database locked" };
Date.now = () => NOW + STALE + 60000;
const head = all(v.render()).find((e) => typeof e.kids[0] === "string" && e.kids[0].startsWith("as of"));
expect([head.kids[0], head.color], ["as of 12:00, stale (17m old); last read failed: bd: database locked", "blocked"], "stale and failed");
herdr.shared["bercail.review"] = { q: null, error: "bercail shep queue exited 1" };
if (!text(v.render()).includes("queue unread: bercail shep queue exited 1")) fail("an unread queue is not shown");
EOF
}

@test "a space bercail made with no window is named from its Shell's label, once, on its own machine, without moving the view" {
  mod_case <<'EOF'
const SHELL = (address, space, name) => ({ address, state: "live", labels: { "herdr.space": space, "bercail.space_name": name } });
herdr.spaces = [S("s0", "home"), S("sp-l", "app.feat"), { ...S("box/sp7", "api.fix"), machine: "box" },
  { ...S("box/sp8", "Mine"), machine: "box", named: true }, { ...S("box/sp9", "api"), machine: "box" }];
// box/t2 is a window's terminal in box/sp7: herdr.space, no name. It comes first.
herdr.terminals = [{ address: "box/t2", state: "live", labels: { "herdr.space": "sp7" } },
  SHELL("t5", "sp-l", "Feat_App"), SHELL("box/t3", "sp7", "Fix_Api"), SHELL("box/t4", "sp8", "Other_Api"),
  SHELL("t6", "sp9", "Wrong_Machine"), { ...SHELL("box/t9", "sp9", "Gone_Api"), state: "exited" }];
expect(adoptedNames(herdr.spaces, herdr.terminals).map(({ space, name }) => [space.id, name]),
  [["sp-l", "Feat_App"], ["box/sp7", "Fix_Api"]], "unnamed spaces whose live Shell on their machine carries a name");
const v = new Spaces();
v.init({}, cx());
const tick250 = timers.find((t) => t.ms === 250).f;
tick250(cx());
expect(viewCalls(), [["space.rename", { id: "sp-l", name: "Feat_App" }], ["tab.rename", { id: "tab-sp-l", name: "Shell" }],
  ["space.rename", { id: "box/sp7", name: "Fix_Api" }], ["tab.rename", { id: "tab-box/sp7", name: "Shell" }]],
  "renames only, no select: the view and the keyboard stay");
tick250(cx());
expect(viewCalls().length, 4, "a rename the app has not echoed yet is not sent again at once");
EOF
}

@test "36 spaces on another machine nest under their checkouts within its core's 16 execs; a refused look is retried in seconds and keeps what it showed" {
  mod_case <<'EOF'
// box's core runs 16 execs at once and refuses the rest (exit 5), as hc 0.1.21 does.
// Six repos there, each a checkout and five worktrees, listed worktrees first.
const repos = ["a", "b", "c", "d", "e", "f"];
const dirs = [...[1, 2, 3, 4, 5].flatMap((n) => repos.map((r) => `/w/${r}.w${n}`)), ...repos.map((r) => `/w/${r}`)];
herdr.spaces = dirs.map((d) => ({ ...S(`box/${d.slice(3)}`, d.slice(3), d), machine: "box" }));
let running = 0, most = 0, refuse = () => false;
herdr.exec = async (cmd, args, opts) => {
  if (cmd !== "git") return { code: 1, stdout: "", stderr: "" };
  if (running >= 16 || refuse(opts.cwd)) return { code: 5, stdout: "", stderr: '{"error":{"kind":"unavailable","message":"16 execs are running already"}}' };
  most = Math.max(most, ++running);
  for (let i = 0; i < 3; i++) await tick();
  running--;
  const top = opts.cwd, repo = top.replace(/\.w\d$/, "");
  const out = { "--show-toplevel": top, "--git-common-dir": `${repo}/.git` }[args.at(-1)];
  if (out) return { code: 0, stdout: `${out}\n`, stderr: "" };
  if (args[0] === "symbolic-ref") return { code: 0, stdout: `refs/heads/${top === repo ? "main" : top.slice(-2)}\n`, stderr: "" };
  return { code: 128, stdout: "", stderr: "fatal: no upstream configured" };
};
const v = new Spaces();
v.init({}, cx());
const tick250 = timers.find((t) => t.ms === 250).f;
const settle = async () => { tick250(cx()); for (let i = 0; i < 500 && (v.refreshing || i < 2); i++) await tick(); };
const unnested = () => v.ordered().filter((r) => /\.w\d$/.test(r.w.folder) && !r.tree).map((r) => r.w.name);
// /w/c.w3's first look is refused: another mod holds the core's slots then.
let refused = 0;
refuse = (cwd) => cwd === "/w/c.w3" && refused++ === 0;
await settle();
expect(unnested(), ["c.w3"], "one refused look leaves only its space out");
if (most > 8) fail(`${most} execs on box at once, want at most 8 (four places, two each)`);
Date.now = () => NOW + 2500;
await settle();
expect(unnested(), [], "the refused place is asked again within seconds and nests");
expect(v.ordered().map((r) => r.w.name).slice(0, 6), ["a", "a.w1", "a.w2", "a.w3", "a.w4", "a.w5"], "a's worktrees under it");
// A minute on, every place is looked at again and box refuses them all: what they showed stays.
refuse = () => true;
Date.now = () => NOW + 2500 + 61000;
await settle();
expect(unnested(), [], "refused looks keep each space's nesting");
EOF
}

@test "a window still waiting on a place on another machine leaves that machine's order alone, and sorts its own" {
  mod_case <<'EOF'
// Here: a worktree listed before its checkout. On box the same, plus box/x, whose first look box refuses.
herdr.spaces = [S("l.w1", "l.w1", "/l.w1"), S("l", "l", "/l"),
  ...[["a.w1", "/b/a.w1"], ["a", "/b/a"], ["x", "/b/x"]].map(([id, d]) => ({ ...S(`box/${id}`, id, d), machine: "box" }))];
let refused = 0;
herdr.exec = async (cmd, args, opts) => {
  if (cmd !== "git") return { code: 1, stdout: "", stderr: "" };
  if (opts.cwd === "/b/x" && refused++ === 0) return { code: 5, stdout: "", stderr: "16 execs are running already" };
  await tick();
  const top = opts.cwd, repo = top.replace(/\.w\d$/, "");
  const out = { "--show-toplevel": top, "--git-common-dir": `${repo}/.git` }[args.at(-1)];
  return out ? { code: 0, stdout: `${out}\n`, stderr: "" } : { code: 128, stdout: "", stderr: "" };
};
const v = new Spaces();
v.init({}, cx());
const tick250 = timers.find((t) => t.ms === 250).f;
const settle = async () => { tick250(cx()); for (let i = 0; i < 100 && (v.refreshing || i < 2); i++) await tick(); };
await settle();
const moves = () => herdr.calls.filter(([n]) => n === "space.move").map(([, a]) => a.id);
expect(v.ordered().map((r) => [r.w.id, r.tree]), [["l", null], ["l.w1", "└─"], ["box/a", null], ["box/a.w1", "└─"], ["box/x", null]],
  "both machines' worktrees show under their checkouts");
expect(moves(), ["l"], "only this computer's spaces move while box/x waits for an answer");
Date.now = () => NOW + 2500;
await settle();
herdr.calls = [];
v.ordered();
expect(moves(), ["l", "box/a"], "box/x answered: box's spaces are sorted too");
EOF
}

@test "a rejected git run keeps its global worker slot until its sibling finishes" {
  mod_case <<'EOF'
herdr.spaces = Array.from({ length: 5 }, (_, i) => ({ ...S(`s${i}`, `s${i}`, `/w/${i}`), machine: i % 2 ? "box" : null }));
const started = new Set(), release = [];
let finishSibling;
herdr.exec = async (cmd, args, opts) => {
  if (cmd !== "git") return { code: 1, stdout: "", stderr: "" };
  started.add(opts.cwd);
  if (opts.cwd === "/w/0" && args.at(-1) === "--show-toplevel") throw new Error("connection lost");
  return new Promise((resolve) => {
    const done = () => resolve({ code: 5, stdout: "", stderr: "busy" });
    if (opts.cwd === "/w/0") finishSibling = done;
    else release.push(done);
  });
};
const v = new Spaces();
v.init({}, cx());
timers.find((t) => t.ms === 250).f(cx());
await tick();
expect([...started], ["/w/0", "/w/1", "/w/2", "/w/3"], "four workers include rejected run's unfinished sibling");
finishSibling();
await tick();
expect([...started], ["/w/0", "/w/1", "/w/2", "/w/3", "/w/4"], "finishing the sibling releases the slot");
for (const done of release) done();
for (let i = 0; i < 100 && v.refreshing; i++) await tick();
expect(v.refreshing, false, "all work drains after release");
EOF
}

@test "spaces recover corrupt persisted machine reconnect and fold state" {
  mod_case <<'EOF'
for (const [key, raw] of [["machines.reconnecting", "{"], ["machines.reconnecting", "null"],
  ["machines.reconnecting", "[]"], ["machines.folded", "{"]]) {
  for (const k of Object.keys(store)) delete store[k];
  store[key] = raw;
  const v = new Spaces();
  try { v.init({}, cx()); v.render(); } catch (e) { fail(`${key}=${raw} prevents rendering: ${e.message}`); }
  expect(v.reconnecting, {}, `${key}=${raw}: no reconnects invented`);
  expect([...v.folded], [], `${key}=${raw}: no folds invented`);
}
EOF
}

@test "active space is revealed on selection and list resize but unchanged renders keep scroll position" {
  mod_case <<'EOF'
herdr.spaces = [{ ...S("s0", "home"), active: true }, S("s1", "work")];
const v = new Spaces();
v.init({}, cx());
const list = () => all(v.render()).find((e) => e.scroll);
let shown = list();
if (!shown) fail("spaces list does not track a ScrollHandle");
expect(shown.scroll.revealed, [0], "initial active row");
list();
expect(shown.scroll.revealed, [0], "unchanged render leaves scrolling alone");
herdr.spaces[0].active = false;
herdr.spaces[1].active = true;
shown = list();
expect(shown.scroll.revealed, [0, 1], "new active row");
if (!shown.resize) fail("list resize does not reveal the active row");
shown.resize({ width: 100, height: 30 }, cx());
expect(shown.scroll.revealed, [0, 1, 1], "resize reveals active row again");
expect(viewCalls(), [], "reveal never selects, focuses or switches views");
EOF
}

@test "active reveal counts machine headers and login notes and skips folded or rebuilt rows in wide and rail layouts" {
  mod_case <<'EOF'
herdr.spaces = [S("local", "home"), { ...S("box/one", "one"), machine: "box" },
  { ...S("box/two", "two"), machine: "box", active: true }];
herdr.machineList = [{ name: "box", state: "needs_login" }];
const v = new Spaces();
v.init({}, cx());
await tick();
const list = () => all(v.render()).find((e) => e.scroll);
let shown = list();
if (!shown) fail("grouped spaces list does not track a ScrollHandle");
expect(shown.scroll.revealed.at(-1), 5, "local header/row, box header/login note, box rows");
const clickHeader = (id) => views(`machine-${id}`)(v.render()).click({}, cx());
clickHeader("local"); // The local header's id is machine-local, folding key null.
shown = list();
expect(shown.scroll.revealed.at(-1), 4, "folded local group loses its row");
clickHeader("box");
shown = list();
const count = shown.scroll.revealed.length;
shown.resize({}, cx());
expect(shown.scroll.revealed.length, count, "folded active machine has no row to reveal");
clickHeader("box");
herdr.layout.children.find((n) => n.id === "sidebar").size = { px: 44 };
shown = list();
expect(shown.scroll.revealed.at(-1), 3, "rail has no login guidance and local remains folded");
herdr.layout.children.find((n) => n.id === "sidebar").size = { px: 268 };
herdr.machineList.unshift({ name: "a", state: "unreachable", why: 'a different core answers there ("new")' });
// The scheduled machine-list read supplies the changed snapshot.
timers.find((t) => t.ms === 15000).f(cx());
await tick();
shown = list();
expect(shown.scroll.revealed.at(-1), 5, "rebuilt machine contributes only its header before box");
expect(viewCalls(), [], "reveal and folding never switch views");
EOF
}

@test "logout warning opens the machine fix dialog without folding or switching views" {
  mod_case <<'EOF'
herdr.spaces = [{ ...S("box/one", "one"), machine: "box" }];
herdr.machineList = [{ name: "box", state: "connected", keeps_running_after_logout: false }];
const v = new Spaces();
v.init({}, cx());
await tick();
const warning = views("machine-logout-box")(v.render());
if (!warning) fail("machine whose agents stop on logout has no warning");
expect(warning.tip, "Agents stop when you disconnect. Click for the fix.", "warning explains the risk");
let stopped = false;
warning.click({}, { stop_propagation: () => { stopped = true; } });
expect(stopped, true, "warning click does not reach the fold handler");
expect(herdr.calls, [["openOverlay", { mod: "machine-add", kind: "dialog", width: 560 }]], "only opens the fix dialog");
expect([...v.folded], [], "warning leaves group unfolded");
EOF
}

@test "closing the last space prunes its git cache and cancels its watch without rearming it" {
  mod_case <<'EOF'
herdr.spaces = [S("s0", "app", "/w/app")];
herdr.exec = async (_cmd, args) => {
  const out = { "--show-toplevel": "/w/app", "--git-common-dir": "/w/app/.git" }[args.at(-1)];
  return { code: 0, stdout: out ? `${out}\n` : args[0] === "symbolic-ref" ? "refs/heads/main\n" : "0 0\n", stderr: "" };
};
const v = new Spaces();
v.init({}, cx());
const poll = timers.find((t) => t.ms === 250).f;
poll(cx());
for (let i = 0; i < 100 && (v.refreshing || i < 2); i++) await tick();
expect(herdr.watches?.map((w) => w.path), ["/w/app/.git"], "local git is watched");
const key = JSON.stringify([null, "/w/app"]);
// A transient refusal leaves retry state for this same place before it disappears.
herdr.exec = async () => ({ code: 5, stdout: "", stderr: "busy" });
Date.now = () => NOW + 61000;
poll(cx());
for (let i = 0; i < 100 && (v.refreshing || i < 2); i++) await tick();
expect(v.tries[key], 1, "transient failure records a retry");
herdr.spaces = [];
poll(cx());
await tick();
expect(Object.keys(v.git), [], "closed space leaves no git cache");
expect(Object.keys(v.checked), [], "closed space leaves no checked time");
expect([...v.unsure], [], "closed space leaves no unsure key");
expect(Object.keys(v.tries), [], "closed space leaves no retry count");
expect(herdr.watches[0].pending.canceled, true, "unused watch canceled");
expect(herdr.watches.length, 1, "canceled watch does not rearm");
EOF
}

@test "Ctrl+Shift+J is review-next in the bercail layout, and docs/keys.md says so" {
  jq -e '.["layout:bercail"]["ctrl-shift-j"] == "bercail-spaces.review-next"' "$ROOT/bercail/keys.json" >/dev/null \
    || fail "keys.json: $(jq -c '.["layout:bercail"]' "$ROOT/bercail/keys.json")"
  grep -q '^| `Ctrl+Shift+J` |' "$ROOT/docs/keys.md" || fail "docs/keys.md does not list Ctrl+Shift+J"
}
