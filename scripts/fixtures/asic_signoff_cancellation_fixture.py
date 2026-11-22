"""WB-096 lifecycle acceptance; real HTTP/daemon, private short prepared-flow provider."""
import argparse
import json
from pathlib import Path
import shutil
import tempfile

import fresh_frontend as frontend

api = frontend.api
field, sexp, wait, save = api.field, api.sexp, api.wait, api.save


def exercise(f, check):
    def active_routing(key):
        workflow = f.launch(key, endpoint="timing")

        def observing():
            current = f.workflow(key)
            refs = field(current, "run")
            if refs:
                candidate = run_record(refs[0])
                if stages(candidate).get("routing", {}).get("status") == "Running":
                    return candidate

        run = wait(observing, "checklist sees live Routing", timeout=12)
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
    workflow, ref, workspace, before = active_routing("cancel-during-routing")
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

    _, other_ref, other_workspace, other_before = active_routing("producer-interruption")
    (other_workspace / "interrupt").touch()
    f.done("producer-interruption", "Interrupted")
    interrupted = refresh(other_ref)
    check(field(interrupted, "status") == "interrupted", "Producer interruption is not user cancellation")
    assert_states(interrupted, other_before, "Interrupted", "Pending")
    assert_later_not_started(other_workspace)
    save(f.base / "interrupted.json", interrupted)


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
    shutil.copyfile(Path(__file__).with_name("routing_cancellation_provider.py"), fixture.root / "physical.py")
    try:
        exercise(fixture, check)
    finally:
        try:
            fixture.stop()
        finally:
            save(args.evidence / "checks.json", checks)
    print(f"PASS: {len(checks)} short-fixture lifecycle assertions", flush=True)
