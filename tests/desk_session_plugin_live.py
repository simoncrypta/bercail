#!/usr/bin/env python3
# Disposable OpenCode TUI: the plugin records the selected session without a prompt.
import base64
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
import urllib.request
from pathlib import Path
from urllib.parse import quote

ROOT = Path(sys.argv[1])
OC = sys.argv[2]
PLUGIN = ROOT / "config/opencode/plugins/bercail-desk/tui.ts"
TMP = Path("/tmp/opencode")
TMP.mkdir(parents=True, exist_ok=True)
WORK = None
PROCS = []
FAILS = []


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
    for key in list(env):
        if key.startswith("OPENCODE") or key in ("HC_TERMINAL_ID", "HC_SESSION", "BASH_ENV"):
            env.pop(key, None)
    env.update(base)
    env.update(extra)
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    return env


def start_ticks(pid):
    text = Path(f"/proc/{pid}/stat").read_text()
    return text[text.rfind(")") + 2 :].split()[19]


def api(base, password, method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    token = base64.b64encode(f"opencode:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def wait_for(label, pred, timeout):
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


class Tui:
    def __init__(self, env, args, record=None, address=None):
        self.record = record
        self.term = WORK / "terminal.log"
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        if record is not None:
            wrap = WORK / f"wrap-{address}.sh"
            wrap.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "python3 -c 'import json,os,sys\n"
                "p,pid,addr=sys.argv[1:]\n"
                "os.makedirs(os.path.dirname(p), exist_ok=True)\n"
                "open(p,\"w\").write(json.dumps({\"address\":addr,\"session\":\"\",\"cwd\":\"/stale\","
                "\"harness\":\"opencode\",\"issue\":\"bercail-1\",\"space\":\"sp1\",\"args\":[\"--verbose\"],"
                "\"pid\":int(pid)})+\"\\n\")\n"
                "os.chmod(p, 0o640)\n"
                f"' {shlex.quote(str(record))} $$ {shlex.quote(address)}\n"
                f"exec {shlex.quote(OC)} \"$@\"\n"
            )
            wrap.chmod(0o755)
            cmd = [str(wrap), *args]
        else:
            cmd = [OC, *args]
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


def main():
    global WORK
    run = Path(TMP) / f"desk-session-plugin.{os.getpid()}"
    if run.exists():
        raise SystemExit(f"temp exists: {run}")
    WORK = run
    home = run / "home"
    plugin_dir = home / ".config/opencode/plugins/bercail-desk"
    plugin_dir.mkdir(parents=True)
    (plugin_dir / "tui.ts").write_bytes(PLUGIN.read_bytes())
    state = run / "state"
    runtime = run / "run"
    project = run / "project"
    for path in (state, runtime, project, run / "data", run / "cache"):
        path.mkdir(parents=True)
    (project / "README").write_text("desk plugin proof\n")
    base = {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(run / "data"),
        "XDG_STATE_HOME": str(state),
        "XDG_CACHE_HOME": str(run / "cache"),
        "XDG_RUNTIME_DIR": str(runtime),
    }
    records = state / "bercail/desk-sessions"
    log = open(run / "serve.log", "wb")
    server = subprocess.Popen(
        [OC, "serve", "--hostname", "127.0.0.1", "--port", "0"],
        cwd=project,
        env=child_env(base),
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    PROCS.append(server)
    password = port = None
    deadline = time.time() + 20
    while time.time() < deadline and (password is None or port is None):
        text = Path(run / "serve.log").read_text(errors="replace") if Path(run / "serve.log").exists() else ""
        for line in text.splitlines():
            if line.startswith("server listening on http://127.0.0.1:"):
                port = line.rsplit(":", 1)[-1].strip()
            if line.startswith("server password "):
                password = line.split(" ", 2)[-1].strip()
        if server.poll() is not None:
            break
        time.sleep(0.1)
    if not password or not port:
        fail(f"server did not start: {Path(run / 'serve.log').read_text(errors='replace')[-500:]}")
        return
    origin = f"http://127.0.0.1:{port}"
    created = api(origin, password, "POST", "/api/session", {})
    session = created["data"]["id"]
    if not session.startswith("ses_"):
        fail(f"session was not created: {created}")
        return
    url = f"http://opencode:{quote(password, safe='')}@{origin.split('://', 1)[1]}"
    print(f"session {session} created with no prompt")

    # Tabs on. A second tab is not opened here: the TUI's leader key is not
    # reliable on a raw PTY. The unit test unions an idle tab with the selection.
    record = records / "t9.json"
    decoy = records / "t-other.json"
    records.mkdir(parents=True, exist_ok=True)
    decoy.write_text('{"address":"t-other","session":"ses_keep","harness":"opencode","pid":1}\n')
    tui = Tui(
        child_env(base, HC_TERMINAL_ID="t9"),
        ["--server", url, "--session", session, str(project)],
        record,
        "t9",
    )
    claim = runtime / "bercail/open-sessions" / f"{tui.proc.pid}.json"

    def recorded():
        data = read_json(record)
        return data.get("session") == session and data.get("cwd") == str(project)

    if wait_for("selected session and its directory", recorded, 20):
        data = read_json(record)
        if data.get("issue") != "bercail-1" or data.get("args") != ["--verbose"] or data.get("space") != "sp1":
            fail(f"record metadata changed: {data}")
        if data.get("pid") != tui.proc.pid or data.get("address") != "t9" or data.get("harness") != "opencode":
            fail(f"record identity changed: {data}")
        if (record.stat().st_mode & 0o777) != 0o640:
            fail(f"record mode changed: {oct(record.stat().st_mode)}")
        claimed = read_json(claim)
        if claimed.get("pid") != tui.proc.pid or claimed.get("start_ticks") != start_ticks(tui.proc.pid):
            fail(f"claim ticks do not match this process: {claimed}")
        if session not in claimed.get("sessions", []):
            fail(f"claim misses the open session: {claimed}")
        cmd = Path(f"/proc/{tui.proc.pid}/cmdline").read_bytes().replace(b"\0", b" ").decode()
        if "--prompt" in cmd:
            fail(f"a prompt was passed: {cmd}")
        fresh = api(origin, password, "GET", f"/api/session/{session}")
        tokens = fresh["data"]["tokens"]
        if fresh["data"].get("cost") or tokens.get("input") or tokens.get("output"):
            fail(f"a model was prompted: {fresh['data']}")
        if decoy.read_text() != '{"address":"t-other","session":"ses_keep","harness":"opencode","pid":1}\n':
            fail("another terminal's record was touched")
        print("PASS: idle TUI recorded the resumed session, its directory, and the open-session claim")
        # Quitting must not look like home: a reboot still needs this session.
        tui.close()
        try:
            tui.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        if read_json(record).get("session") != session:
            fail(f"exit cleared the session: {read_json(record)}")
        else:
            print("PASS: exiting the TUI leaves the session to be resumed")
    else:
        tui.close()

    # Tabs off, the desk's bstack config: the route still names the session.
    off = records / "t-off.json"
    tui = Tui(
        child_env(base, HC_TERMINAL_ID="t-off", OPENCODE_CLI_CONFIG_CONTENT='{"tabs":{"mode":"off"}}'),
        ["--server", url, "--session", session, str(project)],
        off,
        "t-off",
    )
    off_claim = runtime / "bercail/open-sessions" / f"{tui.proc.pid}.json"

    def off_recorded():
        data = read_json(off)
        claimed = read_json(off_claim)
        return data.get("session") == session and session in claimed.get("sessions", [])

    if wait_for("tabs off still records the selected session", off_recorded, 20):
        print("PASS: tabs off, the selected session is still the one recorded")
    tui.close()

    # A nested or stale pid must not overwrite the desk, but this TUI still claims.
    stale = records / "t-stale.json"
    stale.write_text(
        json.dumps(
            {
                "address": "t-stale",
                "session": "",
                "cwd": "/stale",
                "harness": "opencode",
                "issue": "keep",
                "space": "sp1",
                "args": [],
                "pid": 1,
            }
        )
        + "\n"
    )
    original = stale.read_text()
    tui = Tui(
        child_env(base, HC_TERMINAL_ID="t-stale"),
        ["--server", url, "--session", session, str(project)],
    )
    stale_claim = runtime / "bercail/open-sessions" / f"{tui.proc.pid}.json"

    def claimed_only():
        return session in read_json(stale_claim).get("sessions", [])

    if wait_for("stale desk still publishes a claim", claimed_only, 20):
        if stale.read_text() != original:
            fail(f"a stale pid was overwritten: {stale.read_text()}")
        else:
            print("PASS: a stale pid is not overwritten; the TUI still claims its sessions")
    # No terminal: a claim, and no record invented.
    tui.close()
    bare = Tui(child_env(base), ["--server", url, "--session", session, str(project)])
    bare_claim = runtime / "bercail/open-sessions" / f"{bare.proc.pid}.json"
    invented = records / f"{bare.proc.pid}.json"

    def bare_claimed():
        return session in read_json(bare_claim).get("sessions", [])

    if wait_for("a TUI outside a desk still claims", bare_claimed, 20):
        if invented.exists() or (records / "none.json").exists():
            fail("a TUI outside a desk created a record")
        else:
            print("PASS: outside a desk the claim is written and no record is created")
    bare.close()

    # The claim is left behind when the process ends: a reload must not open a gap.
    if not bare_claim.exists():
        fail("the claim was deleted on exit")
    else:
        print("PASS: the claim is not deleted when the TUI exits")


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
