#!/usr/bin/env python3
"""Bounded WB-068 real-PTY probe; prebuilt binaries, no implicit builds.

Uses the existing FS2 native session, retained-byte provider, and incremental ANSI
screen. Emits private fixtures, binary copies, raw ANSI, timestamped I/O, snapshots
and JSON beneath _build/wb068-evidence/ (or --evidence within this checkout).
Key-to-header and key-to-output-quiet are host observation upper bounds, NOT pure
render CPU timings or physical display frames. Hold means independently scheduled
repeat bytes for exactly 2s, then no more input; terminal protocols have no key-up.
The viewer initially selects eight buses even in the large catalog. Columns are
inferred from the displayed integer raster, not pixel/attribute detection. Holds
start at the window's left edge, so h includes automatic panning. Periodic output
continues after the cursor stops: last_output fields are not release backlog.
--step-mode baseline uses h/l raw ticks; column uses h/l integer-raster column
steps; tick uses H/L raw ticks. Correlation uses each mode's expected tick sequence,
including grid-relative rounding and automatic panning, never raw tick ordinals
for column mode. Skipped header observations are counted, not interpolated.
Default release-tail ceiling is 50 ms (host scheduling allowance, not a physical
one-frame acceptance claim). Observe for at least 1s after release and require
500ms cursor stability, correct final position, and no censored drain.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import sys
import tempfile
import threading
import time
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native = load('wb068_native', 'test-fs2-native.py')
latency = load('wb068_latency', 'test-inspector-latency.py')
wire = load('wb068_wire', 'fixtures/fs2_wire.py')
field = native.field


class Terminal(latency.Terminal):
    def palette(self, title):
        for key in (b' ', b'c', b'c'):
            self.key(key)
            self.idle(.15)
        self.wait(lambda s: 'COMMAND PALETTE' in s, 'palette-open')
        self.key(title.encode())
        self.wait(lambda s: 'COMMAND PALETTE' in s and title[-60:] in s,
                  'palette-query')
        self.key(b'\x1b[A' * 16)
        self.idle(.15)
        assert 'No matching commands' not in self.screen.text(), title
        self.key(b'\r')
        self.wait(lambda s: 'COMMAND PALETTE' not in s, 'palette-closed')


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def state(text):
    cursor = re.search(r'Cursor (\d+) ticks', text)
    window = re.search(r'window (\d+)\.\.(\d+)', text)
    scale = re.search(r'(\d+) (cells/tick|ticks/cell)', text)
    if not all((cursor, window, scale)):
        return None
    tick = int(cursor[1])
    start, stop = map(int, window.groups())
    amount = int(scale[1])
    column = ((tick - start) * amount if scale[2] == 'cells/tick'
              else (tick - start) // amount) if start <= tick <= stop else None
    return dict(tick=tick, start=start, stop=stop, scale=[amount, scale[2]], column=column)


def expected_step(before, key, mode, bounds, capacity=None):
    """Public integer-raster contract; expanded columns still step one whole tick.

    Compressed column targets are previous/next bucket starts on the current
    window-relative grid. Left from inside a bucket goes to the previous bucket,
    not the start of the current bucket. Out-of-window navigation pans to target.
    """
    forward = key.lower() == b'l'
    stride = before['scale'][0] if mode == 'column' and before['scale'][1] == 'ticks/cell' else 1
    remainder = (before['tick'] - before['start']) % stride
    delta = stride - remainder if forward else -(stride + remainder)
    tick = max(bounds[0], min(bounds[1], before['tick'] + delta))
    start = before['start']
    if not before['start'] <= tick <= before['stop']:
        start = tick
    capacity = capacity or before['stop'] - before['start'] + 1
    stop = min(bounds[1], start + capacity - 1)
    amount, unit = before['scale']
    column = (tick - start) * amount if unit == 'cells/tick' else (tick - start) // amount
    return dict(tick=tick, start=start, stop=stop, scale=before['scale'], column=column)


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def fixture(path, signals, steps):
    # 10-tick-spaced transitions, deterministic 8-bit buses; duration exceeds holds.
    with path.open('w') as out:
        out.write('$timescale 1 ns $end\n$scope module top $end\n')
        for i in range(signals):
            out.write('$var wire 8 s%d bus_%03d [7:0] $end\n' % (i, i))
        out.write('$upscope $end\n$enddefinitions $end\n')
        for t in range(steps):
            out.write('#%d\n' % (t * 10))
            for i in range(signals):
                out.write('b%08d s%d\n' % (int(format((t + i) % 256, '08b')), i))
    return dict(signals=signals, timestamps=steps, transitions=signals * steps,
                bounds=[0, (steps - 1) * 10], bytes=path.stat().st_size,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def settle(t, quiet=.04, timeout=8):
    end, last, previous = time.monotonic() + timeout, time.monotonic(), t.offset
    while time.monotonic() < end:
        t.pump(.005)
        if t.offset != previous:
            last, previous = time.monotonic(), t.offset
        if time.monotonic() - last >= quiet:
            return last
    raise AssertionError('output did not become quiet within bounded drain')


def setup(args, directory, source):
    for name in ('project', 'state', 'home', 'config', 'tmp'):
        (directory / name).mkdir()
    root = directory / 'project'
    (root / 'dune-project').write_text('(lang dune 3.22)\n(name wb068_probe)\n')
    (root / 'hardcaml-workbench-simulation.sexp').write_text(wire.sexp([
        ('schema_version', 1), ('provider_executable', sys.executable),
        ('provider_args', [str(HERE / 'test-embedded-waveform.py'), '_provider',
                           '--fixture', str(source), '--calls', str(directory / 'calls.jsonl')]),
        ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 30)]))
    session = native.Session(args, directory, root)
    session.deadline = time.monotonic() + 240
    session.env.update(HOME=str(directory / 'home'), XDG_CONFIG_HOME=str(directory / 'config'),
                       TMPDIR=str(directory / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
                       OMP_NUM_THREADS='1', OPENROAD_THREADS='1', _OPENLANE_MAX_CORES='1')
    return session


def run_case(args, directory, source, metadata, result):
    session = setup(args, directory, source)
    t = None
    try:
        session.start()
        catalog = session.discover()
        snap = session.api(operation=['Launch', ['submission_key', 'wb068'],
            ['discovery_digest', field(catalog, 'discovery_digest')[0]],
            ['selection', [('suite', 'fixture'), ('cases', ['first']), ('seed', '42'),
                           ('parameters', []), ('asic_inputs', [])]]])
        aid = field(field(snap, 'attempts')[0], 'id')
        detail = session.done(aid)
        assert field(detail, 'outcome') == 'Passed'
        t = Terminal(session)
        t.wait(lambda s: 'Overview' in s, 'startup')
        t.idle(1)
        t.palette('Switch to Testing')
        t.wait(lambda s: 'simulation-artifacts' in s, 'testing')
        for _ in range(5):
            t.key(b'\t')
            t.idle(.08)
        t.palette('Simulation: Reopen ' + aid + ' fixture')
        t.idle(.3)
        for _ in range(3):
            t.key(b'\t')
            t.idle(.08)
        t.palette('Simulation: Open embedded waveform retained-vcd')
        t.wait(lambda s: state(s) is not None, 'waveform-ready')
        settle(t)
        calls_before = (directory / 'calls.jsonl').read_bytes()
        current_zoom = 0
        keys = (b'L', b'H') if args.step_mode == 'tick' else (b'l', b'h')
        for zoom_name, target_zoom in [('expanded', 3), ('default', 0), ('compressed', -5)]:
            delta = target_zoom - current_zoom
            for _ in range(abs(delta)):
                t.key(b'+' if delta > 0 else b'-')
                t.idle(.08)
            current_zoom = target_zoom
            # Jumping resets the window to the cursor, independent of preceding holds.
            def reset():
                t.key(b':' + b'\x7f' * 32 + b'10000\r')
                t.wait(lambda s: state(s) is not None and state(s)['tick'] == 10000,
                       'reset-' + zoom_name)
                settle(t)

            reset()
            t.snapshot(zoom_name + '-before')
            singles = []
            for key in keys:
                for _ in range(args.samples):
                    before = state(t.screen.text())
                    expected = expected_step(before, key, args.step_mode, metadata['bounds'])
                    offset = t.offset
                    start, _sent = t.key(key)
                    observed = None
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        text = t.pump(.002)
                        now = state(text)
                        if now and now['tick'] == expected['tick']:
                            observed = time.monotonic_ns()
                            break
                    assert observed, 'single key did not change exact cursor header'
                    last = settle(t)
                    after = state(t.screen.text())
                    require(after == expected, 'single position mismatch: %r != %r' % (after, expected))
                    if args.step_mode in ('baseline', 'tick'):
                        require(abs(after['tick'] - before['tick']) == 1, 'raw tick key must move exactly one tick')
                    else:
                        amount, unit = before['scale']
                        old_grid_column = ((after['tick'] - before['start']) * amount if unit == 'cells/tick'
                                           else (after['tick'] - before['start']) // amount)
                        require(abs(old_grid_column - before['column']) >= 1,
                                'column key stayed in same raster column')
                    singles.append(dict(key=key.decode(), before=before, after=after,
                        header_ms=(observed - start) / 1e6,
                        last_output_ms=(last - start / 1e9) * 1000,
                        output_bytes=t.offset - offset, expected=expected,
                        same_column=(before['start'] == after['start'] and
                                     before['column'] == after['column'])))
            row = dict(fixture=directory.name, zoom=zoom_name, metadata=metadata, step_mode=args.step_mode,
                       singles=singles, holds=[])
            result['cases'].append(row)
            save(args.evidence / 'result.json', result)
            for rate in args.rates:
                for key in keys:
                    reset()
                    initial = state(t.screen.text())
                    start = time.monotonic()
                    release = start + 2
                    writes, errors = [], []

                    def sender():
                        try:
                            for i in range(int(2 * rate)):
                                due = start + i / rate
                                time.sleep(max(0, due - time.monotonic()))
                                if time.monotonic() >= release:
                                    break
                                before = time.monotonic_ns()
                                assert os.write(t.master, key) == 1
                                writes.append(dict(before_ns=before, after_ns=time.monotonic_ns()))
                        except BaseException:
                            errors.append(traceback.format_exc())

                    thread = threading.Thread(target=sender, daemon=True)
                    thread.start()
                    changes = []
                    previous = initial
                    at_release = None
                    last_output = start
                    last_cursor = start
                    old_offset = t.offset
                    # Drain throughout input and for at least 1s afterwards; max 8s.
                    # Cursor stability, not byte silence: the client emits periodic
                    # terminal output even after navigation has completely stopped.
                    while time.monotonic() < release + 8:
                        t.pump(.002)
                        stamp = time.monotonic()
                        if t.offset != old_offset:
                            old_offset, last_output = t.offset, stamp
                        now = state(t.screen.text())
                        if now and now != previous:
                            changes.append(dict(ms=(stamp - start) * 1000, state=now))
                            previous = now
                            last_cursor = stamp
                        if stamp >= release and at_release is None:
                            at_release = dict(state=now, observed_ms=(stamp - start) * 1000)
                        if stamp >= release + 1 and stamp - last_cursor >= .5:
                            break
                    thread.join(timeout=1)
                    assert not thread.is_alive() and not errors, errors
                    final = state(t.screen.text())
                    post = [c for c in changes if c['ms'] > 2000]
                    # Compute the exact expected position after each actual byte,
                    # including viewport grid changes. No tick-delta ordinals.
                    expected_positions = []
                    expected = initial
                    capacity = initial['stop'] - initial['start'] + 1
                    for _ in writes:
                        expected = expected_step(expected, key, args.step_mode, metadata['bounds'], capacity)
                        expected_positions.append(expected)
                    by_tick = {s['tick']: ordinal for ordinal, s in enumerate(expected_positions, 1)}
                    require(len(by_tick) == len(writes), 'hold reached bounds; correlation would be ambiguous')
                    correlated = {}
                    for c in changes:
                        ordinal = by_tick.get(c['state']['tick'])
                        if ordinal is not None:
                            elapsed = (start * 1000 + c['ms'] -
                                       writes[ordinal - 1]['before_ns'] / 1e6)
                            if elapsed >= 0:
                                correlated.setdefault(ordinal, elapsed)
                    latencies = list(correlated.values())
                    hold = dict(key=key.decode(), rate_hz=rate, duration_s=2,
                        sent=len(writes), writes=writes, initial=initial, at_release=at_release,
                        final=final, changes=changes,
                        post_release_observed_changes=len(post),
                        last_cursor_change_after_release_ms=max(0, changes[-1]['ms'] - 2000) if changes else 0,
                        last_output_after_release_ms=max(0, (last_output - release) * 1000),
                        final_minus_release_ticks=final['tick'] - at_release['state']['tick'],
                        drain_censored=time.monotonic() - last_cursor < .5,
                        expected_final=expected_positions[-1], expected_positions=expected_positions,
                        step_correlated_header_observations=len(latencies),
                        unobserved_step_headers=len(writes) - len(latencies),
                        step_correlated_header_median_ms=statistics.median(latencies) if latencies else None,
                        step_correlated_header_max_ms=max(latencies) if latencies else None,
                        release_tail_limit_ms=args.max_release_ms,
                        max_sender_lateness_ms=max((w['before_ns'] / 1e9 - start - i / rate) * 1000
                                                  for i, w in enumerate(writes)))
                    row['holds'].append(hold)
                    t.snapshot('%s-%d-%s-after' % (zoom_name, rate, key.decode()))
                    save(args.evidence / 'result.json', result)
                    require(final == hold['expected_final'], 'hold final position mismatch: %r != %r' %
                            (final, hold['expected_final']))
                    require(not hold['drain_censored'], 'hold drain censored before cursor stabilized')
                    require(hold['last_cursor_change_after_release_ms'] <= args.max_release_ms,
                            'release cursor tail exceeded %.1f ms' % args.max_release_ms)
                    require(len(writes) == 2 * rate, 'sender missed scheduled hold bytes')
            row['summary'] = dict(
                single_header_median_ms=statistics.median(s['header_ms'] for s in singles),
                single_header_max_ms=max(s['header_ms'] for s in singles),
                single_last_output_median_ms=statistics.median(s['last_output_ms'] for s in singles),
                same_column=sum(s['same_column'] for s in singles), samples=len(singles))
        assert (directory / 'calls.jsonl').read_bytes() == calls_before
    finally:
        if t:
            t.close()
        if session.process:
            session.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', type=Path, default=HERE.parent / '_build/default/terminal/main.exe')
    parser.add_argument('--daemon', type=Path, default=HERE.parent / '_build/default/daemon/main.exe')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--step-mode', choices=['baseline', 'column', 'tick'], default='column')
    parser.add_argument('--max-release-ms', type=float, default=50)
    parser.add_argument('--samples', type=int, default=8)
    parser.add_argument('--rates', type=int, nargs='+', default=[30, 120])
    parser.add_argument('--sizes', choices=['small', 'large'], nargs='+', default=['small', 'large'])
    parser.add_argument('--width', type=int, default=180)
    parser.add_argument('--height', type=int, default=50)
    args = parser.parse_args()
    def interrupted(signum, _frame):
        raise KeyboardInterrupt('probe interrupted: %d' % signum)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    assert 1 <= args.samples <= 30 and all(1 <= r <= 500 for r in args.rates)
    assert 120 <= args.width <= 300 and 40 <= args.height <= 100
    assert 0 < args.max_release_ms <= 1000
    args.tmux_escape_time = None
    args.outer_timeout = 30
    evidence_root = HERE.parent / '_build/wb068-evidence'
    evidence_root.mkdir(parents=True, exist_ok=True)
    args.evidence = (args.evidence.resolve() if args.evidence else
                     Path(tempfile.mkdtemp(prefix=args.step_mode + '-', dir=evidence_root)))
    assert args.evidence.is_relative_to(HERE.parent)
    args.evidence.mkdir(exist_ok=True)
    binary_dir = args.evidence / 'bin'
    binary_dir.mkdir()
    binaries = {}
    for name in ('client', 'daemon'):
        source = getattr(args, name).resolve(strict=True)
        target = binary_dir / name
        shutil.copy2(source, target)
        binaries[name] = dict(source=str(source), preserved=str(target),
                              sha256=hashlib.sha256(target.read_bytes()).hexdigest())
        setattr(args, name, target)
    result = dict(status='running', argv=sys.argv, binaries=binaries, cases=[],
                  interpretation=__doc__, viewport=[args.width, args.height], step_mode=args.step_mode,
                  release_tail_limit_ms=args.max_release_ms)
    print('Evidence: ' + str(args.evidence), flush=True)
    save(args.evidence / 'invocation.json', result)
    try:
        for size in args.sizes:
            directory = args.evidence / size
            directory.mkdir()
            source = directory / 'fixture.vcd'
            metadata = fixture(source, *({'small': (8, 2048), 'large': (128, 3072)}[size]))
            run_case(args, directory, source, metadata, result)
        result['status'] = 'completed'
    except BaseException:
        result.update(status='failed', error=traceback.format_exc())
        raise
    finally:
        save(args.evidence / 'result.json', result)
        save(args.evidence / 'summary.json', dict(status=result['status'], binaries=binaries,
            step_mode=args.step_mode, release_tail_limit_ms=args.max_release_ms,
            cases=[dict(fixture=r['fixture'], zoom=r['zoom'], metadata=r['metadata'], step_mode=r['step_mode'],
                        summary=r.get('summary'), holds=[{k: v for k, v in h.items()
                            if k not in ('writes', 'changes', 'expected_positions')} for h in r['holds']])
                   for r in result['cases']]))
    for row in result['cases']:
        print(row['fixture'], row['zoom'], json.dumps(row['summary']), flush=True)
        for hold in row['holds']:
            print(' hold', hold['key'], hold['rate_hz'], 'sent', hold['sent'],
                  'post-release ticks', hold['final_minus_release_ticks'],
                  'last cursor ms', round(hold['last_cursor_change_after_release_ms'], 3), flush=True)


if __name__ == '__main__':
    main()
