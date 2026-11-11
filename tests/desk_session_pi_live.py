#!/usr/bin/env python3
# Disposable Pi TUI: the extension records the session without a subscription.
import json
import os
import pty
import select
import shlex
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
EXT = ROOT / "config/pi/extensions/bercail-desk.ts"
PROVIDER = ROOT / "tests/desk_session_pi_provider.ts"
TMP = Path("/tmp")
WORK = None
PROCS = []
FAILS = []
TOKEN = "desk-pi-ping"


def fail(message):
    FAILS.append(message)
    print(f"FAIL: {message}", file=sys.stderr)


def kill_all():
    for proc in PROCS:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    time.sleep(0.2)
    for proc in PROCS:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def child_env(base, **extra):
    env = os.environ.copy()
    drop = {
        "HC_TERMINAL_ID",
        "HC_SESSION",
        "HC_TERMINAL_SOCKET",
        "BASH_ENV",
        "PI_CODING_AGENT_DIR",
        "PI_SESSION_ID",
        "PI_SESSION_FILE",
        "PI_PROVIDER",
        "PI_MODEL",
        "PI_REASONING_LEVEL",
        "PI_OFFLINE",
    }
    for key in list(env):
        if key in drop:
            env.pop(key, None)
    env.update(base)
    env.update(extra)
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["PI_OFFLINE"] = "1"
    return env


def start_ticks(pid):
    text = Path(f"/proc/{pid}/stat").read_text()
    return text[text.rfind(")") + 2 :].split()[19]


def record_text(address, pid, harness):
    return (
        json.dumps(
            {
                "address": address,
                "session": "",
                "cwd": "/stale",
                "harness": harness,
                "issue": "bercail-1",
                "space": "sp1",
                "args": ["--verbose"],
                "pid": pid,
            }
        )
        + "\n"
    )


def wait_for(label, pred, timeout, proc=None):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc is not None and proc.poll() is not None:
            fail(f"{label}: process exited {proc.returncode}")
            return False
        try:
            if pred():
                return True
        except Exception:
            pass
        time.sleep(0.1)
    fail(f"timed out: {label}")
    return False


class Tui:
    def __init__(self, env, args, record=None, address=None, harness="pi"):
        self.term = WORK / f"terminal-{address or 'bare'}-{len(PROCS)}.log"
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        if record is not None:
            wrap = WORK / f"wrap-{address}-{len(PROCS)}.sh"
            wrap.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "python3 -c 'import json,os,sys\n"
                "p,pid,addr,harness=sys.argv[1:]\n"
                "os.makedirs(os.path.dirname(p), exist_ok=True)\n"
                "open(p,\"w\").write(json.dumps({\"address\":addr,\"session\":\"\",\"cwd\":\"/stale\","
                "\"harness\":harness,\"issue\":\"bercail-1\",\"space\":\"sp1\",\"args\":[\"--verbose\"],"
                "\"pid\":int(pid)})+\"\\n\")\n"
                "os.chmod(p, 0o640)\n"
                f"' {shlex.quote(str(record))} $$ {shlex.quote(address)} {shlex.quote(harness)}\n"
                f"exec {shlex.quote(PI)} \"$@\"\n"
            )
            wrap.chmod(0o755)
            cmd = [str(wrap), *args]
        else:
            cmd = [PI, *args]
        self.proc = subprocess.Popen(
            cmd,
            stdin=slave,
            stdout=slave,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=str(WORK / "project"),
            start_new_session=True,
        )
        os.close(slave)
        PROCS.append(self.proc)
        self.sink = open(self.term, "ab")
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

    def send(self, text, delay=0.03):
        for ch in text:
            os.write(self.master, ch.encode())
            time.sleep(delay)

    def close(self):
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.close(self.master)
        except OSError:
            pass


def read_json(path):
    return json.loads(Path(path).read_text())


def pi_args(session_dir, extra=None):
    args = [
        "--offline",
        "-ne",
        "-e",
        str(PROVIDER),
        "-e",
        str(EXT),
        "--model",
        "fake/model",
        "--thinking",
        "off",
        "--session-dir",
        str(session_dir),
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--no-mcp",
        "--no-tools",
    ]
    if extra:
        args.extend(extra)
    return args


def session_file(session_dir, session_id):
    matches = [path for path in Path(session_dir).rglob("*.jsonl") if path.name.endswith(f"_{session_id}.jsonl")]
    return matches[0] if len(matches) == 1 else None


def dump(tui=None):
    if tui is None:
        return
    try:
        text = tui.term.read_text(errors="replace")
    except OSError:
        return
    print("--- terminal ---", file=sys.stderr)
    print(text[-2000:], file=sys.stderr)


