#!/usr/bin/env python3
"""Silver FS2v1 adapter for the Bluespec Classic counter bench.

Run from the project root. This script is standalone (Python standard library
only) so a copied starter does not depend on the Silver source tree.
"""

import argparse
import json
from pathlib import Path
import re
import stat
import subprocess
import sys


SUITE = "bluespec-classic"
CASE = "counter-smoke"
DEFAULT_SEED = "42"
TRACE = "counter.vcd"
REPORT = "counter-report.json"
TARGET = "//:bench"
MAX_ARTIFACT_BYTES = 64 * 1024 * 1024  # FS2v1 per-file limit


def sexp(value):
    if isinstance(value, (list, tuple)):
        return "(" + " ".join(map(sexp, value)) + ")"
    return json.dumps(str(value), ensure_ascii=False)


def parse_request(path):
    # This catalog has no free-text parameters or ASIC inputs. All atoms in
    # a valid request are ASCII keys/numbers; support both bare and quoted atoms.
    with path.open(encoding="ascii") as stream:
        text = stream.read(16385)
    if len(text) > 16384:
        raise ValueError("request file is too large")
    tokens = iter(re.findall(r'\(|\)|"(?:\\.|[^"\\])*"|[^\s()"]+|"', text))

    def read(token, depth=0):
        if token in (None, ")", '"') or depth > 6:
            raise ValueError("invalid request S-expression")
        if token == "(":
            values = []
            for child in tokens:
                if child == ")":
                    return values
                values.append(read(child, depth + 1))
            raise ValueError("unclosed request S-expression")
        return json.loads(token) if token.startswith('"') else token

    request = read(next(tokens, None))
    if next(tokens, None) is not None:
        raise ValueError("trailing request data")

    def record(value, fields):
        if not isinstance(value, list) or any(
            not isinstance(pair, list) or len(pair) != 2 or not isinstance(pair[0], str)
            for pair in value
        ):
            raise ValueError("expected a request record")
        result = dict(value)
        if result.keys() != set(fields.split()) or len(result) != len(value):
            raise ValueError("unexpected, missing, or duplicate request record fields")
        return result

    req = record(request, "protocol_version attempt_id selection")
    if req["protocol_version"] != "1":
        raise ValueError("expected simulation-provider protocol v1")
    attempt = req["attempt_id"]
    if not isinstance(attempt, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", attempt):
        raise ValueError("invalid attempt ID")
    selection = record(req["selection"], "suite cases seed parameters asic_inputs")
    if selection["suite"] != SUITE or selection["cases"] != [CASE]:
        raise ValueError(f"select suite {SUITE} and case {CASE}")
    if selection["parameters"] != [] or selection["asic_inputs"] != []:
        raise ValueError("the counter bench accepts no parameters or ASIC inputs")
    seed = selection["seed"]
    if (not isinstance(seed, str) or not re.fullmatch(r"0|[1-9][0-9]{0,19}", seed)
            or int(seed) >= 2**64):
        raise ValueError("seed must be a canonical unsigned 64-bit decimal")
    return attempt, seed


def catalog():
    return [
        ("protocol_version", 1),
        ("suites", [[
            ("id", SUITE), ("label", "Bluespec Classic"),
            ("cases", [[("id", CASE), ("label", "Counter reset and counting smoke test")]]),
            ("parameters", []), ("default_seed", DEFAULT_SEED),
        ]]),
    ]


class Events:
    def __init__(self, stream, attempt):
        self.stream = stream
        self.attempt = attempt
        self.sequence = 0

    def emit(self, payload):
        self.stream.write(sexp([
            ("protocol_version", 1), ("attempt_id", self.attempt),
            ("sequence", self.sequence), ("payload", payload),
        ]) + "\n")
        self.stream.flush()
        self.sequence += 1

    def artifact(self, path, label, kind, media_type):
        self.emit(["Artifact", [
            ("id", path), ("case_id", [CASE]), ("label", label),
            ("kind", kind), ("media_type", media_type), ("path", path),
        ]])


def bench(trace, seed):
    argv = ["bazel", "run", TARGET, "--", str(trace), seed]
    print(f"Running {TARGET} with seed {seed}", flush=True)
    # Preserve both tool streams as human logs. Only the exact bench marker on
    # stdout is machine-readable, and it is provisional until Bazel exits zero.
    marker = None
    invalid_marker = False
    line_start = True
    try:
        with subprocess.Popen(argv, cwd=Path.cwd(), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE) as child:
            while chunk := child.stdout.readline(16384):
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                if line_start and chunk.startswith(b"RESULT "):
                    if marker is not None or chunk not in (b"RESULT Passed\n", b"RESULT Failed\n"):
                        invalid_marker = True
                    else:
                        marker = chunk[7:-1].decode("ascii")
                line_start = chunk.endswith(b"\n")
            code = child.wait()
    except FileNotFoundError as exc:
        raise RuntimeError("Bazel not found on PATH; install Bazel or Bazelisk") from exc
    if code:
        raise RuntimeError(f"bazel run {TARGET} exited {code}; see the Bazel/bench logs")
    if invalid_marker or marker is None:
        raise RuntimeError("bench must emit exactly one RESULT Passed or RESULT Failed line")
    return marker


def validate_waveform(path):
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise RuntimeError("bench did not write its VCD waveform") from exc
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_ARTIFACT_BYTES:
        raise RuntimeError("bench waveform must be a nonempty regular VCD file up to 64 MiB")
    # The starter's small counter has a short VCD header. Reject obvious
    # non-waveforms (or a header-only dump) without loading the whole trace.
    with path.open("rb") as trace:
        prefix = trace.read(65536)
    header = re.search(rb"(?m)^[ \t]*\$enddefinitions\s+\$end\b", prefix)
    if (header is None or not re.search(rb"(?m)^[ \t]*\$var\s", prefix[:header.start()])
            or not re.search(rb"(?m)^[ \t]*#[0-9]+[ \t]*\r?$", prefix[header.end():])):
        raise RuntimeError("bench waveform is missing VCD declarations or timestamps")


def report(directory, seed, outcome, diagnostic=None):
    evidence = dict(case=CASE, target=TARGET, seed=seed, outcome=outcome)
    if diagnostic is not None:
        evidence["diagnostic"] = diagnostic
    with (directory / REPORT).open("x", encoding="utf-8") as stream:
        json.dump(evidence, stream, indent=2)
        stream.write("\n")


def run(args):
    attempt, seed = parse_request(args.request)
    directory = args.artifact_dir.resolve(strict=True)
    with args.events.open("a", encoding="utf-8", newline="\n") as stream:
        events = Events(stream, attempt)
        events.emit("Started")
        events.emit(["Case_started", CASE])

        trace = directory / TRACE
        try:
            if trace.exists() or trace.is_symlink():
                raise RuntimeError("waveform path already exists; expected a fresh artifact directory")
            outcome = bench(trace, seed)
            validate_waveform(trace)
        except (OSError, RuntimeError) as exc:
            report(directory, seed, "Incomplete", str(exc))
            events.artifact(REPORT, "Counter bench diagnostic", "failure-report", "application/json")
            raise

        message = "Counter bench checks failed; see the bench logs" if outcome == "Failed" else None
        report(directory, seed, outcome, message)
        events.artifact(TRACE, "Counter waveform", "waveform", "text/vcd")
        events.artifact(REPORT, "Counter bench result",
                        "failure-report" if message else "report", "application/json")
        events.emit(["Case_finished", [
            ("case_id", CASE), ("status", outcome), ("message", [message] if message else []),
        ]])
        events.emit(["Finished", outcome])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["discover", "run"])
    parser.add_argument("--protocol-version", required=True, choices=["1"])
    parser.add_argument("--request", type=Path)
    parser.add_argument("--events", type=Path)
    parser.add_argument("--artifact-dir", type=Path)
    args = parser.parse_args()
    if args.operation == "discover":
        print(sexp(catalog()))
        return 0
    if not all((args.request, args.events, args.artifact_dir)):
        parser.error("run requires --request, --events and --artifact-dir")
    if not all(path.is_absolute() for path in (args.request, args.events, args.artifact_dir)):
        parser.error("run requires absolute --request, --events and --artifact-dir paths")
    try:
        run(args)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Bluespec Classic provider: {exc}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
