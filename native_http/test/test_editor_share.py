"""WB-094 producer contract, driven by independent frontend and reader processes."""

import contextlib
import fcntl
import http.server
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import sys
import tempfile
import threading
import urllib.request


class Peer:
    def __init__(self, upstream=None):
        self.instance = "test-instance"
        self.capabilities = "snapshot updates"
        self.on_hello = lambda: None
        self.requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(handler):
                self.requests.append(handler.path)
                if handler.path != "/api/hello":
                    handler.send_error(404)
                    return
                self.on_hello()
                if upstream:
                    with urllib.request.urlopen(upstream + handler.path) as response:
                        body = response.read()
                else:
                    body = (
                        f"((application_version test)(protocol_versions (1))"
                        f"(instance_id {self.instance})(capabilities ({self.capabilities})))"
                    ).encode()
                handler.send_response(200)
                handler.send_header("Content-Type", "application/sexp")
                handler.send_header("Content-Length", str(len(body)))
                handler.end_headers()
                handler.wfile.write(body)

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.endpoint = f"http://127.0.0.1:{self.server.server_port}"

    def __enter__(self):
        self.server_thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server_thread.join()
        self.server.server_close()


def read_line(proc):
    assert select.select([proc.stdout], [], [], 10)[0], "probe output timed out"
    line = proc.stdout.readline().strip()
    assert line, proc.stderr.read()
    return line


def advance(proc):
    proc.stdin.write("\n")
    proc.stdin.flush()


def assert_failed(proc, message):
    _, err = proc.communicate(timeout=10)
    assert proc.returncode != 0 and message in err, (proc.args, proc.returncode, err)


