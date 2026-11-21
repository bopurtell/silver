"""Exercise live theme preview and persistence through the native terminal."""
import argparse
from contextlib import closing
import os
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


PICKER = "Choose theme"
DARK = "Silver Dark"
LIGHT = "Silver Light"
ACTIVE = " [active]"
NO_MATCHES = "No matching themes"
PROJECT_BACKGROUND = re.compile(rb"\x1b\[(?:\d+;)*48;2;(\d+;\d+;\d+)mProject: ")


def send(term, key):
    os.write(term.master, key)


def background(term):
    # The project header at the top of Overview is outside the picker. Check its
    # latest truecolor background, rather than matching any swatch in the picker
    # or a color from an older frame of the ANSI transcript.
    colors = PROJECT_BACKGROUND.findall(term.data)
    assert colors, "No truecolor background on the dashboard project label"
    return tuple(map(int, colors[-1].split(b";")))


def open_picker(term, active):
    term.palette("theme")
    inactive = LIGHT if active == DARK else DARK
    term.capture("theme-picker", [PICKER, "> ▏", f"> {active}{ACTIVE}", inactive, "[Apply]"],
                 absent=["COMMAND PALETTE", inactive + ACTIVE])


def filter_theme(term, theme):
    key = theme.lower().replace(" ", "-")
    send(term, key.encode())
    other = LIGHT if theme == DARK else DARK
    term.capture(f"filtered-{key}", [PICKER, f"> {key}▏", f"> {theme}", "[Apply]"],
                 absent=[other, theme + ACTIVE])


def exercise(client, base):
    project, state = base / "project", base / "state"
    project.mkdir()
    (project / "dune-project").write_text("(lang dune 3.10)\n(name theme_test)\n")
    env = dict(os.environ, HOME=str(base / "home"), XDG_STATE_HOME=str(state),
               XDG_CONFIG_HOME=str(base / "config"), XDG_RUNTIME_DIR=str(base / "runtime"))
    preferences = state / "hardcaml-workbench" / "terminal"

    def launch(evidence):
        evidence.mkdir()
        return closing(Terminal(
            SimpleNamespace(env=env, evidence=evidence),
            argv=[str(client), "--standalone", "--project-root", str(project)],
            cwd=project))

    def saved_preferences():
        return {p.name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns)
                for p in preferences.glob("presentation-*.sexp")}

    def quit_client(term):
        send(term, b"q")
        assert term.process.wait(timeout=5) == 0

    with launch(base / "first") as term:
        term.capture("startup", ["Overview", "Connection: connected", "Project: theme_test"])
        dark_background = background(term)
        assert max(dark_background) < 128, dark_background
        untouched = saved_preferences()

        open_picker(term, DARK)
        filter_theme(term, LIGHT)
        light_background = background(term)
        assert min(light_background) > 128, "Silver Light did not preview on the dashboard"
        assert saved_preferences() == untouched, "Preview changed presentation preferences"
        send(term, b"\x1b")
        term.capture("preview-cancelled", ["Overview"], absent=[PICKER])
        assert background(term) == dark_background, "Escape did not restore Silver Dark"
        assert saved_preferences() == untouched, "Escape changed presentation preferences"

        open_picker(term, DARK)
        filter_theme(term, LIGHT)
        send(term, b"\r")
        term.capture("preview-applied", ["Overview"], absent=[PICKER])
        assert background(term) == light_background, "Enter did not retain Silver Light"
        deadline = time.monotonic() + 5
        while True:
            saved = saved_preferences()
            if saved != untouched:
                break
            assert time.monotonic() < deadline, "Enter did not save presentation preferences"
            term.drain(.1)
        (contents, _, _), = saved.values()
        assert b"(scheme silver-light)" in contents, contents
        quit_client(term)

    with launch(base / "restart") as term:
        term.capture("restart", ["Overview", "Connection: connected", "Project: theme_test"])
        assert background(term) == light_background, "Restart did not load Silver Light"
        open_picker(term, LIGHT)

        # Drop the previewed row from the result set. Enter must not apply that
        # row (or even close the picker) after it ceases to be a match.
        filter_theme(term, DARK)
        assert background(term) == dark_background
        send(term, b"~no-match")
        term.capture("no-matches", [PICKER, "> silver-dark~no-match▏", NO_MATCHES],
                     absent=[DARK, LIGHT, "[Apply]"])
        assert background(term) == dark_background, "Empty results changed the preview"
        send(term, b"\r")
        # Wait for an edit after Enter, proving the picker stayed open and no
        # stale highlighted theme was applied.
        send(term, b"z")
        term.capture("no-matches-after-enter", [PICKER, "> silver-dark~no-matchz▏", NO_MATCHES],
                     absent=[DARK, LIGHT, "[Apply]"])
        assert background(term) == dark_background, "Enter on empty results changed the preview"
        assert saved_preferences() == saved, "Enter on empty results wrote preferences"
        send(term, b"\x1b")
        term.capture("no-matches-cancelled", ["Overview"], absent=[PICKER])
        assert background(term) == light_background, "Escape did not restore saved Silver Light"
        quit_client(term)
    assert saved_preferences() == saved, "Restart or inert picker rewrote preferences"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("client", type=lambda p: Path(p).resolve())
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence:
        args.evidence.mkdir()
        exercise(args.client, args.evidence.resolve())
    else:
        with TemporaryDirectory(prefix="theme-picker-") as tmp:
            exercise(args.client, Path(tmp))
