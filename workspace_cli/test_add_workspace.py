"""Append a live-layout template to stock without replacing its default workspaces."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile


cli = Path(sys.argv[1]).resolve()


def run(*args, check=True):
    return subprocess.run([cli, *args], capture_output=True, text=True, check=check)


with tempfile.TemporaryDirectory() as tmp:
    template = Path(tmp, "hierarchy.sexp")
    config = Path(tmp, "desk.sexp")
    template.write_text("""((version 1) (name "Hierarchy desk") (preset ())
      (views (((kind hierarchy) (hidden false)
               (geometry ((x 0) (y 0) (width 42) (height 10)))))))""")
    stock = Path(tmp, "stock.sexp")
    stock.write_text(run("config", "export", "stock").stdout)
    config.write_text(run("config", "add-workspace", "-key", "scratch", template).stdout)
    summary = run("config", "validate", config).stdout
    def count(text):
        return int(re.search(r"(\d+) workspaces", text)[1])
    assert count(summary) == 1 + count(run("config", "validate", stock).stdout)
    assert "Hierarchy desk" in config.read_text() and "hierarchy" in config.read_text()
    for flags in (["-base", config], ["-window-key", "missing"]):
        failed = run("config", "add-workspace", *flags, "-key", "scratch", template, check=False)
        assert failed.returncode != 0 and not failed.stdout, failed
