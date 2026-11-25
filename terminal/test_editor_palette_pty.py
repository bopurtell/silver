"""The real embedded Cobalt palette can dispatch Silver and Cobalt commands."""
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


EDITOR_TAB = re.compile(r"\[\d+ Editor\]")
OVERVIEW_TAB = re.compile(r"\[\d+ Overview\]")
COBALT_PALETTE = re.compile(r"╭[─ ]+Commands\b")
SILVER_PALETTE = "COMMAND PALETTE"
MODALS = (COBALT_PALETTE, SILVER_PALETTE)


def exercise(client, base):
    launcher = base / "ag"
    launcher.symlink_to(client)
    root = base / "project"
    root.mkdir()
    (root / "dune-project").write_text("(lang dune 3.22)\n(name palette_project)\n")
    source = root / "draft.txt"
    original = "ORIGINAL_HEADER\nTARGET_caret\n"
    source.write_text(original)
    session = SimpleNamespace(
        env=dict(os.environ, XDG_CONFIG_HOME=str(base / "config"),
                 XDG_STATE_HOME=str(base / "state"), XDG_RUNTIME_DIR=str(base / "runtime")),
        evidence=base,
    )
    # Leave room for Cobalt's status message beside the sandboxed project path.
    term = Terminal(session, argv=[launcher, "--project-root", root], cwd=root, width=200)

    def send(data):
        os.write(term.master, data)

    def see(label, *expected, absent=()):
        return term.capture(label, expected, absent=absent)

    def caret():
        # Silver paints the outer terminal cursor after the composite frame.
        updates = re.findall(rb"\x1b\[\?25([hl])(?:\x1b\[(\d+);(\d+)H)?", term.data)
        if updates:
            state, y, x = updates[-1]
            if state == b"h" and x and y:
                return int(x), int(y)
        return None

    def editor_palette(query, selected, label):
        send(b" cc")
        see(label + "-open", EDITOR_TAB, COBALT_PALETTE, absent=(SILVER_PALETTE,))
        send(query.encode())
        see(label + "-query", EDITOR_TAB, COBALT_PALETTE, f"│ > {query}",
            re.compile(r"│ > [^\n]*" + re.escape(selected)),
            absent=(SILVER_PALETTE,))

    def paste(text):
        send(b"\x1b[200~" + text.encode() + b"\x1b[201~")

    typed = "TYPED cc ov|"
    pasted = "PASTED cc ov|"
    dirty = typed + pasted + "TARGET_caret"
    try:
        see("initial", OVERVIEW_TAB)
        term.palette("Open project file")
        see("open-file", "path[:line[:column]]")
        send(b"draft.txt:2:1\r")
        see("focused", EDITOR_TAB, "Cobalt focus", "TARGET_caret", absent=MODALS)

        send(b"i" + typed.encode())
        see("insert-chord-literal", EDITOR_TAB, "Cobalt focus",
            typed + "TARGET_caret", absent=MODALS)
        paste(pasted)
        see("paste-chord-literal", EDITOR_TAB, "Cobalt focus", dirty, absent=MODALS)
        send(b"\x1b")
        see("leave-insert", EDITOR_TAB, "Cobalt focus", "NORMAL", dirty, absent=MODALS)
        paste(" ccov")
        see("normal-paste-not-a-command", EDITOR_TAB, "Cobalt focus", dirty,
            "Paste ignored", absent=MODALS)

        # Check a native result in the same palette, and verify that Enter
        # actually runs it on the dirty document, not just that the row exists.
        editor_palette("undo", "Undo", "native-undo")
        send(b"\r")
        see("native-undo-ran", EDITOR_TAB, "Cobalt focus", "TARGET_caret",
            absent=(*MODALS, typed, pasted))
        send(b"\x12")  # native Ctrl-R redo
        see("native-redo-ran", EDITOR_TAB, "Cobalt focus", dirty, absent=MODALS)
        # Move off the redo cursor so a reset to the open-file position fails.
        send(b"5l")
        screen = see("before-handoff", EDITOR_TAB, "Cobalt focus", dirty, absent=MODALS)
        x0, y0 = next((row.index(dirty) + 1, y)
                      for y, row in enumerate(screen.splitlines(), 1) if dirty in row)
        before = caret()
        assert before is not None and before[1] == y0 and before[0] > x0, before

        editor_palette("ov", "Switch to Overview", "silver-cancel")
        assert caret() != before, "the open palette did not take the terminal cursor"
        send(b"\x1b")
        see("cancelled", EDITOR_TAB, "Cobalt focus", dirty, absent=MODALS)
        assert caret() == before, (before, caret())

        # Cobalt also offers a native editor-workspace restore action. Exercise
        # Silver's explicit command rather than relying on an ambiguous "ed".
        editor_palette("Switch to Editor", "Silver: Switch to Editor", "silver-editor")
        send(b"\r")
        see("editor-ran", EDITOR_TAB, "Cobalt focus", dirty, absent=MODALS)
        assert caret() == before, (before, caret())

        # No F6, focus change or mouse click before running the Silver command.
        editor_palette("ov", "Switch to Overview", "silver-overview")
        send(b"\r")
        see("overview-ran", OVERVIEW_TAB, "Project: palette_project",
            absent=(*MODALS, "Cobalt focus", dirty))
        term.palette("ed")
        see("returned", EDITOR_TAB, "Cobalt focus", dirty, absent=MODALS)
        assert caret() == before, (before, caret())
        assert source.read_text() == original, "the transition saved the dirty buffer"

        send(b" gg")
        see("native-vcs-chord", EDITOR_TAB, "VCS: not a repository", absent=MODALS)
        send(b"q")
        see("native-vcs-returned", EDITOR_TAB, "Cobalt focus", dirty, absent=MODALS)

        send(b"\x03")
        deadline = time.monotonic() + 12
        while term.process.poll() is None:
            screen = term.drain(.15, allow_exit=True)
            assert time.monotonic() < deadline, f"Silver did not exit:\n{screen}"
        assert term.process.returncode == 0
        assert source.read_text() == original, "Silver saved the dirty buffer on exit"
    finally:
        term.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="silver-editor-palette-") as directory:
        exercise(Path(sys.argv[1]).resolve(), Path(directory))
