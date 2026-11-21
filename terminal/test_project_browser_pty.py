"""WB-086: permanent project window, real PTY and compiled mutable starter targets.

Run in the Silver opam switch with hardcaml-asic-starter on PATH. --evidence must
name a new directory on disk; set TMPDIR to a disk-backed directory for Dune.
"""
import argparse
from contextlib import closing
import json
from pathlib import Path
import runpy
import subprocess
import sys
from types import SimpleNamespace

from test_project_menus_pty import ROOT, Session, Terminal, click, field, inspect_second, send, sexp


def setup(base, *, extra_profile=False):
    root = base / "project"
    root.mkdir(parents=True)
    for args in [("render", "--name", "fifo_demo"), ("render-target", "--name", "sram"),
                 ("render-ip", "--name", "controlled_fifo", "--template", "sample")]:
        manifest = json.loads(subprocess.check_output(["hardcaml-asic-starter", *args], cwd=root))
        for f in manifest["files"]:
            path = root / f["path"]
            path.parent.mkdir(exist_ok=True, parents=True)
            path.write_text(f["contents"])
    if extra_profile:
        flows = root / "asic_sram/flows"
        # Both the flow AND the source profile are non-default. Give the
        # source an assignment so copying balanced instead is observable.
        (flows / "flow_timing.ml").write_text(
            (flows / "flow_standard.ml").read_text().replace('~id:"standard"', '~id:"timing"'))
        profiles = flows / "timing/profiles"
        profiles.mkdir(parents=True)
        (profiles / "tuned.ml").write_text(
            'open Hardcaml_asic\nlet create () = Flow.Profile.create ~id:"tuned" '
            '~label:"Tuned" ~description:"" ~assignments:[Flow.Parameter.synth_abc_buffering true]\n')
    chips = [dict(id=c, executable=f"asic_{c}/project.exe") for c in ("fifo_demo", "sram")]
    (root / "hardcaml-asic-targets.json").write_text(json.dumps(dict(
        schema_version=1, default_target="fifo_demo", targets=chips)))
    subprocess.run(["dune", "build", "--root", ".", "-j", "2", *(c["executable"] for c in chips)],
                   cwd=root, check=True)
    (root / "hardcaml-workbench-asic.sexp").write_text(sexp([
        ["schema_version", 1], ["project_executable", "_build/default/" + chips[0]["executable"]],
        ["results_root", "_flow_results/workbench/asic"], ["toolchain", "_flow_tools"],
        ["python", []], ["support_tools", []], ["pdk_root", []], ["stage_timeout_seconds", []]]))
    (root / "hardcaml-workbench-preparation.sexp").write_text(sexp([
        ["schema_version", 1], ["build_target", chips[0]["executable"]],
        ["results_root", "_flow_results/workbench/preparation"], ["timeout_seconds", 30]]))
    control = base / "simulation.json"
    control.write_text("{}")
    (root / "hardcaml-workbench-simulation.sexp").write_text(sexp([
        ["schema_version", 1], ["provider_executable", sys.executable],
        ["provider_args", [str(ROOT / "scripts/fixtures/simulation_fault_provider.py"), "--control", str(control),
                           "--calls", str(base / "simulation-calls")]],
        ["discovery_timeout_seconds", 10], ["run_timeout_seconds", 120]]))
    return root


TITLE = "Manage This Project"
LEGACY = ["[Try ", "Project workspace", "Management window"]
INSPECTION = ["> [x] second", "[2 Testing]"]
HINTS = ["[/ filter]", "Enter select", "Esc back"]


def open_browser(t, label, keyboard=False, hints=False):
    if keyboard:
        send(t, b"\x1bOQ")
    else:
        click(t, t.capture(label + "-before", ["Project ▾"]), "Project ▾")
    click(t, t.capture(label + "-menu", [TITLE]), TITLE)
    return t.capture(label + "-window", [TITLE, "Objects", "Actions", "New IP Library",
                                         *(HINTS if hints else ["[Filter]"])],
                     absent=LEGACY + ([] if hints else HINTS))


