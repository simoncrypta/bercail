import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";
import { expect, test } from "vite-plus/test";

const BEHAVIORS = join(import.meta.dirname, "..", ".agents", "behaviors");
const specs = readdirSync(BEHAVIORS, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name);

// The structural rules from agentbehavior.dev's specification, "Validation".
test.each(specs)("%s passes the format's structural rules", (dir) => {
  const text = readFileSync(join(BEHAVIORS, dir, "BEHAVIOR.md"), "utf8");
  // Pi's parser takes any line that starts with `---` as the end; the format wants the line itself.
  expect(text).toMatch(/^---\n[\s\S]*?\n---\n/);
  const { frontmatter, body } = parseFrontmatter<Record<string, unknown>>(text);
  expect(frontmatter).toBeTypeOf("object");
  expect(Array.isArray(frontmatter)).toBe(false);
  const { name, description, metadata } = frontmatter;
  expect(name).toBe(dir);
  expect(name).toMatch(/^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/);
  expect(description).toBeTypeOf("string");
  expect((description as string).trim().length).toBeGreaterThan(0);
  expect((description as string).length).toBeLessThanOrEqual(1024);
  if (metadata !== undefined) {
    expect(metadata).toBeTypeOf("object");
    expect(Array.isArray(metadata)).toBe(false);
  }
  expect(body.trim().length).toBeGreaterThan(0);
});

// Section 6 of docs/plans/v0.18.md: each group maps to a spec that exists, or is marked a product bug.
test("each ledger group maps to a spec or is marked a product bug", () => {
  const rows: [string, string][] = [];
  for (const line of readFileSync(join(BEHAVIORS, "README.md"), "utf8").split("\n")) {
    const row = /^\| (G\d+) [^|]+\| (.+) \|$/.exec(line);
    if (row) rows.push([row[1], row[2]]);
  }
  expect(rows.map(([group]) => group)).toEqual(Array.from({ length: 10 }, (_, i) => `G${i + 1}`));
  for (const [group, target] of rows) {
    const links = [...target.matchAll(/\]\(([a-z0-9-]+)\/BEHAVIOR\.md\)/g)].map((m) => m[1]);
    if (target.startsWith("product bug:")) expect(links, group).toEqual([]);
    else expect(links.length, group).toBeGreaterThan(0);
    for (const spec of links) expect(existsSync(join(BEHAVIORS, spec, "BEHAVIOR.md")), `${group} ${spec}`).toBe(true);
  }
});
