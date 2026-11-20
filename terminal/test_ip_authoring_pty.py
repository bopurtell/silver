"""Drive native IP/module authoring. Usage: python3 -B test_ip_authoring_pty.py SILVER [RENDERER].

With the optional real hardcaml-asic-starter, also build and test the resulting
disposable Dune project. The default runtest action uses a controlled renderer.
"""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


def snapshot(root):
    # Dune metadata discovery may create _build before any authoring operation.
    files = {}
    for directory, dirs, names in os.walk(root):
        if Path(directory) == root and "_build" in dirs:
            dirs.remove("_build")
        for name in names:
            path = Path(directory) / name
            files[path.relative_to(root).as_posix()] = path.read_bytes()
    return files


def expected(renderer, *args, prefix=""):
    manifest = json.loads(subprocess.check_output([renderer, *args]))
    return {prefix + f["path"]: f["contents"].encode() for f in manifest["files"]}


def send(term, text):
    os.write(term.master, text.encode())


def scroll_to(term, expected):
    for _ in range(60):
        if expected.casefold() in term.drain(.08).casefold():
            return
        send(term, "\x1b[B")
    term.capture("missing-scroll-line", [expected])


def ip_preview(term, name, sample=False):
    term.palette("new ip")
    term.capture("ip-template", ["New IP Library", "empty", "sample"])
    send(term, "\x1b[B\r" if sample else "\r")
    term.capture("ip-name", ["enter library name", "Template: sample" if sample else "Template: empty"])
    send(term, name + "\r")
    term.capture("ip-preview", ["preview", f"ip/{name}/block.ml", f"ip/{name}/dune"])


def exercise_dialogs(launch, root, renderer, original):
    with launch() as term:
        ip_preview(term, "vacant")
        assert snapshot(root) == original
        send(term, "\x1b")
        term.capture("ip-cancelled", ["Preview cancelled. No files created."])
        assert snapshot(root) == original
        assert not (root / "ip").exists()
        send(term, "\r")

        for name, template in [("vacant", "empty"), ("counter", "sample")]:
            ip_preview(term, name, sample=(template == "sample"))
            assert snapshot(root) == original
            send(term, "\r")
            term.capture("ip-created", ["created", f"ip/{name}/block.ml"])
            original.update(expected(renderer, "render-ip", "--name", name, "--template", template))
            assert snapshot(root) == original
            send(term, "\r")

        # A collaborator creates a destination after preview. Nothing else in
        # the recipe may be written, even files ordered before the collision.
        ip_preview(term, "racing", sample=True)
        collision = root / "ip/racing/block.ml"
        collision.parent.mkdir()
        collision.write_bytes(b"(* in-progress edit; never replace *)\r\n")
        occupied = snapshot(root)
        send(term, "\r")
        term.capture("ip-stale", ["Stale_preview"])
        assert snapshot(root) == occupied
        original = occupied

    # A fresh launch has no library selected. Type a destination explicitly;
    # the custom modules list belongs to the user and must be left alone.
    with launch() as term:
        term.palette("new module")
        term.capture("module-directory", ["library", "directory"])
        send(term, "aa_existing\r")
        term.capture("module-name", ["module name", "aa_existing"])
        send(term, "addon\r")
        term.capture("module-preview", ["preview", "aa_existing/addon.ml", "modules"])
        assert snapshot(root) == original
        send(term, "\r")
        term.capture("module-created", ["created", "aa_existing/addon.ml"])
        original.update(expected(renderer, "render-module", "--name", "addon", prefix="aa_existing/"))
        assert snapshot(root) == original

    with launch() as term:
        def selected_library():
            term.palette("Library: ip_counter")
            term.capture("selected-library-actions", ["New Module"])
            send(term, "New Module\r")
            term.capture("contextual-name", ["module name", "ip/counter"])

        selected_library()
        send(term, "pipeline\r")
        term.capture("contextual-preview", ["preview", "ip/counter/pipeline.ml"])
        assert snapshot(root) == original
        send(term, "\r")
        term.capture("contextual-created", ["created", "ip/counter/pipeline.ml"])
        original.update(expected(renderer, "render-module", "--name", "pipeline", prefix="ip/counter/"))
        assert snapshot(root) == original
        send(term, "\r")

        pipeline = root / "ip/counter/pipeline.ml"
        pipeline.write_bytes(b"(* edited after creation *)\nlet user_value = 0x2a\n")
        edited = snapshot(root)
        selected_library()
        send(term, "pipeline\r")
        term.capture("occupied-module", ["enter module name", "Conflict:", "ip/counter/pipeline.ml"])
        assert snapshot(root) == edited

    with launch() as term:
        # A library visible in Dune is not necessarily a chip-compatible IP.
        term.palette("New Chip Target")
        term.capture("chip-source-options", ["From example/template", "From IP library"])
        send(term, "From IP\r")
        term.capture("chip-libraries", ["ip_vacant", "ip_counter"])
        send(term, "ip_vacant\r")
        term.capture("unsupported-mapping", ["ip/vacant", "explicit pin mapping"])
        send(term, "ui_in:uo_out:comb8\r")
        term.capture("unsupported-name", ["enter target name"])
        send(term, "unwired\r")
        term.capture("unsupported-ip", ["enter target name", "Expected regular file"],
                     absent=["CHIP TARGET PREVIEW"])
        assert not (root / "asic_unwired").exists()
        send(term, "\x1b")
        term.capture("dismiss-unsupported", ["Overview"], absent=["enter target name"])

        term.palette("Library: ip_counter")
        term.capture("library-chip-action", ["New Chip Target"])
        send(term, "New Chip Target\r")
        term.capture("chip-mapping", ["ip/counter", "ui_in:uo_out:comb8", "no clock/reset"])
        send(term, "\r")
        term.capture("missing-mapping", ["Enter the supported mapping explicitly"])
        send(term, "ui_in:uo_out:comb8\r")
        term.capture("mapped-name", ["enter target name", "Library: ip/counter"])
        send(term, "wrapped\r")
        term.capture("mapped-preview", ["Chip Target Preview", "registration: on", "combinational"])
        send(term, "r")
        term.capture("declined-preview", ["registration: declined", "absent from picker"])
        assert snapshot(root) == edited
        send(term, "\r")
        term.capture("created-unregistered", ["Chip target created", "Catalog registration declined"],
                     absent=["Select new chip target"])
        assert not (root / "hardcaml-asic-targets.json").exists()
        assert (root / "asic_wrapped/project.ml").is_file()
        assert all((root / path).read_bytes() == contents for path, contents in edited.items())

        # A custom catalog remains owner-managed. The receipt must show the
        # exact manual entry and destination rather than offering selection.
        send(term, "\r")
        custom = root / "hardcaml-asic-targets.json"
        custom.write_text('{"custom":"untouched"}\n')
        term.palette("New Chip Target")
        send(term, "example\r")
        term.capture("example-name", ["enter target name"])
        send(term, "customchip\r")
        term.capture("example-preview", ["registration: on", "Enter applies"])
        scroll_to(term, "Manual catalog entry")
        scroll_to(term, "asic_customchip/project.exe")
        send(term, "\r")
        term.capture("manual-result", ["Chip target created"], absent=["Select new chip target"])
        assert custom.read_text() == '{"custom":"untouched"}\n'

        send(term, "\r")
        custom.write_text(json.dumps(dict(schema_version=1, default_target="customchip",
                                          targets=[dict(id="customchip", executable="asic_customchip/project.exe")])))
        term.palette("New Chip Target")
        send(term, "example\r")
        term.capture("racing-name", ["enter target name"])
        send(term, "late\r")
        term.capture("racing-catalog-preview", ["registration: on"])
        custom.write_text(custom.read_text() + "\n")
        newer = snapshot(root)
        send(term, "\r")
        term.capture("stale-catalog", ["Stale_preview"])
        assert snapshot(root) == newer


