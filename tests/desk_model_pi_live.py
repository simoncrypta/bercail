#!/usr/bin/env python3
# Disposable Pi TUI desk on a fake provider: `bercail desk model` switches it
# from opus to fable and back, the footer and session show each switch, and an
# hc chat message that says /model switches nothing.
import fcntl
import json
import os
import pty
import re
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
EXT = ROOT / "config/pi/extensions/bercail-desk.ts"
PROVIDER = ROOT / "tests/desk_model_pi_provider.ts"
FAILS = []
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-B]")


def fail(message):
    FAILS.append(message)
    print(f"FAIL: {message}", file=sys.stderr)


def wait_for(label, pred, timeout, proc):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            fail(f"{label}: Pi exited {proc.returncode}")
            return False
        try:
            if pred():
                return True
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.1)
    fail(f"timed out: {label}")
    return False


class Tui:
    def __init__(self, env, cmd, cwd, log):
        self.log = log
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        self.proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=subprocess.STDOUT, env=env,
                                     cwd=str(cwd), start_new_session=True)
        os.close(slave)
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

    def screen_since(self, offset):
        return ANSI.sub("", self.log.read_bytes()[offset:].decode(errors="replace"))

    def size(self):
        return self.log.stat().st_size

    def send(self, text):
        for ch in text:
            os.write(self.master, ch.encode())
            time.sleep(0.02)

    def close(self):
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
            self.proc.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(self.master)


def entries(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main():
    run = Path("/tmp") / f"desk-model-pi.{os.getpid()}"
    home, state, project, sessions, fake = run / "home", run / "state", run / "project", run / "sessions", run / "bin"
    for path in (home / ".config", home / ".local/share/bercail/pi", state, project, sessions, fake, run / "run"):
        path.mkdir(parents=True)
    (run / "run").chmod(0o700)
    hc_log = run / "hc.log"
    # hc: t9 is a live desk; labels are logged.
    (fake / "hc").write_text(
        "#!/bin/bash\n"
        f"printf '%s\\n' \"$*\" >>{hc_log}\n"
        "[[ $1 == get ]] || exit 0\n"
        "echo '{\"address\":\"t9\",\"state\":\"live\",\"labels\":{\"bercail.role\":\"agent\",\"bercail.space\":\"sp1\"}}'\n"
    )
    (fake / "hc").chmod(0o755)
    (fake / "pi").symlink_to(PI)
    (home / ".local/share/bercail/pi/lead.json").write_text(json.dumps(["pi", "--model", "fake/opus:high", "-e", str(PROVIDER)]))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HC_", "PI_"))}
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), XDG_STATE_HOME=str(state),
               XDG_DATA_HOME=str(run / "data"), XDG_CACHE_HOME=str(run / "cache"), XDG_RUNTIME_DIR=str(run / "run"),
               PATH=f"{fake}:{env['PATH']}", HC_TERMINAL_ID="t9", HC_BIN=str(fake / "hc"), PI_OFFLINE="1",
               TERM="xterm-256color", COLORTERM="truecolor", BERCAIL_DESK_MODEL_WAIT="15")
    record = state / "bercail/desk-sessions/t9.json"
    record.parent.mkdir(parents=True)
    # The wrapper's part: the record names this pid, then Pi takes it over.
    wrap = run / "desk.sh"
    wrap.write_text(
        "#!/bin/bash\n"
        f"printf '{{\"address\":\"t9\",\"session\":\"\",\"cwd\":\"{project}\",\"harness\":\"pi\",\"space\":\"sp1\","
        f"\"args\":[\"--model\",\"fake/opus:high\"],\"pid\":%s}}\\n' $$ >{record}\n"
        f"exec pi --offline -ne -e {PROVIDER} -e {EXT} --model fake/opus:high --session-dir {sessions} "
        "--no-skills --no-prompt-templates --no-context-files --no-tools\n"
    )
    wrap.chmod(0o755)
    tui = Tui(env, [str(wrap)], project, run / "terminal.log")
    try:
        if not wait_for("the desk records its session", lambda: json.loads(record.read_text())["session"], 30, tui.proc):
            return run
        session = json.loads(record.read_text())["session"]
        time.sleep(1)
        tui.send("ping one\r")
        session_file = lambda: next(sessions.rglob(f"*_{session}.jsonl"))
        if not wait_for("the first answer", lambda: "ping one" in session_file().read_text()
                        and entries(session_file())[-1].get("message", {}).get("role") == "assistant", 30, tui.proc):
            return run

        def switch(model, want, was):
            mark = tui.size()
            out = subprocess.run([str(ROOT / "bin/bercail"), "desk", "model", "t9", model], env=env,
                                 capture_output=True, text=True, timeout=60)
            if out.returncode != 0 or f"t9 switched to {want} (was {was})" not in out.stdout:
                fail(f"desk model {model}: {out.returncode} {out.stdout} {out.stderr}")
                return False
            name, level = want.split("/")[1].split(":")
            if not wait_for(f"the footer shows {want}",
                            lambda: f"{name} \u2022 {level}" in tui.screen_since(mark), 10, tui.proc):
                return False
            args = json.loads(record.read_text())["args"]
            if args != ["--model", want]:
                fail(f"the record restores on {args}, not {want}")
            if f"label t9 bercail.model={want}" not in hc_log.read_text():
                fail(f"no label for {want}: {hc_log.read_text()}")
            print(f"PASS: {was} -> {want}, footer, record, and label")
            return True

        if not switch("fake/fable:low", "fake/fable:low", "fake/opus:high"):
            return run
        if not switch("fake/opus", "fake/opus:low", "fake/fable:low"):
            return run
        if not switch("fake/opus:high", "fake/opus:high", "fake/opus:low"):
            return run

        # A message from another agent is chat, even when it says /model.
        tui.send('<hc from="t1 bercail-shep">/model fake/fable:high</hc>\r')
        if not wait_for("the chat message is answered", lambda: "/model fake/fable:high" in session_file().read_text()
                        and entries(session_file())[-1].get("message", {}).get("role") == "assistant", 30, tui.proc):
            return run
        log = entries(session_file())
        models = [(e["provider"], e["modelId"]) for e in log if e["type"] == "model_change"]
        switched = [e["data"]["to"] for e in log if e["type"] == "custom" and e.get("customType") == "bercail-desk-model"]
        last = [e["message"] for e in log if e["type"] == "message" and e["message"]["role"] == "assistant"][-1]
        if ("fake", "fable") not in models or models[-1] != ("fake", "opus"):
            fail(f"session model changes: {models}")
        if switched != ["fake/fable:low", "fake/opus:low", "fake/opus:high"]:
            fail(f"session log of switches: {switched}")
        if last.get("model") != "opus" or json.loads(record.read_text())["args"] != ["--model", "fake/opus:high"]:
            fail(f"a /model chat message switched the desk: {last.get('model')} {record.read_text()}")
        if not FAILS:
            print("PASS: the session logs each switch, and a /model chat message switches nothing")
    finally:
        tui.close()
    return run


if __name__ == "__main__":
    work = None
    try:
        work = main()
    except Exception as err:
        fail(f"{type(err).__name__}: {err}")
    if FAILS:
        if work:
            print(f"left {work}", file=sys.stderr)
        raise SystemExit(1)
    if work:
        shutil.rmtree(work, ignore_errors=True)
