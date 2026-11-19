#!/usr/bin/env python3
"""Native mouse reporting and routing against the two-run, no-EDA demo fixture."""
import argparse
from contextlib import ExitStack
import errno
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
TRACKING = {1000, 1002, 1003}


def mouse_modes(data):
    """DECSET and DECRST can combine tracking and encoding in one CSI."""
    active, enabled = set(), set()
    for modes, op in re.findall(rb'\x1b\[\?([\d;]+)([hl])', data):
        values = {int(m) for m in modes.split(b';') if m}
        if op == b'h':
            active.update(values)
            enabled.update(values)
        else:
            active.difference_update(values)
    return active, enabled


def cell(screen, label):
    for y, line in enumerate(screen.splitlines(), 1):
        if label in line:
            return line.index(label) + 1, y
    raise AssertionError(f'No visible {label!r}:\n{screen}')


def pointer(term, button, pos):
    x, y = pos
    report = f'\x1b[<{button};{x};{y}'
    term.key((report + 'M' + (report + 'm' if button == 0 else '')).encode())


def quit_client(term):
    # Dashboard q exits normally; retain at-exit DECRST bytes for the mode oracle.
    os.write(term.master, b'q')
    assert term.process.wait(timeout=10) == 0
    while True:
        try:
            data = os.read(term.master, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not data:
            break
        term.data.extend(data)


def run(args, tmp):
    native = runpy.run_path(str(ROOT / 'scripts/test-fs2-native.py'))
    demo = runpy.run_path(str(ROOT / 'scripts/synthetic-flow-demo.py'))
    base = demo['prepare'](tmp / 'fixture', manual=True)
    session = native['Session'](args, base, base / 'project')
    for name in ('home', 'config', 'tmp'):
        (base / name).mkdir()
    session.env.update(HOME=str(base / 'home'), XDG_CONFIG_HOME=str(base / 'config'),
                       TMPDIR=str(base / 'tmp'), OMP_NUM_THREADS='2', OPENROAD_THREADS='2',
                       _OPENLANE_MAX_CORES='2')
    with ExitStack() as stack:
        stack.callback(session.stop)
        session.start()
        for r in json.loads((base / 'manifest.json').read_text())['runs']:
            session.api('asic', ['Register', [['attempt', r['attempt']],
                                              ['stream_id', r['stream_id']]]])
        term = native['Terminal'](session)
        stack.callback(term.close)
        def focus(name):
            return 'Overview › ' + name

        screen = term.capture('startup', [focus('workspaces'), '✓ completed', '! failed'])
        modes, _ = mouse_modes(term.data)
        assert modes & TRACKING and 1006 in modes, f'SGR mouse reporting not active: {modes}'

        def inactive_tab(screen, active, target):
            # Locate the label in the tab strip, not in a breadcrumb or pane.
            _, y = cell(screen, active)
            line = screen.splitlines()[y - 1]
            assert target in line, f'Missing {target!r} tab in {line!r}'
            return line.index(target) + 1, y

        pointer(term, 0, inactive_tab(screen, '[1 Overview]', 'Testing'))
        screen = term.capture('click-workspace-testing', ['[2 Testing]', 'Testing › '])
        pointer(term, 0, inactive_tab(screen, '[2 Testing]', 'Overview'))
        screen = term.capture('click-workspace-overview',
                              ['[1 Overview]', focus('workspaces'), '✓ completed', '! failed'])

        session_cell = cell(screen, 'Connection: connected')
        # Use the live grid rather than tile geometry from the workspace configuration.
        good = cell(screen, '✓ completed')
        bad = cell(screen, '! failed')
        term.key(b'\t')
        term.capture('keyboard-next', [focus('session')])
        term.key(b'\x1b[Z')
        term.capture('keyboard-previous', [focus('workspaces')])
        pointer(term, 81, bad)  # Ctrl-wheel down, deliberately nowhere near the tabs.
        term.capture('ctrl-next', [focus('session')])
        pointer(term, 81, (120, 40))  # Footer has no tile hit.
        term.capture('ctrl-next-again', [focus('run selector')])
        pointer(term, 80, bad)
        term.capture('ctrl-previous', [focus('session')])

        def selected(label, row):
            screen = term.capture(label, [focus('run selector'), 'Run: none selected'])
            line = screen.splitlines()[row[1] - 1]
            assert '>' in line[:row[0]], f'{label}: expected browse cursor on {line!r}\n{screen}'

        pointer(term, 0, bad)
        selected('click-failed-row', bad)
        pointer(term, 0, good)
        selected('click-completed-row', good)
        up, down = sorted((good, bad), key=lambda pos: pos[1])
        pointer(term, 0, up)
        pointer(term, 65, session_cell)
        selected('wheel-outside-focused-list-ignored', up)
        pointer(term, 65, up)  # Wheel down in the focused list.
        selected('wheel-next-row', down)
        pointer(term, 65, up)
        selected('wheel-clamped', down)
        pointer(term, 64, up)
        selected('wheel-previous-row', up)

        pointer(term, 0, session_cell)
        term.capture('click-session', [focus('session')])
        pointer(term, 65, bad)
        term.capture('off-tile-wheel-keeps-focus', [focus('session')])
        for key in (b' ', b'c', b'c'):
            term.key(key)
        screen = term.capture('palette', ['COMMAND PALETTE', '[1 Overview]'])
        pointer(term, 0, inactive_tab(screen, '[1 Overview]', 'Testing'))
        term.capture('palette-consumes-workspace-click', ['COMMAND PALETTE', '[1 Overview]'])
        for button in (0, 81, 65):
            pointer(term, button, (2, bad[1]))  # Exposed run tile outside centered overlay.
            term.capture(f'palette-consumes-{button}', ['COMMAND PALETTE'])
        term.key(b'\x1b')
        term.capture('palette-restores-focus', [focus('session')], absent=['COMMAND PALETTE'])
        quit_client(term)
        assert not (mouse_modes(term.data)[0] & TRACKING), 'Mouse tracking left enabled on exit'

        # The shared driver takes an executable path, so exec the same binary with
        # the extra CLI option in this private fixture.
        wrapper = base / 'keyboard-client'
        wrapper.write_text(f'#!/bin/sh\nexec {shlex.quote(str(args.client))} --no-mouse "$@"\n')
        wrapper.chmod(0o700)
        args.client = wrapper
        # A distinct profile ensures initial focus is deterministic across restarts.
        session.env['XDG_STATE_HOME'] = str(base / 'keyboard-state')
        keyboard = native['Terminal'](session)
        stack.callback(keyboard.close)
        keyboard.capture('disabled', [focus('workspaces')])
        # Stray reports from a multiplexer must not route even if the terminal
        # sends them without being asked.
        pointer(keyboard, 0, bad)
        pointer(keyboard, 81, bad)
        keyboard.capture('disabled-ignores-pointer', [focus('workspaces')])
        keyboard.key(b'\t')
        keyboard.capture('disabled-keyboard-tab', [focus('session')])
        quit_client(keyboard)
        assert not (mouse_modes(keyboard.data)[1] & TRACKING), '--no-mouse enabled reporting'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('client', 'daemon'):
        parser.add_argument('--' + name, type=lambda s: Path(s).resolve(strict=True), required=True)
    args = parser.parse_args()
    sys.dont_write_bytecode = True
    with tempfile.TemporaryDirectory(prefix='mouse-pty-') as tmp:
        run(args, Path(tmp))
