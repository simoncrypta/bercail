// bercail's Pi guard. The decision functions are pure; the default export wires
// tool_call, the repo's git policy (bercail policy show), and the approval log.
import { appendFileSync, mkdirSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** The part of a repo's effective policy (lib/policy.sh) the guard enforces. */
export type Policy = {
  commit: "ask" | "allow";
  push: "ask" | "branch" | "main";
  agentMayRelease: boolean;
  /** A temp-dir repo with no remote: commits go through. */
  scratch: boolean;
  /** Entire captures sessions here (.entire/settings.json, enabled). */
  entire: boolean;
  /** For the log: the main checkout, and where each value came from. */
  repo: string;
  from: Record<string, string>;
};

export const defaultPolicy: Policy = {
  commit: "ask",
  push: "ask",
  agentMayRelease: false,
  scratch: false,
  entire: false,
  repo: "",
  from: {},
};

export type GuardInput = {
  role: string;
  hasUI: boolean;
  /** undefined: after a cd the guard could not follow. */
  cwd: string | undefined;
  /** Current branch per git dir. Missing: not looked up. "": lookup failed. */
  branches?: Record<string, string>;
  /** Effective policy per git dir. Missing: not looked up. */
  policies?: Record<string, Policy>;
  /** Files that decide what the guard lets through: the person edits them. */
  protectedFiles?: string[];
  home?: string;
  /** Within one command: a GIT_* variable now points git somewhere the guard cannot place. */
  gitEnv?: boolean;
  /** Within one command: a GIT_CONFIG* variable now points git at other config. */
  gitConfigEnv?: boolean;
  /** Within one command: repos it made with git init under a mktemp -d dir. */
  fresh?: ReadonlySet<string>;
  /** Within one command: an earlier part may have switched the branch. */
  branchMoved?: boolean;
};

export type GuardDecision =
  | { action: "allow"; approved?: string[] }
  | { action: "block"; reason: string }
  | { action: "ask"; reason: string }
  | { action: "need-branch"; dir: string }
  | { action: "need-policy"; dir: string };

const force = "Force-push is blocked. Push without --force, or ask the person.";
const plusRef = "A refspec starting with + is a force-push. Push the branch without +.";
const mirror = "git push --mirror is blocked.";
const deleteMain = "Deleting main or master is blocked.";
const noVerify = "Skipping git hooks with --no-verify is blocked. Run the command so the hooks run.";
const hooksPath = "Skipping git hooks with core.hooksPath is blocked. Run the command so the hooks run.";
const configKey = (key: string) =>
  `Setting ${key} changes what a later git push or commit does without the guard seeing it. Leave it as it is.`;
const prMerge =
  "Pull request merging is blocked (gh pr merge, gt merge, gh api .../pulls/N/merge). Do not merge the pull request.";
const toMain = "A push to main or master is blocked. Push the pull request branch instead.";
const headless = "A headless run stages its changes and leaves commit and push to the person.";
const headlessRelease = "A headless run does not tag or release. Leave the release to the person.";
const autopilotRelease = "Autopilot does not tag or release. Leave the release to the person.";
const readOnly = "This role is read-only. Do not edit files or change the git tree.";
const readOnlyTool = "This role is read-only. Do not edit or write files.";
const unknownBranch = "Could not read the current branch, so this push is blocked. Push the branch by name.";
const trustCommand =
  "Trusting a repo's policy is the person's call. Ask them to run bercail policy trust in their own shell.";
const protectedFile = "This file decides what bercail's guard lets through. Ask the person to edit it.";
const pushAllEntire =
  "In an Entire repo, pushing every branch (--all, --branches, a refs/heads/* glob) would also push Entire's shadow branches, which hold unredacted snapshots. Push the branch by name.";
const entireMerge = "Approving or merging an Entire trail is the person's call. Do not approve or merge it.";
const entireDismiss = "Dismissing a trail finding can clear a merge gate; only the person does that.";
const entirePerson =
  "This entire command changes Entire's setup, hooks, login, or repositories. Suggest it to the person; do not run it.";
const entireDestroy =
  "This entire command amends a commit, resets git state, or deletes checkpoints. Ask the person to run it.";
const entireUnknown = "A headless run only uses entire commands bercail knows. Leave this one to the person.";

const allow: GuardDecision = { action: "allow" };
const block = (reason: string): GuardDecision => ({ action: "block", reason });
const approve = (reason: string): GuardDecision => ({ action: "allow", approved: [reason] });

function readOnlyRole(role: string): boolean {
  return role === "judge" || role === "council";
}

function isMainRef(ref: string): boolean {
  const bare = ref.replace(/^\+/, "").replace(/^refs\/heads\//, "");
  return bare === "main" || bare === "master";
}

function refDest(spec: string): string {
  const bare = spec.replace(/^\+/, "");
  const colon = bare.lastIndexOf(":");
  return colon >= 0 ? bare.slice(colon + 1) : bare;
}

// Config that changes what a later push or commit does: its refspecs, mirroring,
// hooks, aliases, and included files.
const riskyConfig = /^(remote\..+\.(push|mirror)|push\..+|core\.hookspath|alias\..+|include\..+|includeif\..+)$/i;

function configBlock(key: string): GuardDecision {
  return block(/^core\.hookspath$/i.test(key) ? hooksPath : configKey(key));
}

// A tag by its ref, or by a version-shaped name such as v1.2.3.
const versionTag = /^v?\d+(\.\d+)+([-+.][0-9A-Za-z.-]*)?$/;

function isTagRef(ref: string): boolean {
  const bare = ref.replace(/^\+/, "");
  return bare.startsWith("refs/tags/") || versionTag.test(bare);
}

function specIsTag(spec: string): boolean {
  const bare = spec.replace(/^\+/, "");
  const colon = bare.lastIndexOf(":");
  return isTagRef(colon >= 0 ? bare.slice(0, colon) : bare) || isTagRef(refDest(bare));
}

function readBalanced(text: string, open: number): { body: string; end: number } | undefined {
  let depth = 1;
  let i = open + 1;
  let quote: "'" | '"' | null = null;
  while (i < text.length) {
    const c = text[i];
    if (quote) {
      if (c === "\\" && quote === '"' && i + 1 < text.length) {
        i += 2;
        continue;
      }
      if (c === quote) quote = null;
      i++;
      continue;
    }
    if (c === "'" || c === '"') {
      quote = c;
      i++;
      continue;
    }
    if (c === "(") depth++;
    if (c === ")") {
      depth--;
      if (depth === 0) return { body: text.slice(open + 1, i), end: i + 1 };
    }
    i++;
  }
  return undefined;
}

// $(...) and `...` inside an unquoted heredoc body still run.
function subsIn(text: string): string[] {
  const subs: string[] = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "$" && text[i + 1] === "(") {
      const inner = readBalanced(text, i + 1);
      if (inner) {
        subs.push(inner.body);
        i = inner.end - 1;
      }
    } else if (text[i] === "`") {
      const end = text.indexOf("`", i + 1);
      if (end > i) {
        subs.push(text.slice(i + 1, end));
        i = end;
      }
    }
  }
  return subs;
}

