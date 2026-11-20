// The offline decision-question detector experiment (docs/investigations/decision-detector.md).
// Message text is not checked in, only ids and labels. The bridge receives each reply, in argv.
//   node detector.mjs extract <session.jsonl>...          > candidates.jsonl
//   node detector.mjs sample <candidates.jsonl> [entry]... > sample.jsonl
//   node detector.mjs classify <model> <candidates.jsonl> [labels.jsonl] > model.jsonl
//   node detector.mjs score <labels.jsonl> <candidates.jsonl> <small.jsonl> <large.jsonl>
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const readJsonl = (file) =>
  readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
const key = (row) => `${row.session}:${row.entry}`;
const text = (content) =>
  typeof content === "string"
    ? content
    : (content ?? [])
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join("\n");

// Shep's session is live: the experiment reads the replies written up to the labeling.
const CUTOFF = "2026-11-20T00:30:00Z";

// Shep's final replies (stopReason "stop" with text), with whether a shep_question card was made in that turn.
function extract(files) {
  for (const file of files) {
    const session = basename(file)
      .replace(/^.*_/, "")
      .replace(/\.jsonl$/, "");
    const kind = file.includes("/discuss/") ? "discuss" : "main";
    let cards = 0;
    for (const entry of readJsonl(file)) {
      if (entry.type === "custom_message" || (entry.type === "message" && entry.message.role === "user")) cards = 0;
      if (entry.type !== "message" || entry.message.role !== "assistant") continue;
      for (const part of entry.message.content ?? [])
        if (part.type === "toolCall" && part.name === "shep_question") cards++;
      const reply = text(entry.message.content).trim();
      if (entry.message.stopReason === "stop" && reply && entry.timestamp < CUTOFF)
        console.log(
          JSON.stringify({ session, kind, entry: entry.id, at: entry.timestamp, cardInTurn: cards, text: reply }),
        );
    }
  }
}

// Strata oversample the hard cases: a card in the turn, a question mark, then the rest.
const SIZES = { card: 60, qmark: 140, plain: 100 };
const stratum = (row) => (row.cardInTurn > 0 ? "card" : /\?/.test(row.text) ? "qmark" : "plain");

// A deterministic draw: each stratum ordered by sha256 of session:entry, plus forced entries.
function sample(file, force) {
  const rows = readJsonl(file);
  const hash = (row) => createHash("sha256").update(key(row)).digest("hex");
  const picked = new Set(force);
  for (const [name, size] of Object.entries(SIZES))
    rows
      .filter((row) => stratum(row) === name)
      .sort((a, b) => (hash(a) < hash(b) ? -1 : 1))
      .slice(0, size)
      .forEach((row) => picked.add(row.entry));
  for (const row of rows) if (picked.has(row.entry)) console.log(JSON.stringify({ ...row, stratum: stratum(row) }));
}

// One headless Pi turn on the Claude bridge: no tools, skills, context files or session.
function ask(model, prompt, message) {
  const bridge = join(homedir(), ".pi/agent/npm/node_modules/pi-claude-bridge");
  const args = [
    "-p",
    "--no-session",
    "--no-tools",
    "--no-extensions",
    "-e",
    bridge,
    "--no-skills",
    "--no-context-files",
    "--no-prompt-templates",
    "--no-themes",
    "--provider",
    "claude-bridge",
    "--model",
    model,
    "--thinking",
    "off",
    "--system-prompt",
    prompt,
    `Shep's message:\n<<<\n${message}\n>>>`,
  ];
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn("pi", args, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.on("data", (chunk) => (out += chunk));
    child.stderr.on("data", (chunk) => (err += chunk));
    // Only a clean exit's stdout counts: a p in an error message is not an answer.
    child.on("close", (code) => {
      const match = code === 0 ? out.match(/"p"\s*:\s*([0-9.]+)/) : null;
      const p = match ? Number(match[1]) : NaN;
      const ok = Number.isFinite(p) && p >= 0 && p <= 1;
      resolve({ p: ok ? p : null, ms: Date.now() - started, raw: ok ? undefined : (out + err).slice(-300) });
    });
  });
}

