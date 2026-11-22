#!/usr/bin/env python3
"""Native HTTP/PTY regression for a cancelled Timing stage with passing STA reports.

Only an isolated synthetic provider and private daemon/client state are used.
The fixture advances through Routing, then interrupts Timing after producing STA
evidence. It does not exercise the stop command or automatic run selection.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import urllib.request

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HARNESS = load('cancelled_timing_sidebar', HERE / 'test-overview-sidebar.py')
LEGACY = load('cancelled_timing_analysis', HERE / 'test-timing-checklist.py')
C = HARNESS.composition
field, sexp, require, wait = C.field, C.sexp, C.require, C.wait
PRIOR = 'prior-pass'
CANCELLED = 'later-cancel'


def fixture_provider(base, argv):
    p = load('cancelled_timing_provider', base / 'project/synthetic-provider/provider.py')
    report, inspect = p.report, p.inspect

    def analysis(path):
        attempt = Path(path).parent.name
        a = LEGACY.observation(path, 'a' if attempt == PRIOR else 'c')
        a.update(schema_version=2, occurrence_id=attempt + '/implementation.timing', stage='timing',
                 evidence_scope='immutable_timing_execution_source_not_checkpoint',
                 enclosing_status=p.load(path)['status'], timing_goal='pass')
        a['corners'][0]['setup_goal'] = 'pass'
        a['metrics'][0]['value'] = .125
        a['metrics'][1]['value'] = .250
        a['metrics'][2]['value'] = 0.
        return a

    def timing_report(path):
        result = report(path)
        result['timing_analysis'] = analysis(path)
        return result

    def timing_inspect(path, domain, stage, row_id=None, expected=None):
        if (domain, stage) != ('timing', 'timing'):
            return inspect(path, domain, stage, row_id, expected)
        a = analysis(path)
        digest = 'b' * 64 if a['attempt_id'] == PRIOR else 'd' * 64
        assert expected == (digest if row_id else a['source_digest'])
        result = p.envelope('inspection', execution_file=str(path), execution_sha256=p.digest(path),
            attempt_id=a['attempt_id'], domain=domain, stage=stage, analysis_id=a['analysis_id'],
            analysis_digest=a['source_digest'], source_digest=digest, diagnostics=[], truncated=False,
            rows=[dict(id='setup-path', category='timing_path', producer='OpenROAD.STAPostPNR',
                       corner='slow', group='clk', name=a['attempt_id'] + '-path', value=.125,
                       unit='ns', status='met', source='{}', fields=[])])
        if row_id:
            assert row_id == 'setup-path'
            result.update(row_id=row_id, detail='Report bytes for ' + a['attempt_id'])
        return result

    p.report, p.inspect = timing_report, timing_inspect
    sys.argv = [str(base / 'project/synthetic-flow'), *argv]
    p.main()


def exercise(base, args, url):
    p = load('cancelled_timing_seed', base / 'project/synthetic-provider/provider.py')
    http = C.demo.Client(url, base / 'project', switch=C.demo.switch_name())
    presets = C.demo.workspace_presets(args.preset_export, use_switch=False)
    registry = lambda: http.rpc(domain='workspace')
    C.demo.ensure_workspaces(http, registry(), presets)
    overview = next(w for w in field(registry(), 'workspaces') if field(w, 'preset') == ['overview'])
    wid, cid = field(overview, 'id'), field(overview, 'context')

    def native(operation='Get'):
        body = '((instance_id %s)(project %s)(operation %s))' % (
            sexp(http.instance), sexp(http.project), operation)
        request = urllib.request.Request(url + '/api/v1/asic', data=body.encode(),
            headers={'Content-Type': 'application/sexp', 'X-Workbench-Protocol': '1',
                     'X-Workbench-Asic-Timing-Analysis': '2', 'X-Workbench-Execution-Timing': '1'})
        with urllib.request.urlopen(request, timeout=5) as response:
            text = response.read().decode()
        http.history.append(dict(operation=operation, response=text))
        reply = C.parse(text)
        require(reply[0] == 'Ok', text)
        return reply[1]

    def seed(name, *, cancelled, started_at):
        attempt = p.allocate(base / 'results', p.selection('success', 'timing'), name)
        while True:
            state = p.load(attempt / 'observation.json')
            running = next(s['id'] for s in state['stage_plan']['stages'] if s['status'] == 'running')
            state = p.advance(attempt, cancel=cancelled and running == 'timing')
            if not state['writer_active']:
                break
        # Publish real producer start metadata through the normal observation
        # protocol so the client can distinguish launch time from refresh order.
        state['events'][0].update(event='allocated', recorded_at=started_at)
        if cancelled:
            # Publish the explicit lifecycle projection, while the execution
            # receipt uses the provider's native interrupted occurrence status.
            state['state'].pop('plan')
            execution = p.load(attempt / 'execution.json')
            execution['occurrences'][-1]['status'] = 'interrupted'
            p.save(attempt / 'execution.json', execution)
        p.save(attempt / 'observation.json', state)
        snapshot = http.rpc('(Register ((attempt %s)(stream_id %s)))' % (sexp(str(attempt)), sexp(name)))
        run = next(field(r, 'run') for r in field(snapshot, 'runs') if field(field(r, 'run'), 'id') == name)
        http.rpc('(Observe %s)' % sexp(run))
        http.rpc('(Refresh %s)' % sexp(run))
        return run

    def select_run(run):
        ws = registry()
        ctx = next(x for x in field(ws, 'contexts') if field(x, 'id') == cid)
        http.mutate(ws, '(Select_run (workspace %s)(context %s)(expected_selection_revision %s)(run (%s)))' %
                    (sexp(wid), sexp(cid), field(ctx, 'selection_revision'), sexp(run)))

    def pin_timing(run):
        ws = registry()
        tile = next(t for t in field(ws, 'tiles')
                    if field(t, 'workspace') == wid and field(t, 'kind') == 'timing')
        binding = '(Pin_run %s)' % sexp(run) if run else 'Follow'
        http.mutate(ws, '(Set_tile_binding (tile %s)(binding %s))' %
                    (sexp(field(tile, 'id')), binding))

    def pane_fg(screen, pane, keyword, *, row_label=''):
        left, top, right, bottom = HARNESS.pane_rect(screen, pane)
        for y in range(top + 1, bottom - 1):
            offset = screen.lines()[y].find(keyword, left + 1, right - 1)
            if offset >= 0 and row_label.casefold() in screen.lines()[y][left + 1:right - 1].casefold():
                return screen.cells[y][offset][1][0]
        raise AssertionError('No %r in %s:\n%s' % (keyword, pane, screen.text()))

    prior = seed(PRIOR, cancelled=False, started_at='2026-11-19T12:00:00Z')
    select_run(prior)
    terminal = C.Terminal(base, args, url, 160, 50)
    try:
        prior_screen = terminal.capture('01-prior-passed', [PRIOR, 'Goal: pass', 'Timing: completed'])
        green = pane_fg(prior_screen, 'timing', 'pass')
        require(green == pane_fg(prior_screen, 'stage checklist', 'completed', row_label='Timing:'),
                'Passing validated STA and completed stages use the success role')

        cancelled = seed(CANCELLED, cancelled=True, started_at='2026-11-19T12:01:00Z')
        select_run(cancelled)

        def projection():
            snapshot = native()
            run = next(r for r in field(snapshot, 'runs') if field(r, 'run') == cancelled)
            summary = next(s for s in field(snapshot, 'summaries') if field(s, 'run') == cancelled)
            stages = {field(s, 'id'): field(s, 'status') for s in field(run, 'stages')}
            evidence = field(summary, 'timing_analysis')[0]
            require(field(run, 'status') == 'cancelled' and stages['timing'] == 'Cancelled'
                    and stages['routing'] == 'Completed' and stages['signoff'] == 'Not_requested',
                    'Public run and physical stages preserve cancellation, Routing, and Signoff scope')
            require(field(evidence, 'status') == 'Completed' and field(evidence, 'timing_goal') == 'Pass'
                    and field(field(evidence, 'target'), 'attempt_id') == CANCELLED
                    and not field(summary, 'terminal'), 'Pass belongs to exact captured STA, not finalization')
            return field(summary, 'observed_at')

        def check_screen(label):
            screen = terminal.capture(label, [CANCELLED, 'Timing: cancelled', 'Routing: completed', 'STA runtime: 1.575s',
                    'Captured STA: pass (report only, not stage result)'], absent=['Goal: pass'])
            require(pane_fg(screen, 'timing', 'pass') != green
                    and pane_fg(screen, 'stage checklist', 'cancelled', row_label='Timing:') != green
                    and pane_fg(screen, 'stage checklist', 'completed', row_label='Routing:') == green,
                    'Cancelled Timing and report-only pass are not green; Routing stays green')

        before = projection()
        check_screen('03-cancelled-overview')
        terminal.command('Refresh evidence asic/' + CANCELLED)
        wait(lambda: projection() != before, 'summary refreshed through native palette')
        check_screen('04-cancelled-after-refresh')

        pin_timing(prior)
        pinned = terminal.capture('05-pinned-passed', ['PIN asic/' + PRIOR, 'Goal: pass', 'Timing: cancelled'])
        require(pane_fg(pinned, 'timing', 'pass') == green,
                'Explicit older pin still renders its own authoritative pass')
        pin_timing(None)

        terminal.command('Inspect timing paths asic/' + CANCELLED)
        investigation = terminal.capture('06-exact-timing-investigation', ['stage cancelled', CANCELLED + '-path',
            'Report bytes for ' + CANCELLED, 'Captured STA report, not a stage or signoff verdict'],
            absent=[PRIOR + '-path'])
        require(pane_fg(investigation, 'timing · paths', 'met', row_label=CANCELLED + '-path') != green,
                'A passing path is still inspectable but not painted as stage success')
        select_run(prior)
        terminal.command('Switch to Overview')
        terminal.capture('07-explicit-older-selection', ['Run (older): ' + PRIOR, 'Goal: pass'])
    finally:
        terminal.close()
        (base / 'http.json').write_text(json.dumps(http.history, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('daemon', 'client', 'preset-export'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--evidence', type=Path, help='New directory for private state and captures')
    args = parser.parse_args()
    for name in ('daemon', 'client', 'preset_export'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    args.timing_preload = 'explicit-only'
    os.umask(0o077)
    base = C.demo.prepare(args.evidence or
                          Path('/tmp/opencode') / ('cancelled-timing-pty-' + secrets.token_hex(6)),
                          manual=True)
    print('Evidence: ' + str(base), flush=True)
    for name in ('home', 'config', 'client-state', 'discovery', 'tmp'):
        (base / name).mkdir()
    os.environ['TMPDIR'] = str(base / 'tmp')
    settings = base / 'project/synthetic-settings.json'
    settings.write_text(json.dumps(dict(json.loads(settings.read_text()), executable_timing=True)))
    (base / 'project/synthetic-flow').write_text('#!' + sys.executable + '\nimport os,sys\n'
        + 'os.execv(sys.executable, ' + repr([sys.executable, str(Path(__file__).resolve()),
          '--fixture-provider', str(base)]) + ' + sys.argv[1:])\n')
    with (base / 'daemon.log').open('wb') as log:
        daemon = subprocess.Popen(C.demo.switch_command([args.daemon, '--port', '0',
            '--discovery-dir', base / 'discovery', '--state-dir', base / 'state']),
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            metadata = base / 'discovery/daemon.sexp'
            wait(lambda: metadata.exists() or daemon.poll() is not None, 'private daemon metadata')
            require(daemon.poll() is None, 'Private daemon exited; see daemon.log')
            exercise(base, args, field(C.parse(metadata.read_text()), 'endpoint'))
        finally:
            if daemon.poll() is None:
                os.killpg(daemon.pid, signal.SIGTERM)
                daemon.wait(timeout=10)
    print('PASS: cancelled Timing stays cancelled after refresh; exact STA and older pin are preserved')


if __name__ == '__main__':
    if sys.argv[1:2] == ['--fixture-provider']:
        fixture_provider(Path(sys.argv[2]), sys.argv[3:])
    else:
        main()
