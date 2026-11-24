#!/usr/bin/env python3
"""Opt-in Classic Bluespec acceptance against an installed Silver toolchain.

Requires ag, silver-daemon, Bazel, BSC, Verilator, Rust, and a C++ toolchain
on PATH. No installs, source-tree builds, ASIC provider, or PDK. Retains the
generated workspaces, daemon RPCs, logs and VCDs under /tmp/opencode.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True

# Reuse the native harness's daemon lifecycle and FS2 HTTP client.
spec = importlib.util.spec_from_file_location(
    "native_simulation", Path(__file__).with_name("test-native-simulation.py")
)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
Session, field, require = native.Session, native.field, native.require

SEED = "18446744073709551615"


def command(evidence, name, argv, *, cwd, env, timeout):
    log = evidence / f"{name}.log"
    with log.open("w") as out:
        result = subprocess.run(
            argv, cwd=cwd, env=env, timeout=timeout, stdin=subprocess.DEVNULL,
            stdout=out, stderr=subprocess.STDOUT,
        )
    require(result.returncode == 0, f"{name} exited {result.returncode}; see {log}")
    return log.read_text(errors="replace")


def rpc(session, route, **args):
    response = session.raw(
        "/api/v1/" + route, [("instance_id", session.metadata["instance_id"]), *args.items()]
    )
    require(response[0] == "Ok", str(response))
    return response[1]


def job(session, job_id):
    return next(j for j in field(rpc(session, "snapshot"), "jobs") if field(j, "id") == job_id)


def job_logs(session, job_id, name):
    offset, streams = 0, {"Stdout": [], "Stderr": []}
    while True:
        page = rpc(session, "read-log", job=job_id, offset=offset, max_records=256, max_bytes=262144)
        for entry in field(page, "records"):
            streams[field(entry, "stream")].append(field(entry, "data"))
        if field(page, "eof") == "true":
            break
        next_offset = int(field(page, "next_offset"))
        require(next_offset > offset, "job log must advance before EOF")
        offset = next_offset
    streams = {key: "".join(records) for key, records in streams.items()}
    for stream, data in streams.items():
        (session.evidence / f"{name}.{stream.lower()}").write_text(data)
    return streams


def project_action(session, name, target):
    receipt = command(
        session.evidence, name,
        [session.args.client, "--connect", session.url, "--plain",
         "--project-root", str(session.root), "--action", name, "--wait"],
        cwd=session.root, env=session.env, timeout=session.args.timeout,
    )
    submitted = re.search(rf"^Submitted {name} job (\S+)", receipt, re.MULTILINE)
    require(submitted, f"Silver did not issue the {name} job receipt")
    job_id = submitted[1]
    record = job(session, job_id)
    require(field(record, "state") == "Complete" and field(record, "exit_status") == [["Exited", "0"]],
            f"Silver {name} did not complete successfully: {record}")
    logs = job_logs(session, job_id, name)
    require(any(target in data for data in logs.values()), f"{name} logs do not identify {target}")


def discover(session):
    snap = session.api(operation="Discover")
    discovery_id, = field(snap, "discovery_job")
    deadline = time.monotonic() + session.args.timeout
    while True:
        state = field(job(session, discovery_id), "state")
        if state in ("Complete", "Failed", "Cancelled"):
            break
        require(time.monotonic() < deadline, "FS2 Discovery timed out")
        time.sleep(.15)
    snap = session.api()
    require(state == "Complete" and not field(snap, "discovery_error"), f"FS2 Discovery failed: {snap}")
    catalog, = field(snap, "discovery")
    digest, = field(snap, "discovery_digest")
    require(field(catalog, "protocol_version") == "1", "expected FS2 v1 catalog")
    suite, = field(catalog, "suites")
    case, = field(suite, "cases")
    return digest, [
        ("suite", field(suite, "id")), ("cases", [field(case, "id")]), ("seed", SEED),
        ("parameters", [[field(p, "key"), field(p, "default")] for p in field(suite, "parameters")]),
        ("asic_inputs", []),
    ]


def launch(session, name, digest, selection, expected):
    launched = session.api(operation=["Launch", ["submission_key", name],
                                      ["discovery_digest", digest], ["selection", selection]])
    attempt_id = field(field(launched, "detail")[0], "id")
    finished = session.until(
        ["Observe", attempt_id],
        lambda snap: field(field(snap, "detail")[0], "lifecycle") not in ("Queued", "Running"),
        timeout=session.args.timeout,
    )
    attempt, = field(finished, "detail")
    logs = job_logs(session, field(attempt, "job"), name)
    require(field(attempt, "lifecycle") == "Finished" and field(attempt, "outcome") == expected
            and field(attempt, "exit_code") == ["0"],
            f"{name}: expected checked {expected}, got {field(attempt, 'outcome')} "
            f"(provider exit {field(attempt, 'exit_code')}); see {session.evidence / (name + '.stderr')}")
    received = dict(field(field(attempt, "captured"), "selection"))
    requested = dict(selection)
    require(received == requested, f"{name}: captured inputs differ")
    case, = field(attempt, "cases")
    require(field(case, "case_id") == requested["cases"][0] and field(case, "status") == expected,
            f"{name}: selected case did not report {expected}")
    return attempt, logs


def export(session, attempt, kind, filename):
    artifact, = [a for a in field(attempt, "artifacts") if field(a, "kind") == kind]
    require(field(artifact, "availability") == "Available", f"unavailable artifact: {artifact}")
    require(field(artifact, "case_id") == [field(field(attempt, "cases")[0], "case_id")],
            f"{kind} artifact is not associated with the checked case")
    sha, = field(artifact, "sha256")
    size, = field(artifact, "size")
    data = bytearray()
    while True:
        offset = len(data)
        page, = field(session.api(operation=[
            "Read_artifact_bytes", ["attempt_id", field(attempt, "id")],
            ["artifact_id", field(artifact, "id")], ["sha256", sha], ["offset", offset], ["limit", 8192],
        ]), "byte_page")
        chunk = bytes.fromhex(field(page, "bytes_hex"))
        data.extend(chunk)
        require(int(field(page, "offset")) == offset and int(field(page, "next_offset")) == len(data)
                and field(page, "total_size") == size and field(page, "sha256") == sha,
                "invalid retained artifact page")
        if field(page, "eof") == "true":
            break
        require(chunk and len(data) < int(size), "retained artifact page did not advance toward EOF")
    require(len(data) == int(size) and hashlib.sha256(data).hexdigest() == sha,
            "retained bytes differ from the catalog's size or SHA-256")
    (session.evidence / filename).write_bytes(data)
    return bytes(data)


def vcd_transitions(data, signal):
    header, marker, body = data.decode("ascii").partition("$enddefinitions")
    require(marker, "retained waveform has no VCD definitions")
    codes = re.findall(rf"(?m)^\s*\$var\s+\S+\s+\d+\s+(\S+)\s+{re.escape(signal)}\s", header)
    require(codes, f"VCD does not declare {signal}")
    code = codes[0]
    timestamp = None
    transitions = []
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("#"):
            timestamp = int(line[1:])
        elif timestamp is not None:
            vector = re.fullmatch(r"[bB]([01]+)\s+" + re.escape(code), line)
            if vector:
                value = int(vector[1], 2)
            elif line in ("0" + code, "1" + code):
                value = int(line[0])
            else:
                continue
            if not transitions or value != transitions[-1][1]:
                require(not transitions or timestamp > transitions[-1][0],
                        f"{signal} changes at non-advancing VCD times")
                transitions.append((timestamp, value))
    return transitions


def exercise(session):
    project_action(session, "build", "//:rtl")
    rtl_output = session.root / "bazel-bin" / "mkCounter.v"
    require(rtl_output.is_file() and b"module mkCounter" in rtl_output.read_bytes(),
            "Silver Build did not produce the generated mkCounter Verilog")
    project_action(session, "test", "//:simulation")
    digest, selection = discover(session)
    passed, logs = launch(session, "checked", digest, selection, "Passed")
    require(re.search(rf"(?m)^PASS seed={SEED} cycles=[1-9][0-9]*$", logs["Stdout"]),
            "daemon logs do not contain the Rust checker's successful seeded-cycle result")
    report = json.loads(export(session, passed, "report", "counter-report.json"))
    require(report["case"] == dict(selection)["cases"][0] and report["seed"] == SEED
            and report["outcome"] == "Passed" and report["target"] == "//:bench",
            f"retained report does not identify the checked bench run: {report}")
    vcd = export(session, passed, "waveform", "counter.vcd")
    count = vcd_transitions(vcd, "count")
    clock = vcd_transitions(vcd, "CLK")
    # BSC can initialize the register to a nonzero simulation sentinel before
    # the first reset edge. The directed check starts at the reset value.
    start = next((i for i, (_, value) in enumerate(count) if value == 0), len(count))
    directed = count[start:start + 257]
    require([value for _, value in directed] == [*range(256), 0],
            "real counter transitions must increment and wrap after reset")
    require(len(clock) >= 514 and [value for _, value in clock[:4]] == [0, 1, 0, 1],
            "real clock must toggle in the retained VCD")
    rising = {timestamp for timestamp, value in clock if value == 1}
    require(all(timestamp in rising for timestamp, _ in directed[1:]),
            "directed count transitions must coincide with rising clock edges")

    # Change the *hardware*, not the checker or the provider. A cached/prebuilt
    # bench or unconditional success cannot produce this actual Rust mismatch.
    rtl = session.root / "Counter.bs"
    source = rtl.read_bytes()
    needle = b"value := value + 1"
    require(source.count(needle) == 1, f"cannot identify the starter increment in {rtl}")
    try:
        rtl.write_bytes(source.replace(needle, b"value := value + 2"))
        failed, logs = launch(session, "edited-rtl", digest, selection, "Failed")
        require(re.search(rf"FAIL seed={SEED} .*expected 1, got 2", logs["Stderr"]),
                "edited RTL must cause an actual checker mismatch, not a build or protocol error")
        report = json.loads(export(session, failed, "failure-report", "edited-counter-report.json"))
        require(report["case"] == dict(selection)["cases"][0] and report["seed"] == SEED
                and report["outcome"] == "Failed" and report["target"] == "//:bench",
                f"bad failure report: {report}")
    finally:
        rtl.write_bytes(source)

    # Verify the original bytes outlive the daemon and the subsequent failed run.
    instance = session.metadata["instance_id"]
    session.stop()
    session.start()
    require(session.metadata["instance_id"] != instance, "expected a new daemon instance")
    reopened, = field(session.api(operation=["Observe", field(passed, "id")]), "detail")
    require(field(reopened, "captured") == field(passed, "captured")
            and field(reopened, "outcome") == "Passed", "checked attempt was not durably retained")
    require(export(session, reopened, "waveform", "reopened-counter.vcd") == vcd,
            "original VCD differs after daemon restart")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--silver", default="ag", help="installed Silver executable ag (default: PATH)")
    parser.add_argument("--daemon", default="silver-daemon", help="installed daemon (default: PATH)")
    parser.add_argument("--timeout", type=int, default=240, help="per command or job, in seconds")
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    for arg, executable in (("client", args.silver), ("daemon", args.daemon)):
        located = shutil.which(executable)
        if not located:
            parser.error(f"required executable not found: {executable}")
        setattr(args, arg, str(Path(located).absolute()))
    for tool in ("bazel", "bsc", "verilator", "rustc", "make", "g++"):
        if not shutil.which(tool):
            parser.error(f"required executable not found: {tool}")

    os.umask(0o077)
    evidence = Path(tempfile.mkdtemp(prefix="bluespec-frontend-", dir="/tmp/opencode"))
    print(f"Evidence: {evidence}", flush=True)
    root, caller = evidence / "counter", evidence / "blank-caller"
    root.mkdir()
    caller.mkdir()
    session = Session(args, evidence, root)
    # BSC wrappers may depend on the real HOME; isolate Silver's mutable state.
    session.env.update(XDG_CONFIG_HOME=str(evidence / "config"), XDG_CACHE_HOME=str(evidence / "cache"))
    started = False
    try:
        command(evidence, "init-in-place", [args.client, "init", "--bluespec"], cwd=root,
                env=session.env, timeout=args.timeout)
        named = evidence / "named-counter"
        command(evidence, "init-explicit", [args.client, "init", "--bluespec", str(named)], cwd=caller,
                env=session.env, timeout=args.timeout)
        require(not list(caller.iterdir()), "explicit-destination init wrote into the blank caller")
        for project in (root, named):
            for filename in ("Counter.bs", "bench.cpp", "checker.rs", "BUILD.bazel", ".silver/project.json"):
                require((project / filename).is_file(), f"starter did not write {project / filename}")
            require(not (project / "dune-project").exists(), "Bluespec starter requires no Dune project")
        session.start()
        started = True
        exercise(session)
    finally:
        session.stop()
        if started:
            # Stop just this scratch workspace's Bazel server, leaving the
            # evidence and build outputs available for inspection.
            try:
                command(evidence, "bazel-shutdown", ["bazel", "shutdown"],
                        cwd=root, env=session.env, timeout=30)
            except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
                print(f"Warning: scratch Bazel shutdown failed: {error}", file=sys.stderr)
    print("PASS installed Silver Classic Bluespec: init, Build/Test, checked FS2 run, retained VCD, RTL regression")


if __name__ == "__main__":
    main()
