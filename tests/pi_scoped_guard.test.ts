import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import guard, { decideBash, defaultPolicy } from "../bstack/pi/extensions/guard.ts";
import {
  hasScopedJob,
  scopedModuleRoot,
  scopedProtectedPath,
  scopedStateDir,
} from "../bstack/pi/extensions/scoped-job.ts";
import { QuestionStore, tokenOf, type QuestionSpec } from "../shep/pi/questions.ts";

const root = resolve(import.meta.dirname, "..");
const candidate = {
  head: "a".repeat(40),
  tree: "b".repeat(40),
  base: "c".repeat(40),
  description: "d".repeat(64),
  evidence: "e".repeat(64),
};
const action = {
  op: "execute",
  requestId: "action-1",
  grantId: "grant:Q1@1",
  action: "commit",
  candidate,
};
const preflight = {
  op: "preflight",
  issue: "app-1",
  topic: "Fix",
  base: "refs/heads/main",
  pr: "https://github.com/o/r/pull/1",
  remote: "origin",
};

let home: string;
beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "scoped-guard-"));
  for (const key of Object.keys(process.env)) {
    if (/^(HC_|HERDR_|BERCAIL_|BEADS_|BD_)/.test(key) || key === "BASH_ENV") vi.stubEnv(key, undefined);
  }
  for (const key of [
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_STATE_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_RUNTIME_DIR",
    "TMPDIR",
  ]) {
    const dir = key === "HOME" ? home : join(home, key);
    mkdirSync(dir, { recursive: true });
    vi.stubEnv(key, dir);
  }
  const bin = join(home, "bin");
  mkdirSync(bin);
  for (const name of ["git", "gh", "hc", "bercail", "flock"]) {
    writeFileSync(join(bin, name), "#!/bin/sh\necho unexpected-live-boundary >&2\nexit 97\n", { mode: 0o755 });
  }
  vi.stubEnv("PATH", bin);
  vi.stubEnv("HC_TERMINAL_ID", "actual-desk");
  vi.stubEnv("TZ", "UTC");
  vi.stubEnv("LC_ALL", "C");
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime("2026-11-16T12:00:00.000Z");
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  rmSync(home, { recursive: true, force: true });
});

test("scoped raw commits and pushes never fall through to autopilot, scratch, policy or confirmation", () => {
  for (const role of ["", "builder", "autopilot", "shep"]) {
    const input = {
      role,
      hasUI: true,
      cwd: "/work",
      scopedJob: true,
      policies: { "/work": { ...defaultPolicy, commit: "allow" as const, push: "main" as const, scratch: true } },
      branches: { "/work": "feature" },
      fresh: new Set(["/work"]),
    };
    for (const command of [
      "git commit -m x",
      "git push origin feature",
      "git -C /other commit -m x",
      "gh stack submit",
      "gt submit",
      "git status && git push origin feature",
    ]) {
      expect(decideBash(command, input), `${role}: ${command}`).toMatchObject({
        action: "block",
        reason: expect.stringMatching(/scoped_job/),
      });
    }
    expect(decideBash("git status", input)).toMatchObject({ action: "allow" });
  }
});

test.each([
  "git ci -m escape",
  "git custom-publish",
  "git rebase main",
  "git merge main",
  "git reset --hard HEAD~1",
  "git update-ref refs/heads/feature HEAD~1",
  "git symbolic-ref HEAD refs/heads/other",
  "git branch other",
  "git branch -D feature",
  "git checkout other",
  "git switch other",
  "git cherry-pick HEAD~1",
  "git revert HEAD",
  "git config user.name Replacement",
  "git config --unset user.name",
  "git fetch origin",
  "git stash pop",
  "git commit-tree HEAD^{tree}",
  "git restore -- --staged path",
  "git restore --staged --worktree -- path",
  "git add --unknown .",
  "git diff --output=/tmp/unreviewed",
  "git status --unknown",
  "git log --output=/tmp/unreviewed",
  "git -c diff.external=custom diff",
  "git --exec-path=/tmp/custom status",
  "git --unknown status",
  "gt restack",
  "gt custom-submit",
  "gt log --unknown",
  "origin stack push",
  "origin custom-submit",
  "gh custom-publish",
  "gh stack restack",
])("scoped raw unknown effects are denied: %s", (command) => {
  const input = {
    role: "autopilot",
    hasUI: false,
    cwd: "/work",
    scopedJob: true,
    branches: { "/work": "feature" },
    policies: { "/work": { ...defaultPolicy, commit: "allow" as const, push: "main" as const } },
  };
  expect(decideBash(command, input)).toMatchObject({ action: "block" });
});

