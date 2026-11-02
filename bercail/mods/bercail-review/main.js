// bercail review: the Stack tab of a `bercail review-pr` space.
//
// props.stack is the stack's run dir, props.bercail the bercail that made the tab.
// Everything shown comes from `bercail review-pr state` (the run dir as one JSON
// document); the mod reads nothing else and writes nothing. It reloads when the run
// dir changes, so a row turns ready when its pass writes run.json.
//
// Keys: j/k or ↑/↓ pick a PR, enter moves the review worktree to it (a stack of
// two or more), o opens it in the browser, d pages its diff vs its parent in a tab
// of its own, t opens tuicr seeded with the [AI Agent] questions, p runs its decisions
// pass again, r gathers the stack again (heads, CI, bodies; starts passes that wait).
import { View, div } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { exec, home, notify, props, readTextFile, run, theme, watchFolder } from "herdr";

// What a pass or a gather streams into: no change to what the tab shows.
const NOISE = /\/(pass\.(jsonl|err|log)|open\.log|refresh\.log)$|\/source\/|\.(json|md|patch)\.[A-Za-z0-9]{6}$/;
const SPIN = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const CI_ORDER = ["fail", "pending", "cancel", "pass", "skipping"];
// Where a detached command leaves its exit code and its last output lines, one file
// per job; the tab reads it and removes it. Not the run dir, which only bercail writes.
const JOBS = "/.cache/bercail/review-jobs";
// $0 log, $1 status file, then the command. The log keeps the whole output, as before.
const INNER = 'log=$0; status=$1; shift; out=$("$@" 2>&1 </dev/null); rc=$?; printf "%s\\n" "$out" >>"$log"; '
  + 'mkdir -p "${status%/*}" && { echo "$rc"; printf "%s\\n" "$out" | tail -n 40; } >"$status.tmp" && mv "$status.tmp" "$status"';
const OUTER = 'inner=$1; shift; if command -v setsid >/dev/null 2>&1; '
  + 'then setsid -f sh -c "$inner" "$@" >/dev/null 2>&1 </dev/null; '
  + 'else nohup sh -c "$inner" "$@" >/dev/null 2>&1 </dev/null & fi';
let seq = 0;

export const loc = (e) =>
  !e?.file ? "" : e.file + (e.line ? `:${e.line}` + ((e.end_line ?? e.line) !== e.line ? `-${e.end_line}` : "") : "");

export function ciCounts(ci) {
  const k = {};
  for (const c of ci ?? []) k[c.bucket ?? "pending"] = (k[c.bucket ?? "pending"] ?? 0) + 1;
  return CI_ORDER.filter((b) => k[b]).map((b) => `${k[b]} ${b}`).join(" · ") || "no checks";
}

