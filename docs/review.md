# review

Agents stage their changes and leave them uncommitted. When the desk agent finishes, [tuicr](https://github.com/agavra/tuicr) opens that work so you can read it in the terminal. Comments stay human vs AI, and you choose what gets a GitHub comment.

Review is a tab in the space. Own work → `tuicr -w` (everything uncommitted: staged, unstaged, and untracked; agents stage and never commit unreviewed work); someone else's PR on this checkout → `tuicr pr <n>`. Bercail adds `-w` or `pr <n>` only with `review = "tuicr"` (see [config](config.md)); any other `review` runs as written.

It opens when the desk agent finishes a turn (done, or working → idle) and the checkout has uncommitted changes, the next time you look at that space. A clean tree does not auto-open. `Ctrl+Shift+R` opens it anytime; `auto_review = false` keeps only the key and the agent action. A live Review tab is not restarted: tuicr's diff watch, which bercail turns on, keeps a `-w` review current. A Review tab whose tool has quit opens fresh. An agent opens and closes it with `herdr-app do bercail-desk.review:$HC_TERMINAL_ID` and `bercail-desk.close-review:$HC_TERMINAL_ID`.

The desk mod reads `config.toml` when it loads, so a change to `review` or `auto_review` reaches it after the mod reloads (an app restart does it).

Inside tuicr, `j`/`k` move around. The `review` skill waits for your notes and publishes them to GitHub only when you ask; its helper scripts are listed under [skills](cli.md#skills).

## Someone else's PR: `bercail review-pr`

The code in a teammate's PR was likely written by an agent, and review bots already comment on its lines. `bercail review-pr <PR url-or-branch>` reviews its whole stack by intent and decisions: what each PR is for, the choices it made, which of them nothing explains, and what it promised but didn't do. A single PR is a stack of one.

```bash
bercail review-pr https://github.com/OWNER/REPO/pull/123
```

1. **Discover and gather**: Graphite-initialized repos use `gt` in an isolated clone. Other repos and cross-repo fork entries walk GitHub PR bases down to trunk and children up to the top. Calling with any PR in the stack resolves the same bottom (root) PR. PR bodies, closing issues, Linear ids (only noted), diffs, and `gh pr checks` are gathered in parallel. Checks are kept even when gh exits non-zero. Artifacts live in `${XDG_STATE_HOME:-~/.local/state}/bercail/reviews/<host>/<owner>/<repo>/stack-<root>/`, with one `pr-<n>/<head sha>/` per PR head. `stack.json` records order, parent SHAs and the current PR; `stack.md` gives the stack's order, bases and intent. Each PR's diff is against its parent, not trunk.
2. **Worktree and space**: one detached sibling worktree, such as `~/Work/leftlane_app.review-123`, starts at the root PR. Bercail uses its normal worktree layout helper, so Herdr groups the desk under the reviewed repo rather than creating an unrelated state-directory review space. The main checkout's branch, files, config and other worktrees stay untouched. Graphite synchronization happens only in an isolated clone, never in your checkout.
3. **Thin check**: an empty body, a body that only restates the title, no linked issue (GitHub or Linear), or only "part N of M". The printed JSON lists flags and pass status **per PR**. Thin PRs wait; the rest start immediately. Shep asks only about flagged PRs. `bercail review-pr run N --stack DIR` explicitly reviews one, including a thin PR. `--no-run` gathers without starting any passes.
4. **The decisions passes**: one read-only `bstack-pr-review` opencode run per non-thin PR, all in parallel. Bercail never passes `--model`. Each agent runs outside the reviewed repo with immutable, SHA-pinned file context in its run dir, so moving the worktree cannot change what it reviews. Shell, edits, subagents, external directories, network and MCP tools are denied. No bug hunting, style, nits, or tests. Validated output becomes `review.json` (`bercail.review/v1`); `run.json` records `ready`, `blocked`, or `failed` with the session id. Per-PR locks allow parallel passes; gathering cannot replace inputs during a live pass.
5. **The cards**: the Stack tab lists PRs bottom-to-top with a card preview (`bercail review-pr card N`): why, decisions with kind, `file:line`, stated or undocumented, fit with intent, unmet intent, author questions, and CI. Rows reload as passes finish. **Enter** switches the one detached worktree to that PR and updates `current`; **d** pages `git diff <parent head>...<head>`. A multi-PR stack also shows the `stack.md` header.
6. **tuicr, if the card isn't enough**: `t` opens the Review tab on `tuicr pr <n>` and adds each question as a draft note by `bstack`, starting `[AI Agent] `, on the decision's line (the whole PR when it has none). Edit, delete, add your own, then `:submit`. `o` opens the PR in the browser.

Agents never post. You do, from tuicr's `:submit` or GitHub, and every draft you keep goes out as yours, labelled `[AI Agent]`. In opencode, `/pr-review <run dir>` runs the same pass by hand.

If no checkout is found, bercail clones to `~/Work/<repo>` (or `~/Work/<owner>-<repo>` if the first path belongs to something else), then creates its sibling review worktree. It never overwrites an existing checkout. A newly cloned repo uses the generic GitHub walk because it has no local Graphite configuration.

If a process is killed during lock recovery, an empty `*.lock.reap` directory can remain and block retries. After confirming no gather, pass or open process is using that stack, remove that empty directory with `rmdir`. Do not remove a live process's lock.

Bercail refuses to reuse an unmarked sibling, or switch a review worktree that has edits or is no longer detached. An interruption between worktree creation and writing its marker can leave an unmarked sibling. Inspect it and remove it with `git worktree remove <path>` before retrying. Do not force removal of user changes.

Bot review summaries and refresh after a push are separate slices. When a stack branches or has ambiguous parents, bercail prints a notice and reviews the requested PR alone. It never chooses a partial path through a fork. Cycles, truncated discovery and API errors still fail.
