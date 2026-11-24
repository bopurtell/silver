#!/usr/bin/env python3
"""Project companion flow HTTP captures into compact, deterministic fake-peer fixtures."""
import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'demo/synthetic_flow'))
from http_client import field, parse, sexp


def project(keys, record):
    return [pair for pair in record if pair[0] in keys]


def export(path, action):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    rows = [row for row in rows if row['path'] in ('/api/v1/asic', '/api/v1/preparation')]
    assert all(row['status'] == 200 for row in rows)
    exchanges = []
    remaining = (['Get', 'Discover', 'Get', 'Describe', 'Get', 'Describe', 'Get'] +
                 (['Stage_fresh', 'Get', 'Launch_fresh'] if action == 'stage-checklist' else ['Plan', 'Get', 'Run']))
    for row in rows:
        if not remaining:
            break
        path = row['path']
        request = parse(row['request'])
        operation = field(request, 'operation')
        if path == '/api/v1/asic':
            # Checklist observation uses independent, unscoped public reads;
            # export only the companion-context launch exchange.
            if not isinstance(operation, list) or operation[0] != 'In_context':
                continue
            if field(operation[1:], 'context') != 'cobalt-companion-v1':
                continue
            operation = field(operation[1:], 'operation')
        name = operation if isinstance(operation, str) else operation[0]
        result, snapshot = parse(row['response'])
        assert result == 'Ok'
        if path == '/api/v1/preparation':
            snapshot = project({'availability'}, snapshot)
        else:
            if name != remaining[0]:
                continue
            # Long-running observations can add Get exchanges. Use the first
            # settled catalog/description/preview and the submission fence.
            previous = exchanges[-1][1] if exchanges else None
            prev = previous[0] if isinstance(previous, list) else previous
            if name == 'Get' and prev in ('Discover', 'Describe', 'Plan'):
                key = {'Discover': 'catalog_default', 'Describe': 'description_json', 'Plan': 'preview'}[prev]
                if not field(snapshot, key):
                    continue
            remaining.pop(0)
            snapshot = project({'configured', 'chip_target', 'catalog_default', 'flows',
                                'operations', 'description_json', 'preview', 'fresh_intent',
                                'workflows'}, snapshot)
            for pair in snapshot:
                if pair[0] == 'operations':
                    pair[1] = [o for o in pair[1] if field(o, 'kind') in ('discover', 'describe', 'plan')]
                if pair[0] == 'fresh_intent':
                    pair[1] = [project({'id', 'selection', 'elaboration_only', 'expected_plan_identity'}, i)
                               for i in pair[1]]
                if pair[0] == 'workflows':
                    pair[1] = []
                    if name not in ('Launch_fresh', 'Run'):
                        continue
                    key = next(pair for pair in operation[1:] if pair[0] == 'key')
                    original = next(w for w in field(parse(row['response'])[1], 'workflows')
                                    if field(w, 'key') == key[1])
                    selected = project({'key', 'id', 'intent', 'run'}, original)
                    for w in selected:
                        if w[0] == 'key':
                            w[1] = '@submission'
                        elif w[0] == 'intent':
                            w[1] = project({'id', 'selection', 'elaboration_only',
                                            'expected_plan_identity'}, w[1])
                    pair[1] = [selected]
                    key[1] = '@submission'
        exchanges.append([path, operation, ['Ok', snapshot]])
    assert not remaining, remaining
    return exchanges


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenario', choices=('stage-checklist', 'flow-review'))
    parser.add_argument('trace', type=Path)
    args = parser.parse_args()
    print('(\n' + '\n'.join('  ' + sexp(row) for row in export(args.trace, args.scenario)) + '\n)')


if __name__ == '__main__':
    main()