// The card, top to bottom, as lines with a tone: what the fzf card shows, plus
// the PR's intent and its bot reviews.
export function cardLines(pr) {
  const L = [];
  const add = (text, tone = "plain") => L.push({ text, tone });
  const gap = () => add("");
  const r = pr.review;
  add(`PR #${pr.number}  ${pr.title}`, "title");
  add(`by ${pr.author} · ${pr.base} ← ${pr.head} · ${pr.head_sha.slice(0, 7)}${pr.draft ? " · draft" : ""}`, "dim");
  add(pr.url, "dim");
  if (pr.thin?.length) add(`thin: ${pr.thin.join(", ")}`, "warn");
  gap();
  add("Intent", "head");
  add(`  ${pr.intent || "(no PR body)"}`);
  gap();
  if (!r) {
    add(`Decisions pass: ${pr.status}`, pr.pass === "failed" || pr.pass === "blocked" ? "fail" : "dim");
  } else {
    add("Why", "head");
    add(`  ${r.why || "(not given)"}${r.why_source ? `  [${r.why_source}]` : ""}`);
    gap();
    const undoc = r.decisions.filter((d) => d.stated == null).length;
    add(`Decisions (${r.decisions.length}, ${undoc} undocumented)`, "head");
    r.decisions.forEach((d, i) => {
      add(`  ${i + 1}. [${d.kind ?? "?"}] ${d.statement ?? ""}`);
      const where = (d.evidence ?? []).map(loc).filter(Boolean).join(", ");
      const said = d.stated == null ? "UNDOCUMENTED" : `stated: ${d.stated}`;
      add(`     ${where ? `${where}  ` : ""}${said} · fits intent: ${d.fits_intent ?? "unclear"}`, d.stated == null ? "warn" : "dim");
      if (d.alternative) add(`     over: ${d.alternative}`, "dim");
    });
    if (r.unmet_intent?.length) {
      gap();
      add("Intent with no change", "head");
      for (const u of r.unmet_intent) add(`  - ${u.promise}${u.source ? `  [${u.source}]` : ""}`, "warn");
    }
  }
  if (pr.questions?.length) {
    gap();
    add("Questions for the author", "head");
    pr.questions.forEach((q, i) => add(`  ${i + 1}. [AI Agent] ${q.at ?? "(whole PR)"}  ${q.text}`));
  }
  gap();
  add("Bots", "head");
  const b = pr.bots;
  if (!b) add("  not gathered", "dim");
  else {
    add(`  ${b.threads} threads, ${b.unresolved} unresolved (${b.on_decisions} on a decision's file) · ${b.reviews} reviews · ${b.comments} comments`,
      b.unresolved ? "warn" : "plain");
    if (b.authors?.length) add(`  ${b.authors.join(", ")}`, "dim");
  }
  gap();
  add(`CI  ${ciCounts(pr.ci)}`, "head");
  const rank = (c) => { const i = CI_ORDER.indexOf(c.bucket ?? "pending"); return i < 0 ? 5 : i; };
  for (const c of [...(pr.ci ?? [])].sort((x, y) => rank(x) - rank(y))) {
    const bucket = c.bucket ?? "pending";
    const link = (bucket === "fail" || bucket === "pending") && c.link ? `  ${c.link}` : "";
    add(`  ${bucket.padEnd(8)} ${c.name}${c.workflow ? ` (${c.workflow})` : ""}${link}`,
      bucket === "fail" ? "fail" : bucket === "pending" ? "warn" : bucket === "pass" ? "pass" : "dim");
  }
  return L;
}

const keyHint = (many) =>
  `${many ? "j/k pick · enter: this PR · " : ""}o browser · d diff · t tuicr · p pass again · r refresh`;

export default class Review extends View {
  init(_props, cx) {
    this.h = cx.focus_handle();
    this.state = null;
    this.error = "";
    this.message = "";
    this.sel = null;
    this.jobs = [];
    // Only while a detached command runs: its status file is outside the watched run dir.
    cx.timer.every(1000, (cx) => {
      if (this.jobs.length && !this.checking) cx.spawn(async (cx) => this.ended(cx));
    });
    cx.spawn(async (cx) => {
      await this.reload(cx);
      this.h.focus();
      for (;;) {
        const changed = await watchFolder(props().stack);
        if (changed.some((p) => !NOISE.test(p))) await this.reload(cx);
      }
    });
  }

  async reload(cx) {
    const { stack, bercail } = props();
    try {
      const r = await exec(bercail || "bercail", ["review-pr", "state", "--stack", stack]);
      if (r.code !== 0) throw new Error(r.stderr.trim() || `review-pr state exited ${r.code}`);
      const was = this.state?.current;
      this.state = JSON.parse(r.stdout);
      // The worktree moved (enter, or a gather back to the root): the card follows it.
      if (this.state.current !== was) this.sel = null;
      this.error = "";
    } catch (e) {
      this.error = String(e?.message ?? e);
    }
    cx.notify();
  }

  prs() {
    return this.state?.prs ?? [];
  }

  current() {
    const prs = this.prs();
    if (this.sel == null && this.state) this.sel = Math.max(0, prs.findIndex((p) => p.number === this.state.current));
    return prs[Math.min(this.sel, prs.length - 1)];
  }

  say(text, cx) {
    this.message = text;
    cx.notify();
  }

  // Off the tab's exec (30 s limit): a pass, a gather or tuicr's wait takes longer.
  async detach(what, argv, log, cwd) {
    const status = `${home()}${JOBS}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${++seq}`;
    this.jobs.push({ what, status });
    const r = await exec("sh", ["-c", OUTER, "sh", INNER, log, status, ...argv], cwd ? { cwd } : {});
    if (r.code !== 0) {
      this.jobs = this.jobs.filter((j) => j.status !== status);
      throw new Error(r.stderr.trim() || `exit ${r.code}`);
    }
  }

