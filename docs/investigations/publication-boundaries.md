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

## Scoped grants: landed for independent gh branches only

The earlier inventory [I1](README.md#private-source-records) called scoped job
authorization a staged, pending candidate on `3495144`. That status is
**superseded**: the checked baseline contains
[`b93c99f`](https://github.com/simoncrypta/bercail/commit/b93c99f3b519643d1c5739672b0d6db00892fcdb),
with parent `3495144adaf3faadf0884ed95bb2fd026ea371fb` and tree
`d5aa4b105566468e55146b880970c9de99b44b28`. This establishes landing, not a
fresh approval or activation. The recorded publication CI is
[run 44008064166](https://github.com/simoncrypta/bercail/actions/runs/44008064166).
No product test or CI rerun was performed for these docs.

Use the existing [scoped-grant reference](../shep.md#scoped-commit-and-fast-forward-grants)
and [rollout/recovery instructions](../shep.md#ledger-upgrade-and-recovery),
not the older research's proposed API. Landed code separates a job grant from
an exact candidate review and an action receipt. Its supported executor sends
one immutable OID to one independent `gh` feature ref without force. Graphite,
Entire and native-stack publication remain unsupported, with no silent raw-Git
fallback. The separate trusted-policy path is not a scoped grant.

The publication report recorded no activation. This consolidation did not
inspect the live ledger or installed processes and cannot establish their
current versions or authority state. Shipping files alone creates no grant.
The first successful typed scoped-question creation or revision migrates v1 to
v2 before a pick. Ordinary question writes keep v1. An old reader rejecting v2
does not make an already-loaded old guard safe. Coordinated reader/writer/guard
upgrade and restart remain separate operational work, not actions authorized
by these docs.

The [bounded lifecycle proof](../../tests/statechart/scoped-job/README.md)
explores one grant, one request, two candidates and two callers. Its recorded
511 states and 4,540 edges establish bounded ledger correspondence, not OS lock,
Git transport or complete executor correctness. PR/ownership checks remain
snapshots. Uncertain publication can remain quarantined indefinitely: a new
pick, session or visible OID is not remote-quiescence evidence. None of this
implements or approves G2's lease-rewrite proposal.
