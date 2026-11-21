"""Drive workspace creation, navigation, close/reopen, and deletion in a real terminal."""
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


def expect_registry(before, after, *, revisions=1, **changes):
    expected = dict(before, revision=str(int(field(before, "revision")) + revisions), **changes)
    actual = dict(after)
    for snapshot in (expected, actual):
        snapshot["workspaces"] = [dict(w) for w in snapshot["workspaces"]]
    assert actual == expected, after


def expect_closed(before, after, workspace):
    workspace_id = field(workspace, "id")
    workspaces = [dict(w, closed="true") if field(w, "id") == workspace_id else w
                  for w in field(before, "workspaces")]
    # The registry change is just the flag: all tile IDs, layout data and
    # workspace order must remain unchanged.
    expect_registry(before, after, workspaces=workspaces)


def click(t, x, y):
    report = f"\x1b[<0;{x + 1};{y + 1}"
    os.write(t.master, (report + "M" + report + "m").encode())


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
            testing, = (w for w in stock if field(w, "name") == "Testing")
            custom_header = re.compile(r"^Workspace 1 \|")
            connected = re.compile(r"Connection: connected| \| connected$", re.M)
            close = "Close current workspace"

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
            click(t, line.index("Testing"), y)
            t.capture("clicked-testing", ["[2 Testing]", "simulation-catalog"],
                      absent=[custom_header])
            assert s.rpc("workspace") == created, "Navigation unexpectedly changed the registry"

            # Use a second custom workspace to inspect the narrow list while
            # Workspace 1 is unavailable.
            t.palette("Create blank workspace")
            t.capture("kept-workspace-active", ["Workspace 2: active", "Workspace 1"])
            with_survivor = s.rpc("workspace")
            survivor, = (w for w in field(with_survivor, "workspaces")
                         if field(w, "name") == "Workspace 2")
            assert field(survivor, "window") == field(custom, "window"), survivor

            t.palette("Switch to Workspace 1")
            t.capture("before-custom-close",
                      [custom_header, "Workspace 1: active", "Overview: Enter to open"])
            t.palette(close)
            t.capture("custom-close-fallback", ["[1 Overview]"], absent=[custom_header])
            expect_closed(with_survivor, s.rpc("workspace"), custom)
            t.palette("Switch to Workspace 2")
            t.capture("list-while-custom-closed", ["Workspace 2: active", "Overview", "Testing"],
                      absent=["Workspace 1"])
            with closing(Terminal(s)) as wide:
                wide.capture("tabs-while-custom-closed",
                             [connected, "Overview", f"{len(stock) + 1} Workspace 2"],
                             absent=[re.compile(r"\d+ Workspace 1\b"), custom_header])

            t.palette("Reopen workspace: Workspace 1")
            t.capture("custom-reopened",
                      [custom_header, "Workspace 1: active", "Overview: Enter to open"])
            reopened = s.rpc("workspace")
            expect_registry(with_survivor, reopened, revisions=2)
            # The first j still works on the restored workspace-tabs focus and
            # advances from its retained Overview cursor, not from Workspace 1.
            os.write(t.master, b"j")
            t.capture("browsed-after-reopen",
                      [custom_header, "Workspace 1: active", "Testing: Enter to open"])
            os.write(t.master, b"\r")
            t.capture("opened-testing-after-reopen", ["[2 Testing]", "simulation-catalog"],
                      absent=[custom_header])

        with closing(Terminal(s)) as t:
            custom_tab = f"{len(stock) + 1} Workspace 1"
            survivor_tab = f"{len(stock) + 2} Workspace 2"
            t.capture("tabs-with-custom-reopened", [connected, custom_tab, survivor_tab])
            t.palette("Switch to Testing")
            screen = t.capture("before-testing-close", ["[2 Testing]", "simulation-catalog"])
            y, line = next((i, line) for i, line in enumerate(screen.splitlines())
                           if "simulation-catalog" in line)
            click(t, line.index("simulation-catalog"), y)
            testing_focus = "R run checked cases"
            t.capture("testing-catalog-focused", [testing_focus])
            t.palette(close)
            testing_tab = re.compile(r"\b\d+ Testing\b")
            t.capture("testing-closed", ["[1 Overview]", f"{len(stock) + 1} Workspace 2"],
                      absent=[testing_tab])
            expect_closed(reopened, s.rpc("workspace"), testing)
            t.palette("Reopen workspace: Testing")
            t.capture("testing-reopened", ["[2 Testing]", testing_focus, survivor_tab])
            before_delete = s.rpc("workspace")
            expect_registry(reopened, before_delete, revisions=2)

            t.palette("Switch to Workspace 1")
            t.capture("ready-to-delete", [custom_header, f"[{custom_tab}]", survivor_tab])

            delete = "Delete current workspace"
            confirmation = ["Confirm workspace deletion", "Delete workspace: Workspace 1",
                            "Enter confirms", "Esc cancels"]
            t.palette(delete)
            t.capture("delete-confirmation-before-cancel", confirmation)
            assert s.rpc("workspace") == before_delete, "Opening confirmation changed the registry"
            os.write(t.master, b"\x1b")
            t.capture("delete-canceled", [custom_header, f"[{custom_tab}]", survivor_tab],
                      absent=confirmation)
            assert s.rpc("workspace") == before_delete, "Cancel changed the registry"

            t.palette(delete)
            t.capture("delete-confirmation-before-enter", confirmation)
            os.write(t.master, b"\r")
            t.capture("deleted-and-fell-back", ["[1 Overview]", f"{len(stock) + 1} Workspace 2"],
                      absent=[custom_header, custom_tab, *confirmation])
            deleted = s.rpc("workspace")
            custom_id = field(custom, "id")
            remaining_tiles = [tile for tile in field(before_delete, "tiles")
                               if field(tile, "workspace") != custom_id]
            expect_registry(before_delete, deleted, workspaces=stock + [survivor],
                            tiles=remaining_tiles)

        # Reopening the daemon against the same state directory must load the
        # saved deletion, not just bootstrap the stock workspaces again.
        s.stop()
        s.start()
        assert s.rpc("workspace") == deleted, "Deletion did not survive daemon restart"
        with closing(Terminal(s, width=80)) as t:
            t.capture("restarted", [connected, "Overview"])
            t.palette("Switch to Workspace 2")
            t.capture("list-after-restart", ["Workspace 2: active", "Overview", "Testing"],
                      absent=["Workspace 1"])
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
