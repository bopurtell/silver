#!/usr/bin/env python3
"""Opt-in WB-040 real FIFO/retained ASIC HTTP + PTY export acceptance.

Requires prebuilt applications and example FIFO executables, plus the real-demo
ASIC manifest. Uses a private project/state; only reads the retained ASIC inputs.
Never builds, installs, runs EDA, or starts a graphical viewer.
"""
import argparse
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native = load('streaming_native', ROOT / 'scripts/test-fs2-native.py')
wire = load('streaming_wire', ROOT / 'scripts/fixtures/fs2_wire.py')
field = native.field


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def executable(path, body):
    path.write_text('#!' + sys.executable + '\n' + body)
    path.chmod(0o700)
    return path


class Terminal(native.Terminal):
    def palette(self, title):
        for key in (b' ', b'c', b'c'):
            self.key(key)
        self.key(title.encode())
        self.capture('query-' + str(time.time_ns()), ['COMMAND PALETTE', title[-60:]],
                     absent=['No matching commands'])
        self.key(b'\x1b[A' * 24)
        self.key(b'\r')


def run(args, evidence):
    checks, exports = [], []

    def check(value, label):
        checks.append(dict(passed=bool(value), expectation=label))
        save(evidence / 'checks.json', checks)
        if not value:
            raise AssertionError(label)
        print('PASS ' + label, flush=True)

    manifest = json.loads(args.asic_manifest.read_text())
    provider = Path(manifest['provider']).resolve(strict=True)
    watched = {Path(r['path']): r['sha256'] for r in manifest['hashes']}
    watched[provider] = manifest['provider_sha256']
    check(all(digest(path) == sha for path, sha in watched.items()),
          'retained ASIC inputs match explicit manifest hashes')
    binaries = {name: dict(path=str(path), sha256=digest(path)) for name, path in
                [('daemon', args.daemon), ('client', args.client),
                 ('fifo_provider', args.fifo_provider), ('fifo_simulator', args.fifo_simulator),
                 ('asic_provider', provider)]}
    save(evidence / 'inputs.json', dict(binaries=binaries, asic_manifest=str(args.asic_manifest),
                                      asic_manifest_sha256=digest(args.asic_manifest)))
    for name in ('project', 'state', 'home', 'config', 'tmp', 'results'):
        (evidence / name).mkdir()
    root = evidence / 'project'
    (root / 'dune-project').write_text('(lang dune 3.22)\n(name streaming_acceptance)\n')
    (root / 'hardcaml-workbench-simulation.sexp').write_text(wire.sexp([
        ('schema_version', 1), ('provider_executable', str(args.fifo_provider)),
        ('provider_args', ['--simulator', str(args.fifo_simulator)]),
        ('discovery_timeout_seconds', 30), ('run_timeout_seconds', 120)]))

    # Restrict the real ASIC provider to reads of the explicitly selected run.
    # Artifact paging itself is done by the production backend, not this relay.
    policy = dict(provider=str(provider), allocation=manifest['allocation'],
                  execution=manifest['execution_file'], finalization=manifest['finalization'])
    save(evidence / 'asic-policy.json', policy)
    relay = executable(evidence / 'read-only-asic',
        'import json,pathlib,subprocess,sys\n'
        'base=pathlib.Path(' + repr(str(evidence)) + ')\n'
        "p=json.loads((base/'asic-policy.json').read_text())\n"
        'a=sys.argv[1:]\n'
        "ok=a==['--version','--json'] or a==['report',p['execution'],'--json']\n"
        "ok |= a==['observation','inspect',p['allocation']['attempt'],'--json']\n"
        "ok |= a==['finalization-inspect',p['finalization'],'--json']\n"
        "ok |= (len(a)==8 and a[:3]==['observation','read-updates',p['allocation']['attempt']] "
        "and a[3:6]==['--stream-id',p['allocation']['stream_id'],'--after'] "
        "and a[6].isdigit() and a[7:]==['--json'])\n"
        "with (base/'provider-calls.jsonl').open('a') as out:\n"
        " out.write(json.dumps(dict(argv=a,allowed=bool(ok)))+'\\n')\n"
        "if not ok: sys.exit('unexpected non-read-only ASIC command')\n"
        "sys.exit(subprocess.run([p['provider']]+a,timeout=60).returncode)\n")
    deny = executable(evidence / 'no-project-build', "raise SystemExit('no build/EDA in export test')\n")
    native.fs0.write_config(root, deny, relay, evidence / 'results')

    receipt = evidence / 'viewer.json'
    viewer = executable(evidence / 'record-viewer',
        'import hashlib,json,os,pathlib,stat,sys,time\n'
        'assert len(sys.argv)==2\n'
        'p=pathlib.Path(sys.argv[1])\n'
        'with p.open("rb") as stream: sha=hashlib.file_digest(stream,"sha256").hexdigest()\n'
        'r=dict(path=str(p),size=p.stat().st_size,sha256=sha,at=time.monotonic(),'
        'mode=stat.S_IMODE(p.stat().st_mode),directory_mode=stat.S_IMODE(p.parent.stat().st_mode),'
        'metadata=(p.parent/"metadata.sexp").read_text())\n'
        'target=pathlib.Path(' + repr(str(receipt)) + ')\n'
        'tmp=target.with_suffix(".tmp"); tmp.write_text(json.dumps(r)); os.replace(tmp,target)\n')
    wrapper = executable(evidence / 'client-with-viewer',
        'import os,sys\nos.execv(' + repr(str(args.client)) + ', [' + repr(str(args.client)) +
        ', "--artifact-binary-viewer", ' + repr(str(viewer)) + '] + sys.argv[1:])\n')
    session = native.Session(args, evidence, root)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
                       TMPDIR=str(evidence / 'tmp'), OMP_NUM_THREADS='1', OPENROAD_THREADS='1',
                       _OPENLANE_MAX_CORES='1', PYTHONDONTWRITEBYTECODE='1')

    def terminal():
        # Only the interactive client uses the wrapper; RPC commands use the real CLI.
        original = session.args
        session.args = argparse.Namespace(**{**vars(args), 'client': wrapper})
        try:
            return Terminal(session)
        finally:
            session.args = original

    def handoff(t, kind, action, size, sha):
        if receipt.exists():
            receipt.unlink()
        start = time.monotonic()
        action()
        while not receipt.exists() and time.monotonic() - start < 125:
            screen = t.drain(.1)
            if 'Simulation export: ' in screen or 'export failed' in screen.lower():
                t.save(kind + '-export-error', screen)
                raise AssertionError(kind + ': ' + screen)
        t.capture(kind + '-export-result')
        if not receipt.exists():
            save(evidence / (kind + '-failure.json'), dict(
                elapsed_seconds=time.monotonic() - start,
                viewer_launched=False,
                partial_paths=[str(p) for p in (evidence / 'tmp').glob('hardcaml*export*partial*')
                               if not p.name.endswith('-verified')]))
        check(receipt.exists(), kind + ': external handoff completes within export deadline')
        r = json.loads(receipt.read_text())
        path = Path(r['path'])
        check(r['at'] - start <= 120, kind + ': handoff stays within the 120-second policy')
        check(r['size'] == path.stat().st_size == size and r['sha256'] == digest(path) == sha,
              kind + ': exported bytes match source size and SHA256')
        check(path.is_relative_to(evidence / 'tmp') and path.parent.name.endswith('-verified')
              and r['mode'] == 0o600 and r['directory_mode'] == 0o700
              and stat.S_IMODE((path.parent / 'metadata.sexp').stat().st_mode) == 0o600,
              kind + ': viewer sees only atomically published private file and metadata')
        check(not [p for p in (evidence / 'tmp').glob('hardcaml*export*partial*')
                   if not p.name.endswith('-verified')], kind + ': no partial export remains')
        exports.append(dict(kind=kind, seconds=r['at'] - start, **r))
        save(evidence / 'exports.json', exports)
        return r

    with ExitStack() as cleanup:
        cleanup.callback(session.stop)
        def unchanged():
            check(all(digest(path) == sha for path, sha in watched.items()),
                  'retained ASIC input bytes remain unchanged')
        cleanup.callback(unchanged)
        session.start()
        if args.case in ('all', 'simulation'):
            catalog = session.discover()
            snap = session.api(operation=['Launch', ['submission_key', 'wb040-64mib'],
                ['discovery_digest', field(catalog, 'discovery_digest')[0]], ['selection', [
                    ('suite', 'controlled-fifo'), ('cases', ['export-stress']), ('seed', '42'),
                    ('parameters', [('checker', 'normal'), ('cycles', '4096'), ('trace_mib', '64')]),
                    ('asic_inputs', [])]]])
            attempt_id = field(field(snap, 'attempts')[0], 'id')
            snap = session.until(['Observe', attempt_id], lambda s:
                field(field(s, 'detail')[0], 'lifecycle') not in ('Queued', 'Running'), timeout=120)
            detail = field(snap, 'detail')[0]
            save(evidence / 'simulation.json', detail)
            check(field(detail, 'lifecycle') == 'Finished' and field(detail, 'outcome') == 'Passed',
                  'real FIFO provider passes 64 MiB simulation')
            wave = next(a for a in field(detail, 'artifacts') if field(a, 'label') == 'export-stress.vcd')
            size, sha = int(field(wave, 'size')[0]), field(wave, 'sha256')[0]
            check(size == 64 * 1024 * 1024, 'registered real simulation trace is exactly 64 MiB')
            # Known seed-42 fixture from independently checked native Cyclesim generation.
            check(sha == 'a4662d87338898d3b328a56a9d74692adf2cfc21701c62d21c96c0a0a9b8952e',
                  'fresh provider trace matches independently verified seed-42 fixture')
            with ExitStack() as clients:
                t = terminal()
                clients.callback(t.close)
                t.capture('simulation-startup', ['Overview'])
                t.palette('Switch to Testing')
                for _ in range(5):
                    t.key(b'\t')
                t.palette('Simulation: Reopen ' + attempt_id + ' controlled-fifo')
                t.palette('Simulation: Select case export-stress')
                r = handoff(t, 'simulation', lambda: t.palette(
                    'Simulation: Open external viewer export-stress.vcd'), size, sha)
                check(wire.parse(r['metadata']) == wave,
                      'simulation export metadata preserves exact captured attempt/artifact identity')

        if args.case == 'simulation':
            return

        # Adopt existing ASIC evidence into this private session, then use the
        # actual Reports/Artifacts b key, not a separate test exporter.
        reference = [[key, manifest['allocation'][key]] for key in ('attempt', 'stream_id')]
        snap = session.rpc('asic', '(Register ' + native.fs0.sexp(reference) + ')', wait=True)
        run_ref = field(field(snap, 'runs')[0], 'run')
        run_sexp = native.fs0.sexp(run_ref)
        session.rpc('asic', '(Load_summary ' + run_sexp + ')', wait=True)
        session.rpc('asic', '(Inspect_finalization (run ' + run_sexp + ') (attempt ' +
                    native.fs0.sexp(manifest['finalization']) + '))', wait=True)
        snap = session.rpc('asic', '(List_artifacts ' + run_sexp + ')', wait=True)
        artifacts = field(snap, 'artifacts')
        save(evidence / 'asic-artifacts.json', artifacts)
        index, artifact = next((i, a) for i, a in enumerate(artifacts)
                               if field(a, 'path').endswith('.gds'))
        source = Path(field(artifact, 'path'))
        check(field(artifact, 'run') == run_ref and
              field(artifact, 'terminal_attempt') == manifest['finalization'] and
              digest(source) == field(artifact, 'sha256') == watched[source] and
              0 < source.stat().st_size <= 16 * 1024 * 1024,
              'ASIC catalog retains real GDS run/finalization identity and eligible digest/size')
        ws = session.rpc('workspace')
        context = next(c for c in field(ws, 'contexts') if field(c, 'id') == field(ws, 'main_context'))
        workspace = next(w for w in field(ws, 'workspaces') if field(w, 'context') == field(context, 'id'))
        session.mutate(ws, '(Select_run (workspace %s) (context %s) (expected_selection_revision %s) (run (%s)))' %
                       (field(workspace, 'id'), field(context, 'id'), field(context, 'selection_revision'), run_sexp))
        with ExitStack() as clients:
            t = terminal()
            clients.callback(t.close)
            t.capture('asic-startup')
            t.palette('Switch to Overview')
            t.palette('Browse reports/artifacts asic/' + field(run_ref, 'id'))
            t.capture('asic-catalog', ['REPORTS / ARTIFACTS', 'b: export exact physical binary'])
            for _ in range(index):
                t.key(b'\x1b[B')
            t.key(b'\r')
            t.capture('asic-selected', ['SHA256: ' + digest(source)])
            r = handoff(t, 'asic', lambda: t.key(b'b'), source.stat().st_size, digest(source))
            meta = wire.parse(r['metadata'])
            check(meta[0] == 'terminal-host-exact-binary-export' and
                  field(meta[1:], 'original_reference') == artifact and
                  field(meta[1:], 'verified_sha256') == digest(source),
                  'ASIC handoff preserves exact original reference and verified digest')
        calls = [json.loads(line) for line in (evidence / 'provider-calls.jsonl').read_text().splitlines()]
        check(all(c['allowed'] for c in calls), 'all real ASIC provider calls were read-only')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('daemon', 'client', 'fifo-provider', 'fifo-simulator', 'asic-manifest'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--case', choices=('all', 'simulation', 'asic'), default='all')
    args = p.parse_args()
    for key, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, key, value.resolve(strict=True))
    args.outer_timeout = 90
    os.umask(0o077)
    evidence = Path(tempfile.mkdtemp(prefix='wb040-real-export-', dir='/tmp/opencode'))
    print('Evidence: ' + str(evidence), flush=True)
    def deadline(*_):
        raise TimeoutError('WB-040 acceptance exceeded 600-second budget')
    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(600)
    try:
        run(args, evidence)
        save(evidence / 'result.json', dict(status='passed'))
    except BaseException as error:
        save(evidence / 'result.json', dict(status='failed', error=str(error)))
        raise
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


if __name__ == '__main__':
    main()
