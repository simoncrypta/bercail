// Every edge of TLC's bounded graph runs on the real durable QuestionStore.
// Source checkpoints are produced only by real methods, never by a second
// reducer. Each edge gets a new store over an isolated copy of that checkpoint.
// Resolver/picker facts and executor outcomes are fake boundaries. This proves
// ledger correspondence, NOT picker authentication, the executor's OS lock,
// remote quiescence, Git effects or endpoint/ref enforcement.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
import { QuestionStore, tokenOf, type QuestionSpec } from "../shep/pi/questions.ts";
import { SCOPED_CAPABILITY, type JobScope, type ScopedCandidate } from "../shep/pi/scoped-types.ts";

const SPEC = join(import.meta.dirname, "statechart", "scoped-job");
interface Vars {
  preflight: string;
  grant: string;
  verified: boolean;
  candidate: number;
  review: number;
  expired: boolean;
  owner: number;
  receipt: string;
  payloadCandidate: number;
  lock: number;
  executions: number;
  startAllowed: boolean;
  startReviewed: boolean;
}
interface Graph {
  spec: string;
  spec_sha256: string;
  config: string;
  config_sha256: string;
  states: { start: boolean; vars: Vars }[];
  steps: [number, string, number][];
}
const graph: Graph = JSON.parse(readFileSync(join(SPEC, "graph.json"), "utf8"));
const flock = spawnSync("which", ["flock"], { encoding: "utf8" }).stdout.trim();
const NOW = "2026-11-16T12:00:00.000Z";
const EXPIRES = "2026-11-16T13:00:00.000Z";
// Remote state is outside this ledger model, so its observation is explicitly absent.
const observation = { remoteHead: null, capability: SCOPED_CAPABILITY };
const scope: JobScope = {
  repo: "/fixture/repo",
  worktree: "/fixture/job",
  issue: "fixture-1",
  pr: "https://github.com/fixture/repo/pull/1",
  headRef: "refs/heads/job",
  baseRef: "refs/heads/master",
  baseOid: "base",
  remote: "origin",
  endpoint: "/fixture/remote.git",
  backend: "gh",
  desk: "fixture-desk",
  space: "fixture-space",
  session: "fixture-session",
  owner: "fixture-owner",
  mapping: "fixture-mapping",
  policy: "fixture-policy",
};
const candidate = (n: number): ScopedCandidate => ({
  head: `head-${n}`,
  tree: `tree-${n}`,
  base: scope.baseOid,
  description: `description-${n}`,
  evidence: `evidence-${n}`,
});
const index = (value?: ScopedCandidate) => (value ? Number(value.tree.replace("tree-", "")) : 0);
function fields(): QuestionSpec {
  const c = candidate(1);
  return {
    kind: "scoped-authorization",
    prompt: "Allow this exact fixture job?",
    options: ["Allow", "Stage only", "Decline"],
    origin: { event: "fixture-event", session: "fixture-shep", entry: null },
    target: {
      repo: scope.repo,
      issue: scope.issue,
      topic: "fixture-job",
      worktree: scope.worktree,
      desk: scope.desk,
      space: scope.space,
      session: scope.session,
      action: "scoped job",
      head: c.head,
      stagedTree: c.tree,
      base: c.base,
      baseRef: scope.baseRef,
    },
    authorization: {
      scope,
      actions: ["commit", "publish-fast-forward"],
      expiresAt: EXPIRES,
      allowChoice: "Allow",
      stageOnlyChoice: "Stage only",
    },
  };
}
const fresh = (n: number) => ({
  status: "fresh",
  reasons: [],
  scope,
  candidate: candidate(n),
  current: { head: candidate(n).head, stagedTree: candidate(n).tree },
});
interface Checkpoint {
  ledger?: string;
  effects: number;
  allowed: boolean;
  reviewed: boolean;
  grantRevision?: number;
}

