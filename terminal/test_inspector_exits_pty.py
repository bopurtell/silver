#!/usr/bin/env python3
"""Production PTY inspector exits; prebuilt binaries, no builds or EDA.

Reuses the synthetic demo's completed, on-disk retained evidence fixture. The
client and daemon are real; fixture inspection reads never advance a run.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import secrets
import sys
import tempfile
import traceback

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def inventory(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('daemon', 'client'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--evidence-parent', type=Path, default=Path(tempfile.gettempdir()))
    args = parser.parse_args()
    for name in ('daemon', 'client'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    native = load('inspector_native', ROOT / 'scripts/test-native-simulation.py')
    demo = load('inspector_demo', ROOT / 'scripts/synthetic-flow-demo.py')
    field = native.field
    base = demo.prepare(args.evidence_parent.resolve() / ('inspector-exits-' + secrets.token_hex(6)),
                        manual=True, delay=.05)
    print('Evidence: ' + str(base), flush=True)
    for name in ('state', 'home', 'config', 'tmp', 'client-state'):
        (base / name).mkdir()
    session = native.Session(args, base, base / 'project')
    session.env.update(HOME=str(base / 'home'), XDG_CONFIG_HOME=str(base / 'config'),
                       TMPDIR=str(base / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
                       OMP_NUM_THREADS='6', OPENROAD_THREADS='6', _OPENLANE_MAX_CORES='6')
    before = inventory(base / 'results')
    result = dict(status='failed', command=sys.argv, checks=[], synthetic_fixture=True,
                  binaries={name: dict(path=str(getattr(args, name)), sha256=hashlib.sha256(
                      getattr(args, name).read_bytes()).hexdigest()) for name in ('daemon', 'client')})
    terminal = None

    class Terminal(native.Terminal):
        def key(self, raw):
            with (base / 'keys.jsonl').open('a') as out:
                out.write(json.dumps(dict(hex=raw.hex())) + '\n')
            super().key(raw)

    def check(label, expected, absent=()):
        text = terminal.capture(label, expected, absent=absent)
        result['checks'].append(label)
        print('PASS ' + label, flush=True)
        return text

    try:
        session.start()
        reference = json.loads((base / 'manifest.json').read_text())['runs'][0]
        snapshot = session.api('asic', ['Register', [
            ['attempt', reference['attempt']], ['stream_id', reference['stream_id']]]])
        run = field(field(snapshot, 'runs')[0], 'run')
        session.api('asic', ['Observe', run])
        # Preload the exact retained index, then let the UI request actual detail.
        session.api('asic', ['Inspect', ['run', run], ['domain', 'clocks'],
                            ['stage', 'signoff'], ['refresh', 'false']])
        terminal = Terminal(session)
        check('01-startup', ['Overview'])
        title = 'Inspect clocks asic/' + field(run, 'id')
        terminal.palette(title)
        table = check('02-explorer-table', ['INSPECT clocks', 'Clock/name | Value/unit',
                                           'Enter detail', 'Space c x close'], ['Row:', 'EDIT filter='])
        assert any(line.startswith('> ') for line in table.splitlines()), table
        terminal.key(b'\r')
        detail = check('03-row-detail', ['INSPECT clocks', 'Row:', 'Producer:'],
                       ['Clock/name | Value/unit'])
        row = next(line for line in detail.splitlines() if line.startswith('Row:'))
        terminal.key(b'\x1b')
        check('04-escape-detail-to-table', ['INSPECT clocks', 'Clock/name | Value/unit'], ['Row:'])
        terminal.key(b'/')
        check('05-filter-input', ['INSPECT clocks', 'FILTER INPUT', 'EDIT filter='])
        terminal.key(b'clk')
        check('06-filter-text', ['INSPECT clocks', 'EDIT filter=clk'])
        terminal.key(b'\x1b')
        check('07-escape-filter-stays-explorer', ['INSPECT clocks', 'filter=clk',
                                                'Clock/name | Value/unit'], ['EDIT filter=', 'FILTER INPUT', 'Row:'])
        terminal.key(b'\x1b')
        check('08-escape-closes-explorer', ['Overview'], ['INSPECT clocks', 'Row:', 'EDIT filter='])
        terminal.palette(title)
        check('09-reopened-table', ['INSPECT clocks', 'Clock/name | Value/unit'], ['Row:', 'EDIT filter='])
        terminal.key(b'\r')
        check('10-reopened-detail', ['INSPECT clocks', row, 'Producer:'], ['Clock/name | Value/unit'])
        workspace = session.api('workspace')
        # Separate leader events: direct close must skip the intermediate table.
        for key in (b' ', b'c', b'x'):
            terminal.key(key)
        check('11-direct-close-from-detail', ['Overview', 'Space c c commands', 'Connection: connected'],
              ['INSPECT clocks', 'Row:', 'COMMAND PALETTE'])
        assert session.api('workspace') == workspace, 'Direct close changed authoritative workspace state'
        result['checks'].append('direct-close-preserves-workspace')
        result['status'] = 'passed'
    except BaseException:
        result['error'] = traceback.format_exc()
        raise
    finally:
        try:
            if terminal:
                terminal.close()
        finally:
            session.stop()
            result['client_reaped'] = terminal is None or terminal.process.poll() is not None
            result['daemon_reaped'] = session.process is None or session.process.poll() is not None
            result['retained_evidence_unchanged'] = before == inventory(base / 'results')
            if not all(result[key] for key in
                       ('client_reaped', 'daemon_reaped', 'retained_evidence_unchanged')):
                result['status'] = 'failed'
            (base / 'retained-before.json').write_text(json.dumps(before, indent=2) + '\n')
            (base / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        assert result['client_reaped'] and result['daemon_reaped']
        assert result['retained_evidence_unchanged'], 'Inspector changed retained fixture evidence'


if __name__ == '__main__':
    main()
