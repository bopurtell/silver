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
import re
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
EVIDENCE_ROOT = Path('/var/tmp/cobalt-stage-progress')
STAGES = ('synthesis', 'floorplan', 'placement', 'cts', 'routing', 'timing', 'signoff')
STAGE_LABELS = {stage: 'cts' if stage == 'cts' else stage.title() for stage in STAGES}


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


@contextmanager
def hold_physical(f):
    """Gate one real daemon-owned fixture process, not a frontend/RPC reply."""
    gate = f.root / 'companion-physical-gate'
    gate.mkdir()
    try:
        yield gate
    finally:
        for marker in ('allocate', 'omit-stages', 'complete'):
            (gate / marker).unlink(missing_ok=True)
        gate.rmdir()


class Cobalt:
    def __init__(self, ui, base, width, height):
        self.ui, self.base, self.width, self.height = ui, base, width, height

    def send(self, *keys):
        for key in keys:
            self.ui.keys(key)
            time.sleep(.12)

    def capture(self, label, *markers, matches_screen=lambda _: True):
        def visible():
            return self.screen().text()

        try:
            def matches():
                screen = visible()
                return all(marker in screen for marker in markers) and matches_screen(screen)

            wait(matches, label, timeout=8)
        finally:
            (self.base / (label + '.ansi')).write_bytes(bytes(self.ui.output))
            (self.base / (label + '.txt')).write_text(visible())
        return visible()

    def screen(self):
        return Screen(bytes(self.ui.output), self.width, self.height)

    def palette(self, query):
        self.send(b' ', b'c', b'c', query.encode())

    def command(self, name):
        self.palette(name)
        self.send(b'\r')


def selected_workflow(f, trace, action, label, before_done=None, after_done=None):
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
    if before_done:
        before_done(reservation)
    workflow = f.done(key)
    if after_done:
        after_done(workflow)
    assert len(exchanges(trace, 'Launch_fresh', 'Run')) == 1, label
    run = field(workflow, 'run')[0]
    assert field(workflow, 'id') == field(reservation, 'id') != field(run, 'id')
    selection = dict(field(field(workflow, 'intent'), 'selection'))
    assert dict(selection['chip_target'][0]) == dict(chip='demo-chip', variant='small')
    plan = json.loads(Path(field(field(workflow, 'prepared')[0], 'methodology_plan_path')).read_text())
    prefix = plan['methodology']['recipe']['stages']
    assert tuple(prefix) == STAGES[:STAGES.index(selection['endpoint']) + 1]
    return dict(workflow=field(workflow, 'id'), run=field(run, 'id'), selection=selection,
                physical_prefix=prefix, expected_plan=field(field(workflow, 'intent'), 'expected_plan_identity'))


def workflow_in(snapshot, key):
    return next((w for w in field(snapshot, 'workflows') if field(w, 'key') == key), None)


def workflow_selection(workflow):
    return dict(field(field(workflow, 'intent'), 'selection'))


def linked_run(snapshot, workflow):
    runs = field(workflow, 'run')
    if runs:
        return next((r for r in field(snapshot, 'runs') if field(r, 'run') == runs[0]), None)


def set_native_run(f, run):
    ws = f.http.rpc(domain='workspace')
    overview = next(w for w in field(ws, 'workspaces') if field(w, 'preset') == ['overview'])
    context = next(c for c in field(ws, 'contexts') if field(c, 'id') == field(overview, 'context'))
    f.http.mutate(ws, '(Select_run (workspace %s) (context %s) (expected_selection_revision %s) (run %s))' %
                  (sexp(field(overview, 'id')), sexp(field(context, 'id')), field(context, 'selection_revision'),
                   sexp(run)))


def stage_statuses(run):
    return {field(s, 'id'): field(s, 'status') for s in field(run, 'stages')}


def expected_stage_statuses(endpoint, *, completed):
    prefix = STAGES[:STAGES.index(endpoint) + 1]
    return {s: 'Not_requested' if s not in prefix else
            'Completed' if completed else 'Running' if s == 'synthesis' else 'Pending'
            for s in STAGES}


def stage_pattern(stage, status, *, selected=False):
    marker = {'Running': '⣷', 'Pending': '◷', 'Completed': '✓', 'Not_requested': '·',
              'Unknown': '?'}[status]
    text = 'not reported' if status == 'Unknown' else status.replace('_', ' ').lower()
    return (('›\\s+' if selected else '') + re.escape(marker) + r'\s+' + STAGE_LABELS[stage]
            + r':\s+(?P<status>' + text + r')(?=\s|\||$)')


