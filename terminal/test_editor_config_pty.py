"""Exercise user-owned editor config and project-isolated presentation in Silver."""
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from contextlib import closing
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


DARK = (25, 29, 34)
LIGHT = (245, 247, 249)
ABYSS = (8, 18, 28)
PROBLEMS = re.compile(r"\bProblems \(")


def exercise(client, base):
    config_root = base / "config"
    config = config_root / "silver" / "editor.sexp"
    state = base / "state"
    env = dict(os.environ, HOME=str(base / "home"), XDG_CONFIG_HOME=str(config_root),
               XDG_STATE_HOME=str(state), XDG_RUNTIME_DIR=str(base / "runtime"))
    launcher = base / "ag"
    launcher.symlink_to(client)
    alpha, beta = (base / name for name in ("alpha", "beta"))
    for root in (alpha, beta):
        root.mkdir()
        (root / "dune-project").write_text(f"(lang dune 3.22)\n(name {root.name})\n")
        (root / "draft.txt").write_text(f"opening line\nEDITOR_CONFIG_{root.name}\n")
        # An invalid project-local file must not affect the user's editor.
        (root / "editor.sexp").write_text("this isn't valid")
    (config_root / "cobalt").mkdir(parents=True)
    (config_root / "cobalt" / "config.ml").write_text("this isn't valid either")

    def launch(label, root=alpha, *, env=env):
        evidence = base / label
        evidence.mkdir()
        return closing(Terminal(SimpleNamespace(env=env, evidence=evidence),
                                argv=[launcher, "--project-root", root], cwd=root))

    def send(term, data):
        os.write(term.master, data)

    def enter_editor(term):
        term.palette("Open project file")
        term.capture("open-file", ["path[:line[:column]]"])
        send(term, b"draft.txt\r")

    def source_background(term, root):
        # Cobalt paints the non-current source line as a colored run. Read its latest
        # style, not a previous frame or a Silver palette swatch.
        marker = f"EDITOR_CONFIG_{root.name}".encode()
        background, last = None, None
        for match in re.finditer(rb"\x1b\[([\d;]*)m|" + marker, term.data):
            if match.group(1) is None:
                last = background
                continue
            fields = [int(n or 0) for n in match.group(1).split(b";")]
            while fields:
                op, *fields = fields
                if op in (38, 48) and fields[:1] == [2]:
                    if op == 48:
                        background = tuple(fields[1:4])
                    fields = fields[4:]
                elif op in (0, 49):
                    background = None
        assert last is not None, f"No source-background ANSI style before {marker!r}"
        return last

    def editor(term, root, background, *, problems, footer="Cobalt focus"):
        marker = f"EDITOR_CONFIG_{root.name}"
        expected = [marker, footer, "Project: " + root.name]
        if problems:
            expected.append(PROBLEMS)
        screen = term.capture(f"editor-{root.name}-{problems}", expected,
                              absent=[] if problems else [PROBLEMS])
        if problems:
            rows = screen.splitlines()
            source_row = next(i for i, row in enumerate(rows) if marker in row)
            problems_row = next(i for i, row in enumerate(rows) if PROBLEMS.search(row))
            assert source_row < problems_row
        assert source_background(term, root) == background

    def overview(term, root, *, leave=True):
        if leave:
            send(term, b"\x1b[18~")  # F7 recalls the Silver workspace.
        term.capture("overview", ["Overview", "Project: " + root.name], absent=["Cobalt focus"])

    def overview_background(term, root):
        colors = re.findall(rb"\x1b\[(?:\d+;)*48;2;(\d+;\d+;\d+)mProject: "
                            rb"(?:\x1b\[[\d;]*m)*"
                            + root.name.encode(), term.data)
        assert colors, f"No dashboard background for {root.name}"
        return tuple(map(int, colors[-1].split(b";")))

    def choose_theme(term, key):
        term.palette("theme")
        term.capture("theme-picker", ["Choose theme"])
        send(term, key.encode())
        term.capture("filtered-theme", ["> " + key])
        send(term, b"\r")
        term.capture("applied-theme", ["Overview"], absent=["Choose theme"])

    def check_live_preview(term):
        # Yield input to Silver without leaving the mounted editor. The
        # command palette can preview while the source is still visible.
        send(term, b"\x1b[17~")  # F6
        term.palette("theme")
        term.capture("editor-theme-picker", ["Choose theme"])
        send(term, b"silver-light")
        term.capture("editor-theme-preview", ["> silver-light", "EDITOR_CONFIG_alpha"])
        assert source_background(term, alpha) == LIGHT
        send(term, b"\x1b")
        term.capture("editor-theme-cancel", ["EDITOR_CONFIG_alpha"], absent=["Choose theme"])
        assert source_background(term, alpha) == DARK
        send(term, b"\x1b[17~")
        term.capture("editor-focus-restored", ["Cobalt focus"])

    def quit_client(term):
        send(term, b"\x03")
        deadline = time.monotonic() + 12
        while term.process.poll() is None:
            screen = term.drain(.15, allow_exit=True)
            assert time.monotonic() < deadline, f"Silver did not exit:\n{screen}"
        assert term.process.returncode == 0

    def switch_project(term, root):
        term.palette("Open Project…")
        term.capture("project-picker", ["Existing project directory"])
        send(term, str(root).encode() + b"\r")
        overview(term, root, leave=False)

    with launch("generated") as term:
        overview(term, alpha, leave=False)
        assert not config.exists(), "config must not be created before local editor use"
        enter_editor(term)
        editor(term, alpha, DARK, problems=True)
        default = config.read_text()
        assert "(layout ((views ((Problems Band)))))" in default
        assert "(theme inherit)" in default
        assert "History" not in default and "status" not in default
        check_live_preview(term)

        # The edit changes neither this mount nor new mounts in this Silver
        # process. Runtime geometry keys are local to this mount.
        custom = "((layout ((views ()))) (theme abyss))\n"
        config.write_text(custom)
        send(term, b" vb")  # Toggle only this editor's Problems view.
        editor(term, alpha, DARK, problems=False)
        overview(term, alpha)
        choose_theme(term, "silver-light")
        enter_editor(term)
        editor(term, alpha, LIGHT, problems=False)

        overview(term, alpha)
        switch_project(term, beta)
        enter_editor(term)
        editor(term, beta, DARK, problems=True)
        overview(term, beta)
        switch_project(term, alpha)
        enter_editor(term)
        editor(term, alpha, LIGHT, problems=False)
        assert config.read_text() == custom
        quit_client(term)

    with launch("custom-after-restart") as term:
        overview(term, alpha, leave=False)
        assert overview_background(term, alpha) == LIGHT
        enter_editor(term)
        editor(term, alpha, ABYSS, problems=False)
        overview(term, alpha)
        choose_theme(term, "silver-dark")
        assert overview_background(term, alpha) == DARK
        enter_editor(term)
        editor(term, alpha, ABYSS, problems=False)
        assert config.read_text() == custom
        quit_client(term)

    # A bad file at the HOME fallback must not disable editing or get overwritten;
    # a relative XDG_CONFIG_HOME must not be resolved inside the project.
    bad = "((layout ((views ((Problems Nonexistent))))))\n"
    fallback = Path(env["HOME"]) / ".config" / "silver" / "editor.sexp"
    fallback.parent.mkdir(parents=True)
    fallback.write_text(bad)
    with launch("invalid-defaults", env=dict(env, XDG_CONFIG_HOME="relative-config")) as term:
        overview(term, alpha, leave=False)
        enter_editor(term)
        editor(term, alpha, DARK, problems=True, footer="Using default Editor configuration")
        # The notice takes over the focus hint. Verify actual input routing
        # without relying on what the footer shows after the notice.
        send(term, b"iFOCUS_CHECK_\x1b")
        term.capture("invalid-config-editor-receives-keys", ["FOCUS_CHECK_opening line"])
        assert (alpha / "draft.txt").read_text() == "opening line\nEDITOR_CONFIG_alpha\n"
        assert fallback.read_text() == bad and config.read_text() == custom
        assert not (alpha / "relative-config" / "silver" / "editor.sexp").exists()
        quit_client(term)


if __name__ == "__main__":
    client = Path(sys.argv[1]).resolve()
    if len(sys.argv) > 2:
        base = Path(sys.argv[2]).resolve()
        base.mkdir()
        exercise(client, base)
    else:
        with tempfile.TemporaryDirectory(prefix="silver-editor-config-") as directory:
            exercise(client, Path(directory))