test.each(["log", "info", "status"])("scoped raw gt %s is unsupported even when a native name is aliased", (sub) => {
  for (const graphiteAliases of [[], [sub], ["log", "info", "status"], undefined]) {
    expect(
      decideBash(`gt ${sub}`, { role: "autopilot", hasUI: true, cwd: "/work", scopedJob: true, graphiteAliases }),
    ).toMatchObject({ action: "block" });
  }
});

test("scoped boundaries preserve only master's proven genuine-help path", () => {
  for (const role of ["builder", "judge", "autopilot"]) {
    const input = { role, hasUI: true, cwd: "/work", scopedJob: true, graphiteAliases: [] };
    expect(decideBash("git commit --help", input)).toMatchObject({ action: "allow" });
    expect(decideBash("gt submit --help", input)).toMatchObject({ action: "allow" });
    expect(decideBash("gt submit --help", { ...input, graphiteAliases: ["submit"] })).toMatchObject({
      action: "block",
    });
    expect(decideBash("gt submit --help", { ...input, graphiteAliases: undefined })).toMatchObject({ action: "block" });
    expect(decideBash("gt log --help", { ...input, graphiteAliases: ["log"] })).toMatchObject({ action: "block" });
  }
});

test("unknown native Entire operations cannot ask around scoped effect limits", () => {
  expect(
    decideBash("entire unknown-publisher", { role: "autopilot", hasUI: true, cwd: "/work", scopedJob: true }),
  ).toMatchObject({ action: "block" });
  expect(decideBash("entire unknown-publisher", { role: "autopilot", hasUI: true, cwd: "/work" })).toMatchObject({
    action: "ask",
  });
});

test.each([
  "git ci -m x",
  "git rebase main",
  "git merge main",
  "git reset --hard HEAD~1",
  "git update-ref refs/heads/feature HEAD~1",
  "gt restack",
])("unscoped independent behavior is unchanged: %s", (command) => {
  expect(decideBash(command, { role: "autopilot", hasUI: false, cwd: "/work" })).toMatchObject({ action: "allow" });
});

test("scoped reads and ordinary staging remain available, but read-only roles cannot stage", () => {
  const input = { role: "builder", hasUI: true, cwd: "/work", scopedJob: true };
  for (const command of [
    "git status --short",
    "git diff --cached --stat",
    "git --no-pager log -n 5 --oneline",
    "git show --format=fuller HEAD",
    "git rev-parse --show-toplevel",
    "git ls-files -z",
    "git branch --show-current",
    "git branch --list 'feature*'",
    "git tag --list",
    "git config --get remote.origin.url",
    "git config --list --show-origin",
    "gh pr view 1 --json headRefName",
  ]) {
    expect(decideBash(command, input), command).toMatchObject({ action: "allow" });
    expect(decideBash(command, { ...input, role: "judge" }), command).toMatchObject({ action: "allow" });
  }
  for (const command of ["gh pr comment 1 --body 'Tests passed'", "gh pr edit 1 --body-file report.md"]) {
    expect(decideBash(command, input), command).toMatchObject({ action: "allow" });
    expect(decideBash(command, { ...input, role: "judge" }), command).toMatchObject({ action: "block" });
  }
  for (const command of [
    "git add --all",
    "git add -- path",
    "git restore --staged -- path",
    "git reset HEAD -- path",
    "git reset -- path",
    "git rm --cached path",
    "git mv old new",
    "git write-tree",
  ]) {
    expect(decideBash(command, input), command).toMatchObject({ action: "allow" });
    expect(decideBash(command, { ...input, role: "judge" }), command).toMatchObject({ action: "block" });
  }
});