def distinct_status_colors(ui, statuses):
    screen = ui.screen()
    colors = []
    for stage, status in statuses.items():
        match = re.search(stage_pattern(stage, status), screen.text(), re.I)
        attrs, = screen.attrs_for(match[0])
        colors.append(attrs[match.start('status') - match.start()][0])
    assert 'default' not in colors and len(colors) == len(set(colors)), colors


def capture_stage_rows(ui, label, selection, statuses=None, *, selected=None,
                       elaboration=False, tail=False):
    target = dict(selection['chip_target'][0])
    context = f"{selection['flow']}/{selection['profile']} · {target['chip']}/{target['variant']}"
    expected = statuses or dict.fromkeys(STAGES, 'Unknown')

    def matches(screen):
        lines = screen.splitlines()
        columns = set()
        for stage, status in expected.items():
            # Count independently of status: a shadow endpoint row must not
            # coexist with the real observation row for that same stage.
            rows = [line for line in lines if re.search(r'\b' + STAGE_LABELS[stage] + ':', line, re.I)]
            if not tail and elaboration and stage == 'signoff' and not rows:
                continue  # The fixed-height bottom band scrolls one row.
            if len(rows) != 1:
                return False
            match = re.search(stage_pattern(stage, status, selected=selected == stage), rows[0], re.I)
            if match is None:
                return False
            columns.add(match.start('status'))
        return len(columns) == 1 and (
            bool(re.search(r'✓\s+Elaboration:\s+completed\b', screen)) if elaboration and not tail
            else not re.search(r'\bElaboration:\s+completed\b', screen))

    return ui.capture(label, 'Silver: Stage Checklist', context,
                      matches_screen=matches)


def checklist_snapshot(trace, key, predicate):
    """Use only snapshots actually returned to a client, never a fake responder."""
    for row in reversed(exchanges(trace, 'Get')):
        if field(parse(row['request']), 'operation') != 'Get':
            continue  # The launch adapter has its own scoped Get/revalidation path.
        result, snapshot = parse(row['response'])
        if result == 'Ok' and (workflow := workflow_in(snapshot, key)):
            run = linked_run(snapshot, workflow)
            if predicate(workflow, run):
                return workflow, run


