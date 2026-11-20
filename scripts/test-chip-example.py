#!/usr/bin/env python3
"""Exercise the real example project CLI through a fresh Silver daemon and terminal.

Run after building Silver's daemon/main.exe and terminal/main.exe and the example's
asics/fifo_demo/cli/project.exe. The example must have its ASIC companion configured.
Uses private daemon state and a temporary bundle store. --prepare also writes
a verified bundle to the project preparation store. --synthesize additionally
runs the example's configured synthesis toolchain and retains its execution.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("resource_session", ROOT / "scripts/test-resource-inspector.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--example", type=Path, default=ROOT.parent / "hardcaml_asic_example")
    parser.add_argument("--provider", type=Path, default=ROOT.parent / "hardcaml_asic/_build/install/default/bin/hardcaml-asic-flow")
    parser.add_argument("--daemon", type=Path, default=ROOT / "_build/default/daemon/main.exe")
    parser.add_argument("--client", type=Path, default=ROOT / "_build/default/terminal/main.exe")
    launch = parser.add_mutually_exclusive_group()
    launch.add_argument("--prepare", action="store_true", help="also test Silver's fresh rebuild and emission into the configured preparation store")
    launch.add_argument("--synthesize", action="store_true", help="launch actual two-slot synthesis using the configured project tools")
    launch.add_argument("--check-registered", metavar="ID",
                        help="select an authored chip through the Overview picker and verify its synthesis plan; no launch")
    args = parser.parse_args()
    args.outer_timeout = 60
    example, provider = args.example.resolve(), args.provider.absolute()
    cli = example / "_build/default/asics/fifo_demo/cli/project.exe"
    sys.path.insert(0, str(ROOT / "test"))
    from support.terminal import Terminal

    with tempfile.TemporaryDirectory(prefix="silver-chip-example-") as tmp:
        base = Path(tmp)
        fs, session = g.native_setup(args, base, provider)
        session.root = example
        session.env.update(SILVER_ASIC_PROVIDER=str(provider), GIT_OPTIONAL_LOCKS="0")
        term = None
        try:
            session.start()
            def rpc(action):
                return session.rpc("asic", action, wait=True)

            term = Terminal(session)
            term.capture("startup", ["Overview"])
            # Open the picker on a fresh session without issuing a Discover RPC.
            deadline = time.monotonic() + args.outer_timeout
            catalog = rpc("Get")
            while not fs.field(catalog, "flows"):
                if time.monotonic() >= deadline:
                    raise AssertionError(("startup did not discover ASIC flows", catalog))
                time.sleep(.1)
                catalog = rpc("Get")
            chips = {fs.field(c, "id"): c for c in fs.field(catalog, "chips")}
            assert {"fifo_demo", "program_memory", "sram_budget"} <= chips.keys(), chips
            fifo = fs.field(catalog, "chip_target")[0]
            assert fs.field(fifo, "chip") == "fifo_demo"

            def plan(target):
                selection = [["flow", "standard"], ["profile", "balanced"], ["endpoint", "synthesis"],
                             ["assignments", []], ["chip_target", [target]]]
                preview, = fs.field(rpc(fs.sexp(["Plan", selection])), "preview")
                assert dict(fs.field(preview, "selection")) == dict(selection)
                return json.loads(fs.field(preview, "plan_json"))

            assert plan(fifo)["project_name"] == "controlled_fifo_specimen"
            chip_id = args.check_registered or "sram_budget"
            assert chip_id in chips, ("missing chip in Silver discovery", chip_id, list(chips))
            target = [["chip", chip_id], ["variant", fs.field(chips[chip_id], "default_variant")]]
            overview_screen = term.capture("launch-control", ["Launch chip:", "fifo_demo"])
            for y, line in enumerate(overview_screen.splitlines(), 1):
                if "Launch chip:" in line:
                    x = line.index("Launch chip:") + 1
                    break
            else:
                raise AssertionError("No visible Overview launch chip control")
            click = f"\x1b[<0;{x};{y}"
            os.write(term.master, (click + "M" + click + "m").encode())
            term.capture("overview-target-picker", [chip_id, dict(target)["variant"]])
            os.write(term.master, (chip_id + " " + dict(target)["variant"]).encode())
            term.drain(.15)
            os.write(term.master, b"\r")
            term.drain(.5)
            selected = rpc("Get")
            assert dict(fs.field(selected, "chip_target")[0]) == dict(target)
            if args.check_registered:
                entry, = [row for row in json.loads((example / "hardcaml-asic-targets.json").read_text())["targets"]
                          if row["id"] == chip_id]
                direct = json.loads(subprocess.check_output([
                    example / "_build/default" / entry["executable"], "flow", "plan",
                    "--flow", "standard", "--profile", "balanced", "--endpoint", "synthesis",
                    "--source-root", str(example), "--json"], cwd=example, env=session.env))
                actual = plan(target)
                assert actual["plan_identity"] == direct["plan_identity"], (actual, direct)
                print(f"PASS: Overview selected {chip_id}/{dict(target)['variant']}; "
                      "Silver's synthesis preview matches the directly invoked chip. No launch.")
                return
            def overview(chip, variant):
                screen = term.capture(chip + "-overview", [chip + "/" + variant, "Launch target", "Launch chip", "Endpoint"])
                starts = []
                for label, value in [("Launch chip", chip), ("Variant", variant),
                                     ("Flow", "standard"), ("Profile", "balanced"),
                                     ("Endpoint", "synthesis")]:
                    match = re.search(r"\b" + re.escape(label) + r"\s*:\s*(" + re.escape(value) + r")\b", screen)
                    assert match, (label, screen)
                    starts.append(match.start(1) - screen.rfind("\n", 0, match.start(1)) - 1)
                assert len(set(starts)) == 1, (starts, screen)
                return screen

            overview("sram_budget", dict(target)["variant"])
            plan_json = plan(target)
            assert plan_json["project_name"] == "sram_budget", plan_json["project_name"]
            term.palette("Plan ASIC standard / balanced")
            term.capture("plan-form", ["synthesis", "PLAN ENDPOINT"])
            os.write(term.master, b"\r")
            term.drain(.5)
            intent, = fs.field(rpc("Get"), "fresh_intent")
            inputs = dict(fs.field(intent, "selection"))
            assert inputs["endpoint"] == "synthesis" and dict(inputs["chip_target"][0]) == dict(target)
            cli_args = ["flow", "emit", "--chip", "sram_budget", "--variant", dict(target)["variant"],
                        "--flow", "standard", "--profile", "balanced", "--endpoint", "synthesis",
                        "--expected-plan-identity", plan_json["plan_identity"],
                        "--results-root", str(base / "store"), "--json"]
            receipt = json.loads(subprocess.check_output([cli, *cli_args], cwd=example, env=session.env))
            bundle = Path(receipt["output_dir"])
            manifest = json.loads((bundle / "manifest.json").read_text())
            assert receipt["bundle_identity"] == plan_json["bundle_identity"] == manifest["identity"]
            rows = {r["id"]["display"]: r["selection"] for r in manifest["resource_snapshot"]["resources"]}
            assert set(rows) == {"bank0", "bank1", "bank2"}
            assert [rows[n]["implementation"]["kind"] for n in sorted(rows)] == ["macro", "macro", "flops"]
            assert rows["bank2"]["reason"]["kind"] == "budget_exhausted"
            assert rows["bank2"]["reason"]["limit"] == 2
            if args.prepare or args.synthesize:
                staged = rpc(fs.sexp(["Stage_fresh", ["selection", fs.field(intent, "selection")],
                                      ["elaboration_only", "false" if args.synthesize else "true"],
                                      ["expected_plan_identity", [plan_json["plan_identity"]]]]))
                fresh_id = fs.field(fs.field(staged, "fresh_intent")[0], "id")
                key = f"chip-example-{time.time_ns()}"
                rpc(fs.sexp(["Launch_fresh", ["key", key], ["intent_id", fresh_id]]))
                deadline = time.monotonic() + (600 if args.synthesize else 120)
                while True:
                    workflows = [w for w in fs.field(rpc("Get"), "workflows") if fs.field(w, "key") == key]
                    if workflows and fs.field(workflows[0], "phase") in ("Completed", "Failed", "Cancelled", "Interrupted"):
                        break
                    if time.monotonic() >= deadline:
                        raise AssertionError("fresh build/emission did not finish")
                    time.sleep(.2)
                w = workflows[0]
                assert fs.field(w, "phase") == "Completed", fs.field(w, "error")
                prepared, = fs.field(w, "prepared")
                assert fs.field(prepared, "bundle_identity") == manifest["identity"]
                assert bool(fs.field(w, "run")) == args.synthesize
                if args.synthesize:
                    run, = fs.field(w, "run")
                    print("Synthesized two_slot via Silver:", fs.field(run, "id"), flush=True)
                    found = rpc(fs.sexp(["Resources", ["Load", ["target", ["Run", run]], ["refresh", "true"]]]))
                    state = g.resource_snapshot(fs, found)
                    src = next(s for s in fs.field(state, "sources") if fs.field(s, "target") == ["Run", run])
                    index = next(i for i in fs.field(state, "indexes") if fs.field(i, "source_id") == fs.field(src, "id"))
                    statuses = {fs.field(r, "id"): fs.field(r, "synthesis") for r in fs.field(index, "rows")}
                    assert statuses["bank0"] == statuses["bank1"] == "matched", statuses
                    assert statuses["bank2"] != "matched", statuses

            # Inspect the SRAM evidence while FIFO is the launch target.
            rpc(fs.sexp(["Select_chip", fifo]))
            overview("fifo_demo", "default")
            term.palette("Resources: Import emitted bundle")
            term.capture("import-form", ["exact absolute directory"])
            os.write(term.master, os.fsencode(bundle))
            term.drain(.1)
            os.write(term.master, b"\r")
            ws = session.rpc("workspace")
            tile = next(t for t in fs.field(ws, "tiles") if fs.field(t, "kind") == "resources")
            detail = next(t for t in fs.field(ws, "tiles") if fs.field(t, "kind") == "resource-detail"
                          and fs.field(t, "workspace") == fs.field(tile, "workspace"))
            term.capture("resources", ["bank0", "bank1", "bank2", "Decision"], absent=['"atom":'])
            for key in (b"j", b"j"):
                os.write(term.master, key)
                term.drain(.15)
            # No Enter or detail read: the metadata pane follows the highlighted row.
            split = term.capture("fallback-selected", ["Request & requirements", "bank2", "budget exhausted"],
                                 absent=['"atom":'])
            assert re.search(r"Resource:\s+bank2\b", split), split
            def check_layout(label, stacked, selected="bank2"):
                expected = ["╭ resources ", "╭ resource-detail "]
                if selected is not None:
                    expected += ["Request & requirements", selected]
                screen = term.capture(label, expected)
                def locate(title):
                    return next((y, line.index(title)) for y, line in enumerate(screen.splitlines())
                                if title in line)
                ly, lx = locate("╭ resources ")
                dy, dx = locate("╭ resource-detail ")
                assert ((ly < dy and lx == dx) if stacked else
                        (ly == dy and lx < dx)), screen
                if selected is not None:
                    assert re.search(r"Resource:\s+" + re.escape(selected) + r"\b", screen), screen
                    assert "> " + selected in screen, screen

            stack_title = "Resources: Stack list above detail"
            side_title = "Resources: List and detail side by side"
            # Start the layout change in a full-width, in-place detail view
            # (the appearance of an existing single-tile Resources workspace).
            session.mutate(ws, '(Set_tile_hidden (tile %s)(hidden true))' % fs.sexp(fs.field(detail, "id")))
            session.mutate(session.rpc("workspace"), '(Set_zoom (workspace %s)(tile (%s)))' % (
                fs.sexp(fs.field(tile, "workspace")), fs.sexp(fs.field(tile, "id"))))
            term.drain(.2)
            os.write(term.master, b"\r")
            full = term.capture("full-width-detail", ["Request & requirements", "bank2", "Resource verdict:"],
                                absent=["Detail section: inventory", "Section catalog", "Page items:", "Sections: inventory:"])
            columns = []
            for field in ["Synthesis", "Final", "Resource verdict", "Qualification"]:
                m = re.search(re.escape(field) + r": +(\S)", full)
                assert m, (field, full)
                columns.append(m.start(1) - full.rfind("\n", 0, m.start(1)) - 1)
            assert len(set(columns)) == 1, (columns, full)
            module_before = g.resource_snapshot(fs, rpc("Get"))
            term.palette(stack_title)
            check_layout("stacked", True)
            restored = session.rpc("workspace")
            readers = [t for t in fs.field(restored, "tiles") if fs.field(t, "kind") == "resource-detail"
                       and fs.field(t, "workspace") == fs.field(tile, "workspace")]
            assert len(readers) == 1 and fs.field(readers[0], "id") == fs.field(detail, "id")
            assert fs.field(readers[0], "hidden") == "false"
            term.palette(side_title)
            check_layout("side-by-side", False)
            assert g.resource_snapshot(fs, rpc("Get")) == module_before, "layout changed Resources evidence"
            # Zoom the reader for the raw-data check, entering from the list
            # if focus was restored there.
            screen = term.drain(.2)
            if "Resources › resources" in screen:
                os.write(term.master, b"\r")
                term.drain(.2)
            ws = session.rpc("workspace")
            session.mutate(ws, '(Set_zoom (workspace %s)(tile (%s)))' % (
                fs.sexp(fs.field(detail, "workspace")), fs.sexp(fs.field(detail, "id"))))
            term.capture("fallback-detail", ["bank2", "256", "budget exhausted", "Actual implementation"],
                         absent=['"atom":'])
            os.write(term.master, b"\r")
            term.capture("raw", ["RAW METADATA", '"contract"'])
            assert dict(fs.field(rpc("Get"), "chip_target")[0]) == dict(fifo)
            # A tall inventory must stay navigable past one screen. This fixture
            # exercises the provider's historical bundle format without building
            # another chip or borrowing the real example's source identity.
            big = base / "large-inventory"
            big.mkdir()
            fixture = {"project": "scroll_fixture", "top_module": "top", "resources": [
                {"id": f"ram{i:02}", "request": f"((kind ram) (contract ((width 16) (depth {512+i}))))",
                 "requirement": "Flops", "policy": "Default",
                 "selection": "((implementation Flops) (reason Explicit_flops))",
                 "elaborated_as": "Selected_implementation"} for i in range(64)], "files": []}
            fixture["identity"] = hashlib.sha256(json.dumps(fixture, separators=(",", ":")).encode()).hexdigest()
            (big / "manifest.json").write_text(json.dumps(fixture))
            session.mutate(session.rpc("workspace"), '(Set_zoom (workspace %s)(tile ()))' % fs.sexp(fs.field(tile, "workspace")))
            term.drain(.3)
            term.palette("Resources: Import emitted bundle")
            term.capture("large-import", ["exact absolute directory"])
            os.write(term.master, os.fsencode(big))
            term.drain(.1)
            os.write(term.master, b"\r")
            large_screen = term.capture("large-first", ["ram00", "512"], absent=["ram63"])
            # Importing from a focused detail pane can leave focus there. A
            # click on an actual list row explicitly targets list navigation.
            y, line = next((n, line) for n, line in enumerate(large_screen.splitlines(), 1)
                           if "> ram00" in line)
            click = f"\x1b[<0;{line.index('ram00')+1};{y}"
            os.write(term.master, (click + "M" + click + "m").encode())
            term.drain(.2)
            for _ in range(63):
                os.write(term.master, b"j")
            term.capture("large-last", ["ram63", "575"], absent=["ram00"])
            term.palette(stack_title)
            check_layout("stacked-long-list", True, "ram63")
            term.close()
            term = Terminal(session)
            check_layout("restored-stacked-orientation", True, None)
            print("PASS: FIFO and two-slot SRAM plans, emitted bundle identity, three SRAM request outcomes,"
                  " linked 64-row inventory, side-by-side/stacked layout and restored orientation in native Silver.")
        finally:
            if term:
                term.close()
            g.stop_session(session)


if __name__ == "__main__":
    main()
