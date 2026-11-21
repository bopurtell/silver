#!/usr/bin/env python3
"""Private production daemon/PTY handoff checks; no build or simulator invocation."""
import argparse
import base64
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import signal
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wire = load('handoff_wire', ROOT / 'scripts/fixtures/simulation_fixture_wire.py')
testing_layout = load('handoff_testing_layout', ROOT / 'scripts/fixtures/testing_layout.py')
TESTING_TAB = re.compile(r'\A[^\n]*\[2 Testing\]')
WAVEFORMS_TAB = re.compile(r'\A[^\n]*\[3 Waveforms\]')


def handoff_vcd(case):
    lines = ['$timescale 1 ns $end', f'$scope module {case} $end',
             '$var wire 1 ! clk $end']
    # More than twenty rows, and a sparse time range that starts compressed.
    # Keep the original clock reference so the handoff identity checks still apply.
    signals = range(1, 24) if case == 'flops256' else ()
    lines.extend(f'$var wire 1 s{i} s{i:02d} $end' for i in signals)
    if signals:
        lines.append('$var wire 1 f fifo_full $end')
    lines.extend(('$upscope $end', '$enddefinitions $end', '#0', '0!'))
    lines.extend(f'0s{i}' for i in signals)
    if signals:
        # Two FIFO edges share a compressed column, and none is a clock edge.
        lines.extend(('0f', '#5', '1!', '#131', '1f', '#133', '0f',
                      '#347', '1f', '#8192', '0!'))
    else:
        lines.extend(('#5', '1!', '#10', '0!'))
    return '\n'.join(lines) + '\n'


def provider():
    p = argparse.ArgumentParser()
    p.add_argument('operation')
    p.add_argument('--protocol-version')
    p.add_argument('--request', type=Path)
    p.add_argument('--events', type=Path)
    p.add_argument('--artifact-dir', type=Path)
    a = p.parse_args(sys.argv[2:])
    if a.operation == 'discover':
        suite = Path('suite-id').read_text().strip()
        print(wire.sexp(wire.catalog(suite=suite, cases=['flops256', 'exact256'])))
        return
    request = dict(wire.parse(a.request.read_text()))
    selection = dict(request['selection'])
    writer = wire.EventWriter(a.events, request['attempt_id'])
    writer.emit('Started')
    for case in selection['cases']:
        writer.emit(['Case_started', case])
        path = a.artifact_dir / (case + '.json')
        path.write_text(json.dumps(dict(contract='hardcaml-workbench.pt8-result-reference',
            schema_version=1, result='/retained/' + case + '/result.json', source_digest='a' * 64)))
        writer.artifact(case + '-result-reference', case, 'json', 'application/json', path.name)
        # JSON-only run, then mixed artifacts with distinct case-specific signal names.
        if selection['seed'] == '2':
            path = a.artifact_dir / (case + '.vcd')
            path.write_text(handoff_vcd(case))
            writer.artifact(case + '-waveform', case, 'trace', 'text/vcd', path.name)
        writer.finish_case(case)
    writer.emit(['Finished', 'Passed'])


