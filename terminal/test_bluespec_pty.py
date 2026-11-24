"""Opt-in PTY smoke: python3 terminal/test_bluespec_pty.py [--silver PATH].

Requires the installed Silver launcher and the real Bluespec starter toolchain
(Bazel, BSC, Verilator, Rust, make, and a C++ compiler). No external daemon
or direct API calls.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "test"), str(ROOT / "scripts" / "fixtures")]
from support.terminal import Terminal
from testing_layout import artifact_row, case_row, focus_pane


class KeyboardTerminal(Terminal):
    def key(self, data):
        os.write(self.master, data)


def exercise(silver, base, run_timeout):
    project = base / "classic-counter"
    project.mkdir()
    env = dict(os.environ, XDG_CONFIG_HOME=str(base / "config"),
               XDG_CACHE_HOME=str(base / "cache"), XDG_STATE_HOME=str(base / "state"),
               XDG_RUNTIME_DIR=str(base / "runtime"))
    # Keep HOME and PATH: the real BSC wrapper may locate its install via HOME.
    init = subprocess.run([silver, "init", "--bluespec"], cwd=project, env=env,
                          capture_output=True, text=True, timeout=30)
    output = init.stdout + init.stderr
    (base / "init.txt").write_text(output)
    assert init.returncode == 0, f"{silver} init --bluespec failed:\n{output}"
    name = json.loads((project / ".silver" / "project.json").read_text())["name"]
    source = project / "Counter.bs"
    original = source.read_bytes()
    nested = project / "scratch" / "nested"
    nested.mkdir(parents=True)

    session = SimpleNamespace(env=env, evidence=base)
    # Bare installed silver from a child directory: no --project-root, no
    # --connect, and no substitute launcher or fake toolchain.
    with closing(KeyboardTerminal(session, argv=[silver], cwd=nested,
                                  width=200, height=50)) as term:
        overview = re.compile(r"\A[^\n]*\[\d+ Overview\]")
        testing = re.compile(r"\A[^\n]*\[\d+ Testing\]")
        term.capture("discovered", [overview, "Project: " + name], absent=["Unbound workspace"])

        term.palette("Open project file")
        term.capture("open-prompt", ["path[:line[:column]]"])
        term.key(b"Counter.bs:1\r")
        source_line = "package Counter (Counter(..), mkCounter) where"
        term.capture("bluespec-editor", ["Cobalt focus", "Counter.bs", source_line])
        term.key(b"i-- PTY smoke edit\x1b")
        term.capture("edited-buffer", ["Cobalt focus", "-- PTY smoke edit" + source_line])
        term.key(b"u")
        term.capture("undone-edit", ["Cobalt focus", source_line], absent=["PTY smoke edit"])
        assert source.read_bytes() == original
        term.key(b"\x1b[18~")  # F7 Back
        term.capture("back-to-overview", [overview], absent=["Cobalt focus"])

        suite = "bluespec-classic"
        case = "counter-smoke"
        term.palette("Switch to Testing")
        term.capture("catalog-discovered", [testing, "simulation-catalog", suite], timeout=30)
        term.palette("Testing: Browse/select test suites")
        term.capture("suite-picker", ["COMMAND PALETTE", f"{suite} — Bluespec Classic"])
        term.key(suite.encode() + b"\r")
        term.capture("catalog-ready", [f"Suite: {suite}", f"[x] {case}", "Ready for explicit launch"],
                     absent=["COMMAND PALETTE"])
        focus_pane(term, "simulation-catalog")
        term.key(b"R")
        vcd = artifact_row("Counter waveform", case, "Available")
        term.capture("verification-passed", [testing, "Finished/Passed", case_row(case, "Passed"), vcd],
                     timeout=run_timeout)

        focus_pane(term, "simulation-cases")
        term.palette("Simulation: Select case " + case)
        term.capture("passed-case-selected", [case_row(case, "Passed", selected=True), vcd],
                     absent=["COMMAND PALETTE"])
        focus_pane(term, "simulation-artifacts")
        term.key(b"w")
        term.capture("counter-waveform", [re.compile(r"Cursor \d+ ticks"), re.compile(r"\bCLK\b")])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--silver", default="silver", help="installed silver launcher (default: PATH)")
    parser.add_argument("--evidence", type=Path, help="new directory to retain project and PTY captures")
    parser.add_argument("--run-timeout", type=int, default=180, help="seconds to wait for verification")
    args = parser.parse_args()
    silver = shutil.which(args.silver)
    if silver is None:
        parser.error(f"installed launcher not found: {args.silver}")
    silver = Path(silver).absolute()  # Preserve the launcher basename, even if a symlink.
    if args.run_timeout < 1:
        parser.error("--run-timeout must be positive")
    if args.evidence:
        base = args.evidence.resolve()
        base.mkdir(mode=0o700)
        print(f"Evidence: {base}", flush=True)
        exercise(silver, base, args.run_timeout)
    else:
        scratch = Path("/tmp/opencode")
        with tempfile.TemporaryDirectory(prefix="silver-bluespec-pty-",
                                         dir=scratch if scratch.is_dir() else None) as directory:
            exercise(silver, Path(directory), args.run_timeout)
    print("Silver Bluespec PTY smoke passed: discovery, editor, verification, and counter waveform.")


if __name__ == "__main__":
    main()
