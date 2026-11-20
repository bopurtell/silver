"""Run the same headless authoring commands locally and against the real daemon."""
import os
from pathlib import Path
import selectors
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


cli, daemon, fixture = (Path(arg).resolve() for arg in sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="silver-author-") as tmp:
    base = Path(tmp)
    renderer = base / "hardcaml-asic-starter"
    # Keep fixture commands independent of the installed provider version.
    renderer.write_text(f"#!{sys.executable}\n" + fixture.read_text())
    renderer.chmod(0o755)
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
