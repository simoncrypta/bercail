// bercail's Pi guard. The decision functions are pure; the default export wires
// tool_call and tool_result, the repo's git policy (bercail policy show), the
// approval log, and the log of warnings and refusals.
import { execFile } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import {
  accessSync,
  constants as fsConstants,
  appendFileSync,
  linkSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
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

/** A repo's desk secret (lib/desk-secret.sh): its token file, and the worktree the agent works in. */
export type DeskSecret = { file: string; root: string };

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
  /** For the rest of the command the guard cannot vouch for cwds: they outgrew its count, or
   *  a function was defined, whose body may cd anywhere. Unlike a dir it lost, a relative
   *  write is declined for a read-only role; the known dirs are still checked. */
  cwdsCapped?: boolean;
  /** cwds outgrew the guard's count, which dropped the known ones: a relative write is
   *  refused for every role, for the rest of the command. */
  cwdsOverflowed?: boolean;
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
  /** The repo has a desk secret: the guard keeps its file, the token and the vault out of sight. */
  deskSecret?: DeskSecret;
  /** Within one command: this text runs in a $( ), so what it prints is captured, not shown. */
  captured?: boolean;
  /** Where a read-only role's write tool may write: the temp dirs, and new files under ROOT/.bercail/. */
  readOnlyWrites?: { tmp: string[]; root: string; exists: (path: string) => boolean };
  /** The agent's own TMPDIR, when it is not /tmp: a write under a literal /tmp then warns. */
  tmpdir?: string;
  /** The whole command is this one plain command: no other part, substitution or quoting. */
  sole?: boolean;
  /** The only tool call its assistant message made, so no other call of the session runs beside it. */
  alone?: boolean;
  /** A desk's worktree and the branch its handoff record names, when that is not the trunk.
   * mapped: git config may send a refspec with no :dst to another branch. */
  deskBranch?: { path: string; branch: string; mapped: boolean };
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
const leaseShape =
  "Force-push is blocked. Shep's one force push is a desk's restack, which goes to a guard card only as git -C <worktree> push --force-with-lease=refs/heads/<branch>:<old head> <remote> <new head>:refs/heads/<branch>, both heads as full hashes, with no other flag.";
const forceFor = (input: GuardInput) =>
  block(input.role === "autopilot" ? autopilotForce : input.role === "shep" ? leaseShape : force);
const plusRef = "A refspec starting with + is a force-push. Push the branch without +.";
const leaseToMain = "A force push to main or master is blocked, lease or not.";
const leaseAsk = ({ remote, spec, lease }: Restack) =>
  `Allow this force-with-lease push to ${remote}: ${spec.split(":")[0]} as ${lease.ref}, replacing ${lease.old}? It fails if ${lease.ref} there is no longer ${lease.old}. No keeps it local for the person.`;
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
const routineAsk = "A request about a routine is the person's, sent from the Routines panel. Leave it to them.";
const configEditRefused =
  "config.toml is the person's: only Shep changes it, on a Decisions card they answer. Say in your report what should change (bercail config set <section> <key> <value>, or bercail routine enable <name>), and Shep asks.";
const configEditAsk = "Change your config.toml? The card shows each line it adds or removes.";
const syntheticInput =
  "Typing or clicking for the person (wtype, ydotool, xdotool, /dev/uinput, hyprctl's key dispatchers) is blocked: it could answer for them.";
const discussOnly =
  "A Discuss branch is for talking a question over: it runs no commands and changes nothing. Say what you would do instead.";
const staleGuard =
  "bercail's guard changed on disk after this Pi loaded it (bercail update or an install), so the rules it runs are not the installed ones. Nothing runs until Pi reloads it, which it does once this turn ends; then it tells you, and you run this again if it still fits the task.";
const staleGuardHeadless =
  "bercail's guard changed on disk after this headless run loaded it (bercail update or an install), so the rules it runs are not the installed ones, and nothing runs. Stop and report that; a new run gets the installed guard.";
const guardGone =
  "bercail's guard cannot read its own file, so it cannot tell whether bercail update replaced it, and nothing runs. Tell the person: once bercail is installed again, restart this Pi.";
const guardBroken =
  "bercail's guard changed on disk after this Pi loaded it, and the new one does not load, so Pi keeps the old one and nothing runs. Tell the person: reinstall bercail; the guard reloads once its file loads.";
const guardLost =
  "bercail's guard changed on disk and Pi did not load the new one, so Pi exits rather than run without a guard. Reinstall bercail, then start this Pi again: its session is kept.";
const guardReloaded =
  "bercail's guard reloaded from disk with the installed rules: Pi reloaded every extension and kept this session. Run again what the old guard held back, if it still fits the task.";
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
const cleanupGoneAsk =
  "Record this gone checkout as retired? bercail cleanup --gone removes nothing: it notes in retired.jsonl that the checkout went with nothing lost, so its job's next dispatch starts a new desk.";
const cleanupHeadless =
  "bercail cleanup removes a worktree, so it runs only where the person can say yes. Leave it to Shep or the person.";
const spaceCloseAsk = "Close this Herdr space? It ends every terminal in it.";
const spaceCloseHeadless =
  "Closing a Herdr space ends its terminals, so it runs only where the person can say yes. Leave it to Shep or the person.";
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
const secretFile =
  "This repo's desk secret is for bercail's op shim alone. Run op, which reads it for you; do not read, copy or decrypt the file.";
const printsToken =
  "In a repo with a desk secret, printing the environment or OP_SERVICE_ACCOUNT_TOKEN is blocked. Name the variable you need (printenv HOME), or run op.";
const vaultShown =
  'In a repo with a desk secret, listing the vault or printing a secret is blocked. Read the one field you need into a variable and check it: pw="$(op read \'op://…\')"; : "${pw:?op read failed}". Or write it with -o to a file outside the worktree.';
const basecampWrite =
  "Writing to Basecamp, or to the person's todos, is Shep's. When the person has to do something themselves, put it in your report as Todo: \"<text>\", and Shep adds it. Reads still work: basecamp todos list, show, search.";
const basecampAuth =
  "Logging Basecamp in or out (auth, login, logout, setup, profile create or delete), and its token, are the person's. They run basecamp auth login --device-code in their own shell.";
const todoTargets =
  "Where the person's todos go (bercail todo target add|rm, bercail todo route) is Shep's. Say in your report which list a todo belongs on, and Shep sets it.";
const deskAnswerRefused =
  "Answering a desk's guard prompt is Shep's (bercail desk answer), or the person's at the desk. Leave it to them.";
const deskAnswerAsk = "Answer Yes to a desk's guard prompt? The card shows what the desk asked to run.";
const deskAnswerShape =
  "bercail desk answer runs only alone, as bercail desk answer DESK no --prompt ID --reason TEXT, DESK yes --prompt ID, or either with a last --dry-run.";
const deskAnswerNo =
  "You answered No to a desk's guard prompt for the person: say in your report which desk, what it asked, and why.";
const landCommand =
  "Landing a change (bercail land) is Shep's. Stage it, finish with /validate, and Shep lands it once it is reviewed.";
const todoFile =
  "Todo targets and routes change only through bercail todo target and bercail todo route, which read the list before they keep it. Shep runs them.";
const basecampFlags =
  "Put basecamp's flags after its command and action (basecamp todos list --in 1), so the guard can tell what it runs.";
const unclosedSub =
  "The guard could not read this command to its end: a $( or backtick it could not close, or a case it could not parse. Write the body to a file first, then pass its path.";
const unclosedWarn =
  "The guard could not read a $( or backtick, or a case, to its end, so it did not check the rest of this command. Next time, write the body to a file first, then pass its path.";
const tooManyCwds =
  "The guard lost track of the folder (more cds than it follows), so it cannot place a relative path. Write the target as an absolute path.";
const lostCwd =
  "The guard lost track of the folder after a cd it could not follow, so it checked a relative write target by its name only.";
const pushApproved = (token: string) =>
  `Allowed this push without asking: the person's Decisions answer ${token} approves it, once. Say so in your report.`;
const pushApprovalCommand =
  "Which Decisions answer approves a push is the guard's to check and spend. Push, and the guard checks.";
const guardAskCommand =
  "A guard card and its worker are the guard's: it starts them when Shep runs a command it would ask about. Run the command, and the guard hands it off.";
const landWorker =
  "A land card is bercail's to put up, and its chain (bercail land run and the ledger's land steps) runs only on the person's pick on the panel. No agent runs them, Shep included.";
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

type Heredoc = { delim: string; strip: boolean; quoted: boolean };

// The heredoc a << at i opens, and where its delimiter word ends. A <<< is a here-string.
function heredocAt(text: string, i: number): (Heredoc & { end: number }) | undefined {
  const op = text[i] === "<" ? redirectAt(text, i) : undefined;
  if (op?.op !== "<<") return undefined;
  let j = op.end;
  const strip = text[j] === "-";
  if (strip) j++;
  j = blanksEnd(text, j);
  let delim = "";
  let quoted = false;
  while (j < text.length && !" \t\n;|&<>()".includes(text[j])) {
    const ch = text[j];
    if (ch === "'" || ch === '"') {
      quoted = true;
      const end = text.indexOf(ch, j + 1);
      if (end < 0) {
        j = text.length;
        break;
      }
      delim += text.slice(j + 1, end);
      j = end + 1;
      continue;
    }
    if (ch === "\\") {
      quoted = true;
      delim += text[j + 1] ?? "";
      j += 2;
      continue;
    }
    delim += ch;
    j++;
  }
  return delim ? { delim, strip, quoted, end: j } : undefined;
}

// Past the blanks and backslash-newlines at i, never a real newline.
function blanksEnd(text: string, i: number): number {
  while (text[i] === " " || text[i] === "\t" || (text[i] === "\\" && text[i + 1] === "\n"))
    i += text[i] === "\\" ? 2 : 1;
  return i;
}

// A heredoc's body from the line start at i: its lines, and where the line after
// its delimiter starts.
function heredocBody(text: string, i: number, doc: Heredoc): { lines: string[]; end: number } {
  const lines: string[] = [];
  while (i < text.length) {
    let end = text.indexOf("\n", i);
    if (end < 0) end = text.length;
    const line = text.slice(i, end);
    i = end + 1;
    if ((doc.strip ? line.replace(/^\t+/, "") : line) === doc.delim) break;
    lines.push(line);
  }
  return { lines, end: i };
}

// Where a string that ends at an unescaped quote closes: a backtick's, or $'...''s
// from its first character. -1 when it never does.
function escapedEnd(text: string, i: number, quote: string): number {
  while (i < text.length) {
    if (text[i] === "\\") i += 2;
    else if (text[i] === quote) return i + 1;
    else i++;
  }
  return -1;
}

// Characters that end a word, so what follows starts one.
const wordBreak = " \t\n;&|()<>";
const keyword = /[A-Za-z!{]+/y;

// The body of the ( at open and where it ends, as bash finds its ): past quotes,
// $'...', backslashes, # comments, heredoc bodies, nested ( ), "$( )" and backticks,
// and a case's pattern ). One pass, so a $( that never closes costs one scan.
function readBalanced(text: string, open: number): { body: string; end: number } | undefined {
  // One frame per open ( or "; cases: the case commands open in a ( frame.
  const frames: { quote: boolean; cases: number }[] = [{ quote: false, cases: 0 }];
  const docs: Heredoc[] = [];
  let command = true;
  // At a word's start: set as characters are read, so an escaped blank stays in its word.
  let start = true;
  let i = open + 1;
  while (i < text.length) {
    const c = text[i];
    const frame = frames[frames.length - 1];
    if (c === "\\") {
      if (text[i + 1] !== "\n") start = false;
      i += 2;
      continue;
    }
    if (c === "`") {
      i = escapedEnd(text, i + 1, "`");
      if (i < 0) return undefined;
      start = false;
      continue;
    }
    if (frame.quote) {
      start = c === "$" && text[i + 1] === "(";
      if (c === '"') frames.pop();
      else if (start) {
        frames.push({ quote: false, cases: 0 });
        command = true;
        i++;
      }
      i++;
      continue;
    }
    if (c === "#" && start) {
      const end = text.indexOf("\n", i);
      i = end < 0 ? text.length : end;
      continue;
    }
    if (c === "'" || (c === "$" && text[i + 1] === "'")) {
      i = c === "'" ? text.indexOf("'", i + 1) + 1 : escapedEnd(text, i + 2, "'");
      if (i <= 0) return undefined;
      command = start = false;
      continue;
    }
    if (c === '"') {
      frames.push({ quote: true, cases: 0 });
      command = start = false;
      i++;
      continue;
    }
    const doc = heredocAt(text, i);
    if (doc) {
      docs.push(doc);
      i = doc.end;
      start = false;
      continue;
    }
    if (c === "\n" && docs.length) {
      i++;
      for (const open of docs.splice(0)) i = heredocBody(text, i, open).end;
      command = start = true;
      continue;
    }
    if (c === "(") frames.push({ quote: false, cases: 0 });
    else if (c === ")" && !frame.cases) {
      frames.pop();
      if (!frames.length) return { body: text.slice(open + 1, i), end: i + 1 };
    } else if (start && !wordBreak.includes(c)) {
      keyword.lastIndex = i;
      const word = keyword.exec(text)?.[0] ?? "";
      const whole = word !== "" && (i + word.length === text.length || wordBreak.includes(text[i + word.length]));
      if (command && whole && word === "case") frame.cases++;
      if (command && whole && word === "esac" && frame.cases) frame.cases--;
      command = whole && shellPrefixes.has(word);
    }
    // After ( or ;, and after a case pattern's ), a command starts.
    if ("();&|\n".includes(c)) command = c !== ")" || frame.cases > 0;
    start = wordBreak.includes(c);
    i++;
  }
  return undefined;
}

// The $( ) and backtick bodies in an unquoted heredoc's body, which still run.
// unclosed: one that never closes; the rest is not read.
function subsIn(text: string): { subs: string[]; unclosed: boolean } {
  const subs: string[] = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\") i++;
    else if (text[i] === "$" && text[i + 1] === "(") {
      const inner = readBalanced(text, i + 1);
      if (!inner) return { subs, unclosed: true };
      subs.push(inner.body);
      i = inner.end - 1;
    } else if (text[i] === "`") {
      const end = escapedEnd(text, i + 1, "`");
      if (end < 0) return { subs, unclosed: true };
      subs.push(text.slice(i + 1, end - 1));
      i = end - 1;
    }
  }
  return { subs, unclosed: false };
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

// A redirect: 2>&1 is fd 2, op >&, target 1. The target is in marked form, and
// undefined when there is none or the guard cannot read it as one word (>$(x)); text
// keeps its literal parts all the same ("$PW" of >"$PW$(date)").
type Redirect = { fd: string; op: string; target: string | undefined; text: string };

// A shell word, a redirect, an operator that ends a command, a substitution's body
// ($( ), backtick, <( ) or >( ); output: a >( ), whose output is the command's), a line
// of an unquoted heredoc, or a substitution the guard cannot find the end of.
type Token =
  | { kind: "op"; op: string }
  | { kind: "word"; value: string; quoted: boolean; literal: boolean }
  | ({ kind: "redirect" } & Redirect)
  | { kind: "sub"; value: string; output?: boolean }
  | { kind: "doc"; value: string }
  | { kind: "unclosed" };

const redirectOps = ["&>>", "&>", "<<<", "<<", "<>", "<&", "<", ">>", ">|", ">&", ">"];
// A redirect's fd, glued on, unquoted and unescaped: 2>&1, {fd}>x.
const redirectFd = /^(?:\d+|\{[A-Za-z_]\w*\})$/;
// The escapes of $'...' the guard decodes; it keeps any other as written.
const ansiEscapes: Record<string, string> = { "\\": "\\", "'": "'", '"': '"', n: "\n", t: "\t" };

// The redirect operator at i and where it ends, past the backslash-newlines bash
// drops before it reads >&2, 2>&1 or &>file. A <( or >( is a process substitution.
function redirectAt(command: string, i: number): { op: string; end: number } | undefined {
  if ("<>".includes(command[i]) && command[i + 1] === "(") return undefined;
  let text = "";
  const ends: number[] = [];
  let j = i;
  while (text.length < 3) {
    while (j > i && command[j] === "\\" && command[j + 1] === "\n") j += 2;
    if (j >= command.length || !"<>&|".includes(command[j])) break;
    text += command[j++];
    ends.push(j);
  }
  const op = redirectOps.find((candidate) => text.startsWith(candidate));
  return op ? { op, end: ends[op.length - 1] } : undefined;
}

// tag keeps the mktemp -d dirs of nested commands apart.
function tokenize(command: string, tag = ""): Token[] {
  const tokens: Token[] = [];
  let temps = 0;
  const tempDir = () => `${tempPrefix}${tag}.${temps++}`;
  // Heredocs opened on the current line; their bodies start after its newline.
  const heredocs: Heredoc[] = [];
  let i = 0;
  // The fd glued before the redirect at i.
  let fd = "";
  // Where the last sub token read from the top ended: a # there is in its word.
  let glued = -1;
  // The $( ), backtick, <( ) or >( ) that opens at j: its body and end (-1 when it
  // never closes); undefined when none opens there.
  const scanSub = (j: number): { body: string; end: number; output: boolean } | undefined => {
    const c = command[j];
    if (c === "`") {
      const end = escapedEnd(command, j + 1, "`");
      return { body: end < 0 ? "" : command.slice(j + 1, end - 1), end, output: false };
    }
    if (!"$<>".includes(c) || command[j + 1] !== "(") return undefined;
    const inner = readBalanced(command, j + 1);
    return { body: inner?.body ?? "", end: inner?.end ?? -1, output: c === ">" };
  };
  // One that becomes a sub token, not part of a word: all but a $(mktemp -d).
  const subAt = (j: number) => {
    const sub = scanSub(j);
    return sub && sub.end > 0 && ("<>".includes(command[j]) || !makesTempDir(sub.body)) ? sub : undefined;
  };
  // quoted: it had quotes; literal: quotes or a backslash, so ( or case in it is text.
  const readWord = () => {
    const start = i;
    let word = "";
    let quoted = false;
    let escaped = false;
    while (i < command.length) {
      const ch = command[i];
      if (" \t\n;|&".includes(ch)) break;
      // An unquoted < or > ends the word, as in bash: echo hi>x writes x. A <( or >(
      // here is one the top could not close: the rest is left unchecked.
      if (ch === "<" || ch === ">") {
        if (i === start && command[i + 1] === "(") {
          tokens.push({ kind: "unclosed" });
          i = command.length;
        }
        break;
      }
      // A sub the top could not close. Breaking on an empty word would leave i where it
      // is and loop forever, so the rest is left unchecked.
      const sub = ch === "$" || ch === "`" ? scanSub(i) : undefined;
      if (sub) {
        if (sub.end < 0 && !word) {
          tokens.push({ kind: "unclosed" });
          i = command.length;
          break;
        }
        if (sub.end < 0 || !makesTempDir(sub.body)) break;
        word += tempDir();
        i = sub.end;
        continue;
      }
      // $'...' ends at the first ' no backslash escapes.
      if (ch === "$" && command[i + 1] === "'") {
        quoted = true;
        let text = "";
        i += 2;
        while (i < command.length && command[i] !== "'") {
          if (command[i] === "\\" && i + 1 < command.length) {
            text += ansiEscapes[command[i + 1]] ?? command.slice(i, i + 2);
            i += 2;
            continue;
          }
          text += command[i++];
        }
        word += literal(text);
        i++;
        continue;
      }
      if (ch === "'") {
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
        quoted = true;
        i++;
        while (i < command.length && command[i] !== '"') {
          if (command[i] === "\\" && i + 1 < command.length) {
            word += literal(command[i + 1]);
            i += 2;
            continue;
          }
          const sub = command[i] === "$" || command[i] === "`" ? scanSub(i) : undefined;
          // One that never closes ends the reading: rescanning from each later one would be quadratic.
          if (sub && sub.end < 0) {
            tokens.push({ kind: "unclosed" });
            i = command.length;
            break;
          }
          if (sub) {
            if (makesTempDir(sub.body)) word += tempDir();
            else tokens.push({ kind: "sub", value: sub.body });
            i = sub.end;
            continue;
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
        escaped = true;
        if (i + 1 < command.length) word += literal(command[i + 1]);
        i += 2;
        continue;
      }
      // A ( that starts a word, and any unquoted ), is a word of its own, as bash reads
      // them: time (cd x; true)>/dev/null. An a=( stays in its word.
      if (ch === ")" && word) break;
      word += ch;
      i++;
      if (ch === ")" || word === "(") break;
    }
    return { word, quoted, literal: escaped || quoted };
  };
  // A redirect's target: one shell word, undefined when there is none, a process
  // substitution comes next, or the word holds a substitution.
  const readTarget = (): { target: string | undefined; text: string } => {
    let target = "";
    let quoted = false;
    let known = true;
    while (i < command.length && !" \t\n;|&()<>".includes(command[i])) {
      const sub = subAt(i);
      if (sub) {
        tokens.push({ kind: "sub", value: sub.body, output: sub.output });
        known = false;
        i = sub.end;
        continue;
      }
      const from = i;
      const pushed = tokens.length;
      const part = readWord();
      target += part.word;
      quoted ||= part.quoted;
      if (tokens.length !== pushed) known = false;
      if (i === from) break;
    }
    return { target: known && (target || quoted) ? target : undefined, text: target };
  };
  while (i < command.length) {
    const c = command[i];
    if (c === " " || c === "\t") {
      i++;
      continue;
    }
    // A # that starts a word comments out the rest of the line; the newline still ends it.
    // readWord keeps a # inside a word (a\ #b), so here one starts a word unless a sub
    // just ended there.
    if (c === "#" && i !== glued) {
      const end = command.indexOf("\n", i);
      i = end < 0 ? command.length : end;
      continue;
    }
    const heredoc = heredocAt(command, i);
    if (heredoc) {
      heredocs.push(heredoc);
      fd = "";
      i = heredoc.end;
      continue;
    }
    // Its subs are found over the whole body, so a $( may span lines.
    if (c === "\n" && heredocs.length) {
      tokens.push({ kind: "op", op: "\n" });
      i++;
      for (const doc of heredocs.splice(0)) {
        const body = heredocBody(command, i, doc);
        i = body.end;
        if (doc.quoted) continue;
        for (const line of body.lines) tokens.push({ kind: "doc", value: line });
        const found = subsIn(body.lines.join("\n"));
        for (const sub of found.subs) tokens.push({ kind: "sub", value: sub });
        if (found.unclosed) tokens.push({ kind: "unclosed" });
      }
      continue;
    }
    const redirect = redirectAt(command, i);
    if (redirect) {
      i = redirect.end;
      i = blanksEnd(command, i);
      tokens.push({ kind: "redirect", fd, op: redirect.op, ...readTarget() });
      fd = "";
      continue;
    }
    if (c === "\n" || c === ";" || c === "|" || c === "&") {
      // ;; ;& and ;;& end a case arm.
      const op =
        c === ";"
          ? ([";;&", ";;", ";&"].find((end) => command.startsWith(end, i)) ?? ";")
          : (c === "|" || c === "&") && command[i + 1] === c
            ? c + c
            : c;
      tokens.push({ kind: "op", op });
      i += op.length;
      continue;
    }
    const sub = subAt(i);
    if (sub) {
      tokens.push({ kind: "sub", value: sub.body, output: sub.output });
      i = glued = sub.end;
      continue;
    }
    const { word, quoted, literal } = readWord();
    if (!literal && redirectFd.test(word) && "<>".includes(command[i] ?? "\0") && command[i + 1] !== "(") fd = word;
    else if (word || quoted) tokens.push({ kind: "word", value: word, quoted, literal });
  }
  return tokens;
}

// One simple command, with the operators before and after it ("" at either end).
// marked keeps literalDollar where words has the $ back; quoted: each word had quotes.
// captured: each sub's output is read by the command (all but a >( )).
// redirects: in order and in marked form, kept out of words so none hides the verb.
// docs: unquoted heredoc lines read just before these words; they belong to an earlier command.
// A case arm's command is a segment of its own, with ) before it; its pattern is dropped.
// So is a function definition's head, so its body's commands are read as written;
// pastFunction marks every segment from the first head on.
type Segment = {
  words: string[];
  marked: string[];
  quoted: boolean[];
  subs: string[];
  captured: boolean[];
  docs: string[];
  before: string;
  after: string;
  redirects: Redirect[];
  unclosed: boolean;
  pastFunction: boolean;
};

const armEnds = new Set([";;", ";&", ";;&"]);
const functionName = /^[^\s()<>;&|'"`$]+$/;

// How many words a function definition's head takes: NAME (), NAME() or function NAME [()].
function functionHead(words: string[], verbatim: boolean[]): number {
  const bare = (k: number, word: string | RegExp) =>
    !verbatim[k] && words[k] !== undefined && (typeof word === "string" ? words[k] === word : word.test(words[k]));
  const parens = (k: number) => (bare(k, "(") && bare(k + 1, ")") ? 2 : 0);
  const glued = (k: number) => bare(k, /^[^\s()<>;&|'"`$]+\($/) && bare(k + 1, ")");
  if (bare(0, "function") && bare(1, functionName)) return 2 + parens(2);
  if (bare(0, "function") && glued(1)) return 3;
  if (glued(0)) return 2;
  return bare(0, functionName) && parens(1) ? 3 : 0;
}

function segmentsOf(command: string, tag = ""): Segment[] {
  const out: Segment[] = [];
  let words: string[] = [];
  let quoted: boolean[] = [];
  // Each word had quotes or a backslash: \( and "case" are text, not syntax.
  let verbatim: boolean[] = [];
  let subs: string[] = [];
  let captured: boolean[] = [];
  let docs: string[] = [];
  let redirects: Redirect[] = [];
  let before = "";
  let unclosed = false;
  // The case commands open; a header being read ("selector", then "in" once it has one);
  // whether an arm's pattern is being read, up to its ).
  let cases = 0;
  let header = "";
  let pattern = false;
  // Only reserved words and ( so far: the next word starts the command.
  const atStart = () => words.every((word, k) => !verbatim[k] && (shellPrefixes.has(word) || word === "("));
  let pastFunction = false;
  const flush = (op: string) => {
    const head = functionHead(words, verbatim);
    pastFunction ||= head > 0;
    words = words.slice(head);
    quoted = quoted.slice(head);
    if (words.length || subs.length || docs.length || redirects.length || unclosed) {
      const plain = words.map((word) => word.replaceAll(literalDollar, "$"));
      out.push({
        words: plain,
        marked: words,
        quoted,
        subs,
        captured,
        docs,
        before,
        after: op,
        redirects,
        unclosed,
        pastFunction,
      });
    }
    words = [];
    quoted = [];
    verbatim = [];
    subs = [];
    captured = [];
    docs = [];
    redirects = [];
    before = op;
  };
  for (const token of tokenize(command, tag)) {
    const bare = token.kind === "word" && !token.literal ? token.value : undefined;
    if (pattern && (token.kind === "word" || token.kind === "op")) {
      if (bare === ")") {
        pattern = false;
        before = ")";
        continue;
      }
      if (bare !== "esac") continue;
      pattern = false;
    }
    // case SELECTOR in, newlines allowed, the selector any word or substitution. A header
    // the guard cannot read leaves the rest unchecked rather than read as plain words.
    if (header === "in" && bare === "in") {
      words.push("in");
      quoted.push(false);
      verbatim.push(false);
      flush(")");
      header = "";
      cases++;
      pattern = true;
      continue;
    }
    if (header && token.kind === "op") {
      if (token.op === "\n") continue;
      unclosed = true;
      header = "";
    } else if (header && (token.kind === "word" || token.kind === "sub")) header = "in";
    if (bare === "esac" && !words.length && cases) cases--;
    if (bare === "case" && atStart()) header = "selector";
    if (token.kind === "op" && cases && armEnds.has(token.op)) {
      flush(token.op);
      pattern = true;
    } else if (token.kind === "op") flush(token.op);
    else if (token.kind === "redirect") redirects.push(token);
    else if (token.kind === "unclosed") unclosed = true;
    else if (token.kind === "sub") {
      subs.push(token.value);
      captured.push(!token.output);
    } else if (token.kind === "doc") docs.push(token.value);
    else {
      words.push(token.value);
      quoted.push(token.quoted);
      verbatim.push(token.literal);
    }
  }
  if (header) unclosed = true;
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

// entire's built-in commands (entire agent-help --json), and the Brain and Graph plugins.
const entireCommands = new Set(
  "activity agent agent-help api auth checkpoint cp checkpoints clean cluster configure disable dispatch doctor enable help labs login logout org plugin project recap repo search service-account session sessions status trail version why brain graph".split(
    " ",
  ),
);

function cliHelp(words: string[], graphiteAliases: readonly string[] | undefined): boolean {
  const name = basename(words[0]);
  // entire's own commands, Brain and Graph parse flags anywhere: a last --help with no flag
  // before it, which could take it as a value, prints help. Another plugin is its own program.
  if (/^entire(-brain|-graph)?$/.test(name))
    return (
      words.length > 2 &&
      (name !== "entire" || entireCommands.has(words[1])) &&
      words.at(-1) === "--help" &&
      words.slice(1, -1).every((word) => !word.startsWith("-"))
    );
  if (words.length !== 3 || words[2] !== "--help") return false;
  if (name === "git") return gitHelpBuiltins.has(words[1]);
  // bercail cleanup --help fails its argument check with the usage line and changes nothing.
  if (name === "bercail") return words[1] === "cleanup";
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

// A desk's restack, as Shep publishes it (bercail-i5dx): exactly
// --force-with-lease=refs/heads/<branch>:<old hash> <remote> <new hash>:refs/heads/<branch>.
const leaseFlag = /^--force-with-lease=(refs\/heads\/[\w./-]+):([0-9a-f]{40}|[0-9a-f]{64})$/;
const leaseSpec = /^([0-9a-f]{40}|[0-9a-f]{64}):(refs\/heads\/[\w./-]+)$/;
type Restack = { remote: string; spec: string; lease: { ref: string; old: string } };

function restackOf(args: string[]): Restack | undefined {
  const [flag = "", remote = "", spec = "", ...more] = args;
  const lease = leaseFlag.exec(flag);
  if (!lease || more.length || !remoteName.test(remote) || leaseSpec.exec(spec)?.[2] !== lease[1]) return undefined;
  return { remote, spec, lease: { ref: lease[1], old: lease[2] } };
}

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
    ". version agent-guide capabilities overview brief query search vsearch get multi-get recall status stats doctor verify path show review help inspect inspect.blame inspect.boundaries inspect.changes inspect.code inspect.context inspect.dead-code inspect.graph-schema inspect.impact inspect.query-graph inspect.regressions inspect.search-graph inspect.snippet inspect.tests inspect.trace-path entities entities.history entities.show memories memories.list memories.status memories.tree memories.global memories.vitality memories.map memories.storage memories.storage.status patterns patterns.status webhook webhook.status webhook.events docs docs.extract docs.formats config config.show config.path workspace workspace.list workspace.query workspace.search workspace.get workspace.vsearch workspace.inspect workspace.review memory memory.status memory.jobs",
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
  if (among(cmd, "cluster org project service-account") && sub === "list") return "read";
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
    if (among(sub, "approvals list sessions show stack timeline watch help")) return "read";
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

// reading: the words as this kind was read from them, for agent-help's list. literal:
// entire itself, in the folder the guard reads, with the words bash passes as written.
function decideEntire(
  kind: EntireKind,
  words: string[],
  dir: string | undefined,
  input: GuardInput,
  reading = words,
  literal = false,
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
  if (kind === "push") {
    const verb = entirePath(reading).slice(0, 2).join(" ");
    // A plain link is decided as a push of the branch it names (bercail-23ek); else as a bare
    // push, of the current one. Only in plain words, in a checkout the guard can place
    // (forgeCall drops a --repo and the folder with it), and where the repo's policy decides:
    // autopilot's rule is its own pull request's branch.
    const own = verb === "trail link" && literal && dir !== undefined && input.role !== "autopilot";
    const branch = own ? linkedBranch(reading) : undefined;
    const decision = decidePush(branch ? ["origin", branch] : [], dir, input, `entire ${verb}`);
    return branch && input.role === "shep" && decision.action === "allow" ? worse(decision, warn(shepTrail)) : decision;
  }
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

// bercail cleanup deletes a worktree, so the person says yes first. Its
// --check on one worktree only reads.
function decideCleanup(words: string[], input: GuardInput): GuardDecision {
  const plain = plainWords(words);
  if (basename(plain[0] ?? "") !== "bercail" || plain[1] !== "cleanup") return allow;
  if (words.length === 4 && words[1] === "cleanup" && words[2] === "--check" && !words[3].startsWith("-")) return allow;
  if (readOnlyRole(input.role)) return block(readOnly);
  if (!input.hasUI) return block(cleanupHeadless);
  if (input.role === "shep-bg") return block(backgroundOnly);
  return { action: "ask", reason: words[1] === "cleanup" && words[2] === "--gone" ? cleanupGoneAsk : cleanupAsk };
}

// Closing a Herdr space ends every terminal in it, so the person says yes first.
function decideSpaceClose(words: string[], input: GuardInput): GuardDecision {
  const plain = plainWords(words);
  if (basename(plain[0] ?? "") !== "herdr-app" || plain[1] !== "do" || plain[2] !== "space.close") return allow;
  if (readOnlyRole(input.role)) return block(readOnly);
  if (!input.hasUI) return block(spaceCloseHeadless);
  if (input.role === "shep-bg") return block(backgroundOnly);
  return { action: "ask", reason: spaceCloseAsk };
}

// bercail job merge and supersede run entire trail merge and update for a trail
// job, so each gets the answer that entire command gets.
function decideJob(words: string[], input: GuardInput): GuardDecision {
  const plain = plainWords(words);
  if (basename(plain[0] ?? "") !== "bercail" || plain[1] !== "job") return allow;
  if (plain[2] === "merge") return decideEntire("merge", ["entire", "trail", "merge"], undefined, input);
  if (plain[2] === "supersede") return decideEntire("trail", ["entire", "trail", "update"], undefined, input);
  return allow;
}

// bercail desk answer: a desk's guard prompt, answered from outside the desk (lib/desk.sh).
// bercail as the program run (past env, sudo, xargs and other wrappers, or by sh or bash),
// then its area and verb: the first two words after it that are not options.
function answersDesk(words: string[]): boolean {
  const run = commandWords(words);
  const isAnswer = (at: number) => {
    const [area, verb] = plainWords(run.slice(at + 1));
    return basename(run[at] ?? "") === "bercail" && area === "desk" && verb === "answer";
  };
  if (!["sh", "bash", "dash", "zsh", "ksh"].includes(basename(run[0] ?? ""))) return isAnswer(0);
  // A shell's script is its first operand. Its options may take values, even ending a
  // cluster (-xo errexit): with any option, bercail desk answer anywhere counts.
  if (!/^[-+]/.test(run[1] ?? "")) return isAnswer(1);
  return run.some((_, at) => isAnswer(at));
}

// The one grammar lib/desk.sh accepts too, in this order:
// bercail desk answer DESK yes|no --prompt ID [--reason TEXT] [--dry-run]. undefined for any other.
const promptId = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function deskAnswerArgs(words: string[]): { answer: string; reason: boolean; dry: boolean } | undefined {
  const [bin, area, verb, address, answer, flag, id, ...rest] = words;
  if (basename(bin ?? "") !== "bercail" || area !== "desk" || verb !== "answer") return undefined;
  if (!/^[\w.][\w.-]*$/.test(address ?? "") || !/^(yes|no)$/.test(answer ?? "")) return undefined;
  if (flag !== "--prompt" || !promptId.test(id ?? "")) return undefined;
  const reason = rest[0] === "--reason" && rest.length > 1;
  const dry = rest[reason ? 2 : 0] === "--dry-run";
  return rest.length === (reason ? 2 : 0) + (dry ? 1 : 0) ? { answer, reason, dry } : undefined;
}

// The one shape of a desk answer's Yes that goes to a card: the prompt's id and nothing else.
function deskYes(words: string[]): boolean {
  const args = deskAnswerArgs(words);
  return args?.answer === "yes" && !args.reason && !args.dry;
}

// Shep's desk answer, only as one argv in that grammar: a --dry-run runs, a No with its
// reason runs with a warning, a Yes goes to a card; any other shape is refused, as is
// every other role.
function decideDeskAnswer(command: string, input: GuardInput, depth: number): GuardDecision {
  if (input.role !== "shep") return block(deskAnswerRefused);
  const op = depth === 0 ? guardOperation(command, input.cwd, input.home) : undefined;
  const args = typeof op === "object" && op.kind === "command" ? deskAnswerArgs(op.argv) : undefined;
  if (args?.dry) return allow;
  if (args?.answer === "no" && args.reason) return warn(deskAnswerNo);
  if (typeof op === "object" && op.kind === "command" && deskYes(op.argv)) return ask(deskAnswerAsk);
  return block(deskAnswerShape);
}

// bercail land: Shep's commit and CI wait for a desk's branch.
function isLand(words: string[]): boolean {
  const plain = plainWords(words);
  return plain.some((word, i) => basename(word) === "bercail" && plain[i + 1] === "land");
}

// bercail land run, or the ledger's land steps: only the person's pick starts them.
function runsLandWorker(words: string[]): boolean {
  const plain = plainWords(words);
  return (
    plain.some((word, i) => basename(word) === "bercail" && plain[i + 1] === "land" && plain[i + 2] === "run") ||
    ["land-create", "land-claim", "land-step", "land-result", "land-tell"].some((op) => questionOp(words, op))
  );
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

// bercail routine ask: the person's request to Shep, which only the Routines panel sends.
function isRoutineAsk(words: string[]): boolean {
  const plain = plainWords(words);
  return plain.some((word, i) => basename(word) === "bercail" && plain[i + 1] === "routine" && plain[i + 2] === "ask");
}

// bercail config set or unset, or routine enable or disable: a write to the person's
// config.toml. Its area and verb anywhere after it: a command that only looks odd asks too.
function editsConfig(words: string[]): boolean {
  const plain = plainWords(words);
  const rest = plain.slice(plain.findIndex((word) => basename(word) === "bercail") + 1 || plain.length);
  const has = (...any: string[]) => rest.some((word) => any.includes(word));
  return (has("config") && has("set", "unset")) || (has("routine") && has("enable", "disable"));
}

// Its --dry-run, which writes nothing, only in a command the guard reads word for word
// as one argv (guardOperation): no comment, redirect or expansion bash could take it from.
function dryConfigRun(command: string, input: GuardInput): boolean {
  const op = guardOperation(command, input.cwd, input.home);
  return typeof op !== "string" && op.kind === "command" && op.argv.includes("--dry-run");
}

function isPolicyTrust(words: string[]): boolean {
  const plain = plainWords(words);
  return plain.some((word, i) => word === "policy" && plain[i + 1] === "trust");
}

// The files a shell command writes: its redirect targets, and what a file writer
// changes. Reads (cat, jq, sed -n, the source of a cp) are not writes, and
// neither is 2>&1. A seatbelt, not a sandbox.
const fileWrites = new Set([">", ">>", ">|", "&>", "&>>", "<>"]);
// The target of >& or <& that names an fd, not a file: 2>&1, >&-, 3>&1- (a move).
const fdTarget = /^(\d+-?|-)$/;
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

// The files redirects write; a target the guard cannot read is left out.
function redirectTargets(redirects: Redirect[]): string[] {
  return redirects.flatMap(({ op, target }) =>
    target !== undefined && (fileWrites.has(op) || (op === ">&" && !fdTarget.test(target))) ? [target] : [],
  );
}

// redirected: redirectTargets' files.
function writeTargets(words: string[], redirected: string[]): string[] {
  const targets = [...redirected];
  const [name, ...args] = words;
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
  return targets.filter((target) => target !== "");
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
    String.raw`question\s+answer|policy\s+trust|bercail\s+(todo|config\s+(set|unset)|routine\s+(enable|disable))`,
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

function madeAt(words: string[]): string[] {
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
function writesInTmp(words: string[], redirected: string[], targets: string[], tmpdir: string | undefined): boolean {
  if (!tmpdir) return false;
  const paths = ["rm", "unlink", "shred"].includes(words[0]) ? redirected : [...targets, ...madeAt(words)];
  return paths.some((path) => inTmp(path, tmpdir));
}

// $(mktemp -d -p /tmp): the segments stand a path in for it, so its words are read here.
function mktempInTmp(command: string, tmpdir: string | undefined): boolean {
  if (!tmpdir) return false;
  return subsIn(command).subs.some(
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
  if (input.cwdsCapped && !isAbsolute(path)) return false;
  const cwds = isAbsolute(path) ? [input.cwd] : (input.cwds ?? [input.cwd]);
  // A dir the guard lost passes only for itself: each known one is still checked.
  return cwds.every(
    (cwd) =>
      (cwd === undefined && !isAbsolute(path)) ||
      tempRoot(resolve(cwd ?? "/", path)) ||
      readOnlyWrite(path, input, cwd, true),
  );
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
  // Shep's restack push, as the whole command, asks under every policy, so it goes to a
  // guard card that pins it (pinLease). Inside another command it is any other force push.
  const restack = input.role === "shep" && input.sole ? restackOf(args) : undefined;
  if (restack) return isMainRef(restack.lease.ref) ? block(leaseToMain) : askOr(input, leaseAsk(restack), force);
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

  // Only a push that is the whole command and the only tool call of its message: nothing
  // beside it may change the repo or config deskBranchAt read before it ran.
  if (input.role === "" && input.deskBranch && input.sole && input.alone) {
    const own = ownDeskPush(args, facts, dir, input.deskBranch, input);
    if (typeof own !== "boolean") return own;
    if (own) return worse(decision, approve(deskPush(input.deskBranch.branch)));
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

const deskPush = (branch: string) => `a desk pushes its own branch (${branch}), which its handoff record names`;

// Flags that change neither what a push sends nor where: any other (--repo, --prune,
// --receive-pack, ...) asks as before.
const deskPushFlags = new Set([
  "-u",
  "--set-upstream",
  "-q",
  "--quiet",
  "-v",
  "--verbose",
  "-n",
  "--dry-run",
  "--porcelain",
  "--progress",
  "--no-progress",
]);

// The shape ownDeskPush may allow, read from the words alone, before any git or remote read:
// one git push to origin, no global option, only its harmless flags, a refspec named.
function mayPushOwn(command: string): boolean {
  const git = parseGit(command.trim().split(/ +/), undefined);
  if (git?.sub !== "push" || git.global.length) return false;
  const facts = pushFacts(git.args);
  return (
    facts.remote === "origin" &&
    facts.refspecs.length > 0 &&
    git.args.every((arg) => !arg.startsWith("-") || deskPushFlags.has(arg))
  );
}

// A desk's push of only its own branch to origin, from its worktree, with refspecs named:
// a bare push follows push.default, which may send more. Each refspec sends the branch (or
// HEAD on it) to the branch, a :dst in full; where git config maps a refspec with no :dst
// (own.mapped), each names it. Deletes, tags and --all ask as before.
function ownDeskPush(
  args: string[],
  facts: PushFacts,
  dir: string | undefined,
  own: { path: string; branch: string; mapped: boolean },
  input: GuardInput,
): boolean | GuardDecision {
  if (dir !== own.path || facts.remote !== "origin" || !facts.refspecs.length) return false;
  if (args.some((arg) => arg.startsWith("-") && !deskPushFlags.has(arg))) return false;
  if (facts.deleted.length || facts.tags || facts.every) return false;
  const names = [own.branch, `refs/heads/${own.branch}`];
  let head = false;
  for (const spec of facts.refspecs) {
    const [src, dst] = spec.includes(":")
      ? [spec.slice(0, spec.indexOf(":")), spec.slice(spec.indexOf(":") + 1)]
      : [spec];
    // git resolves a short :dst against the remote's refs, a tag of that name included.
    if (dst === undefined ? own.mapped : dst !== names[1]) return false;
    if (src === "HEAD") head = true;
    else if (!names.includes(src)) return false;
  }
  if (!head) return true;
  const branch = branchOf(dir, input);
  return typeof branch === "string" ? branch === own.branch : branch;
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
  if (sub === "push") {
    // A desk's own-branch push is plain: no -c or other global option, not even a -C,
    // whose folder git may reach through a link the guard reads by name only.
    const here = git.global.length === 0 ? input : { ...input, deskBranch: undefined };
    return decidePush(args, git.dir, here, undefined, approvable(git, input));
  }
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
  const pure =
    !segment.redirects.length && rest.every((word) => assign.test(word) || (head === 1 && word.startsWith("-")));
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

// op that lists or reveals the vault wherever its output goes: item or vault list,
// item get --reveal or as JSON (concealed fields not shown masked there), op run
// --no-masking, and service accounts. RAW has the assignments before op.
function revealsVault(words: string[], raw: string[]): boolean {
  const args = opArgs(words);
  if (!args) return false;
  const [group, verb] = args;
  const item = group === "item" || group === "items";
  if ((item || group === "vault" || group === "vaults") && (verb === "list" || verb === "ls")) return true;
  if (group === "service-account" || group === "sa") return true;
  const all = commandWords(words);
  const own = all.includes("--") ? all.slice(0, all.indexOf("--")) : all;
  if (group === "run") return own.includes("--no-masking");
  const json =
    raw.some((word) => /^OP_FORMAT=json$/i.test(word)) ||
    own.some((word, i) => /^--format=json$/i.test(word) || (word === "--format" && /^json$/i.test(own[i + 1] ?? "")));
  return item && verb === "get" && (json || own.some((word) => /^--reveal(=|$)/.test(word)));
}

// Where op read or op inject sends the secret when it shows it: no -o, or an -o
// the guard cannot place outside the worktree, and stdout not sent to /dev/null.
function showsSecret(words: string[], redirects: Redirect[], input: GuardInput): boolean {
  const args = opArgs(words);
  if (!args || !(args[0] === "read" || args[0] === "inject") || input.captured || !input.deskSecret) return false;
  const at = args.findIndex((word) => /^(-o|--out-file)(=|$)/.test(word));
  if (at < 0) return stdoutOf(redirects) !== "/dev/null";
  let out = args[at].includes("=") ? args[at].slice(args[at].indexOf("=") + 1) : (args[at + 1] ?? "");
  if (out.startsWith("~/") && input.home) out = join(input.home, out.slice(2));
  const path = placeIn(input.cwd, out);
  if (path === undefined) return true;
  if (tempRoot(path)) return false;
  const root = input.deskSecret.root;
  return [root, "/dev", "/proc"].some((dir) => path === dir || path.startsWith(`${dir}/`));
}

// Where fd 1 points once the redirects are done, in order; undefined when the guard
// cannot tell. >/dev/null 1>&2 sends it back to the terminal. An fd is its number: 01 is 1.
function stdoutOf(redirects: Redirect[]): string | undefined {
  const number = (fd: string) => (/^\d+$/.test(fd) ? String(Number(fd)) : fd);
  const fds = new Map<string, string | undefined>([
    ["1", "tty"],
    ["2", "tty"],
  ]);
  for (const { fd, op, target } of redirects) {
    const from = number(fd || (op.startsWith("<") ? "0" : "1"));
    if (op === "&>" || op === "&>>") {
      fds.set("1", target);
      fds.set("2", target);
    } else if (op === ">&" || op === "<&") {
      if (target === undefined) return undefined;
      // N>&M copies M; N>&M- moves it, closing M; >&- closes N; >&file and 1>&file send both.
      const dup = /^(\d+)(-?)$/.exec(target);
      if (dup) {
        fds.set(from, fds.get(number(dup[1])));
        if (dup[2]) fds.delete(number(dup[1]));
      } else if (target === "-") fds.delete(from);
      else if (op === ">&" && from === "1") {
        fds.set("1", target);
        fds.set("2", target);
      } else return undefined;
    } else fds.set(from, target);
  }
  return fds.get("1");
}

// The segment prints the environment, or the token's variable by name: a bare env,
// printenv, set, export or declare. $OP_SERVICE_ACCOUNT_TOKEN itself is decideBash's.
function printsEnv(words: string[], raw: string[]): boolean {
  if (words.length === 0) return raw.some((word) => basename(word) === "env");
  const cmd = basename(words[0]);
  const names = words.slice(1).filter((word) => !word.startsWith("-") && !word.startsWith("+"));
  if (cmd === "set") return words.length === 1;
  if (!["printenv", "export", "declare", "typeset"].includes(cmd)) return false;
  return names.length === 0 || names.some((name) => name.split("=")[0] === "OP_SERVICE_ACCOUNT_TOKEN");
}

// The ways a command can spell PATH under HOME.
function spellings(path: string, home: string | undefined): string[] {
  if (!home || !path.startsWith(`${home}/`)) return [path];
  const rest = path.slice(home.length);
  return [path, `~${rest}`, `$HOME${rest}`, `\${HOME}${rest}`];
}

// The secret's folder, when it is one of its own: not HOME, not above it.
function secretDir(secret: DeskSecret, home: string | undefined): string | undefined {
  const dir = dirname(secret.file);
  return dir === "/" || (home && (home === dir || home.startsWith(`${dir}/`))) ? undefined : dir;
}

// The command names the secret file, its folder, or the shim's variable, or decrypts
// a systemd credential.
function namesSecret(command: string, secret: DeskSecret, home: string | undefined): boolean {
  const dir = secretDir(secret, home);
  const names = [...spellings(secret.file, home), `/${basename(secret.file)}`, "BERCAIL_OP_SERVICE_ACCOUNT"];
  if (dir) names.push(...spellings(dir, home));
  return names.some((name) => command.includes(name)) || /systemd-creds\b[^\n;|&]*\bdecrypt\b/.test(command);
}

// A tool's PATH is the secret file or in its folder. For grep, which reads what is
// under PATH, so is a folder above it below HOME (~/.config, ~/.config/bercail).
function inSecret(tool: string, path: string, secret: DeskSecret, home: string | undefined): boolean {
  const dir = secretDir(secret, home);
  if (path === secret.file || (dir !== undefined && (path === dir || path.startsWith(`${dir}/`)))) return true;
  return tool === "grep" && !!home && path.startsWith(`${home}/`) && secret.file.startsWith(`${path}/`);
}

// The words without a ( subshell's parens, which tokenize makes words of their own:
// (git commit) runs git commit.
function unparen(words: string[], quoted: boolean[]): string[] {
  return words.filter((word, i) => !(["(", ")"].includes(word) && !quoted[i]));
}

// The segment runs op that prints a secret, itself, in a sh -c script, or in a >( ),
// whose output is the segment's.
function segmentReadsSecret(segment: Segment): boolean {
  const words = commandWords(unparen(segment.words, segment.quoted));
  const script = shellScript(words.map((word, i) => (i === 0 ? basename(word) : word)));
  const outputs = segment.subs.filter((_, k) => !segment.captured[k]);
  return (
    readsSecret(words) ||
    [...(script === undefined ? [] : [script]), ...outputs].some((body) =>
      segmentsOf(body, "secret").some(segmentReadsSecret),
    )
  );
}

// 2>&1 in $(op read ...): op's error text becomes the value, and passes a check.
function joinsErrors(segment: Segment): boolean {
  return segment.redirects.some(({ fd, op, target }) => fd === "2" && op === ">&" && target === "1");
}

// The names a plain assignment sets, export and local included; undefined when it runs a command.
// A redirect can fail before the assignment runs.
function assignedNames(segment: Segment): { names: string[]; exported: boolean } | undefined {
  if (segment.redirects.length) return undefined;
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
  if (segment.redirects.length || !["", ";", "\n", "&&"].includes(segment.before)) return undefined;
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
  const segments = segmentsOf(command, "secret");
  // Names that hold op's secret and are not checked yet; true when exported.
  const unchecked = new Map<string, boolean>();
  // Names a [ -n "$X" ] && earlier in this && chain vouches for.
  const guarded = new Set<string>();
  let read = false;
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i];
    if (segment.before !== "&&") guarded.clear();
    read ||= segmentReadsSecret(segment);
    if (segmentReadsSecret(segment) && segment.after === "|") return true;
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
      const targets = segment.redirects.map(({ text }) => text);
      const used = [...segment.marked, ...targets, ...segment.subs].some((text) => refersTo(text, name));
      if (exported || named || used) return true;
    }
    // A >( )'s output is shown, not held: an assignment from one holds a /dev/fd path.
    const readers = segment.subs
      .filter((_, k) => segment.captured[k])
      .flatMap((sub) => segmentsOf(sub, "secret").filter(segmentReadsSecret));
    if (readers.some(joinsErrors)) return true;
    if (readers.length === 0) continue;
    const assigned = assignedNames(segment);
    if (!assigned) return true;
    for (const name of assigned.names) unchecked.set(name, assigned.exported);
  }
  return false;
}

// What a segment's command and redirects write, and /dev/uinput.
// subbed: the segment has a substitution, whose output may be a writer's destination.
function decideWrites(
  words: string[],
  raw: string[],
  redirects: Redirect[],
  here: GuardInput,
  subbed = false,
): GuardDecision {
  let decision: GuardDecision = allow;
  const redirected = redirectTargets(redirects);
  const devices = redirects.flatMap(({ target }) => target ?? []);
  if (fakesInput(words, [...raw, ...devices])) decision = worse(decision, block(syntheticInput));
  const targets = writeTargets(words, redirected);
  // Past the cap only a destination that starts with / as written is placed: not ~ (quoted,
  // it stays relative), a $VAR, a redirect whose target the guard could not read, or a file
  // writer given a substitution, which may be its destination.
  const placed = (target: string) => target.startsWith("/") && !/[$`]/.test(target);
  const unread =
    redirects.some(({ op, target }) => target === undefined && (fileWrites.has(op) || op === ">&")) ||
    (subbed &&
      (everyOperand.has(words[0]) ||
        toDestination.has(words[0]) ||
        (Object.hasOwn(inPlace, words[0]) && words.some((word) => inPlace[words[0]].test(word))) ||
        words[0] === "dd"));
  if (here.cwdsOverflowed && (unread || !targets.every(placed))) decision = worse(decision, block(tooManyCwds));
  if (here.role === "shep-bg" && targets.some((target) => !stream.test(target) && !readOnlyWrite(target, here)))
    decision = worse(decision, block(backgroundOnly));
  // A protected file's reason, below, wins over this one.
  if (readOnlyRole(here.role) && !targets.every((target) => readOnlyTarget(target, here)))
    decision = worse(decision, block(readOnlyTool));
  if (writesGuardFiles(targets, here)) decision = worse(decision, block(protectedFile));
  if (writesTodoFiles(targets, here)) decision = worse(decision, block(todoFile));
  if (here.cwds?.includes(undefined) && targets.some(relativeTarget)) decision = worse(decision, warn(lostCwd));
  if (writesInTmp(words, redirected, targets, here.tmpdir)) decision = worse(decision, warn(tmpWrite(here.tmpdir!)));
  return decision;
}

export function decideBash(command: string, input: GuardInput, depth = 0): GuardDecision {
  if (depth > 4) return block("This command is nested too deep to check. Split it into a simpler command.");
  if (feedsEmptySecret(command)) return block(emptySecret);
  const secret = input.deskSecret;
  if (secret && namesSecret(command, secret, input.home)) return block(secretFile);
  if (secret && (/\$\{?OP_SERVICE_ACCOUNT_TOKEN/.test(command) || /\/proc\/\S*environ/.test(command)))
    return block(printsToken);
  let decision: GuardDecision = mktempInTmp(command, input.tmpdir) ? warn(tmpWrite(input.tmpdir!)) : allow;
  const segments = segmentsOf(command, `${depth}`);
  const configEdit = segments.some((s) => editsConfig(commandWords(unparen(s.words, s.quoted))));
  if (configEdit && !(depth === 0 && dryConfigRun(command, input)))
    decision = input.role === "shep" ? ask(configEditAsk) : block(configEditRefused);
  if (segments.some((s) => answersDesk(commandWords(unparen(s.words, s.quoted)))))
    decision = worse(decision, decideDeskAnswer(command, input, depth));
  // Each dir the shell may be in; git and forges use it only when there is one.
  let cwds = input.cwds ?? [input.cwd];
  let capped = input.cwdsCapped ?? false;
  const cwdOf = () => (cwds.length === 1 ? cwds[0] : undefined);
  let overflowed = input.cwdsOverflowed ?? false;
  // Set the dirs the shell may be in, each once. Past a few the guard stops tracking them
  // for the rest of the command (a chain of redirected relative cds doubles them), and
  // refuses what it would have checked in the ones it dropped.
  const place = (list: (string | undefined)[]) => {
    const unique = [...new Set(list)];
    overflowed ||= unique.length > 8;
    capped ||= overflowed;
    cwds = overflowed ? [undefined] : unique;
  };
  let gitEnv = input.gitEnv ?? false;
  let gitConfigEnv = input.gitConfigEnv ?? false;
  let branchMoved = input.branchMoved ?? false;
  // Later-tokenized redirects/heredocs run first; pipe/background peers can change aliases concurrently.
  let graphiteAliases = segments.some(
    (segment) =>
      ["|", "&"].includes(segment.after) || segment.redirects.length || (segment.docs.length && segment.subs.length),
  )
    ? undefined
    : input.graphiteAliases;
  // Where the shell was before each cd after &&: that cd may not have run.
  let skippedCd: (string | undefined)[] = [];
  const vars: TempVars = new Map();
  let straight = true;
  let closed = false;
  // A function was defined: from there a call may move the shell, so each dir stays possible.
  let defined = false;
  for (const segment of segments) {
    // Apply a ) before the next segment, even when it stood alone after a ;.
    // No inner variables or cwd can be borrowed outside it.
    if (closed) {
      place(defined ? [...cwds, undefined] : [undefined]);
      skippedCd = [];
      straight = false;
      vars.clear();
    }
    // A function body runs when it is called, from wherever the shell is then, and may cd
    // anywhere: from its definition on, the shell may be in any dir it was in, or another.
    if (segment.pastFunction && !defined) {
      defined = capped = true;
      place([...cwds, undefined]);
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
      place([...cwds, ...skippedCd]);
      skippedCd = [];
    }
    const bare = unparen(segment.marked, segment.quoted);
    // Past a branch, loop, function, || or pipe, no mktemp -d variable holds. A ( subshell
    // runs in a straight line inside, so that holds until its ).
    if (compound.has(bare[0]) || ["||", "|", "&"].includes(segment.before)) {
      straight = false;
      vars.clear();
    }
    const here = {
      ...input,
      cwd: cwdOf(),
      cwds,
      cwdsCapped: capped,
      cwdsOverflowed: overflowed,
      gitEnv,
      gitConfigEnv,
      branchMoved,
      graphiteAliases,
      sole: false,
    };
    // A >( )'s output is the command's: captured only when the command's is.
    segment.subs.forEach((sub, k) => {
      const captured = segment.captured[k] || here.captured;
      decision = worse(decision, decideBash(sub, { ...here, captured, graphiteAliases: undefined }, depth + 1));
    });
    if (segment.subs.length) here.graphiteAliases = graphiteAliases = undefined;
    const raw = bare.map((word) => expandTemps(word, vars).replaceAll(literalDollar, "$"));
    const redirects = segment.redirects.map((redirect) => ({
      ...redirect,
      target: redirect.target && expandTemps(redirect.target, vars).replaceAll(literalDollar, "$"),
    }));
    if (straight) recordTemps(command, segment, raw, vars);
    // A substitution's output is not in raw and could add arguments that change help into a write.
    const staticArgs =
      !command.includes("\\") &&
      !segment.quoted.some(Boolean) &&
      !redirects.length &&
      raw.every((word) => staticArg.test(word));
    const help = depth === 0 && staticArgs && !segment.subs.length && raw.length > 0 && cliHelp(raw, graphiteAliases);
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
    if (secret) {
      if (printsEnv(words, raw)) return block(printsToken);
      // The text check above stops at the & of 2>&1; the words have no redirect.
      if (basename(words[0] ?? "") === "systemd-creds" && words.includes("decrypt")) return block(secretFile);
      if (revealsVault(words, raw) || showsSecret(words, redirects, here)) return block(vaultShown);
    }
    // >file alone runs no command but writes.
    if (words.length === 0) {
      decision = worse(decision, decideWrites(words, raw, redirects, here));
      continue;
    }
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
    // cd $(pwd): the target is the substitution's output, which words leave out. A
    // redirect can fail before cd runs, and past a definition a call may undo it, so the
    // shell is in either dir.
    const unseen = piped || segment.subs.length > 0;
    if (words[0] === "cd" || words[0] === "pushd")
      place(
        cwds.flatMap((cwd) => {
          const to = unseen ? undefined : cdTarget(words, cwd, input.home);
          return redirects.length || defined ? [cwd, to] : [to];
        }),
      );
    else if (words[0] === "popd") place(defined ? [...cwds, undefined] : [undefined]);
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
    // entire itself, as Shep wrote it: no substitution, no shell it runs in, and no prefix or
    // wrapper (env -C, sudo, …) that commandWords dropped and that could change its folder or argv.
    const literal =
      depth === 0 && staticArgs && !segment.subs.length && raw[0] === "entire" && words.length === raw.length;
    const kinds = readings.map((reading) => reading && entireKind(reading));
    if (kinds[1] && !help) {
      kinds.forEach((kind, i) => {
        if (kind) decision = worse(decision, decideEntire(kind, forge.words, forge.dir, here, readings[i], literal));
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
    if (!help) decision = worse(decision, decideCleanup(words, here));
    decision = worse(decision, decideSpaceClose(words, here));
    decision = worse(decision, decideJob(words, here));
    if (questionOp(words, "answer")) decision = worse(decision, block(answerCommand));
    if (questionOp(words, "push-approval")) decision = worse(decision, block(pushApprovalCommand));
    if (isRoutineAsk(words)) decision = worse(decision, block(routineAsk));
    if (["guard-create", "guard-default", "guard-claim"].some((op) => questionOp(words, op)) || runsGuardAsk(words))
      decision = worse(decision, block(guardAskCommand));
    if (writesTodo(words) && input.role !== "shep") decision = worse(decision, block(basecampWrite));
    if (setsTodoTarget(words) && input.role !== "shep") decision = worse(decision, block(todoTargets));
    if (isLand(words) && input.role !== "shep") decision = worse(decision, block(landCommand));
    if (runsLandWorker(words)) decision = worse(decision, block(landWorker));
    decision = worse(decision, decideBasecamp(words, input.role));
    decision = worse(decision, decideWrites(words, raw, redirects, here, segment.subs.length > 0));
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
  // Before the write rules: a warning there would let a write to the secret through.
  if (input.deskSecret && path) {
    if (inSecret(tool, resolve(input.cwd ?? "/", path), input.deskSecret, input.home)) return block(secretFile);
  }
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

// A desk's own branch, for its pushes: the last handoff record naming this terminal gives
// its worktree and branch. None for no record, a branch that is the trunk (main, master,
// the default branch origin's server names) or a default it cannot read, a name git resolves
// to another ref, git config that makes a push send more (tags, submodules, a mirror), or a
// push URL that is not origin's one fetch URL. mapped: git may send a refspec with no :dst elsewhere, by push.default upstream or a
// remote.origin.push. Read on each push: config and the server's default may change.
async function deskBranchAt(
  pi: ExtensionAPI,
  desk: string,
  cwd: string,
  signal: AbortSignal | undefined,
): Promise<GuardInput["deskBranch"]> {
  let lines: string[];
  try {
    lines = readFileSync(join(stateDir(), "handoffs.jsonl"), "utf8").split("\n");
  } catch {
    return undefined;
  }
  let record: { path?: unknown; branch?: unknown } | undefined;
  for (let i = lines.length - 1; i >= 0 && !record; i--) {
    try {
      const line = JSON.parse(lines[i]);
      if (line?.desk === desk) record = line;
    } catch {}
  }
  const { path, branch } = record ?? {};
  // Its worktree is where the push runs, before git reads anything there or at origin.
  if (path !== cwd || !isAbsolute(path) || typeof branch !== "string" || !branch || isMainRef(branch)) return undefined;
  try {
    const git = (...args: string[]) => pi.exec("git", ["-C", path, ...args], { timeout: 5000, signal });
    // One place it pushes to, the one ls-remote reads origin's default from below.
    // Byte for byte but git's last newline: a path may end in a space.
    // Pi decodes output as UTF-8, so a path that is not decodes lossily: then it cannot tell.
    const fetch = await git("remote", "get-url", "--all", "origin");
    const push = await git("remote", "get-url", "--push", "--all", "origin");
    const url = fetch.stdout.replace(/\n$/, "");
    if (fetch.code !== 0 || push.code !== 0 || !url || /[\n\uFFFD]/.test(url) || push.stdout.replace(/\n$/, "") !== url)
      return undefined;
    // The branch's own name resolves to the branch, not a tag or other ref git looks up first.
    const full = await git("rev-parse", "--symbolic-full-name", branch);
    if (full.code !== 0 || full.stdout.trim() !== `refs/heads/${branch}`) return undefined;
    const config = await git(
      "config",
      "--get-regexp",
      "^(push\\.(default|followtags|recursesubmodules)|remote\\.origin\\.(push|mirror)|submodule\\.recurse)$",
    );
    if (config.code !== 0 && config.code !== 1) return undefined;
    const lines = config.stdout.split("\n").map((line) => line.trim().toLowerCase());
    const more = /^(push\.followtags|push\.recursesubmodules|remote\.origin\.mirror|submodule\.recurse)( |$)/;
    if (lines.some((line) => more.test(line) && !/ (false|no|off|0|check)$/.test(line))) return undefined;
    const mapped = lines.some(
      (line) => line.startsWith("remote.origin.push ") || /^push\.default (upstream|tracking)$/.test(line),
    );
    // The server's default branch, not the copy a fetch left in refs/remotes/origin/HEAD.
    const head = await git("ls-remote", "--symref", "origin", "HEAD");
    const remoteHead = /^ref: (refs\/heads\/\S+)\tHEAD$/m.exec(head.stdout)?.[1];
    if (head.code !== 0 || !remoteHead || remoteHead === `refs/heads/${branch}`) return undefined;
    return { path, branch, mapped };
  } catch {
    return undefined;
  }
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
  /** [desk_secrets] in config.toml: the token file, and why it cannot be used, if so. */
  desk_secret?: { file: string; problem: string } | null;
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

// The repo's desk secret, for the guard's rules: every role gets them, even when
// the file is unusable.
export function deskSecretOf(json: PolicyJson | undefined): DeskSecret | undefined {
  const file = json?.desk_secret?.file;
  return file ? { file, root: json.root ?? json.repo } : undefined;
}

// A desk's lead, a builder, autopilot and a headless run may use the desk secret.
// Shep, background Shep, Discuss and the judge may not.
const secretRoles = new Set(["", "lead", "builder", "autopilot"]);

// For a role that may use it, puts the op shim in SHIM first on ENV's PATH and
// names the file for it there; the token stays in the file. Any other role, or
// a Pi started from a desk's shell, loses the shim it inherited. Returns what to
// tell the person when the secret is there but unusable.
export function useDeskSecret(
  json: PolicyJson | undefined,
  role: string,
  env: NodeJS.ProcessEnv,
  shim: string,
): string | undefined {
  const secret = json?.desk_secret;
  const dirs = (env.PATH ?? "").split(":");
  const path = dirs.filter((dir) => dir !== shim);
  if (path.length < dirs.length) env.PATH = path.join(":");
  delete env.BERCAIL_OP_SERVICE_ACCOUNT;
  if (!json || !secret?.file || !secretRoles.has(role)) return undefined;
  if (secret.problem)
    return `bercail: ${json.repo}'s desk secret is not used: ${secret.problem}. op asks the 1Password app instead.`;
  env.PATH = [shim, ...path].join(":");
  env.BERCAIL_OP_SERVICE_ACCOUNT = secret.file;
  return undefined;
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
const redactUrls = (text: string) => text.replace(/([a-z][a-z0-9+.-]*:\/\/)[^/\s@]+@/gi, "$1***@");

export function redact(command: string): string {
  const clean = redactUrls(command);
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

// After a push an answer approved: the policy file its card pinned, trusted once it is on
// the trunk (bercail shep question policy-trust checks and writes it). What it did, as
// warnings; none when the card pinned none.
async function policyTrust(pi: ExtensionAPI, token: string, signal: AbortSignal | undefined): Promise<string[]> {
  const retry = `Run bercail shep question policy-trust ${token} again once the push is on the trunk.`;
  try {
    const result = await pi.exec(process.env.BERCAIL_BIN || "bercail", ["shep", "question", "policy-trust", token], {
      timeout: 90000,
      signal,
    });
    const out = JSON.parse(result.stdout) as { trusted?: string | null; repo?: string; reason?: string };
    if (result.code === 0 && typeof out.trusted === "string")
      return [`Trusted ${out.repo}'s new .bercail/policy.toml (sha256 ${out.trusted.slice(0, 12)}), as ${token} said.`];
    if (result.code === 0 && out.trusted === null && out.reason === undefined) return [];
    return [`Did not trust the policy file ${token} pinned: ${out.reason ?? "its trust was not written"}. ${retry}`];
  } catch {
    return [`Did not trust the policy file ${token} pinned: bercail shep question policy-trust failed. ${retry}`];
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
  // gone: bercail cleanup --gone, which records a checkout removed some other way.
  | { kind: "cleanup"; path: string; gone?: true }
  // job: a trail job's bercail job merge, which closes the trail once no change is open.
  | { kind: "trail merge"; dir: string; trail: string | null; job?: string }
  // lease: a restack's --force-with-lease, on its one refspec's branch.
  | { kind: "push"; dir: string; remote: string; refspecs: string[]; lease?: { ref: string; old: string } }
  // Any other one command, run as these words in dir with no shell.
  | { kind: "command"; dir: string; argv: string[] };

/** What it acts on, read from disk, git and entire: the worker runs on these alone. */
export type GuardFacts =
  // A config.toml edit: the lines its --dry-run adds and removes.
  | { kind: "command"; dir: string; argv: string[]; diff: string }
  // A desk answer's Yes, in the desk's worktree: what its --dry-run says it answers.
  | { kind: "command"; dir: string; argv: string[]; answer: string }
  | { kind: "cleanup"; worktree: string; branch: string | null; head: string }
  // The gone checkout's path as its handoffs name it, their one repo, the last one's branch,
  // and how many there are.
  | { kind: "cleanup"; gone: true; path: string; repo: string; branch: string | null; handoffs: number }
  | { kind: "trail merge"; checkout: string; trailId: string; change: string; head: string; base: string; job?: string }
  | { kind: "push"; dir: string; gitDir: string; url: string; refspecs: string[]; lease?: { ref: string; old: string } }
  | { kind: "command"; dir: string; argv: string[] };

// The words of each command joined by &&, as bash passes them, when nothing in them
// expands: bare words of plain characters (a hash refspec's ^{commit} too), and quoted
// text, single or double, that holds no $, backtick or backslash in double quotes. A
// control character, a glob, a ~, a redirect, a pipe, a ; or a & alone: undefined.
function asWritten(command: string): string[][] | undefined {
  // Nothing the card could hide or reorder: no control, format (bidi) or line separator, no lone surrogate.
  if (!command.isWellFormed() || /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(command)) return undefined;
  const segments: string[][] = [[]];
  let i = 0;
  while (i < command.length) {
    if (command[i] === " ") {
      i++;
      continue;
    }
    if (command.startsWith("&&", i) && (command[i + 2] ?? " ") === " ") {
      segments.push([]);
      i += 2;
      continue;
    }
    let word = "";
    let bare = "";
    while (i < command.length && command[i] !== " ") {
      const c = command[i];
      if (c === "'" || c === '"') {
        const end = command.indexOf(c, i + 1);
        if (end < 0) return undefined;
        const text = command.slice(i + 1, end);
        if (c === '"' && /[$`\\]/.test(text)) return undefined;
        word += text;
        bare += "\0";
        i = end + 1;
        continue;
      }
      if (!/[\w./:@=^{}-]/.test(c)) return undefined;
      word += c;
      bare += c;
      i++;
    }
    // Braces expand unless they are a hash refspec's, whole and unquoted.
    if (/[{}^]/.test(bare) && (bare !== word || !hashRefspec.test(word))) return undefined;
    segments.at(-1)!.push(word);
  }
  return segments.every((words) => words.length) ? segments : undefined;
}

// Programs that run their arguments as a script: the card would show the script, not what it runs.
const interpreters = new Set(["bash", "sh", "dash", "zsh", "ksh", "fish", "eval", "source", "."]);

// A word as the shell, and asWritten, read it back: bare when plain, else quoted.
const shellWord = (word: string) =>
  plainWord.test(word)
    ? word
    : !word.includes("'")
      ? `'${word}'`
      : !/[$`\\"]/.test(word)
        ? `"${word}"`
        : `'${word.replaceAll("'", `'"'"'`)}'`;
export const argvText = (argv: string[]) => argv.map(shellWord).join(" ");

// The one operation a command is, or why it is not one: the whole command is that
// command, after at most one cd DIR &&, in words the shell passes as written.
export function guardOperation(command: string, cwd: string | undefined, home: string | undefined): GuardOp | string {
  const written = asWritten(command);
  const segments = segmentsOf(command);
  // The guard decides on segmentsOf's words: they must be the ones the worker runs.
  const same =
    written?.length === segments.length &&
    segments.every(
      (s, i) =>
        !s.subs.length &&
        !s.docs.length &&
        !s.unclosed &&
        s.after === (i < segments.length - 1 ? "&&" : "") &&
        JSON.stringify(s.words) === JSON.stringify(written[i]),
    );
  if (!same)
    return "it is not one command as written (no pipes, redirects, substitutions, variables, globs, or chains but cd DIR && …)";
  let dir = cwd;
  if (segments.length === 2 && segments[0].words[0] === "cd") {
    // An absolute path, which bash's cd reads as the guard does: no ~, option, empty word or CDPATH.
    if (segments[0].words.length !== 2 || !segments[0].words[1].startsWith("/"))
      return "its cd names no one absolute folder";
    dir = cdTarget(segments[0].words, cwd, home);
  } else if (segments.length !== 1) return "it runs more than one command";
  const words = segments.at(-1)!.words;
  // git follows a symlink before a .., and the guard reads .. as text.
  if ([...segments[0].words, ...words].some((word) => /(^|\/)\.\.(\/|$)/.test(word)))
    return "it names a folder with .., which a symlink can send elsewhere";
  if (dir === undefined || !isAbsolute(dir)) return "the guard cannot tell which folder it runs in";
  // The guard's checks drop an empty word, so the argv they read would not be the one run.
  if (words.includes("")) return "it has an empty argument";
  // The worker runs the command itself: what an env prefix, a wrapper or a shell would run is not on the card.
  if (commandWords(words).length !== words.length || interpreters.has(basename(words[0])))
    return "it runs its command through an env prefix, a wrapper or a shell; run the command itself";
  // What the guard reads as a cleanup or a trail merge, in any shape: only the pinned one is handed off.
  const plain = plainWords(words);
  const named = [basename(words[0]), ...words.slice(1)];
  const merges = [named, entireValueReading(named)].some((reading) => reading && entireKind(reading) === "merge");
  if (basename(words[0]) === "bercail" && plain[1] === "cleanup") {
    // --gone takes the absolute path its handoff names, which is gone: nothing to place.
    if (words.length === 4 && words[1] === "cleanup" && words[2] === "--gone" && words[3].startsWith("/"))
      return { kind: "cleanup", path: words[3], gone: true };
    if (words.length !== 3 || words[1] !== "cleanup" || words[2].startsWith("-"))
      return "bercail cleanup takes the one worktree it retires, or --gone and the absolute path of one already removed";
    return { kind: "cleanup", path: placeIn(dir, words[2])! };
  }
  if (merges) {
    if (words[1] !== "trail" || words[2] !== "merge" || words.length > 4 || words[3]?.startsWith("-"))
      return "a trail merge is handed off only as entire trail merge [<trail>|<repo>/<n>], or bercail job merge trail:<n> [--change <repo>/<n>]";
    return { kind: "trail merge", dir, trail: words[3] ?? null };
  }
  // bercail job merge trail:<n> [--change <repo>/<n>] [--repo DIR]: the trail's change, pinned
  // as a trail merge's, that the worker merges and then closes the trail with.
  if (basename(words[0]) === "bercail" && plain[1] === "job" && plain[2] === "merge") {
    if (words[1] !== "job" || words[2] !== "merge")
      return "a trail job merge is handed off only as bercail job merge trail:<n> [--change <repo>/<n>] [--repo DIR]";
    const flags: Record<string, string> = {};
    for (let i = 4; i < words.length; i += 2) {
      if (!["--change", "--repo"].includes(words[i]) || !words[i + 1] || flags[words[i]] !== undefined)
        return "a trail job merge is handed off only as bercail job merge trail:<n> [--change <repo>/<n>] [--repo DIR]";
      flags[words[i]] = words[i + 1];
    }
    const job = /^trail:([1-9][0-9]{0,8})$/.exec(words[3] ?? "");
    const change = flags["--change"];
    if (!job || (change !== undefined && !/^[\w.-]+\/[1-9][0-9]*$/.test(change)))
      return "a trail job merge names its trail as trail:<n>, and a change as <repo>/<n>";
    if (flags["--repo"] !== undefined) dir = placeIn(dir, flags["--repo"]);
    if (dir === undefined) return "its --repo names no one folder";
    return { kind: "trail merge", dir, trail: change ?? job[1], job: words[3] };
  }
  // A desk answer's Yes goes to a card only in its one shape; a No or a --dry-run runs unasked.
  if (answersDesk(words) && !deskYes(words) && !deskAnswerArgs(words)?.dry && deskAnswerArgs(words)?.answer !== "no")
    return "a desk answer's Yes is handed off only as bercail desk answer DESK yes --prompt ID";
  if (basename(words[0]) === "git") {
    let i = 1;
    if (words[1] === "-C") {
      dir = words[2] ? placeIn(dir, words[2]) : undefined;
      i = 3;
    }
    if (dir === undefined) return "its git -C names no one folder";
    const [sub, remote, ...refspecs] = words.slice(i);
    // A restack's push names its worktree with -C, as an absolute path, and nothing else.
    const restack = sub === "push" ? restackOf(words.slice(i + 1)) : undefined;
    if (restack && (segments.length !== 1 || i !== 3 || !isAbsolute(words[2])))
      return "a restack's push names its worktree as git -C <absolute path>, with no cd";
    if (restack) return { kind: "push", dir, remote: restack.remote, refspecs: [restack.spec], lease: restack.lease };
    if (sub !== "push" || !remote || !refspecs.length || [remote, ...refspecs].some((w) => w.startsWith("-")))
      return "a push is handed off only as git [-C DIR] push REMOTE REFSPEC..., with no flags, or a restack as git -C <worktree> push --force-with-lease=refs/heads/<branch>:<old head> REMOTE <new head>:refs/heads/<branch>";
    if (!remoteName.test(remote)) return "it pushes to a URL, not a remote's name";
    return { kind: "push", dir, remote, refspecs };
  }
  return { kind: "command", dir, argv: words };
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
        failed(
          Object.assign(new Error(`${command} ${args.slice(0, 3).join(" ")}: ${why}`), {
            code: error.code,
            program: basename(command),
          }),
        );
      },
    ),
  );

// A failed read in the guard's own words: the program and its exit code or errno, never
// its output, which may quote a token or a config file.
function readFailure(error: unknown): string {
  const { program, code } = error as { program?: string; code?: unknown };
  const errno = typeof code === "string" && /^E[A-Z]+$/.test(code) ? ` (${code})` : "";
  const how = typeof code === "number" ? ` with exit ${code}` : errno;
  if (program) return `${program} failed${how}`;
  return error instanceof SyntaxError ? "a read gave output that is not the JSON it expects" : "a read failed";
}

// The push URLs a card can show (shep/pi/question-target.ts showable): a path, ssh with
// no password, or http(s), git:// or entire:// with no user, and none with a query or a space.
const showableUrl = [
  /^\/[^\s?#]*$/,
  /^file:\/\/\/[^\s?#]*$/,
  /^[\w.-]+@[\w.-]+:[^\s?#]*$/,
  /^(ssh|git\+ssh|ssh\+git):\/\/([\w.-]+@)?[\w.-]+(:\d+)?\/[^\s?#]*$/,
  /^(https?|git|entire):\/\/[\w.-]+(:\d+)?\/[^\s?#@]*$/,
];

// A push URL as the card names it: an entire:// remote as the Entire project it is.
export function urlText(url: string): string {
  const entire = /^entire:\/\/[^/]+\/(.+)$/.exec(url);
  return entire ? `the Entire project ${entire[1]} (${url})` : url;
}

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
async function pinTrail(read: Read, dir: string, trail: string | null, job?: string) {
  const here = realpathSync(await read("git", ["-C", dir, "rev-parse", "--show-toplevel"], dir));
  const worktrees = await read("git", ["-C", here, "worktree", "list", "--porcelain"], here);
  const checkout = realpathSync(worktrees.split("\n")[0].slice("worktree ".length));
  const args = ["trail", "show", ...(trail ? [trail] : []), "--json"];
  let shown;
  try {
    // A job merge runs in the main checkout, so it is read there: what entire shows is what runs.
    shown = JSON.parse(await read(process.env.ENTIRE_BIN || "entire", args, job ? checkout : here));
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
  // A change of another trail is not this job's to merge or close.
  if (job && `trail:${shown.number}` !== job) fail(`${change.repository}/${change.number} is not a change of ${job}`);
  return {
    kind: "trail merge" as const,
    checkout,
    trailId: shown.id,
    change: `${change.repository}/${change.number}`,
    head,
    base: change.base,
    ...(job ? { job } : {}),
  };
}

// A journal in bercail's state folder, oldest first. Each line must be an object, as jq's
// select over the file needs.
function journal(name: string): any[] {
  let lines: string[] = [];
  try {
    lines = readFileSync(join(stateDir(), name), "utf8").split("\n");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  return lines.flatMap((line, i) => {
    if (!line.trim()) return [];
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {}
    if (typeof entry !== "object" || entry === null || Array.isArray(entry))
      fail(`${name} line ${i + 1} is not a JSON object`);
    return [entry];
  });
}

// The handoffs that name a checkout's path, oldest first.
const handoffsAt = (path: string) => journal("handoffs.jsonl").filter((handoff) => handoff.path === path);

// A cleanup --gone's checkout, as bercail cleanup --gone checks it, and stricter: nothing
// at its path, and handoffs that name it, all of one repo whose top folder git no longer
// lists it in. Dispatch retires every handoff at the path, so the repo whose policy speaks
// for it must own them all; their count pins them, so a later handoff there moves it.
// A handoff from before records carried repo proposes one by its path, as worktrunk puts
// a checkout beside the main one (<repo>.<branch, / and \ as ->), and the job's issue in
// that repo's beads binds it: handoff-spawn commented the checkout's path and branch there.
async function pinGone(read: Read, path: string) {
  // The journal bercail reads from /, as its shell spells it: join() would resolve a
  // relative root against Pi's folder, and collapse a .. that bash follows after a symlink.
  const root = process.env.XDG_STATE_HOME || process.env.HOME || "";
  if (!isAbsolute(root) || /(^|\/)\.\.(\/|$)/.test(root))
    fail("the state folder (XDG_STATE_HOME, else HOME) is not an absolute path without ..");
  // Gone only when lstat says so: a folder it cannot read is not known to be gone.
  let there = true;
  try {
    lstatSync(path);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "ENOENT" && code !== "ENOTDIR") throw error;
    there = false;
  }
  if (there) fail(`${path} is still there; bercail cleanup ${path} retires it`);
  const named = handoffsAt(path);
  if (!named.length) fail(`no handoff names ${path}, so no job waits on it`);
  const repoOf = (handoff: { repo?: unknown; branch?: unknown }) => {
    if (handoff.repo !== undefined && handoff.repo !== null) return handoff.repo;
    if (typeof handoff.branch !== "string" || !handoff.branch) return undefined;
    const suffix = `.${handoff.branch.replace(/[/\\]/g, "-")}`;
    return path.endsWith(suffix) && basename(path) !== suffix ? path.slice(0, -suffix.length) : undefined;
  };
  const repos = new Set(named.map(repoOf));
  const [recorded] = repos;
  if (repos.size !== 1 || typeof recorded !== "string" || !isAbsolute(recorded))
    fail(`the handoffs of ${path} name no one repo, whose policy could speak for them all`);
  const last = named.at(-1);
  if (last.branch !== undefined && typeof last.branch !== "string")
    fail(`the handoff of ${path} names a branch that is not text`);
  const repo = realpathSync(recorded);
  if (realpathSync(await read("git", ["-C", repo, "rev-parse", "--show-toplevel"], repo)) !== repo)
    fail(`the handoffs of ${path} name ${recorded}, which is not a repo's top folder`);
  const worktrees = await read("git", ["-C", repo, "worktree", "list", "--porcelain"], repo);
  const unrecorded = named.filter((handoff) => handoff.repo === undefined || handoff.repo === null);
  if (unrecorded.length && realpathSync(worktrees.split("\n")[0].slice("worktree ".length)) !== repo)
    fail(`the handoffs of ${path} name ${recorded}, which is not a repo's main checkout`);
  const bd = (...args: string[]) => read(process.env.HANDOFF_BD_BIN || "bd", [...args, "--json", "--readonly"], repo);
  // bd may read another store than the folder's own (BEADS_DIR, a redirect): only its own vouches.
  if (unrecorded.length && JSON.parse(await bd("context"))?.beads_dir !== join(repo, ".beads"))
    fail(
      `bd in ${recorded} reads another store than ${join(repo, ".beads")}, so its issues cannot say it owns ${path}`,
    );
  for (const { issue, branch } of unrecorded) {
    if (typeof issue !== "string" || !/^[a-z0-9][\w.-]*$/i.test(issue))
      fail(`a handoff of ${path} names no repo and no issue whose beads could say which repo owns it`);
    const said = `linked worktree ${path} (branch ${branch})`;
    const comments = JSON.parse(await bd("comments", issue));
    const intro = (c: { text?: unknown }) =>
      typeof c?.text === "string" && c.text.startsWith("bercail handoff: ") && c.text.includes(said);
    if (!Array.isArray(comments) || !comments.some(intro))
      fail(`no comment on ${issue} in ${recorded}'s beads says "${said}", so ${recorded} is not known to own it`);
  }
  if (worktrees.split("\n").includes(`worktree ${path}`))
    fail(`git still lists ${path} as a worktree; run git -C ${repo} worktree prune first`);
  return {
    kind: "cleanup" as const,
    gone: true as const,
    path,
    repo,
    branch: last.branch || null,
    handoffs: named.length,
  };
}

// The objects an operation acts on now. It throws when they cannot be pinned.
export async function pinOperation(op: GuardOp, read: Read = readOut): Promise<GuardFacts> {
  if (op.kind === "trail merge") return pinTrail(read, op.dir, op.trail, op.job);
  if (op.kind === "cleanup" && op.gone) return pinGone(read, op.path);
  // Its folder by its real path, so a symlink moved later cannot send it elsewhere.
  if (op.kind === "command" && editsConfig(op.argv)) return pinConfigEdit(read, realpathSync(op.dir), op.argv);
  if (op.kind === "command" && answersDesk(op.argv)) return pinDeskAnswer(read, op.dir, op.argv);
  if (op.kind === "command") return { kind: "command", dir: realpathSync(op.dir), argv: op.argv };
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
  const url = await pinUrl(read, dir, op.remote);
  if (!op.lease) return { kind: "push", dir, gitDir, url, refspecs };
  if (realpathSync(op.dir) !== dir) fail(`${op.dir} is not the worktree's top folder`);
  await pinLease(read, dir, url, op.refspecs[0], refspecs[0], op.lease.old);
  return { kind: "push", dir, gitDir, url, refspecs, lease: op.lease };
}

// A restack's push publishes a desk's own branch as the desk left it, over the head the
// remote has now: the last handoff that started a desk in the checkout names that branch,
// and bercail cleanup has not retired the checkout since (as dispatch reads them,
// lib/shep-task.ts); the checkout is on the branch at the new head Shep named; and on the
// remote the branch is at the old head and is neither main, master nor the default branch.
// Each read fails closed.
async function pinLease(read: Read, dir: string, url: string, asked: string, pinned: string, old: string) {
  const [head, ref] = pinned.split(":");
  const branch = ref.slice("refs/heads/".length);
  if (isMainRef(ref)) fail(leaseToMain);
  if (asked.split(":")[0] !== head) fail(`${asked.split(":")[0]} is not a commit's full hash`);
  const desk = handoffsAt(dir)
    .filter((handoff) => handoff.desk && handoff.ok !== false && handoff.agent_started !== false)
    .at(-1);
  if (desk?.branch !== branch) fail(`no desk's handoff names ${dir} on ${branch}, so it is no desk's own branch`);
  if (journal("retired.jsonl").some((line) => line.path === dir && !(String(line.at) < String(desk.at ?? ""))))
    fail(`bercail cleanup retired ${dir} after its desk started, so it is no desk's own checkout`);
  const git = (...args: string[]) =>
    read("git", ["-C", dir, ...args], dir).catch((error) => (error.code === 1 ? "" : Promise.reject(error)));
  // The same path in another repo is another checkout. NUL-separated: a path can hold a newline.
  const main = (await git("worktree", "list", "--porcelain", "-z")).split("\0")[0].slice("worktree ".length);
  let recorded = "";
  try {
    recorded = isAbsolute(desk.repo) ? realpathSync(desk.repo) : "";
  } catch {}
  if (!recorded || !main || recorded !== realpathSync(main))
    fail(`the handoff of ${dir} names the repo ${desk.repo}, not this checkout's ${main || "unknown repo"}`);
  if ((await git("symbolic-ref", "-q", "HEAD")) !== ref)
    fail(`${dir} is not on ${branch}: a restack's push publishes the checkout's own branch`);
  const now = await git("rev-parse", "--verify", "HEAD^{commit}");
  if (now !== head) fail(`${branch} is at ${now || "no commit"} in ${dir}, not ${head}`);
  const there = (await read("git", ["-C", dir, "ls-remote", "--symref", url, "HEAD", ref], dir)).split("\n");
  const trunk = there.find((line) => line.startsWith("ref: ") && line.endsWith("\tHEAD"))?.slice(5, -5);
  if (!trunk) fail(`the guard cannot read the default branch of ${urlText(url)}`);
  if (trunk === ref) fail(`${branch} is the default branch of ${urlText(url)}`);
  const remoteHead = there.find((line) => line.endsWith(`\t${ref}`))?.split("\t")[0];
  if (remoteHead !== old)
    fail(`${branch} is at ${remoteHead ?? "nothing"} on ${urlText(url)}, not the old head ${old}`);
}

// A config.toml edit, run by bercail itself, never the program Shep named: the lines
// its --dry-run adds and removes now, under the file's name. The card shows them. The
// worker runs it with --expect and their hash, so bercail writes only that edit, under
// its lock; the card is stale once they read otherwise.
async function pinConfigEdit(read: Read, dir: string, words: string[]) {
  const [, area, verb] = words;
  if (
    basename(words[0]) !== "bercail" ||
    !["config set", "config unset", "routine enable", "routine disable"].includes(`${area} ${verb}`) ||
    words.includes("--expect")
  )
    fail("a config change is handed off only as bercail config set|unset … or bercail routine enable|disable …");
  const bin = process.env.BERCAIL_BIN || "bercail";
  const shown = await read(bin, [...words.slice(1), "--dry-run"], dir);
  const lines = shown.split("\n").filter((line) => /^[-+]/.test(line));
  const diff = lines.length ? lines.join("\n") : shown;
  const argv = [bin, ...words.slice(1), "--expect", createHash("sha256").update(diff).digest("hex")];
  return { kind: "command" as const, dir, argv, diff };
}

// A desk answer's Yes, run by bercail itself in the desk's worktree: the prompt as its
// --dry-run reads it now, which the card shows. The worker pins it again while the card
// waits and before it runs, so a prompt that closed or changed withdraws the card.
async function pinDeskAnswer(read: Read, dir: string, words: string[]) {
  if (!deskYes(words)) fail("a desk answer's Yes is handed off only as bercail desk answer DESK yes --prompt ID");
  const bin = process.env.BERCAIL_BIN || "bercail";
  const prompt = JSON.parse(await read(bin, ["desk", "prompt", words[3]], dir)) as { id?: unknown; cwd?: unknown };
  if (prompt.id !== words[6] || typeof prompt.cwd !== "string" || !isAbsolute(prompt.cwd))
    fail(`desk ${words[3]} has another prompt waiting now, or none`);
  const desk = realpathSync(prompt.cwd);
  const answer = await read(bin, [...words.slice(1), "--dry-run"], desk);
  return { kind: "command" as const, dir: desk, argv: [bin, ...words.slice(1)], answer };
}

// The fixed argv the worker runs, and where: never the text Shep wrote. A push goes
// to the pinned URL with no tags or submodules a config could add, each commit as
// <hash>^{commit}, which no ref named like the hash can shadow.
export function runOf(facts: GuardFacts): { argv: string[]; cwd: string } {
  if (facts.kind === "command") return { argv: facts.argv, cwd: facts.dir };
  if (facts.kind === "cleanup" && "gone" in facts)
    return { argv: [process.env.BERCAIL_BIN || "bercail", "cleanup", "--gone", facts.path], cwd: "/" };
  if (facts.kind === "cleanup")
    return { argv: [process.env.BERCAIL_BIN || "bercail", "cleanup", facts.worktree], cwd: "/" };
  if (facts.kind === "trail merge" && facts.job)
    return {
      argv: [
        process.env.BERCAIL_BIN || "bercail",
        "job",
        "merge",
        facts.job,
        "--change",
        facts.change,
        "--repo",
        facts.checkout,
      ],
      cwd: facts.checkout,
    };
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
      ...(facts.lease ? [`--force-with-lease=${facts.lease.ref}:${facts.lease.old}`] : []),
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
  missed?: string,
): Promise<{ handed: boolean; reason: string }> {
  // Why its repo's shep_may_run did not let it run with no card, so the next miss shows.
  const note = missed ? ` shep_may_run did not apply: ${missed.replace(/\.$/, "")}.` : "";
  const refused = (why: string) => ({
    handed: false,
    reason: `${asked} Shep's session never waits on a confirm, and this could not go to a Decisions card: ${why}. Run it as one command of its own, as written, after at most one cd DIR && (a push as git -C DIR push REMOTE BRANCH, a trail merge as bercail job merge trail:<n> [--change <repo>/<n>] --repo DIR), or leave it to the person.${note}`,
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
    reason: `Handed off, not run: the person answers this ${opWhat(facts)} on a Decisions card, and the worker ${worker} runs it only on their Allow within the hour, or, if nobody answers and the card says it defaults to Allow, at its deadline. Tell the person in one line that the card is up. Do not retry it, wait for it or run it another way; your turn goes on. Its outcome comes back as a guard event; report it then.${note}`,
  };
}

// What runs in place of Shep's command when it is one operation its repo lets Shep run
// with no card (withoutCard), pinned as a card's would be: the argv a card's worker
// would run (runOf), in its folder, never Shep's own words; and the warning it runs with.
// Missed, and it goes to a card that says why, when it is not alone in its message
// (notAlone), or Shep's environment holds a git variable the pinning reads dropped
// (cleanEnv), so bash would read another repo or config. Undefined when it is no
// operation shep_may_run could name.
async function optedIn(
  command: string,
  input: GuardInput,
  notAlone: string | undefined,
): Promise<{ command: string; why: string } | { missed: string } | undefined> {
  const op = guardOperation(command, input.cwd, input.home);
  if (typeof op === "string" || !mayRunOp(op)) return undefined;
  if (notAlone) return { missed: notAlone };
  // Before any read: a PATH the reads and bash would search differently.
  if (!absolutePath()) return { missed: "Shep's PATH has a folder that is not absolute" };
  const git = Object.keys(process.env).find(
    (key) => gitPlace.test(key) || gitConfigVar.test(key) || key.startsWith("GIT_ALTERNATE"),
  );
  if (git) return { missed: `Shep's environment sets ${git}, which bash would read and the guard's reads drop` };
  let facts: GuardFacts;
  try {
    facts = await pinOperation(op);
  } catch {
    // handOff pins it again, and says why if that fails too.
    return { missed: "the guard could not pin what it acts on" };
  }
  const verdict = await withoutCard(facts);
  if (!verdict.run) return { missed: verdict.why };
  const { argv, cwd } = runOf(facts);
  // The program by its real path, as the guard's reads found it on PATH: bash's own lookup
  // could find another.
  const program = executable(argv[0]);
  if (!program) return { missed: `the guard found no ${argv[0]} to run on Shep's PATH` };
  const run = `cd ${shellWord(cwd)} && GIT_TERMINAL_PROMPT=0 ${argvText([program, ...argv.slice(1)])}`;
  return { command: run, why: `${verdict.why} It runs as: ${run}` };
}

// An operation shep_may_run could name, read from Shep's words: a cleanup, a trail job's
// merge, or an entire trail link of any shape (withoutCard says which shape it takes).
const mayRunOp = (op: GuardOp) =>
  op.kind === "cleanup" ||
  (op.kind === "trail merge" && op.job !== undefined) ||
  (op.kind === "command" && op.argv[1] === "trail" && op.argv[2] === "link" && basename(op.argv[0]) === "entire");

// Every PATH folder absolute: an empty or relative one is the current folder, which
// differs between the guard's reads and bash.
const absolutePath = () => {
  const dirs = (process.env.PATH ?? "").split(":");
  return dirs.every((dir) => dir && isAbsolute(dir)) ? dirs : undefined;
};

// A program as execFile finds it, by its real path: an absolute path as it is, a bare
// name in the first PATH folder that holds it. Undefined for a relative path, a PATH
// with a folder that is not absolute, or a program that is not there.
function executable(name: string): string | undefined {
  if (name.includes("/") && !isAbsolute(name)) return undefined;
  const dirs = name.includes("/") ? [dirname(name)] : absolutePath();
  for (const dir of dirs ?? []) {
    const path = join(dir, basename(name));
    try {
      if (statSync(path).isFile()) {
        accessSync(path, fsConstants.X_OK);
        return realpathSync(path);
      }
    } catch {}
  }
  return undefined;
}

// The operation in a few words, and what it acts on, for the card and the event.
export function opTarget(facts: GuardFacts): string {
  if (facts.kind === "command") return argvText(facts.argv);
  if (facts.kind === "cleanup") return "gone" in facts ? facts.path : facts.worktree;
  if (facts.kind === "trail merge") return facts.change;
  return `${urlText(facts.url)} ${facts.refspecs.map((spec) => spec.split(":")[1]).join(" ")}`;
}

// "push of <target>", or "command <its words>".
export const opWhat = (facts: GuardFacts) =>
  facts.kind === "command"
    ? `command ${opTarget(facts)}`
    : `${"lease" in facts && facts.lease ? "force-with-lease push" : facts.kind}${"gone" in facts ? " --gone" : ""} of ${opTarget(facts)}`;

// An unanswered guard card counts as an Allow at its deadline only when what it runs
// stays private or local (bercail-mdfb, docs/plans/guard-default-allow.md); anything
// else waits for the person and counts as a Deny. Read from the remote, never the words.

/** Whether a card nobody answered counts as an Allow at its deadline, and why. */
export type GuardDefault = { defaults: boolean; why: string };

const waits = (why: string): GuardDefault => ({ defaults: false, why });
const repoPart = /^[\w.-]+$/;

// A remote URL's repo: gh/<owner>/<repo> on github.com over ssh or https, or the
// forge/project/repo an entire:// URL names. Undefined for a path or another host.
function repoOfUrl(url: string): [string, string, string] | undefined {
  const gh =
    /^(?:git@github\.com:|ssh:\/\/git@github\.com\/|https:\/\/github\.com\/)([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/.exec(
      url,
    );
  if (gh) return ["gh", gh[1], gh[2]];
  const entire = /^entire:\/\/[\w.-]+(?::\d+)?\/(et|gh)\/([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/.exec(url);
  return entire ? [entire[1], entire[2], entire[3]] : undefined;
}

// What the remote's own forge says of it: "the private ..." when it is private, else
// why it waits. A GitHub repo by gh on github.com; an Entire-native one by entire, asked
// with its clone URL, so the cluster that holds it answers. Only an exact PRIVATE, or
// private: true for the repo asked, is private; a failed read or another answer waits.
// What it says names the repo by its forge's ID and URL, so a repo replaced under the
// same name, or another cluster's, reads otherwise.
async function privateRepo(read: Read, url: string, dir: string): Promise<{ what: string } | { why: string }> {
  const repo = repoOfUrl(url);
  // A URL a card could not show may hold a credential: it is not named.
  if (!repo)
    return {
      why: `the guard cannot tell whether ${showableUrl.some((shape) => shape.test(url)) ? urlText(url) : "this origin"} is private`,
    };
  const [forge, owner, name] = repo;
  // Entire's mirror of a GitHub repo: GitHub's visibility says nothing of who reads Entire's copy.
  if (forge === "gh" && url.startsWith("entire://"))
    return { why: `${urlText(url)} mirrors a GitHub repo, so the guard cannot tell who sees it` };
  try {
    if (forge === "gh") {
      const shown = JSON.parse(
        await read("gh", ["repo", "view", `github.com/${owner}/${name}`, "--json", "visibility,id"], dir),
      );
      if (typeof shown?.id !== "string" || !shown.id) return { why: `gh named no repo ID for ${owner}/${name}` };
      if (shown.visibility === "PRIVATE") return { what: `the private GitHub repo ${owner}/${name} (${shown.id})` };
      return { why: `the GitHub repo ${owner}/${name} is ${String(shown.visibility ?? "unknown").toLowerCase()}` };
    }
    const shown = JSON.parse(await read(process.env.ENTIRE_BIN || "entire", ["repo", "view", url, "--json"], dir));
    if (
      shown?.repo === `/et/${owner}/${name}` &&
      shown.private === true &&
      typeof shown.repoId === "string" &&
      shown.repoId
    )
      return { what: `the private Entire repo et/${owner}/${name} (${shown.repoId}, ${url})` };
    return {
      why: `the Entire repo et/${owner}/${name} is ${shown?.private === false ? "public" : "of unknown visibility"}`,
    };
  } catch (error) {
    return {
      why: `the guard could not read whether ${forge}/${owner}/${name} is private (${readFailure(error)})`,
    };
  }
}

// The checkout's origin: one URL that it fetches from and pushes to alike, a path by its
// real path. A split or doubled origin, whose repo the policy may not speak for, throws.
async function ownOrigin(read: Read, dir: string): Promise<string> {
  const urls = async (...flags: string[]) =>
    (await read("git", ["-C", dir, "remote", "get-url", ...flags, "--all", "origin"], dir)).split("\n").filter(Boolean);
  const [fetch, push] = [await urls(), await urls("--push")];
  if (fetch.length !== 1 || push.length !== 1 || fetch[0] !== push[0])
    fail("origin is not one URL it both fetches from and pushes to");
  return fetch[0].startsWith("/") && onDisk(fetch[0]) ? realpathSync(fetch[0]) : fetch[0];
}

// Where Entire's pre-push hook sends checkpoints (full agent transcripts) beside a push:
// nowhere, origin, or elsewhere (lib/doctor.sh reads the same settings).
function checkpointsGo(top: string): "nowhere" | "origin" | "elsewhere" {
  let settings: Record<string, any> = {};
  for (const file of ["settings.json", "settings.local.json"])
    try {
      const value = JSON.parse(readFileSync(join(top, ".entire", file), "utf8"));
      settings = {
        ...settings,
        ...value,
        strategy_options: { ...settings.strategy_options, ...value?.strategy_options },
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") return "elsewhere";
    }
  const options = settings.strategy_options ?? {};
  if (options.push_sessions === false) return "nowhere";
  return options.checkpoint_remote === undefined ? "origin" : "elsewhere";
}

// entire trail link <P> --branch B [--base B] [--json]: a link of the branch it names, in
// the checkout's origin's project. Any other flag (a create, a status, another repo), or
// none naming the branch (the checkout's current one, which can move), waits.
function plainLink(argv: string[]): boolean {
  // The entire it runs is the one the guard reads with: no path, no other ENTIRE_BIN.
  return argv[0] === "entire" && (process.env.ENTIRE_BIN ?? "entire") === "entire" && linkedBranch(argv) !== undefined;
}

// The branch a plain link (above) names, whatever runs it; undefined for any other shape.
function linkedBranch(words: string[]): string | undefined {
  const [, trail, link, number, ...flags] = words;
  if (trail !== "trail" || link !== "link" || !/^[1-9]\d{0,8}$/.test(number ?? "")) return undefined;
  const values = new Map<string, string>();
  for (let i = 0; i < flags.length; i++) {
    const flag = flags[i];
    if (values.has(flag)) return undefined;
    values.set(flag, "");
    if (flag === "--json") continue;
    if (
      !["--branch", "--base"].includes(flag) ||
      !/^[\w./-]+$/.test(flags[i + 1] ?? "") ||
      flags[i + 1].startsWith("-")
    )
      return undefined;
    values.set(flag, flags[++i]);
  }
  return values.get("--branch");
}

// What a repo's trusted policy and Entire settings say, as bercail policy show reads them.
async function policyOf(
  read: Read,
  dir: string,
): Promise<{ mergeReversible: boolean; entire: boolean; shepMayRun: string[] }> {
  const shown = JSON.parse(await read(process.env.BERCAIL_BIN || "bercail", ["policy", "show", "--json", dir], dir));
  const list = shown?.policy?.shep_may_run;
  return {
    mergeReversible: shown?.policy?.merge_reversible === true,
    entire: shown?.entire === true,
    shepMayRun: Array.isArray(list) ? list.filter((item: unknown) => typeof item === "string") : [],
  };
}

// The repo an operation acts on, read private or local, in words that name it by its
// forge's ID and URL; or why not. A cleanup's is its worktree's origin. A push goes to
// the checkout's own origin, with Entire's checkpoints nowhere else. A trail's change, or
// the trail a link names, is in the checkout's own Entire-native repo, whose project is
// the trail's audience. It throws on a read that fails.
async function privateTarget(
  facts: GuardFacts,
  read: Read,
  dir: string,
  entire: boolean,
): Promise<{ what: string } | { why: string }> {
  if (facts.kind === "cleanup") {
    const seen = await privateRepo(read, await ownOrigin(read, dir), dir);
    return "what" in seen ? { what: `${"gone" in facts ? "a gone checkout" : "a worktree"} of ${seen.what}` } : seen;
  }
  if (facts.kind === "push") {
    // The policy read speaks for this repo's own remote, and Entire's hook pushes beside it.
    if ((await ownOrigin(read, dir)) !== facts.url)
      return { why: `it pushes to ${urlText(facts.url)}, not this repo's origin` };
    if (entire && checkpointsGo(dir) === "elsewhere")
      return { why: "Entire's pre-push hook would push checkpoints to another remote too" };
    if (facts.url.startsWith("/")) return { what: `it pushes to the repo ${facts.url} on this machine` };
    const seen = await privateRepo(read, facts.url, dir);
    return "what" in seen ? { what: `it pushes to ${seen.what}` } : seen;
  }
  const origin = await ownOrigin(read, dir);
  const repo = repoOfUrl(origin);
  if (repo?.[0] !== "et" || !origin.startsWith("entire://"))
    return { why: "its trail is not in an Entire-native repo, so the guard cannot tell who sees it" };
  if (facts.kind === "trail merge") {
    const shown = JSON.parse(
      await read(process.env.ENTIRE_BIN || "entire", ["trail", "show", facts.change, "--json"], dir),
    );
    const ref = shown?.project?.reference;
    if (
      shown?.id !== facts.trailId ||
      !repoPart.test(ref?.forge ?? "") ||
      !repoPart.test(ref?.project ?? "") ||
      `${ref.forge}/${ref.project}/${facts.change.split("/")[0]}` !== repo.join("/")
    )
      return { why: `${facts.change} is not a change in this checkout's own repo, whose policy is the one read` };
  }
  const seen = await privateRepo(read, origin, dir);
  const what = facts.kind === "trail merge" ? `it merges ${facts.change}` : "it links a branch";
  return "what" in seen ? { what: `${what} in ${seen.what}` } : seen;
}

// The folder whose repo's policy speaks for these facts; a gone checkout's, its handoff's repo.
export const factsDir = (facts: GuardFacts) =>
  facts.kind === "trail merge"
    ? facts.checkout
    : facts.kind === "cleanup"
      ? "gone" in facts
        ? facts.repo
        : facts.worktree
      : facts.dir;

// Whether a card for these pinned facts defaults to Allow at its deadline. A cleanup is
// local. A push, a trail merge or a trail link defaults only in a repo whose trusted
// policy says merge_reversible = true, and only while its target reads private
// (privateTarget). Each call reads afresh; it never throws, and anything it cannot read
// waits. The why names the repo, so a card defaults only while it reads the same.
export async function guardDefault(facts: GuardFacts, read: Read = readOut): Promise<GuardDefault> {
  if (facts.kind === "cleanup" && "gone" in facts)
    return { defaults: true, why: "a cleanup --gone is local: it only records that the gone checkout is retired" };
  if (facts.kind === "cleanup")
    return { defaults: true, why: "a cleanup is local: the worktree goes, and its branch stays" };
  if (facts.kind === "command" && !plainLink(facts.argv))
    return waits("the guard does not class this command as private or local");
  if (facts.kind === "push" && facts.lease)
    return waits("a force-with-lease push replaces the branch's history on the remote");
  const dir = factsDir(facts);
  try {
    const policy = await policyOf(read, dir);
    if (!policy.mergeReversible) return waits("the repo's trusted policy does not say merge_reversible = true");
    const seen = await privateTarget(facts, read, dir, policy.entire);
    return "what" in seen ? { defaults: true, why: seen.what } : waits(seen.why);
  } catch (error) {
    return waits(`the guard could not read what it acts on (${(error as Error).message})`);
  }
}

// The operation's name in shep_may_run: a cleanup, a trail job's merge, or a trail link.
function mayRunName(facts: GuardFacts): string | undefined {
  if (facts.kind === "cleanup") return facts.kind;
  // A trail job's merge (bercail job merge), which checks the job and closes it: not a bare entire trail merge.
  if (facts.kind === "trail merge" && facts.job) return facts.kind;
  if (facts.kind === "command" && plainLink(facts.argv)) return "trail link";
}

// Whether Shep runs these pinned facts with no card: the repo's trusted policy lists the
// operation in shep_may_run (Simon's opt-in, bercail-mdfb), and its target reads private.
// The warning it runs with, or why it goes to a card. It never throws.
export async function withoutCard(facts: GuardFacts, read: Read = readOut): Promise<{ run: boolean; why: string }> {
  const name = mayRunName(facts);
  if (!name && facts.kind === "command" && facts.argv[1] === "trail" && facts.argv[2] === "link")
    return {
      run: false,
      why: "its trail link is only entire trail link <n> --branch <branch> [--base <branch>] [--json], run as entire with no ENTIRE_BIN",
    };
  if (!name) return { run: false, why: "shep_may_run names no such operation" };
  const dir = factsDir(facts);
  try {
    const policy = await policyOf(read, dir);
    if (!policy.shepMayRun.includes(name))
      return { run: false, why: `the trusted policy that ${dir} reads does not list "${name}" in shep_may_run` };
    const seen = await privateTarget(facts, read, dir, policy.entire);
    if (!("what" in seen)) return { run: false, why: seen.why };
    return {
      run: true,
      why: `Allowed with no guard card: the repo's trusted policy lists "${name}" in shep_may_run, and ${seen.what}. Say in your report what it did.`,
    };
  } catch (error) {
    return { run: false, why: `the guard could not read what it acts on (${readFailure(error)})` };
  }
}

/** A desk's guard prompt while it waits, which bercail desk prompt shows and desk answer answers. */
export type DeskPrompt = {
  v: 1;
  id: string;
  address: string;
  pid: number;
  session: string;
  cwd: string;
  tool: string;
  command: string;
  reason: string;
  at: string;
};
export type DeskAnswer = { id: string; answer: "yes" | "no"; reason: string };

// desk-prompts/<address>.json: the prompt; .answer.json: bercail desk answer's, with its
// writer's nonce; .done-<nonce>.json: the guard's receipt for that writer's answer.
export const deskPrompts = () => join(stateDir(), "desk-prompts");
const answerPoll = () => Number(process.env.BERCAIL_DESK_ANSWER_POLL_MS) || 500;

function writeWhole(path: string, text: string): void {
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, `${text}\n`, { mode: 0o600 });
  renameSync(tmp, path);
}

// The answer file, taken once: renamed before it is read, so no reader finds it twice.
// undefined: none; null: one that does not parse.
function takeAnswer(base: string): unknown {
  const taken = `${base}.answer.taken-${process.pid}`;
  try {
    renameSync(`${base}.answer.json`, taken);
  } catch {
    return undefined;
  }
  try {
    return JSON.parse(readFileSync(taken, "utf8"));
  } catch {
    return null;
  } finally {
    rmSync(taken, { force: true });
  }
}

function answerFor(got: unknown, id: string): DeskAnswer | string {
  const a = got as Partial<DeskAnswer> | null;
  if (!a || typeof a !== "object" || a.id !== id) return "it answers another prompt";
  if ((a.answer !== "yes" && a.answer !== "no") || typeof a.reason !== "string") return "it is not yes or no";
  if (a.answer === "no" && !a.reason.trim()) return "a no gives its reason";
  return { id, answer: a.answer, reason: a.reason };
}

// The person's confirm, raced with an answer from outside the desk (bercail desk answer).
// The first settles it. The confirm resolving clears the poll in the same run of microtasks,
// before its next tick; an answer taken first gets its receipt, then closes the confirm.
// With nowhere to publish the prompt, the person alone answers.
export async function confirmOrAnswer(
  confirm: (title: string, message: string, opts?: { signal?: AbortSignal }) => Promise<boolean>,
  title: string,
  prompt: DeskPrompt,
): Promise<{ yes: boolean; answer?: DeskAnswer }> {
  const base = join(deskPrompts(), prompt.address);
  try {
    mkdirSync(deskPrompts(), { recursive: true, mode: 0o700 });
    writeWhole(`${base}.json`, JSON.stringify(prompt));
  } catch {
    return { yes: await confirm(title, prompt.reason) };
  }
  const controller = new AbortController();
  let answer: DeskAnswer | undefined;
  const poll = setInterval(() => {
    if (answer) return;
    const got = takeAnswer(base);
    if (got === undefined) return;
    const { id = null, nonce } = (got ?? {}) as { id?: unknown; nonce?: unknown };
    // No nonce, no receipt its writer can find: it is dropped, and nothing is answered.
    if (typeof nonce !== "string" || !/^[0-9a-f]{32}$/.test(nonce)) return;
    const read = answerFor(got, prompt.id);
    const at = new Date().toISOString();
    try {
      writeWhole(
        `${base}.done-${nonce}.json`,
        JSON.stringify(
          typeof read === "string"
            ? { id, nonce, status: "refused", why: read, at }
            : { id, nonce, status: "taken", answer: read.answer, at },
        ),
      );
    } catch {
      // Its writer could not learn what came of it: act on nothing.
      return;
    }
    if (typeof read === "string") return;
    answer = read;
    controller.abort();
  }, answerPoll());
  try {
    const yes = await confirm(title, prompt.reason, { signal: controller.signal });
    return answer ? { yes: answer.answer === "yes", answer } : { yes };
  } finally {
    clearInterval(poll);
    try {
      if (JSON.parse(readFileSync(`${base}.json`, "utf8")).id === prompt.id) rmSync(`${base}.json`, { force: true });
    } catch {}
  }
}

// What a desk's lead publishes while it asks: only a desk (role "" in a named terminal) has
// a prompt bercail desk answer can reach.
function deskPromptOf(
  role: string,
  ctx: { cwd: string; sessionManager?: { getSessionId?: () => string } },
  tool: string,
  command: string,
  reason: string,
): DeskPrompt | undefined {
  const address = process.env.HC_TERMINAL_ID ?? "";
  if (role !== "" || !/^[\w.-]+$/.test(address)) return undefined;
  return {
    v: 1,
    id: randomUUID(),
    address,
    pid: process.pid,
    session: ctx.sessionManager?.getSessionId?.() ?? "",
    cwd: ctx.cwd,
    tool,
    // Whole, so a card for its Yes shows all of what runs; desk answer cuts what it logs.
    command: redactUrls(command),
    reason: redactUrls(reason),
    at: new Date().toISOString(),
  };
}

const answeredYes =
  "This prompt was answered Yes from outside the desk (bercail desk answer), on the person's Allow on a Decisions card or from their terminal. Say so in your report.";

const policySection = "bercail_git_policy";

const toolCallsOf = (message: { content?: unknown } | undefined): { id: string }[] =>
  Array.isArray(message?.content)
    ? message.content.filter((part: { type?: string; id?: unknown }) => part?.type === "toolCall")
    : [];

// Why a tool call is not alone in its assistant message, or undefined when it is: not a
// call another tool made, and no GIT_DIR of Shep's own, which bash would inherit and the
// guard's reads drop, nor GIT_CONFIG, which only git config reads, so what the guard reads
// is what runs. Its message's calls are counted at message_end, which Pi awaits before
// it checks any of them; a call it checks without one goes to a card.
function whyNotAlone(
  event: { toolCallId: string; parentToolCallId?: string },
  counts: Map<string, number>,
): string | undefined {
  if (event.parentToolCallId) return "another tool made the call";
  const git = Object.keys(process.env).find((key) => gitPlace.test(key) || key === "GIT_CONFIG");
  if (git) return `Shep's environment sets ${git}, which bash would read and the guard's reads drop`;
  const count = counts.get(event.toolCallId);
  counts.delete(event.toolCallId);
  if (count === undefined) return "the guard saw no end of the message that holds this tool call";
  return count === 1
    ? undefined
    : `it was one of ${count} tool calls in its message, which Pi runs together; send it alone`;
}

// The guard file's sha256, or "" when it cannot be read.
function fileHash(file: string): string {
  try {
    return createHash("sha256").update(readFileSync(file)).digest("hex");
  } catch {
    return "";
  }
}

// Set by the reload this guard asks for, read by the guard the reload loads: one process.
// True: the turn ended on its own, so the agent goes on; false: the person stopped it.
const reloadedKey = Symbol.for("bercail.guard.reloaded");
// Set by each guard once it has registered its handlers.
const registeredKey = Symbol.for("bercail.guard.registered");

// Why the guard in FILE does not load and register its tool_call handler, or undefined
// when it does. Under a name of its own beside it, since a loader caches a module by
// its path, and against a stand-in for Pi, in this process.
async function whyNotLoads(file: string): Promise<string | undefined> {
  const probe = join(dirname(file), `.guard-probe-${process.pid}-${randomUUID()}.ts`);
  try {
    writeFileSync(probe, readFileSync(file));
    const next = (await import(pathToFileURL(probe).href)) as { default?: unknown };
    if (typeof next.default !== "function") return "it exports no extension";
    const events = new Set<string>();
    next.default(new Proxy({}, { get: (_, key) => (key === "on" ? (name: string) => events.add(name) : () => {}) }));
    return events.has("tool_call") ? undefined : "it registers no tool_call handler";
  } catch (error) {
    return String(error);
  } finally {
    rmSync(probe, { force: true });
  }
}

export default function (pi: ExtensionAPI) {
  // Pi holds the guard it loaded at start; bercail update replaces the file, not that
  // code. A guard whose file changed refuses every call and reloads Pi once it is idle.
  const self = fileURLToPath(import.meta.url);
  const loaded = fileHash(self);
  let reload = false;
  let resume = false;
  // The hash of a guard file that does not load: this guard stays, refusing, until it changes.
  let broken = "";
  pi.registerCommand("bercail-guard-reload", {
    description: "Reload Pi's extensions: bercail's guard changed on disk",
    handler: async (_args, ctx) => {
      // A reload drops this guard before it loads the next, and a desk's follow-ups
      // still start turns: so the next must load here first.
      const now = fileHash(self);
      const why = await whyNotLoads(self);
      if (why) {
        broken = now;
        ctx.ui.notify(`${guardBroken} ${why}`, "error");
        return;
      }
      const globals = globalThis as Record<symbol, unknown>;
      globals[reloadedKey] = resume;
      delete globals[registeredKey];
      await ctx.reload();
      // Pi did not load the guard that loaded here: it exits rather than run without one.
      if (globals[registeredKey]) return;
      process.once("exit", () => console.error(guardLost));
      process.kill(process.pid, "SIGTERM");
    },
  });
  // Messages sent here run once every settled handler is done, with the agent idle.
  pi.on("agent_settled", (event) => {
    if (!reload) return;
    reload = false;
    resume = (event as { aborted?: boolean }).aborted !== true;
    pi.sendUserMessage("/bercail-guard-reload", { expandPromptTemplates: true });
  });

  const home = process.env.HOME;
  const config =
    process.env.BERCAIL_CONFIG ||
    join(process.env.XDG_CONFIG_HOME || join(home ?? "", ".config"), "bercail/config.toml");
  const protectedFiles = [
    // The one bercail config set writes, wherever BERCAIL_CONFIG or XDG_CONFIG_HOME point.
    join(home ?? "", ".config/bercail/config.toml"),
    join(stateDir(), "policy-trust.json"),
    // The handoff records: a desk pushes the branch its own names without asking.
    join(stateDir(), "handoffs.jsonl"),
    // Shep's question ledger: an answered question in it is the person's pick.
    join(stateDir(), "shep/questions.json"),
    join(stateDir(), "shep/questions.lock"),
    config,
  ];
  // Shep's state: its ledger, inbox and sessions; and the guard's tickets for Shep's asks.
  // And a desk's guard prompts and their answers.
  const protectedDirs = [join(stateDir(), "shep"), guardAsks(), deskPrompts()];
  // Not one of the guard's: a target decides where Shep writes, not what runs.
  const todoFiles = [join(dirname(config), "todo.json")];

  const shim = resolve(dirname(fileURLToPath(import.meta.url)), "../op-shim");
  // The policy of the folder the agent started in, once a lookup works. No abort
  // signal, and a failed lookup is not kept: either would leave the session
  // without its checkout's root or its desk-secret rules.
  let startLookup: { cwd: string; json: PolicyJson } | undefined;
  const startJson = async (cwd: string) => {
    if (startLookup?.cwd === cwd) return startLookup.json;
    const json = await policyJson(pi, cwd, undefined);
    if (json) startLookup = { cwd, json };
    return json;
  };

  // A PR head's .pi/ extensions never load, whatever trust.json says of the parent.
  pi.on("project_trust", async (event) => ({ trusted: isReviewWorktree(event.cwd) ? "no" : "undecided" }));

  // Before the first command: Pi's bash tool runs with this process's environment.
  pi.on("session_start", async (event, ctx) => {
    const globals = globalThis as Record<symbol, unknown>;
    if (event.reason === "reload" && reloadedKey in globals) {
      const triggerTurn = globals[reloadedKey] === true;
      delete globals[reloadedKey];
      pi.sendMessage({ customType: "bercail-guard", display: true, content: guardReloaded }, { triggerTurn });
    }
    const note = useDeskSecret(await startJson(ctx.cwd), process.env.BERCAIL_ROLE ?? "", process.env, shim);
    if (!note) return;
    if (ctx.hasUI) ctx.ui.notify(note, "warning");
    else console.error(note);
  });

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
  // The answer each push it let through spent: once it ran, the policy file that card pinned.
  const pushed = new Map<string, string>();
  // How many tool calls the last assistant message held, by call ID: Pi checks every call
  // of a message before it runs any, then runs them together.
  const counts = new Map<string, number>();
  pi.on("message_end", async (event) => {
    const { message } = event as { message: { role?: string; content?: unknown } };
    if (message.role !== "assistant") return;
    counts.clear();
    const calls = toolCallsOf(message);
    for (const call of calls) counts.set(call.id, calls.length);
  });

  pi.on("tool_call", async (event, ctx) => {
    const input = event.input as { command?: string; path?: string };
    const now = fileHash(self);
    if (!loaded || now !== loaded) {
      // A guard file that is gone or unreadable would reload into no guard at all.
      reload = loaded !== "" && now !== "" && now !== broken && ctx.hasUI;
      const reason =
        !loaded || !now ? guardGone : now === broken ? guardBroken : reload ? staleGuard : staleGuardHeadless;
      logWarning(event.toolName, String(input.command ?? input.path ?? ""), "refusal", [reason], {
        role: process.env.BERCAIL_ROLE ?? "",
        hasUI: ctx.hasUI,
        cwd: ctx.cwd,
      });
      return { block: true, reason };
    }
    const command = event.toolName === "bash" ? String(input.command ?? "") : undefined;
    const notAlone = whyNotAlone(event, counts);
    const json = await startJson(ctx.cwd);
    const desk = process.env.HC_TERMINAL_ID;
    // Only for a command that could take the own-branch push: no remote read for any other.
    const deskBranch =
      (process.env.BERCAIL_ROLE ?? "") === "" && desk && notAlone === undefined && command && mayPushOwn(command)
        ? await deskBranchAt(pi, desk, ctx.cwd, ctx.signal)
        : undefined;
    let guardInput: GuardInput = {
      role: process.env.BERCAIL_ROLE ?? "",
      hasUI: ctx.hasUI,
      cwd: ctx.cwd,
      home,
      protectedFiles,
      protectedDirs,
      todoFiles,
      graphiteAliases: event.toolName === "bash" ? readGraphiteAliases() : undefined,
      deskSecret: deskSecretOf(json),
      readOnlyWrites: {
        tmp: ["/tmp", process.env.TMPDIR ?? ""].filter((dir) => dir && resolve(dir) !== "/"),
        root: json?.root ?? ctx.cwd,
        exists: onDisk,
      },
      tmpdir: process.env.TMPDIR && resolve(process.env.TMPDIR) !== "/tmp" ? process.env.TMPDIR : undefined,
      alone: notAlone === undefined,
      ...(deskBranch ? { deskBranch } : {}),
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
      if (token) {
        decision = { action: "allow", warnings: [...(decision.warnings ?? []), pushApproved(token)] };
        pushed.set(event.toolCallId, token);
      }
    }
    const logged = command ?? input.path ?? "";
    // Shep never waits on a confirm: an ask runs with no card where its repo opts in
    // (shep_may_run), goes to a worker, or is refused. Only a call alone in its message runs
    // that way, so nothing else Shep runs beside it moves what was read.
    if (decision.action === "ask" && guardInput.role === "shep") {
      const opted = command === undefined ? undefined : await optedIn(command, guardInput, notAlone);
      const direct = opted && "command" in opted ? opted : undefined;
      if (direct) {
        // Pi runs the mutated input: the pinned argv, not the words Shep wrote.
        (event.input as { command: string }).command = direct.command;
        decision = { action: "allow", approved: [direct.why], warnings: [direct.why] };
      } else {
        const session = (ctx as { sessionManager?: { getSessionId?: () => string } }).sessionManager?.getSessionId?.();
        const missed = opted && "missed" in opted ? opted.missed : undefined;
        const handed = await handOff(pi, logged, guardInput, decision.reason, session || "unknown", ctx.signal, missed);
        logWarning(event.toolName, logged, handed.handed ? "handoff" : "refusal", [handed.reason], guardInput);
        return { block: true, reason: handed.reason };
      }
    }
    const refuse = (reason: string) => {
      logWarning(event.toolName, logged, "refusal", [reason], guardInput);
      return { block: true, reason };
    };
    if (decision.action === "ask") {
      if (!ctx.hasUI) return refuse(headless);
      const prompt = deskPromptOf(guardInput.role, ctx, event.toolName, logged, decision.reason);
      const asked = prompt
        ? await confirmOrAnswer(ctx.ui.confirm.bind(ctx.ui), "Allow this command?", prompt)
        : { yes: await ctx.ui.confirm("Allow this command?", decision.reason) };
      if (asked.answer?.answer === "no")
        return refuse(
          `Answered No from outside the desk (bercail desk answer): ${redactUrls(asked.answer.reason)} It asked: ${redactUrls(decision.reason)} Leave it for the person.`,
        );
      if (!asked.yes) return refuse(`The person said no to: ${decision.reason} Leave it for them.`);
      if (asked.answer) {
        logApproval(logged, [answeredYes], guardInput);
        decision = { ...decision, warnings: [...(decision.warnings ?? []), answeredYes] };
      }
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
  pi.on("tool_result", async (event, ctx) => {
    const token = pushed.get(event.toolCallId);
    pushed.delete(event.toolCallId);
    const trust = token ? await policyTrust(pi, token, (ctx as { signal?: AbortSignal } | undefined)?.signal) : [];
    const warnings = [...(warned.get(event.toolCallId) ?? []), ...trust];
    if (!warnings.length) return;
    warned.delete(event.toolCallId);
    const text = warnings.map(warningLine).join("\n");
    return {
      content: [{ type: "text" as const, text }, ...event.content],
      ...(event.structuredContent === undefined ? {} : { structuredContent: event.structuredContent }),
    };
  });
  (globalThis as Record<symbol, unknown>)[registeredKey] = true;
}
