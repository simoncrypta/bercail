---
name: review
description: >-
  Wait for human tuicr comments after the agent pane goes done, address them,
  and publish those user comments to the GitHub PR only when asked. Do not
  open tuicr on every turn; the layout hook already does.
compatibility: Requires Herdr (HERDR_ENV=1), the agentic-dev.layout plugin, and tuicr.
---

# review

The layout plugin opens tuicr when the agent pane reports `done` if there is a
PR-shaped diff. Own branch: `tuicr -r origin/main -w` (working tree vs main,
committed + uncommitted) with tuicr's diff watch so later edits show without
restarting. On main: `tuicr -w`. Someone else's PR on this checkout:
`tuicr pr <n>` (forge review, `:submit`). Pickr uses `tuicr pr {url}` for
other people's PRs. `prefix+2` opens Review anytime.

Human comments are written in the TUI (`c`). Agent comments use
`tuicr review add --username …`. Never treat agent comments as the user's
review, and never post them to GitHub as the user.

## When

- User asks to review, wait for comments, or publish comments to a PR.
- Not at session start. Not after every file write. Not after handoff.

## Guard

```bash
test "${HERDR_ENV:-}" = 1
```

If that fails, tell the user to press `prefix+2` (Ctrl-Space then 2) and wait
for them to say comments are ready. Do not run `tuicr` in this pane.

## Recipe

1. Open (or focus) Review only if the user asked and it is not already open:

```bash
herdr plugin action invoke agentic-dev.layout.select-review
```

2. Find the live session (do not copy CLI flags here; `tuicr review --help`
   is the source of truth):

```bash
tuicr review list --repo .
```

Attach to the row with `"active": true`. One repo can hold a worktree session
and a PR session at once — if more than one is active, ask which slug.

3. Wait for human comments (`c` in tuicr) or for the live session to go away
   (`:q` / `q`):

```bash
"$HOME/.agents/skills/review/scripts/wait-comments.sh" --repo . --timeout 600
```

| Exit | Meaning | Next |
|------|---------|------|
| 0 | New **user** comments on stdout (JSON) | Address them, then wait again or close |
| 2 | Live session gone (user quit tuicr) | Review ended; close leftover tab if needed |
| 124 | Timeout | Leave Review open; ask the user |

Treat comment `comment_type` as: `issue` (fix first), `suggestion` (do or
explain why not), `note` (answer), `praise` (no action). Empty comments with
`reviewed_count == file_count` on `tuicr review list` is a completed review
with nothing to flag.

4. Publish to the GitHub PR **only when the user asks**.

- In `tuicr pr` mode the human can `:submit` in the TUI (Comment / Approve /
  Request changes). Prefer that when they are already in a PR session.
- For a local (own-branch) session, post user comments only:

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

- Run `tuicr` / `tuicr pr` in the agent pane (the TUI is for the user).
- Open Review on every edit. Watch keeps an open session current.
- Post agent-authored comments (`tuicr review add --username`) as a GitHub review.
- Impersonate the user's comments.
