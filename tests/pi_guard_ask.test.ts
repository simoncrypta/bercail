// Shep's guard asks (docs/plans/shep-free-guard.md): which command is one operation the
// guard can hand off, and what it pins. Real git in a temp HOME; entire is a stand-in.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import guard, {
  argvText,
  changedFacts,
  guardDefault,
  guardOperation,
  markStart,
  opTarget,
  opWhat,
  pinOperation,
  runOf,
  type GuardFacts,
  type Read,
} from "../bstack/pi/extensions/guard.ts";

let dir: string;
let repo: string;
let origin: string;
const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
const op = (command: string, cwd = "/nowhere") => {
  const got = guardOperation(command, cwd, dir);
  if (typeof got === "string") throw new Error(`${command}: ${got}`);
  return got;
};
const pin = (command: string, cwd?: string) => pinOperation(op(command, cwd));
// The trail entire trail show prints: changes with their state, head and base.
const trail = (changes: Record<string, unknown>[]) =>
  writeFileSync(join(dir, "trail.json"), JSON.stringify({ id: "01TRAIL", number: 41, changes }));
const change = (number: number, extra: Record<string, unknown> = {}) => ({
  repository: "app",
  number,
  status: "open",
  base: "main",
  current: null,
  mergeability: { head_sha: "f".repeat(40) },
  ...extra,
});

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), "guard-ask-")));
  for (const key of Object.keys(process.env)) if (/^(GIT_|BERCAIL_|HC_)/.test(key)) vi.stubEnv(key, undefined);
  vi.stubEnv("HOME", dir);
  vi.stubEnv("XDG_CONFIG_HOME", join(dir, "config"));
  vi.stubEnv("GIT_CONFIG_NOSYSTEM", "1");
  vi.stubEnv("GIT_AUTHOR_NAME", "Test");
  vi.stubEnv("GIT_COMMITTER_NAME", "Test");
  vi.stubEnv("GIT_AUTHOR_EMAIL", "test@example.invalid");
  vi.stubEnv("GIT_COMMITTER_EMAIL", "test@example.invalid");
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(
    join(bin, "entire"),
    `#!/bin/sh\nprintf '%s|%s\\n' "$PWD" "$*" >> '${dir}/entire.argv'\ncat '${dir}/trail.json'\n`,
    { mode: 0o755 },
  );
  vi.stubEnv("ENTIRE_BIN", join(bin, "entire"));
  writeFileSync(
    join(bin, "bd"),
    // As bd resolves its store: BEADS_DIR, else the folder's own .beads.
    `#!/bin/sh\nprintf '%s|%s\\n' "$PWD" "$*" >> '${dir}/bd.argv'\n` +
      `[ "$1" = context ] && { printf '{"beads_dir":"%s"}\\n' "\${BEADS_DIR:-$PWD/.beads}"; exit; }\n` +
      `cat '${dir}/comments.json'\n`,
    { mode: 0o755 },
  );
  vi.stubEnv("HANDOFF_BD_BIN", join(bin, "bd"));
  repo = join(dir, "repo");
  origin = join(dir, "origin.git");
  execFileSync("git", ["init", "-q", "-b", "main", repo]);
  execFileSync("git", ["init", "-q", "--bare", origin]);
  git("commit", "-q", "--allow-empty", "-m", "one");
  git("branch", "feature");
  git("remote", "add", "origin", origin);
});
afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

test("a push pins its checkout, the remote's URL and each commit to its full branch", async () => {
  const head = git("rev-parse", "HEAD");
  const facts = {
    kind: "push",
    dir: repo,
    gitDir: join(repo, ".git"),
    url: origin,
    refspecs: [`${head}:refs/heads/feature`],
  };
  expect(await pin(`git -C ${repo} push origin feature`)).toStrictEqual(facts);
  // The folder a cd names, a relative -C, and each way a refspec names its branch.
  expect(await pin(`cd ${repo} && git push origin feature`)).toStrictEqual(facts);
  expect(await pin("git -C repo push origin feature", dir)).toStrictEqual(facts);
  expect(
    await pin(`git -C ${repo} push origin HEAD feature:refs/heads/other ${head}^{commit}:refs/heads/third`),
  ).toMatchObject({
    refspecs: [`${head}:refs/heads/main`, `${head}:refs/heads/other`, `${head}:refs/heads/third`],
  });
});

// A restack a desk prepared (bercail-i5dx): origin has feature at the old head, and the
// handoff that started the desk names the checkout on feature, which it rewrote.
const handoff = (fields: Record<string, unknown> = {}) =>
  JSON.stringify({
    at: "2026-11-24T10:00:00Z",
    ok: true,
    agent_started: true,
    desk: "t1",
    path: repo,
    repo,
    branch: "feature",
    ...fields,
  });
const journal = (name: string, ...lines: string[]) =>
  writeFileSync(join(dir, "state/bercail", name), lines.map((line) => `${line}\n`).join(""));
const restack = () => {
  git("push", "-q", "origin", "main", "feature");
  execFileSync("git", ["-C", origin, "symbolic-ref", "HEAD", "refs/heads/main"]);
  vi.stubEnv("XDG_STATE_HOME", join(dir, "state"));
  mkdirSync(join(dir, "state/bercail"), { recursive: true });
  journal("handoffs.jsonl", handoff());
  const old = git("rev-parse", "feature");
  git("checkout", "-q", "feature");
  git("commit", "-q", "--amend", "--allow-empty", "-m", "restacked");
  return { old, head: git("rev-parse", "HEAD") };
};
const leasePush = (old: string, head: string, branch = "feature") =>
  `git -C ${repo} push --force-with-lease=refs/heads/${branch}:${old} origin ${head}:refs/heads/${branch}`;

test("a restack's lease push pins both heads to the desk's own branch, runs leased, and never defaults", async () => {
  const { old, head } = restack();
  const lease = { ref: "refs/heads/feature", old };
  const facts = await pin(leasePush(old, head));
  expect(facts).toStrictEqual({
    kind: "push",
    dir: repo,
    gitDir: join(repo, ".git"),
    url: origin,
    refspecs: [`${head}:refs/heads/feature`],
    lease,
  });
  const { argv } = runOf(facts);
  expect(argv).toStrictEqual([
    "git",
    "-C",
    repo,
    "push",
    "--no-follow-tags",
    "--recurse-submodules=no",
    `--force-with-lease=refs/heads/feature:${old}`,
    origin,
    `${head}^{commit}:refs/heads/feature`,
  ]);
  expect(opWhat(facts)).toBe(`force-with-lease push of ${origin} refs/heads/feature`);
  const reversible = async (command: string) =>
    command.endsWith("bercail") ? JSON.stringify({ policy: { merge_reversible: true } }) : origin;
  expect(await guardDefault(facts, reversible)).toStrictEqual({
    defaults: false,
    why: "a force-with-lease push replaces the branch's history on the remote",
  });
  // Someone pushes after the last check: git's lease refuses, and their head stays.
  const theirs = git("commit-tree", "-m", "theirs", `${old}^{tree}`);
  git("push", "-q", "origin", `${theirs}:refs/heads/feature`, "--force");
  expect(() => execFileSync(argv[0], argv.slice(1), { stdio: "pipe" })).toThrow(/stale info/);
  expect(execFileSync("git", ["-C", origin, "rev-parse", "feature"], { encoding: "utf8" }).trim()).toBe(theirs);
});

test.each([
  ["a lease on another branch", (old: string, head: string) => leasePush(old, head).replace(/feature$/, "x")],
  ["a short old head", (old: string, head: string) => leasePush(old.slice(0, 12), head)],
  ["a short ref in the lease", (old: string, head: string) => leasePush(old, head).replace("=refs/heads/", "=")],
  ["a new head by name", (old: string) => leasePush(old, "HEAD")],
  ["two refspecs", (old: string, head: string) => `${leasePush(old, head)} ${head}:refs/heads/y`],
  [
    "the lease after the remote",
    (old: string, head: string) => leasePush(old, head).replace(/(--force\S+) origin/, "origin $1"),
  ],
  ["no -C", (old: string, head: string) => leasePush(old, head).replace(`-C ${repo} `, "")],
  ["a relative -C", (old: string, head: string) => leasePush(old, head).replace(`-C ${repo}`, "-C repo")],
  ["a cd", (old: string, head: string) => `cd ${dir} && ${leasePush(old, head)}`],
] as const)("a lease push with %s is no operation the guard hands off", (_name, command) => {
  const [old, head] = ["a".repeat(40), "b".repeat(40)];
  expect(guardOperation(command(old, head), dir, dir)).toMatch(/no flags|git -C <absolute path>/);
});

test.each([
  [
    "no desk's handoff",
    () => rmSync(join(dir, "state/bercail/handoffs.jsonl")),
    /no desk's handoff names .* on feature/,
  ],
  [
    "a handoff on another branch",
    () => journal("handoffs.jsonl", handoff({ branch: "other" })),
    /no desk's handoff names/,
  ],
  [
    "a handoff of another repo",
    () => journal("handoffs.jsonl", handoff({ repo: origin })),
    /names the repo .*, not this checkout's/,
  ],
  [
    "a handoff whose repo is gone",
    () => journal("handoffs.jsonl", handoff({ repo: join(dir, "gone") })),
    /names the repo/,
  ],
  [
    "only a spawn that never started a desk",
    () => journal("handoffs.jsonl", handoff({ ok: false, agent_started: false })),
    /no desk's handoff names/,
  ],
  [
    "a desk whose checkout cleanup retired",
    () => journal("retired.jsonl", JSON.stringify({ v: 1, at: "2026-11-24T11:00:00Z", path: repo })),
    /bercail cleanup retired .* after its desk started/,
  ],
  [
    "a retirement in the second its desk started",
    () => journal("retired.jsonl", JSON.stringify({ v: 1, at: "2026-11-24T10:00:00Z", path: repo })),
    /bercail cleanup retired/,
  ],
  [
    "a later spawn that failed on another branch",
    () => journal("handoffs.jsonl", handoff(), handoff({ at: "2026-11-24T12:00:00Z", ok: false, branch: "other" })),
    null,
  ],
  [
    "a checkout reused by a new desk after a retirement",
    () => {
      journal("retired.jsonl", JSON.stringify({ v: 1, at: "2026-11-24T09:00:00Z", path: repo }));
      journal("handoffs.jsonl", handoff({ at: "2026-11-24T08:00:00Z", branch: "old" }), handoff());
    },
    null,
  ],
  ["a checkout on another branch", () => git("checkout", "-q", "main"), /is not on feature/],
  [
    "a desk that committed since",
    () => git("commit", "-q", "--allow-empty", "-m", "three"),
    /feature is at [0-9a-f]{40} in .*, not/,
  ],
  [
    "a remote whose default branch it is",
    () => execFileSync("git", ["-C", origin, "symbolic-ref", "HEAD", "refs/heads/feature"]),
    /feature is the default branch of /,
  ],
  [
    "a remote whose default branch it cannot read",
    () => execFileSync("git", ["-C", origin, "symbolic-ref", "HEAD", "refs/heads/unborn"]),
    /cannot read the default branch of /,
  ],
  [
    "a remote someone pushed to since",
    () =>
      git("push", "-q", "--force", "origin", `${git("commit-tree", "-m", "theirs", "HEAD^{tree}")}:refs/heads/feature`),
    /feature is at [0-9a-f]{40} on .*, not the old head/,
  ],
])("a lease push with %s: pins only where no reason is named", async (_name, change, why) => {
  const { old, head } = restack();
  change();
  if (why) await expect(pin(leasePush(old, head))).rejects.toThrow(why);
  else await expect(pin(leasePush(old, head))).resolves.toMatchObject({ lease: { old } });
});