test("a configured Git alias really commits when the old raw boundary permits it", () => {
  const repo = join(home, "alias-repo");
  mkdirSync(repo);
  const env = {
    ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_"))),
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_AUTHOR_NAME: "Fixture",
    GIT_AUTHOR_EMAIL: "fixture@example.invalid",
    GIT_COMMITTER_NAME: "Fixture",
    GIT_COMMITTER_EMAIL: "fixture@example.invalid",
    GIT_AUTHOR_DATE: "2026-11-16T12:00:00Z",
    GIT_COMMITTER_DATE: "2026-11-16T12:00:00Z",
  };
  const git = (...args: string[]) => {
    const run = spawnSync("/usr/bin/git", args, { cwd: repo, env, encoding: "utf8" });
    if (run.status !== 0) throw new Error(run.stderr);
    return run.stdout.trim();
  };
  git("init", "-q", "-b", "feature");
  writeFileSync(join(repo, "file"), "initial\n");
  git("add", "file");
  git("commit", "-qm", "Initial fixture");
  git("config", "alias.ci", "commit");
  const before = git("rev-parse", "HEAD");
  writeFileSync(join(repo, "file"), "unchecked replacement\n");
  git("add", "file");
  const decision = decideBash("git ci -m 'Unchecked alias commit'", {
    role: "autopilot",
    hasUI: false,
    cwd: repo,
    scopedJob: true,
  });
  if (decision.action === "allow") git("ci", "-m", "Unchecked alias commit");
  expect(git("rev-parse", "HEAD"), `raw alias decision: ${JSON.stringify(decision)}`).toBe(before);
  expect(decision.action).toBe("block");
  expect(decideBash("git ci -m x", { role: "autopilot", hasUI: false, cwd: repo }).action).toBe("allow");
});

test("scoped tags and releases cannot use independent policy or plain confirmation", () => {
  const input = {
    role: "shep",
    hasUI: true,
    cwd: "/work",
    scopedJob: true,
    policies: { "/work": { ...defaultPolicy, agentMayRelease: true } },
  };
  for (const command of ["git tag v1", "gh release create v1", "gh api repos/o/r/releases -f tag_name=v1"]) {
    expect(decideBash(command, input), command).toMatchObject({
      action: "block",
      reason: expect.stringMatching(/scoped/),
    });
  }
  expect(decideBash("gh pr comment 1 -b 'Tests passed'", input)).toMatchObject({ action: "allow" });
});

test("guard registers scoped_job with a provider-compatible object schema", () => {
  const tools: unknown[] = [];
  guard({ on() {}, registerTool: (tool: unknown) => tools.push(tool) } as never);
  expect(tools).toHaveLength(1);
  expect(tools[0]).toMatchObject({
    name: "scoped_job",
    parameters: {
      type: "object",
      required: ["op"],
      additionalProperties: false,
      properties: { op: { type: "string", enum: ["preflight", "execute", "inspect", "revoke"] } },
    },
  });
});

function harness() {
  const handlers: Record<string, (event: unknown, ctx: unknown) => Promise<unknown>> = {};
  const tools: Record<string, any> = {};
  const confirm = vi.fn(async () => true);
  const exec = vi.fn(async () => ({
    code: 0,
    stdout: JSON.stringify({
      repo: join(home, "repo"),
      policy: { commit: "allow", push: "main", agent_may_release: true },
      sources: {},
    }),
    stderr: "",
  }));
  guard({
    on: (name: string, handler: never) => {
      handlers[name] = handler;
    },
    registerTool: (tool: any) => {
      tools[tool.name] = tool;
    },
    exec,
  } as never);
  const ctx = {
    cwd: join(home, "repo"),
    hasUI: true,
    sessionManager: { getSessionId: () => "actual-session" },
    ui: { confirm },
  };
  mkdirSync(ctx.cwd, { recursive: true });
  return {
    handlers,
    tools,
    ctx,
    confirm,
    exec,
    call: (toolName: string, input: object) => handlers.tool_call({ toolName, input }, ctx),
  };
}

