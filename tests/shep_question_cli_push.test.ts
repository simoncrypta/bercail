// Question-cli.ts's push approvals and guard cards, and the land and guard events
// Shep reads.
// The fixture is tests/shep_question_cli_fixture.ts.
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { beforeEach, describe, expect, test } from "vite-plus/test";
import { claim, eventLine } from "../shep/pi/inbox.ts";
import {
  cli,
  node,
  dir,
  repo,
  env,
  json,
  git,
  call,
  ok,
  spec,
  events,
  event,
  pick,
} from "./shep_question_cli_fixture.ts";

// A push question (bercail-gmd4): the guard asks push-approval which answer approves a
// push, then claims it once. The remote is a bare repo beside the checkout.
describe("an answer that approves a push", () => {
  let ref: string;
  let origin: string;
  // The guard's call: the answer that approves this push, spent on it.
  const approval = (refspecs: string[], from = repo) => ok("push-approval", undefined, [from, "origin", ...refspecs]);
  const head = () => `${git("rev-parse", "HEAD")}^{commit}:${ref}`;
  const ask = (extra: Record<string, unknown> = {}) =>
    ok(
      "create",
      spec({ options: ["Push it", "Not yet"], push: { approves: "Push it", remote: "origin", refs: [ref] }, ...extra }),
    );
  beforeEach(() => {
    ref = git("symbolic-ref", "HEAD");
    origin = join(dir, "origin.git");
    execFileSync("git", ["init", "-q", "--bare", origin], { env });
    git("remote", "add", "origin", origin);
  });

  test("records the remote's one push URL, and refuses a push nothing can bind or show", () => {
    expect(ask({ push: { approves: "Push it", remote: "origin", refs: [ref], url: "forged" } }).push).toEqual({
      approves: "Push it",
      remote: "origin",
      refs: [ref],
      url: origin,
    });
    const refused = (extra: Record<string, unknown>, message: RegExp) => {
      const result = call(
        "create",
        spec({ requestId: `r-${Math.random()}`, options: ["Push it", "Not yet"], ...extra }),
      );
      expect(result.status).not.toBe(0);
      expect(result.stderr).toMatch(message);
    };
    const push = { approves: "Push it", remote: "origin", refs: [ref] };
    refused({ push: { ...push, approves: "Ship" } }, /push.approves must be one of the options/);
    refused({ kind: "planning", issue: null, desk: null, base: null, action: null, push }, /planning question/);
    refused({ push, reversible: true, recommendation: { choice: "Push it", why: "ok" } }, /one-way door/);
    refused({ push: { ...push, refs: ["refs/tags/v1"] } }, /a tag push needs action release/);
    refused({ push: { ...push, refs: ["master"] } }, /full refs/);
    git("remote", "set-url", "--add", "--push", "origin", origin);
    git("remote", "set-url", "--add", "--push", "origin", join(dir, "mirror.git"));
    refused({ push }, /origin must push to one URL, not 2/);
    git("config", "--unset-all", "remote.origin.pushurl");
    // Only a URL the card can show without a credential, nor one a linked checkout reads elsewhere.
    for (const url of [
      "https://bot:s3cret@example.invalid/app.git",
      "https://s3cret@example.invalid/app.git",
      "https://example.invalid/app.git?token=s3cret",
      "ssh://git:s3cret@example.invalid/app.git",
      "entire://bot@aws-us-east-2.entire.io/et/team/app",
      "../origin.git",
      "/srv/app\u0007.git",
    ]) {
      git("remote", "set-url", "origin", url);
      refused({ push }, /not one the card can show/);
    }
    expect(JSON.stringify(ok("json"))).not.toContain("s3cret");
    git("remote", "set-url", "origin", "git@example.invalid:team/app.git");
    expect(ask({ requestId: "ssh" }).push.url).toBe("git@example.invalid:team/app.git");
    git("remote", "set-url", "origin", "entire://aws-us-east-2.entire.io/et/team/app");
    expect(ask({ requestId: "entire" }).push.url).toBe("entire://aws-us-east-2.entire.io/et/team/app");
  });

  test("the person's pick of the approving choice approves exactly that push, once", () => {
    ask();
    pick("p1", "Push it");
    expect(approval([head()])).toEqual({ approved: "Q1@1" });
    expect(ok("json").questions[0].pushed).toMatchObject({ remote: "origin", refspecs: [head()] });
    // The same answer cannot approve a second push.
    expect(approval([head()])).toEqual({
      approved: null,
      reason: expect.stringMatching(/^Q1@1 already approved a push, at /),
    });
  });

  test.each([
    ["the other choice", () => pick("p1", "Not yet"), () => [head()], /Q1@1 was answered "Not yet", not "Push it"/],
    [
      "a Discuss pick, which an agent could type",
      () => pick("p1", "Push it", "Q1@1", "discuss picker"),
      () => [head()],
      /Q1@1 was answered by the discuss picker; only a pick on the panel card approves a push/,
    ],
    [
      "a check gone stale",
      () => {
        pick("p1", "Push it");
        writeFileSync(join(repo, "file"), "two\n");
        git("add", "file");
      },
      () => [head()],
      /Q1@1 changed since it was answered: stagedTree changed/,
    ],
    [
      "another commit",
      () => pick("p1", "Push it"),
      () => {
        writeFileSync(join(repo, "other"), "unreviewed\n");
        git("add", "other");
        const tree = git("write-tree");
        git("rm", "-q", "--cached", "other");
        const other = execFileSync("git", ["-C", repo, "commit-tree", tree, "-p", git("rev-parse", "HEAD")], {
          env,
          input: "unreviewed\n",
          encoding: "utf8",
        }).trim();
        return [`${other}^{commit}:${ref}`];
      },
      /Q1@1 approves only [0-9a-f]{40}$/,
    ],
    [
      "another ref",
      () => pick("p1", "Push it"),
      () => [head().replace(/:.*/, ":refs/heads/other")],
      /approves a push to origin/,
    ],
    [
      "a hash a ref could shadow",
      () => pick("p1", "Push it"),
      () => [`${git("rev-parse", "HEAD")}:${ref}`],
      /each refspec must be <hash>\^\{commit\}:<full ref>/,
    ],
    [
      "a remote that now pushes elsewhere",
      () => {
        pick("p1", "Push it");
        git("remote", "set-url", "origin", join(dir, "elsewhere.git"));
      },
      () => [head()],
      /origin no longer pushes to the URL the card showed/,
    ],
    [
      "config git cannot read",
      () => {
        pick("p1", "Push it");
        git("config", "push.followTags", "maybe");
      },
      () => [head()],
      /could not read push.followTags/,
    ],
    [
      "config that pushes tags too",
      () => {
        pick("p1", "Push it");
        git("config", "push.followTags", "true");
      },
      () => [head()],
      /push.followTags would push tags too/,
    ],
  ])("refuses %s", (_name, arrange, refspecs, reason) => {
    ask();
    arrange();
    expect(approval(refspecs())).toEqual({ approved: null, reason: expect.stringMatching(reason) });
    expect(ok("json").questions[0].pushed).toBeUndefined();
  });

  test("refuses the push from another repo, and while nobody has picked", () => {
    ask();
    expect(approval([head()]).reason).toBe("no answered question in this repo approves a push");
    pick("p1", "Push it");
    const other = join(dir, "other");
    execFileSync("git", ["clone", "-q", repo, other], { env });
    execFileSync("git", ["-C", other, "remote", "set-url", "origin", origin], { env });
    expect(approval([head()], other)).toEqual({
      approved: null,
      reason: "no answered question in this repo approves a push",
    });
  });

  test("the reviewed tree committed once on the answered HEAD is approved, a sibling commit of it is not", () => {
    writeFileSync(join(repo, "file"), "two\n");
    git("add", "file");
    ask();
    pick("p1", "Push it");
    const answered = git("rev-parse", "HEAD");
    git("commit", "-qm", "the reviewed tree");
    const sibling = execFileSync("git", ["-C", repo, "commit-tree", git("write-tree"), "-p", answered], {
      env,
      input: "same tree, another commit\n",
      encoding: "utf8",
    }).trim();
    expect(approval([`${sibling}^{commit}:${ref}`]).reason).toMatch(/Q1@1 approves only /);
    expect(approval([head()])).toEqual({ approved: "Q1@1" });
  });

  test("a push sends one approved commit to every ref, not the answered HEAD to one and its child to another", () => {
    writeFileSync(join(repo, "file"), "two\n");
    git("add", "file");
    const answered = git("rev-parse", "HEAD");
    ask({ action: "release", push: { approves: "Push it", remote: "origin", refs: [ref, "refs/tags/v1.0.0"] } });
    pick("p1", "Push it");
    git("commit", "-qm", "the reviewed tree");
    git("tag", "-a", "v1.0.0", "-m", "v1.0.0", answered);
    const tag = `${git("rev-parse", "v1.0.0")}^{tag}:refs/tags/v1.0.0`;
    expect(approval([head(), tag]).reason).toMatch(/Q1@1 approves only /);
    expect(approval([`${answered}^{commit}:${ref}`, tag])).toEqual({ approved: "Q1@1" });
  });

  test("a release question approves its tag object and its branch together, and only together", () => {
    git("tag", "-a", "v1.0.0", "-m", "v1.0.0");
    const tag = `${git("rev-parse", "v1.0.0")}^{tag}:refs/tags/v1.0.0`;
    ask({ action: "release", push: { approves: "Push it", remote: "origin", refs: [ref, "refs/tags/v1.0.0"] } });
    pick("p1", "Push it");
    expect(approval([tag]).reason).toMatch(/approves a push to origin/);
    expect(approval([`${git("rev-parse", "v1.0.0")}^{tag}:${ref}`]).reason).toBe("only a tag ref takes a tag object");
    expect(approval([head(), tag])).toEqual({ approved: "Q1@1" });
  });
});

