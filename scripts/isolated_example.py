#!/usr/bin/env python3
"""Audit or explicitly configure a task-specific hardcaml_asic_example checkout.

Default: read-only audit, failing closed on unsafe/copied configuration. Example:
  python3 scripts/isolated_example.py --project-root /task/example \
    --provider-executable /provider/bin/hardcaml-asic-flow --env-file /task/env.json

Add --rewrite to replace known Workbench configs with agent-local output paths.
Add --clone-from /source/hardcaml_asic_example --revision HEAD --rewrite to create
a disposable, detached checkout of committed source (never copies dirty files).
The destination must not exist. No branches, source index operations or commits
are made. An existing explicit task copy needs no Git operations.
Configs may live in .workbench/ or at the legacy project root. If both exist,
their bytes must match; rewrite preserves their locations and equality.

--env-file is a COMPLETE captured string->string environment, not an overlay.
PATH, OPAM_SWITCH_PREFIX and OCAMLPATH must be present explicitly. Setup stores
it privately at PROJECT/.isolated-example/environment.json for isolated_review.py.
No tools, providers, builds or tests are executed by this script. Later Dune
builds must use -j 1. Shared provider/toolchain/PDK files are only read here;
read-only sharing is a dependency contract, NOT an OS sandbox. Untrusted tools
require an external read-only mount/sandbox. Config audit is not a source-code
security audit. Do not run bootstrap/install scripts against shared dependencies.

Known config fields only; S-expression comments/escapes outside the supported
subset fail closed. Symlinks in source/configs or build roots and hardlinked
source files are rejected, not followed or
repaired. Replace them explicitly before setup. Pre-existing nonempty _build*
directories require a setup receipt for this exact task root; initially prepare
a copy without build outputs, then build locally after setup. Proven build trees
are not traversed, allowing Dune's generated symlinks. Simulation setup
requires --simulation-provider with an executable path inside the task copy;
the file may be built later. The selected ASIC provider is always explicit.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parent.parent
OWNER = Path('/home/wayne/devel/jane/hardcaml_asic_example')
PROTECTED = (OWNER, REPO.parent / 'hardcaml_asic', REPO.parent / 'hardcaml_workbench')
ASIC = 'hardcaml-workbench-asic.sexp'
PREPARATION = 'hardcaml-workbench-preparation.sexp'
SIMULATION = 'hardcaml-workbench-simulation.sexp'
STATE = '.isolated-example'
FIELDS = {
    ASIC: {'schema_version', 'project_executable', 'provider_executable',
           'results_root', 'toolchain', 'python', 'support_tools', 'pdk_root',
           'stage_timeout_seconds'},
    PREPARATION: {'schema_version', 'build_target', 'results_root', 'timeout_seconds'},
    SIMULATION: {'schema_version', 'provider_executable', 'provider_args',
                 'discovery_timeout_seconds', 'run_timeout_seconds'},
}
REQUIRED = {
    ASIC: {'schema_version', 'project_executable', 'provider_executable', 'results_root', 'toolchain'},
    PREPARATION: FIELDS[PREPARATION],
    SIMULATION: FIELDS[SIMULATION],
}


class SetupError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise SetupError(message)


def within(path, root):
    return path == root or root in path.parents


def no_symlink_components(path):
    require('..' not in Path(path).parts, f'Parent traversal is not permitted: {path}')
    path = Path(os.path.abspath(path))
    for component in (path, *path.parents):
        require(not component.is_symlink(), f'Symlink path component: {component}')
    return path


def task_root(path, creating=False):
    root = no_symlink_components(path.expanduser())
    for protected in (*PROTECTED, REPO):
        protected = protected.resolve()
        require(not within(root, protected) and not within(protected, root),
                f'Task project overlaps protected checkout: {root} / {protected}')
    if creating:
        require(not root.exists(), f'Clone destination already exists: {root}')
        require(root.parent.is_dir(), f'Clone parent must already exist: {root.parent}')
    else:
        require(root.is_dir(), f'Not a task project directory: {root}')
        require(root.stat().st_uid == os.getuid(), f'Task root is not owned by this user: {root}')
        require((root / 'dune-project').is_file(), f'No dune-project in {root}')
    return root


def audit_tree(root):
    receipt = audit_output_provenance(root)
    # Never descend into .git: git worktree metadata may legitimately refer to a
    # separate Git directory. It is not an output path used by this workflow.
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            info = path.lstat()
            require(not stat.S_ISLNK(info.st_mode), f'Symlink in task tree: {path}')
            if name == '.git' and Path(directory) == root:
                continue
            require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode),
                    f'Non-regular task file: {path}')
            require(info.st_uid == os.getuid(), f'Task path is not owned by this user: {path}')
            if Path(directory) == root and name.startswith('_build') and receipt is not None:
                require(stat.S_ISDIR(info.st_mode), f'Build root must be a directory: {path}')
                dirs.remove(name)
                continue
            if stat.S_ISREG(info.st_mode):
                require(info.st_nlink == 1, f'Hardlinked task file: {path}')
        if Path(directory) == root and '.git' in dirs:
            dirs.remove('.git')


def audit_output_provenance(root):
    receipt_path = no_symlink_components(root / STATE / 'setup.json')
    if receipt_path.exists():
        info = receipt_path.stat()
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                and info.st_uid == os.getuid() and info.st_size <= 65536,
                f'Unsafe setup receipt: {receipt_path}')
        receipt = json.loads(receipt_path.read_text())
        require(isinstance(receipt, dict) and receipt.get('schema_version') == 1
                and receipt.get('project_root') == str(root),
                f'Setup receipt belongs to another copy: {receipt_path}')
        return receipt
    # A normal cp -r may copy regular build products too. Do not silently pin
    # one of those executables or let Dune reuse its copied build database.
    candidates = list(root.glob('_build*'))
    candidates += [root / STATE / 'asic-results', root / STATE / 'preparation-results']
    for path in candidates:
        if path.exists():
            require(path.is_dir() and not any(path.iterdir()),
                    f'Unproven copied outputs: {path}; explicitly remove/move them before initial setup')


def parse_sexp(text):
    """Small strict reader, sufficient for the three flat derived-sexp records."""
    position = 0

    def value():
        nonlocal position
        while position < len(text) and text[position].isspace():
            position += 1
        require(position < len(text), 'Unexpected end of S-expression')
        char = text[position]
        if char == '(':
            position += 1
            result = []
            while True:
                while position < len(text) and text[position].isspace():
                    position += 1
                require(position < len(text), 'Unclosed S-expression')
                if text[position] == ')':
                    position += 1
                    return result
                result.append(value())
        if char == '"':
            try:
                result, count = json.JSONDecoder().raw_decode(text[position:])
            except ValueError as error:
                raise SetupError(f'Unsupported quoted S-expression: {error}') from error
            position += count
            require(isinstance(result, str) and '\0' not in result, 'Invalid string atom')
            return result
        start = position
        while position < len(text) and not text[position].isspace() and text[position] not in '()':
            require(text[position] not in ';"\\#' and ord(text[position]) >= 32,
                    'Unsupported S-expression syntax (comments/escapes fail closed)')
            position += 1
        require(position > start, 'Unexpected S-expression delimiter')
        return text[start:position]

    result = value()
    require(not text[position:].strip(), 'Trailing S-expression data')
    return result


def config_paths(root, name):
    """Match Config_location: common first, legacy allowed only if byte-identical."""
    common = no_symlink_components(root / '.workbench')
    require(not common.exists() or common.is_dir(), f'Not a config directory: {common}')
    paths = [no_symlink_components(common / name),
             no_symlink_components(root / name)]
    present = []
    for path in paths:
        if path.exists():
            info = path.stat()
            require(stat.S_ISREG(info.st_mode) and info.st_size <= 65536,
                    f'Config must be a regular file of at most 65536 bytes: {path}')
            present.append(path)
    if len(present) == 2:
        require(present[0].read_bytes() == present[1].read_bytes(),
                f'Conflicting configuration files: {present[0]} and {present[1]} differ')
    return present


def read_config(root, name):
    paths = config_paths(root, name)
    if not paths:
        return None
    path = paths[0]
    sexp = parse_sexp(path.read_text())
    require(isinstance(sexp, list), f'Not a config record: {path}')
    result = {}
    for entry in sexp:
        require(isinstance(entry, list) and len(entry) == 2 and isinstance(entry[0], str),
                f'Invalid config field: {path}')
        key, value = entry
        require(key in FIELDS[name] and key not in result, f'Unknown/duplicate field {key} in {path}')
        result[key] = value
    require(REQUIRED[name] <= result.keys(), f'Missing required fields in {path}')
    require(result['schema_version'] == '1', f'Unsupported config schema in {path}')
    return result


def atom(config, key):
    value = config.get(key)
    require(isinstance(value, str) and bool(value), f'{key} must be a nonempty atom')
    return value


def optional_atom(config, key):
    value = config.get(key, [])
    require(isinstance(value, list) and len(value) <= 1
            and all(isinstance(x, str) and x for x in value), f'Invalid option field: {key}')
    return value[0] if value else None


def local_path(root, value):
    path = Path(value)
    require(path.is_absolute(), f'Output/executable path must be absolute: {value}')
    path = no_symlink_components(path)
    require(within(path, root) and path != root, f'Path escapes task project: {value}')
    return path


def dependency(value, directory=False):
    path = Path(value).expanduser()
    require(path.is_absolute(), f'Dependency path must be absolute: {value}')
    path = path.resolve(strict=True)
    require(path.is_dir() if directory else path.is_file(), f'Invalid dependency: {path}')
    return str(path)


def environment(path):
    env = json.loads(path.read_text())
    return validate_environment(env)


def validate_environment(env):
    require(isinstance(env, dict) and all(
        isinstance(k, str) and isinstance(v, str) and k and '=' not in k
        and '\0' not in k + v for k, v in env.items()),
        '--env-file must be a complete JSON string->string environment')
    for key in ('PATH', 'OPAM_SWITCH_PREFIX', 'OCAMLPATH'):
        require(key in env, f'Environment must explicitly pin {key}')
    require(env['PATH'] and Path(env['OPAM_SWITCH_PREFIX']).is_absolute(),
            'PATH must be nonempty and OPAM_SWITCH_PREFIX absolute')
    for part in env['PATH'].split(os.pathsep):
        require(part and Path(part).is_absolute(), 'Pinned PATH entries must be absolute (no current directory)')
    for part in filter(None, env['OCAMLPATH'].split(os.pathsep)):
        require(Path(part).is_absolute(), 'OCAMLPATH entries must be absolute')
    # Resolve mutable aliases such as provider/current/lib once during setup.
    # Subsequent launches consume the saved canonical paths, never reselect current.
    for key in ('PATH', 'OCAMLPATH'):
        env[key] = os.pathsep.join(str(Path(part).resolve())
                                  for part in env[key].split(os.pathsep) if part)
    env['OPAM_SWITCH_PREFIX'] = str(Path(env['OPAM_SWITCH_PREFIX']).resolve())
    for key in ('DUNE_BUILD_DIR', 'DUNE_WORKSPACE', 'DUNE_CACHE_ROOT', 'DUNE_INSTALL_PREFIX',
                'DESTDIR', 'HARDCAML_WORKBENCH_DAEMON', 'HARDCAML_WORKBENCH_DIAGNOSTICS',
                'WB_REVIEW_REAL_DUNE'):
        require(not env.get(key), f'Remove output/launcher override {key} from captured environment')
    for key in ('HOME', 'TMPDIR', 'TMP', 'TEMP', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME',
                'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR'):
        if env.get(key):
            path = Path(env[key]).resolve()
            for protected in PROTECTED:
                require(not within(path, protected.resolve()),
                        f'Environment {key} targets protected checkout: {path}')
    # Do not enable a shared writable Dune cache, even if the caller's capture did.
    require(env.get('DUNE_CACHE', 'disabled') == 'disabled', 'Pin DUNE_CACHE=disabled or omit it')
    return env


def environment_digest(env):
    return hashlib.sha256(json.dumps(env, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def audit_for_launch(root, provider, env):
    """Read-only launch gate; pass the captured env BEFORE terminal/session overlays.

    Requires explicit setup, exact canonical provider/config agreement, and the
    setup provider bytes/environment hashes. Returns the validated setup receipt.
    Proven _build* trees are trusted local outputs, not recursively audited;
    this is not protection against hostile/concurrent mutation of a task copy.
    """
    root = task_root(Path(root))
    env = validate_environment(env)
    provider = Path(dependency(provider))
    require(os.access(provider, os.X_OK), f'Provider is not executable: {provider}')
    audit_tree(root)
    receipt = audit_output_provenance(root)
    require(receipt is not None, 'Missing setup receipt; run explicit --rewrite before launch')
    configs = {name: read_config(root, name) for name in FIELDS}
    validate_configs(root, configs, provider)
    require(receipt.get('provider_executable') == str(provider), 'Setup receipt provider path drift')
    require(receipt.get('provider_sha256') == hashlib.sha256(provider.read_bytes()).hexdigest(),
            'Setup receipt provider hash drift; rerun explicit setup')
    require(receipt.get('environment_sha256') == environment_digest(env),
            'Setup receipt environment hash drift; use captured environment or rerun explicit setup')
    return receipt


def positive(config, key, default, maximum=None):
    value = config.get(key, str(default))
    require(isinstance(value, str) and value.isdecimal() and int(value) > 0,
            f'{key} must be a positive integer')
    require(maximum is None or int(value) <= maximum, f'{key} exceeds {maximum}')
    return value


def build_target(config):
    target = atom(config, 'build_target')
    require(not target.startswith(('/', '-', '_build/')) and target.endswith('.exe')
            and all(x not in ('', '.', '..') for x in target.split('/'))
            and '@' not in target and '\\' not in target, 'Unsafe preparation build_target')
    return target


def validate_configs(root, configs, provider):
    asic, prep, sim = (configs[name] for name in (ASIC, PREPARATION, SIMULATION))
    require(asic is not None and prep is not None, 'Missing ASIC/preparation configs; use --rewrite')
    require(atom(asic, 'provider_executable') == str(provider),
            'Configured provider does not exactly match --provider-executable; use --rewrite')
    local_path(root, atom(asic, 'project_executable'))
    local_path(root, atom(asic, 'results_root'))
    dependency(atom(asic, 'toolchain'), directory=True)
    for key in ('python', 'support_tools', 'pdk_root'):
        value = optional_atom(asic, key)
        if value:
            dependency(value, directory=key != 'python')
    timeout = optional_atom(asic, 'stage_timeout_seconds')
    if timeout:
        positive({'stage_timeout_seconds': timeout}, 'stage_timeout_seconds', 3600)
    # stage_timeout_seconds is a sexp option, unlike the mandatory preparation timeout.
    build_target(prep)
    local_path(root, atom(prep, 'results_root'))
    positive(prep, 'timeout_seconds', 600)
    if sim is not None:
        local_path(root, atom(sim, 'provider_executable'))
        require(sim.get('provider_args') == [], 'Simulation provider_args must be empty for isolated setup')
        positive(sim, 'discovery_timeout_seconds', 10, 60)
        positive(sim, 'run_timeout_seconds', 120, 86400)


def generated_configs(args, root, old, provider):
    previous = old[ASIC] or {}
    target = build_target(old[PREPARATION] or {'build_target': 'bin/project.exe'})
    toolchain = args.toolchain or previous.get('toolchain')
    require(isinstance(toolchain, (str, Path)), 'Supply --toolchain when no ASIC config exists')
    asic = {'schema_version': '1',
            'project_executable': str(root / '_build/default' / target),
            'provider_executable': str(provider),
            'results_root': str(root / STATE / 'asic-results'),
            'toolchain': dependency(toolchain, directory=True)}
    for key in ('python', 'support_tools', 'pdk_root'):
        selected = getattr(args, key) or optional_atom(previous, key)
        asic[key] = [dependency(selected, directory=key != 'python')] if selected else []
    asic['stage_timeout_seconds'] = ['3600']
    prep = {'schema_version': '1', 'build_target': target,
            'results_root': str(root / STATE / 'preparation-results'), 'timeout_seconds': '600'}
    sim = None
    if old[SIMULATION] is not None or args.simulation_provider:
        require(args.simulation_provider is not None,
                'Existing simulation config requires explicit --simulation-provider TASK_LOCAL_PATH')
        sim = {'schema_version': '1',
               'provider_executable': str(local_path(root, str(args.simulation_provider))),
               'provider_args': [], 'discovery_timeout_seconds': '10', 'run_timeout_seconds': '120'}
    return {ASIC: asic, PREPARATION: prep, SIMULATION: sim}


def sexp(value):
    if isinstance(value, list):
        return '(' + ' '.join(sexp(x) for x in value) + ')'
    return json.dumps(value, ensure_ascii=True)


def atomic_write(path, text):
    # Replacement, never truncate/follow an existing config inode or symlink.
    no_symlink_components(path)
    fd, temporary = tempfile.mkstemp(prefix='.isolated-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def git(argv, cwd=None):
    # Ignore ambient Git redirects and global hooks/config. No identity changes.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0')
    result = subprocess.run(['git', *argv], cwd=cwd,
                            env=env, text=True, capture_output=True)
    require(result.returncode == 0, f'Git command failed: {shlex.join(argv)}\n{result.stderr}')
    return result.stdout.strip()


def clone(args, root):
    source = args.clone_from.expanduser().resolve(strict=True)
    require(source.is_dir(), 'Clone source must be a local committed repository')
    require(not within(root, source), 'Clone destination must be outside source')
    revision = args.revision or 'HEAD'
    require(not revision.startswith('-'), 'Invalid revision')
    commit = git(['-C', str(source), 'rev-parse', '--verify', revision + '^{commit}'])
    dirty = git(['-C', str(source), '--no-optional-locks', 'status', '--porcelain', '--untracked-files=normal'])
    print(f'Cloning committed source {commit}; source working-tree changes are NOT copied.'
          + (' Source has uncommitted/untracked changes.' if dirty else ''), flush=True)
    git(['clone', '--no-hardlinks', '--no-checkout', '--', str(source), str(root)])
    git(['-C', str(root), 'checkout', '--detach', commit])
    return {'source': str(source), 'commit': commit, 'source_dirty': bool(dirty)}


def setup(args):
    require(not args.clone_from or args.rewrite, '--clone-from requires explicit --rewrite')
    require(not args.revision or args.clone_from, '--revision requires --clone-from')
    require(args.rewrite or not any((args.toolchain, args.python, args.support_tools,
                                   args.pdk_root, args.simulation_provider)),
            'Configuration overrides require --rewrite')
    root = task_root(args.project_root, creating=bool(args.clone_from))
    provider = Path(dependency(args.provider_executable))
    require(os.access(provider, os.X_OK), f'Provider is not executable: {provider}')
    env = environment(args.env_file)
    provenance = clone(args, root) if args.clone_from else None
    task_root(root)
    audit_tree(root)
    audit_output_provenance(root)
    old = {name: read_config(root, name) for name in FIELDS}
    if args.rewrite:
        configs = generated_configs(args, root, old, provider)
        validate_configs(root, configs, provider)
        state = root / STATE
        state.mkdir(mode=0o700, exist_ok=True)
        require(stat.S_IMODE(state.stat().st_mode) & 0o077 == 0,
                f'{state} must be private (mode 0700) for captured environment')
        # Retain originals once in the private directory; refuse to overwrite them.
        for name in FIELDS:
            originals = config_paths(root, name)
            backup = state / (name + '.original')
            if originals and not backup.exists():
                atomic_write(backup, originals[0].read_text())
        for name, config in configs.items():
            if config is not None:
                # Keep identical duplicates identical; preserve the source layout.
                for path in config_paths(root, name) or [root / name]:
                    atomic_write(path, sexp([[k, v] for k, v in config.items()]) + '\n')
        atomic_write(state / 'environment.json', json.dumps(env, indent=2, sort_keys=True) + '\n')
        receipt = {'schema_version': 1, 'project_root': str(root),
                   'provider_executable': str(provider),
                   'provider_sha256': hashlib.sha256(provider.read_bytes()).hexdigest(),
                   'environment_sha256': environment_digest(env),
                   'source': provenance, 'jobs': 1,
                   'shared_dependencies_access': 'read-only contract; no sandbox enforced'}
        atomic_write(state / 'setup.json', json.dumps(receipt, indent=2) + '\n')
        print(f'Rewritten task configs; originals retained in {state}')
        env_file = state / 'environment.json'
    else:
        audit_for_launch(root, provider, env)
        env_file = args.env_file.resolve()
    print(f'Audit passed: {root}\nProvider: {provider}\n'
          'No provider, build, test, toolchain install or PDK install was run.')
    command = [sys.executable, str(REPO / 'scripts/isolated_review.py'),
               '--project-root', str(root), '--provider-executable', str(provider),
               '--env-file', str(env_file)]
    print('Launcher preflight (run separately):\n  ' + shlex.join(command + ['--check']))
    print('Launch (after task-local binaries are built with dune -j 1):\n  ' + shlex.join(command))


def parser():
    result = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    result.add_argument('--project-root', required=True, type=Path)
    result.add_argument('--provider-executable', required=True, type=Path)
    result.add_argument('--env-file', required=True, type=Path)
    mode = result.add_mutually_exclusive_group()
    mode.add_argument('--rewrite', action='store_true', help='explicitly rewrite configs; default is read-only audit')
    mode.add_argument('--audit', action='store_true', help='explicit read-only audit (also the default)')
    result.add_argument('--clone-from', type=Path, help='local committed source; destination must not exist')
    result.add_argument('--revision', help='committed source revision (default HEAD), checked out detached')
    for flag in ('toolchain', 'python', 'support-tools', 'pdk-root', 'simulation-provider'):
        result.add_argument('--' + flag, type=Path)
    return result


def main():
    try:
        setup(parser().parse_args())
        return 0
    except (SetupError, OSError, ValueError) as error:
        print(f'isolated-example: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