function authority(mode: string, worktree = join(home, "repo"), desk = "actual-desk") {
  const state = join(process.env.XDG_STATE_HOME!, "bercail/shep");
  writeFileSync(join(home, "bin/flock"), '#!/bin/sh\nexec /usr/bin/flock "$@"\n', { mode: 0o755 });
  const store = new QuestionStore(state);
  const scope = {
    repo: worktree,
    worktree,
    issue: "app-1",
    pr: "https://github.com/o/r/pull/1",
    headRef: "refs/heads/feature",
    baseRef: "refs/heads/main",
    baseOid: candidate.base,
    remote: "origin",
    endpoint: "https://github.com/o/r.git",
    backend: "gh",
    desk,
    space: "space",
    session: "previous-session",
    owner: "owner",
    mapping: "mapping",
    policy: "policy",
  };
  const spec: QuestionSpec = {
    kind: "scoped-authorization",
    prompt: "Allow exact job commits and fast-forward?",
    options: ["Allow", "Stage only", "No"],
    origin: { event: "event", session: "shep", entry: null },
    target: {
      repo: scope.repo,
      issue: scope.issue,
      topic: "Fix",
      worktree: scope.worktree,
      desk: scope.desk,
      space: scope.space,
      session: scope.session,
      action: "scoped job",
      head: null,
      stagedTree: null,
      base: scope.baseOid,
      baseRef: scope.baseRef,
    },
    authorization: {
      scope,
      actions: ["commit", "publish-fast-forward"],
      expiresAt: "2026-11-16T13:00:00.000Z",
      allowChoice: "Allow",
      stageOnlyChoice: "Stage only",
    },
  };
  const question = store.create("ask", spec, (s) => s);
  if (["active", "paused", "ended", "expired", "stage-only", "declined"].includes(mode)) {
    const choice = mode === "stage-only" ? "Stage only" : mode === "declined" ? "No" : "Allow";
    store.answerScoped("pick", tokenOf(question), choice, "panel picker", () => ({
      status: "fresh",
      reasons: [],
      current: { head: null, stagedTree: null },
      scope,
    }));
    if (mode === "paused") store.pauseGrant("grant:Q1@1", "Facts unavailable");
    if (mode === "ended") store.revokeGrant("grant:Q1@1", "Person revoked");
    if (mode === "expired") vi.setSystemTime("2026-11-16T14:00:00.000Z");
  } else if (mode === "withdrawn") store.withdraw("withdraw", tokenOf(question), "No longer current");
  // Guard preflight may not invoke even the lock helper.
  writeFileSync(join(home, "bin/flock"), "#!/bin/sh\necho forbidden-preflight-lock >&2\nexit 98\n", { mode: 0o755 });
  return state;
}

test.each(["pending", "active", "stage-only", "paused", "ended", "expired", "withdrawn", "declined"])(
  "%s typed scope blocks raw publication even in a replacement session",
  async (mode) => {
    const state = authority(mode);
    const before = readFileSync(join(state, "questions.json"), "utf8");
    const files = readdirSync(state);
    vi.stubEnv("BERCAIL_ROLE", "autopilot");
    const h = harness();
    for (const command of ["git commit -m x", "git push origin feature", "gh stack submit"]) {
      expect(await h.call("bash", { command })).toMatchObject({
        block: true,
        reason: expect.stringMatching(/scoped_job/),
      });
    }
    expect(h.confirm).not.toHaveBeenCalled();
    expect(readFileSync(join(state, "questions.json"), "utf8")).toBe(before);
    expect(readdirSync(state)).toEqual(files);
  },
);

test("cwd descendants, symlink worktrees and matching desks retain scoped restrictions", async () => {
  authority("pending");
  const h = harness();
  const subdir = join(h.ctx.cwd, "subdir");
  mkdirSync(subdir);
  symlinkSync(h.ctx.cwd, join(home, "alias"));
  for (const cwd of [subdir, join(home, "alias"), join(home, "elsewhere")]) {
    h.ctx.cwd = cwd;
    expect(await h.call("bash", { command: "git commit -m x" })).toMatchObject({
      block: true,
      reason: expect.stringMatching(/scoped_job/),
    });
  }
  expect(h.confirm).not.toHaveBeenCalled();
});

