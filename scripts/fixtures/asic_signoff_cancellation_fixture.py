"""WB-096 lifecycle acceptance; real HTTP/daemon, private short prepared-flow provider."""
import argparse
import json
from pathlib import Path
import shutil
import tempfile
import urllib.request

import fresh_frontend as frontend

api = frontend.api
field, sexp, wait, save = api.field, api.sexp, api.wait, api.save


def exercise(f, check):
    def active_stage(key, stage="routing"):
        workflow = f.launch(key, endpoint="timing")

        def observing():
            current = f.workflow(key)
            refs = field(current, "run")
            if refs:
                candidate = run_record(refs[0])
                if stages(candidate).get(stage, {}).get("status") == "Running":
                    return candidate

        run = wait(observing, "checklist sees live " + stage, timeout=12)
        return workflow, field(run, "run"), Path(field(field(run, "reference"), "attempt")).parent, run

    def run_record(ref):
        return next(r for r in field(f.snapshot(), "runs") if field(r, "run") == ref)

    def stages(run):
        return {field(s, "id"): dict(s) for s in field(run, "stages")}

    def refresh(ref):
        f.http.rpc("(Refresh %s)" % sexp(ref), wait=False)
        key = "refresh:" + field(ref, "id")

        def settled():
            task = next((t for t in field(f.snapshot(), "operations") if field(t, "key") == key), None)
            if task and field(task, "state") not in ("pending", "executing"):
                return task

        task = wait(settled, "evidence Refresh completes", timeout=12)
        check(field(task, "state") == "completed", "Refresh revalidates the historical run: " + str(task))
        return run_record(ref)

    def assert_later_not_started(workspace):
        journal = json.loads((workspace / "observation/journal.json").read_text())
        started = [e["data"]["occurrence"]["action_key"] for e in journal["events"] if e["event"] == "started"]
        check(started == ["implementation." + stage for stage in ["synthesis", "floorplan", "placement", "cts", "routing"]],
              "Provider journal records exactly the stages through Routing; Timing never started")
        return journal

    def assert_states(run, before, routing, timing):
        s = stages(run)
        b = stages(before)
        check([s[x] for x in ("synthesis", "floorplan", "placement", "cts")] ==
              [b[x] for x in ("synthesis", "floorplan", "placement", "cts")],
              "Completed stages, including their measured timings, are unchanged")
        check(s["signoff"] == b["signoff"] and s["signoff"]["status"] == "Not_requested",
              "Signoff remains Not requested")
        check(s["routing"]["status"] == routing and s["timing"]["status"] == timing,
              f"Routing is {routing} and requested Timing is {timing}")
        if timing == "Skipped":
            check(s["timing"]["reason"] == ["flow cancelled during routing"],
                  "Timing preserves the exact cancellation reason")

    f.start()
    f.http.rpc("Discover", wait=False)
    wait(lambda: field(f.snapshot(), "flows"), "catalog", timeout=10)
    workflow, ref, workspace, before = active_stage("cancel-during-routing")
    save(f.base / "before.json", before)
    assert_states(before, before, "Running", "Pending")
    child = int((workspace / "routing-child").read_text())
    try:
        f.cancel(workflow)
        wait(lambda: (workspace / "cleanup-entered").exists(), "provider SIGTERM cleanup", timeout=5)
        during = run_record(ref)
        check(field(during, "status") == "cancelling" and Path(f"/proc/{child}").exists()
              and not (workspace / "cleanup-finished").exists(),
              "Exact run reports Cancelling while its owned Routing descendant is still alive")
        assert_states(during, before, "Cancelling", "Pending")
        check(field(f.workflow("cancel-during-routing"), "cancel_requested") == "true",
              "Workflow exposes cancellation intent during cleanup")
        save(f.base / "during.json", during)
    finally:
        (workspace / "cleanup-release").touch()
    f.done("cancel-during-routing", "Cancelled")
    check((workspace / "cleanup-finished").exists() and not Path(f"/proc/{child}").exists(),
          "Terminal cancellation follows cleanup and reap of the Routing child")
    after = run_record(ref)
    check(field(after, "status") == "cancelled", "Terminal run is Cancelled")
    assert_states(after, before, "Cancelled", "Skipped")
    save(f.base / "after.json", after)
    journal = assert_later_not_started(workspace)
    save(f.base / "provider-terminal.json", journal)
    check(journal["inspection"]["state"]["outcome"]["status"] == "interrupted",
          "Provider reports interruption; cancellation attribution is Workbench-owned")

    refreshed = refresh(ref)
    assert_states(refreshed, before, "Cancelled", "Skipped")
    save(f.base / "refreshed.json", refreshed)
    f.stop()
    f.start()
    retained = run_record(ref)
    check(field(retained, "status") == "cancelled", "Registry retains cancellation across daemon restart")
    assert_states(retained, before, "Cancelled", "Skipped")
    reopened = refresh(ref)
    check(field(reopened, "status") == "cancelled", "Cold Refresh independently reprojects cancellation")
    assert_states(reopened, before, "Cancelled", "Skipped")
    save(f.base / "cold-refreshed.json", reopened)
    check(assert_later_not_started(workspace) == journal, "Refresh and daemon restart are read-only")

    _, other_ref, other_workspace, other_before = active_stage("producer-interruption")
    (other_workspace / "interrupt").touch()
    f.done("producer-interruption", "Interrupted")
    interrupted = refresh(other_ref)
    check(field(interrupted, "status") == "interrupted", "Producer interruption is not user cancellation")
    assert_states(interrupted, other_before, "Interrupted", "Pending")
    assert_later_not_started(other_workspace)
    save(f.base / "interrupted.json", interrupted)

    def typed_snapshot():
        body = "((instance_id %s)(project %s)(operation Get))" % (
            sexp(f.http.instance), sexp(f.http.project))
        request = urllib.request.Request(f.url + "/api/v1/asic", data=body.encode(), headers={
            "Content-Type": "application/sexp", "X-Workbench-Protocol": "1",
            "X-Workbench-Asic-Timing-Analysis": "2", "X-Workbench-Execution-Timing": "1"})
        with urllib.request.urlopen(request, timeout=10) as response:
            status, snapshot = api.c.parse(response.read().decode())
        assert status == "Ok", snapshot
        return snapshot

    def assert_timing_outcome(ref, status, freshness):
        snapshot = typed_snapshot()
        run = next(r for r in field(snapshot, "runs") if field(r, "run") == ref)
        s = stages(run)
        check(field(run, "status") == status.lower() and s["timing"]["status"] == status,
              "Exact Timing stage and enclosing run are " + status)
        check(s["routing"]["status"] == "Completed" and s["signoff"]["status"] == "Not_requested",
              "Earlier Routing remains complete; Signoff was not requested")
        check(s["timing"]["reason"] == [
            "Flow cancelled by user" if status == "Cancelled"
            else "Explicit interrupted stage occurrence; not evidence of user cancellation"],
              "Timing preserves the exact attribution")
        summary = next(s for s in field(snapshot, "summaries") if field(s, "run") == ref)
        check(field(summary, "freshness") == freshness and field(summary, "completion") == "interrupted"
              and field(summary, "acceptance") == "not_evaluated" and not field(summary, "terminal"),
              "Report is not a completed execution or an acceptance verdict")
        analysis, = field(summary, "timing_analysis")
        check(field(analysis, "status") == "Completed" and field(analysis, "timing_goal") == "Pass"
              and field(analysis, "enclosing_status") == "interrupted"
              and field(field(analysis, "target"), "occurrence_id") == field(ref, "id") + "/implementation.timing",
              "Successful native STA is supplementary evidence for this exact interrupted occurrence")
        return run, summary

    (f.root / "stop-in-timing").touch()
    workflow, ref, workspace, before = active_stage("cancel-during-timing", "timing")
    assert_states(before, before, "Completed", "Running")
    wait(lambda: (workspace / "sta-finished").exists(), "passing native STA before cancellation")
    try:
        f.cancel(workflow)
        wait(lambda: (workspace / "cleanup-entered").exists(), "Timing SIGTERM cleanup")
        assert_states(run_record(ref), before, "Completed", "Cancelling")
    finally:
        (workspace / "cleanup-release").touch()
    f.done("cancel-during-timing", "Cancelled")
    journal = json.loads((workspace / "observation/journal.json").read_text())
    check([(e["event"], e["data"]["occurrence"]["status"]) for e in journal["events"]
           if e["data"].get("occurrence", {}).get("action_key") == "implementation.timing"]
          == [("started", "running"), ("finished", "interrupted")],
          "The provider journals Timing started/interrupted, never published or completed")
    save(f.base / "timing-cancelled.json", assert_timing_outcome(ref, "Cancelled", "Validated"))
    refresh(ref)
    save(f.base / "timing-refreshed.json", assert_timing_outcome(ref, "Cancelled", "Validated"))

    f.stop()
    f.start()
    f.http.rpc("(Load_summary %s)" % sexp(ref), wait=False)
    wait(lambda: any(field(s, "run") == ref for s in field(typed_snapshot(), "summaries")),
         "load retained Timing summary")
    save(f.base / "timing-cached.json", assert_timing_outcome(ref, "Cancelled", "Cached_unverified"))
    refresh(ref)
    save(f.base / "timing-cold-refreshed.json", assert_timing_outcome(ref, "Cancelled", "Validated"))
    check(json.loads((workspace / "observation/journal.json").read_text()) == journal,
          "Warm and cold Refresh leave Timing journal unchanged")

    _, unrelated, unrelated_workspace, _ = active_stage("interrupted-timing", "timing")
    (unrelated_workspace / "interrupt").touch()
    f.done("interrupted-timing", "Interrupted")
    unrelated_journal = json.loads((unrelated_workspace / "observation/journal.json").read_text())
    check(unrelated_journal["inspection"]["state"]["outcome"] == journal["inspection"]["state"]["outcome"]
          == dict(status="interrupted", exit_code=143, error="backend execution interrupted"),
          "Identical provider outcomes differ only in Silver's exact cancellation attribution")
    refresh(unrelated)
    save(f.base / "timing-interrupted.json", assert_timing_outcome(unrelated, "Interrupted", "Validated"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", required=True, type=lambda p: Path(p).resolve())
    parser.add_argument("--evidence-dir", type=Path, default=Path("/tmp/opencode"))
    args = parser.parse_args()
    args.evidence = Path(tempfile.mkdtemp(prefix="wb096-routing-cancellation-", dir=args.evidence_dir))
    checks = []

    def check(ok, message):
        checks.append(dict(passed=bool(ok), expectation=message))
        api.require(ok, message)

    print(f"Evidence: {args.evidence}", flush=True)
    fixture = api.Fixture(args, "routing", check)
    # Resolve the already-selected switch's Dune before entering the private HOME.
    # No shared Workbench build; private synthetic project builds still use the lock.
    dune = shutil.which("dune")
    api.require(dune is not None, "Run the fixture with Dune on PATH")
    wrapper = fixture.base / "bin/dune"
    wrapper.write_text(wrapper.read_text().replace(
        '"' + str(api.HERE / "with-switch.sh") + '" dune "$@"',
        '"%s" "$@"' % Path(dune).resolve()))
    shutil.copyfile(Path(__file__).with_name("routing_cancellation_provider.py"), fixture.root / "physical.py")
    try:
        exercise(fixture, check)
    finally:
        try:
            fixture.stop()
        finally:
            save(args.evidence / "checks.json", checks)
    print(f"PASS: {len(checks)} short-fixture lifecycle assertions", flush=True)