// $(mktemp -d ...) and nothing else, not a dry run: it prints a new, empty directory.
function makesTempDir(body: string): boolean {
  const words = body.trim().split(/\s+/);
  return (
    words[0] === "mktemp" &&
    words.every((word) => /^[\w./%+=-]+$/.test(word) && word !== "--dry-run" && !/^-[^-]*u/.test(word)) &&
    words.some((word) => word === "--directory" || /^-[qt]*d[qt]*p?$/.test(word))
  );
}

// A mktemp -d dir stands in a word as a path no real dir can have (it holds a NUL),
// so the guard never looks it up and .. out of it lands nowhere it knows.
const tempPrefix = "/\0mktemp";

function tempRoot(path: string | undefined): string | undefined {
  return path?.startsWith(tempPrefix) ? path.split("/").slice(0, 2).join("/") : undefined;
}

// Where TARGET is from BASE, or undefined when the guard cannot tell.
function placeIn(base: string | undefined, target: string): string | undefined {
  if (/[$`]/.test(target)) return undefined;
  const full = isAbsolute(target) ? target : base === undefined ? undefined : `${base}/${target}`;
  if (full === undefined) return undefined;
  const root = tempRoot(full);
  const out = resolve(full);
  if (root && out !== root && !out.startsWith(`${root}/`)) return undefined;
  return out;
}

// Stands in a word for a $ the shell leaves as it is (single quotes, a backslash),
// so only a live $NAME is read as a mktemp -d dir.
const literalDollar = "\u0001";
const literal = (text: string) => text.replaceAll("$", literalDollar);

// A shell word, an operator that ends a command, or a command substitution's body.
type Token = { kind: "op"; op: string } | { kind: "word"; value: string } | { kind: "sub"; value: string };

// tag keeps the mktemp -d dirs of nested commands apart.
function tokenize(command: string, tag = ""): Token[] {
  const tokens: Token[] = [];
  let temps = 0;
  const tempDir = () => `${tempPrefix}${tag}.${temps++}`;
  // Heredocs opened on the current line; their bodies start after its newline.
  const heredocs: { delim: string; strip: boolean; quoted: boolean }[] = [];
  let i = 0;
  while (i < command.length) {
    const c = command[i];
    if (c === " " || c === "\t") {
      i++;
      continue;
    }
    if (c === "<" && command[i + 1] === "<" && command[i + 2] !== "<") {
      let j = i + 2;
      const strip = command[j] === "-";
      if (strip) j++;
      while (command[j] === " " || command[j] === "\t") j++;
      let delim = "";
      let quoted = false;
      while (j < command.length && !" \t\n;|&<>()".includes(command[j])) {
        const ch = command[j];
        if (ch === "'" || ch === '"') {
          quoted = true;
          const end = command.indexOf(ch, j + 1);
          if (end < 0) {
            j = command.length;
            break;
          }
          delim += command.slice(j + 1, end);
          j = end + 1;
          continue;
        }
        if (ch === "\\") {
          quoted = true;
          delim += command[j + 1] ?? "";
          j += 2;
          continue;
        }
        delim += ch;
        j++;
      }
      if (delim) {
        heredocs.push({ delim, strip, quoted });
        i = j;
        continue;
      }
    }
    if (c === "\n" && heredocs.length) {
      tokens.push({ kind: "op", op: "\n" });
      i++;
      for (const doc of heredocs.splice(0)) {
        while (i < command.length) {
          let end = command.indexOf("\n", i);
          if (end < 0) end = command.length;
          const line = command.slice(i, end);
          i = end + 1;
          if ((doc.strip ? line.replace(/^\t+/, "") : line) === doc.delim) break;
          if (!doc.quoted) for (const sub of subsIn(line)) tokens.push({ kind: "sub", value: sub });
        }
      }
      continue;
    }
    if (c === "\n" || c === ";" || c === "|" || c === "&") {
      const double = (c === "|" && command[i + 1] === "|") || (c === "&" && command[i + 1] === "&");
      tokens.push({ kind: "op", op: double ? c + c : c });
      i += double ? 2 : 1;
      continue;
    }
    if (c === "$" && command[i + 1] === "(") {
      const inner = readBalanced(command, i + 1);
      if (inner && !makesTempDir(inner.body)) {
        tokens.push({ kind: "sub", value: inner.body });
        i = inner.end;
        continue;
      }
    }
    if (c === "`") {
      const end = command.indexOf("`", i + 1);
      if (end > i && !makesTempDir(command.slice(i + 1, end))) {
        tokens.push({ kind: "sub", value: command.slice(i + 1, end) });
        i = end + 1;
        continue;
      }
    }
    let word = "";
    while (i < command.length) {
      const ch = command[i];
      if (" \t\n;|&".includes(ch)) break;
      if (ch === "$" && command[i + 1] === "(") {
        const inner = readBalanced(command, i + 1);
        if (!inner || !makesTempDir(inner.body)) break;
        word += tempDir();
        i = inner.end;
        continue;
      }
      if (ch === "`") {
        const end = command.indexOf("`", i + 1);
        if (end < 0 || !makesTempDir(command.slice(i + 1, end))) break;
        word += tempDir();
        i = end + 1;
        continue;
      }
      if (ch === "'") {
        const end = command.indexOf("'", i + 1);
        if (end < 0) {
          word += literal(command.slice(i + 1));
          i = command.length;
          break;
        }
        word += literal(command.slice(i + 1, end));
        i = end + 1;
        continue;
      }
      if (ch === '"') {
        i++;
        while (i < command.length && command[i] !== '"') {
          if (command[i] === "\\" && i + 1 < command.length) {
            word += literal(command[i + 1]);
            i += 2;
            continue;
          }
          if (command[i] === "$" && command[i + 1] === "(") {
            const inner = readBalanced(command, i + 1);
            if (inner) {
              if (makesTempDir(inner.body)) word += tempDir();
              else tokens.push({ kind: "sub", value: inner.body });
              i = inner.end;
              continue;
            }
          }
          if (command[i] === "`") {
            const end = command.indexOf("`", i + 1);
            if (end > i) {
              const body = command.slice(i + 1, end);
              if (makesTempDir(body)) word += tempDir();
              else tokens.push({ kind: "sub", value: body });
              i = end + 1;
              continue;
            }
          }
          word += command[i];
          i++;
        }
        if (command[i] === '"') i++;
        continue;
      }
      if (ch === "\\") {
        if (i + 1 < command.length) word += literal(command[i + 1]);
        i += 2;
        continue;
      }
      word += ch;
      i++;
    }
    if (word) tokens.push({ kind: "word", value: word });
  }
  return tokens;
}

