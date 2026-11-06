// bercail review: the Stack tab of a `bercail review-pr` space.
//
// props.stack is the stack's run dir, props.bercail the bercail that made the tab.
// Everything shown comes from `bercail review-pr state` (the run dir as one JSON
// document); the mod reads nothing else and writes nothing. It reloads when the run
// dir changes, so a row turns ready when its pass writes run.json.
//
// j/k or ↑/↓ pick a PR. Its three actions, by key or by their buttons on the card:
// c  Code review: a Review #N tab on tuicr pr N, seeded with the [AI Agent] questions.
// r  Re-review: gather the stack again, then run this PR's decisions pass again.
// o  Shell: the review worktree on the PR's branch, and a shell tab in it.
import { View, div } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { exec, focused, home, notify, props, readTextFile, run, theme, watchFolder } from "herdr";

// What a pass or a gather streams into: no change to what the tab shows.
const NOISE = /\/(pass\.(jsonl|err|log)|summary\.(jsonl|err|log)|summary-input\.json|open\.log|rereview\.log)$|\/source\/|\.(json|md|patch)\.[A-Za-z0-9]{6}$/;
const SPIN = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const CI_ORDER = ["fail", "pending", "cancel", "pass", "skipping"];
// Where a detached command leaves its exit code and its last output lines, one file
// per job; the tab reads it and removes it. Not the run dir, which only bercail writes.
const JOBS = "/.cache/bercail/review-jobs";
// $0 log, $1 status file, then the command. The log keeps the whole output, as before.
const INNER = 'log=$0; status=$1; shift; rc=0; out=$("$@" 2>&1 </dev/null) || rc=$?; printf "%s\\n" "$out" >>"$log"; '
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

export const shortRef = (s) => s.length > 48 && s.includes("/") ? s.slice(s.lastIndexOf("/") + 1) : s;

