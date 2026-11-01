# Proposal for Herdr: list sub-agents whose parent isn't an agent

For the Herdr app's shipped `agents` mod (`mods/agents/main.js`, 0.1.11).
This is a written proposal. Nobody has filed it upstream.

## Problem

The agents list draws rows only from `agents()`: terminals with a pane that
report a status. A sub-agent (`hc run --parent <t>`) has no pane, so it shows
only as a child row under its parent (`tree()`, `withKids`). When the parent
is a plain shell, which never reports a status and so is never in `agents()`,
the sub-agent gets no row at all. It runs, it reports working, idle or
blocked, and the list never shows it.

With Herdr's own agents mod, every bercail desk hits this: the desk agent is an hc sub-agent of the
space's bash Shell (`hc run --parent <shell> --outlive-parent`). Live example:
`herdr-app ls` showed `RedwoodGQL / Shell: t13 sub_agents ["t2x"]` with t2x
(codex) idle, and the agents list had no row for it. bercail works around
this with its own clone of the mod (`bercail/mods/bercail-agents`), which
lists terminals labelled `bercail.role=agent`. The general fix belongs
upstream.

## Change

A live terminal that reports a status and has a parent, where no ancestor up
its parent chain is in `agents()`, gets a top-level row:

- in the space and tab of the pane its chain hangs from (the shell's pane);
- first among that space's agents, so grouped-by-space keeps one group per space;
- with its `terminals()` status, read the way `kidStatus` reads it (error is
  blocked, done is idle: no pane, so Herdr never marks it seen);
- named by its own title, since the tab name would only say the shell's tab;
- a click runs `agent.focus {terminal}`, because it has no pane to focus.

Sub-agents of listed agents are unchanged: the existing tree draws them, and
the ancestor check keeps them from getting a second row.

## Patch

Checked with `herdr-app check`, and rendered against live `hc get` and
`herdr-app ls` data: t72, t2x and t46 (sub-agents of bash Shells t71, t13
and t15) each got a row, and the pane agents kept theirs.

```diff
--- a/mods/agents/main.js
+++ b/mods/agents/main.js
@@ -46,6 +46,36 @@
   const s = listed.get(k.address) ?? k.status;
   return s === "error" ? "blocked" : s === "done" ? "idle" : s;
 };
+// Live sub-agents that report a status but that no listed agent draws, because
+// their parent (or its parent, up the chain) isn't an agent: a plain shell that
+// started one with `hc run --parent`. A row each, in the space of the pane the
+// chain hangs from, shaped like AgentInfo. No pane of their own: a click shows them.
+export function orphans(list, all, paneList, spaceList, f) {
+  const listed = new Set(list.map((a) => a.address));
+  const byAddr = new Map(all.map((k) => [k.address, k]));
+  const root = (k) => { const seen = new Set(); while (k?.parent && !seen.has(k.address)) { seen.add(k.address); k = byAddr.get(k.parent) ?? { address: k.parent }; } return k; };
+  const under = (k) => { for (let p = k.parent, n = 0; p && n < 64; p = byAddr.get(p)?.parent, n++) if (listed.has(p)) return true; return false; };
+  return all
+    .filter((k) => k.state === "live" && k.parent && k.status && !listed.has(k.address) && !under(k))
+    .flatMap((k) => {
+      const pane = paneList.find((p) => p.terminal === root(k).address);
+      const space = pane && spaceList.find((s) => s.tabs.some((t) => t.id === pane.tab));
+      if (!space) return [];
+      return [{ address: k.address, pane: null, sub: true, space: space.id, space_name: space.name, tab: null,
+        status: kidStatus(k, new Map()), app: k.report?.app ?? null, program: k.program, title: clean(k.title),
+        seq: k.status_ms ?? 0, focused: f?.agent === k.address }];
+    });
+}
+
+// agents() with the orphans, in spaces() order; an orphan comes first in its space.
+export function withOrphans(list, extra, spaceList) {
+  const at = new Map(spaceList.map((s, i) => [s.id, i]));
+  const rank = (a) => at.get(a.space) ?? Infinity;
+  return [...extra, ...list].sort((x, y) => rank(x) - rank(y));
+}
+
+const open = (a) => (a.sub ? run("agent.focus", { terminal: a.address }) : run("pane.focus", { pane: a.pane }));
+
 const SORTS = [
   { id: "priority", label: "Priority", icon: "clock" },
   { id: "grouped", label: "Grouped by space", icon: "layers" },
@@ -212,9 +242,10 @@
     if (props()?.sortMenu) return this.sortMenu(t);
     const collapsed = narrow();
     const sort = sortOf();
+    const all = terminals();
     let list = agents();
+    list = withOrphans(list, orphans(list, all, panes(), spaces(), focused()), spaces());
     this.listed = new Map(list.map((a) => [a.address, a.status]));
-    const all = terminals();
     const shown = focused()?.agent;
     const now = Date.now();
     this.track(list, now);
@@ -291,7 +322,7 @@
           .items_center()
           .gap(4)
           .hover((s) => s.bg(t.hover))
-          .on_click(() => run("pane.focus", { pane: a.pane }))
+          .on_click(() => open(a))
           .child(div().flex_1().min_w(0).whitespace_nowrap().text_right().text_color(t.muted).child(String(i + 1)))
           .child(h_flex().w(14).flex_none().items_center().justify_center().child(this.status(t, a, true)));
       }
@@ -335,7 +366,7 @@
           else if (this.hovered === a.address) this.hovered = null;
           cx.notify();
         })
-        .on_click(() => run("pane.focus", { pane: a.pane }))
+        .on_click(() => open(a))
         .when(Boolean(pic), el => el.child(div().id(`agent-fold-${a.address}`)
           .when(subs.length > 0, el => el.on_click((_e, cx) => {
             cx.stop_propagation();
```

## Open questions for Herdr

- Should these rows count toward `setAgentOrder` and `agent.next`/`agent.prev`?
  Today `setAgentOrder` ignores addresses missing from the model, so they are
  skipped. (bercail's clone passes its desk rows to `setAgentOrder` and steps
  through agents with its own `Alt+Shift+Up`/`Down` keys.)
- What should a click show? bercail found that `agent.focus` on a desk puts the
  keyboard on its parent's pane (the Shell), so its clone asks its own desk mod
  to show the desk. A layout that shows sub-agents in a block of its own may
  want a way to take over the click.
