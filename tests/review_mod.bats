#!/usr/bin/env bats
# The bercail-review mod (the review-pr Stack tab), headless: a fixture run dir
# through `bercail review-pr state`, then the mod's render() and keys in node
# against stubs of gpui-kit and herdr. The rendered text is a snapshot.

setup() {
  load test_helper
  isolate
  need node jq
  # As the old file ran: a command that fails inside a pipe fails its assertion.
  set -o pipefail

  # --- a run dir: #7 reviewed (CI, bot threads), #8 thin and waiting on top of it ----
  S="$BATS_TEST_TMPDIR/stack-7"
  D7="$S/pr-7/aaaaaaa1111111"
  D8="$S/pr-8/bbbbbbb2222222"
  mkdir -p "$D7" "$D8"
  jq -n --arg wt "$BATS_TEST_TMPDIR/widgets.review-7" --arg src "$BATS_TEST_TMPDIR" '{schema: "bercail.stack/v1", host: "github.com", owner: "acme", repo: "widgets",
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
 "why": "Best guess: make uploads resilient by retrying failures.", "why_source": "diff",
 "intent_analysis": {
   "confidence": "medium", "evidence": [{"file":"lib/retry.sh","line":3,"end_line":9,"side":"new"}],
   "clues": [
     {"source":"issue #12","alignment":"less","detail":"Retries omit the requested backoff."},
     {"source":"commit abc123","alignment":"agrees","detail":"The helper isolates retries."},
     {"source":"PR body","alignment":"stale","detail":"Exhausted retries can still fail."}],
   "assessment": "Resilience is worth building, but discuss the retry policy."},
 "decisions": [
  {"kind": "approach", "statement": "Retries live in a new retry.sh helper",
   "evidence": [{"file": "lib/retry.sh", "line": 3, "end_line": 9, "side": "new"}],
    "stated": "commit abc123: use a retry helper", "fits_intent": "yes", "alternative": null, "question": null},
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
             {"path": "README", "line": 1, "isResolved": true, "author": {"login": "bugbot"}}],
 "reviews": [{"author": {"login": "coderabbitai[bot]"}}], "comments": []}
EOF
  echo '[]' >"$D8/ci.json"
}

