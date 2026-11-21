"""Independent stock Testing expectations for the native PTY probes."""
import json
import re
import time


STOCK_KINDS = (
    'workspace-tabs', 'live-status', 'execution', 'simulation-catalog',
    'simulation-attempts', 'simulation-cases', 'simulation-detail',
    'simulation-artifacts', 'simulation-logs',
)
FIT_FOCUS_ORDER = (
    'workspace-tabs', 'live-status', 'simulation-attempts', 'execution',
    'simulation-catalog', 'simulation-detail', 'simulation-cases',
    'simulation-artifacts', 'simulation-logs',
)
PANE_TITLES = ('session', *STOCK_KINDS[2:])
_HEADER = re.compile(r'[╭┌+] (?P<title>' + '|'.join(PANE_TITLES) + r')(?= |[─-])')
_RIGHT_CORNER = re.compile(r'[╮┐+]')
_FOCUS_NAMES = {kind: kind.replace('-', ' ') for kind in STOCK_KINDS}
_FOCUS_NAMES.update({'workspace-tabs': 'workspaces', 'live-status': 'session'})


def _entry(text, selected):
    marker = {True: r'> +', False: '', None: r'(?:> +)?'}[selected]
    # The leading token can be a theme-specific status icon. Bound the match
    # to one pane cell so a neighboring pane or line cannot supply the value.
    return re.compile(r'(?:^|[│|]) *(?:[^ >│|\n]+ +)?' + marker + text
                      + r' *(?=[│|]|$)', re.MULTILINE)


def case_row(case, status, *, selected=None):
    return _entry(re.escape(case) + r': +' + re.escape(status), selected)


def artifact_row(label, case, availability, *, selected=None):
    return _entry(re.escape(label) + r' +— +' + re.escape(case)
                  + r' +\[' + re.escape(availability) + r'\]', selected)


def _breadcrumb(text):
    rows = text.splitlines()
    if rows:
        # The host omits the workspace segment when only the pane name fits.
        parts = re.split(r' {2,}', rows[-1].rstrip(), maxsplit=1)
        if len(parts) == 2:
            name = next((part for part in re.split(r' [›>] ', parts[1])
                         if part in _FOCUS_NAMES.values()), None)
            if name is not None:
                return name
        if rows[-1].startswith('R run checked cases |'):
            return 'simulation catalog'  # The unique Catalog hints can fill the footer.
    return None


def focus_pane(terminal, kind):
    """Navigate by observed focus, not a saved workspace's presumed tile order."""
    for _ in range(12):
        text = terminal.drain(.2)
        if _breadcrumb(text) == _FOCUS_NAMES[kind]:
            return
        terminal.key(b'\t')
    raise AssertionError('Could not focus ' + kind + ':\n' + text)


def assert_focus_order(terminal, order):
    """Check both directions and wraparound using actual terminal key events."""
    focus_pane(terminal, order[0])
    for steps, key in ((order[1:] + order[:1], b'\t'),
                       (order[:0:-1] + order[:1], b'\x1b[Z')):
        for kind in steps:
            terminal.key(key)
            text = terminal.drain(.2)
            actual = _breadcrumb(text)
            if actual != _FOCUS_NAMES[kind]:
                raise AssertionError('Focus order: expected %s, saw %r\n%s' % (kind, actual, text))


def assert_stock_layout(terminal, label, evidence):
    """Measure native frame positions and widths in a real, resized PTY."""
    deadline = time.monotonic() + 15
    width, height = terminal.width, terminal.height
    while True:
        text = terminal.drain(.2)
        rows = text.splitlines()
        frames = {}
        for y, row in enumerate(rows[1:-1], start=1):
            for match in _HEADER.finditer(row):
                corner = _RIGHT_CORNER.search(row, match.end())
                if corner:
                    frames[match['title']] = (match.start(), y, corner.end())
        if set(frames) == set(PANE_TITLES) and len(rows) == height:
            session, attempts, execution = [
                frames[name] for name in ('session', 'simulation-attempts', 'execution')]
            catalog, detail, cases, artifacts, logs = [
                frames['simulation-' + name]
                for name in ('catalog', 'detail', 'cases', 'artifacts', 'logs')]
            split = session[2]
            middle = catalog[2]
            ok = (
                all(x == 0 and edge == split for x, _, edge in (session, attempts, execution))
                and session[1] == catalog[1] == detail[1] == 1
                and session[1] < attempts[1] < execution[1]
                and 0 < split < middle < width
                and cases[0] == split and cases[2] == middle
                and catalog[0] == logs[0] == split
                and detail[0] == artifacts[0] == middle
                and detail[2] == artifacts[2] == logs[2] == width
                and cases[1] == artifacts[1]
                and catalog[1] < cases[1] < logs[1] < height - 2
                and len(rows[-2]) == width
                and rows[-2][split] in '╰└+'
                and rows[-2][middle] in '─-'
                and rows[-2][-1] in '╯┘+'
                and 'Space c c commands' in rows[-1]
                and 'project-tests' not in text)
            if ok:
                (evidence / (label + '.txt')).write_text(text)
                (evidence / (label + '-frames.json')).write_text(json.dumps(
                    dict(width=width, height=height, frames=frames), indent=2) + '\n')
                return text
        if time.monotonic() >= deadline:
            (evidence / (label + '-unpainted.txt')).write_text(text)
            raise AssertionError('%s: no stock Testing arrangement at %dx%d: %r\n%s' %
                                 (label, width, height, frames, text))
