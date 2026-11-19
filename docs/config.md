# config

`~/.config/bercail/config.toml`:

```toml
[layout]
review = "tuicr"                     # or a command of yours
auto_review = true

[bstack]
claude = ""
gpt = ""
effort = "high"
lead = "claude"
build = "claude"
judge = "gpt"                        # GPT reviews; Claude stands in while it is limited
statechart = false                   # true: the statechart skill, with TLC and Java

[git]                                # optional, one line per main checkout
"~/Work/some-repo" = "gh"              # gh | gt | origin | entire

[policy."~/Work/some-repo"]          # optional: your override of that repo's git policy
commit = "allow"

[shep]                               # optional: Shep's compaction and dispatch
compact_at = 250000                  # context tokens at which Pi compacts Shep
keep_recent = 50000                  # recent tokens kept word for word
rollover = false                     # true: a fresh session instead, and each new day
spawn_timeout = 600                  # seconds task dispatch gives handoff-spawn to start a desk

[herdr]                              # optional: bercail on another Herdr machine
backend = ""                         # its name in `hc machine ls`; empty: this computer
```

After you edit it, `bercail reconfigure` re-reads it, refreshes the skills and bstack, and installs Pi and the review tool if they are missing, and TLC and Java when `statechart` is on. The desk always runs bstack's Pi lead. What the `[bstack]` keys do (pins, `effort`, roles) is in [Make it yours](bstack/08-make-it-yours.md#models-and-roles), and `statechart` in [statecharts](bstack.md#statecharts); `review` and `auto_review` in [review](review.md); `[git]` in [handoff](handoff.md#git-backend); `[policy."<path>"]` in [git policy per repo](#git-policy-per-repo); `[shep]` in [Shep's compaction](shep.md#compaction), read at Shep's next start, except `spawn_timeout`, read by each [task dispatch](shep.md#dispatch); the old `[todo]` in [todos](#todos); `[herdr]` in [bercail on another machine](#bercail-on-another-machine), read by the layout's mods when the window opens.

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
- **What the guard does with it.** On a desk, Shep, a sibling, or a headless run, the guard lets a commit or push through without a prompt when the trusted policy allows it, and asks (or, headless, blocks) otherwise. A push under `push = "branch"` goes through unless it may reach `main` or `master`: a push there, `--all`, a glob refspec, or a bare push after a `checkout`, `switch`, or `rebase` in the same command. A tag (`git tag v1.2.0`, a pushed `v1.2.0` or `refs/tags/…`, `--tags`, `--follow-tags`), `gh release create`, or a `gh api` write to releases or tag refs goes through only with `agent_may_release = true`; otherwise it asks on a desk, where you can say yes, and blocks autopilot and headless runs. `gt create` and `gt modify` follow commit policy. `gt submit`, `gh stack submit`, `gh pr create`, `origin stack push`, and `origin pr create` follow push policy, using the current branch for the branch check. The guard does not inspect which other branches a stack publisher sends. Autopilot keeps its own rules: it commits and pushes its PR branch, never main. Judge, council and Discuss stay read-only: they edit no file and change no git state, and their write tool reaches only `/tmp`, `$TMPDIR`, and new files under the worktree's `.bercail/`. `description.md`, `validate.json`, `handoff-result.json` and `policy.toml` are not among them, even when absent and even in a worktree under `/tmp`: bercail trusts the first three as the desk's own, and a policy's rules apply without trust.
- **CLI help.** A direct, unquoted `git <builtin> --help`, with no other arguments, is a read for `add`, `commit`, `push`, `restore`, `clean`, `rm`, `mv`, `merge`, `rebase`, `reset`, `checkout`, `switch`, `branch`, `tag`, `config`, `init` and `worktree`. The same applies to `gt create --help`, `gt modify --help`, `gt submit --help` and `gt merge --help` only when the guard can read Graphite's alias configuration and the command name is not overridden. A missing alias file uses Graphite's defaults. Unknown alias state, a relative or empty `XDG_CONFIG_HOME`, or an earlier command that could change the configuration keeps the existing write checks. Unquoted static directory changes, bare `git status`/`diff`/`log`/`show`, and other recognized help retain that knowledge. These are narrow forms, not a general `--help` or `-h` exemption: wrappers, selectors, extra arguments (including empty ones), substitutions, flag values and text after `--` do not qualify. A backslash anywhere in the bash body disables the new help exemption for that body. Pipelines, background execution, ampersand redirections and unquoted heredocs with substitutions also leave Graphite's alias state unknown. Shell-script bodies are still checked recursively, but gain no new help exemption. Other commands in a bundle still receive their normal checks, and help does not bypass file or secret protections. `gh`, `origin` and `entire` help handling is unchanged.
- **Checks no policy loosens.** In recognized commands, the guard blocks force-push flags (including `gt submit --force` and `gh repo sync --force`), git `+` refspecs, `--mirror`, deleting `main` or `master` (`--delete` or `:main`), `--no-verify`, and PR merges (`gh pr merge`, `gt merge`, `gh api` writes to `/pulls/N/merge`). It also blocks setting the git config that changes what a later push or commit does (`core.hooksPath`, `remote.*.push`, `remote.*.mirror`, `push.*`, `alias.*`, `include.*`, through `git config`, `git -c`, or `GIT_CONFIG_*`), `bercail policy trust`, and writes to the protected files below. For every role, it blocks a command that could run on an empty 1Password secret: `op read`, `op inject`, or `op item get --fields` (or `--otp`, `--reveal`) piped into another command (alone, in a `{ }` group, or from `sh -c`) or read through `<( )`, a `$(op read …)` used directly as an argument or with `2>&1` (its error text would pass as the secret), and a variable filled by one that is used, or exported, before the same command stops on an empty value. The checks it recognizes are `${pw:?}` outside a pipe or `&`, `[ -n "$pw" ] || exit` (also after `&&`), and, not after `&&`, `[ -z "$pw" ] && exit` and `if [ -z "$pw" ]; then …; exit; fi`. `[[ ]]` and `test` work too, and the exit may sit in a `{ …; }` body. `[` and `test` need the variable quoted, and `return` does not count, since at a script's top level it does not stop the shell. A use later in a `[ -n "$pw" ] && …` chain is allowed, and op's own `--help` (before any `--`) prints no secret, so it is not checked. pipefail does not help a value that comes back empty, so a pipe is blocked even with it. This is a seatbelt, not a sandbox: it checks the command text passed to Pi's bash tool, not everything an agent running as you can do. Trust only repos whose agents you would let commit anyway.
- **Protected files.** The guard blocks writes to `config.toml`, the trust file, `todo.json`, and Shep's state folder (`~/.local/state/bercail/shep`, its question ledger included), through the edit tools or a shell write, symlinks followed. A shell write is a redirect's target (`>`, `>>`, `2>`, `&>`), what `tee`, `rm`, `mv`, `unlink`, `shred`, `touch`, `truncate` or `chmod` names, the destination of `cp`, `ln` or `install` (each dir of `install -d`), `dd`'s `of=`, and the files of `sed -i` or `perl -i`. Reading one of these files is not a write (`cat`, `jq`, `sed -n`, the source of a `cp`), and neither is `2>&1` or `2>/dev/null`. A relative path is checked from each folder the shell may be in: after `A && cd X;`, both X and the folder before. When the guard cannot place a path (a `$VAR` it does not know, or a relative path after a `cd` it could not follow, such as `cd $(pwd)`), it goes by the name: a write to a file named `config.toml`, `policy-trust.json`, `todo.json`, `questions.json` or `questions.lock`, or to a path holding the last two parts of one (`bercail/config.toml`), is blocked, and any other write goes through. Writes the guard does not parse go through too: `sed`'s `w` command, code in `perl -e`, `rsync`.
- **Scratch repos.** The guard lets a commit through without asking in two kinds of throwaway repo. Pushes and tags from either still follow the default policy.
  - A repo the same command made with `git init` inside a `mktemp -d` dir, remote or not: `cd "$(mktemp -d)" && git init -q r && cd r && git remote add origin https://x/y.git && git commit -m i`, `d=$(mktemp -d); git init -q $d/r; cd $d/r; git commit -m i`, or `W=$(mktemp -d); ( R=$W/repo; git init -q $R && git -C $R commit -m i )`. The commit must run in that exact repo, and everything before it must run in a straight line of `&&`, `;` and newlines. Inside a `( )` subshell that line goes on, and it ends at the `)`. An `if`, a loop, a function, a `{ }` group, `||`, a pipe, or `&` ends the rule for the rest of the command, and so do `ln`, `cp -s` and `git worktree`, since a symlink or a worktree can lead out of the dir. A variable must be set once, on its own or after `export`: `read`, `for` or `printf -v` with its name counts as setting it again. A path that leaves the dir with `..` is not in it. A variable, `git init` or `cd` after `&&` counts only until that chain ends, and a `$` in single quotes or after a backslash is never read as the dir. `GIT_CONFIG_GLOBAL` and the other `GIT_CONFIG*` variables don't stop the rule, but `GIT_DIR` and the other variables that point git elsewhere do. Bash calls don't share state, so a dir made in an earlier call counts only under the next rule.
  - A repo under a temp dir (`$TMPDIR`, `/tmp`, `/var/tmp`) with no remote and no entry in `config.toml`. A temp copy of a repo with a policy counts too, unless that policy says `commit = "ask"`.
- **Which repo.** The guard checks the repo each git command runs in: `git -C <dir>` and a `cd <dir> &&` before it count. When it cannot tell (a `cd "$VAR"` other than a `mktemp -d` dir above, a `cd $(…)`, a `cd` in a pipe or in the background, a `cd` after `&&` once that chain ends, anything after a `( )` subshell, `--git-dir`, or a `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` set or exported anywhere in the command), it uses the default. Explicit forge repo or host selectors (`-R`, `--repo`, `--hostname`) and directory selectors (`-C`, `--cwd`, `--directory`) also use the default, not the current folder's trust.
- **Known gaps.** Pushing a tag that already exists under a name that does not look like a version (`git push origin stable`) counts as a branch push. `gh workflow run` is not treated as a release. Commands launched inside another program (`python -c`, a script file) are not seen. A command word the shell computes (`$(command -v git) push --force`, `bercail $P trust`) is not recognized at all. Shell keywords and common wrappers (`if`, `then`, `else`, `while`, `until`, `do`, `{`, `!`, `time`, `exec`, `nohup`, `setsid`, `nice`, `timeout`, `xargs`) do not hide a literal command, but this is not a complete shell parser. `eval`, `source`, a git alias, or a branch switch earlier in the same command make the guard treat the repo and branch as unknown, so it asks. An `eval`'s words are joined and checked like a `bash -c` script.
- **The log.** Every command the guard lets through on a policy, the scratch rule, or autopilot's role is appended to `~/.local/state/bercail/guard-approvals.jsonl` with the time, terminal, role, folder, command (URL credentials masked), and why: `jq . ~/.local/state/bercail/guard-approvals.jsonl`.
- **What agents read.** Every Pi agent that loads the guard gets the effective policy of its folder, rules included, as a `bercail_git_policy` section of its system prompt, refreshed at the start of each run. Text from a file you have not trusted is labeled as the repo's, not yours. The handoff comment names the policy in one line. Agents still stage and leave work uncommitted for review; the policy says how to commit, push, or release once someone asks.

### Prepare a policy and verification starter

`policy init` is a fixed file generator, not an installer or trust command. All
three choices are required; without `--write` it only previews:

```sh
bercail policy init --repo /path/to/checkout --profile guarded --backend gh
bercail policy init --repo /path/to/checkout --profile branch-pr --backend gh --verify my-repo --write
bercail policy init --repo /path/to/entire-checkout --profile guarded --backend entire
bercail policy init --repo /path/to/entire-checkout --profile branch-trail --backend entire --verify my-repo --write
```

It shows the exact target paths, proposed new-file diffs and SHA-256 hashes. Its
only destinations are `.bercail/policy.toml` and, with `--verify NAME`,
`.agents/skills/verify-NAME/SKILL.md`, under the **selected checkout's root**.
A subdirectory resolves to that root. In a linked worktree it writes there,
not in the main checkout or another desk. Names use lowercase letters, digits
and single hyphens, without leading/trailing hyphens; `verify-NAME` must fit
within 64 characters.

| Profile | Proposed repo-file settings |
| --- | --- |
| `guarded` (either backend) | `commit = "ask"`, `push = "ask"`, `review = "always"`, `agent_may_release = false` |
| `branch-pr` (`gh` only) | `commit = "allow"`, `push = "branch"`, `integrate = "pr"`, `pr_draft = true`, `review = "always"`, `agent_may_release = false` |
| `branch-trail` (`entire` only) | `commit = "allow"`, `push = "branch"`, `review = "always"`, `agent_may_release = false`; no `integrate` or `pr_draft` keys |

GitHub profiles retain their rule to use `gh`. Both Entire profiles prescribe
integration through a **project-level Trail**, which may contain multiple branches
and repositories. Reuse the appropriate Trail; ask the person when that is unclear.
Create one only when asked. Use each change's true parent/base branch, not an
assumed main branch (`entire trail create --base`, `entire trail retarget --base`).
Keep the description current with `entire trail update` and reference full Trail
and change URLs. Stage and leave work uncommitted until asked to commit or publish.
Do not publish directly to main or master. Desks must not approve or merge Trails.
Only the human, or Shep explicitly asked to merge, may merge after git permission,
actual validation evidence and required human review pass independently. There is
no GitHub PR or gh-stack workflow for Entire.

**The Trail workflow is rules text, not a new policy enum or runtime enforcement.**
The existing schema has only `pr` and `direct` integration values; Entire scaffolds
omit `integrate` and `pr_draft` rather than inventing an enum. General scaffolds use
`review = "always"`; they do not replace a repo's separately reviewed by-stakes policy.

**`--backend gh|entire` declares scaffold intent, not runtime backend configuration.**
No backend key is added to the policy and no global `[git]` entry changes. The
existing override keyed by the canonical main checkout takes precedence when it
matches the requested backend, even if offline evidence differs. A supported but
mismatched override refuses. Multiple matching entries refuse, including duplicate
keys or canonical aliases, rather than silently choosing one. Unknown or malformed
matching `[git]` values also refuse rather than falling back; parser errors in `[git]` or unreadable table
headers conservatively refuse because they cannot be safely matched.

Without an override, offline Origin hosting or a Graphite config refuses for
either backend. `entire` additionally requires an origin URL shaped like
`entire://HOST/et/PROJECT/REPO`. A GitHub host, an Entire GitHub mirror
(`entire://HOST/gh/OWNER/REPO`), capture settings alone or no hosting evidence is
not enough for Entire setup. `gh` retains its no-evidence fallback, including
GitHub mirrors, but refuses Entire `et/` hosting. Init never runs backend tools,
network/ownership probes or initialization. A stale Graphite config can therefore
refuse even when Graphite tracks nothing: use manual setup, or have the owner
review their existing backend choice separately. Init never creates an override.

Before writing anything, init checks **all** requested destinations. Existing
byte-identical files are left untouched, including metadata. Any different file
conflicts, even a policy with malformed or unknown schema; there is no merge,
normalization, `--force`, custom output path or overwrite. Symlink components
(including dangling links), hardlinked targets, non-regular files and
non-directory parents refuse. Repo inputs through symlinks or containing control
characters also refuse. Unset `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR` and
`GIT_INDEX_FILE` before using init so they cannot redirect the explicit repo.

Writes use no-clobber creation. Preexisting conflicts leave every destination
unchanged, but this is **not a multi-file transaction**: an I/O failure or
concurrent creator can leave partial output. Inspect it and retry; identical
files are skipped. The path checks do not protect against a hostile same-user
process replacing parent directories during the write.

The starter is deliberately **INCOMPLETE**. Its normal skill frontmatter and
repo-local location let Pi auto-discover it once the owner permits Pi project
resources; `/validate` can locate it too. **Pi project-resource trust is separate
from bercail policy trust; init grants neither.** Its first instruction
stops validation until reviewed repo-specific commands and acceptance criteria
replace the placeholders. No executable script, test result or validation
description is generated, and init runs no checks.

After preparation, keep the three gates separate:

1. Review and deliberately adopt only the generated policy and optional skill.
   Init does not stage them or change ignore rules; an ignored target still needs
   deliberate adoption. A file on this branch is not installed or adopted on
   every desk.
2. Inspect effective permissions with `bercail policy show --json /path/to/checkout`.
   Init **never creates or changes trust**. Existing matching main-checkout trust
   and local overrides may already apply, so proposed settings are not a promise
   of effective permissions. Only the owner, after reviewing the target bytes,
   may separately run `bercail policy trust /path/to/checkout` in their own shell.
3. Complete and review the verification skill, run real repo checks and keep
   their output. Then obtain the required human review. Permission to publish
   is neither validation evidence nor approval.

There are no self-trust flags, grants, credential/model calls, global skill
writes, installs, deployment, commits, pushes, releases or approvals in init.

## Todos

`bercail todo` puts what only you can do on a to-do list of yours ([how Shep uses it](shep.md#todos-for-the-person)). You can have several, one per project or repo. Each is a **target**: a name for one list. A **route** sends a repo's todos to a target, and the **default** target takes the rest. Shep sets them from the CLI when you name a list, so you never paste numbers into a file:

```sh
bercail todo target add lesentiel https://app.basecamp.com/6317829/buckets/49568764/todolists/10511639538
# added lesentiel: basecamp, to-do list "Lesentiel" in Show the vision · https://3.basecamp.com/…
bercail todo route ~/Work/lesentiel lesentiel   # todos for jobs in that repo go there
bercail todo route --default home               # and the rest to home
bercail todo target list                        # every target, the default, and each one's routes
```

- **Adding a target** reads the list first, so a typo or a list your login cannot see fails before anything is kept. Paste the list's URL from either Basecamp host (`3.basecamp.com` or `app.basecamp.com`). A project's To-dos URL (`…/buckets/<project>/todosets/<id>`, or `…/projects/<project>`) is not one list: the error lists that project's lists with their URLs, and `--create "<list name>"` makes a new one there instead. Adding a name again points it at the new list and keeps its routes. `target rm` drops its routes, and the default if it was. `route --rm <repo>` sends a repo back to the default.
- **Which target a todo goes to.** `bercail todo add --target <name>`, else the route of the job's repo (`--repo`, or the checkout of `--issue`), else the default. With none, it fails and says which of those to run. A route names the repo's main checkout, so its worktrees route with it. `show` and `done` find the target bercail added a todo to; `--target` names another.
- **Where they live.** `~/.config/bercail/todo.json`, written only by `bercail todo target` and `route`. It is not in `config.toml` because Shep sets targets and the guard keeps Shep out of `config.toml`, rightly: that file decides what the guard lets through. A target does not. It decides which of your lists Shep writes to, with the Basecamp login you gave it, which can already write to every list it sees. So Shep may run `target` and `route`; every other role is blocked from them, Discuss runs no commands, and no role, Shep's included, may write `todo.json` by hand, which would skip the read that checks the list.
- **Backends.** The backend comes from the URL, or `--backend`. Basecamp is the only one for now. A backend is one file, `lib/todo/<name>.sh`, that defines `todo_<name>_owns` (is this URL mine), `_target` (read the list a URL names, or make one), `_check`, `_add`, `_list`, `_show` and `_complete`, and reads its target's fields from `TODO_TARGET_JSON`. Adding one changes no caller.
- **Before targets.** A `[todo]` table in `config.toml` still works: it is the target `config`, and the default when `todo.json` names none. `bercail doctor` prints a hint to move it: `target add` its list's URL under a name, `route --default` that name, then delete `[todo]` and `[todo.basecamp]`. Todos bercail added before targets count as `config`'s.

  ```toml
  [todo]
  backend = "basecamp"
  [todo.basecamp]          # https://3.basecamp.com/<account>/buckets/<project>/todolists/<todolist>
  account = "1234567"
  project = "2345678"
  todolist = "3456789"
  ```

For Basecamp, bercail runs the `basecamp` CLI (0.30.0; on Omarchy it comes with the system's mise tools). Todos land on the list unassigned, so read the list, not My Assignments. Log in once, as yourself, in your own shell:

```sh
basecamp auth login --device-code   # prints a link and a one-time code; approve it in any browser
bercail doctor                      # ok  todos lesentiel: basecamp, logged in; to-do list "Lesentiel" in Show the vision
```

`bercail doctor` prints one line per target: `ok` when its list answers, `--` when you are logged out, `unreachable` with Basecamp's error when the list does not answer. It never prints the token.

- **From your laptop, over a remote Herdr shell.** That works. The shell runs on the machine bercail runs on, so the login is stored there, where Shep and the desks use it. `--device-code` never opens a browser on that machine; open the printed link on your laptop or phone. Without the flag, the CLI may open a browser on the machine's own screen when the shell has a display.
- **Where the login goes.** The basecamp CLI keeps it in the system keyring when one answers, else in `credentials.json` (mode 0600) in its config folder. bercail never reads, prints or passes it. `bercail doctor` asks `basecamp auth status`, which reads only what is stored, then reads each target's list, and prints `logged in` or `not logged in`, never the token.
- **Who may use it.** Shep adds and completes todos, and sets targets and routes. Desks, builders, the judge, the council, autopilot and background Sheps may only read; Discuss runs no commands. In every role, Shep's included, the guard blocks basecamp's login, logout and token commands; it does not stop a command that reads the keyring or `credentials.json`. [What the guard counts as a read](shep.md#todos-for-the-person).

## Review by stakes and size

A swarm of desks can stage more in a day than you can review. Four policy keys say which changes wait for you and how much you take on at once.

- **Stakes.** `high_stakes` lists git glob pathspecs (`lib/policy.sh`, `workers/`, `site/worker*`; `*` stays inside a folder, `**` crosses folders, a folder name covers what is under it). A change that stages a matching path is high-stakes, and so is any edit to `.bercail/policy.toml` itself, staged or not, so a desk cannot lower its own change's stakes by editing the list on its branch. With `review = "by-stakes"` (the default) a high-stakes change waits for your LGTM before Shep commits or merges it, even in a repo that integrates straight to main; the rest keep their usual flow. `"always"` makes every change wait; `"none"` makes none wait, and needs trust. With no `high_stakes`, nothing is high-stakes. `/validate` records `stakes:` and `review:` in `.bercail/description.md`, `bercail describe check` prints them (measured from the commit the stamp saw, so a committed change keeps them), and in a repo that commits straight to main `bercail describe commit` refuses a change that waits for you until it gets `--reviewed-by`.
- **Size.** `diff_budget` is how many lines one change may add and remove before `bercail describe check` warns (400 by default, past what a reviewer reads well in one sitting). Lockfiles (by name: `package-lock.json`, `yarn.lock`, `Cargo.lock`, `go.sum`, …), binaries, and files `.gitattributes` marks `linguist-generated` are left out. It is a warning, never a failure: the desk splits the change, or its description says why it is one.
- **Queue.** `review_budget` is how many lines may wait on your review in the repo before Shep warns at a new desk there (1000 by default, about two hours of review). What waits: staged changes in worktrees whose desk is not working (done, idle, blocked, or gone), and, on GitHub, open PRs that ask you for a review or come from a handoff branch, not drafts and not approved. A worktree whose issue is [superseded](shep.md#briefs-and-the-board), or that no open Herdr space has (stale), is listed but does not count. `bercail shep queue [--repo DIR]` lists them; `bercail shep board` ends with the same list. Shep tells you what waits and asks; it never refuses.

## bercail on another machine

A Herdr window on one computer (a laptop) can use bercail on another, added there with `hc machine add`. Shep, the desks, repos, logins, beads and bercail's state stay on that machine. In the laptop's `config.toml`, `[herdr] backend` names it as `hc machine ls` does. Empty, or no `[herdr]`, means this computer: bercail on its own machine works as before. `bercail install --client <machine>` sets it, and installs nothing else bercail runs; [install](install.md#a-laptop-with-bercail-on-another-machine) walks through the laptop's setup.

With a backend, the layout's mods:

- find Shep there and start it there, in that machine's home, and keep the notifier (`bercail-notify`) running there, whichever window is open;
- read the review queue (`bercail shep queue`) there, and match its items to that machine's spaces;
- read the [Decisions panel](shep.md#the-decisions-panel)'s questions (`bercail shep question panel`) there every 30 seconds instead of watching the ledger, record its answers (`bercail shep question answer`) there, and run its Discuss branch (`bercail shep discuss`, in an hc terminal) and the close's event there;
- run the Stack tab's `bercail review-pr` and its jobs there, and read its run dir every 5 seconds instead of watching it.

With or without one, a space's desk (`Ctrl+Shift+A`, Start the agent) starts on the space's machine, under its Shell, and git and gh for a space run there too.

A desk's labels are written on its own machine and name that machine's ids: `bercail.space=sp1` on `box` is the space `box/sp1` in the laptop's window. The mods add and remove only that machine's prefix, and never run on the laptop a path that came from the other machine.

Not yet: the worktrunk hook and `handoff-spawn --branch` open a new space only in a window on bercail's machine; a desk does not start on its own in a space on another machine; and `bercail review-pr` needs a window on bercail's machine.

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

A client install (`--client`) writes only the layout, mods and keys above, `~/.local/bin/bercail` with `~/.local/share/bercail/lib/`, `[herdr] backend` in `config.toml`, and `~/.local/share/bercail/install-mode`, which keeps later updates client-only.

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