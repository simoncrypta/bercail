// bercail Shep: the bercail layout's control room. Two views share one window:
//
// - Shep view: Shep's terminal on the left, the navigator (spaces and agents) on
//   the right. The `work` column is hidden.
// - Space view: the navigator on the left, the shown space's desk, tabs and panels
//   on the right. The `shep` column is hidden.
//
// The view is only which of the layout's `shep` and `work` columns is hidden: hidden
// columns keep their terminals and mods running, so switching never starts or stops
// anything. The app launches into the Shep view. Clicking a space (bercail-spaces)
// shows the space view; the navigator's Shep row (or Ctrl+Shift+H) comes back.
//
// Shep is one hc terminal, `bercail-shep` (label bercail.role=shep), not in any space.
// It is found again by its label, so the same session shows after a restart and no
// second one starts. It starts on its own once per app session; one the person quit
// stays quit until "Start Shep". The terminal runs `bercail shep run`: Shep on Pi.
// With a backend in config.toml ([herdr] backend, the Herdr machine bercail runs on),
// Shep is looked for and started there, and desks' labels name that machine's ids.
//
// props.role:
// - "nav" (default): the navigator's Shep row. Always shown, so it runs the logic: the
//   launch view, Shep's block in `shep-stack`, where the keyboard is, key commands.
// - "header": the bar above Shep's terminal.
// - "empty": the placeholder in `shep-stack` while Shep isn't running.
// - "decisions": the Decisions panel under Shep's terminal (`shep-decisions`, hidden
//   until the header's Decisions toggle shows it): Shep's pending questions as cards,
//   each with Shep's brief and a picker, Shep's recommendation chosen to start with.
//   A two-way door counts down to its deadline; one that defaulted shows for a day.
// - "discuss": the bar of a Discuss dialog: a read-only Pi on a branch of the session
//   the question came from (`bercail shep discuss`). props.token is the question.
// - "modal": the bar of an agent's terminal opened over either view (bercail-agents
//   opens it); props.terminal is the agent, props.back where the keyboard was.
import { View, div, image, svg } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import {
  agents,
  closeOverlay,
  exec,
  focused,
  home,
  layout,
  nextCommand,
  notify,
  openOverlay,
  panes,
  props,
  readTextFile,
  run,
  spaces,
  terminals,
  theme,
  watchFolder,
} from "herdr";

const NAME = "bercail-shep";
const ROLE = "shep";
// Asked of and run in herdr-core's environment (hc exec, hc run), which may lack the
// login shell's PATH (mise, ~/.local/bin). `bercail shep run` keeps the message
// of a Pi that fails on screen until Enter; quitting normally closes the terminal.
const BERCAIL_PATH = 'command -v bercail >/dev/null || PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"';
const SHEP_RUN = `${BERCAIL_PATH}; exec bercail shep run`;
const KEY = "Ctrl+Shift+H";
const CONFIG = "/.config/bercail/config.toml";

// [herdr] backend in this computer's config.toml: the Herdr machine bercail runs on
// (a name from `hc machine ls`), or null for this computer.
export function backendOf(text) {
  let section = "";
  for (const raw of String(text ?? "").split("\n")) {
    const line = raw.replace(/#.*$/, "").trim();
    const sec = line.match(/^\[(.+)\]$/);
    if (sec) section = sec[1].trim();
    const kv = section === "herdr" && line.match(/^backend\s*=\s*"([^"]*)"$/);
    if (kv) return kv[1] || null;
  }
  return null;
}

// Ids across machines: a terminal on box is box/t3 here, and the labels written there
// name ids as box does (sp1 there is box/sp1 here).
export const machineOf = (address) => (address?.includes("/") ? address.slice(0, address.indexOf("/")) : null);
export const qualify = (raw, machine) => (machine && raw ? `${machine}/${raw}` : raw);
// The Decisions panel reads Shep's question ledger through bercail. The person's pick
// (a click or a key in the panel) is recorded by `question answer`, which checks the
// question live first: a local record, not proof of who picked (docs/shep.md,
// "Answering"). Discuss runs `bercail shep discuss` in a dialog; closing it tells Shep.
const PANEL = `${BERCAIL_PATH}; exec bercail shep question panel`;
const ANSWER = `${BERCAIL_PATH}; exec bercail shep question answer <<<"$1"`;
const DISCUSS = `${BERCAIL_PATH}; exec bercail shep discuss "$1"`;
const CLOSED = `${BERCAIL_PATH}; exec bercail shep question closed "$1" "$2"`;
const PANEL_ID = "shep-decisions";
const DISCUSS_ROLE = "shep-discuss";
const KEYS_HINT = "↑↓ card · ←→ or 1-9 choice · Enter answers · d discusses";

export function find(node, id) {
  if (!node || typeof node !== "object") return null;
  if (node.id === id) return node;
  for (const c of node.children ?? []) {
    const hit = find(c, id);
    if (hit) return hit;
  }
  return null;
}

// "shep", "space", or null in a layout without the two views.
export function viewOf(tree) {
  const shep = find(tree, "shep");
  if (!shep || !find(tree, "work")) return null;
  return shep.hidden ? "space" : "shep";
}

// With a backend, only the Shep there; before the config is read, or without one, any.
export function shepTerminal(all = terminals(), backend = S.backend) {
  return (
    all.find(
      (t) =>
        t.state === "live" && t.labels?.["bercail.role"] === ROLE && (!backend || machineOf(t.address) === backend),
    ) ?? null
  );
}

