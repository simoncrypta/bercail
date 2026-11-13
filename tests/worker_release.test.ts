// The Worker serves the repo at the latest release's tag, pins install.sh to
// it, and never falls back to master. No network: fetch is a stand-in.
import { readFile } from "node:fs/promises";
import { beforeEach, describe, expect, test, vi } from "vite-plus/test";

const installSh = await readFile(new URL("../install.sh", import.meta.url), "utf8");
let fromGitHub: (url: URL) => Promise<Response>;

// A fresh module per test: the last known tag lives in it.
beforeEach(async () => {
  vi.resetModules();
  ({ fromGitHub } = await import("../site/github.ts"));
});

// latest: the tag github.com redirects /releases/latest to, or an Error to throw.
function standIn(latest: string | Error): string[] {
  const seen: string[] = [];
  vi.stubGlobal("fetch", async (input: string | URL, init: RequestInit = {}) => {
    const url = String(input);
    seen.push(url);
    if (url.endsWith("/releases/latest")) {
      if (latest instanceof Error) throw latest;
      expect(init.redirect, "the release lookup must read the redirect, not follow it").toBe("manual");
      const headers: Record<string, string> = latest
        ? { Location: `https://github.com/simoncrypta/bercail/releases/tag/${latest}` }
        : {};
      return new Response(null, { status: latest ? 302 : 500, headers });
    }
    const raw = url.match(/^https:\/\/raw\.githubusercontent\.com\/simoncrypta\/bercail\/([^/]+)(\/.*)$/);
    if (!raw) throw new Error(`unexpected fetch ${url}`);
    if (raw[2] === "/install.sh") return new Response(installSh, { headers: { "Content-Length": "1" } });
    if (raw[2] === "/lib/common.sh") return new Response(`# lib at ${raw[1]}\n`);
    return new Response("404: Not Found", { status: 404 });
  });
  return seen;
}

function noMaster(seen: string[]): void {
  for (const url of seen) expect(url, "fetched trunk").not.toMatch(/\/(master|main)\//);
}

describe("with a release", () => {
  test("/install.sh comes from the latest release's tag, pinned to it", async () => {
    const seen = standIn("v0.13.0");
    const res = await fromGitHub(new URL("https://bercail.dev/install.sh"));
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body, "install.sh is pinned to the tag it came from").toMatch(/^BERCAIL_RELEASE="v0\.13\.0"$/m);
    expect(body.length).toBe(installSh.length + "v0.13.0".length);
    expect(res.headers.get("Content-Length"), "a rewritten body must not keep upstream's length").not.toBe("1");
    expect(seen).toContain("https://raw.githubusercontent.com/simoncrypta/bercail/v0.13.0/install.sh");
    noMaster(seen);
  });

  test("other paths come from the same tag, unchanged", async () => {
    standIn("v0.13.0");
    const lib = await fromGitHub(new URL("https://bercail.dev/lib/common.sh"));
    expect(await lib.text()).toBe("# lib at v0.13.0\n");
    expect(lib.headers.get("Content-Type")).toBe("text/plain; charset=utf-8");
  });

  test("a newer release replaces the tag; when GitHub fails, the last known tag keeps serving", async () => {
    standIn("v0.13.0");
    await fromGitHub(new URL("https://bercail.dev/install.sh"));
    standIn("v0.14.0");
    expect(await (await fromGitHub(new URL("https://bercail.dev/lib/common.sh"))).text()).toBe("# lib at v0.14.0\n");
    for (const latest of [new Error("network down"), ""]) {
      const seen = standIn(latest);
      const again = await fromGitHub(new URL("https://bercail.dev/install.sh"));
      expect(again.status).toBe(200);
      expect(await again.text()).toMatch(/^BERCAIL_RELEASE="v0\.14\.0"$/m);
      noMaster(seen);
    }
  });
});

describe("with no tag known", () => {
  test.each([
    ["GitHub unreachable", new Error("network down")],
    ["no redirect", ""],
    ["master", "master"],
    ["a path", "../../evil"],
  ])("%s: a 503 instead of master, and nothing fetched", async (_name, latest) => {
    const seen = standIn(latest);
    const res = await fromGitHub(new URL("https://bercail.dev/install.sh"));
    expect(res.status).toBe(503);
    expect(res.headers.get("Retry-After")).toBe("60");
    expect(seen, "nothing is fetched without a tag").toEqual([
      "https://github.com/simoncrypta/bercail/releases/latest",
    ]);
  });
});
