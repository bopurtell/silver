"""Exercise Silver's argv[0] launcher and the Hardcaml and Bluespec project wizard."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import pty
import re
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
    env = dict(os.environ, XDG_CONFIG_HOME=str(base / "config"), XDG_STATE_HOME=str(state),
               XDG_RUNTIME_DIR=str(runtime),
               PATH=str(tools) + ":" + os.environ["PATH"])
    session = SimpleNamespace(env=env, evidence=base)

    @contextlib.contextmanager
    def launch(*flags, cwd=start, program=silver, width=120, height=40):
        term = Terminal(session, argv=[str(program), *flags], cwd=cwd, width=width, height=height)
        try:
            yield term
        finally:
            term.close()

    def send(term, data):
        os.write(term.master, data.encode())

    def point(term, label, button=0, release_only=False):
        screen = term.capture("pointer-target", [label])
        y, row = next((i, row) for i, row in enumerate(screen.splitlines(), 1) if label in row)
        report = f"\x1b[<{button};{row.index(label) + 1};{y}"
        if not release_only:
            send(term, report + "M")
        if button in (0, 2):
            send(term, report + "m")

    def see(term, text, timeout=15):
        deadline = time.monotonic() + timeout
        while text.encode() not in term.data:
            term.drain(.1, allow_exit=True)
            if text.encode() not in term.data and (
                    term.process.poll() is not None or time.monotonic() > deadline):
                raise AssertionError(f"missing {text!r}: {bytes(term.data[-2500:])!r}")

    unbound = "Unbound workspace"
    choices = ["Create project here", "Open existing project"]
    preset = "Choose a preset"
    hardcaml = "Hardcaml · Dune · OCaml"
    bluespec = "Bluespec Classic · Bazel · Rust"

    def menu(term):
        term.capture("entry-modal", [unbound, *choices])

    def presets(term):
        term.capture("preset-picker", [preset, hardcaml, bluespec])

    def new_project(term):
        menu(term)
        send(term, "c")
        presets(term)

    def dismiss(term, *fields):
        send(term, "\x1b")
        term.capture("entry-dismissed", [unbound, "No project is open."], absent=[*choices, *fields])

    def form(term, destination="", name="demo"):
        new_project(term)
        send(term, "\r")  # Hardcaml is the keyboard default.
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

    def classic_scaffold(root):
        manifest = json.loads((root / ".silver/project.json").read_text())
        assert manifest == dict(schema_version=1, name=root.name,
                                build_label="//:rtl", test_label="//:simulation")
        assert "package Counter" in (root / "Counter.bs").read_text()
        for relative in ("BUILD.bazel", "MODULE.bazel", "simulation_provider.py",
                         ".workbench/hardcaml-workbench-simulation.sexp"):
            assert (root / relative).is_file(), relative
        assert not (root / "dune-project").exists(), "Bluespec must not generate a Dune project"
        assert not (root / "bazel-invocations").exists(), "wizard must not run Bazel"

    def untouched():
        assert list(start.iterdir()) == [] and not state.exists()

    # Use a short viewport so that scrolling the visible preview is observable.
    with launch(width=79, height=17) as term:
        point(term, "[q] Quit")  # Visible behind the modal but inert.
        menu(term)
        point(term, "Esc dismiss")
        point(term, "[p] Create")
        point(term, "New Project")
        presets(term)
        point(term, hardcaml)
        term.capture("pointer-name", ["Project name"])
        send(term, "demo")
        point(term, "Enter continue")
        point(term, "Enter preview")
        first = "First registered chip target"
        term.capture("pointer-preview", [first])
        point(term, "Create preview", 65)
        term.capture("wheel-down", ["Create preview"], absent=[first])
        point(term, "↑")
        term.capture("click-up", [first])
        point(term, "↓")
        term.capture("click-down", ["Create preview"], absent=[first])
        point(term, "Create preview", 64)
        term.capture("wheel-up", [first])
        point(term, first)  # Body text is not Apply.
        point(term, "Apply and open", 2)
        point(term, "Apply and open", release_only=True)
        term.capture("preview-inert", [first])
        untouched()
        point(term, "Esc cancel")
        term.capture("pointer-cancelled", [unbound], absent=["Create preview"])
        untouched()

    # Match the current rendered screen; the launch dialog is transient and
    # its bytes (and stale preview details) remain in the PTY transcript.
    with launch() as term:
        menu(term)
        dismiss(term)
        untouched()
        send(term, "p")
        new_project(term)
        send(term, "h")
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
        point(term, "Enter retry")
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

    # Hold a real standalone state lock. A competing CLI or TUI must report
    # contention without touching the lock or falling back to another service.
    dedicated_state = base / "contention-state"
    standalone = ("--standalone-state-dir", str(dedicated_state))
    lock_path = dedicated_state / "lifetime.lock"
    guidance = "Close the other Silver window with q, then reopen this project."

    def assert_no_monitor(text):
        assert not any(s in text for s in ("monitor.ml", "monitor.sexp", "Raised at",
                                           "Monitor.try_with", "daemon lifetime lock")), text

    with launch(*standalone, cwd=existing) as owner:
        dashboard(owner, existing.name)
        identity = lock_path.stat().st_ino
        for mode in ("--plain", "--api"):
            rejected = subprocess.run([silver, *standalone, mode], cwd=existing, env=env,
                                      capture_output=True, text=True, timeout=15)
            assert rejected.returncode != 0
            for text in ("Another Silver session", str(existing), str(dedicated_state), guidance):
                assert text in rejected.stderr, rejected.stderr
            assert_no_monitor(rejected.stderr)
            if mode == "--plain":
                assert not rejected.stdout
            else:
                assert "Conflict" in rejected.stdout
                assert_no_monitor(rejected.stdout)
        with launch(*standalone, cwd=existing) as contender:
            screen = contender.capture("standalone-locked", [
                "Project already open", str(existing), str(dedicated_state), guidance,
                "Close this window",
            ], absent=["Overview"])
            assert_no_monitor(screen)
            send(contender, "q")
            contender.process.wait(timeout=5)
        with launch(*standalone) as contender:
            menu(contender)
            send(contender, "o")
            contender.capture("open-locked-form", ["Existing project directory"])
            send(contender, str(existing) + "\r")
            screen = contender.capture("open-locked-project", ["Project error", guidance])
            assert_no_monitor(screen)
        assert owner.process.poll() is None
        assert lock_path.stat().st_ino == identity
        with lock_path.open("rb") as probe:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("contender released the owner's state lock")
        send(owner, "Q")
        assert owner.process.wait(timeout=10) == 0
    with launch(*standalone, cwd=existing) as reopened:
        dashboard(reopened, existing.name)
        assert lock_path.stat().st_ino == identity
        send(reopened, "Q")
        assert reopened.process.wait(timeout=10) == 0

    bad_state = subprocess.run([silver, "--plain", "--standalone-state-dir", "relative"],
                               cwd=existing, env=env, capture_output=True, text=True, timeout=15)
    assert bad_state.returncode and "--state-dir must be absolute" in bad_state.stderr
    assert "Another Silver session" not in bad_state.stderr

    with launch(cwd=source) as term:
        see(term, "discovered project root " + str(nested) + " ")
        dashboard(term, nested.name)
        assert unbound.encode() not in term.data
    with launch() as term:
        menu(term)
        point(term, "Open existing")
        term.capture("open", ["Existing project directory"])
        send(term, ".\r")
        # A long sandbox root can wrap the prose mid-word.
        term.capture("open-error", ["Project error", "dune-project"])
        dismiss(term, "Project error")
        send(term, "p")
        menu(term)
        send(term, "o")
        term.capture("open-again", ["Existing project directory"])
        send(term, str(existing))
        point(term, "Enter open")
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
            if destination == "already-empty":
                point(term, "Apply and open")
            else:
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

    # A manifest is sufficient to discover a Bazel project without Dune;
    # opening must not run the tool. Exercise the user-facing Build/Test actions
    # with distinct targets, not a real Bazel install or an ASIC provider.
    classic = base / "classic"
    (classic / ".silver").mkdir(parents=True)
    sources = classic / "src"
    sources.mkdir()
    (classic / ".silver/project.json").write_text(json.dumps({
        "schema_version": 1, "name": "classic_example",
        "build_label": "//:rtl", "test_label": "//:simulation",
    }))
    bazel = tools / "bazel"
    bazel.write_text("#!/bin/sh\n"
                     'test "$#" -eq 2 || exit 1\n'
                     'printf "%s %s\\n" "$1" "$2" >> bazel-invocations\n')
    bazel.chmod(0o755)
    help_text = subprocess.check_output([silver, "--help"], env=env, text=True, timeout=15)
    assert "Silver Bazel" in help_text and ".silver/project.json" in help_text
    opened = subprocess.run([silver, "--plain"], cwd=sources, env=env,
                            capture_output=True, check=True, text=True, timeout=15)
    assert "Project: classic_example" in opened.stdout
    assert "Build tool: Bazel" in opened.stdout
    assert "Dune" not in opened.stdout and "dune=" not in opened.stdout
    invocation_log = classic / "bazel-invocations"
    assert not invocation_log.exists(), "opening should not probe Bazel"
    with launch(cwd=sources, width=180, height=55) as term:
        dashboard(term, "classic_example")
        send(term, "\x1b[19~")  # F8: connection details
        term.capture("classic-details", ["Build tool:", "Bazel"],
                     absent=["Dune version:", "DUNE ITEMS"])
        send(term, "\x1b[19~")  # F8: return to workspace
        term.palette("Build project")
        term.palette("Run project tests")
        term.palette("Switch to Testing")
        term.capture("classic-testing", [
            "Testing", "simulation-catalog",
            re.compile(r"Complete\s+bazel build"), re.compile(r"Complete\s+bazel test"),
        ])
    assert sorted(invocation_log.read_text().splitlines()) == ["build //:rtl", "test //:simulation"]

    def classic_destination(term, *, bound=False):
        term.capture("bluespec-destination", ["Bluespec Classic destination",
                     "Blank creates a sibling named" if bound else "Blank uses the current directory."],
                     absent=["╭ Project name"])

    def classic_review(term, target):
        term.capture("bluespec-preview", ["Create preview", "Preset: " + bluespec,
                     "Destination:", target.name, "Build: //:rtl", "Test: //:simulation",
                     "Apply and open"])

    # A relative destination entered from the blank startup is rooted at the
    # startup directory. Preview/back do not publish files.
    from_blank = start / "classic lab"
    with launch() as term:
        new_project(term)
        point(term, bluespec)
        classic_destination(term)
        send(term, from_blank.name + "\r")
        classic_review(term, from_blank)
        assert not list(start.iterdir())
        point(term, "Esc back")
        term.capture("bluespec-back-keeps-path", ["Bluespec Classic destination", from_blank.name + "▏"])
        point(term, "Enter preview")
        classic_review(term, from_blank)
        point(term, "Apply and open")
        dashboard(term, from_blank.name)
        classic_scaffold(from_blank)
        assert set(start.iterdir()) == {from_blank}

    # Open existing must recognize the actual wizard-created manifest from
    # another blank process, without creating anything in its working directory.
    caller = base / "blank-caller"
    caller.mkdir()
    with launch(cwd=caller) as term:
        menu(term)
        send(term, "o")
        term.capture("open-wizard-output", ["Existing project directory"])
        send(term, str(from_blank) + "\r")
        dashboard(term, from_blank.name)
    assert not list(caller.iterdir())

    # From an already-open Dune project, use the same chooser. An intervening
    # owner at the previewed destination must not be overwritten by Apply.
    from_bound = base / "bound classic"
    with launch(cwd=existing) as term:
        dashboard(term, existing.name)
        term.palette("New Project")
        presets(term)
        send(term, "b")
        classic_destination(term, bound=True)
        send(term, from_bound.name + "\r")
        classic_review(term, from_bound)
        assert not from_bound.exists()
        from_bound.mkdir()
        owned = from_bound / "Counter.bs"
        owned.write_text("-- user-owned source\n")
        send(term, "\r")
        term.capture("bluespec-no-clobber", ["Project error", "Destination is occupied"])
        assert list(from_bound.iterdir()) == [owned]
        assert owned.read_text() == "-- user-owned source\n"
        send(term, "\x1b")
        dashboard(term, existing.name)
        assert (existing / "dune-project").read_text() == "(lang dune 3.10)\n"

        # A different, empty destination is valid and becomes the bound project.
        target = base / "classic sibling"
        target.mkdir()
        term.palette("New Project")
        presets(term)
        send(term, "b")
        classic_destination(term, bound=True)
        send(term, target.name + "\r")
        classic_review(term, target)
        assert not list(target.iterdir())
        send(term, "\r")
        dashboard(term, target.name)
        classic_scaffold(target)
        assert not (existing / target.name).exists()
        assert (existing / "dune-project").read_text() == "(lang dune 3.10)\n"
        assert owned.read_text() == "-- user-owned source\n"

    with launch("--no-mouse") as term:
        point(term, "New Project")
        menu(term)
        send(term, "c")
        presets(term)
        send(term, "\r")
        term.capture("keyboard-only", ["Project name"])


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="silver-entry-") as tmp:
        exercise(Path(sys.argv[1]).resolve(), Path(tmp),
                 Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None)
    print("Silver launcher entry, discovery, and Hardcaml/Bluespec project handoff passed.")
