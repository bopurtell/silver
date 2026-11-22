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

    def editor_palette(query, result):
        for key in (b" ", b"c", b"c"):
            send(key)
            term.drain(.12)
        send(query.encode())
        see("editor-palette-" + query, "Cobalt focus", result)

    def click(x, y):
        send(f"\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m".encode())

    def click_tab(name):
        label = re.compile(rf"\b\d+ {name}\b")
        screen = see("tab-available-" + name, label)
        y, row = next((y, row) for y, row in enumerate(screen.splitlines(), start=1)
                      if label.search(row) and "Project" in row)
        x = label.search(row).start() + 1
        click(x, y)

    def frame(screen, heading):
        return next((row.index(heading), y) for y, row in enumerate(screen.splitlines(), start=1)
                    if heading in row)

    def cursor():
        updates = re.findall(rb"\x1b\[\?25([hl])(?:\x1b\[(\d+);(\d+)H)?", term.data)
        state, y, x = updates[-1]
        return (int(x), int(y)) if state == b"h" and x and y else None

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
        resize(80, 32)
        see("initial", overview_tab, re.compile(r"\b\d+ Editor\b"))
        click_tab("Editor")
        see("editor-without-file", editor_tab, "Cobalt focus", "DIRECTORY", "Alt+Left",
            "Directory: 0 marked", re.compile(r"╭─ .*?/alpha "),
            absent=("Directory: 0 marked |",))
        editor_palette("ov", "Switch to Overview")
        send(b"\r")
        see("overview-from-directory", overview_tab, absent=("Cobalt focus",))
        resize(120, 40)
        see("initial-wide", overview_tab, "Project: alpha")
        open_file("draft.txt")
        see("file-only", editor_tab, "Cobalt focus", "TITLE_alpha", "F7 Back")
        send(b"\x0f")  # Ctrl-O is Cobalt's own jump history, not Silver Back.
        see("cobalt-ctrl-o", editor_tab, "Cobalt focus")
        send(alt_left)
        see("back", overview_tab, "Project: alpha")

        open_file("missing.txt")
        see("missing", overview_tab, "Cannot open in Editor", "missing.txt", absent=(editor_tab,))
        open_file("draft.txt:2:4")
        screen = see("positioned", editor_tab, "Cobalt focus", alpha, "╭ editor ", "╭ session ")
        target = frame(screen, "target_alpha")
        assert cursor() == (target[0] + 1, target[1])
        send(b"iDIRTY_\x1b")
        see("edited", dirty)

        # Normal `o` still opens a line even when Silver exports `ov`.
        send(b"oOPEN_LINE\x1b")
        see("cobalt-normal-o", editor_tab, dirty, "OPEN_LINE", absent=("Switch to Overview",))
        send(b"u")
        see("undo-open-line", editor_tab, dirty, absent=("OPEN_LINE",))
        editor_palette("Open project file", "Silver: Open project file")
        send(b"\r")
        see("silver-prompt-from-merged-palette", editor_tab, "path[:line[:column]]")
        send(b"\x1b")
        screen = see("cancel-silver-prompt", editor_tab, "Cobalt focus", dirty,
                     absent=("path[:line[:column]]",))

        x, y = frame(screen, "╭ session ")
        click(x + 1, y)  # The origin's border focuses Silver, not the buffer.
        see("context-border-focus", "Silver focus", dirty)
        assert cursor() is None
        send(b"ix")
        see("sibling-focus", "Silver focus", dirty, absent=("DIRTY_ixtarget",))
        resize(90, 24)
        see("resized", editor_tab, "Silver focus", dirty)
        click_tab("Overview")
        see("leave-from-companion", overview_tab, absent=("DIRTY_target_alpha",))
        click_tab("Editor")
        see("companion-focus-retained", editor_tab, "Silver focus", dirty)
        screen = see("companion-frame", "╭ editor ", "╭ session ")
        x, y = frame(screen, "╭ editor ")
        click(x + 1, y)
        see("editor-focus", "Cobalt focus", dirty)
        assert cursor() is not None
        resize(70, 24)
        see("narrow-editor", editor_tab, "Cobalt focus", dirty, absent=("╭ session ",))
        send(f6)
        see("narrow-tabs-focus", editor_tab, "Silver focus", dirty)
        assert cursor() is None
        send(f6)
        see("narrow-editor-focus", "Cobalt focus", dirty)
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
        see("back-before-context-tests", overview_tab)
        for workspace, kind in (("Resources", "resources"), ("Testing", "simulation-catalog")):
            click_tab(workspace)
            workspace_tab = re.compile(rf"\[\d+ {workspace}\]")
            title = f"╭ {kind} "
            screen = see("origin-" + kind, workspace_tab, title)
            x, y = frame(screen, title)
            click(x + 1, y)
            open_file("draft.txt:2")
            see("companion-" + kind, editor_tab, title, "╭ editor ", dirty)
            send(alt_left)
            see("back-to-" + kind, workspace_tab, title, absent=("Cobalt focus",))
        click_tab("Overview")
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
        editor_palette("signoff", "Launch signoff and view")
        send(b"\r")
        see("silver-command-unavailable", editor_tab,
            "No declared catalog default; choose explicit flow/profile inputs")
        assert cursor() is not None

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
