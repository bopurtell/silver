#!/usr/bin/env python3
"""Exercise the real example project CLI through a fresh Silver daemon and terminal.

Run after building Silver's daemon/main.exe and terminal/main.exe and the example's
asics/fifo_demo/cli/project.exe. The example must have its ASIC companion configured.
Uses private daemon state and a temporary bundle store. --prepare also writes
a verified bundle to the project preparation store. --synthesize additionally
runs the example's configured synthesis toolchain and retains its execution.
"""
import argparse
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

            catalog = rpc("Discover")
            chips = {fs.field(c, "id"): c for c in fs.field(catalog, "chips")}
            assert {"fifo_demo", "program_memory", "sram_budget"} <= chips.keys(), chips
            fifo = fs.field(catalog, "chip_target")[0]
            assert fs.field(fifo, "chip") == "fifo_demo"
            term = Terminal(session)
            term.capture("startup", ["Overview"])

            def plan(target):
                selection = [["flow", "standard"], ["profile", "balanced"], ["endpoint", "synthesis"],
                             ["assignments", []], ["chip_target", [target]]]
                preview, = fs.field(rpc(fs.sexp(["Plan", selection])), "preview")
                assert dict(fs.field(preview, "selection")) == dict(selection)
                return json.loads(fs.field(preview, "plan_json"))

            assert plan(fifo)["project_name"] == "controlled_fifo_specimen"
            budget_chip = chips["sram_budget"]
            target = [["chip", "sram_budget"], ["variant", fs.field(budget_chip, "default_variant")]]
            term.palette("Select launch target: sram_budget / " + dict(target)["variant"])
            selected = rpc("Get")
            assert dict(fs.field(selected, "chip_target")[0]) == dict(target)
            def overview(chip, variant):
                screen = term.capture(chip + "-overview", [chip, variant, "Launch chip", "Endpoint"])
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
            session.mutate(ws, '(Set_zoom (workspace %s)(tile (%s)))' % (
                fs.sexp(fs.field(tile, "workspace")), fs.sexp(fs.field(tile, "id"))))
            term.capture("resources", ["bank0", "bank1", "bank2", "Inspecting design", dict(target)["variant"]], absent=['"atom":'])
            for key in (b"j", b"j", b"\r"):
                os.write(term.master, key)
                term.drain(.15)
            term.capture("fallback-detail", ["Resource: bank2", "256 words", "budget exhausted"],
                         absent=['"atom":'])
            os.write(term.master, b"\r")
            term.capture("raw", ["RAW METADATA", '"contract"'])
            assert dict(fs.field(rpc("Get"), "chip_target")[0]) == dict(fifo)
            print("PASS: FIFO and two-slot SRAM plans, emitted bundle identity, three SRAM request outcomes,"
                  " independent resource inspection in native Silver.")
        finally:
            if term:
                term.close()
            g.stop_session(session)


if __name__ == "__main__":
    main()