// One simple command, with the operators before and after it ("" at either end).
// marked keeps literalDollar where words has the $ back.
type Segment = { words: string[]; marked: string[]; subs: string[]; before: string; after: string };

function segmentsOf(command: string, tag = ""): Segment[] {
  const out: Segment[] = [];
  let words: string[] = [];
  let subs: string[] = [];
  let before = "";
  const flush = (op: string) => {
    if (words.length || subs.length) {
      const plain = words.map((word) => word.replaceAll(literalDollar, "$"));
      out.push({ words: plain, marked: words, subs, before, after: op });
    }
    words = [];
    subs = [];
    before = op;
  };
  for (const token of tokenize(command, tag)) {
    if (token.kind === "op") flush(token.op);
    else if (token.kind === "sub") subs.push(token.value);
    else words.push(token.value);
  }
  flush("");
  return out;
}

const assign = /^[A-Za-z_][A-Za-z0-9_]*=/;

function skipEnv(words: string[], i: number): number {
  i++;
  while (i < words.length) {
    const word = words[i];
    if (word === "--") return i + 1;
    if (assign.test(word)) {
      i++;
      continue;
    }
    if (!word.startsWith("-")) break;
    const name = word.split("=")[0];
    i++;
    if (!word.includes("=") && ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"].includes(name)) i++;
  }
  return i;
}

function skipSudo(words: string[], i: number): number {
  i++;
  while (i < words.length) {
    const word = words[i];
    if (assign.test(word)) {
      i++;
      continue;
    }
    if (!word.startsWith("-") || word === "-") break;
    const name = word.split("=")[0];
    i++;
    if (
      !word.includes("=") &&
      ["-u", "-g", "-h", "-p", "-C", "-D", "-T", "-R", "--user", "--group", "--host"].includes(name)
    )
      i++;
  }
  return i;
}

const shellPrefixes = new Set(["if", "then", "else", "elif", "while", "until", "do", "{", "!", "time"]);
const wrappers: Record<string, string[]> = {
  exec: ["-a"],
  nohup: [],
  setsid: [],
  nice: ["-n", "--adjustment"],
  timeout: ["-k", "--kill-after", "-s", "--signal"],
  xargs: [
    "-a",
    "--arg-file",
    "-d",
    "--delimiter",
    "-E",
    "-I",
    "-L",
    "-n",
    "--max-args",
    "-P",
    "--max-procs",
    "-s",
    "--max-chars",
  ],
};

function commandWords(words: string[]): string[] {
  let i = 0;
  while (i < words.length) {
    const word = words[i];
    if (assign.test(word)) {
      i++;
      continue;
    }
    if (shellPrefixes.has(word)) {
      i++;
      if (word === "time" && words[i] === "-p") i++;
      continue;
    }
    const name = basename(word);
    if (Object.hasOwn(wrappers, name)) {
      i++;
      while (i < words.length && words[i].startsWith("-")) {
        const option = words[i++];
        if (option === "--") break;
        if (wrappers[name].includes(option)) i++;
      }
      if (name === "timeout") i++; // The duration precedes the command.
      continue;
    }
    if (name === "command") {
      i++;
      if (words[i] === "-p" || words[i] === "--") i++;
      continue;
    }
    if (name === "env") {
      i = skipEnv(words, i);
      continue;
    }
    if (name === "sudo") {
      i = skipSudo(words, i);
      continue;
    }
    break;
  }
  return words.slice(i);
}

const gitValue = new Set([
  "-C",
  "-c",
  "--git-dir",
  "--work-tree",
  "--namespace",
  "--super-prefix",
  "--config-env",
  "--exec-path",
  "--shallow-file",
]);

type GitCall = { sub: string; args: string[]; dir: string | undefined; config: string[] };

// dir is undefined when --git-dir or --work-tree point git somewhere the guard cannot place.
function parseGit(words: string[], cwd: string | undefined): GitCall | undefined {
  if (words[0] !== "git") return undefined;
  let i = 1;
  let dir = cwd;
  const config: string[] = [];
  while (i < words.length && words[i].startsWith("-")) {
    const word = words[i];
    if (word === "--") {
      i++;
      break;
    }
    const eq = word.indexOf("=");
    const name = eq > 0 ? word.slice(0, eq) : word;
    const value = eq > 0 ? word.slice(eq + 1) : words[i + 1];
    if (name === "-C") {
      if (eq < 0) i++;
      if (value) dir = placeIn(dir, value);
      i++;
      continue;
    }
    if (name === "--git-dir" || name === "--work-tree") dir = undefined;
    if (name === "-c" || name === "--config-env") config.push((value ?? "").split("=")[0]);
    if (gitValue.has(name) && eq < 0) i++;
    i++;
  }
  return { sub: words[i] ?? "", args: words.slice(i + 1), dir, config };
}

function shortCluster(word: string): string | undefined {
  if (!/^-[^-]/.test(word)) return undefined;
  return word.slice(1);
}

function hasNoVerify(sub: string, args: string[]): boolean {
  return args.some((arg) => {
    if (arg === "--no-verify" || arg.startsWith("--no-verify=")) return true;
    if (sub !== "commit") return false;
    if (arg === "-n") return true;
    const cluster = shortCluster(arg);
    return cluster !== undefined && cluster.includes("n");
  });
}

type PushFacts = {
  force: boolean;
  mirror: boolean;
  deleteMain: boolean;
  plus: boolean;
  refspecs: string[];
  deleted: string[];
  tags: boolean;
  /** --all, --branches, or a glob refspec: main may be among what it pushes. */
  every: boolean;
};

function pushFacts(args: string[]): PushFacts {
  let forceFlag = false;
  let mirrorFlag = false;
  let deleting = false;
  let deleteMainFlag = false;
  let plus = false;
  let tags = false;
  let every = false;
  const deleted: string[] = [];
  const positionals: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--") {
      positionals.push(...args.slice(i + 1));
      break;
    }
    if (deleting && !arg.startsWith("-")) {
      if (isMainRef(arg)) deleteMainFlag = true;
      deleted.push(arg);
      deleting = false;
      continue;
    }
    if (arg.startsWith("-")) {
      if (arg === "--force" || arg === "-f" || arg.startsWith("--force")) forceFlag = true;
      if (arg === "--mirror") mirrorFlag = true;
      if (arg === "--tags" || arg === "--follow-tags") tags = true;
      if (arg === "--all" || arg === "--branches") every = true;
      if (arg === "--delete" || arg === "-d") deleting = true;
      if (arg.startsWith("--delete=")) {
        const ref = arg.slice("--delete=".length);
        if (isMainRef(ref)) deleteMainFlag = true;
        deleted.push(ref);
      }
      const cluster = shortCluster(arg);
      if (cluster?.includes("f")) forceFlag = true;
      if (cluster?.includes("d")) deleting = true;
      if (arg === "-o" || arg === "--push-option" || arg === "--repo" || arg === "--receive-pack" || arg === "--exec")
        i++;
      continue;
    }
    positionals.push(arg);
  }
  const first = positionals[0];
  const firstIsRef =
    first !== undefined &&
    (first.includes(":") || first.startsWith("+") || first.startsWith("refs/") || first === "HEAD" || isMainRef(first));
  const refspecs = first === undefined ? [] : firstIsRef ? positionals : positionals.slice(1);
  for (const spec of refspecs) {
    if (spec.startsWith("+")) plus = true;
    if (spec.includes("*")) every = true;
    // :<ref> pushes nothing to <ref>: a delete.
    const bare = spec.replace(/^\+/, "");
    if (bare.startsWith(":")) {
      deleted.push(bare.slice(1));
      if (isMainRef(bare.slice(1))) deleteMainFlag = true;
    }
  }
  return { force: forceFlag, mirror: mirrorFlag, deleteMain: deleteMainFlag, plus, refspecs, deleted, tags, every };
}

