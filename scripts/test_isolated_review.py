"""Private-process launcher fixtures; no installed daemon/provider is executed."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

import isolated_example as setup
import isolated_review as review
from isolated_review_dune import single_job


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / 'workbench'
        self.build = self.repo / '_build/default'
        self.build.mkdir(parents=True)
        (self.repo / 'scripts').mkdir()
        shutil.copyfile(review.REPO / 'scripts/isolated_review_dune.py',
                        self.repo / 'scripts/isolated_review_dune.py')
        self.root = self.base / 'example'
        self.root.mkdir()
        (self.root / 'dune-project').write_text('(lang dune 3.22)')
        self.tools = self.base / 'tools'
        self.tools.mkdir()
        self.program(self.tools / 'dune', 'print("3.22.0")')
        self.program(self.tools / 'ocamlfind',
                     'import sys\nprint("/fixture/lib/" + sys.argv[-1])\n'
                     'sys.exit(1 if sys.argv[-1] == "missing_wb052" else 0)')
        self.provider = self.tools / 'provider'
        self.program(self.provider, 'raise RuntimeError("provider must not run")')
        self.env = self.base / 'env.json'
        self.env.write_text(json.dumps({'PATH': str(self.tools) + ':/usr/bin:/bin',
                                       'OPAM_SWITCH_PREFIX': str(self.tools), 'OCAMLPATH': ''}))
        with contextlib.redirect_stdout(io.StringIO()):
            setup.setup(setup.parser().parse_args([
                '--project-root', str(self.root), '--provider-executable', str(self.provider),
                '--env-file', str(self.env), '--rewrite', '--toolchain', str(self.tools)]))
        self.daemon = self.build / 'daemon'
        self.program(self.daemon, '''import os, pathlib, sys, time
discovery = pathlib.Path(sys.argv[sys.argv.index('--discovery-dir') + 1])
(discovery / 'daemon.sexp').write_text(
    f'((endpoint http://127.0.0.1:31234)(pid {os.getpid()})(instance_id fixture))')
time.sleep(60)
''')
        self.client = self.build / 'client'
        self.program(self.client, '''import os, pathlib, sys
assert sys.argv[sys.argv.index('--connect') + 1] == 'http://127.0.0.1:31234'
assert sys.argv[sys.argv.index('--environment') + 1] == 'inherited'
assert pathlib.Path(os.environ['XDG_STATE_HOME']).name == 'preferences'
assert pathlib.Path(os.environ['XDG_RUNTIME_DIR']).name == 'runtime'
assert pathlib.Path(sys.argv[0]).parent.name == 'bin'
''')
        self.args = review.parser().parse_args([
            '--project-root', str(self.root), '--provider-executable', str(self.provider),
            '--env-file', str(self.env), '--daemon', str(self.daemon),
            '--client', str(self.client), '--session-parent', str(self.base / 'sessions'),
            '--plain', '--startup-timeout', '0.5'])

    def program(self, path, source):
        path.write_text('#!' + sys.executable + '\n' + source + '\n')
        path.chmod(0o700)

    def launch(self):
        with patch.object(review, 'REPO', self.repo), contextlib.redirect_stdout(io.StringIO()):
            return review.launch(self.args)

    def receipt(self):
        return json.loads(next((self.base / 'sessions').glob('*/launch.json')).read_text())

    def test_endpoint_identity_preferences_and_owned_cleanup(self):
        self.assertEqual(0, self.launch())
        receipt = self.receipt()
        self.assertEqual('completed', receipt['status'])
        self.assertEqual(review.digest(self.client), receipt['binaries']['client']['sha256'])
        with self.assertRaises(ProcessLookupError):
            os.kill(receipt['daemon_pid'], 0)
        self.assertEqual(0o700, Path(receipt['session']).stat().st_mode & 0o777)

    def test_check_has_no_session_or_process(self):
        self.args.check = True
        with patch.object(review.subprocess, 'Popen', wraps=review.subprocess.Popen) as popen:
            self.assertEqual(0, self.launch())
            self.assertTrue(all('daemon' not in str(c.args[0][0]) for c in popen.call_args_list))
        self.assertFalse((self.base / 'sessions').exists())

    def test_check_uses_common_config_location(self):
        common = self.root / '.silver'
        common.mkdir()
        for name in (setup.ASIC, setup.PREPARATION):
            (self.root / name).rename(common / name)
        self.args.check = True
        self.assertEqual(0, self.launch())
        self.assertFalse((self.base / 'sessions').exists())

    def test_missing_library_actionable_and_no_start(self):
        self.args.require_library = ['missing_wb052']
        with self.assertRaisesRegex(review.LaunchError, 'missing libraries') as error:
            self.launch()
        self.assertIn('OCAMLPATH=', str(error.exception))
        self.assertIn('existing provider executable alone', str(error.exception))
        self.assertFalse((self.base / 'sessions').exists())

    def test_wrong_pid_readiness_times_out_and_cleanup(self):
        self.program(self.daemon, '''import pathlib, sys, time
discovery = pathlib.Path(sys.argv[sys.argv.index('--discovery-dir') + 1])
(discovery / 'daemon.sexp').write_text(
    '((endpoint http://127.0.0.1:31234)(pid 1)(instance_id wrong))')
time.sleep(60)
''')
        with self.assertRaisesRegex(review.LaunchError, 'timed out'):
            self.launch()
        self.assertEqual('failed', self.receipt()['status'])

    def test_early_daemon_exit(self):
        self.program(self.daemon, 'raise SystemExit(7)')
        with self.assertRaisesRegex(review.LaunchError, 'exited with status 7'):
            self.launch()

    def test_interrupt_cleans_up_only_spawned_daemon(self):
        owned = []

        def interrupt(process, discovery, timeout):
            owned.append(process)
            raise KeyboardInterrupt

        with patch.object(review, 'await_endpoint', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.launch()
        self.assertIsNotNone(owned[0].poll())
        self.assertEqual('interrupted', self.receipt()['status'])

    def test_client_failure_propagates(self):
        self.program(self.client, 'raise SystemExit(9)')
        self.assertEqual(9, self.launch())
        self.assertEqual(9, self.receipt()['client_exit_code'])

    def test_binary_from_other_worktree_rejected(self):
        self.args.client = self.provider
        with self.assertRaisesRegex(review.LaunchError, 'this worktree'):
            self.launch()

    def test_job_limit_preserves_exec_arguments(self):
        self.assertEqual(['exec', '-j', '1', 'app', '--', '-j20'],
                         single_job(['exec', '--jobs=20', 'app', '--', '-j20']))
        self.assertEqual(['build', '-j', '1', '@all'], single_job(['build', '-j20', '@all']))
        self.assertEqual(['build', '-j', '1', '@all'], single_job(['build', '-j', '20', '@all']))


if __name__ == '__main__':
    unittest.main()
