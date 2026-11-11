# Project git backend (handoff)

Read `git` from `scripts/handoff-spawn --info`: `gh`, `gt`, or `origin`.
Use that backend throughout the job; do not probe with `gt`, because any `gt`
command auto-initializes a plain repo. `graphite` remains for one release as
`git == "gt"`; new callers use `git`. Detection and per-repo overrides:
[handoff.md](handoff.md#git-backend).

Handoff never auto-commits. Agents stage their work (`git add`) and leave it
uncommitted: the staged diff is what the human reviews in tuicr (`tuicr -w`,
uncommitted changes only). When the user later asks to commit/submit:

| `git` | Stacked branches and publishing |
|-------|--------------------------------|
| `gh` | `gh stack init <parent> <child>` adopts existing branches; `gh stack add <child>` extends a stack from its tip. Publish with `gh stack submit`, update with `gh stack sync`. |
| `gt` | `gt create` for a new branch, `gt track --parent <parent>` for an existing branch, `gt submit`, and `gt get` for remote stack updates. |
| `origin` | `origin stack track <child> --onto <parent>` before publication. Open the child with `origin pr create --stack-on <parent-PR> --status open`; update with `origin stack get`, `origin stack restack`, and `origin stack push --all`. |

`--base <parent>` dependents are stacks, not hand-made PRs that merely target
another PR's branch. Keep the parent relation in the selected backend. Never
run `gt` in a `gh` or `origin` repo. For an independent `gh` branch, plain
`git` and `gh pr` remain appropriate.

Do not commit/submit unless the user asked. When asked, follow the repo's git
policy (`bercail policy show`): a PR or straight to main, drafts, how a release
is cut. Autopilot may commit and push to its PR branch, but never merges. Stop
if updating a stack would rewrite a branch you do not own or require a
force-push.
