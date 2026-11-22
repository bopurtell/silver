"""Check workspace strips, navigation, and lifecycle in a real terminal."""
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

GENERIC_BANNER = re.compile(r"^Workspace \d+ \|", re.M)
TABS_PANEL = re.compile(r"\bworkspaces\s+\[project\]|: (?:active|Enter to open)\b", re.I)
PANEL_FRAME = re.compile(r"[┌┐└┘╭╮╰╯╔╗╚╝]")
LIST_FOCUS = re.compile(r" {2,}(?:[\w ]+ [›>] )?workspaces *\Z")
SESSION_FOCUS = re.compile(r" {2,}(?:Testing [›>] )?session *\Z")


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


def goto_and_rename(t, session, target):
    """Use typed queries and Enter, without moving the palette selection by hand."""
    title = "Hierarchy lab"
    before = session.rpc("workspace")
    t.palette("Rename current workspace")
    os.write(t.master, b"\x15discard this\x1b")
    t.capture("rename-cancelled", ["Workspace 2"], absent=["discard this", "COMMAND PALETTE"])
    assert session.rpc("workspace") == before
    t.palette("Rename current workspace")
    os.write(t.master, b"\x15" + title.encode() + b"\r")
    t.capture("renamed-workspace", [re.compile(r"\[\d+ Hierarchy lab\]")],
              absent=["COMMAND PALETTE", "Workspace 2"])
    after = session.rpc("workspace")
    expected = [dict(w, name=title) if field(w, "id") == field(target, "id") else w
                for w in field(before, "workspaces")]
    expect_registry(before, after, workspaces=expected)
    t.palette("goto ov")
    t.capture("goto-overview-abbreviated", ["[1 Overview]"])
    t.palette("goto hier")
    t.capture("goto-renamed-workspace", [re.compile(r"\[\d+ Hierarchy lab\]")])
    assert session.rpc("workspace") == after
    t.palette("Close current workspace")
    t.capture("goto-after-close", ["[1 Overview]"], absent=[re.compile(r"\d+ Hierarchy lab")])
    t.palette("goto hier")
    t.capture("goto-reopened-by-prefix", [re.compile(r"\[\d+ Hierarchy lab\]")])
    expect_registry(after, session.rpc("workspace"), revisions=2)


def expect_strip(t, label, active, *tabs, expected=(), absent=(), empty=False):
    # Require the stock Project menu and numbered chips together on row zero.
    row_zero = re.compile(
        r"\A *Project ▾ *│" + "".join(f"(?=[^\n]*{re.escape(tab)})"
                                      for tab in (f"[{active}]", *tabs)))
    screen = t.capture(label, [row_zero, *expected],
                       absent=[GENERIC_BANNER, TABS_PANEL, "COMMAND PALETTE", *absent])
    rows = screen.splitlines()
    assert not PANEL_FRAME.search(rows[0]), screen
    if empty:
        # Only the global footer may paint below a blank workspace's strip.
        assert not any(row.strip() for row in rows[1:-1]), screen
    return rows[0]


