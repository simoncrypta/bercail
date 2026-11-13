// The desk Pi extension's record and claim rules, with no Pi installed.
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
import desk, {
  applyClaim,
  applyDesk,
  claimPath,
  deskFields,
  deskNext,
  deskRecordPath,
  sessionIDs,
  startTicks,
  writeAtomic,
} from "../config/pi/extensions/bercail-desk.ts";

const base = {
  address: "t9",
  session: "",
  cwd: "/old",
  harness: "pi",
  issue: "bercail-1",
  space: "sp1",
  args: ["--verbose"],
  pid: 42,
};
const gate = { address: "t9", pid: 42 };
const mode = (path: string) => statSync(path).mode & 0o777;
const mtime = (path: string) => statSync(path, { bigint: true }).mtimeNs;
const readJSON = (path: string) => JSON.parse(readFileSync(path, "utf8"));

describe("startTicks", () => {
  test("reads field 22, after a comm that has spaces or a parenthesis of its own", () => {
    expect(startTicks("12 (my app) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0 424242 rest")).toBe("424242");
    expect(startTicks("12 (a) b) S " + "0 ".repeat(18) + "7\n")).toBe("7");
  });

  test("a line without comm, a missing line, or a short line has no start tick", () => {
    expect(startTicks("nope")).toBeNull();
    expect(startTicks(null)).toBeNull();
    expect(startTicks("12 (pi) S 1")).toBeNull();
  });
});

describe("deskNext", () => {
  test("a session id is stored at once; cwd only once the session has a directory", () => {
    expect(deskNext({ ...base }, { ...gate, session: "ses_a" })).toMatchObject({ session: "ses_a", cwd: "/old" });
    expect(deskNext({ ...base, session: "ses_a" }, { ...gate, session: "ses_a", cwd: "/w" })?.cwd).toBe("/w");
  });

  test("an empty session clears only the session", () => {
    const kept = deskNext({ ...base, session: "ses_old" }, { ...gate, session: "" });
    expect(kept).toMatchObject({ session: "", cwd: "/old", issue: "bercail-1" });
    expect(kept?.args[0]).toBe("--verbose");
  });

  test("an unchanged record is not rewritten", () => {
    expect(deskNext({ ...base, session: "ses_a" }, { ...gate, session: "ses_a" })).toBeNull();
  });

  test("a record for another process or terminal is left alone", () => {
    expect(deskNext({ ...base, pid: 7 }, { ...gate, session: "ses_a" })).toBeNull();
    expect(deskNext({ ...base, pid: "42" }, { ...gate, session: "ses_a" })).toBeNull();
    expect(deskNext({ ...base, harness: "other", pid: 7 }, { ...gate, session: "ses_a" })).toBeNull();
    expect(deskNext({ ...base, address: "t8" }, { ...gate, session: "ses_a" })).toBeNull();
  });

  test("a missing record, one that is not an object, or a session that is not a string is ignored", () => {
    expect(deskNext(null, { ...gate, session: "ses_a" })).toBeNull();
    expect(deskNext(["nope"], { ...gate, session: "ses_a" })).toBeNull();
    expect(deskNext({ ...base }, { ...gate, session: 1 })).toBeNull();
  });
});

describe("deskFields and sessionIDs", () => {
  test("an ephemeral session stores nothing to resume and claims nothing", () => {
    expect(deskFields(undefined, "nope", "/w")).toEqual({ session: "", cwd: "/w" });
    expect(sessionIDs(undefined, "nope")).toEqual([]);
  });

  test("a saved session is the one stored and claimed; cwd only when known; no id, no selection", () => {
    expect(sessionIDs("/tmp/ses.jsonl", "ses_a")).toEqual(["ses_a"]);
    expect(deskFields("/tmp/ses.jsonl", "ses_a", undefined)).toEqual({ session: "ses_a" });
    expect(deskFields("/tmp/ses.jsonl", "", "/w")).toBeNull();
  });
});

describe("deskRecordPath and claimPath", () => {
  test("the record lives under the state dir, by terminal, and a terminal id is not a path", () => {
    expect(deskRecordPath({ HC_TERMINAL_ID: "t9", HOME: "/h" })).toBe("/h/.local/state/bercail/desk-sessions/t9.json");
    expect(deskRecordPath({ HC_TERMINAL_ID: "t9", XDG_STATE_HOME: "/s" })).toBe("/s/bercail/desk-sessions/t9.json");
    expect(deskRecordPath({})).toBeNull();
    expect(deskRecordPath({ HC_TERMINAL_ID: "../x", HOME: "/h" })).toBeNull();
  });

  test("the claim is named by pid under the runtime dir, on Linux only", () => {
    expect(claimPath({ XDG_RUNTIME_DIR: "/run/u" }, 42)).toBe("/run/u/bercail/open-sessions/42.json");
    expect(claimPath({}, 42)).toBeNull();
    expect(claimPath({ XDG_RUNTIME_DIR: "/run/u" }, 42, "darwin")).toBeNull();
    expect(claimPath({ XDG_RUNTIME_DIR: "/run/u" }, "42")).toBeNull();
  });
});