def exercise(client, real_renderer, base):
    bin_dir = base / "bin"
    bin_dir.mkdir()
    renderer = bin_dir / "hardcaml-asic-starter"
    if real_renderer:
        renderer.symlink_to(real_renderer)
    else:
        fixture = Path(__file__).resolve().with_name("ip_starter_fixture.py")
        renderer.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} -B "
                            f"{shlex.quote(str(fixture))} \"$@\"\n")
        renderer.chmod(0o755)
    outer = {k: v for k, v in os.environ.items() if not k.startswith("DUNE_") and k != "INSIDE_DUNE"}
    env = dict(outer, XDG_STATE_HOME=str(base / "state"), XDG_RUNTIME_DIR=str(base / "run"),
               PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
    root = base / "project"
    root.mkdir()
    (root / "dune-project").write_text("(lang dune 3.17)\n(name scratch)\n")
    # Two candidate libraries expose accidental selection of the first match.
    custom = root / "aa_existing"
    custom.mkdir()
    (custom / "dune").write_text("(library (name existing) (modules keep))\n")
    (custom / "keep.ml").write_bytes(b"(* user source *)\nlet keep = 0xff\n")
    original = snapshot(root)

    @contextmanager
    def launch():
        term = Terminal(SimpleNamespace(evidence=base, env=env),
                        argv=[str(client), "--standalone", "--project-root", str(root)], cwd=root)
        try:
            term.capture("bound", ["Overview"])
            yield term
        finally:
            term.close()

    exercise_dialogs(launch, root, renderer, original)
    if real_renderer:
        for action in ("build", "runtest"):
            subprocess.run(["dune", action], check=True, cwd=root, timeout=180, env=env)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("client", type=Path)
    parser.add_argument("renderer", type=Path, nargs="?")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="ip-authoring-") as directory:
        exercise(args.client.resolve(), args.renderer and args.renderer.resolve(), Path(directory))
