"""Exercise normal-workbench exit confirmation, mouse input and restart settings."""

from contextlib import closing
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


def send(term, data):
    os.write(term.master, data)
    term.drain(.12)


def mouse(term, x, y):
    packet = f"\x1b[<0;{x + 1};{y + 1}"
    os.write(term.master, (packet + "M" + packet + "m").encode())


def click(term, screen, label):
    for y, row in enumerate(screen.splitlines()):
        if label in row:
            mouse(term, row.index(label), y)
            return
    raise AssertionError(f"{label} missing: {screen}")


def wait_exit(term, data=None):
    if data is not None:
        os.write(term.master, data)
    deadline = time.monotonic() + 15
    while term.process.poll() is None:
        term.drain(.15, allow_exit=True)
        assert time.monotonic() < deadline, "client did not quit"
    assert term.process.returncode == 0, term.process.returncode


def exercise(client, base):
    env = dict(os.environ, HOME=str(base / "home"), XDG_STATE_HOME=str(base / "state"),
               XDG_RUNTIME_DIR=str(base / "runtime"), XDG_CONFIG_HOME=str(base / "config"))
    for key in ["HOME", "XDG_RUNTIME_DIR"]:
        Path(env[key]).mkdir(mode=0o700)
    root = base / "project"
    (root / ".silver").mkdir(parents=True)
    (root / ".silver/project.json").write_text(json.dumps(
        dict(schema_version=1, name="quit-project", build_label="//:rtl", test_label="//:simulation")))

    def launch():
        return closing(Terminal(SimpleNamespace(env=env, evidence=base),
                                argv=[client, "--standalone", "--project-root", root], cwd=root))

    def ready(term, label):
        term.capture(label, ["Overview"], absent=["Quit Silver?"])

    with launch() as term:
        ready(term, "ready")
        send(term, b"q")
        term.capture("default-yes", ["Quit Silver?", ">[Yes]", "[No]", "Left/Right Tab"])
        send(term, b"\x1b[C")
        term.capture("arrow-no", ["Quit Silver?", ">[No]"])
        send(term, b"\r")
        ready(term, "enter-no")
        send(term, b"q")
        send(term, b"\x1b")
        ready(term, "escape")
        send(term, b"q")
        send(term, b"n")
        ready(term, "keyboard-no")

        term.palette("Hide main window control hints")
        send(term, b"q")
        term.capture("mouse-modal", ["Quit Silver?", ">[Yes]"], absent=["Left/Right Tab"])
        mouse(term, 0, 0)
        screen = term.capture("outside-click-ignored", ["Quit Silver?", ">[Yes]"])
        click(term, screen, "[No]")
        ready(term, "mouse-no")

        term.palette("quit")
        term.capture("palette-quit", ["Quit Silver?", ">[Yes]"])
        send(term, b"\x1b")
        ready(term, "palette-cancel")
        term.palette("Quit: Initially select No")
        send(term, b"q")
        term.capture("preference-no", ["Quit Silver?", ">[No]"])
        send(term, b"\r")
        ready(term, "preference-no-cancel")
        wait_exit(term, b"Q")

    with launch() as term:
        ready(term, "restart-no")
        send(term, b"q")
        term.capture("restart-default-no", ["Quit Silver?", ">[No]"])
        send(term, b"\t")
        term.capture("tab-yes", ["Quit Silver?", ">[Yes]"])
        wait_exit(term, b"\r")

    with launch() as term:
        ready(term, "restart-confirm")
        term.palette("Quit: Immediately on q")
        wait_exit(term, b"q")

    with launch() as term:
        ready(term, "restart-immediate")
        wait_exit(term, b"q")

    with launch() as term:
        ready(term, "restore-dialog")
        term.palette("Quit: Confirm with dialog")
        send(term, b"q")
        screen = term.capture("restore-confirm-default-no", ["Quit Silver?", ">[No]"])
        click(term, screen, "[Yes]")
        wait_exit(term)

    with launch() as term:
        ready(term, "restore-yes")
        term.palette("Quit: Initially select Yes")
        send(term, b"q")
        term.capture("restore-default-yes", ["Quit Silver?", ">[Yes]"])
        wait_exit(term, b"\r")


if __name__ == "__main__":
    with TemporaryDirectory(prefix="silver-quit-") as directory:
        exercise(Path(sys.argv[1]).resolve(), Path(directory))