test("missing ledger creates no state and preserves independent unscoped policy authority", async () => {
  const h = harness();
  expect(await h.call("bash", { command: "git commit -m x" })).toBeUndefined();
  expect(await h.call("bash", { command: "git push origin feature" })).toBeUndefined();
  expect(existsSync(join(process.env.XDG_STATE_HOME!, "bercail/shep"))).toBe(false);
  expect(h.confirm).not.toHaveBeenCalled();
});

test.each([
  { XDG_STATE_HOME: "relative-state", HOME: "" },
  { XDG_STATE_HOME: "relative-state", HOME: "/valid-home" },
  { XDG_STATE_HOME: "", HOME: "" },
  { XDG_STATE_HOME: "", HOME: "relative-home" },
])("invalid authority roots deny raw and structured writes: %j", async (roots) => {
  vi.stubEnv("XDG_STATE_HOME", roots.XDG_STATE_HOME);
  vi.stubEnv("HOME", roots.HOME);
  expect(() => scopedStateDir()).toThrow(/absolute/);
  const h = harness();
  vi.stubEnv("BERCAIL_ROLE", "autopilot");
  expect(await hasScopedJob(h.ctx as never)).toBe(true);
  expect(await h.call("bash", { command: "git commit -m x" })).toMatchObject({ block: true });
  await expect(h.tools.scoped_job.execute("call", preflight, undefined, undefined, h.ctx)).rejects.toThrow(/absolute/);
  expect(h.confirm).not.toHaveBeenCalled();
});

test("protected path uncertainty denies writes without throwing from preflight", async () => {
  symlinkSync("loop", join(home, "loop"));
  expect(scopedProtectedPath(join(home, "loop"))).toBe(true);
  expect(await harness().call("bash", { command: `echo x > ${home}/loop` })).toMatchObject({ block: true });
});

test("an observed scoped context never becomes unscoped when its ledger disappears", async () => {
  const state = authority("pending");
  const h = harness();
  expect(await h.call("bash", { command: "git status" })).toBeUndefined();
  rmSync(join(state, "questions.json"));
  expect(await h.call("bash", { command: "git commit -m escape" })).toMatchObject({ block: true });
  expect(await h.call("bash", { command: "git ci -m escape" })).toMatchObject({ block: true });
  const fresh = harness();
  expect(await fresh.call("bash", { command: "git commit -m independent" })).toBeUndefined();
  writeFileSync(join(home, "bin/flock"), '#!/bin/sh\nexec /usr/bin/flock "$@"\n', { mode: 0o755 });
  await expect(fresh.tools.scoped_job.execute("call", action, undefined, undefined, fresh.ctx)).rejects.toThrow(
    /unknown grant/,
  );
  expect(await h.call("bash", { command: "git commit -m escape" })).toMatchObject({ block: true });
  expect(h.confirm).not.toHaveBeenCalled();
});

test.each([action, { op: "inspect", requestId: "unknown" }, { op: "revoke", grantId: "grant:Q1@1", reason: "Stop" }])(
  "structured first interaction retains scoped denial after ledger loss: %j",
  async (request) => {
    const state = authority("pending");
    const h = harness();
    expect(await h.call("scoped_job", request)).toBeUndefined();
    rmSync(join(state, "questions.json"));
    expect(await h.call("bash", { command: "git commit -m escape" })).toMatchObject({ block: true });
    expect(h.confirm).not.toHaveBeenCalled();
  },
);

test("concurrent unscoped observation cannot clear an observed scoped denial", async () => {
  const state = authority("pending", join(home, "repo"), "different-scope-desk");
  const h = harness();
  await Promise.all([
    h.call("read", { path: "file" }),
    h.handlers.tool_call({ toolName: "read", input: { path: "file" } }, { ...h.ctx, cwd: join(home, "unrelated") }),
  ]);
  rmSync(join(state, "questions.json"));
  expect(await h.call("bash", { command: "git commit -m escape" })).toMatchObject({ block: true });
});

