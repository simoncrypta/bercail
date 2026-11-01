import { fromGitHub } from "../workers/setup-domain/src/github.js";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/install.sh") return fromGitHub(url);
    return env.ASSETS.fetch(request);
  },
};
