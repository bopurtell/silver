"""Exercise native init and relocated discovery without a hardware toolchain."""

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


BINARY = Path(sys.argv.pop(1)).resolve()
SIMULATION_SETUP = Path(sys.argv.pop(1)).resolve()
EXAMPLES = [Path(sys.argv.pop(1)).resolve() for _ in range(2)]
MANIFEST = Path(".silver/project.json")
SIMULATION = Path(".workbench/hardcaml-workbench-simulation.sexp")


class ScaffoldTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="silver-bluespec-init-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.tools = self.base / "tool bin"
        self.tools.mkdir()
        self.silver = self.tools / "silver"
        self.silver.symlink_to(BINARY)
        self.python = self.tools / "python3"
        self.python.write_text("#!/bin/sh\nexit 97\n")
        self.python.chmod(0o755)
        self.env = {
            "PATH": str(self.tools), "HOME": str(self.base), "LC_ALL": "C.UTF-8",
            "XDG_CONFIG_HOME": str(self.base / "config"),
            "XDG_STATE_HOME": str(self.base / "state"),
        }

    def invoke(self, *args, cwd=None, success=True):
        result = subprocess.run(
            ["silver", "init", *args], cwd=cwd or self.base, env=self.env,
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode == 0, success, result)
        return result

    def verify_project(self, root):
        self.assertEqual(json.loads((root / MANIFEST).read_text()), dict(
            schema_version=1, name=root.name, build_label="//:rtl", test_label="//:simulation",
        ))
        for example in EXAMPLES:
            self.assertEqual((root / example.name).read_bytes(), example.read_bytes())
        for required in (".bazelrc", ".gitignore", "BUILD.bazel", "MODULE.bazel",
                         "bench.cpp", "checker.rs", "simulation.bzl", "README.md"):
            self.assertTrue((root / required).is_file(), required)
        self.assertFalse((root / "dune-project").exists())
        self.assertFalse((root / "bazel-bin").exists())
        config = (root / SIMULATION).read_text()
        self.assertRegex(config, rf'\(provider_executable\s+"{re.escape(str(self.python))}"\)')
        self.assertRegex(config, r'\(provider_args\s+\(simulation_provider\.py\)\)')

    def test_new_relative_directory(self):
        root = self.base / "outer" / "quoted project"
        self.invoke("--bluespec", root.relative_to(self.base))
        self.verify_project(root)

    def test_default_current_directory_and_no_reinit(self):
        root = self.base / "cwd project"
        root.mkdir()
        (root / "unrelated.txt").write_text("keep me")
        self.invoke("--bluespec", cwd=root)
        self.verify_project(root)
        (root / "Counter.bs").write_text("my edits")
        manifest = (root / MANIFEST).read_bytes()
        self.assertIn("refusing to overwrite", self.invoke("--bluespec", cwd=root, success=False).stderr)
        self.assertEqual((root / "Counter.bs").read_text(), "my edits")
        self.assertEqual((root / "unrelated.txt").read_text(), "keep me")
        self.assertEqual((root / MANIFEST).read_bytes(), manifest)

    def test_shell_launcher_opens_nearest_silver_project(self):
        (self.base / "dune-project").write_text("(lang dune 3.22)\n")
        root = self.base / "classic"
        self.invoke("--bluespec", root)
        nested = root / "some" / "subdir"
        nested.mkdir(parents=True)
        result = subprocess.run(
            ["silver", "--plain", "--standalone-state-dir", self.base / "state"],
            cwd=nested, env=self.env, text=True, capture_output=True, timeout=25,
        )
        self.assertEqual(result.returncode, 0, result)
        self.assertIn(f"root={root}\n", result.stdout)
        self.assertIn(".silver/project.json", result.stderr)

    def test_relocated_project_discovers_its_local_provider(self):
        self.python.unlink()
        self.python.symlink_to(sys.executable)
        original = self.base / "original project"
        self.invoke("--bluespec", original)
        moved = original.rename(self.base / "relocated project")
        self.assertFalse(original.exists())
        for path in moved.rglob("*"):
            if path.is_file():
                self.assertNotIn(str(original).encode(), path.read_bytes(), path)

        nested = moved / "subdir"
        nested.mkdir()
        result = subprocess.run(
            [SIMULATION_SETUP, "check", "--discover-project"],
            cwd=nested, env=self.env, text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result)
        self.assertIn("simulation_provider.py discover --protocol-version 1", result.stdout)
        self.assertIn(f"Working directory: {moved}\n", result.stdout)
        self.assertIn("suite bluespec-classic", result.stdout)
        self.assertIn("case counter-smoke", result.stdout)

    def test_conflicts_do_not_publish_earlier_files_or_follow_symlinks(self):
        root = self.base / "conflict"
        root.mkdir()
        build = root / "BUILD.bazel"
        build.symlink_to(self.base / "nonexistent")
        self.assertIn(str(build), self.invoke("--bluespec", root, success=False).stderr)
        self.assertEqual(list(root.iterdir()), [build])
        build.unlink()

        other = self.base / "configuration"
        other.mkdir()
        (root / ".workbench").symlink_to(other, target_is_directory=True)
        self.invoke("--bluespec", root, success=False)
        self.assertEqual(list(root.iterdir()), [root / ".workbench"])
        self.assertEqual(list(other.iterdir()), [])

    def test_missing_python_and_bad_usage_do_not_create_project(self):
        root = self.base / "project"
        self.python.unlink()
        self.assertIn("Python 3 is required", self.invoke("--bluespec", root, success=False).stderr)
        self.assertIn("--bluespec", self.invoke(root, success=False).stderr)
        self.assertIn("--bluespec", self.invoke("--help").stdout)
        self.assertFalse(root.exists())


if __name__ == "__main__":
    unittest.main()
