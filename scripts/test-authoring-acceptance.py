"""WB-084 reporting contract. These tests never invoke EDA."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "wb084", Path(__file__).with_name("run-authoring-acceptance.py"))
wb084 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wb084)


class Reporting(unittest.TestCase):
    def test_replay_cannot_inherit_first_runs_state_or_build_cache(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {
                "DUNE_BUILD_DIR": "/other/build", "SILVER_ASIC_PROVIDER": "/other/provider",
                "GIT_DIR": "/other/repo"}):
            root = Path(tmp)
            tools = root / "tools"
            first = wb084.run_environment(root, "ui", tools)
            replay = wb084.run_environment(root, "cli", tools)
            Path(first["XDG_STATE_HOME"], "sentinel").touch()
            self.assertFalse(Path(replay["XDG_STATE_HOME"], "sentinel").exists())
            for key in ("DUNE_BUILD_DIR", "SILVER_ASIC_PROVIDER", "GIT_DIR"):
                self.assertNotIn(key, replay)
            self.assertEqual(replay["DUNE_CACHE"], "disabled")
            self.assertEqual(first["ASIC_TOOLCHAIN"], replay["ASIC_TOOLCHAIN"])

    def invoke(self, tools, body):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "evidence"
            with patch("sys.argv", ["wb084", "--evidence", str(out)]), \
                 patch.object(wb084, "prerequisites", side_effect=tools), \
                 patch.object(wb084, "journey", side_effect=body), \
                 contextlib.redirect_stdout(io.StringIO()):
                code = wb084.main()
            return code, json.loads((out / "summary.json").read_text())

    def test_unavailable_is_not_pass(self):
        code, result = self.invoke(wb084.Unavailable("missing tool"), AssertionError)
        self.assertEqual((code, result["status"], result["reason"]), (77, "skipped", "missing tool"))

    def test_failure_retains_step_and_partial_evidence(self):
        def failed(out, tools, report, record):
            report["silver"] = {"cells": 8}
            record("compare synthesis results")
            raise ValueError("different cell counts")
        code, result = self.invoke(lambda *_: {}, failed)
        self.assertEqual((code, result["status"]), (1, "failed"))
        self.assertEqual(result["step"], "compare synthesis results")
        self.assertIn("different cell counts", result["reason"])
        self.assertEqual(result["silver"], {"cells": 8})


if __name__ == "__main__":
    unittest.main()
