// Trails as jobs: in an Entire repo the job is a trail, named trail:<n> wherever
// a beads id goes. The trail holds the ask; this machine keeps the rest, which
// the trail cannot hold (`entire trail update` has no metadata flag): the job
// record (desk, session, pid), the same fields as beads' bercail_task, and the
// job's comments (the handoff, todo links, the desk's report). Entire refuses
// trail comments from an agent session, so reports stay here.
//
//   bercail job show trail:<n> [--repo DIR] [--json]   the trail and its comments
//   bercail job comment trail:<n> [--repo DIR]         add a comment, text on stdin
//   bercail job list [--repo DIR] [--json]             the repo's open trails, with their records
//   bercail job id trail:<n> [--repo DIR]              the trail's Entire id and URL, for a question
//
// Entire has no dependency field: a line "Blocked by: #12, #15" in a trail's
// body names the trails of its project that must close or merge first.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const TRAIL = /^trail:([1-9][0-9]{0,8})$/;
export const isTrail = (id: string): boolean => TRAIL.test(id);
// The project trail's number, from trail:<n>.
export function trailNumber(id: string): string {
  const match = TRAIL.exec(id);
  if (!match) throw new Error(`${id} is not a trail job; a trail is trail:<n>, its project trail number`);
  return match[1]!;
}

function run(command: string, args: string[], cwd: string): string {
  return execFileSync(command, args, {
    cwd,
    timeout: 20000,
    env: {
      ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("GIT_"))),
      GIT_TERMINAL_PROMPT: "0",
    },
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe"],
    maxBuffer: 8 * 1024 * 1024,
  }).trim();
}

// The main checkout of the repo DIR is in: one repo, one key, from any worktree.
export function mainOf(dir: string): string {
  const first = run("git", ["worktree", "list", "--porcelain"], realpathSync(dir)).split("\n")[0]!;
  return realpathSync(first.slice("worktree ".length));
}

// entire, from the repo's main checkout so it finds the repo from origin. Its
// own message on failure: offline, logged out, or no such trail.
function entire(repo: string, args: string[]): any {
  try {
    return JSON.parse(run(process.env.ENTIRE_BIN || "entire", args, repo));
  } catch (error: any) {
    const why = String(error?.stderr || error?.message || error)
      .trim()
      .split("\n")[0];
    throw new Error(
      `entire ${args.slice(0, 3).join(" ")} failed in ${repo}: ${why} (trails need the network and the person's Entire login)`,
    );
  }
}

// The Entire project of the repo's origin: et/<project> for an Entire remote
// (entire://host/et/<project>/<repo>), gh/<owner> for GitHub.
export function trailProject(repo: string): string {
  const url = run("git", ["remote", "get-url", "origin"], repo);
  const hosted = /^entire:\/\/[^/]+\/([^/]+)\/([^/]+)\/[^/]+?(?:\.git)?\/?$/.exec(url);
  if (hosted) return `${hosted[1]}/${hosted[2]}`;
  const github = /github\.com[:/]([^/]+)\/[^/]+?(?:\.git)?\/?$/.exec(url);
  if (github) return `gh/${github[1]}`;
  throw new Error(`origin of ${repo} (${url}) is neither Entire nor GitHub; no trail project`);
}

export function trailShow(repo: string, id: string): any {
  const trail = entire(repo, ["trail", "show", trailNumber(id), "--json"]);
  if (String(trail?.number) !== trailNumber(id)) throw new Error(`entire has no trail ${trailNumber(id)} for ${repo}`);
  return trail;
}

// The open trails of this repo, or with `project` every trail of its project,
// in one list call (and its pages): the board never reads a trail at a time.
// --repo keeps out the trails of the project's other repos; the project list,
// read only for blockers, has the closed ones too.
export function repoTrails(repo: string, project = false): any[] {
  const scope = project ? [] : ["--repo", run("git", ["remote", "get-url", "origin"], repo), "--status", "open"];
  const items: any[] = [];
  let token = "";
  for (let page = 0; page < 20; page++) {
    const out = entire(repo, [
      "trail",
      "list",
      "--project",
      trailProject(repo),
      ...scope,
      "--limit",
      "100",
      "--json",
      ...(token ? ["--page-token", token] : []),
    ]);
    // An answer of another shape is not an empty list.
    if (!Array.isArray(out?.items)) throw new Error(`entire trail list for ${repo} returned no items array`);
    items.push(...out.items);
    if (out.nextPageToken == null) return items;
    if (typeof out.nextPageToken !== "string" || !out.nextPageToken)
      throw new Error(`entire trail list for ${repo} returned a page token that is not one`);
    token = out.nextPageToken;
  }
  throw new Error(`more than 2000 trails in ${trailProject(repo)}; the list is cut`);
}

