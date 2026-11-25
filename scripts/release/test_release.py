"""Fast release tests; the workflow separately builds and tests real tarballs."""

import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import package


class PackagingTests(unittest.TestCase):
    def test_command_table_has_only_new_public_launcher(self):
        rows = package.command_table(package.REPO)
        self.assertIn(["ag", "hardcaml-workbench"], rows)
        self.assertNotIn("silver", [name for row in rows for name in row])

    def test_version_tag_and_asset_names(self):
        self.assertEqual(
            package.names("v0.12.3"),
            ("silver-v0.12.3-source", "silver-v0.12.3-linux-x86_64-ubuntu-26.04"),
        )
        for tag in ("v0.12", "v0.12.03", "0.12.3", "v0.12.3/..", "v0.12.3\n", "v0.12.3-rc.1"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                package.names(tag)

    def test_archive_has_reproducible_metadata_and_preserves_execute_bit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            release = root / "silver-v1.2.3-source"
            release.mkdir()
            installer = release / "install.sh"
            installer.write_text("#!/bin/sh\n")
            installer.chmod(0o700)
            (release / "README.md").write_text("Silver\n")
            first, second = root / "first.tar.gz", root / "second.tar.gz"
            package.archive(release, first, 1000)
            os.utime(installer, (2000, 2000))
            installer.chmod(0o755)
            package.archive(release, second, 1000)
            self.assertEqual(package.digest(first), package.digest(second))
            with tarfile.open(first) as tar:
                info = tar.getmember(f"{release.name}/install.sh")
                self.assertEqual((info.uid, info.gid, info.mtime, info.mode), (0, 0, 1000, 0o755))

    def test_head_must_match_the_release_tag(self):
        with (patch.object(package, "assert_platform"),
              patch.object(package, "git", side_effect=["head", "other-commit"]),
              self.assertRaisesRegex(ValueError, "not the version tag's commit")):
            package.package(SimpleNamespace(tag="v1.2.3", untagged=False))

    def test_wrong_install_manifest_aborts_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            installed = Path(tmp) / "installed"
            (installed / "bin").mkdir(parents=True)
            (installed / "bin/unexpected").touch()
            with self.assertRaisesRegex(ValueError, "command table mismatch"):
                package.stage_payload(package.REPO, installed, Path(tmp) / "binary")


class BinaryInstallerTests(unittest.TestCase):
    def setUp(self):
        try:
            package.assert_platform()
        except (OSError, ValueError):
            self.skipTest("binary installer only runs on Ubuntu 26.04 x86_64")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.extract = self.root / "extracted archive"
        self.payload = self.extract / "payload/bin"
        self.payload.mkdir(parents=True)
        self.path = self.root / "tools"
        self.path.mkdir()
        for tool in ("bash", "dirname", "uname", "mkdir", "install", "ln", "cmp", "stat", "rm"):
            (self.path / tool).symlink_to(shutil.which(tool))
        self.installed = self.root / "prefix with spaces"
        self.env = {"PATH": str(self.path), "HOME": str(self.root),
                    "OPAM_SWITCH": "ignored", "SILVER_BUILD_JOBS": "ignored"}
        self.rows = package.command_table(package.REPO)
        for relative in ("install.sh", "scripts/release/commands.txt", "scripts/installer-provider.py"):
            dest = self.extract / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(package.REPO / relative, dest)
        (self.extract / "BINARY-RELEASE").touch()
        for name, *_ in self.rows:
            out = self.payload / name
            out.write_text(f"#!/bin/sh\n[ \"$1\" = --help ] && echo {name}\n")
            out.chmod(0o755)

    def invoke(self, *args):
        return subprocess.run(
            [self.extract / "install.sh", "--prefix", self.installed.name, *args],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=10,
        )

    def test_installs_relative_prefix_without_opam_or_python_and_relocates(self):
        result = self.invoke("--without-asic")
        self.assertEqual(result.returncode, 0, result.stderr)
        # Verify an upgrade over an existing prefix as well as a fresh install.
        self.assertEqual(self.invoke("--without-asic").returncode, 0)
        shutil.rmtree(self.extract)
        self.assertFalse((self.installed / "lib").exists())
        self.assertFalse((self.installed / "bin/silver").exists())
        for name, *aliases in self.rows:
            command = self.installed / "bin" / name
            self.assertFalse(command.is_symlink())
            self.assertEqual(subprocess.check_output([command, "--help"], text=True).strip(), name)
            for alias in aliases:
                self.assertEqual((command.parent / alias).readlink(), Path(name))

    def test_unrelated_ag_is_not_overwritten_and_path_collision_warns(self):
        bin_dir = self.installed / "bin"
        bin_dir.mkdir(parents=True)
        launcher = bin_dir / "ag"
        unrelated = b"#!/bin/sh\nexit 11\n"
        launcher.write_bytes(unrelated)
        launcher.chmod(0o755)
        result = self.invoke("--without-asic")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to overwrite", result.stderr)
        self.assertEqual(launcher.read_bytes(), unrelated)
        launcher.unlink()
        launcher.symlink_to(bin_dir / "missing")
        self.assertNotEqual(self.invoke("--without-asic").returncode, 0)
        self.assertTrue(launcher.is_symlink())
        launcher.unlink()
        (self.path / "ag").write_bytes(unrelated)
        (self.path / "ag").chmod(0o755)
        result = self.invoke("--without-asic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("another ag is on PATH", result.stderr)
        self.assertEqual((self.path / "ag").read_bytes(), unrelated)

    def test_upgrade_removes_matching_old_launcher_only(self):
        bin_dir = self.installed / "bin"
        bin_dir.mkdir(parents=True)
        legacy = bin_dir / "hardcaml-workbench"
        old = bin_dir / "silver"
        contents = "#!/bin/sh\n# previous installed Silver\n"
        legacy.write_text(contents)
        legacy.chmod(0o755)
        shutil.copy2(legacy, old)
        result = self.invoke("--without-asic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old.exists())
        self.assertIn("Removed previous Silver launcher", result.stdout)
        self.assertEqual(legacy.readlink(), Path("ag"))

        old.write_text("#!/bin/sh\n# separate unrelated silver\n")
        old.chmod(0o755)
        result = self.invoke("--without-asic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("leaving unrecognized", result.stderr)
        self.assertIn("unrelated silver", old.read_text())

    def test_upgrade_from_legacy_binary_alias(self):
        bin_dir = self.installed / "bin"
        bin_dir.mkdir(parents=True)
        old = bin_dir / "silver"
        old.write_text("#!/bin/sh\n# previous binary release\n")
        old.chmod(0o755)
        (bin_dir / "hardcaml-workbench").symlink_to("silver")
        result = self.invoke("--without-asic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old.exists())
        self.assertEqual((bin_dir / "hardcaml-workbench").readlink(), Path("ag"))

    def test_incomplete_or_unloadable_payload_does_not_write_to_prefix(self):
        cmd = self.payload / "silver-daemon"
        cmd.write_text("#!/bin/sh\nexit 127\n")
        self.assertIn("libgmp10", self.invoke("--without-asic").stderr)
        cmd.unlink()
        self.assertIn("missing silver-daemon", self.invoke("--without-asic").stderr)
        self.assertFalse(self.installed.exists())

    def test_wrong_architecture_and_source_only_flags(self):
        self.assertIn("only apply to source", self.invoke("--without-asic", "--switch", "bad").stderr)
        (self.path / "uname").unlink()
        (self.path / "uname").write_text("#!/bin/sh\n[ \"$1\" = -s ] && echo Linux || echo aarch64\n")
        (self.path / "uname").chmod(0o755)
        self.assertIn("Ubuntu 26.04 Linux x86_64", self.invoke("--without-asic").stderr)
        self.assertFalse(self.installed.exists())

    def test_compatible_asic_provider_is_checked_in_binary_mode(self):
        self.assertIn("python3 is needed", self.invoke().stderr)
        (self.path / "python3").symlink_to(shutil.which("python3"))
        provider = self.path / "hardcaml_asic"
        provider.write_text("#!/bin/sh\n"
                            "echo '{\"cli_contract\":{\"version\":4,\"capabilities\":{\"namedflow1\":true}}}'\n")
        provider.chmod(0o755)
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Compatible ASIC provider: {provider}", result.stdout)


if __name__ == "__main__":
    unittest.main()
