"""Exercise the installed launcher's argv[0] behavior and real project handoff."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import pty
import shlex
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


def exercise(client, base, real_renderer=None):
    silver = base / "silver"
    silver.symlink_to(client)
    start = base / "start"
    start.mkdir()
    state = base / "state"
    tools = base / "bin"
    tools.mkdir()
    # The external provider is deterministic; Silver itself performs all
    # validation, file creation and project opening via the production paths.
    renderer = tools / "hardcaml-asic-starter"
    if real_renderer:
        renderer.symlink_to(real_renderer)
    else:
        fixture = Path(__file__).resolve().with_name("ip_starter_fixture.py")
        renderer.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} -B "
                            f"{shlex.quote(str(fixture))} \"$@\"\n")
        renderer.chmod(0o755)
    descriptor = json.loads(subprocess.check_output([renderer, "render", "--name", "demo"]))
    files = descriptor["files"]
    eda = base / "eda-invoked"
    for name in ("yosys", "openroad", "librelane", "verilator", "iverilog"):
        tool = tools / name
        tool.write_text(f"#!/bin/sh\necho {name} >> '{eda}'\nexit 1\n")
        tool.chmod(0o755)
    runtime = base / "runtime"
    env = dict(os.environ, XDG_STATE_HOME=str(state), XDG_RUNTIME_DIR=str(runtime),
               PATH=str(tools) + ":" + os.environ["PATH"])
    session = SimpleNamespace(env=env, evidence=base)

    @contextlib.contextmanager
    def launch(*flags, cwd=start, program=silver):
        term = Terminal(session, argv=[str(program), *flags], cwd=cwd)
        try:
            yield term
        finally:
            term.close()

    def send(term, data):
        os.write(term.master, data.encode())

    def see(term, text, timeout=15):
        deadline = time.monotonic() + timeout
        while text.encode() not in term.data:
            term.drain(.1, allow_exit=True)
            if text.encode() not in term.data and (
                    term.process.poll() is not None or time.monotonic() > deadline):
                raise AssertionError(f"missing {text!r}: {bytes(term.data[-2500:])!r}")

    unbound = "Unbound workspace"
    choices = ["Create project here", "Open existing project"]

    def menu(term):
        term.capture("entry-modal", [unbound, *choices])

    def dismiss(term, *fields):
        send(term, "\x1b")
        term.capture("entry-dismissed", [unbound], absent=[*choices, *fields])

    def form(term, destination="", name="demo"):
        menu(term)
        send(term, "c")
        term.capture("name", ["Project name"])
        send(term, name + "\r")
        term.capture("destination", ["Destination"])
        send(term, destination + "\r")

    def preview(term, root, destination=""):
        form(term, destination)
        term.capture("preview", ["Create preview", "Recipe: hardcaml-asic-starter-v1",
                                 f"Provider: {descriptor['provider']} {descriptor['version']}",
                                 "Name: demo", "Destination: ", (root / destination).name,
                                 "First registered chip target (default): demo",
                                 "Enter: Apply and open", "New files:", "asic_demo/project.ml"])

    def dashboard(term, name):
        term.capture("opened", ["Overview", "Project: " + name], absent=[unbound])

    def untouched():
        assert list(start.iterdir()) == [] and not state.exists()

    # Match the current rendered screen; the launch dialog is transient and
    # its bytes (and stale preview details) remain in the PTY transcript.
    with launch() as term:
        menu(term)
        dismiss(term)
        untouched()
        send(term, "p")
        menu(term)
        send(term, "c")
        term.capture("edit-name", ["Project name"])
        send(term, "unfinished")
        term.capture("partial-name", ["unfinished"])
        dismiss(term, "Project name", "unfinished")
        untouched()
        send(term, "p")
        preview(term, start, "cancel-me")
        untouched()
        dismiss(term, "Create preview", "dune-project")
        untouched()
        send(term, "p")
        menu(term)
        dismiss(term)
        send(term, "q")
        assert term.process.wait(timeout=5) == 0
    untouched()

    # Redirecting either side alone disables the modal, as do CLI-only flags.
    master, slave = pty.openpty()
    try:
        for stdin, stdout in [(slave, subprocess.PIPE), (subprocess.DEVNULL, slave)]:
            result = subprocess.run([silver], cwd=start, env=env, stdin=stdin, stdout=stdout,
                                    stderr=subprocess.PIPE, timeout=5)
            assert result.returncode and b"no Dune project found" in result.stderr
    finally:
        os.close(slave)
        os.close(master)
    for flag in ("--plain", "--api", "--wait"):
        with launch(flag) as term:
            see(term, "no Dune project found")
            assert term.process.wait(timeout=5) != 0 and unbound.encode() not in term.data
    untouched()

    # Bare silver-client still takes the daemon-attach path. Hold the private
    # lock so the test neither needs nor auto-spawns a shared user daemon.
    assert not runtime.exists()
    lock_dir = runtime / "hardcaml-workbench"
    lock_dir.mkdir(parents=True)
    with (lock_dir / "lifetime.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        generic = base / "silver-client"
        generic.symlink_to(client)
        with launch(program=generic) as term:
            see(term, "default daemon holds its lifetime lock")
            assert term.process.wait(timeout=5) != 0 and unbound.encode() not in term.data
    untouched()

    if os.geteuid() != 0:
        locked = base / "locked"
        locked.mkdir()
        marker = start / "dune-project"
        marker.symlink_to(locked / "hidden")
        locked.chmod(0o600)
        try:
            with launch() as term:
                see(term, "Permission denied")
                assert term.process.wait(timeout=5) != 0 and unbound.encode() not in term.data
        finally:
            locked.chmod(0o700)
            marker.unlink()

    with launch() as term:
        form(term, str(base))
        term.capture("denied", ["Destination_denied"])
        send(term, "\r")
        form(term, name="BadName")
        term.capture("bad-name", ["Invalid_operation"])
        dismiss(term, "Invalid_operation")
    untouched()

    # A stale apply cannot overwrite the intervening owner's file.
    with launch() as term:
        preview(term, start, "new")
        (start / "new").mkdir()
        owned = start / "new/dune-project"
        owned.write_text("owner")
        send(term, "\r")
        term.capture("stale", ["Stale_preview"])
        dismiss(term, "Stale_preview")
        assert list(owned.parent.iterdir()) == [owned] and owned.read_text() == "owner"
        owned.unlink()
        owned.parent.rmdir()
    untouched()

    existing = base / "existing"
    nested = existing / "nested"
    source = nested / "src"
    source.mkdir(parents=True)
    for root in (existing, nested):
        (root / "dune-project").write_text("(lang dune 3.10)\n")
    with launch(cwd=source) as term:
        see(term, "discovered project root " + str(nested) + " ")
        dashboard(term, nested.name)
        assert unbound.encode() not in term.data
    with launch() as term:
        menu(term)
        send(term, "o")
        term.capture("open", ["Existing project directory"])
        send(term, ".\r")
        term.capture("open-error", ["must directly contain"])
        dismiss(term, "must directly contain")
        send(term, "p")
        menu(term)
        send(term, "o")
        term.capture("open-again", ["Existing project directory"])
        send(term, str(existing) + "\r")
        dashboard(term, existing.name)
    assert not list(start.iterdir())
    assert (existing / "dune-project").read_text() == "(lang dune 3.10)\n"

    for destination in ("new", "already-empty", ""):
        work = base / ("create-" + (destination or "here"))
        work.mkdir()
        target = work / destination
        if destination == "already-empty":
            target.mkdir()
        initial = set(work.iterdir())
        with launch(cwd=work) as term:
            preview(term, work, destination)
            assert set(work.iterdir()) == initial
            if target.exists():
                assert not list(target.iterdir())
            send(term, "\r")
            dashboard(term, "demo")
            if destination == "new":
                # Keep A's hand edit and its default while appending B in this same session.
                first = target / "asic_demo/chip.ml"
                first.write_bytes(first.read_bytes() + b"\n(* user-owned edit *)\n")
                original = first.read_bytes()
                term.palette("New Chip Target")
                term.capture("source", ["From IP library", "From example/template"])
                send(term, "example\r")
                term.capture("chip-name", ["enter target name", "20 ns", "Tiny Tapeout"])
                send(term, "second\r")
                term.capture("chip-preview", ["registration: on", "Enter applies", "r toggles"])
                assert not (target / "asic_second").exists()
                send(term, "\r")
                term.capture("chip-added", ["Chip target created", "Registered:", "Select new chip target"])
                assert first.read_bytes() == original
                if real_renderer:
                    build_env = {k: v for k, v in env.items()
                                 if k != "INSIDE_DUNE" and not k.startswith("DUNE_")}
                    subprocess.run(["dune", "build", "asic_demo/project.exe", "asic_second/project.exe"],
                                   check=True, cwd=target, env=build_env, timeout=180)
                    send(term, "s")
                    term.capture("selected", ["Selected launch target: second / default"], timeout=45)
                send(term, "\r")
                dashboard(term, "demo")
        for file in files:
            suffix = "\n(* user-owned edit *)\n" if destination == "new" and file["path"] == "asic_demo/chip.ml" else ""
            assert (target / file["path"]).read_text() == file["contents"] + suffix
        catalog = json.loads((target / "hardcaml-asic-targets.json").read_text())
        assert catalog["default_target"] == "demo"
        assert [entry["id"] for entry in catalog["targets"]] == (
            ["demo", "second"] if destination == "new" else ["demo"])
    assert not eda.exists(), eda.read_text() if eda.exists() else ""


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="silver-entry-") as tmp:
        exercise(Path(sys.argv[1]).resolve(), Path(tmp),
                 Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None)
    print("Silver launcher entry, discovery, preview/cancel/apply and project handoff passed.")
