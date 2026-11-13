// review.ts's rules with no Pi installed: what the reviewer may read, and which
// desk requests it takes.
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test } from "vite-plus/test";
import { decide, inside as isInside, take, toolPath } from "../bstack/pi/extensions/review.ts";

let dir: string;
let stack: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "review-pi-"));
  stack = join(dir, "stack");
  mkdirSync(join(stack, "pr-7/abc/source"), { recursive: true });
  writeFileSync(join(stack, "pr-7/abc/diff.patch"), "+x\n");
  symlinkSync("/etc", join(stack, "escape"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

// [why, tool, input]: decide() returns null for an allowed call, a reason for a blocked one.
const inside: [string, string, Record<string, string>][] = [
  ["a file in the stack dir", "read", { path: "pr-7/abc/diff.patch" }],
  ["grep with no path searches the stack dir", "grep", { pattern: "x" }],
  ["ls with no path lists the stack dir", "ls", {}],
  ["find under the stack dir", "find", { pattern: "*.patch", path: "pr-7" }],
  ["a leading @ is Pi's file mention", "read", { path: "@pr-7/abc/diff.patch" }],
  ["a missing file inside is still inside", "read", { path: "pr-7/abc/missing.txt" }],
];
const outside: [string, string, Record<string, string>][] = [
  ["an absolute path outside", "read", { path: "/etc/hostname" }],
  ["a relative path out of the stack dir", "read", { path: "../outside" }],
  ["~ is home, outside the stack dir", "read", { path: "~/.ssh/id_ed25519" }],
  ["a symlink out of the stack dir", "read", { path: "escape/hostname" }],
  ["grep over /", "grep", { pattern: "x", path: "/" }],
];

describe("the reviewer reads only the stack dir", () => {
  test("a read, grep, find or ls inside the stack dir is allowed", () => {
    for (const [why, tool, input] of inside) expect(decide(stack, tool, input), why).toBeNull();
  });

  test("one that leaves the stack dir, by path, ~, or symlink, is blocked", () => {
    for (const [why, tool, input] of outside) expect(decide(stack, tool, input), why).not.toBeNull();
  });

  test("bash, write and edit are not reviewer tools", () => {
    for (const [tool, input] of [
      ["bash", { command: "ls" }],
      ["write", { path: "x" }],
      ["edit", { path: "x" }],
    ] as const)
      expect(decide(stack, tool, input), tool).not.toBeNull();
  });

  test("an empty path is the stack dir; a sibling with the same prefix is outside", () => {
    expect(toolPath(stack, { path: "" })).toBe(stack);
    expect(isInside(stack, stack)).toBe(true);
    expect(isInside(stack, `${stack}-other`)).toBe(false);
  });
});

describe("the desk takes live, well-formed requests in order", () => {
  let inbox: string;
  let out: string;

  beforeEach(() => {
    inbox = join(stack, "desk/inbox");
    mkdirSync(inbox, { recursive: true });
    out = join(stack, "pr-7/abc/pass.jsonl");
    const dead = spawnSync("true").pid;
    writeFileSync(join(inbox, "1-dead.json"), JSON.stringify({ prompt: "p", out, pid: dead }));
    writeFileSync(join(inbox, "2-bad.json"), "{not json");
    writeFileSync(
      join(inbox, "3-outside.json"),
      JSON.stringify({ prompt: "p", out: "/tmp/elsewhere.jsonl", pid: process.pid }),
    );
    writeFileSync(join(inbox, "4-empty.json"), JSON.stringify({ prompt: "", out, pid: process.pid }));
    writeFileSync(join(inbox, "5-ok.json"), JSON.stringify({ prompt: "review", out, pid: process.pid }));
    writeFileSync(join(inbox, "6-next.json"), JSON.stringify({ prompt: "next", out, pid: process.pid }));
    writeFileSync(join(inbox, "notes.txt"), "not a request");
  });

  test("the oldest live request is taken; a dead caller, bad JSON, an out file outside, and an empty prompt are dropped", () => {
    expect(take(stack)).toMatchObject({ name: "5-ok.json", prompt: "review", out });
    expect(readdirSync(inbox).sort(), "a taken request leaves the inbox; the next one waits").toEqual([
      "6-next.json",
      "notes.txt",
    ]);
  });

  test("the next request is taken in its turn, then nothing; no inbox gives nothing", () => {
    take(stack);
    expect(take(stack)?.prompt).toBe("next");
    expect(take(stack)).toBeNull();
    expect(take(join(dir, "nowhere"))).toBeNull();
  });
});
