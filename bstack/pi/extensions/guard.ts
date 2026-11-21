// bercail's Pi guard. The decision functions are pure; the default export wires
// tool_call and tool_result, the repo's git policy (bercail policy show), the
// approval log, and the log of warnings and refusals.
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  appendFileSync,
  linkSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** The part of a repo's effective policy (lib/policy.sh) the guard enforces. */
export type Policy = {
  push: "ask" | "branch" | "main";
  agentMayRelease: boolean;
  /** Entire captures sessions here (.entire/settings.json, enabled). */
  entire: boolean;
  /** For the log: the main checkout, and where each value came from. */
  repo: string;
  from: Record<string, string>;
};

export const defaultPolicy: Policy = {
  push: "ask",
  agentMayRelease: false,
  entire: false,
  repo: "",
  from: {},
};

export type GuardInput = {
  role: string;
  hasUI: boolean;
  /** undefined: after a cd the guard could not follow, or when the shell may be in more than one dir. */
  cwd: string | undefined;
  /** Within one command: each dir the shell may be in, as after A && cd X; undefined: one it lost. */
  cwds?: (string | undefined)[];
  /** Current branch per git dir. Missing: not looked up. "": lookup failed. */
  branches?: Record<string, string>;
  /** Effective policy per git dir. Missing: not looked up. */
  policies?: Record<string, Policy>;
  /** Graphite alias names from its config file. Missing: unknown; []: no aliases. */
  graphiteAliases?: readonly string[];
  /** Files that decide what the guard lets through: the person edits them. */
  protectedFiles?: string[];
  /** Folders whose every file is protected, such as Shep's state. */
  protectedDirs?: string[];
  /** Todo targets and routes: only bercail todo target and route write them. */
  todoFiles?: string[];
  home?: string;
  /** Within one command: a GIT_* variable now points git somewhere the guard cannot place. */
  gitEnv?: boolean;
  /** Within one command: a GIT_CONFIG* variable now points git at other config. */
  gitConfigEnv?: boolean;
  /** What entire agent-help lists as read-only: top-level names under "", subcommands under their command. */
  entireHelp?: Record<string, readonly string[]>;
  /** Within one command: an earlier part may have switched the branch. */
  branchMoved?: boolean;
  /** Where a read-only role's write tool may write: the temp dirs, and new files under ROOT/.bercail/. */
  readOnlyWrites?: { tmp: string[]; root: string; exists: (path: string) => boolean };
  /** The agent's own TMPDIR, when it is not /tmp: a write under a literal /tmp then warns. */
  tmpdir?: string;
  /** The whole command is this one plain command: no other part, substitution or quoting. */
  sole?: boolean;
  /** The only tool call its assistant message made, so no other call of the session runs beside it. */
  alone?: boolean;
};

/** A git push a Decisions answer may approve: commit hashes to full refs, from dir. */
export type PushRequest = { dir: string; remote: string; refspecs: string[] };

// warnings: lines the command runs with, shown in its result and logged. push: an ask
// that the person's Decisions answer may approve instead (approvable).
export type GuardDecision =
  | { action: "allow"; approved?: string[]; warnings?: string[] }
  | { action: "block"; reason: string }
  | { action: "ask"; reason: string; warnings?: string[]; push?: PushRequest }
  | { action: "need-branch"; dir: string }
  | { action: "need-policy"; dir: string }
  | { action: "need-entire-help"; command: string };

const force = "Force-push is blocked. Push without --force, or ask the person.";
const autopilotForce =
  "Force-push is blocked: autopilot does not publish a rewritten branch, the person does. Stop and report the branch, the PR head you fetched before the restack, the new head, and the checks you ran (the autopilot skill's section 4).";
const forceFor = (input: GuardInput) => block(input.role === "autopilot" ? autopilotForce : force);
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
const headless = "A headless run stages its changes and leaves the push to the person.";
const deskCommit =
  "This commit ran, but desks stage their changes and leave them uncommitted: Shep or the person lands them. Review shows only uncommitted changes, so this commit hides the work from it. Say in your report that you committed.";
const shepCommit = "This commit ran. It stays local; a push still asks. Say in your report what you committed.";
const shepBgCommit =
  "Background Shep reads, runs checks and waits; it does not commit. Report what is ready, and Shep lands it from its own session.";
const headlessRelease = "A headless run does not tag or release. Leave the release to the person.";
const autopilotRelease = "Autopilot does not tag or release. Leave the release to the person.";
const readOnly = "This role is read-only. Do not edit files or change the git tree.";
const backgroundOnly =
  "A background Shep waits and reports: it does not commit, push, tag or edit files. Put the next step in your report on the issue; Shep runs it.";
const readOnlyTool =
  "This role is read-only. Do not edit files. Write only under /tmp or $TMPDIR, or a new file under the worktree's .bercail/ (not description.md, validate.json, handoff-result.json or policy.toml).";
const unknownBranch = "Could not read the current branch, so this push is blocked. Push the branch by name.";
const unknownBranchAsk =
  "Could not read the current branch. Allow this push? Say yes only if it is not main or master.";
const tooManyRepos = "This command touches too many repos to check. Split it into one command per repo.";
const tooManyReposAsk = "This command touches more repos than the guard checks. Allow it?";
const trustCommand =
  "Trusting a repo's policy is the person's call. Ask them to run bercail policy trust in their own shell.";
const protectedFile = "This file decides what bercail's guard lets through. Ask the person to edit it.";
const answerCommand =
  "Answering one of Shep's questions is the person's pick, on a Decisions card or in Discuss. Leave it to them.";
const syntheticInput =
  "Typing or clicking for the person (wtype, ydotool, xdotool, /dev/uinput, hyprctl's key dispatchers) is blocked: it could answer for them.";
const discussOnly =
  "A Discuss branch is for talking a question over: it runs no commands and changes nothing. Say what you would do instead.";
const pushAllEntire =
  "In an Entire repo, pushing every branch (--all, --branches, a refs/heads/* glob) would also push Entire's shadow branches, which hold unredacted snapshots. Push the branch by name.";
const entireMerge =
  "Approving or merging an Entire trail, or dismissing its findings, is the person's call. Do not do it.";
const shepMerge =
  "Shep merges a trail only as a plain entire trail merge [<trail>], when the person asks: no --force, which skips the trail's gates, and no flag before merge that bercail does not know.";
const entirePerson =
  "This entire command changes Entire's setup, hooks, login, or repositories. Suggest it to the person; do not run it.";
const entireDestroy =
  "This entire command amends a commit, resets git state, or deletes checkpoints. Ask the person to run it.";
const entireUnknown = "A headless run only uses entire commands bercail knows. Leave this one to the person.";
const shepTrail =
  "This wrote a trail on entire.com, which the person's team sees. Say in your report which trail you created or changed, with its URL.";
const trailAsk = "Create a trail on entire.com? The team sees it; it pushes no branch.";
const trailHeadless =
  "A headless run does not create trails on entire.com. Put the trail you need in your report, and Shep or the person creates it.";
const cleanupAsk =
  "Retire this worktree? bercail cleanup archives its .bercail/, ends its desk, removes the worktree and closes its space. The branch stays.";
const cleanupHeadless =
  "bercail cleanup removes a worktree, so it runs only where the person can say yes. Leave it to Shep or the person.";
const brainSetup =
  "This Brain or Graph command sets it up, syncs memories, runs background work, or runs a binary it names. Suggest it to the person; do not run it.";
const brainSpend =
  "This Brain command calls a model on the person's tokens (distill, recall --expand, remember without --path, refresh --agent). Leave it to the person.";
const brainSpendAsk = "This Brain command calls a model on your tokens. Allow it?";
const entireListed =
  "bercail does not know this entire command; it ran because entire agent-help lists it as read-only.";
const brainRemember =
  'A memory reaches every branch and desk at once. Propose it in your report as Memory: "<text>" --path <p>, and Shep records it once the person agrees.';
const emptySecret =
  'A command fed by op read, op inject or op item get --fields still runs on an empty value when 1Password fails or its prompt is dismissed. Read the secret into a variable, check it is not empty, then use it: set -o pipefail; pw="$(op read \'op://…\')"; : "${pw:?op read failed}"; then pass "$pw". Or write a small script that starts with set -euo pipefail and does the same.';
const basecampWrite =
  "Writing to Basecamp, or to the person's todos, is Shep's. When the person has to do something themselves, put it in your report as Todo: \"<text>\", and Shep adds it. Reads still work: basecamp todos list, show, search.";
const basecampAuth =
  "Logging Basecamp in or out (auth, login, logout, setup, profile create or delete), and its token, are the person's. They run basecamp auth login --device-code in their own shell.";
const todoTargets =
  "Where the person's todos go (bercail todo target add|rm, bercail todo route) is Shep's. Say in your report which list a todo belongs on, and Shep sets it.";
const landCommand =
  "Landing a change (bercail land) is Shep's. Stage it, finish with /validate, and Shep lands it once it is reviewed.";
const todoFile =
  "Todo targets and routes change only through bercail todo target and bercail todo route, which read the list before they keep it. Shep runs them.";
const basecampFlags =
  "Put basecamp's flags after its command and action (basecamp todos list --in 1), so the guard can tell what it runs.";
const unclosedSub =
  "The guard cannot find where this $( or backtick ends (a heredoc with an apostrophe inside $( ) does that). Write the body to a file first, then pass its path.";
const unclosedWarn =
  "The guard could not find where a $( or backtick ends, so it did not check the rest of this command. Next time, write the body to a file first, then pass its path.";
const lostCwd =
  "The guard lost track of the folder after a cd it could not follow, so it checked a relative write target by its name only.";
const pushApproved = (token: string) =>
  `Allowed this push without asking: the person's Decisions answer ${token} approves it, once. Say so in your report.`;
const pushApprovalCommand =
  "Which Decisions answer approves a push is the guard's to check and spend. Push, and the guard checks.";
const guardAskCommand =
  "A guard card and its worker are the guard's: it starts them when Shep runs a command it would ask about. Run the command, and the guard hands it off.";
const tmpWrite = (tmpdir: string) =>
  `This writes under /tmp, which holds RAM and keeps a file for days. Put scratch in $TMPDIR (${tmpdir}) or a mktemp -d folder instead: bercail removes it when you exit.`;

const allow: GuardDecision = { action: "allow" };
const block = (reason: string): GuardDecision => ({ action: "block", reason });
const ask = (reason: string): GuardDecision => ({ action: "ask", reason });
const approve = (reason: string): GuardDecision => ({ action: "allow", approved: [reason] });
const warn = (warning: string): GuardDecision => ({ action: "allow", warnings: [warning] });

// A UI asks the person; with no one to ask, it is a refusal.
const askOr = (input: GuardInput, question: string, refusal: string): GuardDecision =>
  input.hasUI ? ask(question) : block(refusal);

function readOnlyRole(role: string): boolean {
  return role === "judge" || role === "discuss";
}

// Where a background Shep's shell may write besides its temp dirs.
const stream = /^\/dev\/(null|stdout|stderr|tty|fd\/[0-9]+)$/;

// What refuses a commit, a push, a tag or a tree change: the read-only roles,
// and background Shep, which runs commands only to wait and report.
function noChange(role: string): GuardDecision | undefined {
  if (readOnlyRole(role)) return block(readOnly);
  if (role === "shep-bg") return block(backgroundOnly);
  return undefined;
}

// bercail reads these as the desk's own (describe check's evidence, a handoff's
// result) or the repo's (its policy, whose rules need no trust), so a reviewer
// may not write them.
const deskFiles = new Set(["description.md", "validate.json", "handoff-result.json", "policy.toml"]);

// A read-only role writes its answer and scratch files: anywhere under the temp
// dirs, and a new file under the worktree's .bercail/, which git ignores. Both the
// path as spelled and the file it lands on, through symlinks, must be one of those.
// Pi's tools drop a .. before they open a path; the shell has the kernel follow it.
function readOnlyWrite(path: string, input: GuardInput, cwd = input.cwd, shell = false): boolean {
  const where = input.readOnlyWrites;
  if (!where || (cwd === undefined && !isAbsolute(path))) return false;
  const spelled = resolve(cwd ?? "/", path);
  const opened = shell && !isAbsolute(path) ? `${cwd}/${path}` : shell ? path : spelled;
  try {
    return [spelled, canonical(opened)].every((full) => readOnlyPlace(full, where));
  } catch {
    return false; // A symlink loop: the guard cannot tell where the write lands.
  }
}

