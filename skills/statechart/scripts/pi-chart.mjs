// chart.mmd as a post for Pi's chat (chart.pi.md). Pi's terminal Mermaid draws
// a chart only when it fits the pane, and drops the class colours, so the post is
// the chart top to bottom without its Legend, then each marked state and every
// arrow in words. Over MAX states it is no chart: the owner gets report.md's path.
import { readFileSync, writeFileSync } from "node:fs";

const MAX = 20;
const [from, to] = process.argv.slice(2);
const mmd = readFileSync(from, "utf8");
// Upstream writes a character it must escape as #<code>;.
const text = (s) => s.replace(/#(\d+);/g, (_, n) => String.fromCodePoint(Number(n))).replace(/\u2060/g, "");

const names = new Map();
const leaves = [];
const arrows = [];
const marks = new Map();
const legend = new Map();
const parents = [];
for (const line of mmd.split("\n")) {
  let m;
  if ((m = /^\s*state "(.*)" as (\w+) \{$/.exec(line))) {
    parents.push(m[2] === "all" || m[2] === "legend" ? null : text(m[1]));
    names.set(m[2], parents.filter(Boolean).join(" › "));
  } else if (/^\s*\}$/.test(line)) parents.pop();
  else if ((m = /^\s*(lg\d+): (.*)$/.exec(line))) legend.set(m[1], text(m[2]));
  else if ((m = /^\s*(s\d+): (.*)$/.exec(line))) {
    names.set(m[1], [...parents.filter(Boolean), text(m[2])].join(" › "));
    leaves.push(m[1]);
  } else if ((m = /^\s*(\[\*\]|\w+) --> (\w+)(?:: (.*))?$/.exec(line)))
    // A [*] inside a parent is where the parent starts, not the chart.
    arrows.push([m[1], m[2], m[3] && text(m[3]), parents.filter(Boolean).join(" › ")]);
  else if ((m = /^\s*class (\w+) (\w+)$/.exec(line))) marks.set(m[1], [...(marks.get(m[1]) ?? []), m[2]]);
}

const out = [];
if (leaves.length > MAX) {
  out.push(
    `No chart: it has ${leaves.length} states, over the ${MAX} a chart in chat may have.`,
    "Post the shortest path from report.md as text, or draw a smaller config or view.",
  );
} else {
  // Pi draws neither the Legend nor the class colours.
  const chart = mmd
    .replace("direction LR", "direction TB")
    .replace(/ {2}state "Legend" as legend \{[\s\S]*?\n {2}\}\n/, "")
    .replace(/^ {2}(class|classDef) .*\n/gm, "");
  out.push("```mermaid", chart.trimEnd(), "```", "");
  // The chart marks a bug path's states, not their order: report.md numbers it.
  for (const [lg, label] of legend) {
    const cls = marks.get(lg)?.[0];
    if (!["breaks", "mayBreak", "bugPath", "repeats"].includes(cls)) continue;
    const states = leaves.filter((s) => marks.get(s)?.includes(cls)).map((s) => names.get(s));
    const head =
      cls === "bugPath" ? `States on the ${label[0].toLowerCase()}${label.slice(1)} (report.md has the order)` : label;
    if (states.length) out.push(`${head}: ${states.join("; ")}.`);
  }
  if (out.at(-1) !== "") out.push("");
  out.push("Arrows:");
  for (const [a, b, label, parent] of arrows) {
    const from = a !== "[*]" ? names.get(a) : parent ? `start of ${parent}` : "start";
    out.push(`- ${from} -> ${names.get(b)}${label ? `: ${label}` : ""}`);
  }
}
writeFileSync(to, `${out.join("\n")}\n`);
console.log(`${to}: ${leaves.length > MAX ? `no chart (${leaves.length} states)` : `${leaves.length} states`}`);
