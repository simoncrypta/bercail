# herdr-sidebar

**The sidebar your terminal was missing** — a VS Code-inspired file explorer + source
control panel in one dockable herdr pane.

<img src="docs/media/hero.png" alt="The sidebar Explorer and live preview interface" width="860">

**The full tour lives in the [repo README](../../README.md)** — features, screenshots,
keys, and settings.

## Install

Requires herdr 0.9 or newer.

```
herdr plugin install alexarthurs/herdr-sidebar/plugins/herdr-sidebar
```

or from a local checkout:

```
cargo build --release
herdr plugin link .
```

Open it (or just focus a tab — the hook docks it):

```
herdr plugin action invoke herdr-sidebar.open-sidebar-windows   # windows
herdr plugin action invoke herdr-sidebar.open-sidebar           # linux / macos
```
