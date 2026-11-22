#!/usr/bin/env python3
"""WB-097 acceptance against prebuilt native daemon, terminal and preset exporter.

Run with --daemon, --client, --preset-export and a new private --evidence directory
(prefer /tmp/opencode). The fixture uses private synthetic provider data; keyboard
input, workspace selection, native HTTP/cache and rendered PTY cells are real.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('index_preload', HERE / 'test-timing-preload.py')
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
C, H = legacy.C, legacy.H
field, sexp, wait = C.field, C.sexp, C.wait


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def row_id(number):
    # Neither input order nor lexical ID order is Timing Paths order.
    return 'path-' + 'zfakmq'[number - 1]


def row_name(case, number):
    return f'{case}-path-{number}'


def token(case, number):
    return f'Detail-only arrival: {case.upper()}-{number}-END'


def fixture_provider(base, argv):
    p = legacy.load('detail_preload_provider', base / 'project/synthetic-provider/provider.py')
    old_report, old_inspect = p.report, p.inspect

    def config(path):
        cfg = Path(path).parent / 'detail-preload-fixture.json'
        return json.loads(cfg.read_text()) if cfg.exists() else None

    def observation(path, cfg):
        a = legacy.OLD.observation(str(path) + '.timing-source')
        a.update(schema_version=2, stage='timing', source_digest=sha('analysis/' + cfg['case']),
                 occurrence_id=Path(path).parent.name + '/implementation.timing',
                 evidence_scope='immutable_timing_execution_source_not_checkpoint',
                 enclosing_status='running')
        return a

    def report(path):
        result = old_report(path)
        if cfg := config(path):
            result['timing_analysis'] = observation(path, cfg)
        return result

    def inspect(path, domain, stage, row_id_arg=None, expected=None):
        cfg = config(path)
        if cfg is None or (domain, stage) != ('timing', 'timing'):
            return old_inspect(path, domain, stage, row_id_arg, expected)
        case = cfg['case']
        a = observation(path, cfg)
        digest = sha('index/' + case)
        numbers = [n for n in (4, 2, 6, 1, 5, 3) if n <= cfg['count']]
        by_id = {row_id(n): n for n in numbers}
        number = by_id[row_id_arg] if row_id_arg is not None else 0

        def event(state):
            record = dict(state=state, case=case, number=number, row_id=row_id_arg,
                          expected=expected, pid=os.getpid(), time_ns=time.monotonic_ns())
            fd = os.open(base / 'timing-detail-events.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.write(fd, json.dumps(record).encode() + b'\n')
            finally:
                os.close(fd)

        event('start')
        if expected != (digest if number else a['source_digest']):
            event('wrong-digest')
            raise ValueError('Timing fixture received the wrong captured digest')
        time.sleep(.15)
        if number in cfg['hold']:
            release = base / f'release-{case}-{number}'
            deadline = time.monotonic() + 25
            while not release.exists():
                if time.monotonic() >= deadline:
                    event('gate-timeout')
                    raise ValueError(f'Timing fixture gate timed out: {case}/{number}')
                time.sleep(.02)
        if number == cfg['missing']:
            event('missing')
            raise ValueError(f'WB-097 fixture missing path detail {case}/{number}')
        result = dict(contract='hardcaml-asic.inspection', schema_version=1,
                      execution_file=str(path), execution_sha256=p.digest(path),
                      attempt_id=a['attempt_id'], domain=domain, stage=stage,
                      analysis_id=a['analysis_id'], analysis_digest=a['source_digest'],
                      source_digest=digest, diagnostics=['WB-097 synthetic STA'], truncated=False,
                      rows=[dict(id=row_id(n), category='timing_path', producer='OpenROAD.STAPostPNR',
                                 corner='slow', group='setup', name=row_name(case, n), value=(n - 7) / 10,
                                 unit='ns', status='violated', source='{}',
                                 fields=[['startpoint', f'from{n}'], ['endpoint', f'to{n}']])
                            for n in numbers])
        if number:
            result.update(row_id=row_id_arg, detail=token(case, number))
        event('returned')
        return result

    p.report, p.inspect = report, inspect
    sys.argv = [str(base / 'project/synthetic-flow')] + argv
    p.main()


class Journey:
    def __init__(self, terminal, check, http):
        self.t, self.check, self.http = terminal, check, http
        self.base = terminal.base
        self.runs, self.attempts = {}, {}
        self.provider = legacy.load('detail_preload_seed', self.base / 'project/synthetic-provider/provider.py')
        wrapper = self.base / 'project/synthetic-flow'
        command = [sys.executable, str(Path(__file__).resolve()), '--fixture-provider', str(self.base)]
        wrapper.write_text(f'#!{sys.executable}\nimport os,sys\nos.execv(sys.executable, {command!r} + sys.argv[1:])\n')

    def registry(self):
        return self.http.rpc(domain='workspace')

    def native(self, operation='Get'):
        return legacy.EX.native(self.http, operation)

    def add(self, case, *, count=6, hold=(), missing=None, prime_index=False):
        p = self.provider
        attempt = p.allocate(self.base / 'results', p.selection('success'), 'preload-' + case)
        while p.load(attempt / 'observation.json')['writer_active']:
            p.advance(attempt)
        captured = p.load(attempt / 'execution.json')
        captured['status'] = 'running'
        p.save(attempt / 'execution.json.timing-source', captured)
        p.save(attempt / 'detail-preload-fixture.json',
               dict(case=case, count=count, hold=hold, missing=missing))
        self.native('(Register ((attempt %s)(stream_id %s)))' % (sexp(str(attempt)), sexp(attempt.name)))
        run = next(field(r, 'run') for r in field(self.native(), 'runs')
                   if field(field(r, 'reference'), 'attempt') == str(attempt))
        self.runs[case] = run
        self.attempts[case] = attempt
        self.native('(Observe %s)' % sexp(run))
        self.native('(Refresh %s)' % sexp(run))
        summary = wait(lambda: next((s for s in field(self.native(), 'summaries')
                                    if field(s, 'run') == run and dict(s).get('timing_analysis')), None),
                       f'{case} native summary')
        if prime_index:
            target = field(field(summary, 'timing_analysis')[0], 'target')
            self.native('(Inspect_analysis (run %s)(target %s)(refresh false))' % (sexp(run), sexp(target)))
            wait(lambda: self.index(case), f'{case} primed index')

    def select(self, case, workspace='Overview'):
        registry = self.registry()
        w = next(w for w in field(registry, 'workspaces') if field(w, 'name') == workspace)
        context = next(x for x in field(registry, 'contexts') if field(x, 'id') == field(w, 'context'))
        self.http.mutate(registry, '(Select_run (workspace %s)(context %s)(expected_selection_revision %s)(run (%s)))'
                         % (sexp(field(w, 'id')), sexp(field(context, 'id')), field(context, 'selection_revision'),
                            sexp(self.runs[case])))

    def palette_selected(self, title, label):
        self.t.open_palette(title)
        self.t.capture(label, [title + ' (selected)'])
        self.t.key(b'\x1b')

    def events(self, case):
        path = self.base / 'timing-detail-events.jsonl'
        if not path.exists():
            return []
        events = [json.loads(line) for line in path.read_text().splitlines()]
        return [e for e in events if e['case'] == case]

    def starts(self, case):
        return [e['number'] for e in self.events(case) if e['state'] == 'start']

    def argv_calls(self, case):
        attempt = self.attempts[case]
        return [argv for argv in legacy.calls(self.base)
                if argv[:1] == ['inspect'] and Path(argv[1]).parent == attempt]

    def await_event(self, case, number, state):
        def observed():
            self.t.drain(.02)
            return any(e['number'] == number and e['state'] == state for e in self.events(case))
        wait(observed, f'{case}/{number} provider {state}')

    def release(self, case, number):
        (self.base / f'release-{case}-{number}').touch()

    def index(self, case):
        self.t.drain(.02)
        run = self.runs[case]
        return next((i for i in field(self.native(), 'inspections') if field(i, 'run') == run and
                     field(i, 'source_digest') == sha('index/' + case)), None)

    def published(self, case):
        return [d for d in field(self.native(), 'inspection_details') if field(d, 'run') == self.runs[case]
                and field(d, 'source_digest') == sha('index/' + case)]

    def await_details(self, case, numbers):
        ids = {row_id(n) for n in numbers}
        def published():
            self.t.drain(.02)
            return ids <= {field(d, 'row_id') for d in self.published(case) if not field(d, 'error')}
        wait(published, f'{case} published detail IDs {sorted(ids)}')

    @staticmethod
    def body(screen, pane):
        left, top, right, bottom = H.pane_rect(screen, pane)
        return '\n'.join(line[left + 1:right - 1].strip() for line in screen.lines()[top + 1:bottom - 1])

    def assert_selected(self, screen, label, case, number, detail, *, absent=()):
        try:
            paths = self.body(screen, 'timing · paths')
            selected = self.body(screen, 'timing · selected path')
        except (AssertionError, StopIteration, ValueError):
            self.t.save(label + '-missing-pane', screen)
            raise
        self.t.save(label, screen)
        name = row_name(case, number)
        self.check(any(line.startswith('>') and name in line.split() for line in paths.splitlines())
                   and f'Path: {name}' in selected and detail in selected
                   and not any(x in selected for x in absent),
                   f'{label}: rendered highlight and Selected Path match {name}; expected {detail!r}, absent {absent!r}')

    def overview(self):
        self.t.command('Switch to Overview')
        self.t.capture('preload-overview', ['Overview', 'planned-run'])

    def timing(self, case):
        self.t.command('Switch to Timing')
        self.t.capture(f'{case}-timing', [row_name(case, 1)])
        self.t.focus_view('timing paths')


def acceptance(t, check, http, _runs, _presets):
    j = Journey(t, check, http)
    t.resize(180, 55)

    # Never set the count before this test: verify the project default from a
    # clean HOME/XDG, with a genuinely available new analysis index.
    j.add('zero')
    j.select('zero')
    wait(lambda: j.index('zero'), 'default-zero hidden index')
    t.drain(2)
    check(j.starts('zero') == [0] and len(j.argv_calls('zero')) == 1 and not j.published('zero'),
          'Clean default 0 on Overview: exactly one exact index request; no detail requests or publications')
    j.palette_selected('Timing preload: Top 0 path details', 'wb097-default-count')

    t.command('Timing preload: Top 5 path details')
    j.add('warm', hold=(6,))
    j.select('warm')
    t.capture('wb097-overview-before-navigation', ['Overview', 'planned-run'], ['timing · selected path'])
    j.await_details('warm', range(1, 6))
    t.drain(1)
    t.capture('wb097-overview-after-warmup', ['[1 Overview]', 'planned-run'], ['timing · selected path'])
    check([(e['state'], e['number']) for e in j.events('warm')] ==
          [(state, n) for n in range(6) for state in ('start', 'returned')],
          'Overview makes one index request and exactly five serial detail reads in Timing Paths order')
    index = j.index('warm')
    check([field(r, 'id') for r in field(index, 'rows')] != [row_id(n) for n in range(1, 7)]
          and not any(token('warm', n) in sexp(index) for n in range(1, 7)),
          'HTTP index is scrambled and does not contain the detail-only values')

    j.timing('warm')
    start_keys = len(t.keys)
    for n in range(1, 6):
        screen = t.drain(.12) if n == 1 else t.key(b'j')
        j.assert_selected(screen, f'warm-highlight-{n}', 'warm', n, token('warm', n),
                          absent=tuple(token('warm', k) for k in range(1, 7) if k != n))
        if n == 2:
            j.assert_selected(t.key(b'k'), 'warm-highlight-return-to-first', 'warm', 1, token('warm', 1),
                              absent=(token('warm', 2),))
            j.assert_selected(t.key(b'j'), 'warm-highlight-return-to-second', 'warm', 2, token('warm', 2),
                              absent=(token('warm', 1),))
        check(j.starts('warm') == [0, 1, 2, 3, 4, 5],
              f'Warm path {n}: first screen after highlight input, no provider re-read')
    t.drain(1)
    check([k['hex'] for k in t.keys[start_keys:]] == [bytes([c]).hex() for c in b'jkjjjj']
          and j.starts('warm') == [0, 1, 2, 3, 4, 5],
          'No Enter and no additional reads throughout all five warm highlights and intervening polls')

    screen = t.key(b'j')
    j.assert_selected(screen, 'cold-highlight-pending', 'warm', 6, 'waiting for exact selected path detail',
                      absent=(token('warm', 5), token('warm', 6)))
    j.await_event('warm', 6, 'start')
    j.release('warm', 6)
    screen = t.capture('cold-reply', [token('warm', 6)])
    j.assert_selected(screen, 'cold-highlight-ready', 'warm', 6, token('warm', 6), absent=(token('warm', 5),))
    check(j.starts('warm') == [0, 1, 2, 3, 4, 5, 6] and len(j.argv_calls('warm')) == 7,
          'Cold sixth highlight makes exactly one detail request')
    j.overview()

    t.command('Timing preload: Explicit only')
    j.palette_selected('Timing preload: Explicit only', 'wb097-explicit-only-policy')
    j.palette_selected('Timing preload: Top 5 path details', 'wb097-explicit-only-count-unchanged')
    j.add('explicit')
    j.select('explicit')
    t.drain(2)
    check(not j.argv_calls('explicit') and not j.index('explicit') and not j.published('explicit'),
          'Explicit-only on Overview with saved N=5 and a fresh exact summary: zero index and detail reads')
    j.timing('explicit')
    t.drain(1)
    check(j.starts('explicit') == [0] and not j.published('explicit'),
          'Explicit-only still allows the visible Timing index without speculative detail reads')
    t.key(b'\r')
    screen = t.capture('explicit-request-reply', [token('explicit', 1)])
    j.assert_selected(screen, 'explicit-detail-ready', 'explicit', 1, token('explicit', 1))
    t.drain(1)
    check(j.starts('explicit') == [0, 1],
          'Explicit Enter reads exactly the selected path once and no neighbors in explicit-only mode')
    j.overview()
    t.command('Timing preload: Background index')

    j.add('short', count=3, missing=2)
    j.select('short')
    j.await_event('short', 2, 'missing')
    j.await_details('short', (1, 3))
    t.drain(2)
    check(j.starts('short') == [0, 1, 2, 3],
          'N=5 with three paths and missing row 2: attempts all three once, row 3 succeeds, no automatic retry')

    j.add('priority', hold=(1, 6))
    j.select('priority')
    j.await_event('priority', 1, 'start')
    j.timing('priority')
    screen = t.key(b'n')  # Page down directly to path 6, not through the remaining warm-up rows.
    j.assert_selected(screen, 'foreground-while-preload-pending', 'priority', 6,
                      'waiting for exact selected path detail', absent=(token('priority', 1),))
    j.release('priority', 1)
    j.await_event('priority', 6, 'start')
    check(j.starts('priority')[:3] == [0, 1, 6],
          'Foreground path 6 overtakes every unsent speculative detail after held path 1')
    j.release('priority', 6)
    screen = t.capture('foreground-detail-ready', [token('priority', 6)])
    j.assert_selected(screen, 'foreground-detail-exact', 'priority', 6, token('priority', 6),
                      absent=(token('priority', 1),))
    check(j.starts('priority').count(1) == 1 and j.starts('priority').count(6) == 1,
          'Opening Timing and moving off the held path does not duplicate the matching in-flight read')
    j.overview()

    # Prime only the replacement index so it can render even if a shared
    # automatic lane is still occupied by the old detail.
    j.add('new', hold=(1,), prime_index=True)
    j.add('old', hold=(1,))
    j.select('old')
    j.await_event('old', 1, 'start')
    j.timing('old')
    j.assert_selected(t.key(b'\r'), 'old-selected-joins-held-preload', 'old', 1,
                      'waiting for exact selected path detail', absent=(token('old', 1),))
    j.select('new', workspace='Timing')
    screen = t.capture('replacement-index-while-old-provider-held', ['Path: new-path-1'])
    j.assert_selected(screen, 'replacement-highlight-before-old-reply', 'new', 1,
                      'Path: new-path-1', absent=(token('old', 1), token('new', 1)))
    # No result from either run yet. Release old only after the actual Timing
    # table shows the replacement selection with the same path ID.
    check(j.starts('old') == [0, 1] and not j.published('old')
          and all(row_id(1) in [field(r, 'id') for r in field(j.index(case), 'rows')]
                  for case in ('old', 'new')),
          'Run switch occurs while the old exact row-1 provider response is held')
    before_old_reply = len(t.data)
    j.release('old', 1)
    j.await_event('old', 1, 'returned')
    j.await_event('new', 1, 'start')
    screen = t.capture('after-old-provider-return', [row_name('new', 1)], [token('old', 1), token('new', 1)])
    t.drain(1)
    check(f'Path: {row_name("new", 1)}' in j.body(screen, 'timing · selected path')
          and token('old', 1) not in j.body(t.drain(), 'timing · selected path')
          and token('old', 1).encode() not in t.data[before_old_reply:],
          'Late old same-ID response does not render in the replacement Selected Path while the new response is held')
    j.release('new', 1)
    screen = t.capture('after-new-provider-return', [token('new', 1)], [token('old', 1)])
    j.assert_selected(screen, 'replacement-exact-detail', 'new', 1, token('new', 1), absent=(token('old', 1),))
    check(j.starts('old') == [0, 1] and len(j.argv_calls('old')) == 2,
          'Explicit Enter joins the matching held preload; run switch cancels the old batch’s unsent paths')
    j.overview()
    (j.base / 'pre-restart-keys.json').write_text(json.dumps(t.keys, indent=2))
    return 'Overview'


def restart_acceptance(t, check, http, _runs, _presets):
    j = Journey(t, check, http)
    t.capture('wb097-restarted-overview', ['Overview', 'planned-run'])
    j.palette_selected('Timing preload: Top 5 path details', 'wb097-restored-count')
    j.add('restart', count=2)
    j.select('restart')
    j.await_details('restart', (1, 2))
    check(j.starts('restart') == [0, 1, 2],
          'Persisted N=5 reloads after daemon/client restart and warms both paths of a fresh run on Overview')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('daemon', 'client', 'preset-export', 'evidence'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    for name in ('daemon', 'client', 'preset_export'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    if args.evidence.exists() or args.evidence.is_symlink():
        parser.error('use a new private evidence directory')
    args.palette_only = False
    args.harness = 'WB-097 Timing path detail preload'
    C.demo.provider.STAGES = C.demo.provider.STAGES[:-1] + ['timing', 'signoff']
    C.demo.provider.EXECUTABLE_TIMING = True
    prepare = C.demo.prepare

    def prepare_timing(*a, **kw):
        base = prepare(*a, **kw)
        p = C.demo.provider
        settings = base / 'project/synthetic-settings.json'
        p.save(settings, dict(p.load(settings), executable_timing=True))
        for name in ('tmp', 'cache', 'data', 'runtime', 'opam-logs'):
            (base / name).mkdir()
        os.environ.setdefault('OPAMROOT', str(Path.home() / '.opam'))
        os.environ.update(HOME=str(base / 'home'), TMPDIR=str(base / 'tmp'),
                          XDG_CONFIG_HOME=str(base / 'config'), XDG_STATE_HOME=str(base / 'client-state'),
                          XDG_CACHE_HOME=str(base / 'cache'), XDG_DATA_HOME=str(base / 'data'),
                          XDG_RUNTIME_DIR=str(base / 'runtime'), OPAMLOGS=str(base / 'opam-logs'))
        # Resolve the existing toolchain once. Repeated opam wrappers around
        # prebuilt binaries are unnecessary; the project still requests its
        # normal opam environment from the real daemon.
        env = subprocess.run(['opam', 'env', '--switch=' + C.demo.switch_name(), '--sexp'],
                             check=True, capture_output=True, text=True, timeout=15).stdout
        os.environ.update((k, v) for k, v in C.parse(env) if k != 'OPAM_LAST_ENV')
        return base

    C.demo.prepare = prepare_timing
    C.demo.switch_command = lambda argv: list(map(str, argv))
    os.umask(0o077)
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('WB-097 wall-clock budget exhausted')))
    signal.alarm(240)
    try:
        C.run(args, acceptance=acceptance, focused=True, extra_runs=(),
              restart_acceptance=restart_acceptance)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        raise
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fixture-provider':
        fixture_provider(Path(sys.argv[2]), sys.argv[3:])
    else:
        main()
