# Upstream

- Source: https://github.com/jankeesvw/herdr-focus-to-hover/tree/f5584d20d3e3ce26ba8446f5306496bb41ef88c0
- Commit: f5584d20d3e3ce26ba8446f5306496bb41ef88c0 (2026-11-03)
- License: MIT, Copyright (c) 2026 Jankees van Woezik (LICENSE)
- follow.js sha256: 013548bff6a836c77c6af77676f1b25ceae820f0e0361a0ad9534467a8730e94

`follow.js` and `LICENSE` are upstream's `mods/focus-to-hover/follow.js` and
`LICENSE`, byte for byte. `follow.js` is the whole of focus to hover: an invisible
layer behind a pane header, which the pane's frame clips to the pane, runs
`pane.focus` for that pane when the pointer moves in while Herdr is the active
window. It reads `panes()` and runs only `pane.focus`: no network, no file, no
command.

Upstream's own header (`mods/focus-to-hover/main.js`) is a copy of Herdr 0.1.12's
`pane` mod. bercail does not take it: `main.js` here is Herdr 0.1.18's `pane` mod
(Apache License 2.0, `LICENSE-APACHE`) with `follow` added, as upstream's README
suggests, so pane names and a bottom header still show as Herdr draws them.
`mod.json`'s `cloned_from` records that copy for `bercail doctor`.

To check the copy, or move it to a newer commit:

```sh
d="$(mktemp -d)"
git clone https://github.com/jankeesvw/herdr-focus-to-hover "$d"
git -C "$d" checkout <commit>
diff "$d"/mods/focus-to-hover/follow.js bercail/mods/bercail-pane/follow.js
diff "$d"/LICENSE bercail/mods/bercail-pane/LICENSE
```

A newer commit is copied in whole. Then update the commit and the sha256 here, and
`known` in `lib/deps.json`; `tests/pane_mod.bats` checks that the three agree.
Before taking it, read its diff for a new import, a command other than
`pane.focus`, a network call or a file access, then run `tests/pane_mod.bats` and
`herdr-app check bercail/mods/bercail-pane`.
