"""Exercise Bluespec authoring in the real terminal without invoking a toolchain."""

from contextlib import closing
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
from support.terminal import Terminal


def send(term, keys):
    os.write(term.master, keys)
    term.drain(.12)


def click(term, screen, label):
    row, line = next((row, line) for row, line in enumerate(screen.splitlines()) if label in line)
    position = f"\x1b[<0;{line.index(label) + 1};{row + 1}"
    send(term, (position + "M" + position + "m").encode())


def exercise(silver, base):
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(base / "home"),
        "XDG_STATE_HOME": str(base / "state"),
        "XDG_RUNTIME_DIR": str(base / "runtime"),
    }
    for key in ["HOME", "XDG_RUNTIME_DIR"]:
        Path(env[key]).mkdir(mode=0o700)
    root = base / "classic"
    subprocess.run([silver, "init", "--bluespec", root], env=env, cwd=base, check=True, timeout=10)

    def open_ui(root):
        term = Terminal(SimpleNamespace(evidence=base, env=env),
                        argv=[silver, "--standalone", "--project-root", root], cwd=root)
        return closing(term)

    generic = base / "generic bazel"
    (generic / ".silver").mkdir(parents=True)
    (generic / ".silver/project.json").write_text(json.dumps({
        "schema_version": 1, "name": "generic bazel",
        "build_label": "//:rtl", "test_label": "//:simulation",
    }))
    (generic / "BUILD.bazel").touch()
    (generic / "MODULE.bazel").touch()
    hidden = ["New IP Library", "New Module", "New Chip Target"]
    with open_ui(generic) as term:
        term.capture("generic-bazel-overview", ["Overview"])
        send(term, b"\x1bOQ")
        term.capture("generic-bazel-project-menu", ["Manage This Project", "Open Project"],
                     absent=hidden)
        send(term, b"\x1b")
        term.palette("Manage This Project")
        term.capture("generic-bazel-manage", ["Manage This Project", "Objects", "Actions"],
                     absent=hidden)
        send(term, b"\x1b")
        for command in [b"project.new-ip", b"project.new-module"]:
            for key in (b" ", b"c", b"c", command):
                send(term, key)
            term.capture(f"generic-bazel-palette-{command.decode()}",
                         ["COMMAND PALETTE", "No matching commands"], absent=hidden)
            send(term, b"\x1b")

    with open_ui(root) as term:
        term.capture("bluespec-overview", ["Overview"])
        send(term, b"\x1bOQ")
        term.capture("bluespec-project-menu", ["New IP Library", "New Module"],
                     absent=["New Chip Target", "New Flow", "Duplicate Profile"])
        send(term, b"/New IP Library\r")
        term.capture("bluespec-ip-name", ["NEW BLUESPEC IP LIBRARY", "enter library name"],
                     absent=["Empty template", "Sample behavior"])
        send(term, b"widget\r")
        term.capture("bluespec-ip-preview", ["NEW BLUESPEC IP LIBRARY PREVIEW",
                                           "ip/widget/BUILD.bazel"])
        library = root / "ip/widget"
        assert not library.exists(), "preview created the library"
        send(term, b"\r")
        term.capture("bluespec-ip-created", ["IP library created", "ip/widget/BUILD.bazel"])
        assert (library / "BUILD.bazel").is_file()
        send(term, b"\r")

        term.palette("Manage This Project")
        screen = term.capture("bluespec-manage", ["New IP Library", "New Module", "Objects", "Actions"],
                              absent=["New Chip Target"])
        click(term, screen, "New Module")
        term.capture("bluespec-module-directory", ["NEW BLUESPEC MODULE", "Bazel package directory"],
                     absent=["dune file"])
        send(term, b"ip/widget\r")
        term.capture("bluespec-module-name", ["enter module name", "Library: ip/widget", ".bs"])
        send(term, b"pipeline\r")
        term.capture("bluespec-module-preview", ["NEW BLUESPEC MODULE PREVIEW", "ip/widget/Pipeline.bs"],
                     absent=["Manual Dune edit"])
        assert not (library / "Pipeline.bs").exists(), "preview created the module"
        send(term, b"\r")
        term.capture("bluespec-module-created", ["Module created", "ip/widget/Pipeline.bs"])
        assert (library / "Pipeline.bs").is_file()

    with open_ui(root) as term:
        term.capture("bluespec-reopened", ["Overview"])
        term.palette("new module")
        term.capture("bluespec-module-palette", ["Bazel package directory", "root package"])
        send(term, b".\r")
        term.capture("bluespec-root-module-name", ["enter module name"])
        send(term, b"top_helper\r")
        term.capture("bluespec-root-module-preview", ["Top_helper.bs", "Manual Bazel edit: BUILD.bazel"],
                     absent=["Manual Dune edit"])
        send(term, b"\x1b")
        term.capture("bluespec-cancelled", ["Preview cancelled. No files created."])
        assert not (root / "Top_helper.bs").exists()
        send(term, b"\r")

        build = root / "BUILD.bazel"
        original = build.read_bytes()
        term.palette("new module")
        send(term, b".\r")
        term.capture("bluespec-root-apply-name", ["enter module name"])
        send(term, b"top_helper\r")
        term.capture("bluespec-root-apply-preview", ["Manual Bazel edit: BUILD.bazel"])
        send(term, b"\r")
        term.capture("bluespec-root-applied", ["Module created", "Manual Bazel edit: BUILD.bazel"])
        assert (root / "Top_helper.bs").is_file()
        assert build.read_bytes() == original


if __name__ == "__main__":
    with TemporaryDirectory(prefix="bluespec-authoring-") as tmp:
        exercise(Path(sys.argv[1]).resolve(), Path(tmp))
