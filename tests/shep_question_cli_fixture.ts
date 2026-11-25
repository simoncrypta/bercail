// The shared fixture of the tests/shep_question_cli*.test.ts files: question-cli.ts
// run in a temp HOME with stand-ins for hc, bd and bercail, a git checkout of its own,
// and the helpers its tests share. Importing it registers the beforeEach that builds
// them and the afterEach that removes them, for the importing file's tests.
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, expect } from "vite-plus/test";

export const cli = resolve("shep/pi/question-cli.ts");
export const node = process.execPath;
export let dir: string;
export let repo: string;
export let env: NodeJS.ProcessEnv;
export const json = (file: string, value: unknown) => writeFileSync(file, JSON.stringify(value));
export const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { env, encoding: "utf8" }).trim();
export function call(op: string, input?: unknown, args: string[] = []) {
  return spawnSync(node, [cli, op, ...args], {
    env,
    cwd: dir,
    encoding: "utf8",
    input: input === undefined ? undefined : JSON.stringify(input),
  });
}
export function ok(op: string, input?: unknown, args: string[] = []) {
  const result = call(op, input, args);
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  return JSON.parse(result.stdout);
}
export function spec(extra: Record<string, unknown> = {}) {
  return {
    requestId: "create-one",
    kind: "review",
    prompt: "Review this candidate?",
    options: ["yes", "no"],
    origin: { event: "finished:1", session: "shep-session", entry: "entry-1" },
    repo,
    issue: "app-1",
    topic: "login",
    desk: "t9",
    base: "HEAD",
    action: "stage-only review",
    ...extra,
  };
}
export function terminal(extra: Record<string, unknown> = {}) {
  json(join(dir, "terminal.json"), {
    address: "t9",
    state: "live",
    cwd: repo,
    labels: { "bercail.role": "agent", "bercail.issue": "app-1", "bercail.space": "sp1" },
    records: { "desk-session": { app: "pi", state: "working" } },
    ...extra,
  });
}
export function record(extra: Record<string, unknown> = {}) {
  json(join(env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"), {
    address: "t9",
    session: "desk-session",
    cwd: repo,
    harness: "pi",
    issue: "app-1",
    space: "sp1",
    ...extra,
  });
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "shep-question-cli-"));
  env = Object.fromEntries(
    Object.entries(process.env).filter(
      ([key]) => !/^(HC_|HERDR_|BERCAIL_|BEADS_|BD_|GIT_|XDG_)/.test(key) && key !== "BASH_ENV",
    ),
  );
  for (const key of [
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_STATE_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_RUNTIME_DIR",
    "TMPDIR",
  ]) {
    env[key] = join(dir, key.toLowerCase());
    mkdirSync(env[key]!, { recursive: true });
  }
  const bin = join(dir, "bin");
  mkdirSync(bin);
  env.PATH = `${bin}:${process.env.PATH}`;
  env.TZ = "UTC";
  env.LC_ALL = "C";
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_AUTHOR_NAME = env.GIT_COMMITTER_NAME = "Test";
  env.GIT_AUTHOR_EMAIL = env.GIT_COMMITTER_EMAIL = "test@example.invalid";
  env.GIT_AUTHOR_DATE = env.GIT_COMMITTER_DATE = "2026-01-01T00:00:00Z";
  env.BERCAIL_SHEP_STATE = join(dir, "questions");
  env.BERCAIL_SHEP_BIN = join(bin, "bercail");
  repo = join(dir, "repo");
  mkdirSync(repo);
  git("init", "-q");
  writeFileSync(join(repo, "file"), "one\n");
  git("add", "file");
  git("commit", "-qm", "initial");
  mkdirSync(join(env.XDG_STATE_HOME!, "bercail/desk-sessions"), { recursive: true });
  terminal();
  record();
  json(join(dir, "issue.json"), [{ id: "app-1", title: "Login" }]);
  json(join(dir, "policy.json"), {
    repo,
    root: repo,
    sha256: "policy-one",
    trusted: true,
    policy: { integrate: "direct" },
  });
  const fake = (name: string, body: string) =>
    writeFileSync(join(bin, name), `#!/bin/sh\nprintf '%s %s\\n' '${name}' "$*" >> '${dir}/argv'\n${body}\n`, {
      mode: 0o755,
    });
  fake("hc", `test "$1 $2 $3" = 'get t9 --json' || exit 2\n/bin/cat '${dir}/terminal.json'`);
  fake(
    "bd",
    `test "$PWD" = '${repo}' || exit 2\ntest "$1 $2 $3" = 'show app-1 --json' || exit 2\n/bin/cat '${dir}/issue.json'`,
  );
  fake("bercail", `test "$1 $2 $3 $4" = 'policy show --json ${repo}' || exit 2\n/bin/cat '${dir}/policy.json'`);
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

// A test that moves the checkout the fixture's helpers use: ES imports cannot be assigned.
export function setRepo(path: string) {
  repo = path;
}

// The person's picks and closes, as Shep's inbox receives them.
export const inbox = () => join(env.BERCAIL_SHEP_STATE!, "inbox");
export const events = () => {
  try {
    return readdirSync(inbox()).sort();
  } catch {
    return [];
  }
};
export const event = (name: string) => JSON.parse(readFileSync(join(inbox(), name), "utf8"));
export const pick = (requestId: string, choice: string, token = "Q1@1", source = "panel picker") =>
  ok("answer", { requestId, token, choice, source });
