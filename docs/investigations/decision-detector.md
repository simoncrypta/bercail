# Decision-question detector, offline (v0.18 J16)

Run on 2026-11-20 against Shep's 8 sessions up to 2026-11-20 00:30 UTC. This is
an experiment. Its runner lives in `decision-detector/`, and nothing in bercail
calls it.

**Question.** Can a small model tell, from one of Shep's replies, that it asks
Simon to decide something, well enough to remind Shep to make a Decisions card?
The plan's bar ([v0.18, "A small decision model?"](../plans/v0.18.md#a-small-decision-model)):
it is worth building only if escalating 30% of cases or fewer to Opus matches
Opus's accuracy alone on the same set.

**Answer: on this retrospective sample, it passes.** Claude Haiku 5.5 through
the bridge decides, and the uncertain band (p from 0.3 to 0.9) goes to Opus 5.5.
That hybrid scores 97.7% on the 302 labeled replies, the same as Opus alone. It
escalates 6.6% of the labeled set and 16.2% of the replies a router would check.
Haiku alone scores 96.4%. That gap is 4 replies, which does not settle which
model is better. Whether Phase 3 gains a router job is Simon's call. The
recommendation at the end is a shadow-only pilot first.

## Data and labels

- **Candidates:** every final reply Shep wrote, meaning a turn that ended with
  text. That gives 1,078 replies: 1,054 from the main session and 24 from the
  7 Discuss sessions. 114 of them came in a turn that called `shep_question`.
  In 9 of those turns, every call failed, so no card was made.
- **Sample:** 302 replies in three strata, to oversample the hard cases.
  - 60 from turns with a `shep_question` call.
  - 141 with a question mark and no call.
  - 101 with neither.

  Each stratum is ordered by the SHA-256 of `session:entry`, and the first ones
  are taken. Five replies around the ledger's two misses
  (`decision-asked-only-in-chat`, `asked-in-chat-without-card`) were added by
  hand.
- **Labels:** 213 yes and 89 no. 42 of them are marked hard. I labeled each
  reply before any model ran, reading it with what triggered the turn and
  Simon's next message. The models and the second labeler saw the reply alone.
  The rule is the one in [`prompt.md`](decision-detector/prompt.md):
  - **Yes:** a choice, an approval or a go-ahead that Shep or a desk waits on.
    That includes soft offers ("tell me if you want those deleted") and
    reminders that a decision is still pending.
  - **No:** reports, and telling Simon to act elsewhere (answer a desk's
    prompt, run a command). Factual questions are also no.

  [`labels.jsonl`](decision-detector/labels.jsonl) holds only ids and labels.
  The message text is not checked in, because it names other repos and
  clients.
- **A second labeler:** the GPT 6.2 judge labeled the 42 hard replies blind,
  from the reply alone. It agreed on 34 of 42 (κ = 0.63). All 8 disagreements
  are replies I labeled yes and it labeled no. Most are implicit
  recommendations, clarifications, or questions about facts:
  - `f0ca69ad`, `4cc212dc`, `f0f79a61`, `8117a663`
  - `aad90ed3`, `0573d3a6`, `b4548dd4`, `56e0245e`

  With its labels in place of mine, the accuracy of the hybrid and of Opus
  stays at 97.7%. Their precision drops from 98.6% to 96.7% (3 to 7 false
  yeses), and Haiku alone drops to 95.7%. These 8 are Simon's to settle.

## Models

Each reply goes to a headless `pi -p` with the
[prompt](decision-detector/prompt.md) as its system prompt. The runs use
provider `claude-bridge`, thinking `off`, and no tools, skills, extensions or
context files. Each model returns `{"p": …}`, and yes means p ≥ 0.5. Haiku 5.5
ran on all 1,078 replies and Opus 5.5 on the 302 labeled ones. The bridge
receives each reply's text.

## Results

