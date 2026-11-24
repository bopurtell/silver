#!/usr/bin/env python3
"""Editor project sharing: real Silver publisher + unflagged Cobalt restart, with private PTYs/state."""
import argparse
from contextlib import contextmanager, ExitStack
import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
from tempfile import TemporaryDirectory
import termios
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "test"))
sys.path.insert(0, str(REPO / "demo/synthetic_flow"))
from support.screen import terminal_screen
from http_client import Client, field, parse, sexp
from fixtures.testing_layout import focus_pane


def wait(predicate, reason, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(.04)
    raise AssertionError(reason)


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def overview_field(key, value):
    # Key/value column alignment depends on the visible fields and tile width.
    return re.compile(r"\b" + re.escape(key) + r": +" + re.escape(value) + r"(?= *[│\n]|$)")


class Terminal:
    width, height = 240, 55

    def __init__(self, argv, env, cwd):
        self.master, slave = pty.openpty()
        self.data = bytearray()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ,
                        struct.pack("HHHH", self.height, self.width, 0, 0))
            self.process = subprocess.Popen(argv, env=env, cwd=cwd, start_new_session=True,
                                            stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)

    def screen(self):
        while select.select([self.master], [], [], 0)[0]:
            try:
                self.data.extend(os.read(self.master, 65536))
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
        return terminal_screen(bytes(self.data), width=self.width, height=self.height)

    def see(self, *text, absent=()):
        def contains(screen, item):
            return item in screen if isinstance(item, str) else item.search(screen) is not None

        def check():
            screen = self.screen()
            return screen if all(contains(screen, s) for s in text) and not any(
                contains(screen, s) for s in absent) else None
        try:
            return wait(check, f"wanted {text}, absent {absent}")
        except AssertionError as error:
            raise AssertionError(f"{error}\n{self.screen()}\n{bytes(self.data[-1200:])!r}") from error

    def keys(self, *keys):
        for key in keys:
            os.write(self.master, key.encode() if isinstance(key, str) else key)
            time.sleep(.12)
            self.screen()

    def drain(self, seconds=.2):
        time.sleep(seconds)
        return self.screen()

    def key(self, key):
        self.keys(key)

    def palette(self, query, row=None):
        self.keys(b" ", b"c", b"c", query)
        self.see("Commands" if row else "COMMAND PALETTE", row or query)
        self.keys(b"\r")

    def close(self):
        stop(self.process)
        os.close(self.master)


@contextmanager
def terminal(argv, env, cwd):
    term = Terminal(argv, env, cwd)
    try:
        yield term
    finally:
        term.close()


def make_project(root):
    root.mkdir()
    (root / "dune-project").write_text(f"(lang dune 3.17)\n(name {root.name})\n")
    source = root / "provider"
    source.mkdir()
    for name in ("simulation_provider.py", "simulation_wire.py"):
        data = (REPO / "demo/synthetic_flow" / name).read_text()
        if name == "simulation_provider.py":
            # Hold a real provider after Started, until the test has exercised
            # the lifecycle change. Its normal simulation events/results are unchanged.
            started = "        writer.emit('Started')\n"
            assert data.count(started) == 1
            data = data.replace(started,
                "        writer.emit('Started')\n"
                "        gate = Path(__file__).with_name('hold')\n"
                "        while gate.exists():\n"
                "            time.sleep(.05)\n", 1)
        (source / name).write_text(data)
    config = [["schema_version", "1"], ["provider_executable", sys.executable],
              ["provider_args", [str(source / "simulation_provider.py")]],
              ["discovery_timeout_seconds", "10"], ["run_timeout_seconds", "90"]]
    (root / "hardcaml-workbench-simulation.sexp").write_text(sexp(config) + "\n")
    return source / "hold"


