"""Companion flow’s synthetic EDA boundary; the daemon and both frontends stay real."""
import json
import os
from pathlib import Path
import sys

import unified_fresh_prefix as fresh


CAPABILITIES = dict(backend_recipe='librelane.classic.v1', input='fresh',
                    stage_selection='complete-prefix-through-declared-endpoint',
                    continuation=False, arbitrary_overrides=False)
DESCRIPTORS = [dict(key='STRATEGY', type='enum', allowed_values=['area', 'delay'])]


def envelope(kind, **body):
    return dict(contract='hardcaml-asic.' + kind, schema_version=1, **body)


def entries(root):
    endpoints = fresh.PREFIX.copy()
    if (root / 'withdraw-routing').exists():
        endpoints.remove('routing')
    return [
        dict(methodology=dict(id=flow, label=label, backend_recipe='librelane.classic.v1',
                              input='fresh', endpoints=endpoints, configurable=['STRATEGY'],
                              defaults=[dict(key='STRATEGY', value='area')]),
             default_profile='balanced',
             profiles=[dict(id=profile, assignments=[]) for profile in profiles])
        for flow, label, profiles in [
            ('standard', 'Standard fixture', ['balanced']),
            ('explore', 'Explore fixture', ['balanced', 'review']),
        ]
    ]


def prepared(root, args):
    def option(flag):
        return args[args.index(flag) + 1]

    flow = next(entry for entry in entries(root) if entry['methodology']['id'] == option('--flow'))
    assert option('--profile') in {profile['id'] for profile in flow['profiles']}, args
    assert option('--endpoint') in flow['methodology']['endpoints'], args
    assert (option('--chip'), option('--variant')) == ('demo-chip', 'small'), args
    overrides = [args[i + 1] for i, value in enumerate(args) if value == '--set']
    assert overrides in ([], ['STRATEGY=area'], ['STRATEGY=delay']), args
    value = overrides[0].split('=')[1] if overrides else 'area'
    return fresh.prepared_input(root, args,
                                effective_parameters=[dict(winning=dict(
                                    assignment=dict(key='STRATEGY', value=value)))],
                                config_fields=dict(STRATEGY=value))


if __name__ == '__main__':
    role, root = sys.argv[1], Path(sys.argv[2])
    args = sys.argv[3:]
    if role != 'pinned':
        gate = root / 'companion-physical-gate'
        if role == 'provider' and args[:1] == ['stages'] and gate.is_dir():
            os.environ['COMPANION_FLOW_PHYSICAL_GATE'] = str(gate)
        fresh.main(prepare=prepared)
    else:
        fresh.event(root, 'pinned-call', argv=args)
        if args[:2] == ['chip', 'list']:
            output = dict(schema_version=1, default_chip='demo-chip', chips=[
                dict(id='demo-chip', label='Demo chip', default_variant='small',
                     variants=[dict(id='small', label='Small')])])
        else:
            assert (args[args.index('--chip') + 1], args[args.index('--variant') + 1]) == (
                'demo-chip', 'small'), args
            catalog = entries(root)
            if args[:2] == ['flow', 'list']:
                output = envelope('flow-list', capabilities=CAPABILITIES,
                                  declaration=envelope('flow-catalog', entries=catalog,
                                                       default=dict(flow='standard', profile='balanced')))
            elif args[:2] == ['flow', 'describe']:
                flow = args[args.index('--flow') + 1]
                output = envelope('flow-describe', capabilities=CAPABILITIES,
                                  parameter_descriptors=DESCRIPTORS,
                                  entry=next(e for e in catalog if e['methodology']['id'] == flow))
            else:
                assert args[:2] == ['flow', 'plan'], args
                fresh.gate(root, 'plan')
                output = prepared(root, args)
        print(json.dumps(output), flush=True)
