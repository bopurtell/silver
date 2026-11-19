#!/usr/bin/env python3
"""WB-027 bounded SYNTHETIC baseline, stdlib only; supplied binaries, no builds.

Example (run serially after the parent's build):
  python3 scripts/measure-workbench-performance.py --daemon /path/daemon.exe \
    --client /path/terminal.exe --rows 256,1024 --tiles 1,24 --samples 3
  python3 scripts/measure-workbench-performance.py --self-test

Each matrix cell/sample gets a fresh private project/state, a cold provider index,
an L1 reopen, and a daemon restart/L2 reopen. Both local and injected-delay reads
are measured. Cold means empty Workbench caches, NOT dropped OS page caches.
No Git, builds, owner examples, EDA, physical flows, or real provider are invoked.
Results and all runtime writes remain in a new /tmp/opencode directory. Failed
and censored observations are retained. Budgets are bounds, not acceptance SLOs.
"""

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import traceback
from types import SimpleNamespace
import urllib.request

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wire = load('wb027_wire', REPO / 'demo/synthetic_flow/http_client.py')
fixture = load('wb027_fixture', REPO / 'demo/synthetic_flow/provider.py')
# Importing these modules defines helpers only; their main/prepare paths do not run.
latency = load('wb027_latency', HERE / 'test-inspector-latency.py')
field, sexp, Atom = wire.field, wire.sexp, wire.Atom


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def is_timeout(error):
    return (isinstance(error, TimeoutError) or
            isinstance(getattr(error, 'reason', None), TimeoutError) or
            any(s in str(error).lower() for s in ('timed out', 'timeout', 'budget exhausted')))


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def distribution(values):
    """Nearest-rank percentiles; no interpolation or invented timeout values."""
    ordered = sorted(values)
    n = len(ordered)
    return dict(n=n, min=min(ordered) if n else None,
                median=statistics.median(ordered) if n else None,
                p90=ordered[math.ceil(.90 * n) - 1] if n else None,
                p95=ordered[math.ceil(.95 * n) - 1] if n else None,
                max=max(ordered) if n else None,
                mean=statistics.mean(ordered) if n else None,
                stdev=statistics.stdev(ordered) if n > 1 else None)


def memory(pid):
    """Linux point sample, not a process-tree sum or a sampled peak."""
    start = time.monotonic_ns()
    result = dict(pid=pid, monotonic_ns=start)
    try:
        result['identity'] = latency.cpu(pid)
        status = dict(line.split(':', 1) for line in Path('/proc/%d/status' % pid).read_text().splitlines()
                      if ':' in line)
        result['status_bytes'] = {k: int(status[k].split()[0]) * 1024
                                  for k in ('VmRSS', 'VmHWM', 'VmSize', 'RssAnon', 'RssFile') if k in status}
        try:
            rollup = Path('/proc/%d/smaps_rollup' % pid).read_text().splitlines()
            result['rollup_bytes'] = {k: int(v.split()[0]) * 1024 for k, v in
                                     (line.split(':', 1) for line in rollup if ':' in line)
                                     if k in ('Pss', 'Private_Clean', 'Private_Dirty', 'Swap')}
        except OSError as error:
            result['rollup_unsupported'] = str(error)
    except OSError as error:
        result['unsupported'] = str(error)
    result['probe_ms'] = (time.monotonic_ns() - start) / 1e6
    return result


def disk(root):
    result = dict(files=0, logical_bytes=0, allocated_bytes=0)
    if root.exists():
        for path in root.rglob('*'):
            if path.is_file() and not path.is_symlink():
                st = path.stat()
                result['files'] += 1
                result['logical_bytes'] += st.st_size
                result['allocated_bytes'] += st.st_blocks * 512
    return result


def host_environment(base):
    result = dict(platform=platform.platform(), python=sys.version,
        cpu_count=os.cpu_count(), affinity=sorted(os.sched_getaffinity(0)),
        load_average=os.getloadavg(), kernel=platform.release(),
        clock=dict(name='monotonic_ns', resolution_seconds=time.get_clock_info('monotonic').resolution))
    for name, path, wanted in (
            ('cpu', '/proc/cpuinfo', ('model name', 'Hardware', 'microcode')),
            ('memory', '/proc/meminfo', ('MemTotal', 'MemAvailable', 'SwapTotal'))):
        try:
            values = {}
            for line in Path(path).read_text().splitlines():
                if ':' in line:
                    key, value = line.split(':', 1)
                    if key.strip() in wanted:
                        values.setdefault(key.strip(), value.strip())
            result[name] = values
        except OSError as error:
            result[name] = dict(unsupported=str(error))
    fs = os.statvfs(base)
    result['evidence_filesystem'] = dict(path=str(base), block_size=fs.f_bsize,
        fragment_size=fs.f_frsize, available_bytes=fs.f_bavail * fs.f_frsize,
        interpretation='statvfs capacity; physical device/cache topology not inferred')
    return result


def calls(base):
    path = base / 'provider-calls.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def index_calls(base):
    return [c for c in calls(base) if c['argv'][:1] == ['inspect']]


