"""Fast, offline native CI checks: python3 -B scripts/ci/test_cache.py (non-root)."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
WORKFLOW = REPO / ".github/workflows/ci.yml"

# These stand-ins record observable work. They deliberately perform no network
# operations and cannot invoke a real compiler, opam switch, or Git remote.
FAKE_OPAM = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CI_TEST_LOG'], 'a') as log:
    print(json.dumps(args), file=log)
root = Path(os.environ['OPAMROOT'])
switch = root / 'silver'
if args[:1] == ['init']:
    root.mkdir(parents=True)
    (root / 'config').touch()
elif args[:3] == ['switch', 'list', '--short']:
    if switch.is_dir():
        print('silver')
elif args[:2] == ['switch', 'create']:
    switch.mkdir()
elif args[:2] in (['repository', 'add'], ['pin', 'add']):
    pass
elif args[:1] == ['install']:
    if os.environ.get('CI_TEST_FAIL_INSTALL'):
        sys.exit('simulated dependency installation failure')
    (switch / 'installed').touch()
elif args[:1] == ['clean']:
    pass
elif args[:1] == ['list']:
    if (switch / 'installed').exists():
        print(os.environ.get('CI_TEST_PACKAGES', 'dune 3.20.2\\nocaml 5.2.0+ox'))
elif args[:3] == ['exec', '--switch=silver', '--']:
    if not (switch / 'installed').is_file():
        sys.exit('unprovisioned switch')
    if args[3:] in (['ocamlc', '-version'], ['dune', '--version']):
        print('fake native tool version')
    elif args[3:5] == ['dune', 'build']:
        if os.environ.get('DUNE_CACHE') != 'disabled':
            sys.exit('Dune cache is enabled')
        build = Path('_build')
        if '@install' in args:
            if build.exists():
                sys.exit('build products were restored')
            build.mkdir()
        elif not build.is_dir():
            sys.exit('tests were not preceded by a fresh build')
        with (build / 'commands').open('a') as out:
            print(json.dumps(args), file=out)
    else:
        sys.exit('unexpected opam exec invocation: ' + repr(args))
else:
    sys.exit('unexpected opam invocation: ' + repr(args))
"""

FAKE_CURL = """#!/usr/bin/env python3
import io, sys, tarfile
with tarfile.open(sys.argv[sys.argv.index('-o')+1], 'w:gz') as archive:
    data = b'opam-version: "2.0"'
    info = tarfile.TarInfo('repo/repo')
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))
"""

FAKE_GIT = """#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
if args == ['rev-parse', '--show-toplevel']:
    print(os.getcwd())
elif args[0] == 'status':
    print('!! _build/' if Path('_build').exists() else
          os.environ.get('CI_TEST_GIT_STATUS', ''), end='')
elif args[0] in ('config', 'init') or args[0] == '-C':
    pass
else:
    sys.exit('unexpected git invocation: ' + repr(args))
"""


class CacheTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.source = self.root / "source"
        self.home = self.root / "home"
        self.data = self.home / ".local/share"
        self.config = self.home / ".config"
        self.state = self.data / "silver"
        self.log = self.root / "opam.jsonl"
        tools = self.root / "tools"
        tools.mkdir()
        for name, script in (("opam", FAKE_OPAM), ("curl", FAKE_CURL),
                             ("git", FAKE_GIT)):
            path = tools / name
            path.write_text(script)
            path.chmod(0o755)
        self.env = dict(PATH=f"{tools}:{os.defpath}", HOME=str(self.home),
                        XDG_DATA_HOME=str(self.data), XDG_CONFIG_HOME=str(self.config),
                        CI_TEST_LOG=str(self.log), SILVER_CACHE_KEY="test-exact-key")
        self.fresh_source()

    def fresh_source(self):
        if self.source.exists():
            shutil.rmtree(self.source)
        for name in ("scripts/ci", "scripts/release"):
            shutil.copytree(REPO / name, self.source / name,
                            ignore=shutil.ignore_patterns("__pycache__"))
        for name in ("silver.opam", "silver_provider.opam", "dune-project"):
            shutil.copy2(REPO / name, self.source / name)
        workflow = self.source / WORKFLOW.relative_to(REPO)
        workflow.parent.mkdir(parents=True)
        shutil.copy2(WORKFLOW, workflow)

    def invoke(self, *args, **env):
        return subprocess.run(
            ["bash", "scripts/ci/check.sh", *args], cwd=self.source,
            env=dict(self.env, **env), text=True, capture_output=True, timeout=30,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_built_and_tested(self, commands):
        expected = [
            ["exec", "--switch=silver", "--", "dune", "build", "-j", "2", "-p",
             "silver_provider,silver", "@install"],
            ["exec", "--switch=silver", "--", "dune", "build", "-j", "1", "@test-local"],
            ["exec", "--switch=silver", "--", "dune", "build", "-j", "1", "@test-api"],
        ]
        observed = [cmd for cmd in commands if cmd[:5] ==
                    ["exec", "--switch=silver", "--", "dune", "build"]]
        self.assertEqual(observed, expected)
        self.assertEqual([json.loads(line) for line in
                          (self.source / "_build/commands").read_text().splitlines()],
                         expected)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def cold_provision(self):
        self.assert_success(self.invoke("provision", SILVER_CACHE_HIT="false"))
        commands = self.commands()
        self.assertTrue(any(cmd[:2] == ["switch", "create"] for cmd in commands))
        self.assertTrue(any("--deps-only" in cmd for cmd in commands))
        self.assertTrue(any(cmd[:1] == ["clean"] for cmd in commands))
        self.assertFalse((self.source / "_build").exists())
        self.assertTrue((self.state / "ci-cache-key").is_file())
        self.assertTrue((self.state / "ci-installed-packages").is_file())
        return commands

    def test_cold_and_exact_hit_both_build_and_test_fresh_source(self):
        self.cold_provision()
        # The workflow archives only the managed state, before source builds.
        archive = self.root / "cached-state"
        shutil.copytree(self.state, archive)
        self.assertFalse(any(p.name == "_build" for p in archive.rglob("*")))
        self.log.unlink()
        self.assert_success(self.invoke("test"))
        self.assert_built_and_tested(self.commands())
        self.assertTrue(all(cmd[0] in ("list", "exec") for cmd in self.commands()))

        # Simulate a cache restore into the same absolute installation path,
        # but with the source checkout replaced by a different revision.
        shutil.rmtree(self.home)
        self.fresh_source()
        (self.source / "changed.ml").write_text("let changed = true\n")
        shutil.copytree(archive, self.state)
        self.log.unlink()

        self.assert_success(self.invoke("provision", SILVER_CACHE_HIT="true"))
        self.assertFalse((self.source / "_build").exists())
        self.assert_success(self.invoke("test", SILVER_CACHE_HIT="true"))
        commands = self.commands()
        self.assert_built_and_tested(commands)
        self.assertTrue(all(cmd[0] in ("list", "exec") for cmd in commands),
                        commands)

    def test_rejects_invalid_restored_toolchain(self):
        self.cold_provision()
        for env in ({"SILVER_CACHE_KEY": "different-key"},
                    {"CI_TEST_PACKAGES": "dune 0.0"}):
            with self.subTest(env=env):
                self.log.unlink(missing_ok=True)
                result = self.invoke("provision", SILVER_CACHE_HIT="true", **env)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.source / "_build").exists())
                if self.log.exists():
                    self.assertTrue(all(cmd[0] in ("list", "exec")
                                        for cmd in self.commands()))

    def test_provision_failure_does_not_publish_success_marker(self):
        result = self.invoke("provision", CI_TEST_FAIL_INSTALL="true")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.state / "ci-cache-key").exists())
        self.assertFalse((self.source / "_build").exists())

    def test_existing_build_products_are_rejected_even_on_hit(self):
        self.cold_provision()
        (self.source / "_build").mkdir()
        result = self.invoke("test", SILVER_CACHE_HIT="true")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("clean checkout", result.stderr)

    def test_workflow_key_tracks_dependencies_but_not_silver_source(self):
        # Execute the actual workflow setup shell block with Docker replaced by
        # an inert stand-in. The only Docker output consumed by the key is the
        # installed host-package inventory.
        setup = next(step for step in workflow_steps() if "id: setup" in step)
        script = setup.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in script.splitlines())
        docker = Path(self.env["PATH"].split(":")[0]) / "docker"
        docker.write_text("""#!/bin/sh
if [ "$3" = dpkg-query ]; then
    echo "$CI_TEST_HOST_PACKAGES"
fi
""")
        docker.chmod(0o755)
        output = self.root / "output"
        runner = self.root / "runner"
        runner.mkdir()

        def key(**changes):
            output.write_text("")
            env = dict(self.env, RUNNER_TEMP=str(runner), GITHUB_OUTPUT=str(output),
                       UBUNTU_IMAGE="ubuntu:pinned", PLATFORM="linux/amd64",
                       CI_TEST_HOST_PACKAGES="libgmp 1")
            result = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", script],
                                    cwd=self.source, env=dict(env, **changes),
                                    text=True, capture_output=True, timeout=10)
            self.assert_success(result)
            shutil.rmtree(runner / "silver-ci-data")
            return output.read_text()

        baseline = key()
        self.assertRegex(baseline, r"^key=silver-native-.*[0-9a-f]{64}\n$")
        (self.source / "changed.ml").write_text("let changed = true\n")
        self.assertEqual(baseline, key())
        self.assertNotEqual(baseline, key(CI_TEST_HOST_PACKAGES="libgmp 2"))
        self.assertNotEqual(baseline, key(UBUNTU_IMAGE="ubuntu:other"))
        self.assertNotEqual(baseline, key(PLATFORM="linux/arm64"))
        for name in ("silver.opam", "silver_provider.opam",
                     "scripts/release/toolchain.env", "scripts/release/host-deps.sh",
                     "scripts/release/managed-toolchain.sh",
                     "scripts/ci/check.sh", "scripts/ci/container.sh",
                     ".github/workflows/ci.yml"):
            with self.subTest(name=name):
                path = self.source / name
                previous = path.read_bytes()
                path.write_bytes(previous + b"\n# changed\n")
                self.assertNotEqual(baseline, key())
                path.write_bytes(previous)


