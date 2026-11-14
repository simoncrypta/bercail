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
| Merge | you: `entire trail merge`, once the trail's gates pass |

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
- **Dismissing a finding:** only you. A desk asks, and autopilot and headless
  runs are blocked.
- **Blocked:** `trail approve` and `trail merge`, setup (`enable`, `configure`,
  `agent`, `login`, `repo …`), and commands that amend, reset or delete
  (`session attach --force`, `checkpoint delete`).
- **Other entire commands:** a desk asks, and a headless run is blocked.
- **`git push --all`** (or `--branches`, or a glob refspec) is blocked in an
  Entire repo. It would also push Entire's shadow branches, which hold
  unredacted snapshots.

The pre-push hook sends checkpoints with any push the guard allows, so where
they go is a setting, not a guard decision: see `bercail doctor`.