async function classify(model, file, labelsFile) {
  const prompt = readFileSync(join(here, "prompt.md"), "utf8");
  const only = labelsFile ? new Set(readJsonl(labelsFile).map(key)) : null;
  const queue = readJsonl(file).filter((row) => !only || only.has(key(row)));
  const worker = async () => {
    for (let row = queue.shift(); row; row = queue.shift()) {
      let result = await ask(model, prompt, row.text);
      if (result.p === null) result = await ask(model, prompt, row.text);
      console.log(JSON.stringify({ session: row.session, entry: row.entry, model, ...result }));
    }
  };
  await Promise.all(Array.from({ length: Number(process.env.JOBS ?? 4) }, worker));
}

// Precision, recall and accuracy at a 0.5 cutoff, over rows with a label and an answer.
function metrics(rows, decide) {
  let tp = 0,
    fp = 0,
    fn = 0,
    tn = 0;
  for (const row of rows) {
    const yes = decide(row);
    if (yes && row.label) tp++;
    else if (yes) fp++;
    else if (row.label) fn++;
    else tn++;
  }
  const n = tp + fp + fn + tn;
  return { n, tp, fp, fn, tn, precision: tp / (tp + fp), recall: tp / (tp + fn), accuracy: (tp + tn) / n };
}

const pct = (x) => (Number.isFinite(x) ? `${(100 * x).toFixed(1)}%` : "n/a");
const row = (cells) => `| ${cells.join(" | ")} |`;

