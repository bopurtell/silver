"""WB-083: real native menu, dispatch, daemon, authoring files and launch selection."""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from test_project_menus_pty import click, send
from test_chip_contexts_pty import FIFO, MEM, Session, Terminal, field, setup, sexp, wait


def fixture_renderer():
    if sys.argv[1] == "describe-flow-authoring":
        print(json.dumps(dict(schema_version=1, recipes=[dict(
            id="librelane_classic_v1", endpoints=["synthesis", "floorplan"])])))
        return
    p = json.loads(sys.argv[2])
    assert p["registered"] and p["owner"] == "asic_program_memory"
    assert p["catalog"]["declaration"]["default"]["flow"] == "standard"
    flow, profile = p["flow_id"], p["profile_id"]
    if sys.argv[1] == "render-flow":
        assert p["recipe"] == "librelane_classic_v1" and p["endpoints"] == ["synthesis"]
        assert profile == "balanced"
        path = f"{p['owner']}/flows/flow_{flow}.ml"
    else:
        assert sys.argv[1] == "render-profile" and p["source_profile"] == "balanced"
        assert p["edits"] == {"TUNE": "delay"}
        path = f"{p['owner']}/flows/{flow}/profiles/{profile}.ml"
    print(json.dumps(dict(schema_version=1, provider="controlled", version="1",
                          files=[dict(path=path, contents=f'let id = "{flow}/{profile}"\n')],
                          manual_registration=False, snippet="Discovered on successful build.")))


def exercise(base, client, daemon):
    root, tools = base / "project", base / "tools"
    setup(root, tools)
    renderer = tools / "hardcaml-asic-starter"
    import shlex
    renderer.write_text("#!/bin/sh\nexec " + shlex.join([sys.executable, "-B",
                        str(Path(__file__).resolve())]) + ' "$@"\n')
    renderer.chmod(0o700)
    manifest = dict(schema_version=1, default_target=FIFO[0], targets=[])
    for chip in (FIFO[0], MEM[0]):
        target = f"asic_{chip}/project.exe"
        manifest["targets"].append(dict(id=chip, executable=target))
        executable = root / "_build/default" / target
        executable.parent.mkdir(parents=True)
        shutil.copy2(root / "project-cli", executable)
        flows = root / f"asic_{chip}/flows"
        (flows / "standard/profiles").mkdir(parents=True)
        (flows / "dune").write_text("; hardcaml-asic flow collection v1\n")
        (flows / "flow_standard.ml").write_text("(* hardcaml-asic profile directory v1 *)\n")
    catalog = root / (MEM[0] + ".json")
    data = json.loads(catalog.read_text())
    entry, = data["declaration"]["entries"]
    entry["methodology"].update(id="standard", configurable=["TUNE"])
    entry["profiles"][0]["assignments"] = [{"key": "TUNE", "value": "area"}]
    data["parameter_descriptors"] = [dict(key="TUNE", type="enum", allowed_values=["area", "delay"])]
    data["declaration"]["default"]["flow"] = "standard"
    catalog.write_text(json.dumps(data))
    (root / "hardcaml-asic-targets.json").write_text(json.dumps(manifest))
    args = SimpleNamespace(client=client, daemon=daemon, outer_timeout=20)
    s = Session(args, base, root)
    s.env["PATH"] = str(tools) + os.pathsep + s.env["PATH"]
    try:
        s.start(daemon_args=["--authoring-root", str(root)])
        with closing(Terminal(s, width=80)) as t:
            t.capture("boot", ["Synthesis: available"])
            target = [["chip", FIFO[0]], ["variant", FIFO[1]]]
            selection = [["flow", "fifo-flow"], ["profile", FIFO[2]], ["endpoint", "synthesis"],
                         ["assignments", []], ["chip_target", [target]]]
            staged = s.rpc("asic", sexp(["Stage_fresh", ["selection", selection],
                           ["elaboration_only", "false"], ["expected_plan_identity", []]]))
            def same_launch():
                current = s.rpc("asic")
                for key in ("chip_target", "fresh_intent", "runs", "workflows"):
                    assert field(current, key) == field(staged, key), key

            def choose(label, *more):
                click(t, t.capture("click-" + str(s.sequence), [label, *more]), label)

            def name_preview(name):
                t.capture("name", ["enter new ID", "Owner chip: program_memory"])
                send(t, name.encode())
                choose("[Preview]")
                return t.capture("preview", ["Owner chip: program_memory", "[Apply]", "[Cancel]"])

            def files():
                return {p.relative_to(root): p.read_bytes()
                        for p in root.glob("asic_*/**/*") if p.is_file()}
            original = files()
            for new_id, apply in (("unused", False), ("timing", True)):
                choose("Project ▾")
                choose("New Flow…")
                choose("Owner: program_memory", "> Owner: fifo")
                choose("librelane_classic_v1")
                choose("[x] floorplan")
                choose("Next: initial profile", "[ ] floorplan")
                choose("[Next]", "balanced")
                screen = name_preview(new_id)
                assert files() == original
                if apply:
                    send(t, b"\r")
                else:
                    click(t, screen, "[Cancel]")
                choose("[Done]", "Source created" if apply else "Preview cancelled")
                if apply:
                    original[Path("asic_program_memory/flows/flow_timing.ml")] = b'let id = "timing/balanced"\n'
                assert files() == original
                same_launch()
            t.palette("Duplicate Profile")
            choose("Owner: program_memory")
            choose("standard/balanced")
            choose("TUNE = area")
            choose("delay")
            choose("Next: new profile ID", "TUNE = delay")
            screen = name_preview("trial")
            click(t, screen, "[Apply]")
            choose("[Done]", "Source created")
            original[Path("asic_program_memory/flows/standard/profiles/trial.ml")] = b'let id = "standard/trial"\n'
            assert files() == original
            same_launch()
            t.palette("Run Flow")
            choose("fifo-flow/fast")
            choose("[Launch]", "synthesis")
            wait(t, lambda: bool(field(s.rpc("asic"), "runs")), "No existing flow launched")
            assert files() == original
    finally:
        s.stop()


