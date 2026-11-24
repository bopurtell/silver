#!/usr/bin/env python3
"""FS2v1 conformance and Bazel adapter tests, without a Bluespec toolchain."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
from fixtures.simulation_fixture_wire import parse, sexp

SOURCE = (
    Path(__file__).resolve().parents[1] / "examples" / "bluespec_classic" / "simulation_provider.py"
)
FAKE_BAZEL = r'''
import json
import os
from pathlib import Path
import sys

argv = sys.argv[1:]
Path("invocation.json").write_text(json.dumps({"cwd": str(Path.cwd()), "args": argv}))
assert argv[:3] == ["run", "//:bench", "--"] and len(argv) == 5
trace = Path(argv[3])
assert trace.is_absolute() and not trace.exists()
mode = os.environ["FAKE_MODE"]
vcd = ("$timescale 1ns $end\n$scope module counter $end\n"
       "$var wire 1 ! count $end\n$upscope $end\n$enddefinitions $end\n#0\n0!\n#5\n1!\n")
if mode == "symlink":
    source = Path.cwd() / "outside.vcd"
    source.write_text(vcd)
    trace.symlink_to(source)
elif mode != "missing-wave":
    trace.write_text("not a VCD\n" if mode == "bad-wave" else vcd)
if mode == "failed":
    print("Mismatch: expected 1, got 0", file=sys.stderr)
    print("RESULT Failed")
elif mode == "no-result":
    print("RESULT Passed", file=sys.stderr)
elif mode == "bad-result":
    print("RESULT Maybe")
elif mode == "duplicate":
    print("RESULT Passed")
    print("RESULT Passed")
elif mode == "embedded":
    print("x" * 16384 + "RESULT Passed")
else:
    print("RESULT Passed")
if mode == "bazel-failed":
    print("Bazel/build failure", file=sys.stderr)
    sys.exit(17)
'''


class ProviderTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="classic provider ")
        self.addCleanup(directory.cleanup)
        self.project = Path(directory.name)
        self.provider = self.project / SOURCE.name
        shutil.copyfile(SOURCE, self.provider)
        self.artifacts = self.project / "artifacts"
        self.artifacts.mkdir()
        self.request_path = self.project / "request.sexp"
        self.events_path = self.project / "events.sexp"
        self.events_path.touch()
        self.invocation = self.project / "invocation.json"
        self.bin = self.project / "bin"
        self.bin.mkdir()
        fake = self.bin / "bazel"
        fake.write_text(f"#!{sys.executable}\n{FAKE_BAZEL}", encoding="utf-8")
        fake.chmod(0o755)

    def call(self, operation, *args, mode="passed", bazel=True):
        return subprocess.run(
            [sys.executable, "-S", str(self.provider), operation, "--protocol-version", "1",
             *map(str, args)],
            cwd=self.project, env={**os.environ, "PATH": str(self.bin) if bazel else "",
                                   "FAKE_MODE": mode},
            capture_output=True, text=True, timeout=10,
        )

    @staticmethod
    def request(seed="42", selection_overrides=None):
        selection = {
            "suite": "bluespec-classic", "cases": ["counter-smoke"], "seed": seed,
            "parameters": [], "asic_inputs": [],
        }
        selection.update(selection_overrides or {})
        return [
            ("protocol_version", 1), ("attempt_id", "sim-example"),
            ("selection", list(selection.items())),
        ]

    def run_request(self, request=None, raw=None, **kwargs):
        self.request_path.write_text(raw if raw is not None else sexp(request or self.request()))
        return self.call("run", "--request", self.request_path, "--events", self.events_path,
                         "--artifact-dir", self.artifacts, **kwargs)

    def events(self):
        data = self.events_path.read_bytes()
        self.assertTrue(data.endswith(b"\n"), data)
        self.assertNotIn(b"\r", data)
        records = [dict(parse(line.decode())) for line in data.splitlines()]
        for index, record in enumerate(records):
            self.assertEqual(record["attempt_id"], "sim-example")
            self.assertEqual(record["protocol_version"], "1")
            self.assertEqual(record["sequence"], str(index))
        return [record["payload"] for record in records]

    def test_discovery_standalone_without_bazel(self):
        proc = self.call("discover", bazel=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = dict(parse(proc.stdout))
        self.assertEqual(result["protocol_version"], "1")
        [suite] = map(dict, result["suites"])
        self.assertEqual(suite["id"], "bluespec-classic")
        self.assertEqual(suite["default_seed"], "42")
        self.assertEqual(suite["parameters"], [])
        [case] = map(dict, suite["cases"])
        self.assertEqual(case["id"], "counter-smoke")
        self.assertIn("Counter", case["label"])
        self.assertFalse(self.invocation.exists())

    def test_passed_catalog_case_with_full_width_seed(self):
        seed = "18446744073709551615"
        request = (
            "((protocol_version 1)(attempt_id sim-example)(selection "
            f"((suite bluespec-classic)(cases (counter-smoke))(seed {seed})"
            "(parameters ())(asic_inputs ()))))"
        )
        proc = self.run_request(raw=request)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("RESULT Passed", proc.stdout)
        invocation = json.loads(self.invocation.read_text())
        self.assertEqual(invocation["cwd"], str(self.project))
        self.assertEqual(invocation["args"], ["run", "//:bench", "--",
                                              str(self.artifacts / "counter.vcd"), seed])
        start, case_start, wave, report, case_finish, finish = self.events()
        self.assertEqual(start, "Started")
        self.assertEqual(case_start, ["Case_started", "counter-smoke"])
        self.assertEqual(wave[0], "Artifact")
        wave = dict(wave[1])
        self.assertEqual(wave["case_id"], ["counter-smoke"])
        self.assertEqual((wave["kind"], wave["media_type"]), ("waveform", "text/vcd"))
        self.assertIn("#5\n1!", (self.artifacts / wave["path"]).read_text())
        self.assertEqual(report[0], "Artifact")
        report = dict(report[1])
        self.assertNotEqual(wave["id"], report["id"])
        evidence = json.loads((self.artifacts / report["path"]).read_text())
        self.assertEqual(evidence["seed"], seed)
        self.assertEqual(evidence["outcome"], "Passed")
        self.assertEqual(case_finish[0], "Case_finished")
        self.assertEqual(dict(case_finish[1])["message"], [])
        self.assertEqual(dict(case_finish[1])["status"], "Passed")
        self.assertEqual(finish, ["Finished", "Passed"])

    def test_semantic_mismatch_keeps_waveform_and_exits_zero(self):
        proc = self.run_request(mode="failed")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Mismatch", proc.stderr)
        _, _, wave, report, case_finish, finish = self.events()
        self.assertEqual(dict(wave[1])["kind"], "waveform")
        self.assertEqual(dict(report[1])["kind"], "failure-report")
        self.assertTrue(dict(case_finish[1])["message"])
        self.assertEqual(dict(case_finish[1])["status"], "Failed")
        self.assertEqual(finish, ["Finished", "Failed"])

    def assert_incomplete(self, reason, **kwargs):
        proc = self.run_request(**kwargs)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(reason, proc.stderr)
        start, case_start, report = self.events()
        self.assertEqual(start, "Started")
        self.assertEqual(case_start, ["Case_started", "counter-smoke"])
        kind, fields = report
        self.assertEqual(kind, "Artifact")
        report = dict(fields)
        self.assertEqual(report["kind"], "failure-report")
        evidence = json.loads((self.artifacts / report["path"]).read_text())
        self.assertEqual(evidence["outcome"], "Incomplete")
        self.assertIn(reason, evidence["diagnostic"])

    def test_success_marker_does_not_override_nonzero_process_exit(self):
        self.assert_incomplete("exited 17", mode="bazel-failed")

    def test_no_bazel(self):
        self.assert_incomplete("Bazel not found on PATH", bazel=False)

    def test_stderr_is_not_a_bench_result(self):
        self.assert_incomplete("must emit exactly one RESULT", mode="no-result")

    def test_malformed_bench_result(self):
        self.assert_incomplete("must emit exactly one RESULT", mode="bad-result")

    def test_duplicate_bench_result(self):
        self.assert_incomplete("must emit exactly one RESULT", mode="duplicate")

    def test_long_log_line_is_not_a_bench_result(self):
        self.assert_incomplete("must emit exactly one RESULT", mode="embedded")

    def test_missing_waveform(self):
        self.assert_incomplete("did not write its VCD", mode="missing-wave")

    def test_bad_waveform(self):
        self.assert_incomplete("missing VCD declarations or timestamps", mode="bad-wave")

    def test_symlink_is_not_an_artifact(self):
        self.assert_incomplete("nonempty regular VCD", mode="symlink")

    def test_invalid_request_does_not_run_bazel_or_publish_events(self):
        for request in (
            self.request(seed="-1"), self.request(seed="01"),
            self.request(seed="18446744073709551616"),
            self.request(selection_overrides={"suite": "other"}),
            self.request(selection_overrides={"cases": []}),
            self.request(selection_overrides={"cases": ["counter-smoke", "counter-smoke"]}),
            self.request(selection_overrides={"parameters": [["unknown", "value"]]}),
            self.request(selection_overrides={"asic_inputs": ["unwanted"]}),
            [*self.request(), ("attempt_id", "sim-duplicate")],
        ):
            with self.subTest(request=request):
                proc = self.run_request(request)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("Bluespec Classic provider", proc.stderr)
                self.assertFalse(self.invocation.exists())
                self.assertEqual(self.events_path.read_bytes(), b"")
                self.assertEqual(list(self.artifacts.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