  // Detached commands that finished: a failure says why, in the bar and a toast.
  async ended(cx) {
    this.checking = true;
    try {
      for (const job of [...this.jobs]) {
        let text;
        try {
          text = await readTextFile(job.status);
        } catch (e) {
          text = `1\ncould not read ${job.status}: ${e?.message ?? e}`;
        }
        if (text == null) continue;
        this.jobs = this.jobs.filter((j) => j !== job);
        await exec("rm", ["-f", job.status]).catch(() => {});
        const [rc, ...lines] = text.split("\n");
        // review-pr run prints run.json (blocked exits 0, with a reason); other commands end on an error line.
        const out = lines.join("\n").trim();
        let run = null;
        try { run = JSON.parse(out); } catch {}
        if (rc === "0" && run?.status !== "blocked") {
          this.say(`${job.what}: done`, cx);
          continue;
        }
        const why = run?.reason || (run ? "" : out.split("\n").at(-1)) || `exit ${rc}`;
        const word = run?.status === "blocked" ? "blocked" : "failed";
        this.say(`${job.what} ${word}: ${why}`, cx);
        notify({ title: `bercail: ${job.what} ${word}`, body: why, level: word === "blocked" ? "warning" : "error" });
      }
    } finally {
      this.checking = false;
    }
  }

  act(name, cx) {
    const s = this.state;
    const pr = this.current();
    if (!s || !pr) return;
    const self = props().bercail || "bercail";
    const n = String(pr.number);
    const fail = (what) => (e) => notify({ title: `bercail: ${what}`, body: String(e?.message ?? e), level: "error" });
    switch (name) {
      case "open":
        cx.open_url(pr.url);
        return;
      case "diff":
        // A tab of its own: a terminal in the Stack tab would make it look like the old fzf tab to `ui`.
        run("tab.new", { name: `Diff #${n}`, argv: [self, "review-pr", "diff", n, "--stack", s.stack] });
        return;
      case "select":
        if (this.prs().length < 2 || pr.number === s.current) return;
        this.say(`moving the review worktree to #${n}…`, cx);
        cx.spawn(async (cx) => {
          const r = await exec(self, ["review-pr", "select", n, "--stack", s.stack]);
          this.say(r.code === 0 ? `the review worktree is at #${n}` : r.stderr.trim(), cx);
          await this.reload(cx);
        });
        return;
      case "tuicr":
        this.say(`opening tuicr on #${n}; log: open.log`, cx);
        cx.spawn(async () => this.detach(`tuicr #${n}`, [self, "review-pr", "open", n, "--stack", s.stack], `${s.stack}/open.log`)
          .catch(fail("tuicr")));
        return;
      case "pass":
        if (pr.pass === "running") return this.say(`#${n}'s pass is already running`, cx);
        this.say(`started a decisions pass for #${n}`, cx);
        cx.spawn(async () => this.detach(`pass #${n}`, [self, "review-pr", "run", n, "--head", pr.head_sha, "--stack", s.stack],
          `${pr.dir}/pass.log`).catch(fail("pass")));
        return;
      case "refresh": {
        // review-pr refuses to gather while a pass runs, and only its log would say so.
        if (this.prs().some((p) => p.pass === "running")) return this.say("a pass is running; refresh when it ends", cx);
        if (this.jobs.some((j) => j.what === "refresh")) return this.say("already gathering the stack again", cx);
        const root = this.prs().find((p) => p.number === s.root) ?? pr;
        this.say("gathering the stack again; log: refresh.log", cx);
        cx.spawn(async () => this.detach("refresh", [self, "review-pr", root.url], `${s.stack}/refresh.log`, s.source)
          .catch(fail("refresh")));
        return;
      }
    }
  }