function shellScript(words: string[]): string | undefined {
  const cmd = words[0];
  if (cmd !== "bash" && cmd !== "sh" && cmd !== "dash" && cmd !== "eval") return undefined;
  if (cmd === "eval") return words[1];
  for (let i = 1; i < words.length; i++) {
    const word = words[i];
    if (word === "-c" || word === "--command") return words[i + 1];
    const cluster = shortCluster(word);
    if (cluster?.includes("c")) return words[i + 1];
    if (!word.startsWith("-")) break;
  }
  return undefined;
}

function plainWords(words: string[]): string[] {
  return words.filter((word) => !word.startsWith("-"));
}

// Strip repo selectors for command recognition, but never lend them cwd's trust.
function forgeCall(words: string[], cwd: string | undefined): { words: string[]; dir: string | undefined } {
  const selectors = ["-R", "--repo", "--hostname", "--host", "-C", "--cwd", "--directory"];
  const out: string[] = [];
  let dir = cwd;
  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    if (selectors.includes(word.split("=")[0])) {
      dir = undefined;
      if (!word.includes("=")) i++;
    } else if (/^-R.+/.test(word)) {
      dir = undefined;
    } else out.push(word);
  }
  return { words: out, dir };
}

function isForgeMerge(words: string[]): boolean {
  const plain = plainWords(words);
  return (
    (words[0] === "gt" && plain[1] === "merge") ||
    (words[0] === "gh" && plain[1] === "pr" && plain[2] === "merge") ||
    (words[0] === "gh" &&
      plain[1] === "api" &&
      ghApiWrites(words) &&
      words.some((word) => /\/pulls\/\d+\/merge(?:$|\?)/.test(word)))
  );
}

function forgePublish(words: string[]): "commit" | "push" | undefined {
  const plain = plainWords(words);
  if (words[0] === "gt") {
    if (["create", "modify"].includes(plain[1])) return "commit";
    if (plain[1] === "submit") return "push";
  }
  if (["gh", "origin"].includes(words[0])) {
    if (plain[1] === "pr" && plain[2] === "create") return "push";
    if (plain[1] === "stack" && plain[2] === (words[0] === "gh" ? "submit" : "push")) return "push";
  }
  return undefined;
}

// What an entire command does: a read, a publish like gh pr create, a trail
// write like gh pr edit, or one that is the person's (bercail-znd's classes,
// starting from `entire agent-help`).
type EntireKind = "read" | "push" | "write" | "ask" | "dismiss" | "merge" | "person" | "destroy";

// entire's flags that take a value, so the value is not read as a subcommand.
const entireValueFlags = new Set(
  [
    "--context --project --repo --branch --base --body --title --type --status --priority --assignee",
    "--add-assignee --remove-assignee --branch-action --idempotency-key --trail --severity --cursor",
    "--limit -n --freshness --message -m --session --commit --checkpoint -c --line --from --cluster",
    "--agent --model",
  ]
    .join(" ")
    .split(" "),
);

function entirePath(words: string[]): string[] {
  const path: string[] = [];
  for (let i = 1; i < words.length && words[i] !== "--"; i++) {
    if (!words[i].startsWith("-")) path.push(words[i]);
    else if (entireValueFlags.has(words[i])) i++;
  }
  return path;
}

// No --help or --dry-run shortcut: a string flag takes the next word as its
// value, so `trail approve 3 -m --help` is a real approval.
const entireAliases: Record<string, string> = { cp: "checkpoint", checkpoints: "checkpoint", sessions: "session" };

function entireKind(words: string[]): EntireKind | undefined {
  if (words[0] !== "entire") return undefined;
  const path = entirePath(words);
  const [cmd, sub, third] = [entireAliases[path[0]] ?? path[0], path[1], path[2]];
  const flag = (...names: string[]) => words.some((w) => names.some((n) => w === n || w.startsWith(`${n}=`)));
  const among = (word: string | undefined, list: string) => word === undefined || list.split(" ").includes(word);
  if (cmd === undefined || among(cmd, "status why blame search activity labs recap version agent-help help"))
    return "read";
  if (cmd === "auth" && sub === "status") return "read";
  if (among(cmd, "enable disable configure clean login logout auth cluster org project service-account plugin"))
    return "person";
  if (cmd === "agent") return sub === "list" ? "read" : "person";
  if (cmd === "repo")
    return sub === "view" || sub === "list" || (sub === "mirror" && third === "list") ? "read" : "person";
  if (cmd === "checkpoint") {
    if (among(sub, "list search tokens") || (sub === "explain" && !flag("--generate"))) return "read";
    return sub === "push" ? "push" : sub === "delete" ? "destroy" : "ask";
  }
  if (cmd === "session") {
    if (among(sub, "list info current tokens")) return "read";
    const force = flag("--force") || words.some((w) => shortCluster(w)?.split("=")[0].includes("f"));
    return among(sub, "attach resume") && force ? "destroy" : "ask";
  }
  if (cmd === "trail") {
    // Anywhere in the path: a value flag bercail does not know must not hide them.
    if (path.includes("merge") || path.includes("approve")) return "merge";
    if (path.includes("finding") && path.includes("dismiss")) return "dismiss";
    if (among(sub, "approvals list sessions show stack timeline watch")) return "read";
    if (among(sub, "create link ci-pr update-branch")) return "push";
    if (sub === "finding") return among(third, "list show") ? "read" : third === "dismiss" ? "dismiss" : "write";
    if (among(sub, "update ready retarget comment rerun-review unlink attachment")) return "write";
  }
  return "ask";
}

