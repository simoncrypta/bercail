// Shep's guard asks (docs/plans/shep-free-guard.md): which command is one operation the
// guard can hand off, and what it pins. Real git in a temp HOME; entire is a stand-in.
import { execFileSync } from "node:child_process";
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