def stage(s):
    asic = s.rpc("asic")
    target, = field(asic, "chip_target")
    assert field(target, "chip") == "fifo_demo", asic
    selection = [["flow", "standard"], ["profile", "balanced"], ["endpoint", "synthesis"],
                 ["assignments", []], ["chip_target", [target]]]
    staged = s.rpc("asic", sexp(["Stage_fresh", ["selection", selection],
                                ["elaboration_only", "false"], ["expected_plan_identity", []]]))
    intent, = field(staged, "fresh_intent")

    def same_launch():
        after = s.rpc("asic")
        assert field(after, "chip_target") == [target]
        assert field(after, "fresh_intent") == [intent]
        for key in ("runs", "workflows"):
            assert field(after, key) == field(staged, key), key
    return same_launch


def check_frame(screen, *, right, bottom):
    # Inclusive, zero-based PTY coordinates. The frame consumes cells of the
    # original panel, leaving the two-column and one-row workspace margins.
    left, top = 2, 1
    rows = screen.splitlines()
    rule = "─" * (right - left - 1)
    for y, expected in [(top, "╭" + rule + "╮"), (bottom, "╰" + rule + "╯")]:
        assert rows[y][left:right + 1] == expected, (y, screen)
    for y in range(top + 1, bottom):
        assert rows[y][left:left + 1] == rows[y][right:right + 1] == "│", (y, screen)
    # Assert complete controls and footer inside the rails, independently of
    # padding. Adjacent frame cells must not overwrite the first or last glyph.
    header = rows[top + 1][left + 1:right]
    assert TITLE in header and "[Back to inspection]" in header, screen
    assert "For: Project" in rows[bottom - 1][left + 1:right], screen


def compact(t):
    t.capture("compact-inspection", ["Compact: focused tile only"])
    screen = open_browser(t, "compact", keyboard=True)
    check_frame(screen, right=77, bottom=22)  # 76×22 panel at 80×24
    assert "Compact:" in screen.splitlines()[-1], screen
    send(t, b"v")
    screen = t.capture("compact-no-switch", [TITLE, "New IP Library"], absent=LEGACY)
    click(t, screen, "New IP Library")
    t.capture("compact-ip-command", ["Sample behavior template"])
    send(t, b"\x1b")
    screen = t.capture("compact-ip-cancel", [TITLE, "New IP Library", "Back to inspection"])
    # Probe immediately before the Back hitbox, then its first painted cell.
    # Together they catch a one-column shift in either direction.
    back = "[Back to inspection]"
    row, = [line for line in screen.splitlines() if back in line]
    click(t, screen, row[row.index(back) - 1:])  # click() uses the first cell
    screen = t.capture("compact-outside-back", [TITLE, back, "New IP Library"])
    click(t, screen, back)
    t.capture("compact-back", ["Compact: focused tile only"], absent=[TITLE])


def hint_preference(t, *, restarting):
    # Opt-in must work from the unmodified startup focus, including after restart.
    t.capture("restart-ready" if restarting else "preference-ready",
              ["Connection: connected", "Overview › workspaces"])
    if not restarting:
        t.palette("Show project browser control hints")
    screen = open_browser(t, "restart-enabled" if restarting else "enabled", hints=True)
    click(t, screen, "[/ filter]")
    t.capture("enabled-editing", ["Filter: ▏"])
    send(t, b"\x1b")
    screen = t.capture("enabled-committed", HINTS)
    click(t, screen, "Back to inspection")
    if restarting:
        t.palette("Hide project browser control hints")


