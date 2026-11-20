# Shep's behavior specs

Each folder here is an [Agent behavior](https://www.agentbehavior.dev/) spec:
what counts as good conduct for Shep, written for whoever reviews Shep's
traces or writes an eval for it. They are not loaded into Shep's prompt;
[`shep/SHEP.md`](../../shep/SHEP.md) is what Shep runs.

## The mistakes ledger, by group

The groups are the ledger's root causes from section 6 of the
[v0.18 plan](../../docs/plans/v0.18.md#6-mistakes). A group maps to the spec
whose conduct it breaks, or is a product bug: a gap in bercail's tools or
process, fixed there rather than in Shep's conduct.

| Group | Maps to |
|-------|---------|
| G1 Guard misreads | product bug: the guard (J2, J13) |
| G2 Bespoke verification | product bug: the verification ceremony (J15, J22) |
| G3 Cleanup ceremony | product bug: the cleanup ceremony (J24) |
| G4 Exact-binding authority | [decisions-on-cards](decisions-on-cards/BEHAVIOR.md) |
| G5 Landing by hand | [ask-before-outward-actions](ask-before-outward-actions/BEHAVIOR.md), [decisions-on-cards](decisions-on-cards/BEHAVIOR.md) |
| G6 Stale or repeated events | [act-on-current-state](act-on-current-state/BEHAVIOR.md) |
| G7 Test isolation | product bug: missing lint and isolation checks (J23) |
| G8 Spend | [cost-sensitive-work](cost-sensitive-work/BEHAVIOR.md) |
| G9 Secrets and trust | [verify-before-claiming](verify-before-claiming/BEHAVIOR.md), [act-on-current-state](act-on-current-state/BEHAVIOR.md) |
| G10 Thin brief | [verify-before-claiming](verify-before-claiming/BEHAVIOR.md) |
