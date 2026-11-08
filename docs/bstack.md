# bstack

**bstack is bercail's opinionated opencode.** opencode signs in with a Claude plan (Claude Agent), a ChatGPT plan, and an X subscription, so one harness runs all three, on subscriptions you already pay for. bstack sets opencode up the way bercail works: the job is a beads issue, agents stage and leave changes uncommitted for tuicr, and each kind of work goes to the model that is best at it.

It borrows from [pstack](https://github.com/cursor/plugins/tree/main/pstack) (rigor, playbooks, roles by model strength, `how`/`why`/`unslop`), [cursor-team-kit](https://github.com/cursor/plugins/tree/main/cursor-team-kit) (babysit-pr and CI loops, which became autopilot), [tstack](https://github.com/t3dotgg/tstack) (a council of providers), and [gstack](https://github.com/garrytan/gstack), on top of [Shep](shep.md)'s handoff workflow.

New installs run bstack. Claude Code, Codex CLI, and cursor-agent stay equal harnesses beside it. Bercail does not prefer one for a handoff, pick one, or fall back from one to another.

```bash
bercail bstack setup     # installs opencode, connects your plans; models are picked for you
bercail bstack status    # what is connected, which model each role uses
dev                      # the desk starts opencode as the bstack agent
```

## On Pi

New configs set `harness = "pi"` under `[bstack]`. Set it in an existing `config.toml` and run `bercail update` to render the [Pi](https://pi.dev) profile with your own logins (`/login anthropic`, `/login openai`, `/login xai` inside `pi`). Pi's Anthropic login bills extra usage per token. Existing configs without `harness` keep using opencode; `harness = "opencode"` selects it explicitly. Automatic Pi desk launching is a separate follow-up.

bercail renders the profile to `~/.local/share/bercail/pi/` and never edits `~/.pi/agent/`; each launch names the profile with flags. No bercail extensions are installed or loaded. Role boundaries and git rules are instructions, not enforced tool restrictions. The builder, judge, council, and autopilot run as interactive `hc` sibling agents from templates in `~/.config/herdr-core/templates/`. Pi handoffs use desks or interactive siblings, not one-shot runs.

## Where to find what

[The bstack guide](bstack/README.md) is the full story, with prompts to copy. Each fact lives on one page:

| Topic | Page |
|-------|------|
| `setup`, sign-ins, how models are picked, `status`, `/bstack-setup`, turning it on | [Set up bstack](bstack/01-setup.md) |
| The playbooks, the roles (lead, build, judge, council, autopilot), what a prompt holds | [Work with the bstack agent](bstack/02-the-bstack-agent.md) |
| `/how`, `/why`, taking over a branch | [Understand the code](bstack/03-understand.md) |
| The build playbooks, `/unslop` | [Build and clean the change](bstack/04-build-and-clean.md) |
| `/council`, `/ready` | [Review it](bstack/05-review.md) |
| `/autopilot` and what `bstack-autopilot` may do | [Ship with autopilot](bstack/06-autopilot.md) |
| `/handoff`, stages `bstack` and `autopilot` | [Run jobs in parallel](bstack/07-handoff.md) |
| Pinning models, effort, role fallback, the files bstack writes, `bercail bstack off` | [Make it yours](bstack/08-make-it-yours.md) |
| Prompts and pitfalls | [Recipes and pitfalls](bstack/09-recipes-and-pitfalls.md) |

The skills (`bstack`, `how`, `why`, `unslop`, `council`, `autopilot`) are listed in [commands](cli.md#skills), the `[bstack]` defaults in [config](config.md), and the headless stages in [handoff](handoff.md).
