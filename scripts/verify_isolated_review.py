#!/usr/bin/env python3
"""Opt-in real-example smoke test. Retains a disposable checkout and evidence.

Only committed source is cloned. No installation, physical flow or owner process
control is performed. Run after building this worktree's daemon/client with -j 1.
The selected generation and toolchain are read-only dependencies by contract.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import isolated_example as example
import isolated_review as review


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'generation', 'switch-prefix', 'toolchain'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--parent', type=Path, default=Path('/tmp/opencode'))
    args = parser.parse_args()
    base = Path(tempfile.mkdtemp(prefix='wb052-', dir=args.parent))
    print('Disposable verification directory: ' + str(base), flush=True)
    generation = args.generation.resolve(strict=True)
    switch = args.switch_prefix.resolve(strict=True)
    provider = generation / 'bin/hardcaml-asic-flow'
    project = base / 'example'
    # Explicit complete environment: do not inherit ambient provider overlays,
    # Git redirects, build redirects, credentials, or owner preferences.
    env = {'PATH': f'{generation}/bin:{switch}/bin:/usr/bin:/bin',
           'OPAM_SWITCH_PREFIX': str(switch), 'OCAMLPATH': str(generation / 'lib'),
           'HOME': str(base), 'LANG': 'C.UTF-8', 'DUNE_CACHE': 'disabled',
           'OPAMJOBS': '1', 'DUNEJOBS': '1', 'OMP_NUM_THREADS': '1',
           'OPENBLAS_NUM_THREADS': '1', 'PYTHONDONTWRITEBYTECODE': '1'}
    env_file = base / 'environment.json'
    example.atomic_write(env_file, json.dumps(env, indent=2) + '\n')
    env = example.environment(env_file)
    setup_args = example.parser().parse_args([
        '--project-root', str(project), '--provider-executable', str(provider),
        '--env-file', str(env_file), '--clone-from', str(args.source),
        '--revision', args.revision, '--rewrite', '--toolchain', str(args.toolchain),
        '--simulation-provider', str(project / 'simulation/provider.py')])
    example.setup(setup_args)
    example.audit_for_launch(project, provider, env)
    review.validate_environment(env, project, review.DEFAULT_LIBRARIES)
    # Audit above runs before the first project build or provider execution.
    command = [str(switch / 'bin/dune'), 'build', '-j', '1', '--root', str(project),
               'bin/project.exe']
    print('Build command: ' + repr(command), flush=True)
    subprocess.run(command, cwd=project, env=env, check=True)
    launcher = [sys.executable, '-B', str(review.REPO / 'scripts/isolated_review.py'),
                '--project-root', str(project), '--provider-executable', str(provider),
                '--env-file', str(project / example.STATE / 'environment.json'),
                '--session-parent', str(base / 'sessions')]
    subprocess.run(launcher + ['--check'], check=True)
    subprocess.run(launcher + ['--plain'], check=True)
    receipts = list((base / 'sessions').glob('*/launch.json'))
    assert len(receipts) == 1
    receipt = json.loads(receipts[0].read_text())
    assert receipt['status'] == 'completed' and receipt['client_exit_code'] == 0
    try:
        os.kill(receipt['daemon_pid'], 0)
    except ProcessLookupError:
        pass
    else:
        raise RuntimeError('Owned daemon still exists after plain-client exit')
    print('PASS: audited clone, project build, private pair, endpoint handoff, owned cleanup.')
    print('Evidence retained: ' + str(base))


if __name__ == '__main__':
    main()
