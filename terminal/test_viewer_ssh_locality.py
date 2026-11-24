#!/usr/bin/env python3
"""Opt-in real OpenSSH/PTY viewer locality test; never builds.

Example (run in the selected opam environment):
  python3 -B terminal/test_viewer_ssh_locality.py \
    --daemon _build/default/daemon/main.exe --client _build/default/terminal/main.exe \
    --ssh-host configured-host --remote-client /absolute/path/to/matching/main.exe
Add --ssh-config /path/to/config if needed. The configured host must permit local
and remote loopback TCP forwarding and provide python3. No remote checkout is
needed: a private local daemon serves one retained fixture VCD via a reverse
forward. The separate local client uses a local forward through that same SSH
host. Client executable SHA256 must match before either client is started.

--loopback starts an unprivileged, private localhost sshd instead; it exercises
the identical transport/UI/recorder path but explicitly does not certify two
different hosts. Evidence is retained under --evidence-parent (default /tmp).
"""
import argparse
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback
from types import SimpleNamespace

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


handoff = load('ssh_handoff', ROOT / 'terminal/test_waveform_handoff_pty.py')
native = load('ssh_native', ROOT / 'scripts/test-native-simulation.py')


def command(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), check=True, text=True,
                          capture_output=True, timeout=15, **kwargs).stdout


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def write(path, text, executable=False):
    path.write_text(text)
    path.chmod(0o700 if executable else 0o600)
    return path


