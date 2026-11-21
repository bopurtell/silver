"""Create a blank workspace and drive its workspace list in a real terminal."""
import argparse
from contextlib import closing
import os
from pathlib import Path
import re
import runpy
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "test"))
from support.terminal import Terminal

native = runpy.run_path(str(ROOT / "scripts/test-native-execution.py"))
Session, field = native["Session"], native["field"]


def exercise(args, evidence):
    root = evidence / "project"
    root.mkdir()
    (root / "dune-project").write_text("(lang dune 3.22)\n")
    s = Session(args, evidence, root)
    try:
        s.start()
        # The sole tile fills the available area. At 80 columns the workspace
        # chips don't fit side by side, so it paints a list with a textual cursor.
        with closing(Terminal(s, width=80)) as t:
            t.capture("ready", ["Connection: connected", "[1 Overview]"])
            before = s.rpc("workspace")
            stock = field(before, "workspaces")
            overview, = (w for w in stock if field(w, "name") == "Overview")
            custom_header = re.compile(r"^Workspace 1 \|")

            t.palette("Create blank workspace")
            t.capture("created-and-active", [custom_header, "Workspace 1: active", "Overview"],
                      absent=["COMMAND PALETTE", "No visible tiles"])
            created = s.rpc("workspace")
            workspaces = field(created, "workspaces")
            assert workspaces[:-1] == stock, workspaces
            custom = workspaces[-1]
            assert field(custom, "name") == "Workspace 1", custom
            assert field(custom, "window") == field(overview, "window"), custom
            assert field(custom, "context") == field(created, "main_context"), custom
            assert field(custom, "preset") == [], custom
            tiles = field(created, "tiles")
            assert tiles[:-1] == field(before, "tiles"), tiles
            tile = tiles[-1]
            assert field(tile, "workspace") == field(custom, "id"), tile
            assert field(tile, "kind") == "workspace-tabs", tile
            assert dict(field(tile, "requested_geometry")) == {
                "x": "0", "y": "0", "width": "80", "height": "1",
            }, tile

            # Walk from the last workspace back to Overview without activating any
            # intermediate workspace. Enter must use the cursor, not the active row.
            os.write(t.master, b"k" * len(stock))
            t.capture("browsed-overview", [custom_header, "Workspace 1: active",
                                           "Overview: Enter to open"])
            os.write(t.master, b"\r")
            t.capture("opened-overview", ["[1 Overview]"], absent=[custom_header])

            # Return to the custom tile, then click a different row from the
            # retained keyboard cursor to verify pointer dispatch uses the hit.
            t.palette("Switch to Workspace 1")
            screen = t.capture("returned-to-custom",
                               [custom_header, "Workspace 1: active", "Overview: Enter to open"])
            y, line = next((i, line) for i, line in enumerate(screen.splitlines())
                           if line.strip() == "Testing")
            x = line.index("Testing")
            report = f"\x1b[<0;{x + 1};{y + 1}"
            os.write(t.master, (report + "M" + report + "m").encode())
            t.capture("clicked-testing", ["[2 Testing]", "simulation-catalog"],
                      absent=[custom_header])
            assert s.rpc("workspace") == created, "Navigation unexpectedly changed the registry"
    finally:
        s.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("client", "daemon"):
        parser.add_argument("--" + name, type=lambda p: Path(p).resolve(strict=True), required=True)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    args.outer_timeout = 20
    if args.evidence:
        args.evidence.mkdir()
        exercise(args, args.evidence.resolve())
    else:
        with TemporaryDirectory(prefix="custom-workspace-pty-") as tmp:
            exercise(args, Path(tmp))
