import { fromGitHub } from "./github.js";

const GITHUB_REPO = "https://github.com/simoncrypta/bercail";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "") {
      return Response.redirect(GITHUB_REPO, 301);
    }
    return fromGitHub(url);
  },
};