def workflow_steps():
    """Split the workflow's step blocks without requiring a YAML dependency."""
    return re.split(r"(?m)^      - name: ", WORKFLOW.read_text())[1:]


class WorkflowTests(unittest.TestCase):
    def test_automatic_and_manual_triggers(self):
        # Match the small top-level trigger block without a YAML dependency.
        triggers = re.search(r"(?m)^on:\n((?: +[^\n]*\n)+)",
                             WORKFLOW.read_text()).group(1)
        self.assertEqual(re.findall(r"(?m)^  (\w+):", triggers),
                         ["pull_request", "push", "workflow_dispatch"])
        self.assertRegex(triggers, r"(?m)^  pull_request:\s*\n  push:")
        self.assertRegex(triggers,
                         r"(?m)^  push:\n    branches:\n      - oxcaml\n"
                         r"  workflow_dispatch:")
        self.assertRegex(triggers, r"(?m)^      cold:\n"
                         r"(?:        [^\n]*\n)*?        type: boolean\n"
                         r"        default: false$")

    def test_only_superseded_runs_of_the_same_pr_are_cancelled(self):
        workflow = WORKFLOW.read_text()
        concurrency = re.search(r"(?m)^concurrency:\n((?: +[^\n]*\n)+)",
                                workflow).group(1)
        # A PR uses its stable number; every push/manual invocation (including
        # reruns) uses its own unique group, so it cannot displace another run.
        self.assertIn(
            "  group: ${{ github.event_name == 'pull_request' && "
            "format('silver-native-pr-{0}', github.event.pull_request.number) || "
            "format('silver-native-run-{0}-{1}', github.run_id, github.run_attempt) }}",
            concurrency)
        self.assertIn(
            "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
            concurrency)

    def test_only_managed_state_is_cached_before_unconditional_source_tests(self):
        steps = workflow_steps()
        restore = next(i for i, s in enumerate(steps) if "uses: actions/cache/restore@" in s)
        provision = next(i for i, s in enumerate(steps)
                         if "bash scripts/ci/container.sh provision" in s)
        save = next(i for i, s in enumerate(steps) if "uses: actions/cache/save@" in s)
        test = next(i for i, s in enumerate(steps) if "bash scripts/ci/container.sh test" in s)
        self.assertLess(restore, provision)
        self.assertLess(provision, save)
        self.assertLess(save, test)
        self.assertFalse(re.search(r"(?m)^        if:", steps[test]))
        self.assertFalse(re.search(r"(?m)^        if:", steps[provision]))
        self.assertEqual(sum("uses: actions/cache" in step for step in steps), 2)
        for i in (restore, save):
            self.assertEqual(re.findall(r"(?m)^          path: (.+)$", steps[i]),
                             ["${{ runner.temp }}/silver-ci-data/silver"])
            self.assertEqual(re.findall(r"(?m)^          key: (.+)$", steps[i]),
                             ["${{ steps.setup.outputs.key }}"])
            self.assertNotIn("restore-keys:", steps[i])
        # All normal runs may restore the exact cache. Cold dispatches bypass
        # both cache actions; only non-PR oxcaml runs may publish a miss.
        self.assertEqual(re.findall(r"(?m)^        if: (.+)$", steps[restore]),
                         ["${{ !(github.event_name == 'workflow_dispatch' && inputs.cold) }}"])
        self.assertEqual(re.findall(r"(?m)^        if: (.+)$", steps[save]),
                         ["${{ github.event_name != 'pull_request' && "
                          "github.ref == 'refs/heads/oxcaml' && "
                          "!(github.event_name == 'workflow_dispatch' && inputs.cold) && "
                          "steps.restore.outputs.cache-hit != 'true' }}"])


if __name__ == "__main__":
    unittest.main()
