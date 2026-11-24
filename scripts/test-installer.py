"""Run with python3 scripts/test-installer.py. Never uses a real switch or home."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
FAKE_OPAM = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['LOG'], 'a') as log:
    print(json.dumps(args), file=log)
if args == ['switch', 'show']:
    print('selected')
elif args[:1] == ['exec'] and args[2:3] == ['--']:
    if args[3] == 'ocamlc' and args[1] == '--switch=missing':
        sys.exit(1)
    if args[3:5] == ['dune', 'build'] and os.environ.get('BUILD_FAIL'):
        sys.exit(1)
else:
    sys.exit(2)
"""


class InstallerTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        opam = self.root / "opam"
        opam.write_text(FAKE_OPAM)
        opam.chmod(0o755)
        self.log = self.root / "commands"
        self.env = dict(PATH=f"{self.root}:{os.defpath}", HOME=str(self.root),
                        LOG=str(self.log))
        self.provider = self.root / "hardcaml_asic"
        self.provider.write_text("""#!/bin/sh
[ "$#" = 2 ] && [ "$1" = --version ] && [ "$2" = --json ] || exit 1
echo '{"cli_contract":{"version":4,"capabilities":{"namedflow1":true}}}'
""")
        self.provider.chmod(0o755)

    def invoke(self, *args):
        return subprocess.run([INSTALLER, *args], cwd=self.root, env=self.env,
                              text=True, capture_output=True)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_defaults(self):
        r = self.invoke()
        self.assertEqual(r.returncode, 0, r.stderr)
        commands = self.commands()
        self.assertEqual(commands[0], ["switch", "show"])
        for cmd in commands[1:]:
            self.assertEqual(cmd[:3], ["exec", "--switch=selected", "--"])
        self.assertIn("hardcaml_workbench_provider,hardcaml_workbench", commands[-2])
        self.assertIn("@install", commands[-2])
        self.assertEqual(commands[-1][-4:], ["--prefix", str(self.root / ".local"),
                                             "hardcaml_workbench_provider", "hardcaml_workbench"])
        self.assertIn("export PATH=", r.stdout)
        self.assertIn(f"Compatible ASIC provider: {self.provider}", r.stdout)

    def test_incompatible_cli_and_generic_mode(self):
        self.provider.write_text(self.provider.read_text().replace("true", "false"))
        r = self.invoke()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("CLI4 + namedflow1=true", r.stderr)
        self.assertFalse(self.log.exists())
        self.provider.unlink()
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.invoke("--without-asic").returncode, 0)

    def test_override_precedence(self):
        self.env["SILVER_ASIC_PROVIDER"] = str(self.root / "missing")
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertNotEqual(self.invoke("--asic-provider", "hardcaml_asic").returncode, 0)
        self.assertFalse(self.log.exists())
        pin = self.provider.rename(self.root / "provider v1")
        r = self.invoke("--asic-provider", str(pin))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("export SILVER_ASIC_PROVIDER=", r.stdout)
        self.env["SILVER_ASIC_PROVIDER"] = str(pin)
        self.assertEqual(self.invoke().returncode, 0)

    def test_prefix_and_switch_precedence(self):
        self.env.update(OPAM_SWITCH="env-switch", SILVER_PREFIX="env prefix")
        self.assertEqual(self.invoke().returncode, 0)
        self.assertIn("--switch=env-switch", self.commands()[-1])
        self.assertIn(str(self.root / "env prefix"), self.commands()[-1])
        r = self.invoke("--switch", "chosen", "--prefix", "private prefix", "--jobs", "2")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--switch=chosen", self.commands()[-1])
        self.assertIn(str(self.root / "private prefix"), self.commands()[-1])
        self.assertIn("2", self.commands()[-2])

    def test_missing_switch(self):
        r = self.invoke("--switch", "missing")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("opam switch list", r.stderr)
        self.assertFalse(any("build" in cmd for cmd in self.commands()))

    def test_local_switch_is_relative_to_caller(self):
        r = self.invoke("--switch", "projects/local-switch")
        self.assertEqual(r.returncode, 0, r.stderr)
        for command in self.commands():
            self.assertIn(f"--switch={self.root / 'projects/local-switch'}", command)

    def test_build_jobs_precedence(self):
        self.env["HCW_BUILD_JOBS"] = "3"
        for silver_jobs, args, expected in [
            (None, (), "3"),
            ("5", (), "5"),
            ("5", ("--jobs", "2"), "2"),
        ]:
            if silver_jobs is not None:
                self.env["SILVER_BUILD_JOBS"] = silver_jobs
            r = self.invoke(*args)
            self.assertEqual(r.returncode, 0, r.stderr)
            for cmd in self.commands()[-2:]:
                self.assertEqual(cmd[cmd.index("-j") + 1], expected)

    def test_missing_dependency(self):
        self.env["BUILD_FAIL"] = "1"
        r = self.invoke()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--deps-only ./hardcaml_workbench_provider.opam", r.stderr)
        self.assertFalse(any("install" in cmd for cmd in self.commands()))

    def test_bad_option_before_build(self):
        for args in [("--jobs", "0"), ("--prefix",), ("--typo",)]:
            self.assertNotEqual(self.invoke(*args).returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
