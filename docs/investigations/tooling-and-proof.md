# Tooling and bounded proof

These outcomes are **landed in the checked baseline**, not claims about the
person's installation. Commit messages and [I1](README.md#private-source-records)
retain historical validation reports. This consolidation checked source and
references only. It did not rerun their tests or activate these features.

## Repo setup prepares files, not authority

[`3495144`](https://github.com/simoncrypta/bercail/commit/3495144adaf3faadf0884ed95bb2fd026ea371fb)
landed the GitHub/Entire policy scaffolder. Its canonical contract is
[Prepare a policy and verification starter](../config.md#prepare-a-policy-and-verification-starter),
implemented in [`lib/policy-init.sh`](../../lib/policy-init.sh).

The durable distinction is between preparing files, trusting permissions,
proving a candidate and obtaining required human review. `policy init` handles
only preparation. Its verification starter is explicitly INCOMPLETE until the
owner supplies reviewed repo-specific commands and acceptance criteria. It
creates neither Pi project-resource trust nor Bercail policy trust, and runs no
repo verification. Existing trust or local overrides may already affect the
effective policy, so generated settings are not a promise of effective rights.

The Entire profile's project-level Trail workflow is rules text, not a new
integration enum or runtime enforcement. Entire capture or a GitHub mirror does
not by itself establish native Entire hosting. This distinction matters in a
repo that captures sessions while using `gh` for hosting.

**Limits:** no-clobber creation is not a multi-file transaction. I/O failure or
a concurrent creator can leave partial output. Parent-path checks do not defend
against hostile same-user path replacement. The earlier GitHub-only source is
historical, not a second setup feature awaiting shipment. I1 found all seven
source blobs differed from the landed extension, so landing alone was not
byte-equivalence or permission to discard that source's proof.

## Statecharts connect a bounded model to selected real code

[`fe8a7c1`](https://github.com/simoncrypta/bercail/commit/fe8a7c16007c56860dc01a767706b22f847464dc)
landed the opt-in statechart skill and Shep inbox model/replay. Follow
[statechart usage](../bstack.md#statecharts) and
[development/proof maintenance](../development.md#statecharts). The vendored
upstream revision is recorded in [`UPSTREAM.md`](../../skills/statechart/UPSTREAM.md).
TLC is pinned to 1.7.4. The wrapper does not install dependencies itself.

The inbox [full configuration](../../tests/statechart/shep-inbox/full.cfg)
models two consumers and up to three sessions. Its
[replay configuration](../../tests/statechart/shep-inbox/replay.cfg) uses one
consumer, two sessions and a notice. The
[replay test](../../tests/shep_inbox_statechart.test.ts) checks every exported
edge on real `inbox.ts` behavior. Two-consumer locking is model-checked only.
The model's `SavedOnce` rule concerns durable saving, not a promise that a user
can never see a notice twice after a lost reply. Planted bugs and expected-red
replays are sensitivity checks, not open production defects.

[`00b33ab`](https://github.com/simoncrypta/bercail/commit/00b33ab6f4ff403a3239353694735b001215c624)
then suppressed mise's misleading inactive-tool warning by adding `--quiet`
only to TLC and fallback Java installation. The checksum pin, path resolution
and non-global activation approach stayed unchanged. Historical isolated
real-mise proof is reported in that commit. Errors remain visible, but other
non-error installer diagnostics are also suppressed. This was not a live
update of the person's installation.

**Limits:** a model checks its encoded rules and finite bounds. Replay connects
only its chosen actions and observations to code. Neither establishes arbitrary
concurrency, transport or physical-system guarantees. The separate scoped-job
model went with the feature in v0.18.
Existing charts remain at their source locations. No new implementation chart
or acceptance claim is introduced here.

## Herdr mod sync preserves Bercail's differences

[`4d59ff5`](https://github.com/simoncrypta/bercail/commit/4d59ff54b513d656f05b6ae5900ee3e7f278dd0f)
ported Herdr 0.1.16 spaces/agents fixes. The
[spaces](../../bercail/mods/bercail-spaces/mod.json) and
[agents](../../bercail/mods/bercail-agents/mod.json) clone records retain their
upstream version/fingerprints. This was a source sync, not replacement of the
mods with unmodified upstream copies.

The landed commit retained Bercail's Shep/review handling and desk rows while
porting scrolling, stale git-cache/watch cleanup, persisted-state recovery and
agent title/address fixes. The
[spaces implementation](../../bercail/mods/bercail-spaces/main.js) uses a global
four-place worker limit, rather than upstream's six, and waits for both Git
commands to settle. Its retained capacity choice may slow mixed-machine refresh
but bounds concurrent work without a new scheduler.

I1 compared the original eight-path delta with the landed delta using stable
patch ID `6a2c44721d76cec316186ddce84efa29f2fae952`. Matching feature blobs and
patch IDs established equivalence of that delta despite differing inherited
whole trees. The nonancestor source commit
`adc13f28dae4695ed3c040da26bc63c3c93d9f15` still needed preservation. Whole-tree
inequality alone was not evidence of an unlanded feature, and feature equivalence
was not evidence that ignored research or live ownership could be discarded.

**Unverified here:** current installed mod bytes, visual behavior and remote
runtime capacity. The original commit recorded no live install or visual
inspection. Saved checks are not a substitute for a future operational check.
