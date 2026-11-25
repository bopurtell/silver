"""Parent-coordinated tests: python3 -B -m unittest discover -s scripts -p test_isolated_example.py

Uses disposable temporary task trees only. Does not run Dune, providers or Git.
"""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import isolated_example as example


class IsolatedExampleTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / 'task'
        self.root.mkdir()
        (self.root / 'dune-project').write_text('(lang dune 3.17)\n')
        self.provider = self.base / 'provider'
        self.provider.write_text('#!/bin/sh\nexit 99\n')
        self.provider.chmod(0o700)
        self.tools = self.base / 'tools'
        self.tools.mkdir()
        self.env = self.base / 'env.json'
        self.env.write_text(json.dumps({'PATH': '/usr/bin:/bin',
                                        'OPAM_SWITCH_PREFIX': '/shared/switch', 'OCAMLPATH': ''}))
        self.args = argparse.Namespace(project_root=self.root, provider_executable=self.provider,
                                       env_file=self.env, rewrite=False, clone_from=None,
                                       revision=None, toolchain=self.tools, python=None,
                                       support_tools=None, pdk_root=None, simulation_provider=None)

    def setup(self):
        with contextlib.redirect_stdout(io.StringIO()):
            example.setup(self.args)

    def rewrite(self):
        self.args.rewrite = True
        self.setup()
        self.args.rewrite = False
        self.args.toolchain = None

    def configs(self):
        return {name: example.read_config(self.root, name) for name in example.FIELDS}

    def write_config(self, name, config):
        (self.root / name).write_text(example.sexp([[k, v] for k, v in config.items()]) + '\n')

    def test_rewrite_and_readonly_audit_roundtrip(self):
        self.rewrite()
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.setup()
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        self.assertEqual(self.provider, Path(self.configs()[example.ASIC]['provider_executable']))
        self.assertEqual(0o600, (self.root / example.STATE / 'environment.json').stat().st_mode & 0o777)

    def test_owner_results_fail_closed_then_explicit_rewrite_preserves_original(self):
        self.rewrite()
        config = self.configs()[example.ASIC]
        config['results_root'] = str(example.OWNER / '.dev/results')
        self.write_config(example.ASIC, config)
        original = (self.root / example.ASIC).read_bytes()
        with self.assertRaisesRegex(example.SetupError, 'escapes task'):
            self.setup()
        self.assertEqual(original, (self.root / example.ASIC).read_bytes())
        self.args.rewrite = True
        self.setup()
        self.assertEqual(original, (self.root / example.STATE / (example.ASIC + '.original')).read_bytes())

    def test_rewrite_preserves_current_project_target_and_relocates_executable(self):
        self.rewrite()
        prep = self.configs()[example.PREPARATION]
        prep['build_target'] = 'asics/fifo_demo/cli/project.exe'
        self.write_config(example.PREPARATION, prep)
        self.args.rewrite = True
        self.setup()
        configs = self.configs()
        self.assertEqual(prep['build_target'], configs[example.PREPARATION]['build_target'])
        self.assertEqual(str(self.root / '_build/default' / prep['build_target']),
                         configs[example.ASIC]['project_executable'])

    def test_common_only_configs_rewritten_in_place(self):
        self.rewrite()
        common = self.root / '.silver'
        common.mkdir()
        for name in (example.ASIC, example.PREPARATION):
            (self.root / name).rename(common / name)
        prep = self.configs()[example.PREPARATION]
        prep['build_target'] = 'asics/fifo_demo/cli/project.exe'
        (common / example.PREPARATION).write_text(example.sexp(list(map(list, prep.items()))))
        self.args.rewrite = True
        self.setup()
        self.assertEqual(prep['build_target'], self.configs()[example.PREPARATION]['build_target'])
        self.assertFalse((self.root / example.ASIC).exists())
        example.audit_for_launch(self.root, self.provider, example.environment(self.env))

    def test_identical_common_and_legacy_configs_stay_identical_after_rewrite(self):
        self.rewrite()
        common = self.root / '.silver'
        common.mkdir()
        for name in (example.ASIC, example.PREPARATION):
            (common / name).write_bytes((self.root / name).read_bytes())
        self.provider = self.tools / 'new-provider'
        self.provider.write_text('#!/bin/sh\nexit 99\n')
        self.provider.chmod(0o700)
        self.args.provider_executable = self.provider
        self.args.rewrite = True
        self.setup()
        for name in (example.ASIC, example.PREPARATION):
            self.assertEqual((common / name).read_bytes(), (self.root / name).read_bytes())
        self.assertEqual(str(self.provider), self.configs()[example.ASIC]['provider_executable'])

    def test_conflicting_locations_rejected_before_rewrite(self):
        self.rewrite()
        common = self.root / '.silver'
        common.mkdir()
        legacy = self.root / example.ASIC
        before = legacy.read_bytes()
        (common / example.ASIC).write_bytes(before + b'\n')
        self.args.rewrite = True
        with self.assertRaisesRegex(example.SetupError, 'Conflicting configuration files'):
            self.setup()
        self.assertEqual(before, legacy.read_bytes())

    def test_common_config_symlinks_rejected_by_reader(self):
        common = self.root / '.silver'
        common.mkdir()
        (common / example.ASIC).symlink_to(self.base / 'missing')
        with self.assertRaisesRegex(example.SetupError, 'Symlink'):
            example.read_config(self.root, example.ASIC)

    def test_rewrite_rejects_unsafe_project_targets_before_writing(self):
        self.rewrite()
        for target in ('/owner/project.exe', '../project.exe', '-bad.exe',
                       '_build/default/project.exe', 'a/@bad.exe'):
            with self.subTest(target=target):
                prep = self.configs()[example.PREPARATION]
                prep['build_target'] = target
                self.write_config(example.PREPARATION, prep)
                before = (self.root / example.ASIC).read_bytes()
                self.args.rewrite = True
                with self.assertRaisesRegex(example.SetupError, 'Unsafe preparation build_target'):
                    self.setup()
                self.assertEqual(before, (self.root / example.ASIC).read_bytes())

    def test_owner_project_executable_is_rejected(self):
        self.rewrite()
        config = self.configs()[example.ASIC]
        config['project_executable'] = str(example.OWNER / '_build/default/bin/project.exe')
        self.write_config(example.ASIC, config)
        with self.assertRaisesRegex(example.SetupError, 'escapes task'):
            self.setup()

    def test_config_and_build_symlinks_never_rewritten(self):
        self.rewrite()
        outside = self.base / 'outside'
        outside.write_text('unchanged')
        for name in (example.ASIC, '_build'):
            path = self.root / name
            if path.exists():
                path.unlink()
            path.symlink_to(outside)
            with self.assertRaisesRegex(example.SetupError, 'Symlink'):
                self.setup()
            path.unlink()
        self.assertEqual('unchanged', outside.read_text())

    def test_hardlinked_outputs_rejected(self):
        output = self.base / 'owner-output'
        output.write_text('owner')
        os.link(output, self.root / 'output-copy')
        with self.assertRaisesRegex(example.SetupError, 'Hardlinked'):
            example.audit_tree(self.root)

    def test_regular_copied_build_outputs_need_task_receipt(self):
        build = self.root / '_build/default/bin'
        build.mkdir(parents=True)
        (build / 'project.exe').write_text('copied owner binary')
        self.args.rewrite = True
        with self.assertRaisesRegex(example.SetupError, 'Unproven copied outputs'):
            self.setup()
        self.assertFalse((self.root / example.ASIC).exists())

    def test_receipt_from_another_copy_rejected(self):
        self.rewrite()
        receipt = self.root / example.STATE / 'setup.json'
        data = json.loads(receipt.read_text())
        data['project_root'] = str(example.OWNER)
        receipt.write_text(json.dumps(data))
        with self.assertRaisesRegex(example.SetupError, 'another copy'):
            self.setup()

    def test_proven_build_generated_symlinks_allowed(self):
        self.rewrite()
        build = self.root / '_build/default'
        build.mkdir(parents=True)
        (build / 'generated').symlink_to(self.root / 'dune-project')
        self.setup()
        receipt = example.audit_for_launch(self.root, self.provider, example.environment(self.env))
        self.assertEqual(str(self.root), receipt['project_root'])

    def test_proven_build_root_symlink_still_rejected(self):
        self.rewrite()
        (self.root / '_build').symlink_to(self.tools, target_is_directory=True)
        with self.assertRaisesRegex(example.SetupError, 'Symlink'):
            example.audit_for_launch(self.root, self.provider, example.environment(self.env))

    def test_launch_requires_receipt_even_with_safe_configs(self):
        self.rewrite()
        (self.root / example.STATE / 'setup.json').unlink()
        with self.assertRaisesRegex(example.SetupError, 'Missing setup receipt'):
            example.audit_for_launch(self.root, self.provider, example.environment(self.env))

    def test_launch_rejects_provider_bytes_drift(self):
        self.rewrite()
        self.provider.write_text('changed provider bytes')
        with self.assertRaisesRegex(example.SetupError, 'provider hash drift'):
            example.audit_for_launch(self.root, self.provider, example.environment(self.env))

    def test_launch_rejects_environment_drift_before_overlays(self):
        self.rewrite()
        env = example.environment(self.env)
        for key, value in (('PATH', '/different/bin'), ('OPAM_SWITCH_PREFIX', '/other/switch'),
                           ('OCAMLPATH', '/other/lib'), ('TERM', 'xterm')):
            with self.subTest(key=key):
                with self.assertRaisesRegex(example.SetupError, 'environment hash drift'):
                    example.audit_for_launch(self.root, self.provider, {**env, key: value})

    def test_launch_rejects_provider_path_drift_in_receipt(self):
        self.rewrite()
        path = self.root / example.STATE / 'setup.json'
        receipt = json.loads(path.read_text())
        receipt['provider_executable'] = '/different/provider'
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(example.SetupError, 'provider path drift'):
            example.audit_for_launch(self.root, self.provider, example.environment(self.env))

    def test_simulation_requires_explicit_local_provider(self):
        self.rewrite()
        self.write_config(example.SIMULATION, {
            'schema_version': '1', 'provider_executable': str(example.OWNER / 'simulation.exe'),
            'provider_args': [], 'discovery_timeout_seconds': '10', 'run_timeout_seconds': '120'})
        self.args.rewrite = True
        with self.assertRaisesRegex(example.SetupError, '--simulation-provider'):
            self.setup()
        self.args.simulation_provider = self.root / '_build/default/simulation/provider.exe'
        self.setup()
        self.assertEqual(str(self.args.simulation_provider),
                         self.configs()[example.SIMULATION]['provider_executable'])

    def test_provider_mismatch_rejected(self):
        self.rewrite()
        config = self.configs()[example.ASIC]
        config['provider_executable'] = '/different/provider'
        self.write_config(example.ASIC, config)
        with self.assertRaisesRegex(example.SetupError, 'exactly match'):
            self.setup()

    def test_unknown_duplicate_and_commented_fields_rejected(self):
        for text in ('((schema_version 1) (evil /owner))',
                     '((schema_version 1) (schema_version 1))',
                     '; comment\n((schema_version 1))'):
            (self.root / example.ASIC).write_text(text)
            with self.assertRaises(example.SetupError):
                example.read_config(self.root, example.ASIC)

    def test_environment_is_complete_and_has_no_build_redirects(self):
        env = json.loads(self.env.read_text())
        for alteration in ({'DUNE_BUILD_DIR': str(example.OWNER / '_build')},
                           {'PATH': '/usr/bin:'}, {'DUNE_CACHE': 'enabled'}):
            self.env.write_text(json.dumps({**env, **alteration}))
            with self.assertRaises(example.SetupError):
                example.environment(self.env)
        del env['OCAMLPATH']
        self.env.write_text(json.dumps(env))
        with self.assertRaisesRegex(example.SetupError, 'OCAMLPATH'):
            example.environment(self.env)

    def test_protected_roots_and_parent_traversal_rejected(self):
        for root in (*example.PROTECTED, example.REPO, example.OWNER.parent,
                     self.root / 'child/../output'):
            with self.assertRaises(example.SetupError):
                example.task_root(root)

    def test_clone_uses_committed_revision_no_hardlinks_and_detached_checkout(self):
        source = self.base / 'source'
        source.mkdir()
        self.args.clone_from = source
        self.args.revision = 'HEAD'
        commit = 'a' * 40
        destination = self.base / 'new-copy'
        with patch.object(example, 'git', side_effect=[commit, ' M dirty.ml', '', '']) as git:
            with contextlib.redirect_stdout(io.StringIO()) as output:
                receipt = example.clone(self.args, destination)
        self.assertTrue(receipt['source_dirty'])
        self.assertIn('NOT copied', output.getvalue())
        calls = [call.args[0] for call in git.call_args_list]
        self.assertEqual(['clone', '--no-hardlinks', '--no-checkout', '--',
                          str(source), str(destination)], calls[2])
        self.assertEqual(['-C', str(destination), 'checkout', '--detach', commit], calls[3])


if __name__ == '__main__':
    unittest.main()
