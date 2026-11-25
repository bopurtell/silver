#!/usr/bin/env python3
"""Exercise first Waveforms paint from Overview against an isolated real daemon."""
import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import struct
import sys
import tempfile
import termios
import time

sys.dont_write_bytecode = True
import test_waveform_handoff_pty as handoff


def run(args, evidence):
    print(f'Evidence: {evidence}', flush=True)
    root = handoff.ROOT
    native = handoff.load('waveform_prep_native', root / 'scripts/test-native-simulation.py')
    embedded = handoff.load('waveform_prep_proxy', root / 'scripts/test-embedded-waveform.py')
    field = native.field
    project = evidence / 'project'
    for name in ('project', 'state', 'home', 'config', 'tmp'):
        (evidence / name).mkdir()
    (project / 'dune-project').write_text('(lang dune 3.22)\n(name waveform_prepare)\n')
    (project / 'suite-id').write_text('waveform-fixture\n')
    (project / 'silver-simulation.sexp').write_text(handoff.wire.sexp([
        ('schema_version', 1), ('provider_executable', sys.executable),
        ('provider_args', [str(Path(handoff.__file__).resolve()), '_provider']),
        ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 30)]))
    session = native.Session(args, evidence, project)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        XDG_CACHE_HOME=str(evidence / 'cache'), XDG_DATA_HOME=str(evidence / 'data'),
        TMPDIR=str(evidence / 'tmp'), SILVER_TRACE_WAVEFORM_PREPARATION='1')
    diagnostics = evidence / 'client.log'
    overview = re.compile(r'\A[^\n]*\[1 Overview\]')
    checks = []

    class Terminal(native.Terminal):
        def palette(self, title):
            for key in (b' ', b'c', b'c'):
                self.key(key)
            self.key(title.encode())
            self.capture('query-' + str(time.time_ns()), ['COMMAND PALETTE', title[-60:]],
                         absent=['No matching commands'])
            self.key(b'\x1b[A' * 24)
            self.key(b'\r')

    def check(value, label):
        checks.append(dict(passed=bool(value), expectation=label))
        assert value, label
        print('PASS ' + label, flush=True)

    with ExitStack() as cleanup:
        cleanup.callback(lambda: (evidence / 'checks.json').write_text(json.dumps(checks, indent=2)))
        cleanup.callback(session.stop)
        session.start()
        catalog = session.discover()

        def launch(key, case, seed):
            snap = session.api(operation=['Launch', ['submission_key', key],
                ['discovery_digest', field(catalog, 'discovery_digest')[0]], ['selection', [
                    ('suite', 'waveform-fixture'), ('cases', [case]), ('seed', seed),
                    ('parameters', []), ('asic_inputs', [])]]])
            return session.done(field(field(snap, 'attempts')[0], 'id'))

        missing = launch('json-only', 'flops256', '1')
        multiple = launch('multiple', 'exact256', '3')
        replacement = launch('replacement', 'exact256', '2')
        initial = launch('initial', 'flops256', '2')
        proxy = embedded.DelayedBytesProxy(session.url, evidence)
        cleanup.callback(proxy.close)
        session.url = proxy.url
        def new_terminal():
            return Terminal(session, width=200, height=50, argv=[
                str(args.client), '--connect', session.url, '--project-root', str(project),
                '--diagnostics-file', str(diagnostics)])

        terminal = new_terminal()
        cleanup.callback(lambda: terminal.close())

        def wave(attempt, *, alternate=False):
            return next(a for a in field(attempt, 'artifacts')
                        if field(a, 'media_type') == 'text/vcd'
                        and field(a, 'id').endswith('-alternate-waveform') == alternate)

        def trace():
            return diagnostics.read_text() if diagnostics.exists() else ''

        def wait_prepared(artifact, *, since=0):
            marker = f"waveform viewport prepared {field(artifact, 'id')} {field(artifact, 'sha256')[0]}"
            deadline = time.monotonic() + 12
            while marker not in trace()[since:] and time.monotonic() < deadline:
                terminal.drain(.08)
            check(marker in trace()[since:], 'decoded viewport prepared before switching')

        def switch_ready(label, signal_name, absent_signal):
            reads, log, start = len(proxy.records), len(trace()), len(terminal.data)
            terminal.key(b'3')
            terminal.capture(label, [handoff.WAVEFORMS_TAB, '╭ Waves ', 'Cursor 0 ticks',
                signal_name, re.compile(r'[┌┐┘└]─{3,}')],
                absent=[absent_signal, 'VCD unavailable'])
            check(len(proxy.records) == reads and 'waveform read ' not in trace()[log:],
                  label + ': no waveform byte reads on switch')
            check('waveform viewport foreground ' not in trace()[log:]
                  and b'Fetching bounded bytes' not in terminal.data[start:],
                  label + ': no first-paint loading or foreground rendering')

        def select_attempt(attempt):
            terminal.key(b'2')
            terminal.capture('testing-' + str(time.time_ns()), [handoff.TESTING_TAB])
            handoff.testing_layout.focus_pane(terminal, 'simulation-attempts')
            terminal.palette('Simulation: Reopen ' + field(attempt, 'id') + ' waveform-fixture')
            terminal.key(b'1')
            terminal.capture('overview-' + str(time.time_ns()), [overview])

        terminal.capture('startup-overview', [overview])
        wait_prepared(wave(initial))
        terminal.capture('idle-before-first-switch', [overview])
        switch_ready('first-switch', 'flops256.clk', 'exact256.clk')

        # Do not let the replacement decode before we are back on Overview.
        gate = proxy.arm('changed-artifact')
        select_attempt(replacement)
        check(gate['ready'].wait(10), 'changed identity requests its exact bytes')
        check(gate['request']['artifact_id'] == field(wave(replacement), 'id')
              and gate['request']['sha256'] == field(wave(replacement), 'sha256')[0],
              'changed artifact request carries the new digest')
        select_attempt(missing)
        terminal.key(b'3')
        terminal.capture('held-source-invalidated', [handoff.WAVEFORMS_TAB,
            'No retained waveform source'], absent=['Cursor 0 ticks'])
        gate['release'].set()
        check(gate['delivered'].wait(5) and not gate['timed_out'], 'late reply was released')
        terminal.capture('late-reply-ignored', [handoff.WAVEFORMS_TAB, 'No retained waveform source'],
                         absent=['Cursor 0 ticks', 'exact256.clk'])
        check('waveform viewport prepared ' + field(wave(replacement), 'id') not in trace(),
              'superseded bytes do not publish a viewport')
        select_attempt(replacement)
        wait_prepared(wave(replacement))
        terminal.capture('idle-before-changed-switch', [overview])
        switch_ready('changed-switch', 'exact256.clk', 'flops256.clk')

        terminal.key(b'1')
        terminal.capture('before-resize', [overview])
        before, reads = len(trace()), len(proxy.records)
        terminal.width = 190
        fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 190, 0, 0))
        # Popen starts a new session that does not own the PTY as controlling
        # terminal, so changing its size alone need not deliver SIGWINCH.
        os.kill(terminal.process.pid, signal.SIGWINCH)
        wait_prepared(wave(replacement), since=before)
        check(len(proxy.records) == reads, 'new terminal geometry reprojects without reading bytes')
        switch_ready('resized-switch', 'exact256.clk', 'flops256.clk')

        select_attempt(multiple)
        reads = len(proxy.records)
        terminal.key(b'3')
        terminal.capture('ambiguous-source', [handoff.WAVEFORMS_TAB, 'Multiple applicable VCDs'],
                         absent=['Cursor 0 ticks'])
        check(len(proxy.records) == reads, 'default Testing cursor does not pick an ambiguous VCD')
        terminal.key(b'2')
        handoff.testing_layout.focus_pane(terminal, 'simulation-artifacts')
        before = len(trace())
        terminal.key(b'j')
        terminal.key(b'1')
        terminal.capture('before-selected-vcd', [overview])
        wait_prepared(wave(multiple, alternate=True), since=before)
        switch_ready('exact-testing-selection', re.compile(r'(?:alternate|…ternate)\.clk'),
                     'exact256.clk')

        select_attempt(missing)
        reads = len(proxy.records)
        terminal.key(b'3')
        terminal.capture('no-source', [handoff.WAVEFORMS_TAB, 'No retained waveform source',
            'No available supported VCD'], absent=['Cursor 0 ticks', 'exact256.clk'])
        check(len(proxy.records) == reads, 'JSON-only attempt never becomes a waveform')

        # Explicit W establishes a durable binding; later Testing selection is not a retarget.
        select_attempt(replacement)
        terminal.key(b'2')
        handoff.testing_layout.focus_pane(terminal, 'simulation-artifacts')
        terminal.key(b'W')
        terminal.capture('pin-replacement', [handoff.WAVEFORMS_TAB, 'Pinned: exact256-waveform'])
        select_attempt(initial)
        terminal.capture('idle-before-pinned-restart', [overview])
        terminal.key(b'3')
        terminal.capture('pin-survives-testing-selection',
                         [handoff.WAVEFORMS_TAB, 'Pinned: exact256-waveform', 'exact256.clk'],
                         absent=['flops256.clk'])
        terminal.key(b'1')
        terminal.capture('saved-overview', [overview])
        # Let the normal retained-navigation poll persist the new active tab.
        terminal.drain(1.2)
        terminal.close()
        before = len(trace())
        terminal = new_terminal()
        terminal.capture('restarted-overview', [overview])
        wait_prepared(wave(replacement), since=before)
        switch_ready('restored-pin-switch', 'exact256.clk', 'flops256.clk')
        terminal.capture('restored-pin', ['Pinned: exact256-waveform'])
        check(all(r['request']['artifact_id'].endswith('-waveform') for r in proxy.records),
              'byte requests target only exact VCD artifacts')
        (evidence / 'binaries.json').write_text(json.dumps({
            name: {'path': str(getattr(args, name)),
                   'sha256': hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
            for name in ('client', 'daemon')}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--daemon', type=Path, required=True)
    parser.add_argument('--client', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, help='create and retain this evidence directory')
    args = parser.parse_args()
    args.daemon, args.client = (path.resolve(strict=True) for path in (args.daemon, args.client))
    os.umask(0o077)

    def deadline(*_):
        raise TimeoutError('waveform preparation regression deadline')

    signal.signal(signal.SIGALRM, deadline)
    with ExitStack() as cleanup:
        if args.evidence:
            evidence = args.evidence.resolve()
            evidence.mkdir(mode=0o700)
        else:
            evidence = Path(cleanup.enter_context(tempfile.TemporaryDirectory(
                prefix='waveform-preparation-')))
        signal.alarm(100)
        try:
            run(args, evidence)
        finally:
            signal.alarm(0)