// The trail numbers a body's "Blocked by:" lines name, and the first line that
// is not a list of #N.
export function blockedBy(body: string): { numbers: string[]; malformed: string | null } {
  const numbers: string[] = [];
  let malformed: string | null = null;
  for (const line of body.split("\n").filter((l) => /^\s*blocked by\s*:/i.test(l))) {
    const items = line
      .replace(/^\s*blocked by\s*:/i, "")
      .split(",")
      .map((item) => item.trim());
    if (items.every((item) => /^#[1-9][0-9]{0,8}$/.test(item))) numbers.push(...items.map((item) => item.slice(1)));
    else malformed ??= line.trim();
  }
  return { numbers: [...new Set(numbers)], malformed };
}

// Blockers of `trails` that `known` (the repo's trails, by number) lacks are
// another repo's in the project, or no trail: one project-wide list adds those
// it has, however many blockers there are.
export function knowBlockers(repo: string, trails: any[], known: Map<string, any>): void {
  if (trails.every((t) => blockedBy(t.body || "").numbers.every((n) => known.has(n)))) return;
  for (const t of repoTrails(repo, true)) if (!known.has(String(t.number))) known.set(String(t.number), t);
}

// What a trail still waits on: each blocker that is neither closed nor merged
// (phase complete), or that `known` (after knowBlockers) does not have, and a
// line that cannot be read. Empty is ready.
export function waitingOn(trail: any, known: Map<string, any>): string[] {
  const { numbers, malformed } = blockedBy(trail.body || "");
  const waiting: string[] = [];
  for (const n of numbers) {
    const blocker = known.get(n);
    if (!blocker) waiting.push(`#${n} (no such trail)`);
    else if (blocker.status !== "closed" && blocker.phase !== "complete") waiting.push(`#${n}`);
  }
  if (malformed) waiting.push(`an unreadable line: ${malformed} (write it as Blocked by: #12, #15)`);
  return waiting;
}

// The trail, if it is one of this checkout's repo: the same number in another
// repo of the project is another job.
export function ownTrail(repo: string, id: string): any {
  const trail = trailShow(repo, id);
  const mine = entire(repo, ["repo", "view", "--json"])?.id;
  if (!mine || !Array.isArray(trail.repoIds) || !trail.repoIds.includes(mine))
    throw new Error(`${id} is not a trail of ${repo}; use the checkout of the repo it belongs to`);
  return trail;
}

// What one trail waits on, read only when its body names blockers: the repo's
// open trails first, the project's only for a blocker they lack.
export function trailWaits(repo: string, trail: any): string[] {
  if (!/^\s*blocked by\s*:/im.test(trail.body || "")) return [];
  const known = new Map<string, any>(repoTrails(repo).map((t: any) => [String(t.number), t]));
  knowBlockers(repo, [trail], known);
  return waitingOn(trail, known);
}

// ~/.local/state/bercail/jobs/<repo-key>/: the repo's folder name and a hash
// of its main checkout's path, so two clones never share records.
export function jobDir(repo: string): string {
  const state = process.env.XDG_STATE_HOME || join(process.env.HOME!, ".local/state");
  const key = `${basename(repo)}-${createHash("sha256").update(repo).digest("hex").slice(0, 12)}`;
  return join(state, "bercail/jobs", key);
}
const recordFile = (repo: string, id: string) => join(jobDir(repo), `${trailNumber(id)}.json`);
const commentsFile = (repo: string, id: string) => join(jobDir(repo), `${trailNumber(id)}.comments.jsonl`);

// The job record: bercail_task's fields, or null before the first dispatch.
export function readRecord(repo: string, id: string): any {
  const file = recordFile(repo, id);
  return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : null;
}

// Replace the record whole, by rename, so a reader never sees half of it.
// Dispatch holds the repo's lock around its read and write.
export function writeRecord(repo: string, id: string, record: any): void {
  const file = recordFile(repo, id);
  mkdirSync(jobDir(repo), { recursive: true, mode: 0o700 });
  writeFileSync(`${file}.tmp`, JSON.stringify(record) + "\n", { mode: 0o600 });
  renameSync(`${file}.tmp`, file);
}

// Every record of the repo, as {id, record}.
export function records(repo: string): { id: string; record: any }[] {
  const dir = jobDir(repo);
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => /^[1-9][0-9]*\.json$/.test(f))
    .map((f) => ({ id: `trail:${f.slice(0, -5)}`, record: JSON.parse(readFileSync(join(dir, f), "utf8")) }));
}

// Comments as bd prints them: {text, author, created_at}, oldest first.
export function comments(repo: string, id: string): any[] {
  const file = commentsFile(repo, id);
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

// One line, appended: a comment never rewrites another.
export function addComment(repo: string, id: string, text: string): any {
  if (!text.trim()) throw new Error("the comment is empty; pass its text on stdin");
  let author = process.env.USER || "?";
  try {
    author = run("git", ["config", "user.name"], repo) || author;
  } catch {}
  const comment = { text: text.replace(/\s+$/, ""), author, created_at: new Date().toISOString() };
  mkdirSync(jobDir(repo), { recursive: true, mode: 0o700 });
  appendFileSync(commentsFile(repo, id), JSON.stringify(comment) + "\n", { mode: 0o600 });
  return comment;
}

// The trail as a job, in bd show's shape where they meet: id, title, status,
// priority, issue_type; and phase, url, body, changes, the record and the comments.
export function job(repo: string, id: string): any {
  const trail = ownTrail(repo, id);
  const { numbers } = blockedBy(trail.body || "");
  return {
    id,
    title: trail.title || "",
    status: trail.status,
    phase: trail.phase,
    priority: trail.priority,
    issue_type: trail.type,
    // Entire's ID for the trail: the same number in another project is another trail.
    trail_id: trail.id,
    url: trail.url,
    body: trail.body || "",
    blocked_by: numbers.map((n) => `#${n}`),
    waiting_on: trailWaits(repo, trail),
    changes: (trail.changes || []).map((c: any) => ({
      change: `${c.repository}/${c.number}`,
      branch: c.branch,
      base: c.base,
      status: c.status,
      url: c.url,
    })),
    record: readRecord(repo, id),
    comments: comments(repo, id),
  };
}

function showText(value: any): string {
  const changes = value.changes.map((c: any) => `- change ${c.change}: ${c.branch} into ${c.base}, ${c.status}`);
  const notes = value.comments.map((c: any) => `--- ${c.author} at ${c.created_at}\n${c.text}`);
  const deps = value.waiting_on.length
    ? [`blocked: waits on ${value.waiting_on.join(", ")}`]
    : value.blocked_by.length
      ? [`ready: ${value.blocked_by.join(", ")} closed or merged`]
      : [];
  return [
    `${value.id}: ${value.title}`,
    [value.status, value.phase, value.issue_type, value.priority && `priority ${value.priority}`, value.url]
      .filter(Boolean)
      .join(" · "),
    ...deps,
    "",
    value.body || "(no body)",
    ...(changes.length ? ["", "Changes:", ...changes] : []),
    "",
    notes.length
      ? `Comments on this machine (${notes.length}):`
      : `No comments on this machine yet. Add one with: bercail job comment ${value.id} <<'EOF'`,
    ...notes,
    "",
    `People's discussion on Entire: entire trail comment list --trail ${value.id.slice(6)}`,
  ].join("\n");
}

export function jobCommand(argv: string[], stdin: () => string): string {
  const [op, ...rest] = argv;
  let id = "";
  let dir = process.cwd();
  let json = false;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "--repo") dir = rest[++i] || "";
    else if (rest[i]?.startsWith("--repo=")) dir = rest[i]!.slice(7);
    else if (rest[i] === "--json") json = true;
    else if (!id && !rest[i]!.startsWith("-")) id = rest[i]!;
    else throw new Error(USAGE);
  }
  let repo: string;
  try {
    repo = mainOf(resolve(dir));
  } catch {
    throw new Error(`${dir} is not a git checkout; pass the trail's repo with --repo`);
  }
  if (op === "list" && !id) {
    const mine = new Map(records(repo).map((r) => [r.id, r.record]));
    const all = repoTrails(repo);
    const known = new Map<string, any>(all.map((t: any) => [String(t.number), t]));
    const open = all.filter((t: any) => t.status === "open");
    knowBlockers(repo, open, known);
    const trails = open.map((t: any) => ({
      id: `trail:${t.number}`,
      title: t.title || "",
      status: t.status,
      phase: t.phase,
      priority: t.priority,
      issue_type: t.type,
      waiting_on: waitingOn(t, known),
      record: mine.get(`trail:${t.number}`) ?? null,
    }));
    return json
      ? JSON.stringify(trails)
      : trails
          .map(
            (t) =>
              `${t.id}: ${t.title} · ${t.phase} · ${t.waiting_on.length ? `blocked by ${t.waiting_on.join(", ")}` : "ready"}` +
              (t.record ? " · dispatched" : ""),
          )
          .join("\n") || "no open trails";
  }
  if (!id) throw new Error(USAGE);
  trailNumber(id);
  if (op === "show") {
    const value = job(repo, id);
    return json ? JSON.stringify(value) : showText(value);
  }
  // Who the trail is, project-wide: a question binds to its Entire id, and
  // links its page, whichever repo of the project it is scoped to.
  if (op === "id") {
    const trail = trailShow(repo, id);
    return JSON.stringify({ id, trail_id: trail.id, url: trail.url });
  }
  if (op === "comment" && !json) {
    // The trail must be this repo's: a comment never points at a trail that is not.
    ownTrail(repo, id);
    addComment(repo, id, stdin());
    return `commented on ${id} (on this machine; bercail job show ${id} --repo ${repo})`;
  }
  throw new Error(USAGE);
}

const USAGE =
  "usage: bercail job show trail:<n> [--repo DIR] [--json] | comment trail:<n> [--repo DIR] (text on stdin) | list [--repo DIR] [--json] | id trail:<n> [--repo DIR]";

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    console.log(jobCommand(process.argv.slice(2), () => readFileSync(0, "utf8")));
  } catch (error) {
    console.error(`bercail job: ${(error as Error).message}`);
    process.exitCode = 1;
  }
}