def exercise(args, evidence):
    root = evidence / "project"
    root.mkdir()
    (root / "dune-project").write_text("(lang dune 3.22)\n")
    s = Session(args, evidence, root)
    try:
        s.start()
        with closing(Terminal(s)) as t:
            expect_strip(t, "ready", "1 Overview", "2 Testing",
                         expected=["Connection: connected"])
            before = s.rpc("workspace")
            stock = field(before, "workspaces")
            overview, = (w for w in stock if field(w, "name") == "Overview")
            testing, = (w for w in stock if field(w, "name") == "Testing")
            custom_tab = f"{len(stock) + 1} Workspace 1"
            survivor_tab = f"{len(stock) + 2} Workspace 2"
            renumbered_survivor = f"{len(stock) + 1} Workspace 2"
            close = "Close current workspace"

            t.palette("Create blank workspace")
            top = expect_strip(t, "created-and-active", custom_tab, "1 Overview", "2 Testing",
                               absent=["No visible tiles"], empty=True)
            created = s.rpc("workspace")
            click(t, top.index("Project"), 0)
            menu = t.capture("custom-project-menu", ["/ filter", f"[{custom_tab}]"])
            assert menu.splitlines()[0] == top, menu
            os.write(t.master, b"\x1b")
            expect_strip(t, "custom-project-menu-dismissed", custom_tab,
                         absent=["/ filter"], empty=True)
            assert s.rpc("workspace") == created
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

            # Every list move switches the visible workspace without entering its
            # content, even when several moves arrive in one input batch.
            os.write(t.master, b"k" * (len(stock) - 1))
            expect_strip(t, "list-testing", "2 Testing",
                         expected=["simulation-catalog", LIST_FOCUS])
            os.write(t.master, b"k")
            expect_strip(t, "list-overview", "1 Overview",
                         expected=["Connection: connected", LIST_FOCUS], absent=["simulation-catalog"])
            os.write(t.master, b"j")
            expect_strip(t, "list-testing-again", "2 Testing",
                         expected=["simulation-catalog", LIST_FOCUS])
            os.write(t.master, b"\r")
            expect_strip(t, "entered-testing", "2 Testing",
                         expected=["simulation-catalog", SESSION_FOCUS])
            os.write(t.master, b"k")
            expect_strip(t, "testing-keeps-content-focus", "2 Testing",
                         expected=["simulation-catalog", SESSION_FOCUS])

            # Return to the custom workspace, then click a different tab to
            # verify pointer dispatch uses the hit, not the active workspace.
            t.palette("Switch to Workspace 1")
            top = expect_strip(t, "returned-to-custom", custom_tab, "2 Testing", empty=True)
            click(t, top.index("2 Testing"), 0)
            expect_strip(t, "clicked-testing", "2 Testing", expected=["simulation-catalog"])
            assert s.rpc("workspace") == created, "Navigation unexpectedly changed the registry"

            # Use a second custom workspace to inspect the strip while
            # Workspace 1 is unavailable.
            t.palette("Create blank workspace")
            expect_strip(t, "kept-workspace-active", survivor_tab, custom_tab, empty=True)
            with_survivor = s.rpc("workspace")
            survivor, = (w for w in field(with_survivor, "workspaces")
                         if field(w, "name") == "Workspace 2")
            assert field(survivor, "window") == field(custom, "window"), survivor

            t.palette("Switch to Workspace 1")
            expect_strip(t, "before-custom-close", custom_tab, survivor_tab, empty=True)
            t.palette(close)
            expect_strip(t, "custom-close-fallback", "1 Overview", renumbered_survivor,
                         absent=[custom_tab])
            expect_closed(with_survivor, s.rpc("workspace"), custom)
            t.palette("Switch to Workspace 2")
            expect_strip(t, "tabs-while-custom-closed", renumbered_survivor,
                         "1 Overview", "2 Testing", absent=["Workspace 1"], empty=True)

            t.palette("Reopen workspace: Workspace 1")
            expect_strip(t, "custom-reopened", custom_tab, survivor_tab, empty=True)
            reopened = s.rpc("workspace")
            expect_registry(with_survivor, reopened, revisions=2)
            # Reopening restores list focus; navigation starts at the active
            # workspace, not wherever this strip was last used.
            os.write(t.master, b"j")
            expect_strip(t, "list-next-after-reopen", survivor_tab, custom_tab,
                         expected=[LIST_FOCUS], empty=True)
            os.write(t.master, b"k")
            expect_strip(t, "list-previous-after-reopen", custom_tab, survivor_tab,
                         expected=[LIST_FOCUS], empty=True)
            assert s.rpc("workspace") == reopened, "List navigation changed the registry"

        with closing(Terminal(s)) as t:
            t.capture("tabs-with-custom-reopened", ["Project ▾", custom_tab, survivor_tab])
            for alias, tab in (("ti", "4 Timing"), ("ov", "1 Overview"),
                               ("wa", "3 Waveforms"), ("re", "5 Resources")):
                t.palette(alias)
                expect_strip(t, f"bare-{alias}", tab)
            t.palette("te")
            screen = t.capture("bare-te", ["[2 Testing]", "simulation-catalog"],
                               absent=["COMMAND PALETTE"])
            assert s.rpc("workspace") == reopened, "Navigation unexpectedly changed the registry"
            y, line = next((i, line) for i, line in enumerate(screen.splitlines())
                           if "simulation-catalog" in line)
            click(t, line.index("simulation-catalog"), y)
            testing_focus = "R run checked cases"
            t.capture("testing-catalog-focused", [testing_focus])
            testing_tab = re.compile(r"\b\d+ Testing\b")
            testing_reopened = reopened
            for method, query in (("by-name", "Reopen workspace: Testing"), ("by-bare-te", "te")):
                t.palette(close)
                expect_strip(t, f"testing-closed-{method}", "1 Overview", renumbered_survivor,
                             absent=[testing_tab])
                expect_closed(testing_reopened, s.rpc("workspace"), testing)
                t.palette(query)
                expect_strip(t, f"testing-reopened-{method}", "2 Testing", survivor_tab,
                             expected=[testing_focus])
                after_reopen = s.rpc("workspace")
                expect_registry(testing_reopened, after_reopen, revisions=2)
                testing_reopened = after_reopen

            t.palette("Switch to Workspace 1")
            blank_top = expect_strip(t, "before-add-hierarchy", custom_tab, survivor_tab,
                                     empty=True)
            t.palette("Add hierarchy tile")
            # The hierarchy starts immediately below row zero; navigation has no
            # extra border, title, or body row.
            hierarchy_below = re.compile(r"\A[^\n]*\n[^\n]*\bhierarchy\b", re.I)
            populated_top = expect_strip(t, "hierarchy-below-strip", custom_tab, survivor_tab,
                                         expected=[hierarchy_below, "Tested top / DUT: unknown"])
            assert populated_top == blank_top, (blank_top, populated_top)
            before_delete = s.rpc("workspace")
            custom_id = field(custom, "id")
            hierarchy = field(before_delete, "tiles")[-1]
            assert field(hierarchy, "workspace") == custom_id, hierarchy
            assert field(hierarchy, "kind") == "hierarchy", hierarchy
            expect_registry(testing_reopened, before_delete,
                            next_id=str(int(field(testing_reopened, "next_id")) + 1),
                            tiles=field(testing_reopened, "tiles") + [hierarchy])

            delete = "Delete current workspace"
            confirmation = ["Confirm workspace deletion", "Delete workspace: Workspace 1",
                            "Enter confirms", "Esc cancels"]
            t.palette(delete)
            t.capture("delete-confirmation-before-cancel", confirmation)
            assert s.rpc("workspace") == before_delete, "Opening confirmation changed the registry"
            os.write(t.master, b"\x1b")
            expect_strip(t, "delete-canceled", custom_tab, survivor_tab,
                         expected=[hierarchy_below], absent=confirmation)
            assert s.rpc("workspace") == before_delete, "Cancel changed the registry"

            t.palette(delete)
            t.capture("delete-confirmation-before-enter", confirmation)
            os.write(t.master, b"\r")
            expect_strip(t, "deleted-and-fell-back", "1 Overview", renumbered_survivor,
                         absent=[custom_tab, *confirmation])
            deleted = s.rpc("workspace")
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
            t.capture("restarted", ["Project ▾", "Overview"])
            t.palette("Switch to Workspace 2")
            expect_strip(t, "narrow-strip-after-restart", renumbered_survivor,
                         absent=["Workspace 1"], empty=True)
        with closing(Terminal(s, width=160)) as t:
            t.capture("ready-for-rename-client", ["Project ▾", renumbered_survivor])
            t.palette("Switch to Workspace 2")
            expect_strip(t, "before-rename", renumbered_survivor, empty=True)
            goto_and_rename(t, s, survivor)
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