describe("the files", () => {
  let dir: string;
  let record: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "desk-pi-unit-"));
    record = join(dir, "t9.json");
    writeFileSync(record, `${JSON.stringify(base)}\n`);
    chmodSync(record, 0o640);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("applyDesk updates the record and keeps its other fields and mode", () => {
    expect(applyDesk(record, { ...gate, session: "ses_a" })).toBe(true);
    expect(readJSON(record).issue).toBe("bercail-1");
    expect(mode(record)).toBe(0o640);
  });

  test("a second write of the same session does nothing and keeps the mtime", () => {
    applyDesk(record, { ...gate, session: "ses_a" });
    const before = mtime(record);
    expect(applyDesk(record, { ...gate, session: "ses_a" })).toBe(false);
    expect(mtime(record)).toBe(before);
  });

  test("a record that is missing, not JSON, or not an object is left alone, not replaced", () => {
    expect(applyDesk(join(dir, "missing.json"), { ...gate, session: "ses_a" })).toBe(false);
    expect(existsSync(join(dir, "missing.json"))).toBe(false);
    writeFileSync(record, "not json\n");
    expect(applyDesk(record, { ...gate, session: "ses_b" })).toBe(false);
    expect(readFileSync(record, "utf8")).toBe("not json\n");
    writeFileSync(record, "[]\n");
    expect(applyDesk(record, { ...gate, session: "ses_b" })).toBe(false);
    expect(readFileSync(record, "utf8")).toBe("[]\n");
  });

  test("a claim is written 0600, lists the open session, and is not rewritten when unchanged", () => {
    const claim = join(dir, "42.json");
    const doc = { pid: 42, start_ticks: "424242", sessions: ["ses_a"] };
    expect(applyClaim(claim, doc)).toBe(true);
    expect(mode(claim)).toBe(0o600);
    const before = mtime(claim);
    expect(applyClaim(claim, doc)).toBe(false);
    expect(mtime(claim)).toBe(before);
    expect(readJSON(claim).sessions[0]).toBe("ses_a");
  });

  test("a new file takes the mode it was given", () => {
    const file = join(dir, "mode.json");
    writeAtomic(file, "x\n", 0o600);
    expect(mode(file)).toBe(0o600);
  });
});

describe("the extension's events", () => {
  let dir: string;
  let live: string;
  let claimFile: string;
  let handlers: Record<string, (event: unknown, ctx: any) => unknown>;
  let ctx: { cwd: string; sessionManager: { getSessionFile: () => string | undefined; getSessionId: () => string } };
  const owned = { ...base, pid: process.pid, harness: "pi", session: "" };

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "desk-pi-unit-"));
    const state = join(dir, "state");
    const runtime = join(dir, "run");
    mkdirSync(join(state, "bercail/desk-sessions"), { recursive: true });
    mkdirSync(runtime, { mode: 0o700 });
    vi.stubEnv("XDG_STATE_HOME", state);
    vi.stubEnv("XDG_RUNTIME_DIR", runtime);
    vi.stubEnv("HC_TERMINAL_ID", "t9");
    vi.stubEnv("HOME", join(dir, "home"));
    live = join(state, "bercail/desk-sessions/t9.json");
    claimFile = join(runtime, "bercail/open-sessions", `${process.pid}.json`);
    writeFileSync(live, `${JSON.stringify(owned)}\n`);
    chmodSync(live, 0o640);
    handlers = {};
    desk({
      on(name: string, fn: (event: unknown, ctx: unknown) => unknown) {
        handlers[name] = fn;
      },
    } as any);
    ctx = {
      cwd: "/work",
      sessionManager: { getSessionFile: () => "/tmp/ses.jsonl", getSessionId: () => "uuid-1" },
    };
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("shutdown does not publish", () => {
    let read = false;
    handlers.session_shutdown?.(
      {},
      {
        get sessionManager() {
          read = true;
          return {};
        },
      },
    );
    expect(read).toBe(false);
  });

  test("session_start fills session and cwd, keeps the record mode, and claims the session 0600", () => {
    handlers.session_start!({}, ctx);
    expect(readJSON(live)).toMatchObject({ session: "uuid-1", cwd: "/work", issue: "bercail-1" });
    expect(mode(live)).toBe(0o640);
    expect(readJSON(claimFile).sessions[0]).toBe("uuid-1");
    expect(mode(claimFile)).toBe(0o600);
  });

  test("session_info_changed publishes the new id and claim; the same id is not rewritten", () => {
    handlers.session_start!({}, ctx);
    ctx.sessionManager.getSessionId = () => "uuid-2";
    handlers.session_info_changed!({}, ctx);
    expect(readJSON(live).session).toBe("uuid-2");
    expect(readJSON(claimFile).sessions[0]).toBe("uuid-2");
    const same = mtime(live);
    handlers.session_info_changed!({}, ctx);
    expect(mtime(live)).toBe(same);
  });

  test("an ephemeral session stores an empty id and claims nothing", () => {
    handlers.session_start!({}, ctx);
    ctx.sessionManager.getSessionFile = () => undefined;
    ctx.sessionManager.getSessionId = () => "nope";
    handlers.session_start!({}, ctx);
    expect(readJSON(live).session).toBe("");
    expect(readJSON(claimFile).sessions).toHaveLength(0);
  });

  test("a session error does not escape and leaves the stored empty id", () => {
    ctx.sessionManager.getSessionFile = () => undefined;
    handlers.session_start!({}, ctx);
    const boom = {
      sessionManager: {
        getSessionFile() {
          throw new Error("boom");
        },
      },
    };
    expect(() => handlers.session_start!({}, boom)).not.toThrow();
    expect(readJSON(live).session).toBe("");
  });

  test("the event leaves a stale record byte-for-byte", () => {
    writeFileSync(live, `${JSON.stringify({ ...owned, harness: "other", pid: 0, session: "keep" })}\n`);
    const foreign = readFileSync(live, "utf8");
    ctx.sessionManager.getSessionId = () => "uuid-3";
    handlers.session_start!({}, ctx);
    expect(readFileSync(live, "utf8")).toBe(foreign);
  });
});
