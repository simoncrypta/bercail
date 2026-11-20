# Upstream

- Source: https://github.com/johnlindquist/pi-emphasis/tree/f884b736c489944ee778ab951c7f78580f137b02
- Commit: f884b736c489944ee778ab951c7f78580f137b02 (2026-11-15), package version 0.2.0
- License: MIT, Copyright (c) 2026 John Lindquist (LICENSE)
- index.ts sha256: 036c2705c5c3ba676556494a5d56ba6184892ee683598d25ce0ccfce5f112d4f

`index.ts` and `LICENSE` are upstream's, byte for byte. Upstream is a Pi package
with no releases and no npm package; `pi install git:` would clone it and run npm
in the clone, and write to the person's own Pi settings. Its one import is a
type, so the single file loads as it is, with no install step and no
network.

To check the copy, or move it to a newer commit:

```sh
d="$(mktemp -d)"
git clone https://github.com/johnlindquist/pi-emphasis "$d"
git -C "$d" checkout <commit>
diff "$d"/index.ts bstack/pi/extensions/pi-emphasis/index.ts
diff "$d"/LICENSE bstack/pi/extensions/pi-emphasis/LICENSE
```

A newer commit is copied in whole. Then update the commit and the sha256 here, and
`known` in `lib/deps.json`; `tests/pi_emphasis.bats` checks that the three agree.
Before taking it, read its diff for a new import, a network call, a shortcut, or
a new prompt section, and run `bash tests/run.sh --live tests/pi_emphasis.bats`.
