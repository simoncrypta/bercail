#!/usr/bin/env bash
# shellcheck shell=bash
# The bercail-review mod (the review-pr Stack tab), headless: a fixture run dir
# through `bercail review-pr state`, then the mod's render() and keys in node
# against stubs of gpui-kit and herdr. The rendered text is a snapshot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for bin in node jq; do
  command -v "$bin" >/dev/null 2>&1 || { printf 'SKIP: %s not found\n' "$bin"; exit 0; }
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- a run dir: #7 reviewed (CI, bot threads), #8 thin and waiting on top of it ----
S="$TMP_DIR/stack-7"
D7="$S/pr-7/aaaaaaa1111111"
D8="$S/pr-8/bbbbbbb2222222"
mkdir -p "$D7" "$D8"
jq -n --arg wt "$TMP_DIR/widgets.review-7" --arg src "$TMP_DIR" '{schema: "bercail.stack/v1", host: "github.com", owner: "acme", repo: "widgets",
  via: "github", trunk: "main", root: 7, current: 7, worktree: $wt, source: $src, space: null,
  prs: [
    {number: 7, title: "Retry flaky uploads", author: "dana", url: "https://github.com/acme/widgets/pull/7", draft: false,
     base: "main", head: "retry", head_sha: "aaaaaaa1111111", base_sha: "0000000", linked: [12], linear: [], thin: [],
     intent: "Adds a retry helper so uploads stop failing."},
    {number: 8, title: "Docs", author: "dana", url: "https://github.com/acme/widgets/pull/8", draft: true,
     base: "retry", head: "docs", head_sha: "bbbbbbb2222222", base_sha: "aaaaaaa1111111", linked: [], linear: [],
     thin: ["empty_body", "no_linked_issue"], intent: ""}]}' >"$S/stack.json"
printf '# Stack #7 acme/widgets\n\nvia github, trunk main\n' >"$S/stack.md"
cat >"$D7/review.json" <<'EOF'
{"schema": "bercail.review/v1", "pr": 7, "head_sha": "aaaaaaa1111111", "session_id": "ses_1",
 "why": "Uploads fail on flaky networks.", "why_source": "issue #12",
 "decisions": [
  {"kind": "approach", "statement": "Retries live in a new retry.sh helper",
   "evidence": [{"file": "lib/retry.sh", "line": 3, "end_line": 9, "side": "new"}],
   "stated": "PR body: adds a retry helper", "fits_intent": "yes", "alternative": null, "question": null},
  {"kind": "behavior", "statement": "Uploads retry 5 times with no backoff",
   "evidence": [{"file": "lib/upload.sh", "line": 12, "side": "new"}],
   "stated": null, "fits_intent": "partial", "alternative": "exponential backoff",
   "question": "Why 5 retries with no backoff?"}],
 "unmet_intent": [{"promise": "Log each retry", "source": "issue #12", "question": "Is logging in another PR?"}],
 "questions": [{"text": "Should this ship behind a flag?"}]}
EOF
echo '{"status": "ready", "summary": "2 decisions, 1 undocumented, 1 unmet, 3 questions", "session_id": "ses_1"}' >"$D7/run.json"
cat >"$D7/ci.json" <<'EOF'
[{"name": "test", "bucket": "pass", "state": "SUCCESS", "workflow": "CI", "link": "https://ci/test"},
 {"name": "lint", "bucket": "fail", "state": "FAILURE", "workflow": "CI", "link": "https://ci/lint"}]
EOF
cat >"$D7/bots.json" <<'EOF'
{"threads": [{"path": "lib/upload.sh", "line": 12, "isResolved": false, "author": {"login": "coderabbitai[bot]"}},
             {"path": "README", "line": 1, "isResolved": true, "author": {"login": "cursor[bot]"}}],
 "reviews": [{"author": {"login": "coderabbitai[bot]"}}], "comments": []}
EOF
echo '[]' >"$D8/ci.json"

