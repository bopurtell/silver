"""Fast authoring handoff tests; no provider, PDK, or EDA tools required."""

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import authoring_acceptance_replay as replay


SELECTION = dict(chip="sample", variant="default", flow="standard", profile="balanced",
                 endpoint="synthesis", assignments=[])
SOURCES = {"dune-project": "(lang dune 3.17)\n", "asic_sample/dune": "test dune",
           "asic_sample/chip.ml": "test chip", "asic_sample/project.ml": "test CLI"}
CATALOG = dict(schema_version=1, default_target="sample",
               targets=[dict(id="sample", executable="asic_sample/project.exe")])


class ReplayTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name).resolve()
        self.project = self.base / "original design"
        self.project.mkdir()
        self.receipts = self.base / "evidence"
        self.receipts.mkdir()
        self.clone = self.base / "clean design"
        self.rendered = dict(schema_version=1, provider="hardcaml_asic",
                             files=[dict(path=path, contents=contents) for path, contents in SOURCES.items()])
        self.published = [*SOURCES, replay.CATALOG, *sorted(replay.SILVER_CONFIG)]
        for name, text in {**SOURCES, replay.CATALOG: json.dumps(CATALOG),
                           **dict.fromkeys(replay.SILVER_CONFIG, "Silver config")}.items():
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def snapshot(self):
        return replay.capture_starter(self.project, self.published, self.rendered)

    def assert_step(self, step, pattern, call):
        with self.assertRaisesRegex(replay.ReplayError, pattern) as raised:
            call()
        self.assertEqual(raised.exception.step, step)

    def test_capture_rejects_unreviewed_bytes_and_paths(self):
        source = self.project / "asic_sample/chip.ml"
        source.write_text("changed")
        self.assert_step("starter source capture", "authored bytes differ", self.snapshot)
        source.write_text(SOURCES["asic_sample/chip.ml"])
        self.published.append(".dev/activate.sh")
        self.assert_step("starter source capture", "published portable paths differ", self.snapshot)
        self.published.pop()
        self.rendered["files"].append(dict(path="asic_sample/_build/cache", contents="stale"))
        self.assert_step("starter source capture", "not a portable starter path", self.snapshot)
        self.rendered["files"].pop()
        source.unlink()
        outside = self.base / "outside"
        outside.write_text(SOURCES["asic_sample/chip.ml"])
        source.symlink_to(outside)
        self.assert_step("starter source capture", "not a plain source file", self.snapshot)

    @unittest.skipUnless(shutil.which("git"), "fixture cloning requires Git")
    def test_only_verified_sources_are_committed_in_a_separate_clone(self):
        snapshot = self.snapshot()
        fake_repo = self.base / "developer metadata"
        fake_repo.mkdir()
        (fake_repo / "do-not-copy").write_text("unchanged")
        # An inherited developer Git dir, index and identity must be ignored.
        inherited = dict(os.environ, GIT_DIR=str(fake_repo), GIT_INDEX_FILE=str(fake_repo / "index"),
                         GIT_AUTHOR_EMAIL="developer@example.com")
        commit_receipts = self.base / "commit"
        commit_receipts.mkdir()
        (self.project / "_build").mkdir()
        for name in (".digest-db", "trace.csexp", ".lock"):
            (self.project / "_build" / name).touch()
        commit = replay.commit_starter(snapshot, commit_receipts, inherited)
        self.assert_step("commit starter fixture", "existing repository",
                         lambda: replay.commit_starter(snapshot, commit_receipts, inherited))
        for name in (".dev", "_flow_tools", "_build", "_flow_results", ".silver"):
            directory = self.project / name
            directory.mkdir(exist_ok=True)
            (directory / "do-not-copy").write_text(name)
        env = replay.command_env(inherited)
        info = replay.clone_starter(snapshot, self.clone, self.receipts, env, fixture_commit=commit)
        self.assertEqual(set(info["files"]), {*SOURCES, replay.CATALOG})
        self.assertEqual(info["fixture_identity"], replay.FIXTURE_IDENTITY)
        self.assertRegex(info["fixture_commit"], "^[0-9a-f]{40}$")
        self.assertEqual(info["fixture_commit"], commit)
        self.assertTrue((self.clone / ".git").is_dir())
        self.assertEqual(list(fake_repo.iterdir()), [fake_repo / "do-not-copy"])
        for name in (".dev", "_flow_tools", "_build", "_flow_results", ".silver"):
            self.assertFalse((self.clone / name).exists())
        other_receipts = self.base / "evidence again"
        other_receipts.mkdir()
        repeated = replay.clone_starter(snapshot, self.base / "another clone", other_receipts, env,
                                        fixture_commit=commit)
        self.assertEqual(info["fixture_commit"], repeated["fixture_commit"])
        from_commit = self.base / "from existing fixture"
        from_commit.mkdir()
        existing = replay.clone_starter(replay.StarterSnapshot(self.clone, snapshot.files),
                                        self.base / "clone of clone", from_commit, env,
                                        fixture_commit=info["fixture_commit"])
        self.assertEqual(info["fixture_commit"], existing["fixture_commit"])
        self.assertFalse((from_commit / "starter-fixture").exists())
        self.assert_step("clean source clone", "separate tree", lambda: replay.clone_starter(
            snapshot, self.project / "unsafe", self.receipts, env, fixture_commit=commit))

    def report(self):
        methodology = dict(state="recorded", reference={"attempt_id": "stream"},
                           plan_identity="preview", bundle_identity="bundle",
                           flow={"id": "standard"}, profile={"id": "balanced"},
                           endpoint="synthesis", effective_parameters=[])
        compatibility = dict(binding=dict(image_identity=dict(image_id="docker-image")), bridge_sha256="bridge",
                             requested_tools={"pdk_revision": "pdk"}, target={"technology": "ihp-sg13cmos5l"})
        checkpoint = dict(reference={"boundary": "synthesis"}, validation={"manifest": {"compatibility": compatibility}},
                          metrics=[dict(raw_key=replay.METRIC, value=14.0, unit="cells",
                                        availability="available", source={"field": "metrics." + replay.METRIC})])
        return dict(contract="hardcaml-asic.report", schema_version=1,
                    target=dict(kind="stage_execution", selected_record="/execution"),
                    execution=dict(attempt_id="stream", status="completed", exit_code=0),
                    completion=dict(requested="synthesis", physical="synthesis"),
                    methodology=methodology, checkpoints=[checkpoint])

    def read(self, report):
        return replay.read_metric(report, execution="/execution", stream_id="stream", plan_identity="preview",
                                  selection=SELECTION, observed_methodology=self.report()["methodology"])

    def test_metric_requires_valid_completed_synthesis_and_exact_units(self):
        self.assertEqual(self.read(self.report())["metric"]["value"], 14)
        for value in (True, "14", 0, -14, 14.2, float("nan"), float("inf"), None):
            with self.subTest(value=value):
                report = self.report()
                report["checkpoints"][0]["metrics"][0]["value"] = value
                with self.assertRaisesRegex(ValueError, "not a positive integer"):
                    self.read(report)
        report = self.report()
        report["checkpoints"] *= 2
        with self.assertRaisesRegex(ValueError, "one synthesis checkpoint"):
            self.read(report)
        report = self.report()
        report["execution"]["status"] = "failed"
        with self.assertRaisesRegex(ValueError, "not a completed execution"):
            self.read(report)

    def pair(self):
        common = dict(**self.read(self.report()), selection=SELECTION, provider_sha256="provider",
                      runtime_roots=replay.canonical_tool_paths(dict(
                          support_tools=self.base / "tools/tt", pdk_root=self.base / "tools/pdk",
                          python=self.base / "tools/.venv/bin/python")),
                      design_inputs={path: hashlib.sha256(data.encode()).hexdigest() for path, data in SOURCES.items()},
                      synthesis_inputs={"src/chip.v": "rtl"})
        return (dict(**common, project=str(self.project), attempt="/attempt", stream_id="old",
                     execution_file="/old/execution"),
                dict(**copy.deepcopy(common), project=str(self.clone), attempt="/different-attempt", stream_id="new",
                     execution_file="/new/execution"))

    def test_comparison_ignores_attempt_specific_ids_but_not_results_or_inputs(self):
        original, repeat = self.pair()
        repeat.update(plan_identity="new-preview", bundle_identity="new-bundle")
        self.assertEqual(replay.compare_synthesis(original, repeat),
                         dict(key=replay.METRIC, unit="cells", silver=14, replay=14, equal=True))
        for field in ("runtime", "runtime_roots", "effective_parameters", "design_inputs", "synthesis_inputs",
                      "provider_sha256", "selection"):
            with self.subTest(field=field):
                changed = dict(repeat, **{field: None})
                self.assert_step("compare synthesis", f"non-comparable {field}",
                                 lambda: replay.compare_synthesis(original, changed))
        repeat["metric"]["value"] = 15
        self.assert_step("compare synthesis", "Silver 14, replay 15",
                         lambda: replay.compare_synthesis(original, repeat))
        self.assert_step("compare synthesis", "independently allocated",
                         lambda: replay.compare_synthesis(original, original))

    @unittest.skipUnless(shutil.which("git"), "fixture cloning requires Git")
    def test_replay_dispatches_the_documented_cli_chain(self):
        original, repeat = self.pair()
        results = self.receipts / "results"
        bundle, attempt = results / "bundles/bundle", results / "observations/attempt"
        execution = results / "workspace/execution-new.json"
        plan = dict(plan_identity="new-preview", bundle_identity="new-bundle")
        repeat.update(attempt=str(attempt), execution_file=str(execution), **plan)
        snapshot = self.snapshot()
        fixture = self.base / "commit"
        fixture.mkdir()
        commit = replay.commit_starter(snapshot, fixture)
        original["source_revision"] = commit
        real_clone = replay.clone_starter
        real_run = replay.run

        def clone(*args, **kwargs):
            result = real_clone(*args, **kwargs)
            repeat["source_revision"] = result["fixture_commit"]
            return result

        def run(name, argv, cwd, receipts, env, timeout=120):
            if name == "build":
                self.assertEqual(cwd, self.clone)
                self.assertEqual(argv, ["dune", "build", "--root", self.clone, "--build-dir", "_build",
                                        "--cache=disabled", "-j", "1", "asic_sample/project.exe"])
            elif name == "synthesize":
                self.assertEqual(argv[:3], [self.base / "provider", "stages", bundle])
                self.assertEqual(argv[argv.index("--expected-plan-identity") + 1], "new-preview")
                self.assertEqual(json.loads((receipts / "methodology-plan.json").read_text()), plan)
                attempt.mkdir(parents=True)
                execution.parent.mkdir()
                execution.touch()
                output = receipts / "stub.stdout"
                output.write_text("\n".join(map(json.dumps, [
                    dict(contract="hardcaml-asic.stage-observation", event="observation_allocated",
                         attempt=str(attempt), stream_id="new"),
                    dict(attempt_id="new", status="completed", exit_code=0, execution_file=str(execution)),
                ])))
                return output
            else:
                return real_run(name, argv, cwd, receipts, env, timeout)

        def query(name, argv, cwd, receipts, env):
            self.assertEqual(cwd, self.clone)
            self.assertEqual(argv[:3], [self.clone / "_build/default/asic_sample/project.exe", "flow", name])
            for field in ("flow", "profile", "chip", "variant", "endpoint"):
                self.assertEqual(argv[argv.index("--" + field) + 1], SELECTION[field])
            if name == "plan":
                return plan
            self.assertEqual(argv[argv.index("--expected-plan-identity") + 1], "new-preview")
            bundle.mkdir(parents=True)
            return dict(kind="bundle_emission", reused=False, output_dir=str(bundle), plan=plan, **plan)

        steps = []
        with (patch.object(replay, "clone_starter", side_effect=clone),
              patch.object(replay, "run", side_effect=run),
              patch.object(replay, "query", side_effect=query),
              patch.object(replay, "inspect_synthesis", return_value=repeat) as inspect):
            result = replay.replay_synthesis(
                snapshot, self.clone, provider=self.base / "provider", toolchain=self.base / "tools",
                selection=SELECTION, baseline=original, receipts=self.receipts, record=steps.append,
                fixture_commit=commit)
        self.assertEqual(inspect.call_args.kwargs["attempt"], attempt)
        self.assertEqual(inspect.call_args.kwargs["stream_id"], "new")
        self.assertTrue(result["comparison"]["equal"])
        self.assertEqual(steps, ["clean source clone", "build", "plan", "emit", "synthesize",
                                      "compare synthesis"])


if __name__ == "__main__":
    unittest.main()
