// bercail's Pi guard. The decision functions are pure; the default export wires tool_call.
import { isAbsolute, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type GuardInput = {
  role: string;
  hasUI: boolean;
  cwd: string;
  /** undefined: not looked up. "": lookup failed. */
  branch?: string;
};

export type GuardDecision =
  | { action: "allow" }
  | { action: "block"; reason: string }
  | { action: "ask"; reason: string }
  | { action: "need-branch"; dir: string };

const force = "Force-push is blocked. Push without --force, or ask the person.";
const plusRef = "A refspec starting with + is a force-push. Push the branch without +.";
const mirror = "git push --mirror is blocked.";
const deleteMain = "Deleting main or master is blocked.";
const noVerify = "Skipping git hooks with --no-verify is blocked. Run the command so the hooks run.";
const prMerge = "gh pr merge is blocked. Do not merge the pull request.";
const toMain = "A push to main or master is blocked. Push the pull request branch instead.";
const headless = "A headless run stages its changes and leaves commit and push to the person.";
const readOnly = "This role is read-only. Do not edit files or change the git tree.";
const readOnlyTool = "This role is read-only. Do not edit or write files.";
const unknownBranch = "Could not read the current branch, so this push is blocked. Push the branch by name.";

const allow: GuardDecision = { action: "allow" };
const block = (reason: string): GuardDecision => ({ action: "block", reason });

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

type Token = { kind: "word"; value: string } | { kind: "op" } | { kind: "sub"; value: string };

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

function tokenize(command: string): Token[] {
  const tokens: Token[] = [];
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
      tokens.push({ kind: "op" });
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
      if ((c === "|" && command[i + 1] === "|") || (c === "&" && command[i + 1] === "&")) i++;
      tokens.push({ kind: "op" });
      i++;
      continue;
    }
    if (c === "$" && command[i + 1] === "(") {
      const inner = readBalanced(command, i + 1);
      if (inner) {
        tokens.push({ kind: "sub", value: inner.body });
        i = inner.end;
        continue;
      }
    }
    if (c === "`") {
      const end = command.indexOf("`", i + 1);
      if (end > i) {
        tokens.push({ kind: "sub", value: command.slice(i + 1, end) });
        i = end + 1;
        continue;
      }
    }
    let word = "";
    while (i < command.length) {
      const ch = command[i];
      if (" \t\n;|&".includes(ch)) break;
      if (ch === "$" && command[i + 1] === "(") break;
      if (ch === "`") break;
      if (ch === "'") {
        const end = command.indexOf("'", i + 1);
        if (end < 0) {
          word += command.slice(i + 1);
          i = command.length;
          break;
        }
        word += command.slice(i + 1, end);
        i = end + 1;
        continue;
      }
      if (ch === '"') {
        i++;
        while (i < command.length && command[i] !== '"') {
          if (command[i] === "\\" && i + 1 < command.length) {
            word += command[i + 1];
            i += 2;
            continue;
          }
          if (command[i] === "$" && command[i + 1] === "(") {
            const inner = readBalanced(command, i + 1);
            if (inner) {
              tokens.push({ kind: "sub", value: inner.body });
              i = inner.end;
              continue;
            }
          }
          if (command[i] === "`") {
            const end = command.indexOf("`", i + 1);
            if (end > i) {
              tokens.push({ kind: "sub", value: command.slice(i + 1, end) });
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
        if (i + 1 < command.length) word += command[i + 1];
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

function segmentsOf(command: string): { words: string[]; subs: string[] }[] {
  const tokens = tokenize(command);
  const out: { words: string[]; subs: string[] }[] = [];
  let words: string[] = [];
  let subs: string[] = [];
  const flush = () => {
    if (words.length || subs.length) out.push({ words, subs });
    words = [];
    subs = [];
  };
  for (const token of tokens) {
    if (token.kind === "op") flush();
    else if (token.kind === "sub") subs.push(token.value);
    else words.push(token.value);
  }
  flush();
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
    if (!word.includes("=") && ["-u", "-g", "-h", "-p", "-C", "-D", "-T", "-R", "--user", "--group", "--host"].includes(name)) i++;
  }
  return i;
}

function commandWords(words: string[]): string[] {
  let i = 0;
  while (i < words.length) {
    const word = words[i];
    if (assign.test(word)) {
      i++;
      continue;
    }
    if (word === "command") {
      i++;
      if (words[i] === "-p" || words[i] === "--") i++;
      continue;
    }
    if (word === "env") {
      i = skipEnv(words, i);
      continue;
    }
    if (word === "sudo") {
      i = skipSudo(words, i);
      continue;
    }
    break;
  }
  return words.slice(i);
}

const gitValue = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--exec-path", "--shallow-file"]);

function parseGit(words: string[], cwd: string): { sub: string; args: string[]; dir: string } | undefined {
  if (words[0] !== "git") return undefined;
  let i = 1;
  let dir = cwd;
  while (i < words.length && words[i].startsWith("-")) {
    const word = words[i];
    if (word === "--") {
      i++;
      break;
    }
    const eq = word.indexOf("=");
    const name = eq > 0 ? word.slice(0, eq) : word;
    if (name === "-C") {
      const value = eq > 0 ? word.slice(eq + 1) : words[i + 1];
      if (eq < 0) i++;
      if (value) dir = isAbsolute(value) ? value : resolve(dir, value);
      i++;
      continue;
    }
    if (gitValue.has(name) && eq < 0) i++;
    i++;
  }
  return { sub: words[i] ?? "", args: words.slice(i + 1), dir };
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

function pushFacts(args: string[]): { force: boolean; mirror: boolean; deleteMain: boolean; plus: boolean; refspecs: string[]; hasRefspec: boolean } {
  let forceFlag = false;
  let mirrorFlag = false;
  let deleting = false;
  let deleteMainFlag = false;
  let plus = false;
  const positionals: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--") {
      positionals.push(...args.slice(i + 1));
      break;
    }
    if (deleting && !arg.startsWith("-")) {
      if (isMainRef(arg)) deleteMainFlag = true;
      deleting = false;
      continue;
    }
    if (arg.startsWith("-")) {
      if (arg === "--force" || arg === "-f" || arg.startsWith("--force")) forceFlag = true;
      if (arg === "--mirror") mirrorFlag = true;
      if (arg === "--delete" || arg === "-d") deleting = true;
      if (arg.startsWith("--delete=")) {
        if (isMainRef(arg.slice("--delete=".length))) deleteMainFlag = true;
      }
      const cluster = shortCluster(arg);
      if (cluster?.includes("f")) forceFlag = true;
      if (cluster?.includes("d")) deleting = true;
      if (arg === "-o" || arg === "--push-option" || arg === "--repo" || arg === "--receive-pack" || arg === "--exec") i++;
      continue;
    }
    positionals.push(arg);
  }
  const first = positionals[0];
  const firstIsRef = first !== undefined && (first.includes(":") || first.startsWith("+") || first.startsWith("refs/") || first === "HEAD" || isMainRef(first));
  const refspecs = first === undefined ? [] : firstIsRef ? positionals : positionals.slice(1);
  for (const spec of refspecs) {
    if (spec.startsWith("+")) plus = true;
  }
  return { force: forceFlag, mirror: mirrorFlag, deleteMain: deleteMainFlag, plus, refspecs, hasRefspec: refspecs.length > 0 };
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

function isGhPrMerge(words: string[]): boolean {
  if (words[0] !== "gh") return false;
  const plain = words.filter((word) => !word.startsWith("-"));
  return plain[1] === "pr" && plain[2] === "merge";
}

function gitWrite(sub: string, args: string[]): boolean {
  if (["add", "commit", "push", "restore", "clean", "rm", "mv", "merge", "rebase"].includes(sub)) return true;
  if (sub === "reset" && args.some((arg) => arg === "--hard" || arg.startsWith("--hard"))) return true;
  if (sub === "checkout" && (args.includes("--") || args.includes(".") || args.some((arg) => arg === "-f" || arg === "--force"))) return true;
  return false;
}

function publish(kind: "commit" | "push", input: GuardInput): GuardDecision {
  if (input.hasUI) {
    const verb = kind === "commit" ? "commit" : "push";
    return { action: "ask", reason: `Allow this git ${verb}? No leaves the changes staged for the person.` };
  }
  return block(headless);
}

function decidePush(args: string[], dir: string, input: GuardInput): GuardDecision {
  const facts = pushFacts(args);
  if (facts.force) return block(force);
  if (facts.plus) return block(plusRef);
  if (facts.mirror) return block(mirror);
  if (facts.deleteMain) return block(deleteMain);
  if (hasNoVerify("push", args)) return block(noVerify);
  if (readOnlyRole(input.role)) return block(readOnly);
  if (input.role === "autopilot") {
    for (const spec of facts.refspecs) {
      const dest = refDest(spec);
      if (dest !== "HEAD" && dest !== "" && isMainRef(dest)) return block(toMain);
    }
    const needsBranch = !facts.hasRefspec || facts.refspecs.some((spec) => {
      const dest = refDest(spec);
      return dest === "HEAD" || dest === "";
    });
    if (needsBranch) {
      if (input.branch === undefined) return { action: "need-branch", dir };
      if (input.branch === "") return block(unknownBranch);
      if (input.branch === "main" || input.branch === "master") return block(toMain);
    }
    return allow;
  }
  return publish("push", input);
}

function decideGit(parsed: { sub: string; args: string[]; dir: string }, input: GuardInput): GuardDecision {
  const { sub, args } = parsed;
  if (hasNoVerify(sub, args) && ["commit", "push", "merge", "rebase"].includes(sub)) return block(noVerify);
  if (sub === "push") return decidePush(args, parsed.dir, input);
  if (readOnlyRole(input.role) && gitWrite(sub, args)) return block(readOnly);
  if (sub === "commit") {
    if (input.role === "autopilot") return allow;
    if (readOnlyRole(input.role)) return block(readOnly);
    return publish("commit", input);
  }
  return allow;
}

function worse(current: GuardDecision, next: GuardDecision): GuardDecision {
  if (next.action === "block" || current.action === "block") return next.action === "block" ? next : current;
  if (next.action === "need-branch") return next;
  if (current.action === "need-branch") return current;
  if (next.action === "ask") return next;
  if (current.action === "ask") return current;
  return allow;
}

export function decideBash(command: string, input: GuardInput, depth = 0): GuardDecision {
  if (depth > 4) return block("This command is nested too deep to check. Split it into a simpler command.");
  let decision: GuardDecision = allow;
  for (const segment of segmentsOf(command)) {
    for (const sub of segment.subs) decision = worse(decision, decideBash(sub, input, depth + 1));
    const words = commandWords(segment.words);
    if (words.length === 0) continue;
    const script = shellScript(words);
    if (script) decision = worse(decision, decideBash(script, input, depth + 1));
    if (isGhPrMerge(words)) decision = worse(decision, block(prMerge));
    const git = parseGit(words, input.cwd);
    if (git) decision = worse(decision, decideGit(git, input));
    if (decision.action === "block") return decision;
  }
  return decision;
}

export function decideTool(tool: string, command: string | undefined, input: GuardInput): GuardDecision {
  if ((tool === "edit" || tool === "write") && readOnlyRole(input.role)) return block(readOnlyTool);
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

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    const command = event.toolName === "bash" ? String((event.input as { command?: string }).command ?? "") : undefined;
    const base: GuardInput = { role: process.env.BERCAIL_ROLE ?? "", hasUI: ctx.hasUI, cwd: ctx.cwd };
    let decision = decideTool(event.toolName, command, base);
    if (decision.action === "need-branch") {
      decision = decideTool(event.toolName, command, { ...base, branch: await branchAt(pi, decision.dir, ctx.signal) });
    }
    if (decision.action === "allow" || decision.action === "need-branch") return;
    if (decision.action === "ask") {
      if (ctx.hasUI && (await ctx.ui.confirm("Allow this git command?", decision.reason))) return;
      return { block: true, reason: ctx.hasUI ? "The person said no. Leave the changes staged." : headless };
    }
    return { block: true, reason: decision.reason };
  });
}