// The .bercail/ rules come first, since a worktree may itself live under /tmp. That
// worktree is still the one under review: the rest of it, the worktree itself, or a
// folder holding it is not scratch. A temp dir itself is, as cp's destination.
function readOnlyPlace(full: string, where: NonNullable<GuardInput["readOnlyWrites"]>): boolean {
  if (basename(dirname(full)) === ".bercail" && deskFiles.has(basename(full))) return false;
  const spellings = (dir: string) => [resolve(dir), canonical(dir)];
  const within = (path: string, dir: string) => spellings(dir).some((d) => path.startsWith(`${d}/`));
  if (within(full, join(where.root, ".bercail"))) return !where.exists(full);
  const roots = spellings(where.root);
  const tree = roots.some((root) => full === root || full.startsWith(`${root}/`) || root.startsWith(`${full}/`));
  if (tree && roots.some((root) => where.tmp.some((dir) => within(root, dir)))) return false;
  return where.tmp.some((dir) => spellings(dir).includes(full) || within(full, dir));
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

// A shell word, an operator that ends a command, a command substitution's body,
// a line of an unquoted heredoc, or a $( or backtick the guard cannot find the end of.
type Token =
  | { kind: "op"; op: string; redirect?: boolean }
  | { kind: "word"; value: string; quoted: boolean }
  | { kind: "sub"; value: string }
  | { kind: "doc"; value: string }
  | { kind: "unclosed" };

// tag keeps the mktemp -d dirs of nested commands apart.
function tokenize(command: string, tag = ""): Token[] {
  const tokens: Token[] = [];
  let temps = 0;
  const tempDir = () => `${tempPrefix}${tag}.${temps++}`;
  // Heredocs opened on the current line; their bodies start after its newline.
  const heredocs: { delim: string; strip: boolean; quoted: boolean }[] = [];
  let i = 0;
  let bareRedirect = false;
  while (i < command.length) {
    const c = command[i];
    if (c === " " || c === "\t") {
      bareRedirect = false;
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
        bareRedirect = false;
        i = j;
        continue;
      }
    }
    if (c === "\n" && heredocs.length) {
      bareRedirect = false;
      tokens.push({ kind: "op", op: "\n" });
      i++;
      for (const doc of heredocs.splice(0)) {
        while (i < command.length) {
          let end = command.indexOf("\n", i);
          if (end < 0) end = command.length;
          const line = command.slice(i, end);
          i = end + 1;
          if ((doc.strip ? line.replace(/^\t+/, "") : line) === doc.delim) break;
          if (doc.quoted) continue;
          tokens.push({ kind: "doc", value: line });
          for (const sub of subsIn(line)) tokens.push({ kind: "sub", value: sub });
        }
      }
      continue;
    }
    if (c === "\n" || c === ";" || c === "|" || c === "&") {
      const double = (c === "|" && command[i + 1] === "|") || (c === "&" && command[i + 1] === "&");
      // Backslash-newline disappears before bash reads >&2, 2>&1 or &>file.
      let next = i + 1;
      while (command[next] === "\\" && command[next + 1] === "\n") next += 2;
      const redirect = c === "&" && !double && (bareRedirect || command[next] === ">");
      bareRedirect = false;
      tokens.push({ kind: "op", op: double ? c + c : c, redirect });
      i += double ? 2 : 1;
      continue;
    }
    if (c === "$" && command[i + 1] === "(") {
      const inner = readBalanced(command, i + 1);
      if (inner && !makesTempDir(inner.body)) {
        bareRedirect = false;
        tokens.push({ kind: "sub", value: inner.body });
        i = inner.end;
        continue;
      }
    }
    if (c === "`") {
      const end = command.indexOf("`", i + 1);
      if (end > i && !makesTempDir(command.slice(i + 1, end))) {
        bareRedirect = false;
        tokens.push({ kind: "sub", value: command.slice(i + 1, end) });
        i = end + 1;
        continue;
      }
    }
    let word = "";
    let quoted = false;
    while (i < command.length) {
      const ch = command[i];
      if (" \t\n;|&".includes(ch)) break;
      // readBalanced gives up on a $( it can't close, like one around a heredoc
      // whose body has an apostrophe. Breaking on an empty word would leave i
      // where it is and loop forever, so the rest is left unchecked and blocked.
      if (ch === "$" && command[i + 1] === "(") {
        const inner = readBalanced(command, i + 1);
        if (!inner && !word) {
          tokens.push({ kind: "unclosed" });
          i = command.length;
          break;
        }
        if (!inner || !makesTempDir(inner.body)) break;
        bareRedirect = false;
        word += tempDir();
        i = inner.end;
        continue;
      }
      if (ch === "`") {
        const end = command.indexOf("`", i + 1);
        if (end < 0 && !word) {
          tokens.push({ kind: "unclosed" });
          i = command.length;
          break;
        }
        if (end < 0 || !makesTempDir(command.slice(i + 1, end))) break;
        bareRedirect = false;
        word += tempDir();
        i = end + 1;
        continue;
      }
      if (ch === "'") {
        bareRedirect = false;
        quoted = true;
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
        bareRedirect = false;
        quoted = true;
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
        if (command[i + 1] === "\n") {
          i += 2;
          continue;
        }
        bareRedirect = false;
        if (i + 1 < command.length) word += literal(command[i + 1]);
        i += 2;
        continue;
      }
      // A ( that starts a word, and any unquoted ), is a word of its own, as bash reads
      // them: time (cd x; true)>/dev/null. A <( or a=( stays in its word.
      if (ch === ")" && word) break;
      bareRedirect = ch === "<" || ch === ">";
      word += ch;
      i++;
      if (ch === ")" || word === "(") break;
    }
    if (word || quoted) tokens.push({ kind: "word", value: word, quoted });
  }
  return tokens;
}

// One simple command, with the operators before and after it ("" at either end).
// marked keeps literalDollar where words has the $ back; quoted: each word had quotes.
// redirect: the & after it belongs to a redirect such as >&2.
// docs: unquoted heredoc lines read just before these words; they belong to an earlier command.
type Segment = {
  words: string[];
  marked: string[];
  quoted: boolean[];
  subs: string[];
  docs: string[];
  before: string;
  after: string;
  redirect: boolean;
  unclosed: boolean;
};

