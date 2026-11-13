// What the live proofs share: a terminal for a TUI Pi, and pass/fail reporting.
// Node has no pty, so util-linux script(1) gives the command one, 40x120 like a
// desk's, and writes all it shows to the log itself: nothing here has to drain it,
// so a blocking spawnSync can't stall the TUI. Linux only: macOS's script differs.
import { type ChildProcess, spawn } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";

export const fails: string[] = [];
const terms: Term[] = [];
// oxlint-disable-next-line no-control-regex -- ANSI escapes are control characters
const ANSI = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-B]/g;

export function fail(message: string): void {
  fails.push(message);
  console.error(`FAIL: ${message}`);
}

export function pass(message: string): void {
  console.log(`PASS: ${message}`);
}

export const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

// Polls PRED until it holds; a throw counts as not yet. Fails with LABEL on timeout,
// or at once when TERM's program has exited.
export async function waitFor(
  label: string,
  pred: () => unknown,
  { timeout = 30, term }: { timeout?: number; term?: Term } = {},
): Promise<boolean> {
  const deadline = Date.now() + timeout * 1000;
  while (Date.now() < deadline) {
    if (term?.exited()) {
      fail(`${label}: the program exited ${term.proc.exitCode ?? term.proc.signalCode}`);
      return false;
    }
    try {
      if (await pred()) return true;
    } catch {}
    await sleep(100);
  }
  fail(`timed out: ${label}`);
  return false;
}

const quote = (s: string) => `'${s.replaceAll("'", `'\\''`)}'`;

export class Term {
  readonly proc: ChildProcess;
  readonly log: string;
  // The command's pid, which leads its own process group.
  pid = 0;

  private constructor(argv: string[], env: NodeJS.ProcessEnv, cwd: string, log: string) {
    this.log = log;
    const pidFile = `${log}.pid`;
    // script runs $SHELL -c; sh reads this line, and the command gets its own SHELL back.
    const shell = env.SHELL ? `export SHELL=${quote(env.SHELL)}` : "unset SHELL";
    const line = `stty rows 40 cols 120; echo $$ >${quote(pidFile)}; ${shell}; exec ${argv.map(quote).join(" ")}`;
    this.proc = spawn("script", ["-qfec", line, log], {
      env: { ...env, SHELL: "/bin/sh" },
      cwd,
      stdio: ["pipe", "ignore", "ignore"],
    });
    this.proc.stdin!.on("error", () => {});
    terms.push(this);
  }

  static async start(argv: string[], { env, cwd, log }: { env: NodeJS.ProcessEnv; cwd: string; log: string }) {
    const term = new Term(argv, env, cwd, log);
    const pidFile = `${log}.pid`;
    for (let i = 0; i < 100 && !term.pid; i++) {
      if (existsSync(pidFile)) term.pid = Number(readFileSync(pidFile, "utf8")) || 0;
      if (!term.pid) await sleep(50);
    }
    if (!term.pid) throw new Error(`no pid from script(1) for ${argv[0]}; is util-linux installed?`);
    return term;
  }

  exited(): boolean {
    return this.proc.exitCode !== null || this.proc.signalCode !== null;
  }

  size(): number {
    return existsSync(this.log) ? statSync(this.log).size : 0;
  }

  // What the terminal showed after byte OFFSET of the log, escapes stripped.
  screenSince(offset: number): string {
    return readFileSync(this.log).subarray(offset).toString("utf8").replace(ANSI, "");
  }

  // Keys, one at a time, as a person types them.
  async send(text: string, delay = 30): Promise<void> {
    for (const ch of text) {
      this.proc.stdin!.write(ch);
      await sleep(delay);
    }
  }

  // TEXT into Pi's editor, then Enter on its own.
  async type(text: string): Promise<void> {
    this.proc.stdin!.write(text);
    await sleep(400);
    this.proc.stdin!.write("\r");
  }

  signal(sig: NodeJS.Signals): void {
    try {
      if (this.pid) process.kill(-this.pid, sig);
    } catch {}
  }

  // SIGTERM to the command's group; SIGKILL after TIMEOUT seconds.
  async stop(timeout = 10): Promise<void> {
    this.signal("SIGTERM");
    const deadline = Date.now() + timeout * 1000;
    while (!this.exited() && Date.now() < deadline) await sleep(50);
    if (!this.exited()) this.signal("SIGKILL");
    this.proc.stdin!.destroy();
  }
}

// Every terminal still running dies with the proof.
export function killAll(): void {
  for (const term of terms) {
    term.signal("SIGKILL");
    try {
      term.proc.kill("SIGKILL");
    } catch {}
    term.proc.stdin!.destroy();
  }
}