class LiveProgress:
    def __init__(self, f, ui, native_trace, cobalt_trace, label, gate, selection):
        self.f, self.ui, self.label = f, ui, label
        self.native_trace, self.cobalt_trace = native_trace, cobalt_trace
        self.gate, self.selection = gate, selection
        self.watched = checklist.selected(f)
        self.record = {}

    def capture(self, name, *, phase, statuses=None):
        label = self.label + '-' + name

        def authoritative(workflow, run):
            if workflow_selection(workflow) != self.selection or field(workflow, 'phase') != phase:
                return False
            if name == 'before-allocation':
                return run is None and not field(workflow, 'run')
            if run is None:
                return False
            if name == 'absent-stages':
                return field(run, 'status') == 'observing' and not stage_statuses(run)
            return stage_statuses(run) == statuses

        workflow, run = wait(lambda: checklist_snapshot(self.cobalt_trace, self.key, authoritative),
                             label + ' public Cobalt Get evidence', timeout=12)
        assert field(workflow, 'id') == self.workflow
        self.record[name] = dict(workflow=workflow, run=run)
        save(self.f.base / (self.label + '-public-evidence.json'), self.record)
        assert field(workflow, 'elaboration_status') == 'completed'
        endpoint = self.selection['endpoint']
        capture_stage_rows(self.ui, label + '-cobalt', self.selection, statuses,
                           selected=endpoint, elaboration=True)
        if name == 'running':
            distinct_status_colors(self.ui, dict(synthesis='Running', routing='Pending', timing='Not_requested'))
        elif name == 'completed':
            distinct_status_colors(self.ui, dict(synthesis='Completed', timing='Not_requested'))
        self.ui.send(b'G')
        capture_stage_rows(self.ui, label + '-cobalt-tail', self.selection, statuses,
                           selected='signoff', elaboration=True, tail=True)
        self.ui.send(b'g', b'g', *[b'j'] * (STAGES.index(endpoint) + 1))
        capture_stage_rows(self.ui, label + '-cobalt-restored', self.selection, statuses,
                           selected=endpoint, elaboration=True)
        if run is None:
            assert checklist.selected(self.f) == self.watched
            return

        run_ref = field(run, 'run')
        assert field(workflow, 'reference') == [field(run, 'reference')]
        assert field(run, 'selection') == [field(field(workflow, 'intent'), 'selection')]
        if name in ('absent-stages', 'completed'):
            assert run_ref == field(self.record['running']['run'], 'run')
        if name == 'completed':
            assert field(run, 'status') == 'completed'
        # Picking the run here is an explicit test inspection, not a side
        # effect of R. Restore the original Silver workspace selection.
        assert checklist.selected(self.f) == self.watched
        begin = len(self.native_trace)
        try:
            set_native_run(self.f, [run_ref])
            fixture.zoom(self.f, 'stage-checklist')
            markers = ['stage checklist', 'Elaboration: completed'] + [
                field(s, 'name') + ': ' + field(s, 'status').replace('_', ' ').lower()
                for s in field(run, 'stages')
            ]
            if name == 'absent-stages':
                self.f.terminal.capture(label + '-native', markers + [endpoint + ': unconfirmed'],
                                        [endpoint + ': completed', 'synthesis: running', 'placement: pending'])
            else:
                self.f.terminal.capture(label + '-native', markers)
            assert checklist.selected(self.f) == [run_ref]
            native_workflow, native_run = wait(
                lambda: checklist_snapshot(self.native_trace[begin:], self.key, authoritative),
                label + ' matching native Silver Get evidence', timeout=5)
            assert field(native_workflow, 'id') == self.workflow
            assert field(native_run, 'run') == run_ref
            self.record[name].update(native_workflow=native_workflow, native_run=native_run)
            save(self.f.base / (self.label + '-public-evidence.json'), self.record)
        finally:
            set_native_run(self.f, self.watched)

    def before_done(self, reservation):
        self.key, self.workflow = field(reservation, 'key'), field(reservation, 'id')
        self.record['reservation'] = reservation
        assert workflow_selection(reservation) == self.selection
        self.capture('before-allocation', phase='Physical')
        (self.gate / 'allocate').touch()
        self.capture('running', phase='Physical',
                     statuses=expected_stage_statuses(self.selection['endpoint'], completed=False))
        (self.gate / 'omit-stages').touch()
        self.capture('absent-stages', phase='Physical')
        (self.gate / 'complete').touch()

    def after_done(self, workflow):
        assert field(workflow, 'id') == self.workflow
        self.capture('completed', phase='Completed',
                     statuses=expected_stage_statuses(self.selection['endpoint'], completed=True))


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
    screen = ui.capture('c8-empty-editor', 'WB095_OUTSIDE_DOCUMENT')
    assert 'Silver: Flow Runner' not in screen
    ui.command('silver stage checklist')
    selection = selected_inputs('standard', 'routing')
    assert not field(f.snapshot(), 'workflows')
    capture_stage_rows(ui, 'c8-checklist-no-asic-evidence', selection)
    ui.send(b'gg', b'j', b'j', b'j', b'j')
    capture_stage_rows(ui, 'c8-routing-selected', selection, selected='routing')

    with hold_physical(f) as gate:
        progress = LiveProgress(f, ui, native_trace, cobalt_trace, 'c8-stage-progress', gate, selection)
        begin = len(cobalt_trace)
        ui.send(b'R')
        compared['checklist'] = selected_workflow(
            f, TraceWindow(cobalt_trace, begin), 'Launch_fresh', 'checklist',
            before_done=progress.before_done, after_done=progress.after_done)
    capture_stage_rows(ui, 'c8-focus-after-R', selection,
                       expected_stage_statuses('routing', completed=True), selected='routing', elaboration=True)
    for index, endpoint in [(5, 'routing'), (1, 'synthesis'), (6, 'timing')]:
        checklist.position(f, index)
        begin = len(native_trace)
        native.key(b'R')
        compared['native-' + endpoint] = selected_workflow(
            f, TraceWindow(native_trace, begin), 'Launch_fresh', 'native-' + endpoint)
        assert checklist.selected(f) == watched
    assert compared['checklist']['selection'] == compared['native-routing']['selection']

    for name, endpoint in [('synth', 'synthesis'), ('timing', 'timing'), ('routing', 'routing')]:
        begin = len(cobalt_trace)
        ui.palette(name)
        screen = ui.capture('c8-alias-' + name, 'Run ' + name + ' ·')
        assert_first(screen, name)
        ui.send(b'\r')
        result = selected_workflow(f, TraceWindow(cobalt_trace, begin), 'Launch_fresh', name)
        assert result['selection'] == compared['native-' + endpoint]['selection']
        compared[name] = result
    ui.capture('c8-last-ack', 'Accepted · workfl')
    capture_stage_rows(ui, 'c8-last-progress', selection,
                       expected_stage_statuses('routing', completed=True), selected='routing', elaboration=True)
    ui.palette('routing')
    ui.capture('c8-alias-reopened', 'Run routing ·')
    ui.send(b' checklist')
    screen = ui.capture('c8-related', 'routing checklist', '> Silver: Stage Checklist')
    assert 'Run routing ·' not in screen, screen
    ui.send(b'\x1b')
    capture_stage_rows(ui, 'c8-palette-restores-checklist', selection,
                       expected_stage_statuses('routing', completed=True), selected='routing', elaboration=True)
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
    # The independent observation reader also sends unscoped Get requests.
    # Inspect the launch revalidation's catalog, not that reader's context.
    revalidation = next(r for r in exchanges(cobalt_trace[begin:], 'Get')
                        if (operation := field(parse(r['request']), 'operation')) != 'Get'
                        and field(operation[1:], 'context') == 'cobalt-companion-v1')
    latest = parse(revalidation['response'])[1]
    standard = next(flow for flow in field(latest, 'flows') if field(flow, 'id') == 'standard')
    assert 'routing' not in field(standard, 'fresh_stage_endpoints')
    ui.send(b'\x1b')

    ui.send(b' vU', b'r', b'\x1b')
    capture_stage_rows(ui, 'c8-routing-evidence-stays-separate-from-capability', selection,
                       expected_stage_statuses('routing', completed=True), elaboration=True)
    ui.palette('routing')
    screen = ui.capture('c8-exact-disabled', 'Run routing · Unavailable:')
    assert_first(screen, 'routing')
    begin, before = len(cobalt_trace), len(field(f.snapshot(), 'workflows'))
    ui.send(b'\t', b'\r')
    without_submit(cobalt_trace, f, begin, before)
    assert not exchanges(cobalt_trace[begin:], 'Stage_fresh')


