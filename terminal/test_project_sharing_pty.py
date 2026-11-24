"""Editor sharing: scripted keyboard UX and publication lifecycle in real Silver PTYs."""
from contextlib import ExitStack, closing, contextmanager
import fcntl
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "test"), str(ROOT / "scripts" / "fixtures")]
from support.terminal import Terminal
from simulation_fixture_wire import catalog, parse, sexp

WIZARD = "Share with Cobalt…"
MANAGE = "Manage This Project"
ESC, ENTER, F2 = b"\x1b", b"\r", b"\x1bOQ"


def temp_parent():
    # Dune can give actions a group-writable TMPDIR under a safe temporary
    # parent. Use the closest safe ancestor so the sharing path checks work.
    preferred = Path(tempfile.gettempdir()).resolve()
    for candidate in (preferred, *preferred.parents):
        if candidate == Path("/") or not os.access(candidate, os.W_OK | os.X_OK):
            continue
        entries = [entry.stat() for entry in (candidate, *candidate.parents)]
        if all(entry.st_uid in (0, os.geteuid()) and (
                not entry.st_mode & 0o022 or
                entry.st_uid == 0 and entry.st_mode & stat.S_ISVTX) for entry in entries):
            return candidate
    raise AssertionError(f"No safe writable temporary directory above {preferred}")


def key(term, keys):
    os.write(term.master, keys)


def quit_ui(term):
    key(term, b"\x03")
    deadline = time.monotonic() + 12
    while term.process.poll() is None:
        assert time.monotonic() < deadline, "Silver did not exit on Ctrl-C"
        term.drain(.1, allow_exit=True)
    assert term.process.returncode == 0


def click(term, frame, label):
    y, line = next((i, line) for i, line in enumerate(frame.splitlines(), 1) if label in line)
    x = line.index(label) + 1
    key(term, f"\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m".encode())


@contextmanager
def daemon(exe, env, *args):
    with subprocess.Popen([exe, *args], env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, start_new_session=True, text=True) as child:
        try:
            assert select.select([child.stdout], [], [], 15)[0], "Daemon did not become ready"
            line = child.stdout.readline()
            assert line.startswith("silver-daemon listening on "), line
            yield line.strip().split()[-1]
        finally:
            child.terminate()
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)


