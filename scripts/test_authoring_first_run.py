"""Offline checks of WB-084's terminal acceptance oracles."""

import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock

import authoring_first_run as driver


class FirstRunTest(unittest.TestCase):
    def test_selected_command_ignores_query_unselected_rows_and_background(self):
        query = "Launch and view planned run"
        expected = "Launch staged in view — demo/default · standard / balanced → synthesis"
        wrong = "Launch staged in view — demo/default · standard / balanced → floorplan"
        width = 80

        def row(content):
            return "│ > " + f"│{content:<{width}}│" + expected

        def screen(selected, unselected):
            return "\n".join((
                "    ╭" + f"{' COMMAND PALETTE · captured target ':─<{width}}" + "╮",
                row(f" > {query}▏"),
                row(" > " + selected),
                row("   " + unselected),
                "    ╰" + "─" * width + "╯",
            ))

        self.assertEqual(driver.selected_command(screen(wrong, expected), query), wrong)
        self.assertEqual(driver.selected_command(screen(expected, wrong), query), expected)
        self.assertIsNone(driver.selected_command(screen(expected, wrong), "some other query"))

    def test_launch_requires_a_completed_synthesis_with_a_reported_count(self):
        term = Mock()
        final = "│ ✓ Synthesis: completed ││ Reported cells (agg.): 53 │"
        term.drain.side_effect = [
            "│ Synthesis: running ││ Elaboration: completed ││ Reported cells (agg.): 53 │",
            "│ Synthesis: completed ││ Reported cells (agg.): not reported │",
            final,
        ]
        driver.wait_for_synthesis(term, 10)
        term.save.assert_called_once_with("synthesis-completed", final)

    def test_emission_failure_is_reported_before_synthesis_timeout(self):
        term = Mock()
        screen = "│ ! Workflow: Elaboration: emission_failed; workflow w │"
        term.drain.return_value = screen
        with self.assertRaisesRegex(RuntimeError, "failed workflow"):
            driver.wait_for_synthesis(term, 10)
        term.save.assert_called_once_with("synthesis-failed", screen)

    def test_running_is_not_an_acceptance(self):
        term = Mock()
        screen = "│ Synthesis: running │"
        term.drain.return_value = screen
        with self.assertRaisesRegex(TimeoutError, "did not show completed synthesis"):
            driver.wait_for_synthesis(term, 0)
        term.save.assert_called_once_with("synthesis-timeout", screen)

    def test_inspection_uses_one_positive_total_not_a_subtotal(self):
        self.assertEqual(driver.cell_count("│  Reported cells (agg.): 53   │\n│ 1 FDRE │"), 53)
        for text in (
            "│ Reported cells (agg.): unknown (not reported) │",
            "│ Reported cells (agg.): 0 │",
            "│ Reported cells (agg.): -2 (invalid reported total) │",
            "│ Reported cells (agg.): 53 │\n│ Reported cells (agg.): 65 │",
            "│ Filtered cell count: 35 (subset) │",
        ):
            with self.subTest(text=text), self.assertRaisesRegex(RuntimeError, "one positive total"):
                driver.cell_count(text)

    def test_dirty_directory_is_rejected_before_authoring(self):
        with TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / ".keep").touch()
            record = Mock()
            commit = Mock()
            with self.assertRaisesRegex(RuntimeError, "empty project directory"):
                driver.first_run(project, project / "evidence", project, {}, record,
                                 commit_design=commit)
            record.assert_called_once_with("silver-start-empty")
            commit.assert_not_called()
            self.assertEqual([p.name for p in project.iterdir()], [".keep"])

    def test_execution_record_must_be_one_fresh_successful_synthesis(self):
        with TemporaryDirectory() as tmp:
            results = Path(tmp)
            execution = results / "execution-test-attempt.json"
            plan = {"stages": ["synthesis"], "initial_boundary": None}
            execution.write_text(json.dumps(dict(status="completed", exit_code=0, plan=plan)))
            self.assertEqual(driver.successful_execution(results), execution)
            plan["stages"] += ["floorplan"]
            execution.write_text(json.dumps(dict(status="completed", exit_code=0, plan=plan)))
            with self.assertRaisesRegex(RuntimeError, "one fresh synthesis"):
                driver.successful_execution(results)
            (results / "execution-other.json").touch()
            with self.assertRaisesRegex(RuntimeError, "exactly one"):
                driver.successful_execution(results)

    def test_observation_reference_is_correlated_to_exact_execution(self):
        with TemporaryDirectory() as tmp:
            results = Path(tmp)
            workspace = results / "workspace"
            workspace.mkdir()
            stream, plan_identity = "1" * 32, "2" * 64
            execution = workspace / f"execution-{stream}.json"
            execution.write_text(json.dumps(dict(attempt_id=stream,
                                                 methodology=dict(plan_identity=plan_identity))))

            def allocate(name, stream_id, path):
                attempt = results / "observations" / name
                attempt.mkdir(parents=True)
                (attempt / "000000000001.json").write_text(json.dumps(
                    dict(event="allocated", stream_id=stream_id, data=dict(workspace=str(path)))))
                return attempt

            allocate("unrelated-workspace", stream, results)
            allocate("unrelated-stream", "3" * 32, workspace)
            with self.assertRaisesRegex(RuntimeError, "Expected one observation"):
                driver.execution_reference(results, execution)
            attempt = allocate("matching-observation", stream, workspace)
            self.assertEqual(driver.execution_reference(results, execution),
                             dict(attempt=str(attempt), stream_id=stream, plan_identity=plan_identity))


if __name__ == "__main__":
    unittest.main()
