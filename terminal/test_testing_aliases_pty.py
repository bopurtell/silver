"""Exercise the Testing aliases with real palette dispatch and a private provider."""
import argparse
from contextlib import closing
import importlib.util
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "fixtures"))
from fs2_wire import EventWriter, catalog, parse, sexp


def provider():
    if sys.argv[2] == "discover":
        suites = dict(catalog("alpha", ["a-only"]))["suites"]
        suites += dict(catalog("beta", ["b-first", "b-second"]))["suites"]
        print(sexp([("protocol_version", 1), ("suites", suites)]))
    else:
        flags = dict(zip(sys.argv[3::2], sys.argv[4::2]))
        request = dict(parse(Path(flags["--request"]).read_text()))
        writer = EventWriter(Path(flags["--events"]), request["attempt_id"])
        writer.emit("Started")
        for case in dict(request["selection"])["cases"]:
            writer.emit(["Case_started", case])
            writer.finish_case(case)
        writer.emit(["Finished", "Passed"])


def exercise(args, base):
    source = importlib.util.spec_from_file_location("native", ROOT / "scripts/test-fs2-native.py")
    native = importlib.util.module_from_spec(source)
    source.loader.exec_module(native)
    field = native.field
    for name in ("project", "state", "home", "config"):
        (base / name).mkdir()
    root = base / "project"
    (root / "dune-project").write_text("(lang dune 3.22)\n(name testing_aliases)\n")
    (root / "hardcaml-workbench-simulation.sexp").write_text(sexp([
        ("schema_version", 1), ("provider_executable", sys.executable),
        ("provider_args", [str(Path(__file__).resolve()), "_provider"]),
        ("discovery_timeout_seconds", 10), ("run_timeout_seconds", 30)]))
    session = native.Session(args, base, root)
    session.env.update(HOME=str(base / "home"), XDG_CONFIG_HOME=str(base / "config"))

    def jobs():
        reply = session.raw("/api/v1/snapshot", [("instance_id", session.metadata["instance_id"])])
        assert reply[0] == "Ok", reply
        return field(reply[1], "jobs")

    def empty_attempts():
        assert field(session.api(), "attempts") == []

    try:
        session.start()
        with closing(native.Terminal(session, width=160, height=45)) as terminal:
            terminal.capture("startup", ["Overview"])
            terminal.palette("test")
            terminal.capture("initial-chooser", ["COMMAND PALETTE", "Discover suites explicitly"])
            empty_attempts()
            assert jobs() == [], "test must not implicitly discover or dispatch dune test"
            terminal.key(b"\r")
            terminal.capture("after-discovery", ["Suite: alpha", "Ready for explicit launch"],
                             absent=["COMMAND PALETTE"])
            assert len(jobs()) == 1
            empty_attempts()

            terminal.palette("test suites")
            terminal.capture("choose-suite", ["COMMAND PALETTE", "alpha", "beta"])
            terminal.key(b"beta")
            terminal.key(b"\r")
            terminal.capture("beta-selected", ["Suite: beta", "Selected: 2 cases"],
                             absent=["COMMAND PALETTE"])
            terminal.key(b"x")
            terminal.capture("subset-selected", ["Selected: 1 cases"])
            terminal.palette("verification")
            terminal.capture("choose-current-suite", ["COMMAND PALETTE", "beta (selected)"])
            terminal.key(b"beta")
            terminal.key(b"\r")
            terminal.capture("subset-preserved", ["Suite: beta", "Selected: 1 cases"],
                             absent=["COMMAND PALETTE"])
            assert len(jobs()) == 1
            empty_attempts()

            terminal.palette("test")
            terminal.capture("review-subset", ["Suite: beta", "CASES", "> b-second▏"])
            terminal.key(b"\r")
            terminal.capture("review-seed", ["SEED"])
            terminal.key(b"\r")
            terminal.capture("await-confirmation", ["CONFIRM"])
            assert len(jobs()) == 1
            empty_attempts()
            terminal.key(b"\r")
            snapshot = session.until("Get", lambda s: bool(field(s, "attempts")))
            attempt, = field(snapshot, "attempts")
            result = session.done(field(attempt, "id"))
            assert field(result, "outcome") == "Passed", result
            assert dict(field(field(result, "captured"), "selection")) == {
                "suite": "beta", "cases": ["b-second"], "seed": "42",
                "parameters": [], "asic_inputs": []}
            assert len(jobs()) == 2
    finally:
        session.stop()


if __name__ == "__main__":
    if sys.argv[1:2] == ["_provider"]:
        provider()
    else:
        parser = argparse.ArgumentParser()
        parser.add_argument("--daemon", type=lambda p: Path(p).resolve(), required=True)
        parser.add_argument("--client", type=lambda p: Path(p).resolve(), required=True)
        parser.add_argument("--evidence", type=Path)
        args = parser.parse_args()
        if args.evidence:
            args.evidence.mkdir()
            exercise(args, args.evidence.resolve())
        else:
            with tempfile.TemporaryDirectory(prefix="testing-aliases-") as tmp:
                exercise(args, Path(tmp))
