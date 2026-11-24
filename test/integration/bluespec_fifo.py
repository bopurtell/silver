#!/usr/bin/env python3
"""Opt-in BSC/Verilator regression: run with python3 test/integration/bluespec_fifo.py.

Uses the starter's local toolchain in a disposable workspace. Does not need
Silver, modify the starter, or leave a Bazel server running.
"""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile


STARTER = Path(__file__).resolve().parents[2] / "examples" / "bluespec_classic"
SIDE_FIFO = """\
package SideFifo (SideFifo(..), mkSideFifo) where

import FIFO

interface SideFifo =
  sample :: Bit 8

{-# properties mkSideFifo = { synthesize, alwaysReady } #-}
mkSideFifo :: Module SideFifo
mkSideFifo = module
  queue :: FIFO (Bit 8) <- mkFIFO
  next :: Reg (Bit 8) <- mkReg 7
  observed :: Reg (Bit 8) <- mkReg 0
  rules
    when True ==> action
      queue.enq next
      next := next + 3
    when True ==> action
      observed := queue.first
      queue.deq
  interface
    sample = observed
"""


def add_fifo(project):
    (project / "SideFifo.bs").write_text(SIDE_FIFO, encoding="ascii")
    path = project / "Counter.bs"
    source = path.read_text(encoding="ascii")
    edits = [
        ("where\n", "where\n\nimport SideFifo\n"),
        ("  count :: Bit 8\n", "  count :: Bit 8\n  probe :: Bit 8\n"),
        ("<- mkReg 0\n", "<- mkReg 0\n  side <- mkSideFifo\n"),
        ("    count = value\n", "    count = value\n    probe = side.sample\n"),
    ]
    for before, after in edits:
        if source.count(before) != 1:
            raise ValueError(f"cannot attach FIFO probe to starter: expected {before!r} once")
        source = source.replace(before, after)
    path.write_text(source, encoding="ascii")


def check_trace(trace):
    declarations, marker, body = trace.read_text(encoding="ascii").partition("$enddefinitions")
    if not marker:
        raise ValueError("VCD has no declarations")
    scopes, vectors = [], {}
    for line in declarations.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "$scope":
            scopes.append(fields[2])
        elif fields[0] == "$upscope":
            scopes.pop()
        elif fields[0] == "$var":
            vectors[".".join([*scopes, fields[4]])] = fields[3]

    expected = [(7 + 3 * i) % 256 for i in range(64)]
    queue, probe = "TOP.mkCounter.side.queue.D_OUT", "TOP.probe"
    transition_times = {}
    for name in (queue, probe):
        if name not in vectors:
            raise ValueError(f"VCD does not declare {name}")
        update = re.compile(r"b([01]+)\s+" + re.escape(vectors[name]))
        timestamp = 0
        changes = []
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("#"):
                timestamp = int(line[1:])
            # Ignore Verilator/BSC initialization before the first reset edge.
            elif timestamp > 0 and (match := update.fullmatch(line)):
                value = int(match[1], 2)
                if not changes or value != changes[-1][1]:
                    changes.append((timestamp, value))
        if name == probe and changes and changes[0][1] == 0:
            changes = changes[1:]  # The probe register resets to zero.
        observed = [value for _, value in changes[:len(expected)]]
        if observed != expected:
            raise ValueError(f"{name}: expected first FIFO values {expected}, got {observed}")
        transition_times[name] = [time for time, _ in changes[:len(expected)]]

    if not all(q < p for q, p in zip(transition_times[queue], transition_times[probe])):
        raise ValueError("FIFO values must appear on D_OUT before the drain rule captures them")


def main():
    scratch_parent = Path("/tmp/opencode")
    with tempfile.TemporaryDirectory(
        prefix="bluespec-fifo-", dir=scratch_parent if scratch_parent.is_dir() else None
    ) as temporary:
        root = Path(temporary)
        project = root / "project"
        shutil.copytree(
            STARTER, project,
            ignore=shutil.ignore_patterns("bazel-*", "MODULE.bazel.lock", "*.vcd", "__pycache__"),
        )
        add_fifo(project)
        trace = root / "fifo.vcd"
        result = subprocess.run(
            ["bazel", "--batch", f"--output_base={root / 'bazel-output'}",
             "run", "//:bench", "--", str(trace), "42"],
            cwd=project, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180,
        )
        if result.returncode or "RESULT Passed" not in result.stdout.splitlines():
            raise SystemExit(
                f"FIFO bench did not pass (Bazel exit {result.returncode}):\n"
                f"{result.stdout}\n{result.stderr}"
            )
        generated = project / "bazel-bin"
        top = (generated / "mkCounter.v").read_text(encoding="ascii")
        child = (generated / "rtl_modules" / "mkSideFifo.v").read_text(encoding="ascii")
        if not re.search(r"\bmkSideFifo\s+side\s*\(", top):
            raise ValueError("top does not instantiate the separately synthesized child")
        if not re.search(r"\bFIFO2\s*#", child):
            raise ValueError("child does not instantiate the standard FIFO2 primitive")
        check_trace(trace)
    print("PASS: separately synthesized Classic FIFO child transferred 64 checked values")


if __name__ == "__main__":
    main()
