# Bercail investigations

Last checked on 2026-11-17 against Bercail commit
[`b93c99f`](https://github.com/simoncrypta/bercail/commit/b93c99f3b519643d1c5739672b0d6db00892fcdb).
These pages retain conclusions from completed investigations, not raw desk
reports or new permission to act. The linked reference docs describe current
usage.

- [Publication boundaries](publication-boundaries.md): historical Graphite
  contract research, the landed help fix, and scoped grants (removed in v0.18).
- [Tooling and bounded proof](tooling-and-proof.md): landed repo setup,
  statechart and Herdr mod-sync outcomes, with their remaining limits.
- [Evidence preservation](evidence-preservation.md): what the cleanup inventory
  and private recovery archive establish, and why originals still need custody.
- [Decision-question detector](decision-detector.md): v0.18 J16's offline test
  of Haiku 5.5 as the check for decisions asked in chat, with its labels and
  runner.
- [Vendoring](vendoring.md): proposal. What bercail copies from other repos and
  how each copy is pinned. Why copies beat subtree, submodules and fetched pins
  here, and a `git:` source for the dependency tracker that opens a `vendor`
  issue when an upstream moves.
- [Script languages](script-languages.md): bash, dash, QuickJS and Node
  measured on one desktop: keep bash for glue, and adopt neither dash nor
  QuickJS. Its pilot port of autopilot's `pr-state.sh` to TypeScript did not
  land and found no case for porting more.
- [Mulroy's tools](mulroy-tools.md): research. From dmmulroy's dotfiles only
  `GIT_EDITOR=true`; a staged switch from pi-claude-bridge to pi-claude-cli,
  with rollback; web fetch and search options, their costs and guard rules.
- [Shep's panels](shep-panels-ux.md): proposal. A UI/UX review of the
  Decisions and Routines panels in an isolated Herdr: the keys can answer a
  card the person never chose, nothing shows that the panel has the keyboard,
  and less than one card fits. Seven fixes, sized, with before and after
  mockups.
- [Worktree tool](worktree-tool.md): research. Keep worktrunk, and have a
  desk's spawn call it with `--no-hooks` and run each step itself. The worktree
  bugs on record are bercail's glue, not worktrunk's. Why plain `git worktree`,
  Herdr's worktree mod, Entire, jj and the stack tools do not fit better.

## Reading the evidence

**Landed** means present in the checked Git baseline, not installed or enabled.
**Historical** describes the source's version and observation window.
**Unsupported** means the required contract was not demonstrated.
**Proposal** is neither implementation nor owner approval. Saved test results
below are historical evidence, not tests rerun for this documentation.

## Private source records

Archive identifier: `bercail/20261117T032600Z-22y2`. This is a private local
recovery archive outside worktrees, not a public download or a Git directory.
Resolve these keys through its manifests, without publishing raw contents:

| Key | Record within the archive |
| --- | --- |
| P1 | `SUMMARY.json`, `RECOVERY.md`, `VERIFICATION.json`, root `SHA256SUMS` and the eight per-tree `manifest.json` files |
| P2 | `supplement/manifest.json` and `additional/manifest.json`, which record later copies and remaining gaps |
| I1 | `supplement/files/tmp/shep-bercail-review-cleanup-20261117-MkjBOA/report.md` |
| G1 | `supplement/files/tmp/bercail-0h5/report.md` |
| G2 | `additional/files/tmp/bercail-jvl/design.md` |

P1's `SUMMARY.json` SHA-256 is
`665262b63853acb82a9050d4ad86dba25ed238787ca6cbe6002be15681b72898`.
The root `SHA256SUMS` file's SHA-256 is
`a21f833284b0d870de296fa7092b8978288002e7cd691294307565a5923178f8`.
P2 maps each copied record to its content hash. Hashes identify retained bytes,
not completeness, approval or permission to remove their sources.
