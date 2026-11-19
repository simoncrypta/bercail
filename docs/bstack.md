# bstack

**bstack is bercail's opinionated Pi.** [Pi](https://pi.dev) signs in with a Claude plan (through Claude Code) and a ChatGPT plan, so one agent runs both, on subscriptions you already pay for. bstack sets Pi up the way bercail works: the job is a beads issue, agents stage and leave changes uncommitted for tuicr, Claude Opus does the work and makes the calls, and GPT judges as a second opinion.

It borrows from [pstack](https://github.com/cursor/plugins/tree/main/pstack) (rigor, playbooks, roles by model strength, `how`/`why`/`unslop`), [cursor-team-kit](https://github.com/cursor/plugins/tree/main/cursor-team-kit) (babysit-pr and CI loops, which became autopilot), [tstack](https://github.com/t3dotgg/tstack) (a council of providers), and [gstack](https://github.com/garrytan/gstack), on top of [Shep](shep.md)'s handoff workflow.

Every install runs bstack: the desk agent is its Pi lead.

```bash
bercail bstack setup     # installs Pi and the Claude bridge; models are picked for you
bercail bstack status    # what is logged in, which model each role uses
dev                      # the desk starts Pi as the bstack lead
```

## How it runs

`bercail bstack setup` installs [Pi](https://pi.dev) (>=1.5.1) and `npm:pi-claude-bridge@0.12.0`. Claude uses your Claude Code login (`claude auth login`), not Pi's `/login anthropic` or per-token Extra Usage. GPT uses `/login openai` inside Pi. A desk runs Pi as the lead: `bercail update` writes its command line to `pi/lead.json`, and the desk shows its status and [comes back after a reboot](config.md#desks-after-a-reboot).

bercail renders the profile to `~/.local/share/bercail/pi/`. Installing the bridge adds its pinned package to Pi's settings, leaving unrelated settings and auth intact. Each `bercail update` also sets `compaction.modelOverrides` there, `reserveTokens: 40000` for every `claude-bridge` model Pi lists: Claude Code refuses a prompt ("Prompt is too long") once it is within about 23k tokens of the window (20k for output, 3k of margin), and Pi's default 16384 reserve would compact only after that. A larger reserve you set stays. Every role explicitly loads the bridge and the managed `extensions/fallback.ts` with `-e`, and unsets `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, and `ANTHROPIC_AUTH_TOKEN` so Claude runs on your plan. Role boundaries and git rules remain instructions, not enforced tool restrictions. The builder, judge, council, and autopilot run as interactive `hc` sibling agents from templates in `~/.config/herdr-core/templates/`. Pi handoffs use desks or interactive siblings, not one-shot runs.

Shep, the lead, the builder, Discuss and autopilot run on Claude Opus; the judge runs on GPT. After Pi exhausts its own rate-limit retries, the extension does not move these roles to another model:

- **Paused.** A 429, a usage limit, or a Claude plan usage rejection, whether an Opus-only window (`seven_day_opus`) or a plan window (`five_hour`, `seven_day`), pauses the role until the reset the provider gives, for 5 minutes when it gives none, or for a second when that reset has already passed. Then the same request goes on, on the same model. While it waits, the desk shows a dialog with the reset time, so Pi reports it as blocked and Shep gets a blocked desk event. Esc in that dialog stops waiting and ends the run, and so does SIGTERM or SIGHUP, so closing the pane ends it too. A headless run waits the same way, without the dialog. A blocked desk refuses `hc send` without `--force`, so a child's report or Shep's follow-up to it is refused while it waits. Each pause is a `bercail-fallback-pause` entry in the session.
- **The judge's stand-in.** When the judge's own model (GPT) is limited or dead, Claude Opus (the `claude` line in `pi/models`) stands in, so `/validate` still finishes; the judge's report says which model judged. If Opus is limited too, the judge pauses until whichever resets first. At the next user message after GPT's limit lifts, or at the end of a pause when GPT reset first, the judge goes back to GPT; that switch is a `bercail-fallback-restore` entry. With no ChatGPT login, the judge runs on Opus from the start.
- **Stopped.** A 402, "out of credits", or "need a … subscription" does not reset on its own, and neither does a missing Claude plan login (`claude auth status`). The role stops with the fix in its message: add credits, or run `claude auth login`. A dead provider is logged once in `~/.local/state/bercail/fallback-dead.jsonl`. A builder, judge, council seat, or autopilot that stops sends its parent the reason with `hc send`. A safety-blocked judge remains incomplete. Its parent cannot replace the missing review with self-approval.
- **Thinking level.** Pi's model switch resets thinking to its `defaultThinkingLevel` (medium unless set). The judge's switches put its level back, so a `:high` judge stays high on the stand-in. A level you set with `/thinking` becomes the desk's level.

The desk's session name, which the desk status shows, adds `paused until <time>` while it waits, `stand-in <model>` while the judge's stand-in runs, and `dead <provider>` for dead providers.

The profile stores resolved `family=model` lines in `pi/models`. `bercail bstack status` reports bridge availability and Claude Code subscription auth (`authMethod` `claude.ai` or `oauth_token`, not an API key). `bercail doctor` checks the installed bridge, flags missing or stale profile data, and lists the providers found dead in the last day. It probes no provider, so a provider you have since paid for stays listed until that day is over. A `grok` or `fallback` key from before v0.18, or a role set to `grok`, is ignored with a warning.

## Provider stops and incomplete reviews

The extension classifies provider failures as `provider_safety_block`,
`auth_expired_or_denied`, `usage_limit`, `transient_transport`, `model_refusal`,
or `unknown_provider_error`. Safety evidence wins over mixed 429, 402, quota
text or rejected rate-limit headers. Auth failures and unknown errors stop the role;
they do not pause it or move the judge. The pause on a limit is separate from
Pi's bounded transport retries.

A safety block records an incomplete attempt in a `bercail-provider-error`
session entry, without copying the error body, credentials or request payload.
Records identify the session, episode, attempt, role, phase and candidate. Set
`BERCAIL_PHASE` and `BERCAIL_CANDIDATE` when launching a candidate-bound review.
An absent candidate is `unknown`, not an inferred approval target. Files and
completed verification evidence stay in place with their original labels.
The parent notice names the unfinished review and asks for human review or the
provider's access/review process. It does not request a replacement self-review,
rewrite the prompt, switch providers or continue the blocked request.

Notice claims persist in the session, so duplicate events and a resumed session
do not resend the same episode. Separate assistant attempts remain recorded.
A claim precedes delivery: a crash in between can lose the notice. This is not
an exactly-once delivery guarantee.

**Pi 1.5.2 limitation:** agent retries run before the extension's final
settlement hook. Its native retry classifier has no safety precedence, so a
safety error containing `429` can still be retried by Pi before bercail stops
the role. Provider-level retries also run below this boundary when configured
(their default is zero). This extension does not suppress those retries or
change retry settings. Queued work can also run before settlement, and
`continue: false` is not a veto on Pi's natural queued work. Upstream needs a
non-retryable safety reason propagated through provider normalization, both
retry layers and queued-work scheduling. A safety attempt remains
incomplete even if a native retry later succeeds. Structured refusal events
are distinguishable when a provider exposes them. Ordinary successful text,
including a refusal or a harmless quotation, is not reliably classifiable
without that signal.

## Statecharts

The `statechart` skill models a stateful change in TLA+ (a lifecycle, retry or resume, lock or lease, queue, recovery, or concurrent writers), checks it with [TLC](https://github.com/tlaplus/tlaplus), shows the owner a Mermaid chart in Pi's chat, and replays the model's steps on the real code. It is pstack's [statechart skill](https://github.com/cursor/plugins/tree/main/pstack/skills/statechart), vendored at a pinned commit (`skills/statechart/UPSTREAM.md`), with bstack's wrapper around it. The feature playbook calls it for such a change, and `/statechart <target>` runs it by hand.

It is off until you turn it on, because it needs Java:

```toml
[bstack]
statechart = true
```

Then `bercail reconfigure` (or the next `bercail update`) installs tla2tools 1.7.4 through mise, which checks the jar's sha256, uses the `java` on PATH when it is 11 or later and otherwise installs `java@temurin-25` through mise without making it your global java, writes both paths to `~/.local/share/bercail/statechart.env`, and gives every bstack agent the skill. `bercail doctor` checks the two paths. With the key off, nothing is installed, the skill is not deployed, and `/statechart` says how to turn it on. Turning it off removes the skill and `statechart.env`. What mise installed stays until `mise uninstall`, and `mise prune` removes it while the key is on, since no mise config names it: `bercail doctor` then says it is missing, and `bercail reconfigure` puts it back. A `statechart` skill of your own in `~/.agents/skills` (pstack's) is never written over or removed: bercail warns and leaves it.

The skill's command, `~/.agents/skills/statechart/scripts/statechart-bstack`, never installs anything: without TLC and Java it exits 2 with the fix. `TLA2TOOLS` and `JAVA` in the environment win over `statechart.env`. Each run stops after `STATECHART_TIMEOUT` seconds (600), through GNU coreutils' `timeout` (`brew install coreutils` on macOS): without it the command exits 2. The view module that labels the chart is JavaScript the command runs, so a review never runs a PR's spec or view.

What reaches chat is `chart.pi.md`: the chart, then the states that break a rule and every arrow in words. A chart has 20 states or fewer. Over that, the owner gets the bug's path as text (see [Shep's diagrams](shep.md#diagrams-in-chat)).

bercail's own spec is Shep's inbox, in `tests/statechart/shep-inbox/`: the model, a config for the chart, the configs with planted bugs, and `check.sh`, which runs them all and rewrites the chart and the graph that `tests/shep_inbox_statechart.test.ts` replays on `shep/pi/inbox.ts` on every test run (see [development](development.md#statecharts)).

## Where to find what

[The bstack guide](bstack/README.md) is the full story, with prompts to copy. Each fact lives on one page:

| Topic | Page |
|-------|------|
| `setup`, sign-ins, how models are picked, `status`, `/bstack-setup` | [Set up bstack](bstack/01-setup.md) |
| The playbooks, the roles (lead, build, judge, council, autopilot), what a prompt holds | [Work with the bstack agent](bstack/02-the-bstack-agent.md) |
| `/how`, `/why`, taking over a branch | [Understand the code](bstack/03-understand.md) |
| The build playbooks, `/unslop` | [Build and clean the change](bstack/04-build-and-clean.md) |
| `/council`, `/validate` | [Review it](bstack/05-review.md) |
| `/autopilot` and what `bstack-autopilot` may do | [Ship with autopilot](bstack/06-autopilot.md) |
| `/handoff`, stages `bstack` and `autopilot` | [Run jobs in parallel](bstack/07-handoff.md) |
| Pinning models, effort, what a rate limit does, the files bstack writes | [Make it yours](bstack/08-make-it-yours.md) |
| Prompts and pitfalls | [Recipes and pitfalls](bstack/09-recipes-and-pitfalls.md) |

The skills (`bstack`, `how`, `why`, `unslop`, `unit-testing`, `council`, `autopilot`, and `statechart` when it is on) are listed in [commands](cli.md#skills), the `[bstack]` defaults in [config](config.md), and the headless stages in [handoff](handoff.md).
