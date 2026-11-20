---
name: cost-sensitive-work
description: Shep keeps model use within the job and the person's plans. Ordinary work runs on the subscription without asking; benchmarks, comparison runs and repeated model calls run only on an explicit ask, with a cap and a stop. Applies when Shep scopes a job and when a desk or its siblings run model-heavy steps.
---

# Cost-sensitive work

**Intent:** Shep and its desks run on the person's own plans: Claude for the
work, ChatGPT for the judge. There is no fallback model for the Opus roles,
so a used-up Claude plan pauses them until it resets. Either plan, used up,
also limits the person's own use of it. The spend is hard to see: Pi records $0 for the subscription
bridge, so any figure is an estimate.

**Evidence:** What the job will run, on which plan, and how many times: the
desk, its builder, one judge review per /validate, and anything beyond that
(benchmarks, live runs, comparison sets, loops of model calls). Plan usage
where the tools show it.

**Decision:** Is this step's model use beyond the job's ordinary work? Does it
draw on a plan other than the one the work runs on? Is there a cap and a
point at which the job stops?

**Execution:** Ordinary work goes ahead. For anything beyond it, Shep asks
first, says which plan it draws on and roughly how much, and writes the cap
and the stop condition into the job's issue or trail. A desk that reaches the cap stops
and reports; it does not finish the run first.

**Recovery:** When usage cannot be measured, Shep and the desk say the figure
is an estimate and stop early rather than late. When the Claude plan hits its
limit, the Opus roles pause and report the reset time. The judge is the one
role that moves: from a limited GPT to Opus, and it pauses when Opus is
limited too. No other role switches provider to keep going.

**Failure modes:**

- A job with no cap running benchmarks on the person's ChatGPT plan until the
  plan's limit.
- A desk reporting, after the fact, that it ran over its cap.
- A desk that cannot read its own meter and goes on anyway.
- An Opus role moving to another model to finish when the Claude plan is
  limited.

## Seen in the ledger

G8, Spend: `model-spend-uncapped`, six times on Nov 14 and 15. The first
(lesentiel) ran a computer-use comparison on the ChatGPT plan until it hit
the usage limit; the other five are desks that went over their job cap by
estimate.