def make_rows(count, padding):
    return [dict(id='wb027-path-%06d' % n, category='timing_path',
                 producer='SYNTHETIC.wb027', corner='synthetic_slow', group='setup',
                 name='SYNTHETIC endpoint/%06d' % n, value=round(-.1 + n / 10000, 6),
                 unit='ns', status='violated' if n < 1000 else 'available',
                 source=json.dumps(dict(synthetic=True, row=n, padding='x' * padding)),
                 fields=[['startpoint', 'synthetic/start/%06d' % n],
                         ['endpoint', 'synthetic/end/%06d' % n]]) for n in range(count)]


def prepare(base, rows, padding, delay):
    for name in ('project', 'state', 'results', 'home', 'config', 'cache', 'tmp', 'bin', 'client-state'):
        (base / name).mkdir(mode=0o700)
    root = base / 'project'
    (root / 'dune-project').write_text('(lang dune 3.17)\n(name wb027_synthetic)\n')
    # Pure fixture construction; seed/advance manipulate private JSON only.
    reference = fixture.seed(base / 'results')[0]
    execution = Path(reference['attempt']) / 'execution.json'
    evidence = execution.parent / 'inspection-timing-signoff.json'
    save(evidence, dict(synthetic=True, rows=make_rows(rows, padding), details={}))
    save(base / 'control.json', dict(delay=delay))
    policy = dict(execution=str(execution), reference=reference,
                  evidence=str(evidence), provider_source=str(REPO / 'demo/synthetic_flow/provider.py'))
    save(base / 'policy.json', policy)
    provider = base / 'read-only-synthetic-provider'
    provider.write_text('#!' + sys.executable + '\nimport runpy, sys\n' +
                        'sys.argv = [' + repr(str(Path(__file__).resolve())) +
                        ', "--fixture-provider", ' + repr(str(base)) + '] + sys.argv[1:]\n' +
                        'runpy.run_path(' + repr(str(Path(__file__).resolve())) + ', run_name="__main__")\n')
    provider.chmod(0o700)
    deny = base / 'bin' / 'deny'
    deny.write_text('#!' + sys.executable + '\nimport sys\nsys.exit("WB027 forbids project/tool execution")\n')
    deny.chmod(0o700)
    # Project metadata probes may need real Dune, but no action is permitted.
    # Avoid a dependency on Dune by supplying only its metadata protocol.
    dune = base / 'bin' / 'dune'
    dune.write_text('#!' + sys.executable + '\nimport sys\na=sys.argv[1:]\n' +
                    'if a == ["--version"]: print("3.22.0")\n' +
                    'elif a == ["describe", "workspace", "--root", ' + repr(str(root)) +
                    ', "--format=sexp", "--lang=0.1"]: print(' +
                    repr(sexp([['root', str(root)], ['build_context', '_build/default']])) + ')\n' +
                    'else: sys.exit("WB027 forbids Dune actions: " + repr(a))\n')
    dune.chmod(0o700)
    for name in ('git', 'nix', 'nix-shell', 'make', 'openroad', 'yosys', 'opam'):
        (base / 'bin' / name).symlink_to('deny')
    cfg = [['schema_version', '1'], ['project_executable', str(deny)],
           ['provider_executable', str(provider)], ['results_root', str(base / 'results')],
           ['toolchain', str(root)], ['python', []], ['support_tools', []],
           ['pdk_root', []], ['stage_timeout_seconds', []]]
    (root / 'hardcaml-workbench-asic.sexp').write_text(sexp(cfg) + '\n')
    save(base / 'fixture-identity.json', dict(synthetic=True, reference=reference,
         execution=dict(path=str(execution), sha256=sha(execution)),
         evidence=dict(path=str(evidence), sha256=sha(evidence), bytes=evidence.stat().st_size),
         rows=rows, row_padding_bytes=padding, injected_read_delay_seconds=delay))
    return root, reference


def fixture_provider(base, argv):
    """No forwarding CLI: only explicitly allowed read-only operations exist."""
    policy = json.loads((base / 'policy.json').read_text())
    ref, execution = policy['reference'], policy['execution']
    ok = (argv == ['--version', '--json'] or argv == ['report', execution, '--json'] or
          argv == ['observation', 'inspect', ref['attempt'], '--json'] or
          (len(argv) == 8 and argv[:3] == ['observation', 'read-updates', ref['attempt']] and
           argv[3:6] == ['--stream-id', ref['stream_id'], '--after'] and
           argv[6].isdigit() and argv[7:] == ['--json']) or
          argv == ['inspect', execution, '--domain', 'timing', '--stage', 'signoff', '--json'])
    started = time.monotonic_ns()
    with (base / 'provider-calls.jsonl').open('a') as out:
        out.write(json.dumps(dict(argv=argv, allowed=ok, pid=os.getpid(), started_ns=started,
                                  identity=latency.cpu(os.getpid()))) + '\n')
    require(ok, 'Non-allowlisted synthetic provider command: ' + repr(argv))
    if argv == ['--version', '--json']:
        result = dict(cli_contract=dict(version=4, capabilities=dict(namedflow1=True)), synthetic=True)
    elif argv[0] == 'inspect':
        delay = json.loads((base / 'control.json').read_text())['delay']
        # Deliberate provider-side read stall, NOT a real filesystem latency claim.
        time.sleep(delay)
        result = fixture.inspect(execution, 'timing', 'signoff')
    elif argv[0] == 'report':
        result = fixture.report(execution)
    elif argv[1] == 'inspect':
        result = fixture.load(Path(ref['attempt']) / 'observation.json')
    else:
        state = fixture.load(Path(ref['attempt']) / 'observation.json')
        after = int(argv[6])
        require(0 <= after <= state['cursor'], 'Invalid observation cursor')
        result = fixture.envelope('stage-observation', 2, stream_id=ref['stream_id'],
                                 after=after, cursor=state['cursor'],
                                 events=[e for e in state['events'] if e['sequence'] > after])
    raw = json.dumps(result).encode()
    with (base / 'provider-completions.jsonl').open('a') as out:
        out.write(json.dumps(dict(argv=argv, started_ns=started, completed_ns=time.monotonic_ns(),
                                  bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())) + '\n')
    sys.stdout.buffer.write(raw + b'\n')


