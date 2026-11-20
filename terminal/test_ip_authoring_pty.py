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