def real_starter(base, client, daemon):
    """Installed provider proof: build and rediscover the authored modules in B alone."""
    from test_project_browser_pty import setup as setup_real_project
    root = setup_real_project(base)
    s = Session(SimpleNamespace(client=client, daemon=daemon, outer_timeout=20), base, root)

    def entries(chip):
        cli = root / f"_build/default/asic_{chip}/project.exe"
        doc = json.loads(subprocess.check_output([cli, "flow", "list", "--chip", chip, "--json"], cwd=root))
        return {row["methodology"]["id"]: row for row in doc["declaration"]["entries"]}

    try:
        s.start(daemon_args=["--authoring-root", str(root)])
        with closing(Terminal(s, width=80)) as t:
            t.capture("ready", ["Synthesis: available"])
            def choose(label, *more):
                click(t, t.capture("choose", [label, *more]), label)
            t.palette("New Flow")
            choose("Owner: sram", "> Owner: fifo_demo")
            choose("librelane_classic_v1")
            choose("Next: initial profile")
            choose("[Next]", "balanced")
            t.capture("id", ["enter new ID"])
            send(t, b"timing\r")
            choose("[Apply]", "Owner chip: sram", "registers on successful build")
            choose("[Done]", "Source created")
            t.palette("Duplicate Profile")
            choose("Owner: sram")
            choose("standard/balanced")
            choose("SYNTH_STRATEGY = (methodology default)")
            choose("DELAY 1")
            choose("Next: new profile ID")
            t.capture("id", ["enter new ID"])
            send(t, b"timing_trial\r")
            choose("[Apply]", "Owner chip: sram")
            choose("[Done]", "Source created")
            a = s.rpc("asic")
            assert field(field(a, "chip_target")[0], "chip") == "fifo_demo"
            assert not field(a, "fresh_intent") and not field(a, "runs")
            subprocess.run(["dune", "build", "--root", ".", "asic_sram/project.exe"], cwd=root, check=True)
            b = entries("sram")
            assert b["timing"]["default_profile"] == "balanced"
            assignments = {p["id"]: p["assignments"] for p in b["standard"]["profiles"]}
            assert assignments["timing_trial"] == [{"key": "SYNTH_STRATEGY", "value": "DELAY 1"}]
            assert assignments["balanced"] == [] and b["standard"]["default_profile"] == "balanced"
            assert "timing" not in entries("fifo_demo")
            t.palette("Duplicate Profile")
            choose("Owner: sram")
            t.capture("rebuilt-sources", ["standard/timing_trial", "timing/balanced"])
            assert field(field(s.rpc("asic"), "chip_target")[0], "chip") == "fifo_demo"
    finally:
        s.stop()


if __name__ == "__main__":
    if sys.argv[1] in ("describe-flow-authoring", "render-flow", "render-profile"):
        fixture_renderer()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--client", type=Path, required=True)
        parser.add_argument("--daemon", type=Path, required=True)
        parser.add_argument("--real-starter", action="store_true",
                            help="Use the installed renderer and compile real authored entries.")
        args = parser.parse_args()
        with TemporaryDirectory(prefix="flow-authoring-") as temp:
            (real_starter if args.real_starter else exercise)(
                Path(temp), args.client.resolve(), args.daemon.resolve())
