# Upstream

- Source: https://github.com/cursor/plugins/tree/0b46ec399d55f2829e88822998f53b84944837d3/pstack/skills/statechart
- Commit: 0b46ec399d55f2829e88822998f53b84944837d3 (2026-11-19)
- License: MIT, Copyright (c) 2026 Lauren Tan (LICENSE, from pstack/LICENSE)

Every file under `scripts/` and `references/` is upstream's, byte for byte, except
bercail's four scripts below. `SKILL.upstream.md` is upstream's SKILL.md. Left out:
`scripts/test/`, upstream's own suite and its 3.7 MB corpus, which also needs
fast-check, Java and TLC.

bercail's own files:

- `SKILL.md`: the same instructions for Pi and bstack (what changed is listed at its end).
- `scripts/statechart-bstack`: runs upstream's command on tla-ts (or on TLC when
  `TLA2TOOLS` and `JAVA` are both set), with a time bound, and never installs it.
  It writes `chart.pi.md`, and its `graph` mode writes the state graph as JSON
  for a replay on real code.
- `scripts/tla-ts-java`: the `java` upstream's command calls, running tla-ts as TLC 1.7.4.
- `scripts/pi-chart.mjs`: `chart.mmd` as a post for Pi's chat.
- `scripts/graph.ts`: the graph, read with upstream's own config and dot parsers.

To check the copy, or move it to a newer commit, compare it with upstream:

```sh
d="$(mktemp -d)"
git clone --filter=blob:none https://github.com/cursor/plugins "$d"
git -C "$d" checkout <commit>
diff -r --exclude=test "$d"/pstack/skills/statechart/scripts skills/statechart/scripts
diff -r "$d"/pstack/skills/statechart/references skills/statechart/references
```

The only differences are bercail's four scripts. A newer commit is copied in whole,
`SKILL.upstream.md` with it. Then update `SKILL.md`, the commit here and in
`lib/deps.json`, and rerun `tests/statechart/shep-inbox/check.sh`. Upstream's suite
runs from its own checkout (`cd pstack/skills/statechart/scripts && npm test`).
