"""Black-box lifecycle checks against the installed entry points."""
import contextlib
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from support.terminal import Terminal


def project(root):
    root.mkdir(parents=True)
    (root / "dune-project").write_text("(lang dune 3.0)\n")
    return root


def isolated(base):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("DUNE_", "HARDCAML_WORKBENCH_", "XDG_"))
           and k != "INSIDE_DUNE"}
    for key in ("HOME", "TMPDIR", "XDG_RUNTIME_DIR", "XDG_STATE_HOME",
                "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = base / key
        directory.mkdir(parents=True, mode=0o700)
        env[key] = str(directory)
    env["HARDCAML_WORKBENCH_DAEMON"] = str(base / "must-never-be-spawned")
    # The production build adapter requests -j20. Keep the real Dune build,
    # but constrain nested actions to one worker for this suite.
    dune = shutil.which("dune")
    assert dune
    wrapper = base / "bin" / "dune"
    wrapper.parent.mkdir()
    wrapper.write_text(
        f"#!{sys.executable}\nimport os, re, sys\n"
        f"os.execv({dune!r}, [{dune!r}] + ['-j1' if re.fullmatch(r'-j[0-9]+', a) "
        "else a for a in sys.argv[1:]])\n")
    wrapper.chmod(0o700)
    env["PATH"] = str(wrapper.parent) + os.pathsep + env["PATH"]
    return env


def run(silver, daemon, base):
    env = isolated(base / "client")
    for prefix in ("silver", "hardcaml-workbench"):
        for suffix in ("", "-daemon", "-init", "-simulation-setup", "-workspace"):
            name = prefix + suffix
            help_text = subprocess.check_output([silver.with_name(name), "--help"],
                                                env=env, text=True, timeout=15)
            assert name in help_text, (name, help_text)
            if not suffix:
                summary = help_text.splitlines()[0]
                if prefix == "silver":
                    assert "nearest Silver Bazel or Dune project" in summary, summary
                else:
                    assert summary == "Connect to Silver", summary
    # Run the lifecycle with only the primary command on the client side.
    client_bin = base / "client-bin"
    client_bin.mkdir()
    (client_bin / "silver").symlink_to(silver)
    silver = client_bin / "silver"
    outer = project(base / "outer")
    inner = project(outer / "inner")
    nested = inner / "src"
    nested.mkdir()
    alias = base / "alias"
    alias.symlink_to(inner)

    def invoke(*args, cwd=nested, ok=True):
        p = subprocess.run([silver, *args], cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=25)
        assert (p.returncode == 0) == ok, (p.args, p.stdout, p.stderr)
        return p

    def client(*args, **kwargs):
        return invoke(*args, **kwargs).stdout

    def workspace(op, **kwargs):
        reply = client("--api", "--workspace-operation", op, **kwargs)
        assert reply.startswith("(Ok("), reply
        return reply

    @contextlib.contextmanager
    def tui(*args, cwd=nested):
        term = Terminal(SimpleNamespace(env=env, evidence=base),
                        argv=[silver, *args], cwd=cwd)
        try:
            term.capture("ready", ["Overview"])
            yield
            os.write(term.master, b"Q")
            deadline = time.monotonic() + 15
            while term.process.poll() is None:
                screen = term.drain(.15, allow_exit=True)
                assert time.monotonic() < deadline, f"Q did not exit:\n{screen}"
            assert term.process.returncode == 0, "Q did not exit cleanly"
        finally:
            term.close()

    missing = invoke("--plain", cwd=base, ok=False)
    assert "no Dune project found" in missing.stderr, missing
    status = client("--plain")
    assert f"root={inner}\n" in status, status
    endpoint = urlsplit(re.search(r"^Daemon: (\S+)", status, re.M)[1])
    with socket.socket() as probe:
        probe.settimeout(2)
        assert probe.connect_ex((endpoint.hostname, endpoint.port)) != 0, status

    with tui():
        conflict = client("--api", "--workspace-operation", "Get", "--project-root", alias, ok=False)
        assert len(conflict.splitlines()) == 1 and conflict.startswith("(Error("), conflict
        assert "(kind " in conflict and "lock" in conflict.lower(), conflict
        other = client("--plain", "--project-root", outer)
        assert f"root={outer}\n" in other, other

    # A fresh process can acquire the lock after q. Mutate the real registry
    # and read it across another restart via the checkout's symlink.
    state = workspace("Get")
    revision = re.search(r"\(revision (\d+)\)", state)[1]
    wid = re.search(r"\(workspaces\(\(\(id ([^() ]+)\)", state)[1]
    name = "standalone-retained-test"
    change = f"(Rename_workspace (workspace {wid}) (name {name}))"
    assert name in workspace(f"(Mutate (expected_revision {revision}) (mutation {change}))")
    assert name in workspace("Get", cwd=alias)
    assert name not in workspace("Get", cwd=outer)
    (inner / "dune").write_text("(rule (target proof) (action (write-file proof complete)))\n")
    built = client("--plain", "--action", "build")
    job = re.search(r"Submitted build job (\S+)", built)[1]
    assert f"job {job}: complete".lower() in built.lower(), built
    assert (inner / "_build/default/proof").read_text() == "complete"

    # Stand in for the server behind an SSH loopback forward: it has its own
    # cwd, HOME and XDG state. A relative root exists only at the daemon cwd.
    server = base / "server"
    server_env = isolated(server)
    remote = project(server / "remote-project")
    # Hold a real build across the attached client's q, then allow it to
    # finish. This distinguishes preserving the listener from preserving work.
    release = server / "release"
    (remote / "dune").write_text(
        "(rule (target survived) (action (run python3 %{dep:wait.py} %{target})))\n")
    (remote / "wait.py").write_text(
        "from pathlib import Path\nimport time, sys\n"
        "deadline = time.monotonic() + 30\n"
        f"while not Path({str(release)!r}).exists():\n"
        "    if time.monotonic() >= deadline: raise TimeoutError('release')\n"
        "    time.sleep(.05)\n"
        "Path(sys.argv[1]).write_text('done')\n")
    discovery = server / "discovery"
    with (server / "log").open("w+") as log:
        process = subprocess.Popen([daemon, "--port", "0", "--discovery-dir", discovery],
                                   cwd=server, env=server_env, stdout=log, stderr=log)
        try:
            metadata = discovery / "daemon.sexp"
            deadline = time.monotonic() + 15
            while not metadata.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    log.seek(0)
                    raise AssertionError("daemon not ready: " + log.read())
                time.sleep(.05)
            record = metadata.read_text()
            url = re.search(r"\(endpoint ([^()]+)\)", record)[1]
            instance = re.search(r"\(instance_id ([^()]+)\)", record)[1]
            args = ("--connect", url, "--project-root", remote.name)
            with tui(*args, cwd=base):
                submitted = client("--plain", *args, "--action", "build", cwd=base)
                assert "Submitted build job " in submitted, submitted
            assert process.poll() is None, "attached q stopped the persistent daemon"
            release.touch()
            output = remote / "_build/default/survived"
            deadline = time.monotonic() + 20
            while not output.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            assert output.read_text() == "done", "remote job did not survive attached q"
            status = client("--plain", *args, cwd=base)
            assert f"Instance: {instance}\n" in status and f"root={remote}\n" in status, status
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    # Explicit attach to the now-dead endpoint must not fall back to startup.
    client("--plain", *args, cwd=base, ok=False)
    assert not list(Path(env["XDG_RUNTIME_DIR"]).iterdir()), "unexpected local daemon discovery"


if __name__ == "__main__":
    # Preserve the installed command name when Dune uses symlinks.
    with tempfile.TemporaryDirectory(prefix="silver-lifecycle-") as tmp:
        run(*(Path(p).absolute() for p in sys.argv[1:]), Path(tmp).resolve())
    print("Installed silver standalone and persistent attach lifecycle passed")
