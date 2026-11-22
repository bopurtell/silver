"""Short prepared-flow fixture with CLI4 observation cursors and staged cleanup."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def envelope(kind, version=1, **fields):
    return dict(contract="hardcaml-asic." + kind, schema_version=version, **fields)


def atomic(path, data):
    pending = path.with_suffix(".pending")
    pending.write_text(json.dumps(data))
    pending.replace(path)


def emit(data):
    print(json.dumps(data), flush=True)


def produce(option):
    plan = json.loads(Path(option("--methodology-plan")).read_text())
    assert plan["plan_identity"] == option("--expected-plan-identity")
    recipe = plan["methodology"]["recipe"]
    assert recipe["stages"] == ["synthesis", "floorplan", "placement", "cts", "routing", "timing"]
    workspace = Path(option("--workspace"))
    attempt = workspace / "observation"
    attempt.mkdir(parents=True)
    stream = workspace.name
    execution_file = attempt / "execution.json"
    methodology = envelope("historical-methodology", state="recorded",
                           plan_identity=plan["plan_identity"], bundle_identity=plan["bundle_identity"],
                           reference=dict(attempt_id=stream))
    events, artifacts = [], []
    occurrences = {stage: dict(action_key="implementation." + stage,
                               occurrence_id=stream + "/implementation." + stage,
                               status="unreached", exit_code=None, duration_seconds=0,
                               error=None, best_effort=False, verdict=None)
                   for stage in recipe["stages"]}
    started = time.monotonic()

    def event(name, **data):
        events.append(envelope("stage-observation", 2, stream_id=stream, sequence=len(events) + 1,
                               event=name, data=data, recorded_at="2026-10-20T12:00:00.000000Z",
                               elapsed_seconds=time.monotonic() - started))

    def publish(outcome=None):
        execution = dict(attempt_id=stream, plan=recipe, occurrences=list(occurrences.values()),
                         artifacts=artifacts)
        if outcome:
            atomic(execution_file, dict(execution, **outcome))
        inspection = envelope("stage-observation", 2, stream_id=stream, cursor=len(events),
                              writer_active=outcome is None,
                              observation_status="active" if outcome is None else "final",
                              state=dict(execution, outcome=outcome), methodology=methodology,
                              execution_file=str(execution_file) if outcome else None)
        # A single atomic generation for both observations.
        atomic(attempt / "journal.json", dict(inspection=inspection, events=events))

    def occurrence(stage, name, status, exit_code, duration=0, error=None, artifact=None):
        current = dict(occurrences[stage], status=status, exit_code=exit_code,
                       duration_seconds=duration, error=error)
        occurrences[stage] = current
        event(name, occurrence=current, artifact=artifact)

    request = dict(expected_plan_identity=plan["plan_identity"],
                   methodology_launch=dict(attempt_id=stream, expected_plan_identity=plan["plan_identity"]))
    event("allocated", request=request, workspace=str(workspace))
    event("planned", plan=recipe)
    event("prepared", runtime_record=None)
    for stage in recipe["stages"][:4]:
        checkpoint = workspace / (stage + "-checkpoint")
        checkpoint.write_text(stage)
        artifact = dict(boundary=stage, path=str(checkpoint), identity=hashlib.sha256(stage.encode()).hexdigest())
        artifacts.append(artifact)
        occurrence(stage, "started", "running", None)
        occurrence(stage, "published", "running", None, artifact=artifact)
        occurrence(stage, "finished", "completed", 0, duration=.125, artifact=artifact)

    stop = None

    def terminate(_signum, _frame):
        nonlocal stop
        stop = "SIGTERM"

    signal.signal(signal.SIGTERM, terminate)
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    (workspace / "routing-child").write_text(str(child.pid))
    try:
        occurrence("routing", "started", "running", None)
        publish()
        emit(envelope("stage-observation", event="observation_allocated",
                      attempt=str(attempt), stream_id=stream))
        deadline = time.monotonic() + 30
        while stop is None and not (workspace / "interrupt").exists() and time.monotonic() < deadline:
            time.sleep(.02)
        if stop is not None:
            (workspace / "cleanup-entered").touch()
            deadline = time.monotonic() + 10
            while not (workspace / "cleanup-release").exists() and time.monotonic() < deadline:
                time.sleep(.02)
        error = "Routing interrupted by " + (stop or "fixture producer")
    finally:
        child.terminate()
        child.wait(timeout=2)
    (workspace / "cleanup-finished").touch()
    occurrence("routing", "finished", "interrupted", 143 if stop else 130,
               duration=time.monotonic() - started, error=error)
    outcome = dict(status="interrupted", exit_code=143 if stop else 130, error=error)
    event("outcome", **outcome)
    publish(outcome)
    emit(envelope("stage-observation", event="observation_terminal", execution_file=str(execution_file)))
    return outcome["exit_code"]


def main():
    args = sys.argv[1:]

    def option(flag):
        return args[args.index(flag) + 1]

    if args == ["--version", "--json"]:
        emit(dict(cli_contract=dict(version=4, capabilities=dict(namedflow1=True, timing_stage1=True))))
    elif args[:1] == ["stages"]:
        return produce(option)
    elif args[:1] == ["observation"]:
        generation = json.loads((Path(args[2]) / "journal.json").read_text())
        inspection = generation["inspection"]
        if args[1] == "inspect":
            emit(inspection)
        else:
            assert args[1] == "read-updates" and option("--stream-id") == inspection["stream_id"]
            after = int(option("--after"))
            emit(envelope("stage-observation", 2, stream_id=inspection["stream_id"], after=after,
                          cursor=inspection["cursor"], events=generation["events"][after:]))
    elif args[:1] == ["report"]:
        path = Path(args[1])
        inspection = json.loads((path.parent / "journal.json").read_text())["inspection"]
        execution = json.loads(path.read_text())
        emit(envelope("report", execution=execution, methodology=inspection["methodology"],
                      checkpoints=[dict(reference=a) for a in execution["artifacts"]],
                      completion=dict(physical="partial"), acceptance="not_evaluated"))
    else:
        raise ValueError(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