class HTTP(wire.Client):
    def __init__(self, session):
        self.session = session
        super().__init__(session.url, session.root)

    def raw(self, path, data=None):
        start = time.monotonic_ns()
        request = urllib.request.Request(self.url + path,
            data=None if data is None else sexp(data).encode(),
            headers={'Content-Type': 'application/sexp', 'X-Workbench-Protocol': '1'})
        event = dict(path=path, request=data, started_ns=start)
        try:
            remaining = min(self.session.args.timeout, self.session.deadline - time.monotonic())
            if remaining <= 0:
                raise TimeoutError('HTTP request budget exhausted before dispatch')
            with urllib.request.urlopen(request, timeout=remaining) as response:
                raw = response.read()
            event.update(received_ns=time.monotonic_ns(), bytes=len(raw),
                         response_sha256=hashlib.sha256(raw).hexdigest())
            result = wire.parse(raw.decode())
            event.update(parsed_ns=time.monotonic_ns(), failed=False, timed_out=False)
        except BaseException as error:
            event.update(failed=True, timed_out=is_timeout(error), error=repr(error))
            raise
        finally:
            event['finished_ns'] = time.monotonic_ns()
            event['elapsed_ms'] = (event['finished_ns'] - start) / 1e6
            with (self.session.evidence / 'http.jsonl').open('a') as out:
                out.write(json.dumps(event) + '\n')
        if path == '/api/hello':
            return result
        require(result[0] == 'Ok', 'HTTP RPC error: ' + repr(result))
        return result[1]

    def rpc(self, operation='Get', domain='asic', wait=False):
        # Waiting is explicit and scoped by the caller; old cancelled operations
        # must not turn every later query into a false failure.
        return super().rpc(operation, domain, wait=wait)


