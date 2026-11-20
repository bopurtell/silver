#!/usr/bin/env python3
"""Cross-package acceptance: real starter -> Silver daemon -> ordinary Dune project.

Build daemon/main.exe, put the matching hardcaml-asic-starter on PATH, and
activate the provider's OCaml libraries before running this script.
"""
import argparse
import json
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import urllib.request

from fixtures.fs2_wire import parse, sexp


def exercise(endpoint, dest):
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
    assert set(first["new_files"]) == files.keys()
    assert rpc("authoring", operation=["Cancel", ("preview_id", first["preview_id"])]) == "Cancelled"
    assert not list(dest.iterdir())
    plan = preview()
    result = rpc("authoring", operation=["Apply", ("preview_id", plan["preview_id"])])
    assert result[0] == "Applied", result
    assert set(dict(result[1:])["created_files"]) == files.keys()
    assert {p.relative_to(dest).as_posix(): p.read_bytes()
            for p in dest.rglob("*") if p.is_file()} == files
    rpc("open-project", root=str(dest), environment="Inherit_daemon")
    assert not dict(rpc("snapshot"))["jobs"], "opening a starter unexpectedly submitted a job"
    subprocess.run(["dune", "runtest", "--root", str(dest), "-j", "1"], cwd=dest, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", type=Path, default=Path(__file__).resolve().parents[1]
                        / "_build/default/daemon/main.exe")
    args = parser.parse_args()
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
                exercise(line.split()[-1], dest)
            finally:
                daemon.terminate()
    print("Real starter preview, cancel, create, open, and Dune tests passed.")


if __name__ == "__main__":
    main()
