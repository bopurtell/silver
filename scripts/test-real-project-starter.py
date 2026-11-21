#!/usr/bin/env python3
"""Cross-package acceptance: real starter -> Silver daemon -> ordinary Dune project.

Build daemon/main.exe, put the matching hardcaml-asic-starter on PATH, and
activate the provider's OCaml libraries before running this script.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import urllib.request

from fixtures.simulation_fixture_wire import parse, sexp


def exercise(endpoint, dest, author, flow_recipe=None):
    with urllib.request.urlopen(endpoint + "/api/hello", timeout=10) as response:
        instance = dict(parse(response.read().decode()))["instance_id"]

    def rpc(route, **fields):
        body = sexp([("instance_id", instance), *fields.items()]).encode()
        request = urllib.request.Request(endpoint + "/api/v1/" + route, body, {
            "Content-Type": "application/sexp", "X-Workbench-Protocol": "1"})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = parse(response.read().decode())
        assert result[0] == "Ok", result
        return result[1]

    def preview():
        target = [("destination", str(dest)), ("project", []), ("object_id", [])]
        op = [("recipe", "hardcaml-asic-starter-v1"), ("name", "sample"), ("target", target)]
        result = rpc("authoring", operation=["Preview", op])
        assert result[0] == "Previewed", result
        return dict(result[1])

    rendered = json.loads(subprocess.check_output(
        ["hardcaml-asic-starter", "render", "--name", "sample"], cwd=dest))
    files = {f["path"]: f["contents"].encode() for f in rendered["files"]}
    assert "dune-project" in files and len(files) > 1
    first = preview()
    expected = {dict(f)["path"] for f in first["files"]}
    assert set(first["new_files"]) == expected
    assert files.keys() <= expected
    assert rpc("authoring", operation=["Cancel", ("preview_id", first["preview_id"])]) == "Cancelled"
    assert not list(dest.iterdir())
    plan = preview()
    result = rpc("authoring", operation=["Apply", ("preview_id", plan["preview_id"])])
    assert result[0] == "Applied", result
    catalog_file = "hardcaml-asic-targets.json"
    registration, = plan["registration"]
    assert dict(registration)["path"] == catalog_file
    published = {p.relative_to(dest).as_posix(): p.read_bytes()
                 for p in dest.rglob("*") if p.is_file()}
    assert set(dict(result[1:])["created_files"]) == published.keys() == expected | {catalog_file}
    assert all(published[path] == data for path, data in files.items())
    assert json.loads(published[catalog_file])["default_target"] == "sample"
    rpc("open-project", root=str(dest), environment="Inherit_daemon")
    assert not dict(rpc("snapshot"))["jobs"], "opening a starter unexpectedly submitted a job"
    subprocess.run(["dune", "runtest", "--root", str(dest), "-j", "1"], cwd=dest, check=True)
    if author:
        def run(*argv):
            return subprocess.check_output(argv, cwd=dest, text=True, timeout=120)

        def publish(cmd, *args):
            return run(author, cmd, "--endpoint", endpoint, "--root", str(dest), *args)

        def catalog():
            return json.loads(run("hardcaml-asic-targets", "list"))

        base_catalog = catalog()
        assert base_catalog["default_target"] == "sample"
        assert [t["id"] for t in base_catalog["targets"]] == ["sample"]
        edited = dest / "asic_sample/chip.ml"
        edited.write_text(edited.read_text() + "\n(* Owner edit; keep this byte-for-byte. *)\n")
        original = {p: (dest / p).read_bytes() for p in expected if p != "hardcaml-asic-targets.json"}
        publish("new-ip", "invert", "--template", "sample", "--apply")
        ip = {p: p.read_bytes() for p in (dest / "ip").rglob("*") if p.is_file()}
        assert ip
        publish("new-chip", "chip_b", "--from-ip", "ip/invert",
                "--mapping", "ui_in:uo_out:comb8", "--apply")
        assert catalog()["default_target"] == "sample"
        assert [t["id"] for t in catalog()["targets"]] == ["sample", "chip_b"]
        assert all(p.read_bytes() == data for p, data in ip.items())
        assert all((dest / p).read_bytes() == data for p, data in original.items())
        registered = (dest / "hardcaml-asic-targets.json").read_bytes()
        publish("new-chip", "unlisted", "--no-register", "--apply")
        assert (dest / "hardcaml-asic-targets.json").read_bytes() == registered
        run("dune", "build", "--root", str(dest), "-j", "1", "asic_unlisted/project.exe",
            *(t["executable"] for t in catalog()["targets"]))
        run("dune", "runtest", "--root", str(dest), "-j", "1")
        assert not dict(rpc("snapshot"))["jobs"], "authoring unexpectedly submitted a job"
        if flow_recipe:
            exercise_flows(dest, publish, catalog(), flow_recipe)


def exercise_flows(project, publish, catalog, recipe):
    """Only new source files may change; rebuild B and A away from all Silver state."""
    def source_files(root):
        contents = {}
        for directory, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in ("_build", "_flow_results")]
            for filename in files:
                p = Path(directory) / filename
                contents[p.relative_to(root)] = p.read_bytes()
        return contents

    def single_add(before, after, suffix):
        added = after.keys() - before.keys()
        assert len(added) == 1 and next(iter(added)).as_posix().endswith(suffix), added
        assert all(after[p] == data for p, data in before.items())

    before = source_files(project)
    flow = ["new-flow", "explore", "--chip", "chip_b", "--recipe", recipe]
    publish(*flow)
    assert source_files(project) == before, "preview wrote source"
    publish(*flow, "--apply")
    with_flow = source_files(project)
    single_add(before, with_flow, "/flow_explore.ml")
    publish("duplicate-profile", "timing_trial", "--chip", "chip_b",
            "--flow", "standard", "--from", "balanced", "--apply")
    with_profile = source_files(project)
    single_add(with_flow, with_profile, "/flows/standard/profiles/timing_trial.ml")

    # Copy authored source only, not .workbench, cached executables, or session data.
    with tempfile.TemporaryDirectory(prefix="silver-flow-clean-") as tmp:
        clean = Path(tmp)
        for path, content in with_profile.items():
            if path.parts[0].startswith("."):
                continue
            out = clean / path
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(content)
        executables = {e["id"]: e["executable"] for e in catalog["targets"]}
        subprocess.run(["dune", "build", "--root", str(clean), "-j", "1",
                        *executables.values()], cwd=clean, check=True)
        for chip in ("chip_b", "sample"):
            exe = clean / "_build/default" / executables[chip]
            declaration = json.loads(subprocess.check_output(
                [exe, "flow", "list", "--json"], cwd=clean))["declaration"]
            flows = {e["methodology"]["id"]: e for e in declaration["entries"]}
            assert ("explore" in flows) == (chip == "chip_b"), (chip, flows.keys())
            profiles = {p["id"] for p in flows["standard"]["profiles"]}
            assert ("timing_trial" in profiles) == (chip == "chip_b"), (chip, profiles)
            assert declaration["default"] == dict(flow="standard", profile="balanced")
        print("Clean Dune build verified chip-local flow/profile additions and unchanged defaults.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", type=Path, default=Path(__file__).resolve().parents[1]
                        / "_build/default/daemon/main.exe")
    parser.add_argument("--author", type=Path, help="Also verify adding registered and unlisted chips via this silver-author")
    parser.add_argument("--flow-recipe", help="With --author, test chip-scoped flow authoring and a clean source-only rebuild")
    args = parser.parse_args()
    if args.flow_recipe and not args.author:
        parser.error("--flow-recipe requires --author")
    if not shutil.which("hardcaml-asic-starter"):
        parser.error("matching hardcaml-asic-starter must be on PATH")
    with tempfile.TemporaryDirectory(prefix="silver-starter-") as tmp:
        root = Path(tmp)
        dest = root / "sample"
        dest.mkdir()
        with subprocess.Popen([args.daemon.resolve(), "--authoring-root", str(dest),
                               "--state-dir", str(root / "state")], cwd=root,
                              text=True, stdout=subprocess.PIPE) as daemon:
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(daemon.stdout, selectors.EVENT_READ)
                    assert selector.select(20), "daemon did not announce endpoint"
                line = daemon.stdout.readline().strip()
                assert line.startswith("silver-daemon listening on "), line
                exercise(line.split()[-1], dest, args.author and args.author.resolve(), args.flow_recipe)
            finally:
                daemon.terminate()
    print("Real starter preview, cancel, create, open, and Dune tests passed.")


if __name__ == "__main__":
    main()