function segmentsOf(command: string, tag = ""): Segment[] {
  const out: Segment[] = [];
  let words: string[] = [];
  let quoted: boolean[] = [];
  let subs: string[] = [];
  let docs: string[] = [];
  let before = "";
  let unclosed = false;
  const flush = (op: string, redirect = false) => {
    if (words.length || subs.length || docs.length || unclosed) {
      const plain = words.map((word) => word.replaceAll(literalDollar, "$"));
      out.push({ words: plain, marked: words, quoted, subs, docs, before, after: op, redirect, unclosed });
    }
    words = [];
    quoted = [];
    subs = [];
    docs = [];
    before = op;
  };
  for (const token of tokenize(command, tag)) {
    if (token.kind === "op") flush(token.op, token.redirect);
    else if (token.kind === "unclosed") unclosed = true;
    else if (token.kind === "sub") subs.push(token.value);
    else if (token.kind === "doc") docs.push(token.value);
    else {
      words.push(token.value);
      quoted.push(token.quoted);
    }
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
  // Keep legacy conservative classification; help recognition uses the full raw argv.
  words = words.filter((word) => word !== "");
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

// Only a bare builtin's sole --help: no aliases, selectors, wrappers or flag values.
const gitHelpBuiltins = new Set([
  "add",
  "commit",
  "push",
  "restore",
  "clean",
  "rm",
  "mv",
  "merge",
  "rebase",
  "reset",
  "checkout",
  "switch",
  "branch",
  "tag",
  "config",
  "init",
  "worktree",
]);

const staticArg = /^[\w./-]+$/;

function cliHelp(words: string[], graphiteAliases: readonly string[] | undefined): boolean {
  if (words.length !== 3 || words[2] !== "--help") return false;
  const name = basename(words[0]);
  if (name === "git") return gitHelpBuiltins.has(words[1]);
  // Graphite expands aliases before parsing help, even aliases named submit or merge.
  return (
    name === "gt" &&
    ["create", "modify", "submit", "merge"].includes(words[1]) &&
    graphiteAliases !== undefined &&
    !graphiteAliases.includes(words[1])
  );
}

function readGraphiteAliases(): readonly string[] | undefined {
  const home = process.env.HOME;
  if (!home || !isAbsolute(home)) return undefined;
  const config = process.env.XDG_CONFIG_HOME ?? join(home, ".config");
  if (!isAbsolute(config)) return undefined;
  try {
    const path = join(config, "graphite/aliases");
    if (!statSync(path).isFile()) return undefined;
    return readFileSync(path, "utf8")
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#"))
      .map((line) => line.split(/\s+/)[0]);
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT" ? [] : undefined;
  }
}

type GitCall = { sub: string; args: string[]; dir: string | undefined; config: string[]; global: string[] };

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
  return { sub: words[i] ?? "", args: words.slice(i + 1), dir, config, global: words.slice(1, i) };
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
  /** The remote it names, if any. */
  remote?: string;
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
    if (arg.startsWith("-")) {
      if (arg === "--force" || arg === "-f" || arg.startsWith("--force")) forceFlag = true;
      if (arg === "--mirror") mirrorFlag = true;
      if (arg === "--tags" || arg === "--follow-tags") tags = true;
      if (arg === "--all" || arg === "--branches") every = true;
      if (arg === "--delete" || arg === "-d") deleting = true;
      if (arg.startsWith("--delete=")) deleted.push(arg.slice("--delete=".length));
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
  const listed = first === undefined ? [] : firstIsRef ? positionals : positionals.slice(1);
  // With --delete, git deletes every ref listed, wherever the flag stands.
  const refspecs = deleting ? [] : listed;
  if (deleting) deleted.push(...listed);
  for (const spec of refspecs) {
    if (spec.startsWith("+")) plus = true;
    if (spec.includes("*")) every = true;
    // :<ref> pushes nothing to <ref>: a delete.
    const bare = spec.replace(/^\+/, "");
    if (bare.startsWith(":")) deleted.push(bare.slice(1));
  }
  const remote = first === undefined || firstIsRef ? undefined : first;
  return {
    force: forceFlag,
    mirror: mirrorFlag,
    deleteMain: deleted.some(isMainRef),
    plus,
    remote,
    refspecs,
    deleted,
    tags,
    every,
  };
}

function shellScript(words: string[]): string | undefined {
  const cmd = words[0];
  if (cmd !== "bash" && cmd !== "sh" && cmd !== "dash" && cmd !== "eval") return undefined;
  // eval joins its words with spaces and runs that, after an optional --.
  if (cmd === "eval") return words.slice(words[1] === "--" ? 2 : 1).join(" ") || undefined;
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
// trail: a trail write on entire.com that pushes no git ref (create --no-branch, update).
type EntireKind = "read" | "push" | "write" | "trail" | "ask" | "merge" | "approve" | "person" | "destroy" | BrainKind;
// Brain and Graph (bercail-shr): a local index rebuild, a repository memory, a
// model call on the person's tokens, and setup, sync or background work.
type BrainKind = "refresh" | "remember" | "spend" | "setup";

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

// The same words as cobra reads them when each flag bercail does not know takes a
// value: it eats the next word, so `entire --verbose status trail merge` runs
// trail merge. undefined when that reading is no different.
function entireValueReading(words: string[]): string[] | undefined {
  const out = [words[0]];
  let eaten = false;
  for (let i = 1; i < words.length; i++) {
    const word = words[i];
    out.push(word);
    if (word === "--") return eaten ? [...out, ...words.slice(i + 1)] : undefined;
    if (entireValueFlags.has(word)) {
      if (i + 1 < words.length) out.push(words[++i]);
    } else if (/^(--[^=]+|-[^-=])$/.test(word) && i + 1 < words.length) {
      i++;
      eaten = true;
    }
  }
  return eaten ? out : undefined;
}

// entire trail merge [<trail>] that both readings agree on: before merge, only
// flags with a value bercail knows, and no --force.
function plainTrailMerge(words: string[]): boolean {
  const lead: string[] = [];
  let i = 1;
  for (; i < words.length && lead.length < 2; i++) {
    if (!words[i].startsWith("-")) lead.push(words[i]);
    else if (entireValueFlags.has(words[i])) i++;
    else if (!/^-[^=]+=/.test(words[i])) return false;
  }
  const end = words.indexOf("--");
  const flags = end < 0 ? words : words.slice(0, end);
  return lead.join(" ") === "trail merge" && !flags.some((word) => word === "--force" || word.startsWith("--force="));
}

// No --help or --dry-run shortcut: a string flag takes the next word as its
// value, so `trail approve 3 -m --help` is a real approval.
const entireAliases: Record<string, string> = { cp: "checkpoint", checkpoints: "checkpoint", sessions: "session" };

// Brain's and Graph's flags that take a value. A set of their own, so Brain's
// --path does not change how a trail command parses.
const pluginValueFlags = new Set(
  [
    "--path --kind --locus --k --source --query --dir --output -o --test --setup --report --graph-binary",
    "--agent-command --profile-json --entire-binary --branch --agent --model --limit -n --number --session",
    "--scope --format --profile --cache-dir --after --before --concept --sessions --max-bytes --effort",
  ]
    .join(" ")
    .split(" "),
);

// Subcommands by dotted path. A group's next word is its subcommand; a leaf's
// next words are its arguments. A group alone prints its help. A flag before a
// subcommand leaves it unknown: cobra takes an unknown flag's next word as its
// value, so `entire-brain --workspace status setup` runs setup.
const pluginGroups = new Set(
  "brain graph brain.inspect brain.entities brain.memories brain.memories.storage brain.patterns brain.patterns.skills brain.webhook brain.docs brain.config brain.workspace brain.workspace.patterns brain.memory brain.refresh".split(
    " ",
  ),
);
const pluginKinds: [EntireKind, string, string][] = [
  [
    "read",
    "brain",
    ". version agent-guide capabilities overview brief query search vsearch get multi-get recall status stats doctor verify path show review help inspect inspect.blame inspect.boundaries inspect.changes inspect.code inspect.context inspect.dead-code inspect.graph-schema inspect.impact inspect.query-graph inspect.regressions inspect.search-graph inspect.snippet inspect.tests inspect.trace-path entities entities.history entities.show memories memories.status memories.tree memories.global memories.vitality memories.map memories.storage memories.storage.status patterns patterns.status webhook webhook.status webhook.events docs docs.extract docs.formats config config.show config.path workspace workspace.list workspace.query workspace.search workspace.get workspace.vsearch workspace.inspect workspace.review memory memory.status memory.jobs",
  ],
  [
    "refresh",
    "brain",
    "refresh refresh.delta refresh.history refresh.index refresh.seed refresh.sessions entities.backfill patterns.refresh repair memory.rebuild memory.repair memory.reconcile memory.retry",
  ],
  [
    "spend",
    "brain",
    "distill patterns.verify patterns.skills.form memories.outline memory.abstract memory.configure workspace.patterns.verify",
  ],
  ["remember", "brain", "remember memories.retract"],
  [
    "setup",
    "brain",
    "setup add connect disconnect memories.sync memories.import memories.gc memories.reclassify memories.storage.migrate memory.push-work memory.notify watch workspace.watch workspace.create workspace.add workspace.remove workspace.refresh stop start reset config.init init daemon-reregister init-agents publish bundle webhook.test viz dash",
  ],
  [
    "read",
    "graph",
    ". query neighbors impact def explain symbols edges snapshot snapshot-query commit diff checkpoint health doctor version capabilities context store agent-guide stats verify help",
  ],
  ["refresh", "graph", "index"],
  ["setup", "graph", "setup"],
];
const pluginKind = new Map(
  pluginKinds.flatMap(([kind, name, paths]) =>
    paths.split(" ").map((path) => [path === "." ? name : `${name}.${path}`, kind] as const),
  ),
);

type PluginCall = { key: string; flags: Map<string, string> };

// entire brain …, entire graph …, or the plugin binary itself (entire-brain …):
// the subcommand's dotted path and the flags it was given.
function pluginCall(words: string[]): PluginCall | undefined {
  let args: string[] | undefined;
  let key = /^entire-(brain|graph)$/.exec(words[0])?.[1];
  if (key) args = words.slice(1);
  else if (words[0] === "entire") {
    for (let i = 1; i < words.length && words[i] !== "--" && args === undefined; i++) {
      if (!words[i].startsWith("-")) {
        if (words[i] !== "brain" && words[i] !== "graph") return undefined;
        key = words[i];
        args = words.slice(i + 1);
      } else if (entireValueFlags.has(words[i])) i++;
    }
  }
  if (key === undefined || args === undefined) return undefined;
  const flags = new Map<string, string>();
  let leaf = false;
  for (let i = 0; i < args.length && args[i] !== "--"; i++) {
    const word = args[i];
    const eq = word.indexOf("=");
    const group = !leaf && pluginGroups.has(key);
    if (!word.startsWith("-")) {
      if (group && flags.size > 0) return { key: `${key}.?`, flags };
      if (group) key += `.${word}`;
      else leaf = true;
    } else if (eq > 0) flags.set(word.slice(0, eq), word.slice(eq + 1));
    else flags.set(word, pluginValueFlags.has(word) ? (args[++i] ?? "") : "");
  }
  return { key, flags };
}

function pluginCallKind({ key, flags }: PluginCall): EntireKind {
  const flag = (name: string) => flags.has(name);
  if (["--agent-command", "--graph-binary", "--profile-json", "--entire-binary"].some(flag)) return "setup";
  if (key === "brain.remember") return flag("--global") ? "setup" : flags.get("--path") ? "remember" : "spend";
  if (key === "brain.memories.retract" && flag("--global")) return "setup";
  if (key === "brain.repo-identity" && flag("--keep")) return "setup";
  if (key === "brain.recall" && flag("--expand")) return "spend";
  if (key.startsWith("brain.refresh") && flag("--agent") && flags.get("--agent") !== "none") return "spend";
  if (key === "graph.index" && flag("--report")) return "ask";
  return pluginKind.get(key) ?? "ask";
}

// The commands graph verify runs: decided like bash -c.
function pluginScripts(words: string[]): string[] {
  const call = pluginCall(words);
  if (call?.key !== "graph.verify") return [];
  return [call.flags.get("--test"), call.flags.get("--setup")].filter((script) => script !== undefined);
}

function entireKind(words: string[]): EntireKind | undefined {
  const plugin = pluginCall(words);
  if (plugin) return pluginCallKind(plugin);
  if (words[0] !== "entire") return undefined;
  const path = entirePath(words);
  const [cmd, sub, third] = [entireAliases[path[0]] ?? path[0], path[1], path[2]];
  const flag = (...names: string[]) => words.some((w) => names.some((n) => w === n || w.startsWith(`${n}=`)));
  const among = (word: string | undefined, list: string) => word === undefined || list.split(" ").includes(word);
  if (cmd === undefined || among(cmd, "status why blame search activity labs recap version agent-help help"))
    return "read";
  if (cmd === "auth" && sub === "status") return "read";
  if (cmd === "plugin") return among(sub, "list info search doctor") ? "read" : "person";
  if (among(cmd, "enable disable configure clean login logout auth cluster org project service-account"))
    return "person";
  if (cmd === "agent") return sub === "list" ? "read" : "person";
  if (cmd === "repo")
    return sub === "view" || sub === "list" || (sub === "mirror" && third === "list") ? "read" : "person";
  // A dismissed finding can clear a merge gate, so it counts as an approval.
  if (cmd === "api" && words.some((word) => /merge|approv|dismiss/i.test(word))) return "approve";
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
    if (path.includes("approve")) return "approve";
    if (path.includes("merge")) return "merge";
    if (path.includes("finding") && path.includes("dismiss")) return "approve";
    if (among(sub, "approvals list sessions show stack timeline watch")) return "read";
    // --no-branch=false still links a branch.
    if (sub === "create" && words.some((w) => w === "--no-branch" || w === "--no-branch=true")) return "trail";
    if (among(sub, "create link ci-pr update-branch")) return "push";
    if (sub === "finding") return among(third, "list show") ? "read" : "write";
    if (sub === "update") return "trail";
    if (among(sub, "ready retarget comment rerun-review unlink attachment")) return "write";
  }
  return "ask";
}

// Shep merges a trail when the person asks (bercail-wd0). It asks rather than
// following a policy: a project trail can merge a change in another repo, so no
// checkout's policy covers it. --force skips the trail's gates: the person's.
function decideTrailMerge(words: string[], input: GuardInput): GuardDecision {
  if (input.role !== "shep" || !input.hasUI) return block(entireMerge);
  if (!plainTrailMerge(words)) return block(shepMerge);
  return { action: "ask", reason: "Merge this Entire trail into its base? Say yes only if you asked Shep to." };
}

// reading: the words as this kind was read from them, for agent-help's list.
function decideEntire(
  kind: EntireKind,
  words: string[],
  dir: string | undefined,
  input: GuardInput,
  reading = words,
): GuardDecision {
  if (kind === "read") return allow;
  if (kind === "approve") return block(entireMerge);
  if (kind === "merge") return decideTrailMerge(words, input);
  if (kind === "person") return block(entirePerson);
  if (kind === "destroy") return block(entireDestroy);
  if (kind === "setup") return block(brainSetup);
  if (kind === "spend") return askOr(input, brainSpendAsk, brainSpend);
  // Memories go through Shep and the person, as standing rules do.
  if (kind === "remember") return input.role === "shep" ? allow : block(brainRemember);
  if (readOnlyRole(input.role)) return block(readOnly);
  if (kind === "push") return decidePush([], dir, input, `entire ${entirePath(reading).slice(0, 2).join(" ")}`);
  if (kind === "trail") return decideTrailWrite(entirePath(reading)[1] === "create", dir, input);
  if (kind === "write" || kind === "refresh") return allow;
  if (!input.hasUI) return entireListedRead(reading, input);
  return ask("Allow this entire command? bercail does not know it to be read-only.");
}

// Shep's trail writes run with a warning: the person is fine with the team seeing
// trails (bercail-vzm1). A desk's create follows the push policy, with its own
// question; an update is like gh pr edit.
function decideTrailWrite(create: boolean, dir: string | undefined, input: GuardInput): GuardDecision {
  if (!create) return input.role === "shep" ? warn(shepTrail) : allow;
  const refused = noChange(input.role);
  if (refused) return refused;
  if (input.role === "shep") return warn(shepTrail);
  const policy = policyFor(dir, input);
  if (!isPolicy(policy)) return policy;
  if (policy.push !== "ask") return approve(because(policy, "push", policy.push));
  return askOr(input, trailAsk, trailHeadless);
}

// A headless run has no one to ask, so an entire command bercail does not know
// runs only when entire agent-help, read in the wrapper, lists it as read-only.
// Brain and Graph are plugins agent-help does not list.
function entireListedRead(words: string[], input: GuardInput): GuardDecision {
  if (words[0] !== "entire" || pluginCall(words)) return block(entireUnknown);
  const [first, sub] = entirePath(words);
  const cmd = entireAliases[first] ?? first;
  const top = input.entireHelp?.[""];
  if (!top) return { action: "need-entire-help", command: "" };
  if (top.includes(cmd)) return warn(entireListed);
  if (sub === undefined || !/^[a-z][a-z0-9-]*$/.test(cmd)) return block(entireUnknown);
  const subs = input.entireHelp?.[cmd];
  if (!subs) return { action: "need-entire-help", command: cmd };
  return subs.includes(sub) ? warn(entireListed) : block(entireUnknown);
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

// bercail shep question answer or push-approval, or the question helper's op run directly.
function questionOp(words: string[], op: string): boolean {
  const plain = plainWords(words);
  return plain.some((word, i) => (word === "question" || word.endsWith("question-cli.ts")) && plain[i + 1] === op);
}

// Programs that type or click as the person, and the kernel's input device. Through
// hyprctl: its key dispatchers, or a dispatch exec or --batch that runs one.
const inputFakers = new Set(["wtype", "ydotool", "dotool", "dotoolc", "xdotool", "evemu-play", "evemu-event"]);
const hyprInput = /\b(sendshortcut|sendkeystate|pass|wtype|ydotool|dotoolc?|xdotool)\b/;

function fakesInput(words: string[], raw: string[]): boolean {
  if (inputFakers.has(words[0]) || raw.some((word) => word.includes("/dev/uinput"))) return true;
  return words[0] === "hyprctl" && hyprInput.test(words.slice(1).join(" "));
}

// basecamp's flags that may come before its command or action: the ones that
// take a value, and the switches. Cobra reads any other flag there as taking
// the next word, so the guard could not tell which word is the command.
const basecampValue = new Set([
  "-a",
  "--account",
  "-p",
  "--project",
  "--in",
  "--jq",
  "-P",
  "--profile",
  "--cache-dir",
  "--todolist",
]);
const basecampSwitch = new Set(["-j", "--json", "-m", "--md", "-q", "--quiet", "-v", "--verbose", "--version"]);
// Commands that only read, and the resource commands whose list and show actions read.
const basecampReads = new Set(["search", "show", "url", "me", "version", "commands", "help", "timeline"]);
const basecampResources = new Set(
  (
    "projects todos subtasks todolists todosets hillcharts gauges todolistgroups messages chat pings cards files " +
    "schedule uploads vaults docs assignments calendars bookmarks people templates webhooks lineup messageboards " +
    "messagetypes forwards subscriptions attachments embeds comments boost notifications recordings filings " +
    "accounts profile tools doors drafts notes"
  ).split(" "),
);
const basecampListing = new Set(["todos", "projects", "todolists"]);
const basecampLogin = new Set(["login", "logout", "setup", "quick-start"]);

// basecamp's command and action, past the known flags before them. Another flag
// first: undefined, or with valued set, read as taking the next word or not.
function basecampCall(words: string[], valued?: boolean): string[] | undefined {
  const out: string[] = [];
  for (let i = 1; i < words.length && out.length < 2; i++) {
    const word = words[i];
    const flag = word.split("=")[0];
    if (!word.startsWith("-")) out.push(word);
    else if (basecampValue.has(flag)) i += word.includes("=") ? 0 : 1;
    else if (basecampSwitch.has(word)) continue;
    else if (valued === undefined) return undefined;
    else if (valued && !word.includes("=")) i++;
  }
  return out;
}

// With a flag it does not know before the command, the guard cannot tell which
// word is the command, so it decides both readings: it warns when both are
// allowed, and refuses as the worse one does.
function decideBasecamp(words: string[], role: string): GuardDecision {
  if (words[0] !== "basecamp") return allow;
  const call = basecampCall(words);
  if (call) return decideBasecampCall(call, role);
  for (const valued of [false, true]) {
    const got = decideBasecampCall(basecampCall(words, valued) ?? [], role);
    if (got.action === "block") return block(`${got.reason} ${basecampFlags}`);
  }
  return warn(basecampFlags);
}

// Its login and token are the person's in every role. Shep may write; any other
// role may only read, and what bercail does not know as a read is a write.
function decideBasecampCall(call: string[], role: string): GuardDecision {
  const [command, action] = call;
  // profile create logs a new profile in; profile delete revokes its credential.
  const login =
    basecampLogin.has(command) ||
    (command === "auth" && action !== "status") ||
    (command === "profile" && (action === "create" || action === "delete"));
  if (login) return block(basecampAuth);
  if (role === "shep") return allow;
  const reads =
    command === undefined ||
    basecampReads.has(command) ||
    (basecampResources.has(command) && (action === "list" || action === "show")) ||
    (action === undefined && basecampListing.has(command)) ||
    (command === "auth" && action === "status") ||
    (command === "config" && action === "show");
  return reads ? allow : block(basecampWrite);
}

// The words after bercail todo, or undefined when the command is not one.
function todoArgs(words: string[]): string[] | undefined {
  const plain = plainWords(words);
  const at = plain.findIndex((word, i) => basename(word) === "bercail" && plain[i + 1] === "todo");
  return at < 0 ? undefined : plain.slice(at + 2);
}

// bercail todo add or done: a write to the person's todo backend.
function writesTodo(words: string[]): boolean {
  const args = todoArgs(words);
  return args !== undefined && ["add", "done"].includes(args[0]);
}

// bercail todo route, or target add or rm: where Shep writes in the person's account.
function setsTodoTarget(words: string[]): boolean {
  const args = todoArgs(words);
  return args !== undefined && (args[0] === "route" || (args[0] === "target" && ["add", "rm"].includes(args[1])));
}

// bercail cleanup deletes a worktree, so the person says yes first.
function decideCleanup(words: string[], input: GuardInput): GuardDecision {
  const plain = plainWords(words);
  if (basename(plain[0] ?? "") !== "bercail" || plain[1] !== "cleanup") return allow;
  if (readOnlyRole(input.role)) return block(readOnly);
  if (!input.hasUI) return block(cleanupHeadless);
  if (input.role === "shep-bg") return block(backgroundOnly);
  return { action: "ask", reason: cleanupAsk };
}

// bercail land: Shep's commit and CI wait for a desk's branch.
function isLand(words: string[]): boolean {
  const plain = plainWords(words);
  return plain.some((word, i) => basename(word) === "bercail" && plain[i + 1] === "land");
}

// bercail guard ask, or the worker's file: only the guard starts it, on its own ticket.
function runsGuardAsk(words: string[]): boolean {
  const plain = plainWords(words);
  return plain.some(
    (word, i) =>
      (basename(word) === "bercail" && plain[i + 1] === "guard" && plain[i + 2] === "ask") ||
      word.endsWith("guard-ask.ts"),
  );
}

function isPolicyTrust(words: string[]): boolean {
  const plain = plainWords(words);
  return plain.some((word, i) => word === "policy" && plain[i + 1] === "trust");
}

// The files a shell command writes: its redirect targets, and what a file writer
// changes. Reads (cat, jq, sed -n, the source of a cp) are not writes, and
// neither is 2>&1. A seatbelt, not a sandbox.
const redirect = /^(?:\d*>>?|&>>?)(.*)$/;
const everyOperand = new Set(["tee", "mv", "rm", "unlink", "shred", "truncate", "chmod", "touch"]);
const toDestination = new Set(["cp", "ln", "install"]);
const inPlace: Record<string, RegExp> = { sed: /^-[bnrsuzE]*i|^--in-place/, perl: /^-[^-MIei]*i/ };
// Flags whose next word is a value, not a file: a script, a size, a date, a mode. A
// short one only when it ends a cluster of flags that take none, as getopt reads it;
// in -r/tmp/x the value is glued on, and the next word is a file.
const valueFlag: Record<string, RegExp> = {
  sed: /^(-[nrsuzEb]*[ef]|--expression|--file)$/,
  perl: /^-[pnaswtTWXc]*[eE]$/,
  touch: /^(-[acfhm]*[dtr]|--date|--reference)$/,
  truncate: /^(-[co]*[sr]|--size|--reference)$/,
  install: /^(-[bcCdDpsv]*[mogS]|--mode|--owner|--group|--suffix)$/,
  chmod: /^--reference$/,
};
// A script given by flag, its value glued on (-es/a/b/) or not. Matching too much
// only keeps the script a target.
const scriptFlag: Record<string, RegExp> = { sed: /^(-[^-]*[ef]|--expression|--file)/, perl: /^-[^-]*[eE]/ };
const chmodMode = /^[0-7]{1,4}$|^[ugoa]*[-+=][-+=rwxXstugoa,]*$/;

// A redirect's target: glued on (>file) or the next word.
function redirectTargets(raw: string[]): string[] {
  return raw.flatMap((word, i) => {
    const to = redirect.exec(word);
    return to ? [to[1] || raw[i + 1] || ""] : [];
  });
}

function writeTargets(words: string[], raw: string[]): string[] {
  const targets = redirectTargets(raw);
  const operands = words.filter((word, i) => !redirect.test(word) && redirect.exec(words[i - 1] ?? "")?.[1] !== "");
  const [name, ...args] = operands;
  // One pass, so a flag's value (touch -r -r FILE) is never read as a flag or as --.
  const valued = valueFlag[name];
  const plain: string[] = [];
  let ended = false;
  for (let i = 0; i < args.length; i++) {
    if (ended || !args[i].startsWith("-")) plain.push(args[i]);
    else if (args[i] === "--") ended = true;
    else if (valued?.test(args[i])) i++;
  }
  // With no flag to give it, the first operand is sed's or perl's script, or chmod's mode.
  const given = args.some((arg) => scriptFlag[name]?.test(arg) || /^--reference(=|$)/.test(arg));
  if (((name === "sed" || name === "perl") && !given) || (name === "chmod" && !given && chmodMode.test(plain[0] ?? "")))
    plain.shift();
  const makesDirs = name === "install" && args.some((arg) => arg === "--directory" || /^-[^-]*d/.test(arg));
  if (everyOperand.has(name) || makesDirs || (inPlace[name] && args.some((arg) => inPlace[name].test(arg))))
    targets.push(...plain);
  if (name === "dd") targets.push(...args.filter((arg) => arg.startsWith("of=")).map((arg) => arg.slice(3)));
  if (toDestination.has(name) && !makesDirs) {
    // -t DIR, -tDIR or --target-directory=DIR names the destination up front.
    const t = args.findIndex((arg) => /^(-t|--target-directory)(=|$)|^-t./.test(arg));
    if (t >= 0) targets.push(args[t].replace(/^(--target-directory|-t)=?/, "") || (args[t + 1] ?? ""));
    else if (plain.length > 1) targets.push(plain.at(-1)!);
    // ln with one operand makes the link in the current dir, under the target's name.
    else if (name === "ln" && plain.length === 1) targets.push(basename(plain[0]));
  }
  return targets.filter((target) => target !== "" && !target.startsWith("&"));
}

// The real path, through symlinks, even when the file or its parents do not exist yet.
function canonical(path: string, links = 0): string {
  if (links > 40) throw new Error("symlink loop");
  try {
    return realpathSync.native(path);
  } catch {
    let link: string | undefined;
    try {
      link = readlinkSync(path);
    } catch {
      /* A missing leaf may still have a symlink parent. */
    }
    if (link) return canonical(link.startsWith("/") ? link : `${dirname(path)}/${link}`, links + 1);
    const parent = dirname(path);
    return parent === path ? resolve(path) : join(canonical(parent, links), basename(path));
  }
}

// Expands what the guard knows of ~ and the state and config dirs. That can only
// make a write protected, never let one through.
function expandDirs(path: string, home: string | undefined): string {
  const known = (name: string) => (name === "HOME" ? (home ?? process.env.HOME) : process.env[name]);
  return path
    .replace(/^~(?=\/|$)/, home ?? process.env.HOME ?? "~")
    .replace(
      /\$(?:\{(HOME|XDG_STATE_HOME|XDG_CONFIG_HOME|XDG_RUNTIME_DIR)\}|(HOME|XDG_STATE_HOME|XDG_CONFIG_HOME|XDG_RUNTIME_DIR)\b)/g,
      (all, braced, bare) => known(braced ?? bare) || all,
    );
}

// A write lands on a protected file, or in a protected folder, from any dir the
// shell may be in. A path the guard cannot place (an unknown $VAR, or a relative
// path once the cwd is lost) is checked by name: a protected file's last two
// parts, or its file name.
function protectedTarget(
  target: string,
  input: GuardInput,
  files: string[],
  dirs: string[],
  literal: boolean,
): boolean {
  if (!files.length && !dirs.length) return false;
  const path = literal ? target : expandDirs(target, input.home);
  const placed = literal || (!/[$`]/.test(path) && !path.startsWith("~"));
  const cwds = input.cwds ?? [input.cwd];
  const fulls = !placed ? [] : path.startsWith("/") ? [path] : cwds.map((cwd) => cwd && `${cwd}/${path}`);
  if (!placed || fulls.includes(undefined)) {
    const named = (file: string) => {
      const tail = file.split("/").slice(-2).join("/");
      return basename(path) === basename(file) || `/${path}/`.includes(`/${tail}/`);
    };
    if (files.some(named)) return true;
  }
  try {
    const roots = [...files, ...dirs].map((root) => canonical(root));
    return fulls.some((full) => {
      if (!full) return false;
      const real = canonical(full);
      return roots.some((root) => real === root || real.startsWith(`${root}/`) || root.startsWith(`${real}/`));
    });
  } catch {
    // A symlink loop: the guard cannot tell where the write lands.
    return true;
  }
}

// What could make the unparsed rest of a command one the guard refuses or asks
// about: git and the forges, entire, a push, the person's commands, op,
// basecamp, typing for the person, and the names of the files it protects.
const refusalTriggers = new RegExp(
  [
    String.raw`\b(git|gh|gt|origin|entire(-brain|-graph)?|push|op|basecamp|wtype|ydotool|dotoolc?|xdotool|evemu-\w+|hyprctl|uinput)\b`,
    String.raw`question\s+answer|policy\s+trust|bercail\s+todo`,
    String.raw`config\.toml|policy-trust\.json|questions\.(json|lock)|todo\.json|bercail/shep`,
  ].join("|"),
);

// Quotes and backslashes go first: 'answer' and g\it are still the words.
function refusable(text: string): boolean {
  return refusalTriggers.test(text.replace(/['"\\]/g, ""));
}

// A write target the guard places from the cwd: not absolute, ~ or a $VAR.
function relativeTarget(target: string): boolean {
  return !/^[/~]/.test(target) && !/[$`]/.test(target);
}

// The guard's own files and Shep's state. A literal path is a file tool's: Pi
// expands no $VAR in it, and toolPath has already expanded its ~.
function writesGuardFiles(targets: string[], input: GuardInput, literal = false): boolean {
  const files = input.protectedFiles ?? [];
  const dirs = input.protectedDirs ?? [];
  return targets.some((target) => protectedTarget(target, input, files, dirs, literal));
}

function writesTodoFiles(targets: string[], input: GuardInput, literal = false): boolean {
  return targets.some((target) => protectedTarget(target, input, input.todoFiles ?? [], [], literal));
}

// An absolute path under /tmp, as written, and not in the agent's own TMPDIR,
// which may be there.
function inTmp(path: string, tmpdir: string): boolean {
  if (!isAbsolute(path)) return false;
  const full = resolve(path);
  const own = resolve(tmpdir);
  return (full === "/tmp" || full.startsWith("/tmp/")) && full !== own && !full.startsWith(`${own}/`);
}

// Where a command makes something, as its operands name it: mkdir's folders,
// mktemp's template or -p dir, git clone's and git worktree add's folder, tar
// -x's -C dir, rsync's and scp's destination, unzip's -d dir. A heuristic:
// another writer's flags (sort -o) are not read.
// git clone's and git worktree add's flags that take the next word as a value.
const cloneValue = new Set([
  "--depth",
  "-b",
  "--branch",
  "-o",
  "--origin",
  "-c",
  "--config",
  "--reference",
  "--reference-if-able",
  "--separate-git-dir",
  "--template",
  "-j",
  "--jobs",
  "--filter",
  "-u",
  "--upload-pack",
  "--shallow-since",
  "--shallow-exclude",
  "--bundle-uri",
  "--server-option",
]);
const worktreeValue = new Set(["-b", "-B", "--reason"]);

// A command's operands: past its flags, the values VALUED flags take, and --.
function operandsOf(args: string[], valued: Set<string>): string[] {
  const out: string[] = [];
  let ended = false;
  for (let i = 0; i < args.length; i++) {
    if (ended || !args[i].startsWith("-")) out.push(args[i]);
    else if (args[i] === "--") ended = true;
    else if (valued.has(args[i])) i++;
  }
  return out;
}

function madeAt(command: string[]): string[] {
  // Redirects are writeTargets'; here they would read as operands.
  const words = command.filter((word, i) => !redirect.test(word) && redirect.exec(command[i - 1] ?? "")?.[1] !== "");
  const [name, ...args] = words;
  const plain = (from = 0) => args.slice(from).filter((arg) => !arg.startsWith("-"));
  const valueOf = (flag: RegExp) =>
    args.flatMap((arg, i) => (flag.test(arg) ? [arg.replace(flag, "") || args[i + 1] || ""] : []));
  if (name === "mkdir") return plain();
  if (name === "mktemp") return [...plain(), ...valueOf(/^(-p|--tmpdir=?)/)];
  if (name === "unzip") return valueOf(/^-d/);
  if (name === "rsync" || name === "scp") return plain().length > 1 ? [plain().at(-1)!] : [];
  if (name === "tar" && args.some((arg) => /^-[^-]*x|^--(extract|get)$/.test(arg)))
    return valueOf(/^(-C|--directory=?)/);
  const git = parseGit(words, undefined);
  if (git?.sub === "clone") return operandsOf(git.args, cloneValue).slice(1, 2);
  if (git?.sub === "worktree" && git.args[0] === "add") return operandsOf(git.args.slice(1), worktreeValue).slice(0, 1);
  return [];
}

// A shell write under /tmp while the agent has its own TMPDIR. A removal's
// operands are not writes; its redirects are.
function writesInTmp(words: string[], raw: string[], targets: string[], tmpdir: string | undefined): boolean {
  if (!tmpdir) return false;
  const paths = ["rm", "unlink", "shred"].includes(words[0]) ? redirectTargets(raw) : [...targets, ...madeAt(words)];
  return paths.some((path) => inTmp(path, tmpdir));
}

// $(mktemp -d -p /tmp): the segments stand a path in for it, so its words are read here.
function mktempInTmp(command: string, tmpdir: string | undefined): boolean {
  if (!tmpdir) return false;
  return subsIn(command).some(
    (body) => makesTempDir(body) && madeAt(body.trim().split(/\s+/)).some((path) => inTmp(path, tmpdir)),
  );
}

// A read-only role's shell write goes where its write tool may, or into a mktemp -d
// dir, from each dir the shell may be in. The terminal devices are not files. A
// target the guard cannot place (a $VAR it does not know, or a relative path once
// the cwd is lost) passes.
function readOnlyTarget(target: string, input: GuardInput): boolean {
  if (/^\/dev\/(null|stdout|stderr|tty|fd\/\d+)$/.test(target)) return true;
  const path = expandDirs(target, input.home);
  if (/[$`]/.test(path) || path.startsWith("~")) return true;
  const cwds = isAbsolute(path) ? [input.cwd] : (input.cwds ?? [input.cwd]);
  if (!isAbsolute(path) && cwds.includes(undefined)) return true;
  return cwds.every((cwd) => tempRoot(resolve(cwd ?? "/", path)) || readOnlyWrite(path, input, cwd, true));
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
  const writes = "add commit push restore clean rm mv merge rebase cherry-pick revert am pull switch".split(" ");
  if (writes.includes(sub)) return true;
  if (sub === "reset" && args.some((arg) => arg === "--hard" || arg.startsWith("--hard"))) return true;
  if (
    sub === "checkout" &&
    (args.includes("--") || args.includes(".") || args.some((arg) => arg === "-f" || arg === "--force"))
  )
    return true;
  return false;
}

function publish(kind: "push" | "release", input: GuardInput, what = "this push"): GuardDecision {
  if (kind === "release")
    return askOr(
      input,
      "Allow this tag or release? This repo's policy leaves releases to the person.",
      headlessRelease,
    );
  return askOr(input, `Allow ${what}? No keeps it local for the person.`, headless);
}

// What a push sends, for its question: each ref and where it goes, so a command
// that also commits asks about its push alone (bercail-vzm1). via: the forge
// command that pushes, when it is not git push.
function pushWhat(facts: PushFacts, dests: string[], branch: string, via?: string): string {
  if (via) return `this push by ${via}`;
  const current = branch ? `the current branch (${branch})` : "the current branch";
  const named = (ref: string) => (ref === "HEAD" ? current : ref);
  const sent = facts.refspecs
    .filter((spec) => !spec.startsWith(":") && !spec.includes("*"))
    .map((spec) => {
      const [src, dst] = spec.split(":");
      return dst === undefined || dst === src || (src === "HEAD" && dst === branch)
        ? named(src)
        : `${named(src)} as ${dst}`;
    });
  const deletes = facts.deleted.map((ref) => `a delete of ${ref}`);
  const bare = facts.refspecs.length === 0 && facts.deleted.length === 0 && dests.includes("");
  const items = [
    ...sent,
    ...deletes,
    ...(bare ? [current] : []),
    ...(dests.includes("*") ? ["every branch"] : []),
    ...(facts.tags ? ["tags"] : []),
  ];
  return `this push${facts.remote ? ` to ${facts.remote}` : ""}: ${items.join(", ")}`;
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
  const refused = noChange(input.role);
  if (refused) return refused;
  const policy = policyFor(dir, input);
  if (!isPolicy(policy)) return policy;
  if (policy.agentMayRelease) return approve(because(policy, "agent_may_release", "true"));
  if (input.role === "autopilot") return block(autopilotRelease);
  return publish("release", input);
}

// Shep's push that a Decisions answer may approve (bercail-gmd4): the whole command is
// one plain git push of objects named by hash, which no ref can shadow (^{commit}), to
// full refs, so what the guard checks is what git sends. It is the only tool call of its
// message, so nothing else Shep runs can move a ref or the remote's URL beside it.
// Anything else, or a push today's rules do not ask about, is decided as before.
const hashRefspec = /^([0-9a-f]{40}|[0-9a-f]{64})\^\{(commit|tag)\}:refs\/(heads|tags)\/[\w./-]+$/;
const plainWord = /^[\w./:@=-]+$/;
const remoteName = /^[A-Za-z0-9][\w.-]*$/;

function approvable(git: GitCall, input: GuardInput): PushRequest | undefined {
  if (input.role !== "shep" || !input.sole || !input.alone || git.dir === undefined || git.config.length)
    return undefined;
  // At most one -C, to an absolute path without .., so the folder the helper checks is the one git uses.
  const [flag, folder = "", ...more] = git.global;
  if (
    more.length ||
    (flag !== undefined && (flag !== "-C" || !/^\/[\w./@-]*$/.test(folder) || /\/\.\.(\/|$)/.test(folder)))
  )
    return undefined;
  // No flags: the remote, then each <hash>^{commit}:<full ref>.
  const [remote, ...refspecs] = git.args;
  if (!remote || !remoteName.test(remote) || !refspecs.length || !refspecs.every((spec) => hashRefspec.test(spec)))
    return undefined;
  return { dir: git.dir, remote, refspecs };
}

function decidePush(
  args: string[],
  dir: string | undefined,
  input: GuardInput,
  via?: string,
  plain?: PushRequest,
): GuardDecision {
  const decision = pushPolicy(args, dir, input, via);
  return plain && decision.action === "ask" ? { ...decision, push: plain } : decision;
}

function pushPolicy(args: string[], dir: string | undefined, input: GuardInput, via?: string): GuardDecision {
  const facts = pushFacts(args);
  if (facts.force) return forceFor(input);
  if (facts.plus) return block(plusRef);
  if (facts.mirror) return block(mirror);
  if (facts.deleteMain) return block(deleteMain);
  if (hasNoVerify("push", args)) return block(noVerify);
  const refused = noChange(input.role);
  if (refused) return refused;

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
      if (branch === "") return worse(decision, askOr(input, unknownBranchAsk, unknownBranch));
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
  const branch = dir === undefined || input.branchMoved ? "" : (input.branches?.[dir] ?? "");
  return worse(decision, publish("push", input, pushWhat(facts, dests, branch, via)));
}

// A commit is local and reversible, so it runs in every repo with a warning; only
// a push publishes. Read-only roles and background Shep never commit.
function decideCommit(input: GuardInput): GuardDecision {
  if (readOnlyRole(input.role)) return block(readOnly);
  if (input.role === "shep-bg") return block(shepBgCommit);
  if (input.role === "autopilot") return approve("autopilot commits to its pull request branch");
  return warn(input.role === "shep" ? shepCommit : deskCommit);
}

function decideGit(git: GitCall, input: GuardInput): GuardDecision {
  const { sub, args } = git;
  if (hasNoVerify(sub, args) && ["commit", "push", "merge", "rebase"].includes(sub)) return block(noVerify);
  const risky = git.config.find((key) => riskyConfig.test(key)) ?? (sub === "config" ? configWrite(args) : undefined);
  if (risky) return configBlock(risky);
  if (sub === "push") return decidePush(args, git.dir, input, undefined, approvable(git, input));
  if (sub === "tag" && tagWrites(args)) return decideRelease(git.dir, input);
  if (sub === "commit") return decideCommit(input);
  if (gitWrite(sub, args)) {
    const refused = noChange(input.role);
    if (refused) return refused;
  }
  return allow;
}

function lookup(decision: GuardDecision): boolean {
  return ["need-branch", "need-policy", "need-entire-help"].includes(decision.action);
}

// A refusal wins, then a lookup, then an ask. Warnings add up, once each.
function worse(current: GuardDecision, next: GuardDecision): GuardDecision {
  if (next.action === "block" || current.action === "block") return next.action === "block" ? next : current;
  if (lookup(next)) return next;
  if (lookup(current)) return current;
  const warned = (d: GuardDecision) => ("warnings" in d && d.warnings) || [];
  const warnings = [...new Set([...warned(current), ...warned(next)])];
  const extra = warnings.length ? { warnings } : {};
  if (next.action === "ask") return { ...next, ...extra };
  if (current.action === "ask") return { ...current, ...extra };
  const approved = [
    ...(current.action === "allow" ? (current.approved ?? []) : []),
    ...(next.action === "allow" ? (next.approved ?? []) : []),
  ];
  return { action: "allow", ...(approved.length ? { approved } : {}), ...extra };
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

// NAME=value set once, outside a pipe or a skipped branch, and only to a
// mktemp -d dir: what $NAME and \${NAME} mean until a subshell closes.
type TempVars = Map<string, { value: string; chained: boolean }>;

const declares = new Set(["export", "declare", "typeset", "readonly"]);

// Words that start code which may run in another order, more than once, or not at
// all: past one, the guard no longer knows what a variable holds.
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

// Every other spelling of the name may set it: read d, for d, printf -v d, and a
// value glued to a flag, printf -vd. A flag of its own such as mktemp -d, or a path
// part such as $d/r, cannot.
function assignedOnce(command: string, name: string): boolean {
  const spelled = `(?:(?<![\\w$./-])(?<!\\$\\{)|(?<=(?:^|[^\\w$-])-[A-Za-z]+))${name}(?!\\w)`;
  return (command.match(new RegExp(spelled, "g")) ?? []).length === 1;
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

// op's global flags that take a value.
const opValue = new Set(["--account", "--config", "--encoding", "--format", "--session"]);

// op's words from its subcommand on, past the global flags; undefined when it is not op,
// or asks for help, which prints no secret. A --help after op run's -- is its command's.
function opArgs(words: string[]): string[] | undefined {
  const cmd = commandWords(words);
  if (cmd.length === 0 || basename(cmd[0]) !== "op") return undefined;
  const own = cmd.includes("--") ? cmd.slice(0, cmd.indexOf("--")) : cmd;
  if (own.some((word) => word === "--help" || word === "-h")) return undefined;
  let i = 1;
  while (i < cmd.length && cmd[i].startsWith("-")) i += opValue.has(cmd[i]) ? 2 : 1;
  return cmd.slice(i);
}

// op read, op inject, and op item get with --fields, --otp or --reveal print a secret.
function readsSecret(words: string[]): boolean {
  const args = opArgs(words);
  if (!args) return false;
  if (args[0] === "read" || args[0] === "inject") return true;
  return args[0] === "item" && args.includes("get") && args.some((word) => /^--(fields|otp|reveal)(=|$)/.test(word));
}

// segmentsOf, with the & of >&2, 2>&1 and &>file put back in its command: the
// tokenizer ends a segment there, as if it ran in the background.
function commandsOf(command: string): Segment[] {
  const out: Segment[] = [];
  for (const segment of segmentsOf(command, "secret")) {
    const last = out.at(-1);
    if (!last?.redirect) {
      out.push(segment);
      continue;
    }
    out[out.length - 1] = {
      words: [...last.words, ...segment.words],
      marked: [...last.marked, ...segment.marked],
      quoted: [...last.quoted, ...segment.quoted],
      subs: [...last.subs, ...segment.subs],
      docs: [...last.docs, ...segment.docs],
      before: last.before,
      after: segment.after,
      redirect: segment.redirect,
      unclosed: last.unclosed || segment.unclosed,
    };
  }
  return out;
}

// The words without a ( subshell's parens, which tokenize makes words of their own:
// (git commit) runs git commit.
function unparen(words: string[], quoted: boolean[]): string[] {
  return words.filter((word, i) => !(["(", ")"].includes(word) && !quoted[i]));
}

// The segment runs op that prints a secret, itself or in a sh -c script.
function segmentReadsSecret(segment: Segment): boolean {
  const words = commandWords(unparen(segment.words, segment.quoted));
  const script = shellScript(words.map((word, i) => (i === 0 ? basename(word) : word)));
  return readsSecret(words) || (script !== undefined && commandsOf(script).some(segmentReadsSecret));
}

// 2>&1 in $(op read ...): op's error text becomes the value, and passes a check.
function joinsErrors(segment: Segment): boolean {
  return segment.words.some((word, i) => word === "2>" && segment.words[i + 1] === "1");
}

// The segment's command reads op's secret from a <( ).
function readsSecretFrom(segment: Segment): boolean {
  const at = segment.words.findIndex((word) => word.includes("<("));
  const word = segment.words[at] ?? "";
  return at >= 0 && readsSecret([word.slice(word.indexOf("<(") + 2), ...segment.words.slice(at + 1)]);
}

// The names a plain assignment sets, export and local included; undefined when it runs a command.
function assignedNames(segment: Segment): { names: string[]; exported: boolean } | undefined {
  let words = segment.words;
  while (shellPrefixes.has(words[0])) words = words.slice(1);
  const head = declares.has(words[0]) || words[0] === "local";
  const flags = head ? words.slice(1).filter((word) => word.startsWith("-")) : [];
  const rest = head ? words.slice(1).filter((word) => !word.startsWith("-")) : words;
  if (rest.length === 0 || !rest.every((word) => assign.test(word))) return undefined;
  const exported = words[0] === "export" || flags.some((flag) => /^-\w*x/.test(flag));
  return { names: rest.map((word) => word.slice(0, word.indexOf("="))), exported };
}

// The segment at j runs exit, or opens a { } or then body that does. return is no
// check: at a script's top level it fails and the shell goes on. Neither is an exit
// in a pipe or behind &, which ends only a subshell.
function exits(segments: Segment[], j: number): boolean {
  let found = false;
  for (let k = j; k < segments.length; k++) {
    const segment = segments[k];
    if (["|", "&"].includes(segment.after) || segment.before === "|") return false;
    let words = segment.words;
    const opens = ["then", "{"].includes(words[0]);
    while (["then", "{"].includes(words[0])) words = words.slice(1);
    if (words[0] === "exit") found = true;
    if (k === j && !opens) return found;
    if (words.some((word) => ["}", "fi", "else", "elif", "if", "while", "until", "for", "case"].includes(word)))
      return found;
  }
  return false;
}

// [ -n "$X" ], [[ -z $X ]] or test -n "$X", maybe after if, where a skipped test
// cannot hide: its flag and name. [ and test need "$X" quoted, since an empty X
// leaves [ -n ], which is true.
function testOf(segment: Segment): { flag: string; name: string; inIf: boolean } | undefined {
  if (!["", ";", "\n", "&&"].includes(segment.before)) return undefined;
  const at = segment.marked[0] === "if" ? 1 : 0;
  const words = segment.marked.slice(at);
  const brackets = words.length === 4 && words[0] === "[[" && words[3] === "]]";
  const single =
    (words.length === 4 && words[0] === "[" && words[3] === "]") || (words.length === 3 && words[0] === "test");
  const name = /^\$(?:([A-Za-z_]\w*)|\{([A-Za-z_]\w*)\})$/.exec(words[2] ?? "");
  if (!name || !["-n", "-z"].includes(words[1])) return undefined;
  if (!brackets && !(single && segment.quoted[at + 2])) return undefined;
  return { flag: words[1], name: name[1] ?? name[2], inIf: at === 1 };
}

// [ -n "$X" ] || exit, [ -z "$X" ] && exit, test -n "$X" || { ...; exit; },
// if [ -z "$X" ]; then ...; exit; fi: the name it stops the shell on when empty.
// After &&, only the || form: when what came before fails, its exit still runs.
function checkedName(segments: Segment[], i: number): string | undefined {
  const segment = segments[i];
  const test = testOf(segment);
  if (!test) return undefined;
  const orExit = !test.inIf && test.flag === "-n" && segment.after === "||";
  const stops =
    orExit ||
    (segment.before !== "&&" &&
      (test.inIf
        ? test.flag === "-z" && segments[i + 1]?.words[0] === "then"
        : test.flag === "-z" && segment.after === "&&"));
  return stops && exits(segments, i + 1) ? test.name : undefined;
}

function refersTo(text: string, name: string): boolean {
  return new RegExp(String.raw`\$\{?${name}(?!\w)`).test(text);
}

// Shep's mistake secret-pipe-no-pipefail, twice: op failed or its prompt was dismissed,
// and what it fed still ran, typing or sending an empty password. True when, in this command,
// op's secret goes into a pipe or straight into a command, or a variable that holds
// it is used, or exported, before a check stops the shell when it is empty.
function feedsEmptySecret(command: string): boolean {
  const segments = commandsOf(command);
  // Names that hold op's secret and are not checked yet; true when exported.
  const unchecked = new Map<string, boolean>();
  // Names a [ -n "$X" ] && earlier in this && chain vouches for.
  const guarded = new Set<string>();
  let read = false;
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i];
    if (segment.before !== "&&") guarded.clear();
    read ||= segmentReadsSecret(segment);
    if ((segmentReadsSecret(segment) && segment.after === "|") || readsSecretFrom(segment)) return true;
    // { op read; } | curl: the group's output, op's included, goes into the pipe.
    const closes = segment.words.some((word) => ["}", "done", "fi", "esac"].includes(word) || word.endsWith(")"));
    if (read && closes && segment.after === "|") return true;
    for (const name of unchecked.keys()) if (segment.docs.some((line) => refersTo(line, name))) return true;
    const checked = checkedName(segments, i);
    if (checked) {
      unchecked.delete(checked);
      continue;
    }
    const test = testOf(segment);
    if (test && !test.inIf && test.flag === "-n" && segment.after === "&&") {
      guarded.add(test.name);
      continue;
    }
    // ${X:?} stops the shell on an empty X, unless a pipe, a & or a ( runs it in a subshell.
    const ownShell =
      ["", ";", "\n", "&&"].includes(segment.before) &&
      !["|", "&"].includes(segment.after) &&
      !segment.words[0]?.startsWith("(");
    if (ownShell)
      for (const name of unchecked.keys())
        if (segment.marked.some((word) => word.includes(`\${${name}:?`))) unchecked.delete(name);
    for (const [name, exported] of unchecked) {
      if (guarded.has(name)) continue;
      const named = declares.has(segment.words[0]) && segment.words.includes(name);
      const used = [...segment.marked, ...segment.subs].some((text) => refersTo(text, name));
      if (exported || named || used) return true;
    }
    const readers = segment.subs.flatMap((sub) => commandsOf(sub).filter(segmentReadsSecret));
    if (readers.some(joinsErrors)) return true;
    if (readers.length === 0) continue;
    const assigned = assignedNames(segment);
    if (!assigned) return true;
    for (const name of assigned.names) unchecked.set(name, assigned.exported);
  }
  return false;
}

export function decideBash(command: string, input: GuardInput, depth = 0): GuardDecision {
  if (depth > 4) return block("This command is nested too deep to check. Split it into a simpler command.");
  if (feedsEmptySecret(command)) return block(emptySecret);
  let decision: GuardDecision = mktempInTmp(command, input.tmpdir) ? warn(tmpWrite(input.tmpdir!)) : allow;
  // Each dir the shell may be in; git and forges use it only when there is one.
  let cwds = input.cwds ?? [input.cwd];
  const cwdOf = () => (cwds.length === 1 ? cwds[0] : undefined);
  let gitEnv = input.gitEnv ?? false;
  let gitConfigEnv = input.gitConfigEnv ?? false;
  let branchMoved = input.branchMoved ?? false;
  const segments = segmentsOf(command, `${depth}`);
  // Later-tokenized redirects/heredocs run first; pipe/background peers can change aliases concurrently.
  let graphiteAliases = segments.some(
    (segment) => ["|", "&"].includes(segment.after) || (segment.docs.length && segment.subs.length),
  )
    ? undefined
    : input.graphiteAliases;
  // Where the shell was before each cd after &&: that cd may not have run.
  let skippedCd: (string | undefined)[] = [];
  const vars: TempVars = new Map();
  let straight = true;
  let closed = false;
  for (const segment of segments) {
    // Apply a ) before the next segment, even when it stood alone after a ;.
    // No inner variables or cwd can be borrowed outside it.
    if (closed) {
      cwds = [undefined];
      skippedCd = [];
      straight = false;
      vars.clear();
    }
    // tokenize makes each unquoted ) a word of its own; a quoted one is text.
    closed = segment.words.some((word, i) => word === ")" && !segment.quoted[i]);
    // Past an unclosed $( the rest is unchecked: refused when it could hold
    // something the guard refuses or asks about, else run with a warning.
    if (segment.unclosed) {
      if (refusable(command)) return block(unclosedSub);
      decision = worse(decision, warn(unclosedWarn));
    }
    // export GIT_DIR=... holds for the rest of the command, so it counts from here on.
    if (segment.words.some((word) => gitPlace.test(word))) gitEnv = true;
    if (segment.words.some((word) => gitConfigVar.test(word))) gitConfigEnv = true;
    const envKey = segment.words.flatMap(envConfigKeys).find((key) => riskyConfig.test(key));
    if (envKey) return configBlock(envKey);
    // What ran after && may not have run once that chain ends.
    if (segment.before !== "&&") {
      for (const [name, v] of vars) if (v.chained) vars.delete(name);
      cwds = [...new Set([...cwds, ...skippedCd])];
      skippedCd = [];
    }
    const bare = unparen(segment.marked, segment.quoted);
    // Past a branch, loop, function, || or pipe, no mktemp -d variable holds. A ( subshell
    // runs in a straight line inside, so that holds until its ).
    if (compound.has(bare[0]) || ["||", "|", "&"].includes(segment.before)) {
      straight = false;
      vars.clear();
    }
    const here = { ...input, cwd: cwdOf(), cwds, gitEnv, gitConfigEnv, branchMoved, graphiteAliases, sole: false };
    for (const sub of segment.subs)
      decision = worse(decision, decideBash(sub, { ...here, graphiteAliases: undefined }, depth + 1));
    if (segment.subs.length) here.graphiteAliases = graphiteAliases = undefined;
    const raw = bare.map((word) => expandTemps(word, vars).replaceAll(literalDollar, "$"));
    if (straight) recordTemps(command, segment, raw, vars);
    // A substitution's output is not in raw and could add arguments that change help into a write.
    const staticArgs =
      !command.includes("\\") && !segment.quoted.some(Boolean) && raw.every((word) => staticArg.test(word));
    const help = depth === 0 && staticArgs && segment.subs.length === 0 && cliHelp(raw, graphiteAliases);
    // Only these bare reads and directory changes leave Graphite's alias proof intact.
    const bareRead =
      staticArgs &&
      raw.length === 2 &&
      basename(raw[0]) === "git" &&
      ["status", "diff", "log", "show"].includes(raw[1]);
    const bareCd =
      staticArgs && raw.length <= 2 && ["cd", "pushd", "popd"].includes(raw[0]) && !raw[1]?.startsWith("-");
    if (!help && !bareRead && !bareCd) graphiteAliases = undefined;
    const words = commandWords(raw);
    if (words.length === 0) continue;
    // Nothing the guard reads differently from bash: no env prefix or wrapper, and git
    // itself, not ./git.
    here.sole =
      raw[0] === "git" &&
      depth === 0 &&
      segments.length === 1 &&
      !segment.subs.length &&
      !segment.docs.length &&
      !segment.unclosed &&
      !segment.quoted.some(Boolean) &&
      command.trim().split(/ +/).join("\0") === raw.join("\0") &&
      raw.every((word) => plainWord.test(word) || hashRefspec.test(word)) &&
      words.length === raw.length;
    // /usr/bin/git is git.
    if (words[0].includes("/")) words[0] = basename(words[0]);
    // A cd in a pipe or in the background may run in a subshell: where the shell is, is unknown.
    const piped = segment.before === "|" || segment.after === "|" || segment.after === "&";
    // A cd after && may not have run once that chain ends.
    if (["cd", "pushd", "popd"].includes(words[0]) && segment.before === "&&") skippedCd.push(...cwds);
    // cd $(pwd): the target is the substitution's output, which words leave out.
    const unseen = piped || segment.subs.length > 0;
    if (words[0] === "cd" || words[0] === "pushd")
      cwds = [...new Set(cwds.map((cwd) => (unseen ? undefined : cdTarget(words, cwd, input.home))))];
    else if (words[0] === "popd") cwds = [undefined];
    const script = shellScript(words);
    if (script) decision = worse(decision, decideBash(script, here, depth + 1));
    // What eval or source sets stays set, and the guard cannot see what that is.
    if (words[0] === "eval" || words[0] === "source" || words[0] === ".") {
      gitEnv = branchMoved = true;
      vars.clear();
    }
    const forge = forgeCall(words, gitEnv || gitConfigEnv ? undefined : here.cwd);
    if (!help && isForgeMerge(forge.words)) return block(prMerge);
    // The words as written go last, so a block names what the agent wrote.
    const valueReading =
      forge.words[0] === "entire" && !pluginCall(forge.words) ? entireValueReading(forge.words) : undefined;
    const readings = [valueReading, forge.words];
    const kinds = readings.map((reading) => reading && entireKind(reading));
    if (kinds[1]) {
      kinds.forEach((kind, i) => {
        if (kind) decision = worse(decision, decideEntire(kind, forge.words, forge.dir, here, readings[i]));
      });
      // It runs them in --repo, which forgeCall left out of forge.dir.
      for (const script of pluginScripts(forge.words))
        decision = worse(decision, decideBash(script, { ...here, cwd: forge.dir, cwds: undefined }, depth + 1));
      const path = entirePath(forge.words);
      if (path.includes("checkout") || path.includes("resume") || forge.words.includes("--checkout"))
        branchMoved = true;
    }
    const publishing = help ? undefined : forgePublish(forge.words);
    const forgePlain = plainWords(forge.words);
    const sync = words[0] === "gh" && forgePlain[1] === "repo" && forgePlain[2] === "sync";
    if ((publishing === "push" || sync) && words.some((word) => word === "-f" || word.startsWith("--force")))
      return forceFor(input);
    if (publishing) {
      if (hasNoVerify("push", words)) return block(noVerify);
      const via = forgePlain.slice(0, words[0] === "gt" ? 2 : 3).join(" ");
      decision = worse(decision, publishing === "commit" ? decideCommit(here) : decidePush([], forge.dir, here, via));
    }
    const refused = sync ? noChange(input.role) : undefined;
    if (refused) decision = worse(decision, refused);
    if (isPolicyTrust(words)) decision = worse(decision, block(trustCommand));
    decision = worse(decision, decideCleanup(words, here));
    if (questionOp(words, "answer")) decision = worse(decision, block(answerCommand));
    if (questionOp(words, "push-approval")) decision = worse(decision, block(pushApprovalCommand));
    if (questionOp(words, "guard-create") || questionOp(words, "guard-claim") || runsGuardAsk(words))
      decision = worse(decision, block(guardAskCommand));
    if (writesTodo(words) && input.role !== "shep") decision = worse(decision, block(basecampWrite));
    if (setsTodoTarget(words) && input.role !== "shep") decision = worse(decision, block(todoTargets));
    if (isLand(words) && input.role !== "shep") decision = worse(decision, block(landCommand));
    decision = worse(decision, decideBasecamp(words, input.role));
    if (fakesInput(words, raw)) decision = worse(decision, block(syntheticInput));
    const targets = writeTargets(words, raw);
    if (input.role === "shep-bg" && targets.some((target) => !stream.test(target) && !readOnlyWrite(target, here)))
      decision = worse(decision, block(backgroundOnly));
    // A protected file's reason, below, wins over this one.
    if (readOnlyRole(input.role) && !targets.every((target) => readOnlyTarget(target, here)))
      decision = worse(decision, block(readOnlyTool));
    if (writesGuardFiles(targets, here)) decision = worse(decision, block(protectedFile));
    if (writesTodoFiles(targets, here)) decision = worse(decision, block(todoFile));
    if (cwds.includes(undefined) && targets.some(relativeTarget)) decision = worse(decision, warn(lostCwd));
    if (writesInTmp(words, raw, targets, input.tmpdir)) decision = worse(decision, warn(tmpWrite(input.tmpdir!)));
    const prCheckout = words[0] === "gh" && forgePlain[1] === "pr" && forgePlain[2] === "checkout";
    const checkoutRefused = prCheckout && !help ? noChange(input.role) : undefined;
    if (checkoutRefused) decision = worse(decision, checkoutRefused);
    if (!help && (words[0] === "gt" || prCheckout)) branchMoved = true;
    if (isGhRelease(forge.words) || isGhApiRelease(forge.words)) {
      decision = worse(decision, decideRelease(forge.dir, here));
    }
    const git = parseGit(words, here.cwd);
    if (git && !help) {
      if (gitEnv || gitConfigEnv) git.dir = undefined;
      decision = worse(decision, decideGit(git, here));
      if (movesBranch(git)) branchMoved = true;
    }
    if (decision.action === "block") return decision;
  }
  return decision;
}

// The path a Pi file tool acts on, as its resolveToCwd reads one: Unicode spaces
// as spaces, a leading @ dropped, ~ and file:// URLs expanded.
function toolPath(path: string, home: string | undefined): string {
  const named = path.replace(/[\u00a0\u2000-\u200a\u202f\u205f\u3000]/g, " ").replace(/^@/, "");
  if (home && (named === "~" || named.startsWith("~/"))) return join(home, named.slice(2));
  try {
    return named.startsWith("file://") ? fileURLToPath(named) : named;
  } catch {
    return named; // Pi's tool throws on it too, and writes nothing.
  }
}

export function decideTool(
  tool: string,
  command: string | undefined,
  input: GuardInput,
  given?: string,
): GuardDecision {
  // read, edit, write, grep, find and ls all take a path; another tool's may not be a string.
  const path = typeof given === "string" ? toolPath(given, input.home) : undefined;
  if (tool === "edit" || tool === "write") {
    if (noChange(input.role) && !(tool === "write" && path && readOnlyWrite(path, input))) return block(readOnlyTool);
    const targets = path ? [path] : [];
    if (writesGuardFiles(targets, input, true)) return block(protectedFile);
    if (writesTodoFiles(targets, input, true)) return block(todoFile);
    if (path && input.tmpdir && inTmp(path, input.tmpdir)) return warn(tmpWrite(input.tmpdir));
  }
  if (tool === "bash") return input.role === "discuss" ? block(discussOnly) : decideBash(command ?? "", input);
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
  /** The checkout's top folder: this worktree. */
  root?: string;
  /** Entire captures sessions in this checkout (git_backend_entire_capture). */
  entire?: boolean;
  prompt: string;
  policy: { push: Policy["push"]; agent_may_release: boolean };
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
    push: json.policy.push === "main" || json.policy.push === "branch" ? json.policy.push : "ask",
    agentMayRelease: json.policy.agent_may_release === true,
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

// A dangling symlink is on disk too: writing through it lands somewhere else.
export function onDisk(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

export function stateDir(): string {
  return join(process.env.XDG_STATE_HOME || join(process.env.HOME ?? "", ".local/state"), "bercail");
}

// URL credentials never reach the log.
export function redact(command: string): string {
  const clean = command.replace(/([a-z][a-z0-9+.-]*:\/\/)[^/\s@]+@/gi, "$1***@");
  return clean.length > 500 ? `${clean.slice(0, 500)}…` : clean;
}

// One line in a log under the state dir.
function appendLog(name: string, command: string, input: GuardInput, fields: Record<string, unknown>): void {
  try {
    const file = join(stateDir(), name);
    mkdirSync(dirname(file), { recursive: true });
    const entry = {
      at: new Date().toISOString(),
      terminal: process.env.HC_TERMINAL_ID ?? "",
      role: input.role || "lead",
      cwd: input.cwd,
      command: redact(command),
      ...fields,
    };
    appendFileSync(file, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
  } catch {
    // The log is for the person's audit; a full disk must not stop the agent.
  }
}

function logApproval(command: string, approved: string[], input: GuardInput): void {
  appendLog("guard-approvals.jsonl", command, input, { approved });
}

// Warnings and refusals share a log, so one seen often becomes evidence for a fix.
function logWarning(
  tool: string,
  command: string,
  kind: "warning" | "refusal" | "handoff",
  reasons: string[],
  input: GuardInput,
) {
  appendLog("guard-warnings.jsonl", command, input, { tool, kind, reasons });
}

// The line a warning adds to the tool's result; the agent repeats it in its report.
const warningLine = (warning: string) => `bercail guard warning: ${warning}`;

// What entire agent-help --json lists as read-only: top-level commands, or a
// command's subcommands. [] when entire is missing or says nothing.
async function entireReadOnly(
  pi: ExtensionAPI,
  command: string,
  cwd: string,
  signal: AbortSignal | undefined,
): Promise<string[]> {
  try {
    const args = ["agent-help", ...(command ? [command] : []), "--json"];
    const result = await pi.exec("entire", args, { timeout: 10000, signal, cwd });
    const json = JSON.parse(result.stdout) as { subcommands?: { name?: unknown; audience?: unknown }[] };
    return (json.subcommands ?? [])
      .filter((sub) => sub.audience === "read-only" && typeof sub.name === "string")
      .map((sub) => sub.name as string);
  } catch {
    return [];
  }
}

// The person's Decisions answer that approves this push, spent on it (bercail shep
// question push-approval claims it under the ledger's lock), or undefined: then it asks.
async function pushApproval(
  pi: ExtensionAPI,
  push: PushRequest,
  signal: AbortSignal | undefined,
): Promise<string | undefined> {
  const args = ["shep", "question", "push-approval", push.dir, push.remote, ...push.refspecs];
  try {
    const result = await pi.exec(process.env.BERCAIL_BIN || "bercail", args, { timeout: 30000, signal });
    const approved = (JSON.parse(result.stdout) as { approved?: unknown }).approved;
    return result.code === 0 && typeof approved === "string" && /^Q[1-9]\d*@[1-9]\d*$/.test(approved)
      ? approved
      : undefined;
  } catch {
    return undefined;
  }
}

/** What the guard looks up while it decides: reads only, in the order the decision asks. */
export type Lookups = {
  branch: (dir: string) => Promise<string>;
  policy: (dir: string) => Promise<Policy>;
  entireHelp: (command: string) => Promise<readonly string[]>;
};

// The decision on a tool call with every lookup it needs made, and the input it was
// made on. Past the lookups it makes, headless refuses. A UI decides the rest on
// worst-case facts, so a rule that refuses still refuses (an unread branch, the
// default policy in an Entire repo, no read-only entire command), and anything else asks.
export async function decideLive(
  tool: string,
  command: string | undefined,
  start: GuardInput,
  path: string | undefined,
  look: Lookups,
): Promise<{ decision: GuardDecision; input: GuardInput }> {
  let input = start;
  let decision = decideTool(tool, command, input, path);
  for (let i = 0; i < 8 && lookup(decision); i++) {
    if (decision.action === "need-branch")
      input = { ...input, branches: { ...input.branches, [decision.dir]: await look.branch(decision.dir) } };
    else if (decision.action === "need-policy")
      input = { ...input, policies: { ...input.policies, [decision.dir]: await look.policy(decision.dir) } };
    else if (decision.action === "need-entire-help") {
      const key = decision.command;
      input = { ...input, entireHelp: { ...input.entireHelp, [key]: await look.entireHelp(key) } };
    }
    decision = decideTool(tool, command, input, path);
  }
  if (lookup(decision) && !input.hasUI) decision = block(tooManyRepos);
  if (lookup(decision)) {
    let worst = input;
    for (let i = 0; i < 64 && lookup(decision); i++) {
      if (decision.action === "need-branch") worst = { ...worst, branches: { ...worst.branches, [decision.dir]: "" } };
      else if (decision.action === "need-policy")
        worst = {
          ...worst,
          policies: { ...worst.policies, [decision.dir]: { ...defaultPolicy, entire: true, repo: decision.dir } },
        };
      else if (decision.action === "need-entire-help")
        worst = { ...worst, entireHelp: { ...worst.entireHelp, [decision.command]: [] } };
      decision = decideTool(tool, command, worst, path);
    }
    if (decision.action !== "block") decision = ask(tooManyReposAsk);
  }
  return { decision, input };
}

// Shep never waits on a confirm (docs/plans/shep-free-guard.md): an ask in its session
// becomes one of these operations, pinned to the objects it acts on, and a model-free
// worker (guard-ask.ts) runs it only on the person's Allow on a Decisions card.

/** What Shep's command asks for, read from its words alone. */
export type GuardOp =
  | { kind: "cleanup"; path: string }
  | { kind: "trail merge"; dir: string; trail: string | null }
  | { kind: "push"; dir: string; remote: string; refspecs: string[] };

/** What it acts on, read from disk, git and entire: the worker runs on these alone. */
export type GuardFacts =
  | { kind: "cleanup"; worktree: string; branch: string | null; head: string }
  | { kind: "trail merge"; checkout: string; trailId: string; change: string; head: string; base: string }
  | { kind: "push"; dir: string; gitDir: string; url: string; refspecs: string[] };

const opWord = (word: string) => plainWord.test(word) || hashRefspec.test(word);

// The one operation a command is, or why it is not one: the whole command is that
// command, after at most one cd DIR &&, in plain words the shell reads as written.
export function guardOperation(command: string, cwd: string | undefined, home: string | undefined): GuardOp | string {
  const segments = segmentsOf(command);
  const plain = segments.every(
    (s) => !s.subs.length && !s.docs.length && !s.unclosed && !s.quoted.some(Boolean) && s.words.every(opWord),
  );
  const flat = segments.flatMap((s, i) => (i ? [segments[i - 1].after, ...s.words] : s.words));
  if (!plain || command.includes("\\") || command.trim().split(/ +/).join("\0") !== flat.join("\0"))
    return "it is not one command in plain words (no quotes, variables, substitutions or redirects)";
  let dir = cwd;
  if (segments.length === 2 && segments[0].after === "&&" && segments[0].words[0] === "cd") {
    if (segments[0].words.length !== 2) return "its cd names no one folder";
    dir = cdTarget(segments[0].words, cwd, home);
  } else if (segments.length !== 1) return "it runs more than one command";
  const words = segments.at(-1)!.words;
  // git follows a symlink before a .., and the guard reads .. as text.
  if ([...segments[0].words, ...words].some((word) => /(^|\/)\.\.(\/|$)/.test(word)))
    return "it names a folder with .., which a symlink can send elsewhere";
  if (dir === undefined || !isAbsolute(dir)) return "the guard cannot tell which folder it runs in";
  if (basename(words[0]) === "bercail" && words[1] === "cleanup") {
    if (words.length !== 3 || words[2].startsWith("-")) return "bercail cleanup takes the one worktree it retires";
    return { kind: "cleanup", path: placeIn(dir, words[2])! };
  }
  if (words[0] === "entire" && words[1] === "trail" && words[2] === "merge") {
    if (words.length > 4 || words[3]?.startsWith("-"))
      return "a trail merge is handed off only as entire trail merge [<trail>]";
    return { kind: "trail merge", dir, trail: words[3] ?? null };
  }
  if (words[0] === "git") {
    let i = 1;
    if (words[1] === "-C") {
      dir = words[2] ? placeIn(dir, words[2]) : undefined;
      i = 3;
    }
    if (dir === undefined) return "its git -C names no one folder";
    const [sub, remote, ...refspecs] = words.slice(i);
    if (sub !== "push" || !remote || !refspecs.length || [remote, ...refspecs].some((w) => w.startsWith("-")))
      return "a push is handed off only as git [-C DIR] push REMOTE REFSPEC..., with no flags";
    if (!remoteName.test(remote)) return "it pushes to a URL, not a remote's name";
    return { kind: "push", dir, remote, refspecs };
  }
  return "it is not a cleanup, a trail merge or a push";
}

/** A read the pinning makes: its stdout without the newline that ends it, or a throw. */
export type Read = (command: string, args: string[], cwd: string) => Promise<string>;

// No GIT_DIR, GIT_CONFIG or the like of the caller's: they would point git elsewhere.
export function cleanEnv(): NodeJS.ProcessEnv {
  return {
    ...Object.fromEntries(
      Object.entries(process.env).filter(
        ([key]) => !gitPlace.test(key) && !gitConfigVar.test(key) && key !== "GIT_ALTERNATE_OBJECT_DIRECTORIES",
      ),
    ),
    GIT_TERMINAL_PROMPT: "0",
  };
}

export const readOut: Read = (command, args, cwd) =>
  new Promise((done, failed) =>
    execFile(
      command,
      args,
      { cwd, env: cleanEnv(), timeout: 30000, maxBuffer: 8 * 1024 * 1024, encoding: "utf8" },
      (error, stdout, stderr) => {
        // Only the newline: a URL that ends in a space is another URL.
        if (!error) return done(stdout.replace(/\n+$/, ""));
        const why = (stderr || error.message).trim().split("\n")[0];
        failed(Object.assign(new Error(`${command} ${args.slice(0, 3).join(" ")}: ${why}`), { code: error.code }));
      },
    ),
  );

// The push URLs a card can show (shep/pi/question-target.ts showable): a path, ssh with
// no password, or http(s) or git:// with no user, and none with a query or a space.
const showableUrl = [
  /^\/[^\s?#]*$/,
  /^file:\/\/\/[^\s?#]*$/,
  /^[\w.-]+@[\w.-]+:[^\s?#]*$/,
  /^(ssh|git\+ssh|ssh\+git):\/\/([\w.-]+@)?[\w.-]+(:\d+)?\/[^\s?#]*$/,
  /^(https?|git):\/\/[\w.-]+(:\d+)?\/[^\s?#@]*$/,
];
const headRef = /^refs\/heads\/[\w./-]+$/;
const objectId = /^([0-9a-f]{40}|[0-9a-f]{64})$/;

function fail(why: string): never {
  throw new Error(why);
}

// The remote's one push URL as git uses it, which git then sends to as written: a
// group, several URLs, one with a credential, or one a url.* rule rewrites again does not
// pin. A local repo is pinned by its real path, so a symlink moved later cannot redirect it.
async function pinUrl(read: Read, dir: string, remote: string): Promise<string> {
  const urls = (await read("git", ["-C", dir, "remote", "get-url", "--push", "--all", "--", remote], dir))
    .split("\n")
    .filter(Boolean);
  if (urls.length !== 1) fail(`${remote} must push to one URL, not ${urls.length}`);
  let url = urls[0];
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f-\u009f]/.test(url) || !showableUrl.some((shape) => shape.test(url)))
    fail(`${remote}'s push URL is not one a card can show: a path, ssh, or https with no credential or query`);
  // git decodes a file:// URL's %-escapes, which a path read here would not.
  if (url.startsWith("file://")) fail(`${remote}'s push URL is a file:// URL; set it to the repo's path`);
  if (url.startsWith("/")) {
    // realpath reads .. as text before it follows a symlink; git follows the symlink first.
    if (/(^|\/)\.\.?(\/|$)/.test(url)) fail(`${remote}'s push URL names a folder with . or ..`);
    try {
      url = realpathSync(url);
    } catch {
      fail(`${remote}'s push URL ${url} is not a repo on this machine`);
    }
  }
  // NUL-separated: a rule's key (its URL) can hold a space or a newline.
  const rules = await read(
    "git",
    ["-C", dir, "config", "--null", "--get-regexp", "^url\\..*\\.(push)?insteadof$"],
    dir,
  ).catch((error) => (error.code === 1 ? "" : Promise.reject(error)));
  for (const entry of rules.split("\0").filter(Boolean))
    if (url.startsWith(entry.slice(entry.indexOf("\n") + 1))) fail(`a url.* rule rewrites ${remote}'s push URL`);
  return url;
}

// Each refspec as <object ID>:<full branch ref>: a source git names, sent to the ref
// git would update. A delete, a glob, a tag, or a ref git would pick from the remote's
// refs or remote.<name>.push (a short destination, or none under that config) does not pin.
async function pinRefspec(read: Read, dir: string, spec: string, mapped: boolean): Promise<string> {
  const parts = spec.split(":");
  if (parts.length > 2 || !parts[0] || spec.includes("*")) fail(`${spec} is not one source to one branch`);
  const [src, dst] = parts;
  const git = (...args: string[]) => read("git", ["-C", dir, ...args], dir);
  const full =
    src === "HEAD"
      ? await git("symbolic-ref", "-q", "HEAD").catch(() => "")
      : await git("rev-parse", "--symbolic-full-name", src).catch(() => "");
  // The commit of the ref it names, so the card's ref and commit are one reading.
  const oid = await git("rev-parse", "--verify", "--end-of-options", `${full || src}^{commit}`).catch(() =>
    fail(`${src} is not a commit in ${dir}`),
  );
  if (dst !== undefined && !dst.startsWith("refs/"))
    fail(`${spec} names its destination short, which git matches against the remote's refs; write refs/heads/${dst}`);
  if (dst === undefined && mapped)
    fail(`remote.<name>.push decides where ${spec} goes; write it as ${spec}:refs/heads/<branch>`);
  const ref = dst ?? full;
  if (!headRef.test(ref)) fail(`${spec} does not push to a branch the guard can name (refs/heads/<branch>)`);
  if (!objectId.test(oid)) fail(`${src} did not resolve to one commit`);
  return `${oid}:${ref}`;
}

// The change a trail merge acts on, read where Shep named it (a bare merge is the
// branch's), and the repo's main checkout, where the worker merges it.
async function pinTrail(read: Read, dir: string, trail: string | null) {
  const here = realpathSync(await read("git", ["-C", dir, "rev-parse", "--show-toplevel"], dir));
  const worktrees = await read("git", ["-C", here, "worktree", "list", "--porcelain"], here);
  const checkout = realpathSync(worktrees.split("\n")[0].slice("worktree ".length));
  const args = ["trail", "show", ...(trail ? [trail] : []), "--json"];
  let shown;
  try {
    shown = JSON.parse(await read(process.env.ENTIRE_BIN || "entire", args, here));
  } catch (error) {
    fail(`entire trail show failed: ${(error as Error).message} (trails need the network and Entire's login)`);
  }
  const changes = Array.isArray(shown?.changes) ? shown.changes : [];
  // A project trail's one open change; through a change or the branch, that change.
  const named = trail === null || trail.includes("/");
  const open = changes.filter((c: { status?: unknown }) => c?.status === "open");
  const change = named ? changes.find((c: { current?: unknown }) => c?.current === true) : open[0];
  if (!named && open.length !== 1) fail(`the trail has ${open.length} open changes; name one as <repo>/<number>`);
  const head = change?.mergeability?.head_sha;
  if (
    typeof shown?.id !== "string" ||
    !shown.id ||
    change?.status !== "open" ||
    typeof change.repository !== "string" ||
    !/^[\w.-]+$/.test(change.repository) ||
    !Number.isSafeInteger(change.number) ||
    typeof head !== "string" ||
    !objectId.test(head) ||
    typeof change.base !== "string" ||
    !change.base
  )
    fail("entire trail show names no one open change with a head and a base");
  return {
    kind: "trail merge" as const,
    checkout,
    trailId: shown.id,
    change: `${change.repository}/${change.number}`,
    head,
    base: change.base,
  };
}

// The objects an operation acts on now. It throws when they cannot be pinned.
export async function pinOperation(op: GuardOp, read: Read = readOut): Promise<GuardFacts> {
  if (op.kind === "trail merge") return pinTrail(read, op.dir, op.trail);
  if (op.kind === "cleanup") {
    const worktree = realpathSync(op.path);
    const git = (...args: string[]) => read("git", ["-C", worktree, ...args], worktree);
    if (realpathSync(await git("rev-parse", "--show-toplevel")) !== worktree)
      fail(`${op.path} is inside a worktree; name the worktree itself`);
    const branch = await git("symbolic-ref", "-q", "HEAD").catch(() => null);
    return { kind: "cleanup", worktree, branch, head: await git("rev-parse", "--verify", "HEAD^{commit}") };
  }
  const dir = realpathSync(await read("git", ["-C", op.dir, "rev-parse", "--show-toplevel"], op.dir));
  const gitDir = realpathSync(await read("git", ["-C", dir, "rev-parse", "--absolute-git-dir"], dir));
  const mapped = await read("git", ["-C", dir, "config", "--get-all", `remote.${op.remote}.push`], dir).then(
    (out) => out !== "",
    (error) => (error.code === 1 ? false : Promise.reject(error)),
  );
  const refspecs: string[] = [];
  for (const spec of op.refspecs) refspecs.push(await pinRefspec(read, dir, spec, mapped));
  if (new Set(refspecs.map((spec) => spec.split(":")[1])).size !== refspecs.length)
    fail("it pushes to the same branch twice");
  return { kind: "push", dir, gitDir, url: await pinUrl(read, dir, op.remote), refspecs };
}

// The fixed argv the worker runs, and where: never the text Shep wrote. A push goes
// to the pinned URL with no tags or submodules a config could add, each commit as
// <hash>^{commit}, which no ref named like the hash can shadow.
export function runOf(facts: GuardFacts): { argv: string[]; cwd: string } {
  if (facts.kind === "cleanup")
    return { argv: [process.env.BERCAIL_BIN || "bercail", "cleanup", facts.worktree], cwd: "/" };
  if (facts.kind === "trail merge")
    return { argv: [process.env.ENTIRE_BIN || "entire", "trail", "merge", facts.change], cwd: facts.checkout };
  return {
    argv: [
      "git",
      "-C",
      facts.dir,
      "push",
      "--no-follow-tags",
      "--recurse-submodules=no",
      facts.url,
      ...facts.refspecs.map((spec) => spec.replace(":", "^{commit}:")),
    ],
    cwd: facts.dir,
  };
}

// Which pinned facts differ between two pinnings of one operation.
export function changedFacts(was: Record<string, unknown>, now: Record<string, unknown>): string[] {
  const keys = [...new Set([...Object.keys(was), ...Object.keys(now)])];
  return keys.filter((key) => JSON.stringify(was[key]) !== JSON.stringify(now[key])).map((key) => `${key} changed`);
}

/** A handed-off ask, under guard-asks/ (0600): what the worker runs, and for whom. */
export type GuardTicket = {
  v: 1;
  id: string;
  at: string;
  /** One hour on: a pick after it is refused, and the card counts as a Deny. */
  expires: string;
  command: string;
  cwd: string;
  reason: string;
  op: GuardOp;
  facts: GuardFacts;
  shep: { terminal: string; session: string };
};

export const guardAsks = () => join(stateDir(), "guard-asks");
export const ticketId = /^[0-9a-f]{12}$/;
const expiry = 3600 * 1000;

// The ticket's one start state, written once: the worker's "started" or the guard's
// "void", whichever comes first. link() fails when the other already wrote it.
export function markStart(id: string, value: "started" | "void"): string {
  const file = join(guardAsks(), `${id}.state`);
  const temp = `${file}.${process.pid}.${value}`;
  writeFileSync(temp, value, { mode: 0o600 });
  try {
    linkSync(temp, file);
    return value;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    return readFileSync(file, "utf8");
  } finally {
    rmSync(temp, { force: true });
  }
}

// A new ticket, mode 0600, never over another; it expires an hour from now.
export function writeTicket(fields: Omit<GuardTicket, "v" | "id" | "at" | "expires">): GuardTicket {
  const id = randomBytes(6).toString("hex");
  const at = new Date();
  const ticket: GuardTicket = {
    v: 1,
    id,
    at: at.toISOString(),
    expires: new Date(at.getTime() + expiry).toISOString(),
    ...fields,
  };
  mkdirSync(guardAsks(), { recursive: true, mode: 0o700 });
  writeFileSync(join(guardAsks(), `${id}.json`), `${JSON.stringify(ticket)}\n`, { mode: 0o600, flag: "wx" });
  return ticket;
}

// Shep's ask, handed to a worker: the ticket, hc run, and the start handshake. The
// reason Shep reads: handed off, or refused with what to do instead.
async function handOff(
  pi: ExtensionAPI,
  command: string,
  input: GuardInput,
  asked: string,
  session: string,
  signal: AbortSignal | undefined,
): Promise<{ handed: boolean; reason: string }> {
  const refused = (why: string) => ({
    handed: false,
    reason: `${asked} Shep's session never waits on a confirm, and this could not go to a Decisions card: ${why}. Run a cleanup, a trail merge or a push as a command of its own (cd DIR && entire trail merge [<trail>], git -C DIR push REMOTE BRANCH), or leave it to the person.`,
  });
  const op = guardOperation(command, input.cwd, input.home);
  if (typeof op === "string") return refused(op);
  let facts: GuardFacts;
  try {
    facts = await pinOperation(op);
  } catch (error) {
    return refused((error as Error).message);
  }
  const wait = Number(process.env.BERCAIL_GUARD_ASK_WAIT_MS) || 10000;
  const start = Date.now();
  let id: string;
  try {
    ({ id } = writeTicket({
      command,
      cwd: input.cwd!,
      reason: asked,
      op,
      facts,
      shep: { terminal: process.env.HC_TERMINAL_ID ?? "", session },
    }));
  } catch (error) {
    return refused(`the guard could not write its ticket: ${(error as Error).message}`);
  }
  const worker = `guard-ask-${id}`;
  const bin = process.env.BERCAIL_BIN || "bercail";
  // hc runs it from the Herdr server, so only this env prefix reaches it.
  const env = [
    "BERCAIL_ROLE=shep",
    `XDG_STATE_HOME=${dirname(stateDir())}`,
    ...["BERCAIL_BIN", "ENTIRE_BIN"].flatMap((key) => (process.env[key] ? [`${key}=${process.env[key]}`] : [])),
  ];
  let why = `${worker} did not start within ${Math.round(wait / 1000)} s`;
  try {
    const args = ["run", "--bg", "--name", worker, "--cwd", guardAsks(), "--outlive-parent", "--no-notify", "--rm"];
    const started = await pi.exec("hc", [...args, "--", "env", ...env, bin, "guard", "ask", id], {
      timeout: wait,
      signal,
    });
    if (started.code !== 0)
      why = `hc could not start ${worker}: ${started.stderr.trim().split("\n")[0] || `exit ${started.code}`}`;
    else
      while (Date.now() - start < wait && !onDisk(join(guardAsks(), `${id}.state`)))
        await new Promise((done) => setTimeout(done, 100));
  } catch (error) {
    why = `hc could not start ${worker}: ${(error as Error).message}`;
  }
  // A worker that starts after this makes no card.
  let state: string;
  try {
    state = markStart(id, "void");
  } catch (error) {
    return refused(`${why}, and the guard could not void its ticket: ${(error as Error).message}`);
  }
  if (state !== "started") return refused(why);
  return {
    handed: true,
    reason: `Handed off, not run: the person answers this ${op.kind} of ${opTarget(facts)} on a Decisions card, and the worker ${worker} runs it only on their Allow, within the hour. Tell the person in one line that the card is up. Do not retry it, wait for it or run it another way; your turn goes on. Its outcome comes back as a guard event; report it then.`,
  };
}

// The operation in a few words, and what it acts on, for the card and the event.
export function opTarget(facts: GuardFacts): string {
  if (facts.kind === "cleanup") return facts.worktree;
  if (facts.kind === "trail merge") return facts.change;
  return `${facts.url} ${facts.refspecs.map((spec) => spec.split(":")[1]).join(" ")}`;
}

const policySection = "bercail_git_policy";

export default function (pi: ExtensionAPI) {
  const home = process.env.HOME;
  const config =
    process.env.BERCAIL_CONFIG ||
    join(process.env.XDG_CONFIG_HOME || join(home ?? "", ".config"), "bercail/config.toml");
  const protectedFiles = [
    join(stateDir(), "policy-trust.json"),
    // Shep's question ledger: an answered question in it is the person's pick.
    join(stateDir(), "shep/questions.json"),
    join(stateDir(), "shep/questions.lock"),
    config,
  ];
  // Shep's state: its ledger, inbox and sessions; and the guard's tickets for Shep's asks.
  const protectedDirs = [join(stateDir(), "shep"), guardAsks()];
  // Not one of the guard's: a target decides where Shep writes, not what runs.
  const todoFiles = [join(dirname(config), "todo.json")];

  // The policy of the folder the agent started in, once a lookup works. No abort
  // signal, and a failed lookup is not kept: either would leave the session
  // without its checkout's root.
  let startLookup: { cwd: string; json: PolicyJson } | undefined;
  const startJson = async (cwd: string) => {
    if (startLookup?.cwd === cwd) return startLookup.json;
    const json = await policyJson(pi, cwd, undefined);
    if (json) startLookup = { cwd, json };
    return json;
  };

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

  // entire agent-help's read-only lists, read once a session; warnings by tool call.
  const entireHelp: Record<string, string[]> = {};
  const warned = new Map<string, string[]>();
  // Tool calls that were the only one in their assistant message: Pi checks every call of
  // a message before it runs any, then runs them together.
  const alone = new Set<string>();
  pi.on("message_end", async (event) => {
    const { message } = event as { message: { role?: string; content?: unknown } };
    const calls = Array.isArray(message.content)
      ? message.content.filter((part: { type?: string; id?: string }) => part?.type === "toolCall")
      : [];
    if (message.role === "assistant" && calls.length === 1) alone.add(calls[0].id);
  });

  pi.on("tool_call", async (event, ctx) => {
    const input = event.input as { command?: string; path?: string };
    const command = event.toolName === "bash" ? String(input.command ?? "") : undefined;
    const json = await startJson(ctx.cwd);
    let guardInput: GuardInput = {
      role: process.env.BERCAIL_ROLE ?? "",
      hasUI: ctx.hasUI,
      cwd: ctx.cwd,
      home,
      protectedFiles,
      protectedDirs,
      todoFiles,
      graphiteAliases: event.toolName === "bash" ? readGraphiteAliases() : undefined,
      readOnlyWrites: {
        tmp: ["/tmp", process.env.TMPDIR ?? ""].filter((dir) => dir && resolve(dir) !== "/"),
        root: json?.root ?? ctx.cwd,
        exists: onDisk,
      },
      tmpdir: process.env.TMPDIR && resolve(process.env.TMPDIR) !== "/tmp" ? process.env.TMPDIR : undefined,
      // Not a call another tool made. No GIT_DIR of Shep's own, which bash would inherit and
      // the helper drops, nor GIT_CONFIG, which only git config reads, so the helper's
      // checks read what git push will.
      alone:
        alone.delete(event.toolCallId) &&
        !(event as { parentToolCallId?: string }).parentToolCallId &&
        !Object.keys(process.env).some((key) => gitPlace.test(key) || key === "GIT_CONFIG"),
    };
    const live = await decideLive(event.toolName, command, guardInput, input.path, {
      branch: (dir) => branchAt(pi, dir, ctx.signal),
      policy: async (dir) => policyFromJson(await policyJson(pi, dir, ctx.signal)),
      entireHelp: async (key) => (entireHelp[key] ??= await entireReadOnly(pi, key, ctx.cwd, ctx.signal)),
    });
    let decision = live.decision;
    guardInput = live.input;
    // A push it would ask about that the person's Decisions answer approves: the answer
    // is spent on it, and it runs with a warning naming the answer. None: it asks.
    if (decision.action === "ask" && decision.push) {
      const token = await pushApproval(pi, decision.push, ctx.signal);
      if (token) decision = { action: "allow", warnings: [...(decision.warnings ?? []), pushApproved(token)] };
    }
    const logged = command ?? input.path ?? "";
    // Shep never waits on a confirm: an ask goes to a worker, or is refused.
    if (decision.action === "ask" && guardInput.role === "shep") {
      const session = (ctx as { sessionManager?: { getSessionId?: () => string } }).sessionManager?.getSessionId?.();
      const handed = await handOff(pi, logged, guardInput, decision.reason, session || "unknown", ctx.signal);
      logWarning(event.toolName, logged, handed.handed ? "handoff" : "refusal", [handed.reason], guardInput);
      return { block: true, reason: handed.reason };
    }
    const refuse = (reason: string) => {
      logWarning(event.toolName, logged, "refusal", [reason], guardInput);
      return { block: true, reason };
    };
    if (decision.action === "ask") {
      if (!ctx.hasUI) return refuse(headless);
      if (!(await ctx.ui.confirm("Allow this command?", decision.reason)))
        return refuse(`The person said no to: ${decision.reason} Leave it for them.`);
    } else if (decision.action === "allow") {
      if (decision.approved?.length) logApproval(logged, decision.approved, guardInput);
    } else if (decision.action === "block") {
      return refuse(decision.reason);
    }
    const warnings = "warnings" in decision ? (decision.warnings ?? []) : [];
    if (warnings.length) {
      logWarning(event.toolName, logged, "warning", warnings, guardInput);
      warned.set(event.toolCallId, warnings);
    }
  });

  // A warning goes at the top of the tool's result, where the agent reads it.
  pi.on("tool_result", async (event) => {
    const warnings = warned.get(event.toolCallId);
    if (!warnings) return;
    warned.delete(event.toolCallId);
    const text = warnings.map(warningLine).join("\n");
    return {
      content: [{ type: "text" as const, text }, ...event.content],
      ...(event.structuredContent === undefined ? {} : { structuredContent: event.structuredContent }),
    };
  });
}
