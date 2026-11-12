#!/usr/bin/env python3
# Shep's context on Pi, live: `bercail shep run` starts the installed Pi in a
# terminal, in a temp HOME, on a scripted offline model. It proves that Pi loads
# Shep's workspace settings, that /compact gives a summary with the job board,
# a standing rule added while Shep runs, and the model's decisions, that the
# session goes on after it, that Pi compacts on its own once the context passes
# [shep] compact_at, and that rollover moves Shep to a fresh, seeded session.
import fcntl
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
import threading
import time
from pathlib import Path

ROOT = Path(sys.argv[1])
PI = sys.argv[2]
FAILS = []
PROCS = []
COMPACT_AT = 20000


def fail(message):
    FAILS.append(message)
    print(f"FAIL: {message}", file=sys.stderr)


def wait_for(label, pred, timeout=60):
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
        self.log = log
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

    # Types TEXT into Pi's editor, then Enter on its own, as a person would.
    def type(self, text):
        os.write(self.master, text.encode())
        time.sleep(0.4)
        os.write(self.master, b"\r")

    def stop(self):
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)
        try:
            os.close(self.master)
        except OSError:
            pass


def session_files(sessions):
    return sorted(Path(sessions).rglob("*.jsonl"), key=lambda f: f.stat().st_mtime)


def entries(path):
    out = []
    for line in Path(path).read_text().splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(p.get("text", "") for p in c if isinstance(p, dict))
    return ""


def replies(path):
    return [text_of(e["message"]) for e in entries(path) if e.get("type") == "message"
            and e.get("message", {}).get("role") == "assistant"]


def compactions(path):
    return [e for e in entries(path) if e.get("type") == "compaction"]


