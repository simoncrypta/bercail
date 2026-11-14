# config

`~/.config/bercail/config.toml`:

```toml
[layout]
review = "tuicr"                     # or a command of yours
auto_review = true

[bstack]
fallback = ["claude", "gpt", "grok"] # Pi rate-limit candidates: families or Pi model ids, no duplicates
claude = ""
gpt = ""
grok = ""
effort = "high"
lead = "claude"
build = "grok"
judge = "claude"

[git]                                # optional, one line per main checkout
"~/Work/some-repo" = "gh"              # gh | gt | origin | entire

[policy."~/Work/some-repo"]          # optional: your override of that repo's git policy
commit = "allow"

[shep]                               # optional: Shep's compaction
compact_at = 250000                  # context tokens at which Pi compacts Shep
keep_recent = 50000                  # recent tokens kept word for word
rollover = false                     # true: a fresh session instead, and each new day
```

After you edit it, `bercail reconfigure` re-reads it, refreshes the skills and bstack, and installs Pi and the review tool if they are missing. The desk always runs bstack's Pi lead. What the `[bstack]` keys do (pins, `effort`, roles) is in [Make it yours](bstack/08-make-it-yours.md#models-and-roles); `review` and `auto_review` in [review](review.md); `[git]` in [handoff](handoff.md#git-backend); `[policy."<path>"]` in [git policy per repo](#git-policy-per-repo); `[shep]` in [Shep's compaction](shep.md#compaction), read at Shep's next start.

Those are all the keys bercail reads. `bercail doctor` names any other key in the file (`unknown  [shep] session (nothing reads it)`), a `[git]` value that is not a backend, and a line it cannot read; none of them counts as a failure. `bercail config get <section> <key>` prints one value as bercail reads it. The file is read as a subset of TOML: quoted and `"""` strings, `true` and `false`, whole numbers, and one-line arrays.

## Git policy per repo

Each repo can say how its agents commit, push, and release, in `.bercail/policy.toml`, committed so the team shares it. bercail's own is in this repo:

```toml
commit = "allow"            # ask | allow: may an agent commit without a prompt
push = "main"               # ask | branch (any branch but main/master) | main (main too)
integrate = "direct"        # pr (a PR the person reviews) | direct (straight to main)
pr_draft = false            # open PRs as drafts
release = "Bump the version in lib/common.sh, ..., then tag it v<version> and push the tag."
agent_may_release = false   # may an agent tag and release without a prompt
pr_template = ""            # the PR template to follow, or "none"; empty finds .github/, the root, then docs/
provenance = "line"         # line | trailer (Assisted-by:, Reviewed-by:) | none: the "written with" line on each description
review = "by-stakes"        # always | by-stakes | none: which changes wait for your LGTM before they land
# git glob pathspecs, one a line (or a one-line array): what makes a change high-stakes
high_stakes = """
lib/policy.sh
workers/
"""
diff_budget = 400           # lines one change adds and removes before /validate warns
review_budget = 1000        # lines waiting on your review before Shep warns at a new desk
rules = """
Free text: commit style, gh or gt, who merges.
"""
```

With no file, the guard asks before a commit or push and no agent releases, as before policies existed.

- **Effective policy.** `bercail policy show [repo]` prints each value and where it came from: your override, the repo file, or the default. `--json` is what the guard and handoff read. A linked worktree reads its own copy of the file, and its main checkout's override and trust.
- **Your override.** `[policy."<main checkout>"]` in `config.toml`, keyed like `[git]`. It wins over the repo file and needs no trust: it is your file.
- **Trust.** A repo value that lets agents do more (`commit = "allow"`, `push = "branch"` or `"main"`, `agent_may_release = true`) counts only after you run `bercail policy trust [repo]`, like `mise trust`. So does `review = "none"`, and a `diff_budget` or `review_budget` above the default. bercail stores the file's sha256 per main checkout in `~/.local/state/bercail/policy-trust.json`. Any edit to the file, including one a desk makes on its branch, changes the hash, and those values go back to the default until you trust it again. `bercail policy untrust [repo]` forgets it. Values that loosen nothing (`integrate`, `pr_draft`, `release`, `rules`, `pr_template`, `provenance`, `review = "always"`, `high_stakes`, smaller budgets) apply as soon as the file is there.
- **What the guard does with it.** On a desk, Shep, a sibling, or a headless run, the guard lets a commit or push through without a prompt when the trusted policy allows it, and asks (or, headless, blocks) otherwise. A push under `push = "branch"` goes through unless it may reach `main` or `master`: a push there, `--all`, a glob refspec, or a bare push after a `checkout`, `switch`, or `rebase` in the same command. A tag (`git tag v1.2.0`, a pushed `v1.2.0` or `refs/tags/…`, `--tags`, `--follow-tags`), `gh release create`, or a `gh api` write to releases or tag refs goes through only with `agent_may_release = true`; otherwise it asks on a desk, where you can say yes, and blocks autopilot and headless runs. `gt create` and `gt modify` follow commit policy. `gt submit`, `gh stack submit`, `gh pr create`, `origin stack push`, and `origin pr create` follow push policy, using the current branch for the branch check. The guard does not inspect which other branches a stack publisher sends. Autopilot keeps its own rules: it commits and pushes its PR branch, never main. Judge and council stay read-only.
- **Checks no policy loosens.** In recognized commands, the guard blocks force-push flags (including `gt submit --force` and `gh repo sync --force`), git `+` refspecs, `--mirror`, deleting `main` or `master` (`--delete` or `:main`), `--no-verify`, and PR merges (`gh pr merge`, `gt merge`, `gh api` writes to `/pulls/N/merge`). It also blocks setting the git config that changes what a later push or commit does (`core.hooksPath`, `remote.*.push`, `remote.*.mirror`, `push.*`, `alias.*`, `include.*`, through `git config`, `git -c`, or `GIT_CONFIG_*`), `bercail policy trust`, and writes to `config.toml` or the trust file through the edit tools or a shell redirect, `tee`, `cp`, `sed`, and the like. This is a seatbelt, not a sandbox: it checks the command text passed to Pi's bash tool, not everything an agent running as you can do. Trust only repos whose agents you would let commit anyway.
- **Scratch repos.** The guard lets a commit through without asking in two kinds of throwaway repo. Pushes and tags from either still follow the default policy.
  - A repo the same command made with `git init` inside a `mktemp -d` dir, remote or not: `cd "$(mktemp -d)" && git init -q r && cd r && git remote add origin https://x/y.git && git commit -m i`, or `T=$(mktemp -d); cd $T; git init r; cd r; git commit -m i`. The commit must run in that exact repo, and everything before it must run in a straight line of `&&`, `;` and newlines. An `if`, a loop, a function, a `{ }` group, a subshell, `||`, a pipe, or `&` ends the rule for the rest of the command. A variable must be set once, on its own or after `export`. A variable, `git init` or `cd` after `&&` counts only until that chain ends, and a `$` in single quotes or after a backslash is never read as the dir. `GIT_CONFIG_GLOBAL` and the other `GIT_CONFIG*` variables don't stop the rule, but `GIT_DIR` and the other variables that point git elsewhere do. Bash calls don't share state, so a dir made in an earlier call counts only under the next rule.
  - A repo under a temp dir (`$TMPDIR`, `/tmp`, `/var/tmp`) with no remote and no entry in `config.toml`. A temp copy of a repo with a policy counts too, unless that policy says `commit = "ask"`.
- **Which repo.** The guard checks the repo each git command runs in: `git -C <dir>` and a `cd <dir> &&` before it count. When it cannot tell (a `cd "$VAR"` other than a `mktemp -d` dir above, a `cd` in a pipe or in the background, a `cd` after `&&` once that chain ends, a subshell, `--git-dir`, or a `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` set or exported anywhere in the command), it uses the default. Explicit forge repo or host selectors (`-R`, `--repo`, `--hostname`) and directory selectors (`-C`, `--cwd`, `--directory`) also use the default, not the current folder's trust.
- **Known gaps.** Pushing a tag that already exists under a name that does not look like a version (`git push origin stable`) counts as a branch push. `gh workflow run` is not treated as a release. Commands launched inside another program (`python -c`, a script file) are not seen. A command word the shell computes (`$(command -v git) push --force`, `bercail $P trust`) is not recognized at all. Shell keywords and common wrappers (`if`, `then`, `else`, `while`, `until`, `do`, `{`, `!`, `time`, `exec`, `nohup`, `setsid`, `nice`, `timeout`, `xargs`) do not hide a literal command, but this is not a complete shell parser. `eval`, `source`, a git alias, or a branch switch earlier in the same command make the guard treat the repo and branch as unknown, so it asks. An `eval`'s words are joined and checked like a `bash -c` script.
- **The log.** Every command the guard lets through on a policy, the scratch rule, or autopilot's role is appended to `~/.local/state/bercail/guard-approvals.jsonl` with the time, terminal, role, folder, command (URL credentials masked), and why: `jq . ~/.local/state/bercail/guard-approvals.jsonl`.
- **What agents read.** Every Pi agent that loads the guard gets the effective policy of its folder, rules included, as a `bercail_git_policy` section of its system prompt, refreshed at the start of each run. Text from a file you have not trusted is labeled as the repo's, not yours. The handoff comment names the policy in one line. Agents still stage and leave work uncommitted for review; the policy says how to commit, push, or release once someone asks.

## Review by stakes and size

A swarm of desks can stage more in a day than you can review. Four policy keys say which changes wait for you and how much you take on at once.

- **Stakes.** `high_stakes` lists git glob pathspecs (`lib/policy.sh`, `workers/`, `site/worker*`; `*` stays inside a folder, `**` crosses folders, a folder name covers what is under it). A change that stages a matching path is high-stakes, and so is any edit to `.bercail/policy.toml` itself, staged or not, so a desk cannot lower its own change's stakes by editing the list on its branch. With `review = "by-stakes"` (the default) a high-stakes change waits for your LGTM before Shep commits or merges it, even in a repo that integrates straight to main; the rest keep their usual flow. `"always"` makes every change wait; `"none"` makes none wait, and needs trust. With no `high_stakes`, nothing is high-stakes. `/validate` records `stakes:` and `review:` in `.bercail/description.md`, `bercail describe check` prints them (measured from the commit the stamp saw, so a committed change keeps them), and in a repo that commits straight to main `bercail describe commit` refuses a change that waits for you until it gets `--reviewed-by`.
- **Size.** `diff_budget` is how many lines one change may add and remove before `bercail describe check` warns (400 by default, past what a reviewer reads well in one sitting). Lockfiles (by name: `package-lock.json`, `yarn.lock`, `Cargo.lock`, `go.sum`, …), binaries, and files `.gitattributes` marks `linguist-generated` are left out. It is a warning, never a failure: the desk splits the change, or its description says why it is one.
- **Queue.** `review_budget` is how many lines may wait on your review in the repo before Shep warns at a new desk there (1000 by default, about two hours of review). What waits: staged changes in worktrees whose desk is not working (done, idle, blocked, or gone), and, on GitHub, open PRs that ask you for a review or come from a handoff branch, not drafts and not approved. `bercail shep queue [--repo DIR]` lists them; `bercail shep board` ends with the same list. Shep tells you what waits and asks; it never refuses.

## Files bercail manages

- `~/.config/herdr-app/layouts/bercail.json`, `mods/bercail-desk/`, `mods/bercail-shep/`, `mods/bercail-spaces/`, `mods/bercail-agents/` and `mods/bercail-review/` (the app rewrites the layout as you use it, so `bercail update` replaces it only when bercail ships a new one), and the `layout:bercail` section of `keys.json` (see [keys](keys.md)).
- `~/.config/bercail/` (`config.toml`, `shell/`, `config.toml.example`, `notify.d/`), and the marker block in your `~/.bashrc` or `~/.zshrc` that sources the shell helpers.
- worktrunk hooks (`~/.config/worktrunk/config.toml`, `herdr-layout.sh`).
- `~/.local/bin/{bercail,bercail-desk-agent}` (a mise or packslip install keeps its own `bercail`), and `~/.local/share/bercail/` (in it, `release/` is the release a curl install unpacked).
- `~/.agents/skills/{handoff,review,bstack,council,autopilot,how,why,unslop,desk-restore,unit-testing,describe}`, with a link to each in `~/.pi/agent/skills`.
- bstack's Pi profile in `~/.local/share/bercail/pi/` and role templates in `~/.config/herdr-core/templates/` (see [Make it yours](bstack/08-make-it-yours.md#your-own-files)). bstack installs `npm:pi-claude-bridge@0.12.0` into Pi's package settings, and a 40k compaction reserve for each `claude-bridge` model in `compaction.modelOverrides` there ([why](bstack.md#how-it-runs)).
- The Pi extension `~/.local/share/bercail/pi-extensions/bercail-desk.ts` that every Pi desk loads with `-e`.
- `diff_watch_interval_ms` in `~/.config/tuicr/config.toml`, unless you set it already.
- On Linux and Omarchy, the extras in [platforms](development.md#platforms).

## Desks after a reboot

Herdr brings back spaces, tabs, and each desk's terminal, but as a bare shell: it never reruns a program. So `bercail-desk-agent` writes down what ran there, and the desk comes back on the same session in the same space, with no prompt sent again.

- **The record.** `~/.local/state/bercail/desk-sessions/<address>.json` holds `session`, `cwd`, `harness`, `issue`, `issue_title` (empty when unknown), `space`, `args` (resume-safe flags, including the `--model` of a desk [handed off on another model](handoff.md) or [switched](#a-desks-model)) and `pid`, keyed by the terminal's address. The `bercail-desk` Pi extension records the session Pi has open, even while idle. A watcher touches the file every minute while the desk lives. Headless runs get no record.
- **What comes back.** A record fresh within ten minutes of shutdown (the last journal line of the previous boot), on a desk at a bare shell, in a folder that still exists, whose session is not already open. Records written since shutdown also qualify for a manual restore after a core stop/start. A desk you quit has finished, so it stays quit. Older records stay shells.
- **Duplicate checks.** Restore checks process arguments, all live Herdr terminals' status records, and the Pi extension's runtime claims in `$XDG_RUNTIME_DIR/bercail/open-sessions/`. Claims include idle sessions, and count only while their original process is alive. A Pi started before the extension was installed may have no claim: check those manually before restoring.
- **When.** Once per boot, through Omarchy's post-boot hook or else a systemd user unit: it waits until you open Herdr, then a notification says how many came back. Omarchy logs to `~/.local/state/bercail/desk-restore.log`; systemd logs to `journalctl --user -u bercail-desk-restore`. After a core restart, or to run it yourself, use `bercail desk restore`; `--dry-run` lists each desk and why.
- **What does not.** A Pi with no session saved (`--no-session`) has nothing to resume. The lead's `hc` siblings (builder, judge, council) are not desks and stay shells. No boot hook runs on macOS or without Omarchy/systemd; manual restore is still available. For these, and for desks from before records existed, the `desk-restore` skill finds the session by folder and content. Install/update wires the hooks for future sessions, not agents already running.

## A desk's model

`bercail desk model DESK PROVIDER/MODEL[:thinking]` switches a live Pi desk to another model, for example `bercail desk model t1c3 claude-bridge/claude-fable-5-2:high`. DESK is the terminal's address or name.

- **The channel.** The command writes a request to `~/.local/state/bercail/desk-commands/<address>.json` (0600) for the Pi process the desk's record names, and the `bercail-desk` Pi extension takes it. It is not a message: `hc send DESK "/model ..."` reaches the desk as chat from another agent, which it ignores, and no chat text switches the model.
- **When.** Only when the desk is idle: a run in flight finishes on the model it started with. An idle desk switches within a second or two and the command prints `switched to <model> (was <model>)`. A busy one prints that it switches when its current run ends.
- **Checks.** The terminal must be a live desk (`bercail.role=agent`) whose record names a running Pi. Before anything is written, `pi --offline --list-models` with the lead's extensions must list the model; the desk checks again against its own models and logins. A refusal while the command waits fails it with the reason; a later one shows in the desk and in the answer file below.
- **Thinking.** A `:thinking` suffix sets the level. Without one the desk keeps its own level, clamped to what the model supports.
- **What it updates.** Pi's footer and session (a `model_change` entry, then a `bercail-desk-model` entry naming both models), the `--model` in the desk's record so [a restore](#desks-after-a-reboot) brings it back on the new model, and the `bercail.model` label that `bercail shep brief` and `board` show. The desk's answer is in `desk-commands/<address>.done.json`. A desk started before `bercail update` brought this extension never answers: restart it, then switch again.