test("another checkout and desk are not opted into a historical scoped job", async () => {
  authority("pending", join(home, "different"), "different-desk");
  const h = harness();
  expect(await h.call("bash", { command: "git commit -m x" })).toBeUndefined();
  expect(h.confirm).not.toHaveBeenCalled();
});

test.each([
  "{broken",
  JSON.stringify({ version: 999, questions: [], requests: [], selected: null }),
  JSON.stringify({ version: 2, questions: [], requests: [], selected: null, grants: [{}], reviews: [], actions: [] }),
])("corrupt authority fails closed without a confirmation override: %s", async (raw) => {
  const state = join(process.env.XDG_STATE_HOME!, "bercail/shep");
  mkdirSync(state, { recursive: true });
  writeFileSync(join(state, "questions.json"), raw);
  const h = harness();
  expect(await h.call("bash", { command: "git push origin feature" })).toMatchObject({ block: true });
  expect(await h.call("bash", { command: "git status" })).toBeUndefined();
  expect(h.confirm).not.toHaveBeenCalled();
  expect(readFileSync(join(state, "questions.json"), "utf8")).toBe(raw);
});

test.each(["questions.json", "questions.lock", ".questions.attacker.tmp", "../scoped-locks/target.lock"])(
  "agent writes cannot replace authority or its serialization: %s",
  async (name) => {
    const state = join(process.env.XDG_STATE_HOME!, "bercail/shep");
    mkdirSync(state, { recursive: true });
    const h = harness();
    symlinkSync(state, join(home, "state-alias"));
    const path = `${home}/state-alias/${name}`;
    expect(await h.call("write", { path })).toMatchObject({ block: true });
    expect(await h.call("edit", { path })).toMatchObject({ block: true });
    for (const command of [
      `rm ${path}`,
      `cp /tmp/new ${path}`,
      `echo bad > ${path}`,
      `dd if=/tmp/new of=${path}`,
      `cd ${state}; rm ${name}`,
    ]) {
      expect(await h.call("bash", { command }), command).toMatchObject({ block: true });
    }
  },
);

test("dangling symlink aliases cannot create a replacement ledger or lock", async () => {
  const h = harness();
  const state = join(process.env.XDG_STATE_HOME!, "bercail/shep");
  symlinkSync(join(state, "questions.json"), join(home, "missing-ledger"));
  symlinkSync(join(state, "questions.lock"), join(home, "missing-lock"));
  for (const path of [join(home, "missing-ledger"), join(home, "missing-lock")]) {
    expect(await h.call("write", { path })).toMatchObject({ block: true });
    expect(await h.call("bash", { command: `echo bad > ${path}` })).toMatchObject({ block: true });
  }
});

test("a ledger symlink cannot expose its authority target to agent writes", async () => {
  const state = join(process.env.XDG_STATE_HOME!, "bercail/shep");
  mkdirSync(state, { recursive: true });
  const target = join(home, "authority-target");
  writeFileSync(target, "corrupt authority must still be protected");
  symlinkSync(target, join(state, "questions.json"));
  const h = harness();
  expect(await h.call("write", { path: target })).toMatchObject({ block: true });
  expect(await h.call("bash", { command: `rm ${target}` })).toMatchObject({ block: true });
});

test("revoke ends only the actual session's grant and cannot mint authority", async () => {
  const state = authority("active");
  const h = harness();
  h.ctx.sessionManager.getSessionId = () => "previous-session";
  writeFileSync(join(home, "bin/flock"), '#!/bin/sh\nexec /usr/bin/flock "$@"\n', { mode: 0o755 });
  const result = await h.tools.scoped_job.execute(
    "call",
    { op: "revoke", grantId: "grant:Q1@1", reason: "Stop this job" },
    undefined,
    undefined,
    h.ctx,
  );
  expect(result.details).toMatchObject({ state: "ended", reason: "Stop this job" });
  expect(new QuestionStore(state).scopedSnapshot().grants).toHaveLength(1);
});

