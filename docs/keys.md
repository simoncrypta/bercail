# keys

Keyboard and mouse both work: `Ctrl+Shift` keys like the rest of the Herdr app, a file tree you can click, and `j`/`k` in tuicr.

```
┌─────────┬─────────────────────────────────────────────────────┐
│         │ tabs: Shell | Review* | …     Ctrl+Shift+S / R      │
│ sidebar ├──────────────┬────────────────────────┬─────────────┤
│ spaces  │ desk agent   │ the tab's panes        │ changes     │
│ agents  │ Ctrl+Shift+A │ (tuicr on agent done)  │ or files    │
│         │              │                        │ +G / +F     │
└─────────┴──────────────┴────────────────────────┴─────────────┘
```

The desk (bstack when it is on, else your `[agent] command`) sits under the tab bar, beside the current tab's panes. It is an hc terminal, so it keeps running when the window closes or the Shell's program ends. The sidebar's agents list (bercail's `bercail-agents` mod) has a row for each desk; click it to focus that desk.

In the bercail layout (`~/.config/herdr-app/keys.json`, section `layout:bercail`):

| Key | Action |
|-----|--------|
| `Ctrl+Shift+A` | Focus the desk agent, or start it |
| `Ctrl+Shift+R` | Review |
| `Ctrl+Shift+S` | Shell tab |
| `Ctrl+Shift+F` / `G` | Show or hide files / changes |
| `Ctrl+Alt+Left` / `Right` | Move between panes; left from the leftmost pane reaches the desk |
| `Alt+Up` / `Down` | Previous/next space: repos and other spaces, skipping worktree spaces nested under their repo's main checkout |
| `Ctrl+Alt+Up` / `Down` | Previous/next space of this repo: its main checkout and worktrees, as the sidebar nests them |
| `Alt+Shift+Up` / `Down` | Previous/next agent, desks included, in sidebar order |
| `Ctrl+Shift+Q` | Close this space |

`bercail update` keeps the keys you changed or removed in that section and warns about each one, and about any `terminal` key that takes one of bercail's. `bercail doctor` lists them too.

The rest are the Herdr app's: `Ctrl+Shift+T`/`W` new/close tab, `Ctrl+Shift+O`/`E` split, `Ctrl+Shift+X` close pane, `Ctrl+Shift+Z` zoom, `Alt+1`…`9` tabs, `Alt+H`/`J`/`K`/`L` panes, `Ctrl+Shift+B` sidebar, `Ctrl+Shift+L` layout, `Ctrl+Shift+?` all keys.