def main():
    global WORK
    run = TMP / f"desk-session-pi.{os.getpid()}"
    if run.exists():
        raise SystemExit(f"temp exists: {run}")
    WORK = run
    home = run / "home"
    state = run / "state"
    runtime = run / "run"
    project = run / "project"
    sessions = run / "sessions"
    for path in (home, state, runtime, project, sessions, run / "data", run / "cache", home / ".config"):
        path.mkdir(parents=True)
    runtime.chmod(0o700)
    (project / "README").write_text("desk pi proof\n")
    base = {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(run / "data"),
        "XDG_STATE_HOME": str(state),
        "XDG_CACHE_HOME": str(run / "cache"),
        "XDG_RUNTIME_DIR": str(runtime),
    }
    records = state / "bercail/desk-sessions"
    record = records / "t9.json"
    env = child_env(base, HC_TERMINAL_ID="t9")

    tui = Tui(env, pi_args(sessions), record, "t9", "pi")
    claim = runtime / "bercail/open-sessions" / f"{tui.proc.pid}.json"

    def recorded():
        data = read_json(record)
        return isinstance(data.get("session"), str) and data["session"] != ""

    if not wait_for("session id recorded at startup", recorded, 30, tui.proc):
        dump(tui)
        return
    data = read_json(record)
    session = data["session"]
    time.sleep(0.6)
    tui.send(TOKEN + "\r")

    def filed():
        path = session_file(sessions, session)
        return path is not None and TOKEN in path.read_text(errors="replace")

    if not wait_for("session file named with the recorded id", filed, 30, tui.proc):
        dump(tui)
        return
    data = read_json(record)
    if data.get("cwd") != str(project):
        fail(f"cwd was not the dir Pi ran in: {data.get('cwd')}")
    if (
        data.get("issue") != "bercail-1"
        or data.get("args") != ["--verbose"]
        or data.get("space") != "sp1"
        or data.get("address") != "t9"
        or data.get("harness") != "pi"
        or data.get("pid") != tui.proc.pid
    ):
        fail(f"record metadata changed: {data}")
    if (record.stat().st_mode & 0o777) != 0o640:
        fail(f"record mode changed: {oct(record.stat().st_mode)}")
    claimed = read_json(claim)
    if claimed.get("pid") != tui.proc.pid or claimed.get("start_ticks") != start_ticks(tui.proc.pid):
        fail(f"claim ticks do not match this process: {claimed}")
    if claimed.get("sessions") != [session]:
        fail(f"claim is not the one session: {claimed}")
    if (claim.stat().st_mode & 0o777) != 0o600:
        fail(f"claim mode is not 0600: {oct(claim.stat().st_mode)}")
    saved = session_file(sessions, session)
    if FAILS:
        dump(tui)
        return
    print("PASS: startup recorded the session id, its directory, and the open-session claim")

    tui.send("/quit\r")
    try:
        tui.proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        fail(" /quit did not exit")
        dump(tui)
        return
    if read_json(record).get("session") != session:
        fail(f"exit cleared the session: {read_json(record)}")
        return
    print("PASS: quitting leaves the session to be resumed")

    tui = Tui(env, pi_args(sessions, ["--session-id", session]), record, "t9", "pi")
    claim = runtime / "bercail/open-sessions" / f"{tui.proc.pid}.json"

    def resumed():
        data = read_json(record)
        # The previous process left the same id behind. This run's wrapper
        # rewrites pid first, so the new pid is what proves this process wrote.
        return (
            data.get("pid") == tui.proc.pid
            and data.get("session") == session
            and data.get("cwd") == str(project)
            and TOKEN in saved.read_text(errors="replace")
        )

    if not wait_for("resumed session id recorded", resumed, 30, tui.proc):
        dump(tui)
        return
    claimed = read_json(claim) if claim.exists() else None
    if not claimed or claimed.get("sessions") != [session] or claimed.get("pid") != tui.proc.pid:
        fail(f"resumed claim is not the same session: {claimed}")
    else:
        print("PASS: --session-id records the same id and keeps the earlier message")

    time.sleep(0.6)
    tui.send("/new\r")

    def renewed():
        current = read_json(record).get("session")
        return isinstance(current, str) and current not in ("", session)

    if not wait_for("/new moves the recorded session", renewed, 15, tui.proc):
        tui.send("\r")
        if not wait_for("/new moves the recorded session", renewed, 15, tui.proc):
            dump(tui)
            return
    new_id = read_json(record)["session"]
    if read_json(claim).get("sessions") != [new_id]:
        fail(f"/new did not move the claim: {read_json(claim)}")
    else:
        print(f"PASS: /new moved the recorded session to {new_id}")
    tui.send("/quit\r")
    try:
        tui.proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        tui.close()

    foreign = records / "t-other.json"
    other = Tui(child_env(base, HC_TERMINAL_ID="t-other"), pi_args(sessions), foreign, "t-other", "other")
    other_claim = runtime / "bercail/open-sessions" / f"{other.proc.pid}.json"
    expected = record_text("t-other", other.proc.pid, "other")

    def claimed_only():
        return other_claim.exists() and read_json(other_claim).get("pid") == other.proc.pid

    if wait_for("foreign desk still publishes a claim", claimed_only, 30, other.proc):
        if foreign.read_text() != expected:
            fail(f"a foreign record was overwritten: {foreign.read_text()!r} != {expected!r}")
        else:
            print("PASS: a non-Pi record is left byte-for-byte alone")
    else:
        dump(other)
    other.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        fail(f"{type(err).__name__}: {err}")
    finally:
        kill_all()
    if FAILS:
        if WORK:
            print(f"left {WORK}", file=sys.stderr)
        raise SystemExit(1)
    if WORK:
        import shutil

        shutil.rmtree(WORK, ignore_errors=True)