test("a replacement session cannot revoke or inherit the old grant", async () => {
  const state = authority("active");
  const h = harness();
  writeFileSync(join(home, "bin/flock"), '#!/bin/sh\nexec /usr/bin/flock "$@"\n', { mode: 0o755 });
  await expect(
    h.tools.scoped_job.execute(
      "call",
      { op: "revoke", grantId: "grant:Q1@1", reason: "Stop" },
      undefined,
      undefined,
      h.ctx,
    ),
  ).rejects.toThrow(/actual session/);
  expect(new QuestionStore(state).scopedSnapshot().grants[0].state).toBe("active");
});

test("a grantless direct tool execution cannot borrow permissive policy", async () => {
  const h = harness();
  writeFileSync(join(home, "bin/flock"), '#!/bin/sh\nexec /usr/bin/flock "$@"\n', { mode: 0o755 });
  vi.stubEnv("BERCAIL_ROLE", "autopilot");
  await expect(h.tools.scoped_job.execute("call", action, undefined, undefined, h.ctx)).rejects.toThrow(
    /unknown grant/,
  );
  expect(h.exec).not.toHaveBeenCalled();
  expect(h.confirm).not.toHaveBeenCalled();
});

test("protected path data redirected elsewhere is not an authority write", async () => {
  const h = harness();
  expect(
    await h.call("bash", { command: `printf '%s' '${process.env.XDG_STATE_HOME}' > ${home}/diagnostic.txt` }),
  ).toBeUndefined();
});

test("trusted module roots depend only on the extension location", () => {
  expect(scopedModuleRoot("file:///checkout/bstack/pi/extensions/scoped-job.ts")).toBe("/checkout/shep/pi");
  expect(scopedModuleRoot("file:///share/bercail/pi/extensions/scoped-job.ts")).toBe("/share/bercail/shep/pi");
});

// Run the installed extension against a fake engine boundary, not the checkout or live tools.
function installed(
  input: unknown,
  options: { role?: string; preflight?: boolean; session?: string; desk?: string } = {},
) {
  const share = mkdtempSync(join(home, "installed-"));
  const extensions = join(share, "pi/extensions");
  const shep = join(share, "shep/pi");
  mkdirSync(extensions, { recursive: true });
  mkdirSync(shep, { recursive: true });
  symlinkSync(join(root, "node_modules"), join(share, "node_modules"), "dir");
  for (const name of ["guard.ts", "scoped-job.ts"])
    writeFileSync(join(extensions, name), readFileSync(join(root, "bstack/pi/extensions", name)));
  writeFileSync(
    join(shep, "questions.ts"),
    `export class QuestionStore { constructor(dir) { this.dir = dir; } scopedSnapshot() { return {grants: []}; } }`,
  );
  writeFileSync(
    join(shep, "scoped-target.ts"),
    `export function feasibility(input) { return {supported: true, input}; }`,
  );
  writeFileSync(
    join(shep, "scoped-execution.ts"),
    `export async function executeScoped(state, request, caller) { return {engine: 'execute', state: state.dir, request, caller}; } export async function inspectScoped(state, requestId, caller) { return {engine: 'inspect', state: state.dir, requestId, caller}; }`,
  );
  const script = `import {readFileSync} from 'node:fs';
    import guard from ${JSON.stringify(join(extensions, "guard.ts"))};
    const payload = JSON.parse(readFileSync(0, 'utf8'));
    const handlers = {}; let tool;
    guard({on(name, fn) {handlers[name] = fn;}, registerTool(t) {tool = t;}});
    const ctx = {cwd: ${JSON.stringify(join(home, "actual-repo"))}, hasUI: true, sessionManager: {getSessionId() {return payload.session;}}};
    try { const result = payload.preflight ? await handlers.tool_call({toolName: 'scoped_job', input: payload.input}, ctx) : await tool.execute('call', payload.input, undefined, undefined, ctx); console.log(JSON.stringify({result})); }
    catch(error) { console.log(JSON.stringify({error: error.message})); }`;
  const run = spawnSync(process.execPath, ["--input-type=module", "-e", script], {
    input: JSON.stringify({ input, preflight: options.preflight, session: options.session ?? "actual-session" }),
    encoding: "utf8",
    env: {
      ...process.env,
      HC_TERMINAL_ID: options.desk ?? "actual-desk",
      BERCAIL_ROLE: options.role ?? "builder",
      BERCAIL_SHEP_STATE: join(home, "forged-state"),
    },
    timeout: 5000,
  });
  expect(run.status, run.stderr).toBe(0);
  return JSON.parse(run.stdout);
}

