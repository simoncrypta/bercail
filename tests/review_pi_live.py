#!/usr/bin/env python3
# review-pr's reviewer on the installed Pi, with a fake model. Headless, review.ts
# blocks a read outside the stack dir. As the review desk (Pi's TUI in a
# terminal), it takes the CLI's turns: bercail's own _review_turn sends one,
# reads its reply, and stops a held one with a cancel.
import json
import os
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import fcntl
import threading
import time
from pathlib import Path

ROOT = Path(sys.argv[1])
PI = sys.argv[2]
FAILS = []
PROCS = []


def fail(message):
    FAILS.append(message)
    print(f"FAIL: {message}", file=sys.stderr)


def wait_for(label, pred, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if pred():
                return True
        except Exception:
            pass
        time.sleep(0.1)
    fail(f"timed out: {label}")
    return False


class Term:
    def __init__(self, cmd, env, cwd, log):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        self.proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=subprocess.STDOUT,
                                     env=env, cwd=cwd, start_new_session=True)
        os.close(slave)
        PROCS.append(self.proc)
        self.sink = open(log, "ab")
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        while True:
            try:
                ready, _, _ = select.select([self.master], [], [], 0.2)
            except (OSError, ValueError):
                return
            if self.master not in ready:
                if self.proc.poll() is not None:
                    return
                continue
            try:
                data = os.read(self.master, 65536)
            except OSError:
                return
            if not data:
                return
            self.sink.write(data)
            self.sink.flush()


def events(path):
    out = []
    for line in Path(path).read_text().splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def texts(evs):
    return "\n".join(p.get("text", "") for e in evs if e.get("type") == "message_end"
                     and e.get("message", {}).get("role") == "assistant"
                     for p in e["message"].get("content", []) if isinstance(p, dict))


def main():
    run = Path(f"/tmp/review-pi-live.{os.getpid()}")
    run.mkdir()
    try:
        body(run)
    finally:
        for p in PROCS:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        if not FAILS and not os.environ.get("KEEP"):
            shutil.rmtree(run, ignore_errors=True)
        else:
            print(f"kept: {run}", file=sys.stderr)
    if FAILS:
        raise SystemExit(1)


def body(run):
    home, stack = run / "home", run / "stack"
    (home / ".pi/agent").mkdir(parents=True)
    (home / ".pi/agent/settings.json").write_text(json.dumps({"retry": {"enabled": False}, "compaction": {"enabled": False}}))
    (stack / "pr-7/abc").mkdir(parents=True)
    (stack / "pr-7/abc/diff.patch").write_text("+retry\n")
    secret = run / "secret.txt"
    secret.write_text("OUTSIDE_SECRET\n")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("PI_", "HC_")) and k != "BASH_ENV"}
    env.update(HOME=str(home), PI_CODING_AGENT_DIR=str(home / ".pi/agent"), PI_OFFLINE="1",
               TERM="xterm-256color", __MISE_BASH_ENV_LOADED="1")
    # The reviewer as review.json has it, on the fake model.
    argv = [PI, "--offline", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-context-files",
            "-e", str(ROOT / "tests/review_pi_provider.ts"), "-e", str(ROOT / "bstack/pi/extensions/review.ts"),
            "--tools", "read,grep,find,ls", "--model", "fake-review/model", "--session-dir", str(stack / "sessions")]

    def headless(prompt):
        r = subprocess.run([*argv, "-p", "--mode", "json", "--", prompt], env=env, cwd=stack,
                           capture_output=True, text=True, timeout=60)
        if "Failed to load extension" in r.stderr:
            fail(f"extension did not load: {r.stderr}")
        return r.stdout

    out = headless(f"READ {secret}")
    if "OUTSIDE_SECRET" in out or "reads only the review stack dir" not in out:
        fail(f"a read outside the stack dir was not blocked: {out[-2000:]}")
    out = headless("READ pr-7/abc/diff.patch")
    if "TOOL_RESULT" not in out or "+retry" not in out:
        fail(f"a read inside the stack dir failed: {out[-2000:]}")
    if not FAILS:
        print("PASS: headless, review.ts lets the reviewer read the stack dir and nothing outside it")

    # The desk: Pi's TUI in the stack dir, on a session bercail minted.
    session = "11111111-2222-4333-8444-555555555555"
    Term([*argv, "--session-id", session], env, str(stack), run / "desk.log")
    if not wait_for("desk/pi.json", lambda: json.loads((stack / "desk/pi.json").read_text())["pid"] > 0):
        return
    desk = json.loads((stack / "desk/pi.json").read_text())
    if desk.get("session") != session:
        fail(f"desk/pi.json names session {desk.get('session')}, not {session}")

    def turn(out, prompt, background=False):
        script = (f'set -euo pipefail; source "{ROOT}/lib/common.sh"; source "{ROOT}/lib/review.sh"; '
                  f'R_STACK="{stack}"; _review_turn "$1" "$1.err" "$2" {session}')
        cmd = ["bash", "-c", script, "turn", str(out), prompt]
        if background:
            return subprocess.Popen(cmd, env=env)
        return subprocess.run(cmd, env=env, timeout=60).returncode

    pass_out = stack / "pr-7/abc/pass.jsonl"
    rc = turn(pass_out, "review pr-7")
    evs = events(pass_out)
    if rc != 0 or not evs or evs[0] != {"type": "session", "id": session}:
        fail(f"desk turn: rc={rc} events={evs[:2]}")
    elif "REVIEW_OK review pr-7" not in texts(evs) or evs[-1] != {"type": "agent_settled", "aborted": False}:
        fail(f"desk turn reply: {evs}")
    else:
        print("PASS: the desk takes a turn from _review_turn and writes it in Pi's json shape, on its session")

    held = stack / "summary.jsonl"
    proc = turn(held, "HOLD", background=True)
    if wait_for("the held turn starts", lambda: any(e.get("type") == "session" for e in events(held))):
        subprocess.run(["bash", "-c", f'source "{ROOT}/lib/review.sh"; _review_turn_cancel "$1"', "cancel", str(held)],
                       env=env, check=True)
        if wait_for("the cancel stops the turn", lambda: proc.poll() is not None, timeout=20):
            evs = events(held)
            if evs[-1] != {"type": "agent_settled", "aborted": True}:
                fail(f"a cancelled turn: {evs}")
            else:
                print("PASS: a cancel aborts the desk's turn")

    # A request whose caller is gone never runs.
    dead = subprocess.Popen(["true"])
    dead.wait()
    late = stack / "late.jsonl"
    (stack / "desk/inbox/0-late.json").write_text(json.dumps({"prompt": "late", "out": str(late), "pid": dead.pid}))
    if wait_for("the dead caller's request leaves the inbox", lambda: not (stack / "desk/inbox/0-late.json").exists()):
        time.sleep(1)
        if late.exists():
            fail("a request whose caller is gone ran")
        else:
            print("PASS: a request whose caller is gone is dropped")


if __name__ == "__main__":
    main()
