"""Run the same headless authoring commands locally and against the real daemon."""
import os
import json
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import sys
import tempfile


def exercise(root, endpoint=None):
    root.mkdir()
    marker = root / "dune-project"
    marker.write_text("(lang dune 3.10)\n(name consumer)\n")
    # Headless source and flow authoring must not probe Dune or start discovery.
    guard = root / "no-dune-while-authoring"
    guard.touch()
    flags = ["--root", str(root), "--endpoint", endpoint] if endpoint else []

    def invoke(command, *args, ok=True):
        result = subprocess.run([cli, command, *args, *flags], cwd=root, env=env,
                                text=True, capture_output=True, timeout=30)
        assert (result.returncode == 0) == ok, (args, result)
        return result.stdout + result.stderr

    assert "Preview only" in invoke("new-ip", "accum", "--template", "sample")
    assert set(root.iterdir()) == {marker, guard}
    invoke("new-ip", "accum", "--template", "sample", "--apply")
    library = root / "ip/accum"
    assert (library / "dune").is_file()
    args = ["helper", "--library", "ip/accum"]
    invoke("new-module", *args)
    source = library / "helper.ml"
    assert not source.exists()
    invoke("new-module", *args, "--apply")
    source.write_text("(* user edited this module *)\n")
    invoke("new-module", *args, "--apply", ok=False)
    invoke("new-ip", "accum", "--apply", ok=False)
    assert source.read_text() == "(* user edited this module *)\n"
    assert marker.read_text() == "(lang dune 3.10)\n(name consumer)\n"
    if endpoint:
        invoke("new-module", "oops", "--library", "../", "--apply", ok=False)

    targets = [{"id": id_, "executable": f"asic_{id_}/project.exe"}
               for id_ in ["first", "second"]]
    chip_catalog = root / "hardcaml-asic-targets.json"
    chip_catalog.write_text(json.dumps(dict(schema_version=1, default_target="first", targets=targets)))
    manifest = chip_catalog.read_bytes()
    # No executable for default "first": falling back to the active chip must fail.
    exe = root / "_build/default/asic_second/project.exe"
    exe.parent.mkdir(parents=True)
    compiled = dict(contract="hardcaml-asic.flow-list", schema_version=1, capabilities={},
                    parameter_descriptors=[dict(key="buffer", type="boolean", allowed_values=[False, True])],
                    declaration=dict(contract="hardcaml-asic.flow-catalog", schema_version=1, entries=[
                        dict(methodology=dict(id="standard", configurable=["buffer"]),
                             profiles=[dict(id="balanced", assignments=[dict(key="buffer", value=False)])],
                             default_profile="balanced")]))
    exe.write_text(f"#!{sys.executable}\nimport sys, os\n"
                   "assert sys.argv[1:] == ['flow', 'list', '--chip', 'second', '--json']\n"
                   "assert os.path.isfile('hardcaml-asic-targets.json')\n"
                   f"print({json.dumps(compiled)!r})\n")
    exe.chmod(0o755)
    flows = root / "asic_second/flows"
    flows.mkdir(parents=True)
    stanza = flows / "dune"
    stanza.write_text("; hardcaml-asic flow collection v1\n")
    entry = flows / "flow_standard.ml"
    entry.write_text("(* hardcaml-asic profile directory v1 *)\n")
    args = ["trial", "--chip", "second"]
    assert "Owner chip: second" in invoke("new-flow", *args)
    assert not (flows / "flow_trial.ml").exists()
    assert "Build the owner" in invoke("new-flow", *args, "--apply")
    duplicate = ["timing_trial", "--chip", "second", "--flow", "standard",
                 "--from", "balanced", "--set", "buffer=true"]
    invoke("duplicate-profile", *duplicate, "--apply")
    dst = flows / "standard/profiles/timing_trial.ml"
    dst.write_text("user bytes")
    invoke("duplicate-profile", *duplicate, "--apply", ok=False)
    assert dst.read_text() == "user bytes"
    # Even inside an opted-in collection, an unmarked entry is manual.
    entry.write_text("(* user-owned entry *)\n")
    manual = invoke("duplicate-profile", "manual", *duplicate[1:], "--apply")
    assert "declaration" in manual and "Created 0" in manual
    assert not (dst.parent / "manual.ml").exists()
    assert entry.read_text() == "(* user-owned entry *)\n" and chip_catalog.read_bytes() == manifest
    # An opted-in entry alone cannot register profiles in a hand-written catalog.
    entry.write_text("(* hardcaml-asic profile directory v1 *)\n")
    stanza.write_text("; custom catalog\n")
    assert "Created 0" in invoke("duplicate-profile", "manual", *duplicate[1:], "--apply")
    assert not (dst.parent / "manual.ml").exists()


