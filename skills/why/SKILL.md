---
name: why
description: >-
  Finds out why code is the way it is from the record: git history, the PRs and
  beads issues behind it, review threads, and docs. Separates what the record
  says from what you infer. Use for "why is X like this", "can we remove Y",
  "does this still hold", or before changing code whose reason is unclear.
---

# why

The record answers "why", not your guess. Every claim cites where it came from.
"Nobody wrote it down" is an answer, and a useful one. Change nothing.

## 1. Anchor

Name the exact thing: `path:line-range`, a symbol, a flag, a config value. Then
find the commits that shaped it:

```bash
git log -L <start>,<end>:<path> --format='%h %ad %an %s' --date=short   # that range over time
git log -S '<literal>' --format='%h %ad %s' --date=short -- <path>       # when it appeared or vanished
git blame -w -C -L <start>,<end> <path>
```

Read the full message of each commit that matters (`git show --stat <sha>`).

## 2. Follow the trail

In parallel where the harness has subagents (`explore`), otherwise in turn:

- **PRs:** `gh pr list --state all --search <sha>`, then `gh pr view <n> --comments`
  for the body and the review threads.
- **beads:** issue ids in commit messages or branch names (`bd show <id>`), and
  `bd search <topic>`.
- **Handoffs:** `~/.local/state/agentic-dev/handoffs.jsonl` names the issue and
  branch of each agent job.
- **In the repo:** comments next to the code, README, CHANGELOG, docs, tests
  named after a bug.
- **Elsewhere:** whatever the harness can reach (an issue tracker, chat, error
  tracking). Say which ones you could not reach.

## 3. Weigh it

Label each claim:

| Label | Means |
|-------|-------|
| **said** | the record states it (a commit, PR, issue, or comment), quoted |
| **shown** | the code or a run shows it |
| **inferred** | follows from said and shown, with the step written out |
| **guess** | plausible, nothing backs it; say "appears to" |
| **unknown** | looked, found nothing |

Do not raise a label because the story is tidy. Two weak sources agreeing are
still weak.

## 4. Answer

```
## Answer          one paragraph, with labels
## Timeline        date, sha or PR, what changed and the reason given
## Does it still hold   is the reason true of the code today? shown or guess
## Sources         what you searched, including the ones that came up empty
```

When the question comes before a change, add:

```
## Keep    what the reason still protects
## Change  what the reason no longer covers
## Risk    what could break, and the test or check that would catch it
```
