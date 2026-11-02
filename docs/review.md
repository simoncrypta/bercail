# review

Agents stage their changes and leave them uncommitted. When the desk agent finishes, [tuicr](https://github.com/agavra/tuicr) opens that work so you can read it in the terminal. Comments stay human vs AI, and you choose what gets a GitHub comment.

Review is a tab in the space. Own work → `tuicr -w` (everything uncommitted: staged, unstaged, and untracked; agents stage and never commit unreviewed work); someone else's PR on this checkout → `tuicr pr <n>`. Bercail adds `-w` or `pr <n>` only with `review = "tuicr"` (see [config](config.md)); any other `review` runs as written.

It opens when the desk agent finishes a turn (done, or working → idle) and the checkout has uncommitted changes, the next time you look at that space. A clean tree does not auto-open. `Ctrl+Shift+R` opens it anytime; `auto_review = false` keeps only the key and the agent action. A live Review tab is not restarted: tuicr's diff watch, which bercail turns on, keeps a `-w` review current. A Review tab whose tool has quit opens fresh. An agent opens and closes it with `herdr-app do bercail-desk.review:$HC_TERMINAL_ID` and `bercail-desk.close-review:$HC_TERMINAL_ID`.

The desk mod reads `config.toml` when it loads, so a change to `review` or `auto_review` reaches it after the mod reloads (an app restart does it).

Inside tuicr, `j`/`k` move around. The `review` skill waits for your notes and publishes them to GitHub only when you ask; its helper scripts are listed under [skills](cli.md#skills).

## Someone else's PR: `bercail review-pr`

The code in a teammate's PR was likely written by an agent, and review bots already comment on its lines. `bercail review-pr <PR url>` reviews it by intent and decisions instead: what the PR is for, the choices it made, which of them nothing explains, and what it promised but didn't do.

```bash
bercail review-pr https://github.com/OWNER/REPO/pull/123
```

1. **Gather** (plain `gh` and `git`, in parallel): the PR body, its closing issues, Linear ids (only noted), `gh pr diff`, and `gh pr checks` (kept even though gh exits non-zero while checks pend or fail). Everything goes in the run dir, `${XDG_STATE_HOME:-~/.local/state}/bercail/reviews/<host>/<owner>/<repo>/stack-<n>/`, one `pr-<n>/<head sha>/` per head: `intent.md`, `diff.patch`, `ci.json`, then `review.json`, `run.json`, `seeded.json`.
2. **Worktree and space**: a detached worktree at the PR head, `stack-<n>/worktree`, backed by a private bare clone in the reviews dir. Bercail clones locally from a matching checkout when available, otherwise from GitHub with a blobless clone. Symlink settings apply only to this private repo. Your source checkout stays untouched. The space is `Review-<n>_<Repo>`, with a bstack desk for questions and a **Stack** tab.
3. **Thin check**: an empty body, a body that only restates the title, no linked issue (GitHub or Linear), or only "part N of M". The JSON the command prints lists the flags per PR. Any flag stops there: Shep asks you whether to review anyway (`bercail review-pr run`) or ask the author first.
4. **The decisions pass**: with no flag, one read-only `bstack-pr-review` opencode run starts on its own, on the lead's model from `[bstack]`. It can read and search the run dir and worktree. Shell, edits, subagents, network and MCP tools are denied. Git symlinks become plain text on checkout. No bug hunting, style, nits, or tests. Bercail validates its JSON before writing `review.json` (`bercail.review/v1`). `run.json` records `ready`, `blocked`, or `failed` with the session id. A stack lock prevents a gather from moving the worktree during a pass.
5. **The card**: the Stack tab is an fzf list with the card as its preview (`bercail review-pr card`): why, each decision with kind, `file:line`, stated or undocumented, and fit with the intent, intent with no change, questions for the author, and CI. It reloads when `run.json` lands.
6. **tuicr, if the card isn't enough**: `t` opens the Review tab on `tuicr pr <n>` and adds each question as a draft note by `bstack`, starting `[AI Agent] `, on the decision's line (the whole PR when it has none). Edit, delete, add your own, then `:submit`. `o` opens the PR in the browser.

Agents never post. You do, from tuicr's `:submit` or GitHub, and every draft you keep goes out as yours, labelled `[AI Agent]`. In opencode, `/pr-review <run dir>` runs the same pass by hand.

If a process is killed during lock recovery, an empty `*.lock.reap` directory can remain and block retries. After confirming no gather, pass or open process is using that stack, remove that empty directory with `rmdir`. Do not remove a live process's lock.

This is slice 1: one PR as a stack of one. Bot review summaries, real stacks, and refresh after a push come later.
