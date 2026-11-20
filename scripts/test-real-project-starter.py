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


def exercise(endpoint, dest, author):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", type=Path, default=Path(__file__).resolve().parents[1]
                        / "_build/default/daemon/main.exe")
    parser.add_argument("--author", type=Path, help="Also verify adding registered and unlisted chips via this silver-author")
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
                exercise(line.split()[-1], dest, args.author and args.author.resolve())
            finally:
                daemon.terminate()
    print("Real starter preview, cancel, create, open, and Dune tests passed.")


if __name__ == "__main__":
    main()