def main():
    run = Path(f"/tmp/shep-context-live.{os.getpid()}")
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
    home, state, binp = run / "home", run / "state", run / "bin"
    share = home / ".local/share/bercail/shep"
    for p in (home / ".config/bercail", state / "bercail/shep", binp, share / "pi", home / ".local/share/bercail/pi"):
        p.mkdir(parents=True)
    (binp / "pi").symlink_to(PI)
    for rel in ("SHEP.md", "pi/inbox.ts", "pi/compaction.ts"):
        shutil.copy(ROOT / "shep" / rel, share / rel)
    (home / ".local/share/bercail/pi/lead.json").write_text(json.dumps(
        ["pi", "--model", "fake/model:high", "-e", str(ROOT / "tests/shep_context_provider.ts")]))
    config = home / ".config/bercail/config.toml"
    config.write_text(f"[shep]\ncompact_at = {COMPACT_AT}\nkeep_recent = 2000\n")
    # One known repo, from Shep's extras file, with one job in its beads.
    repo = run / "app"
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    (repo / ".beads").mkdir()
    (state / "bercail/shep/repos").write_text(f"{repo}\n")
    (binp / "bd").write_text("#!/bin/sh\n[ \"$1\" = list ] && printf '%s\\n' "
                             "'[{\"id\":\"live-1\",\"title\":\"Live job\",\"status\":\"in_progress\"}]'\n")
    (binp / "hc").write_text("#!/bin/sh\n[ \"$1\" = ls ] && printf '{\"terminals\":[]}\\n'\nexit 0\n")
    for f in ("bd", "hc"):
        (binp / f).chmod(0o755)

    env = {k: v for k, v in os.environ.items() if not k.startswith(("PI_", "HC_", "BERCAIL_")) and k != "BASH_ENV"}
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), XDG_STATE_HOME=str(state),
               XDG_DATA_HOME=str(run / "data"), XDG_CACHE_HOME=str(run / "cache"),
               PATH=f"{binp}:/usr/bin:/bin", TERM="xterm-256color", PI_OFFLINE="1",
               HERDR_APP_BIN=str(run / "no-herdr-app"), __MISE_BASH_ENV_LOADED="1")
    shep_dir = state / "bercail/shep"
    sessions = shep_dir / "pi-sessions"
    bercail = str(ROOT / "bin/bercail")

    def start(n):
        term = Term([bercail, "shep", "run"], env, str(run), run / f"term{n}.log")
        # A resumed session can initially draw history without its footer. Wait
        # for terminal input mode, not a context meter that needs another redraw.
        wait_for("Pi's terminal input", lambda: b"\x1b[?2004h" in (run / f"term{n}.log").read_bytes())
        time.sleep(1)
        return term

    def answered(prompt, timeout=60):
        return wait_for(f"a reply to {prompt!r}",
                        lambda: any(r.startswith(f"Shep ok: {prompt}") for r in replies(session_files(sessions)[-1])), timeout)

    shep = start(1)
    settings = json.loads((shep_dir / "workspace/.pi/settings.json").read_text())
    want = {"enabled": True, "keepRecentTokens": 2000,
            "modelOverrides": {"fake/model": {"keepRecentTokens": 2000, "reserveTokens": 64000 - COMPACT_AT}}}
    if settings.get("compaction") != want:
        fail(f"settings: {settings}")
    if b"Trust" in (run / "term1.log").read_bytes() and b"project" in (run / "term1.log").read_bytes():
        fail("Pi asked to trust Shep's workspace")
    shep.type("hello")
    if not answered("hello"):
        return
    session = session_files(sessions)[-1]
    if compactions(session):
        fail("compacted before the context reached compact_at")
    print("PASS: Shep starts on its workspace settings, with no trust question")

    # A rule added while Shep runs is in the next summary. "medium" gives
    # /compact more than keep_recent to summarize.
    shep.type("medium")
    wait_for("the medium reply", lambda: any(r.startswith("Shep medium:") for r in replies(session)))
    shep.type("then")
    answered("then")
    subprocess.run([bercail, "shep", "remember", "LIVE-RULE: merge app work straight to main", "--scope", "app"],
                   env=env, check=True, stdout=subprocess.DEVNULL)
    shep.type("/compact")
    if not wait_for("the /compact entry", lambda: len(compactions(session)) == 1):
        return
    c = compactions(session)[0]
    s = c.get("summary", "")
    for want_text in ("- live-1: Live job [in_progress] · no desk · -", "[app] LIVE-RULE: merge app work straight to main",
                      "LIVE-DECISION: ship live-1 once reviewed"):
        if want_text not in s:
            fail(f"/compact summary lacks {want_text!r}: {s}")
    if c.get("details", {}).get("by") != "bercail-shep" or c.get("details", {}).get("reason") != "manual":
        fail(f"compaction details: {c.get('details')}")
    shep.type("after compact")
    if answered("after compact") and session_files(sessions)[-1] == session:
        print("PASS: /compact writes the board, the new rule and the decisions; the session goes on")
    log = (shep_dir / "compaction.log").read_text()
    if "manual compaction: Shep's summary" not in log:
        fail(f"compaction.log: {log}")

    # Past compact_at, Pi compacts on its own, with Shep's summary.
    shep.type("big")
    wait_for("the big reply", lambda: any(r.startswith("Shep big:") for r in replies(session)))
    shep.type("next")
    if wait_for("a threshold compaction", lambda: len(compactions(session)) == 2, 90):
        c = compactions(session)[1]
        if c.get("details", {}).get("reason") != "threshold" or "- live-1: Live job" not in c.get("summary", ""):
            fail(f"threshold compaction: {c.get('details')} {c.get('summary', '')[:300]}")
        elif c.get("tokensBefore", 0) <= COMPACT_AT:
            fail(f"compacted under compact_at: tokensBefore {c.get('tokensBefore')}")
        else:
            print(f"PASS: past compact_at ({c.get('tokensBefore')} > {COMPACT_AT} tokens) Pi compacts with Shep's summary")
    answered("next", 90)
    shep.stop()

    # Rollover on: the next threshold starts a fresh session seeded with the
    # board and the rules; the old one stays on disk.
    config.write_text(config.read_text() + "rollover = true\n")
    shep = start(2)
    shep.type("big")
    if not wait_for("a rollover session", lambda: len(session_files(sessions)) == 2, 90):
        return
    fresh = session_files(sessions)[-1]
    first = [text_of(e["message"]) for e in entries(fresh) if e.get("type") == "message"]
    seed_text = first[0] if first else ""
    if not (seed_text.startswith("bercail rollover") and str(session) in seed_text and "- live-1: Live job" in seed_text
            and "LIVE-RULE" in seed_text):
        fail(f"rollover seed: {seed_text[:400]}")
    if len(compactions(session)) != 2:
        fail(f"the rollover compacted the old session too: {len(compactions(session))}")
    shep.type("in the new session")
    if answered("in the new session") and session_files(sessions)[-1] == fresh:
        print("PASS: rollover starts a fresh session seeded with the board and the rules; the old one is kept")
    shep.stop()


if __name__ == "__main__":
    main()