"$ROOT/bin/bercail" review-pr state --stack "$S" >"$TMP_DIR/state.json" || fail "review-pr state"
jq -e '.schema == "bercail.review-ui/v1" and (.prs | length) == 2 and .header != null
  and .prs[0].pass == "ready" and .prs[1].pass == "waiting" and .prs[1].review == null
  and .prs[0].bots.unresolved == 1 and .prs[0].bots.on_decisions == 1
  and (.prs[0].questions | map(.at)) == ["lib/upload.sh:12", null, null]' "$TMP_DIR/state.json" >/dev/null \
  || fail "state JSON: $(cat "$TMP_DIR/state.json")"
printf 'PASS: review-pr state reads the run dir: pass status, questions, bots, header\n'

# A stack of one: no header, one PR.
S1="$TMP_DIR/stack-9"
mkdir -p "$S1/pr-7"
cp -R "$D7" "$S1/pr-7/"
jq --arg wt "$TMP_DIR/widgets.review-9" '.prs |= .[0:1] | .worktree = $wt' "$S/stack.json" >"$S1/stack.json"
"$ROOT/bin/bercail" review-pr state --stack "$S1" >"$TMP_DIR/state1.json" || fail "review-pr state (one PR)"
jq -e '.header == null and (.prs | length) == 1' "$TMP_DIR/state1.json" >/dev/null || fail "stack of one has no header"

# Cards bigger than one argv string (a Linux argument is at most 128 KiB).
jq '.decisions = [range(3000) as $i | .decisions[1] | .statement = "decision \($i) with some words to make it longer"]' \
  "$D7/review.json" >"$TMP_DIR/big.json"
mkdir -p "$TMP_DIR/stack-big" && cp -R "$S/pr-7" "$S/pr-8" "$S/stack.json" "$S/stack.md" "$TMP_DIR/stack-big/"
cp "$TMP_DIR/big.json" "$TMP_DIR/stack-big/pr-7/aaaaaaa1111111/review.json"
cp "$TMP_DIR/big.json" "$TMP_DIR/stack-big/pr-8/bbbbbbb2222222/review.json"
[[ "$(wc -c <"$TMP_DIR/big.json")" -gt 200000 ]] || fail "the big review is not big"
assert_big="$("$ROOT/bin/bercail" review-pr state --stack "$TMP_DIR/stack-big" | jq -c '[.prs[].review.decisions | length]')" \
  || fail "review-pr state on big cards"
[[ "$assert_big" == "[3000,3000]" ]] || fail "big cards: $assert_big"
printf 'PASS: review-pr state with cards past the argv limit\n'

# --- the mod in node ----------------------------------------------------------------
# Element methods the mod may call: gpui-kit's when its types are on this machine.
DTS=""
for f in "$ROOT/bercail/mods/bercail-desk/gpui-kit.d.ts" "${HERDR_APP_CONFIG_DIR:-$HOME/.config/herdr-app}/gpui-kit.d.ts"; do
  [[ -f "$f" ]] && { DTS="$f"; break; }
done
if [[ -n "$DTS" ]]; then
  grep -oE '^\s+[a-z_0-9]+<Self extends Element' "$DTS" | grep -oE '^\s+[a-z_0-9]+' | tr -d ' ' | sort -u \
    | jq -Rnc '[inputs]' >"$TMP_DIR/methods.json"
else
  echo null >"$TMP_DIR/methods.json"
fi