class TraceWindow:
    def __init__(self, trace, start):
        self.trace, self.start = trace, start

    def __iter__(self):
        return iter(self.trace[self.start:])


def assert_first(screen, alias, *, title=None):
    lines = screen.splitlines()
    query = next(i for i, line in enumerate(lines) if f'> {alias} ' in line)
    title = title or f'Run {alias} ·'
    assert f'> {title}' in lines[query + 1], screen


def selected_inputs(flow, endpoint, *, profile='balanced', assignments=()):
    return dict(flow=flow, profile=profile, endpoint=endpoint, assignments=list(assignments),
                chip_target=[[['chip', 'demo-chip'], ['variant', 'small']]])


def c9(f, ui, native_url, native_trace, cobalt_trace):
    watched = checklist.selected(f)
    before = len(field(f.snapshot(), 'workflows'))
    ui.palette('st')
    ui.send(b'\t', b'\r')
    capture_stage_rows(ui, 'c9-stage-initial', selected_inputs('standard', 'routing'))
    ui.send(b'g', b'g', b'j', b'j', b'j', b'j')
    capture_stage_rows(ui, 'c9-stage-routing', selected_inputs('standard', 'routing'), selected='routing')
    ui.palette('flow')
    assert_first(ui.capture('c9-flow-palette', 'Silver: Flow Runner'), 'flow',
                 title='Silver: Flow Runner')
    ui.send(b'\t', b'\r')
    ui.capture('c9-flow-choice', 'WB095_OUTSIDE_DOCUMENT', 'Silver: Flow Runner',
               '› Standard fixture · active', 'Explore fixture')
    ui.send(b'j')
    ui.capture('c9-flow-explore', '› Explore fixture · active')
    ui.send(b'k')
    ui.capture('c9-flow-standard', '› Standard fixture · active')
    ui.send(b'j')
    ui.capture('c9-flow-explore-again', '› Explore fixture · active')
    assert not exchanges(cobalt_trace, 'Plan', 'Stage_fresh')
    without_submit(cobalt_trace, f, 0, before)
    ui.command('Toggle Silver: Flow Runner')
    screen = ui.capture('c9-selector-hidden', 'WB095_OUTSIDE_DOCUMENT')
    assert 'Explore fixture' not in screen
    ui.palette('st')
    ui.send(b'\t', b'\r')
    selection = selected_inputs('explore', 'routing')
    capture_stage_rows(ui, 'c9-stage-explore', selection, selected='routing')
    with hold_physical(f) as gate:
        progress = LiveProgress(f, ui, native_trace, cobalt_trace, 'c9-stage-progress', gate, selection)
        begin = len(cobalt_trace)
        ui.send(b'R')
        stage = selected_workflow(f, TraceWindow(cobalt_trace, begin), 'Launch_fresh', 'selected-flow',
                                  before_done=progress.before_done, after_done=progress.after_done)
    assert stage['selection'] == selection
    assert not stage['expected_plan'] and checklist.selected(f) == watched
    save(f.base / 'c9-selected-flow.json', stage)

    start_after_stage = len(cobalt_trace)
    ui.command('flow')
    ui.send(b'k')
    ui.capture('c9-stale-standard-choice', '› Standard fixture · active')
    ui.palette('st')
    ui.send(b'\t', b'\r')
    capture_stage_rows(ui, 'c9-no-borrowed-explore-evidence', selected_inputs('standard', 'routing'),
                       selected='routing')
    ui.command('flow')
    ui.send(b'j')
    ui.capture('c9-explore-restored', '› Explore fixture · active')
    ui.palette('st')
    ui.send(b'\t', b'\r')
    capture_stage_rows(ui, 'c9-same-flow-evidence-restored', selection,
                       expected_stage_statuses('routing', completed=True), selected='routing', elaboration=True)
    without_submit(cobalt_trace, f, start_after_stage, before + 1)

    selection = selected_inputs('explore', 'routing', profile='review', assignments=['STRATEGY=delay'])
    before = len(field(f.snapshot(), 'workflows'))
    expected = native_plan(f, native_url, selection)
    assert dict(field(expected, 'selection')) == selection
    ui.command('Silver: Flow Review')
    ui.capture('c9-review-choices', 'Silver: Flow Review', '› Flow choice: Explore fixture')
    begin = len(cobalt_trace)
    ui.send(b'K')  # No reviewed preview: never submit anything else.
    without_submit(cobalt_trace, f, begin, before)
    ui.send(b'\r')
    ui.capture('c9-edit', 'Flow inputs', 'Explore fixture')
    ui.send(b'\x15', b'review', b'\t', b'\x15', b'routing', b'\t', b'\x15', b'delay', b'\r')
    ui.capture('c9-draft', 'Applied draft (not a preview)', 'Profile: review')
    assert not exchanges(cobalt_trace[begin:], 'Plan')
    without_submit(cobalt_trace, f, begin, before)
    ui.send(b'p')
    plan_id = field(expected, 'plan_identity')
    ui.capture('c9-preview', 'Reviewed preview: ' + plan_id, 'demo-chip / small',
               'Flow: explore', 'Profile: review', 'Endpoint: routing', 'Parameter STRATEGY = delay')
    without_submit(cobalt_trace, f, begin, before)
    ui.send(b'K', b'K')
    result = selected_workflow(f, TraceWindow(cobalt_trace, begin), 'Run', 'kickoff')
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
    parser.add_argument('--evidence-parent', type=Path, default=EVIDENCE_ROOT)
    parser.add_argument('--slice', choices=('c8', 'c9'), required=True)
    args = parser.parse_args()
    parent = args.evidence_parent.resolve()
    if not parent.is_relative_to(EVIDENCE_ROOT):
        parser.error(f'--evidence-parent must be in {EVIDENCE_ROOT}')
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.evidence = Path(tempfile.mkdtemp(prefix=f'wb095-{args.slice}-', dir=parent))
    tmp = args.evidence / 'tmp'
    tmp.mkdir(mode=0o700)
    os.environ['TMPDIR'] = str(tmp)  # Includes the daemon, both clients, and their subprocesses.
    args.build_lock = parent / 'publisher-build.lock'
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
            width, height = 260, 36
            with editor(str(args.cobalt), file, env, ['--silver-endpoint', url, '--silver-project',
                                                     str(f.root), '--silver-run', watched], width=width) as term:
                ui = Cobalt(term, f.base, width, height)
                attempt_row = re.compile(r'\bAttempt: +' + re.escape(watched) + r'(?= *[│\n]|$)')
                ui.capture(args.slice + '-watched-before', 'Silver: Overview',
                           matches_screen=lambda screen: attempt_row.search(screen) is not None)
                if args.slice == 'c8':
                    c8(f, ui, native, native_trace, trace)
                else:
                    c9(f, ui, native_url, native_trace, trace)
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
