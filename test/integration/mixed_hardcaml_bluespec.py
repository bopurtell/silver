#!/usr/bin/env python3
"""Opt-in Dune/Hardcaml/BSC/Verilator check using a disposable project copy."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile


EXAMPLE = Path(__file__).resolve().parents[2] / "examples" / "mixed_hardcaml_bluespec"


def dune(project, *args, failure=None):
    result = subprocess.run(
        ["dune", *args], cwd=project, capture_output=True, text=True, timeout=180,
    )
    output = result.stdout + result.stderr
    if failure is None:
        if result.returncode:
            raise RuntimeError(output)
    elif not result.returncode or failure not in output:
        raise RuntimeError(f"expected simulation failure {failure!r}; got:\n{output}")
    return output


def exercise(project):
    dune(project, "build", "@rtl")
    built = project / "_build" / "default"
    top = (built / "mixed_top.v").read_text(encoding="ascii")
    child = (built / "mkCounterIp.v").read_text(encoding="ascii")
    if not re.search(r"\bmkCounterIp\s+u_counter_ip\s*\(", top):
        raise RuntimeError("Hardcaml top did not emit the external IP instance")
    if "module mkCounterIp" not in child:
        raise RuntimeError("BSC did not emit the child module")
    output = dune(project, "runtest")
    if "PASS: mixed top checked " not in output:
        raise RuntimeError(f"missing checked simulation result:\n{output}")
    trace = (built / "mixed.vcd").read_text(encoding="ascii")
    if "$scope module u_counter_ip $end" not in trace or "#15\n" not in trace:
        raise RuntimeError("mixed waveform did not trace the IP instance and clocked run")

    # Mutate only the external RTL source; the unchanged mixed top and bench
    # must rebuild and observe the wrong count on the first enabled edge.
    ip = project / "CounterIp.bs"
    source = ip.read_text(encoding="ascii")
    if source.count("value + 1") != 1:
        raise RuntimeError("cannot find the child increment to mutate")
    ip.write_text(source.replace("value + 1", "value + 2"), encoding="ascii")
    dune(project, "runtest", failure="cycle 2: expected ip_count=1 sampled_count=0; got 2 and 0")


def main():
    scratch_parent = Path("/tmp/opencode")
    with tempfile.TemporaryDirectory(
        prefix="mixed-hardcaml-bluespec-", dir=scratch_parent if scratch_parent.is_dir() else None
    ) as temporary:
        project = Path(temporary) / "project"
        shutil.copytree(EXAMPLE, project, ignore=shutil.ignore_patterns("_build"))
        exercise(project)
    print("PASS: mixed Hardcaml/Bluespec simulation, waveform, and child mutation")


if __name__ == "__main__":
    main()
