# Credits

bercail is MIT ([LICENSE](../LICENSE)). It ships copies of other people's code,
each under its own license, and borrows ideas from a few more projects.

## Code bercail ships

The copies of pi-emphasis, the statechart skill and focus-to-hover keep
upstream's `LICENSE` beside them, with an `UPSTREAM.md` that records the commit
they were taken at and how to compare them with upstream. The copies of Herdr's
mods keep Herdr's Apache license beside them as `LICENSE-APACHE` and name the
Herdr version they came from in `mod.json` (`cloned_from`). The
[dependency tracker](development.md#dependency-tracker) opens an issue when one
of these upstreams moves.

| Copy | Upstream | Author | License | What is copied |
|------|----------|--------|---------|----------------|
| `bstack/pi/extensions/pi-emphasis/` | [pi-emphasis](https://github.com/johnlindquist/pi-emphasis) | John Lindquist | MIT | `index.ts`, byte for byte: the [reply pills](bstack.md#reply-pills) in bstack's roles and Shep |
| `skills/statechart/` | pstack's [statechart skill](https://github.com/cursor/plugins/tree/main/pstack/skills/statechart) | Lauren Tan | MIT | `scripts/` and `references/` byte for byte, beside bercail's own `SKILL.md` and four scripts ([statecharts](bstack.md#statecharts)) |
| `bercail/mods/bercail-pane/follow.js` | [herdr-focus-to-hover](https://github.com/jankeesvw/herdr-focus-to-hover) | Jankees van Woezik | MIT | `follow.js`, byte for byte: [focus follows the mouse](config.md#focus-follows-the-mouse) |
| `bercail/mods/bercail-pane/main.js` | the Herdr app's `pane` mod 0.1.18 | Herdr | Apache 2.0 | the mod, with `follow` added |
| `bercail/mods/bercail-spaces/`, `bercail/mods/bercail-agents/` | the Herdr app's `spaces` and `agents` mods 0.1.18 | Herdr | Apache 2.0 | forks: each `main.js` header lists bercail's changes |
| `bercail/layouts/bercail.json` | the Herdr app's `main` layout 0.1.6 | Herdr | Apache 2.0 | a fork ([RECIPE.md](../bercail/RECIPE.md#built-from)) |
| `bercail/herdr-keys/` | [Herdr's default keys](https://github.com/herdrdev/herdr-app) | Herdr | Apache 2.0 | `keys.json` and `keys.macos.json`, unchanged |

## Ideas bercail borrows

- **[pstack](https://github.com/cursor/plugins/tree/main/pstack)**: rigor, playbooks, roles by model strength, and the `how`, `why` and `unslop`
  skills. [The bstack guide](bstack/README.md) is shaped after the pstack guide.
- **[cursor-team-kit](https://github.com/cursor/plugins/tree/main/cursor-team-kit)**:
  its babysit-pr and CI loops became [autopilot](bstack/06-autopilot.md).
- **[gstack](https://github.com/garrytan/gstack)**, by Garry Tan.
- **[F.I.R.S.T Principles of Unit Testing](https://github.com/tekguard/Principles-of-Unit-Testing)**,
  by Rajesh Kannan: the `unit-testing` skill paraphrases it. That repo has no
  license, so the skill quotes none of it.
- **[The No AI Slop manifesto](https://www.slopmanifesto.com/)**: the principles
  bercail holds itself to ([docs index](README.md#principles)).

## What bercail runs on

bercail installs these and does not copy them: [Herdr](https://herdr.dev),
[Pi](https://pi.dev) with [pi-claude-bridge](https://www.npmjs.com/package/pi-claude-bridge),
[beads](https://beads.gascity.com/), [worktrunk](https://github.com/max-sixty/worktrunk),
[tuicr](https://github.com/agavra/tuicr), [fzf](https://github.com/junegunn/fzf),
[jq](https://github.com/jqlang/jq), and, when you turn it on,
[tla-ts](https://github.com/aidenybai/tla-ts). [The stack](stack.md) says why
bercail uses the main ones. `lib/deps.json` lists the tools bercail tracks and
the version each was last checked against.