function setView(view) {
  run("layout.hide", { id: view === "shep" ? "work" : "shep" });
  run("layout.show", { id: view === "shep" ? "shep" : "work" });
}

// The view written into a tree, for a layout.set made before a setView has shown.
export function withView(tree, view) {
  const shep = find(tree, "shep"),
    work = find(tree, "work");
  if (shep && work) {
    shep.hidden = view !== "shep";
    work.hidden = view === "shep";
  }
  return tree;
}

// Shep's block in `shep-stack`: `shep-<address>`, added once per terminal and kept,
// like a desk's. Returns the tree to layout.set (with the child to show), a child to
// select, or nothing. `added`: block ids already added, never added twice (the app
// drops a block whose terminal ends; adding it back could loop).
export function stackPlan(tree, shep, added) {
  const stack = find(tree, "shep-stack");
  if (!stack) return {};
  const id = shep ? `shep-${shep.address}` : null;
  const kids = stack.children ?? [];
  const stale = (c) => c.id !== "shep-empty" && c.id !== id;
  const add = Boolean(id) && !kids.some((c) => c.id === id) && !added.has(id);
  const want = id && (add || kids.some((c) => c.id === id)) ? id : "shep-empty";
  if (add || kids.some(stale)) {
    stack.children = kids.filter((c) => !stale(c));
    if (add) stack.children.push({ id, type: "block", content: { terminal: shep.address }, padding: [6, 6] });
    stack.active = want; // with the tree: a separate select can lose to the file
    return { set: tree, added: add ? id : null };
  }
  if (stack.active !== want && kids.some((c) => c.id === want)) return { select: want };
  return {};
}

// Where the keyboard must go so it never types into a hidden terminal: in the Shep
// view, out of a (hidden) pane into Shep; coming back to the space view (`was`: the
// view at the last render), or still on Shep there, to where it was in the space
// (`back`: { pane } or { terminal } of its desk), else the shown tab's first pane.
// `ready`: Shep's block is in the layout (pane.focus fails before). Returns pane.focus
// args, or null.
export function focusPlan(view, was, f, shep, ready, back, ps, space) {
  if (!f) return null;
  if (view === "shep") return f.pane && shep && ready ? { terminal: shep.address } : null;
  const onShep = Boolean(shep) && !f.pane && f.terminal === shep.address;
  if (view !== "space" || (was !== "shep" && !onShep)) return null;
  let to = null;
  if (back?.pane && ps.some((p) => p.pane === back.pane)) to = { pane: back.pane };
  else if (back?.terminal) to = { terminal: back.terminal };
  else if (onShep) {
    const tab = space?.tabs.find((t) => t.active);
    const pane = ps.find((p) => p.tab === tab?.id && p.terminal) ?? ps.find((p) => p.tab === tab?.id);
    if (pane) to = { pane: pane.pane };
  }
  if (!to || (to.pane && to.pane === f.pane) || (to.terminal && !f.pane && to.terminal === f.terminal)) return null;
  return to;
}

// Shared by every copy: whether bercail is installed (and why a check could not tell),
// a start in flight, and the backend (undefined until config.toml is read).
const S = {
  found: null,
  checkError: null,
  check: null,
  starting: false,
  error: null,
  backend: undefined,
  config: null,
};

function readBackend() {
  S.config ??= readTextFile(home() + CONFIG)
    .catch(() => null)
    .then((text) => {
      S.backend = backendOf(text);
    });
  return S.config;
}

// Shared by every copy: the last panel JSON, its error, the load in flight (and whether
// the ledger changed during it), and the copies waiting to redraw.
const D = { view: null, error: null, loading: null, again: false, waiters: [], note: null };

function decisionsChanged() {
  const waiting = D.waiters;
  D.waiters = [];
  for (const wake of waiting) wake();
}
const nextDecisions = () => new Promise((wake) => D.waiters.push(wake));
// The cards that wait on the person: not the ones that already defaulted.
const waiting = () => (D.view?.cards ?? []).filter((c) => !c.defaulted);

function decisionsShown(tree = layout()) {
  const node = find(tree, PANEL_ID);
  return viewOf(tree) === "shep" && Boolean(node) && !node.hidden;
}

export function loadDecisions() {
  // A change during a load may not be in what it read: load once more after it.
  if (D.loading) {
    D.again = true;
    return D.loading;
  }
  // Shep's ledger is where bercail runs: on the backend when there is one.
  D.loading = readBackend()
    .then(() => exec("bash", ["-lc", PANEL], { timeout: 60000, on: S.backend }))
    .then((r) => {
      if (r.code !== 0) throw new Error(r.stderr.trim() || `bercail shep question panel exited ${r.code}`);
      D.view = JSON.parse(r.stdout);
      D.error = null;
    })
    .catch((e) => {
      D.error = String(e?.message ?? e);
    })
    .finally(() => {
      D.loading = null;
      decisionsChanged();
      if (D.again) {
        D.again = false;
        loadDecisions();
      }
    });
  return D.loading;
}

