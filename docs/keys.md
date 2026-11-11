# keys

Keyboard and mouse both work: `Ctrl+Shift` keys like the rest of the Herdr app, a file tree you can click, and `j`/`k` in tuicr.

The window has two views. It opens on the **Shep view**: Shep's terminal (Pi) on the left, and the navigator (Shep, spaces, agents) on the right.

```
┌──────────────────────────────────────────┬─────────────┐
│ Shep: bercail shep run (Pi)              │ ● Shep      │
│                                          │ spaces      │
│                                          │ agents      │
└──────────────────────────────────────────┴─────────────┘
```

Click a space and the **space view** shows it: the navigator moves to the left, beside that space's desk, tabs and panels. The navigator's top row reads **Back to Shep**.

```
┌─────────────┬─────────────────────────────────────────────────────┐
│ ‹ Back to   │ tabs: Shell | Review* | …     Ctrl+Shift+S / R      │
│   Shep      ├──────────────┬────────────────────────┬─────────────┤
│ spaces      │ desk agent   │ the tab's panes        │ changes     │
│ agents      │ Ctrl+Shift+A │ (tuicr on agent done)  │ or files    │
│             │              │                        │ +G / +F     │
└─────────────┴──────────────┴────────────────────────┴─────────────┘
```

Switching views starts and stops nothing. Shep, the desks and every shell keep running while hidden, and each view comes back as you left it, the keyboard included. Shep is one terminal for every desk, not part of any space; it is found again after a restart, so no second one starts. It starts on its own once per app session; quit it and it stays quit until **Start Shep**. See [Shep](shep.md#the-shep-view).

The desk (bstack when it is on, else your `[agent] command`) sits under the tab bar, beside the current tab's panes. It is an hc terminal, so it keeps running when the window closes or the Shell's program ends. Supported sessions [come back after a reboot](config.md#desks-after-a-reboot). The agents list (bercail's `bercail-agents` mod) has a row for each desk. Click any agent, desk or not, to open its own terminal in a dialog over either view: while it is open, what you type goes to that agent. ✕ or a click beside the dialog closes it and puts the keyboard back; **Show in space** goes to its space instead.

In the bercail layout (`~/.config/herdr-app/keys.json`, section `layout:bercail`):

| Key | Action |
|-----|--------|
| `Ctrl+Shift+H` | Shep view / space view |
| `Ctrl+Space` | Go to…: Herdr's search for a space, tab or agent |
| `Ctrl+Shift+A` | Focus the desk agent, or start it |
| `Ctrl+Shift+R` | Review |
| `Ctrl+Shift+S` | Shell tab |
| `Ctrl+Shift+F` / `G` | Show or hide files / changes |
| `Ctrl+Alt+Left` / `Right` | Move between panes; left from the leftmost pane reaches the desk |
| `Alt+Up` / `Down` | Previous/next space: repos and other spaces, skipping worktree spaces nested under their repo's main checkout |
| `Ctrl+Alt+Up` / `Down` | Previous/next space of this repo: its main checkout and worktrees, as the sidebar nests them |
| `Alt+Shift+Up` / `Down` | Previous/next agent, desks included, in sidebar order |
| `Ctrl+Shift+Q` | Close this space |

The keys from `Ctrl+Space` to `Alt+Shift+Up`/`Down` act in the space view. Pressed in the Shep view, they show the space view first, with the keyboard where you left it, and act from there: `Alt+Down` from Shep opens the space after the last one you were in, and what you pick in Go to… shows. `Ctrl+Shift+H` goes back to Shep.

These keys go to the layout, never to the program in Shep or the desk. If your input method switches on `Ctrl+Space` (fcitx5's default, macOS's input sources), rebind it in that section. `Ctrl+Up`/`Down` and `Ctrl+Shift+Up`/`Down` are not bercail's: they reach Shep or the desk, and Pi jumps between prompts with them.

`bercail update` keeps the keys you changed or removed in that section and warns about each one, and about any `terminal` key that takes one of bercail's. `bercail doctor` lists them too.

The rest are the Herdr app's: `Ctrl+Shift+T`/`W` new/close tab, `Ctrl+Shift+O`/`E` split, `Ctrl+Shift+X` close pane, `Ctrl+Shift+Z` zoom, `Alt+1`…`9` tabs, `Alt+H`/`J`/`K`/`L` panes, `Ctrl+Shift+B` sidebar, `Ctrl+Shift+L` layout, `Ctrl+Shift+?` all keys.