function decideEntire(kind: EntireKind, dir: string | undefined, input: GuardInput): GuardDecision {
  if (kind === "read") return allow;
  if (kind === "merge") return block(entireMerge);
  if (kind === "person") return block(entirePerson);
  if (kind === "destroy") return block(entireDestroy);
  if (readOnlyRole(input.role)) return block(readOnly);
  if (kind === "push") return decidePush([], dir, input);
  if (kind === "write") return allow;
  if (kind === "dismiss") {
    if (input.role === "autopilot" || !input.hasUI) return block(entireDismiss);
    return { action: "ask", reason: "Dismiss this trail finding? It can clear a merge gate." };
  }
  if (!input.hasUI) return block(entireUnknown);
  return { action: "ask", reason: "Allow this entire command? bercail does not know it to be read-only." };
}

function isGhRelease(words: string[]): boolean {
  if (words[0] !== "gh") return false;
  const plain = plainWords(words);
  return plain[1] === "release" && ["create", "edit", "delete", "upload", "delete-asset"].includes(plain[2]);
}

// With fields and no method, gh api posts. An explicit GET still only reads.
function ghApiWrites(words: string[]): boolean {
  let method: string | undefined;
  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    if (word === "-X" || word === "--method") method = words[++i];
    else if (word.startsWith("--method=")) method = word.slice(9);
    else if (/^-X.+/.test(word)) method = word.slice(2);
    else if (
      [
        "-f",
        "-F",
        "--field",
        "--raw-field",
        "--input",
        "-H",
        "--header",
        "-q",
        "--jq",
        "-t",
        "--template",
        "-p",
        "--preview",
        "--cache",
      ].includes(word)
    )
      i++;
  }
  if (method) return !["GET", "HEAD", "OPTIONS"].includes(method.toUpperCase());
  return words.some(
    (word) => ["-f", "-F", "--field", "--raw-field", "--input"].includes(word.split("=")[0]) || /^-[fF].+/.test(word),
  );
}

function isGhApiRelease(words: string[]): boolean {
  return (
    words[0] === "gh" &&
    plainWords(words)[1] === "api" &&
    ghApiWrites(words) &&
    words.some((word) => /(^|\/)(releases|git\/refs\/tags|git\/tags)(\/|$|\?)/.test(word))
  );
}

function isPolicyTrust(words: string[]): boolean {
  const plain = plainWords(words);
  return plain.some((word, i) => word === "policy" && plain[i + 1] === "trust");
}

// A shell write to a file that decides the guard's answers: a redirect, or a
// command that writes files, naming it. A seatbelt, not a sandbox.
const fileWriters = new Set([
  "tee",
  "cp",
  "mv",
  "rm",
  "ln",
  "install",
  "truncate",
  "sed",
  "perl",
  "dd",
  "chmod",
  "touch",
]);

function writesProtected(words: string[], raw: string[], files: string[] | undefined): boolean {
  if (!files?.length) return false;
  const tails = files.map((file) => file.split("/").slice(-2).join("/"));
  if (!raw.some((word) => tails.some((tail) => word.includes(tail)))) return false;
  return fileWriters.has(words[0]) || raw.some((word) => /^\d*>|^&>/.test(word));
}

// git commands that leave HEAD on its branch. Anything else, an alias included,
// may move it.
const keepsBranch = new Set([
  "status",
  "diff",
  "log",
  "show",
  "add",
  "commit",
  "push",
  "fetch",
  "pull",
  "merge",
  "cherry-pick",
  "revert",
  "stash",
  "tag",
  "config",
  "remote",
  "rev-parse",
  "ls-files",
  "ls-remote",
  "blame",
  "grep",
  "describe",
  "shortlog",
  "restore",
  "rm",
  "mv",
  "notes",
  "format-patch",
  "apply",
  "am",
  "clean",
  "gc",
  "fsck",
  "for-each-ref",
  "show-ref",
  "cat-file",
  "rev-list",
  "reflog",
  "help",
  "version",
  "var",
  "count-objects",
  "",
]);

function movesBranch(git: GitCall): boolean {
  if (git.sub === "branch") return git.args.some((arg) => ["-m", "-M", "--move"].includes(arg));
  return !keepsBranch.has(git.sub);
}

// GIT_* variables that point git at another repo or index, and at other config.
const gitPlace = /^GIT_(DIR|WORK_TREE|INDEX_FILE|COMMON_DIR|OBJECT_DIRECTORY|NAMESPACE)(=|$)/;
const gitConfigVar = /^GIT_CONFIG\w*(=|$)/;

