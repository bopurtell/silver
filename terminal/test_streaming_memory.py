#!/usr/bin/env python3
"""Opt-in RSS regression probe; build first, then pass the native executable.

Each export runs in a fresh process under GNU time. Python computes its expected
digest incrementally, outside the measured child. TMPDIR contains all exporter
files and is removed even if the child fails. No whole-trace source is allocated.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def expected_digest(size):
    digest = hashlib.sha256()
    # Same absolute-offset byte definition as the probe, independent implementation.
    pattern = bytes(range(251))
    block = pattern * 256  # 64,256 bytes; integral periods, constant source storage.
    remaining = size
    while remaining >= len(block):
        digest.update(block)
        remaining -= len(block)
    digest.update(block[:remaining])
    return digest.hexdigest()


def measure(executable, size):
    expected = expected_digest(size)
    with tempfile.TemporaryDirectory(prefix="wb040-memory-") as directory:
        root = Path(directory)
        rss_file = root / "rss.txt"
        environment = dict(os.environ, TMPDIR=directory)
        result = subprocess.run(
            ["/usr/bin/time", "-f", "%M", "-o", str(rss_file),
             str(executable), str(size), expected],
            env=environment, text=True, capture_output=True, timeout=180,
        )
        if result.returncode:
            raise RuntimeError(f"Probe failed ({result.returncode}): {result.stdout}\n{result.stderr}")
        evidence = json.loads(result.stdout)
        assert evidence == dict(bytes=size, pages=max(1, (size + 65535) // 65536),
                                sha256=expected, verified=True), evidence
        evidence["peak_rss_kib"] = int(rss_file.read_text().strip())
        rss_file.unlink()
        # Exporter publication and metadata must have been removed by the probe.
        assert not list(root.iterdir()), list(root.iterdir())
        evidence["cleanup_verified"] = True
        return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    executable = args.executable.resolve(strict=True)
    small, large = 1024 * 1024, 64 * 1024 * 1024
    samples = []
    for _ in range(args.repetitions):
        for size in (small, large):
            evidence = measure(executable, size)
            samples.append(evidence)
            print(json.dumps(evidence, sort_keys=True), flush=True)
    # Compare worst large to best small: conservative across fresh-process noise.
    growth = max(s["peak_rss_kib"] for s in samples if s["bytes"] == large) - min(
        s["peak_rss_kib"] for s in samples if s["bytes"] == small)
    # 24 MiB permits GC/runtime headroom, but rejects retaining the extra 63 MiB.
    print(json.dumps(dict(rss_growth_kib=growth, max_growth_kib=24 * 1024,
                          trace_growth_kib=(large - small) // 1024), sort_keys=True))
    assert growth < 24 * 1024, f"RSS growth {growth} KiB exceeds bounded-memory envelope"


if __name__ == "__main__":
    main()
