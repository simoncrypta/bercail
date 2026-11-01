# review

Agents stage their changes and leave them uncommitted. When the desk agent finishes, [tuicr](https://github.com/agavra/tuicr) opens that work so you can read it in the terminal. Comments stay human vs AI, and you choose what gets a GitHub comment.

Review is a tab in the space. Own work → `tuicr -w` (everything uncommitted: staged, unstaged, and untracked; agents stage and never commit unreviewed work); someone else's PR on this checkout → `tuicr pr <n>`. Bercail adds `-w` or `pr <n>` only with `review = "tuicr"` (see [config](config.md)); any other `review` runs as written.

It opens when the desk agent finishes a turn (done, or working → idle) and the checkout has uncommitted changes, the next time you look at that space. A clean tree does not auto-open. `Ctrl+Shift+R` opens it anytime; `auto_review = false` keeps only the key and the agent action. A live Review tab is not restarted: tuicr's diff watch, which bercail turns on, keeps a `-w` review current. A Review tab whose tool has quit opens fresh. An agent opens and closes it with `herdr-app do bercail-desk.review:$HC_TERMINAL_ID` and `bercail-desk.close-review:$HC_TERMINAL_ID`.

The desk mod reads `config.toml` when it loads, so a change to `review` or `auto_review` reaches it after the mod reloads (an app restart does it).

Inside tuicr, `j`/`k` move around. The `review` skill waits for your notes and publishes them to GitHub only when you ask; its helper scripts are listed under [skills](cli.md#skills).