| Set | Model | n | Precision | Recall | Accuracy | False yes | False no |
| --- | --- | --- | --- | --- | --- | --- | --- |
| all | Haiku | 302 | 96.3% | 98.6% | 96.4% | 8 | 3 |
| all | Opus | 302 | 98.6% | 98.1% | 97.7% | 3 | 4 |
| hard | Haiku | 42 | 80.0% | 88.9% | 78.6% | 6 | 3 |
| hard | Opus | 42 | 92.0% | 85.2% | 85.7% | 2 | 4 |
| no `shep_question` call | Haiku | 242 | 95.0% | 98.7% | 95.9% | 8 | 2 |
| no `shep_question` call | Opus | 242 | 98.1% | 98.1% | 97.5% | 3 | 3 |

The two models disagree on 8 replies. Haiku alone is wrong on 6 of them and
Opus alone on 2, and both are wrong on 5 more. With 6 against 2, the difference
is not significant (McNemar, p ≈ 0.29). Haiku's 95% interval, 93.6% to 98.0%,
contains Opus's score.

The sample oversamples questions. To get Shep's real mix, weight each stratum
by its candidates over its labeled replies. Then Haiku's precision drops to
89.9% and Opus's to 95.5%, and recall stays at 97.7% and 97.4%. The few false
yeses in the plain stratum each count about 7 times.

**Calibration** compares each bucket of the stated p with the share of labels
that are yes:

| p bucket | Haiku n | Haiku mean p | Haiku yes | Opus n | Opus mean p | Opus yes |
| --- | --- | --- | --- | --- | --- | --- |
| 0.0–0.1 | 65 | 0.04 | 0.0% | 50 | 0.04 | 0.0% |
| 0.1–0.3 | 16 | 0.17 | 18.8% | 27 | 0.13 | 3.7% |
| 0.3–0.5 | 3 | 0.30 | 0.0% | 13 | 0.34 | 23.1% |
| 0.5–0.7 | 2 | 0.63 | 50.0% | 4 | 0.57 | 75.0% |
| 0.7–0.9 | 7 | 0.80 | 71.4% | 12 | 0.82 | 83.3% |
| 0.9–1.0 | 209 | 0.97 | 97.6% | 196 | 0.97 | 100.0% |

Haiku's Brier score is 0.031, with an expected calibration error of 0.023. Opus
scores 0.021 and 0.040. These figures describe this sample. They do not show
that calibration holds on new traffic.

- **Haiku says it is sure.** 274 of its 302 answers are below 0.1 or at 0.9
  and above, so its middle buckets hold 28 replies and say little.
- **Its confident errors have one cause.** Haiku makes 5 of its 11 mistakes at
  p ≥ 0.9, all false yeses. Each one tells Simon to act somewhere else: answer
  a desk's prompt ("Answer **Yes**", "If you say yes in the desk…"), approve a
  1Password prompt, or pause a webhook. The rule counts those as no. The two at
  exactly 0.9 fall inside the band, and the three at 0.93 to 0.97 do not. This
  is the overconfidence the plan warns about.
- **Opus's mistakes sit near the middle**, from 0.15 to 0.85.

**Escalation:** Haiku decides outside the band, and Opus decides inside it.
The last column counts the 512 main-session replies after the Decisions panel
existed (from 2026-11-15 15:42) whose turn had no `shep_question` call. Those
are the replies a router would check.

