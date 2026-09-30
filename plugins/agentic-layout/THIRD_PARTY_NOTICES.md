# Third-party notices

## herdr-sidebar

The sidebar TUI in `crates/herdr-sidebar/` is derived from
[herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar) by Alex Arthurs.

Copyright (c) Alex Arthurs and contributors  
License: MIT (see `crates/herdr-sidebar/UPSTREAM_LICENSE`)

Modifications for agentic-dev-setup:

- Embedded mode (no auto-dock; layout-owned right pane)
- Default dock-right; external editor via `agentic-dev.layout.open-editor`
- Simplified source-control surface (staged/changes only in embedded mode)
- Review refresh integration with the layout center pane
- Pierre file icon theme (see below)

## Pierre Icons for VS Code

The file-tree icon mapping (file names/extensions → icon) and palette colors in
`crates/herdr-sidebar/src/icons.rs` are adapted from
[pierrecomputer/vscode-icons](https://github.com/pierrecomputer/vscode-icons).
Glyphs are Nerd Font equivalents; no Pierre SVGs are redistributed.

Copyright (c) 2026 The Pierre Computer Company  
License: MIT
