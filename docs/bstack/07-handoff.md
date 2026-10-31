# Run jobs in parallel

One desk, one job. For more than one, hand them off.

## The job is a beads issue

```text
/handoff fix the flaky upload test, and separately add retries to the webhook sender
```

`/handoff` writes one beads issue per job (`bd create`) with the ask, the repo,
links, and what done looks like, then spawns each one. The issue is the whole
spec. The agent's prompt is one line that points at it.

## A desk or headless

- **`--branch NAME`:** a sibling worktree with its own space in the Herdr app.
  Its desk runs opencode as `bstack`, stages its work, and goes `done`. You
  review it in that space's tuicr.
- **No branch:** a headless `opencode run --agent bstack`. It writes
  `.bercail/handoff-result.json` (`status` ready, blocked, or failed, a summary,
  the session id; `reason` is `usage-limit` when a plan is exhausted) and nothing opens.
  It edits and stages but can't commit, push, or merge: a headless run rejects
  anything that would ask. Stage `autopilot` is the exception (see
  [Ship with autopilot](./06-autopilot.md)).

Stage `bstack` runs on the lead's model. `--binary opencode` with `--stage start`
or `--stage codex` runs Claude or GPT through your opencode plans instead.

Follow a desk with `hc wait <desk>`. Each spawn is logged in
`~/.local/state/agentic-dev/handoffs.jsonl`.

## Shep

[Shep](../../README.md#shep-the-grok-bot), the Grok bot, drives the same
handoffs from your phone. It writes the issue, picks the stage, and pings you
when a desk is ready for review. bstack is one of the stages it can pick.

## Leave it running

A long run stays honest when it has a check it can't fake and a record you can
read later:

```text
keep going until every fixture passes. don't stop to ask. log each decision and why in the beads issue as a comment.
```

The beads comments become the audit trail. Read them before you read the diff.

**Pitfall:** two agents in one worktree. They overwrite each other, and nobody
can tell who changed what. Give each job its own `--branch`.

Next: [Make it yours](./08-make-it-yours.md).
