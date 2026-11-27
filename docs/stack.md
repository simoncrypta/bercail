# What bercail assumes, and why these tools

## Built for one setup

bercail is Simon's own development environment, published as it runs on his
machine. This table lists what it assumes, so you can see what you would keep
and what you would replace.

| Assumed | Simon's | What uses it | Without it |
|---------|---------|--------------|------------|
| A desktop | [Omarchy](https://omarchy.org) (Arch, Hyprland) | A post-update hook that updates a clone install of bercail, a post-boot hook that brings desks back, `SUPER+ALT+RETURN` for the Herdr app ([platforms](development.md#platforms)) | Ubuntu, Debian and macOS install and run it. Other Linux with a systemd user manager gets the desk restore as a user unit |
| [The Herdr app](https://herdr.dev) and herdr-core | the same | Every space, desk and view | Required |
| A Claude plan | Claude Max | By default Shep, every desk, the builder and autopilot ([setup](bstack/01-setup.md)) | Assumed. Claude Pro signs in the same way. A role can be pinned to another Pi model ([Make it yours](bstack/08-make-it-yours.md)); with no sign-in at all, agents use Pi's default model |
| A ChatGPT plan | ChatGPT Pro | The judge, and `bercail review-pr`'s reviewer | Optional: the judge runs on Claude instead, Fable first |
| [Basecamp](https://basecamp.com) | to-do lists per project | Shep's [todos for you](shep.md#todos-for-the-person) | Optional. Basecamp is `bercail todo`'s one backend, so without it Shep has no list to put your todos on |
| [1Password](https://1password.com) | `op` with a service account per repo | [Desk secrets](config.md#a-desk-secret-per-repo) | Optional, set per repo |
| [Entire](https://entire.com) | on some repos | Session capture, trails, Brain ([Entire](entire.md)) | Optional, turned on per repo |
| GitHub, through `gh` | the same | PRs, CI runs for the land card, `bercail review-pr` | A repo can use Graphite (`gt`), Origin or Entire instead ([git backend](handoff.md#git-backend)) |

**Fork it.** Some of it will not fit you: another todo app, another desktop,
another review tool. Fork the repo and change it. The CLI is bash, one file per
area under `lib/`, and [development](development.md) shows how to run the tests.
The policy file, `config.toml` and the bstack roles are made to be changed
without a fork ([config](config.md), [Make it yours](bstack/08-make-it-yours.md)).

## Why these tools

- **[Herdr](https://herdr.dev).** Its terminals run in herdr-core, apart from the
  window, so a desk keeps working when the window closes or restarts. Its layouts
  and mods let bercail draw the desk column, the Shep view and its panels in
  JavaScript, without a fork of the app. Each agent reports its status (working,
  blocked, done) to herdr-core, which is how the sidebar and Shep know where a desk
  is.
- **[Pi](https://pi.dev).** It signs in with a Claude plan, through
  [pi-claude-bridge](https://www.npmjs.com/package/pi-claude-bridge) and Claude
  Code, and with a ChatGPT plan, so one agent runs on the subscriptions you already
  pay for. Its extensions are where bercail puts the guard, the rate-limit pause
  and the desk's record. See [bstack](bstack.md).
- **[beads](https://beads.gascity.com/).** An issue tracker in the repo, driven by
  the `bd` CLI. Agents read and write it the way you do, so the issue can be the
  job's spec: the desk reads it, reports on it, and Shep keeps the dispatch record
  in its metadata.
- **[Entire](https://entire.com).** It records the agent session behind each commit,
  so the reason for a change stays with it. A repo hosted on Entire uses trails
  for its jobs instead of beads ([Entire](entire.md)).
- **[worktrunk](https://github.com/max-sixty/worktrunk).** One worktree per job,
  made with `wt switch --create`. A desk's spawn runs it with `--no-hooks` and
  opens the space itself; for a worktree you make with `wt switch`, worktrunk's
  hooks open and close its Herdr space ([handoff](handoff.md#what-a---branch-spawn-does)).
  It stays because it supplies each project's path template and hooks, which
  plain `git worktree` and Herdr's worktree mod do not; the spawn's bugs were
  fixed in bercail's own glue.
- **[tuicr](https://github.com/agavra/tuicr).** Review in the terminal, on the
  uncommitted tree the desk left, watching it as the desk stages more. Comments
  stay marked human or AI, and you choose which go to GitHub ([review](review.md)).
- **[gh](https://cli.github.com) and gh stack.** bercail lives on GitHub. The land
  card reads CI through `gh run list`, and dependent branches use `gh stack`.
- **[mise](https://mise.jdx.dev) and [packslip](https://github.com/jdx/packslip).**
  Each release is a signed archive. mise or packslip checks the signature against
  this repository and the archive's digest before it unpacks anything, and runs no
  downloaded code ([install](install.md)).
- **A Cloudflare Worker for bercail.dev.** It serves `install.sh` from the latest
  release's tag, never from master, so a curl install gets what was released
  ([releasing](development.md#releasing)).

[Credits](credits.md) lists the projects bercail copies from or learned from.