cat >"$TMP_DIR/herdr.mjs" <<'EOF'
const h = () => globalThis.herdr;
import { spawnSync } from "child_process";
import { readFileSync } from "fs";
export const exec = async (cmd, args, opts) => {
  h().execs.push([cmd, ...(args ?? [])]);
  if (args?.[0] === "review-pr" && args[1] === "state") return { code: 0, stdout: h().state, stderr: "" };
  // The detach wrapper and its cleanup run for real; /bin/bercail is the fake bercail.
  if (cmd === "sh" || cmd === "rm") {
    const r = spawnSync(cmd, args.map((a) => (a === "/bin/bercail" ? process.env.FAKE_BERCAIL : a)), { cwd: opts?.cwd, encoding: "utf8" });
    return { code: r.status, stdout: r.stdout, stderr: r.stderr };
  }
  return { code: 0, stdout: "", stderr: "" };
};
export const home = () => process.env.FAKE_HOME;
export const notify = (n) => h().notes.push(n);
export const props = () => h().props;
export const run = (name, args) => h().runs.push([name, args]);
export const theme = () => new Proxy({}, { get: (_t, k) => String(k) });
export const readTextFile = async (path) => { try { return readFileSync(path, "utf8"); } catch { return null; } };
// The test wakes the watch loop with h().wake(paths).
export const watchFolder = () => new Promise((resolve) => { h().wake = resolve; });
EOF
cat >"$TMP_DIR/gpui.mjs" <<'EOF'
// An element records its text children and nested elements, in order. A method
// gpui-kit doesn't have throws, so a typo fails here and not in the app.
import { readFileSync } from "fs";
const known = JSON.parse(readFileSync(process.env.METHODS, "utf8"));
const el = () => {
  const e = { kids: [], on: {} };
  const p = new Proxy(e, {
    get: (t, k) => {
      if (k === "__el") return t;
      if (typeof k !== "string") return undefined;
      if (known && !known.includes(k)) throw new Error(`gpui-kit has no element method ${k}`);
      return (...a) => {
        if (k === "id") t.id = a[0];
        if (k === "child") t.kids.push(a[0]);
        if (k === "children") t.kids.push(...(a[0] ?? []));
        if (k.startsWith("on_")) t.on[k] = a[a.length - 1];
        if (k === "when" && a[0]) a[1](p);
        if (k === "frames") t.kids.push(a[0][0]);
        return p;
      };
    },
  });
  return p;
};
export class View {}
export const div = el, h_flex = el, v_flex = el;
// Text in order, one line per element that holds text.
export function dump(node, out = []) {
  const e = node?.__el ?? node;
  if (e == null || e === false) return out;
  if (typeof e !== "object") { out.push(String(e)); return out; }
  const text = e.kids.filter((k) => typeof k !== "object" || k === null).join("");
  if (text) out.push(text);
  for (const k of e.kids) if (k && typeof k === "object") dump(k, out);
  return out;
}
EOF
sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui.mjs"|' \
  -e 's|from "gpui-base"|from "./gpui.mjs"|' "$ROOT/bercail/mods/bercail-review/main.js" >"$TMP_DIR/main.mjs"

cat >"$TMP_DIR/test.mjs" <<'EOF'
import { readdirSync, readFileSync, writeFileSync } from "fs";
import Review from "./main.mjs";
import { dump } from "./gpui.mjs";

const [stateFile, outFile] = process.argv.slice(2);
const state = readFileSync(stateFile, "utf8");
const S = JSON.parse(state);
globalThis.herdr = { state, execs: [], runs: [], notes: [], files: {}, props: { stack: S.stack, bercail: "/bin/bercail" } };
const urls = [];
const cx = {
  timer: { every: (_ms, f) => { herdr.timer = f; } },
  focus_handle: () => ({ focus() {}, is_focused: () => true }),
  spawn: (f) => f(cx),
  notify() {},
  open_url: (u) => urls.push(u),
  stop_propagation() {},
};
const fail = (m) => { console.error(`FAIL: ${m}`); process.exit(1); };
const v = new Review();
v.init({}, cx);
v.render(cx); // the loading render, before state arrives, must not pick a PR
await new Promise((r) => setTimeout(r, 20));
if (!dump(v.render(cx)).includes(`PR #${S.current}  ${S.prs.find((p) => p.number === S.current).title}`))
  fail(`the card opens on the current PR, #${S.current}`);
const shots = [];
const shot = (label) => shots.push(`== ${label}`, ...dump(v.render(cx)));
const key = (k) => v.key({ keystroke: k }, cx);
const last = () => herdr.execs.at(-1).join(" ");
// A detached command: the wrapper, its log, then the command line.
const detached = (log, cmd) => { const l = last(); return l.startsWith("sh -c ") && l.includes(` ${log} `) && l.endsWith(cmd); };

shot("open");
key("o");
if (urls.at(-1) !== `https://github.com/acme/widgets/pull/${S.current}`) fail(`o opens the PR: ${urls}`);
key("d");
const [name, args] = herdr.runs.at(-1);
if (name !== "tab.new" || args.name !== `Diff #${S.current}` || args.argv.join(" ") !== `/bin/bercail review-pr diff ${S.current} --stack ${S.stack}`)
  fail(`d pages the diff in a tab of its own: ${JSON.stringify(herdr.runs)}`);
