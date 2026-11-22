"""Exercise Testing aliases, launch keys and parallel runs with a private provider."""
import argparse
from contextlib import closing
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "fixtures"))
from simulation_fixture_wire import EventWriter, catalog, parse, sexp


def await_release(path):
    deadline = time.monotonic() + 30
    while not path.exists():
        assert time.monotonic() < deadline, f"Timed out waiting for {path.name}"
        time.sleep(.05)


def provider():
    run_log = Path(sys.argv[2])
    if sys.argv[3] == "discover":
        if (run_log.parent / "hold-refresh").exists():
            (run_log.parent / "refresh-started").touch()
            await_release(run_log.parent / "release-refresh")
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
        selection = dict(request["selection"])
        writer.emit("Started")
        for case in selection["cases"]:
            writer.emit(["Case_started", case])
            if (run_log.parent / "hold-runs").exists():
                await_release(run_log.parent / f"release-{selection['suite']}")
            writer.finish_case(case)
        writer.emit(["Finished", "Passed"])


def private_session(args, base, *, parallel=False):
    source = importlib.util.spec_from_file_location("native", ROOT / "scripts/test-native-simulation.py")
    native = importlib.util.module_from_spec(source)
    source.loader.exec_module(native)
    for name in ("project", "state", "home", "config"):
        (base / name).mkdir()
    root = base / "project"
    run_log = base / "provider-runs.jsonl"
    (root / "dune-project").write_text("(lang dune 3.22)\n(name testing_aliases)\n")
    config = [
        ("schema_version", 1), ("provider_executable", sys.executable),
        ("provider_args", [str(Path(__file__).resolve()), "_provider", str(run_log)]),
        ("discovery_timeout_seconds", 30 if parallel else 10),
        ("run_timeout_seconds", 30)]
    if parallel:
        config.append(("max_parallel_runs", 2))
    (root / "hardcaml-workbench-simulation.sexp").write_text(sexp(config))
    session = native.Session(args, base, root)
    session.env.update(HOME=str(base / "home"), XDG_CONFIG_HOME=str(base / "config"))
    return native, session, run_log


def exercise(args, base):
    native, session, run_log = private_session(args, base)
    field = native.field

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


def exercise_overlap(args, base):
    base.mkdir()
    native, session, run_log = private_session(args, base, parallel=True)
    field = native.field
    (base / "hold-runs").touch()

    def started_case(attempt_id):
        # A Running job alone does not prove the provider process has started;
        # this status comes from the actual provider's Case_started event.
        return session.until(
            ["Observe", attempt_id],
            lambda s: any(field(c, "status") == "Running"
                          for c in field(field(s, "detail")[0], "cases")),
            timeout=8)

    def attempt_row(status, suite):
        return re.compile(rf"(?m)^│[^│\n]*{status}[^│\n]*│[^\n]*\n"
                          rf"│[^│\n]*· {suite}[^│\n]*│")

    try:
        session.start()
        with closing(native.Terminal(session, width=160, height=45)) as terminal:
            terminal.capture("startup", ["Overview"])
            initial = session.until("Get", lambda s: bool(field(s, "discovery_digest")))
            digest, = field(initial, "discovery_digest")
            terminal.palette("test")
            terminal.capture("choose-alpha", ["COMMAND PALETTE", "alpha", "beta"])
            terminal.key(b"alpha")
            terminal.key(b"\r")
            terminal.capture("alpha-ready", ["Suite: alpha", "Ready for explicit launch"],
                             absent=["COMMAND PALETTE"])
            terminal.key(b"R")
            first = session.until("Get", lambda s: bool(field(s, "attempts")))
            alpha, = field(first, "attempts")
            alpha_id = field(alpha, "id")
            started_case(alpha_id)

            (base / "hold-refresh").touch()
            terminal.key(b"d")
            refresh = session.until(
                "Get", lambda s: field(s, "discovery_job") and (base / "refresh-started").exists(),
                timeout=8)
            assert field(refresh, "discovery_digest") == [digest], refresh
            terminal.palette("test suites")
            terminal.capture("choose-beta-with-alpha-running", ["COMMAND PALETTE", "beta"])
            terminal.key(b"beta")
            terminal.key(b"\r")
            terminal.capture("beta-ready", ["Suite: beta", "Selected: 2 cases",
                                            "discovery refresh in progress"],
                             absent=["COMMAND PALETTE", "Launch disabled"])
            terminal.key(b"R")
            admitted = session.until("Get", lambda s: len(field(s, "attempts")) >= 2, timeout=8)
            beta_id, = {field(a, "id") for a in field(admitted, "attempts")} - {alpha_id}

            started_case(beta_id)
            overlap = session.api()
            assert {field(a, "id"): field(a, "lifecycle") for a in field(overlap, "attempts")} == {
                alpha_id: "Running", beta_id: "Running"}, overlap
            assert field(overlap, "discovery_job") == field(refresh, "discovery_job"), overlap
            assert field(overlap, "discovery_digest") == [digest], overlap
            terminal.capture("both-running-during-refresh", [
                attempt_row("Running/Unknown", "alpha"),
                attempt_row("Running/Unknown", "beta"),
                "discovery refresh in progress"], timeout=5)

            # Beta must finish before we unblock Alpha or the discovery provider.
            (base / "release-beta").touch()
            beta = session.done(beta_id)
            assert field(beta, "outcome") == "Passed", beta
            overlap = session.api(operation=["Observe", alpha_id])
            assert field(field(overlap, "detail")[0], "lifecycle") == "Running", overlap
            assert field(overlap, "discovery_job") == field(refresh, "discovery_job"), overlap
            assert field(overlap, "discovery_digest") == [digest], overlap
            (base / "release-alpha").touch()
            (base / "release-refresh").touch()

            expected = [
                {"suite": "alpha", "cases": ["a-only"], "seed": "42",
                 "parameters": [], "asic_inputs": []},
                {"suite": "beta", "cases": ["b-first", "b-second"], "seed": "42",
                 "parameters": [["mode", "fast"]], "asic_inputs": []},
            ]
            for detail, selection in zip((session.done(alpha_id), beta), expected):
                assert field(detail, "outcome") == "Passed", detail
                captured = field(detail, "captured")
                assert dict(field(captured, "selection")) == selection, detail
                assert field(captured, "discovery_digest") == digest, detail
            refreshed = session.until("Get", lambda s: not field(s, "discovery_job"))
            assert not field(refreshed, "discovery_error"), refreshed
            assert field(refreshed, "discovery_digest") == [digest], refreshed
            requests = [json.loads(line) for line in run_log.read_text().splitlines()]
            assert [request["attempt_id"] for request in requests] == [alpha_id, beta_id], requests
            assert [dict(request["selection"]) for request in requests] == expected, requests
    finally:
        (base / "release-alpha").touch()
        (base / "release-beta").touch()
        (base / "release-refresh").touch()
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
            base = args.evidence.resolve()
            exercise(args, base)
            exercise_overlap(args, base / "overlap")
        else:
            with tempfile.TemporaryDirectory(prefix="testing-aliases-") as tmp:
                base = Path(tmp)
                exercise(args, base)
                exercise_overlap(args, base / "overlap")