// Backticks mark explicit code. Also recognize identifiers and paths in existing
// cards, which predate that convention. Everything remains native text, never HTML.
export function textTokens(text) {
  return String(text ?? "").split(/(`[^`\n]+`)/g).filter(Boolean).flatMap((s) => {
    if (s.startsWith("`") && s.endsWith("`")) return [{ text: s.slice(1, -1), code: true }];
    return s.split(/(\b[a-z_$][\w$]*[A-Z_][\w$]*(?:\.[\w$]+)*|\b[\w$]+\(\)|\b[\w.-]+\.(?:tsx?|jsx?|sh|py|rs|sql|json|toml|md)(?::\d+(?:-\d+)?)?|\.[a-z_$][\w$]*(?=\()|\b(?:[\w@.-]+\/)+[\w@.-]+\.[A-Za-z0-9]+(?::\d+(?:-\d+)?)?)/g)
      .flatMap((part, i) => i % 2 ? [{ text: part, code: true }]
        : (part.match(/\S+\s*|\s+/g) ?? []).map((text) => ({ text, code: false })));
  });
}

const ACTIONS = [
  { name: "review", key: "c", label: "Code review" },
  { name: "rereview", key: "r", label: "Re-review" },
  { name: "shell", key: "o", label: "Shell" },
];

export default class Review extends View {
  init(_props, cx) {
    this.h = cx.focus_handle();
    this.state = null;
    this.error = "";
    this.message = "";
    this.sel = null;
    this.jobs = [];
    // Only while a detached command runs: its status file is outside the watched run dir.
    this.loaded = 0;
    cx.timer.every(1000, (cx) => {
      if (this.jobs.length && !this.checking) cx.spawn(async (cx) => this.ended(cx));
      // A pass killed outside its traps leaves its lock and changes no file: look again now and then.
      if (this.prs().some((p) => p.pass === "running") && Date.now() - this.loaded > 15000) {
        this.loaded = Date.now();
        cx.spawn(async (cx) => this.reload(cx));
      }
    });
    // Status files of jobs a reload of this mod forgot.
    exec("find", [`${home()}${JOBS}`, "-type", "f", "-mmin", "+1440", "-delete"]).catch(() => {});
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
      this.loaded = Date.now();
      // A checkout or gather moved the worktree: the card follows it.
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
    // A gather can drop PRs: keep the selection in the stack, so j/k move from what shows.
    if (this.sel != null) this.sel = Math.max(0, Math.min(this.sel, prs.length - 1));
    return prs[this.sel ?? 0];
  }

  say(text, cx) {
    this.message = text;
    cx.notify();
  }

  // Off the tab's exec (30 s limit): a pass, a gather or tuicr's wait takes longer.
  async detach(what, argv, log) {
    const status = `${home()}${JOBS}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${++seq}`;
    this.jobs.push({ what, status, at: Date.now() });
    try {
      const r = await exec("sh", ["-c", OUTER, "sh", INNER, log, status, ...argv]);
      if (r.code !== 0) throw new Error(r.stderr.trim() || `exit ${r.code}`);
    } catch (e) {
      this.jobs = this.jobs.filter((j) => j.status !== status);
      throw e;
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
        // review-pr run prints run.json last (blocked exits 0, with a reason); a re-review's
        // gather prints its own JSON before it. Other commands end on an error line.
        const out = lines.join("\n").trim();
        const at = out.lastIndexOf("\n{");
        let run = null;
        try { run = JSON.parse(at < 0 ? out : out.slice(at + 1)); } catch {}
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
    // cx: the spawned task's, never this handler's (it ends when the handler returns).
    const fail = (what, cx) => (e) => {
      this.say(`${what} failed: ${e?.message ?? e}`, cx);
      notify({ title: `bercail: ${what}`, body: String(e?.message ?? e), level: "error" });
    };
    switch (name) {
      case "review":
        this.say(`opening tuicr on #${n}…`, cx);
        cx.spawn(async (cx) => this.detach(`code review #${n}`, [self, "review-pr", "open", n, "--stack", s.stack], `${s.stack}/open.log`)
          .catch(fail(`code review #${n}`, cx)));
        return;
      case "rereview":
        // review-pr refuses to gather while a pass runs, and only its log would say so.
        if (this.prs().some((p) => p.pass === "running")) return this.say("a pass is running; re-review when it ends", cx);
        // A gather and a pass take minutes; one with no status file after 20 is not one to wait for.
        if (this.jobs.some((j) => j.what.startsWith("re-review") && Date.now() - j.at < 1200000)) {
          return this.say("a re-review is already running", cx);
        }
        this.say(`re-reviewing #${n}: gathering the stack, then its pass…`, cx);
        cx.spawn(async (cx) => this.detach(`re-review #${n}`, [self, "review-pr", "rereview", n, "--stack", s.stack], `${s.stack}/rereview.log`)
          .catch(fail(`re-review #${n}`, cx)));
        return;
      case "shell": {
        // This tab's space now: the checkout can take seconds, and the person may move on.
        const space = focused()?.space;
        this.say(`checking out #${n}…`, cx);
        cx.spawn(async (cx) => {
          try {
            const r = await exec(self, ["review-pr", "checkout", n, "--stack", s.stack]);
            if (r.code !== 0) throw new Error(r.stderr.trim().split("\n").at(-1) || `exit ${r.code}`);
            const out = JSON.parse(r.stdout);
            run("tab.new", { ...(space ? { space } : {}), name: `Shell #${n}`, folder: out.worktree });
            this.say(out.branch ? `#${n} is on ${out.branch} in the shell tab` : `#${n} at its head, detached: ${out.note}`, cx);
          } catch (e) {
            fail(`shell #${n}`, cx)(e);
          }
        });
        return;
      }
    }
  }

  key(e, cx) {
    const move = (d) => {
      this.current();
      this.sel = Math.max(0, Math.min(this.prs().length - 1, this.sel + d));
      cx.notify();
    };
    const k = e.keystroke;
    const action = ACTIONS.find((a) => a.key === k);
    if (action) this.act(action.name, cx);
    else if (this.prs().length > 1 && (k === "j" || k === "down")) move(1);
    else if (this.prs().length > 1 && (k === "k" || k === "up")) move(-1);
    else return;
    cx.stop_propagation();
  }

  passColor(t, pass) {
    return { ready: t.ansi2, running: t.working, failed: t.ansi1, blocked: t.blocked }[pass] ?? t.muted;
  }

  row(t, pr, i, on) {
    const running = pr.pass === "running";
    return h_flex()
      .id(`row-${pr.number}`)
      .px(10)
      .py(7)
      .gap(9)
      .rounded(7)
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
        .child(div().truncate().text_size(13.5).font_semibold().text_color(t.foreground).child(`#${pr.number} ${pr.title}`))
        .child(div().truncate().text_size(12.5).text_color(t.foreground).tooltip(pr.intent || "Awaiting code-based intent inference.")
          .child(pr.intent || "Awaiting code-based intent inference."))
        .child(div().truncate().text_size(12).text_color(t.muted).child(`${pr.pass} · CI ${ciCounts(pr.ci)}`)));
  }

  code(t, text) {
    return div().font_family("JetBrains Mono").text_size(12.5).text_color(t.ansi6).bg(t.raised)
      .px(4).rounded(3).whitespace_nowrap().max_w_full().truncate().tooltip(text).child(shortRef(text));
  }

  prose(t, text) {
    return h_flex().min_w(0).flex_wrap().items_baseline().text_size(14).text_color(t.foreground)
      .children(textTokens(text).map((p) => p.code ? this.code(t, p.text) : div().child(p.text)));
  }

  section(t, title, children, meta = "") {
    return v_flex().gap(9).pt(18).pb(4)
      .child(h_flex().gap(10).items_baseline().pb(6).border_b(1).border_color(t.border)
        .child(div().text_size(16).font_bold().text_color(t.accent).child(title))
        .when(!!meta, (el) => el.child(div().text_size(12).text_color(t.muted).child(meta))))
      .children(children);
  }

  field(t, label, value) {
    return v_flex().gap(3)
      .child(div().text_size(11.5).font_semibold().text_color(t.muted).child(label))
      .child(typeof value === "string" ? this.prose(t, value) : value);
  }

  body(t, pr) {
    const r = pr.review;
    const body = v_flex().gap(2);
    if (r?.intent_analysis) {
      const a = r.intent_analysis;
      body.child(this.section(t, "Inferred intent", [
        this.prose(t, r.why),
        this.field(t, "Confidence", a.confidence),
        this.field(t, "Evidence", h_flex().flex_wrap().gap(6).children(a.evidence.map(loc).filter(Boolean).map((at) => this.code(t, at)))),
        this.field(t, "Right thing to build", a.assessment),
      ], "best educated guess from code"));
      body.child(this.section(t, "Clue comparison", a.clues.map((c) => v_flex().p(12).gap(8).rounded(8).bg(t.surface)
        .child(this.field(t, "Source", c.source))
        .child(this.field(t, "Alignment", c.alignment))
        .child(this.field(t, "Comparison", c.detail)))));
    } else if (r) {
      body.child(this.section(t, "Saved review context", [this.prose(t, r.why || "Not given"),
        div().text_size(12).text_color(t.muted).child(r.why_source || "No source given"),
        this.prose(t, "Re-review for code-based intent, confidence and clue comparison."),
      ]));
    } else {
      body.child(this.section(t, "Inferred intent", [this.prose(t, "Awaiting code-based intent inference.")]));
    }
    if (r) {
      body.child(this.section(t, "Decisions", r.decisions.map((d, i) => v_flex().p(12).gap(10).rounded(8).bg(t.surface)
          .child(this.field(t, "Kind", div().text_size(13).font_bold().text_color(t.accent).child(`${i + 1}. ${d.kind}`)))
          .child(this.field(t, "Summary", d.statement))
          .child(this.field(t, "Evidence", h_flex().flex_wrap().gap(6).children((d.evidence ?? []).map(loc).filter(Boolean)
            .map((at) => this.code(t, at)))))
          .child(this.field(t, "Stated", d.stated || "UNDOCUMENTED"))
          .child(this.field(t, "Fit", div().font_semibold()
            .text_color(d.fits_intent === "yes" ? t.ansi2 : d.fits_intent === "no" ? t.ansi1 : t.ansi3).child(d.fits_intent || "unclear")))
          .child(this.field(t, "Alternative", d.alternative || "Not given"))),
        `${r.decisions.length} choices · ${r.decisions.filter((d) => d.stated == null).length} undocumented`));
      if (r.unmet_intent?.length) body.child(this.section(t, "Unmet", r.unmet_intent.map((u) => v_flex().gap(4)
        .child(this.prose(t, u.promise)).child(div().text_size(12).text_color(t.muted).child(u.source || "No source given")))));
    }
    if (pr.questions?.length) body.child(this.section(t, "Questions", pr.questions.map((q, i) => v_flex().gap(5).pb(7)
      .child(h_flex().gap(8).items_center()
        .child(div().font_semibold().text_color(t.accent).child(`${i + 1}. [AI Agent]`))
        .child(q.at ? this.code(t, q.at) : div().text_color(t.muted).child("whole PR")))
      .child(this.prose(t, q.text)))));
    const b = pr.bots;
    body.child(this.section(t, "Bots", b ? [
      this.prose(t, `${b.threads} threads, ${b.unresolved} unresolved (${b.on_decisions} on a decision's file)`),
      this.prose(t, `${b.reviews} reviews, ${b.comments} comments`),
      div().text_size(12).text_color(t.muted).child((b.authors ?? []).join(", ")),
    ] : [div().text_color(t.muted).child("Not gathered yet")]));
    const rank = (c) => { const i = CI_ORDER.indexOf(c.bucket ?? "pending"); return i < 0 ? 5 : i; };
    body.child(this.section(t, "CI", [...(pr.ci ?? [])].sort((a, b) => rank(a) - rank(b)).map((c, i) => v_flex().gap(3)
      .child(div().font_semibold().text_color(c.bucket === "fail" ? t.ansi1 : t.foreground).child(`${c.bucket ?? "pending"}: ${c.name}`))
      .when(!!c.workflow, (el) => el.child(div().text_size(12).text_color(t.muted).child(c.workflow)))
      .when(/^https?:\/\//.test(c.link ?? "") && (c.bucket === "fail" || c.bucket === "pending"), (el) => el.child(
        div().id(`ci-link-${i}`).truncate().text_size(12.5).text_color(t.accent).tooltip(c.link).cursor_pointer()
          .on_click((_e, cx) => cx.open_url(c.link)).child(c.link)))), ciCounts(pr.ci)));
    return body;
  }

  overview(t) {
    const s = this.state.summary;
    const box = v_flex().id("stack-summary").p(10).gap(10).mb(10).pb(16).border_b(1).border_color(t.border)
      .child(div().text_size(16).font_bold().text_color(t.accent).child(`Stack #${this.state.root}`))
      .child(div().text_size(12).text_color(t.muted).child(this.state.repo));
    if (s?.status !== "ready") return box.child(div().text_size(12.5).text_color(t.muted)
      .child(s?.status === "running" ? "Desk is writing the stack summary…" : s?.reason || "Stack summary follows when every card is ready."));
    box.child(this.prose(t, s.overview).text_size(13));
    for (const [label, lines] of [["Order", s.order], ["Risks", s.risks], ["Look here first", s.start_here]]) {
      box.child(v_flex().gap(5).child(div().font_bold().text_size(12.5).text_color(t.accent).child(label))
        .children(lines.map((line) => this.prose(t, `• ${line}`).text_size(13))));
    }
    return box;
  }

  button(t, a) {
    return h_flex()
      .id(`act-${a.name}`)
      .h(30)
      .px(10)
      .gap(8)
      .items_center()
      .rounded(7)
      .border(1)
      .border_color(t.border)
      .bg(t.raised)
      .cursor_pointer()
      .hover((el) => el.bg(t.hover))
      .on_click((_e, cx) => {
        this.h.focus();
        this.act(a.name, cx);
      })
      .child(div().px(6).rounded(4).bg(t.surface).text_size(12).font_bold().text_color(t.muted).child(a.key))
      .child(div().text_size(13.5).font_semibold().text_color(t.foreground).child(a.label));
  }

  header(t, pr) {
    return v_flex().gap(5).pb(12).mb(4).border_b(1).border_color(t.border)
      .child(h_flex().gap(8).items_center()
        .child(div().text_size(18).text_color(t.muted).child(`#${pr.number}`))
        .child(div().flex_1().min_w(0).text_size(18).font_bold().text_color(t.foreground).child(pr.title)))
      .child(div().truncate().max_w_full().text_size(13).text_color(t.muted)
        .tooltip(`by ${pr.author} · ${pr.base} ← ${pr.head} · ${pr.head_sha} · ${pr.url}`)
        .child(`by ${pr.author} · ${pr.base} ← ${pr.head} · ${pr.head_sha.slice(0, 7)}${pr.draft ? " · draft" : ""} · ${pr.url}`))
      .when(!!pr.thin?.length, (el) => el.child(div().text_size(13).text_color(t.ansi3).child(`thin: ${pr.thin.join(", ")}`)))
      .child(h_flex().gap(7).items_center().text_size(13)
        .child(div().text_color(this.passColor(t, pr.pass)).child(pr.pass === "running" ? div().frames(SPIN, 90) : "●"))
        .child(div().text_color(t.foreground).child(`Decisions pass: ${pr.status.replace(/; bercail review-pr run$/, "; r runs it")}`)))
      .child(h_flex().pt(4).gap(8).children(ACTIONS.map((a) => this.button(t, a))));
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
      .text_size(14)
      .text_color(t.foreground)
      .track_focus(this.h)
      .on_key_down((e, cx) => this.key(e, cx))
      .on_mouse_down("left", () => this.h.focus());
    if (!this.state) {
      return root.p(16).child(div().text_color(this.error ? t.ansi1 : t.muted).child(this.error || "Loading the stack…"));
    }
    const card = v_flex().id("review-card").flex_1().min_w(0).px(20).py(16).overflow_y_scrollbar()
      .when(!!pr, (el) => el
        .when(!many, (el) => el.child(this.overview(t)))
        .child(this.header(t, pr))
        .child(this.body(t, pr)));
    const list = v_flex().id("review-list").w(350).h_full().min_h(0).flex_none().p(8).gap(2).border_r(1).border_color(t.border)
      .bg(t.surface)
      .child(this.overview(t).max_h(260).flex_none().overflow_y_scrollbar())
      .child(v_flex().id("review-picker").flex_1().min_h(0).overflow_y_scrollbar()
        .children(prs.map((p, i) => this.row(t, p, i, p === pr))));
    return root
      .when(!!this.error, (el) => el.child(div().px(14).py(5).bg(t.surface).text_color(t.ansi1).child(this.error)))
      .child(h_flex().flex_1().min_h(0).items_stretch().when(many, (el) => el.child(list)).child(card))
      .child(h_flex().h(30).flex_none().px(14).gap(12).items_center().justify_between().border_t(1).border_color(t.border)
        .bg(t.chrome).text_size(12.5)
        .child(div().truncate().text_color(t.muted)
          .child(`${many ? "j/k pick · " : ""}${ACTIONS.map((a) => `${a.key} ${a.label.toLowerCase()}`).join(" · ")}`))
        .child(div().truncate().text_color(t.foreground).child(this.message)));
  }
}
