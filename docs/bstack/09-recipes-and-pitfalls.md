# Recipes and pitfalls

Prompts worth copying, then the mistakes everyone makes once. Swap in your own
paths and checks.

## Understand a subsystem, then its history

```text
/how the session restore works. then /why it broke last week.
```

## Restate a noisy report before touching code

```text
read this issue thread. restate the underlying problem in plain words. no code changes yet.
```

A misreading shows up in the restatement, where it costs one message.

## Fix a bug through a failing test

```text
repro the duplicate write. if there's a cheap test path, write the failing test first. then fix and rerun.
```

"if there's a cheap test path" matters. A test built on brittle mocks proves
less than the real command.

## Check before you remove

```text
/why does this fallback exist? if the reason is gone, remove it and prove nothing breaks.
```

## Review a branch skeptically

```text
/council the branch against master. only bugs and behavior regressions, no style.
```

## Clean the diff and the PR body

```text
/unslop the diff and the pr description. no em dashes.
```

## Get a PR green while you do something else

```text
/handoff run autopilot on pr 42
```

## Redirect a drifting run

```text
i asked for a repro, not a fix yet.
```

```text
show me the real output, not the build log.
```

## The pitfalls

- **Naming every skill in the prompt.** "use /how then /council then /unslop"
  reorders steps the playbook already sequences. Say the goal and the check.
- **A finish line that can't fail.** "make it better" gives the agent nothing to
  check. Name a command, an output, or a screen.
- **Leading with your theory.** The agent searches where you point. Ask it to
  restate the problem first.
- **Success off a green build.** A build proves it compiles. Ask for the real
  command or flow, and expect it in the report.
- **Accepting every review comment.** Bots and people both mix real catches with
  noise. The council and autopilot check each one before acting on it.
- **Two agents in one worktree.** Give each job its own `--branch`.
- **Expecting a commit.** bstack stages and stops. You review in tuicr and
  commit. Autopilot is the one exception, and only on the PR's branch.
- **Pinning a model and forgetting it.** A pin skips every new release. Leave
  it empty unless you have a reason.

Back to the [guide index](./README.md).