def check_waveform_modal_keys(terminal, check):
    count = re.compile(r'\bCount: *\d+\b', re.IGNORECASE)
    cursor_and_window = re.compile(r'Cursor (\d+) ticks .*?window (\d+)\.\.(\d+)')
    visual = 'Visual line ('

    def focus(title):
        # Click the visible frame title rather than a Signals row: focusing a
        # tile must not itself change the selected signal or cursor.
        screen = terminal.capture('counts-focus-' + title, [f'╭ {title} '])
        for y, line in enumerate(screen.splitlines(), 1):
            if f'╭ {title} ' in line:
                x = line.index(f'╭ {title} ') + 3
                terminal.key(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m'.encode())
                return

    def state(label, tick=None, *, pending=None, expected=(), absent=()):
        expectations = [WAVEFORMS_TAB, '╭ Waves ', cursor_and_window, *expected]
        if tick is not None:
            expectations.append(f'Cursor {tick} ticks')
        if pending is not None:
            expectations.append(re.compile(rf'\bCount: *{pending}\b', re.IGNORECASE))
        else:
            absent = [count, *absent]
        screen = terminal.capture('waveform-' + label, expectations, absent=absent)
        return tuple(map(int, cursor_and_window.search(screen).groups()))

    def signal_row(name, *, enabled=None, marker='[>~ ]'):
        flag = {True: r'\*', False: ' ', None: '[ *]'}[enabled]
        return re.compile(rf'{marker}\[{flag}\] flops256\.{name}\b')

    def active_signal(name):
        return signal_row(name, marker='>')

    focus('Waves')
    initial = state('start', 0, expected=['Compressed edges', active_signal('clk')])
    for _ in range(20):
        terminal.key(b'l')
    repeated = state('twenty-single-columns')
    check(repeated[0] > 20, 'fixture distinguishes compressed columns from exact ticks')
    terminal.key(b'g')
    state('rewind', 0)

    terminal.key(b'2')
    check(state('pending-two', 0, pending=2) == initial, 'first digit neither moves nor pans')
    terminal.key(b'0')
    check(state('pending-twenty', 0, pending=20) == initial, 'second digit extends count without motion')
    terminal.key(b'l')
    check(state('twenty-columns', repeated[0]) == repeated,
          '20l matches twenty single l presses, including viewport')
    terminal.key(b'20h')
    state('twenty-columns-back', 0)
    terminal.key(b'20h')
    state('column-clamps-at-start', 0)
    terminal.key(b'20L')
    state('twenty-ticks', 20)
    terminal.key(b'H')
    state('consumed-count', 19)
    terminal.key(b'20H')
    state('tick-clamps-at-start', 0)
    terminal.key(b'GH')
    state('one-before-end', 8191)
    terminal.key(b'20L')
    state('tick-clamps-at-end', 8192)
    terminal.key(b'H')
    state('one-before-column-clamp', 8191)
    terminal.key(b'20l')
    state('column-clamps-at-end', 8192)
    terminal.key(b'20')
    state('before-non-motion', 8192, pending=20)
    terminal.key(b'g')
    state('non-motion-cancels-and-still-rewinds', 0)

    terminal.key(b'20j')
    state('twenty-rows', 0, expected=[active_signal('s20')])
    terminal.key(b'3k')
    state('three-rows-back', 0, expected=[active_signal('s17')])
    terminal.key(b'20k')
    state('row-clamps-at-start', 0, expected=[active_signal('clk')])

    terminal.key(b'20')
    state('before-escape', 0, pending=20)
    terminal.key(b'\x1b')
    state('escape-cancels', 0)
    terminal.key(b'L')
    state('single-tick-after-escape', 1)

    terminal.key(b'20')
    state('before-palette', 1, pending=20)
    for key in (b' ', b'c', b'c'):
        terminal.key(key)
    terminal.capture('counts-palette-opens', ['COMMAND PALETTE'])
    terminal.key(b'\x1b')
    state('palette-cancels', 1, absent=['COMMAND PALETTE'])
    terminal.key(b'L')
    state('single-tick-after-palette', 2)

    terminal.key(b'20')
    state('before-tab', 2, pending=20)
    terminal.key(b'\t')
    state('tab-cancels', 2)
    focus('Signals')
    terminal.key(b'2')
    state('signals-digit-is-local', 2, expected=[active_signal('clk')])
    terminal.key(b'j')
    state('signals-digit-does-not-count', 2, expected=[active_signal('s01')])
    focus('Waves')
    terminal.key(b'L')
    state('return-to-waves-has-no-count', 3)

    focus('Signals')
    terminal.key(b'/20')
    state('digits-in-filter-edit', 3, expected=[re.compile(r'/ 20 *(?:[│|]|·)')])
    terminal.key(b'\r')
    state('digits-in-filter-applied', 3, expected=['1 matching', active_signal('s20')])
    terminal.key(b'/\x1799\r')
    state('filter-no-matches', 3, expected=['0 matching'])
    terminal.key(b'2')
    state('signals-owns-digits-even-when-empty', 3, expected=['0 matching'])

    # The VCD declares clk and s01–s07 first, so the initial eight enabled
    # signals straddle the s07/s08 boundary. Filter to s01–s09 to test both
    # visible neighbors and ensure bulk actions don't touch filtered-out clk.
    terminal.key(b'/\x17s0\rjjjjjj')
    s06 = signal_row('s06', enabled=True, marker=' ')
    s07_on = signal_row('s07', enabled=True)
    s08_off = signal_row('s08', enabled=False)
    s09 = signal_row('s09', enabled=False, marker=' ')
    state('visual-fixture', 3, expected=[
        '9 matching · 8 enabled', active_signal('s07'), s06, s07_on, s08_off, s09],
        absent=[visual])
    terminal.key(b'V')
    state('visual-start', 3, expected=['Visual line (1)', active_signal('s07')])
    terminal.key(b'jj')
    state('visual-extends-down', 3, expected=[
        'Visual line (3)', signal_row('s07', enabled=True, marker='~'),
        signal_row('s08', enabled=False, marker='~'), active_signal('s09')])
    terminal.key(b'k')
    state('visual-shrinks-on-k', 3, expected=[
        'Visual line (2)', active_signal('s08'), s09])
    terminal.key(b'\r')
    s08_on = signal_row('s08', enabled=True)
    state('visual-enter-enables-mixed-range', 3, expected=[
        '9 matching · 9 enabled', s06, s07_on, s08_on, s09], absent=[visual])

    terminal.key(b'Vk')
    state('visual-extends-up', 3, expected=[
        'Visual line (2)', active_signal('s07'), signal_row('s08', enabled=True, marker='~')])
    terminal.key(b'\x1b')
    state('visual-escape-keeps-both-enabled', 3, expected=[
        '9 matching · 9 enabled', s06, s07_on, s08_on, s09], absent=[visual])
    terminal.key(b'Vj\r')
    state('visual-enter-disables-all-enabled-range', 3, expected=[
        '9 matching · 7 enabled', s06, signal_row('s07', enabled=False), s08_off, s09],
        absent=[visual])
    terminal.key(b'/\x17\r')
    state('visual-leaves-filtered-out-signal-enabled', 3, expected=[
        '25 matching · 7 enabled', signal_row('clk', enabled=True)], absent=[visual])
    check(True, 'Signals visual mode expands in both directions, toggles only the range, and cancels')

    # The narrow Signals name column may elide the start of the scope.
    fifo_full = re.compile(r'>\[ \] (?:flops256|…256)\.fifo_full\b')
    terminal.key(b'/fifo\r')
    state('edge-fixture', 3, expected=['1 matching · 7 enabled', fifo_full, 'Compressed edges'])
    terminal.key(b'\t')  # Signals → Waves, leaving fifo_full focused but disabled.
    terminal.key(b'w')
    state('edge-next-fifo-full-asserts', 131, expected=[fifo_full])
    terminal.key(b'2')
    state('edge-count-pending', 131, pending=2, expected=[fifo_full])
    terminal.key(b'w')
    state('edge-counted-forward', 347, expected=[fifo_full])
    terminal.key(b'2p')
    state('edge-counted-backward', 131, expected=[fifo_full])
    terminal.key(b'n')
    state('edge-next-within-compressed-column', 133, expected=[fifo_full])
    terminal.key(b'b')
    state('edge-previous-within-compressed-column', 131, expected=[fifo_full])
    terminal.key(b'\x1b[Z')  # Shift-Tab: Waves → Signals.
    terminal.key(b'/\x17\r')
    state('edge-focus-clock-at-same-tick', 131, expected=[active_signal('clk')])
    terminal.key(b'\t')
    terminal.key(b'w')
    state('edge-next-clock', 8192, expected=[active_signal('clk')])
    terminal.key(b'b')
    state('edge-previous-clock', 5, expected=[active_signal('clk')])
    check(True, 'Waves w/b follows exact transitions of the signal focused in Signals, even disabled')

    focus('Session')
    terminal.key(b'2')
    terminal.capture('counts-session-digit-switches-to-testing',
                     [TESTING_TAB, 'simulation-artifacts'],
                     absent=['╭ Waves ', count])
    check(True, 'Waves counts are consumed or cancelled; Signals and Session route digits by focus')


def run(args, evidence):
    print('Evidence: ' + str(evidence), flush=True)
    native = load('handoff_native', ROOT / 'scripts/test-native-simulation.py')
    embedded = load('handoff_embedded', ROOT / 'scripts/test-embedded-waveform.py')
    field = native.field
    for name in ('project', 'state', 'home', 'config', 'tmp'):
        (evidence / name).mkdir()
    root = evidence / 'project'
    (root / 'dune-project').write_text('(lang dune 3.22)\n(name handoff)\n')
    (root / 'hardcaml-workbench-simulation.sexp').write_text(wire.sexp([
        ('schema_version', 1), ('provider_executable', sys.executable),
        ('provider_args', [str(Path(__file__).resolve()), '_provider']),
        ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 30)]))
    session = native.Session(args, evidence, root)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        XDG_CACHE_HOME=str(evidence / 'cache'), XDG_DATA_HOME=str(evidence / 'data'),
        TMPDIR=str(evidence / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
        OMP_NUM_THREADS='2', OPENROAD_THREADS='2', _OPENLANE_MAX_CORES='2')
    terminal = proxy = None
    checks = []

    class Terminal(native.Terminal):
        def __init__(self, session):
            # Give stock Waveforms' narrow left column enough room to display
            # full signal names and enabled totals, alongside the Waves plot.
            super().__init__(session, width=200, height=50)

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
        if not value:
            raise AssertionError(label)
        print('PASS ' + label, flush=True)

    try:
        session.start()
        attempts = []
        # Retain a capture from the old catalog before switching to the renamed suite.
        for seed, suite in [('1', 'pt8-memory-workloads'), ('2', 'memory-workloads')]:
            (root / 'suite-id').write_text(suite)
            catalog = session.discover()
            check([field(s, 'id') for s in field(field(catalog, 'discovery')[0], 'suites')]
                == [suite], 'discovery advertises only ' + suite)
            snap = session.api(operation=['Launch', ['submission_key', 'seed-' + seed],
                ['discovery_digest', field(catalog, 'discovery_digest')[0]], ['selection', [
                    ('suite', suite), ('cases', ['flops256', 'exact256']), ('seed', seed),
                    ('parameters', []), ('asic_inputs', [])]]])
            attempts.append(session.done(field(field(snap, 'attempts')[0], 'id')))
        proxy = embedded.DelayedBytesProxy(session.url, evidence)
        session.url = proxy.url
        viewer_receipt = evidence / 'viewer.json'
        viewer = evidence / 'record-viewer.py'
        viewer.write_text('#!' + sys.executable + '\nimport hashlib,json,pathlib,sys\n'
            'p=pathlib.Path(sys.argv[1])\n'
            'pathlib.Path(' + repr(str(viewer_receipt)) + ').write_text(json.dumps(dict('
            'path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest())))\n')
        viewer.chmod(0o700)
        wrapper = evidence / 'client-with-viewer'
        wrapper.write_text('#!' + sys.executable + '\nimport os,sys\nos.execv(' +
            repr(str(args.client)) + ', [' + repr(str(args.client)) +
            ', "--simulation-viewer", ' + repr(str(viewer)) + '] + sys.argv[1:])\n')
        wrapper.chmod(0o700)
        session.args = argparse.Namespace(**vars(args))
        session.args.client = wrapper
        terminal = Terminal(session)
        terminal.capture('startup', [re.compile(r'\A[^\n]*\[1 Overview\]')])
        terminal.key(b'2')
        terminal.capture('overview-digit-switches-to-testing', [TESTING_TAB, 'simulation-artifacts'])
        testing_layout.focus_pane(terminal, 'simulation-attempts')

        def reopen(attempt):
            suite = field(field(field(attempt, 'captured'), 'selection'), 'suite')
            terminal.palette('Simulation: Reopen ' + field(attempt, 'id') + ' ' + suite)
            terminal.palette('Simulation: Select case flops256')

        def check_inspect_action(label):
            # Exercise discovery of the action without executing nonexistent retained paths.
            for key in (b' ', b'c', b'c'):
                terminal.key(key)
            terminal.key(b'Inspect workload result (selected Testing case)')
            terminal.capture(label, ['Inspect workload result'], absent=['No matching commands'])
            terminal.key(b'\x1b')

        reopen(attempts[0])
        testing_layout.focus_pane(terminal, 'simulation-artifacts')
        terminal.key(b'w')
        terminal.capture('json-only-no-vcd', ['No available supported VCD'],
            absent=['Embedded viewer supports VCD only', 'Captured waveform identity'])
        check(not proxy.records, 'JSON-only w does not fetch/pin a JSON waveform')
        check_inspect_action('legacy-json-inspect-action')
        check(True, 'legacy JSON-only case retains Inspect workload result action')
        reopen(attempts[1])
        check_inspect_action('current-json-inspect-action')
        check(True, 'current mixed case exposes Inspect workload result action')
        terminal.key(b'w')
        terminal.capture('mixed-flops-quick', ['flops256.clk', 'Cursor'], absent=['exact256.clk'])
        check(all('flops256-waveform' in r['request']['artifact_id'] for r in proxy.records),
            'mixed w fetches only exact selected flops waveform')
        check(b'\x1b]52;' not in terminal.data,
            'embedded waveform loading never requests clipboard writes')
        terminal.key(b'\x1b')
        terminal.key(b'e')
        # The notice wraps in the narrower History column. Verify the full
        # clipboard outcome from the OSC 52 payload rather than one screen row.
        terminal.capture('export-clipboard', ['Export ready; path sent'],
            absent=['Verified simulation bytes retained:'])
        copies = re.findall(rb'\x1b\]52;c;([A-Za-z0-9+/=]+)\x07', bytes(terminal.data))
        check(len(copies) == 1, 'successful verified external export emits one OSC52 request')
        exported = Path(os.fsdecode(base64.b64decode(copies[0], validate=True)))
        check(exported.is_file() and '$scope module flops256 ' in exported.read_text(),
            'clipboard decodes to the actual completed terminal-host trace file')
        terminal.key(b'\x1b[19~')  # F8
        terminal.capture('export-path-fallback', ['Last simulation export:',
            'Exact path (OCaml string):', 'F9 retries OSC 52'])
        terminal.key(b'\x1b[20~')  # F9
        copies = re.findall(rb'\x1b\]52;c;([A-Za-z0-9+/=]+)\x07', bytes(terminal.data))
        check(copies == [copies[0], copies[0]], 'F9 resends the exact retained path')
        terminal.key(b'\x1b[19~')  # F8 returns to Testing

        # Hold a real HTTP byte reply until after an actual attempt-selection
        # command. Cancellation must clean up without waiting for that reply.
        before_exports = set((evidence / 'tmp').glob('hardcaml*'))
        before_copies = len(re.findall(rb'\x1b\]52;c;', bytes(terminal.data)))
        gate = proxy.arm('cancel-external-export')
        terminal.key(b'v')
        check(gate['ready'].wait(10), 'external export reached deliberately held byte reply')
        partials = set((evidence / 'tmp').glob('hardcaml*')) - before_exports
        check(bool(partials) and all(not p.name.endswith('-verified') for p in partials),
            'in-flight export owns private partial storage before cancellation')
        reopen(attempts[0])
        deadline = time.monotonic() + 5
        while any(p.exists() for p in partials) and time.monotonic() < deadline:
            terminal.drain(.05)
        check(all(not p.exists() for p in partials),
            'UI attempt switch removes partial storage while HTTP reply is still held')
        check(not gate['release'].is_set() and not gate['timed_out'],
            'cleanup precedes explicit transport release, not the export timeout')
        check(not viewer_receipt.exists(), 'cancelled export never launches external viewer')
        gate['release'].set()
        check(gate['delivered'].wait(5) and not gate['timed_out'],
            'late cancelled reply released within bounded gate deadline')
        terminal.drain(.3)
        check(set((evidence / 'tmp').glob('hardcaml*')) == before_exports,
            'late reply cannot recreate partial storage or publish cancelled export')
        check(not viewer_receipt.exists() and
            len(re.findall(rb'\x1b\]52;c;', bytes(terminal.data))) == before_copies,
            'late cancelled reply triggers neither viewer nor clipboard handoff')
        reopen(attempts[1])
        terminal.key(b'v')
        deadline = time.monotonic() + 10
        while not viewer_receipt.exists() and time.monotonic() < deadline:
            terminal.drain(.05)
        check(viewer_receipt.exists(), 'fresh export after cancellation releases busy reservation')
        receipt = json.loads(viewer_receipt.read_text())
        check(receipt['sha256'] == hashlib.sha256(exported.read_bytes()).hexdigest()
            and Path(receipt['path']).parent.name.endswith('-verified'),
            'headless recording viewer receives only the verified byte-exact file')
        terminal.palette('Simulation: Select case exact256')
        gate = proxy.arm('late-exact-quick')
        terminal.key(b'w')
        check(gate['ready'].wait(10), 'held exact-case waveform byte reply reached transport')
        terminal.key(b'\x1b')
        terminal.palette('Simulation: Select case flops256')
        terminal.key(b'W')
        terminal.capture('flops-workspace', ['Signals', 'Waves', 'Pinned: flops256-waveform'],
            absent=['exact256-waveform'])
        gate['release'].set()
        time.sleep(.3)
        terminal.capture('late-exact-fenced', ['Pinned: flops256-waveform'], absent=['exact256-waveform'])
        check(True, 'late exact-case reply cannot replace flops workspace pin/model')
        for key in (b' ', b'c', b'c'):
            terminal.key(key)
        terminal.key(b'Waveform: Select VCD exact256-waveform')
        terminal.capture('picker-cross-case-absent', ['No matching commands'])
        terminal.key(b'\x1b')
        check(True, 'pinned case picker excludes another case VCD')
        check_waveform_modal_keys(terminal, check)
        check(all(r['request']['artifact_id'].endswith('-waveform') for r in proxy.records),
            'production byte requests never target result-reference JSON')
        terminal.palette('Workloads: Launch fresh memory workload')
        terminal.capture('memory-workload-launch', ['Suite: memory-workloads'])
        check(True, 'Workloads launch opens Testing with the renamed suite')
    finally:
        # A deadline interrupts the scenario, not its bounded cleanup. ExitStack
        # still attempts every cleanup if a preceding callback raises.
        signal.alarm(0)
        with ExitStack() as cleanup:
            def receipts():
                (evidence / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
                (evidence / 'binaries.json').write_text(json.dumps({name: dict(path=str(getattr(args, name)),
                    sha256=hashlib.sha256(getattr(args, name).read_bytes()).hexdigest())
                    for name in ('client', 'daemon')}, indent=2) + '\n')
            cleanup.callback(receipts)
            cleanup.callback(session.stop)
            if proxy:
                cleanup.callback(proxy.close)
            if terminal:
                cleanup.callback(terminal.close)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--daemon', type=Path, required=True)
    p.add_argument('--client', type=Path, required=True)
    p.add_argument('--ephemeral', action='store_true',
        help='remove owned state/evidence on exit (Dune); default retains historical evidence')
    p.add_argument('--timeout-seconds', type=int, default=180)
    args = p.parse_args()
    if not 1 <= args.timeout_seconds <= 300:
        p.error('--timeout-seconds must be 1..300')
    args.daemon, args.client = args.daemon.resolve(strict=True), args.client.resolve(strict=True)
    if not args.daemon.is_file() or not args.client.is_file():
        p.error('--daemon and --client must name prebuilt executable files')
    os.umask(0o077)

    def deadline(*_):
        raise TimeoutError('waveform handoff smoke budget exhausted')

    previous = signal.signal(signal.SIGALRM, deadline)
    try:
        with ExitStack() as cleanup:
            if args.ephemeral:
                evidence = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix='workload-waveform-pty-')))
            else:
                evidence = Path(tempfile.mkdtemp(prefix='workload-waveform-pty-', dir='/tmp/opencode'))
            signal.alarm(args.timeout_seconds)
            run(args, evidence)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


if __name__ == '__main__':
    provider() if len(sys.argv) > 1 and sys.argv[1] == '_provider' else main()
