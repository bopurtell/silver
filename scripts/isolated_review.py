#!/usr/bin/env python3
"""Launch this worktree's daemon/client with isolated state and pinned environment.

Interface for scripts/isolated_example.py (no manifest schema dependency):
  python3 scripts/isolated_review.py --project-root ROOT \
    --provider-executable ABSOLUTE_PROVIDER --env-file ENVIRONMENT_JSON

ENVIRONMENT_JSON is a *complete* subprocess environment: a JSON object mapping
names to string values, including PATH and any OPAM_SWITCH_PREFIX/OCAMLPATH.
Use the environment.json emitted by isolated_example.py. No ambient provider
environment is used implicitly; setup receipt validation precedes all tools.
Repeat --require-library to replace the default ASIC project library checks.
Checks run ocamlfind queries and dune --version, never a build. --check exits
after preflight; --build explicitly builds this worktree's two binaries -j 1.

Each invocation creates a fresh private session below --session-parent (default
this worktree/.dev/isolated-review). State, preferences, logs, binary snapshots
and a launch receipt are retained after exit. The launcher owns and stops only
the processes it creates; there is no attach/stop-existing-daemon operation.
The displayed provider must match hardcaml-workbench-asic.sexp in the project.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import isolated_example

REPO = Path(__file__).resolve().parent.parent
OWNER_PROJECT = REPO.parent / 'hardcaml_asic_example'
MAIN_CHECKOUT = REPO.parent / 'hardcaml_workbench'
DEFAULT_LIBRARIES = ('core', 'hardcaml', 'hardcaml_asic',
                     'hardcaml_asic.execution', 'ppx_jane', 'ppx_hardcaml')


class LaunchError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise LaunchError(message)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def within(path, root):
    return path == root or root in path.parents


def safe_project(path):
    root = path.expanduser().resolve(strict=True)
    for protected in (OWNER_PROJECT, MAIN_CHECKOUT):
        require(not within(root, protected.resolve()),
                f'Refusing protected project {root}; prepare an isolated project copy first.')
    require((root / 'dune-project').is_file(), f'No dune-project in {root}')
    return root


def run_readonly(argv, env, cwd):
    try:
        result = subprocess.run(argv, env=env, cwd=cwd, capture_output=True,
                                text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LaunchError(f'Cannot run {shlex.join(map(str, argv))}: {error}') from error
    return result


def pinned_environment(args):
    return isolated_example.environment(args.env_file), f'file:{args.env_file.resolve()}'


def executable(name, env):
    path = shutil.which(name, path=env['PATH'])
    require(path is not None,
            f'Missing {name} in selected environment PATH. Install/select the provider '
            'toolchain, or supply --env-file with its bin directories and OCAMLPATH.')
    return str(Path(path).resolve())


def validate_environment(env, project, libraries):
    dune = executable('dune', env)
    findlib = executable('ocamlfind', env)
    version = run_readonly([dune, '--version'], env, project)
    match = re.match(r'^(\d+)\.(\d+)', version.stdout.strip())
    require(version.returncode == 0 and match is not None
            and tuple(map(int, match.groups())) >= (3, 22),
            'Workbench requires Dune >= 3.22; selected dune is ' + dune + ': '
            + (version.stdout + version.stderr).strip())
    found, missing = {}, []
    for library in libraries:
        result = run_readonly([findlib, 'query', library], env, project)
        if result.returncode:
            missing.append(f'  {library}: {result.stderr.strip()}')
        else:
            found[library] = result.stdout.strip()
    require(not missing,
            'Selected provider build environment is missing libraries:\n' + '\n'.join(missing)
            + '\nOPAM_SWITCH_PREFIX=' + env.get('OPAM_SWITCH_PREFIX', '<unset>')
            + '\nOCAMLPATH=' + env.get('OCAMLPATH', '<unset>')
            + '\nSelect the provider switch containing these libraries, or regenerate '
            '--env-file with the provider installation lib directories on OCAMLPATH. '
            'An existing provider executable alone does not provide build dependencies. '
            'Use --require-library NAME (repeatable) for a different project dependency set.')
    return {'dune': dune, 'dune_version': version.stdout.strip(),
            'ocamlfind': findlib, 'libraries': found}


def configured_provider(project):
    config = project / 'hardcaml-workbench-asic.sexp'
    require(config.is_file(), f'Missing {config}; run isolated example setup first.')
    # The generated ASIC config is a flat sexp record. Only read the executable
    # field; require an unambiguous quoted or whitespace-delimited absolute atom.
    token = r'(?:"(?:[^"\\]|\\.)*"|[^\s()]+)'
    text = config.read_text()
    matches = re.findall(r'\(\s*"?provider_executable"?\s+(' + token + r')\s*\)', text)
    require(len(matches) == 1, f'Cannot identify one provider_executable in {config}')
    value = json.loads(matches[0]) if matches[0].startswith('"') else matches[0]
    require(Path(value).is_absolute(), f'Provider path in {config} must be absolute')
    roots = re.findall(r'\(\s*"?results_root"?\s+(' + token + r')\s*\)', text)
    require(len(roots) == 1, f'Cannot identify one results_root in {config}')
    result_value = json.loads(roots[0]) if roots[0].startswith('"') else roots[0]
    results = Path(result_value)
    results = (results if results.is_absolute() else project / results).resolve()
    for protected in (OWNER_PROJECT.resolve(), MAIN_CHECKOUT.resolve()):
        require(not within(results, protected),
                f'ASIC results_root points into protected checkout: {results}; '
                'regenerate isolated project configuration before launching.')
    return Path(value).resolve(strict=True)


def binary_path(path):
    require(path.exists(), f'Missing worktree binary: {path}; build this worktree with '
            'dune build -j 1 daemon/main.exe terminal/main.exe, or launch with --build.')
    path = path.resolve(strict=True)
    require(within(path, REPO / '_build'),
            f'Binary must come from this worktree {REPO / "_build"}: {path}')
    require(path.is_file() and os.access(path, os.X_OK), f'Not executable: {path}')
    return path


def save_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    os.replace(temporary, path)


def stop_owned(process):
    if process is None:
        return
    if process.poll() is None:
        # The daemon starts its own session. Never read a PID from disk to
        # decide what to terminate, and never signal the caller's process group.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def await_endpoint(process, discovery, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        require(process.poll() is None,
                f'Daemon exited with status {process.returncode}; inspect daemon.log')
        try:
            body = (discovery / 'daemon.sexp').read_text()
        except FileNotFoundError:
            time.sleep(0.05)
            continue
        endpoint = re.search(r'\(endpoint\s+"?(http://127\.0\.0\.1:(\d+))"?\)', body)
        pid = re.search(r'\(pid\s+(\d+)\)', body)
        instance = re.search(r'\(instance_id\s+"?([^\s()"]+)"?\)', body)
        if endpoint and pid and instance and int(pid[1]) == process.pid:
            require(0 < int(endpoint[2]) <= 65535, 'Invalid daemon endpoint port')
            # The real daemon publishes metadata only after its own hello probe.
            return endpoint[1], instance[1]
        time.sleep(0.05)
    raise LaunchError(f'Daemon readiness timed out after {timeout}s; inspect daemon.log')


def launch(args):
    project = safe_project(args.project_root)
    provider = args.provider_executable.expanduser().resolve(strict=True)
    require(provider == configured_provider(project),
            'Selected provider differs from project ASIC config; rerun isolated setup '
            'with this provider, then launch that project.')
    require(os.access(provider, os.X_OK), f'Provider is not executable: {provider}')
    env, env_source = pinned_environment(args)
    isolated_example.audit_for_launch(project, provider, env)
    # Check the captured environment before applying client-local terminal identity.
    for key in ('TERM', 'COLORTERM', 'TERM_PROGRAM', 'TMUX', 'SSH_TTY'):
        if key in os.environ:
            env[key] = os.environ[key]
    toolchain = validate_environment(env, project, args.require_library or DEFAULT_LIBRARIES)
    print(f'Workbench worktree: {REPO}\nProject: {project}\nProvider: {provider}\n'
          f'Provider SHA256: {digest(provider)}\nEnvironment: {env_source}\n'
          f'OPAM_SWITCH_PREFIX: {env.get("OPAM_SWITCH_PREFIX", "<unset>")}\n'
          f'OCAMLPATH: {env.get("OCAMLPATH", "<unset>")}\n'
          f'Dune: {toolchain["dune"]} ({toolchain["dune_version"]}); jobs: 1', flush=True)
    if args.build:
        isolated_example.no_symlink_components(REPO / '_build')
        command = [toolchain['dune'], 'build', '-j', '1', '--root', str(REPO),
                   'daemon/main.exe', 'terminal/main.exe']
        require(subprocess.run(command, cwd=REPO, env=env).returncode == 0,
                'Workbench build failed; no daemon started.')
    daemon_source, client_source = binary_path(args.daemon), binary_path(args.client)
    for name, path in [('Daemon', daemon_source), ('Client', client_source)]:
        print(f'{name}: {path}\n{name} SHA256: {digest(path)}', flush=True)
    if args.check:
        print('Preflight passed; no daemon/client started.', flush=True)
        return 0
    require(args.plain or sys.stdin.isatty(), 'Interactive launch requires a terminal; use --plain for status.')
    parent = args.session_parent.expanduser().resolve()
    for protected in (OWNER_PROJECT.resolve(), MAIN_CHECKOUT.resolve(), project):
        require(not within(parent, protected), f'Session parent must be outside project/protected checkout: {parent}')
    parent.mkdir(parents=True, exist_ok=True)
    session = Path(tempfile.mkdtemp(prefix='review-', dir=parent))
    for name in ('bin', 'discovery', 'state', 'preferences', 'runtime', 'cache', 'tmp'):
        (session / name).mkdir(mode=0o700)
    env.update(XDG_STATE_HOME=str(session / 'preferences'),
               XDG_RUNTIME_DIR=str(session / 'runtime'),
               HARDCAML_WORKBENCH_DAEMON=str(session / 'bin/daemon'),
               HARDCAML_WORKBENCH_DIAGNOSTICS=str(session / 'terminal.log'),
               WB_REVIEW_REAL_DUNE=toolchain['dune'], OPAMJOBS='1', DUNEJOBS='1',
               DUNE_CACHE='disabled', XDG_CACHE_HOME=str(session / 'cache'),
               TMPDIR=str(session / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
               OMP_NUM_THREADS='1', OPENBLAS_NUM_THREADS='1')
    # Immutable per-launch copies avoid accidentally running a subsequently rebuilt inode.
    binaries = {}
    for name, source in [('daemon', daemon_source), ('client', client_source)]:
        target = session / 'bin' / name
        before = digest(source)
        shutil.copyfile(source, target)
        target.chmod(0o700)
        require(before == digest(target) == digest(source), f'Binary changed during snapshot: {source}')
        binaries[name] = {'source': str(source), 'snapshot': str(target), 'sha256': before}
    wrapper = session / 'bin/dune'
    helper = (REPO / 'scripts/isolated_review_dune.py').read_text().split('\n', 1)[1]
    wrapper.write_text('#!' + sys.executable + '\n' + helper)
    wrapper.chmod(0o700)
    env['PATH'] = str(session / 'bin') + os.pathsep + env['PATH']
    daemon_argv = [str(session / 'bin/daemon'), '--port', '0', '--discovery-dir',
                   str(session / 'discovery'), '--state-dir', str(session / 'state')]
    receipt = {'schema_version': 1, 'worktree': str(REPO), 'project_root': str(project),
               'provider': {'path': str(provider), 'sha256': digest(provider)},
               'environment_source': env_source, 'toolchain': toolchain,
               'binaries': binaries, 'session': str(session), 'daemon_argv': daemon_argv,
               'status': 'starting', 'jobs': 1}
    receipt['environment_sha256'] = hashlib.sha256(
        json.dumps(env, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    # Full environment may contain credentials. Keep it within the mode-0700 session.
    save_json(session / 'environment.json', env)
    save_json(session / 'launch.json', receipt)
    print(f'Private session: {session}\nDaemon log: {session / "daemon.log"}', flush=True)
    daemon = client = None
    previous = {}

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    try:
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            previous[sig] = signal.signal(sig, interrupted)
        with (session / 'daemon.log').open('wb') as log:
            daemon = subprocess.Popen(daemon_argv, env=env, cwd=project,
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                      start_new_session=True)
        endpoint, instance = await_endpoint(daemon, session / 'discovery', args.startup_timeout)
        client_argv = [str(session / 'bin/client'), '--connect', endpoint,
                       '--project-root', str(project), '--environment', 'inherited']
        if args.plain:
            client_argv.append('--plain')
        receipt.update(status='running', endpoint=endpoint, instance_id=instance,
                       daemon_pid=daemon.pid, client_argv=client_argv)
        save_json(session / 'launch.json', receipt)
        print(f'Endpoint: {endpoint}\nDaemon instance: {instance}\n'
              f'Client command: {shlex.join(client_argv)}', flush=True)
        # Keep terminal foreground process-group semantics (including raw-mode input).
        client = subprocess.Popen(client_argv, cwd=project, env=env)
        while client.poll() is None:
            require(daemon.poll() is None, 'Private daemon exited; see ' + str(session / 'daemon.log'))
            time.sleep(0.1)
        receipt.update(status='completed', client_exit_code=client.returncode)
        return client.returncode if client.returncode >= 0 else 128 - client.returncode
    except BaseException as error:
        receipt.update(status='interrupted' if isinstance(error, KeyboardInterrupt) else 'failed',
                       error=str(error))
        raise
    finally:
        # Ignore additional interrupts while restoring the terminal and reaping children.
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        if client is not None and client.poll() is None:
            client.terminate()
            try:
                client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait()
        stop_owned(daemon)
        save_json(session / 'launch.json', receipt)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        print(f'Review session retained: {session}', flush=True)


def parser():
    result = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    result.add_argument('--project-root', required=True, type=Path)
    result.add_argument('--provider-executable', required=True, type=Path)
    result.add_argument('--env-file', required=True, type=Path)
    result.add_argument('--require-library', action='append', metavar='FINDLIB_NAME')
    result.add_argument('--daemon', type=Path, default=REPO / '_build/default/daemon/main.exe')
    result.add_argument('--client', type=Path, default=REPO / '_build/default/terminal/main.exe')
    result.add_argument('--session-parent', type=Path, default=REPO / '.dev/isolated-review')
    result.add_argument('--startup-timeout', type=float, default=20)
    result.add_argument('--plain', action='store_true', help='print project status and shut down owned daemon')
    result.add_argument('--check', action='store_true', help='read-only preflight; never start a daemon')
    result.add_argument('--build', action='store_true', help='explicitly build own daemon/client with dune -j 1')
    return result


def main():
    args = parser().parse_args()
    try:
        require(args.startup_timeout > 0, '--startup-timeout must be positive')
        require(not (args.check and args.build), '--check and --build are mutually exclusive')
        return launch(args)
    except KeyboardInterrupt:
        return 130
    except (LaunchError, isolated_example.SetupError, OSError, ValueError) as error:
        print(f'isolated-review: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
