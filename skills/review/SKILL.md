---
name: review
description: >-
  Wait for human hunk comments after the agent pane goes done, address them,
  and publish those user comments to the GitHub PR only when asked. Do not
  open hunk on every turn; the layout hook already does.
compatibility: Requires Herdr (HERDR_ENV=1), the agentic-dev.layout plugin, and hunk.
---

# review

The layout plugin opens hunk when the agent pane reports `done` if there is a
PR-shaped diff: `hunk diff origin/main --watch --agent-notes` on a feature
branch (working tree vs main, committed + uncommitted), or `hunk diff --watch
--agent-notes` on main. Use this skill when the user asks to review, wait for
notes, or publish notes to GitHub.

Human notes (`c` in hunk) are `--type user`. Agent notes are `--type ai` /
`--type agent`. Never treat agent notes as the user's review, and never post
them to GitHub as the user.

## When

- User asks to review, wait for comments, or publish comments to a PR.
- Not at session start. Not after every file write. Not after handoff.

## Guard

```bash
test "${HERDR_ENV:-}" = 1
```

If that fails, tell the user to press `prefix+2` (Ctrl-Space then 2) and wait
for them to say comments are ready. Do not run `hunk diff` in this pane.

## Recipe

1. Open (or focus) Review only if the user asked and it is not already open:

```bash
herdr plugin action invoke agentic-dev.layout.select-review
```

2. Load hunk's session skill (do not copy its flags here):

```bash
hunk skill path
```

Use `hunk session *` against `--repo .` (or this worktree). Optional: navigate,
add **agent** notes, highlight.

3. Wait for human notes (`c` in hunk) or for hunk to quit (`q`):

```bash
"$HOME/.agents/skills/review/scripts/wait-comments.sh" --repo . --timeout 600
```

| Exit | Meaning | Next |
|------|---------|------|
| 0 | New **user** comments on stdout (JSON) | Address them, then wait again or close |
| 2 | Live session gone (user quit hunk) | Review ended; close leftover tab if needed |
| 124 | Timeout | Leave Review open; ask the user |

Retry with network/sandbox escalation if loopback `127.0.0.1:47657` is blocked.

4. Publish to the GitHub PR **only when the user asks**. Posts `--type user`
   notes only. Needs an open PR for this branch (`gh pr create` first if none):

```bash
"$HOME/.agents/skills/review/scripts/publish-github.sh" --repo .
```

`--event comment` (default), `approve`, or `request-changes`. Own PRs cannot
be approved; the script falls back to `comment`. Do not invent a PR. Do not
auto-publish after every wait.

5. After the round, close Review (docks stickies back to Shell):

```bash
herdr plugin action invoke agentic-dev.layout.close-review
```

Reopen later with step 1. The human can also `prefix+2` / `prefix+k`.

## Do not

- Run `hunk diff` / `hunk show` in the agent pane (the TUI is for the user).
- Open Review on every edit.
- Restate hunk session CLI flags; `hunk skill path` is the source of truth.
- Post `--type ai` / `--type agent` notes as a GitHub review.
- Impersonate the user's comments.
