# config

`~/.config/bercail/config.toml`:

```toml
[layout]
review = "tuicr"                     # or "hunk"
auto_review = true

[bstack]                             # --no-bstack installs: none, and the desk runs plain Pi
enabled = true
fallback = ["claude", "gpt", "grok"] # Pi rate-limit candidates, no duplicates
claude = ""
gpt = ""
grok = ""
effort = "high"
lead = "claude"
build = "grok"
judge = "claude"

[git]                                # optional, one line per main checkout
"~/Work/some-repo" = "gh"              # gh | gt | origin

[policy."~/Work/some-repo"]          # optional: your override of that repo's git policy
commit = "allow"

[shep]                               # optional: Shep's compaction
compact_at = 250000                  # context tokens at which Pi compacts Shep
keep_recent = 50000                  # recent tokens kept word for word
rollover = false                     # true: a fresh session instead, and each new day
```

After you edit it, `bercail reconfigure` re-reads it, refreshes the skills and bstack, and installs Pi and the review tool if they are missing. The desk always runs Pi: bstack's lead when bstack is on, else plain `pi`. What the `[bstack]` keys do (pins, `effort`, roles) is in [Make it yours](bstack/08-make-it-yours.md#models-and-roles); `review` and `auto_review` in [review](review.md); `[git]` in [handoff](handoff.md#git-backend); `[policy."<path>"]` in [git policy per repo](#git-policy-per-repo); `[shep]` in [Shep's compaction](shep.md#compaction), read at Shep's next start. Legacy `[graphite]` booleans still work (`true` → `gt`, `false` → `gh`), but `[git]` takes precedence.

## Git policy per repo

Each repo can say how its agents commit, push, and release, in `.bercail/policy.toml`, committed so the team shares it. bercail's own is in this repo:

```toml
commit = "allow"            # ask | allow: may an agent commit without a prompt
push = "main"               # ask | branch (any branch but main/master) | main (main too)
integrate = "direct"        # pr (a PR the person reviews) | direct (straight to main)
pr_draft = false            # open PRs as drafts
release = "Bump the version in lib/common.sh, ..., then tag it v<version> and push the tag."
agent_may_release = false   # may an agent tag and release without a prompt
rules = """
Free text: commit style, gh or gt, who merges.
"""
```

With no file, the guard asks before a commit or push and no agent releases, as before policies existed.

- **Effective policy.** `bercail policy show [repo]` prints each value and where it came from: your override, the repo file, or the default. `--json` is what the guard and handoff read. A linked worktree reads its own copy of the file, and its main checkout's override and trust.
- **Your override.** `[policy."<main checkout>"]` in `config.toml`, keyed like `[git]`. It wins over the repo file and needs no trust: it is your file.
- **Trust.** A repo value that lets agents do more (`commit = "allow"`, `push = "branch"` or `"main"`, `agent_may_release = true`) counts only after you run `bercail policy trust [repo]`, like `mise trust`. bercail stores the file's sha256 per main checkout in `~/.local/state/bercail/policy-trust.json`. Any edit to the file, including one a desk makes on its branch, changes the hash, and those values go back to the default until you trust it again. `bercail policy untrust [repo]` forgets it. Values that loosen nothing (`integrate`, `pr_draft`, `release`, `rules`) apply as soon as the file is there.
- **What the guard does with it.** On a desk, Shep, a sibling, or a headless run, the guard lets a commit or push through without a prompt when the trusted policy allows it, and asks (or, headless, blocks) otherwise. A push under `push = "branch"` goes through unless it may reach `main` or `master`: a push there, `--all`, a glob refspec, or a bare push after a `checkout`, `switch`, or `rebase` in the same command. A tag (`git tag v1.2.0`, a pushed `v1.2.0` or `refs/tags/…`, `--tags`, `--follow-tags`), `gh release create`, or a `gh api` write to releases or tag refs goes through only with `agent_may_release = true`; otherwise it asks on a desk, where you can say yes, and blocks autopilot and headless runs. Autopilot keeps its own rules: it commits and pushes its PR branch, never main. Judge and council stay read-only.
- **Never loosened.** Force-push, `+` refspecs, `--mirror`, deleting `main` or `master` (`--delete` or `:main`), `--no-verify`, `gh pr merge`, and setting the git config that changes what a later push or commit does (`core.hooksPath`, `remote.*.push`, `remote.*.mirror`, `push.*`, `alias.*`, `include.*`, through `git config`, `git -c`, or `GIT_CONFIG_*`) stay blocked under any policy. The guard also blocks `bercail policy trust` and writes to `config.toml` or the trust file, through the edit tools or a shell redirect, `tee`, `cp`, `sed`, and the like. That is a seatbelt, not a sandbox: an agent running as you can still reach those files another way. Trust only repos whose agents you would let commit anyway.
- **Scratch repos.** A repo under a temp dir (`$TMPDIR`, `/tmp`, `/var/tmp`) with no remote and no entry in `config.toml` is scratch: the guard lets commits there through. A temp copy of a repo with a policy counts too, unless that policy says `commit = "ask"`. Pushes still follow the policy.
- **Which repo.** The guard checks the repo each git command runs in: `git -C <dir>` and a `cd <dir> &&` before it count. When it cannot tell (a `cd "$VAR"`, a subshell, `--git-dir`, or a `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` set or exported anywhere in the command), it uses the default.
- **Known gaps.** Pushing a tag that already exists under a name that does not look like a version (`git push origin stable`) counts as a branch push. `gh workflow run` is not treated as a release. A command word the shell computes (`$(command -v git) push --force`, `bercail $P trust`) is not recognized at all. `eval`, `source`, a git alias, or a branch switch earlier in the same command make the guard treat the repo and branch as unknown, so it asks.
- **The log.** Every command the guard lets through on a policy, the scratch rule, or autopilot's role is appended to `~/.local/state/bercail/guard-approvals.jsonl` with the time, terminal, role, folder, command (URL credentials masked), and why: `jq . ~/.local/state/bercail/guard-approvals.jsonl`.
- **What agents read.** Every Pi agent that loads the guard gets the effective policy of its folder, rules included, as a `bercail_git_policy` section of its system prompt, refreshed at the start of each run. Text from a file you have not trusted is labeled as the repo's, not yours. The handoff comment names the policy in one line. Agents still stage and leave work uncommitted for review; the policy says how to commit, push, or release once someone asks.
- **Without bstack.** The guard and the policy prompt come with bstack's Pi profile. With bstack off, neither the desks nor Shep load them, and nothing enforces a policy.

## Files bercail manages

- `~/.config/herdr-app/layouts/bercail.json`, `mods/bercail-desk/`, `mods/bercail-shep/`, `mods/bercail-spaces/`, `mods/bercail-agents/` and `mods/bercail-review/` (the app rewrites the layout as you use it, so `bercail update` replaces it only when bercail ships a new one), and the `layout:bercail` section of `keys.json` (see [keys](keys.md)).
- `~/.config/bercail/` (`config.toml`, `shell/`, `config-reader.sh`, `config.toml.example`, `notify.d/`), and the marker block in your `~/.bashrc` or `~/.zshrc` that sources the shell helpers.
- worktrunk hooks (`~/.config/worktrunk/config.toml`, `herdr-layout.sh`).
- `~/.local/bin/{bercail,agentic-dev,bercail-desk-agent}` (a mise or packslip install keeps its own `bercail`), and `~/.local/share/bercail/`.
- `~/.agents/skills/{handoff,review,bstack,council,autopilot,how,why,unslop,desk-restore,unit-testing}`, with a link to each in `~/.pi/agent/skills`.
- bstack's Pi profile in `~/.local/share/bercail/pi/` and role templates in `~/.config/herdr-core/templates/` (see [Make it yours](bstack/08-make-it-yours.md#your-own-files)). bstack installs `npm:pi-claude-bridge@0.11.0` into Pi's package settings.
- The Pi extension `~/.local/share/bercail/pi-extensions/bercail-desk.ts` that every Pi desk loads with `-e`, including when bstack is off.
- `diff_watch_interval_ms` in `~/.config/tuicr/config.toml`, unless you set it already.
- On Linux and Omarchy, the extras in [platforms](development.md#platforms).

## Desks after a reboot

Herdr brings back spaces, tabs, and each desk's terminal, but as a bare shell: it never reruns a program. So `bercail-desk-agent` writes down what ran there, and the desk comes back on the same session in the same space, with no prompt sent again.

- **The record.** `~/.local/state/bercail/desk-sessions/<address>.json` holds `session`, `cwd`, `harness`, `issue`, `issue_title` (empty when unknown), `space`, `args` (resume-safe flags) and `pid`, keyed by the terminal's address. The `bercail-desk` Pi extension records the session Pi has open, even while idle and with bstack off. A watcher touches the file every minute while the desk lives. Headless runs get no record.
- **What comes back.** A record fresh within ten minutes of shutdown (the last journal line of the previous boot), on a desk at a bare shell, in a folder that still exists, whose session is not already open. Records written since shutdown also qualify for a manual restore after a core stop/start. A desk you quit has finished, so it stays quit. Older records stay shells.
- **Duplicate checks.** Restore checks process arguments, all live Herdr terminals' status records, and the Pi extension's runtime claims in `$XDG_RUNTIME_DIR/bercail/open-sessions/`. Claims include idle sessions, and count only while their original process is alive. A Pi started before the extension was installed may have no claim: check those manually before restoring.
- **When.** Once per boot, through Omarchy's post-boot hook or else a systemd user unit: it waits until you open Herdr, then a notification says how many came back. Omarchy logs to `~/.local/state/bercail/desk-restore.log`; systemd logs to `journalctl --user -u bercail-desk-restore`. After a core restart, or to run it yourself, use `bercail desk restore`; `--dry-run` lists each desk and why.
- **What does not.** A Pi with no session saved (`--no-session`) has nothing to resume. The lead's `hc` siblings (builder, judge, council) are not desks and stay shells. No boot hook runs on macOS or without Omarchy/systemd; manual restore is still available. For these, and for desks from before records existed, the `desk-restore` skill finds the session by folder and content. Install/update wires the hooks for future sessions, not agents already running.
