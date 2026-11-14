# Entire

[Entire](https://docs.entire.com) records the agent sessions behind each commit
(a checkpoint) and hosts repos whose changes are trails instead of PRs. In
bercail it is two things:

- **Capture**, on any backend: Entire's git hooks plus its Pi extension. A
  repo where it is on reports `"entire": true` in `handoff-spawn --info`.
- **A git backend**, `entire`, only for a repo hosted on Entire
  (`origin` is `entire://<host>/et/<project>/<repo>`). A GitHub repo mirrored on
  Entire (`entire://<host>/gh/...`) stays `gh`: its PRs, CI and merges are
  GitHub's.

## Turn it on in a repo

These are your commands; agents suggest them and the guard stops them running
them.

```sh
entire enable --agent pi        # git hooks in the shared git dir, .entire/, .pi/extensions/entire/
entire configure --checkpoint-remote github:<owner>/<repo>-checkpoints   # a public repo: keep transcripts private
```

Then set these in `.entire/settings.json` and commit it with `.entire/.gitignore`
and `.pi/extensions/entire/index.ts`, so every worktree has them:

```json
{ "commit_linking": "always", "telemetry": false, "redaction": { "pii": { "enabled": true } } }
```

`.entire/settings.local.json` is per worktree: a new desk worktree never sees
it, so anything desks need goes in `settings.json`.

Pi loads the extension only in a folder it trusts (`/trust`, or
`~/.pi/agent/trust.json`). Then run `bercail doctor` from the checkout. Its
Entire section checks:

- the CLI, the hooks, and that the extension is committed,
- Pi's trust,
- these settings, and your login,
- whether checkpoints go somewhere public. They are full transcripts, so a
  public destination is a warning and a private checkpoint repo is ok.

The section never fails doctor: someone who clones the repo may not use Entire.
It reads visibility from GitHub only. For a repo hosted on Entire, it says
unknown.

## What is captured

| Who | Captured |
|-----|----------|
| A desk's lead | yes |
| Builder, judge, council siblings | each as its own session. Pi has no subagent tree in Entire. A read-only session changes no files, so it never lands in a checkpoint. |
| Headless stages and autopilot | yes, even when a desk starts them: `handoff-spawn` drops the desk's `ENTIRE_PI_NESTED`, which would make Entire record nothing |
| Background Shep | yes, in a checkout where Entire is on |
| Shep | no: its workspace is not a repo |
| review-pr's reviewer | never loads a project's `.pi/` (`--no-approve`) |
| A desk, sibling or Shep in a review worktree (`<repo>.review-<n>`) | bercail's guard answers Pi's trust question no, so a PR head's extensions never load. A plain `pi` you start there follows your own trust settings. |

A commit links the sessions that changed files in its worktree. Shep's commits
link without a prompt, because Pi marks its commands as an agent's. A person's
commit asks first, unless `commit_linking` is `always`.

## Squash merges and amends

A squash or a reworded amend drops each commit's `Entire-Checkpoint` trailer,
and with it the link to the sessions. `bercail describe body|commit
--checkpoints <base>` carries the trailers of `<base>..HEAD` into the text. The
describe skill's commands always pass it.

## Repos hosted on Entire (`git = entire`)

The trail is the PR.

| Step | Command |
|------|---------|
| Open | `bercail describe commit \| git commit -F -`, then `entire trail create --title "$(bercail describe title)" --body "$(bercail describe body)"`, which publishes the branch |
| Update | commit, `git push`, then `entire trail update --body "$(bercail describe body)"` |
| Ready for review | `entire trail ready` |
| Merge | you, or Shep when you ask: `entire trail merge`, once the trail's gates pass |

Supported so far:

- **Stacks:** Entire has none. A dependent's trail names its parent
  (`entire trail create --base <parent>`), and `entire trail retarget` moves it
  once the parent lands. `handoff-spawn --base` tells the desk so.
- **CI:** the trail's gates decide the merge, and `entire trail show` reads
  them. Autopilot does not watch a trail yet.
- **review-pr:** it reviews GitHub and Origin PRs. It refuses a branch in an
  Entire repo.
- **Trails next to GitHub PRs** for a mirrored repo: not built yet. It will be
  opt-in per repo.

## Brain

[Brain](https://docs.entire.com/guides/brain/overview.md) is an Entire plugin:
a local memory of the repo built from checkpointed sessions, docs, git history,
and Graph's code index. There is one store per repository, keyed by its origin,
so every worktree and desk shares it. Pi uses it through the CLI alone; setup's
hooks are Claude Code's. These are your commands, in a clean main checkout:

```sh
entire plugin install brain --yes       # installs entire-graph too
ENTIRE_BRAIN_NO_EGRESS=1 entire brain setup --no-backfill --no-daemon --no-agent-hooks
entire graph setup --repo . --no-claude-hook
echo '.entire/agent-guide.md linguist-generated=true' >> .gitattributes
git add AGENTS.md CLAUDE.md .entire/agent-guide.md .gitattributes && git commit
```

Setup writes a managed block into `AGENTS.md`, a `CLAUDE.md`, and
`.entire/agent-guide.md`. Commit them on main, on their own: they are
working-tree files, so a worktree sees them only once its branch has the commit.
Setup does not need a clean tree, and in a desk's worktree its files would land
in the review diff. `linguist-generated` keeps the guide's regenerations out of
the diff budget.

`--no-backfill` and `--no-daemon` keep it from spending tokens.
Backfill and the watcher send transcript chunks to the `claude` or `codex` CLI
on your login, and the watcher ignores `ENTIRE_BRAIN_NO_EGRESS` in your shell.
`entire brain connect` uploads the repo's memories to Entire. Do not connect a
public repo whose checkpoints go to a private one, such as bercail.

Pi loads `AGENTS.md` but not the guide it imports, so bstack's instructions
tell each desk to run `entire brain brief` at the start of a job and `recall`
before it changes a rule. A desk proposes a memory in its report, and Shep
records it with `entire brain remember` once you agree.

When the plugin is installed, `bercail doctor`'s Entire section also checks
Brain's and Graph's versions, that the guide and the `AGENTS.md` block are
committed, that no watcher is installed, and that a public repo's memories are
not synced to Entire.

## The guard

On top of the repo's policy, for every role:

- **Read:** status, why, search, `checkpoint list|explain` (not
  `--generate`), `trail show|list`, the findings list, and `agent-help`.
  Anyone may run these.
- **No help or dry-run shortcut:** `--help` and `--dry-run` are not reads. A
  flag takes the next word as its value, so `trail approve 3 -m --help`
  approves. Use `entire agent-help` and `entire trail show`.
- **Publish:** `trail create`, `trail link`, `trail ci-pr`, `trail update-branch`
  and `checkpoint push` count as pushes. The policy's `push` decides.
- **Trail writes:** `trail update`, `trail ready`, `trail comment`, and finding
  replies or resolves are allowed, except for read-only roles.
- **Dismissing a finding:** only you, through the CLI or `entire api`. A desk
  asks, and Shep, autopilot and headless runs are blocked.
- **Merging a trail:** you, or Shep when you ask. Shep's
  `entire trail merge [<trail>]` asks you first and the trail's gates decide
  the rest. It asks rather than following the repo's policy, because a project
  trail can merge a change in another repo. Shep's merge is blocked with
  `--force`, which skips the gates, or with a flag before `merge` that bercail
  does not know. Every other role is blocked: the lead, its siblings,
  autopilot, headless runs, and background Shep.
- **Blocked:** `trail approve`, `entire api` calls whose path or fields name a
  merge or an approval, setup (`enable`, `configure`, `agent`, `login`,
  `repo …`), and commands that amend, reset or delete
  (`session attach --force`, `checkpoint delete`).
- **A flag bercail does not know** may take the next word as its value, the way
  cobra reads it, so `entire --json 3 trail merge` merges trail 3.
  The guard decides both readings and takes the stricter.
- **Brain and Graph**, as `entire brain|graph` or as `entire-brain|entire-graph`:
  - Reads (`brief`, `recall`, `query`, `status`, `inspect`, Graph's queries,
    `entire plugin list|info`) are open to anyone.
  - A local refresh (`refresh`, `graph index`, `repair`) is allowed, except for
    read-only roles.
  - `remember` with `--path` and `memories retract` are Shep's alone.
  - Model calls (`distill`, `recall --expand`, `remember` without `--path`,
    `refresh … --agent`) are blocked, and so are setup, `connect`, sync, the
    watcher, `plugin install|upgrade`, and any flag that names a binary to run.
  - A flag before a subcommand, or a subcommand bercail does not know, asks a
    desk and is blocked elsewhere.
  - `graph verify --test|--setup` commands are checked like `bash -c`, in its
    `--repo`.
- **Other entire commands:** a desk asks, and a headless run is blocked.
- **`git push --all`** (or `--branches`, or a glob refspec) is blocked in an
  Entire repo. It would also push Entire's shadow branches, which hold
  unredacted snapshots.

The pre-push hook sends checkpoints with any push the guard allows, so where
they go is a setting, not a guard decision: see `bercail doctor`.