// A guard card (docs/plans/shep-free-guard.md): the guard's worker asks the person to
// Allow an operation it pinned. bercail guard check is a stand-in that prints the
// reasons in guard-check.json.
describe("a guard card", () => {
  const ticket = "0123456789ab";
  const expires = (minutes: number) => new Date(Date.now() + minutes * 60000).toISOString();
  const facts = {
    kind: "push",
    dir: "",
    gitDir: "",
    url: "/srv/origin.git",
    refspecs: [`${"a".repeat(40)}:refs/heads/x`],
  };
  const card = (extra: Record<string, unknown> = {}) =>
    call("guard-create", {
      requestId: `guard-${ticket}`,
      prompt: "Allow this push to origin: x? No keeps it local for the person.",
      brief: "Shep ran: git -C repo push origin x.",
      origin: { event: `guard:${ticket}`, session: "shep-session", entry: null },
      dir: repo,
      guard: {
        ticket,
        worker: `guard-ask-${ticket}`,
        op: { kind: "push", dir: repo, remote: "origin", refspecs: ["x"] },
        facts: { ...facts, dir: repo },
        expires: hour,
      },
      ...extra,
    });
  const reasons = (list: string[]) => json(join(dir, "guard-check.json"), { reasons: list });
  let hour: string;
  beforeEach(() => {
    hour = expires(60);
    reasons([]);
    writeFileSync(
      join(dir, "bin/bercail"),
      `#!/bin/sh\nprintf 'bercail %s\\n' "$*" >> '${dir}/argv'\ntest "$1 $2" = 'guard check' || exit 2\n/bin/cat > '${dir}/guard-check.in'\n/bin/cat '${dir}/guard-check.json'\n`,
      { mode: 0o755 },
    );
  });

  test("offers Allow and Deny on the repo of the folder it acts in, with no recommendation or default", () => {
    const created = card();
    expect(created.stderr).toBe("");
    expect(JSON.parse(created.stdout)).toMatchObject({
      kind: "guard",
      options: ["Allow", "Deny"],
      target: { repo: join(repo, ".git"), worktree: repo, topic: `guard-${ticket}`, issue: null, desk: null },
      guard: { ticket, worker: `guard-ask-${ticket}` },
    });
    // The same request again is its receipt: two workers on one ticket share one card.
    expect(JSON.parse(card().stdout).id).toBe("Q1");
    // Its live check sends the card's op and facts to bercail guard check.
    expect(ok("check", undefined, ["Q1@1"])).toMatchObject({ status: "fresh", reasons: [] });
    expect(JSON.parse(readFileSync(join(dir, "guard-check.in"), "utf8"))).toEqual({
      op: { kind: "push", dir: repo, remote: "origin", refspecs: ["x"] },
      facts: { ...facts, dir: repo },
    });
    for (const [extra, why] of [
      [
        {
          requestId: "r1",
          guard: {
            ticket,
            worker: "guard-ask-other",
            op: { kind: "push" },
            facts: {},
            expires: expires(60),
          },
        },
        /names its ticket/,
      ],
      [
        {
          requestId: "r2",
          guard: {
            ticket,
            worker: `guard-ask-${ticket}`,
            op: { kind: "rm" },
            facts: {},
            expires: expires(60),
          },
        },
        /holds its operation/,
      ],
    ] as const) {
      const refused = card(extra);
      expect(refused.status).not.toBe(0);
      expect(refused.stderr).toMatch(why);
    }
  });

  test("takes a panel pick once, refuses Discuss and a stale or expired card, and tells Shep its worker acts", () => {
    card();
    // Discuss can talk it over, not pick: an agent can type into that terminal.
    expect(pick("d1", "Allow", "Q1@1", "discuss picker")).toMatchObject({
      accepted: false,
      reason: "a guard card is answered on the panel card only",
    });
    reasons(["url changed"]);
    expect(pick("p0", "Allow")).toMatchObject({ accepted: false, reason: "changed since Shep asked: url changed" });
    reasons([]);
    expect(pick("p1", "Allow")).toMatchObject({ accepted: true });
    const decision = event("decision-Q1-1.json");
    expect(decision).toMatchObject({ choice: "Allow", by: "panel picker", guard: { worker: `guard-ask-${ticket}` } });
    expect(eventLine(decision)).toMatch(
      new RegExp(`Its worker guard-ask-${ticket} acts on it, not you: do not run it, retry it or ask again`),
    );
    // Its worker claims the Allow once.
    expect(ok("guard-claim", undefined, ["Q1@1", "ffffffffffff"])).toMatchObject({
      accepted: false,
      reason: "not this ticket's guard card",
    });
    expect(ok("guard-claim", undefined, ["Q1@1", ticket])).toMatchObject({ accepted: true });
    expect(ok("guard-claim", undefined, ["Q1@1", ticket]).reason).toMatch(/already claimed/);
    // The questions Shep acts on once leave a guard card out.
    expect(call("list").stdout).not.toMatch(/Answered by the person's pick/);
  });

  test("the person's Close withdraws it for its worker to report, with no decision event of its own", () => {
    card();
    expect(ok("answer", { requestId: "c1", token: "Q1@1", source: "panel picker", outcome: "closed" })).toMatchObject({
      accepted: true,
      question: { status: "withdrawn", withdrawal: { source: "panel picker" } },
    });
    expect(events()).toEqual([]);
    expect(ok("guard-claim", undefined, ["Q1@1", ticket])).toMatchObject({ accepted: false });
  });

  test("a card past its hour is stale and takes no pick, and a Deny is never claimed", () => {
    card({
      requestId: "old",
      guard: {
        ticket,
        worker: `guard-ask-${ticket}`,
        op: { kind: "push" },
        facts: { kind: "push" },
        expires: expires(-1),
      },
    });
    expect(ok("check", undefined, ["Q1@1"])).toMatchObject({
      status: "stale",
      reasons: [expect.stringMatching(/^expired at /)],
    });
    expect(pick("p1", "Allow").accepted).toBe(false);
    card();
    expect(pick("p2", "Deny", "Q2@1")).toMatchObject({ accepted: true });
    expect(ok("guard-claim", undefined, ["Q2@1", ticket]).reason).toBe("not the person's Allow on the panel");
  });

  // bercail-mdfb: a card that said it defaults counts as an Allow at its deadline.
  const defaulting = (minutes: number, why = "it pushes to the private GitHub repo acme/app") =>
    card({
      requestId: `guard-${minutes}-${Math.random()}`,
      guard: {
        ticket,
        worker: `guard-ask-${ticket}`,
        op: { kind: "push" },
        facts: { kind: "push" },
        expires: expires(minutes),
        defaults: { why },
      },
    });
  // The helper `minutes` on: a clock module moves Date for its process.
  const later = (op: string, input: unknown, args: string[], minutes = 61) => {
    const clock = join(dir, "clock.mjs");
    writeFileSync(
      clock,
      "const Real = Date; const off = Number(process.env.CLOCK_MS);\n" +
        "globalThis.Date = class extends Real { constructor(...a) { super(...(a.length ? a : [Real.now() + off])); } static now() { return Real.now() + off; } };\n",
    );
    const result = spawnSync(node, ["--import", clock, cli, op, ...args], {
      env: { ...env, CLOCK_MS: String(minutes * 60000) },
      cwd: dir,
      encoding: "utf8",
      input: JSON.stringify(input),
    });
    expect(result.stderr).toBe("");
    return JSON.parse(result.stdout);
  };
  const why = "it pushes to the private GitHub repo acme/app";
  const fallback = (token: string, said = why, minutes = 61) =>
    later("guard-default", { why: said }, [token, ticket], minutes);

  test("its worker records the default only past the deadline, on a pending card that said it defaults, as it said it", () => {
    defaulting(60);
    expect(fallback("Q1@1", why, 59)).toMatchObject({
      accepted: false,
      reason: expect.stringMatching(/^not past its deadline/),
    });
    card({
      requestId: "waits",
      guard: {
        ticket,
        worker: `guard-ask-${ticket}`,
        op: { kind: "push" },
        facts: { kind: "push" },
        expires: expires(60),
      },
    });
    expect(fallback("Q2@1").reason).toBe("it waits for the person: nobody answering counts as a Deny");
    // A card that went up with less than most of its hour left never defaults.
    defaulting(-1);
    expect(fallback("Q3@1").reason).toBe("it went up too late to give the person most of its hour");
    defaulting(60);
    expect(fallback("Q4@1", "it pushes to the private GitHub repo acme/other").reason).toMatch(
      /no longer reads as it did/,
    );
    expect(later("guard-default", { why }, ["Q4@1", "ffffffffffff"]).reason).toBe("not this ticket's guard card");
    // Past its deadline the person's Allow is refused, and the card's default is not theirs.
    expect(
      later("answer", { requestId: "late", token: "Q4@1", choice: "Allow", source: "panel picker" }, []).reason,
    ).toMatch(/expired at .*, which counts as an Allow if it still reads private or local/);
    // Long after its deadline (a machine that slept), its reading is stale.
    expect(fallback("Q4@1", why, 75).reason).toBe("it is too long past its deadline: its reading is stale");
    expect(fallback("Q4@1")).toMatchObject({
      accepted: true,
      question: { status: "answered", answer: { choice: "Allow", source: "guard default at expiry" } },
    });
    expect(fallback("Q4@1").reason).toBe("question is answered");
    // Its worker claims it once; no decision event, no OK or Reverse, and it leaves the panel.
    expect(later("guard-claim", undefined, ["Q4@1", ticket])).toMatchObject({ accepted: true });
    expect(later("guard-claim", undefined, ["Q4@1", ticket]).reason).toMatch(/already claimed/);
    expect(events()).toEqual([]);
    expect(ok("answer", { requestId: "ok1", token: "Q4@1", source: "panel picker", outcome: "ok" }).reason).toMatch(
      /not defaulted/,
    );
    expect(ok("panel").cards.map((c: { token: string }) => c.token)).not.toContain("Q4@1");
    expect(ok("pending").pending.map((q: { id: string }) => q.id)).not.toContain("Q4");
  });

  test("the person's Deny stands with no live check, even past the deadline, and no default replaces it", () => {
    defaulting(60);
    // Past its deadline, with a check that cannot finish: the Deny does not wait on it.
    writeFileSync(join(dir, "bin/bercail"), "#!/bin/sh\nexit 3\n", { mode: 0o755 });
    expect(
      later("answer", { requestId: "no", token: "Q1@1", choice: "Deny", source: "panel picker" }, []),
    ).toMatchObject({
      accepted: true,
      question: { answer: { choice: "Deny", source: "panel picker" } },
    });
    expect(fallback("Q1@1").reason).toBe("question is answered");
    expect(ok("guard-claim", undefined, ["Q1@1", ticket]).reason).toBe("not the person's Allow on the panel");
    // Its panel card says whether it defaults, and when.
    defaulting(30);
    expect(ok("panel").cards.find((c: { token: string }) => c.token === "Q2@1").guard).toMatchObject({
      defaults: true,
    });
  });

  test("a push approval never spends a guard card's Allow", () => {
    execFileSync("git", ["init", "-q", "--bare", join(dir, "origin.git")], { env });
    git("remote", "add", "origin", join(dir, "origin.git"));
    card();
    pick("p1", "Allow");
    const head = `${git("rev-parse", "HEAD")}^{commit}:${git("symbolic-ref", "HEAD")}`;
    expect(ok("push-approval", undefined, [repo, "origin", head])).toEqual({
      approved: null,
      reason: "no answered question in this repo approves a push",
    });
  });
});

test("a land event is Shep's line from its fields alone, never a command for the person, and a malformed one is dropped", () => {
  const sha = "76d6a4f91b2f77e82054244a440aed4280fc9f0b";
  const ev = {
    source: "bercail",
    schema: "bercail.land/v2",
    kind: "land",
    sink: "shep",
    event_id: "land:Q12@1",
    question: "Q12@1",
    repo: "bercail",
    issue: "bercail-fq7y",
    branch: "one-pick-landing",
    trunk: "master",
    commit: sha,
    outcome: "landed",
    step: "sync",
    why: null,
    warnings: [],
    log: "/state/bercail/land/Q12-1.log",
  };
  expect(eventLine(ev)).toBe(
    "- bercail-fq7y landed on master as 76d6a4f91b2f in bercail from the person's pick on Q12@1 (branch one-pick-landing). Tell the person in one line; its log is /state/bercail/land/Q12-1.log. [event land:Q12@1]",
  );
  expect(eventLine({ ...ev, trusted: "a".repeat(64) })).toContain(
    "(branch one-pick-landing). It now trusts bercail's new .bercail/policy.toml (sha256 aaaaaaaaaaaa), as the card said. Tell the person",
  );
  expect(eventLine({ ...ev, warnings: ["the desk and its worktree stay: clean changed"] })).toContain(
    "Not done after it landed: the desk and its worktree stay: clean changed. Handle that yourself or with the desk; never hand the person a command.",
  );
  expect(eventLine({ ...ev, outcome: "ci-failed", step: "ci", why: ".github/workflows/ci.yml failure" })).toBe(
    "- bercail-fq7y's land card Q12@1 (branch one-pick-landing in bercail) stopped before landing: a required CI workflow did not pass at its ci step, after it made 76d6a4f91b2f (.github/workflows/ci.yml failure). The job stays open. Send the desk the failed run to fix, then ask a new land card; never hand the person a command. Tell the person in one line; its log is /state/bercail/land/Q12-1.log. [event land:Q12@1]",
  );
  expect(eventLine({ ...ev, outcome: "changed", step: "check", commit: null, why: "stagedTree changed" })).toMatch(
    /stopped before landing: something it was pinned to changed since the pick at its check step \(stagedTree changed\)\. The job stays open\./,
  );
  // A mapping of its own: one land event is never taken for a desk's.
  const inbox = join(dir, "inbox");
  const delivered = join(dir, "delivered");
  mkdirSync(inbox);
  mkdirSync(delivered);
  writeFileSync(join(inbox, "land-Q12-1.json"), JSON.stringify(ev));
  expect(claim(inbox, delivered).map((t) => t.name)).toEqual(["land-Q12-1.json"]);
  for (const bad of [
    { ...ev, outcome: "merged" },
    { ...ev, outcome: "constructor" },
    { ...ev, event_id: "land:Q13@1" },
    { ...ev, question: "Q12" },
    { ...ev, commit: null },
    { ...ev, commit: "nope" },
    { ...ev, step: "deploy" },
    { ...ev, issue: "rm -rf /; echo" },
    { ...ev, branch: "" },
    { ...ev, warnings: [" "] },
    { ...ev, warnings: "none" },
    { ...ev, schema: "bercail.land/v3" },
    { ...ev, trusted: "nope" },
    { ...ev, outcome: "changed", step: "check", trusted: "a".repeat(64) },
  ])
    expect(eventLine(bad), JSON.stringify(bad)).toBeNull();
});

test("a guard event is Shep's line from its fields alone, and a malformed one is dropped", () => {
  const ev = {
    source: "bercail",
    schema: "bercail.guard_ask/v1",
    kind: "guard",
    sink: "shep",
    event_id: "guard:0123456789ab",
    terminal: "guard-ask-0123456789ab",
    operation: "trail merge",
    target: "lesentiel/41",
    outcome: "ran",
    exit: 0,
    log: "/state/bercail/guard-asks/0123456789ab.log",
  };
  expect(eventLine(ev)).toBe(
    "- The trail merge of lesentiel/41 you handed off ran on the person's Allow, exit 0; its output is in /state/bercail/guard-asks/0123456789ab.log. Tell the person in one line. [event guard:0123456789ab] (worker guard-ask-0123456789ab)",
  );
  expect(eventLine({ ...ev, outcome: "changed", exit: undefined, log: undefined, why: "head changed" })).toBe(
    "- The trail merge of lesentiel/41 you handed off acts on something that changed since it was asked, so nothing ran; ask again only if it still matters (head changed). Tell the person in one line. [event guard:0123456789ab] (worker guard-ask-0123456789ab)",
  );
  // Any other command, by its words.
  expect(eventLine({ ...ev, operation: "command", target: "entire trail link 41 --branch b" })).toBe(
    "- The command entire trail link 41 --branch b you handed off ran on the person's Allow, exit 0; its output is in /state/bercail/guard-asks/0123456789ab.log. Tell the person in one line. [event guard:0123456789ab] (worker guard-ask-0123456789ab)",
  );
  // A default at the deadline says so, never as the person's Allow.
  expect(eventLine({ ...ev, defaulted: true })).toBe(
    "- The trail merge of lesentiel/41 you handed off ran by default at its deadline (nobody answered, and it still read private or local; not the person's Allow), exit 0; its output is in /state/bercail/guard-asks/0123456789ab.log. Tell the person in one line that it was defaulted, not picked. [event guard:0123456789ab] (worker guard-ask-0123456789ab)",
  );
  expect(
    eventLine({
      ...ev,
      defaulted: true,
      outcome: "expired",
      exit: undefined,
      log: undefined,
      why: "nobody answered, and right before the run the Entire repo et/acme/app is public",
    }),
  ).toBe(
    "- The trail merge of lesentiel/41 you handed off defaulted to Allow at its deadline, but no longer read private or local right before the run; nothing ran (nobody answered, and right before the run the Entire repo et/acme/app is public). Tell the person in one line that it was defaulted, not picked. [event guard:0123456789ab] (worker guard-ask-0123456789ab)",
  );
  for (const bad of [
    { ...ev, defaulted: "yes" },
    { ...ev, defaulted: false },
    { ...ev, outcome: "merged" },
    { ...ev, operation: "rm -rf" },
    { ...ev, terminal: "t9" },
    { ...ev, event_id: "guard:ffffffffffff" },
    { ...ev, exit: undefined },
    { ...ev, outcome: "denied" },
    { ...ev, schema: "bercail.land/v1" },
    { ...ev, target: " " },
    { ...ev, outcome: "constructor", exit: undefined },
  ])
    expect(eventLine(bad), JSON.stringify(bad)).toBeNull();
  // A decision on a guard card needs its worker, and only a panel pick has one.
  const decision = {
    source: "bercail",
    kind: "decision",
    event_id: "decision:Q1-1",
    question: { token: "Q1@1", prompt: "Allow this push?", topic: "guard-0123456789ab" },
    choice: "Allow",
    by: "panel picker",
    guard: { worker: "guard-ask-0123456789ab" },
  };
  expect(eventLine(decision)).toMatch(
    /^- The person picked "Allow" on the panel for a guard card\. Its worker guard-ask-0123456789ab acts on it/,
  );
  expect(eventLine({ ...decision, by: "discuss picker" })).toBeNull();
  expect(eventLine({ ...decision, guard: { worker: "t9" } })).toBeNull();
});
