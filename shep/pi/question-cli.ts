import { spawnSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import {
  door,
  GUARD_CHOICES,
  LAND_CHOICES,
  LGTM_LAND_CHOICES,
  mergesIn,
  QuestionStore,
  projection,
  tokenOf,
  type Question,
  type QuestionSpec,
} from "./questions.ts";
import { captureTarget, checkQuestion, landFacts, mergeReversible, repoOf, withTarget } from "./question-target.ts";
import { approvePush, closed, discussionOf, expireDue, openDiscussion, pick, settle, unsettled } from "./discuss.ts";

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
  } else if (op === "push-approval") {
    // The guard's: the answer that approves this push, spent on it.
    const [dir, remote, ...refspecs] = args;
    if (!dir || !remote || !refspecs.length) throw new Error("push-approval requires DIR REMOTE REFSPEC...");
    result = await approvePush(state, { dir, remote, refspecs });
  } else if (op === "guard-claim") {
    // The guard's worker: the person's Allow on its card, claimed once.
    if (args.length !== 2 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("guard-claim requires a Qn@revision token and the ticket");
    result = store.claimGuard(args[0]!, args[1]!);
  } else if (op === "land-claim") {
    // A land card's worker: the person's Ship it, claimed once.
    if (args.length !== 1 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("land-claim requires a Qn@revision token");
    result = store.claimLand(args[0]!);
  } else if (op === "land-step") {
    if (args.length < 2 || args.length > 3 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("land-step requires a Qn@revision token and the step, then optionally what it says");
    result = store.landStep(args[0]!, args[1] as never, args[2]);
  } else if (op === "discuss") {
    if (args.length !== 1 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("discuss requires a Qn@revision token");
    const question = store.snapshot().questions.find((q) => tokenOf(q) === args[0]);
    if (!question) throw new Error("unknown question revision");
    result = openDiscussion(state, question);
  } else if (op === "closed") {
    if (args.length !== 2) throw new Error("closed requires a Qn@revision token and the opening's id");
    result = { told: closed(state, args[0]!, args[1]!) };
  } else if (
    ["create", "revise", "reply", "answer", "withdraw", "guard-create", "land-create", "land-result"].includes(op ?? "")
  ) {
    if (args.length) throw new Error(`${op} reads JSON from stdin, not argv`);
    const input = JSON.parse(readFileSync(0, "utf8"));
    if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("expected a JSON object");
    if (op === "guard-create") {
      // The guard's worker: its card, bound to the repo of the folder it acts in.
      if (Object.keys(input).sort().join() !== "brief,dir,guard,origin,prompt,requestId")
        throw new Error("guard-create fields must be requestId, prompt, brief, origin, dir and guard");
      result = store.create(input.requestId, input, () => guardSpec(input));
    } else if (op === "land-create") {
      // A land card, its facts pinned here from the worktree and its job. They are read
      // before the ledger's lock, which a remote read must not hold; a replay of the same
      // request still gets its receipt, and a failed read fails only a new one.
      if (Object.keys(input).sort().join() !== "brief,issue,origin,prompt,requestId,worktree")
        throw new Error("land-create fields must be requestId, prompt, brief, origin, worktree and issue");
      let read: QuestionSpec | Error;
      try {
        read = landSpec(input);
      } catch (error) {
        read = error as Error;
      }
      result = store.create(input.requestId, input, () => {
        if (read instanceof Error) throw read;
        return read;
      });
    } else if (op === "land-result") {
      if (Object.keys(input).sort().join() !== "commit,log,outcome,token,warnings")
        throw new Error("land-result fields must be token, outcome, commit, warnings and log");
      const { token, ...outcome } = input;
      result = store.landResult(token, outcome);
    } else if (op === "withdraw") {
      if (Object.keys(input).sort().join() !== "reason,requestId,token")
        throw new Error("withdraw fields must be requestId, token and reason only");
      result = store.withdraw(input.requestId, input.token, input.reason);
    } else if (op === "answer") {
      // A pick names its choice; the person's OK or Reverse on a default names its
      // outcome, and a Reverse may name another choice.
      const keys = Object.keys(input).sort().join();
      if (keys === "outcome,requestId,source,token" && ["ok", "reversed"].includes(input.outcome))
        result = await settle(state, input.requestId, input.token, input.outcome, null, input.source);
      else if (keys === "choice,outcome,requestId,source,token" && input.outcome === "reversed")
        result = await settle(state, input.requestId, input.token, "reversed", input.choice, input.source);
      else if (keys === "choice,requestId,source,token")
        result = await pick(state, input.requestId, input.token, input.choice, input.source);
      else
        throw new Error(
          'answer fields must be requestId, token, choice and source, or requestId, token, source and outcome "ok" or "reversed" (a Reverse may add choice)',
        );
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
        ...withTarget(captureTarget(input), input.push),
      });
      result =
        op === "create"
          ? store.create(requestId, intent, resolveSpec, mergeReversible)
          : store.revise(requestId, token, intent, resolveSpec, mergeReversible);
    }
  } else
    throw new Error(
      "usage: question-cli.ts list | json | panel | expire | create | revise | reply | answer | withdraw | guard-create | land-create | land-result | thread TOPIC | check Qn@revision | discuss Qn@revision | closed Qn@revision OPENING | push-approval DIR REMOTE REFSPEC... | guard-claim Qn@revision TICKET | land-claim Qn@revision | land-step Qn@revision STEP [DETAIL]",
    );
  console.log(JSON.stringify(result));
}

// A guard card's spec: Allow or Deny on the guard's reason, bound to the folder's repo and
// to the ticket. The store checks its shape.
function guardSpec(input: Record<string, any>): QuestionSpec {
  const dir = realpathSync(String(input.dir));
  return {
    kind: "guard",
    prompt: input.prompt,
    options: GUARD_CHOICES,
    brief: input.brief,
    origin: input.origin,
    guard: input.guard,
    target: {
      repo: repoOf(dir),
      issue: null,
      topic: `guard-${input.guard?.ticket}`,
      worktree: dir,
      desk: null,
      space: null,
      session: null,
      action: null,
      head: null,
      stagedTree: null,
      base: null,
      baseRef: null,
    },
  };
}

// A land card's spec: Ship it or Not yet on the facts read now, refused while its desk does
// not check out. The store checks every fact is there.
function landSpec(input: Record<string, any>): QuestionSpec {
  const { target, land, warnings } = landFacts(input.worktree, input.issue);
  if (warnings.length) throw new Error(`a land card binds to its desk: ${warnings.join("; ")}`);
  return {
    kind: "land",
    prompt: input.prompt,
    options: land.review.required ? LGTM_LAND_CHOICES : LAND_CHOICES,
    brief: input.brief,
    origin: input.origin,
    target,
    land,
  };
}

// What the Decisions panel shows: each pending question with its brief, Shep's
// recommendation, live check (its desk warnings too) and deadline, and the staged change's size and stakes for
// a review or action; and each default until the person says OK, or Shep withdraws it.
// Answering is `answer`; this only reads.
async function panel(store: QuestionStore, state: string) {
  const bin = process.env.BERCAIL_SHEP_BIN || "bercail";
  const cards = [];
  const shown = (q: Question) =>
    q.status === "pending" || unsettled(q) || (q.status === "answered" && q.settled?.outcome === "reversed");
  for (const q of store.snapshot().questions.filter(shown)) {
    // A default is checked too: the person's OK or Reverse on it needs it fresh.
    const check = await checkQuestion(q);
    let change = null;
    if (!q.answer && q.kind !== "planning" && q.kind !== "guard" && q.target.worktree) {
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
      push: q.push ?? null,
      discussed: discussionOf(state, q) !== null,
      createdAt: q.createdAt,
      // A deadline only while it is still a two-way door, with the policy just read.
      deadline: q.answer || door(q, () => mergesIn(check)).door === "two-way" ? (q.deadline ?? null) : null,
      defaulted: q.answer ? { choice: q.answer.choice, at: q.answer.at } : null,
      reversed: q.settled ? { choice: q.settled.choice, at: q.settled.at } : null,
      target: { repo, topic, worktree, space, url: url ?? null },
      status: check.status,
      reasons: check.reasons,
      warnings: check.warnings,
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
