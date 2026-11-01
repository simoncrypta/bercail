# bercail

**an ADE on [herdr](https://herdr.dev).**

Run a handful of coding agents at once and never lose one. Bercail is an agentic development environment on the [Herdr app](https://herdr.dev) and herdr-core (`hc`), built for working in parallel with control and observability.

One git worktree, one Herdr space. Each space has a desk: one agent that stays on the left while you switch between shell, review, and files. You can see when each agent is working, blocked, or done.

Agents stage their changes and leave them uncommitted. When the desk agent goes `done`, [tuicr](https://github.com/agavra/tuicr) opens that work and watches further edits. You review in the terminal, comments stay human vs AI, and nothing goes to GitHub until you ask.

**Built to be herded by a Grok bot.** Bercail is French for the sheepfold, so of course there's a shepherd. [Shep](docs/shep.md) is a public Grok bot that runs bercail for you. It writes the job as a [beads](https://beads.gascity.com/) issue, hands it to an agent, and tells you when a desk is ready. Bercail does the local work; Shep decides what happens next. You can also do Shep's part by hand.

**New installs run [bstack](docs/bstack.md):** one harness, [opencode](https://github.com/anomalyco/opencode), on your own Claude, ChatGPT, and X subscriptions. Claude Code, Codex CLI, and cursor-agent stay equal harnesses beside it. A handoff's whole prompt is one line pointing at its beads issue.

Omarchy, Ubuntu/Debian, macOS. Installer and CLI: `bercail`.

<img width="2133" height="1386" alt="bercail" src="https://github.com/user-attachments/assets/9760e643-b0da-45c1-88bc-d69f0d9c04c2" />

## What you get

- **The desk.** Each space's agent is pinned beside the tabs and keeps running when the window closes.
- **Review on `done`.** tuicr opens the uncommitted work the agent left you. `Ctrl+Shift+R` opens it anytime.
- **Parallel handoff.** One beads issue per job, run headless or in a sibling worktree with its own desk.
- **Your keyboard, your mouse.** `Ctrl+Shift` keys like the rest of the Herdr app, plus a file tree you can click.

## Quick start

The easy way: add [Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF), our Grok Bot template, connect this computer to it, and ask it to set up bercail. It installs and configures everything, and asks before it runs anything.

### Or install it yourself

Current release: [v0.10.0](https://github.com/simoncrypta/bercail/releases/tag/v0.10.0).

```bash
mise use -g packslip:github.com/simoncrypta/bercail   # mise 2026.9.2+
bercail install
```

mise waits 24 hours before it takes a new release. Can't wait? Pin it: `mise use -g packslip:github.com/simoncrypta/bercail@0.10.0`. No mise? `packslip install github.com/simoncrypta/bercail` does the same job, or use curl:

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

Found bercail on [herdr.dev](https://herdr.dev/layouts/)? Its recipe walks your agent through these same commands. Switch the Herdr app to the bercail layout once (`Ctrl+Shift+L` → bercail). Then, in a repo:

```bash
dev          # this directory's space, with its desk agent
```

`Ctrl+Shift+A` focuses the desk, `Ctrl+Shift+R` opens Review, and `bercail doctor` tells you if anything is missing. Something else? `bercail help`.

## Docs

- [install](docs/install.md): every install path, what it touches, upgrading from 0.8.
- [commands](docs/cli.md): the `bercail` CLI, shell helpers, and skills.
- [keys](docs/keys.md): the layout at a glance and every key.
- [config](docs/config.md): `config.toml` and the files bercail manages.
- [review](docs/review.md): tuicr, and how Review opens and closes.
- [handoff](docs/handoff.md): stages, headless runs, result files.
- [bstack](docs/bstack.md): opencode on your own plans, roles, autopilot. Then [the bstack guide](docs/bstack/README.md).
- [Shep](docs/shep.md): the Grok bot, and agent status webhooks.
- [development](docs/development.md): tests, dependencies, platforms.
- [Herdr agents and subagents](docs/herdr-agents-subagents.md): a proposal for Herdr's agents list.

The index lives in [docs/README.md](docs/README.md).

## license

MIT — [LICENSE](LICENSE).