// Each header and Decisions copy watches on its own cx, so one closing stops no other;
// loads in flight are shared. A new question rewrites questions.json; a staged tree or
// a desk changes elsewhere, and a two-way door's countdown runs down, so the open panel
// also looks again (and redraws) every 30 seconds. A
// ledger on the backend can't be watched from here: the count looks every 30 seconds.
// Data never moves the view or the keyboard: only the count and the cards change.
function watchDecisions(cx) {
  cx.spawn(async (cx) => {
    for (;;) {
      await nextDecisions();
      cx.notify();
    }
  });
  cx.timer.every(30000, () => {
    if (S.backend || decisionsShown()) loadDecisions();
  });
  cx.spawn(async (cx) => {
    await (D.loading ?? loadDecisions()); // the other copy's first load will do
    for (;;) {
      const dir = S.backend ? null : D.view?.state; // a backend's path is not this computer's
      let paths = null;
      try {
        if (dir) paths = await watchFolder(dir);
      } catch {}
      // Shep's session files change all the time: only the ledger reloads (and redraws).
      if (paths?.some((p) => p === dir || p.endsWith("/questions.json"))) {
        await loadDecisions();
        cx.notify(); // also ends this loop once a newer mod version runs
      } else if (!paths) await nextDecisions();
    }
  });
}

const REASONS = {
  "repo changed": "the repo",
  "head changed": "new commits",
  "branch changed": "the branch",
  "stagedTree changed": "the staged change",
  "base changed": "the base",
  "worktree changed": "the worktree",
};

function clock(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "at an unknown time";
  const pad = (n) => String(n).padStart(2, "0");
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const today = new Date();
  return d.toDateString() === today.toDateString()
    ? time
    : `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${time}`;
}

// The time to a deadline, in words: "29 min", "1 h 5 min", "under a minute".
function timeLeft(ms) {
  const min = Math.floor(ms / 60000);
  if (min < 1) return "under a minute";
  return min < 60 ? `${min} min` : `${Math.floor(min / 60)} h${min % 60 ? ` ${min % 60} min` : ""}`;
}

// A two-way door's countdown: until its deadline it waits for the person, then Shep's
// next check takes the recommendation, unless the question changed since Shep asked.
// Null for a question with no deadline. `word`: the card's state in words.
function countdown(card, word) {
  if (!card.deadline || card.defaulted) return null;
  const ms = Date.parse(card.deadline) - Date.now();
  const pick = card.recommendation?.choice;
  if (card.status !== "fresh")
    return `two-way door: ${ms > 0 ? `due in ${timeLeft(ms)}, but` : "past its deadline;"} it waits for you while it is ${word}`;
  return ms > 0
    ? `two-way door: defaults to ${pick} in ${timeLeft(ms)}`
    : `two-way door: defaults to ${pick} at Shep's next check`;
}

// A card in words: where (the space as Herdr names it), what (size and stakes), its state,
// and its desk warnings (a desk that is gone or elsewhere still lets the card be answered).
// Question tokens are the ledger's keys, never shown.
export function cardWords(card, all = spaces(), backend = S.backend) {
  const t = card.target ?? {};
  const space = all.find((x) => x.id === qualify(t.space, backend)); // the backend's sp1 is box/sp1 here
  const folder = (t.worktree || t.repo || "")
    .replace(/\/\.git$/, "")
    .split("/")
    .filter(Boolean)
    .pop();
  const where = space?.name || (t.space ? `${folder || "a desk"} (its space is closed)` : folder || t.topic);
  const change = card.change;
  const what = [
    where,
    change ? `${change.lines} ${change.lines === 1 ? "line" : "lines"}` : null,
    change?.stakes === "high" ? "high-stakes" : null,
  ].filter(Boolean);
  const reasons = (card.reasons ?? []).map((r) =>
    r.startsWith("target unavailable: ")
      ? r.slice(20).replace(/^Question target: /, "")
      : r === "policy unavailable; not checked"
        ? "the repo's policy could not be read"
        : (REASONS[r] ?? r),
  );
  const state =
    card.status === "fresh"
      ? { word: "open", why: null }
      : card.status === "defaulted"
        ? {
            word: "defaulted",
            why: `two-way door: nobody picked by ${clock(card.deadline)}, so it took Shep's recommendation, ${card.defaulted?.choice}. Discuss tells Shep if you disagree.`,
          }
        : card.status === "stale"
          ? { word: "stale", why: `Changed since Shep asked: ${reasons.join(", ")}. Shep must ask again.` }
          : { word: "unknown", why: `Can't check it now: ${reasons.join("; ") || "no answer from bercail"}.` };
  return {
    title: what.join(", "),
    ...state,
    asked: `asked ${clock(card.createdAt)}`,
    timer: countdown(card, state.word),
    warnings: (card.warnings ?? []).map((x) => `Warning: ${x}.`),
  };
}

// A card can be answered when the live check found nothing changed and it has choices,
// until a two-way door's deadline: past it, the door takes Shep's recommendation.
export const answerable = (card) =>
  card.status === "fresh" && card.options?.length > 0 && !(card.deadline && Date.parse(card.deadline) <= Date.now());

// The choice a card starts on: Shep's recommendation, else none (Enter waits for a pick).
export function startChoice(card) {
  const i = card.options?.indexOf(card.recommendation?.choice) ?? -1;
  return i >= 0 ? i : null;
}

// The question's Discuss terminal, while one runs (with a backend, only there).
export function discussTerminal(token, all = terminals(), backend = S.backend) {
  return (
    all.find(
      (t) =>
        t.state === "live" &&
        t.labels?.["bercail.role"] === DISCUSS_ROLE &&
        t.labels?.["bercail.question"] === token &&
        (!backend || machineOf(t.address) === backend),
    ) ?? null
  );
}

