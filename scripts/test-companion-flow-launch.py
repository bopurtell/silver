#!/usr/bin/env python3
"""WB-095 native Silver and standalone Cobalt PTYs against one private real daemon."""
import argparse
from contextlib import contextmanager
import hashlib
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'fixtures'))
import fresh_frontend as fixture

api = fixture.api
field, sexp, wait, save = api.field, api.sexp, api.wait, api.save
parse, Terminal, Screen = api.c.parse, api.c.Terminal, api.c.Screen
checklist = api.module('native_checklist', HERE / 'test-checklist-launch-workflow.py')


def companion_operation(f, operation):
    kind = 'discover' if operation == 'Discover' else 'plan'

    def rpc(op):
        return f.http.rpc('(In_context (context cobalt-companion-v1) (initial_target ()) (operation %s))'
                          % op, wait=False)

    def settled(snapshot):
        tasks = [task for task in field(snapshot, 'operations') if field(task, 'kind') == kind]
        assert not [t for t in tasks if field(t, 'state') == 'failed'], tasks
        if not [t for t in tasks if field(t, 'state') in ('pending', 'executing')]:
            return snapshot

    snapshot = settled(rpc(operation)) or wait(lambda: settled(rpc('Get')), kind + ' in companion context')
    assert field(snapshot, 'catalog_default' if kind == 'discover' else 'preview')
    return snapshot


def op(body):
    operation = field(parse(body), 'operation')
    if isinstance(operation, list) and operation[0] == 'In_context':
        operation = field(operation[1:], 'operation')
    if isinstance(operation, str):
        return operation, None
    if operation[0] in ('Stage_fresh', 'Launch_fresh', 'Run'):
        return operation[0], operation[1:]
    return operation[0], operation[1]


@contextmanager
def recorder(f, name):
    target = urlsplit(f.url)
    trace = []
    journal = (f.base / (name + '-http.jsonl')).open('w')

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def forward(self):
            request = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            conn = HTTPConnection(target.hostname, target.port, timeout=30)
            try:
                conn.request(self.command, self.path, request if self.command == 'POST' else None,
                             {k: v for k, v in self.headers.items()
                              if k.lower() in ('content-type', 'x-workbench-protocol')})
                response = conn.getresponse()
                body = response.read()
                row = dict(method=self.command, path=self.path, request=request.decode(),
                           status=response.status, response=body.decode())
                trace.append(row)
                journal.write(json.dumps(row) + '\n')
                journal.flush()
                self.send_response(response.status)
                self.send_header('Content-Type', 'application/sexp')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            finally:
                conn.close()

        do_GET = forward
        do_POST = forward

    with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f'http://127.0.0.1:{server.server_port}', trace
        finally:
            server.shutdown()
            thread.join()
            journal.close()


def exchanges(trace, *operations):
    return [row for row in trace if row['path'] == '/api/v1/asic'
            and op(row['request'])[0] in operations]


def configure(f):
    shutil.copyfile(f.root / 'fixture.py', f.root / 'unified_fresh_prefix.py')
    shutil.copyfile(HERE / 'fixtures/companion_flow.py', f.root / 'fixture.py')


class Cobalt:
    def __init__(self, ui, base):
        self.ui, self.base = ui, base

    def send(self, *keys):
        for key in keys:
            self.ui.keys(key)
            time.sleep(.12)

    def capture(self, label, *markers):
        def visible():
            return Screen(bytes(self.ui.output), 260, 36).text()

        try:
            def matches():
                screen = visible()
                return all(marker in screen for marker in markers)

            wait(matches, label, timeout=8)
        finally:
            (self.base / (label + '.ansi')).write_bytes(bytes(self.ui.output))
            (self.base / (label + '.txt')).write_text(visible())
        return visible()

    def palette(self, query):
        self.send(b' ', b'c', b'c', query.encode())

    def command(self, name):
        self.palette(name)
        self.send(b'\r')