class Backend(Client):
    """Read the already-open project. Never use Client.__init__ (open-project)."""
    def __init__(self, offer):
        self.url = offer["endpoint"]
        self.instance = offer["instance_id"]
        self.project = offer["project_id"]
        self.history = []
        assert field(self.raw("/api/hello"), "instance_id") == self.instance
        descriptor, = [p for p in field(self.snapshot(), "projects") if field(p, "id") == self.project]
        assert field(field(descriptor, "root"), "path") == offer["project_root"]

    def snapshot(self):
        return self.raw("/api/v1/snapshot", [["instance_id", self.instance]])

    def jobs(self):
        return {field(job, "id"): field(job, "state") for job in field(self.snapshot(), "jobs")}

    def simulation(self, op="Get"):
        return self.rpc(op, domain="simulation", wait=False)

    def attempts(self):
        return {field(a, "id"): dict(a) for a in field(self.simulation(), "attempts")}

    def completed(self, attempt, job, outcome):
        def result():
            latest = self.attempts()[attempt]
            if latest["lifecycle"] == "Finished":
                assert latest["outcome"] == outcome
                detail, = field(self.simulation(f"(Observe {sexp(attempt)})"), "detail")
                assert field(detail, "job") == job
                if self.jobs().get(job) == "Complete":
                    return latest
        return wait(result, f"{attempt} did not complete as {outcome}")

    def discover(self):
        if field(self.simulation(), "discovery_digest"):
            return
        self.simulation("Discover")
        wait(lambda: field(self.simulation(), "discovery_digest"), "simulation catalog not discovered")

    def seed(self):
        self.discover()
        digest, = field(self.simulation(), "discovery_digest")
        selection = sexp([["suite", "synthetic-checks"], ["cases", ["seeded-pattern"]],
                          ["seed", "314159"], ["parameters", [["pattern", "walking"], ["steps", "8"]]],
                          ["asic_inputs", []]])
        detail, = field(self.simulation(f"(Launch (submission_key sharing-retained-attempt)"
            f" (discovery_digest {sexp(digest)}) (selection {selection}))"), "detail")
        attempt, job = field(detail, "id"), field(detail, "job")
        self.completed(attempt, job, "Passed")
        return attempt

    def new_attempt(self, before, *, running=False):
        def submitted():
            attempts = self.attempts()
            new = set(attempts) - before
            if not new:
                return
            attempt, = new
            detail, = field(self.simulation(f"(Observe {sexp(attempt)})"), "detail")
            job = field(detail, "job")
            if not running or (attempts[attempt]["lifecycle"] == "Running"
                               and self.jobs().get(job) == "Running"):
                return attempt, job
        return wait(submitted, "no new attempt/job" + (" in Running" if running else ""))


def live_offers(runtime):
    offers = {}
    for path in (runtime / "editor-shares/v1").glob("*.sexp"):
        try:
            with path.open() as fd:
                try:
                    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                except BlockingIOError:
                    tag, fields = parse(fd.read())
                    offer = dict(fields)
                    oid = offer["offer_id"]
                    assert tag == "silver-editor-share-v1" and re.fullmatch("[0-9a-f]{32}", oid)
                    assert path.stem == oid
                    offers[oid] = offer
        except FileNotFoundError:
            pass
    return offers


def open_connection_picker(cobalt):
    cobalt.palette("silver connect", "Silver: Discover/Connect")


def check_cobalt_restart(argv, env, cwd, silver, runtime, offer, backend, retained):
    oid = offer["offer_id"]
    record = runtime / "editor-shares/v1" / f"{oid}.sexp"
    original = record.stat()
    remembered = Path(env["XDG_CONFIG_HOME"]) / "silver/editor-share-remembered-v1"
    projects = field(backend.snapshot(), "projects")
    jobs = backend.jobs()
    history = backend.attempts()
    assert set(history) == {retained} and history[retained]["outcome"] == "Passed"
    # Both launches use the same private home and runtime. No Silver input is
    # sent between runs, not even a visit to the share wizard.
    for launch in ("initial Cobalt", "restarted Cobalt"):
        assert silver.process.poll() is None
        assert live_offers(runtime) == {oid: offer}
        assert os.path.samestat(original, record.stat())
        assert not list(remembered.glob("*.sexp"))
        with terminal(argv, env, cwd) as cobalt:
            cobalt.see("UNRELATED_COBALT_BUFFER")
            open_connection_picker(cobalt)
            try:
                cobalt.see(f"[{offer['mode']} · {oid[:12]}]")
            except AssertionError as error:
                raise AssertionError(f"{launch} did not list live offer {oid}: {error}") from error
            cobalt.keys(b"\r")
            cobalt.see("Connected to Silver")
            cobalt.keys(b" vz", b" vU", b" st")
            cobalt.see("Silver: Overview", overview_field("Endpoint", offer["endpoint"]),
                       overview_field("Instance", backend.instance),
                       overview_field("Project ID", backend.project),
                       overview_field("Project", offer["project_root"]),
                       overview_field("Attempt", retained), overview_field("Outcome", "Passed"))
            cobalt.keys(b" bp")
            cobalt.see("UNRELATED_COBALT_BUFFER")
            cobalt.keys(b" q")

            def exited():
                cobalt.screen()
                return cobalt.process.poll() is not None
            try:
                wait(exited, f"{launch} did not quit normally", seconds=10)
            except AssertionError as error:
                raise AssertionError(f"{error}\n{cobalt.screen()}") from error
            assert cobalt.process.returncode == 0
        assert silver.process.poll() is None
        assert live_offers(runtime) == {oid: offer}
        assert os.path.samestat(original, record.stat())
        assert not list(remembered.glob("*.sexp"))
        assert field(backend.raw("/api/hello"), "instance_id") == backend.instance
        assert field(backend.snapshot(), "projects") == projects
        assert backend.jobs() == jobs
        assert backend.attempts() == history


