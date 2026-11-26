// A pane's header, for layouts that frame their panes:
//   { "tab": "active", "pane": { "header": { "content": { "mod": "pane" } } } }
// Shows the program's icon (the app's program table), the agent's name or
// the terminal's title, the folder, and the agent's status; buttons split, zoom and close
// this pane. Props from the app: { pane, terminal }. Click: focus the pane.
//
// bercail's copy of Herdr's pane mod 0.1.18 (Apache License 2.0). Rebase it when Herdr
// ships a newer pane mod: take Herdr's file and put these back. bercail's changes, all of them:
// - focus follows the mouse: with `[layout] focus_follows_mouse = true` in bercail's
//   config.toml, read when the mod loads, the header is wrapped in `follow` from
//   follow.js, jankeesvw/herdr-focus-to-hover's, byte for byte (MIT, LICENSE; UPSTREAM.md):
//   the pane under the pointer gets the keyboard. Off, the header is Herdr's.
// The buttons' icons stay Herdr's, in mods/pane/.

import { View, div, svg, image } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, props, run, theme, home, layout, readTextFile } from "herdr";
import { follow } from "./follow.js";

const CONFIG = "/.config/bercail/config.toml";

// config.toml's key lines as bercail's TOML reader (lib/toml.sh) sees them: [table, line],
// the line without its comment. A value that opens a """ or ''' string runs to its closing
// delimiter: the lines between are text, and whatever follows the delimiter is dropped.
// Line ends may be CRLF. Table and key names are read bare, as `bercail config set` writes them.
export function tomlLines(text) {
  const out = [];
  let table = "";
  let ml = "";
  for (const raw of String(text ?? "").split(/\r?\n/)) {
    if (ml) {
      if (raw.includes(ml)) ml = "";
      continue;
    }
    const open = raw.match(/^\s*(?:"[^"]*"|'[^']*'|[\w-]+)\s*=\s*('''|""")(.*)$/);
    if (open && !open[2].includes(open[1])) {
      ml = open[1];
      continue;
    }
    const line = raw.replace(/"(?:[^"\\]|\\.)*"|'[^']*'|#.*$/g, (m) => (m[0] === "#" ? "" : m)).trim();
    const sec = line.match(/^\[(.+)\]$/);
    if (sec) table = sec[1].trim();
    else if (line) out.push([table, line]);
  }
  return out;
}

// [layout] focus_follows_mouse from config.toml's text: true only when it says true.
export function followsMouse(text) {
  return tomlLines(text).some(([table, line]) => table === "layout" && /^focus_follows_mouse\s*=\s*true$/.test(line));
}

// Match the first visible tab frame, including the active child of a stack.
function paneFrame(node) {
  if (!node || node.hidden) return null;
  if (node.content?.tab && node.content.pane) return node.content.pane;
  let children = node.children ?? [];
  if (node.type === "stack") {
    const visible = children.filter(child => !child.hidden);
    children = [visible.find(child => child.id === node.active) ?? visible[0]];
  }
  for (const child of children) {
    const frame = paneFrame(child);
    if (frame) return frame;
  }
  return null;
}

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

function folder(cwd) {
  if (!cwd) return "";
  const h = home();
  return cwd === h ? "~" : cwd.startsWith(h + "/") ? "~" + cwd.slice(h.length) : cwd;
}

export default class Pane extends View {
  init(_props, cx) {
    this.hovered = false;
    this.follow = false;
    cx.spawn(async (cx) => {
      this.follow = followsMouse(await readTextFile(home() + CONFIG).catch(() => ""));
      if (this.follow) cx.notify();
    });
  }

  me() {
    return panes().find((p) => p.pane === props()?.pane);
  }

  button(t, id, icon, command, args) {
    return div()
      .id(id)
      .p(3)
      .rounded(4)
      .text_color(t.dim)
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        run(command, args);
      })
      .child(svg(`mods/pane/${icon}.svg`).size(14));
  }

  render() {
    const head = this.header();
    return this.follow ? follow(this, props()?.pane, head) : head;
  }

  header() {
    const t = theme();
    const p = this.me();
    if (!p) return div();
    const name = p.name || ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || p.program?.name || "shell";
    const pic = icon(p.program, 14, t.dim);
    const st = p.status;
    const pane = p.pane;
    const bottom = paneFrame(layout())?.header?.position === "bottom";
    return h_flex()
      .id(`pane-head-${pane}`)
      .size_full()
      .px(10)
      .gap(8)
      .items_center()
      .bg(t.background)
      .when(bottom, el => el.border_t(1))
      .when(!bottom, el => el.border_b(1))
      .border_color(t.border)
      .text_size(12)
      .on_hover((hovered, cx) => { this.hovered = hovered; cx.notify(); })
      .on_click(() => run("pane.focus", { pane }))
      .when(Boolean(pic), (el) => el.child(pic))
      .child(div().flex_none().truncate().max_w(260).font_medium().text_color(t.foreground).child(name))
      .child(div().flex_1().truncate().text_color(t.dim).child(folder(p.cwd)))
      .when(st === "working", el => el.child(svg("mods/workspace-chrome/spinner.svg").size(12).flex_none().text_color(t.working).spin(900)))
      .when(st === "blocked", el => el.child(div().flex_none().px(6).h(18).flex().items_center().rounded(5).bg(t.blocked + "26").text_size(10.5).font_semibold().text_color(t.blocked).child("Needs you")))
      .when(st === "done", el => el.child(div().size(7).flex_none().rounded(4).bg(t.done)))
      .when(this.hovered, el => el
        .child(this.button(t, `ph-r-${pane}`, "split-right", "pane.split", { direction: "right", pane }))
        .child(this.button(t, `ph-d-${pane}`, "split-down", "pane.split", { direction: "down", pane }))
        .child(this.button(t, `ph-z-${pane}`, p.zoomed ? "unzoom" : "zoom", "pane.zoom", { pane }))
        .child(this.button(t, `ph-x-${pane}`, "close", "pane.close", { pane })));
  }
}
