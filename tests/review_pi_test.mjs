// review.ts's rules with no Pi installed: what the reviewer may read, and which
// desk requests it takes.
import { mkdirSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"

const root = new URL("..", import.meta.url)
const { decide, inside, take, toolPath } = await import(new URL("./bstack/pi/extensions/review.ts", root).href)

let failed = 0
function expect(cond, message) {
  if (cond) return
  failed += 1
  console.error(`FAIL: ${message}`)
}

const dir = mkdtempSync(join(tmpdir(), "review-pi-"))
try {
  const stack = join(dir, "stack")
  mkdirSync(join(stack, "pr-7/abc/source"), { recursive: true })
  writeFileSync(join(stack, "pr-7/abc/diff.patch"), "+x\n")
  symlinkSync("/etc", join(stack, "escape"))

  expect(decide(stack, "read", { path: "pr-7/abc/diff.patch" }) === null, "a file in the stack dir is readable")
  expect(decide(stack, "grep", { pattern: "x" }) === null, "grep with no path searches the stack dir")
  expect(decide(stack, "ls", {}) === null, "ls with no path lists the stack dir")
  expect(decide(stack, "find", { pattern: "*.patch", path: "pr-7" }) === null, "find under the stack dir")
  expect(decide(stack, "read", { path: "@pr-7/abc/diff.patch" }) === null, "a leading @ is Pi's file mention")
  expect(decide(stack, "read", { path: "pr-7/abc/missing.txt" }) === null, "a missing file inside is still inside")
  expect(decide(stack, "read", { path: "/etc/hostname" }) !== null, "an absolute path outside is blocked")
  expect(decide(stack, "read", { path: "../outside" }) !== null, "a relative path out of the stack dir is blocked")
  expect(decide(stack, "read", { path: "~/.ssh/id_ed25519" }) !== null, "~ is home, outside the stack dir")
  expect(decide(stack, "read", { path: "escape/hostname" }) !== null, "a symlink out of the stack dir is blocked")
  expect(decide(stack, "grep", { pattern: "x", path: "/" }) !== null, "grep over / is blocked")
  expect(decide(stack, "bash", { command: "ls" }) !== null, "bash is not a reviewer tool")
  expect(decide(stack, "write", { path: "x" }) !== null, "write is not a reviewer tool")
  expect(decide(stack, "edit", { path: "x" }) !== null, "edit is not a reviewer tool")
  expect(toolPath(stack, { path: "" }) === stack, "an empty path is the stack dir")
  expect(inside(stack, stack), "the stack dir is inside itself")
  expect(!inside(stack, `${stack}-other`), "a sibling with the same prefix is outside")

  const inbox = join(stack, "desk/inbox")
  mkdirSync(inbox, { recursive: true })
  const dead = spawnSync("true").pid
  const out = join(stack, "pr-7/abc/pass.jsonl")
  writeFileSync(join(inbox, "1-dead.json"), JSON.stringify({ prompt: "p", out, pid: dead }))
  writeFileSync(join(inbox, "2-bad.json"), "{not json")
  writeFileSync(join(inbox, "3-outside.json"), JSON.stringify({ prompt: "p", out: "/tmp/elsewhere.jsonl", pid: process.pid }))
  writeFileSync(join(inbox, "4-empty.json"), JSON.stringify({ prompt: "", out, pid: process.pid }))
  writeFileSync(join(inbox, "5-ok.json"), JSON.stringify({ prompt: "review", out, pid: process.pid }))
  writeFileSync(join(inbox, "6-next.json"), JSON.stringify({ prompt: "next", out, pid: process.pid }))
  writeFileSync(join(inbox, "notes.txt"), "not a request")
  const req = take(stack)
  expect(req && req.name === "5-ok.json" && req.prompt === "review" && req.out === out,
    "the oldest live request is taken; a dead caller, bad JSON, an out file outside, and an empty prompt are dropped")
  expect(JSON.stringify(readdirSync(inbox).sort()) === JSON.stringify(["6-next.json", "notes.txt"]),
    "a taken request leaves the inbox; the next one waits")
  expect(take(stack)?.prompt === "next", "the next request is taken in its turn")
  expect(take(stack) === null, "an empty inbox gives nothing")
  expect(take(join(dir, "nowhere")) === null, "no inbox gives nothing")
} finally {
  rmSync(dir, { recursive: true, force: true })
}

if (failed) process.exit(1)
console.log("PASS: review.ts reads only the stack dir and takes live, well-formed desk requests in order")
