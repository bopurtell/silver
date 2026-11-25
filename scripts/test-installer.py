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
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['LOG'], 'a') as log:
    print(json.dumps(args), file=log)
with open(os.environ['LOG'] + '.env', 'a') as log:
    print(json.dumps(dict(os.environ)), file=log)
if args[:1] == ['init']:
    root = Path(os.environ['OPAMROOT'])
    root.mkdir()
    (root / 'config').touch()
elif args[:2] == ['repository', 'add']:
    pass
elif args == ['switch', 'list', '--short']:
    if (Path(os.environ['OPAMROOT']) / 'silver').exists():
        print('silver')
elif args[:2] == ['switch', 'create']:
    (Path(os.environ['OPAMROOT']) / 'silver').mkdir()
elif args[:2] == ['pin', 'add']:
    pass
elif args[:1] == ['install']:
    if os.environ.get('DEPS_FAIL'):
        sys.exit(1)
elif args[:1] == ['exec'] and args[2:3] == ['--']:
    if args[3] == 'ocamlc' and args[1] == '--switch=missing':
        sys.exit(1)
    if args[3:5] == ['dune', 'build'] and os.environ.get('BUILD_FAIL'):
        sys.exit(1)
else:
    sys.exit(2)
"""
FAKE_CURL = """#!/usr/bin/env python3
import io, json, os, sys, tarfile
args = sys.argv[1:]
with open(os.environ['LOG'] + '.curl', 'a') as log:
    print(json.dumps(args), file=log)
with tarfile.open(args[args.index('-o')+1], 'w:gz') as archive:
    data = b'opam-version: "2.0"'
    info = tarfile.TarInfo('repo/repo')
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))
"""
FAKE_GIT = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['LOG'] + '.git', 'a') as log:
    print(json.dumps(sys.argv[1:]), file=log)
"""


class InstallerTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        for name, script in (("opam", FAKE_OPAM), ("curl", FAKE_CURL), ("git", FAKE_GIT)):
            executable = self.root / name
            executable.write_text(script)
            executable.chmod(0o755)
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
        state = self.root / ".local/share/silver"
        self.assertEqual(commands[0], ["init", "--bare", "--no-setup", "--no-opamrc",
                                       "--yes", "default", str(state / "default")])
        create = next(cmd for cmd in commands if cmd[:2] == ["switch", "create"])
        self.assertIn("--no-switch", create)
        self.assertIn("--repos=ox,default", create)
        self.assertIn("silver", create)
        pins = dict(line.split("=", 1) for line in
                    (INSTALLER.parent / "scripts/release/toolchain.env").read_text().splitlines()
                    if line and not line.startswith("#"))
        self.assertIn(f"--packages=ocaml-variants.5.2.0+ox,oxcaml-compiler.{pins['SILVER_OXCAML']}", create)
        curl = Path(str(self.log) + ".curl").read_text()
        self.assertIn(pins["SILVER_OPAM_REPOSITORY"], curl)
        self.assertIn(pins["SILVER_OX_REPOSITORY"], curl)
        git = Path(str(self.log) + ".git").read_text()
        self.assertIn(pins["SILVER_COBALT_COMMIT"], git)
        for package, version in (("dune", pins["SILVER_DUNE"]),
                                 ("bonsai", pins["SILVER_JANE"]),
                                 ("hardcaml", pins["SILVER_JANE"])):
            self.assertIn(["pin", "add", "--switch=silver", "--yes", "--no-action",
                           "--kind=version", package, version], commands)
        for cmd in commands[-4:]:
            self.assertEqual(cmd[:3], ["exec", "--switch=silver", "--"])
        self.assertIn("hardcaml_workbench_provider,hardcaml_workbench", commands[-2])
        self.assertIn("@install", commands[-2])
        self.assertEqual(commands[-1][-4:], ["--prefix", str(self.root / ".local"),
                                             "hardcaml_workbench_provider", "hardcaml_workbench"])
        for option in ("--libdir", "--libexecdir"):
            self.assertEqual(commands[-1][commands[-1].index(option) + 1],
                             str(state / "sdk/lib"))
        self.assertIn("export PATH=", r.stdout)
        self.assertIn("/bin/ag", r.stdout)
        self.assertIn(f"Compatible ASIC provider: {self.provider}", r.stdout)

    def test_managed_ignores_activated_switch_and_reuses_toolchain(self):
        user_root = self.root / "user opam"
        user_root.mkdir()
        sentinel = user_root / "config"
        sentinel.write_text("user's existing opam configuration")
        bin_dir = user_root / "active/bin"
        bin_dir.mkdir(parents=True)
        state = self.root / "custom data/silver"
        self.env.update(XDG_DATA_HOME=str(state.parent), OPAMROOT=str(user_root),
                        OPAMSWITCH="active", OPAM_SWITCH_PREFIX=str(bin_dir.parent),
                        OPAM_LAST_ENV="old", OPAMYES="false", OCAMLPATH="/previous/lib",
                        CAML_LD_LIBRARY_PATH="/previous/stublibs", OCAMLFIND_CONF="/previous/conf",
                        DUNE_WORKSPACE="/previous/workspace", DUNE_BUILD_DIR="/previous/build",
                        DUNE_CACHE="enabled", DESTDIR="/previous/dest",
                        PATH=f"{bin_dir}:{self.env['PATH']}")
        result = self.invoke("--without-asic")
        self.assertEqual(result.returncode, 0, result.stderr)
        for line in Path(str(self.log) + ".env").read_text().splitlines():
            env = json.loads(line)
            self.assertEqual(env["OPAMROOT"], str(state / "opam"))
            for variable in ("OPAMSWITCH", "OPAM_SWITCH_PREFIX", "OPAM_LAST_ENV", "OPAMYES",
                             "OCAMLPATH", "CAML_LD_LIBRARY_PATH", "OCAMLFIND_CONF", "DUNE_WORKSPACE"):
                self.assertNotIn(variable, env)
            self.assertEqual(env["DUNE_CACHE"], "disabled")
            self.assertNotIn("DESTDIR", env)
            self.assertEqual(env["XDG_CACHE_HOME"], str(state / "cache"))
            self.assertNotIn(str(bin_dir), env["PATH"])
        envs = [json.loads(line) for line in Path(str(self.log) + ".env").read_text().splitlines()]
        for command, env in zip(self.commands(), envs):
            if command[0] == "exec":
                self.assertIn(env.get("DUNE_BUILD_DIR"), (None, "_build_silver_managed"))
            else:
                self.assertNotIn("DUNE_BUILD_DIR", env)
        self.assertEqual(sentinel.read_text(), "user's existing opam configuration")
        self.assertNotIn("DESTDIR", json.loads(Path(str(self.log) + ".env").read_text().splitlines()[-1]))
        self.log.unlink()
        self.assertEqual(self.invoke("--without-asic").returncode, 0)
        self.assertFalse(any(cmd[0] == "init" or cmd[:2] == ["switch", "create"]
                             for cmd in self.commands()))
        self.assertEqual(len(Path(str(self.log) + ".curl").read_text().splitlines()), 2)
        self.assertEqual(len(Path(str(self.log) + ".git").read_text().splitlines()), 3)

    def test_managed_refuses_to_adopt_user_root(self):
        state = self.root / ".local/share/silver/opam"
        state.mkdir(parents=True)
        result = self.invoke("--without-asic")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to take ownership", result.stderr)
        self.assertFalse(self.log.exists())

    def test_pin_drift_refuses_to_mutate_existing_managed_root(self):
        self.assertEqual(self.invoke("--without-asic").returncode, 0)
        state = self.root / ".local/share/silver"
        marker = state / "toolchain.env"
        old_pins = "\n".join("SILVER_DUNE=3.0.0" if line.startswith("SILVER_DUNE=") else line
                             for line in marker.read_text().splitlines()) + "\n"
        marker.write_text(old_pins)
        self.log.unlink()
        result = self.invoke("--without-asic")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"move {state} aside", result.stderr)
        self.assertEqual(marker.read_text(), old_pins)
        self.assertTrue((state / "opam/config").exists())
        self.assertFalse(self.log.exists())

    def test_managed_preserves_preexisting_public_sdk(self):
        sdk = self.root / ".local/lib/hardcaml_workbench_provider"
        sdk.mkdir(parents=True)
        (sdk / "META").write_text("existing developer SDK")
        result = self.invoke("--without-asic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("untouched", result.stderr)
        self.assertEqual((sdk / "META").read_text(), "existing developer SDK")
        self.assertNotIn(str(sdk.parent), self.commands()[-1])

    def test_failed_managed_dependencies_never_build(self):
        self.env["DEPS_FAIL"] = "1"
        result = self.invoke("--without-asic")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(cmd[0] == "exec" for cmd in self.commands()))

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
        self.env.update(OPAM_SWITCH="env-switch", SILVER_PREFIX="env prefix",
                        OCAMLPATH="/local/cobalt/build/lib")
        self.assertEqual(self.invoke().returncode, 0)
        self.assertIn("--switch=env-switch", self.commands()[-1])
        self.assertIn(str(self.root / "env prefix"), self.commands()[-1])
        self.assertTrue(all(cmd[0] == "exec" for cmd in self.commands()))
        self.assertNotIn("--libdir", self.commands()[-1])
        env = json.loads(Path(str(self.log) + ".env").read_text().splitlines()[-1])
        self.assertEqual(env["OCAMLPATH"], "/local/cobalt/build/lib")
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
        r = self.invoke("--switch", "developer")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--deps-only ./hardcaml_workbench_provider.opam", r.stderr)
        self.assertFalse(any("install" in cmd for cmd in self.commands()))

    def test_bad_option_before_build(self):
        for args in [("--jobs", "0"), ("--prefix",), ("--typo",)]:
            self.assertNotEqual(self.invoke(*args).returncode, 0)
        self.assertFalse(self.log.exists())

    def test_launcher_collision_rejected_before_build(self):
        bin_dir = self.root / ".local/bin"
        bin_dir.mkdir(parents=True)
        launcher = bin_dir / "ag"
        launcher.write_text("#!/bin/sh\nexit 12\n")
        launcher.chmod(0o755)
        result = self.invoke("--without-asic")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to overwrite", result.stderr)
        self.assertFalse(self.log.exists())
        self.assertEqual(launcher.read_text(), "#!/bin/sh\nexit 12\n")

    def test_old_launcher_removal_waits_for_successful_install(self):
        bin_dir = self.root / ".local/bin"
        bin_dir.mkdir(parents=True)
        old = bin_dir / "silver"
        legacy = bin_dir / "hardcaml-workbench"
        for launcher in (old, legacy):
            launcher.write_text("#!/bin/sh\n# launcher fixture\n")
            launcher.chmod(0o755)
        self.env["BUILD_FAIL"] = "1"
        self.assertNotEqual(self.invoke("--without-asic").returncode, 0)
        self.assertTrue(old.exists())
        del self.env["BUILD_FAIL"]
        result = self.invoke("--without-asic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old.exists())


if __name__ == "__main__":
    unittest.main()
