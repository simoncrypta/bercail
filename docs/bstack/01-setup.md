# Set up bstack

New bercail installs turn bstack on (`./install.sh --no-bstack` to skip). On an
existing install, `bercail bstack setup` or `bercail bstack on` turns it on.
With bstack off, the desk runs plain Pi.

## Sign in

```bash
bercail bstack setup
```

It installs [Pi](https://pi.dev) when it is missing (bstack needs 1.2.0 or
newer) and the Claude bridge (`npm:pi-claude-bridge@0.11.0`), then prints the
sign-ins that are still missing:

| Plan | How to sign in |
|------|----------------|
| Claude (Pro or Max) | `claude auth login` in a terminal. The bridge runs Claude Code on your plan |
| ChatGPT (Plus or Pro) | `/login openai` inside Pi, choose Sign in with ChatGPT |
| X subscription | `/login xai` inside Pi |

Sign in to the ones you pay for. One is enough to start. bstack spreads the
work out as you add more; run `bercail update` after a new sign-in.

Setup does not ask about models. Each plan you are signed in to gets its newest
model: the newest Claude Opus, the newest GPT Sol, the newest plain Grok
release, each at `effort` (default `high`). `bercail update` picks again, so a
new release reaches bstack without you doing anything. To pin a model or change
the effort, see [Make it yours](./08-make-it-yours.md).

## Check it

```bash
bercail bstack status
```

It shows which sign-ins are ready, the model each one uses (`auto` or
`pinned`), and which model each role ends up on. `bercail doctor` warns when a
sign-in or a model changed since the last update.

Inside Pi, `/bstack-setup` shows the same thing and tells you what to run.

## Start working

```bash
dev
```

The desk starts Pi as the bstack lead. Pick something small and real,
and describe it the way you would to a colleague:

```text
add a --json flag to this command. the text output stays byte-identical. prove both.
```

Watch the todo list. Its first items are the feature playbook's steps. When the
agent skips one, it says why.

When the agent finishes, its desk goes `done` and tuicr opens on the
uncommitted change. That is your [review](../review.md).

## Keep the cost in check

Each sibling agent and each council seat spends tokens from a plan. To spend less:

- Save the playbooks for work that needs them. A one-line fix doesn't.
- Point `build` at your cheapest plan in `[bstack]` (see [Make it yours](./08-make-it-yours.md)).
- `/ready` does not run the council. Ask for `/council` only when a change earns it.

Next: [Work with the bstack agent](./02-the-bstack-agent.md).
