"""Exercise Testing palette aliases and catalog launch keys with a private provider."""
import argparse
from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "fixtures"))
from simulation_fixture_wire import EventWriter, catalog, parse, sexp


def provider():
    run_log = Path(sys.argv[2])
    if sys.argv[3] == "discover":
        suites = dict(catalog("alpha", ["a-only"]))["suites"]
        suites += dict(catalog(
            "beta", ["b-first", "b-second"], [("mode", "fast", ["fast", "thorough"])]
        ))["suites"]
        print(sexp([("protocol_version", 1), ("suites", suites)]))
    else:
        flags = dict(zip(sys.argv[4::2], sys.argv[5::2]))
        request = dict(parse(Path(flags["--request"]).read_text()))
        with run_log.open("a") as out:
            out.write(json.dumps(request) + "\n")
        writer = EventWriter(Path(flags["--events"]), request["attempt_id"])
        writer.emit("Started")
        for case in dict(request["selection"])["cases"]:
            writer.emit(["Case_started", case])
            writer.finish_case(case)
        writer.emit(["Finished", "Passed"])


def exercise(args, base):
    source = importlib.util.spec_from_file_location("native", ROOT / "scripts/test-native-simulation.py")
    native = importlib.util.module_from_spec(source)
    source.loader.exec_module(native)
    field = native.field
    for name in ("project", "state", "home", "config"):
        (base / name).mkdir()
    root = base / "project"
    run_log = base / "provider-runs.jsonl"
    (root / "dune-project").write_text("(lang dune 3.22)\n(name testing_aliases)\n")
    (root / "hardcaml-workbench-simulation.sexp").write_text(sexp([
        ("schema_version", 1), ("provider_executable", sys.executable),
        ("provider_args", [str(Path(__file__).resolve()), "_provider", str(run_log)]),
        ("discovery_timeout_seconds", 10), ("run_timeout_seconds", 30)]))
    session = native.Session(args, base, root)
    session.env.update(HOME=str(base / "home"), XDG_CONFIG_HOME=str(base / "config"))

    def jobs():
        reply = session.raw("/api/v1/snapshot", [("instance_id", session.metadata["instance_id"])])
        assert reply[0] == "Ok", reply
        return field(reply[1], "jobs")

    def run_requests():
        if not run_log.exists():
            return []
        return [json.loads(line) for line in run_log.read_text().splitlines()]

    def assert_runs(*attempt_ids):
        actual = sorted(field(a, "id") for a in field(session.api(), "attempts"))
        assert actual == sorted(attempt_ids), ("daemon attempts", actual, attempt_ids)
        actual = [request["attempt_id"] for request in run_requests()]
        assert actual == list(attempt_ids), ("provider calls", actual, attempt_ids)
        count = len(jobs())
        assert count == 1 + len(attempt_ids), ("discovery plus run jobs", count, attempt_ids)

    def new_passed_attempt(*previous_ids, cases, seed, mode):
        snapshot = session.until("Get", lambda s: len(field(s, "attempts")) > len(previous_ids))
        attempt_id, = [field(a, "id") for a in field(snapshot, "attempts")
                       if field(a, "id") not in previous_ids]
        result = session.done(attempt_id)
        assert field(result, "outcome") == "Passed", result
        expected = {
            "suite": "beta", "cases": cases, "seed": seed,
            "parameters": [["mode", mode]], "asic_inputs": []}
        captured = dict(field(field(result, "captured"), "selection"))
        assert captured == expected, ("captured selection", captured, expected)
        request, = [request for request in run_requests() if request["attempt_id"] == attempt_id]
        submitted = dict(request["selection"])
        assert submitted == expected, ("provider selection", submitted, expected)
        return attempt_id

    def replace_field(terminal, value):
        terminal.key(b"\x15")  # Ctrl-U
        terminal.key(value)
        terminal.key(b"\r")

    form_title = "SIMULATION LAUNCH FORM"
    editor_title = "CATALOG CONFIGURATION"
    no_form = [form_title, editor_title, "COMMAND PALETTE"]

    try:
        session.start()
        with closing(native.Terminal(session, width=160, height=45)) as terminal:
            terminal.capture("startup", ["Overview"])
            session.until("Get", lambda s: bool(field(s, "discovery_digest")))
            startup_jobs = jobs()
            assert len(startup_jobs) == 1
            terminal.palette("test")
            terminal.capture("initial-chooser", ["COMMAND PALETTE", "alpha", "beta"])
            assert_runs()
            assert jobs() == startup_jobs, (
                "test consumes the background catalog without rediscovery or dune test")
            terminal.key(b"alpha")
            terminal.key(b"\r")
            terminal.capture("after-discovery", ["Suite: alpha", "Ready for explicit launch"],
                             absent=["COMMAND PALETTE"])
            assert_runs()

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
            assert_runs()

            terminal.palette("test")
            terminal.capture("alias-review-subset", [form_title, "Suite: beta", "CASES", "> b-second▏"])
            terminal.key(b"\x1b")
            terminal.capture("alias-review-cancelled", ["Suite: beta", "Selected: 1 cases"],
                             absent=no_form)
            assert_runs()

            # A single uppercase R starts the selected subset with catalog defaults.
            terminal.key(b"R")
            quick_id = new_passed_attempt(cases=["b-second"], seed="42", mode="fast")
            terminal.capture("quick-launch-no-form", ["Suite: beta", "Selected: 1 cases"],
                             absent=no_form)
            assert_runs(quick_id)

            # Enter still opens the editable form and submits only on confirmation.
            terminal.key(b"\r")
            terminal.capture("enter-review-subset", [form_title, "Suite: beta", "CASES", "> b-second▏"])
            terminal.key(b"\r")
            terminal.capture("review-seed", ["SEED", "> 42▏"])
            replace_field(terminal, b"73")
            terminal.capture("review-parameter", ["PARAMETER mode", "> fast▏"])
            replace_field(terminal, b"thorough")
            terminal.capture("await-confirmation", ["CONFIRM", "73", "thorough"])
            assert_runs(quick_id)
            terminal.key(b"\r")
            reviewed_id = new_passed_attempt(quick_id, cases=["b-second"], seed="73", mode="thorough")
            assert_runs(quick_id, reviewed_id)

            # Save inputs for future launches without submitting a job.
            terminal.key(b"e")
            terminal.capture("edit-cases", [editor_title, "CASES", "> b-second▏"])
            replace_field(terminal, b"b-first")
            terminal.capture("edit-seed", ["SEED", "> 42▏"])
            replace_field(terminal, b"91")
            terminal.capture("edit-parameter", ["PARAMETER mode", "> fast▏"])
            replace_field(terminal, b"thorough")
            terminal.capture("await-save", ["SAVE — Enter saves", "> save▏", "(seed 91)"])
            assert_runs(quick_id, reviewed_id)
            terminal.key(b"\r")
            terminal.capture(
                "saved-without-launch",
                ["Suite: beta", "Selected cases: b-first", "Saved seed: 91", "Parameter mode = thorough"],
                absent=no_form)
            assert_runs(quick_id, reviewed_id)

            terminal.key(b"R")
            configured_id = new_passed_attempt(
                quick_id, reviewed_id, cases=["b-first"], seed="91", mode="thorough")
            terminal.capture("edited-quick-launch-no-form", ["Suite: beta", "Selected cases: b-first"],
                             absent=no_form)
            assert_runs(quick_id, reviewed_id, configured_id)
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
