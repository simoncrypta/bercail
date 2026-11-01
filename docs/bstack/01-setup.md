# Set up bstack

New bercail installs turn bstack on (`./install.sh --no-bstack` to skip). On an
existing install, `bercail bstack setup` turns it on too; `bercail bstack on`
does it without the sign-ins. Either one moves the desk default from
cursor-agent to opencode.

## Connect your plans

```bash
bercail bstack setup
```

It installs opencode when it is missing (bstack needs 2.2.3 or newer), then
offers each sign-in:

| Plan | What it runs |
|------|--------------|
| Claude (Pro or Max) | `opencode auth login claude-agent`. Claude Agent runs Claude Code, so install it and sign in with `claude auth login` first; setup skips Claude without it |
| ChatGPT (Plus or Pro) | `opencode auth login openai`, choose Sign in with ChatGPT |
| X subscription | `opencode auth login xai --method device` |

Connect the ones you pay for. One is enough to start. bstack spreads the work
out as you add more. `--yes` connects nothing: it turns bstack on and uses the
plans already connected.

Setup does not ask about models. Each connected plan gets its newest model:
Claude's `opus` alias, the newest GPT Sol, the newest plain Grok release, each
at `effort` (default `high`). `bercail update` picks again, so a new release
reaches bstack without you doing anything. To pin a model or change the effort,
see [Make it yours](./08-make-it-yours.md).

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

When the agent finishes, its desk goes `done` and tuicr opens on the
uncommitted change. That is your [review](../review.md).

## Keep the cost in check

Each subagent and each council seat spends tokens from a plan. To spend less:

- Save the playbooks for work that needs them. A one-line fix doesn't.
- Point `build` at your cheapest plan in `[bstack]` (see [Make it yours](./08-make-it-yours.md)).
- Run `/council` once per change, at the end, not after every step.

Next: [Work with the bstack agent](./02-the-bstack-agent.md).
