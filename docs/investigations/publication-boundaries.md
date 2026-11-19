# Publication boundaries

## Graphite: unsupported exact-ref rewrite contract

**Historical finding, Graphite 1.8.6.** The completed research did not establish
an execution-time contract for publishing one immutable candidate to one exact
feature ref against a caller-pinned expected remote OID. The proposed narrow
lease exception was design-only. It was not implemented or enabled. Sources:
[G1 and G2](README.md#private-source-records), especially G2's decision,
evidence and races sections.

The researchers read recorded CLI help, installed package manifests and strings
from the compiled Linux executable, plus anonymous Graphite and Git docs. They
did not execute `gt` or prove native publication end to end. G2 identifies the
binary by SHA-256
`d400bdfbe954c8dad4569deb70e99eaafbbdc9c1e4fa223e5523abc37907e979`.
Strings and documentation corroborate an interface, not every control-flow path.

| Recorded interface | Consequence for a one-branch job |
| --- | --- |
| `gt submit` defaults to force-with-lease | Omitting `--force` does not establish a no-rewrite path. |
| `gt modify`, including `--commit`, restacks descendants | Remote lease protection does not authorize local changes to child branches. |
| `submit --no-stack` omits descendants, not ancestors | It does not establish an exact-one-ref update. |
| `--update-only` selects branches with existing PRs | It does not select one PR. |
| `--dry-run`, `--no-edit`, `--no-ai` | Planning or metadata options do not enforce the eventual ref/lease scope. |

These are observations about the researched version, not a claim about every
future Graphite release. The archived command-reference extracts accompany G2.
The [live command reference](https://graphite.com/docs/command-reference) is a
place to begin a separately authorized re-evaluation, not a frozen source.

**Still unresolved:** native enforcement of the exact endpoint/ref/expected-OID/
candidate tuple, absence of extra local or remote effects, and reliable outcome
receipts. A lower-level Git compare-and-swap primitive is not proof of Graphite
support or permission to substitute raw Git. An OID-value lease cannot detect an
intervening E→X→E change. Ref updates do not atomically bind PR/base metadata.
Cooperative local locks do not fence arbitrary writers. G2 proposed upstream
support or a separately approved adapter, not an available escape hatch.

## Genuine help: a separate landed fix

[`5266b32`](https://github.com/simoncrypta/bercail/commit/5266b326d5bc7bbb05206610b375f416331621d6)
landed narrow recognition of genuine Git and Graphite CLI help. The current
[help rules](../config.md#git-policy-per-repo) and
[`cliHelp`](../../bstack/pi/extensions/guard.ts) require exact command forms and,
for Graphite, known non-overridden aliases. Unknown alias state keeps the write
checks. This fixes help misclassification, not native publication scope. A
parser allowing a command string is not authority to execute its effects.

## Scoped grants: landed, then removed in v0.18

The earlier inventory [I1](README.md#private-source-records) called scoped job
authorization a staged, pending candidate on `3495144`. It landed as
[`b93c99f`](https://github.com/simoncrypta/bercail/commit/b93c99f3b519643d1c5739672b0d6db00892fcdb)
for independent `gh` branches only: a job grant, a separate candidate review
and an action receipt, with one immutable OID sent to one feature ref without
force. Graphite, Entire and native-stack publication stayed unsupported.

It was never used: of the 101 questions Shep had asked when the
[v0.18 plan](../plans/v0.18.md) counted them, none was of its kinds. The plan
removed it (S3, job J5), with its tool,
question kinds, guard rules and statechart. Shep commits and pushes through
the repo's policy and the guard's ask instead. None of this implements or
approves G2's lease-rewrite proposal.
