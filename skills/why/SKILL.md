---
name: why
description: >-
  Finds out why code is the way it is from the record: Entire's checkpoints in
  an Entire repo, git history, the PRs and beads issues behind it, review
  threads, and docs. Separates what the record says from what you infer. Use
  for "why is X like this", "can we remove Y", "does this still hold", or
  before changing code whose reason is unclear.
---

# why

The record answers "why", not your guess. Every claim cites where it came from.
"Nobody wrote it down" is an answer, and a useful one. Change nothing.

## 1. Anchor

Name the exact thing: `path:line-range`, a symbol, a flag, a config value.

In a repo where Entire capture is on (`entire status` says Enabled), start
with the checkpoint behind it:

```bash
entire why <path>:<line> --json                  # the checkpoints behind the line, and its commit and prompt when recorded
entire brain entities history <Symbol> --json    # the indexed commits and checkpoints that changed a symbol
```

Then, in every repo, find the commits that shaped it:

```bash
git log -L <start>,<end>:<path> --format='%h %ad %an %s' --date=short   # that range over time
git log -S '<literal>' --format='%h %ad %s' --date=short -- <path>       # when it appeared or vanished
git blame -w -C -L <start>,<end> <path>
```

Read the full message of each commit that matters (`git show --stat <sha>`).

## 2. Follow the trail

In an Entire repo, read Entire's record first:

- **Checkpoints:** `entire checkpoint explain <id> --no-pager` shows the
  intent and the part of the session that made the commit. `--full` is the
  whole session, often large. Never pass `--generate`: it writes a summary
  and spends tokens.
- **Search:** `entire search "<question>" --compact` ranks commits, sessions
  and checkpoints by meaning and keyword. It needs the network and the
  person's login. Open a hit with `entire checkpoint explain <id>`.
- **Brain:** `entire brain recall "<question>" --json` for recorded
  decisions, rejected approaches and gotchas. A memory's `provenance` names
  its checkpoint when it has one. `entire brain query --source history "<question>" --json`
  searches past sessions' text.

A checkpoint records the session that made the commit. For a merge, a rebase
or a replayed branch, that session may have moved the change without deciding
it. Confirm the commit with `git blame`. Before you name the decision, follow
the source sha the message gives, or `git log` past the replay, and read that
commit's checkpoint when it has one.

A command that fails for want of a login, the network, Brain or Graph's
index goes under Sources as not reached. Go on with the rest.

Then follow these sources in turn:

- **PRs:** `gh pr list --state all --search <sha>`, then `gh pr view <n> --comments`
  for the body and the review threads. In a repo hosted on Entire the PR is a
  trail: `entire trail show --branch <branch>` gives its intent and changes.
- **beads:** issue ids in commit messages or branch names (`bd show <id>`), and
  `bd search <topic>`.
- **Handoffs:** `~/.local/state/bercail/handoffs.jsonl` names the issue and
  branch of each agent job.
- **In the repo:** comments next to the code, README, CHANGELOG, docs, tests
  named after a bug.
- **Elsewhere:** whatever the harness can reach (an issue tracker, chat, error
  tracking). Say which ones you could not reach.

## 3. Weigh it

Label each claim:

| Label | Means |
|-------|-------|
| **said** | the record states it (a commit, checkpoint, PR, issue, or comment), quoted, with its id |
| **shown** | the code or a run shows it |
| **inferred** | follows from said and shown, with the step written out |
| **guess** | plausible, nothing backs it; say "appears to" |
| **unknown** | looked, found nothing |

Do not raise a label because the story is tidy. Two weak sources agreeing are
still weak. A Brain memory is **said** only with the checkpoint or commit its
`provenance` names, read; otherwise it is **inferred**.

## 4. Answer

```
## Answer          one paragraph, with labels
## Timeline        date, sha, checkpoint or PR, what changed and the reason given
## Does it still hold   is the reason true of the code today? shown or guess
## Sources         what you searched, including the ones that came up empty or you could not reach
```

When the question comes before a change, add:

```
## Keep    what the reason still protects
## Change  what the reason no longer covers
## Risk    what could break, and the test or check that would catch it
```