// Config keys set through GIT_CONFIG_KEY_<n> or GIT_CONFIG_PARAMETERS.
function envConfigKeys(word: string): string[] {
  const key = /^GIT_CONFIG_KEY_\d+=(.*)$/s.exec(word);
  if (key) return [key[1]];
  const params = /^GIT_CONFIG_PARAMETERS=(.*)$/s.exec(word);
  if (!params) return [];
  return params[1]
    .split(/\s+/)
    .map((part) => part.replace(/['"]/g, "").split("=")[0])
    .filter(Boolean);
}

// git tag with a name creates or deletes a tag; -l, -v, and no name only read.
const tagListValue = new Set([
  "--contains",
  "--no-contains",
  "--points-at",
  "--merged",
  "--no-merged",
  "--sort",
  "--format",
  "--color",
  "--column",
]);

function tagWrites(args: string[]): boolean {
  let names = 0;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const name = arg.split("=")[0];
    if (["--delete", "--annotate", "--sign", "--local-user", "--force", "--message", "--file", "--edit"].includes(name))
      return true;
    if (arg === "--list" || arg === "--verify") return false;
    const cluster = shortCluster(arg);
    if (cluster !== undefined) {
      if (/^n\d*$/.test(cluster)) continue;
      if (cluster.includes("l") || cluster.includes("v")) return false;
      if (/[adsufmFe]/.test(cluster)) return true;
      continue;
    }
    if (arg.startsWith("--")) {
      if (tagListValue.has(arg)) i++;
      continue;
    }
    names++;
  }
  return names > 0;
}

// The risky key a git config command writes, if any. Reads are fine.
function configWrite(args: string[]): string | undefined {
  const reads = ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "get", "list"];
  if (args.some((arg) => reads.includes(arg))) return undefined;
  return args.find((arg) => !arg.startsWith("-") && riskyConfig.test(arg));
}

function gitWrite(sub: string, args: string[]): boolean {
  if (["add", "commit", "push", "restore", "clean", "rm", "mv", "merge", "rebase"].includes(sub)) return true;
  if (sub === "reset" && args.some((arg) => arg === "--hard" || arg.startsWith("--hard"))) return true;
  if (
    sub === "checkout" &&
    (args.includes("--") || args.includes(".") || args.some((arg) => arg === "-f" || arg === "--force"))
  )
    return true;
  return false;
}

function publish(kind: "commit" | "push" | "release", input: GuardInput): GuardDecision {
  if (input.hasUI) {
    if (kind === "release")
      return { action: "ask", reason: "Allow this tag or release? This repo's policy leaves releases to the person." };
    return { action: "ask", reason: `Allow this git ${kind}? No leaves the changes staged for the person.` };
  }
  return block(kind === "release" ? headlessRelease : headless);
}

// The policy for a git dir: need-policy until the wrapper has looked it up. A dir
// the guard cannot place gets the default, which loosens nothing.
function policyFor(dir: string | undefined, input: GuardInput): Policy | GuardDecision {
  if (dir === undefined || tempRoot(dir)) return defaultPolicy;
  return input.policies?.[dir] ?? { action: "need-policy", dir };
}

function isPolicy(value: Policy | GuardDecision): value is Policy {
  return !("action" in value);
}

function because(policy: Policy, key: string, value: string): string {
  return `${policy.repo}: ${key} = ${value} (${policy.from[key] ?? "repo"})`;
}

// "" in dests is the current branch.
function branchOf(dir: string | undefined, input: GuardInput): string | GuardDecision {
  if (dir === undefined || tempRoot(dir) || input.branchMoved) return "";
  return input.branches?.[dir] ?? { action: "need-branch", dir };
}

function decideRelease(dir: string | undefined, input: GuardInput): GuardDecision {
  if (readOnlyRole(input.role)) return block(readOnly);
  const policy = policyFor(dir, input);
  if (!isPolicy(policy)) return policy;
  if (policy.agentMayRelease) return approve(because(policy, "agent_may_release", "true"));
  if (input.role === "autopilot") return block(autopilotRelease);
  return publish("release", input);
}

function decidePush(args: string[], dir: string | undefined, input: GuardInput): GuardDecision {
  const facts = pushFacts(args);
  if (facts.force) return block(force);
  if (facts.plus) return block(plusRef);
  if (facts.mirror) return block(mirror);
  if (facts.deleteMain) return block(deleteMain);
  if (hasNoVerify("push", args)) return block(noVerify);
  if (readOnlyRole(input.role)) return block(readOnly);

  let decision: GuardDecision = allow;
  const release = facts.tags || facts.refspecs.some(specIsTag) || facts.deleted.some(isTagRef);
  if (release) decision = worse(decision, decideRelease(dir, input));
  const dests = [
    ...facts.refspecs.filter((spec) => !specIsTag(spec)).map((spec) => (refDest(spec) === "HEAD" ? "" : refDest(spec))),
    ...facts.deleted.filter((ref) => !isTagRef(ref)),
  ];
  // A bare push sends the current branch; a push of tags alone sends no branch.
  if (facts.refspecs.length === 0 && facts.deleted.length === 0 && !args.includes("--tags") && !facts.every)
    dests.push("");
  if (facts.every) dests.push("*");
  if (dests.length === 0 || decision.action === "block") return decision;
  const hitsMain = (dest: string) => dest.includes("*") || (dest !== "" && isMainRef(dest));

  if (input.role === "autopilot") {
    if (dests.some(hitsMain)) return block(toMain);
    if (dests.includes("")) {
      const branch = branchOf(dir, input);
      if (typeof branch !== "string") return branch;
      if (branch === "") return block(unknownBranch);
      if (isMainRef(branch)) return block(toMain);
    }
    return worse(decision, approve("autopilot pushes its pull request branch"));
  }

  const policy = policyFor(dir, input);
  if (!isPolicy(policy)) return policy;
  if (facts.every && policy.entire) return block(pushAllEntire);
  if (policy.push === "main") return worse(decision, approve(because(policy, "push", "main")));
  if (policy.push === "branch") {
    let toMainRef = dests.some(hitsMain);
    if (!toMainRef && dests.includes("")) {
      const branch = branchOf(dir, input);
      if (typeof branch !== "string") return branch;
      toMainRef = branch === "" || isMainRef(branch);
    }
    if (!toMainRef) return worse(decision, approve(because(policy, "push", "branch")));
  }
  return worse(decision, publish("push", input));
}

function decideCommit(dir: string | undefined, input: GuardInput): GuardDecision {
  if (readOnlyRole(input.role)) return block(readOnly);
  if (input.role === "autopilot") return approve("autopilot commits to its pull request branch");
  if (dir !== undefined && input.fresh?.has(dir))
    return approve("scratch repo: this command made it with git init under mktemp -d");
  const policy = policyFor(dir, input);
  if (!isPolicy(policy)) return policy;
  if (policy.commit === "allow") return approve(because(policy, "commit", "allow"));
  if (policy.scratch) return approve(`${policy.repo}: scratch repo (temp dir, no remote)`);
  return publish("commit", input);
}

function decideGit(git: GitCall, input: GuardInput): GuardDecision {
  const { sub, args } = git;
  if (hasNoVerify(sub, args) && ["commit", "push", "merge", "rebase"].includes(sub)) return block(noVerify);
  const risky = git.config.find((key) => riskyConfig.test(key)) ?? (sub === "config" ? configWrite(args) : undefined);
  if (risky) return configBlock(risky);
  if (sub === "push") return decidePush(args, git.dir, input);
  if (sub === "tag" && tagWrites(args)) return decideRelease(git.dir, input);
  if (readOnlyRole(input.role) && gitWrite(sub, args)) return block(readOnly);
  if (sub === "commit") return decideCommit(git.dir, input);
  return allow;
}

function worse(current: GuardDecision, next: GuardDecision): GuardDecision {
  if (next.action === "block" || current.action === "block") return next.action === "block" ? next : current;
  if (next.action === "need-branch" || next.action === "need-policy") return next;
  if (current.action === "need-branch" || current.action === "need-policy") return current;
  if (next.action === "ask") return next;
  if (current.action === "ask") return current;
  const approved = [...(current.approved ?? []), ...(next.approved ?? [])];
  return approved.length ? { action: "allow", approved } : allow;
}

// Where a cd or pushd leaves the shell, or undefined when the guard cannot tell.
function cdTarget(words: string[], cwd: string | undefined, home: string | undefined): string | undefined {
  const args = words.slice(1).filter((word) => !/^-[LPe@]+$/.test(word));
  let target = args[0] ?? home;
  if (target === undefined || target === "-" || /[$`*?]/.test(target)) return undefined;
  if (target === "~" || target.startsWith("~/")) {
    if (home === undefined) return undefined;
    target = home + target.slice(1);
  }
  if (target.startsWith("~")) return undefined;
  return placeIn(cwd, target);
}

// The dir git init makes a repo in, or undefined when the repo goes elsewhere.
const initValue = new Set(["-b", "--initial-branch", "--template", "--object-format", "--ref-format"]);

function initDir(git: GitCall): string | undefined {
  let target = ".";
  for (let i = 0; i < git.args.length; i++) {
    const arg = git.args[i];
    if (arg.split("=")[0] === "--separate-git-dir") return undefined;
    if (initValue.has(arg)) i++;
    else if (!arg.startsWith("-")) target = arg;
  }
  return placeIn(git.dir, target);
}

// NAME=value set once, outside a pipe, a subshell or a skipped branch, and only
// to a mktemp -d dir: what $NAME and \${NAME} mean in the rest of the command.
type TempVars = Map<string, { value: string; chained: boolean }>;

const declares = new Set(["export", "declare", "typeset", "readonly"]);

// Words that start code which may run in another order, more than once, or not at
// all: past one, the guard no longer knows a repo was made where it thinks.
const compound = new Set([
  "if",
  "then",
  "else",
  "elif",
  "fi",
  "while",
  "until",
  "do",
  "done",
  "for",
  "select",
  "case",
  "esac",
  "function",
  "{",
  "}",
  "!",
]);

function assignedOnce(command: string, name: string): boolean {
  return (command.match(new RegExp(`(?<![\\w$])(?<!\\$\\{)${name}(?!\\w)`, "g")) ?? []).length === 1;
}

function recordTemps(command: string, segment: Segment, words: string[], vars: TempVars): void {
  const plain = ["", ";", "\n", "&&"].includes(segment.before) && ["", ";", "\n", "&&"].includes(segment.after);
  const head = declares.has(words[0]) ? 1 : 0;
  const rest = words.slice(head);
  const pure = rest.every((word) => assign.test(word) || (head === 1 && word.startsWith("-")));
  for (const word of rest.filter((w) => assign.test(w))) {
    const name = word.slice(0, word.indexOf("="));
    const value = word.slice(name.length + 1);
    if (plain && pure && tempRoot(value) && !/[$`]/.test(value) && assignedOnce(command, name))
      vars.set(name, { value, chained: segment.before === "&&" });
    else vars.delete(name);
  }
}

function expandTemps(word: string, vars: TempVars): string {
  return word.replace(
    /\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))/g,
    (ref, braced?: string, bare?: string) => vars.get(braced ?? bare ?? "")?.value ?? ref,
  );
}

