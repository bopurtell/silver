#!/usr/bin/env python3
"""Real FIFO discovery -> standalone Silver -> hosted Cobalt PTY.

Fixture mode uses prebuilt Silver and FIFO binaries with a private source copy
and deterministic LSP peer. --live uses the installed Silver, the example
checkout's normal composite config, and the caller's toolchain. It sends no edit
or launch keys. Both modes isolate Silver state and retain PTY evidence.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "test"))
sys.path.insert(0, str(HERE))
from support.terminal import Terminal
from fixtures.simulation_fixture_wire import parse, record, sexp
from fixtures.testing_layout import focus_pane

CASE = "seeded"
SUITE = "controlled-fifo"
DECLARATION_FILE = "ip/controlled_fifo/verif/simulation/test_provider.ml"
MARKER = "TEST_DECLARATION_DIRTY_"
SELECTED = re.compile(rf"(?m)(?:^|[│|]) *> +\[ \] {CASE}\b")
FOCUS_PANE = b"\x1b[17~"  # F6
ALT_LEFT = b"\x1b[1;3D"  # xterm Alt+Left
F7 = b"\x1b[18~"  # compatibility alias
CURSOR_VISIBILITY = re.compile(rb"\x1b\[\?25([hl])")
CURSOR_ADDRESS = re.compile(rb"\x1b\[(\d+);(\d+)H")


class Caret:
    """A visible Notty caret on an exact ASCII source line and display column."""
    def __init__(self, tty, source_line, column):
        assert source_line.isascii() and source_line.isprintable()
        assert 1 <= column <= len(source_line.rstrip())
        self.tty, self.source_line, self.column = tty, source_line.rstrip(), column
        self.actual, self.expected = None, []

    def search(self, text):
        # Notty hides the caret for repainting, then explicitly shows and
        # positions it. Use only the last visibility command, never a stale
        # cursor or the addresses used to draw the frame.
        self.actual = None
        last = None
        for last in CURSOR_VISIBILITY.finditer(self.tty.data):
            pass
        if last is not None and last.group(1) == b"h":
            address = CURSOR_ADDRESS.match(self.tty.data, last.end())
            if address:
                self.actual = tuple(map(int, address.groups()))
        self.expected = [
            (row, match.start() + self.column)
            for row, painted in enumerate(text.split("\n"), 1)
            for match in re.finditer(re.escape(self.source_line), painted)
        ]
        return self.expected == [self.actual]

    def __repr__(self):
        return (f"Caret(source column {self.column}, terminal candidates {self.expected}, "
                f"visible terminal caret {self.actual})")


class Tty(Terminal):
    def key(self, key):
        os.write(self.master, key)
        self.drain(.15)

    def click_workspace(self, name, label):
        # Use the normal workspace bar, not a palette action or fixed index.
        top = self.capture(f"{label}-bar", [workspace_tab(name)]).splitlines()[0]
        x = re.search(rf"\b{re.escape(name)}\b", top).start() + 1
        self.key(f"\x1b[<0;{x};1M".encode())
        self.key(f"\x1b[<0;{x};1m".encode())

    def check_startup(self):
        self.capture("startup-tabs", [workspace_tab("Overview", active=True),
                                      workspace_tab("Testing"), workspace_tab("Editor")])
        self.click_workspace("Editor", "open-editor-on-startup")
        self.accept("startup-editor-tab-is-usable",
                    [workspace_tab("Editor", active=True), "Cobalt focus"])
        self.key(ALT_LEFT)
        self.accept("startup-editor-back", [workspace_tab("Overview", active=True)], ["Cobalt focus"])
        self.click_workspace("Testing", "open-testing")
        self.capture("testing-workspace", [workspace_tab("Testing", active=True), "simulation-catalog"])

    def accept(self, label, expected=(), absent=()):
        self.capture(label, expected, absent)
        print("PASS:", label, flush=True)

    def caret(self, source_line, column):
        return Caret(self, source_line, column)

    def quit_silver(self):
        # Exercise the ordinary dashboard quit route after Back, rather than
        # bypassing it: the editor/return destination must yield input to Silver.
        os.write(self.master, b"q")
        self.capture("quit-confirmation", ["Quit Silver?", ">[Yes]", "[No]"])
        os.write(self.master, b"\r")
        deadline = time.monotonic() + 12
        while self.process.poll() is None:
            self.drain(.15, allow_exit=True)
            assert time.monotonic() < deadline, "Silver's confirmed quit did not work after Back"
        assert self.process.returncode == 0, self.process.returncode


def script(path, contents):
    path.write_text("#!/bin/sh\n" + contents, encoding="utf-8")
    path.chmod(0o700)


def workspace_tab(name, *, active=False):
    tab = rf"\d+ +{re.escape(name)}\b"
    if active:
        tab = rf"\[{tab} *\]"
    return re.compile(rf"\A[^\n]*{tab}")


def project(args):
    base = args.evidence
    root = base / "project"
    source = root / DECLARATION_FILE
    source.parent.mkdir(parents=True)
    # The real producer has a project-relative coordinate. Copy its exact
    # source at that path; do not mount or edit the live example checkout.
    shutil.copyfile(args.example / DECLARATION_FILE, source)
    (root / "dune-project").write_text("(lang dune 3.22)\n(name testing_declaration_pty)\n")

    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("DUNE_", "XDG_", "HARDCAML_WORKBENCH_", "SILVER_"))
           and k != "INSIDE_DUNE"}
    for key in ("HOME", "TMPDIR", "XDG_RUNTIME_DIR", "XDG_STATE_HOME",
                "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        path = base / key
        path.mkdir(mode=0o700)
        env[key] = str(path)
    env.update(LC_ALL="C.UTF-8", TEST_DECLARATION_LSP_LOG=str(base / "lsp.jsonl"))
    bin_dir = base / "bin"
    bin_dir.mkdir()
    script(bin_dir / "ocamllsp",
           "exec " + shlex.join([sys.executable, str(HERE / "fixtures/declaration_lsp.py")]) + "\n")
    env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]

    # The real provider owns all discovery data. Record every invocation and
    # reject unexpected operations before they can start the simulator.
    provider = [str(args.provider)]
    calls = base / "provider-calls.txt"
    wrapper = bin_dir / "provider"
    script(wrapper, f'printf "%s\\n" "$1" >> {shlex.quote(str(calls))}\n'
           '[ "$1" = discover ] || exit 64\n'
           f'exec {shlex.join(provider)} "$@"\n')
    config = [("schema_version", 1), ("provider_executable", str(wrapper)),
              ("provider_args", []), ("discovery_timeout_seconds", 10),
              ("run_timeout_seconds", 30)]
    (root / "silver-simulation.sexp").write_text(sexp(config), encoding="utf-8")
    return root, source, env, provider, calls


def discover(args, root, env, provider):
    reply = subprocess.run([*provider, "discover", "--protocol-version", "1"],
                           cwd=root, env=env, capture_output=True, timeout=20)
    (args.evidence / "discovery.sexp").write_bytes(reply.stdout)
    (args.evidence / "discovery-stderr.txt").write_bytes(reply.stderr)
    reply.check_returncode()
    discovery = record(parse(reply.stdout.decode()))
    captures = [d for entry in discovery.get("declarations", []) if
                (d := record(entry))["suite_id"] == SUITE and d["case_id"] == CASE]
    assert len(captures) == 1, f"Rebuild the declaration-producing FIFO provider: {captures}"
    loc = captures[0]
    assert loc["relative_path"] == DECLARATION_FILE, loc
    return int(loc["line"]), int(loc["column"])


def await_declaration(tty, source, line, column):
    """Require an actual Cobalt LSP declaration request at the opened location."""
    log = Path(tty.session.env["TEST_DECLARATION_LSP_LOG"])

    def messages():
        if not log.exists():
            return []
        text = log.read_text(encoding="utf-8")
        # Ignore a possibly incomplete record while the peer is writing it.
        return [json.loads(row) for row in text[:text.rfind("\n") + 1].splitlines()]

    uri = source.as_uri()
    deadline = time.monotonic() + 12
    while not any(m["method"] == "textDocument/didOpen"
                  and m["params"]["textDocument"]["uri"] == uri for m in messages()):
        tty.drain(.15)
        assert time.monotonic() < deadline, "Cobalt did not attach to the declaration document"
    tty.key(b"g")
    tty.key(b"d")
    tty.capture("cobalt-gd", ["No destinations found", source.name])
    requests = [m["params"] for m in messages() if m["method"] == "textDocument/declaration"]
    expected = {"textDocument": {"uri": uri},
                "position": {"line": line - 1, "character": column - 1}}
    assert requests == [expected], (requests, expected)
    print("PASS: cobalt gd reached the LSP peer at the declaration coordinates", flush=True)


def back(tty, label, *, key, expected):
    tty.capture(f"{label}-control", [workspace_tab("Editor", active=True), "Alt+Left"])
    tty.key(key)
    tty.accept(label, [workspace_tab("Testing", active=True), *expected],
               [MARKER, "Cobalt focus"])


def run(args):
    root, source, env, provider, calls = project(args)
    original = source.read_bytes()
    line, column = discover(args, root, env, provider)
    declaration = original.decode().splitlines()[line - 1]
    # In the producer fixture, case sites are ASCII. This makes display cells,
    # character offsets, and the LSP peer's UTF-16 offsets agree for this test.
    assert declaration.isascii() and 1 <= column <= len(declaration), (line, column)
    assert f'"{CASE}"' in declaration and declaration[column - 1:].startswith("[%here]"), (
        line, column, declaration)
    dirty = declaration[:column - 1] + MARKER + declaration[column - 1:]
    assert original.decode().splitlines().count(declaration) == 1, declaration

    # With Status hidden, the LSP result shares one compact row with the
    # absolute filename. Leave room for both and the Silver sibling pane.
    width = max(220, len(os.fsencode(source)) + 100)
    tty = Tty(SimpleNamespace(evidence=args.evidence, env=env),
              argv=[str(args.client), "--standalone", "--project-root", str(root),
                     "--diagnostics-file", str(args.evidence / "silver.log")],
              cwd=root, width=width, height=44)
    try:
        tty.check_startup()
        focus_pane(tty, "simulation-catalog")
        tty.capture("catalog", [f"Suite: {SUITE}", "Ready for explicit launch", CASE])
        tty.key(b"j")
        tty.key(b"x")  # non-default row and checked subset make a reset visible
        tty.accept("selected-seeded", [SELECTED, "Selected: 2 cases"])

        tty.key(b"g")
        tty.key(b"d")
        tty.accept("open-declaration", [workspace_tab("Editor", active=True),
                                       "Cobalt focus", source.name, declaration.strip(),
                                       tty.caret(declaration, column)])
        tty.key(FOCUS_PANE)
        tty.capture("silver-sibling-focus", ["Silver focus"])
        tty.key(b"k")
        tty.capture("silver-sibling-handles-navigation", [re.compile(r">\s+\[x\] directed\b")])
        tty.key(b"j")
        tty.capture("silver-sibling-restores-selection", [SELECTED])
        tty.key(b"iTEST_DECLARATION_WRONG_PANE\x1b")
        tty.key(FOCUS_PANE)
        tty.accept("focus-returns-to-unmodified-cobalt",
                   ["Cobalt focus", declaration.strip(), tty.caret(declaration, column)],
                   ["TEST_DECLARATION_WRONG_PANE", "INSERT"])
        await_declaration(tty, source, line, column)
        tty.key(b"i" + MARKER.encode() + b"\x1b")
        tty.accept("dirty-at-declaration", [dirty.strip()])
        assert source.read_bytes() == original, "typing into Cobalt must not write to disk"

        tty.key(b"0")  # distinguish tab resume from a declaration-position reset
        moved = tty.caret(dirty, 1)
        tty.capture("dirty-cursor-moved", [dirty.strip(), moved])
        expected = [SELECTED, "Selected: 2 cases"]
        back(tty, "alt-left-restores-same-selection", key=ALT_LEFT, expected=expected)
        tty.click_workspace("Editor", "return-by-tab")
        tty.accept("editor-tab-retains-dirty-buffer-and-cursor",
                   [workspace_tab("Editor", active=True), dirty.strip(), moved])
        back(tty, "f7-restores-same-selection", key=F7, expected=expected)
        # Do not refocus the catalog: this must work from the restored focus.
        tty.key(b"g")
        tty.key(b"d")
        tty.accept("repeat-retains-dirty-buffer",
                   [workspace_tab("Editor", active=True), source.name, dirty.strip(),
                     tty.caret(dirty, column)])
        tty.key(b"u")
        tty.accept("undo-history-retained", [declaration.strip()], [MARKER])
        tty.key(b"\x12")  # Cobalt Ctrl-R
        tty.accept("redo-history-retained", [dirty.strip()])

        back(tty, "second-alt-left-restores-same-selection", key=ALT_LEFT, expected=expected)
        tty.quit_silver()
        assert source.read_bytes() == original, "dirty edits persisted to disk"
        assert calls.read_text().splitlines() == ["discover"], "expected discovery only, no test run"
    finally:
        tty.close()


def run_live(args):
    """Open the real project by cwd and verify the configured composite route."""
    root = args.example
    source = root / DECLARATION_FILE
    config = root / ".silver" / "silver-simulation.sexp"
    original, config_bytes = source.read_bytes(), config.read_bytes()
    settings = record(parse(config_bytes.decode()))
    assert any(Path(arg).name == "checkout_provider.py" for arg in settings["provider_args"]), (
        f"Not the standard composite simulation config: {config}")
    targets = [text for text in original.decode().splitlines()
               if re.search(rf'\bcase \[%here\] "{CASE}"', text)]
    assert len(targets) == 1, targets
    declaration = targets[0]
    assert declaration.isascii()
    column = declaration.index("[%here]") + 1
    ready = "Ready for explicit launch"
    selected = re.compile(rf"(?m)(?:^|[│|]) *> +\[x\] {CASE}\b")

    # Keep HOME, PATH, config and provider environment intact. Only use a new
    # state tree so no running Silver session/history can supply a cached catalog.
    env = dict(os.environ, XDG_STATE_HOME=str(args.evidence / "state"))
    argv = [str(args.client), "--diagnostics-file", str(args.evidence / "silver.log")]
    if args.client.name != "ag":
        argv.append("--standalone")  # a source-built main.exe is not the installed entry point
    tty = Tty(SimpleNamespace(evidence=args.evidence, env=env),
              argv=argv,
              cwd=root, width=200, height=48)
    try:
        tty.check_startup()
        focus_pane(tty, "simulation-catalog")
        # Assert discovery really came through the composite, not just the FIFO
        # producer: the independent memory-workloads suite must also be present.
        outcome = re.compile(r"Ready for explicit launch|Discovery failed:", re.IGNORECASE)
        text = tty.capture("composite-discovery", [outcome], timeout=45)
        assert "Discovery failed:" not in text, (
            "Configured composite discovery failed; inspect composite-discovery.txt "
            "or run silver-simulation-setup check from the example root"
        )
        text = tty.capture("composite-catalog", [ready, "memory-workloads"])
        if f"Suite: {SUITE}" not in text:
            tty.key(b"p")  # the other suite is memory-workloads
        tty.capture("fifo-catalog", [f"Suite: {SUITE}", CASE])
        tty.key(b"j")
        tty.accept("real-project-seeded-selected", [selected])

        expected = [f"Suite: {SUITE}", selected]

        def jump(label):
            tty.key(b"g")
            tty.key(b"d")
            tty.accept(label,
                       [workspace_tab("Editor", active=True), "Cobalt focus",
                         DECLARATION_FILE, declaration.strip(), tty.caret(declaration, column)])

        jump("real-project-declaration")
        tty.key(b"l")  # cursor movement only, never edit the real checkout
        moved = tty.caret(declaration, column + 1)
        tty.capture("real-project-cursor-moved", [moved])
        back(tty, "real-project-alt-left", key=ALT_LEFT, expected=expected)
        tty.click_workspace("Editor", "real-project-return-by-tab")
        tty.accept("real-project-editor-tab-retains-cursor",
                   [workspace_tab("Editor", active=True), moved, declaration.strip()])
        back(tty, "real-project-f7", key=F7, expected=expected)
        jump("real-project-repeat-declaration")
        back(tty, "real-project-repeat-alt-left", key=ALT_LEFT, expected=expected)
        # Back above returns to Testing. This time, navigate to a *different*
        # workspace via Silver's alias without first relinquishing Cobalt focus.
        tty.click_workspace("Editor", "real-project-return-for-command")
        tty.capture("real-project-before-command", ["Cobalt focus", tty.caret(declaration, column)])
        for key in (b" ", b"c", b"c", b"ov", b"\r"):
            tty.key(key)
        tty.accept("real-project-editor-command-ov", [workspace_tab("Overview", active=True)])
        for key in (b" ", b"c", b"c", b"ed", b"\r"):
            tty.key(key)
        tty.accept("real-project-overview-command-ed",
                   [workspace_tab("Editor", active=True), "Cobalt focus", tty.caret(declaration, column)])
        tty.key(ALT_LEFT)
        tty.accept("real-project-ed-back", [workspace_tab("Overview", active=True)])
        # Navigate the actual stock strip, including the Editor with the file
        # still open. Merely displaying that buffer must not give it input.
        focus_pane(tty, "workspace-tabs")
        for name, key in (("Testing", b"j"), ("Waveforms", b"j"), ("Timing", b"j"),
                          ("Resources", b"j"), ("Editor", b"j"), ("Resources", b"k"),
                          ("Editor", b"j")):
            tty.key(key)
            tty.capture("real-project-strip-" + name, [workspace_tab(name, active=True)],
                        absent=["Cobalt focus"])
        tty.key(b"\r")
        tty.accept("real-project-enter-from-strip",
                   ["Cobalt focus", tty.caret(declaration, column)])
        tty.key(ALT_LEFT)
        tty.quit_silver()
    finally:
        tty.close()
        assert source.read_bytes() == original, "real declaration source changed"
        assert config.read_bytes() == config_bytes, "real simulation config changed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="probe the actual configured example; no edits or launches")
    parser.add_argument("--client", type=Path, help="Silver executable (default for --live: ~/.local/bin/ag)")
    parser.add_argument("--provider", type=Path,
                        help="prebuilt controlled FIFO test_provider.exe (no simulator needed)")
    parser.add_argument("--example", type=Path, default=HERE.parents[1] / "hardcaml_asic_example",
                        help="actual example checkout, or source for the fixture mode")
    parser.add_argument("--evidence", type=Path, help="new directory for all private state and evidence")
    args = parser.parse_args()
    if args.live:
        if args.provider:
            parser.error("--live uses the project's configured provider, not --provider")
        args.client = args.client or Path.home() / ".local/bin/ag"
    elif not (args.provider and args.client):
        parser.error("fixture mode requires --provider and --client")
    # Keep argv[0] as supplied for ag, including Dune's install-tree symlink.
    # In live mode this basename determines whether to exercise bare discovery.
    args.client.resolve(strict=True)
    args.client = args.client.absolute()
    for name in ("provider", "example"):
        if value := getattr(args, name):
            setattr(args, name, value.resolve(strict=True))
    os.umask(0o077)
    if args.evidence is None:
        scratch = Path("/tmp/opencode")
        args.evidence = Path(tempfile.mkdtemp(prefix="silver-testing-declaration-",
                                              dir=scratch if scratch.is_dir() else None)).resolve()
    else:
        args.evidence = args.evidence.resolve()
        args.evidence.mkdir()
    print("Evidence:", args.evidence, flush=True)
    if args.live:
        run_live(args)
        print("PASS: real composite Testing -> exact declaration -> Back -> repeat; no edit or launch")
    else:
        run(args)
        print("PASS: Testing -> Cobalt declaration -> dirty edit -> Back -> repeat; no test ran")


if __name__ == "__main__":
    main()