function score(labelsFile, candidatesFile, smallFile, largeFile) {
  const labels = new Map(readJsonl(labelsFile).map((l) => [key(l), l]));
  const small = new Map(readJsonl(smallFile).map((r) => [key(r), r.p]));
  const large = new Map(readJsonl(largeFile).map((r) => [key(r), r.p]));
  const candidates = readJsonl(candidatesFile);
  const strata = {};
  for (const c of candidates) strata[stratum(c)] = (strata[stratum(c)] ?? 0) + 1;
  const rows = candidates
    .filter((c) => labels.has(key(c)))
    .map((c) => ({
      ...labels.get(key(c)),
      stratum: stratum(c),
      small: small.get(key(c)),
      large: large.get(key(c)),
    }));
  const answered = rows.filter((r) => r.small != null && r.large != null);
  const cut = 0.5;

  const yes = rows.filter((r) => r.label).length;
  const hard = rows.filter((r) => r.hard).length;
  console.log(
    `Candidates: ${candidates.length} ${JSON.stringify(strata)}. Labeled: ${rows.length}, yes ${yes}, hard ${hard}.`,
  );
  console.log(`Answered by both models: ${answered.length}.\n`);

  console.log(row(["Set", "Model", "n", "Precision", "Recall", "Accuracy", "FP", "FN"]));
  console.log(row(Array(8).fill("---")));
  const sets = {
    all: answered,
    hard: answered.filter((r) => r.hard),
    "no card": answered.filter((r) => r.stratum !== "card"),
  };
  for (const [name, set] of Object.entries(sets))
    for (const field of ["small", "large"]) {
      const m = metrics(set, (r) => r[field] >= cut);
      console.log(row([name, field, m.n, pct(m.precision), pct(m.recall), pct(m.accuracy), m.fp, m.fn].map(String)));
    }

  // Calibration of each model: buckets of its stated probability against the labeled rate.
  const edges = [0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0001];
  for (const field of ["small", "large"]) {
    console.log(`\nCalibration, ${field}:\n`);
    console.log(row(["p bucket", "n", "mean p", "labeled yes", "gap"]));
    console.log(row(Array(5).fill("---")));
    let brier = 0,
      ece = 0;
    for (let i = 0; i < edges.length - 1; i++) {
      const bucket = answered.filter((r) => r[field] >= edges[i] && r[field] < edges[i + 1]);
      if (!bucket.length) continue;
      const meanP = bucket.reduce((s, r) => s + r[field], 0) / bucket.length;
      const rate = bucket.filter((r) => r.label).length / bucket.length;
      ece += (bucket.length / answered.length) * Math.abs(meanP - rate);
      const hi = Math.min(edges[i + 1], 1).toFixed(1);
      console.log(
        row(
          [`${edges[i].toFixed(1)}–${hi}`, bucket.length, meanP.toFixed(2), pct(rate), (meanP - rate).toFixed(2)].map(
            String,
          ),
        ),
      );
    }
    for (const r of answered) brier += (r[field] - (r.label ? 1 : 0)) ** 2;
    console.log(`\nBrier ${(brier / answered.length).toFixed(3)}, expected calibration error ${ece.toFixed(3)}.`);
    const wrong = answered.filter((r) => r[field] >= cut !== Boolean(r.label));
    console.log(
      `Its ${wrong.length} mistakes have p: ${wrong
        .map((r) => r[field])
        .sort((a, b) => a - b)
        .join(", ")}.`,
    );
  }

  // The hybrid: the small model decides outside [lo, hi]; inside, the large model does.
  const allSmall = candidates.map((c) => small.get(key(c))).filter((p) => p != null);
  console.log(`\nEscalation: the small model decides outside the band, the large one inside it.\n`);
  console.log(
    row(["Band", "Escalated (labeled)", "Escalated (all candidates)", "Hybrid accuracy", "Precision", "Recall"]),
  );
  console.log(row(Array(6).fill("---")));
  const bands = [
    [0.3, 0.9],
    [0.3, 0.7],
    [0.2, 0.8],
    [0.1, 0.9],
    [0.05, 0.95],
    [0.02, 0.98],
  ];
  for (const [lo, hi] of bands) {
    const inBand = (p) => p >= lo && p <= hi;
    const m = metrics(answered, (r) => (inBand(r.small) ? r.large : r.small) >= cut);
    const esc = answered.filter((r) => inBand(r.small)).length / answered.length;
    const escAll = allSmall.filter(inBand).length / allSmall.length;
    console.log(row([`${lo}–${hi}`, pct(esc), pct(escAll), pct(m.accuracy), pct(m.precision), pct(m.recall)]));
  }

  // Stratum weights turn the oversampled set back into Shep's real mix of messages.
  console.log(`\nWeighted to the real mix (stratum weight = candidates / labeled):\n`);
  const labeledPer = {};
  for (const r of answered) labeledPer[r.stratum] = (labeledPer[r.stratum] ?? 0) + 1;
  const weight = (r) => strata[r.stratum] / labeledPer[r.stratum];
  console.log(row(["Model", "Precision", "Recall", "Accuracy", "Positive rate"]));
  console.log(row(Array(5).fill("---")));
  for (const field of ["small", "large"]) {
    let tp = 0,
      fp = 0,
      fn = 0,
      tn = 0;
    for (const r of answered) {
      const w = weight(r);
      const yes = r[field] >= cut;
      if (yes && r.label) tp += w;
      else if (yes) fp += w;
      else if (r.label) fn += w;
      else tn += w;
    }
    const n = tp + fp + fn + tn;
    console.log(row([field, pct(tp / (tp + fp)), pct(tp / (tp + fn)), pct((tp + tn) / n), pct((tp + fn) / n)]));
  }
}

const [command, ...args] = process.argv.slice(2);
if (command === "extract") extract(args);
else if (command === "sample") sample(args[0], args.slice(1));
else if (command === "classify") await classify(args[0], args[1], args[2]);
else if (command === "score") score(...args);
else {
  console.error("usage: node detector.mjs extract|sample|classify|score … (see the header)");
  process.exit(2);
}