export function decideBash(command: string, input: GuardInput, depth = 0): GuardDecision {
  if (depth > 4) return block("This command is nested too deep to check. Split it into a simpler command.");
  let decision: GuardDecision = allow;
  let cwd = input.cwd;
  let gitEnv = input.gitEnv ?? false;
  let gitConfigEnv = input.gitConfigEnv ?? false;
  let branchMoved = input.branchMoved ?? false;
  const fresh = new Set(input.fresh);
  const chainedFresh = new Set<string>();
  let chainedCd = false;
  const vars: TempVars = new Map();
  let straight = true;
  for (const segment of segmentsOf(command, `${depth}`)) {
    // export GIT_DIR=... holds for the rest of the command, so it counts from here on.
    if (segment.words.some((word) => gitPlace.test(word))) gitEnv = true;
    if (segment.words.some((word) => gitConfigVar.test(word))) gitConfigEnv = true;
    const envKey = segment.words.flatMap(envConfigKeys).find((key) => riskyConfig.test(key));
    if (envKey) return configBlock(envKey);
    // What ran after && may not have run once that chain ends.
    if (segment.before !== "&&") {
      for (const [name, v] of vars) if (v.chained) vars.delete(name);
      for (const dir of chainedFresh) fresh.delete(dir);
      chainedFresh.clear();
      if (chainedCd) cwd = undefined;
      chainedCd = false;
    }
    const subshell = segment.words[0]?.startsWith("(") ?? false;
    const closes = segment.words.some((word) => word.endsWith(")"));
    // Past a branch, loop, function, subshell, || or pipe, no repo counts as made here.
    if (subshell || closes || compound.has(segment.words[0]) || ["||", "|", "&"].includes(segment.before)) {
      straight = false;
      fresh.clear();
      vars.clear();
    }
    const here = { ...input, cwd, gitEnv, gitConfigEnv, branchMoved, fresh };
    for (const sub of segment.subs) decision = worse(decision, decideBash(sub, here, depth + 1));
    // A ( subshell's cd ends at its ); from there on the guard cannot place the shell.
    const raw = segment.marked.map((word, i) =>
      expandTemps(i === 0 ? word.replace(/^\(+/, "") : word, vars).replaceAll(literalDollar, "$"),
    );
    if (straight) recordTemps(command, segment, raw, vars);
    const words = commandWords(raw);
    if (words.length === 0) continue;
    // /usr/bin/git is git.
    if (words[0].includes("/")) words[0] = basename(words[0]);
    // A cd in a pipe or in the background may run in a subshell: where the shell is, is unknown.
    const piped = segment.before === "|" || segment.after === "|" || segment.after === "&";
    if (words[0] === "cd" || words[0] === "pushd") cwd = piped ? undefined : cdTarget(words, cwd, input.home);
    else if (words[0] === "popd" || subshell) cwd = undefined;
    if (closes) cwd = undefined;
    // A cd after && may not have run once that chain ends.
    if (["cd", "pushd", "popd"].includes(words[0]) && segment.before === "&&") chainedCd = true;
    const script = shellScript(words);
    if (script) decision = worse(decision, decideBash(script, here, depth + 1));
    // What eval or source sets stays set, and the guard cannot see what that is.
    if (words[0] === "eval" || words[0] === "source" || words[0] === ".") {
      gitEnv = branchMoved = true;
      vars.clear();
    }
    const forge = forgeCall(words, gitEnv || gitConfigEnv ? undefined : here.cwd);
    if (isForgeMerge(forge.words)) return block(prMerge);
    const entire = entireKind(forge.words);
    if (entire) {
      decision = worse(decision, decideEntire(entire, forge.dir, here));
      const path = entirePath(forge.words);
      if (path.includes("checkout") || path.includes("resume") || forge.words.includes("--checkout"))
        branchMoved = true;
    }
    const publishing = forgePublish(forge.words);
    const forgePlain = plainWords(forge.words);
    const sync = words[0] === "gh" && forgePlain[1] === "repo" && forgePlain[2] === "sync";
    if ((publishing === "push" || sync) && words.some((word) => word === "-f" || word.startsWith("--force")))
      return block(force);
    if (publishing) {
      if (hasNoVerify("push", words)) return block(noVerify);
      decision = worse(
        decision,
        publishing === "commit" ? decideCommit(forge.dir, here) : decidePush([], forge.dir, here),
      );
    }
    if (sync && readOnlyRole(input.role)) decision = worse(decision, block(readOnly));
    if (isPolicyTrust(words)) decision = worse(decision, block(trustCommand));
    if (writesProtected(words, raw, input.protectedFiles)) decision = worse(decision, block(protectedFile));
    if (words[0] === "gt" || (words[0] === "gh" && forgePlain[1] === "pr" && forgePlain[2] === "checkout"))
      branchMoved = true;
    if (isGhRelease(forge.words) || isGhApiRelease(forge.words)) {
      decision = worse(decision, decideRelease(forge.dir, here));
    }
    const git = parseGit(words, here.cwd);
    if (git) {
      const made = git.sub === "init" && straight && !gitEnv ? initDir(git) : undefined;
      if (made && tempRoot(made)) {
        fresh.add(made);
        if (segment.before === "&&") chainedFresh.add(made);
      }
      // Other config cannot move a commit out of a repo this command just made.
      if (gitEnv || (gitConfigEnv && !(git.dir && fresh.has(git.dir)))) git.dir = undefined;
      decision = worse(decision, decideGit(git, here));
      if (movesBranch(git)) branchMoved = true;
    }
    if (decision.action === "block") return decision;
  }
  return decision;
}

export function decideTool(tool: string, command: string | undefined, input: GuardInput, path?: string): GuardDecision {
  if (tool === "edit" || tool === "write") {
    if (readOnlyRole(input.role)) return block(readOnlyTool);
    const full = path?.startsWith("~/") && input.home ? join(input.home, path.slice(2)) : path;
    if (full && input.cwd !== undefined && input.protectedFiles?.includes(resolve(input.cwd, full)))
      return block(protectedFile);
  }
  if (tool === "bash") return decideBash(command ?? "", input);
  return allow;
}

async function branchAt(pi: ExtensionAPI, dir: string, signal: AbortSignal | undefined): Promise<string> {
  try {
    const result = await pi.exec("git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], { timeout: 5000, signal });
    return result.code === 0 ? result.stdout.trim() : "";
  } catch {
    return "";
  }
}

type PolicyJson = {
  repo: string;
  scratch: boolean;
  /** Entire captures sessions in this checkout (git_backend_entire_capture). */
  entire?: boolean;
  prompt: string;
  policy: { commit: Policy["commit"]; push: Policy["push"]; agent_may_release: boolean };
  sources: Record<string, string>;
};

// bercail policy show --json, or undefined outside a git checkout or without bercail.
async function policyJson(
  pi: ExtensionAPI,
  dir: string,
  signal: AbortSignal | undefined,
): Promise<PolicyJson | undefined> {
  try {
    const result = await pi.exec(process.env.BERCAIL_BIN || "bercail", ["policy", "show", "--json", dir], {
      timeout: 10000,
      signal,
    });
    return result.code === 0 ? (JSON.parse(result.stdout) as PolicyJson) : undefined;
  } catch {
    return undefined;
  }
}

// What the guard enforces of bercail policy show --json. No JSON: the default.
export function policyFromJson(json: PolicyJson | undefined): Policy {
  if (!json) return defaultPolicy;
  return {
    commit: json.policy.commit === "allow" ? "allow" : "ask",
    push: json.policy.push === "main" || json.policy.push === "branch" ? json.policy.push : "ask",
    agentMayRelease: json.policy.agent_may_release === true,
    scratch: json.scratch === true,
    entire: json.entire === true,
    repo: json.repo,
    from: json.sources ?? {},
  };
}

// A review worktree (<repo>.review-<n>, from bercail review-pr) holds someone
// else's PR head, so its .pi/ extensions are the author's code.
export function isReviewWorktree(cwd: string): boolean {
  return cwd.split("/").some((part) => /\.review-\d+$/.test(part));
}

function stateDir(): string {
  return join(process.env.XDG_STATE_HOME || join(process.env.HOME ?? "", ".local/state"), "bercail");
}

// URL credentials never reach the log.
export function redact(command: string): string {
  const clean = command.replace(/([a-z][a-z0-9+.-]*:\/\/)[^/\s@]+@/gi, "$1***@");
  return clean.length > 500 ? `${clean.slice(0, 500)}…` : clean;
}

function logApproval(command: string, approved: string[], input: GuardInput): void {
  try {
    const file = join(stateDir(), "guard-approvals.jsonl");
    mkdirSync(dirname(file), { recursive: true });
    const entry = {
      at: new Date().toISOString(),
      terminal: process.env.HC_TERMINAL_ID ?? "",
      role: input.role || "lead",
      cwd: input.cwd,
      command: redact(command),
      approved,
    };
    appendFileSync(file, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
  } catch {
    // The log is for the person's audit; a full disk must not stop the agent.
  }
}

const policySection = "bercail_git_policy";

export default function (pi: ExtensionAPI) {
  const home = process.env.HOME;
  const protectedFiles = [
    join(stateDir(), "policy-trust.json"),
    process.env.BERCAIL_CONFIG ||
      join(process.env.XDG_CONFIG_HOME || join(home ?? "", ".config"), "bercail/config.toml"),
  ];

  // A PR head's .pi/ extensions never load, whatever trust.json says of the parent.
  pi.on("project_trust", async (event) => ({ trusted: isReviewWorktree(event.cwd) ? "no" : "undecided" }));

  // Each run starts with the policy of the repo this agent works in.
  pi.on("before_agent_start", async (event, ctx) => {
    const sections = event.systemPromptOptions?.sections;
    if (!sections) return;
    const json = await policyJson(pi, ctx.cwd, ctx.signal);
    if (json?.prompt) sections[policySection] = json.prompt;
    else delete sections[policySection];
  });

  pi.on("tool_call", async (event, ctx) => {
    const input = event.input as { command?: string; path?: string };
    const command = event.toolName === "bash" ? String(input.command ?? "") : undefined;
    let guardInput: GuardInput = {
      role: process.env.BERCAIL_ROLE ?? "",
      hasUI: ctx.hasUI,
      cwd: ctx.cwd,
      home,
      protectedFiles,
    };
    let decision = decideTool(event.toolName, command, guardInput, input.path);
    for (let i = 0; i < 8 && (decision.action === "need-branch" || decision.action === "need-policy"); i++) {
      if (decision.action === "need-branch") {
        guardInput = {
          ...guardInput,
          branches: { ...guardInput.branches, [decision.dir]: await branchAt(pi, decision.dir, ctx.signal) },
        };
      } else {
        guardInput = {
          ...guardInput,
          policies: {
            ...guardInput.policies,
            [decision.dir]: policyFromJson(await policyJson(pi, decision.dir, ctx.signal)),
          },
        };
      }
      decision = decideTool(event.toolName, command, guardInput, input.path);
    }
    if (decision.action === "allow") {
      if (decision.approved?.length) logApproval(command ?? "", decision.approved, guardInput);
      return;
    }
    if (decision.action === "need-branch" || decision.action === "need-policy") {
      return {
        block: true,
        reason: "This command touches too many repos to check. Split it into one command per repo.",
      };
    }
    if (decision.action === "ask") {
      if (ctx.hasUI && (await ctx.ui.confirm("Allow this git command?", decision.reason))) return;
      return { block: true, reason: ctx.hasUI ? "The person said no. Leave the changes staged." : headless };
    }
    return { block: true, reason: decision.reason };
  });
}