def selected_workflow(f, trace, action, label):
    row = wait(lambda: next(iter(exchanges(trace, 'Launch_fresh', 'Run')), None),
               label + ' reservation')
    assert len(exchanges(trace, 'Launch_fresh', 'Run')) == 1, label
    operation, payload = op(row['request'])
    assert action == operation, (action, operation)
    key = field(payload, 'key')
    result, snapshot = parse(row['response'])
    assert result == 'Ok', row
    reservation = next(w for w in field(snapshot, 'workflows') if field(w, 'key') == key)
    assert not field(reservation, 'run'), 'Expected reservation before physical allocation'
    workflow = f.done(key)
    run = field(workflow, 'run')[0]
    assert field(workflow, 'id') == field(reservation, 'id') != field(run, 'id')
    selection = dict(field(field(workflow, 'intent'), 'selection'))
    assert dict(selection['chip_target'][0]) == dict(chip='demo-chip', variant='small')
    plan = json.loads(Path(field(field(workflow, 'prepared')[0], 'methodology_plan_path')).read_text())
    prefix = plan['methodology']['recipe']['stages']
    stages = ['synthesis', 'floorplan', 'placement', 'cts', 'routing', 'timing', 'signoff']
    assert prefix == stages[:stages.index(selection['endpoint']) + 1]
    return dict(workflow=field(workflow, 'id'), run=field(run, 'id'), selection=selection,
                physical_prefix=prefix, expected_plan=field(field(workflow, 'intent'), 'expected_plan_identity'))


def native_plan(f, url, selection):
    env = dict(os.environ, HOME=str(f.base / 'home'), XDG_CONFIG_HOME=str(f.base / 'config'),
               XDG_STATE_HOME=str(f.base / 'client-state'))
    cmd = [str(f.args.client), '--connect', url, '--project-root', str(f.root),
           '--environment', 'inherited', '--api', '--wait', '--asic-operation',
           '(Plan ' + sexp(list(selection.items())) + ')']
    proc = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=45)
    (f.base / 'native-plan.stdout').write_text(proc.stdout)
    (f.base / 'native-plan.stderr').write_text(proc.stderr)
    assert proc.returncode == 0, (cmd, proc.stderr, proc.stdout)
    return field(parse(proc.stdout)[1], 'preview')[0]


def without_submit(trace, f, prior, before):
    time.sleep(.4)
    assert not exchanges(trace[prior:], 'Launch_fresh', 'Run')
    assert len(field(f.snapshot(), 'workflows')) == before


def c8(f, ui, native, native_trace, cobalt_trace):
    compared = {}
    watched = checklist.selected(f)
    assert watched
    for index, endpoint in [(5, 'routing'), (1, 'synthesis'), (6, 'timing')]:
        checklist.position(f, index)
        begin = len(native_trace)
        native.key(b'R')
        compared['native-' + endpoint] = selected_workflow(
            f, TraceWindow(native_trace, begin), 'Launch_fresh', 'native-' + endpoint)
        assert checklist.selected(f) == watched
    screen = ui.capture('c8-empty-editor', 'WB095_OUTSIDE_DOCUMENT')
    assert 'Silver flow kickoff' not in screen
    ui.command('silver stage checklist')
    ui.capture('c8-checklist', 'Silver: Stage checklist', 'Routing', 'Ready:')
    ui.send(b'gg', b'j', b'j', b'j', b'j')
    ui.capture('c8-routing-selected', '› Routing')
    for name, endpoint, keys in [
            ('checklist', 'routing', [b'R']),
            ('synth', 'synthesis', []), ('timing', 'timing', []), ('routing', 'routing', [])]:
        begin = len(cobalt_trace)
        if keys:
            ui.send(*keys)
        else:
            ui.palette(name)
            screen = ui.capture('c8-alias-' + name, 'Run ' + name + ' ·')
            assert_first(screen, name)
            ui.send(b'\r')
        result = selected_workflow(f, TraceWindow(cobalt_trace, begin), 'Launch_fresh', name)
        assert result['selection'] == compared['native-' + endpoint]['selection']
        compared[name] = result
        if keys:
            ui.capture('c8-focus-after-R', '› Routing')
    ui.capture('c8-last-ack', 'Accepted · workfl', '› Routing')
    ui.palette('routing')
    ui.capture('c8-alias-reopened', 'Run routing ·')
    ui.send(b' checklist')
    screen = ui.capture('c8-related', 'routing checklist', '> Silver: Stage checklist')
    assert 'Run routing ·' not in screen, screen
    ui.send(b'\x1b')
    ui.capture('c8-palette-restores-checklist', '› Routing')
    assert checklist.selected(f) == watched
    assert len({record['run'] for record in compared.values()}) == len(compared)
    assert len({record['workflow'] for record in compared.values()}) == len(compared)
    save(f.base / 'c8-comparisons.json', compared)

    # The real Discover reply loses Routing while an already rendered exact
    # action remains captured in the Cobalt palette.
    ui.palette('routing')
    assert_first(ui.capture('c8-alias-before-withdrawal', 'Run routing · endpoint routing'), 'routing')
    (f.root / 'withdraw-routing').touch()
    companion_operation(f, 'Discover')
    begin, before = len(cobalt_trace), len(field(f.snapshot(), 'workflows'))
    ui.send(b'\r', b' vM')
    ui.capture('c8-captured-stale', 'Silver stage · Rejected')
    without_submit(cobalt_trace, f, begin, before)
    assert not exchanges(cobalt_trace[begin:], 'Stage_fresh')
    latest = parse(exchanges(cobalt_trace[begin:], 'Get')[0]['response'])[1]
    standard = next(flow for flow in field(latest, 'flows') if field(flow, 'id') == 'standard')
    assert 'routing' not in field(standard, 'fresh_stage_endpoints')
    ui.send(b'\x1b')

    ui.send(b' vU', b'r', b'\x1b')
    ui.capture('c8-routing-unavailable', 'does not advertise Routing')
    ui.palette('routing')
    screen = ui.capture('c8-exact-disabled', 'Run routing · Unavailable:')
    assert_first(screen, 'routing')
    begin, before = len(cobalt_trace), len(field(f.snapshot(), 'workflows'))
    ui.send(b'\t', b'\r')
    without_submit(cobalt_trace, f, begin, before)


