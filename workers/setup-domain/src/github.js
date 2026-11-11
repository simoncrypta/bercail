// Serve a path from the repo at the latest release's tag (60s cache). master is
// unreleased trunk: only a v* tag with a GitHub release (release.yml) ships.
const REPO = "simoncrypta/bercail";
const UA = "bercail-cdn";
const TAG = /^v[0-9][0-9A-Za-z.+-]*$/;

// The last tag GitHub named, kept while GitHub is unreachable. Never master.
let lastTag = "";

// github.com answers /releases/latest with a redirect to the release's tag: no
// API token and no API rate limit, which Workers share by egress IP.
export async function latestTag() {
  try {
    const response = await fetch(`https://github.com/${REPO}/releases/latest`, {
      headers: { "User-Agent": UA },
      redirect: "manual",
      cf: { cacheTtl: 60 },
    });
    const location = response.headers.get("Location") || "";
    const tag = decodeURIComponent(location.split("/releases/tag/")[1] || "");
    if (TAG.test(tag)) lastTag = tag;
  } catch {
    // Keep lastTag.
  }
  return lastTag;
}

export async function fromGitHub(url) {
  const tag = await latestTag();
  if (!tag) {
    return new Response(
      "Cannot reach GitHub to find the latest bercail release. Try again in a minute.\n",
      { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8", "Retry-After": "60" } },
    );
  }
  const upstream = new URL(
    `https://raw.githubusercontent.com/${REPO}/${tag}${url.pathname}${url.search}`,
  );
  const response = await fetch(upstream, {
    headers: { "User-Agent": UA },
    cf: { cacheTtl: 60, cacheEverything: true },
  });

  if (response.status === 404) {
    return new Response("Not found\n", { status: 404 });
  }

  const headers = new Headers(response.headers);
  if (url.pathname.endsWith(".sh") || url.pathname.endsWith(".toml")) {
    headers.set("Content-Type", "text/plain; charset=utf-8");
  }
  headers.set("Cache-Control", "public, max-age=60");

  let body = response.body;
  // Pin install.sh to the tag it came from, so every file it fetches is from it too.
  if (url.pathname === "/install.sh" && response.ok) {
    body = (await response.text()).replace(/^BERCAIL_RELEASE=""$/m, `BERCAIL_RELEASE="${tag}"`);
    for (const name of ["Content-Length", "Content-Encoding", "ETag"]) headers.delete(name);
  }

  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