def exercise(s, t):
    t.capture("wide-connected", ["Connection: connected", "Project ▾"])
    inspect_second(t)
    same_launch = stage(s)

    # Keep the same monitored attempt running throughout both wizards.
    (s.evidence / "simulation.json").write_text('{"mode":"slow"}')
    t.palette("Simulation: Launch selected catalog subset")
    for step in ("CASES", "SEED", "CONFIRM"):
        t.capture("launch-" + step.lower(), ["SIMULATION LAUNCH FORM", step])
        send(t, b"\r")
    t.capture("live-inspection", ["running"])

    def running_job():
        ok, snap = s.raw("/api/v1/snapshot", [["instance_id", s.metadata["instance_id"]]])
        assert ok == "Ok"
        job, = [j for j in field(snap, "jobs") if field(j, "state") == "Running"]
        return field(job, "id")

    job = running_job()
    screen = open_browser(t, "wide")
    check_frame(screen, right=117, bottom=38)  # 116×38 panel at 120×40
    # Behind the panel the live Testing tiles contain text and grid lines.
    # Neither may bleed through the unused space between the lists and footer.
    rows = screen.splitlines()
    last_chip = next(i for i, row in enumerate(rows) if "Chip: sram" in row)
    footer = next(i for i, row in enumerate(rows) if "For: Project" in row)
    assert footer > last_chip + 1 and all(not row[3:t.width - 3].strip()
                                          for row in rows[last_chip + 1:footer]), screen
    # Blanks rendered with a terminal-default background can look correct in
    # the text oracle yet become transparent in the user's terminal.
    Screen = runpy.run_path(str(ROOT / "scripts/test-frontend-composition.py"))["Screen"]
    cells = Screen(t.data, t.width, t.height)
    surface = cells.attrs_for(TITLE)[0][0][1]
    assert surface != "default"
    for y in range(1, t.height - 1):
        for x in range(2, t.width - 2):
            assert cells.cells[y][x][1][1] != "default", (x, y)
    assert all(attr[1] == surface for row in cells.cells[last_chip + 1:footer]
               for _, attr in row[3:t.width - 3])
    click(t, screen, "Chip: sram")
    browse = "Browse flows and profiles"
    screen = t.capture("wide-columns", [browse, "Objects", "Actions"])
    heading, = [r for r in screen.splitlines() if "Objects" in r and "Actions" in r]
    assert heading.index("Objects") < heading.index("Actions"), screen
    row, = [r for r in screen.splitlines() if browse in r]
    # The clicked action's Y coordinate also hits an unrelated object in
    # the left pane. Row-only hit-testing would silently change the owner.
    assert "IP library:" in row[:row.index(browse)], screen
    click(t, screen, browse)
    t.capture("expanded-owner", ["tuned"])
    send(t, b"/sram/timing")
    screen = t.capture("filtered-children", ["balanced", "tuned"])
    click(t, screen, "tuned")
    send(t, b"\t")
    location = [TITLE, "For: sram/timing/tuned", "› Duplicate Profile", "▶ Actions"]

    def location_screen(label):
        screen = t.capture(label, location)
        assert any("Filter" in r and "sram/timing" in r for r in screen.splitlines()), screen
        return screen

    # A successful Apply and a cancelled preview must each return to the
    # committed filter, expanded owner, selected child and selected action.
    for name, apply in (("copy_tuned", True), ("discard_tuned", False)):
        before = location_screen(name + "-before")
        if apply:
            click(t, before, "Duplicate Profile")
        else:
            send(t, b"\r")  # proves focus was restored to Actions
        screen = t.capture(name + "-source", ["sram/timing/tuned", "Next: new profile ID"])
        click(t, screen, "Next: new profile ID")
        t.capture(name + "-id", ["enter new ID", "Owner chip: sram"])
        send(t, (name + "\r").encode())
        screen = t.capture(name + "-preview", ["[Apply]", "[Cancel]", name])
        path = s.root / f"asic_sram/flows/timing/profiles/{name}.ml"
        assert not path.exists()
        click(t, screen, "[Apply]" if apply else "[Cancel]")
        if apply:
            screen = t.capture(name + "-receipt", ["Source created", "[Done]"])
            click(t, screen, "[Done]")
        location_screen(name + "-resumed")
        assert path.exists() == apply, path
        assert running_job() == job
        same_launch()
    send(t, b"\x1b")
    t.capture("live-resumed", ["running", *INSPECTION], absent=[TITLE])
    send(t, b"k")
    t.capture("original-catalog-focus", ["> [x] first", "[2 Testing]"])
    assert running_job() == job
    same_launch()

    build = "asic_sram/project.exe"
    subprocess.run(["dune", "build", "--root", ".", "-j", "2", build], check=True, cwd=s.root)
    catalog = json.loads(subprocess.check_output(
        [s.root / "_build/default" / build, "flow", "list", "--chip", "sram", "--json"], cwd=s.root))
    flow, = [f for f in catalog["declaration"]["entries"] if f["methodology"]["id"] == "timing"]
    profiles = {p["id"]: p["assignments"] for p in flow["profiles"]}
    assert profiles["copy_tuned"] == profiles["tuned"] == [{"key": "SYNTH_ABC_BUFFERING", "value": True}]
    assert "discard_tuned" not in profiles

    # Library commands cover another wizard family and a non-first action.
    # Click it straight from the editing filter, without tabbing to Actions.
    screen = open_browser(t, "library")
    click(t, screen, "[Filter]")
    t.capture("library-editing", ["Filter: ▏"], absent=HINTS)
    send(t, b"ip_controlled_fif")
    t.capture("library-partial", ["Filter: ip_controlled_fif▏"])
    send(t, b"\x1b")
    screen = t.capture("library-committed", ["Filter: ip_controlled_fif"], absent=["▏", *HINTS])
    click(t, screen, "Filter: ip_controlled_fif")
    send(t, b"o")
    lib = "For: ip/controlled_fifo"
    screen = t.capture("library-filter", [lib, "Filter: ip_controlled_fifo▏", "New Chip Target",
                                          "New Module"], absent=HINTS)
    click(t, screen, "New Chip Target")
    t.capture("chip-mapping", ["explicit pin mapping"])
    send(t, b"ui_in:uo_out:comb8\r")
    t.capture("chip-name", ["enter target name"])
    send(t, b"cancelled_chip\r")
    screen = t.capture("chip-preview", ["Chip Target Preview", "[Cancel]"])
    click(t, screen, "[Cancel]")
    screen = t.capture("library-resumed", [TITLE, lib, "Filter: ip_controlled_fifo",
                                           "▶ Actions", "› New Chip Target"])
    assert not (s.root / "asic_cancelled_chip").exists()
    click(t, screen, "New Module")
    t.capture("module-name", ["module name", "ip/controlled_fifo"])
    send(t, b"trial_module\r")
    t.capture("module-preview", ["ip/controlled_fifo/trial_module.ml", "[Apply]"])
    send(t, b"\r")
    t.capture("module-created", ["created", "[Done]"])
    send(t, b"\r")
    t.capture("module-resumed", [TITLE, lib, "Filter: ip_controlled_fifo", "▶ Actions", "› New Module"])
    assert (s.root / "ip/controlled_fifo/trial_module.ml").is_file()
    send(t, b"\x1b")
    t.capture("library-back", ["> [x] first", "[2 Testing]"], absent=[TITLE])
    same_launch()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ["client", "daemon", "evidence"]:
        p.add_argument("--" + name, type=lambda s: Path(s).resolve(), required=True)
    args = p.parse_args()
    args.evidence.mkdir()
    root = setup(args.evidence, extra_profile=True)
    s = Session(SimpleNamespace(client=args.client, daemon=args.daemon, outer_timeout=20), args.evidence, root)
    try:
        s.start(daemon_args=["--authoring-root", str(root)])
        with closing(Terminal(s, width=80, height=24)) as t:
            compact(t)
        with closing(Terminal(s)) as t:
            hint_preference(t, restarting=False)
        with closing(Terminal(s, width=120, height=40)) as t:
            hint_preference(t, restarting=True)
            exercise(s, t)
    finally:
        s.stop()


if __name__ == "__main__":
    main()
