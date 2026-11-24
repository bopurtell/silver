#!/usr/bin/env python3
"""Opt-in build/simulation test for a Classic IP Bazel subpackage."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


STARTER = Path(__file__).resolve().parents[2] / "examples" / "bluespec_classic"
IP_LABEL = "//ip/counter_step:sources"


def empty_module(package):
    return f"""\
package {package} ({package}(..), mk{package}) where

interface {package} =
  result :: Bit 8

mk{package} :: Module {package}
mk{package} = module
  interface
    result = 0
"""


def edit(path, *replacements):
    source = path.read_text(encoding="ascii")
    for before, after in replacements:
        if source.count(before) != 1:
            raise ValueError(f"{path.name}: expected {before!r} exactly once")
        source = source.replace(before, after)
    path.write_text(source, encoding="ascii")


def add_ip(project, author):
    """Create an IP library plus a module added under the same owner."""
    ip = project / "ip" / "counter_step"
    if author:
        manifest = project / ".silver" / "project.json"
        manifest.parent.mkdir(exist_ok=True)
        manifest.write_text(json.dumps(dict(
            schema_version=1, name="ip-test", language="bluespec-classic",
            build_label="//:rtl", test_label="//:simulation",
        )), encoding="ascii")
        for args in [("new-ip", "counter_step", "--template", "empty"),
                     ("new-module", "step_logic", "--library", "ip/counter_step")]:
            subprocess.run([author, *args, "--root", str(project), "--apply"],
                           cwd=project, check=True, timeout=30)
    else:
        ip.mkdir(parents=True)
        (ip / "BUILD.bazel").write_text(
            """\
filegroup(
    name = "sources",
    srcs = glob(["*.bs"], allow_empty = False),
    visibility = ["//visibility:public"],
)
""",
            encoding="ascii",
        )
        for package in ("Counter_step", "Step_logic"):
            (ip / f"{package}.bs").write_text(empty_module(package), encoding="ascii")

    edit(ip / "Counter_step.bs", ("result = 0", "result = 1"))
    edit(
        ip / "Step_logic.bs",
        ("where\n", "where\n\nimport Counter_step\n"),
        ("mkStep_logic ::", "{-# properties mkStep_logic = { synthesize, alwaysReady } #-}\n"
                            "mkStep_logic ::"),
        ("= module\n", "= module\n  increment <- mkCounter_step\n"),
        ("result = 0", "result = increment.result"),
    )
    edit(
        project / "Counter.bs",
        ("where\n", "where\n\nimport Step_logic\n"),
        ("<- mkReg 0\n", "<- mkReg 0\n  stepIp <- mkStep_logic\n"),
        ("value + 1", "value + stepIp.result"),
    )
    return ip


def bazel(project, *args, failure=None):
    result = subprocess.run(
        ["bazel", "--batch", f"--output_base={project.parent / 'bazel-output'}", *args],
        cwd=project, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180,
    )
    output = result.stdout + result.stderr
    if failure is None:
        if result.returncode:
            raise RuntimeError(output)
    elif not result.returncode or not re.search(failure, output):
        raise RuntimeError(f"expected Bazel failure matching {failure!r}; got:\n{output}")
    return output


def exercise(project, author):
    ip = add_ip(project, author)
    # Local spawn can see the undeclared file on disk. It must still be
    # invisible to BSC until the filegroup is listed in IP_SOURCES.
    bazel(project, "build", "--spawn_strategy=local", "//:rtl",
          failure=r"(?i)cannot find.*package.*Step_logic")

    build = project / "BUILD.bazel"
    source = build.read_text(encoding="ascii")
    if source.count("IP_SOURCES = [") != 1:
        raise ValueError("starter must declare IP_SOURCES exactly once")
    build.write_text(source.replace("IP_SOURCES = [", f'IP_SOURCES = [\n    "{IP_LABEL}",'),
                     encoding="ascii")
    bazel(project, "build", "//:rtl", "--output_groups=+generated_modules")
    outputs = project / "bazel-bin"
    top = (outputs / "mkCounter.v").read_text(encoding="ascii")
    child = outputs / "rtl_modules" / "mkStep_logic.v"
    if not re.search(r"\bmkStep_logic\s+stepIp\s*\(", top) or not child.is_file():
        raise RuntimeError("top did not instantiate separately synthesized IP")
    original = child.read_bytes()

    first = project / "before.vcd"
    passed = bazel(project, "run", "//:bench", "--", str(first), "42")
    if "RESULT Passed" not in passed.splitlines() or not first.stat().st_size:
        raise RuntimeError(f"expected a passing simulation with a trace:\n{passed}")

    # Change only the library helper, not the child, top, or checker. Both
    # BSC and Verilator must rebuild without a clean or label change.
    edit(ip / "Counter_step.bs", ("result = 1", "result = 2"))
    second = project / "after.vcd"
    failed = bazel(project, "run", "//:bench", "--", str(second), "42")
    if ("RESULT Failed" not in failed.splitlines() or "expected 1, got 2" not in failed
            or not second.stat().st_size or original == child.read_bytes()):
        raise RuntimeError(f"expected mutated dependency to change RTL and fail simulation:\n{failed}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--author", type=Path,
                        help="path to a prebuilt silver-author supporting Classic; otherwise use a fixture")
    args = parser.parse_args()
    author = args.author.resolve(strict=True) if args.author else None
    scratch_parent = Path("/tmp/opencode")
    with tempfile.TemporaryDirectory(
        prefix="bluespec-ip-", dir=scratch_parent if scratch_parent.is_dir() else None
    ) as temporary:
        project = Path(temporary) / "project"
        shutil.copytree(
            STARTER, project,
            ignore=shutil.ignore_patterns("bazel-*", "MODULE.bazel.lock", "*.vcd", "__pycache__"),
        )
        exercise(project, author)
    print("PASS: explicit Classic IP sources, separate synthesis, and dependency mutation")


if __name__ == "__main__":
    main()
