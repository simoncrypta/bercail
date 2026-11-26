// Focus to hover: the pane under the pointer gets the keyboard.
//
// A pane header copy only hears the pointer over its own strip, so `follow`
// lays an invisible layer behind the header that reaches far up and down; the
// pane's frame clips it to the pane, whether the header sits at the top or the
// bottom. The layer doesn't occlude anything: clicks, selections, scrolling and
// links still reach the terminal underneath.
//
// The pane gets the keyboard as soon as the pointer moves inside it, or, with a
// `delay` in ms, once the pointer has rested there that long. Only real pointer
// moves count: a pane that grows under a still pointer, or a pane chosen with the
// keyboard, keeps the focus until the mouse moves again. Nothing happens while
// Herdr isn't the active window.
import { div } from "gpui-kit";
import { panes, run } from "herdr";

export const DELAY = 0;
const REACH = 100000;

export function follow(view, pane, child, delay = DELAY) {
  const s = (view.__focusToHover ??= { inside: false, wait: null });
  const stop = () => {
    s.wait?.cancel();
    s.wait = null;
  };
  const focus = () => {
    const me = panes().find((p) => p.pane === pane);
    if (s.inside && me && !me.focused && window.is_window_active()) run("pane.focus", { pane });
  };
  return div()
    .size_full()
    .relative()
    .child(div()
      .id(`focus-to-hover-${pane}`)
      .absolute().left(0).w_full().top(-REACH / 2).h(REACH)
      .on_hover((hovered) => {
        s.inside = hovered;
        if (!hovered) stop();
      })
      .on_mouse_down("left", stop)
      .on_mouse_move((_e, cx) => {
        stop();
        if (delay <= 0) {
          s.inside = true;
          focus();
          return;
        }
        s.wait = cx.timer.after(delay, () => {
          s.wait = null;
          focus();
        });
      }))
    .child(child);
}
