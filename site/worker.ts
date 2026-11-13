import { fromGitHub } from "./github.ts";

type Env = { ASSETS: { fetch(request: Request): Promise<Response> } };

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/install.sh") return fromGitHub(url);
    return env.ASSETS.fetch(request);
  },
};