test("tool execution calls the engine with fixed state, immutable candidate and actual caller", () => {
  const got = installed(action).result.details;
  expect(got).toEqual({
    engine: "execute",
    state: join(process.env.XDG_STATE_HOME!, "bercail/shep"),
    request: {
      requestId: action.requestId,
      grantId: action.grantId,
      action: action.action,
      candidate,
    },
    caller: { cwd: join(home, "actual-repo"), desk: "actual-desk", session: "actual-session", role: "builder" },
  });
});

test("preflight tool_call performs no engine execution or authority effects", () => {
  expect(installed(action, { preflight: true })).toEqual({});
});

test("incomplete preflight reports unsupported without constructing a store or engine", async () => {
  const h = harness();
  const result = await h.tools.scoped_job.execute(
    "call",
    { op: "preflight", issue: "app-1", topic: "Fix" },
    undefined,
    undefined,
    h.ctx,
  );
  expect(result.details).toMatchObject({ supported: false });
  expect(existsSync(join(process.env.XDG_STATE_HOME!, "bercail/shep"))).toBe(false);
});

test("preflight resolves scope read-only without constructing a store", () => {
  const got = installed(preflight).result.details;
  const { op: _op, ...target } = preflight;
  expect(got).toEqual({ supported: true, input: { ...target, repo: join(home, "actual-repo"), desk: "actual-desk" } });
});

test("inspect reaches only the inspection boundary", () => {
  expect(installed({ op: "inspect", requestId: "unknown" }).result.details).toEqual({
    engine: "inspect",
    state: join(process.env.XDG_STATE_HOME!, "bercail/shep"),
    requestId: "unknown",
    caller: { cwd: join(home, "actual-repo"), desk: "actual-desk", session: "actual-session", role: "builder" },
  });
});

test.each(["judge", "council", "discuss"])("%s cannot execute even when bypassing guard preflight", (role) => {
  expect(installed(action, { role })).toEqual({ error: expect.stringMatching(/read-only/) });
});

test.each([
  { op: "preflight", issue: "app-1" },
  { op: "execute", requestId: "action-1", grantId: "grant:Q1@1", action: "commit" },
  { op: "inspect" },
  { op: "inspect", requestId: "action-1", grantId: "grant:Q1@1" },
  { op: "revoke", grantId: "grant:Q1@1" },
  { ...action, cwd: "/forged" },
  { ...action, desk: "parent" },
  { ...action, session: "old" },
  { ...action, role: "autopilot" },
  { ...action, state: "/forged" },
  { ...action, command: "git push --force" },
  { ...action, flags: ["--no-verify"] },
  { ...action, candidate: { ...candidate, shell: "git push" } },
  { ...action, candidate: { ...candidate, head: "HEAD" } },
  { ...action, candidate: { ...candidate, description: "forged transcript" } },
  { ...action, candidate: { ...candidate, evidence: "tests passed" } },
  { ...action, action: "rebase" },
  { ...action, message: "Unchecked commit message" },
  { op: "approve", grantId: "grant:Q1@1" },
])("tool runtime rejects forged or open-ended fields without guard preflight: %j", (input) => {
  expect(installed(input)).toEqual({ error: expect.stringMatching(/scoped_job:/) });
});

test.each(["session", "desk"])("actual %s cannot be borrowed from a parent or a supplied grant", (field) => {
  expect(installed(action, { [field]: "" })).toEqual({
    error: expect.stringMatching(/actual cwd, desk and Pi session/),
  });
});