// The branch's terminal in a dialog that a click beside it doesn't close: closing
// tells Shep, so only ✕ (or the branch ending after /pick) does.
export function discussDialog(address, token, opening, f) {
  const back = { pane: f?.pane ?? null, terminal: f?.terminal ?? null };
  return {
    kind: "dialog",
    modal: true,
    width: 0.86,
    height: 0.86,
    layout: {
      type: "column",
      children: [
        {
          type: "block",
          size: { px: 34 },
          content: { mod: NAME, props: { role: "discuss", terminal: address, token, opening, back } },
        },
        { type: "block", content: { terminal: address }, padding: [6, 6] },
      ],
    },
  };
}

// Starts the question's branch (or finds the one running) and opens it in a dialog.
async function openDiscuss(card) {
  await readBackend();
  let address = discussTerminal(card.token)?.address;
  if (!address) {
    const r = await exec("hc", [
      "run",
      "--bg",
      "--json",
      "--no-parent",
      "--no-notify",
      "--rm",
      "--name",
      `shep-discuss-${card.token.replace("@", "-").toLowerCase()}`,
      ...(S.backend ? ["--on", S.backend] : ["--cwd", home()]),
      "--label",
      `bercail.role=${DISCUSS_ROLE}`,
      "--label",
      `bercail.question=${card.token}`,
      "bash",
      "-lc",
      DISCUSS,
      NAME,
      card.token,
    ]);
    if (r.code !== 0) throw new Error((r.stderr || r.stdout).trim() || `hc run exited ${r.code}`);
    const raw = JSON.parse(r.stdout).address;
    address = raw.includes("/") ? raw : qualify(raw, S.backend);
  }
  const opening = `o${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
  openOverlay(discussDialog(address, card.token, opening, focused()));
}

function checkBercail() {
  S.check ??= readBackend()
    .then(() =>
      exec("hc", [
        "exec",
        ...(S.backend ? ["--on", S.backend] : []),
        "bash",
        "-lc",
        `${BERCAIL_PATH}; command -v bercail`,
      ]),
    )
    .then((r) => {
      S.found = r.code === 0;
      // hc's own error (an unknown machine, one that is away), not bercail missing.
      const hcError = !S.found && r.stderr.trim().startsWith('{"error"') && JSON.parse(r.stderr).error?.message;
      S.checkError = hcError || null;
    })
    .catch((e) => {
      S.found = false;
      S.checkError = String(e?.message ?? e);
    })
    .finally(() => {
      S.check = null;
    });
  return S.check;
}

// One Shep: none while one is live or starting. hc names are unique among live
// terminals, so a start that races one the list doesn't show yet is refused: fine.
async function startShep() {
  await readBackend(); // which Shep counts depends on it
  if (S.starting || shepTerminal()) return;
  S.starting = true;
  S.error = null;
  try {
    await checkBercail();
    if (!S.found) return;
    const r = await exec("hc", [
      "run",
      "--bg",
      "--json",
      "--no-parent",
      "--no-notify",
      "--rm",
      "--name",
      NAME,
      // On the backend, hc starts it in that machine's home.
      ...(S.backend ? ["--on", S.backend] : ["--cwd", home()]),
      "--label",
      `bercail.role=${ROLE}`,
      "bash",
      "-lc",
      SHEP_RUN,
    ]);
    if (r.code !== 0 && !/"name_taken"/.test(r.stderr + r.stdout)) throw new Error((r.stderr || r.stdout).trim());
  } catch (e) {
    S.error = String(e?.message ?? e);
    notify({ title: "bercail: Shep did not start", body: S.error, level: "error" });
  } finally {
    S.starting = false;
  }
}

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

export default class BercailShep extends View {
  init(_props, cx) {
    this.role = props()?.role ?? "nav";
    if (this.role === "modal" || this.role === "discuss") return;
    cx.spawn(async (cx) => {
      await checkBercail();
      cx.notify();
    });
    if (this.role === "header" || this.role === "decisions") watchDecisions(cx);
    if (this.role === "decisions") {
      this.h = cx.focus_handle();
      this.sel = 0; // the card the keys act on
      this.picked = {}; // token -> the choice's index, once the person moved it
      this.busy = new Set(); // tokens whose answer is on its way
    }
    if (this.role !== "nav") return;
    this.added = new Set(); // Shep block ids this copy added
    this.back = {}; // space id -> { pane } or { terminal }: where the keyboard was
    this.pending = null; // { view, at }: a view this copy set that layout() doesn't show yet
    // Once per app session (a mod reload keeps globalThis): the Shep view, and Shep.
    // Done in sync(): layout() and terminals() are empty this early.
    const app = (globalThis.bercailShep ??= {});
    this.launch = !app.launched;
    this.autostart = !app.launched;
    app.launched = true;
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        await this.command(c);
        cx.notify();
      }
    });
  }

  async command(raw) {
    const view = viewOf(layout());
    const [c, arg] = raw.split(/:(.*)/s);
    switch (c) {
      case "toggle":
        if (view) this.show(view === "shep" ? "space" : "shep");
        break;
      case "show":
        if (view) this.show("shep");
        break;
      case "space":
        if (view) this.show("space");
        break;
      case "start":
        await startShep();
        break;
      // Ctrl+Space: Herdr's own Go to… search, over the space view so a pick shows.
      case "goto":
        this.inSpace(view, ["mod.open", { name: "picker" }]);
        break;
      // A bercail-desk key pressed in the Shep view (its `keys` copy sends it here).
      case "desk":
        if (arg) this.inSpace(view, [`bercail-desk.${arg}`]);
        break;
    }
  }

  // Runs a command in the space view: from the Shep view, once that shows and the
  // keyboard is back in the space, so a command that moves it (an agent, a pick) wins.
  inSpace(view, cmd) {
    if (view === "shep") this.show("space", cmd);
    else run(...cmd);
  }

  // then: [name, args] to run once the view shows.
  show(view, then = null) {
    this.pending = { view, at: Date.now(), then };
    setView(view);
  }

  // Runs on every render: Herdr re-renders on any live change.
  sync() {
    const tree = layout();
    const view = viewOf(tree);
    if (!view) return view;
    if (this.launch) {
      this.launch = false;
      if (view === "space") this.show("shep");
    }
    const then = this.pending?.view === view ? this.pending.then : null;
    if (this.pending?.view === view || Date.now() - (this.pending?.at ?? 0) > 2000) this.pending = null;
    // Start Shep once the core has listed its terminals (it lists them after the
    // layout): before that, terminals() can't tell whether Shep runs already.
    if (this.autostart && terminals().length > 0) {
      this.autostart = false;
      startShep();
    }
    const shep = shepTerminal();
    const plan = stackPlan(tree, shep, this.added);
    if (plan.set) {
      if (plan.added) this.added.add(plan.added);
      // layout.set writes the whole tree: a view switch still on its way would be undone.
      run("layout.set", { layout: this.pending ? withView(plan.set, this.pending.view) : plan.set });
    } else if (plan.select) {
      run("layout.select", { stack: "shep-stack", child: plan.select });
    }
    const f = focused();
    const ps = panes();
    const was = this.view;
    this.view = view;
    // Where the keyboard is in the space, kept while the space view stays: hiding the
    // Shep view moves it on its own first.
    if (view === "space" && was === "space" && f?.space) {
      const desk =
        f.terminal &&
        terminals().find(
          (t) =>
            t.address === f.terminal &&
            t.labels?.["bercail.role"] === "agent" &&
            qualify(t.labels?.["bercail.space"], machineOf(t.address)) === f.space,
        );
      if (f.pane) this.back[f.space] = { pane: f.pane };
      else if (desk) this.back[f.space] = { terminal: f.terminal };
    }
    const ready =
      Boolean(shep) &&
      !plan.set &&
      Boolean(find(tree, "shep-stack")?.children?.some((c) => c.id === `shep-${shep.address}`));
    const space = spaces().find((s) => s.id === f?.space);
    const to = focusPlan(view, was, f, shep, ready, this.back[f?.space], ps, space);
    if (to) run("pane.focus", to);
    if (then) run(...then);
    return view;
  }

  render(cx) {
    const t = theme();
    switch (this.role) {
      case "header":
        return this.header(t);
      case "empty":
        return this.empty(t);
      case "decisions":
        return this.decisions(t);
      case "modal":
        return this.modal(t);
      case "discuss":
        return this.discussBar(t);
    }
    const view = this.sync();
    const shep = shepTerminal();
    const on = view === "shep";
    const dot = shep ? t.ansi2 : S.found === false ? t.blocked : t.dim;
    // The sidebar's rail (narrower than 160px): the mark alone.
    const rail = (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;
    return h_flex()
      .size_full()
      .px(rail ? 0 : 8)
      .items_center()
      .justify_center()
      .bg(t.chrome)
      .text_size(13)
      .child(
        h_flex()
          .id("shep-row")
          .h(34)
          .px(8)
          .gap(9)
          .items_center()
          .rounded(8)
          .when(!rail, (el) => el.flex_1())
          .when(on, (el) => el.bg(t.selected))
          .when(!on, (el) => el.hover((s) => s.bg(t.hover)))
          .cursor_pointer()
          .tooltip(on ? "Shep, the orchestrator" : `Back to Shep (${KEY})`)
          .on_click(() => {
            if (view) this.show("shep");
          })
          .child(
            on || rail
              ? h_flex()
                  .size(18)
                  .flex_none()
                  .rounded(5)
                  .bg(on ? t.solid : t.raised)
                  .items_center()
                  .justify_center()
                  .text_size(10.5)
                  .font_bold()
                  .text_color(on ? t.solid_foreground : t.foreground)
                  .child("S")
              : svg("mods/workspace-chrome/chevron-left.svg").size(14).mx(2).flex_none().text_color(t.muted),
          )
          .when(!rail, (el) =>
            el
              .child(
                div()
                  .flex_1()
                  .truncate()
                  .text_color(t.foreground)
                  .font_medium()
                  .child(on ? "Shep" : "Back to Shep"),
              )
              .when(!on, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(KEY)))
              .child(div().size(7).mx(3).flex_none().rounded(4).bg(dot)),
          ),
      );
  }

  header(t) {
    const shep = shepTerminal();
    const word = shep ? "running" : S.found === false ? "bercail missing" : S.starting ? "starting" : "stopped";
    const color = shep ? t.ansi2 : S.found === false ? t.blocked : t.dim;
    return h_flex()
      .size_full()
      .px(12)
      .gap(8)
      .items_center()
      .bg(t.chrome)
      .text_size(12.5)
      .text_color(t.muted)
      .child(div().size(7).rounded(4).bg(color))
      .child(div().text_color(t.foreground).font_semibold().child("Shep"))
      .child(
        div()
          .flex_1()
          .truncate()
          .text_color(t.dim)
          .child(shep?.title || "the orchestrator for every desk"),
      )
      .child(div().text_color(color).child(word))
      .child(this.decisionsToggle(t))
      .child(div().text_size(11).text_color(t.dim).child(`${KEY} spaces`));
  }

  // In the header: the count of open decisions, and the person's click shows or hides
  // the panel. A new decision changes the count only.
  decisionsToggle(t) {
    const n = waiting().length;
    const open = decisionsShown();
    return (
      div()
        .id("shep-decisions-toggle")
        .flex_none()
        .px(8)
        .py(2)
        .rounded(5)
        .cursor_pointer()
        .text_color(n ? t.foreground : t.dim)
        .when(open, (el) => el.bg(t.selected))
        .when(!open, (el) => el.hover((s) => s.bg(t.hover)))
        .tooltip(open ? "Hide decisions" : "Show what Shep asks you")
        // The header drags the window; a press on the toggle doesn't.
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
        .on_click(() => {
          if (!find(layout(), PANEL_ID)) return;
          run(open ? "layout.hide" : "layout.show", { id: PANEL_ID });
          if (!open) loadDecisions();
        })
        .child(n ? `Decisions ${n}` : "Decisions")
    );
  }

  // The Decisions panel: the keyboard is here once the person clicks in it, or opens it
  // from the header. Keys never come from a command (nextCommand): only this panel.
  decisions(t) {
    const cards = D.view?.cards ?? [];
    this.sel = Math.max(0, Math.min(cards.length - 1, this.sel));
    const checked = D.view?.at ? `checked ${clock(D.view.at)}` : D.loading ? "checking…" : "";
    const list = v_flex().id("decision-list").flex_1().min_h(0).px(10).pb(10).gap(8).overflow_y_scrollbar();
    const say = (text, color = t.dim) => div().px(12).py(6).text_color(color).child(text);
    return v_flex()
      .id("decisions-root")
      .size_full()
      .bg(t.background)
      .border_t(1)
      .border_color(t.border)
      .text_size(12.5)
      .text_color(t.muted)
      .track_focus(this.h)
      .on_key_down((e, cx) => this.key(e, cx))
      .on_mouse_down("left", () => this.h.focus())
      .child(
        h_flex()
          .h(32)
          .flex_none()
          .px(12)
          .gap(8)
          .items_center()
          .child(div().text_color(t.foreground).font_semibold().child("Decisions"))
          .child(
            div()
              .flex_1()
              .truncate()
              .text_color(t.dim)
              .child(waiting().length ? `${waiting().length} waiting on you · ${KEYS_HINT}` : ""),
          )
          .child(div().text_size(11).text_color(t.dim).child(checked)),
      )
      .when(Boolean(D.error), (el) => el.child(say(`Can't read Shep's questions: ${D.error}`, t.blocked)))
      .when(Boolean(D.note), (el) => el.child(say(D.note, t.blocked)))
      .when(!cards.length && !D.error, (el) => el.child(say(D.view ? "Nothing waits on you." : "Loading…")))
      .child(list.children(cards.map((c, i) => this.card(t, c, i === this.sel, i))));
  }

  choiceOf(c) {
    return this.picked[c.token] ?? startChoice(c);
  }

  key(e, cx) {
    const cards = D.view?.cards ?? [];
    const c = cards[this.sel];
    const k = e.keystroke;
    const n = c?.options?.length ?? 0;
    const choose = (i) => {
      if (c && answerable(c)) this.picked[c.token] = i;
    };
    if (k === "down" || k === "j") this.sel = Math.min(cards.length - 1, this.sel + 1);
    else if (k === "up" || k === "k") this.sel = Math.max(0, this.sel - 1);
    else if (k === "right" && n) choose(((this.choiceOf(c) ?? -1) + 1) % n);
    else if (k === "left" && n) choose(((this.choiceOf(c) ?? 0) - 1 + n) % n);
    else if (/^[1-9]$/.test(k) && Number(k) <= n) choose(Number(k) - 1);
    else if (k === "enter" && c) this.accept(c, cx);
    else if (k === "d" && c) this.discuss(c, cx);
    else return;
    cx.stop_propagation();
    cx.notify();
  }

  card(t, c, on, i) {
    const w = cardWords(c);
    const color = w.word === "open" || w.word === "defaulted" ? t.dim : w.word === "stale" ? t.blocked : t.unknown;
    const can = answerable(c) && !this.busy.has(c.token);
    const at = this.choiceOf(c);
    const rec = c.recommendation;
    const button = (id, label, enabled, onClick) =>
      div()
        .id(id)
        .px(10)
        .py(3)
        .rounded(5)
        .bg(t.raised)
        .text_color(enabled ? t.foreground : t.dim)
        .when(enabled, (el) =>
          el
            .cursor_pointer()
            .hover((s) => s.bg(t.hover))
            .on_click(onClick),
        )
        .child(label);
    const chip = (o, j) =>
      div()
        .id(`decision-choice-${c.token}-${j}`)
        .px(9)
        .py(2)
        .rounded(5)
        .border(1)
        .border_color(t.border)
        .when(j === at && answerable(c), (el) => el.bg(t.solid).text_color(t.solid_foreground))
        .when(j !== at || !answerable(c), (el) => el.text_color(answerable(c) ? t.foreground : t.dim))
        .when(can, (el) =>
          el.cursor_pointer().on_click((_e, cx) => {
            this.sel = i;
            this.picked[c.token] = j;
            this.h.focus();
            cx.notify();
          }),
        )
        .child(`${j + 1} ${o}${o === rec?.choice ? " ★" : ""}`);
    return v_flex()
      .id(`decision-${c.token}`)
      .flex_none()
      .p(10)
      .gap(6)
      .rounded(8)
      .border(1)
      .border_color(on ? t.solid : t.border)
      .bg(t.chrome)
      .child(
        h_flex()
          .gap(8)
          .child(div().flex_1().truncate().font_semibold().text_color(t.foreground).child(w.title))
          .child(div().flex_none().text_size(11).text_color(color).child(w.word)),
      )
      .child(div().text_color(t.foreground).child(c.prompt))
      .when(Boolean(c.brief), (el) => el.child(div().text_color(t.muted).child(c.brief)))
      .when(Boolean(rec), (el) => el.child(div().text_color(t.dim).child(`Shep recommends ${rec.choice}: ${rec.why}`)))
      .when(c.options?.length > 0 && !c.defaulted, (el) =>
        el.child(h_flex().gap(6).flex_wrap().children(c.options.map(chip))),
      )
      .when(!c.options?.length, (el) => el.child(div().text_color(t.dim).child("No choices: answer Shep in chat.")))
      .when(Boolean(w.why), (el) => el.child(div().text_color(color).child(w.why)))
      .children(w.warnings.map((x) => div().text_color(t.unknown).child(x)))
      .child(
        h_flex()
          .gap(8)
          .items_center()
          .child(div().flex_1().text_size(11).text_color(t.dim).child(w.asked))
          .when(Boolean(w.timer), (el) =>
            el.child(div().flex_none().text_size(11).text_color(t.foreground).child(w.timer)),
          )
          .child(
            button(`decision-discuss-${c.token}`, c.discussed ? "Continue discussion" : "Discuss", true, (_e, cx) =>
              this.discuss(c, cx),
            ),
          )
          .when(c.options?.length > 0 && !c.defaulted, (el) =>
            el.child(
              button(
                `decision-accept-${c.token}`,
                this.busy.has(c.token) ? "Answering…" : at === null ? "Pick a choice" : `Answer ${c.options[at]}`,
                can && at !== null,
                (_e, cx) => this.accept(c, cx),
              ),
            ),
          ),
      );
  }

  // The person's pick: once per card at a time, recorded on the machine with the ledger.
  accept(c, cx) {
    const at = this.choiceOf(c);
    if (!answerable(c) || at === null || this.busy.has(c.token)) return;
    this.busy.add(c.token);
    const input = JSON.stringify({
      requestId: `panel-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`,
      token: c.token,
      choice: c.options[at],
      source: "panel picker",
    });
    cx.spawn(async (cx) => {
      let r;
      try {
        r = await readBackend().then(() =>
          exec("bash", ["-lc", ANSWER, NAME, input], { timeout: 60000, on: S.backend }),
        );
      } catch (e) {
        r = { code: 1, stdout: "", stderr: String(e?.message ?? e) };
      }
      let out = null;
      try {
        out = JSON.parse(r.stdout);
      } catch {}
      D.note =
        r.code !== 0
          ? `Not recorded: ${r.stderr.trim() || `exit ${r.code}`}`
          : out?.accepted
            ? null
            : `Not recorded: ${out?.reason ?? "no answer from bercail"}.`;
      this.busy.delete(c.token);
      await loadDecisions();
      cx.notify();
    });
  }

  // The person's click or d: the question's branch, in a dialog over the window.
  discuss(c, cx) {
    cx.spawn(async (cx) => {
      try {
        await openDiscuss(c);
        D.note = null;
      } catch (e) {
        D.note = `Discuss did not open: ${String(e?.message ?? e)}`;
      }
      cx.notify();
    });
  }

  // The Discuss dialog's bar: which question, how to answer, and ✕.
  discussBar(t) {
    const { token, overlay } = props() ?? {};
    const c = (D.view?.cards ?? []).find((x) => x.token === token);
    return h_flex()
      .size_full()
      .px(12)
      .gap(8)
      .items_center()
      .bg(t.chrome)
      .border_b(1)
      .border_color(t.border)
      .text_size(12.5)
      .text_color(t.muted)
      .child(div().flex_none().font_semibold().text_color(t.foreground).child("Discuss"))
      .child(
        div()
          .flex_1()
          .truncate()
          .text_color(t.dim)
          .child(c?.prompt ?? ""),
      )
      .child(
        div()
          .flex_none()
          .text_size(11)
          .text_color(t.dim)
          .child(
            c?.defaulted ? "read-only branch · it defaulted; closing tells Shep" : "read-only branch · /pick answers",
          ),
      )
      .child(
        div()
          .id("discuss-close")
          .px(8)
          .py(2)
          .rounded(5)
          .cursor_pointer()
          .hover((s) => s.bg(t.hover).text_color(t.foreground))
          .on_click(() => closeOverlay(overlay))
          .child("✕"),
      );
  }

  empty(t) {
    const missing = S.found === false;
    const busy = S.starting || S.found === null;
    const act = (cx, f) =>
      cx.spawn(async (cx) => {
        await f();
        cx.notify();
      });
    const button = (id, label, f) =>
      div()
        .id(id)
        .px(14)
        .py(6)
        .rounded(6)
        .bg(t.solid)
        .text_color(t.solid_foreground)
        .hover((s) => s.opacity(0.85))
        .on_click((_e, cx) => act(cx, f))
        .child(label);
    const body = v_flex()
      .size_full()
      .items_center()
      .justify_center()
      .gap(10)
      .px(24)
      .bg(t.background)
      .text_color(t.muted)
      .text_size(13);
    if (missing) {
      return body
        .child(
          div()
            .text_color(t.foreground)
            .font_semibold()
            .child(S.backend ? `bercail is not installed on ${S.backend}` : "bercail is not installed"),
        )
        .child(
          div()
            .max_w(460)
            .text_center()
            .child("Shep starts with bercail shep run. Install bercail (bercail.dev), then check again."),
        )
        .child(button("shep-check", "Check again", checkBercail))
        .child(div().text_color(t.dim).text_size(12).child("Your spaces work without it: pick one on the right."))
        .when(Boolean(S.checkError), (el) =>
          el.child(div().max_w(460).text_center().text_color(t.blocked).text_size(12).child(S.checkError)),
        );
    }
    if (busy) return body.child("Starting Shep…");
    return body
      .child(div().text_color(t.foreground).font_semibold().child("Shep is not running"))
      .child(button("shep-start", "Start Shep", startShep))
      .child(div().text_color(t.dim).text_size(12).child("Runs Shep on Pi, in its own session."))
      .when(Boolean(S.error), (el) =>
        el.child(div().max_w(460).text_center().text_color(t.blocked).text_size(12).child(S.error)),
      );
  }

  // The bar of an agent opened in a dialog. Its terminal is the one in its pane or
  // desk: typing here types there. Closing puts the keyboard back where it was.
  modal(t) {
    const { terminal, overlay } = props() ?? {};
    const k = terminals().find((x) => x.address === terminal);
    const a = agents().find((x) => x.address === terminal);
    const status = a?.status ?? (k?.status === "error" ? "blocked" : k?.status) ?? null;
    const color = t[status] ?? t.dim;
    const spaceId = a?.space ?? qualify(k?.labels?.["bercail.space"], machineOf(k?.address)) ?? null;
    const space = spaces().find((s) => s.id === spaceId);
    const desk = k?.labels?.["bercail.role"] === "agent";
    const pic = icon(k?.program ?? a?.program, 14, t.foreground);
    const button = (id, label, onClick) =>
      div()
        .id(id)
        .px(8)
        .py(2)
        .rounded(5)
        .text_color(t.muted)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click(onClick)
        .child(label);
    return h_flex()
      .size_full()
      .px(12)
      .gap(8)
      .items_center()
      .bg(t.chrome)
      .border_b(1)
      .border_color(t.border)
      .text_size(12.5)
      .text_color(t.muted)
      .child(div().size(7).flex_none().rounded(4).bg(color))
      .when(Boolean(pic), (el) => el.child(pic))
      .child(
        div()
          .flex_none()
          .font_semibold()
          .text_color(t.foreground)
          .child(desk ? "Desk" : k?.name || a?.program?.name || k?.program?.name || terminal || ""),
      )
      .when(Boolean(space), (el) =>
        el.child(div().flex_none().max_w(220).truncate().text_color(t.dim).child(space.name)),
      )
      .child(
        div()
          .flex_1()
          .truncate()
          .text_color(t.dim)
          .child(a?.title ?? k?.title ?? ""),
      )
      .when(Boolean(status), (el) => el.child(div().flex_none().text_color(color).child(status)))
      .when(Boolean(space), (el) =>
        el.child(
          button("modal-space", "Show in space", () => {
            this.left = true;
            closeOverlay(overlay);
            run("space.select", { id: space.id });
            if (viewOf(layout())) setView("space");
            if (!desk) run("agent.focus", { terminal });
          }),
        ),
      )
      .child(button("modal-close", "✕", () => closeOverlay(overlay)));
  }

  // The dialog closed (✕, a click beside it, its terminal ended): the keyboard goes
  // back where it was, unless "Show in space" took it elsewhere.
  async close() {
    if (this.role === "discuss") return this.discussClosed();
    if (this.role !== "modal" || this.left) return;
    this.restoreFocus();
  }

  // The keyboard back where it was before the dialog opened.
  restoreFocus() {
    const back = props()?.back;
    if (back?.pane && panes().some((p) => p.pane === back.pane)) run("pane.focus", { pane: back.pane });
    else if (back?.terminal && terminals().some((x) => x.address === back.terminal && x.state === "live")) {
      run("pane.focus", { terminal: back.terminal });
    }
  }

  // The Discuss dialog closed (✕, or its Pi ended after /pick): end the branch's Pi
  // (it continues on the next open) and tell Shep, which the closed op skips when a
  // pick already did. Both run where the branch and the ledger are.
  async discussClosed() {
    const { terminal, token, opening } = props() ?? {};
    await readBackend();
    try {
      await exec("hc", ["kill", terminal], { timeout: 10000 });
    } catch {}
    try {
      await exec("bash", ["-lc", CLOSED, NAME, token, opening], { timeout: 30000, on: S.backend });
    } catch {}
    loadDecisions();
    this.restoreFocus();
  }
}