# The mod's stubs, the node test, and the fake bercail its detached keys run.
arrange_mod() {
  # --- the mod in node ----------------------------------------------------------------
  # Element methods the mod may call: gpui-kit's when its types are on this machine.
  DTS=""
  for f in "$ROOT/bercail/mods/bercail-desk/gpui-kit.d.ts" "${HERDR_APP_CONFIG_DIR:-$HOME/.config/herdr-app}/gpui-kit.d.ts"; do
    [[ -f "$f" ]] && { DTS="$f"; break; }
  done
  if [[ -n "$DTS" ]]; then
    grep -oE '^\s+[a-z_0-9]+<Self extends Element' "$DTS" | grep -oE '^\s+[a-z_0-9]+' | tr -d ' ' | sort -u \
      | jq -Rnc '[inputs]' >"$BATS_TEST_TMPDIR/methods.json"
  else
    echo null >"$BATS_TEST_TMPDIR/methods.json"
  fi

  cat >"$BATS_TEST_TMPDIR/herdr.mjs" <<'EOF'
const h = () => globalThis.herdr;
import { spawnSync } from "child_process";
import { readFileSync } from "fs";
export const exec = async (cmd, args, opts) => {
  h().execs.push([cmd, ...(args ?? [])]);
  if (args?.[0] === "review-pr" && args[1] === "state") return { code: 0, stdout: h().state, stderr: "" };
  if (args?.[0] === "review-pr" && args[1] === "checkout") return h().checkout(args[2]);
  // The detach wrapper and its cleanup run for real; /bin/bercail is the fake bercail.
  if (h().reject) throw new Error(h().reject);
  if (cmd === "sh" || cmd === "rm") {
    const r = spawnSync(cmd, args.map((a) => (a === "/bin/bercail" ? process.env.FAKE_BERCAIL : a)), { cwd: opts?.cwd, encoding: "utf8" });
    return { code: r.status, stdout: r.stdout, stderr: r.stderr };
  }
  return { code: 0, stdout: "", stderr: "" };
};
export const home = () => process.env.FAKE_HOME;
export const focused = () => ({ space: "s1" });
export const notify = (n) => h().notes.push(n);
export const props = () => h().props;
export const run = (name, args) => h().runs.push([name, args]);
export const theme = () => new Proxy({}, { get: (_t, k) => String(k) });
export const readTextFile = async (path) => { try { return readFileSync(path, "utf8"); } catch { return null; } };
// The test wakes the watch loop with h().wake(paths).
export const watchFolder = () => new Promise((resolve) => { h().wake = resolve; });
EOF
  cat >"$BATS_TEST_TMPDIR/gpui.mjs" <<'EOF'
// An element records its text children, nested elements and handlers, in order. A
// method gpui-kit doesn't have throws, so a typo fails here and not in the app.
import { readFileSync } from "fs";
const known = JSON.parse(readFileSync(process.env.METHODS, "utf8"));
const el = () => {
  const e = { kids: [], on: {}, styles: {} };
  const p = new Proxy(e, {
    get: (t, k) => {
      if (k === "__el") return t;
      if (typeof k !== "string") return undefined;
      if (known && !known.includes(k)) throw new Error(`gpui-kit has no element method ${k}`);
       return (...a) => {
         t.styles[k] = a;
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
export const div = () => el(), h_flex = () => el(), v_flex = () => el();
// Text in order, one line per element that holds text.
export function dump(node, out = []) {
  const e = node?.__el ?? node;
  if (e == null || e === false) return out;
  if (typeof e !== "object") { out.push(String(e)); return out; }
  if (e.styles?.flex_wrap && e.styles?.items_baseline) {
    const flatten = (n) => typeof n === "object" ? (n?.__el ?? n)?.kids?.map(flatten).join("") ?? "" : String(n);
    out.push(flatten(e).trim());
    return out;
  }
  const text = e.kids.filter((k) => typeof k !== "object" || k === null).join("");
  if (text) out.push(...text.replace(/\n$/, "").split("\n"));
  for (const k of e.kids) if (k && typeof k === "object") dump(k, out);
  return out;
}
export function find(node, id) {
  const e = node?.__el ?? node;
  if (!e || typeof e !== "object") return null;
  if (e.id === id) return e;
  for (const k of e.kids ?? []) { const f = find(k, id); if (f) return f; }
  return null;
}
EOF
  sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui.mjs"|' \
    -e 's|from "gpui-base"|from "./gpui.mjs"|' "$ROOT/bercail/mods/bercail-review/main.js" >"$BATS_TEST_TMPDIR/main.mjs"

  cat >"$BATS_TEST_TMPDIR/test.mjs" <<'EOF'
import { readdirSync, readFileSync, writeFileSync } from "fs";
import Review, { shortRef, textTokens } from "./main.mjs";
import { dump, find } from "./gpui.mjs";
import { theme } from "./herdr.mjs";

const [stateFile, outFile] = process.argv.slice(2);
const state = readFileSync(stateFile, "utf8");
const S = JSON.parse(state);
globalThis.herdr = {
  state, execs: [], runs: [], notes: [], urls: [], props: { stack: S.stack, bercail: "/bin/bercail" },
  checkout: (n) => ({ code: 0, stderr: "", stdout: JSON.stringify(n === String(S.root)
    ? { worktree: "/wt", branch: "retry", note: null }
    : { worktree: "/wt", branch: null, note: "your docs is at 1234567, not the PR head bbbbbbb; it is left alone" }) }),
};
// As in gpui, a handler's cx ends when the handler returns; a task gets its own.
const context = () => {
  const c = {
    live: true,
    timer: { every: (_ms, f) => { herdr.timer = f; } },
    focus_handle: () => ({ focus() {}, is_focused: () => true }),
    spawn: (f) => f(context()),
    notify() { if (!c.live) throw new Error("a cx used after its handler returned"); },
    stop_propagation() {},
    open_url: (url) => herdr.urls.push(url),
  };
  return c;
};
const cx = context();
const fail = (m) => { console.error(`FAIL: ${m}`); process.exit(1); };
// Code spans, identifiers and paths stay native text, not markup. Long paths
// shorten only their visible label; each code chip retains the full tooltip.
{
  const text = "calculatePastDueDate uses `account.balance` and past_due in api/src/retry.ts:12, not <Button>.";
  const tokens = textTokens(text);
  for (const name of ["calculatePastDueDate", "account.balance", "past_due", "api/src/retry.ts:12"]) {
    if (!tokens.some((p) => p.code && p.text === name)) fail(`not styled as code: ${name}`);
  }
  if (tokens.map((p) => p.text).join("") !== text.replace(/`/g, "")) fail("tokenization changed the text");
  const prose = "Read/write (i.e. the worker) and e.g. retries, client/server and CI/CD.";
  if (textTokens(prose).some((p) => p.code)) fail("ordinary prose became code chips");
  const path = "api/src/domains/bhph/scheduledPayment/scheduledPayment.ts:42-48";
  if (shortRef(path) !== "scheduledPayment.ts:42-48") fail("long path is not shortened");
  const chip = new Review().code(new Proxy({}, {get: (_, k) => k}), path).__el;
  if (chip.styles.tooltip[0] !== path || chip.styles.font_family[0] !== "JetBrains Mono"
      || !chip.styles.whitespace_nowrap || chip.styles.text_color[0] !== "ansi6") fail("code chip lost its style or full path");
}
const tick = () => new Promise((r) => setTimeout(r, 5));
const v = new Review();
v.init({}, cx);
v.render(cx); // the loading render, before state arrives, must not pick a PR
await tick();
const cur = S.prs.find((p) => p.number === S.current);
if (!dump(v.render(cx)).includes(cur.title)) fail(`the card opens on the current PR, #${S.current}`);
const shots = [];
const shot = (label) => shots.push(`== ${label}`, ...dump(v.render(cx)));
const key = (k) => { const c = context(); v.key({ keystroke: k }, c); c.live = false; };
const click = (id) => {
  const e = find(v.render(cx), id);
  if (!e?.on.on_click) fail(`no button ${id}`);
  const c = context(); e.on.on_click({}, c); c.live = false;
};
const last = () => herdr.execs.at(-1).join(" ");
// A detached command: the wrapper, its log, then the command line.
const detached = (log, cmd) => { const l = last(); return l.startsWith("sh -c ") && l.includes(` ${log} `) && l.endsWith(cmd); };
const n = S.current;

shot("open");
if (cur.ci.some((c) => c.bucket === "fail" && c.link)) {
  click("ci-link-0");
  if (herdr.urls.at(-1) !== "https://ci/lint") fail("CI link did not open its full URL");
}
// c and its button: tuicr on this PR.
key("c");
await tick();
if (!detached(`${S.stack}/open.log`, `/bin/bercail review-pr open ${n} --stack ${S.stack}`)) fail(`c opens tuicr: ${last()}`);
// r: re-review, gather then pass, once at a time.
click("act-rereview");
await tick();
if (!detached(`${S.stack}/rereview.log`, `/bin/bercail review-pr rereview ${n} --stack ${S.stack}`)) fail(`r re-reviews: ${last()}`);
const execs = herdr.execs.length;
key("r");
if (herdr.execs.length !== execs || v.message !== "a re-review is already running") fail(`a second r while one runs: ${v.message}`);
// o: the PR's branch in the worktree, then a shell tab in it.
click("act-shell");
await tick();
if (last() !== `/bin/bercail review-pr checkout ${n} --stack ${S.stack}`) fail(`o checks out: ${last()}`);
if (JSON.stringify(herdr.runs.at(-1)) !== JSON.stringify(["tab.new", { space: "s1", name: `Shell #${n}`, folder: "/wt" }]))
  fail(`o opens a shell tab in this space: ${JSON.stringify(herdr.runs)}`);
// A second press must also set cwd, not select an existing tab.
key("o");
await tick();
if (JSON.stringify(herdr.runs.at(-1)) !== JSON.stringify(["tab.new", { space: "s1", name: `Shell #${n}`, folder: "/wt" }]))
  fail(`o did not open a fresh shell in the worktree: ${JSON.stringify(herdr.runs.at(-1))}`);
// Keys the tab no longer has.
const before = [herdr.execs.length, herdr.runs.length];
for (const k of ["d", "t", "p", "enter"]) key(k);
if (herdr.execs.length !== before[0] || herdr.runs.length !== before[1]) fail("d, t, p and enter do nothing");
if (S.prs.length > 1) {
  key("j");
  shot("j: the next PR");
  key("o");
  await tick();
  if (!v.message.includes("left alone")) fail(`a branch left alone is said: ${v.message}`);
} else {
  const was = v.sel;
  key("j");
  if (v.sel !== was) fail("j moves nothing in a stack of one");
}
// The summary replaces the redundant numbered PR list, without adding an action.
const oldState = v.state;
const reviewed = S.prs.find((p) => p.review?.intent_analysis);
if (reviewed) {
  const noIssue = structuredClone(reviewed);
  noIssue.linked = [];
  noIssue.review.intent_analysis.clues = [{source: "linked issues", alignment: "unavailable", detail: "No linked issue clues to compare."}];
  const inferred = dump(v.body(theme(), noIssue)).join("\n");
  for (const text of ["Inferred intent", "best educated guess from code", "Confidence", "Evidence", "Right thing to build", "Clue comparison", "unavailable"]) {
    if (!inferred.includes(text)) fail(`no-issue inference missing ${text}`);
  }
  if (inferred.includes("Intent unknown")) fail("missing issues hid the inferred intent");
  const legacy = structuredClone(reviewed);
  delete legacy.review.intent_analysis;
  const saved = dump(v.body(theme(), legacy)).join("\n");
  if (!saved.includes("Saved review context") || !saved.includes("Re-review for code-based intent") || saved.includes("Inferred intent")) {
    fail("legacy context was labeled as code-inferred intent");
  }
}
v.state = { ...oldState, summary: { status: "ready", overview: "Retries across the upload stack.",
  order: ["#7 adds the helper", "#8 documents it"], risks: ["No backoff"], start_here: ["Read `retry()` first"] } };
const overview = dump(find(v.render(cx), "stack-summary"));
for (const text of ["Retries across the upload stack.", "Order", "Risks", "Look here first", "• Read retry() first"]) {
  if (!overview.includes(text)) fail(`stack summary missing ${text}`);
}
if (find(v.render(cx), "stack-md")) fail("the duplicate PR list remains");
if (S.prs.length > 1 && (find(v.render(cx), "stack-summary").styles.max_h[0] !== 260
    || !find(v.render(cx), "review-list").styles.h_full
    || !find(v.render(cx), "review-picker").styles.overflow_y_scrollbar)) fail("long summary pushes the picker away");
v.state = oldState;
if (herdr.notes.length) fail(`notifications: ${JSON.stringify(herdr.notes)}`);
if (S.prs.length > 1) {
  // A gather moves the worktree back to the root: the card follows current.
  const other = S.prs.find((p) => p.number !== S.current);
  herdr.state = JSON.stringify({ ...S, current: other.number });
  herdr.wake([`${S.stack}/stack.json`]);
  await tick();
  if (!dump(v.render(cx)).includes(other.title)) fail(`the card follows current to #${other.number}`);
}
// The detached commands end (the fake bercail: tuicr fails, the re-review's pass is
// blocked); each says how, once, from its status file, which is then removed.
for (let i = 0; i < 100 && v.jobs.length; i++) { herdr.timer(cx); await tick(); }
if (v.jobs.length) fail(`jobs never ended: ${JSON.stringify(v.jobs)}`);
const said = herdr.notes.map((x) => `${x.level} ${x.title}: ${x.body}`).sort();
const want = [
  `error bercail: code review #${n} failed: error: tuicr did not open PR #${n} within 60s`,
  `warning bercail: re-review #${n} blocked: diff.patch is empty`,
].sort();
if (JSON.stringify(said) !== JSON.stringify(want)) fail(`how the detached commands ended:\n${said.join("\n")}`);
for (let i = 0; i < 5; i++) { herdr.timer(cx); await tick(); }
if (herdr.notes.length !== want.length) fail("a job's end is reported once");
// exec rejects (a missing folder): the job goes with the toast, and r works again.
herdr.reject = "no such folder: /gone";
click("act-review");
await tick();
if (v.jobs.length || herdr.notes.at(-1)?.title !== `bercail: code review #${v.current().number}`
    || herdr.notes.at(-1)?.body !== "no such folder: /gone") fail("the code review button reports a launch failure");
key("r");
await tick();
delete herdr.reject;
if (v.jobs.length || herdr.notes.at(-1)?.body !== "no such folder: /gone") fail(`a re-review that never started: ${JSON.stringify(v.jobs)}`);
key("r");
if (v.message === "a re-review is already running") fail("r is stuck after a re-review that never started");
for (let i = 0; i < 100 && v.jobs.length; i++) { herdr.timer(cx); await tick(); }
if (readdirSync(`${process.env.FAKE_HOME}/.cache/bercail/review-jobs`).length) fail("status files are removed");
if (!readFileSync(`${S.stack}/open.log`, "utf8").includes("did not open")) fail("the log keeps the output");
writeFileSync(outFile, shots.join("\n") + "\n");
EOF

  # The bercail the detached keys run: tuicr fails, a re-review's pass is blocked.
  cat >"$BATS_TEST_TMPDIR/fake-bercail" <<'SH'
#!/usr/bin/env bash
case "$2" in
  open) echo "error: tuicr did not open PR #$3 within 60s" >&2; exit 1 ;;
  # The gather's JSON, then the pass's run.json.
  rereview) printf '{\n  "schema": "bercail.review-pr/v1",\n  "pass": "waiting"\n}\n{\n  "status": "blocked",\n  "reason": "diff.patch is empty"\n}\n'; exit 0 ;;
  *) echo "fake bercail: $*" >&2; exit 2 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/fake-bercail"
  export FAKE_BERCAIL="$BATS_TEST_TMPDIR/fake-bercail" FAKE_HOME="$BATS_TEST_TMPDIR/home"
}

@test "review-pr state reads the run dir: pass status, questions, bots, header" {
  "$ROOT/bin/bercail" review-pr state --stack "$S" >"$BATS_TEST_TMPDIR/state.json" || fail "review-pr state"
  jq -e '.schema == "bercail.review-ui/v1" and (.prs | length) == 2 and .header != null
    and .prs[0].pass == "ready" and .prs[1].pass == "waiting" and .prs[1].review == null
    and .prs[0].bots.unresolved == 1 and .prs[0].bots.on_decisions == 1
    and .prs[0].intent == .prs[0].review.why and .prs[0].review.intent_analysis.confidence == "medium"
    and .prs[1].intent == "Awaiting code-based intent inference."
    and (.prs[0].questions | map(.at)) == ["lib/upload.sh:12", null, null]' "$BATS_TEST_TMPDIR/state.json" >/dev/null \
    || fail "state JSON: $(cat "$BATS_TEST_TMPDIR/state.json")"
}

@test "review-pr state, stack of one: no header" {
  # A stack of one: no header, one PR.
  S1="$BATS_TEST_TMPDIR/stack-9"
  mkdir -p "$S1/pr-7"
  cp -R "$D7" "$S1/pr-7/"
  jq --arg wt "$BATS_TEST_TMPDIR/widgets.review-9" '.prs |= .[0:1] | .worktree = $wt' "$S/stack.json" >"$S1/stack.json"
  "$ROOT/bin/bercail" review-pr state --stack "$S1" >"$BATS_TEST_TMPDIR/state1.json" || fail "review-pr state (one PR)"
  jq -e '.header == null and (.prs | length) == 1' "$BATS_TEST_TMPDIR/state1.json" >/dev/null || fail "stack of one has no header"
}

@test "review-pr state with cards past the argv limit" {
  # Cards bigger than one argv string (a Linux argument is at most 128 KiB).
  jq '.decisions = [range(3000) as $i | .decisions[1] | .statement = "decision \($i) with some words to make it longer"]' \
    "$D7/review.json" >"$BATS_TEST_TMPDIR/big.json"
  mkdir -p "$BATS_TEST_TMPDIR/stack-big" && cp -R "$S/pr-7" "$S/pr-8" "$S/stack.json" "$S/stack.md" "$BATS_TEST_TMPDIR/stack-big/"
  cp "$BATS_TEST_TMPDIR/big.json" "$BATS_TEST_TMPDIR/stack-big/pr-7/aaaaaaa1111111/review.json"
  cp "$BATS_TEST_TMPDIR/big.json" "$BATS_TEST_TMPDIR/stack-big/pr-8/bbbbbbb2222222/review.json"
  [[ "$(wc -c <"$BATS_TEST_TMPDIR/big.json")" -gt 200000 ]] || fail "the big review is not big"
  assert_big="$("$ROOT/bin/bercail" review-pr state --stack "$BATS_TEST_TMPDIR/stack-big" | jq -c '[.prs[].review.decisions | length]')" \
    || fail "review-pr state on big cards"
  [[ "$assert_big" == "[3000,3000]" ]] || fail "big cards: $assert_big"
}

@test "render snapshot, stack of two: intent in picker rows, labeled decisions, styled code; c/r/o unchanged" {
  arrange_mod
  "$ROOT/bin/bercail" review-pr state --stack "$S" >"$BATS_TEST_TMPDIR/state.json" || fail "review-pr state"
  jq -e '.schema == "bercail.review-ui/v1" and (.prs | length) == 2 and .header != null
    and .prs[0].pass == "ready" and .prs[1].pass == "waiting" and .prs[1].review == null
    and .prs[0].bots.unresolved == 1 and .prs[0].bots.on_decisions == 1
    and .prs[0].intent == .prs[0].review.why and .prs[0].review.intent_analysis.confidence == "medium"
    and .prs[1].intent == "Awaiting code-based intent inference."
    and (.prs[0].questions | map(.at)) == ["lib/upload.sh:12", null, null]' "$BATS_TEST_TMPDIR/state.json" >/dev/null \
    || fail "state JSON: $(cat "$BATS_TEST_TMPDIR/state.json")"
  METHODS="$BATS_TEST_TMPDIR/methods.json" node "$BATS_TEST_TMPDIR/test.mjs" "$BATS_TEST_TMPDIR/state.json" "$BATS_TEST_TMPDIR/render.txt"
  diff -u - "$BATS_TEST_TMPDIR/render.txt" <<'EOF' || fail "render snapshot (stack of two)"
== open
Stack #7
acme/widgets
Stack summary follows when every card is ready.
●
#7 Retry flaky uploads
Best guess: make uploads resilient by retrying failures.
ready · CI 1 fail · 1 pass
●
#8 Docs
Awaiting code-based intent inference.
waiting · CI no checks
#7
Retry flaky uploads
by dana · main ← retry · aaaaaaa · https://github.com/acme/widgets/pull/7
●
Decisions pass: ready: 2 decisions, 1 undocumented, 1 unmet, 3 questions
c
Code review
r
Re-review
o
Shell
Inferred intent
best educated guess from code
Best guess: make uploads resilient by retrying failures.
Confidence
medium
Evidence
lib/retry.sh:3-9
Right thing to build
Resilience is worth building, but discuss the retry policy.
Clue comparison
Source
issue #12
Alignment
less
Comparison
Retries omit the requested backoff.
Source
commit abc123
Alignment
agrees
Comparison
The helper isolates retries.
Source
PR body
Alignment
stale
Comparison
Exhausted retries can still fail.
Decisions
2 choices · 1 undocumented
Kind
1. approach
Summary
Retries live in a new retry.sh helper
Evidence
lib/retry.sh:3-9
Stated
commit abc123: use a retry helper
Fit
yes
Alternative
Not given
Kind
2. behavior
Summary
Uploads retry 5 times with no backoff
Evidence
lib/upload.sh:12
Stated
UNDOCUMENTED
Fit
partial
Alternative
exponential backoff
Unmet
Log each retry
issue #12
Questions
1. [AI Agent]
lib/upload.sh:12
Why 5 retries with no backoff?
2. [AI Agent]
whole PR
Is logging in another PR?
3. [AI Agent]
whole PR
Should this ship behind a flag?
Bots
2 threads, 1 unresolved (1 on a decision's file)
1 reviews, 0 comments
bugbot, coderabbitai[bot]
CI
1 fail · 1 pass
fail: lint
CI
https://ci/lint
pass: test
CI
j/k pick · c code review · r re-review · o shell
== j: the next PR
Stack #7
acme/widgets
Stack summary follows when every card is ready.
●
#7 Retry flaky uploads
Best guess: make uploads resilient by retrying failures.
ready · CI 1 fail · 1 pass
●
#8 Docs
Awaiting code-based intent inference.
waiting · CI no checks
#8
Docs
by dana · retry ← docs · bbbbbbb · draft · https://github.com/acme/widgets/pull/8
thin: empty_body, no_linked_issue
●
Decisions pass: waiting: thin (empty_body, no_linked_issue); r runs it
c
Code review
r
Re-review
o
Shell
Inferred intent
Awaiting code-based intent inference.
Bots
Not gathered yet
CI
no checks
j/k pick · c code review · r re-review · o shell
#7 is on retry in the shell tab
EOF
}

@test "render, stack of one: summary and card, no PR picker or j/k" {
  arrange_mod
  # A stack of one: no header, one PR.
  S1="$BATS_TEST_TMPDIR/stack-9"
  mkdir -p "$S1/pr-7"
  cp -R "$D7" "$S1/pr-7/"
  jq --arg wt "$BATS_TEST_TMPDIR/widgets.review-9" '.prs |= .[0:1] | .worktree = $wt' "$S/stack.json" >"$S1/stack.json"
  "$ROOT/bin/bercail" review-pr state --stack "$S1" >"$BATS_TEST_TMPDIR/state1.json" || fail "review-pr state (one PR)"
  jq -e '.header == null and (.prs | length) == 1' "$BATS_TEST_TMPDIR/state1.json" >/dev/null || fail "stack of one has no header"
  METHODS="$BATS_TEST_TMPDIR/methods.json" node "$BATS_TEST_TMPDIR/test.mjs" "$BATS_TEST_TMPDIR/state1.json" "$BATS_TEST_TMPDIR/render1.txt"
  # A stack of one: summary and card, no PR picker or j/k.
  [[ "$(grep -c '^#7 Retry flaky uploads' "$BATS_TEST_TMPDIR/render1.txt")" == 0 ]] || fail "a stack of one shows the PR picker"
  grep -qxF 'Retry flaky uploads' "$BATS_TEST_TMPDIR/render1.txt" || fail "a stack of one shows the card"
  grep -qxF 'c code review · r re-review · o shell' "$BATS_TEST_TMPDIR/render1.txt" \
    || fail "a stack of one's keys: $(cat "$BATS_TEST_TMPDIR/render1.txt")"
}

@test "the mod with the worktree on #8: the tab opens there, not on the first PR" {
  arrange_mod
  "$ROOT/bin/bercail" review-pr state --stack "$S" >"$BATS_TEST_TMPDIR/state.json" || fail "review-pr state"
  jq -e '.schema == "bercail.review-ui/v1" and (.prs | length) == 2 and .header != null
    and .prs[0].pass == "ready" and .prs[1].pass == "waiting" and .prs[1].review == null
    and .prs[0].bots.unresolved == 1 and .prs[0].bots.on_decisions == 1
    and .prs[0].intent == .prs[0].review.why and .prs[0].review.intent_analysis.confidence == "medium"
    and .prs[1].intent == "Awaiting code-based intent inference."
    and (.prs[0].questions | map(.at)) == ["lib/upload.sh:12", null, null]' "$BATS_TEST_TMPDIR/state.json" >/dev/null \
    || fail "state JSON: $(cat "$BATS_TEST_TMPDIR/state.json")"
  jq '.current = 8' "$BATS_TEST_TMPDIR/state.json" >"$BATS_TEST_TMPDIR/state8.json"
  METHODS="$BATS_TEST_TMPDIR/methods.json" node "$BATS_TEST_TMPDIR/test.mjs" "$BATS_TEST_TMPDIR/state8.json" "$BATS_TEST_TMPDIR/render8.txt"
}
