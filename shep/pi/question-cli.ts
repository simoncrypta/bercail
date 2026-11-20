import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import {
  DEFAULT_SOURCE,
  door,
  mergesIn,
  QuestionStore,
  projection,
  tokenOf,
  type Question,
  type QuestionSpec,
} from "./questions.ts";
import { captureTarget, checkQuestion, mergeReversible } from "./question-target.ts";
import { closed, discussionOf, expireDue, openDiscussion, pick, recent } from "./discuss.ts";

async function main() {
  const state = process.env.BERCAIL_SHEP_STATE;
  if (!state?.trim()) throw new Error("set BERCAIL_SHEP_STATE to the question state directory");
  const [op, ...args] = process.argv.slice(2);
  const store = new QuestionStore(state);
  let result: unknown;
  if (op === "list") {
    console.log(projection(store.snapshot()));
    return;
  }
  if (op === "json") result = store.snapshot();
  else if (op === "panel") result = await panel(store, state);
  // What Shep's runtime runs on its timer: records the defaults that are due.
  else if (op === "expire") result = (await expireDue(state)).map(tokenOf);
  else if (op === "thread") {
    if (args.length !== 1) throw new Error("thread requires a topic (or - to clear)");
    store.select(args[0] === "-" ? null : args[0]!);
    result = store.snapshot();
  } else if (op === "check") {
    if (args.length !== 1 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("check requires an explicit Qn@revision token");
    const question = store.snapshot().questions.find((q) => tokenOf(q) === args[0]);
    if (!question) throw new Error("unknown question revision");
    const check = await checkQuestion(question);
    // A reversible question's door with the policy just read: act on its default only
    // while it is fresh and still two-way.
    result = question.reversible ? { ...check, door: door(question, () => mergesIn(check)) } : check;
  } else if (op === "discuss") {
    if (args.length !== 1 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("discuss requires a Qn@revision token");
    const question = store.snapshot().questions.find((q) => tokenOf(q) === args[0]);
    if (!question) throw new Error("unknown question revision");
    result = openDiscussion(state, question);
  } else if (op === "closed") {
    if (args.length !== 2) throw new Error("closed requires a Qn@revision token and the opening's id");
    result = { told: closed(state, args[0]!, args[1]!) };
  } else if (["create", "revise", "reply", "answer", "withdraw"].includes(op ?? "")) {
    if (args.length) throw new Error(`${op} reads JSON from stdin, not argv`);
    const input = JSON.parse(readFileSync(0, "utf8"));
    if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("expected a JSON object");
    if (op === "withdraw") {
      if (Object.keys(input).sort().join() !== "reason,requestId,token")
        throw new Error("withdraw fields must be requestId, token and reason only");
      result = store.withdraw(input.requestId, input.token, input.reason);
    } else if (op === "answer") {
      if (Object.keys(input).sort().join() !== "choice,requestId,source,token")
        throw new Error("answer fields must be requestId, token, choice and source only");
      result = await pick(state, input.requestId, input.token, input.choice, input.source);
    } else if (op === "reply") {
      if (Object.keys(input).sort().join() !== "answer,requestId,source,token")
        throw new Error("reply fields must be requestId, token, answer and source only; no verification flags");
      result = store.propose(input.requestId, input.token, input.answer, input.source);
    } else {
      if (
        !input.origin ||
        !["event", "session"].every((key) => typeof input.origin[key] === "string" && input.origin[key].trim()) ||
        (input.origin.entry !== null && (typeof input.origin.entry !== "string" || !input.origin.entry.trim()))
      )
        throw new Error("origin requires nonempty event/session and entry or null");
      const { requestId, token, ...intent } = input;
      const resolveSpec = (): QuestionSpec => ({
        kind: input.kind,
        prompt: input.prompt,
        options: input.options,
        ...(input.brief === undefined ? {} : { brief: input.brief }),
        ...(input.recommendation == null ? {} : { recommendation: input.recommendation }),
        ...(input.reversible === true ? { reversible: true as const } : {}),
        origin: input.origin,
        target: captureTarget(input),
      });
      result =
        op === "create"
          ? store.create(requestId, intent, resolveSpec, mergeReversible)
          : store.revise(requestId, token, intent, resolveSpec, mergeReversible);
    }
  } else
    throw new Error(
      "usage: question-cli.ts list | json | panel | expire | create | revise | reply | answer | withdraw | thread TOPIC | check Qn@revision | discuss Qn@revision | closed Qn@revision OPENING",
    );
  console.log(JSON.stringify(result));
}

// What the Decisions panel shows: each pending question with its brief, Shep's
// recommendation, live check (its desk warnings too) and deadline, and the staged change's size and stakes for
// a review or action; then the questions that defaulted in the last day. Answering is
// `answer`; this only reads.
async function panel(store: QuestionStore, state: string) {
  const bin = process.env.BERCAIL_SHEP_BIN || "bercail";
  const cards = [];
  const shown = (q: Question) => q.status === "pending" || (q.answer?.source === DEFAULT_SOURCE && recent(q));
  for (const q of store.snapshot().questions.filter(shown)) {
    // A defaulted question is settled: nothing to check, and no picker.
    const check = q.answer ? null : await checkQuestion(q);
    let change = null;
    if (!q.answer && q.kind !== "planning" && q.target.worktree) {
      // describe check exits 1 while the change has no description; its JSON still holds the size.
      const r = spawnSync(bin, ["describe", "check", "--json", q.target.worktree], {
        cwd: q.target.worktree,
        encoding: "utf8",
        timeout: 10000,
      });
      try {
        const c = JSON.parse(r.stdout).change;
        change = { lines: c.lines, stakes: c.stakes };
      } catch {}
    }
    const { repo, topic, worktree, space, url } = q.target;
    cards.push({
      token: tokenOf(q),
      kind: q.kind,
      prompt: q.prompt,
      brief: q.brief ?? null,
      options: q.options,
      recommendation: q.recommendation ?? null,
      discussed: discussionOf(state, q) !== null,
      createdAt: q.createdAt,
      // A deadline only while it is still a two-way door, with the policy just read.
      deadline: !check || door(q, () => mergesIn(check)).door === "two-way" ? (q.deadline ?? null) : null,
      defaulted: q.answer ? { choice: q.answer.choice, at: q.answer.at } : null,
      target: { repo, topic, worktree, space, url: url ?? null },
      status: check?.status ?? "defaulted",
      reasons: check?.reasons ?? [],
      warnings: check?.warnings ?? [],
      change,
    });
  }
  return { state, at: new Date().toISOString(), cards };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`Shep questions: ${error.message}`);
    process.exitCode = 1;
  });
}