@contextlib.contextmanager
def publisher(probe, mode, runtime, endpoint, root, *, started=None, instance="test-instance"):
    with subprocess.Popen(
        [probe, mode, str(runtime), endpoint, started or endpoint, instance, str(root)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ) as proc:
        try:
            yield proc
        finally:
            if proc.poll() is None:
                proc.kill()


def make_metadata(runtime, endpoint, instance="test-instance"):
    temp = runtime / "record.tmp"
    temp.write_text(f"((endpoint {endpoint})(instance_id {instance})(pid {os.getpid()}))")
    temp.chmod(0o600)
    temp.replace(runtime / "daemon.sexp")


def live(record):
    try:
        with record.open("rb") as handle:
            st = os.fstat(handle.fileno())
            try:
                fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return record.stat().st_ino == st.st_ino
            return False
    except FileNotFoundError:
        return False


def publish(proc, registry):
    advance(proc)
    offer = read_line(proc)
    assert re.fullmatch("[0-9a-f]{32}", offer), offer
    path = registry / (offer + ".sexp")
    assert live(path), path
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    return path, offer


def assert_record(path, offer, peer, root, mode):
    expected = (
        f"(silver-editor-share-v1((offer_id {offer})(endpoint {peer.endpoint})"
        f"(instance_id test-instance)(project_id example-project)"
        f"(project_root {root})(mode {mode})))"
    )
    assert re.sub(r"\s*\(\s*", "(", path.read_text().strip()) == expected


def preferences(probe, temporary, root, other_root):
    config = temporary / "new-config"
    alias = temporary / "root-alias"
    alias.symlink_to(root, target_is_directory=True)

    def command(root, verb):
        return [probe, "remember", str(config), str(root), verb]

    def get(root):
        return subprocess.check_output(command(root, "get"), text=True).strip()

    assert get(root) == "false"
    assert not config.exists()
    for_root = subprocess.Popen(command(root, "set"))
    for_other = subprocess.Popen(command(other_root, "set"))
    assert for_root.wait(timeout=10) == for_other.wait(timeout=10) == 0
    assert get(alias) == get(other_root) == "true"
    subprocess.run(command(alias, "clear"), check=True, timeout=10)
    assert get(root) == "false"
    assert get(other_root) == "true"
    store = config / "silver/editor-share-remembered-v1"
    [entry] = store.iterdir()
    assert entry.read_text() == str(other_root), "no endpoint or session identity is stored"
    entry.unlink()
    entry.symlink_to(root)
    err = subprocess.run(command(other_root, "set"), capture_output=True, text=True, timeout=10)
    assert err.returncode != 0 and entry.is_symlink()


def embedded(probe, temporary, root, peer):
    runtime = temporary / "embedded-runtime"
    registry = runtime / "editor-shares/v1"
    with publisher(probe, "embedded", runtime, peer.endpoint, root) as first, \
         publisher(probe, "embedded", runtime, peer.endpoint, root) as second:
        assert read_line(first) == read_line(second) == "validated"
        assert not runtime.exists(), "checking eligibility must not publish"
        p1, a = publish(first, registry)
        p2, b = publish(second, registry)
        assert a != b
        assert set(registry.iterdir()) == {p1, p2}
        assert_record(p1, a, peer, root, "embedded")
        for path in (runtime, registry.parent, registry):
            assert stat.S_IMODE(path.stat().st_mode) == 0o700
        # An independent open descriptor must see unlink, then release of the
        # original inode's lock (not a lock on a separate marker).
        with p1.open("rb") as original:
            advance(first)
            assert first.wait(timeout=10) == 0
            assert not p1.exists() and os.fstat(original.fileno()).st_nlink == 0
            fcntl.flock(original, fcntl.LOCK_SH | fcntl.LOCK_NB)
        assert live(p2)
        second.kill()
        second.wait(timeout=10)
        assert p2.is_file() and not live(p2), "a crash leaves a stale offer"
    with publisher(probe, "embedded", runtime, peer.endpoint, root) as third:
        assert read_line(third) == "validated"
        p3, c = publish(third, registry)
        assert c not in {a, b} and not live(p2)
        # Replacement at the pathname is not the publisher's inode to unlink.
        p3.unlink()
        p3.symlink_to(p2)
        advance(third)
        assert third.wait(timeout=10) == 0
        assert p3.is_symlink() and p2.is_file()
    with publisher(probe, "embedded", runtime, peer.endpoint, root,
                   started="http://127.0.0.1:1") as proc:
        assert_failed(proc, "not the embedded service")


def unlink_failure(probe, temporary, root, peer):
    if os.geteuid() == 0:
        print("Withdrawal permission regression skipped as root (root can unlink in 0500)")
        return
    runtime = temporary / "unlink-failure-runtime"
    registry = runtime / "editor-shares/v1"
    with publisher(probe, "embedded", runtime, peer.endpoint, root) as proc:
        assert read_line(proc) == "validated"
        path, _ = publish(proc, registry)
        registry.chmod(0o500)
        try:
            assert live(path)
            with path.open("rb") as original:
                advance(proc)
                error = read_line(proc)
                assert error.startswith("withdraw-error: ") and "unlink share record" in error, error
                assert "Permission denied" in error, error
                assert proc.poll() is None, "the publisher must still be alive"
                before = os.fstat(original.fileno())
                after = path.stat()
                assert (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino)
                fcntl.flock(original, fcntl.LOCK_SH | fcntl.LOCK_NB)
        finally:
            registry.chmod(0o700)
        advance(proc)
        assert proc.wait(timeout=10) == 0, "withdrawal remains idempotent after an unlink error"
        assert path.is_file() and not live(path)
    print("Withdrawal permission regression: EACCES reported; original inode unlocked before exit")


def attached(probe, temporary, root, peer):
    runtime = temporary / "daemon-runtime"
    runtime.mkdir(mode=0o700)
    make_metadata(runtime, peer.endpoint)
    lock_path = runtime / "lifetime.lock"
    lock_path.touch(mode=0o600)
    with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
        assert_failed(proc, "lifetime lock is not held")
    with lock_path.open("rb+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        registry = runtime / "editor-shares/v1"
        with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
            assert read_line(proc) == "validated"
            path, offer = publish(proc, registry)
            assert_record(path, offer, peer, root, "attached")
            advance(proc)
            assert proc.wait(timeout=10) == 0 and not path.exists()
        with urllib.request.urlopen(peer.endpoint + "/api/hello") as response:
            assert response.status == 200, "withdrawal must not stop the service"
        with Peer(upstream=peer.endpoint) as forwarded:
            # The forward really returns the same live hello; only the known
            # daemon endpoint-plus-instance can establish locality.
            with urllib.request.urlopen(forwarded.endpoint + "/api/hello") as response:
                assert b"test-instance" in response.read()
            with publisher(probe, "attached", runtime, forwarded.endpoint, root) as proc:
                assert_failed(proc, "does not match the local daemon's endpoint and instance")
        with publisher(probe, "attached", runtime, peer.endpoint, root, instance="other") as proc:
            assert_failed(proc, "does not match the local daemon's endpoint and instance")
        peer.instance = "changed-instance"
        with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
            assert_failed(proc, "did not confirm its instance and v1 snapshot support")
        peer.instance = "test-instance"
        peer.capabilities = "updates"
        with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
            assert_failed(proc, "did not confirm its instance and v1 snapshot support")
        peer.capabilities = "snapshot updates"

        metadata = runtime / "daemon.sexp"
        metadata.chmod(0o640)
        with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
            assert_failed(proc, "open safe share record")
        metadata.chmod(0o600)
        metadata.rename(runtime / "actual-daemon.sexp")
        metadata.symlink_to("actual-daemon.sexp")
        with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
            assert_failed(proc, "open safe share record")
        make_metadata(runtime, peer.endpoint)
        lock_path.rename(runtime / "actual-lock")
        lock_path.symlink_to("actual-lock")
        with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
            assert_failed(proc, "open safe share record")
        lock_path.unlink()
        (runtime / "actual-lock").rename(lock_path)

        # Replace an otherwise identical record during the fresh hello. The
        # second identity check must reject rather than trusting the response.
        peer.on_hello = lambda: make_metadata(runtime, peer.endpoint)
        with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
            assert_failed(proc, "Share entry was replaced")
        peer.on_hello = lambda: None

        with publisher(probe, "attached", runtime, peer.endpoint, root) as proc:
            assert read_line(proc) == "validated"
            fcntl.flock(lock, fcntl.LOCK_UN)
            advance(proc)
            assert_failed(proc, "lifetime lock is not held")
        assert not list(registry.iterdir())


def unsafe_registry(probe, temporary, root, peer):
    runtime = temporary / "unsafe-runtime"
    elsewhere = temporary / "other-runtime"
    elsewhere.mkdir(mode=0o700)
    runtime.symlink_to(elsewhere, target_is_directory=True)
    with publisher(probe, "embedded", runtime, peer.endpoint, root) as proc:
        assert_failed(proc, "open safe share directory")
    assert not list(elsewhere.iterdir())
    runtime.unlink()
    runtime.mkdir(mode=0o755)
    with publisher(probe, "embedded", runtime, peer.endpoint, root) as proc:
        assert_failed(proc, "open safe share directory")
    assert stat.S_IMODE(runtime.stat().st_mode) == 0o755
    runtime.chmod(0o700)
    with publisher(probe, "embedded", runtime, peer.endpoint, root) as proc:
        assert read_line(proc) == "validated"
        (runtime / "editor-shares").symlink_to(elsewhere, target_is_directory=True)
        advance(proc)
        assert_failed(proc, "open safe share subdirectory")
    assert not list(elsewhere.iterdir())


def main():
    probe = str(Path(sys.argv[1]).resolve())
    # Dune's own TMPDIR can have group-writable ancestors. Use the system's
    # sticky temporary directory to test the same trust boundary as production.
    with tempfile.TemporaryDirectory(prefix="silver-share-producer-", dir="/var/tmp") as temporary, Peer() as peer:
        temporary = Path(temporary).resolve()
        root = temporary / "project"
        other_root = temporary / "other-project"
        root.mkdir()
        other_root.mkdir()
        embedded(probe, temporary, root, peer)
        unlink_failure(probe, temporary, root, peer)
        attached(probe, temporary, root, peer)
        unsafe_registry(probe, temporary, root, peer)
        preferences(probe, temporary, root, other_root)
        assert set(peer.requests) == {"/api/hello"}
    print("WB-094 producer contract: PASS")


if __name__ == "__main__":
    main()