class Session:
    def __init__(self, args, base, root):
        self.args, self.evidence, self.root = args, base, root
        self.deadline = args.deadline
        self.process = self.log = None
        self.owned_processes = []
        self.env = dict(os.environ, HOME=str(base / 'home'), XDG_CONFIG_HOME=str(base / 'config'),
                        XDG_CACHE_HOME=str(base / 'cache'), XDG_STATE_HOME=str(base / 'client-state'),
                        TMPDIR=str(base / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
                        PATH=str(base / 'bin') + os.pathsep + os.environ.get('PATH', ''))

    def start(self):
        discovery = self.evidence / ('discovery-' + str(time.time_ns()))
        discovery.mkdir()
        self.log = (discovery / 'daemon.log').open('wb')
        argv = [str(self.args.daemon), '--port', '0', '--discovery-dir', str(discovery),
                '--state-dir', str(self.evidence / 'state')]
        self.process = subprocess.Popen(argv, cwd=self.root, env=self.env, stdout=self.log,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        self.owned_processes.append(dict(kind='daemon', pid=self.process.pid,
                                        identity=latency.cpu(self.process.pid)))
        deadline = min(self.deadline, time.monotonic() + self.args.timeout)
        path = discovery / 'daemon.sexp'
        while not path.exists():
            require(self.process.poll() is None, 'Daemon exited: ' + str(discovery))
            require(time.monotonic() < deadline, 'Daemon discovery timed out')
            time.sleep(.01)
        self.metadata = dict(wire.parse(path.read_text()))
        self.url = self.metadata['endpoint']
        self.http = HTTP(self)

    def stop(self):
        if self.process:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=3)
        if self.log:
            self.log.close()


def until(session, predicate, label):
    deadline = min(session.deadline, time.monotonic() + session.args.timeout)
    while True:
        snap = session.http.rpc()
        found = predicate(snap)
        if found:
            return found
        if time.monotonic() >= deadline:
            raise TimeoutError(label + ' timed out; inspect http/provider logs')
        time.sleep(session.args.poll)


def settled(session):
    snap = until(session, lambda s: s if not any(field(o, 'state') in ('pending', 'executing')
                 for o in field(s, 'operations')) else None, 'operation settlement')
    require(not any(field(o, 'state') == 'failed' for o in field(snap, 'operations')),
            'Provider operation failed: ' + sexp(field(snap, 'operations')))
    return snap


def checkpoint(session, result, label, terminal=None):
    result['resources'].append(dict(label=label, daemon=memory(session.process.pid),
        client=memory(terminal.app_pid) if terminal else None,
        retained_state=disk(session.evidence / 'state'),
        retained_fixture=disk(session.evidence / 'results'),
        instrumentation=disk(session.evidence)))


def measured(result, metric, action):
    started = time.monotonic_ns()
    try:
        value = action()
    except BaseException as error:
        result['measurements'].append(dict(metric=metric,
            elapsed_ms=(time.monotonic_ns() - started) / 1e6, failed=True,
            timed_out=is_timeout(error),
            error=str(error)))
        raise
    result['measurements'].append(dict(metric=metric, elapsed_ms=(time.monotonic_ns() - started) / 1e6,
                                       timed_out=False))
    return value


PALETTE_HEADING = 'COMMAND PALETTE · captured target'


def workspace_visible(text):
    # Built-ins list inactive tabs on the first line; custom workspaces instead
    # render an authoritative "<name> | run ..." header. Neither accepts WB027
    # merely appearing as an inactive tab on Overview.
    header = text.splitlines()[0]
    selected = bool(re.search(r'\[\d+ WB027\]', header)) or header.startswith('WB027 | run ')
    return selected and PALETTE_HEADING not in text


class Terminal(latency.Terminal):
    """Harness-local adapter for the committed host; shared code supplies PTY/VT."""
    def __init__(self, session):
        super().__init__(session)
        session.owned_processes.append(dict(kind='client', pid=self.app_pid,
                                            identity=self.app_identity))

    def wait(self, predicate, label, timeout=15):
        deadline = min(self.session.deadline, time.monotonic() + timeout)
        while True:
            text = self.pump()
            if predicate(text):
                self.snapshot(label)
                return text
            if time.monotonic() >= deadline:
                self.snapshot(label + '-timeout')
                save(self.session.evidence / (label + '-timeout.json'), dict(
                    timed_out=True, monotonic_ns=time.monotonic_ns(), pty_offset=self.offset,
                    client_pid=self.app_pid, daemon_pid=self.session.process.pid))
                raise TimeoutError(label + ': PTY screen timed out\n' + text)

    def palette(self, title=None):
        self.ready()
        for key in (b' ', b'c', b'c'):
            self.key(key)
            self.idle(.2)
        self.wait(lambda s: PALETTE_HEADING in s, 'palette-open')
        if title:
            self.key(title.encode())
            # Match the selected result, not the user's query echoed in the
            # prompt. This exact command title comes from workspace_host.ml.
            self.wait(lambda s: PALETTE_HEADING in s and
                      bool(re.search(r'> ' + re.escape(title) + r' +[│|]', s)),
                      'palette-filtered')
            self.key(b'\r')


def cleanup_audit(session):
    records = list(session.owned_processes)
    records.extend(dict(kind='provider', pid=c['pid'], identity=c.get('identity'))
                   for c in calls(session.evidence))
    for entry in records:
        current = latency.cpu(entry['pid'])
        original = entry['identity']
        same = bool(current and original and current['start_ticks'] == original['start_ticks'])
        entry['after_cleanup'] = current
        entry['same_process_live'] = same and current['state'] not in ('Z', 'X')
    return dict(processes=records, all_owned_processes_stopped=not any(e['same_process_live'] for e in records))


def pty_probe(terminal, result, prefix):
    """Measure actual raw/noecho input, with no fixed post-key drain in the timer."""
    terminal.palette()
    terminal.ready()
    query = 'WB027_NO_MATCH'
    require(query not in terminal.screen.text(), 'PTY target already visible')
    started, sent = terminal.key(query.encode())
    deadline = min(terminal.session.deadline, started / 1e9 + terminal.args.timeout)
    observed = None
    while time.monotonic() < deadline:
        text = terminal.pump()
        if query in text and PALETTE_HEADING in text:
            observed = time.monotonic_ns()
            break
    result['measurements'].append(dict(metric=prefix + '.input_to_visible', timed_out=False,
        elapsed_ms=((observed or time.monotonic_ns()) - started) / 1e6, write_ms=(sent - started) / 1e6,
        observed_offset=terminal.offset))
    result['measurements'][-1]['timed_out'] = observed is None
    terminal.snapshot(prefix + '-query-visible')
    require(observed is not None, 'PTY query input timed out')
    started, sent = terminal.key(b'\x1b')
    deadline = min(terminal.session.deadline, started / 1e9 + terminal.args.pty_timeout)
    observed = None
    while time.monotonic() < deadline:
        text = terminal.pump()
        if workspace_visible(text):
            observed = time.monotonic_ns()
            break
    result['measurements'].append(dict(metric=prefix + '.escape_to_workspace',
        timed_out=observed is None, elapsed_ms=((observed or time.monotonic_ns()) - started) / 1e6,
        write_ms=(sent - started) / 1e6, observed_offset=terminal.offset))
    terminal.snapshot(prefix + '-escape')
    if observed is None:
        # Recovery is outside, and never substituted for, the censored sample.
        terminal.key(b'\x00')
        terminal.wait(workspace_visible, prefix + '-recovered', timeout=5)


def trial(args, base, row_count, tile_count, delay, result):
    session = terminal = None
    try:
        root, reference = prepare(base, row_count, args.row_padding, delay)
        session = Session(args, base, root)
        measured(result, 'daemon.cold_start_and_open', session.start)
        h = session.http
        checkpoint(session, result, 'opened_empty')
        ref = [[k, reference[k]] for k in ('attempt', 'stream_id')]
        h.rpc('(Register %s)' % sexp(ref))
        registered = until(session, lambda s: field(s, 'runs'), 'registration')
        settled(session)
        require(len(registered) == 1, 'Expected one registered synthetic run')
        run = field(registered[0], 'run')
        result['run'] = run

        def summary_load():
            session.http.rpc('(Load_summary %s)' % sexp(run))
            settled(session)
            return until(session, lambda s: next((v for v in field(s, 'summaries')
                         if field(v, 'run') == run), None), 'summary loading')

        # Registration can eagerly populate a summary in some binary revisions.
        # Preserve that fact rather than labeling a preloaded summary cold.
        result['summary_preloaded_at_registration'] = bool(field(h.rpc(), 'summaries'))
        original_summary = measured(result, 'summary.first_explicit_load', summary_load)
        report_calls = len([c for c in calls(base) if c['argv'][:1] == ['report']])
        warm_summary = measured(result, 'summary.warm_load', summary_load)
        require(warm_summary == original_summary, 'Warm summary changed')
        require(len([c for c in calls(base) if c['argv'][:1] == ['report']]) == report_calls,
                'Warm summary launched provider')

        def inspect(refresh=False):
            return '(Inspect (run %s) (domain timing) (stage signoff) (refresh %s))' % (
                sexp(run), 'true' if refresh else 'false')

        def get_index():
            session.http.rpc(inspect())
            settled(session)
            return until(session, lambda s: next((i for i in field(s, 'inspections')
                if field(i, 'run') == run and field(i, 'domain') == 'timing' and
                field(i, 'stage') == 'signoff'), None), 'index loading')

        require(not index_calls(base), 'Cold inspection unexpectedly preloaded')
        index = measured(result, 'index.cold_load', get_index)
        require(len(field(index, 'rows')) == row_count, 'Wrong evidence row count')
        require(field(index, 'cached_unverified') == 'false', 'Cold index not provider validated')
        require(len(index_calls(base)) == 1, 'Cold index did not make exactly one provider read')
        require(field(index, 'source_digest') == sha(Path(reference['attempt']) / 'inspection-timing-signoff.json'),
                'Cold source digest does not identify exact synthetic evidence bytes')
        warm = measured(result, 'index.warm_load', get_index)
        require(warm == index and len(index_calls(base)) == 1, 'L1 cache mismatch/provider read')
        result['cache_assertions'].append('cold exact digest/row count, single provider read; warm identical with zero reads')
        checkpoint(session, result, 'cold_and_warm_loaded')

        ws = h.rpc(domain='workspace')
        ws = h.mutate(ws, '(Create_workspace (window %s) (name WB027) (context %s))' %
                      (sexp(field(field(ws, 'windows')[0], 'id')), sexp(field(ws, 'main_context'))))
        workspace = field(ws, 'workspaces')[-1]
        for n in range(tile_count):
            ws = h.mutate(ws, '(Create_tile (workspace %s) (kind timing) (geometry ((x %d)(y %d)(width 56)(height 14))))' %
                          (sexp(field(workspace, 'id')), (n % 3) * 57, (n // 3) * 15))
        context = next(c for c in field(ws, 'contexts') if field(c, 'id') == field(workspace, 'context'))
        ws = h.mutate(ws, '(Select_run (workspace %s)(context %s)(expected_selection_revision %s)(run (%s)))' %
            (sexp(field(workspace, 'id')), sexp(field(context, 'id')), field(context, 'selection_revision'), sexp(run)))
        result['workspace_tiles'] = sum(field(t, 'workspace') == field(workspace, 'id')
                                        for t in field(ws, 'tiles'))
        require(result['workspace_tiles'] == tile_count, 'Tile workload did not materialize exactly')
        result['total_tiles'] = len(field(ws, 'tiles'))
        saved_ws = ws
        checkpoint(session, result, 'tiles_created')
        old_instance = session.metadata['instance_id']
        session.stop()
        measured(result, 'daemon.restart_and_open', session.start)
        require(session.metadata['instance_id'] != old_instance, 'Daemon instance did not change')
        require(session.http.rpc(domain='workspace') == saved_ws, 'Restart changed saved workspace')
        before = len(calls(base))
        restored_summary = measured(result, 'summary.restart_l2_load', summary_load)
        require(field(restored_summary, 'freshness') == 'Cached_unverified', 'Summary L2 freshness incorrect')
        require([(k, v) for k, v in restored_summary if k != 'freshness'] ==
                [(k, v) for k, v in original_summary if k != 'freshness'], 'L2 summary payload changed')
        restored = measured(result, 'index.restart_l2_load', get_index)
        require(field(restored, 'cached_unverified') == 'true', 'L2 not cached-unverified')
        require([(k, v) for k, v in restored if k != 'cached_unverified'] ==
                [(k, v) for k, v in index if k != 'cached_unverified'], 'L2 index payload changed')
        require(len(calls(base)) == before, 'L2 reopen invoked provider')
        result['cache_assertions'].append('new daemon identity; identical workspace and L2 payloads, unverified freshness, zero provider calls')
        checkpoint(session, result, 'restart_l2_loaded')

        terminal = Terminal(session)
        terminal.wait(lambda s: 'Space c c commands' in s, 'startup', timeout=args.timeout)
        terminal.palette('Switch to WB027')
        selected = terminal.wait(lambda s: workspace_visible(s) and 'WB027 › timing' in s,
                                 'private-workspace', timeout=args.timeout)
        result['selected_workspace'] = dict(id=field(workspace, 'id'), name='WB027',
                                            active_header_line=selected.splitlines()[0],
                                            focused_tile_breadcrumb='WB027 › timing')
        pty_probe(terminal, result, 'pty.idle')
        checkpoint(session, result, 'client_tiles_rendered', terminal)
        # Keep one deliberately blocked read pending for query/cancel transport
        # measurements. This case is distinct from the local/slow cold timings.
        hold = max(15.0, args.slow_delay)
        save(base / 'control.json', dict(delay=hold))
        prior = {field(o, 'key') for o in field(session.http.rpc(), 'operations')}
        dispatched = measured(result, 'query.slow_read_dispatch_ack', lambda: session.http.rpc(inspect(True)))
        active = next((o for o in field(dispatched, 'operations')
                       if field(o, 'state') in ('pending', 'executing') and
                       ('inspect' in field(o, 'key'))), None)
        require(active is not None, 'Refresh did not expose pending inspection operation')
        result['cancel_target'] = dict(key=field(active, 'key'), previously_present=field(active, 'key') in prior,
                                       injected_hold_seconds=hold)
        deadline = min(args.deadline, time.monotonic() + args.timeout)
        while len(index_calls(base)) < 2:
            require(time.monotonic() < deadline, 'Slow provider never entered')
            terminal.pump()
        pending = session.http.rpc()
        require(any(field(o, 'key') == field(active, 'key') and field(o, 'state') in ('pending', 'executing')
                    for o in field(pending, 'operations')), 'Slow read completed before responsiveness probes')
        measured(result, 'query.get_during_slow_read', lambda: session.http.rpc())
        # Query input takes no intentional sleep after key dispatch; ESC may be
        # censored independently if the host decoder buffers standalone Escape.
        pty_probe(terminal, result, 'pty.during_synthetic_read_stall')
        still_active = session.http.rpc()
        require(any(field(o, 'key') == field(active, 'key') and field(o, 'state') in ('pending', 'executing')
                    for o in field(still_active, 'operations')), 'Read no longer pending at Cancel; raise --slow-delay')
        key = field(active, 'key')
        cancel_started = time.monotonic_ns()
        measured(result, 'cancel.transport_ack', lambda: session.http.rpc('(Cancel %s)' % sexp(key)))
        ended = until(session, lambda s: next((o for o in field(s, 'operations') if field(o, 'key') == key and
                      field(o, 'state') not in ('pending', 'executing')), None), 'cancel completion')
        result['measurements'].append(dict(metric='cancel.to_terminal_state', timed_out=False,
            elapsed_ms=(time.monotonic_ns() - cancel_started) / 1e6))
        require(field(ended, 'state') == 'failed', 'Cancelled read unexpectedly succeeded')
        require('cancel' in sexp(field(ended, 'error')).lower(), 'Read failed for a reason other than cancellation')
        result['cancel_outcome'] = ended
        checkpoint(session, result, 'cancelled', terminal)
        result['provider_calls'] = calls(base)
        require(all(c['allowed'] for c in result['provider_calls']), 'Disallowed provider command attempted')
        result['status'] = 'completed-with-timeouts' if any(m['timed_out'] for m in result['measurements']) else 'passed'
    except BaseException:
        result.update(status='failed', error=traceback.format_exc())
        raise
    finally:
        primary_failed = result['status'] == 'failed'
        cleanup_errors = []
        try:
            if terminal:
                terminal.close()
        except BaseException:
            cleanup_errors.append(traceback.format_exc())
        finally:
            try:
                if session:
                    session.stop()
            except BaseException:
                cleanup_errors.append(traceback.format_exc())
            result['cleanup'] = cleanup_audit(session) if session else {}
            result['cleanup']['errors'] = cleanup_errors
            cleanup_failed = bool(cleanup_errors) or result['cleanup'].get('all_owned_processes_stopped') is False
            if cleanup_failed:
                result['status'] = 'failed'
            result['retained_disk_after_shutdown'] = dict(state=disk(base / 'state'),
                fixture=disk(base / 'results'), all_evidence=disk(base))
            save(base / 'result.json', result)
            if cleanup_failed and not primary_failed:
                raise RuntimeError('Workload cleanup failed; see trial result.json')


def self_test():
    latency.screen_self_check()
    require(distribution([])['n'] == 0 and distribution([9])['stdev'] is None, 'Empty/single distribution')
    d = distribution(list(range(1, 21)))
    require(d['median'] == 10.5 and d['p90'] == 18 and d['p95'] == 19, 'Nearest rank percentiles')
    rows = make_rows(1024, 64)
    require(len({r['id'] for r in rows}) == 1024 and all(len(json.loads(r['source'])['padding']) == 64 for r in rows),
            'Representative rows must have unique IDs and exact padding')
    require(wire.parse(sexp([['payload', 'µ\x00\\123']])) == [['payload', 'µ\x00\\123']], 'Wire round trip')
    require(not workspace_visible(' [1 Overview]  2 WB027\nOverview › run selector') and
            workspace_visible('WB027 | run asic/test | linked\nWB027 › timing') and
            not workspace_visible('WB027 | run asic/test\n' + PALETTE_HEADING),
            'PTY workload selection distinguishes active header from inactive tab/palette')
    # Pure Python fixture/allowlist contract check: private temporary files only;
    # no daemon, PTY, child processes, builds, Git, or physical tools.
    with tempfile.TemporaryDirectory(prefix='wb027-self-test-', dir='/tmp/opencode') as directory:
        base = Path(directory)
        require(host_environment(base)['evidence_filesystem']['block_size'] > 0,
                'Environment filesystem attribution')
        client = HTTP.__new__(HTTP)
        client.url = 'http://127.0.0.1:1'
        client.session = SimpleNamespace(evidence=base, args=SimpleNamespace(timeout=1),
                                         deadline=time.monotonic() + 5)
        original_urlopen = urllib.request.urlopen

        def deliberate_timeout(*_args, **_kwargs):
            raise TimeoutError('deliberate pure self-test transport timeout')

        timed = dict(measurements=[])
        urllib.request.urlopen = deliberate_timeout
        try:
            try:
                measured(timed, 'test.raw_timeout', lambda: client.raw('/api/hello'))
            except TimeoutError:
                pass
            else:
                raise AssertionError('Raw transport timeout was swallowed')
        finally:
            urllib.request.urlopen = original_urlopen
        event = json.loads((base / 'http.jsonl').read_text())
        require(event['timed_out'] and event['failed'] and event['elapsed_ms'] >= 0 and
                timed['measurements'][0]['timed_out'] and timed['measurements'][0]['failed'],
                'Raw timeouts persist in both transport log and excluded/censored measurements')
        _, ref = prepare(base, 128, 32, 0)
        execution = str(Path(ref['attempt']) / 'execution.json')
        evidence = Path(ref['attempt']) / 'inspection-timing-signoff.json'
        original_hash = sha(evidence)

        class Sink:
            def __init__(self):
                self.buffer = io.BytesIO()

        def query(argv):
            sink = Sink()
            with contextlib.redirect_stdout(sink):
                fixture_provider(base, argv)
            return json.loads(sink.buffer.getvalue())

        require(query(['--version', '--json'])['cli_contract']['version'] == 4, 'Provider version contract')
        observed = query(['observation', 'inspect', ref['attempt'], '--json'])
        require(observed['stream_id'] == ref['stream_id'] and not observed['writer_active'], 'Seed is final')
        updates = query(['observation', 'read-updates', ref['attempt'], '--stream-id', ref['stream_id'],
                         '--after', '0', '--json'])
        require(updates['cursor'] == observed['cursor'] and updates['events'], 'Retained update cursor')
        report = query(['report', execution, '--json'])
        require(report['contract'] == 'hardcaml-asic.report', 'Retained report contract')
        index = query(['inspect', execution, '--domain', 'timing', '--stage', 'signoff', '--json'])
        require(len(index['rows']) == 128 and index['source_digest'] == original_hash,
                'Provider returns exact private row count/source digest')
        try:
            fixture_provider(base, ['flow', 'run'])
        except AssertionError:
            pass
        else:
            raise AssertionError('Provider allowlist admitted a producer command')
        require(sha(evidence) == original_hash and calls(base)[-1]['allowed'] is False,
                'Read-only fixture and denied producer audit')
    print('PASS: WB027 pure self-tests (distributions, rows, protocol, ANSI, retained fixture, provider allowlist)')


def sizes(text):
    values = [int(v) for v in text.split(',')]
    require(values and len(values) == len(set(values)), 'Sizes must be unique comma-separated integers')
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--daemon', type=Path)
    parser.add_argument('--client', type=Path)
    parser.add_argument('--rows', type=sizes, default=[1024])
    parser.add_argument('--tiles', type=sizes, default=[24])
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument('--row-padding', type=int, default=256)
    parser.add_argument('--slow-delay', type=float, default=10.0,
                        help='Injected pre-read sleep seconds; synthetic stall, not physical storage')
    parser.add_argument('--storage', choices=('both', 'local', 'synthetic-slow'), default='both')
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--pty-timeout', type=float, default=2)
    parser.add_argument('--poll', type=float, default=.02)
    parser.add_argument('--budget', type=int, default=600)
    parser.add_argument('--width', type=int, default=200)
    parser.add_argument('--height', type=int, default=60)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    require(args.daemon and args.client, '--daemon and --client supplied binaries required')
    for key in ('daemon', 'client'):
        path = getattr(args, key).resolve(strict=True)
        require(path.is_file() and os.access(path, os.X_OK), 'Executable required: ' + str(path))
        setattr(args, key, path)
    require(1 <= args.samples <= 20 and all(1 <= n <= 50000 for n in args.rows) and
            all(1 <= n <= 200 for n in args.tiles), 'Samples 1..20, rows 1..50000, tiles 1..200')
    require(0 <= args.row_padding <= 4096 and max(args.rows) * (args.row_padding + 1024) <= 128 * 1024 * 1024,
            'Padding 0..4096; estimated evidence per trial <=128 MiB')
    require(len(json.dumps(make_rows(max(args.rows), args.row_padding)).encode()) <= 1500 * 1024,
            'Rows/padding exceed the conservative 1500 KiB row budget for the production 2 MiB inspection cap')
    require(1 <= args.slow_delay <= 20 and 5 <= args.timeout <= 90 and .1 <= args.pty_timeout <= 5 and
            .005 <= args.poll <= .25 and 30 <= args.budget <= 1800, 'Invalid timing bounds')
    require(120 <= args.width <= 400 and 40 <= args.height <= 120, 'PTY dimensions out of bounds')
    conditions = [('local', 0), ('synthetic-slow', args.slow_delay)]
    if args.storage != 'both':
        conditions = [c for c in conditions if c[0] == args.storage]
    require(len(args.rows) * len(args.tiles) * args.samples * len(conditions) <= 40, 'At most 40 isolated trials')
    args.tmux_escape_time = None  # Shared Terminal: direct PTY transport only.
    os.umask(0o077)
    base = Path(tempfile.mkdtemp(prefix='workbench-performance-', dir='/tmp/opencode'))
    args.deadline = time.monotonic() + args.budget
    report = dict(status='failed', synthetic=True, ticket='WB-027', trials=[],
        options={k: str(v) for k, v in vars(args).items()}, argv=sys.argv,
        environment=host_environment(base),
        identities={str(p): sha(p) for p in (args.client, args.daemon, Path(__file__).resolve(),
            REPO / 'demo/synthetic_flow/provider.py', REPO / 'demo/synthetic_flow/scenarios.json',
            HERE / 'test-inspector-latency.py', HERE / 'test-fs1-investigation.py',
            HERE / 'test-fs1-lifecycle.py', HERE / 'test-fs1-terminal-results.py',
            HERE / 'test-fs1-metrics.py', HERE / 'test-fs0-dashboard.py', HERE / 'test-fs0.py',
            REPO / 'demo/synthetic_flow/http_client.py')},
        method=dict(distributions='nearest-rank p90/p95; successful samples only; timeouts separate',
            loading='HTTP dispatch through observed publication; includes polling, transfer, parse and log overhead',
            query='HTTP POST transport round trip including response decoding; no CLI launch cost',
            input='direct real client PTY raw/noecho palette query and standalone ESC; host-visible upper bound',
            memory='Linux /proc point samples, process identities, RSS/HWM/PSS where accessible',
            disk='logical/allocated regular-file bytes; state separate from fixture and instrumentation',
            isolation='fresh project/state per sample; same fixture shape; no OS page-cache eviction',
            slow='controlled provider sleep immediately before real private JSON read; no physical slow device',
            metadata='private synthetic Dune version/workspace metadata, no real Dune build/action'),
        unsupported=['OCaml allocation/GC counts (no instrumented binary)',
            'physical display/compositor latency', 'physical slow-storage or remote-host behavior',
            'OS-cold storage, peak process-tree memory, device I/O latency',
            'confidence intervals/SLO acceptance from these small samples',
            'inspector row filtering/detail latency (PTY measures workspace palette input)',
            'inspection payloads beyond production 2 MiB cap (conservative 1500 KiB row budget enforced)',
            'DUT timing/area/power performance and real physical-flow execution'])
    save(base / 'invocation.json', report)
    print('Evidence: ' + str(base), flush=True)

    def interrupted(sig, _frame):
        raise KeyboardInterrupt('WB027 interrupted/budget exhausted: %s' % sig)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGALRM):
        signal.signal(sig, interrupted)
    signal.alarm(args.budget)
    try:
        # Instrument-only calibration is recorded, never subtracted from timings.
        clock_cost, resource_cost = [], []
        for _ in range(100):
            start = time.monotonic_ns()
            time.monotonic_ns()
            clock_cost.append((time.monotonic_ns() - start) / 1e6)
        for _ in range(10):
            resource_cost.append(memory(os.getpid())['probe_ms'])
        report['overhead'] = dict(clock_pair_ms=distribution(clock_cost),
            proc_probe_ms=distribution(resource_cost), polling_interval_ms=args.poll * 1000,
            pty_select_max_ms=10, timing_correction='none',
            uncalibrated='HTTP/JSON/S-expression parsing, ANSI reconstruction, file logging, fixture Python startup; all included. No uninstrumented paired run.')
        for rows in args.rows:
            for tiles in args.tiles:
                for condition, delay in conditions:
                    for sample in range(args.samples):
                        name = 'rows-%d-tiles-%d-%s-%02d' % (rows, tiles, condition, sample)
                        private = base / name
                        private.mkdir(mode=0o700)
                        result = dict(name=name, rows=rows, tiles=tiles, condition=condition,
                            sample=sample, measurements=[], resources=[], cache_assertions=[], status='failed')
                        report['trials'].append(result)
                        trial(args, private, rows, tiles, delay, result)
                        save(base / 'result.json', report)
        report['status'] = ('completed-with-timeouts' if any(t['status'] == 'completed-with-timeouts'
                            for t in report['trials']) else 'passed')
    except BaseException:
        report.update(status='failed', error=traceback.format_exc())
        raise
    finally:
        signal.alarm(0)
        groups = {}
        for t in report['trials']:
            for m in t['measurements']:
                key = 'rows=%s tiles=%s storage=%s %s' % (t['rows'], t['tiles'], t['condition'], m['metric'])
                groups.setdefault(key, []).append(m)
        report['distributions_ms'] = {key: dict(observations=len(values),
            timeouts=sum(v['timed_out'] for v in values),
            failures=sum(v.get('failed', False) for v in values),
            successful=distribution([v['elapsed_ms'] for v in values if not v['timed_out'] and not v.get('failed')]),
            censored_lower_bounds_ms=[v['elapsed_ms'] for v in values if v['timed_out']])
            for key, values in groups.items()}
        report['retained_disk'] = disk(base)
        save(base / 'result.json', report)
    print(report['status'] + ': ' + str(base / 'result.json'), flush=True)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fixture-provider':
        fixture_provider(Path(sys.argv[2]), sys.argv[3:])
    else:
        main()
