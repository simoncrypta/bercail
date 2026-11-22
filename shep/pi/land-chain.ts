// A land card's chain around its worker (docs/plans/one-pick-landing.md, sections 3 to 5):
// start the worker on the person's Ship it, sweep picks with no live worker and chains
// whose worker died, and write each result's one land event. The worker itself is
// `bercail land run` (lib/land.sh); nothing here runs an effect.
import { spawnSync } from "node:child_process";
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, renameSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { landTerminal, QuestionStore, shipped, tokenOf, type Question } from "./questions.ts";

// What hc says of the worker's terminal: live, gone, or not known (hc did not answer).
// No answer is not gone: the sweep waits.
export function terminalState(name: string): "live" | "gone" | "unknown" {
  const r = spawnSync(process.env.HC_BIN || "hc", ["get", name, "--json"], { encoding: "utf8", timeout: 10000 });
  let shown: any = null;
  try {
    shown = JSON.parse(r.stdout);
  } catch {}
  if (r.status === 0 && shown && typeof shown === "object" && typeof shown.state === "string")
    return shown.state === "live" ? "live" : "gone";
  if (r.status !== 0 && shown?.error?.kind === "not_found") return "gone";
  return "unknown";
}

// Reserve the next start under the ledger's lock, then start the worker in its own hc
// terminal, from the Herdr server, so only this env prefix reaches it. A start that fails
// leaves the reservation, and the sweep starts it again.
export function startLand(state: string, token: string): { started: boolean; reason?: string } {
  const store = new QuestionStore(state);
  const q = store.snapshot().questions.find((x) => tokenOf(x) === token);
  if (!q) return { started: false, reason: "unknown question revision" };
  const reserved = store.reserveLand(token, (q.landing?.starts.length ?? 0) + 1);
  if (!reserved.accepted) return { started: false, reason: reserved.reason };
  // The worker's bercail finds this ledger under XDG_STATE_HOME/bercail/shep.
  const xdg = state.endsWith("/bercail/shep")
    ? dirname(dirname(state))
    : process.env.XDG_STATE_HOME || join(process.env.HOME ?? "", ".local/state");
  const r = spawnSync(
    process.env.HC_BIN || "hc",
    [
      "run",
      "--bg",
      "--name",
      landTerminal(q),
      "--cwd",
      "/",
      "--outlive-parent",
      "--no-notify",
      "--rm",
      "--label",
      "bercail.land=run",
      "--label",
      `bercail.question=${token}`,
      "--",
      "env",
      "BERCAIL_ROLE=shep",
      `XDG_STATE_HOME=${xdg}`,
      q.land!.bercail,
      "land",
      "run",
      token,
    ],
    { stdio: ["ignore", "ignore", "pipe"], encoding: "utf8", timeout: 30000 },
  );
  if (r.status !== 0)
    return {
      started: false,
      reason: `hc could not start ${landTerminal(q)}: ${(r.stderr || "").trim().split("\n")[0]}`,
    };
  return { started: true };
}

// The repo's name, from its git dir: the folder the main checkout is in.
const repoName = (repo: string) => basename(repo.replace(/\/\.git$/, ""));

// A result's one land event, from the ledger's record and its fields alone.
export function landEvent(q: Question) {
  const r = q.landing!.result!;
  const token = tokenOf(q);
  return {
    source: "bercail",
    schema: "bercail.land/v2",
    kind: "land",
    sink: "shep",
    at: r.at,
    event_id: `land:${token}`,
    question: token,
    repo: repoName(q.target.repo),
    issue: q.target.issue,
    branch: q.target.branch!.replace(/^refs\/heads\//, ""),
    trunk: q.target.baseRef,
    commit: r.commit,
    outcome: r.outcome,
    step: r.step,
    why: r.why ?? null,
    trusted: r.trusted ?? null,
    warnings: r.warnings,
    log: r.log,
  };
}

// The result's event, unless the inbox or delivered/ has it (a crash after the write, or
// one Shep already read), then the ledger's `told`, all under the ledger's lock: once, even
// when the worker and the sweep tell it at the same time.
export function tellLand(state: string, token: string): { told: boolean; reason?: string } {
  const told = new QuestionStore(state).landTold(token, (q) => {
    const name = `land-${q.id}-${q.revision}.json`;
    if (["inbox", "delivered"].some((dir) => existsSync(join(state, dir, name)))) return;
    const inbox = join(state, "inbox");
    mkdirSync(inbox, { recursive: true, mode: 0o700 });
    const tmp = join(inbox, `.${name}.${process.pid}.tmp`);
    const fd = openSync(tmp, "w", 0o600);
    try {
      writeFileSync(fd, `${JSON.stringify(landEvent(q))}\n`);
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, join(inbox, name));
  });
  return told.accepted ? { told: true } : { told: false, reason: told.reason };
}

// Shep's timer, beside the defaults: each Ship it with no claim and no live worker gets a
// new one; each claimed chain whose worker is gone without a result ends `unknown`; each
// result not yet told is told. A worker hc cannot answer for is left until next time.
export function sweepLand(state: string): string[] {
  const store = new QuestionStore(state);
  const done: string[] = [];
  let failed: unknown = null;
  for (const q of store.snapshot().questions.filter((x) => x.kind === "land" && shipped(x))) {
    const token = tokenOf(q);
    const l = q.landing;
    try {
      if (!l?.claim) {
        if (l?.starts.length && terminalState(landTerminal(q)) !== "gone") continue;
        if (startLand(state, token).started) done.push(`${token} started`);
      } else if (!l.result) {
        if (terminalState(landTerminal(q)) !== "gone") continue;
        const ended = store.landResult(token, {
          outcome: "unknown",
          commit: null,
          why: `its worker ${landTerminal(q)} ended before it recorded a result; the log and its last step say how far it got`,
          warnings: [],
          log: join(state, "..", "land", `${q.id}-${q.revision}.log`),
        });
        if (ended.accepted) done.push(`${token} unknown`);
      }
      const now = store.snapshot().questions.find((x) => tokenOf(x) === token)!;
      if (now.landing?.result && !now.landing.result.told && tellLand(state, token).told) done.push(`${token} told`);
    } catch (error) {
      failed ??= error;
    }
  }
  if (failed) throw failed;
  return done;
}
