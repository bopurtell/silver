"""Run the same headless authoring commands locally and against the real daemon."""
import os
import json
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile


def exercise(root, endpoint=None):
    root.mkdir()
    marker = root / "dune-project"
    marker.write_text("(lang dune 3.10)\n(name consumer)\n")
    flags = ["--root", str(root), "--endpoint", endpoint] if endpoint else []

    def invoke(command, *args, ok=True):
        result = subprocess.run([cli, command, *args, *flags], cwd=root, env=env,
                                text=True, capture_output=True, timeout=30)
        assert (result.returncode == 0) == ok, (args, result)
        return result.stdout + result.stderr

    assert "Preview only" in invoke("new-ip", "accum", "--template", "sample")
    assert list(root.iterdir()) == [marker]
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
    # Normal workspace opening can start driver discovery. A flow-authoring root
    # binding and the actual preview/apply must work without invoking Dune at all.
    (root / "no-dune-while-authoring").touch()
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


cli, daemon, fixture = (Path(arg).resolve() for arg in sys.argv[1:])
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
        finally:
            proc.terminate()
