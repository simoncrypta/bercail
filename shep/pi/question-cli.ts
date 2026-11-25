import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, resolve } from "node:path";
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
  type QuestionLand,
  type QuestionSpec,
  shipped,
} from "./questions.ts";
import {
  captureTarget,
  checkLand,
  checkQuestion,
  landFacts,
  mergeReversible,
  policyChange,
  repoOf,
  withTarget,
} from "./question-target.ts";
import { sweepLand, tellLand } from "./land-chain.ts";
import {
  approvePush,
  close,
  closed,
  discussionOf,
  expireDue,
  openDiscussion,
  pick,
  reask,
  settle,
  unsettled,
} from "./discuss.ts";

const rebaseNote = (check: { status: string; rebased?: unknown }) =>
  check.status === "fresh" && check.rebased ? "fresh (rebased: patch unchanged)" : null;

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
  if (op === "waiting") {
    console.log(await decisions(store.snapshot(), state));
    return;
  }
  if (op === "json") result = store.snapshot();
  // What waits on the person, and the land chains still running: `bercail shep questions --json`.
  else if (op === "pending") {
    const all = store.snapshot().questions;
    result = { pending: all.filter(waiting), landing: all.filter(landing) };
  } else if (op === "get") {
    if (args.length !== 1 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("get requires an explicit Qn@revision token");
    result = store.snapshot().questions.find((q) => tokenOf(q) === args[0]);
    if (!result) throw new Error("unknown question revision");
  } else if (op === "panel") result = await panel(store, state);
  // What Shep's runtime runs on its timer: records the defaults that are due, then sweeps
  // the land chains (a pick with no worker, a worker gone, a result not told).
  else if (op === "expire") {
    let failed: unknown = null;
    const due = await expireDue(state).catch((error) => ((failed = error), []));
    const land = (() => {
      try {
        return sweepLand(state);
      } catch (error) {
        failed ??= error;
        return [];
      }
    })();
    if (failed) throw failed;
    result = [...due.map(tokenOf), ...land];
  } else if (op === "thread") {
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
    const note = rebaseNote(check);
    result = {
      ...check,
      ...(note ? { note } : {}),
      ...(question.reversible ? { door: door(question, () => mergesIn(check)) } : {}),
    };
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
  } else if (op === "guard-default") {
    // The guard's worker, at its deadline: nobody answered, and what it runs still reads
    // as the card said (its why, on stdin). The ledger records the default once.
    if (args.length !== 2 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("guard-default requires a Qn@revision token and the ticket, and {why} on stdin");
    const input = JSON.parse(readFileSync(0, "utf8"));
    if (!input || Object.keys(input).join() !== "why" || typeof input.why !== "string")
      throw new Error("guard-default reads {why} on stdin");
    result = store.defaultGuard(args[0]!, args[1]!, input.why);
  } else if (op === "land-claim") {
    // A land card's worker: the person's Ship it, claimed once.
    if (args.length !== 1 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("land-claim requires a Qn@revision token");
    result = store.claimLand(args[0]!);
  } else if (op === "land-check") {
    // The land worker's check before an effect: every pinned fact, HEAD its own commit once
    // it made one, and the trunk that commit once it pushed it (--landed).
    const landed = args[2] === "--landed";
    if (args.length < 1 || args.length > (landed ? 3 : 2) || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("land-check requires a Qn@revision token, then optionally the chain's commit and --landed");
    if (args[1] !== undefined && !/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(args[1]))
      throw new Error("land-check takes the chain's full commit id");
    const question = store.snapshot().questions.find((q) => tokenOf(q) === args[0]);
    if (question?.kind !== "land") throw new Error("land-check requires a land card's token");
    const { status, reasons, warnings } = checkLand(question, args[1], landed);
    result = { status, reasons, warnings };
  } else if (op === "land-tell") {
    if (args.length !== 1 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("land-tell requires a Qn@revision token");
    result = tellLand(state, args[0]!);
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
      if (Object.keys(input).sort().join() !== "issue,origin,prompt,requestId,worktree")
        throw new Error("land-create fields must be requestId, prompt, origin, worktree and issue");
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
      const keys = Object.keys(input).filter((key) => key !== "why" && key !== "trusted");
      if (keys.sort().join() !== "commit,log,outcome,token,warnings")
        throw new Error(
          "land-result fields must be token, outcome, commit, warnings and log, and why when it stopped or trusted when it trusted the policy",
        );
      const { token, ...outcome } = input;
      result = store.landResult(token, outcome);
    } else if (op === "withdraw") {
      if (Object.keys(input).sort().join() !== "reason,requestId,token")
        throw new Error("withdraw fields must be requestId, token and reason only");
      result = store.withdraw(input.requestId, input.token, input.reason);
    } else if (op === "answer") {
      // A pick names its choice; the person's OK or Reverse on a default names its
      // outcome, and a Reverse may name another choice. Their Close on any card is
      // here too: like an answer, it is the person's, so the guard blocks it for agents.
      // So is their Ask again on a stale card, which answers nothing: Shep hears of it.
      const keys = Object.keys(input).sort().join();
      if (keys === "outcome,requestId,source,token" && input.outcome === "closed")
        result = close(state, input.requestId, input.token, input.source);
      else if (keys === "outcome,requestId,source,token" && input.outcome === "reask")
        result = await reask(state, input.token, input.source);
      else if (keys === "outcome,requestId,source,token" && ["ok", "reversed"].includes(input.outcome))
        result = await settle(state, input.requestId, input.token, input.outcome, null, input.source);
      else if (keys === "choice,outcome,requestId,source,token" && input.outcome === "reversed")
        result = await settle(state, input.requestId, input.token, "reversed", input.choice, input.source);
      else if (keys === "choice,requestId,source,token")
        result = await pick(state, input.requestId, input.token, input.choice, input.source);
      else
        throw new Error(
          'answer fields must be requestId, token, choice and source, or requestId, token, source and outcome "ok", "reversed" (which may add choice), "closed" or "reask"',
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
      "usage: question-cli.ts list | json | pending | get Qn@revision | waiting | panel | expire | create | revise | reply | answer | withdraw | guard-create | land-create | land-result | thread TOPIC | check Qn@revision | discuss Qn@revision | closed Qn@revision OPENING | push-approval DIR REMOTE REFSPEC... | guard-default Qn@revision TICKET | guard-claim Qn@revision TICKET | land-claim Qn@revision | land-step Qn@revision STEP [DETAIL] | land-check Qn@revision [COMMIT [--landed]] | land-tell Qn@revision",
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

// A pending card, or a default the person has not said OK to or reversed.
const waiting = (q: Question) => q.status === "pending" || unsettled(q);
// A land card the person shipped whose chain has no result yet: picked, or landing.
const landing = (q: Question) => shipped(q) && !q.landing?.result;

// A land card's spec: Ship it or Not yet on the facts read now, refused while its desk does
// not check out. Its CI branch is named from the request, so a replay names the same one.
// The brief is each effect the pick allows, with its target, written from those facts. The
// store checks every fact is there.
function landSpec(input: Record<string, any>): QuestionSpec {
  const { target, land: read, warnings, policy } = landFacts(input.worktree, input.issue);
  if (warnings.length) throw new Error(`a land card binds to its desk: ${warnings.join("; ")}`);
  // The profile one pick lands, read from the policy this card pins, whose hash its checks compare.
  const p = policy.policy;
  if (!policy.trusted || p.push !== "main" || p.integrate !== "direct" || !p.required_ci?.length)
    throw new Error(
      'a land card lands only where the trusted policy says push = "main", integrate = "direct" and names required_ci',
    );
  const branch = (target.branch ?? "").replace(/^refs\/heads\//, "");
  const id = createHash("sha256").update(String(input.requestId)).digest("hex").slice(0, 12);
  const change = policyChange(target.worktree!);
  const land = { ...read, ciRef: `refs/heads/bercail-land/${branch}/${id}`, policyTrust: change?.sha256 ?? null };
  return {
    kind: "land",
    prompt: input.prompt,
    options: land.review.required ? LGTM_LAND_CHOICES : LAND_CHOICES,
    brief: landBrief(target, land, change?.diff ?? null),
    origin: input.origin,
    target,
    land,
  };
}

// What a pick on the card allows, effect by effect, with each target, and the policy diff
// it trusts.
function landBrief(t: QuestionSpec["target"], l: QuestionLand, policyDiff: string | null): string {
  const short = (sha: string | null) => (sha ?? "?").slice(0, 12);
  const ci = l.ciRef.replace(/^refs\/heads\//, "");
  const lines = [
    `Commit tree ${short(t.stagedTree)} on ${(t.branch ?? "").replace(/^refs\/heads\//, "")} (parent ${short(t.head)}, ${t.baseRef} on ${l.url}).`,
    `Push it to ${l.url} as the new branch ${ci}.`,
    `Wait up to two hours for CI (${l.requiredCi.map((w) => w.path).join(", ")}) to pass on that commit.`,
    `Push the same commit to ${t.baseRef} there, with no force.`,
    `Clean up the desk ${t.desk} and its worktree ${t.worktree}.`,
    `Fast-forward the main checkout to it.`,
    `Close ${t.issue} once those held.`,
  ];
  if (l.review.required)
    lines.push(
      `It touches high-stakes paths (${l.review.highStakes.join(", ")}): the commit names ${l.reviewer} as Reviewed-by, as a record of this pick.`,
    );
  if (l.policyTrust)
    lines.push(
      `It changes the repo's .bercail/policy.toml: once its commit is on ${t.baseRef}, it trusts that file, sha256 ${l.policyTrust}, as bercail policy trust would.`,
    );
  lines.push("If anything it was pinned to changes, it stops there and the job stays open.");
  return lines.join(" ") + (policyDiff ? `\n\nThe policy diff:\n${policyDiff}` : "");
}

// What the Decisions panel shows: each pending question with its brief, Shep's
// recommendation, live check (its desk warnings too) and deadline, and the staged change's size and stakes for
// a review or action; and each default until the person says OK, or Shep withdraws it.
// Answering is `answer`; this only reads.
async function panel(store: QuestionStore, state: string) {
  const bin = process.env.BERCAIL_SHEP_BIN || "bercail";
  const cards = [];
  const shown = (q: Question) =>
    waiting(q) || landing(q) || (q.status === "answered" && q.settled?.outcome === "reversed");
  for (const q of store.snapshot().questions.filter(shown)) {
    // A default is checked too: the person's OK or Reverse on it needs it fresh. A land
    // card whose chain runs is not: it shows how far it got, and takes no pick.
    const check = landing(q)
      ? { status: "landing", reasons: [] as string[], warnings: [] as string[], policy: undefined }
      : await checkQuestion(q);
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
    const note = rebaseNote(check);
    cards.push({
      token: tokenOf(q),
      kind: q.kind,
      prompt: q.prompt,
      brief: note ? [q.brief, note].filter(Boolean).join("\n") : (q.brief ?? null),
      options: q.options,
      recommendation: q.recommendation ?? null,
      push: q.push ?? null,
      // A guard card's own deadline: it defaults to Allow then, or counts as a Deny.
      guard: q.guard ? { expires: q.guard.expires, defaults: q.guard.defaults !== undefined } : null,
      discussed: discussionOf(state, q) !== null,
      createdAt: q.createdAt,
      // A deadline only while it is still a two-way door, with the policy just read.
      deadline: q.answer || (!note && door(q, () => mergesIn(check)).door === "two-way") ? (q.deadline ?? null) : null,
      defaulted: q.answer ? { choice: q.answer.choice, at: q.answer.at } : null,
      reversed: q.settled ? { choice: q.settled.choice, at: q.settled.at } : null,
      target: { repo, topic, worktree, space, url: url ?? null },
      status: check.status,
      reasons: check.reasons,
      warnings: check.warnings,
      change,
      landing: landing(q) ? landingOf(q) : null,
    });
  }
  return { state, at: new Date().toISOString(), cards };
}

// How far a shipped land card's chain got: picked and waiting for its worker, or its
// last step and what that step says.
function landingOf(q: Question) {
  const step = q.landing?.steps.at(-1);
  return step ? { step: step.step, detail: step.detail ?? null, at: step.at } : { step: null, detail: null, at: null };
}

// How long a space's Herdr name is kept, so a settle runs no lookup for one it named.
const SPACE_TTL_MS = 10 * 60000;
// A name is optional: every lookup of one run shares this, and the cards print without it.
const SPACE_LOOKUP_MS = 1500;

// The Herdr names of spaces IDS, as notify reads them (notify_space_info in lib/notify.sh):
// the window's, else the one bercail gave a space it made through hc. Kept, misses too,
// in the state dir's space-names.json for SPACE_TTL_MS; one lookup serves every stale id.
// A run cut short by SPACE_LOOKUP_MS keeps nothing, and a cache it cannot write is skipped.
function spaceNames(state: string, ids: string[], now: number): Record<string, string | null> {
  const file = join(state, "space-names.json");
  let cache: Record<string, { name: string | null; at: number }> = {};
  try {
    cache = JSON.parse(readFileSync(file, "utf8"));
  } catch {}
  const due = [...new Set(ids)].filter((id) => !(now - (cache[id]?.at ?? -Infinity) < SPACE_TTL_MS));
  if (due.length) {
    const end = performance.now() + SPACE_LOOKUP_MS;
    let cut = false;
    const json = (bin: string, args: string[]) => {
      const timeout = Math.floor(end - performance.now());
      if (timeout <= 0) return void (cut = true);
      const r = spawnSync(bin, args, { encoding: "utf8", timeout, killSignal: "SIGKILL" });
      if ((r.error as NodeJS.ErrnoException | undefined)?.code === "ETIMEDOUT") cut = true;
      try {
        return JSON.parse(r.stdout);
      } catch {
        return null;
      }
    };
    const hc = process.env.HC_BIN || "hc";
    const spaces = json(process.env.HERDR_APP_BIN || "herdr-app", ["ls"])?.spaces;
    const found: typeof cache = {};
    for (const id of due) {
      let name = Array.isArray(spaces) ? spaces.find((x) => x?.id === id)?.name : undefined;
      if (typeof name !== "string" || !name) {
        const shell = json(hc, ["ls", "--json", "--label", `herdr.space=${id}`])?.terminals?.[0]?.address;
        name = shell ? json(hc, ["get", shell, "--json"])?.labels?.["bercail.space_name"] : undefined;
      }
      found[id] = { name: typeof name === "string" && name ? name : null, at: now };
    }
    if (cut) return Object.fromEntries(ids.map((id) => [id, (found[id] ?? cache[id])?.name ?? null]));
    Object.assign(cache, found);
    const tmp = `${file}.${process.pid}`;
    try {
      writeFileSync(tmp, JSON.stringify(cache) + "\n", { mode: 0o600 });
      renameSync(tmp, file);
    } catch {
      rmSync(tmp, { force: true });
    }
  }
  return Object.fromEntries(ids.map((id) => [id, cache[id]?.name ?? null]));
}

// "Waiting on you" for the board and Shep's reply, from the ledger alone: one line per
// card that waits on the person, named by its desk's Herdr space (else its job or folder),
// with its live check when not fresh and a two-way door's countdown. Its check skips
// beads (checkQuestion says why).
export async function decisions(snapshot: { questions: Question[] }, state: string) {
  const now = Date.now();
  const cut = (s: string, max: number) => {
    // eslint-disable-next-line no-control-regex
    const flat = s.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ");
    return flat.length > max ? flat.slice(0, max - 1) + "…" : flat;
  };
  const cards = snapshot.questions.filter(waiting);
  const names = spaceNames(
    state,
    cards.flatMap((q) => (q.target.space ? [q.target.space] : [])),
    now,
  );
  const lines = ["Decisions:"];
  for (const q of cards) {
    const check = await checkQuestion(q, { beads: false });
    const folder = (q.target.worktree ?? "").split("/").filter(Boolean).pop();
    const where = (q.target.space && names[q.target.space]) || q.target.issue || folder || q.target.topic;
    const parts = [`- ${cut(where, 64)}: ${cut(q.prompt, 100)}`];
    if (check.status !== "fresh")
      parts.push(check.status + (check.reasons.length ? `: ${cut(check.reasons.join(", "), 80)}` : ""));
    if (unsettled(q)) parts.push(`defaulted to ${cut(q.answer!.choice, 40)}, waits for your OK or Reverse`);
    else if (q.deadline && !rebaseNote(check) && door(q, () => mergesIn(check)).door === "two-way") {
      // The panel's countdown (bercail-shep's countdown()): a card that is not fresh never defaults.
      const ms = Date.parse(q.deadline) - now;
      const min = Math.floor(ms / 60000);
      const left =
        min < 1
          ? "under a minute"
          : min < 60
            ? `${min} min`
            : `${Math.floor(min / 60)} h${min % 60 ? ` ${min % 60} min` : ""}`;
      parts.push(
        check.status === "fresh"
          ? `two-way door: defaults to ${cut(q.recommendation!.choice, 40)} ${ms > 0 ? `in ${left}` : "at Shep's next check"}`
          : `two-way door: ${ms > 0 ? `due in ${left}, but` : "past its deadline;"} it waits for you while it is ${check.status}`,
      );
    }
    lines.push(parts.join(" · "));
  }
  if (lines.length === 1) lines.push("- nothing");
  // The chains the person started: they wait on no one, so they are listed apart.
  const running = snapshot.questions.filter(landing);
  if (running.length) {
    lines.push("Landing:");
    for (const q of running) {
      const { step, detail } = landingOf(q);
      const what = step ? `${step}${detail ? `: ${cut(detail, 80)}` : ""}` : "picked; waiting for its worker";
      lines.push(`- ${cut(q.target.issue ?? q.target.topic, 64)}: ${cut(q.prompt, 100)} · ${what}`);
    }
  }
  return lines.join("\n");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`Shep questions: ${error.message}`);
    process.exitCode = 1;
  });
}
