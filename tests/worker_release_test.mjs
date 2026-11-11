// The Worker serves the repo at the latest release's tag, pins install.sh to
// it, and never falls back to master. No network: fetch is a stand-in.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const installSh = await readFile(new URL("../install.sh", import.meta.url), "utf8");
const github = new URL("../workers/setup-domain/src/github.js", import.meta.url).href;
let fresh = 0;
const load = () => import(`${github}?${fresh++}`);

// latest: the tag github.com redirects /releases/latest to, or an Error to throw.
function standIn(latest) {
  const seen = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    seen.push(url);
    if (url.endsWith("/releases/latest")) {
      if (latest instanceof Error) throw latest;
      assert.equal(init.redirect, "manual", "the release lookup must read the redirect, not follow it");
      const headers = latest ? { Location: `https://github.com/simoncrypta/bercail/releases/tag/${latest}` } : {};
      return new Response(null, { status: latest ? 302 : 500, headers });
    }
    const raw = url.match(/^https:\/\/raw\.githubusercontent\.com\/simoncrypta\/bercail\/([^/]+)(\/.*)$/);
    assert.ok(raw, `unexpected fetch ${url}`);
    if (raw[2] === "/install.sh") return new Response(installSh, { headers: { "Content-Length": "1" } });
    if (raw[2] === "/lib/common.sh") return new Response(`# lib at ${raw[1]}\n`);
    return new Response("404: Not Found", { status: 404 });
  };
  return seen;
}

function noMaster(seen) {
  for (const url of seen) assert.ok(!/\/(master|main)\//.test(url), `fetched trunk: ${url}`);
}

{
  const { fromGitHub } = await load();
  const seen = standIn("v0.13.0");
  const res = await fromGitHub(new URL("https://bercail.dev/install.sh"));
  assert.equal(res.status, 200);
  const body = await res.text();
  assert.match(body, /^BERCAIL_RELEASE="v0\.13\.0"$/m, "install.sh is pinned to the tag it came from");
  assert.equal(body.length, installSh.length + "v0.13.0".length);
  assert.notEqual(res.headers.get("Content-Length"), "1", "a rewritten body must not keep upstream's length");
  assert.ok(seen.includes("https://raw.githubusercontent.com/simoncrypta/bercail/v0.13.0/install.sh"), seen.join("\n"));
  noMaster(seen);
  console.log("PASS: /install.sh comes from the latest release's tag, pinned to it");

  standIn("v0.13.0");
  const lib = await fromGitHub(new URL("https://setup.simoncrypta.dev/lib/common.sh"));
  assert.equal(await lib.text(), "# lib at v0.13.0\n");
  assert.equal(lib.headers.get("Content-Type"), "text/plain; charset=utf-8");
  console.log("PASS: other paths (the legacy host) come from the same tag, unchanged");

  // A newer release replaces the tag; GitHub failing after that keeps the last one.
  standIn("v0.14.0");
  assert.equal(await (await fromGitHub(new URL("https://bercail.dev/lib/common.sh"))).text(), "# lib at v0.14.0\n");
  for (const latest of [new Error("network down"), ""]) {
    const seen2 = standIn(latest);
    const again = await fromGitHub(new URL("https://bercail.dev/install.sh"));
    assert.equal(again.status, 200);
    assert.match(await again.text(), /^BERCAIL_RELEASE="v0\.14\.0"$/m);
    noMaster(seen2);
  }
  console.log("PASS: when GitHub fails, the last known tag keeps serving");
}

{
  const { fromGitHub } = await load();
  for (const latest of [new Error("network down"), "", "master", "../../evil"]) {
    const seen = standIn(latest);
    const res = await fromGitHub(new URL("https://bercail.dev/install.sh"));
    assert.equal(res.status, 503, `latest=${latest}`);
    assert.equal(res.headers.get("Retry-After"), "60");
    assert.deepEqual(seen, ["https://github.com/simoncrypta/bercail/releases/latest"], "nothing is fetched without a tag");
  }
  console.log("PASS: with no tag known, a 503 instead of master");
}