class TraceWindow:
    def __init__(self, trace, start):
        self.trace, self.start = trace, start

    def __iter__(self):
        return iter(self.trace[self.start:])


def assert_first(screen, alias):
    lines = screen.splitlines()
    query = next(i for i, line in enumerate(lines) if f'> {alias} ' in line)
    assert f'> Run {alias} ·' in lines[query + 1], screen


def c9(f, ui, native_url, cobalt_trace):
    selection = dict(flow='explore', profile='review', endpoint='routing',
                     assignments=['STRATEGY=delay'], chip_target=[[['chip', 'demo-chip'], ['variant', 'small']]])
    watched = checklist.selected(f)
    before = len(field(f.snapshot(), 'workflows'))
    expected = native_plan(f, native_url, selection)
    assert dict(field(expected, 'selection')) == selection
    ui.command('Focus Silver flow kickoff')
    ui.capture('c9-flow-choice', 'Flow choice: Explore fixture')
    ui.send(b'j', b'\r')
    ui.capture('c9-edit', 'Flow inputs', 'Explore fixture')
    ui.send(b'\x15', b'review', b'\t', b'\x15', b'routing', b'\t', b'\x15', b'delay', b'\r')
    ui.capture('c9-draft', 'Applied draft (not a preview)', 'Profile: review')
    assert not exchanges(cobalt_trace, 'Plan')
    without_submit(cobalt_trace, f, 0, before)
    ui.send(b'p')
    plan_id = field(expected, 'plan_identity')
    ui.capture('c9-preview', 'Reviewed preview: ' + plan_id, 'demo-chip / small',
               'Flow: explore', 'Profile: review', 'Endpoint: routing', 'Parameter STRATEGY = delay')
    without_submit(cobalt_trace, f, 0, before)
    ui.send(b'K', b'K')
    result = selected_workflow(f, cobalt_trace, 'Run', 'kickoff')
    assert result['selection'] == selection and result['expected_plan'] == [plan_id]
    transmitted = field(op(exchanges(cobalt_trace, 'Run')[0]['request'])[1], 'preview')
    assert dict(transmitted) == dict(expected)
    ui.capture('c9-ack', 'Accepted · workflow ' + result['workflow'])
    assert checklist.selected(f) == watched
    save(f.base / 'c9-comparison.json', result)

    ui.send(b'p')
    ui.capture('c9-preview-before-edit', 'Reviewed preview: ' + plan_id)
    # Change the draft after review. The old preview must not be submittable.
    ui.send(b'G', b'\r')
    ui.capture('c9-reedit', 'Flow inputs', 'Explore fixture')
    ui.send(b'\t', b'\t', b'\x15', b'area', b'\r')
    ui.capture('c9-invalidated', 'Kickoff disabled: Prepare the edited inputs before Kickoff')
    begin = len(cobalt_trace)
    ui.send(b'K')
    without_submit(cobalt_trace, f, begin, before + 1)
    ui.send(b'p')
    ui.capture('c9-preview-before-supersession', 'Reviewed preview:', 'Parameter STRATEGY = area')
    # Another client uses the same protocol context (as a second companion
    # would). Its plan must not be substituted for the one Cobalt displayed.
    alternate = dict(selection, endpoint='placement')
    companion_operation(f, '(Plan %s)' % sexp(list(alternate.items())))
    begin = len(cobalt_trace)
    ui.send(b'K')
    ui.capture('c9-server-stale', 'reviewed preview was superseded')
    without_submit(cobalt_trace, f, begin, before + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('daemon', 'client', 'preset-export', 'cobalt'):
        parser.add_argument('--' + key, required=True, type=lambda x: Path(x).resolve(strict=True))
    parser.add_argument('--cobalt-source', required=True, type=lambda x: Path(x).resolve(strict=True))
    parser.add_argument('--evidence-parent', type=Path, default=Path('/tmp/opencode'))
    parser.add_argument('--slice', choices=('c8', 'c9'), required=True)
    args = parser.parse_args()
    args.evidence = Path(tempfile.mkdtemp(prefix='wb095-', dir=args.evidence_parent.resolve(strict=True)))
    print(f'WB-095 {args.slice} evidence: {args.evidence}', flush=True)
    binaries = {}
    for name in ('daemon', 'client', 'preset_export', 'cobalt'):
        path = getattr(args, name)
        with path.open('rb') as binary:
            binaries[name] = dict(path=str(path), sha256=hashlib.file_digest(binary, 'sha256').hexdigest())
    save(args.evidence / 'binaries.json', binaries)
    sys.path.insert(0, str(args.cobalt_source / 'bin'))
    from test_silver_cli import editor
    f = None

    def check(ok, label):
        assert ok, label

    try:
        f, _ = fixture.setup(args, args.slice, check, configure=configure, attach=False, use_switch=False)
        file = f.base / 'outside-project.txt'
        file.write_text('WB095_OUTSIDE_DOCUMENT\n')
        env = dict(os.environ, HOME=str(f.base / 'home'), XDG_CONFIG_HOME=str(f.base / 'config'),
                   XDG_STATE_HOME=str(f.base / 'client-state'), XDG_RUNTIME_DIR=str(f.base / 'home'),
                   TERM='xterm-256color', COLORTERM='truecolor', LC_ALL='C.UTF-8')
        with recorder(f, 'native') as (native_url, native_trace), recorder(f, 'cobalt') as (url, trace):
            f.terminal = native = Terminal(f.base, args, native_url, 180, 55, inherited=True)
            native.capture('native-startup', ['stage checklist'])
            native.command('Quick-launch behavior: keep current context')
            seed = api.c.demo.seed_simulation(f.base, f.http)
            watched = seed['submissions']['synthetic-fs2-v1-pass']['attempt_id']
            with editor(str(args.cobalt), file, env, ['--silver-endpoint', url, '--silver-project',
                                                     str(f.root), '--silver-run', watched], width=260) as term:
                ui = Cobalt(term, f.base)
                ui.capture(args.slice + '-watched-before', 'Attempt: ' + watched)
                if args.slice == 'c8':
                    c8(f, ui, native, native_trace, trace)
                else:
                    c9(f, ui, native_url, trace)
                assert {field(parse(r['request']), 'operation')[1] for r in trace if
                        r['path'] == '/api/v1/simulation' and
                        isinstance(field(parse(r['request']), 'operation'), list) and
                        field(parse(r['request']), 'operation')[0] == 'Observe'} == {watched}
            assert file.read_text() == 'WB095_OUTSIDE_DOCUMENT\n'
            for rows in (native_trace, trace):
                opens = [r for r in rows if r['path'] == '/api/v1/open-project']
                assert opens
                for row in opens:
                    request = dict(parse(row['request']))
                    assert request['root'] == str(f.root) and request['environment'] == 'Inherit_daemon'
                    assert field(field(parse(row['response'])[1], 'project'), 'id') == f.http.project
    finally:
        if f:
            fixture.finish(f)
    print('PASS: WB-095 ' + args.slice)


if __name__ == '__main__':
    main()