  key(e, cx) {
    const many = this.prs().length > 1;
    const move = (d) => {
      this.current();
      this.sel = Math.max(0, Math.min(this.prs().length - 1, this.sel + d));
      cx.notify();
    };
    const keys = {
      j: () => move(1), down: () => move(1), k: () => move(-1), up: () => move(-1),
      enter: () => this.act("select", cx), o: () => this.act("open", cx), d: () => this.act("diff", cx),
      t: () => this.act("tuicr", cx), p: () => this.act("pass", cx), r: () => this.act("refresh", cx),
    };
    const f = keys[e.keystroke];
    if (!f || (!many && ["j", "k", "up", "down", "enter"].includes(e.keystroke))) return;
    f();
    cx.stop_propagation();
  }

  tone(t, tone) {
    return { title: t.foreground, head: t.foreground, dim: t.dim, warn: t.ansi3, fail: t.ansi1, pass: t.ansi2 }[tone] ?? t.foreground;
  }

  passColor(t, pass) {
    return { ready: t.ansi2, running: t.working, failed: t.ansi1, blocked: t.blocked }[pass] ?? t.dim;
  }

  row(t, pr, i, on) {
    const running = pr.pass === "running";
    return h_flex()
      .id(`row-${pr.number}`)
      .px(10)
      .py(6)
      .gap(8)
      .rounded(6)
      .items_start()
      .when(on, (el) => el.bg(t.selected))
      .hover((el) => el.bg(on ? t.selected : t.hover))
      .on_click((_e, cx) => {
        this.sel = i;
        this.h.focus();
        cx.notify();
      })
      .child(div().w(12).flex_none().text_color(this.passColor(t, pr.pass))
        .child(running ? div().frames(SPIN, 90) : "●"))
      .child(v_flex().flex_1().min_w(0).gap(2)
        .child(div().truncate().text_color(t.foreground).child(`#${pr.number} ${pr.title}`))
        .child(div().truncate().text_size(11.5).text_color(t.dim).child(`${pr.pass} · CI ${ciCounts(pr.ci)}`)));
  }

  render() {
    const t = theme();
    const prs = this.prs();
    const many = prs.length > 1;
    const pr = this.current();
    const root = v_flex()
      .id("review-root")
      .size_full()
      .bg(t.background)
      .text_size(13)
      .text_color(t.foreground)
      .track_focus(this.h)
      .on_key_down((e, cx) => this.key(e, cx))
      .on_mouse_down("left", () => this.h.focus());
    if (!this.state) {
      return root.p(16).child(div().text_color(this.error ? t.ansi1 : t.dim).child(this.error || "Loading the stack…"));
    }
    const card = v_flex().id("review-card").flex_1().min_w(0).p(14).gap(1).overflow_y_scrollbar()
      .children(pr ? cardLines(pr).map((l, i) => div()
        .id(`line-${i}`)
        .min_h(l.text ? 0 : 8)
        .text_color(this.tone(t, l.tone))
        .when(l.tone === "title", (el) => el.text_size(15).font_semibold())
        .when(l.tone === "head", (el) => el.font_semibold().pt(2))
        .child(l.text)) : []);
    const list = v_flex().id("review-list").w(320).flex_none().p(8).gap(2).border_r(1).border_color(t.border)
      .overflow_y_scrollbar().bg(t.surface)
      .child(div().px(10).pb(6).text_size(11.5).text_color(t.dim).child(`Stack #${this.state.root} · ${this.state.repo}`))
      .children(prs.map((p, i) => this.row(t, p, i, p === pr)))
      .when(!!this.state.header, (el) => el.child(v_flex().px(10).pt(12).gap(1).text_size(11.5).text_color(t.dim)
        .children(this.state.header.split("\n").filter((s) => s.trim()).map((s, i) => div().id(`hdr-${i}`).child(s)))));
    return root
      .when(!!this.error, (el) => el.child(div().px(14).py(4).bg(t.surface).text_color(t.ansi1).child(this.error)))
      .child(h_flex().flex_1().min_h(0).when(many, (el) => el.child(list)).child(card))
      .child(h_flex().h(28).flex_none().px(14).gap(12).items_center().justify_between().border_t(1).border_color(t.border)
        .bg(t.chrome).text_size(11.5).text_color(t.dim)
        .child(div().truncate().child(keyHint(many)))
        .child(div().truncate().child(this.message)));
  }
}