def exercise(args, base, mode):
    base.mkdir(mode=0o700)
    root = base / "shared"
    hold = make_project(root)
    other = base / "other"
    make_project(other)
    code = base / "code.txt"
    code.write_text("UNRELATED_COBALT_BUFFER\n")
    dirs = {key: base / name for key, name in [
        ("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
        ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"),
        ("XDG_RUNTIME_DIR", "run"), ("TMPDIR", "tmp")]}
    for path in dirs.values():
        path.mkdir(mode=0o700)
    env = dict(os.environ, **{k: str(v) for k, v in dirs.items()}, TERM="xterm-256color",
               COLORTERM="truecolor", LC_ALL="C.UTF-8", PYTHONNOUSERSITE="1")
    for key in ("COBALT_SILVER_SHARE_FIXTURE", "HARDCAML_WORKBENCH_DIAGNOSTICS"):
        env.pop(key, None)
    runtime = dirs["XDG_RUNTIME_DIR"] / "hardcaml-workbench"
    state = base / "deliberately-nondefault-state"
    cobalt_argv = [args.cobalt, "--no-lsp", code]
    silver_exe = base / "silver"
    silver_exe.symlink_to(args.silver)
    with ExitStack() as stack:
        if mode == "attached":
            runtime.mkdir(mode=0o700)
            log = stack.enter_context((base / "daemon.log").open("wb"))
            daemon = subprocess.Popen([args.daemon, "--port", "0", "--discovery-dir", runtime,
                                       "--state-dir", state], env=env, cwd=base,
                                      stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            stack.callback(stop, daemon)
            metadata = runtime / "daemon.sexp"
            try:
                wait(lambda: metadata.exists() or daemon.poll() is not None,
                     "default local daemon discovery missing")
                assert metadata.exists() and daemon.poll() is None
            except AssertionError as error:
                raise AssertionError(f"{error}\n{(base / 'daemon.log').read_text()}") from error
            attach = field(parse(metadata.read_text()), "endpoint")
            flags = ["--connect", attach]
        else:
            flags = ["--standalone", "--standalone-state-dir", state]

        @contextmanager
        def silver(*, duplicate=False):
            selected_flags = flags
            if duplicate and mode == "embedded":
                selected_flags = ["--standalone", "--standalone-state-dir", base / "duplicate-state"]
            with terminal([silver_exe, *selected_flags, "--project-root", root], env, root) as t:
                t.see("Connection: connected")
                yield t

        def offers():
            return live_offers(runtime)

        def share(t):
            before = set(offers())
            t.palette("Share with Cobalt")
            t.see("Share for this session")
            t.keys(b"\r")
            added = wait(lambda: set(offers()) - before, f"{mode} Silver did not publish")
            oid, = added
            offer = offers()[oid]
            assert offer["project_root"] == str(root) and offer["mode"] == mode
            t.see("Sharing: on", "Back")
            t.keys(b"\x1b")
            return oid, offer

        with silver() as initial:
            first, offer = share(initial)
            seeded = Backend(offer)
            retained = seeded.seed()
            check_cobalt_restart(cobalt_argv, env, base, initial, runtime, offer, seeded, retained)
            initial.keys(b"\x03")
            assert initial.process.wait(timeout=10) == 0
        wait(lambda: first not in offers(), "normal exit left live offer")
        assert not (runtime / "editor-shares/v1" / (first + ".sexp")).exists()
        assert any(p.name == retained for p in (state / "simulation-v1").glob("*/*"))

        with silver() as s, silver(duplicate=True) as duplicate, terminal(cobalt_argv, env, base) as c:
            oid, offer = share(s)
            twin_id, twin = share(duplicate)
            assert len({first, oid, twin_id}) == 3 and offer["project_root"] == twin["project_root"]
            backend = Backend(offer)
            if mode == "attached":
                assert backend.instance == seeded.instance == twin["instance_id"]
                assert backend.project == seeded.project == twin["project_id"]
            else:
                assert backend.instance not in (seeded.instance, twin["instance_id"])
            assert backend.attempts()[retained]["outcome"] == "Passed"
            backend.discover()

            s.palette("Switch to Testing")
            s.see(retained[-4:], "Finished/Passed", "seeded-pattern")
            focus_pane(s, "simulation-cases")
            hold.touch()
            # Run the sampled case from the Silver frontend, not the E2E HTTP oracle.
            s.palette("Simulation: Rerun case seeded-pattern")
            silver_run, silver_job = backend.new_attempt({retained}, running=True)
            projects_before = {field(p, "id") for p in field(backend.snapshot(), "projects")}
            jobs_before = backend.jobs()

            def picker():
                open_connection_picker(c)
                c.see(oid[:12], twin_id[:12])

            def choose(wanted):
                if sorted([oid, twin_id])[0] != wanted:
                    c.keys(b"\t")
                c.keys(b"\r")

            c.see("UNRELATED_COBALT_BUFFER")
            picker()
            choose(oid)
            c.see("Connected to Silver")
            c.keys(b" vz", b" vU", b" st")
            c.see("Silver: Overview", overview_field("Instance", backend.instance),
                  overview_field("Project ID", backend.project),
                  overview_field("Attempt", retained), overview_field("Outcome", "Passed"))
            c.keys(b"\x1b")

            picker()
            os.killpg(duplicate.process.pid, signal.SIGKILL)
            duplicate.process.wait(timeout=5)
            assert (runtime / "editor-shares/v1" / (twin_id + ".sexp")).exists()
            assert set(offers()) == {oid}
            choose(twin_id)
            c.see("Silver share was withdrawn or changed")
            open_connection_picker(c)
            c.see(oid[:12], absent=(twin_id[:12],))
            c.keys(b"\x1b")
            assert set(backend.attempts()) == {retained, silver_run}
            assert backend.jobs() == jobs_before
            assert {field(p, "id") for p in field(backend.snapshot(), "projects")} == projects_before

            # Run the first picker target (whole suite, an intentional semantic fail).
            c.palette("test", "Choose a suite or variant")
            c.see("Choose a Silver test", "synthetic-checks")
            c.keys(b"\r")
            try:
                cobalt_run, cobalt_job = backend.new_attempt({retained, silver_run})
            except AssertionError as error:
                raise AssertionError(f"{error}\n{backend.attempts()}\n{c.screen()}") from error
            c.see("Accepted", cobalt_run, cobalt_job)
            s.see(cobalt_run[-4:], retained[-4:])

            survivor = stack.enter_context(silver(duplicate=True))
            survivor_id, _ = share(survivor)
            assert survivor_id not in (first, oid, twin_id)

            if mode == "embedded":
                s.palette("Open Project")
                s.see("Existing project directory")
                s.keys(str(other), b"\r")
                s.see("Project: other", "Connection: connected")
            else:
                s.palette("Share with Cobalt")
                s.see("Stop sharing")
                s.keys(b"s")
                s.see("Sharing: off", "Back")
                s.keys(b"\x1b", b"\x03")
                assert s.process.wait(timeout=10) == 0
                assert daemon.poll() is None
            wait(lambda: set(offers()) == {survivor_id}, "withdraw did not leave only the independent offer")
            assert not (runtime / "editor-shares/v1" / (oid + ".sexp")).exists()
            assert backend.jobs()[silver_job] == "Running"
            assert backend.attempts()[cobalt_run]["lifecycle"] == "Queued"
            open_connection_picker(c)
            c.see(survivor_id[:12], absent=(oid[:12], twin_id[:12]))
            c.keys(b"\x1b")
            survivor.keys(b"\x03")
            assert survivor.process.wait(timeout=10) == 0
            wait(lambda: not offers(), "independent offer was not withdrawn on exit")
            open_connection_picker(c)
            c.see("No Silver project shares")
            c.keys(b"\x1b")
            hold.unlink()
            backend.completed(silver_run, silver_job, "Passed")
            backend.completed(cobalt_run, cobalt_job, "Failed")
            assert set(backend.attempts()) == {retained, silver_run, cobalt_run}
            assert set(backend.jobs()) == set(jobs_before) | {cobalt_job}
            assert backend.attempts()[retained]["outcome"] == "Passed"
            assert field(backend.raw("/api/hello"), "instance_id") == backend.instance
            # Withdrawal does not revoke a verified attachment already in use.
            if "[2:Silver: Overview]" not in c.screen().splitlines()[0]:
                c.keys(b" bn")
            c.see("[2:Silver: Overview]", "Silver: Overview")
            c.keys(b"r")
            c.see(overview_field("Outcome", "Failed"), overview_field("Attempt", cobalt_run),
                  overview_field("Instance", backend.instance))
            assert state.is_dir()
    print(f"Editor sharing {mode}: unremembered offer {first} survived Cobalt restart; "
          f"retained {retained}, Silver job {silver_job}, "
          f"Cobalt acknowledged {cobalt_run}/{cobalt_job}; stale/withdraw left jobs intact")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["silver", "daemon", "cobalt"]:
        parser.add_argument("--" + name, type=lambda p: Path(p).resolve(strict=True), required=True)
    parser.add_argument("--mode", choices=("embedded", "attached"))
    args = parser.parse_args()
    with TemporaryDirectory(prefix="silver-cobalt-sharing-") as temp:
        for mode in ([args.mode] if args.mode else ["embedded", "attached"]):
            exercise(args, Path(temp).resolve() / mode, mode)


if __name__ == "__main__":
    main()
