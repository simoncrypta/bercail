# Herdr's default keys

`keys.json` (Linux and Windows) and `keys.macos.json` are unchanged copies of
`defaults/keys.json` and `defaults/keys.macos.json` from
[herdrdev/herdr-app](https://github.com/herdrdev/herdr-app) at commit
`2d1464e02ddad5484eaaf9a5b59b594e3930aeba` (herdr-app 0.1.17), under the
Apache License 2.0 in `LICENSE`.

Herdr reads a `keys.json` it did not write as the whole keymap, so
`bercail update` merges these under bercail's `layout:bercail` keys
(`lib/config.sh`, `docs/keys.md#herdrs-default-keys`). When Herdr changes its
defaults, copy both files again and update the commit above.