def exercise(client, service, base):
    launcher = base / "silver"
    launcher.symlink_to(client)
    for name in ("config", "state", "runtime", "home", "cache", "tmp", "unbound", "evidence"):
        (base / name).mkdir(mode=0o700)
    env = dict(os.environ, HOME=str(base / "home"), XDG_CONFIG_HOME=str(base / "config"),
               XDG_STATE_HOME=str(base / "state"), XDG_RUNTIME_DIR=str(base / "runtime"),
               XDG_CACHE_HOME=str(base / "cache"), TMPDIR=str(base / "tmp"),
               HARDCAML_WORKBENCH_DIAGNOSTICS=str(base / "diagnostics"),
               PYTHONDONTWRITEBYTECODE="1")
    session = SimpleNamespace(env=env, evidence=base / "evidence")
    runtime = base / "runtime/hardcaml-workbench"
    registry = runtime / "editor-shares/v1"
    preferences = base / "config/silver/editor-share-remembered-v1"

    def project(name, *, simulation=False):
        root = base / name
        root.mkdir()
        (root / "dune-project").write_text(f"(lang dune 3.22)\n(name {name})\n")
        if simulation:
            config = [("schema_version", 1), ("provider_executable", sys.executable),
                      ("provider_args", [str(Path(__file__).resolve()), "_provider"]),
                      ("discovery_timeout_seconds", 10), ("run_timeout_seconds", 10)]
            (root / "hardcaml-workbench-simulation.sexp").write_text(sexp(config))
        return root

    alpha = project("alpha", simulation=True)
    beta = project("beta")
    alternate = base / "alternate-state"

    def open_ui(root=None, *flags, cwd=None):
        argv = [launcher, *flags]
        if root is not None:
            argv += ["--project-root", root]
        return closing(Terminal(session, argv=argv, cwd=cwd or root or base / "unbound",
                                width=140, height=42))

    def remember_records():
        return sorted(preferences.glob("*.sexp"))

    def records(*, include_stale=False):
        offers = {}
        for file in sorted(registry.glob("*.sexp")):
            with file.open("r") as opened:
                try:
                    fcntl.flock(opened, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    live = False
                except BlockingIOError:
                    live = True
                if live or include_stale:
                    version, fields = parse(opened.read())
                    assert version == "silver-editor-share-v1", version
                    data = dict(fields)
                    assert file.stem == data["offer_id"], data
                    assert file.stat().st_mode & 0o777 == 0o600
                    offers[file.stem] = dict(data, live=live)
        return offers

    def one(root, mode="embedded"):
        offers = records()
        offer, = offers.values()
        assert offer["project_root"] == str(root) and offer["mode"] == mode, offer
        return offer

    def ready(term, root):
        try:
            return term.capture("ready-" + root.name,
                                ["Overview", "Project: " + root.name, "Project ▾"])
        except AssertionError:
            if term.process.poll() is not None:
                raise AssertionError(bytes(term.data).decode(errors="replace")) from None
            raise

    def wizard(term, label, *expected, absent=()):
        # Match the framed wizard heading, not the management action behind it.
        return term.capture(label, ["╭ " + WIZARD, *expected], absent=absent)

    def off(term, *expected):
        wizard(term, "available-off", "Sharing: off", "[ ] Remember for this project",
               "Share for this session", *expected)

    def share(term, *, remember=False):
        if remember:
            key(term, b"r")
            wizard(term, "checked", "[x] Remember for this project", "Share and remember")
        key(term, ENTER)
        wizard(term, "confirmed", "Sharing: on", "Enter / Esc  Back",
               *(["remembered for this project"] if remember else []))
        key(term, ESC)
        term.capture("share-dismissed", absent=["╭ " + WIZARD])

    def stop(term):
        wizard(term, "can-stop", "Sharing: on", "Stop sharing", "interrupt jobs")
        key(term, ENTER)
        wizard(term, "stopped", "Sharing: off", "Enter / Esc  Back")
        key(term, ESC)
        term.capture("stop-dismissed", absent=["╭ " + WIZARD])

    def switch_project(term, root):
        term.palette("Open Project")
        term.capture("switch-chooser", ["Existing project directory"])
        key(term, str(root).encode() + ENTER)
        ready(term, root)

    # No project, no endpoint, no writes.
    with open_ui() as term:
        term.capture("unbound", ["Unbound workspace", "[s] " + WIZARD])
        key(term, b"s")
        wizard(term, "unbound-share", "Project: none", "No project binding",
               absent=["Share for this session", "Remember for this project"])
        key(term, ENTER)
        wizard(term, "unbound-enter", "Sharing: off")
        key(term, ESC)
        term.capture("unbound-return", ["Open existing project"], absent=["╭ " + WIZARD])
        quit_ui(term)
    assert not registry.exists() and not preferences.exists()

    with open_ui(alpha, "--standalone-state-dir", alternate) as term:
        frame = ready(term, alpha)
        assert not records() and not preferences.exists()
        click(term, frame, "Testing")
        frame = term.capture("testing", ["[2 Testing]", "simulation-catalog"])
        click(term, frame, "simulation-catalog")
        key(term, b"d")
        term.capture("fixture-cases", ["> [x] first", "[x] second"])
        key(term, b"j")
        selected_row = ["> [x] second", "[2 Testing]"]
        term.capture("chosen-row", selected_row)

        # Management route: navigate through the Project menu and project's Actions.
        key(term, F2)
        term.capture("project-menu", [MANAGE])
        key(term, b"/Manage This Project")
        term.capture("manage-only", [MANAGE], absent=["New IP Library"])
        key(term, ENTER)
        term.capture("management", ["Manage This Project", WIZARD, "Actions"])
        key(term, b"\t" + b"99j" + ENTER)
        off(term, "Project: alpha")
        assert not registry.exists() and not preferences.exists()
        key(term, b"r")
        wizard(term, "checked-but-unconfirmed", "[x] Remember for this project")
        key(term, ESC)
        term.capture("back-to-management", ["Back to inspection", WIZARD])
        key(term, ESC)
        term.capture("restored-row-after-cancel", selected_row, absent=[MANAGE])
        key(term, b"k")
        term.capture("restored-tile-after-cancel", ["> [x] first", "[2 Testing]"])
        key(term, b"j")
        term.capture("selected-again", selected_row)
        assert not registry.exists() and not preferences.exists()

        term.palette("Share with Cobalt")
        off(term)
        key(term, b"\x1b[200~r\r\x1b[201~")
        off(term)
        assert not records() and not preferences.exists()
        share(term)
        term.capture("restored-row-after-share", selected_row)
        key(term, b"k")
        term.capture("restored-tile-after-share", ["> [x] first", "[2 Testing]"])
        first = one(alpha)
        assert alternate.is_dir() and not preferences.exists()

        # The same retained service and project come back, but with a fresh offer.
        term.palette("Open Project")
        term.capture("cancel-switch-chooser", ["Existing project directory"])
        key(term, ESC)
        term.capture("cancel-switch-restored", ["[2 Testing]", "> [x] first"])
        assert one(alpha) == first
        switch_project(term, beta)
        assert not records() and not records(include_stale=True)
        with urlopen(first["endpoint"] + "/api/hello", timeout=2) as response:
            assert dict(parse(response.read().decode()))["instance_id"] == first["instance_id"]
        term.palette("Share with Cobalt")
        off(term, "Project: beta")
        share(term, remember=True)
        beta_offer = one(beta)

        switch_project(term, alpha)
        term.palette("Share with Cobalt")
        wizard(term, "retained-session", "Sharing: on", "Project: alpha")
        again = one(alpha)
        assert first["offer_id"] != again["offer_id"]
        for field in ("endpoint", "instance_id", "project_id"):
            assert first[field] == again[field], (first, again)

        key(term, ESC)
        term.capture("retained-wizard-dismissed", ["[2 Testing]"], absent=["╭ " + WIZARD])
        switch_project(term, beta)
        term.palette("Share with Cobalt")
        wizard(term, "remembered-switch", "Sharing: on (remembered for this project)")
        assert one(beta)["offer_id"] != beta_offer["offer_id"]
        stop(term)
        quit_ui(term)
    assert not records(include_stale=True) and not remember_records()

    with open_ui(alpha, "--standalone-state-dir", alternate) as term:
        ready(term, alpha)
        term.palette("Share with Cobalt")
        off(term)
        share(term, remember=True)
        remembered = one(alpha)
        record, = remember_records()
        assert parse(record.read_text()) == str(alpha)
        quit_ui(term)
    assert not records(include_stale=True)

    with open_ui(alpha, "--standalone-state-dir", alternate) as term:
        ready(term, alpha)
        term.palette("Share with Cobalt")
        wizard(term, "remembered-reopen", "Sharing: on (remembered for this project)")
        assert one(alpha)["offer_id"] != remembered["offer_id"]
        stop(term)
        assert not records(include_stale=True) and not remember_records()
        quit_ui(term)

    with open_ui(alpha, "--standalone-state-dir", alternate) as term:
        ready(term, alpha)
        term.palette("Share with Cobalt")
        off(term)
        assert not records()
        quit_ui(term)

    # A real but unregistered loopback daemon is not eligible.
    with daemon(service, env) as endpoint, open_ui(beta, "--connect", endpoint) as term:
        ready(term, beta)
        term.palette("Share with Cobalt")
        wizard(term, "unverified", "Unavailable:", "Sharing: off",
               absent=["Share for this session", "Remember for this project"])
        key(term, ENTER)
        wizard(term, "unverified-enter", "Sharing: off")
        assert not records() and not remember_records()
        quit_ui(term)

    with daemon(service, env, "--discovery-dir", runtime) as endpoint:
        with open_ui(beta, "--connect", endpoint) as first, ExitStack() as clients:
            # Opening the first binding runs Dune's project inspection. Open
            # the peer only after that has settled, to avoid racing Dune's lock.
            ready(first, beta)
            second = clients.enter_context(open_ui(beta, "--connect", endpoint))
            ready(second, beta)
            first.palette("Share with Cobalt")
            share(first)
            offer = one(beta, "attached")
            assert offer["endpoint"] == endpoint
            second.palette("Share with Cobalt")
            share(second)
            offers = records()
            assert len(offers) == 2 and all(o["project_id"] == offer["project_id"]
                                             for o in offers.values()), offers
            first.palette("Share with Cobalt")
            stop(first)
            other = one(beta, "attached")
            assert other["offer_id"] != offer["offer_id"], other
            first.palette("Share with Cobalt")
            share(first)
            assert len(records()) == 2
            quit_ui(first)
            assert records(include_stale=True) == {other["offer_id"]: other}
            second.process.kill()
            second.process.wait(timeout=10)
            assert not records()
            assert records(include_stale=True) == {other["offer_id"]: dict(other, live=False)}
        with urlopen(endpoint + "/api/hello", timeout=2) as response:
            assert dict(parse(response.read().decode()))["instance_id"] == offer["instance_id"]


if __name__ == "__main__":
    if sys.argv[1] == "_provider":
        assert sys.argv[2] == "discover", sys.argv
        print(sexp(catalog()))
    else:
        with tempfile.TemporaryDirectory(prefix="silver-share-pty-", dir=temp_parent()) as directory:
            exercise(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), Path(directory))
