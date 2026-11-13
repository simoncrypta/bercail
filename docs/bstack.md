# bstack

**bstack is bercail's opinionated Pi.** [Pi](https://pi.dev) signs in with a Claude plan (through Claude Code), a ChatGPT plan, and an X subscription, so one agent runs all three, on subscriptions you already pay for. bstack sets Pi up the way bercail works: the job is a beads issue, agents stage and leave changes uncommitted for tuicr, and each kind of work goes to the model that is best at it.

It borrows from [pstack](https://github.com/cursor/plugins/tree/main/pstack) (rigor, playbooks, roles by model strength, `how`/`why`/`unslop`), [cursor-team-kit](https://github.com/cursor/plugins/tree/main/cursor-team-kit) (babysit-pr and CI loops, which became autopilot), [tstack](https://github.com/t3dotgg/tstack) (a council of providers), and [gstack](https://github.com/garrytan/gstack), on top of [Shep](shep.md)'s handoff workflow.

Every install runs bstack: the desk agent is its Pi lead.

```bash
bercail bstack setup     # installs Pi and the Claude bridge; models are picked for you
bercail bstack status    # what is logged in, which model each role uses
dev                      # the desk starts Pi as the bstack lead
```

## How it runs

`bercail bstack setup` installs [Pi](https://pi.dev) (>=1.5.1) and `npm:pi-claude-bridge@0.12.0`. Claude uses your Claude Code login (`claude auth login`), not Pi's `/login anthropic` or per-token Extra Usage. GPT and Grok use `/login openai` and `/login xai` inside Pi. A desk runs Pi as the lead: `bercail update` writes its command line to `pi/lead.json`, and the desk shows its status and [comes back after a reboot](config.md#desks-after-a-reboot).

bercail renders the profile to `~/.local/share/bercail/pi/`. Installing the bridge adds its pinned package to Pi's settings, leaving unrelated settings and auth intact. Each `bercail update` also sets `compaction.modelOverrides` there, `reserveTokens: 40000` for every `claude-bridge` model Pi lists: Claude Code refuses a prompt ("Prompt is too long") once it is within about 23k tokens of the window (20k for output, 3k of margin), and Pi's default 16384 reserve would compact only after that. A larger reserve you set stays. Every role explicitly loads the bridge and the managed `extensions/fallback.ts` with `-e`, and unsets `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, and `ANTHROPIC_AUTH_TOKEN` so fallback to Claude uses your plan. Role boundaries and git rules remain instructions, not enforced tool restrictions. The builder, judge, council, and autopilot run as interactive `hc` sibling agents from templates in `~/.config/herdr-core/templates/`. Pi handoffs use desks or interactive siblings, not one-shot runs.

After Pi exhausts its own rate-limit retries, the extension tries the next model in `[bstack] fallback` (default `["claude", "gpt", "grok"]`). It scans from the start and skips the current model, models already tried for this message, and limited or dead ones. It leaves the initial role picks unchanged.

- **Limited.** A 429, a usage limit, or a Claude plan refusal limits the whole provider until the reset the provider gives, or for 5 minutes when it gives none. Claude's plan windows (`five_hour`, `seven_day`) cover every model on the plan, so another Claude model would hit the same limit. A window for one model (`seven_day_opus`) limits only that model, and the next Claude model in the order still runs.
- **Dead.** A 402, "out of credits", or "need a … subscription" does not reset on its own. The extension says so once, skips that provider for the rest of the session, and appends a line to `~/.local/state/bercail/fallback-dead.jsonl`.
- **Back to the desk's model.** At the next user message or turn after its limit lifts, the desk goes back to its own model: the `--model` it started with, or the one you last picked with `/model`. The switch back is a `bercail-fallback-restore` entry in the session.
- **Thinking level.** Pi's model switch resets thinking to its `defaultThinkingLevel` (medium unless set). Each switch the extension makes, to a fallback or back, puts the desk's level back, so a `:high` desk stays high on every model. A level you set with `/thinking` becomes the desk's level.
- **Siblings.** A builder, judge, council seat, or autopilot that runs out of models sends its parent the reason with `hc send` and stops, so the lead can do that part itself.

The desk's session name, which the desk status shows, adds `fallback <provider>` while it runs elsewhere and `dead <provider>` for dead providers.

Set `fallback = ["gpt", "grok"]` to limit candidates, or `[]` to disable them. An entry can also be a Pi model id without an effort, such as `fallback = ["claude-bridge/claude-sonnet-5-5", "claude", "gpt", "grok"]`, to try another model on the same plan first. Entries must be unique. The profile stores resolved `family=model` lines in `pi/models` and one fallback entry per line in `pi/fallback`. `bercail bstack status` reports the order, bridge availability, and Claude Code subscription auth (`authMethod` `claude.ai` or `oauth_token`, not an API key). `bercail doctor` checks the installed bridge, flags missing or stale profile data, prints the fallback order, and lists the providers the fallback found dead in the last day. It probes no provider, so a provider you have since paid for stays listed until that day is over.

## Where to find what

[The bstack guide](bstack/README.md) is the full story, with prompts to copy. Each fact lives on one page:

| Topic | Page |
|-------|------|
| `setup`, sign-ins, how models are picked, `status`, `/bstack-setup` | [Set up bstack](bstack/01-setup.md) |
| The playbooks, the roles (lead, build, judge, council, autopilot), what a prompt holds | [Work with the bstack agent](bstack/02-the-bstack-agent.md) |
| `/how`, `/why`, taking over a branch | [Understand the code](bstack/03-understand.md) |
| The build playbooks, `/unslop` | [Build and clean the change](bstack/04-build-and-clean.md) |
| `/council`, `/ready` | [Review it](bstack/05-review.md) |
| `/autopilot` and what `bstack-autopilot` may do | [Ship with autopilot](bstack/06-autopilot.md) |
| `/handoff`, stages `bstack` and `autopilot` | [Run jobs in parallel](bstack/07-handoff.md) |
| Pinning models, effort, role fallback, the files bstack writes | [Make it yours](bstack/08-make-it-yours.md) |
| Prompts and pitfalls | [Recipes and pitfalls](bstack/09-recipes-and-pitfalls.md) |

The skills (`bstack`, `how`, `why`, `unslop`, `unit-testing`, `council`, `autopilot`) are listed in [commands](cli.md#skills), the `[bstack]` defaults in [config](config.md), and the headless stages in [handoff](handoff.md).
