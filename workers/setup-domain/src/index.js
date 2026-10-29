const GITHUB_REPO = "https://github.com/simoncrypta/bercail";
const GITHUB_SHA_API =
  "https://api.github.com/repos/simoncrypta/bercail/commits/master";
const UA = "bercail-cdn";

async function masterSha() {
  const response = await fetch(GITHUB_SHA_API, {
    headers: { "User-Agent": UA, Accept: "application/vnd.github.sha" },
    cf: { cacheTtl: 60 },
  });
  if (!response.ok) return "master";
  const sha = (await response.text()).trim();
  return /^[0-9a-f]{7,40}$/i.test(sha) ? sha : "master";
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "") {
      return Response.redirect(GITHUB_REPO, 301);
    }

    const sha = await masterSha();
    const upstream = new URL(
      `https://raw.githubusercontent.com/simoncrypta/bercail/${sha}${url.pathname}${url.search}`,
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

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};