def wait_port(port, process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError('SSH listener exited; see SSH log')
        with socket.socket() as sock:
            sock.settimeout(.2)
            if sock.connect_ex(('127.0.0.1', port)) == 0:
                return
        time.sleep(.05)
    raise TimeoutError('SSH listener startup')


def loopback(args, evidence, cleanup):
    """Private host keys/auth/config; never reads or writes ~/.ssh or system config."""
    user = pwd.getpwuid(os.getuid()).pw_name
    if os.getuid() == 0:
        raise ValueError('--loopback expects an unprivileged user')
    for name in ('host-key', 'client-key'):
        command(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', evidence / name])
        cleanup.callback((evidence / name).unlink, missing_ok=True)
    auth = write(evidence / 'authorized_keys', 'from="127.0.0.1",no-agent-forwarding,no-X11-forwarding ' +
                 (evidence / 'client-key.pub').read_text())
    cleanup.callback(auth.unlink, missing_ok=True)
    port = free_port()
    config = write(evidence / 'sshd_config', f'''Port {port}
ListenAddress 127.0.0.1
HostKey {evidence}/host-key
PidFile {evidence}/sshd.pid
AuthorizedKeysFile none
AuthorizedKeysCommand /usr/bin/cat {auth}
AuthorizedKeysCommandUser {user}
StrictModes yes
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin no
AllowUsers {user}
AllowAgentForwarding no
X11Forwarding no
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no
PermitUserRC no
PrintMotd no
LogLevel VERBOSE
''')
    pub = (evidence / 'host-key.pub').read_text().split()
    known = write(evidence / 'known_hosts', f'[127.0.0.1]:{port} {pub[0]} {pub[1]}\n')
    args.ssh_host = 'viewer-private-loopback'
    args.ssh_config = write(evidence / 'ssh_config', f'''Host {args.ssh_host}
 HostName 127.0.0.1
 Port {port}
 User {user}
 IdentityFile {evidence}/client-key
 IdentitiesOnly yes
 IdentityAgent none
 UserKnownHostsFile {known}
 GlobalKnownHostsFile /dev/null
 StrictHostKeyChecking yes
''')
    command([args.sshd, '-t', '-f', config])
    log = cleanup.enter_context((evidence / 'sshd.log').open('w'))
    process = subprocess.Popen([str(args.sshd), '-D', '-e', '-f', str(config)], stdout=log, stderr=log)
    cleanup.callback(stop, process)
    wait_port(port, process)
    args.remote_client = str(args.client)


def recorder(python, receipt):
    return ('#!' + python + '\nimport hashlib,json,os,pathlib,socket,sys\n'
            'p=pathlib.Path(sys.argv[1]).resolve(strict=True)\n'
            'data=p.read_bytes()\n'
            'r=pathlib.Path(' + repr(str(receipt)) + ')\n'
            'tmp=r.with_suffix(".partial")\n'
            'tmp.write_text(json.dumps(dict(hostname=socket.gethostname(),path=str(p),'
            'sha256=hashlib.sha256(data).hexdigest(),size=len(data),argv=sys.argv)))\n'
            'os.replace(tmp,r)\n')


def run(args, evidence, result, cleanup):
    if args.loopback:
        loopback(args, evidence, cleanup)
    ssh = ['ssh']
    if args.ssh_config:
        ssh += ['-F', str(args.ssh_config)]
    ssh += ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
            '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2',
            '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no', '-o', 'PermitLocalCommand=no']

    def remote(code):
        return command(ssh + [args.ssh_host, shlex.join([args.remote_python, '-c', code])])

    probe = json.loads(remote('import hashlib,json,pathlib,socket,sys; '
        'p=pathlib.Path(' + repr(args.remote_client) + ').resolve(strict=True); '
        'print(json.dumps(dict(hostname=socket.gethostname(),python=sys.executable,'
        'client=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest())))'))
    local_hash = hashlib.sha256(args.client.read_bytes()).hexdigest()
    result.update(mode='loopback' if args.loopback else 'two-host', remote=probe,
                  local_hostname=socket.gethostname(), binaries={
                      name: dict(path=str(getattr(args, name)), sha256=hashlib.sha256(
                          getattr(args, name).read_bytes()).hexdigest()) for name in ('client', 'daemon')})

    def check(ok, label):
        result['checks'].append(dict(passed=bool(ok), expectation=label))
        if not ok:
            raise AssertionError(label)
        print('PASS ' + label, flush=True)

    check(probe['sha256'] == local_hash, 'local and SSH client executables match SHA256')
    check(args.loopback or probe['hostname'] != socket.gethostname(),
          'distinct runner hostnames required in two-host mode (explicitly waived for loopback)')

    remote_dir = remote('import tempfile; print(tempfile.mkdtemp(prefix="viewer-"))').strip()
    result['remote_private_directory'] = remote_dir

    def remote_cleanup():
        result['remote_cleanup'] = json.loads(remote(
            'import json,pathlib,shutil; p=pathlib.Path(' + repr(remote_dir) + '); '
            'shutil.rmtree(p); print(json.dumps(dict(directory_removed=not p.exists())))'))
    cleanup.callback(remote_cleanup)

    def stop_remote_client():
        # The remote launcher removes this marker after wait(), avoiding stale
        # PID cleanup after an orderly exit. Run before terminating the SSH PTY.
        remote('import os,pathlib,signal; p=pathlib.Path(' + repr(remote_dir) + ')/"client.pid"\n'
               'if p.exists():\n'
               ' try: os.kill(int(p.read_text()),signal.SIGKILL)\n'
               ' except ProcessLookupError: pass\n')

    # Reuse the deterministic repository VCD producer, native endpoint/session,
    # and shared PTY/screen driver. Only private fixture/state paths are created.
    for name in ('project', 'state', 'home', 'config', 'tmp'):
        (evidence / name).mkdir()
    root = evidence / 'project'
    write(root / 'dune-project', '(lang dune 3.22)\n(name viewer_ssh_locality)\n')
    write(root / 'suite-id', 'fixture\n')
    write(root / 'hardcaml-workbench-simulation.sexp', handoff.wire.sexp([
        ('schema_version', 1), ('provider_executable', sys.executable),
        ('provider_args', [str(ROOT / 'terminal/test_waveform_handoff_pty.py'), '_provider']),
        ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 30)]))
    session = native.Session(args, evidence, root)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        XDG_CACHE_HOME=str(evidence / 'cache'), XDG_DATA_HOME=str(evidence / 'data'),
        TMPDIR=str(evidence / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
        OMP_NUM_THREADS='2', OPENROAD_THREADS='2', _OPENLANE_MAX_CORES='2')
    cleanup.callback(session.stop)
    session.start()
    field = native.field
    catalog = session.discover()
    snap = session.api(operation=['Launch', ['submission_key', 'ssh-viewer'],
        ['discovery_digest', field(catalog, 'discovery_digest')[0]], ['selection', [
            ('suite', 'fixture'), ('cases', ['flops256']), ('seed', '2'),
            ('parameters', []), ('asic_inputs', [])]]])
    attempt = session.done(field(field(snap, 'attempts')[0], 'id'))
    check(field(attempt, 'outcome') == 'Passed', 'retained fixture attempt passed')
    artifact = next(a for a in field(attempt, 'artifacts') if field(a, 'label') == 'flops256-waveform')
    digest = field(artifact, 'sha256')[0]
    result.update(attempt=attempt, artifact=artifact, daemon_endpoint=session.url)
    # Read retained bytes independently of the UI and save the byte oracle.
    page = field(session.api(operation=['Read_artifact_bytes',
        ['attempt_id', field(attempt, 'id')], ['artifact_id', field(artifact, 'id')],
        ['sha256', digest], ['offset', 0], ['limit', 65536]]), 'byte_page')[0]
    raw = bytes.fromhex(field(page, 'bytes_hex'))
    check(field(page, 'eof') == 'true' and hashlib.sha256(raw).hexdigest() == digest,
          'retained VCD bytes independently match daemon artifact digest')
    (evidence / 'retained.vcd').write_bytes(raw)

    remote_port = int(remote('import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); '
                             'print(s.getsockname()[1]); s.close()').strip())
    local_port = free_port()
    daemon_port = int(session.url.rsplit(':', 1)[1])
    tunnel_log = cleanup.enter_context((evidence / 'tunnel.log').open('w'))
    tunnel = subprocess.Popen(ssh + ['-N', '-o', 'ExitOnForwardFailure=yes',
        '-R', f'127.0.0.1:{remote_port}:127.0.0.1:{daemon_port}',
        '-L', f'127.0.0.1:{local_port}:127.0.0.1:{remote_port}', args.ssh_host],
        stdout=tunnel_log, stderr=tunnel_log)
    cleanup.callback(stop, tunnel)
    wait_port(local_port, tunnel)
    result['forwarding'] = dict(remote_port=remote_port, local_port=local_port)

    remote_path = Path(remote_dir)
    remote_viewer = remote_path / 'record-viewer.py'
    remote_receipt = remote_path / 'viewer.json'
    remote_env = dict(PATH='/usr/bin:/bin', TERM='xterm-256color', LANG='C.UTF-8',
        **{key: str(remote_path / name) for key, name in (
            ('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state'),
            ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data'), ('TMPDIR', 'tmp'))})
    remote_setup_code = ('import pathlib; p=pathlib.Path(' + repr(remote_dir) + ')\n'
        'for name in ["home","config","state","cache","data","tmp"]: (p/name).mkdir(mode=0o700)\n'
        'v=p/"record-viewer.py"; v.write_text(' + repr(recorder(probe['python'], remote_receipt)) +
        '); v.chmod(0o700)')
    remote(remote_setup_code)
    (evidence / 'remote-setup.py').write_text(remote_setup_code)

    for role in ('remote', 'local'):
        role_dir = evidence / role
        role_dir.mkdir()
        receipt = role_dir / 'viewer.json'
        wrapper = role_dir / 'client-wrapper'
        if role == 'remote':
            argv = [probe['client'], '--simulation-viewer', str(remote_viewer),
                    '--connect', f'http://127.0.0.1:{remote_port}', '--project-root', str(root)]
            code = ('import pathlib,subprocess,sys; p=pathlib.Path(' +
                    repr(str(remote_path / 'client.pid')) + '); '
                    'child=subprocess.Popen(' + repr(argv) + ',env=' + repr(remote_env) + '); '
                    'p.write_text(str(child.pid))\n'
                    'try: sys.exit(child.wait())\n'
                    'finally: p.unlink(missing_ok=True)\n')
            launch = ssh + ['-tt', args.ssh_host, shlex.join([probe['python'], '-c', code])]
        else:
            viewer = write(role_dir / 'record-viewer.py', recorder(sys.executable, receipt), True)
            launch = [str(args.client), '--simulation-viewer', str(viewer)]
        write(wrapper, '#!' + sys.executable + '\nimport os,sys\nargv=' + repr(launch) +
              ('\nos.execvp(argv[0],argv)\n' if role == 'remote' else
               '\nos.execv(argv[0],argv+sys.argv[1:])\n'), True)
        view_session = SimpleNamespace(args=SimpleNamespace(client=wrapper), root=root,
            url=f'http://127.0.0.1:{local_port}', env=session.env, evidence=role_dir)
        terminal = native.Terminal(view_session)
        with ExitStack() as client_cleanup:
            client_cleanup.callback(terminal.close)
            if role == 'remote':
                client_cleanup.callback(stop_remote_client)
            terminal.capture('startup', ['Overview'])
            terminal.palette('Switch to Testing')
            handoff.testing_layout.focus_pane(terminal, 'simulation-attempts')
            terminal.palette('Simulation: Reopen ' + field(attempt, 'id') + ' fixture')
            terminal.palette('Simulation: Select case flops256')
            handoff.testing_layout.focus_pane(terminal, 'simulation-artifacts')
            terminal.key(b'v')
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                terminal.drain(.1)
                if role == 'remote':
                    text = remote('import pathlib; p=pathlib.Path(' + repr(str(remote_receipt)) +
                                  '); print(p.read_text() if p.exists() else "")').strip()
                    if text:
                        receipt.write_text(text + '\n')
                if receipt.exists():
                    break
            terminal.save('viewer-handoff', terminal.drain(.1))
            check(receipt.exists(), role + ' headless viewer completed within deadline')
            observed = json.loads(receipt.read_text())
            result[role + '_receipt'] = observed
            expected_host = probe['hostname'] if role == 'remote' else socket.gethostname()
            check(observed['hostname'] == expected_host, role + ' viewer ran on expected client host')
            expected_tmp = remote_path / 'tmp' if role == 'remote' else evidence / 'tmp'
            path = Path(observed['path'])
            check(path.is_relative_to(expected_tmp) and path.parent.name.endswith('-verified'),
                  role + ' viewer received private verified export path on client host')
            check(observed['sha256'] == digest and observed['size'] == len(raw),
                  role + ' viewer bytes match independently verified retained VCD')
    check(result['remote_receipt']['sha256'] == result['local_receipt']['sha256'],
          'SSH PTY and tunneled local client handed off identical verified bytes')
    check(tunnel.poll() is None and session.process.poll() is None,
          'owned daemon and SSH tunnel survived both client handoffs')
    result['status'] = 'passed'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--daemon', type=Path, required=True)
    parser.add_argument('--client', type=Path, required=True)
    parser.add_argument('--ssh-host')
    parser.add_argument('--ssh-config', type=Path)
    parser.add_argument('--remote-client')
    parser.add_argument('--remote-python', default='python3')
    parser.add_argument('--loopback', action='store_true')
    parser.add_argument('--sshd', type=Path, default=Path('/usr/sbin/sshd'))
    parser.add_argument('--evidence-parent', type=Path, default=Path('/tmp'))
    parser.add_argument('--timeout-seconds', type=int, default=180)
    args = parser.parse_args()
    if args.loopback and (args.ssh_host or args.ssh_config or args.remote_client):
        parser.error('--loopback supplies its own host, config and matching remote client')
    if not args.loopback and (not args.ssh_host or not args.remote_client):
        parser.error('two-host mode requires --ssh-host and --remote-client')
    if args.ssh_host and args.ssh_host.startswith('-'):
        parser.error('--ssh-host must be an OpenSSH host alias, not an option')
    if not 1 <= args.timeout_seconds <= 300:
        parser.error('--timeout-seconds must be 1..300')
    for name in ('daemon', 'client'):
        path = getattr(args, name).resolve(strict=True)
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error('--' + name + ' must name a prebuilt executable')
        setattr(args, name, path)
    os.umask(0o077)
    evidence = Path(tempfile.mkdtemp(prefix='viewer-ssh-', dir=args.evidence_parent))
    print('Evidence: ' + str(evidence), flush=True)
    result = dict(status='failed', checks=[], invocation=sys.argv)

    def deadline(*_):
        raise TimeoutError('SSH viewer test budget exhausted')

    previous = signal.signal(signal.SIGALRM, deadline)
    try:
        with ExitStack() as cleanup:
            # Cancel scenario deadline before bounded resource cleanup begins.
            cleanup.callback(signal.alarm, 0)
            signal.alarm(args.timeout_seconds)
            try:
                run(args, evidence, result, cleanup)
            finally:
                signal.alarm(0)
    except BaseException:
        result.update(status='failed', error=traceback.format_exc())
        raise
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