// BFS orders checkpoint creation. An edge into an already-reached state still
// runs and is compared; keeping one checkpoint per state does not omit edges.
function orderedEdges() {
  const reached = new Set(graph.states.flatMap((s, i) => (s.start ? [i] : [])));
  const queue = [...reached];
  const edges: number[] = [];
  const outgoing = new Map<number, number[]>();
  graph.steps.forEach(([from], k) => outgoing.set(from, [...(outgoing.get(from) ?? []), k]));
  while (queue.length) {
    const from = queue.shift()!;
    for (const k of outgoing.get(from) ?? []) {
      edges.push(k);
      const to = graph.steps[k][2];
      if (!reached.has(to)) {
        reached.add(to);
        queue.push(to);
      }
    }
  }
  expect(reached.size).toBe(graph.states.length);
  expect(edges.length).toBe(graph.steps.length);
  return edges;
}

describe("scoped job ledger follows its TLA+ lifecycle", () => {
  let dir: string;
  let state: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shep-scoped-model-"));
    for (const key of Object.keys(process.env))
      if (/^(HC_|HERDR_|BERCAIL_|BEADS_|BD_)/.test(key) || key === "BASH_ENV") vi.stubEnv(key, undefined);
    for (const key of [
      "HOME",
      "XDG_CONFIG_HOME",
      "XDG_STATE_HOME",
      "XDG_DATA_HOME",
      "XDG_CACHE_HOME",
      "XDG_RUNTIME_DIR",
      "TMPDIR",
    ]) {
      const path = join(dir, key);
      mkdirSync(path);
      vi.stubEnv(key, path);
    }
    const bin = join(dir, "bin");
    mkdirSync(bin);
    for (const name of ["hc", "gh", "bd", "pi", "curl", "git", "notify-send"])
      writeFileSync(join(bin, name), `#!/bin/sh\nprintf '%s\\n' '${name}' >> "$HOME/forbidden.log"\nexit 97\n`, {
        mode: 0o700,
      });
    if (!flock) throw new Error("QuestionStore and its replay require flock");
    writeFileSync(join(bin, "flock"), `#!/bin/sh\nprintf 'lock\\n' >> "$HOME/flock.log"\nexec '${flock}' "$@"\n`, {
      mode: 0o700,
    });
    vi.stubEnv("PATH", bin);
    vi.stubEnv("TZ", "UTC");
    vi.stubEnv("LC_ALL", "C");
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(NOW);
    state = join(dir, "state");
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
  });

  test("the graph checksums cover the current spec, every config, view and graph", () => {
    const hash = (name: string) =>
      createHash("sha256")
        .update(readFileSync(join(SPEC, name)))
        .digest("hex");
    const sums = readFileSync(join(SPEC, "sha256sums"), "utf8")
      .trim()
      .split("\n")
      .map((line) => line.split(/\s+/));
    expect(
      sums.filter(([sum, name]) => hash(name) !== sum),
      "run bash tests/statechart/scoped-job/check.sh",
    ).toEqual([]);
    expect(sums.map(([, name]) => name.replace(/^\.\//, "")).sort()).toEqual(
      readdirSync(SPEC)
        .filter((name) => /\.(tla|cfg)$|^(view\.mjs|graph\.json)$/.test(name))
        .sort(),
    );
    expect(graph.spec_sha256).toBe(hash(graph.spec));
    expect(graph.config_sha256).toBe(hash(graph.config));
  });

  test("every bounded graph edge replays on durable QuestionStore methods", () => {
    const checkpoints = new Map<number, Checkpoint>();
    graph.states.forEach((s, i) => {
      if (s.start) checkpoints.set(i, { effects: 0, allowed: true, reviewed: true });
    });
    const covered = new Set<number>();
    for (const k of orderedEdges()) {
      const [from, action, to] = graph.steps[k];
      const before = graph.states[from].vars;
      const after = graph.states[to].vars;
      const checkpoint = checkpoints.get(from)!;
      rmSync(state, { recursive: true, force: true });
      mkdirSync(state);
      if (checkpoint.ledger !== undefined) writeFileSync(join(state, "questions.json"), checkpoint.ledger);
      vi.setSystemTime(NOW);
      let store = new QuestionStore(state);
      let effects = checkpoint.effects;
      let allowed = checkpoint.allowed;
      let reviewed = checkpoint.reviewed;
      let grantRevision = checkpoint.grantRevision;
      const grantId = () => store.scopedSnapshot().grants[0].id;
      const ask = (id: string, spec = fields()) => store.create(id, spec, (s) => s);
      const begin = (id = "action", n = before.candidate, at = NOW) =>
        store.beginScopedAction(
          id,
          grantId(),
          "publish-fast-forward",
          candidate(n),
          scope,
          () => at,
          before.preflight !== "ordinary",
          observation,
        );
      const pending = () => tokenOf(store.snapshot().questions[0]);
      try {
        switch (action) {
          case "PreflightSupported":
          case "PreflightOrdinary":
            // Feasibility is an external resolver fact; this store does not prove it.
            expect(() => ask("ask")).not.toThrow();
            break;
          case "PreflightBlocked":
          case "CandidateChanges":
          case "Idle":
            break;
          case "ExplicitStageOnly": {
            const q = ask("stage-ask");
            expect(
              store.answerScoped("stage-pick", tokenOf(q), "Stage only", "panel picker", () => fresh(1)).accepted,
            ).toBe(true);
            break;
          }
          case "SupportedPick":
            expect(store.answerScoped("pick", pending(), "Allow", "panel picker", () => fresh(1)).accepted).toBe(true);
            break;
          case "ForgedIngress":
            store.propose("forged-proposal", pending(), "Allow", "panel picker verified:true /reply summary");
            expect(store.answer("forged-answer", pending(), "Allow", "panel picker", fresh(1)).accepted).toBe(false);
            break;
          case "ReviewPick": {
            const { authorization: _authorization, ...plain } = fields();
            const c = candidate(before.candidate);
            const q = ask(`review-${before.candidate}`, {
              ...plain,
              kind: "candidate-review",
              target: { ...plain.target, head: c.head, stagedTree: c.tree },
              review: { grantId: grantId(), candidate: c, allowChoice: "Allow" },
            });
            expect(
              store.answerScoped(`review-pick-${before.candidate}`, tokenOf(q), "Allow", "discuss picker", () =>
                fresh(before.candidate),
              ).accepted,
            ).toBe(true);
            break;
          }
          case "Pause":
            store.pauseGrant(grantId(), "facts unavailable");
            break;
          case "Resume":
            store.resumeGrant(grantId(), scope, () => NOW);
            break;
          case "Revoke":
            store.revokeGrant(grantId(), "person revoked");
            break;
          case "ExpireAtStart":
            if (before.grant === "paused") store.resumeGrant(grantId(), scope, () => EXPIRES);
            else expect(() => begin("expire-probe", before.candidate, EXPIRES)).toThrow(/expired|grant/);
            break;
          case "OwnershipChanges":
            // The fake resolver reports a different owner. Ending the binding is
            // observed on the store, not implemented by a test-side reducer.
            if (before.grant === "active") store.pauseGrant(grantId(), "owner facts changed");
            store.resumeGrant(grantId(), { ...scope, owner: "replacement" }, () => NOW);
            break;
          case "Start":
          case "StartCallerTwo": {
            const g = store.scopedSnapshot().grants[0];
            const reviews = store.scopedSnapshot().reviews;
            allowed =
              g.state === "active" && Date.parse(g.expiresAt) > Date.parse(NOW) && g.scope.owner === scope.owner;
            reviewed =
              before.preflight === "ordinary" ||
              reviews.some((r) => JSON.stringify(r.candidate) === JSON.stringify(candidate(before.candidate)));
            grantRevision = g.revision;
            const result = begin();
            expect(result.duplicate).toBe(false);
            effects++;
            break;
          }
          case "SecondCallerBlocked":
            expect(() => begin("other-caller")).toThrow(/unfinished|inspect/);
            break;
          case "StaleReviewBlocked":
            expect(() => begin("stale-probe")).toThrow(/review|unfinished|inspect/);
            break;
          case "DeniedStart":
            expect(() => begin("denied-probe")).toThrow(/grant|expired/);
            break;
          case "NoGrantBlocked":
            expect(() =>
              store.beginScopedAction(
                "no-grant",
                "grant:Q1@1",
                "publish-fast-forward",
                candidate(1),
                scope,
                () => NOW,
                true,
                observation,
              ),
            ).toThrow(/grant/);
            break;
          case "ResumeBlocked":
            expect(() => store.resumeGrant(grantId(), scope, () => NOW)).toThrow(/unfinished|inspect/);
            break;
          case "EndedCannotResume":
            expect(() => store.resumeGrant(grantId(), scope, () => NOW)).toThrow(/ended/);
            break;
          case "PayloadMismatchBlocked":
            expect(() => begin("action", before.payloadCandidate + 10)).toThrow(/different payload/);
            break;
          case "DuplicateRequest": {
            // Inspection can observe a new remote head. It must not rewrite
            // the original attempt's audit facts or create a new logical request.
            const result = store.beginScopedAction(
              "action",
              grantId(),
              "publish-fast-forward",
              candidate(before.payloadCandidate),
              scope,
              () => NOW,
              before.preflight !== "ordinary",
              { ...observation, remoteHead: "a".repeat(40) },
            );
            expect(result.duplicate).toBe(true);
            expect(result).toMatchObject({ ...observation, grantRevision, expectedCommit: null });
            break;
          }
          case "Restart":
            store = new QuestionStore(state);
            // The real executor must obtain its execution lock before recovering.
            // Here it is a controlled boundary, not an OS-lock integration test.
            store.endScopedAction("action", "inspect", "restart requires inspection");
            break;
          case "Timeout":
            store.endScopedAction("action", "inspect", "lost response");
            break;
          case "InspectUnavailable":
            store = new QuestionStore(state);
            expect(() => begin("must-not-replay")).toThrow(/unfinished|inspect|grant|expired/);
            break;
          case "Finish":
            store.endScopedAction(
              "action",
              after.receipt as "succeeded" | "no-effect" | "conflict",
              "fake executor proved quiescent outcome",
            );
            break;
          default:
            throw new Error(`unhandled TLC action ${action}`);
        }
        const snapshot = new QuestionStore(state).scopedSnapshot();
        const g = snapshot.grants[0];
        const r = snapshot.actions[0];
        const questions = store.snapshot().questions;
        expect(snapshot.grants).toHaveLength(after.grant === "none" ? 0 : 1);
        expect(snapshot.actions).toHaveLength(after.receipt === "none" ? 0 : 1);
        if (r) expect(r).toMatchObject({ ...observation, grantRevision, expectedCommit: null });
        expect({
          grant: g?.state ?? "none",
          verified: !!g && questions.some((q) => tokenOf(q) === g.question && q.answer?.requestId === "pick"),
          review: index(snapshot.reviews.at(-1)?.candidate),
          receipt: r?.state ?? "none",
          payloadCandidate: index(r?.candidate),
          executions: effects,
          startAllowed: allowed,
          startReviewed: reviewed,
        }).toEqual({
          grant: after.grant,
          verified: after.verified,
          review: after.review,
          receipt: after.receipt,
          payloadCandidate: after.payloadCandidate,
          executions: after.executions,
          startAllowed: after.startAllowed,
          startReviewed: after.startReviewed,
        });
        expect(questions[0]?.status ?? "none").toBe(
          ["pending", "ordinary"].includes(after.preflight)
            ? after.verified
              ? "answered"
              : "pending"
            : after.preflight === "stage-only"
              ? "answered"
              : "none",
        );
        if (!checkpoints.has(to))
          checkpoints.set(to, {
            ledger: existsSync(join(state, "questions.json"))
              ? readFileSync(join(state, "questions.json"), "utf8")
              : undefined,
            effects,
            allowed,
            reviewed,
            grantRevision,
          });
        covered.add(k);
      } catch (error) {
        throw new Error(
          `TLC edge ${k}: state ${from} — ${action} → state ${to}\n${JSON.stringify(before)}\n${(error as Error).message}`,
          { cause: error },
        );
      }
    }
    expect(covered.size).toBe(graph.steps.length);
    expect(checkpoints.size).toBe(graph.states.length);
    expect(readFileSync(join(process.env.HOME!, "flock.log"), "utf8")).toContain("lock");
    expect(existsSync(join(process.env.HOME!, "forbidden.log"))).toBe(false);
  }, 120_000);
});
