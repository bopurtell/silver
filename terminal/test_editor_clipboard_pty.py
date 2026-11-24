"""Real embedded Cobalt yank with an isolated clipboard-owner stub and OSC 52."""

import base64
from contextlib import closing
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


OSC52 = re.compile(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x07")
YANK = b"-- clipboard example \xc3\xa9 \xe7\x95\x8c\n"
SOURCE = YANK + b"package Counter where\n"


def clipboard_stub(path):
    path.write_text(f"""#!{sys.executable}
import os
from pathlib import Path
import sys
import time

name = Path(sys.argv[0]).name
content = sys.stdin.buffer.read()
with Path(os.environ["CLIPBOARD_LOG"]).open("a") as log:
    log.write(name + " " + " ".join(sys.argv[1:]) + "\\n")
if name in os.environ["CLIPBOARD_SLOW"].split(","):
    time.sleep(20)
if name in os.environ["CLIPBOARD_FAIL"].split(","):
    sys.exit(1)
path = Path(os.environ["CLIPBOARD_FILE"])
pending = path.with_suffix(".pending")
pending.write_bytes(content)
pending.replace(path)
""")
    path.chmod(0o755)


def exercise(client, base, *, mode="auto", failure="", slow="", remote=False,
             wayland=True, expected_native=None, expected_osc=False, internal=False,
             visual=False):
    config = base / "config" / "silver"
    config.mkdir(parents=True)
    (config / "editor.sexp").write_text(f"((clipboard {mode}))\n")
    tools = base / "bin"
    tools.mkdir()
    for name in ("wl-copy", "xclip"):
        clipboard_stub(tools / name)
    project = base / "project"
    project.mkdir()
    launcher = base / "ag"
    launcher.symlink_to(client)
    clipboard = base / "selection"
    clipboard.write_bytes(b"old stale clipboard\n")
    log = base / "clipboard.log"
    env = dict(os.environ, XDG_CONFIG_HOME=str(base / "config"),
               XDG_STATE_HOME=str(base / "state"), XDG_CACHE_HOME=str(base / "cache"),
               XDG_RUNTIME_DIR=str(base / "runtime"),
               PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
               DISPLAY=":invalid-isolated-display",
               CLIPBOARD_FILE=str(clipboard), CLIPBOARD_LOG=str(log),
               CLIPBOARD_FAIL=failure, CLIPBOARD_SLOW=slow)
    for key in ("SSH_CLIENT", "SSH_CONNECTION", "SSH_TTY", "WAYLAND_SOCKET", "WAYLAND_DISPLAY"):
        env.pop(key, None)
    if remote:
        env["SSH_CONNECTION"] = "192.0.2.1 12345 192.0.2.2 22"
    if wayland:
        env["WAYLAND_DISPLAY"] = "invalid-isolated-wayland"

    init = subprocess.run([launcher, "init", "--bluespec"], cwd=project, env=env,
                          capture_output=True, text=True, timeout=30)
    assert init.returncode == 0, init.stdout + init.stderr
    source = project / "Counter.bs"
    source.write_bytes(SOURCE)
    session = SimpleNamespace(env=env, evidence=base)
    with closing(Terminal(session, argv=[launcher], cwd=project, width=160, height=44)) as term:
        term.capture("overview", ["Overview", "Project: project"])
        term.palette("Open project file")
        term.capture("path", ["path[:line[:column]]"])
        os.write(term.master, b"Counter.bs:1\r")
        term.capture("editor", ["Cobalt focus", "Counter.bs", "clipboard example"])
        offset = len(term.data)
        os.write(term.master, b"Vy" if visual else b"yy")

        def paste_and_save():
            # The exact linewise register (including Unicode and trailing LF)
            # survives native delivery, failed transport, and disabling.
            os.write(term.master, b"p w")
            deadline = time.monotonic() + 8
            while source.read_bytes() != YANK + SOURCE:
                term.drain(.2)
                assert time.monotonic() < deadline, source.read_bytes()

        if internal and slow:
            # Start the paste shortly after the yank, while the slow clipboard
            # helper is still waiting. Editor commands must not wait for it.
            term.drain(.2)
            paste_and_save()

        if expected_native:
            term.capture("clipboard-native", [f"Copied to clipboard via {expected_native}"])
            assert clipboard.read_bytes() == YANK
        elif expected_osc:
            expected = ["OSC 52 sent", "terminal acceptance unknown"]
            if slow:
                expected.extend(["wl-copy timed out", "xclip failed"])
            term.capture("clipboard-osc52", expected)
            copies = OSC52.findall(term.data[offset:])
            assert [base64.b64decode(copy) for copy in copies] == [YANK]
            assert clipboard.read_bytes() == b"old stale clipboard\n"
        else:
            term.capture("clipboard-disabled", ["Clipboard disabled"])
            assert clipboard.read_bytes() == b"old stale clipboard\n"

        if not expected_osc:
            assert not OSC52.findall(term.data[offset:]), "native/disabled must not also emit OSC 52"
        commands = log.read_text().splitlines() if log.exists() else []
        wayland_args = "wl-copy --type text/plain;charset=utf-8"
        xclip_args = "xclip -selection clipboard -in -silent"
        if expected_native == "wl-copy":
            assert commands == [wayland_args], commands
        elif expected_native == "xclip":
            assert commands == ([wayland_args] if wayland else []) + [xclip_args], commands
        elif failure or slow:
            assert commands == [wayland_args, xclip_args], commands
        else:
            assert not commands, commands

        if internal and not slow:
            paste_and_save()
        if internal:
            assert clipboard.read_bytes() == (YANK if expected_native else b"old stale clipboard\n")


def main():
    client = Path(sys.argv[1]).resolve(strict=True)
    scratch = Path("/tmp/opencode")
    with tempfile.TemporaryDirectory(prefix="silver-editor-clipboard-",
                                     dir=scratch if scratch.is_dir() else None) as directory:
        root = Path(directory)
        exercise(client, root / "wayland", expected_native="wl-copy", internal=True)
        exercise(client, root / "x11", wayland=False, expected_native="xclip", visual=True)
        exercise(client, root / "fallback-x11", failure="wl-copy", expected_native="xclip")
        exercise(client, root / "transport-failure", failure="xclip", slow="wl-copy",
                 expected_osc=True, internal=True)
        exercise(client, root / "ssh", remote=True, expected_osc=True)
        exercise(client, root / "explicit", mode="osc52", expected_osc=True)
        exercise(client, root / "disabled", mode="disabled", internal=True)
    print("PASS: embedded clipboard native/OSC52 routes, diagnostics and internal paste")


if __name__ == "__main__":
    main()