test("a desk's linked worktree pins its lease push: the handoff names the main checkout as its repo", async () => {
  restack();
  const worktree = join(dir, "repo.topic");
  git("worktree", "add", "-q", "-b", "topic", worktree, "main");
  git("push", "-q", "origin", "topic");
  const old = git("rev-parse", "topic");
  execFileSync("git", ["-C", worktree, "commit", "-q", "--amend", "--allow-empty", "-m", "restacked"]);
  const head = execFileSync("git", ["-C", worktree, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  journal("handoffs.jsonl", handoff({ path: worktree, repo, branch: "topic" }));
  const command = `git -C ${worktree} push --force-with-lease=refs/heads/topic:${old} origin ${head}:refs/heads/topic`;
  expect(await pin(command)).toMatchObject({ dir: worktree, lease: { ref: "refs/heads/topic", old } });
  journal("handoffs.jsonl", handoff({ path: worktree, repo: worktree, branch: "topic" }));
  await expect(pin(command)).rejects.toThrow(/names the repo .*repo\.topic, not this checkout's .*repo$/);
});

test("a desk's repo is read whole when its main checkout's path holds a newline", async () => {
  restack();
  const main = join(dir, "x\ny");
  const run = (cwd: string, ...args: string[]) =>
    execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
  execFileSync("git", ["init", "-q", "-b", "main", main]);
  execFileSync("git", ["init", "-q", join(dir, "x")]);
  run(main, "commit", "-q", "--allow-empty", "-m", "one");
  run(main, "remote", "add", "origin", origin);
  run(main, "push", "-q", "origin", "main:refs/heads/side");
  const worktree = join(dir, "side");
  run(main, "worktree", "add", "-q", "-b", "side", worktree);
  const old = run(worktree, "rev-parse", "HEAD");
  run(worktree, "commit", "-q", "--amend", "--allow-empty", "-m", "restacked");
  const head = run(worktree, "rev-parse", "HEAD");
  const command = `git -C ${worktree} push --force-with-lease=refs/heads/side:${old} origin ${head}:refs/heads/side`;
  journal("handoffs.jsonl", handoff({ path: worktree, repo: main, branch: "side" }));
  expect(await pin(command)).toMatchObject({ dir: worktree, lease: { old } });
  // The path's first line is another repo: not this checkout's.
  journal("handoffs.jsonl", handoff({ path: worktree, repo: join(dir, "x"), branch: "side" }));
  await expect(pin(command)).rejects.toThrow(/names the repo/);
});

test("a lease push of main, over a null old head, of a tag's hash, or from a subfolder does not pin", async () => {
  const { old, head } = restack();
  await expect(pin(leasePush("0".repeat(40), head))).rejects.toThrow(/on .*, not the old head 0{40}/);
  git("branch", "-f", "main", head);
  git("checkout", "-q", "main");
  await expect(pin(leasePush(old, head, "main"))).rejects.toThrow(/force push to main or master is blocked/);
  git("checkout", "-q", "feature");
  git("tag", "-a", "-m", "t", "t1");
  await expect(pin(leasePush(old, git("rev-parse", "t1")))).rejects.toThrow(/is not a commit's full hash/);
  mkdirSync(join(repo, "sub"));
  await expect(pin(leasePush(old, head).replace(`-C ${repo}`, `-C ${repo}/sub`))).rejects.toThrow(
    /sub is not the worktree's top folder/,
  );
});

test("a cleanup pins the worktree's real path, branch and HEAD; a trail merge, its one change", async () => {
  const worktree = join(dir, "repo.topic");
  git("worktree", "add", "-q", worktree, "feature");
  symlinkSync(worktree, join(dir, "link"));
  expect(await pin(`bercail cleanup ${join(dir, "link")}`)).toStrictEqual({
    kind: "cleanup",
    worktree,
    branch: "refs/heads/feature",
    head: git("rev-parse", "HEAD"),
  });
  const merged = {
    kind: "trail merge",
    checkout: repo,
    trailId: "01TRAIL",
    change: "app/7",
    head: "f".repeat(40),
    base: "main",
  };
  // A project trail's one open change, among closed and merged ones.
  trail([change(6, { status: "merged" }), change(7)]);
  expect(await pin(`cd ${repo} && entire trail merge 41`)).toStrictEqual(merged);
  // Through a change, or the branch: the change show says it came through.
  trail([change(6), change(7, { current: true })]);
  expect(await pin(`cd ${repo} && entire trail merge app/7`)).toStrictEqual(merged);
  expect(await pin(`cd ${repo} && entire trail merge`)).toStrictEqual(merged);
  // From a linked worktree: entire reads its branch's change there, and it merges in the main checkout.
  expect(await pin(`cd ${worktree} && entire trail merge`)).toStrictEqual(merged);
  expect(readFileSync(join(dir, "entire.argv"), "utf8").trim().split("\n").at(-1)).toBe(
    `${worktree}|trail show --json`,
  );
});

// A handoffs.jsonl line per handoff, as handoff-spawn writes them, under $XDG_STATE_HOME.
const handoffs = (...lines: (Record<string, unknown> | string)[]) => {
  mkdirSync(join(dir, "state/bercail"), { recursive: true });
  writeFileSync(
    join(dir, "state/bercail/handoffs.jsonl"),
    lines.map((line) => (typeof line === "string" ? line : JSON.stringify(line))).join("\n") + "\n",
  );
};

test("a cleanup --gone pins the path, its handoffs' one repo, the last one's branch and their count, and its worker runs bercail cleanup --gone on it", async () => {
  vi.stubEnv("XDG_STATE_HOME", join(dir, "state"));
  const gone = join(dir, "repo.gone");
  symlinkSync(repo, join(dir, "link"));
  const lines = [
    { path: gone, repo: join(dir, "link"), branch: "old" },
    "",
    { path: join(dir, "other"), repo: "/elsewhere", branch: "main" },
    { path: gone, repo: join(dir, "link"), branch: "feature" },
  ];
  handoffs(...lines);
  const facts = { kind: "cleanup", gone: true, path: gone, repo, branch: "feature", handoffs: 2 } as const;
  // As dispatch names it: the path in single quotes.
  const gonePath = op(`bercail cleanup --gone '${gone}'`);
  expect(gonePath).toStrictEqual({ kind: "cleanup", path: gone, gone: true });
  expect(await pinOperation(gonePath)).toStrictEqual(facts);
  expect(runOf(facts)).toStrictEqual({ argv: ["bercail", "cleanup", "--gone", gone], cwd: "/" });
  expect(opTarget(facts)).toBe(gone);
  // A later handoff at that path, of the same repo and branch, moves what a card named.
  handoffs(...lines, { path: gone, repo: join(dir, "link"), branch: "feature" });
  expect(changedFacts(facts, await pinOperation(gonePath))).toStrictEqual(["handoffs changed"]);
});

// The comments bd prints for an issue, as handoff-spawn left them.
const comments = (...texts: string[]) =>
  writeFileSync(join(dir, "comments.json"), JSON.stringify(texts.map((text) => ({ issue_id: "bc-1", text }))));

// A handoff from before records carried repo: worktrunk put its checkout beside the main one,
// and handoff-spawn said so on the job's issue in that repo's beads.
test("a cleanup --gone of a handoff with no repo pins the main checkout its path is <repo>.<branch> of, once the issue there names the checkout", async () => {
  vi.stubEnv("XDG_STATE_HOME", join(dir, "state"));
  const gone = join(dir, "repo.simon-topic");
  comments(
    "started",
    `bercail handoff: stage bstack, desk agent pi, linked worktree ${gone} (branch simon/topic). Stay.`,
  );
  handoffs(
    { path: gone, repo: null, branch: "simon/topic", issue: "bc-1" },
    { path: gone, branch: "simon/topic", issue: "bc-1" },
  );
  expect(await pin(`bercail cleanup --gone ${gone}`)).toStrictEqual({
    kind: "cleanup",
    gone: true,
    path: gone,
    repo,
    branch: "simon/topic",
    handoffs: 2,
  });
  expect(readFileSync(join(dir, "bd.argv"), "utf8").trim().split("\n")).toStrictEqual([
    `${repo}|context --json --readonly`,
    `${repo}|comments bc-1 --json --readonly`,
    `${repo}|comments bc-1 --json --readonly`,
  ]);
  // Beside a later handoff that names the repo, it is of that one repo.
  handoffs({ path: gone, branch: "simon/topic", issue: "bc-1" }, { path: gone, repo, branch: "simon/topic" });
  expect(await pin(`bercail cleanup --gone ${gone}`)).toMatchObject({ repo, handoffs: 2 });
});

test.each([
  ["no issue", { branch: "feature" }, () => {}, /names no repo and no issue/],
  ["an issue that reads as a flag", { branch: "feature", issue: "--db=x" }, () => {}, /names no repo and no issue/],
  // A path of another layout can share a repo's prefix; that repo's beads never saw it.
  [
    "an issue whose comments there name no checkout",
    { branch: "feature", issue: "bc-1" },
    () => comments("started"),
    /no comment on bc-1 in .*repo's beads says "linked worktree .*repo\.feature \(branch feature\)"/,
  ],
  [
    "an issue whose comment names another checkout",
    { branch: "feature", issue: "bc-1" },
    () => comments(`bercail handoff: stage bstack, linked worktree ${join(dir, "repo.feature2")} (branch feature)`),
    /no comment on bc-1/,
  ],
  // A note that quotes the path is not the handoff that made the checkout.
  [
    "an issue whose only mention of the checkout is not a handoff's",
    { branch: "feature", issue: "bc-1" },
    () => comments(`saw linked worktree ${join(dir, "repo.feature")} (branch feature) go`),
    /no comment on bc-1/,
  ],
  // The comment is right, but bd read it from another repo's store.
  [
    "a bd that reads another store",
    { branch: "feature", issue: "bc-1" },
    () => {
      comments(`bercail handoff: stage bstack, linked worktree ${join(dir, "repo.feature")} (branch feature).`);
      vi.stubEnv("BEADS_DIR", join(dir, "other/.beads"));
    },
    /bd in .*repo reads another store than .*repo\/\.beads/,
  ],
  ["an issue bd cannot read", { branch: "feature", issue: "bc-1" }, () => {}, /comments\.json/],
  // A bare repo lists itself first, as a main checkout does, and has no top folder.
  [
    "a prefix that is a bare repo",
    { branch: "feature", issue: "bc-1" },
    () => {
      rmSync(repo, { recursive: true });
      execFileSync("git", ["init", "-q", "--bare", repo]);
    },
    /must be run in a work tree/,
  ],
])("a cleanup --gone of a handoff with no repo and %s does not pin", async (_name, handoff, setup, why) => {
  vi.stubEnv("XDG_STATE_HOME", join(dir, "state"));
  const gone = join(dir, "repo.feature");
  handoffs({ path: gone, ...handoff });
  setup();
  await expect(pin(`bercail cleanup --gone ${gone}`)).rejects.toThrow(why);
});

test.each([
  ["a path that is still there", () => mkdirSync(join(dir, "repo.gone")), /repo\.gone is still there/],
  ["a path no handoff names", () => handoffs({ path: join(dir, "other"), repo }), /no handoff names/],
  ["a handoff with no repo or branch", () => handoffs({ path: join(dir, "repo.gone") }), /name no one repo/],
  [
    "a handoff with no repo whose path is not <repo>.<branch>",
    () => handoffs({ path: join(dir, "repo.gone"), branch: "feature" }),
    /name no one repo/,
  ],
  [
    "a handoff with no repo whose path is <branch> alone",
    () => {
      handoffs({ path: join(dir, ".feature"), branch: "feature" });
      return join(dir, ".feature");
    },
    /name no one repo/,
  ],
  // The folder its path names is a linked worktree, not the main checkout handoff-spawn records.
  [
    "a handoff with no repo whose path names a linked worktree",
    () => {
      git("worktree", "add", "-q", join(dir, "repo.other"), "feature");
      handoffs({ path: join(dir, "repo.other.gone"), branch: "gone" });
      return join(dir, "repo.other.gone");
    },
    /name .*repo\.other, which is not a repo's main checkout/,
  ],
  // Dispatch retires every handoff at the path: one repo's policy cannot speak for another's.
  [
    "handoffs of two repos",
    () => handoffs({ path: join(dir, "repo.gone"), repo: "/elsewhere" }, { path: join(dir, "repo.gone"), repo }),
    /name no one repo/,
  ],
  [
    "an earlier handoff with no repo",
    () => handoffs({ path: join(dir, "repo.gone") }, { path: join(dir, "repo.gone"), repo }),
    /name no one repo/,
  ],
  [
    "a ledger with a line that is not JSON",
    () => handoffs("", "not json", { path: join(dir, "repo.gone"), repo }),
    /handoffs.jsonl line 2 is not a JSON object/,
  ],
  // jq's select cannot read a string's .path, so bercail cleanup --gone would fail on it.
  [
    "a ledger with a line that is not an object",
    () => handoffs({ path: join(dir, "repo.gone"), repo }, '"text"'),
    /handoffs.jsonl line 2 is not a JSON object/,
  ],
  [
    "a relative XDG_STATE_HOME, which bercail reads from /",
    () => {
      vi.stubEnv("XDG_STATE_HOME", "state");
      vi.stubEnv("HOME", dir);
    },
    /state folder .* not an absolute path/,
  ],
  [
    "an XDG_STATE_HOME with ..",
    () => {
      vi.stubEnv("XDG_STATE_HOME", `${dir}/state/bercail/..`);
    },
    /state folder .* without \.\./,
  ],
  [
    "a handoff whose branch is not text",
    () => handoffs({ path: join(dir, "repo.gone"), repo, branch: 7 }),
    /branch that is not text/,
  ],
  [
    "a path in a folder it cannot read",
    () => {
      mkdirSync(join(dir, "locked"));
      handoffs({ path: join(dir, "locked/repo.gone"), repo });
      chmodSync(join(dir, "locked"), 0);
      return join(dir, "locked/repo.gone");
    },
    /EACCES/,
  ],
  [
    "a handoff whose repo is a folder inside one",
    () => {
      mkdirSync(join(repo, "sub"));
      handoffs({ path: join(dir, "repo.gone"), repo: join(repo, "sub") });
    },
    /not a repo's top folder/,
  ],
  [
    "a checkout git still lists as a worktree",
    () => {
      git("worktree", "add", "-q", join(dir, "repo.gone"), "feature");
      rmSync(join(dir, "repo.gone"), { recursive: true });
    },
    /git still lists .*repo\.gone as a worktree; run git -C .* worktree prune first/,
  ],
])("a cleanup --gone of %s does not pin", async (_name, setup, why) => {
  vi.stubEnv("XDG_STATE_HOME", join(dir, "state"));
  handoffs({ path: join(dir, "repo.gone"), repo });
  const path = setup() ?? join(dir, "repo.gone");
  try {
    await expect(pin(`bercail cleanup --gone ${path}`)).rejects.toThrow(why);
  } finally {
    if (existsSync(join(dir, "locked"))) chmodSync(join(dir, "locked"), 0o755);
  }
});

test("a trail job merge pins its trail's change as a trail merge does, and its worker runs bercail job merge on it", async () => {
  const merged = {
    kind: "trail merge",
    checkout: repo,
    trailId: "01TRAIL",
    change: "app/7",
    head: "f".repeat(40),
    base: "main",
    job: "trail:41",
  } as const;
  trail([change(6, { status: "merged" }), change(7)]);
  expect(await pin(`bercail job merge trail:41 --repo ${repo}`)).toStrictEqual(merged);
  expect(await pin(`cd ${repo} && bercail job merge trail:41`)).toStrictEqual(merged);
  // From a linked worktree it is read in the main checkout, where the worker runs it.
  const worktree = join(dir, "repo.topic");
  git("worktree", "add", "-q", worktree, "feature");
  expect(await pin(`cd ${worktree} && bercail job merge trail:41`)).toStrictEqual(merged);
  expect(readFileSync(join(dir, "entire.argv"), "utf8").trim().split("\n").at(-1)).toBe(`${repo}|trail show 41 --json`);
  expect(runOf(merged)).toStrictEqual({
    argv: ["bercail", "job", "merge", "trail:41", "--change", "app/7", "--repo", repo],
    cwd: repo,
  });
  // A change it names is read through the change, and must be its trail's.
  trail([change(6), change(7, { current: true })]);
  expect(await pin(`bercail job merge trail:41 --change app/7 --repo ${repo}`)).toStrictEqual(merged);
  await expect(pin(`bercail job merge trail:42 --change app/7 --repo ${repo}`)).rejects.toThrow(
    /app\/7 is not a change of trail:42/,
  );
  // Several open changes and none named: the person cannot tell which one the card merges.
  await expect(pin(`bercail job merge trail:41 --repo ${repo}`)).rejects.toThrow(/2 open changes; name one/);
});

test.each([
  ["a second command", (r: string) => `git -C ${r} push origin feature; true`],
  ["a pipe", (r: string) => `git -C ${r} push origin feature | cat`],
  ["two cds", (r: string) => `cd / && cd ${r} && git push origin feature`],
  ["a substitution", (r: string) => `git -C ${r} push origin $(echo feature)`],
  ["a variable", (r: string) => `git -C ${r} push $REMOTE feature`],
  ["a variable in double quotes", (r: string) => `cd ${r} && entire brain remember "see $HOME" --json`],
  ["a substitution in double quotes", (r: string) => `cd ${r} && entire brain remember "see \`id\`" --json`],
  ["a backslash", (r: string) => `cd ${r} && entire brain remember it\\'s --json`],
  ["an unclosed quote", (r: string) => `cd ${r} && entire brain remember 'see --json`],
  ["a newline in quotes", (r: string) => `cd ${r} && entire brain remember 'one\ntwo' --json`],
  ["a glob", (r: string) => `cd ${r} && entire brain remember *.md --json`],
  ["a tilde", () => "entire brain remember x --path ~/notes"],
  ["a brace expansion", (r: string) => `cd ${r} && entire brain remember {a,b} --json`],
  ["a comment", (r: string) => `cd ${r} && entire trail link 41 # note`],
  ["a background &", (r: string) => `cd ${r} && entire trail link 41 &`],
  ["an ||", (r: string) => `cd ${r} && entire trail link 41 || true`],
  ["a wrapper", (r: string) => `cd ${r} && timeout 60 entire trail link 41`],
  ["a shell", (r: string) => `cd ${r} && bash -c 'entire trail link 41'`],
  ["a shell by its path", (r: string) => `cd ${r} && /bin/sh -c 'entire trail merge 41'`],
  ["a shell script", (r: string) => `cd ${r} && sh ./publish.sh`],
  // bash's cd reads these otherwise than a path: a literal ~, HOME, an error, CDPATH.
  ["a quoted ~ cd", () => "cd '~' && entire trail link 41"],
  ["a cd --", () => "cd -- && entire trail link 41"],
  ["an empty cd", () => "cd '' && entire trail link 41"],
  ["a relative cd", () => "cd repo && entire trail link 41"],
  // The guard's checks drop an empty word, which the worker would pass.
  ["an empty argument", (r: string) => `cd ${r} && entire brain remember --path '' note`],
  ["a lone surrogate", (r: string) => `cd ${r} && entire brain remember 'a\ud800b' --json`],
  ["a bidi override", (r: string) => `cd ${r} && entire brain remember 'a\u202eb' --json`],
  ["a zero-width space", (r: string) => `cd ${r} && entire brain remember 'a\u200bb' --json`],
  ["a redirect", (r: string) => `git -C ${r} push origin feature 2>/dev/null`],
  ["a flag", (r: string) => `git -C ${r} push -q origin feature`],
  ["an env prefix", (r: string) => `GIT_SSH_COMMAND=ssh git -C ${r} push origin feature`],
  ["no refspec", (r: string) => `git -C ${r} push origin`],
  ["a URL for a remote", (r: string) => `git -C ${r} push /srv/other.git feature`],
  ["a cleanup flag", (r: string) => `bercail cleanup --force ${r}`],
  ["a trail merge flag", (r: string) => `cd ${r} && entire trail merge 41 --force`],
  // entire trail merge takes no --change; bercail job merge does.
  ["a trail merge --change", (r: string) => `cd ${r} && entire trail merge 41 --change app/7`],
  ["a push by its path", (r: string) => `/usr/bin/git -C ${r} push -q origin feature`],
  // What the guard asks about as a merge or a cleanup never becomes a plain command.
  ["a trail merge after a selector", (r: string) => `cd ${r} && entire --context work trail merge 41`],
  ["a trail merge with a flag inside its path", (r: string) => `cd ${r} && entire trail --branch feature merge`],
  ["a cleanup after a flag", (r: string) => `bercail -q cleanup ${r}`],
  ["a cleanup --gone of a relative path", () => "bercail cleanup --gone repo.gone"],
  ["a cleanup --gone of two paths", (r: string) => `bercail cleanup --gone ${r}.a ${r}.b`],
  ["a cleanup --gone of no path", () => "bercail cleanup --gone"],
  ["a cleanup --gone after its path", (r: string) => `bercail cleanup ${r}.gone --gone`],
  ["a cleanup --gone with ..", (r: string) => `bercail cleanup --gone ${r}/../repo.gone`],
  ["a job merge after a flag", (r: string) => `bercail -q job merge trail:41 --repo ${r}`],
  ["a relative folder with no cwd", () => "git -C repo push origin feature"],
  ["a folder with ..", (r: string) => `git -C ${r}/../repo push origin feature`],
  ["a cd with ..", (r: string) => `cd ${r}/.. && entire trail merge 41`],
  ["a cleanup with ..", (r: string) => `bercail cleanup ${r}/../repo.topic`],
  ["a job merge flag", (r: string) => `bercail job merge trail:41 --repo ${r} --force`],
  ["a job merge of a bare number", (r: string) => `bercail job merge 41 --repo ${r}`],
  ["a job merge of a change not <repo>/<n>", (r: string) => `bercail job merge trail:41 --change 7 --repo ${r}`],
  ["a job merge with two --repo", (r: string) => `bercail job merge trail:41 --repo ${r} --repo /`],
  ["a job merge --repo with ..", (r: string) => `bercail job merge trail:41 --repo ${r}/../repo`],
])("%s is not one operation", (_name, command) => {
  expect(typeof guardOperation(command(repo), _name.includes("no cwd") ? undefined : "/", dir)).toBe("string");
});

test("any other one command is its words as written, quoted text and all, run in its folder's real path", async () => {
  symlinkSync(repo, join(dir, "here"));
  const text = 'never `rm -rf` | cat; a && b > c $(d) $HOME \\ "q" it\'s';
  const argv = ["entire", "brain", "remember", text, "--path=docs/a b", "--json"];
  // Each quote the shell takes away, single or double, and text next to a bare word.
  const quoted = `entire brain remember '${text.replaceAll("'", "'\"'\"'")}' --path='docs/a b' "--json"`;
  expect(op(`cd ${join(dir, "here")} && ${quoted}`)).toStrictEqual({
    kind: "command",
    dir: join(dir, "here"),
    argv,
  });
  const facts = await pin(`cd ${join(dir, "here")} && ${quoted}`);
  expect(facts).toStrictEqual({ kind: "command", dir: repo, argv });
  expect(runOf(facts)).toStrictEqual({ argv, cwd: repo });
  // Shown as the shell would read it back: the same words again.
  expect(argvText(argv)).toBe(`entire brain remember '${text.replaceAll("'", `'"'"'`)}' '--path=docs/a b' --json`);
  expect(argvText(["echo", "it's", "a b"])).toBe(`echo "it's" 'a b'`);
  for (const words of [argv, ["echo", "it's", "a b"]]) expect(op(argvText(words), repo)).toMatchObject({ argv: words });
  expect(op(`cd ${repo} && entire trail link 41 --branch feature --base main`)).toStrictEqual({
    kind: "command",
    dir: repo,
    argv: ["entire", "trail", "link", "41", "--branch", "feature", "--base", "main"],
  });
  // Its folder moved under it: the card is stale.
  rmSync(join(dir, "here"));
  symlinkSync(dir, join(dir, "here"));
  expect(changedFacts(facts, await pin(`cd ${join(dir, "here")} && ${quoted}`))).toStrictEqual(["dir changed"]);
});

test("a config change pins bercail itself, the lines its --dry-run changes and their hash, writes nothing, and is stale once they read otherwise", async () => {
  const cli = join(process.cwd(), "bin/bercail");
  vi.stubEnv("BERCAIL_BIN", cli);
  const config = join(dir, ".config/bercail/config.toml");
  mkdirSync(join(dir, ".config/bercail"), { recursive: true });
  writeFileSync(config, "[shep]\nrollover = false # mine\n");
  const facts = await pin("/elsewhere/bercail config set shep rollover true", repo);
  const diff = `--- ${config}\n+++ ${config}\n-rollover = false # mine\n+rollover = true # mine`;
  const argv = [
    cli,
    "config",
    "set",
    "shep",
    "rollover",
    "true",
    "--expect",
    createHash("sha256").update(diff).digest("hex"),
  ];
  expect(facts).toStrictEqual({ kind: "command", dir: repo, argv, diff });
  expect(runOf(facts)).toStrictEqual({ argv, cwd: repo });
  expect(readFileSync(config, "utf8")).toBe("[shep]\nrollover = false # mine\n");
  expect(await pin(`cd ${repo} && bercail routine enable deps`)).toMatchObject({
    diff: `--- ${config}\n+++ ${config}\n+\n+[routine.deps]\n+run = "deps"\n+at = "08:00"`,
  });
  // The person changed it meanwhile; the program Shep named is never the one that runs.
  writeFileSync(config, "[shep]\nrollover = true\n");
  const now = await pin("bercail config set shep rollover true", repo);
  expect(changedFacts(facts, now)).toStrictEqual(["argv changed", "diff changed"]);
  expect(now).toMatchObject({ diff: `unchanged: ${config}` });
  // What bercail refuses is refused before any card, in its words, and a hash is the guard's to give.
  await expect(pin("bercail config set shep nope 1", repo)).rejects.toThrow(/bercail reads no \[shep\] nope/);
  await expect(pin("bercail -v config set shep rollover true", repo)).rejects.toThrow(/handed off only as bercail/);
  await expect(pin(`bercail config set shep rollover true --expect ${"0".repeat(64)}`, repo)).rejects.toThrow(
    /handed off only as bercail/,
  );
});

test("a push to an entire:// remote pins its URL, and the card names the Entire project", async () => {
  const url = "entire://aws-us-east-2.entire.io/et/lesentiel/lesentiel";
  git("remote", "set-url", "origin", url);
  const facts = await pin(`git -C ${repo} push origin feature`);
  expect(facts).toMatchObject({ kind: "push", url });
  expect(opTarget(facts)).toBe(`the Entire project et/lesentiel/lesentiel (${url}) refs/heads/feature`);
  expect(runOf(facts).argv).toContain(url);
  // Still no credential or query.
  for (const bad of [
    "entire://bot@aws-us-east-2.entire.io/et/a/b",
    "entire://aws-us-east-2.entire.io/et/a/b?token=x",
  ]) {
    git("remote", "set-url", "origin", bad);
    await expect(pin(`git -C ${repo} push origin feature`)).rejects.toThrow(/not one a card can show/);
  }
});

test.each([
  ["a git -C to a folder it cannot read", async () => `git -C ${join(dir, "missing")} push origin feature`, /missing/],
  [
    "a remote with two push URLs",
    async () => {
      git("remote", "set-url", "--add", "--push", "origin", origin);
      git("remote", "set-url", "--add", "--push", "origin", join(dir, "mirror.git"));
      return `git -C ${repo} push origin feature`;
    },
    /must push to one URL, not 2/,
  ],
  [
    "a URL with a credential",
    async () => {
      git("remote", "set-url", "origin", "https://bot:s3cret@example.invalid/app.git");
      return `git -C ${repo} push origin feature`;
    },
    /not one a card can show/,
  ],
  [
    "a URL a url.* rule rewrites again",
    async () => {
      // git sends to the rewritten URL, which a push to it as written rewrites once more.
      execFileSync("git", ["init", "-q", "--bare", join(dir, "rewritten.git")]);
      git("config", `url.${join(dir, "rewritten.git")}.insteadOf`, origin);
      git("config", `url.${join(dir, "third.git")}.pushInsteadOf`, join(dir, "rewritten"));
      return `git -C ${repo} push origin feature`;
    },
    /rewrites origin's push URL/,
  ],
  [
    "a URL a rule with a space in its key rewrites again",
    async () => {
      // git sends to rewritten.git, which a rule keyed by a URL with a space rewrites once more.
      execFileSync("git", ["init", "-q", "--bare", join(dir, "rewritten.git")]);
      git("config", `url.${join(dir, "rewritten.git")}.insteadOf`, origin);
      git("config", `url.${join(dir, "with space.git")}.pushInsteadOf`, join(dir, "rewritten"));
      return `git -C ${repo} push origin feature`;
    },
    /rewrites origin's push URL/,
  ],
  [
    "a local URL through ..",
    async () => {
      git("remote", "set-url", "origin", `${dir}/repo/../origin.git`);
      return `git -C ${repo} push origin feature`;
    },
    /names a folder with \. or \.\./,
  ],
  [
    "a file:// URL, whose %-escapes git decodes",
    async () => {
      git("remote", "set-url", "origin", `file://${origin}`);
      return `git -C ${repo} push origin feature`;
    },
    /is a file:\/\/ URL; set it to the repo's path/,
  ],
  [
    "a tag",
    async () => {
      git("tag", "v1");
      return `git -C ${repo} push origin v1`;
    },
    /does not push to a branch/,
  ],
  ["a hash to a short name", async () => `git -C ${repo} push origin ${git("rev-parse", "HEAD")}:feature`, /short/],
  // git matches a short destination against the remote's refs: a tag v1 there gets the push.
  ["a branch to a short name", async () => `git -C ${repo} push origin feature:v1`, /write refs\/heads\/v1/],
  [
    "a branch remote.<name>.push maps elsewhere",
    async () => {
      git("config", "remote.origin.push", "refs/heads/feature:refs/heads/other");
      return `git -C ${repo} push origin feature`;
    },
    /remote.<name>.push decides where feature goes/,
  ],
  ["a delete", async () => `git -C ${repo} push origin :feature`, /not one source/],
  ["one branch twice", async () => `git -C ${repo} push origin feature feature`, /same branch twice/],
  ["a cleanup of a folder inside a worktree", async () => `bercail cleanup ${join(repo, ".git")}`, /./],
  [
    "a trail with several open changes",
    async () => {
      trail([change(6), change(7)]);
      return `cd ${repo} && entire trail merge 41`;
    },
    /2 open changes; name one/,
  ],
  [
    "a change with no head yet",
    async () => {
      trail([change(7, { current: true, mergeability: null })]);
      return `cd ${repo} && entire trail merge app/7`;
    },
    /no one open change/,
  ],
  [
    "a trail entire cannot show",
    async () => {
      chmodSync(join(dir, "bin/entire"), 0o644);
      return `cd ${repo} && entire trail merge 41`;
    },
    /entire trail show failed/,
  ],
])("%s does not pin", async (_name, setup, why) => {
  await expect(pinOperation(op(await setup(), "/"))).rejects.toThrow(why);
});

test("each pinned fact that moves is named: a -C destination, the push URL, the trail's open change", async () => {
  const other = join(dir, "other");
  execFileSync("git", ["clone", "-q", repo, other]);
  execFileSync("git", ["-C", other, "remote", "set-url", "origin", origin]);
  // The same words and cwd, but the folder -C names now points elsewhere.
  symlinkSync(repo, join(dir, "here"));
  const push = op(`git -C ${join(dir, "here")} push origin main`);
  const was = await pinOperation(push);
  rmSync(join(dir, "here"));
  symlinkSync(other, join(dir, "here"));
  expect(changedFacts(was, await pinOperation(push))).toStrictEqual(["dir changed", "gitDir changed"]);
  // A local remote through a symlink is pinned by its real path: moving the link moves the URL.
  execFileSync("git", ["init", "-q", "--bare", join(dir, "second.git")]);
  symlinkSync(origin, join(dir, "link.git"));
  git("remote", "set-url", "origin", join(dir, "link.git"));
  const linked = await pinOperation(op(`git -C ${repo} push origin main`));
  expect(linked).toMatchObject({ url: origin });
  rmSync(join(dir, "link.git"));
  symlinkSync(join(dir, "second.git"), join(dir, "link.git"));
  expect(changedFacts(linked, await pinOperation(op(`git -C ${repo} push origin main`)))).toStrictEqual([
    "url changed",
  ]);
  git("remote", "set-url", "origin", join(dir, "elsewhere.git"));
  execFileSync("git", ["init", "-q", "--bare", join(dir, "elsewhere.git")]);
  const fromRepo = op(`git -C ${repo} push origin main`);
  const atRepo = await pinOperation(fromRepo);
  git("remote", "set-url", "origin", origin);
  expect(changedFacts(atRepo, await pinOperation(fromRepo))).toStrictEqual(["url changed"]);
  trail([change(6, { status: "merged" }), change(7)]);
  const merge = op(`cd ${repo} && entire trail merge 41`);
  const before = await pinOperation(merge);
  trail([change(6, { status: "merged" }), change(8)]);
  expect(changedFacts(before, await pinOperation(merge))).toStrictEqual(["change changed"]);
  trail([change(6, { status: "merged" }), change(7, { mergeability: { head_sha: "e".repeat(40) } })]);
  expect(changedFacts(before, await pinOperation(merge))).toStrictEqual(["head changed"]);
});

// guardDefault's reads, answered from a table by their words; any other read fails, as one
// that cannot reach its host. The policy says merge_reversible, and origin is $url.
function world(url: string, extra: Record<string, string | Error> = {}): Read {
  const table: Record<string, string | Error> = {
    "bercail policy show --json /r": JSON.stringify({ policy: { merge_reversible: true }, entire: false }),
    "git -C /r remote get-url --all origin": url,
    "git -C /r remote get-url --push --all origin": url,
    ...extra,
  };
  return async (command, args) => {
    const got = table[[command.split("/").pop(), ...args].join(" ")];
    if (got === undefined || got instanceof Error) throw got ?? new Error(`${command} ${args.join(" ")}: unreachable`);
    return got;
  };
}
const entireUrl = "entire://aws-us-east-2.entire.io/et/acme/app";
const push = (url: string, ref = "refs/heads/feature"): GuardFacts => ({
  kind: "push",
  dir: "/r",
  gitDir: "/r/.git",
  url,
  refspecs: [`${"a".repeat(40)}:${ref}`],
});
const merge: GuardFacts = {
  kind: "trail merge",
  checkout: "/r",
  trailId: "01TRAIL",
  change: "app/7",
  head: "f".repeat(40),
  base: "main",
};
const link = (...flags: string[]): GuardFacts => ({
  kind: "command",
  dir: "/r",
  argv: ["entire", "trail", "link", "87", ...flags],
});
const viewed = (repo: string, isPrivate: unknown): Record<string, string> => ({
  [`entire repo view ${entireUrl} --json`]: JSON.stringify({ repo, private: isPrivate, repoId: "01REPO" }),
});
const shown = (forge: string, project: string) => ({
  "entire trail show app/7 --json": JSON.stringify({ id: "01TRAIL", project: { reference: { forge, project } } }),
});
const github = (visibility: string) => ({
  "gh repo view github.com/acme/app --json visibility,id": JSON.stringify({ visibility, id: "R_1" }),
});

test.each([
  ["a cleanup, always", { kind: "cleanup", worktree: "/w", branch: null, head: "a".repeat(40) }, world(""), true],
  [
    "a cleanup --gone, always",
    { kind: "cleanup", gone: true, path: "/w", repo: "/r", branch: null, handoffs: 1 },
    world(""),
    true,
  ],
  [
    "a push to a private GitHub origin",
    push("git@github.com:acme/app.git"),
    world("git@github.com:acme/app.git", github("PRIVATE")),
    true,
  ],
  [
    "a push to its trunk, under merge_reversible",
    push("git@github.com:acme/app.git", "refs/heads/main"),
    world("git@github.com:acme/app.git", github("PRIVATE")),
    true,
  ],
  ["a push to a private Entire origin", push(entireUrl), world(entireUrl, viewed("/et/acme/app", true)), true],
  ["a push to an origin on this machine", push("/srv/app.git"), world("/srv/app.git"), true],
  [
    "a trail merge in its own private Entire repo",
    merge,
    world(entireUrl, { ...viewed("/et/acme/app", true), ...shown("et", "acme") }),
    true,
  ],
  [
    "a trail link of a named branch in a private Entire repo",
    link("--branch", "b", "--base", "main"),
    world(entireUrl, viewed("/et/acme/app", true)),
    true,
  ],
  // Waits: public, unknown, unreadable, another repo, or no merge_reversible.
  [
    "a push to a public GitHub origin",
    push("https://github.com/acme/app"),
    world("https://github.com/acme/app", github("PUBLIC")),
    false,
  ],
  [
    "a push to an internal GitHub origin",
    push("https://github.com/acme/app"),
    world("https://github.com/acme/app", github("INTERNAL")),
    false,
  ],
  [
    "a push whose visibility gh cannot read",
    push("https://github.com/acme/app"),
    world("https://github.com/acme/app"),
    false,
  ],
  ["a push to a public Entire origin", push(entireUrl), world(entireUrl, viewed("/et/acme/app", false)), false],
  [
    "a push where entire answers for another repo",
    push(entireUrl),
    world(entireUrl, viewed("/et/acme/other", true)),
    false,
  ],
  ["a push to another host", push("https://gitlab.com/acme/app.git"), world("https://gitlab.com/acme/app.git"), false],
  ["a push to a remote that is not origin", push("/srv/fork.git"), world("/srv/app.git"), false],
  [
    "a push where the policy does not say merge_reversible",
    push("/srv/app.git"),
    world("/srv/app.git", { "bercail policy show --json /r": JSON.stringify({ policy: { merge_reversible: false } }) }),
    false,
  ],
  [
    "a push whose policy cannot be read",
    push("/srv/app.git"),
    world("/srv/app.git", { "bercail policy show --json /r": new Error("no bercail") }),
    false,
  ],
  [
    "a trail merge of another repo's change",
    merge,
    world("entire://aws-us-east-2.entire.io/et/acme/web", { ...shown("et", "acme") }),
    false,
  ],
  [
    "a trail merge in a GitHub-backed repo",
    merge,
    world("git@github.com:acme/app.git", { ...github("PRIVATE"), ...shown("gh", "acme") }),
    false,
  ],
  [
    "a trail merge in a public Entire repo",
    merge,
    world(entireUrl, { ...viewed("/et/acme/app", false), ...shown("et", "acme") }),
    false,
  ],
  ["a trail merge whose trail cannot be read", merge, world(entireUrl, viewed("/et/acme/app", true)), false],
  ["a trail link of the current branch", link(), world(entireUrl, viewed("/et/acme/app", true)), false],
  [
    "a trail link that creates a branch",
    link("--branch", "b", "--branch-action", "create"),
    world(entireUrl, viewed("/et/acme/app", true)),
    false,
  ],
  [
    "a trail link to a path that is named entire",
    { ...link("--branch", "b"), argv: ["/tmp/x/entire", "trail", "link", "87", "--branch", "b"] } as GuardFacts,
    world(entireUrl, viewed("/et/acme/app", true)),
    false,
  ],
  [
    "a push to an origin that pushes elsewhere than it fetches",
    push("/srv/app.git"),
    world("/srv/app.git", { "git -C /r remote get-url --all origin": "/srv/fork.git" }),
    false,
  ],
  [
    "a push to an origin with two push URLs",
    push("/srv/app.git"),
    world("/srv/app.git", { "git -C /r remote get-url --push --all origin": "/srv/app.git\n/srv/fork.git" }),
    false,
  ],
  [
    "a push to Entire's mirror of a GitHub repo",
    push("entire://aws-us-east-2.entire.io/gh/acme/app"),
    world("entire://aws-us-east-2.entire.io/gh/acme/app", github("PRIVATE")),
    false,
  ],
  [
    "a push where entire names no repo ID",
    push(entireUrl),
    world(entireUrl, {
      [`entire repo view ${entireUrl} --json`]: JSON.stringify({ repo: "/et/acme/app", private: true }),
    }),
    false,
  ],
  [
    "a trail link to another repo",
    link("--branch", "b", "--repo", "et/acme/web"),
    world(entireUrl, viewed("/et/acme/app", true)),
    false,
  ],
  [
    "any other command",
    { kind: "command", dir: "/r", argv: ["entire", "brain", "remember", "x"] },
    world(entireUrl),
    false,
  ],
] as const)("%s: defaults %s", async (_name, facts, read, defaults) => {
  vi.stubEnv("ENTIRE_BIN", undefined);
  const got = await guardDefault(facts as GuardFacts, read);
  expect(got.defaults, got.why).toBe(defaults);
  expect(got.why).toMatch(/\S/);
});

test("a push in an Entire repo whose hook sends checkpoints to another remote waits; one that keeps them, or sends them to origin, defaults", async () => {
  const top = join(dir, "top");
  mkdirSync(join(top, ".entire"), { recursive: true });
  const facts: GuardFacts = { ...push("/srv/app.git"), dir: top } as GuardFacts;
  const read = async (command: string, args: string[]) =>
    command.endsWith("bercail")
      ? JSON.stringify({ policy: { merge_reversible: true }, entire: true })
      : args.includes("--all")
        ? "/srv/app.git"
        : Promise.reject(new Error("unreachable"));
  const settings = (value: unknown, file = "settings.json") =>
    writeFileSync(join(top, ".entire", file), JSON.stringify(value));
  settings({ strategy_options: {} });
  expect(await guardDefault(facts, read)).toMatchObject({ defaults: true });
  settings({ strategy_options: { checkpoint_remote: { provider: "github", repo: "acme/transcripts" } } });
  expect(await guardDefault(facts, read)).toMatchObject({ defaults: false, why: expect.stringMatching(/checkpoints/) });
  settings({ strategy_options: { push_sessions: false } }, "settings.local.json");
  expect(await guardDefault(facts, read)).toMatchObject({ defaults: true });
});

// The guard in Shep's session (BERCAIL_ROLE=shep) or a desk's: exec stands in for
// bercail policy show, entire agent-help, push-approval and hc run; hc does what `hc` says.
function session(role: string, hc: (args: string[]) => { code: number; stderr?: string } = () => ({ code: 1 })) {
  vi.stubEnv("BERCAIL_ROLE", role);
  vi.stubEnv("XDG_STATE_HOME", join(dir, "state"));
  const handlers: Record<string, (event: unknown, ctx: unknown) => Promise<unknown>> = {};
  const exec = vi.fn(async (cmd: string, args: string[]) => {
    if (cmd === "hc") return { stdout: "", stderr: "", ...hc(args) };
    if (args[0] === "policy")
      return { code: 0, stdout: JSON.stringify({ repo: args.at(-1), policy: { push: "ask" } }), stderr: "" };
    if (args[0] === "shep") return { code: 0, stdout: JSON.stringify({ approved: approve }), stderr: "" };
    return { code: 0, stdout: "{}", stderr: "" };
  });
  const confirm = vi.fn(async () => false);
  guard({ on: (name: string, handler: never) => (handlers[name] = handler), registerTool() {}, exec } as never);
  const ctx = { hasUI: true, cwd: repo, ui: { confirm }, sessionManager: { getSessionId: () => "shep-session" } };
  let calls = 0;
  // The input Pi runs, as the last tool_call left it.
  const ran = { command: "" };
  // Pi ends the assistant message, then checks its calls. ended: false checks a call with no
  // message_end. siblings: the message's other calls.
  const bash = async (command: string, { ended = true, siblings = 0 } = {}) => {
    const id = `c${calls++}`;
    const content = [id, ...Array.from({ length: siblings }, (_, i) => `${id}-${i}`)].map((call) => ({
      type: "toolCall",
      id: call,
    }));
    if (ended) await handlers.message_end({ message: { role: "assistant", content } }, ctx);
    const input = { command };
    const result = (await handlers.tool_call({ toolName: "bash", toolCallId: id, input }, ctx)) as
      | { block: true; reason: string }
      | undefined;
    ran.command = input.command;
    return result;
  };
  return { bash, confirm, exec, ran };
}
let approve: string | null = null;
const asks = () => join(dir, "state/bercail/guard-asks");
// Every kind of ask the guard makes in Shep's session today.
const askFixtures = () => [
  `git -C ${repo} push origin feature`,
  `git -C ${repo} tag v1.0.0`,
  `git -C ${repo} push origin feature && git -C ${repo} push origin main`,
  "gh release create v1.0.0",
  "gh pr create --fill",
  `bercail cleanup ${repo}`,
  `bercail cleanup --gone ${repo}.gone`,
  `cd ${repo} && entire trail merge 41`,
  `bercail job merge trail:41 --repo ${repo}`,
  "entire brain distill --dry-run",
  "entire frob",
  Array.from({ length: 9 }, (_, i) => `git -C /r${i} push origin f`).join("; "),
];

test("Shep's session never waits on a guard confirm: every ask is handed off or refused", async () => {
  const shep = session("shep");
  trail([change(7)]);
  for (const command of askFixtures()) {
    const got = await shep.bash(command);
    expect(got, command).toMatchObject({
      block: true,
      reason: expect.stringMatching(/Shep's session never waits on a confirm|Handed off/),
    });
  }
  expect(shep.confirm).not.toHaveBeenCalled();
  // A desk keeps today's dialog for each of them, but for a trail merge, which only Shep runs.
  const desk = session("");
  for (const command of askFixtures()) {
    const before = desk.confirm.mock.calls.length;
    await desk.bash(command);
    expect(desk.confirm.mock.calls.length - before, command).toBe(/trail merge|job merge/.test(command) ? 0 : 1);
  }
});

test("Shep's bercail job merge goes to a card as a trail merge; its supersede runs with a warning", async () => {
  const shep = session("shep", (args) => {
    markStart(args.at(-1)!, "started");
    return { code: 0 };
  });
  trail([change(7)]);
  const got = await shep.bash(`bercail job merge trail:41 --repo ${repo}`);
  expect(got).toMatchObject({
    block: true,
    reason: expect.stringMatching(/^Handed off, not run: .*trail merge of app\/7/),
  });
  const [name] = readdirSync(asks()).filter((n) => n.endsWith(".json"));
  expect(JSON.parse(readFileSync(join(asks(), name), "utf8"))).toMatchObject({
    op: { kind: "trail merge", dir: repo, trail: "41", job: "trail:41" },
    facts: { kind: "trail merge", change: "app/7", job: "trail:41" },
  });
  expect(await shep.bash(`bercail job supersede trail:41 --with trail:25 --repo ${repo}`)).toBeUndefined();
  expect(shep.confirm).not.toHaveBeenCalled();
});

test("Shep's quoted Brain memory and its trail link go to cards as the words they run", async () => {
  const shep = session("shep", (args) => {
    markStart(args.at(-1)!, "started");
    return { code: 0 };
  });
  const tickets = () => readdirSync(asks()).filter((n) => n.endsWith(".json"));
  for (const [command, argv] of [
    [
      `cd ${repo} && entire brain remember "Run tests; never | pipe them" --json`,
      ["entire", "brain", "remember", "Run tests; never | pipe them", "--json"],
    ],
    [
      `cd ${repo} && entire trail link 41 --branch feature --base main`,
      ["entire", "trail", "link", "41", "--branch", "feature", "--base", "main"],
    ],
  ] as const) {
    const before = existsSync(asks()) ? tickets() : [];
    const got = await shep.bash(command);
    const [name] = tickets().filter((n) => !before.includes(n));
    expect(got, command).toStrictEqual({
      block: true,
      reason: expect.stringContaining(`Handed off, not run: the person answers this command ${argvText([...argv])} on`),
    });
    expect(JSON.parse(readFileSync(join(asks(), name), "utf8"))).toMatchObject({
      command,
      op: { kind: "command", dir: repo, argv },
      facts: { kind: "command", dir: repo, argv },
    });
  }
  expect(shep.confirm).not.toHaveBeenCalled();
});

test("an ask handed off writes its ticket and starts its worker, which Shep is told of", async () => {
  let argv: string[] = [];
  const shep = session("shep", (args) => {
    argv = args;
    markStart(args.at(-1)!, "started");
    return { code: 0 };
  });
  const got = await shep.bash(`git -C ${repo} push origin feature`);
  const [name] = readdirSync(asks()).filter((n) => n.endsWith(".json"));
  const id = name.slice(0, -5);
  expect(got).toStrictEqual({
    block: true,
    reason: `Handed off, not run: the person answers this push of ${origin} refs/heads/feature on a Decisions card, and the worker guard-ask-${id} runs it only on their Allow within the hour, or, if nobody answers and the card says it defaults to Allow, at its deadline. Tell the person in one line that the card is up. Do not retry it, wait for it or run it another way; your turn goes on. Its outcome comes back as a guard event; report it then.`,
  });
  expect(argv).toStrictEqual([
    "run",
    "--bg",
    "--name",
    `guard-ask-${id}`,
    "--cwd",
    asks(),
    "--outlive-parent",
    "--no-notify",
    "--rm",
    "--",
    "env",
    "BERCAIL_ROLE=shep",
    `XDG_STATE_HOME=${join(dir, "state")}`,
    `ENTIRE_BIN=${join(dir, "bin/entire")}`,
    "bercail",
    "guard",
    "ask",
    id,
  ]);
  const ticket = JSON.parse(readFileSync(join(asks(), name), "utf8"));
  expect(statSync(join(asks(), name)).mode & 0o777).toBe(0o600);
  expect(ticket).toMatchObject({
    id,
    command: `git -C ${repo} push origin feature`,
    cwd: repo,
    reason: "Allow this push to origin: feature? No keeps it local for the person.",
    op: { kind: "push", dir: repo, remote: "origin", refspecs: ["feature"] },
    facts: { kind: "push", url: origin, refspecs: [`${git("rev-parse", "feature")}:refs/heads/feature`] },
    shep: { session: "shep-session" },
  });
  expect(Date.parse(ticket.expires) - Date.parse(ticket.at)).toBe(3600000);
  // Its folder is the guard's: no agent writes a ticket, or starts a worker on one.
  const forged = await shep.bash(`echo '{}' > ${join(asks(), "0123456789ab.json")}`);
  expect(forged).toMatchObject({
    block: true,
    reason: expect.stringMatching(/decides what bercail's guard lets through/),
  });
  for (const command of [
    `bercail guard ask ${id}`,
    "bercail shep question guard-claim Q1@1 x",
    "bercail shep question guard-default Q1@1 x",
  ])
    expect(await shep.bash(command), command).toMatchObject({
      block: true,
      reason: expect.stringMatching(/the guard's/),
    });
});

test("Shep's lease push of a desk's restack goes to a card pinned to both heads; a desk's is still blocked", async () => {
  const shep = session("shep", (args) => {
    markStart(args.at(-1)!, "started");
    return { code: 0 };
  });
  const { old, head } = restack();
  const command = leasePush(old, head);
  expect(await shep.bash(command)).toMatchObject({
    block: true,
    reason: expect.stringMatching(/^Handed off, not run: the person answers this force-with-lease push of /),
  });
  const [name] = readdirSync(asks()).filter((n) => n.endsWith(".json"));
  const lease = { ref: "refs/heads/feature", old };
  expect(JSON.parse(readFileSync(join(asks(), name), "utf8"))).toMatchObject({
    command,
    reason: expect.stringMatching(/^Allow this force-with-lease push to origin: .* replacing /),
    op: { kind: "push", dir: repo, remote: "origin", refspecs: [`${head}:refs/heads/feature`], lease },
    facts: { kind: "push", url: origin, refspecs: [`${head}:refs/heads/feature`], lease },
  });
  expect(shep.confirm).not.toHaveBeenCalled();
  const desk = session("");
  expect(await desk.bash(command)).toMatchObject({
    block: true,
    reason: expect.stringMatching(/^Force-push is blocked/),
  });
  expect(desk.confirm).not.toHaveBeenCalled();
});

test.each([
  [
    "a ticket it cannot write",
    () => writeFileSync(join(dir, "state/bercail/guard-asks"), ""),
    () => ({ code: 0 }),
    /could not write its ticket/,
  ],
  [
    "a worker hc cannot start",
    () => {},
    () => ({ code: 1, stderr: "no server\n" }),
    /hc could not start guard-ask-[0-9a-f]{12}: no server/,
  ],
  [
    "a worker that never says it started",
    () => {},
    () => ({ code: 0 }),
    /guard-ask-[0-9a-f]{12} did not start within 0 s/,
  ],
])("%s is refused, and a late worker finds its ticket void", async (_name, setup, hc, why) => {
  vi.stubEnv("BERCAIL_GUARD_ASK_WAIT_MS", "300");
  mkdirSync(join(dir, "state/bercail"), { recursive: true });
  setup();
  const shep = session("shep", hc);
  const got = await shep.bash(`git -C ${repo} push origin feature`);
  expect(got).toMatchObject({ block: true, reason: expect.stringMatching(why) });
  expect(got?.reason).toMatch(/Shep's session never waits on a confirm/);
  for (const name of existsSync(asks()) && statSync(asks()).isDirectory() ? readdirSync(asks()) : [])
    if (name.endsWith(".json")) expect(markStart(name.slice(0, -5), "started")).toBe("void");
  expect(shep.confirm).not.toHaveBeenCalled();
});

test("a push the person's answer approves runs in Shep's session with no handoff", async () => {
  approve = "Q7@1";
  try {
    const shep = session("shep");
    const head = git("rev-parse", "HEAD");
    expect(await shep.bash(`git -C ${repo} push origin ${head}^{commit}:refs/heads/main`)).toBeUndefined();
    expect(shep.exec.mock.calls.some(([cmd]) => cmd === "hc")).toBe(false);
    expect(existsSync(asks())).toBe(false);
  } finally {
    approve = null;
  }
});

test("a trail link defaults only with the entire the guard reads with, and its reading names the repo's ID and URL", async () => {
  const read = world(entireUrl, viewed("/et/acme/app", true));
  vi.stubEnv("ENTIRE_BIN", undefined);
  expect(await guardDefault(link("--branch", "b"), read)).toStrictEqual({
    defaults: true,
    why: `it links a branch in the private Entire repo et/acme/app (01REPO, ${entireUrl})`,
  });
  vi.stubEnv("ENTIRE_BIN", "/opt/entire");
  expect(await guardDefault(link("--branch", "b"), read)).toMatchObject({ defaults: false });
});

test("where its repo's trusted policy lists it in shep_may_run and reads private, Shep's link, merge and cleanup run with no card", async () => {
  const url = "entire://aws-us-east-2.entire.io/et/acme/app";
  git("remote", "set-url", "origin", url);
  const worktree = join(dir, "repo.topic");
  git("worktree", "add", "-q", worktree, "feature");
  const bin = join(dir, "bin");
  // bercail policy show and entire, as this repo's would answer; entire on PATH, as the link runs it.
  let mayRun = ["cleanup", "trail link", "trail merge"];
  let isPrivate = true;
  const policy = () => JSON.stringify({ policy: { push: "branch", shep_may_run: mayRun }, entire: false });
  writeFileSync(join(bin, "bercail"), `#!/bin/sh\ncat '${dir}/policy.json'\n`, { mode: 0o755 });
  writeFileSync(
    join(bin, "entire"),
    `#!/bin/sh\n[ "$1" = repo ] && exec cat '${dir}/repo.json'\ncat '${dir}/trail.json'\n`,
    { mode: 0o755 },
  );
  const world = () => {
    writeFileSync(join(dir, "policy.json"), policy());
    writeFileSync(
      join(dir, "repo.json"),
      JSON.stringify({ repo: "/et/acme/app", private: isPrivate, repoId: "01REPO" }),
    );
    writeFileSync(
      join(dir, "trail.json"),
      JSON.stringify({
        id: "01TRAIL",
        number: 41,
        project: { reference: { forge: "et", project: "acme" } },
        changes: [change(7)],
      }),
    );
  };
  world();
  vi.stubEnv("BERCAIL_BIN", join(bin, "bercail"));
  vi.stubEnv("ENTIRE_BIN", undefined);
  vi.stubEnv("PATH", `${bin}:${process.env.PATH}`);
  // No git variable of Shep's own, which bash would read and the guard's reads drop.
  vi.stubEnv("GIT_CONFIG_NOSYSTEM", undefined);
  const shep = session("shep");
  const commands = [
    `cd ${repo} && entire trail link 41 --branch feature`,
    `bercail job merge trail:41 --repo ${repo}`,
    `bercail cleanup ${worktree}`,
  ];
  // What runs is the argv a card's worker would run, in its folder, never Shep's words, with
  // the program by the path the guard's reads found it at.
  const runs = [
    `cd ${repo} && GIT_TERMINAL_PROMPT=0 ${join(bin, "entire")} trail link 41 --branch feature`,
    `cd ${repo} && GIT_TERMINAL_PROMPT=0 ${join(bin, "bercail")} job merge trail:41 --change app/7 --repo ${repo}`,
    `cd / && GIT_TERMINAL_PROMPT=0 ${join(bin, "bercail")} cleanup ${worktree}`,
  ];
  for (const [i, command] of commands.entries()) {
    expect(await shep.bash(command), command).toBeUndefined();
    expect(shep.ran.command).toBe(runs[i]);
  }
  // A path that is named bercail gets the same argv: the one the guard read with.
  expect(await shep.bash(`/tmp/x/bercail cleanup ${worktree}`)).toBeUndefined();
  expect(shep.ran.command).toBe(runs[2]);
  expect(shep.exec.mock.calls.some(([cmd]) => cmd === "hc")).toBe(false);
  expect(existsSync(asks())).toBe(false);
  const log = readFileSync(join(dir, "state/bercail/guard-approvals.jsonl"), "utf8");
  expect(log).toContain(
    'lists \\"trail link\\" in shep_may_run, and it links a branch in the private Entire repo et/acme/app',
  );
  // Not listed, public, or a link with no --branch: each goes to a card, which says why.
  const missed = (why: string) => ({
    block: true,
    reason: expect.stringContaining(`shep_may_run did not apply: ${why}`),
  });
  for (const [change, why] of [
    [() => (mayRun = ["cleanup"]), `the trusted policy that ${repo} reads does not list "trail link" in shep_may_run`],
    [() => ((mayRun = ["trail link"]), (isPrivate = false)), "the Entire repo et/acme/app is public"],
  ] as const) {
    change();
    world();
    expect(await shep.bash(commands[0]), JSON.stringify(mayRun)).toMatchObject(missed(why));
  }
  mayRun = ["cleanup", "trail link", "trail merge"];
  isPrivate = true;
  world();
  expect(await shep.bash(`cd ${repo} && entire trail link 41`)).toMatchObject(missed("its trail link is only"));
  vi.stubEnv("GIT_CONFIG_GLOBAL", join(dir, "other.gitconfig"));
  expect(await shep.bash(commands[0])).toMatchObject(missed("Shep's environment sets GIT_CONFIG_GLOBAL"));
  vi.stubEnv("GIT_CONFIG_GLOBAL", undefined);
  // A relative PATH folder could hold another entire for bash than for the guard's reads.
  const path = process.env.PATH;
  for (const unsafe of [`bin:${path}`, `:${path}`, `${path}::/usr/bin`]) {
    vi.stubEnv("PATH", unsafe);
    expect(await shep.bash(commands[0]), unsafe).toMatchObject(missed("Shep's PATH has a folder that is not absolute"));
  }
  vi.stubEnv("PATH", path);
  // The opt-in itself still holds.
  expect(await shep.bash(commands[0])).toBeUndefined();
  // A bare entire trail merge is not a trail job's merge, which checks the job and closes it.
  expect(await shep.bash(`cd ${repo} && entire trail merge 41`)).toMatchObject({ block: true });
  // A cleanup needs its repo private on its forge: an origin on this machine is not read so.
  git("remote", "set-url", "origin", origin);
  expect(await shep.bash(`bercail cleanup ${worktree}`)).toMatchObject(missed("the guard cannot tell whether"));
  expect(shep.exec.mock.calls.filter(([cmd]) => cmd === "hc")).toHaveLength(9);
});

// bercail-c2ij: Shep's links in Lesentiel went to cards with no word of why. The issue's
// command and origin, with Lesentiel's shep_may_run; push = ask is the push rule here, so
// only the opt-in can skip the card.
function lesentiel(policyOf: (folder: string) => unknown) {
  const url = "entire://aws-us-east-2.entire.io/et/lesentiel/lesentiel";
  git("remote", "set-url", "origin", url);
  git("branch", "glkvm-takeover-results");
  const bin = join(dir, "bin");
  const policies = join(dir, "policies");
  mkdirSync(policies);
  writeFileSync(join(bin, "bercail"), `#!/bin/sh\ncat "${policies}/$(printf %s "$4" | tr / _)"\n`, { mode: 0o755 });
  const world = (...folders: string[]) => {
    for (const folder of folders)
      writeFileSync(join(policies, folder.replaceAll("/", "_")), JSON.stringify(policyOf(folder)));
  };
  writeFileSync(
    join(bin, "entire"),
    `#!/bin/sh\n[ "$1 $2 $3" = "repo view ${url}" ] && echo '{"repo":"/et/lesentiel/lesentiel","private":true,"repoId":"01M7BX"}'\n`,
    { mode: 0o755 },
  );
  vi.stubEnv("BERCAIL_BIN", join(bin, "bercail"));
  vi.stubEnv("ENTIRE_BIN", undefined);
  vi.stubEnv("PATH", `${bin}:${process.env.PATH}`);
  vi.stubEnv("GIT_CONFIG_NOSYSTEM", undefined);
  // hc starts the card's worker, which says it started.
  const shep = session("shep", (args) => {
    markStart(args.at(-1)!, "started");
    return { code: 0 };
  });
  return { bin, shep, world };
}
const handedOff = (why: string) => ({
  block: true,
  reason: expect.stringMatching(
    new RegExp(
      `^Handed off, not run: .* shep_may_run did not apply: ${why.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\.$`,
    ),
  ),
});
const handoffLog = () =>
  readFileSync(join(dir, "state/bercail/guard-warnings.jsonl"), "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.kind === "handoff")
    .map((entry) => entry.reasons.join(" "));

test("a lone shep_may_run link skips the card; a link beside another call, or not listed, goes to one that says why", async () => {
  let mayRun = ["cleanup", "trail link", "trail merge"];
  const { bin, shep, world } = lesentiel(() => ({ policy: { shep_may_run: mayRun }, entire: true }));
  world(repo);
  const command = `cd ${repo} && entire trail link 109 --branch glkvm-takeover-results`;
  expect(await shep.bash(command)).toBeUndefined();
  expect(shep.ran.command).toBe(
    `cd ${repo} && GIT_TERMINAL_PROMPT=0 ${join(bin, "entire")} trail link 109 --branch glkvm-takeover-results`,
  );
  const why = "it was one of 2 tool calls in its message, which Pi runs together; send it alone";
  expect(await shep.bash(command, { siblings: 1 })).toMatchObject(handedOff(why));
  // A call Pi checks with no message_end before it cannot be told alone.
  const unseen = "the guard saw no end of the message that holds this tool call";
  expect(await shep.bash(command, { ended: false })).toMatchObject(handedOff(unseen));
  mayRun = ["cleanup"];
  world(repo);
  const unlisted = `the trusted policy that ${repo} reads does not list "trail link" in shep_may_run`;
  expect(await shep.bash(command)).toMatchObject(handedOff(unlisted));
  // An ask that shep_may_run cannot name says nothing of it.
  expect((await shep.bash(`git -C ${repo} push origin feature`))?.reason).toMatch(
    /^Handed off, not run: (?!.*shep_may_run)/,
  );
  const log = handoffLog();
  expect(log).toHaveLength(4);
  expect(log.slice(0, 3).map((line) => line.split("shep_may_run did not apply: ")[1])).toStrictEqual(
    [why, unseen, unlisted].map((reason) => `${reason}.`),
  );
});

// The 02:26 cleanup: runner-real-gateway's branch held Lesentiel's policy from before
// shep_may_run, and a cleanup reads its worktree's own policy.
test("a cleanup whose worktree's policy lists no cleanup goes to a card that names the folder it read", async () => {
  const worktree = join(dir, "runner-real-gateway");
  git("worktree", "add", "-q", worktree, "feature");
  const { shep, world } = lesentiel((folder) => ({
    policy: folder === worktree ? {} : { shep_may_run: ["cleanup", "trail link", "trail merge"] },
    entire: true,
  }));
  world(repo, worktree);
  const why = `the trusted policy that ${worktree} reads does not list "cleanup" in shep_may_run`;
  expect(await shep.bash(`bercail cleanup ${worktree}`)).toMatchObject(handedOff(why));
  expect(handoffLog()).toStrictEqual([expect.stringContaining(`shep_may_run did not apply: ${why}.`)]);
});

// A miss's reason reads an origin URL and helpers' output; a token in either is not shown.
test("a cleanup's miss reason names no credential from its origin or a read's error, in the reply or the log", async () => {
  const secret = "sentinel-c2ij-token";
  const worktree = join(dir, "runner-real-gateway");
  git("worktree", "add", "-q", worktree, "feature");
  const { bin, shep, world } = lesentiel(() => ({ policy: { shep_may_run: ["cleanup"] }, entire: true }));
  world(repo, worktree);
  git("remote", "set-url", "origin", `https://x-token:${secret}@example.invalid/acme/app.git`);
  const first = await shep.bash(`bercail cleanup ${worktree}`);
  expect(first).toMatchObject(handedOff("the guard cannot tell whether this origin is private"));
  // bercail policy show fails quoting a token, then prints a token where its JSON should be.
  const policyShow = (script: string) => writeFileSync(join(bin, "bercail"), `#!/bin/sh\n${script}\n`, { mode: 0o755 });
  policyShow(`echo "fatal: Authorization: Bearer ${secret}" >&2\nexit 3`);
  const second = await shep.bash(`bercail cleanup ${worktree}`);
  expect(second).toMatchObject(handedOff("the guard could not read what it acts on (bercail failed with exit 3)"));
  policyShow(`echo "token=${secret}"`);
  const third = await shep.bash(`bercail cleanup ${worktree}`);
  expect(third).toMatchObject(
    handedOff("the guard could not read what it acts on (a read gave output that is not the JSON it expects)"),
  );
  const log = readFileSync(join(dir, "state/bercail/guard-warnings.jsonl"), "utf8");
  for (const text of [first?.reason, second?.reason, third?.reason, log]) expect(text).not.toContain(secret);
});

// bercail-cty3: dispatch told Shep to run bercail cleanup --gone for two gone Lesentiel
// checkouts, and the guard refused it outright, though Lesentiel's shep_may_run lists cleanup.
test("Shep's cleanup --gone runs with no card where its handoff's repo lists cleanup in shep_may_run, else goes to one that says it removes nothing", async () => {
  let mayRun = ["cleanup"];
  const { bin, shep, world } = lesentiel(() => ({ policy: { shep_may_run: mayRun }, entire: true }));
  world(repo);
  const gone = join(dir, "glkvm-readonly-wave4");
  handoffs({ path: gone, repo, branch: "glkvm-readonly-wave4" });
  const command = `bercail cleanup --gone '${gone}'`;
  expect(await shep.bash(command)).toBeUndefined();
  expect(shep.ran.command).toBe(`cd / && GIT_TERMINAL_PROMPT=0 ${join(bin, "bercail")} cleanup --gone ${gone}`);
  expect(readFileSync(join(dir, "state/bercail/guard-approvals.jsonl"), "utf8")).toContain(
    'lists \\"cleanup\\" in shep_may_run, and a gone checkout of the private Entire repo et/lesentiel/lesentiel',
  );
  mayRun = [];
  world(repo);
  const why = `the trusted policy that ${repo} reads does not list "cleanup" in shep_may_run`;
  const handed = await shep.bash(command);
  expect(handed).toMatchObject(handedOff(why));
  expect(handed?.reason).toContain(`this cleanup --gone of ${gone} on a Decisions card`);
  const [name] = readdirSync(asks()).filter((n) => n.endsWith(".json"));
  expect(JSON.parse(readFileSync(join(asks(), name), "utf8"))).toMatchObject({
    reason: expect.stringMatching(/^Record this gone checkout as retired\? .* removes nothing/),
    op: { kind: "cleanup", path: gone, gone: true },
    facts: { kind: "cleanup", gone: true, path: gone, repo, branch: "glkvm-readonly-wave4", handoffs: 1 },
  });
  expect(shep.confirm).not.toHaveBeenCalled();
});