key("t");
await new Promise((r) => setTimeout(r, 0));
if (!detached(`${S.stack}/open.log`, `/bin/bercail review-pr open ${S.current} --stack ${S.stack}`)) fail(`t opens tuicr: ${last()}`);
key("r");
await new Promise((r) => setTimeout(r, 0));
if (!detached(`${S.stack}/refresh.log`, `/bin/bercail review-pr https://github.com/acme/widgets/pull/${S.root}`)) fail(`r gathers again: ${last()}`);
const execs = herdr.execs.length;
key("r");
if (herdr.execs.length !== execs || v.message !== "already gathering the stack again") fail(`a second r while one runs: ${v.message}`);
if (S.prs.length > 1) {
  key("j");
  shot("j: the next PR");
  key("p");
  await new Promise((r) => setTimeout(r, 0));
  const pr = S.prs[1];
  if (!detached(`${pr.dir}/pass.log`, `/bin/bercail review-pr run ${pr.number} --head ${pr.head_sha} --stack ${S.stack}`))
    fail(`p runs the pass again: ${last()}`);
  key("enter");
  await new Promise((r) => setTimeout(r, 0));
  const moved = herdr.execs.some((e) => e.join(" ") === `/bin/bercail review-pr select ${pr.number} --stack ${S.stack}`);
  if (moved !== (pr.number !== S.current)) fail(`enter moves the worktree only to another PR (moved: ${moved})`);
} else {
  const n = herdr.execs.length;
  key("enter");
  key("j");
  shot("j and enter do nothing in a stack of one");
  if (herdr.execs.length !== n) fail("a stack of one has no enter");
}
if (herdr.notes.length) fail(`notifications: ${JSON.stringify(herdr.notes)}`);
const tick = () => new Promise((r) => setTimeout(r, 5));
if (S.prs.length > 1) {
  // A gather moves the worktree back to the root: the card follows current.
  const other = S.prs.find((p) => p.number !== S.current);
  herdr.state = JSON.stringify({ ...S, current: other.number });
  herdr.wake([`${S.stack}/stack.json`]);
  await tick();
  if (!dump(v.render(cx)).includes(`PR #${other.number}  ${other.title}`)) fail(`the card follows current to #${other.number}`);
}
// The detached commands end (the fake bercail: tuicr and the gather fail, the pass
// is blocked); each says how, once, from its status file, which is then removed.
for (let i = 0; i < 100 && v.jobs.length; i++) { herdr.timer(cx); await tick(); }
if (v.jobs.length) fail(`jobs never ended: ${JSON.stringify(v.jobs)}`);
const said = herdr.notes.map((n) => `${n.level} ${n.title}: ${n.body}`).sort();
const want = [
  `error bercail: refresh failed: error: the review stack is busy gathering; try again when it ends`,
  `error bercail: tuicr #${S.current} failed: error: tuicr did not open PR #${S.current} within 60s`,
  ...(S.prs.length > 1 ? [`warning bercail: pass #${S.prs[1].number} blocked: diff.patch is empty`] : []),
].sort();
if (JSON.stringify(said) !== JSON.stringify(want)) fail(`how the detached commands ended:\n${said.join("\n")}`);
for (let i = 0; i < 5; i++) { herdr.timer(cx); await tick(); }
if (herdr.notes.length !== want.length) fail("a job's end is reported once");
if (readdirSync(`${process.env.FAKE_HOME}/.cache/bercail/review-jobs`).length) fail("status files are removed");
if (!readFileSync(`${S.stack}/refresh.log`, "utf8").includes("busy gathering")) fail("the log keeps the output");
writeFileSync(outFile, shots.join("\n") + "\n");
EOF

# The bercail the detached keys run: tuicr and the gather fail, a pass is blocked.
cat >"$TMP_DIR/fake-bercail" <<'SH'
#!/usr/bin/env bash
case "$2" in
  open) echo "error: tuicr did not open PR #$3 within 60s" >&2; exit 1 ;;
  run) printf '{\n  "status": "blocked",\n  "reason": "diff.patch is empty"\n}\n'; exit 0 ;;
  *) echo "error: the review stack is busy gathering; try again when it ends" >&2; exit 1 ;;
