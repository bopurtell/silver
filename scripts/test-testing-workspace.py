#!/usr/bin/env python3
"""Private HTTP/PTY cooperative Testing acceptance; requires prebuilt executables.

No builds, EDA, live sessions or project configuration are touched. All daemon,
client, fixture and evidence state lives in a new /tmp/opencode directory.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import struct
import sys
import tempfile
import termios
import time
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('native_testing', HERE / 'test-native-simulation.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
field, require, sexp = native.field, native.require, native.sexp
from fixtures.testing_layout import (
    FIT_FOCUS_ORDER, STOCK_KINDS, assert_focus_order, assert_stock_layout, focus_pane,
)


class Terminal(native.Terminal):
    def save(self, label, text):
        if label.startswith('palette-'):
            # Keep the painted palette, not another copy of the cumulative PTY stream.
            (self.session.evidence / (label + '.txt')).write_text(text)
        else:
            super().save(label, text)

    def resize(self, width, height):
        self.width, self.height = width, height
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))
        # This child has no controlling PTY, so ioctl alone need not notify it.
        # Wait for painted edges, not old text reconstructed in a resized grid.
        os.kill(self.process.pid, signal.SIGWINCH)
        self.wait_viewport('resize-%dx%d' % (width, height))

    def wait_viewport(self, label):
        deadline = time.monotonic() + 15
        while True:
            text = self.drain(.2)
            rows = text.splitlines()
            top = rows[1] if len(rows) > 1 else ''
            bottom = rows[self.height - 2] if len(rows) >= self.height - 1 else ''
            footer = rows[self.height - 1] if len(rows) >= self.height else ''
            # Border rows contain only single-cell box-drawing/plain glyphs.
            if (len(top) == self.width and top.endswith('╮') and
                    len(bottom) == self.width and bottom.endswith('╯') and
                    footer.startswith('Space c c commands')):
                break
            if time.monotonic() >= deadline:
                self.save(label + '-unpainted', text)
                raise AssertionError('%s: no painted %dx%d viewport; top=%d bottom=%d footer=%r' %
                                     (label, self.width, self.height, len(top), len(bottom), footer))
        self.save(label + '-painted', text)
        proof = dict(label=label, width=self.width, height=self.height,
                     top_right_border_column=len(top), bottom_right_border_column=len(bottom),
                     bottom_pane_row=self.height - 1, footer_row=self.height, passed=True)
        with (self.session.evidence / 'viewport-checks.jsonl').open('a') as out:
            out.write(json.dumps(proof) + '\n')


def run(args):
    evidence = args.evidence
    for name in ('project', 'unconfigured', 'state', 'home', 'config', 'tmp'):
        (evidence / name).mkdir()
    root = evidence / 'project'
    (root / 'dune-project').write_text('(lang dune 3.22)\n(name testing_workspace_acceptance)\n')
    unconfigured = evidence / 'unconfigured'
    (unconfigured / 'dune-project').write_text('(lang dune 3.22)\n(name no_simulation_provider)\n')
    control, calls = evidence / 'control.json', evidence / 'calls.jsonl'

    def mode(value):
        control.write_text(json.dumps(dict(mode=value)))

    mode('pass')
    (root / 'hardcaml-workbench-simulation.sexp').write_text(sexp([
        ('schema_version', 1), ('provider_executable', sys.executable),
        ('provider_args', [str(HERE / 'fixtures/simulation_fault_provider.py'), '--control', str(control), '--calls', str(calls)]),
        ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 90)]))
    session = native.Session(args, evidence, root)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
                       TMPDIR=str(evidence / 'tmp'), PYTHONDONTWRITEBYTECODE='1')
    terminal = None
    result = dict(status='failed', checks=[])

    def check(ok, message):
        result['checks'].append(dict(passed=bool(ok), expectation=message))
        require(ok, message)

    def records():
        return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    def workspace():
        return session.api(domain='workspace')

    def job_ids():
        reply = session.raw('/api/v1/snapshot', [('instance_id', session.metadata['instance_id'])])
        require(reply[0] == 'Ok', str(reply))
        return {field(j, 'id') for j in field(reply[1], 'jobs')}

    def discoveries():
        return [r for r in records() if r['operation'] == 'discover']

    def mutate(mutation):
        snapshot = workspace()
        return session.api(domain='workspace', operation=['Mutate',
            ['expected_revision', field(snapshot, 'revision')], ['mutation', mutation]])

    def wait_for(predicate, message):
        deadline = time.monotonic() + 25
        while not predicate():
            require(time.monotonic() < deadline, message)
            if terminal:
                terminal.drain(.15)
            time.sleep(.1)

    try:
        session.start()
        check(not field(session.api(), 'discovery_job') and not job_ids() and not records(),
              'opening via HTTP and reading Get stay passive before a terminal attaches')
        terminal = Terminal(session)
        terminal.capture('startup', ['Overview'])
        initial = session.until('Get', lambda s: bool(field(s, 'discovery_digest')))
        initial_jobs = job_ids()
        check([r['operation'] for r in records()] == ['discover'] and not field(initial, 'attempts')
              and len(initial_jobs) == 1,
              'startup automatically discovers exactly once and does not start simulation or generic tests')

        # A second root without simulation configuration must not allocate a job.
        opened = session.raw('/api/v1/open-project', [
            ('instance_id', session.metadata['instance_id']), ('root', str(unconfigured)),
            ('environment', 'Inherit_daemon')])
        require(opened[0] == 'Ok', str(opened))
        bare_project = field(field(opened[1], 'project'), 'id')
        bare_client = Terminal(session, argv=[str(args.client), '--connect', session.url,
                                               '--project-root', str(unconfigured)])
        try:
            bare_client.capture('unconfigured-startup', ['Overview'])
            bare_client.palette('Switch to Testing')
            focus_pane(bare_client, 'simulation-catalog')
            bare_client.palette('Zoom focused tile')
            bare_client.capture('unconfigured-catalog', ['No simulation provider configured'])
        finally:
            bare_client.close()
        bare = session.raw('/api/v1/simulation', [
            ('instance_id', session.metadata['instance_id']), ('project', bare_project),
            ('operation', 'Get')])
        require(bare[0] == 'Ok', str(bare))
        check(not any(field(bare[1], key) for key in
                      ('discovery_job', 'discovery_error', 'discovery', 'attempts'))
              and job_ids() == initial_jobs,
              'attaching Testing to an unconfigured project adds no backend jobs or discovery errors')

        # This suite checks exact provenance; compact rendering has its own WB-073 suite.
        terminal.palette('Strings (global): Show full identifiers')
        terminal.palette('Switch to Testing')
        assert_stock_layout(terminal, 'testing-layout-120x40', evidence)
        check(True, 'stock Testing tracks and spanning Logs painted at 120x40')
        terminal.resize(180, 55)
        assert_stock_layout(terminal, 'testing-layout-180x55', evidence)
        check(True, 'stock Testing tracks and spanning Logs painted at 180x55')
        assert_focus_order(terminal, FIT_FOCUS_ORDER)
        check(True, 'Tab and Shift-Tab wrap through the depth-first Fit order')
        terminal.palette('Layout: Requested tile sizes')
        assert_focus_order(terminal, STOCK_KINDS)
        check(True, 'Tab and Shift-Tab wrap through registry order in Preferred')
        terminal.palette('Layout: Fit tiles to window')
        terminal.resize(120, 40)
        assert_stock_layout(terminal, 'testing-layout-return-120x40', evidence)
        check(True, 'stock Testing tracks and spanning Logs repaint after resizing back to 120x40')
        check([r['operation'] for r in records()] == ['discover'],
              'render and workspace navigation do not repeat startup discovery or launch tests')
        snapshot = workspace()
        testing = next(w for w in field(snapshot, 'workspaces') if field(w, 'preset') == ['testing'])
        wid = field(testing, 'id')
        tiles = [t for t in field(snapshot, 'tiles') if field(t, 'workspace') == wid]
        check(tuple(field(t, 'kind') for t in tiles) == STOCK_KINDS,
              'stock membership and registry order exclude Project Tests and the ASIC selector')
        focus_pane(terminal, 'simulation-catalog')
        terminal.palette('Zoom focused tile')
        terminal.capture('catalog-auto-discovered', ['first', 'second', 'Ready for explicit launch'])
        terminal.key(b'x')  # remove first: exact subset is second
        terminal.key(b'/'); terminal.key(b'second'); terminal.key(b'\r')
        terminal.capture('catalog-filter-subset', ['Selected cases: second'], absent=['[x] first'])
        terminal.key(b'\r')
        terminal.capture('subset-form', ['CASES', 'second'])
        check(len(records()) == 1 and job_ids() == initial_jobs,
              'filter/subset/form navigation invokes no tools before confirmation')
        # Cases, seed, then confirmation (the fixture declares no parameters).
        terminal.key(b'\r'); terminal.key(b'\r')
        terminal.capture('subset-confirm', ['CONFIRM', 'second'])
        terminal.key(b'\r')
        wait_for(lambda: any(r['operation'] == 'run' for r in records()), 'explicit launch reaches provider')
        run_call = next(r for r in records() if r['operation'] == 'run')
        selection = field(run_call['request'], 'selection')
        check(field(selection, 'cases') == ['second'] and field(selection, 'asic_inputs') == [],
              'PTY launch captures exact selected subset without ASIC provenance')
        aid = field(run_call['request'], 'attempt_id')
        done = session.done(aid)
        check(field(done, 'outcome') == 'Passed', 'selected subset produces actual normalized fixture result')
        terminal.palette('Unzoom workspace')
        focus_pane(terminal, 'execution')  # Labels use the job's captured subset.
        terminal.palette('Zoom focused tile')
        terminal.capture('execution-readable-labels', ['sim discover', 'sim run fixture/second'])
        terminal.palette('Unzoom workspace')
        focus_pane(terminal, 'simulation-attempts')
        terminal.palette('Simulation: Reopen ' + aid + ' fixture')
        focus_pane(terminal, 'simulation-cases')
        terminal.key(b'j')
        focus_pane(terminal, 'simulation-detail')
        terminal.palette('Zoom focused tile')
        terminal.capture('shared-detail', ['second', aid])
        terminal.palette('Unzoom workspace')
        focus_pane(terminal, 'simulation-artifacts')
        terminal.key(b'j')
        terminal.palette('Zoom focused tile')
        terminal.capture('shared-artifacts', ['second-raw'])
        terminal.key(b'e')
        terminal.capture('shared-export-ready', ['Export ready'])
        exported, = (evidence / 'tmp').glob('hardcaml_export_*-verified/artifact*')
        artifact = next(a for a in field(done, 'artifacts') if field(a, 'id').endswith('-second-raw'))
        check(hashlib.sha256(exported.read_bytes()).hexdigest() == field(artifact, 'sha256')[0],
              'cooperative export retains exact selected artifact bytes and SHA256')
        terminal.palette('Unzoom workspace')
        focus_pane(terminal, 'simulation-logs')
        terminal.palette('Zoom focused tile')
        terminal.capture('shared-exact-logs', [aid, field(done, 'job')[:25], 'job-2'])
        terminal.palette('Simulation: Rerun case second (original inputs; current project)')
        wait_for(lambda: len([r for r in records() if r['operation'] == 'run']) == 2,
                 'cooperative captured targeted rerun')
        child_call = [r for r in records() if r['operation'] == 'run'][-1]
        child = session.done(field(child_call['request'], 'attempt_id'))
        check(field(child, 'id') != aid and field(field(child, 'parent')[0], 'attempt_id') == aid
              and field(field(field(child, 'captured'), 'selection'), 'cases') == ['second'],
              'cooperative targeted rerun captures exact parent and original selected case inputs')
        terminal.palette('Simulation: Reopen ' + aid + ' fixture')
        terminal.palette('Unzoom workspace')
        # A second workspace with identical definitions defaults to the newest
        # attempt instead of copying the first workspace's explicit selection.
        created = mutate(['Create_workspace', ['window', field(testing, 'window')],
                          ['name', 'Independent Testing'], ['context', field(testing, 'context')]])
        other = next(w for w in field(created, 'workspaces') if field(w, 'name') == 'Independent Testing')
        specs = [[field(t, 'kind'), field(t, 'requested_geometry')] for t in tiles]
        mutate(['Apply_preset', ['workspace', field(other, 'id')], ['preset', 'testing'], ['tiles', specs]])
        terminal.palette('Switch to Independent Testing')
        focus_pane(terminal, 'simulation-logs')
        terminal.palette('Zoom focused tile')
        terminal.capture('independent-workspace', [field(child, 'id'), field(child, 'job')[:25]],
                         absent=[aid])
        terminal.palette('Unzoom workspace')
        terminal.palette('Switch to Testing')
        terminal.palette('Zoom focused tile')  # restores Logs focus
        terminal.capture('workspace-selection-retained', [aid, field(done, 'job')[:25]])
        terminal.palette('Unzoom workspace')
        # Add a hidden legacy tile, then apply the updated template additively.
        added = mutate(['Create_tile', ['workspace', wid], ['kind', 'simulation'],
                        ['geometry', [('x', 0), ('y', 0), ('width', 80), ('height', 12)]]])
        extra = field(added, 'tiles')[-1]
        mutate(['Set_tile_hidden', ['tile', field(extra, 'id')], ['hidden', 'true']])
        mutate(['Set_tile_binding', ['tile', field(extra, 'id')], ['binding', ['Pin_run',
            [('backend', 'saved-fixture'), ('id', 'preserved-pin'), ('build', []), ('label', [])]]]])
        moved = next(t for t in tiles if field(t, 'kind') == 'simulation-artifacts')
        mutate(['Move_tile', ['tile', field(moved, 'id')], ['workspace', field(other, 'id')]])
        before = workspace()
        terminal.palette('Apply default layout (add missing tiles)')
        wait_for(lambda: len(field(workspace(), 'tiles')) == len(field(before, 'tiles')) + 1,
                 'Apply adds missing cooperative pane')
        after = workspace()
        previous = {field(t, 'id'): t for t in field(before, 'tiles')}
        check(all(previous.get(field(t, 'id'), t) == t for t in field(after, 'tiles')),
              'additive upgrade preserves saved hidden legacy extras, pins and geometry')
        # Revisit Catalog: failed discovery retains rows but disables launch.
        terminal.palette('Switch to Independent Testing')
        focus_pane(terminal, 'simulation-catalog')
        terminal.palette('Zoom focused tile')
        before_refresh = job_ids()
        mode('discovery-malformed')
        terminal.key(b'd')
        session.until('Get', lambda s: bool(field(s, 'discovery_error')))
        check(len(job_ids() - before_refresh) == 1
              and [r['mode'] for r in discoveries()] == ['pass', 'discovery-malformed'],
              'explicit refresh after startup allocates one fresh discovery job')
        terminal.capture('stale-catalog', ['Launch disabled:', 'Discovery failed:', 'first', 'second'])
        count = len([r for r in records() if r['operation'] == 'run'])
        terminal.key(b'\r')
        terminal.drain(.6)
        check(len([r for r in records() if r['operation'] == 'run']) == count,
              'failed authoritative discovery blocks Enter launch')
        check(len(discoveries()) == 2,
              'catalog observation does not retry a failed explicit refresh')
        before_restart = records()
        terminal.close(); terminal = None
        session.stop(); session.start()
        terminal = Terminal(session)
        terminal.capture('restart-startup', ['Space c c commands', 'connected'])
        cold_failure = session.until('Get', lambda s: bool(field(s, 'discovery_error')))
        cold_jobs = job_ids()
        check(not field(cold_failure, 'discovery_digest')
              and records()[:-1] == before_restart
              and records()[-1]['operation'] == 'discover'
              and records()[-1]['mode'] == 'discovery-malformed'
              and len(cold_jobs) == 1,
              'fresh daemon automatically attempts discovery once without replaying retained runs')
        mode('pass')  # Repair alone must not cause observation/navigation to retry.
        terminal.palette('Switch to Testing')
        focus_pane(terminal, 'simulation-logs')
        terminal.palette('Simulation: Reopen ' + aid + ' fixture')
        terminal.palette('Zoom focused tile')
        terminal.capture('historical-exact-logs-unavailable', ['Job logs unavailable in this daemon'])
        terminal.palette('Unzoom workspace')
        focus_pane(terminal, 'simulation-catalog')
        terminal.palette('Zoom focused tile')
        terminal.capture('cold-discovery-blocked', ['Launch disabled:', 'Discovery failed:'])
        peer = Terminal(session)
        try:
            peer.capture('cold-discovery-peer-startup', ['Testing'])
            peer.drain(2.5)
        finally:
            peer.close()
        check(records()[:-1] == before_restart and len(discoveries()) == 3
              and job_ids() == cold_jobs,
              'polling, reopening history and attaching a second client do not retry failed auto discovery')
        terminal.key(b'd')
        terminal.capture('explicit-retry-ready', ['first', 'second', 'Ready for explicit launch'])
        ready = session.api()
        check(not field(ready, 'discovery_error')
              and len(discoveries()) == 4 and records()[-1]['mode'] == 'pass'
              and len([r for r in records() if r['operation'] == 'run']) == 2
              and len(job_ids() - cold_jobs) == 1,
              'explicit retry repairs failed auto discovery without starting or replaying tests')
        before_restart = records()
        terminal.close(); terminal = None
        session.stop(); session.start()
        terminal = Terminal(session)
        terminal.capture('healthy-restart-startup', ['Space c c commands', 'connected'])
        restored = session.until('Get', lambda s: bool(field(s, 'discovery_digest')))
        check(field(restored, 'discovery_digest') == field(ready, 'discovery_digest')
              and records()[:-1] == before_restart and records()[-1]['operation'] == 'discover'
              and len(job_ids()) == 1,
              'healthy restart repopulates the same catalog without any UI input or replay')
        result['status'] = 'passed'
    except BaseException:
        result['traceback'] = traceback.format_exc()
        if terminal:
            terminal.save('failure', terminal.drain(.1))
        raise
    finally:
        try:
            if terminal:
                terminal.close()
        finally:
            session.stop()
            (evidence / 'verified.json').write_text(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--daemon', type=Path, required=True)
    parser.add_argument('--client', type=Path, required=True)
    args = parser.parse_args()
    args.daemon = args.daemon.resolve(strict=True)
    args.client = args.client.resolve(strict=True)
    args.outer_timeout = 30
    os.umask(0o077)
    args.evidence = Path(tempfile.mkdtemp(prefix='testing-workspace-', dir='/tmp/opencode'))
    print('Evidence: ' + str(args.evidence), flush=True)
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('acceptance budget exhausted')))
    signal.alarm(300)
    try:
        run(args)
    finally:
        signal.alarm(0)
    print('PASS cooperative Testing HTTP + PTY', flush=True)


if __name__ == '__main__':
    main()
