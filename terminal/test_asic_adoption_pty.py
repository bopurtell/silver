"""Drive bound setup through the real local palette, authoring RPC and config writer."""
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


def select(term, title):
    term.palette("Set up project")
    term.capture("setup-choices", ["Add ASIC starter", "Import existing ASIC design"])
    os.write(term.master, title.encode() + b"\r")


def exercise(client, base):
    project = base / "chip"
    project.mkdir()
    marker = project / "dune-project"
    marker.write_text("(lang dune 3.10)\n")
    design = project / "design (existing)"
    invoked = base / "unexpected-launch"
    source = f"#!/bin/sh\ntouch '{invoked}'\n"
    design.write_text(source)
    design.chmod(0o700)
    config = project / ".workbench" / "hardcaml-workbench-asic.sexp"
    env = dict(os.environ, XDG_STATE_HOME=str(base / "state"))
    term = Terminal(SimpleNamespace(env=env, evidence=base),
                    argv=[str(client), "--standalone", "--project-root", str(project)],
                    cwd=project)
    try:
        term.capture("dashboard", ["Overview"])
        select(term, "Import existing")
        term.capture("form", ["existing project executable"])
        os.write(term.master, design.name.encode() + b"\x1b")
        term.capture("cancelled", absent=["existing project executable"])
        assert not config.exists()
        select(term, "Import existing")
        term.capture("import-form", ["existing project executable"])
        os.write(term.master, b"missing.exe\r")
        term.capture("correctable-error", ["missing.exe", "existing project executable"])
        assert not config.exists()
        os.write(term.master, b"\x7f" * len("missing.exe") + design.name.encode() + b"\r")
        term.capture("saved", absent=["existing project executable"])
        assert str(design) in config.read_text()
        assert design.read_text() == source
        assert marker.read_text() == "(lang dune 3.10)\n"
        assert not invoked.exists()
    finally:
        term.close()


def exercise_add(client, base, real_renderer=None):
    root = base / "generic"
    root.mkdir()
    marker = root / "dune-project"
    marker.write_text("(lang dune 3.10)\n(name original)\n")
    owned = root / "original.ml"
    owned.write_text("let original = true\n")
    catalog = root / "hardcaml-asic-targets.json"
    catalog.write_text('{"custom":"preserve"}\n')
    files = [{"path": "asic_demo/" + path, "contents": contents}
             for path, contents in [("project.ml", "let () = ()\n"), ("chip.ml", ""),
                                    ("dune", "(executable (name project))\n")]]
    renderer = base / "hardcaml-asic-starter"
    if real_renderer:
        renderer.symlink_to(real_renderer)
        files = json.loads(subprocess.check_output(
            [renderer, "render-existing", "--name", "demo"]))["files"]
    else:
        renderer.write_text("#!/bin/sh\n[ \"$*\" = 'render-existing --name demo' ] || exit 2\n"
                            + "cat <<'JSON'\n" + json.dumps(dict(
                                schema_version=1, provider="hardcaml_asic", version="1",
                                files=files)) + "\nJSON\n")
        renderer.chmod(0o755)
    env = dict(os.environ, PATH=str(base) + ":" + os.environ["PATH"],
               XDG_STATE_HOME=str(base / "state"))
    term = Terminal(SimpleNamespace(env=env, evidence=base),
                    argv=[str(client), "--standalone", "--project-root", str(root)], cwd=root)
    try:
        term.capture("bound", ["Overview"])
        for decision in ("cancel", "conflict", "apply"):
            select(term, "Add ASIC")
            term.capture("starter-name", ["enter starter name"])
            os.write(term.master, b"demo\r")
            term.capture("preview", ["ASIC STARTER PREVIEW", "hardcaml-asic-add-to-project-v1",
                                     "asic_demo/project.ml", "Proposed registration"])
            assert not (root / "asic_demo").exists()
            assert not (root / ".workbench").exists()
            if decision == "conflict":
                collision = root / "asic_demo"
                collision.mkdir()
                rival = collision / "project.ml"
                rival.write_text("owned by another author\n")
            os.write(term.master, b"\x1b" if decision == "cancel" else b"a")
            if decision == "cancel":
                term.capture("cancelled-preview", ["Preview cancelled"])
                assert not (root / "asic_demo").exists() and not (root / ".workbench").exists()
                os.write(term.master, b"\r")
            elif decision == "conflict":
                term.capture("stale-preview", ["Stale_preview", "asic_demo"])
                assert rival.read_text() == "owned by another author\n"
                assert not (root / ".workbench").exists()
                rival.unlink()
                collision.rmdir()
                os.write(term.master, b"\r")
            else:
                term.capture("applied", ["ASIC starter added", "Skipped registration"])
        for file in files:
            assert (root / file["path"]).read_text() == file["contents"]
        config = root / ".workbench/hardcaml-workbench-asic.sexp"
        assert str(root / "_build/default/asic_demo/project.exe") in config.read_text()
        assert catalog.read_text() == '{"custom":"preserve"}\n'
        assert marker.read_text() == "(lang dune 3.10)\n(name original)\n"
        assert owned.read_text() == "let original = true\n"
    finally:
        term.close()


if __name__ == "__main__":
    with TemporaryDirectory(prefix="asic-adoption-") as tmp:
        exercise(Path(sys.argv[1]).resolve(), Path(tmp))
        exercise_add(Path(sys.argv[1]).resolve(), Path(tmp),
                     Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None)
