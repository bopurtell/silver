"""Exercise Silver's generic open action against the real embedded Cobalt pane."""
import fcntl
import os
from pathlib import Path
import re
import signal
import struct
import sys
import tempfile
import termios
import time
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


def exercise(client, base):
    launcher = base / "silver"
    launcher.symlink_to(client)
    roots = [base / name for name in ("alpha", "beta")]
    for root in roots:
        root.mkdir()
        (root / "dune-project").write_text(f"(lang dune 3.22)\n(name {root.name})\n")
        (root / "draft.txt").write_text(f"TITLE_{root.name}\né界target_{root.name}\n")
    env = dict(os.environ, XDG_CONFIG_HOME=str(base / "config"),
               XDG_STATE_HOME=str(base / "state"), XDG_RUNTIME_DIR=str(base / "runtime"))
    session = SimpleNamespace(env=env, evidence=base)
    term = Terminal(session, argv=[launcher, "--project-root", roots[0]], cwd=roots[0])

    def send(data):
        os.write(term.master, data)

    def see(label, *expected, absent=()):
        return term.capture(label, expected, absent=absent)

    def open_file(target):
        term.palette("Open project file")
        see("open-file-prompt", "path[:line[:column]]")
        send(target.encode() + b"\r")

    def click_tab(name):
        label = re.compile(rf"\b\d+ {name}\b")
        screen = see("tab-available-" + name, label)
        y, row = next((y, row) for y, row in enumerate(screen.splitlines(), start=1)
                      if label.search(row) and "Project" in row)
        x = label.search(row).start() + 1
        send(f"\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m".encode())

    def resize(width, height):
        term.width, term.height = width, height
        fcntl.ioctl(term.master, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
        term.process.send_signal(signal.SIGWINCH)

    def switch_project(root):
        term.palette("Open Project…")
        see("project-picker", "Existing project directory")
        send(str(root).encode() + b"\r")
        see("switched-" + root.name, "Overview", "Project: " + root.name)

    f6, f7 = b"\x1b[17~", b"\x1b[18~"
    alt_left = b"\x1b[1;3D"
    editor_tab = re.compile(r"\[\d+ Editor\]")
    overview_tab = re.compile(r"\[\d+ Overview\]")
    # The lightweight ANSI oracle leaves the trailing cell of a wide glyph
    # visible as a space. Assert the textual position without that artifact.
    alpha = re.compile(r"é界 *target_alpha")
    beta = re.compile(r"é界 *target_beta")
    dirty = re.compile(r"é界 *DIRTY_target_alpha")
    try:
        see("initial", overview_tab, "Project: alpha", re.compile(r"\b\d+ Editor\b"))
        click_tab("Editor")
        see("editor-without-file", editor_tab, "Cobalt focus", "NORMAL", "Alt+Left")
        click_tab("Overview")
        see("clicked-out-of-editor", overview_tab, "Project: alpha")
        open_file("draft.txt")
        see("file-only", editor_tab, "Cobalt focus", "TITLE_alpha", "F7 Back")
        send(b"\x0f")  # Ctrl-O is Cobalt's own jump history, not Silver Back.
        see("cobalt-ctrl-o", editor_tab, "Cobalt focus")
        send(alt_left)
        see("back", overview_tab, "Project: alpha")

        open_file("missing.txt")
        see("missing", overview_tab, "Cannot open in Editor", "missing.txt", absent=(editor_tab,))
        open_file("draft.txt:2:4")
        see("positioned", editor_tab, "Cobalt focus", alpha)
        send(b"iDIRTY_\x1b")
        see("edited", dirty)

        send(f6 + b"ix")
        see("sibling-focus", "Silver focus", dirty, absent=("DIRTY_ixtarget",))
        resize(90, 24)
        see("resized", editor_tab, "Silver focus", dirty)
        send(f6)
        see("editor-focus", "Cobalt focus", dirty)
        resize(70, 24)
        see("narrow-editor", editor_tab, "Cobalt focus", dirty)
        resize(120, 40)
        see("wide-editor", editor_tab, "F6 Focus pane", dirty)

        send(f7)
        see("hidden", overview_tab, absent=("DIRTY_target_alpha",))
        open_file("draft.txt:2")
        see("retained", "Cobalt focus", dirty)
        send(b"u")
        see("undo", alpha, absent=("DIRTY_target_alpha",))
        send(b"\x12")
        see("redo", dirty)
        assert (roots[0] / "draft.txt").read_text() == "TITLE_alpha\né界target_alpha\n"
        send(b" gg")
        see("cobalt-vcs", "VCS: not a repository")
        send(b"q")
        see("after-cobalt-vcs", "Cobalt focus", dirty)

        send(f7)
        see("before-project-switch", "Project: alpha")
        switch_project(roots[1])
        open_file("draft.txt")
        see("other-project", "TITLE_beta", beta, absent=("DIRTY_target_alpha",))
        send(b" q")
        see("editor-closed", "Project: beta", absent=("Cobalt focus",))
        open_file("draft.txt")
        see("editor-restarted", "TITLE_beta", beta)
        send(f7)
        see("beta-dashboard", "Project: beta")
        switch_project(roots[0])
        term.palette("Switch to Editor")
        see("original-project-retained", "TITLE_alpha", dirty)

        send(b"\x03")
        deadline = time.monotonic() + 12
        while term.process.poll() is None:
            screen = term.drain(.15, allow_exit=True)
            assert time.monotonic() < deadline, f"Silver did not exit:\n{screen}"
        term.drain(.15, allow_exit=True)
        assert term.process.returncode == 0
        assert (roots[0] / "draft.txt").read_text() == "TITLE_alpha\né界target_alpha\n"
    finally:
        term.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="silver-editor-") as directory:
        exercise(Path(sys.argv[1]).resolve(), Path(directory))