def exercise_bluespec(root, endpoint=None, *, legacy=False):
    shutil.copytree(bluespec_starter, root)
    (root / ".silver").mkdir()
    manifest = dict(schema_version=1, name=root.name, build_label="//:rtl",
                    test_label="//:simulation")
    if not legacy:
        manifest["language"] = "bluespec-classic"
    (root / ".silver/project.json").write_text(json.dumps(manifest))

    # Write no fixtures after this snapshot: preview should be read-only.
    def snapshot():
        return {p.relative_to(root).as_posix(): p.read_bytes()
                for p in root.rglob("*") if p.is_file()}

    original = snapshot()
    flags = ["--root", str(root), "--endpoint", endpoint] if endpoint else []
    working = root.parent if endpoint else root

    def invoke(command, *args, ok=True):
        result = subprocess.run([cli, command, *args, *flags], cwd=working, env=env,
                                text=True, capture_output=True, timeout=30)
        assert (result.returncode == 0) == ok, (args, result)
        return result.stdout + result.stderr

    root_args = ["top_helper", "--library", "."]
    manual = invoke("new-module", *root_args)
    assert "Manual registration: BUILD.bazel" in manual and "Top_helper.bs" in manual, manual
    assert snapshot() == original
    invoke("new-module", *root_args, "--apply")
    assert "package Top_helper " in (root / "Top_helper.bs").read_text()

    for name, template in [("accum", "sample"), ("blank", "empty")]:
        preview = invoke("new-ip", name, "--template", template)
        assert "Preview only" in preview and f"ip/{name}/BUILD.bazel" in preview, preview
        assert "silver-bluespec-classic" in preview, preview
        assert re.search(rf"ip/{name}/\w+\.bs", preview), preview
        assert not (root / "ip" / name).exists()
        invoke("new-ip", name, "--template", template, "--apply")
        library = root / "ip" / name
        assert 'name = "sources"' in (library / "BUILD.bazel").read_text()
        classic_packages = list(library.glob("*.bs"))
        assert classic_packages
        assert not (library / "dune").exists() and not list(library.glob("*.ml"))
        for package in classic_packages:
            assert re.search(rf"\bpackage\s+{package.stem}\b", package.read_text())
        if name == "accum":
            original_library = snapshot()
            args = ["helper", "--library", "ip/accum"]
            preview = invoke("new-module", *args)
            path = re.search(r"ip/accum/\w+\.bs", preview)
            assert path and "Preview only" in preview, preview
            source = root / path[0]
            assert not source.exists() and snapshot() == original_library
            invoke("new-module", *args, "--apply")
            module_contents = source.read_bytes()
            assert re.search(rf"\bpackage\s+{source.stem}\b", module_contents.decode())
            source.write_text("-- user edited this package\n")
            invoke("new-module", *args, "--apply", ok=False)
            invoke("new-ip", name, "--apply", ok=False)
            assert source.read_text() == "-- user edited this package\n"
            invoke("new-module", "escape", "--library", "../ip/accum", "--apply", ok=False)
    current = snapshot()
    assert all(current[path] == content for path, content in original.items())
    additions = current.keys() - original.keys()
    assert additions == {"Top_helper.bs", "ip/accum/Accum.bs", "ip/accum/BUILD.bazel", "ip/accum/Helper.bs",
                         "ip/blank/Blank.bs", "ip/blank/BUILD.bazel"}, additions
    return {**{path: current[path] for path in additions}, "ip/accum/Helper.bs": module_contents}


def reject_unknown_bazel(root, endpoint=None):
    (root / ".silver").mkdir(parents=True)
    manifest = root / ".silver/project.json"
    manifest.write_text(json.dumps(dict(
        schema_version=1, name="unclassified", build_label="//:rtl", test_label="//:simulation",
    )))
    flags = ["--root", str(root), "--endpoint", endpoint] if endpoint else []
    result = subprocess.run([cli, "new-ip", "would_clobber", "--apply", *flags],
                            cwd=root, env=env, text=True, capture_output=True, timeout=30)
    assert result.returncode != 0 and "bluespec-classic" in result.stderr, result
    assert not (root / "ip").exists()


cli, daemon, fixture, bluespec_starter = (Path(arg).resolve() for arg in sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="silver-author-") as tmp:
    base = Path(tmp)
    renderer = base / "hardcaml-asic-starter"
    # Keep fixture commands independent of the installed provider version.
    flow_renderer = Path(__file__).with_name("test_flow_renderer.py")
    renderer.write_text(f"#!{sys.executable}\n" + flow_renderer.read_text() + "\n" + fixture.read_text())
    renderer.chmod(0o755)
    dune = base / "dune"
    dune.write_text(f"#!{sys.executable}\nimport os, sys\n"
                    "if os.path.exists('no-dune-while-authoring'): sys.exit(97)\n"
                    f"os.execv({shutil.which('dune')!r}, sys.argv)\n")
    dune.chmod(0o755)
    env = {**os.environ, "PATH": str(base) + ":" + os.environ["PATH"]}
    exercise(base / "local")
    local_classic = exercise_bluespec(base / "local-classic")
    reject_unknown_bazel(base / "local-bazel")
    permitted = base / "permitted"
    permitted.mkdir()
    with subprocess.Popen([daemon, "--authoring-root", permitted, "--state-dir", base / "state"],
                          env=env, cwd=base, text=True, stdout=subprocess.PIPE) as proc:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                assert selector.select(15), "daemon did not announce endpoint"
            line = proc.stdout.readline().strip()
            assert line.startswith("silver-daemon listening on "), line
            exercise(permitted / "consumer", line.split()[-1])
            remote_classic = exercise_bluespec(permitted / "classic", line.split()[-1], legacy=True)
            assert remote_classic == local_classic
            reject_unknown_bazel(permitted / "unknown-bazel", line.split()[-1])
        finally:
            proc.terminate()
