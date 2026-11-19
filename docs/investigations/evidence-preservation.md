# Evidence preservation and cleanup limits

## Inventory findings are time-bound

The completed Bercail inventory [I1](README.md#private-source-records) sampled
worktrees, native refs and process metadata at 2026-11-17 02:22:41–02:22:45 UTC,
then inspected saved proof and original feature deltas. It was not atomic and
ran no product tests. It counted one canonical candidate ready for human review,
zero authorized shipments and zero worktrees proven removable at that time.

The pending scoped-authorization classification is now
[superseded by its landed commit](publication-boundaries.md#scoped-grants-landed-then-removed-in-v018),
and the feature was later removed.
Do not carry old candidate counts, clean-tree observations or process snapshots
forward as current status. The setup, help, statechart, quiet-installer and mod
changes were already landed in I1. Their old copies were preservation concerns,
not additional candidate approvals.

I1's useful method was to compare original feature deltas rather than inherited
whole-tree identity, then separately inspect staged, unstaged, untracked and
ignored evidence. Exact staged-tree reconstruction protects a different thing
from a product patch-equivalence check. Neither protects omitted sessions,
external artifacts or live writers. A done desk or clean tracked tree does not
establish that its directory is disposable.

## What the recovery archive establishes

The preservation coordinator recorded eight commissioned Bercail source trees
in archive `bercail/20261117T032600Z-22y2`. See
[P1 and P2](README.md#private-source-records) for identity hashes and record keys.
This later recovery snapshot supersedes the preliminary metadata-screening
snapshot `20261117T032020Z-22y2`, not the original sources.

P1 records standalone history bundles, original HEAD/ref metadata, raw indices,
binary patches and selected technical evidence. The coordinator reconstructed
each recorded staged tree in isolated scratch using the bundle and patch,
compared index entries/modes, and independently checked the retained raw index.
It reported matching trees and unchanged source identities/digests after
preservation. Those are the coordinator's recorded recovery results, not a
recovery rerun by this documentation job.

The archive stores regular files as non-executable private copies, with original
modes in Git/index catalogues and copy manifests. Its scratch reconstruction was
sanitized by removing coordinator-created symlink nodes after recording their
identities. It is not a ready-to-run checkout. P1's `RECOVERY.md` describes fresh,
isolated recovery without original hooks/config/object-store dependence. Do not
restore its paths over a live source or execute archived files as validation.

Consult per-tree manifests together with P2's supplement and additional
manifests. A first-pass exclusion may have a later explicit copy. Conversely, a
hash or a recorded path is not evidence that the referenced bytes were copied.
The archive is partial, with **all eight Bercail trees KEEP and zero ready for
removal** in its recorded disposition.

## Unresolved custody blocks cleanup

The coordinator retained originals and did not resolve these exclusions:

- Private session histories and live `.entire`, `.beads` and `.wrangler` stores.
- Credentials, login/token material, private environment files and browser
  profiles. These must not be copied into tracked findings to fill a gap.
- Redirect/symlink destinations, unknown ignored directories, dependency/cache
  bulk and unselected, missing or directory-only volatile references.
- Live terminal/process ownership. A cwd snapshot cannot rule out changed-cwd
  processes or other open handles.

The scoped-authorization plan/build/integration trees were protected and were
outside this eight-tree archive commission. Their later code publication does
not establish preservation or deletion readiness. External native/WASM custody
mentioned in the cross-repo coordinator's report was also outside this Bercail
archive scope. No availability or recovery claim about those artifacts follows
from these manifests. Other repositories' product acceptance is not a Bercail
documentation result.

A future cleanup decision needs current exact-path permission, verified custody
of unique material and resolved live ownership. Directory removal, branch
retention/deletion, space closure and process termination are separate choices.
I1 found removal tooling could delete patch-equivalent branches and an installed
hook could close the associated space. That historical observation is not a
current tooling audit or a removal recipe. No shipping, activation, cleanup or
source-session disposal is authorized by this documentation.