| Band | Escalated (labeled) | Accuracy | Precision | Recall | Escalated (router's 512) |
| --- | --- | --- | --- | --- | --- |
| none (Haiku alone) | 0% | 96.4% | 96.3% | 98.6% | 0% |
| 0.3–0.7 | 2.0% | 96.7% | 97.2% | 98.1% | |
| 0.3–0.9 | 6.6% | 97.7% | 98.6% | 98.1% | 16.2% (83) |
| 0.1–0.9 | 11.9% | 97.4% | 98.1% | 98.1% | |
| 0.05–0.95 | 27.2% | 97.4% | 98.1% | 98.1% | |
| all (Opus alone) | 100% | 97.7% | 98.6% | 98.1% | 100% |

The band from the Hightouch study, 0.3–0.9, is the lowest-escalation band
tested that matches Opus. The wider bands tested did no better, because Opus
gets some of Haiku's low-p replies wrong. Counting failed calls as no card
gives 521 replies, of which 84 escalate (16.1%).

**The misses the plan names.** The four sampled replies that asked the ledger's
uncarded decisions score p ≥ 0.97 from both models:

- deleting the 39 old GitHub branches, asked twice;
- messaging the desks;
- restarting a client PR's work.

Among the 18 replies in the sample, by my labels, that ask a new decision after
the panel existed and have no `shep_question` call, Haiku flags 17. The one it
misses, `0573d3a6`, is one the second labeler calls no.

**What a router would see.** Haiku calls 173 of the router's 512 replies
decisions. This run did not measure how many of those restate a question that
is already open on the panel. So a router needs the list of open questions, or
it will nag about cards that exist. A check after the reply also catches a
missing card only once Simon has read the question in chat, not before.

**Latency and quota.** A call through the bridge took a median of 4.5 s for
Haiku (7.9 s at p90) and 6.4 s for Opus (10.6 s at p90). The run hit the
five-hour Claude limit, which it shares with the other desks. 738 Haiku rows
and 97 Opus rows came back empty, and they ran again after the reset. Shep
wrote 100 to 184 replies a day (UTC) from Nov 14 to Nov 19. A check per reply
is that many calls a day, and it must run after the reply, never in front of
it.

## Limits

- **One labeler, partly checked.** I labeled every reply. I am Opus 5.5, the
  same model as the baseline and as Shep. 10 of the 13 replies that either
  model gets wrong are ones I marked hard. On those 42, a second labeler agreed
  on 81%. Label disagreement is about as large as the gap between the models.
- **Small set.** The middle calibration buckets hold 2 to 16 replies. The
  sample is from the same sessions the rule was written from: no held-out set.
- **The prompt was not tuned.** Both models ran the first version.

## Recommendation for Phase 3

Add a router job, shadow-only at first. After each Shep turn that ends with
text and has no successful `shep_question` call:

1. Ask Haiku 5.5 with this prompt.
2. Send p in 0.3–0.9 to Opus.
3. Log the verdict next to the open questions, and do not nudge yet.

After a week of fresh turns, Simon reads the logged yeses and settles the 8
disputed labels. Then measure precision on new uncarded decisions, with
reminders of open cards left out, before the nudge goes live. Haiku alone is
within noise of the hybrid. It is the simpler choice if the extra Opus call is
not worth about one point of accuracy and more false yeses.

## Rerunning

From this folder, with Shep's state at `~/.local/state/bercail/shep`. Put the
outputs outside the repo, since they hold Shep's messages. The bridge receives
each one, in `pi`'s argv:

```bash
s=~/.local/state/bercail/shep; o=~/.cache/bercail-scratch/j16; mkdir -p "$o"
node detector.mjs extract $s/pi-sessions/*.jsonl $s/discuss/sessions/*.jsonl > $o/candidates.jsonl
node detector.mjs sample $o/candidates.jsonl 0368e1f8 f5529010 4c9a8dcd 48549a72 0998f835 > $o/sample.jsonl  # the labeled ids
JOBS=3 node detector.mjs classify claude-haiku-5-5 $o/candidates.jsonl > $o/haiku.jsonl
JOBS=3 node detector.mjs classify claude-opus-5-5 $o/candidates.jsonl labels.jsonl > $o/opus.jsonl
node detector.mjs score labels.jsonl $o/candidates.jsonl $o/haiku.jsonl $o/opus.jsonl
```

A call that fails twice, or that answers with no p from 0 to 1, records
`"p": null` with the output's end in `raw`, and the score skips it. Rerun those
rows before you trust the tables. To read the hard labels with their text:

```bash
jq -r --slurpfile l labels.jsonl '($l|map(select(.hard)|{(.entry):.label})|add) as $h
  | select($h[.entry] != null) | "\(.entry) label=\($h[.entry])\n\(.text)\n"' $o/candidates.jsonl
```