esac
SH
chmod +x "$TMP_DIR/fake-bercail"
export FAKE_BERCAIL="$TMP_DIR/fake-bercail" FAKE_HOME="$TMP_DIR/home"
METHODS="$TMP_DIR/methods.json" node "$TMP_DIR/test.mjs" "$TMP_DIR/state.json" "$TMP_DIR/render.txt"
METHODS="$TMP_DIR/methods.json" node "$TMP_DIR/test.mjs" "$TMP_DIR/state1.json" "$TMP_DIR/render1.txt"
# The worktree on #8: the tab opens there, not on the first PR.
jq '.current = 8' "$TMP_DIR/state.json" >"$TMP_DIR/state8.json"
METHODS="$TMP_DIR/methods.json" node "$TMP_DIR/test.mjs" "$TMP_DIR/state8.json" "$TMP_DIR/render8.txt"

diff -u - "$TMP_DIR/render.txt" <<'EOF' || fail "render snapshot (stack of two)"
== open
Stack #7 · acme/widgets
●
#7 Retry flaky uploads
ready · CI 1 fail · 1 pass
●
#8 Docs
waiting · CI no checks
# Stack #7 acme/widgets
via github, trunk main
PR #7  Retry flaky uploads
by dana · main ← retry · aaaaaaa
https://github.com/acme/widgets/pull/7
Intent
  Adds a retry helper so uploads stop failing.
Why
  Uploads fail on flaky networks.  [issue #12]
Decisions (2, 1 undocumented)
  1. [approach] Retries live in a new retry.sh helper
     lib/retry.sh:3-9  stated: PR body: adds a retry helper · fits intent: yes
  2. [behavior] Uploads retry 5 times with no backoff
     lib/upload.sh:12  UNDOCUMENTED · fits intent: partial
     over: exponential backoff
Intent with no change
  - Log each retry  [issue #12]
Questions for the author
  1. [AI Agent] lib/upload.sh:12  Why 5 retries with no backoff?
  2. [AI Agent] (whole PR)  Is logging in another PR?
  3. [AI Agent] (whole PR)  Should this ship behind a flag?
Bots
  2 threads, 1 unresolved (1 on a decision's file) · 1 reviews · 0 comments
  coderabbitai[bot], cursor[bot]
CI  1 fail · 1 pass
  fail     lint (CI)  https://ci/lint
  pass     test (CI)
j/k pick · enter: this PR · o browser · d diff · t tuicr · p pass again · r refresh
== j: the next PR
Stack #7 · acme/widgets
●
#7 Retry flaky uploads
ready · CI 1 fail · 1 pass
●
#8 Docs
waiting · CI no checks
# Stack #7 acme/widgets
via github, trunk main
PR #8  Docs
by dana · retry ← docs · bbbbbbb · draft
https://github.com/acme/widgets/pull/8
thin: empty_body, no_linked_issue
Intent
  (no PR body)
Decisions pass: waiting: thin (empty_body, no_linked_issue); bercail review-pr run
Bots
  not gathered
CI  no checks
j/k pick · enter: this PR · o browser · d diff · t tuicr · p pass again · r refresh
already gathering the stack again
EOF
printf 'PASS: render snapshot, stack of two: rows, header, the card, keys, current followed, detached failures and a blocked pass reported\n'

# A stack of one: the card alone, no list or header, and no enter.
grep -q '^Stack #7' "$TMP_DIR/render1.txt" && fail "a stack of one shows the PR list: $(cat "$TMP_DIR/render1.txt")"
grep -qF 'PR #7  Retry flaky uploads' "$TMP_DIR/render1.txt" || fail "a stack of one shows the card"
grep -qxF 'o browser · d diff · t tuicr · p pass again · r refresh' "$TMP_DIR/render1.txt" \
  || fail "a stack of one's keys: $(cat "$TMP_DIR/render1.txt")"
printf 'PASS: render, stack of one: the card alone, no enter or j/k\n'
