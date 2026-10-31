# Set up bstack

New bercail installs turn bstack on. On an existing install, run
`bercail bstack on` first.

## Connect your plans

```bash
bercail bstack setup
```

It installs opencode when it is missing, then offers each sign-in:

| Plan | What it runs |
|------|--------------|
| Claude (Pro or Max) | `claude auth login`, then `opencode auth login claude-agent` |
| ChatGPT (Plus or Pro) | `opencode auth login openai`, choose Sign in with ChatGPT |
| X subscription | `opencode auth login xai --method device` |

Connect the ones you pay for. One is enough to start. bstack spreads the work
out as you add more.

Setup does not ask about models. Each connected plan gets its newest model:
Claude's `opus`, the newest GPT Sol, the newest plain Grok release, each at
high reasoning effort. `bercail update` picks again, so a new release reaches
bstack without you doing anything.

## Check it

```bash
bercail bstack status
```

It shows which plans are connected, the model each one uses (`auto` or
`pinned`), and which model each role ends up on. `bercail doctor` warns when a
plan or a model changed since the last update.

Inside opencode, `/bstack-setup` shows the same thing and tells you what to run.

## Start working

```bash
dev
```

The desk starts opencode as the `bstack` agent. Pick something small and real,
and describe it the way you would to a colleague:

```text
add a --json flag to this command. the text output stays byte-identical. prove both.
```

Watch the todo list. Its first items are the feature playbook's steps. When the
agent skips one, it says why.

When the agent finishes, its desk goes `done` and tuicr opens on the staged
change. That is your review.

## Keep the cost in check

Each subagent and each council seat spends tokens from a plan. To spend less:

- Save the playbooks for work that needs them. A one-line fix doesn't.
- Point `build` at your cheapest plan in `[bstack]` (see [Make it yours](./08-make-it-yours.md)).
- Run `/council` once per change, at the end, not after every step.

Next: [Work with the bstack agent](./02-the-bstack-agent.md).
