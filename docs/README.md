# bercail docs

The [README](../README.md) is the tour. These pages are the reference.

- [install](install.md): mise + packslip, curl, what the installer touches, coming from 0.8, first run.
- [commands](cli.md): the `bercail` CLI, the shell helpers (`dev`, `wtc`, …), and the skills.
- [keys](keys.md): the layout's two views at a glance and every key.
- [config](config.md): `config.toml`, each repo's git policy, and the other files bercail manages.
- [review](review.md): tuicr when the desk is done, and `bercail review-pr` for someone else's PR.
- [handoff](handoff.md): one beads issue per job, headless or in a sibling desk.
- [Entire](entire.md): capturing desks' sessions, repos hosted on Entire, and what the guard allows.
- [bstack](bstack.md): Pi on your own Claude, ChatGPT, and X plans.
  - [the bstack guide](bstack/README.md): a walk-through, with prompts to copy.
- [Shep](shep.md): the orchestrator on Pi, the Shep view, what Shep knows (repos, briefs, standing rules), its compaction, desk events, and agent status webhooks.
- [development](development.md): hacking on bercail, dependencies, platforms.
- [Herdr agents and subagents](herdr-agents-subagents.md): a proposal for Herdr, so desks get their own row in the agents list.

## Principles

bercail follows the [No AI Slop manifesto](https://www.slopmanifesto.com/). Each value maps to something bercail does:

| Value | What bercail does |
|-------|-------------------|
| Outcomes over output | A [review budget](config.md#review-by-stakes-and-size): `/validate` warns on a change too big to review in one sitting, and Shep shows what waits on your review and warns before a new desk when it is over budget. |
| Understanding over speed | Every change ships a [description](bstack/05-review.md#the-change-description) for a reader who was not there, checked against the staged tree. |
| Our own thinking over a model's first draft | Your ask is a beads issue, the spec each change is judged against, and [review is by stakes](config.md#review-by-stakes-and-size): a change to a path the repo marks high-stakes waits for your LGTM before Shep lands it. |
| Better work over easier work | `/validate` cleans the diff with `unslop` and asks the judge what could be removed; a behavior change comes with a test that fails without it. |
| Improving the system over patching the output | Shep's [mistakes ledger](shep.md#mistakes): a mistake seen twice gets a guardrail, not another fix by hand. |
