# bercail

Herdr's layout with a desk: each space gets one sticky agent in its own column
on the left of the work area, beside the space's tabs (Shell, Review) and a
files/changes panel on the right. Tabs come and go around the desk; the agent
stays. When the desk agent finishes with uncommitted changes, a Review tab
opens on them by itself. It is the app half of
[bercail](https://github.com/simoncrypta/bercail), and works on its own too.

![bercail](preview.png)

## Needs

- Easiest: install [bercail](https://github.com/simoncrypta/bercail)
  (`bercail install`). It installs the Herdr app and herdr-core if they
  are missing, adds this layout, its mod and its keys, and gives you
  worktrees, handoff and webhooks too. The rest of this section is for
  adding the layout on its own.
- **The Herdr app** (`herdr-app`, home `~/.config/herdr-app`) with
  herdr-core (`hc`). Its installer brings both and the app keeps them
  updated: `curl -fsSL https://releases.herdr.dev/app/install.sh | sh`
  (see [herdr.dev](https://herdr.dev)). Built and checked with herdr-app
  0.1.9 and hc 0.1.14; no older version has been tried.
- Not the `herdr` terminal (`~/.config/herdr`, `herdr plugin install`,
  `herdr-plugin.toml`): it has no layouts or mods, and this layout does not
  run in it.
- To add it by hand: copy `layouts/bercail.json` and `mods/bercail-desk/`
  into `~/.config/herdr-app/`, merge the `layout:bercail` section of
  `keys.json` into `~/.config/herdr-app/keys.json`, run `herdr-app check
  ~/.config/herdr-app/mods/bercail-desk`, then switch with `ctrl-shift-l`.

## What you see

Left to right, under no system title bar (`titlebar: "none"`, macOS traffic
lights at 12,16):

- **Sidebar**, 268px wide (min 44, max 480, not resizable), `chrome`
  background. Herdr's own brand row (46px), then the spaces list and the
  agents list sharing the rest equally (min 90px each), then the footer
  (69px, Settings / Add machine).
- **Work column**: the tab bar (42px), the work body, and the status bar
  (28px). The work body has 8px padding and 8px gaps between its three parts:
  - **The desk**, weight 1 (min 320px): a card with `background` fill, 1px
    `border`, radius 10, and a 1px `accent` border while the keyboard is in
    it. A 32px header row on `chrome`: a 7px status dot, the agent's program
    name (semibold, `foreground`), its terminal title (`dim`, truncated), and
    the status word in the status color. Below it, the agent's terminal with
    6px padding. With no desk agent, the column shows "No agent on this
    desk" and one button per agent (Claude Code, Codex, Grok; the last one
    picked filled with `solid`, uninstalled ones at 45% opacity), and a hint
    line.
  - **The tabs**, weight 1, so desk and tabs split the width evenly: the
    shown tab's panes as cards (radius 10, 1px `border`, `accent` on focus,
    8px gaps, a 30px `pane` header always shown, also on a lone pane).
  - **Files / Changes**, a 240px stack showing Herdr's `files` or `changes`
    panel.
- Terminal text padding is 14×12px. Colors come from the user's theme; the
  layout sets none.

## How it behaves

- **The desk agent** belongs to the shown space. Switching spaces points the
  desk at that space's agent, or shows the empty desk.
- **Statuses** show in the header dot and word: working `working`, blocked
  `blocked`, done `done`, idle `idle` (each its theme color); no status is
  `dim`.
- **Review**: when a desk agent arrives at `done` (or goes working → idle)
  and its checkout has uncommitted changes, the space gets a tab named
  Review running the review tool (default `tuicr -w`, watching the
  uncommitted tree; `tuicr pr N` when the checkout's PR is someone else's).
  A live Review tab is only selected, never restarted; one whose tool quit
  is replaced. At most one automatic open per space every 15s; a space that
  isn't shown opens it the next time it is.
- **Keys** (keys.json section `layout:bercail`):
  - `ctrl-shift-a` focuses the desk agent, or starts one: the last agent
    picked on an empty desk, else `[agent] command` from
    `~/.config/bercail/config.toml` (`cursor-agent` when there is none).
  - `ctrl-shift-r` Review (opens even on a clean tree); `ctrl-shift-s` the
    first tab (Shell).
  - `ctrl-shift-f` / `ctrl-shift-g` show Files / Changes; the same key again
    hides the panel.
  - `ctrl-alt-left/right` move between panes. Left from the leftmost
    pane enters the desk; right from the desk returns to the pane you came
    from. (`alt-h/j/k/l`, Herdr's `pane.go`, still move up and down.)
  - Spaces go by the sidebar's order: a space's repo is git's common dir
    where its first terminal is, and a linked worktree's space sits under
    the first space on its repo's main checkout. `alt-up/down` step through
    the spaces not nested that way (from a worktree, its repo's neighbors);
    `ctrl-alt-up/down` step through the current repo's spaces, main checkout
    and worktrees, wrapping. Outside a repo they do nothing.
  - `alt-shift-up/down` step through the agents: spaces in sidebar order,
    each space's desk first, then its pane agents. A desk is focused in its
    space's desk column.
  - `ctrl-shift-q` closes the space.
- **Clicks**: an empty desk's buttons start that agent and remember it.
  Everything else is Herdr's own (sidebar, tabs, panes, panels).
- The first tab is renamed Shell when the desk agent starts in it.

## Built from

- `layouts/bercail.json`, cloned from Herdr's `main` (0.1.6). Node tree:
  `root` row → `sidebar` column (`brand` workspace-chrome, `sidebar-lists`
  column of `spaces` and `agents`, `sidebar-footer` workspace-chrome with
  `props: {footer: true}`) and `work` column (`tabs` mod, `work-body` row,
  `status` workspace-status). `work-body`: `desk` column (`desk-header`
  block = `bercail-desk` mod; `agent-stack` stack of `empty`, the
  `bercail-desk` mod with `props: {role: "empty"}`, plus one
  `{terminal: …}` block per desk, `desk-<address>`, that the mod adds), `main` block `{tab: "active", pane: {...}}`,
  `panel-body` stack of `files` and `changes`.
- Shipped mods used: `workspace-chrome`, `spaces`, `agents`, `tabs`, `pane`,
  `files`, `changes`, `workspace-status`.
- `mods/bercail-desk` (`place: "none"`), one script, two roles:
  - `header` (default): draws the header row, takes the key commands
    (`nextCommand()`), and on every render shows the space's desk: the first
    time, it adds the desk's block with `layout.set` (already selected);
    after that, it only picks the stack child with `layout.select`.
  - `empty`: the agent picker; lists choices from `knownAgents()` and keeps
    the last pick in shared state `bercail.agent`.
- A desk agent is an hc terminal: `hc run --bg --json --keep
  --outlive-parent --no-notify --parent <first pane of the first tab> --cwd
  <its cwd> --label bercail.role=agent --label bercail.space=<space id>
  <argv>` (codex gets `--no-daemon`). The mod finds it again by those labels
  in `terminals()`.
- Commands it runs: `pane.focus`, `pane.go`, `tab.select`, `tab.new` (Review,
  with `argv`), `tab.close`, `tab.rename`, `layout.set`, `layout.select`,
  `layout.show`, `layout.hide`. Programs: `hc`, `git status --porcelain`,
  `gh pr view` / `gh api user` (whose PR it is), the review tool, `bash`.
- `herdr` functions: `terminals`, `spaces`, `panes`, `focused`, `agents`,
  `knownAgents`, `layout`, `nextCommand`, `exec`, `run`, `notify`, `shared`,
  `setShared`, `readTextFile`, `home`, `theme`, `props`.
- Commands from outside: `herdr-app do bercail-desk.<command>` or
  `bercail-desk.<command>:<terminal>` (acts on that terminal's space), e.g.
  an agent opening its own Review with `bercail-desk.review:$HC_TERMINAL_ID`.
- With [bercail](https://github.com/simoncrypta/bercail) installed, the mod
  also keeps `bercail notify run` alive as the hidden hc terminal
  `bercail-notify` (checked every 60s), which posts desk status changes to
  webhooks.

## Watch out

- An agent block can't take the keyboard from a command, and `agent.focus`
  moves focus to the parent pane. The desk is a **terminal** block, not
  `{agent: "focused"}`: one per desk, never repointed. A single block
  repointed per space could show a desk blank (cursor top-left) until its
  agent redrew.
- The desk is a layout block, not a pane of the tab: `pane.go` never reaches
  or leaves it. That is why the arrow keys are the mod's commands.
- Herdr rewrites `layouts/bercail.json` as it is used (the `agent` block's
  terminal, the stack's active child, sizes). Don't treat those fields as
  part of the design.
- Keys live in `keys.json` under `layout:bercail`; adding the layout folder
  alone doesn't bind them. Merge that section without touching the others.
  `ctrl-alt-arrows` and `alt-up/down` there override `global`'s `pane.go`
  and `space.prev/next` while this layout shows; a `terminal` key wins over
  both.
- Herdr's `agent.next/prev` don't reach desks the way the desk wants (a desk
  is a sub-agent, and `agent.focus` lands on its parent pane): the agent keys
  are the mod's.
- Start desks with `TERM=xterm-256color`: `hc run` passes on the caller's
  environment, and a headless caller's `TERM=dumb` leaves the agent without
  colors or key handling.
- Review assumes [tuicr](https://github.com/agavra/tuicr) (≥ 0.20); set
  `[layout] review` in `~/.config/bercail/config.toml` to use another tool,
  or `auto_review = false` to open Review only by key.
- Without a Shell terminal in the space's first tab, no desk can start (the
  desk is its sub-agent); the mod says so.
- The webhook follower is only started when `bercail` is on PATH.

## Done when

- `herdr-app check mods/bercail-desk` passes and `layout.switch
  {"name":"bercail"}` shows the sidebar, the desk, the tabs and Files.
- In a space with no desk agent, the desk shows the picker; clicking Claude
  Code starts `claude` as an hc terminal labelled `bercail.role=agent` and
  `bercail.space=<id>`, and the desk shows it with its status.
- Switching to another space shows that space's desk (or the picker);
  switching back shows the first agent, still running.
- `ctrl-shift-a` from a pane puts the keyboard in the desk;
  `ctrl-alt-right` returns it to that pane.
- With uncommitted changes in the checkout, the agent finishing a turn opens
  a Review tab running `tuicr -w`; a second finish selects it again instead
  of opening another.
- `ctrl-shift-g` shows Changes, pressing it again hides the panel.
- With a repo space and two of its worktree spaces, `alt-down` skips the
  worktrees, `ctrl-alt-down` cycles the three, and `alt-shift-down` from a
  pane reaches the next desk with the keyboard in it.
